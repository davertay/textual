import SwiftUI

// MARK: - Overview
//
// HighlightedTextFragment displays syntax-highlighted code. Highlighting is derived in `body` from
// the current content, the latest tokens, and the environment (theme, color scheme, dynamic type).
//
// The displayed text always comes from the current content. Tokens from an earlier version of the
// code are reused while they still match it from the start, as streamed code does: the matching
// tokens keep their colors and the rest shows as plain text until the next tokenization lands.
//
// Tokenization is requested from `body` too, rather than from `task(id:)` or `onChange`, which a
// rapidly updating view can miss: SwiftUI runs an `onChange` action at most once per frame. At most
// one tokenization runs at a time and the latest code wins, so streamed code never queues a backlog
// and always ends tokenized.
//
// The presentationIntent is preserved after highlighting so pasteboard formatters can
// reconstruct the block structure when copying code.

struct HighlightedTextFragment: View {
  @Environment(\.textEnvironment) private var textEnvironment

  @State private var model = Model()

  private let content: AttributedSubstring
  private let languageHint: String?
  private let theme: StructuredText.HighlighterTheme

  init(
    _ content: AttributedSubstring,
    languageHint: String?,
    theme: StructuredText.HighlighterTheme
  ) {
    self.content = content
    self.languageHint = languageHint
    self.theme = theme
  }

  var body: some View {
    let code = String(content.characters[...])
    let _ = model.requestTokens(for: code, languageHint: languageHint)
    TextFragment(
      Self.highlight(
        tokens: model.tokens(for: code),
        presentationIntent: content.presentationIntent,
        using: theme,
        environment: textEnvironment
      )
    )
    .foregroundStyle(theme.foregroundColor)
  }

  static func highlight(
    tokens: [CodeToken],
    presentationIntent: PresentationIntent?,
    using theme: StructuredText.HighlighterTheme,
    environment: TextEnvironmentValues
  ) -> AttributedString {
    var attributes = AttributeContainer()
    // Re-apply the presentation intent for pasteboard formatters
    attributes.presentationIntent = presentationIntent
    ForegroundColorProperty(theme.foregroundColor)
      .apply(in: &attributes, environment: environment)
    var highlightedCode = AttributedString()

    for token in tokens {
      var content = AttributedString(token.content)
      var tokenAttributes = attributes

      if let tokenProperties = theme.tokenProperties[token.type] {
        tokenProperties.apply(in: &tokenAttributes, environment: environment)
      }

      content.mergeAttributes(tokenAttributes)
      highlightedCode.append(content)
    }

    return highlightedCode
  }
}

extension HighlightedTextFragment {
  @MainActor @Observable final class Model {
    struct Tokenization: Equatable {
      let code: String
      let languageHint: String
      let tokens: [CodeToken]
    }

    /// The latest finished tokenization.
    private(set) var tokenized: Tokenization?

    @ObservationIgnored private var requested: (code: String, languageHint: String)?
    @ObservationIgnored private var isTokenizing = false

    /// Tokens that concatenate to exactly `code`: the latest tokenization's leading tokens for as
    /// long as they match `code`, then whatever is left as plain text.
    func tokens(for code: String) -> [CodeToken] {
      var tokens: [CodeToken] = []
      var remaining = code[...]

      for token in tokenized?.tokens ?? [] {
        guard remaining.hasPrefix(token.content) else { break }
        tokens.append(token)
        remaining = remaining.dropFirst(token.content.count)
      }

      if !remaining.isEmpty {
        tokens.append(CodeToken(content: String(remaining), type: .plain))
      }
      return tokens
    }

    /// Asks for `code` to be tokenized. Cheap to call on every `body` evaluation: only a change
    /// starts work, at most one tokenization runs at a time, and the latest request wins.
    func requestTokens(for code: String, languageHint: String?) {
      guard CodeTokenizer.shared != nil, let languageHint else { return }
      guard requested?.code != code || requested?.languageHint != languageHint else { return }

      requested = (code, languageHint)
      guard !isTokenizing else { return }

      isTokenizing = true
      Task { await tokenizeRequests() }
    }

    /// Tokenizes the latest request until no newer one is waiting.
    func tokenizeRequests() async {
      defer { isTokenizing = false }

      while let request = requested,
        request.code != tokenized?.code || request.languageHint != tokenized?.languageHint
      {
        tokenized = await tokenize(code: request.code, languageHint: request.languageHint)
      }
    }

    private func tokenize(code: String, languageHint: String) async -> Tokenization {
      let tokens = await CodeTokenizer.shared?.tokenize(code: code, language: languageHint) ?? []
      // Tokens that don't reproduce the code exactly would change the displayed text.
      guard tokens.map(\.content).joined() == code else {
        return Tokenization(
          code: code, languageHint: languageHint, tokens: [CodeToken(content: code, type: .plain)]
        )
      }
      return Tokenization(code: code, languageHint: languageHint, tokens: tokens)
    }
  }
}

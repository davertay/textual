import Testing

@testable import Textual

@MainActor
struct HighlightedTextFragmentModelTests {
  @Test func showsPlainCodeBeforeAnyTokenization() {
    let model = HighlightedTextFragment.Model()
    #expect(model.tokens(for: "let x = 1") == [CodeToken(content: "let x = 1", type: .plain)])
  }

  @Test func usesTheTokenizationOfTheSameCode() async {
    let model = HighlightedTextFragment.Model()
    await tokenize("let x = 1", in: model)

    let tokens = model.tokens(for: "let x = 1")
    #expect(tokens.count > 1)
    #expect(tokens.map(\.content).joined() == "let x = 1")
  }

  @Test func extendsTheTokenizationWithAPlainSuffixWhenTheCodeGrows() async {
    let model = HighlightedTextFragment.Model()
    await tokenize("let x = 1", in: model)
    let tokenized = model.tokens(for: "let x = 1")

    #expect(
      model.tokens(for: "let x = 1\nlet y") == tokenized + [CodeToken(content: "\nlet y", type: .plain)]
    )
  }

  @Test func keepsTheMatchingLeadingTokensWhenTheTailDiverges() async {
    // A streamed closing fence briefly leaves a backtick at the end of the block's code.
    let model = HighlightedTextFragment.Model()
    await tokenize("let x = 1\n`", in: model)

    let tokens = model.tokens(for: "let x = 1\n")
    #expect(tokens.map(\.content).joined() == "let x = 1\n")
    #expect(tokens.first == model.tokenized?.tokens.first)
    #expect(tokens.first?.type != .plain)
  }

  @Test func showsUnrelatedCodeAsPlainText() async {
    let model = HighlightedTextFragment.Model()
    await tokenize("let x = 1", in: model)

    #expect(model.tokens(for: "var y = 2") == [CodeToken(content: "var y = 2", type: .plain)])
  }

  @Test func leavesCodeWithoutALanguageHintPlain() {
    let model = HighlightedTextFragment.Model()
    model.requestTokens(for: "let x = 1", languageHint: nil)

    #expect(model.tokenized == nil)
    #expect(model.tokens(for: "let x = 1") == [CodeToken(content: "let x = 1", type: .plain)])
  }

  @Test func tokenizesTheLatestOfRapidRequests() async {
    let model = HighlightedTextFragment.Model()
    model.requestTokens(for: "let a", languageHint: "swift")
    model.requestTokens(for: "let ab", languageHint: "swift")
    await tokenize("let abc", in: model)

    #expect(model.tokenized?.code == "let abc")
  }

  private func tokenize(_ code: String, in model: HighlightedTextFragment.Model) async {
    model.requestTokens(for: code, languageHint: "swift")
    for _ in 0..<400 where model.tokenized?.code != code {
      try? await Task.sleep(for: .milliseconds(5))
    }
  }
}

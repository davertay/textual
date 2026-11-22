import SwiftUI

// MARK: - Overview
//
// `WithAttachments` resolves attachment references in an `AttributedString`.
//
// Markup parsing keeps some items as URL attributes:
// - `run.imageURL` for images
// - `run.textual.emojiURL` for custom emoji references emitted by pattern expansion
//
// This view loads those URLs asynchronously using the environment-provided attachment loaders,
// and derives its content in `body` by writing the attachments loaded so far back into the current
// attributed string as `Textual.Attachment` attributes. The rest of the rendering pipeline treats
// attachment runs like any other span.
//
// The text always comes from the current attributed string: an attachment only decorates a run
// whose URL, text, and color environment it was loaded for, so changing content never shows a
// previous string, and an attachment already loaded for earlier content appears immediately.
// Loads are requested from `body`, rather than from `task(id:)` or `onChange`, which a rapidly
// updating view can miss (SwiftUI runs those actions at most once per frame), and each attachment
// is loaded once rather than once per content change.

struct WithAttachments<Content: View>: View {
  @Environment(\.imageAttachmentLoader) private var imageAttachmentLoader
  @Environment(\.emojiAttachmentLoader) private var emojiAttachmentLoader
  @Environment(\.colorEnvironment) private var colorEnvironment

  @State private var model = Model()

  private let attributedString: AttributedString
  private let content: (AttributedString) -> Content

  init(
    _ attributedString: AttributedString,
    @ViewBuilder content: @escaping (AttributedString) -> Content
  ) {
    self.attributedString = attributedString
    self.content = content
  }

  var body: some View {
    let _ = model.requestAttachments(
      in: attributedString,
      imageAttachmentLoader: imageAttachmentLoader,
      emojiAttachmentLoader: emojiAttachmentLoader,
      environment: colorEnvironment
    )
    content(model.applyingLoadedAttachments(to: attributedString, environment: colorEnvironment))
  }
}

extension WithAttachments {
  @MainActor @Observable final class Model {
    struct Key: Hashable {
      enum Kind: Hashable {
        case image
        case emoji
      }

      let kind: Kind
      let url: URL
      let text: String
      let environment: ColorEnvironmentValues
    }

    private(set) var loaded: [Key: AnyAttachment] = [:]

    @ObservationIgnored private var requested: Set<Key> = []

    /// Starts loading the attachments `attributedString` refers to that haven't been requested
    /// yet. Cheap to call on every `body` evaluation.
    func requestAttachments(
      in attributedString: AttributedString,
      imageAttachmentLoader: any AttachmentLoader,
      emojiAttachmentLoader: any AttachmentLoader,
      environment: ColorEnvironmentValues
    ) {
      for run in attributedString.runs {
        guard
          let key = Self.key(for: run, in: attributedString, environment: environment),
          requested.insert(key).inserted
        else {
          continue
        }

        let loader =
          switch key.kind {
          case .image: imageAttachmentLoader
          case .emoji: emojiAttachmentLoader
          }

        Task {
          let attachment = try? await loader.attachment(
            for: key.url,
            text: key.text,
            environment: key.environment
          )
          if let attachment {
            loaded[key] = AnyAttachment(attachment)
          }
        }
      }
    }

    /// `attributedString` with every attachment loaded so far for its runs.
    func applyingLoadedAttachments(
      to attributedString: AttributedString,
      environment: ColorEnvironmentValues
    ) -> AttributedString {
      guard !loaded.isEmpty else {
        return attributedString
      }

      var output = attributedString

      for run in attributedString.runs {
        guard
          let key = Self.key(for: run, in: attributedString, environment: environment),
          let attachment = loaded[key]
        else {
          continue
        }
        output[run.range].textual.attachment = attachment
      }

      return output
    }

    private static func key(
      for run: AttributedString.Runs.Run,
      in attributedString: AttributedString,
      environment: ColorEnvironmentValues
    ) -> Key? {
      let text = { String(attributedString[run.range].characters[...]) }

      if let imageURL = run.imageURL {
        return Key(kind: .image, url: imageURL, text: text(), environment: environment)
      } else if let emojiURL = run.textual.emojiURL {
        return Key(kind: .emoji, url: emojiURL, text: text(), environment: environment)
      }
      return nil
    }
  }
}

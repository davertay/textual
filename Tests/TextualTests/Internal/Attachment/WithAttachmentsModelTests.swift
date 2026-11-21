import Foundation
import SwiftUI
import Synchronization
import Testing

@testable import Textual

@MainActor
struct WithAttachmentsModelTests {
  private typealias Model = WithAttachments<EmptyView>.Model

  private let light = ColorEnvironmentValues(colorScheme: .light, colorSchemeContrast: .standard)
  private let dark = ColorEnvironmentValues(colorScheme: .dark, colorSchemeContrast: .standard)

  @Test func leavesContentWithoutAttachmentURLsUnchanged() throws {
    let model = Model()
    let loader = RecordingLoader()
    let plain = try parse("Just **text**")

    request(plain, in: model, loader: loader, environment: light)

    #expect(loader.calls.isEmpty)
    #expect(model.applyingLoadedAttachments(to: plain, environment: light) == plain)
  }

  @Test func attachesTheLoadedAttachmentToItsRun() async throws {
    let model = Model()
    let loader = RecordingLoader()
    let content = try parse("Look ![a cat](https://example.com/cat.png)")

    request(content, in: model, loader: loader, environment: light)
    await waitForLoads(in: model, count: 1)

    let output = model.applyingLoadedAttachments(to: content, environment: light)
    #expect(output.attachments().count == 1)
    #expect(String(output.characters[...]) == String(content.characters[...]))
  }

  @Test func showsGrownContentWithTheLoadedAttachmentImmediately() async throws {
    let model = Model()
    let loader = RecordingLoader()
    request(try parse("Look ![a cat](https://example.com/cat.png)"), in: model, loader: loader, environment: light)
    await waitForLoads(in: model, count: 1)

    let grown = try parse("Look ![a cat](https://example.com/cat.png) and more")
    let output = model.applyingLoadedAttachments(to: grown, environment: light)

    #expect(output.attachments().count == 1)
    #expect(String(output.characters[...]) == String(grown.characters[...]))
  }

  @Test func showsNewContentWithoutAttachmentsRatherThanTheLastResolvedString() async throws {
    let model = Model()
    let loader = RecordingLoader()
    request(try parse("Look ![a cat](https://example.com/cat.png)"), in: model, loader: loader, environment: light)
    await waitForLoads(in: model, count: 1)

    let plain = try parse("Just text")
    #expect(model.applyingLoadedAttachments(to: plain, environment: light) == plain)
  }

  @Test func loadsEachAttachmentOnceAsContentChanges() async throws {
    let model = Model()
    let loader = RecordingLoader()

    for suffix in ["", " and", " and more"] {
      request(
        try parse("Look ![a cat](https://example.com/cat.png)\(suffix)"),
        in: model, loader: loader, environment: light
      )
    }
    await waitForLoads(in: model, count: 1)

    #expect(loader.calls == [URL(string: "https://example.com/cat.png")!])
  }

  @Test func loadsAgainForANewColorEnvironment() async throws {
    let model = Model()
    let loader = RecordingLoader()
    let content = try parse("Look ![a cat](https://example.com/cat.png)")

    request(content, in: model, loader: loader, environment: light)
    request(content, in: model, loader: loader, environment: dark)
    await waitForLoads(in: model, count: 2)

    #expect(loader.calls.count == 2)
    #expect(model.applyingLoadedAttachments(to: content, environment: dark).attachments().count == 1)
  }

  // MARK: - Helpers

  private func parse(_ markdown: String) throws -> AttributedString {
    try AttributedStringMarkdownParser(baseURL: nil).attributedString(for: markdown)
  }

  private func request(
    _ content: AttributedString,
    in model: Model,
    loader: RecordingLoader,
    environment: ColorEnvironmentValues
  ) {
    model.requestAttachments(
      in: content,
      imageAttachmentLoader: loader,
      emojiAttachmentLoader: loader,
      environment: environment
    )
  }

  private func waitForLoads(in model: Model, count: Int) async {
    for _ in 0..<400 where model.loaded.count < count {
      try? await Task.sleep(for: .milliseconds(5))
    }
  }
}

private struct StubAttachment: Textual.Attachment {
  let url: URL

  var description: String { url.absoluteString }

  var body: some View { Color.clear }

  func sizeThatFits(_: ProposedViewSize, in _: TextEnvironmentValues) -> CGSize {
    CGSize(width: 10, height: 10)
  }
}

private final class RecordingLoader: AttachmentLoader {
  private let log = Mutex<[URL]>([])

  var calls: [URL] { log.withLock { $0 } }

  func attachment(
    for url: URL,
    text _: String,
    environment _: ColorEnvironmentValues
  ) async throws -> StubAttachment {
    log.withLock { $0.append(url) }
    return StubAttachment(url: url)
  }
}

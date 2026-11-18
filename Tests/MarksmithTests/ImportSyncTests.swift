import XCTest
import AppKit
@testable import Marksmith

/// Regression coverage for "import a text file: the preview shows the new
/// content but the editor keeps the starter document".
///
/// Two defects combined to produce that split brain:
///  * `ContentView.initialise()` queued a deferred sync that captured the
///    *pre-import* text; it ran after the import and overwrote the editor.
///  * `EditorBridge.syncText()` dropped any text that arrived before
///    `makeNSView` had connected the real NSTextView.
@MainActor
final class ImportSyncTests: XCTestCase {

    private let starter = "# 欢迎使用 Marksmith\n\n旧内容"
    private let imported = "ok，好了。现在有些 iPhone，iPad 上的 app 已经下架。\n\n技术上做不到的部分"

    // MARK: - Bridge

    func testSyncBeforeConnectionIsReplayedOnAttach() throws {
        PendingImport.payload = nil
        let fixture = makeEditor(initial: starter)
        let bridge = EditorBridge()

        // A new window is still being built: nothing is connected yet.
        bridge.syncText(imported)
        XCTAssertNil(bridge.textView)
        XCTAssertEqual(fixture.textView.string, starter)

        bridge.attach(textView: fixture.textView, scrollView: fixture.scrollView,
                      findController: FindController())
        XCTAssertEqual(fixture.textView.string, imported)
        XCTAssertEqual(fixture.textView.layoutManager?
                        .glyphRange(for: fixture.container).length,
                       (imported as NSString).length)
    }

    func testDeferredFlushReplaysLatestValueNotStaleSnapshot() throws {
        PendingImport.payload = nil
        let fixture = makeEditor(initial: starter)
        let bridge = EditorBridge()
        bridge.textView = fixture.textView
        bridge.scrollView = fixture.scrollView

        bridge.syncText(starter)
        bridge.syncText(imported)

        // Simulate a stale deferred pass that wrote the starter text back.
        fixture.textView.applyProgrammaticText(starter)
        XCTAssertEqual(fixture.textView.string, starter)

        bridge.flush()   // no captured snapshot — repairs from latestText
        XCTAssertEqual(fixture.textView.string, imported)
    }

    // MARK: - Import hand-off

    func testPendingImportHandoffKeepsDocumentAndEditorAligned() async throws {
        PendingImport.payload = nil
        let fixture = makeEditor(initial: starter)
        let bridge = EditorBridge()
        bridge.textView = fixture.textView
        bridge.scrollView = fixture.scrollView
        let document = MarksmithDocument(text: starter)
        let createdAt = Date()

        let id = PendingImport.stage(imported)
        // A window that existed before the import must not steal the payload.
        XCTAssertNil(ImportService.consumePendingImport(
            into: document, bridge: bridge,
            viewCreatedAt: createdAt.addingTimeInterval(-10)))
        XCTAssertEqual(document.text, starter)
        XCTAssertEqual(fixture.textView.string, starter)

        let value = ImportService.consumePendingImport(
            into: document, bridge: bridge,
            viewCreatedAt: createdAt.addingTimeInterval(1))
        XCTAssertEqual(value, imported)
        XCTAssertEqual(document.text, imported)
        XCTAssertEqual(fixture.textView.string, imported)
        XCTAssertNil(PendingImport.payload)
        PendingImport.cancel(id)   // already consumed: harmless

        // The deferred repair pass from `ContentView.initialise()` must not
        // revert the editor to the starter text on the next run-loop turn.
        let editorBridge = bridge
        DispatchQueue.main.async { [weak editorBridge] in editorBridge?.flush() }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(fixture.textView.string, imported)
        XCTAssertEqual(document.text, imported)
    }

    func testReplaceImportWritesDocumentAndEditor() throws {
        PendingImport.payload = nil
        let fixture = makeEditor(initial: starter)
        let bridge = EditorBridge()
        bridge.textView = fixture.textView
        bridge.scrollView = fixture.scrollView
        let document = MarksmithDocument(text: starter)

        ImportService.writeImportedText(imported, to: document, bridge: bridge,
                                        target: .replace)
        XCTAssertEqual(document.text, imported)
        XCTAssertEqual(fixture.textView.string, imported)
        XCTAssertEqual(bridge.latestText, imported)
    }

    func testAppendImportKeepsEditorAndCaretAligned() throws {
        PendingImport.payload = nil
        let fixture = makeEditor(initial: starter)
        let bridge = EditorBridge()
        bridge.textView = fixture.textView
        bridge.scrollView = fixture.scrollView
        fixture.textView.setSelectedRange(
            NSRange(location: (starter as NSString).length, length: 0))
        let document = MarksmithDocument(text: starter)

        ImportService.writeImportedText("追加内容", to: document, bridge: bridge,
                                        target: .append)
        let expected = starter + "\n\n追加内容"
        XCTAssertEqual(document.text, expected)
        XCTAssertEqual(fixture.textView.string, expected)
        XCTAssertEqual(fixture.textView.selectedRange.location,
                       (expected as NSString).length)
    }

    func testStalePayloadCanOnlyBeCancelledById() throws {
        PendingImport.payload = nil
        let first = PendingImport.stage("第一次导入")
        let second = PendingImport.stage("第二次导入")
        PendingImport.cancel(first)
        XCTAssertEqual(PendingImport.payload?.markdown, "第二次导入")
        PendingImport.cancel(second)
        XCTAssertNil(PendingImport.payload)
    }

    // MARK: - Fixture

    private struct Fixture {
        let container: NSTextContainer
        let textView: MarkdownEditorTextView
        let scrollView: NSScrollView
    }

    private func makeEditor(initial: String) -> Fixture {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let storage = HighlightingTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let textView = MarkdownEditorTextView(frame: .zero, textContainer: container)
        textView.isRichText = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 500))
        scrollView.documentView = textView
        storage.setText(initial)
        textView.configure(font: AppSettings.shared.editorFont(), dark: true,
                           wordWrap: true, vimEnabled: false, force: true)
        scrollView.layoutSubtreeIfNeeded()
        return Fixture(container: container, textView: textView, scrollView: scrollView)
    }
}

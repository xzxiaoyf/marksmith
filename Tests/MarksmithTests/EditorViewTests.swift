import XCTest
import AppKit
import SwiftUI
@testable import Marksmith

/// Regression coverage for the "preview renders but the editor stays blank"
/// failure. The editor must end up with the document text, laid-out glyphs,
/// visible attributes and actually drawn pixels — not merely a matching
/// `String` in the model.
final class EditorViewTests: XCTestCase {

    private let documentPath = "/Volumes/machack2/download/swift_program/LANScanner/DESIGN.md"

    @MainActor
    func testBridgeSyncMakesEditorVisible() throws {
        let text = try String(contentsOfFile: documentPath, encoding: .utf8)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .darkAqua)

        let fixture = try makeEditor()
        let bridge = EditorBridge()
        bridge.textView = fixture.textView
        bridge.scrollView = fixture.scrollView

        // Simulates a file that finishes loading after the window appeared.
        // Before the fix, this path could leave the text view empty/unredrawn.
        bridge.syncText(text)

        XCTAssertEqual(fixture.textView.string, text)
        XCTAssertEqual(fixture.textView.string.count, text.count)
        let glyphs = fixture.layoutManager.glyphRange(for: fixture.container)
        XCTAssertEqual(glyphs.length, (text as NSString).length)
        XCTAssertGreaterThan(fixture.layoutManager.usedRect(for: fixture.container).height, 1000)

        let attrs = fixture.storage.attributes(at: 0, effectiveRange: nil)
        XCTAssertNotNil(attrs[.font], "editor text needs an explicit font")
        XCTAssertNotNil(attrs[.foregroundColor], "editor text needs an explicit colour")
        XCTAssertNotNil(fixture.textView.textColor)

        // The offscreen render must contain visible, non-background pixels.
        let lit = Self.litPixelCount(in: fixture.scrollView)
        XCTAssertGreaterThan(lit, 500, "editor rendered blank: no visible glyph pixels")

        // Idempotent: syncing the same text must not disturb the selection or
        // duplicate the content.
        bridge.syncText(text)
        XCTAssertEqual(fixture.textView.string, text)
    }

    @MainActor
    func testTextArrivingAfterViewCreation() throws {
        let text = try String(contentsOfFile: documentPath, encoding: .utf8)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .darkAqua)

        let model = EditorTextModel(text: "")
        let bridge = EditorBridge()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: EditorHost(model: model, bridge: bridge))
        hosting.frame = window.contentLayoutRect
        window.contentView = hosting
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        model.text = text
        bridge.syncText(text)
        hosting.layoutSubtreeIfNeeded()

        guard let tv = Self.firstTextView(in: hosting) as? MarkdownEditorTextView else {
            return XCTFail("editor text view not found")
        }
        XCTAssertEqual(tv.string, text)
        XCTAssertEqual(tv.layoutManager?.glyphRange(for: tv.textContainer!).length,
                       (text as NSString).length)
        let attrs = tv.textStorage?.attributes(at: 0, effectiveRange: nil) ?? [:]
        XCTAssertNotNil(attrs[.font])
        XCTAssertNotNil(attrs[.foregroundColor])
    }

    @MainActor
    func testStorageReplacementKeepsAttributesAndGlyphs() throws {
        let text = try String(contentsOfFile: documentPath, encoding: .utf8)
        let storage = HighlightingTextStorage()
        let lm = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude))
        lm.addTextContainer(container)
        storage.addLayoutManager(lm)

        storage.setText("# Title\n\nSome **bold** text")
        storage.setText(text)
        XCTAssertEqual(storage.string, text)
        XCTAssertEqual(lm.glyphRange(for: container).length, (text as NSString).length)
        let attrs = storage.attributes(at: 0, effectiveRange: nil)
        XCTAssertNotNil(attrs[.font])
        XCTAssertNotNil(attrs[.foregroundColor])
    }

    // MARK: - Fixtures

    private struct Fixture {
        let storage: HighlightingTextStorage
        let layoutManager: NSLayoutManager
        let container: NSTextContainer
        let textView: MarkdownEditorTextView
        let scrollView: NSScrollView
    }

    @MainActor
    private func makeEditor() throws -> Fixture {
        let storage = HighlightingTextStorage()
        let lm = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        lm.addTextContainer(container)
        storage.addLayoutManager(lm)
        let tv = MarkdownEditorTextView(frame: NSRect.zero, textContainer: container)
        tv.isRichText = true
        tv.textContainerInset = NSSize(width: 12, height: 14)
        tv.minSize = NSSize.zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 500))
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1)
        tv.configure(font: AppSettings.shared.editorFont(), dark: true,
                     wordWrap: true, vimEnabled: false, force: true)
        scroll.layoutSubtreeIfNeeded()
        return Fixture(storage: storage, layoutManager: lm, container: container,
                       textView: tv, scrollView: scroll)
    }

    /// Counts pixels noticeably brighter than the dark editor background in
    /// an offscreen PDF render — a proxy for "text is actually visible".
    private static func litPixelCount(in view: NSView) -> Int {
        let pdf = view.dataWithPDF(inside: view.bounds)
        guard let image = NSImage(data: pdf),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return 0 }
        var count = 0
        for y in stride(from: 5, to: min(rep.pixelsHigh - 5, 400), by: 2) {
            for x in stride(from: 5, to: min(rep.pixelsWide - 5, 500), by: 2) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let brightness = (c.redComponent + c.greenComponent + c.blueComponent) / 3
                if brightness > 0.35 { count += 1 }
            }
        }
        return count
    }

    private static func firstTextView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews { if let found = firstTextView(in: sub) { return found } }
        return nil
    }
}

private final class EditorTextModel: ObservableObject {
    @Published var text: String
    init(text: String) { self.text = text }
}

private struct EditorHost: View {
    @ObservedObject var model: EditorTextModel
    let bridge: EditorBridge
    private let settings = AppSettings.shared
    private let finder = FindController()

    var body: some View {
        MarkdownEditorView(
            text: $model.text,
            settings: settings,
            bridge: bridge,
            findController: finder,
            isDark: true,
            imageBaseURL: nil,
            onCursorChange: { _, _ in },
            onVimModeChange: { _ in }
        )
        .frame(width: 540, height: 500)
    }
}

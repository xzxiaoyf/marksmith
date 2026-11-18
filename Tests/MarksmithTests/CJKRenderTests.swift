import XCTest
import AppKit
import CoreText
@testable import Marksmith

/// Regression coverage for "the preview shows Chinese, the editor shows none".
/// A custom NSTextStorage that rewrites attributes during `processEditing` can
/// miss NSLayoutManager's CJK font substitution; the Chinese characters then
/// generate zero-width glyphs. These tests assert glyphs, advances and the
/// effective font — not just the string.
final class CJKRenderTests: XCTestCase {

    private let sample = "# LANScanner（macOS / Swift）设计文档\n| 项目 | 内容 |\n网段发现：枚举接口\n**粗体中文** 与 😀"

    private struct Stack {
        let storage: HighlightingTextStorage
        let layout: NSLayoutManager
        let container: NSTextContainer
        let textView: MarkdownEditorTextView
    }

    @MainActor
    private func makeStack(font: NSFont? = nil) -> Stack {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let storage = HighlightingTextStorage()
        storage.theme = .make(dark: true)
        if let font { storage.baseFont = font }
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 600, height: 1_000_000))
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let tv = MarkdownEditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 300),
                                        textContainer: container)
        tv.isRichText = true
        return Stack(storage: storage, layout: layout, container: container, textView: tv)
    }

    /// Asserts a character has a real, non-zero-width glyph drawn with a font
    /// that actually contains it.
    @MainActor
    private func assertVisible(_ stack: Stack, _ marker: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let ns = stack.storage.string as NSString
        let index = ns.range(of: marker).location
        guard index != NSNotFound else {
            return XCTFail("marker \(marker) missing", file: file, line: line)
        }
        _ = stack.layout.glyphRange(for: stack.container)
        let glyphIndex = stack.layout.glyphIndexForCharacter(at: index)
        let glyph = stack.layout.glyph(at: glyphIndex, isValidIndex: nil)
        XCTAssertNotEqual(glyph, NSGlyph(NSNullGlyph), "\(marker) produced a null glyph",
                          file: file, line: line)
        // boundingRect works even for the final glyph (where the next glyph's
        // location cannot be queried).
        let bounding = stack.layout.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1), in: stack.container)
        XCTAssertGreaterThan(bounding.width, 1,
                             "\(marker) has zero width — it would be invisible",
                             file: file, line: line)

        guard let font = stack.storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont else {
            return XCTFail("\(marker) has no font attribute", file: file, line: line)
        }
        // Pass the complete UTF-16 sequence of the first scalar: surrogate
        // pairs (emoji) need both units.
        let units = Array(marker.unicodeScalars.prefix(1)).flatMap { Array($0.utf16) }
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        XCTAssertTrue(CTFontGetGlyphsForCharacters(font as CTFont, units, &glyphs, units.count),
                      "\(font.fontName) cannot draw \(marker)", file: file, line: line)
    }

    @MainActor
    func testProgrammaticLoadRendersChinese() {
        let stack = makeStack()
        stack.storage.setText(sample)
        for marker in ["设", "项", "网", "（", "：", "粗"] {
            assertVisible(stack, marker)
        }
    }

    /// The path that used to fail: characters and attributes arrive via the
    /// storage primitives (typing / incremental document change) rather than
    /// through `setText`.
    @MainActor
    func testIncrementalEditRendersChinese() {
        let stack = makeStack()
        stack.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: sample)
        for marker in ["设", "项", "（"] { assertVisible(stack, marker) }

        let appended = "\n新增中文段落"
        stack.storage.replaceCharacters(in: NSRange(location: stack.storage.length, length: 0),
                                        with: appended)
        assertVisible(stack, "新")
    }

    @MainActor
    func testTypingChineseThroughTextViewRendersGlyphs() {
        let stack = makeStack()
        stack.storage.setText("")
        stack.textView.insertText("中文输入测试", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(stack.storage.string, "中文输入测试")
        assertVisible(stack, "中")
        assertVisible(stack, "试")
    }

    @MainActor
    func testBoldChineseInHeadingKeepsBoldCJKFont() {
        let stack = makeStack()
        stack.storage.setText("# 设计文档\n\n普通中文")
        guard let font = stack.storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont else {
            return XCTFail("missing font")
        }
        XCTAssertTrue(font.fontName.localizedCaseInsensitiveContains("PingFang") ||
                      font.fontName.localizedCaseInsensitiveContains("Hiragino") ||
                      font.fontName.localizedCaseInsensitiveContains("Heiti") ||
                      font.fontName.localizedCaseInsensitiveContains("PingFangUI"),
                      "expected a CJK font, got \(font.fontName)")
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask),
                      "bold heading should keep a bold CJK font, got \(font.fontName)")
        assertVisible(stack, "设")
    }

    @MainActor
    func testUserSelectedCJKFontIsPreserved() {
        guard let cjk = NSFont(name: "Hiragino Sans GB", size: 14) else {
            return XCTFail("Hiragino Sans GB unavailable")
        }
        let stack = makeStack(font: cjk)
        stack.storage.setText("# 设计文档")
        // A heading is bold, so the expected result is the user font's bold
        // variant — crucially still the user's own CJK family, not PingFang
        // forced on top of a different choice.
        let font = stack.storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font?.fontName.hasPrefix("HiraginoSansGB") ?? false,
                      "user-selected CJK family was overridden: \(font?.fontName ?? "nil")")
        assertVisible(stack, "设")
    }

    @MainActor
    func testFullWidthPunctuationAndEmojiAreVisible() {
        let stack = makeStack()
        stack.storage.setText("说明：中文（括号）与表情 😀 结束")
        assertVisible(stack, "：")
        assertVisible(stack, "（")
        assertVisible(stack, "😀")
    }

    /// The whole point: Chinese must produce visible ink in an offscreen
    /// render, not merely plausible-looking attributes.
    @MainActor
    func testChineseInkIsDrawn() {
        let stack = makeStack()
        stack.storage.setText("中文显示检查：局域网设备发现与诊断工具\n" +
                              String(repeating: "设计文档中文预览测试\n", count: 12))
        stack.textView.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1)
        let pdf = stack.textView.dataWithPDF(inside: stack.textView.bounds)
        guard let image = NSImage(data: pdf),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return XCTFail("offscreen render failed")
        }
        var lit = 0
        for y in stride(from: 5, to: min(rep.pixelsHigh - 5, 220), by: 2) {
            for x in stride(from: 5, to: min(rep.pixelsWide - 5, 560), by: 2) {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                if (colour.redComponent + colour.greenComponent + colour.blueComponent) / 3 > 0.35 {
                    lit += 1
                }
            }
        }
        XCTAssertGreaterThan(lit, 400, "Chinese text rendered blank")
    }
}

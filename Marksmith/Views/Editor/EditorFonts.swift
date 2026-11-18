import AppKit
import CoreText

/// Explicit font substitution for characters a monospaced Latin font cannot
/// draw.
///
/// `NSLayoutManager` normally falls back to a CJK font automatically. With a
/// custom `NSTextStorage` subclass that rewrites attributes during
/// `processEditing`, that substitution is not reliably applied: the CJK
/// characters then produce zero-width glyphs and vanish from the editor even
/// though the string itself is intact (the WebKit preview still shows them).
/// Assigning a font that actually contains the glyphs to those runs makes
/// rendering deterministic, independent of the text system's fallback.
///
/// This helper is deliberately isolated from the highlighter so a new script
/// (Cyrillic, Arabic, ...) only needs one more `Family` here.
enum EditorFonts {

    private struct Family {
        let regular: NSFont
        let bold: NSFont
        let matches: (UInt32) -> Bool
    }

    /// Applies fallback fonts to every run within `range` whose characters the
    /// base font cannot render. Colours and all other attributes are preserved.
    static func apply(to storage: NSMutableAttributedString,
                      range: NSRange,
                      baseFont: NSFont) {
        guard range.length > 0 else { return }
        let families = makeFamilies(size: baseFont.pointSize, baseFont: baseFont)
        guard !families.isEmpty else { return }

        let full = storage.string as NSString
        let end = min(NSMaxRange(range), full.length)
        guard end > range.location else { return }

        var active: Family?
        var runStart = 0

        func flush(upTo location: Int) {
            defer { active = nil }
            guard let family = active, location > runStart else { return }
            let run = NSRange(location: runStart, length: location - runStart)
            let current = storage.attribute(.font, at: runStart, effectiveRange: nil) as? NSFont
            let size = current?.pointSize ?? baseFont.pointSize
            let isBold = current.map {
                NSFontManager.shared.traits(of: $0).contains(.boldFontMask)
            } ?? false
            let chosen = isBold ? family.bold : family.regular
            let sized = NSFont(descriptor: chosen.fontDescriptor, size: size) ?? chosen
            storage.addAttribute(.font, value: sized, range: run)
        }

        // Walk UTF-16 units directly so ranges stay in NSString coordinates.
        // Surrogate pairs are combined into one scalar before matching.
        var location = range.location
        while location < end {
            let unit = full.character(at: location)
            var value = UInt32(unit)
            var width = 1
            if (0xD800...0xDBFF).contains(unit), location + 2 <= end {
                let low = full.character(at: location + 1)
                if (0xDC00...0xDFFF).contains(low) {
                    value = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                    width = 2
                }
            }
            let family = families.first { $0.matches(value) }
            // `nil == nil` keeps a Latin run inactive; the same family extends
            // the current run.
            if family?.regular.fontName == active?.regular.fontName {
                location += width
                continue
            }
            flush(upTo: location)
            active = family
            runStart = location
            location += width
        }
        flush(upTo: end)
    }

    // MARK: - Families

    private static func makeFamilies(size: CGFloat, baseFont: NSFont) -> [Family] {
        var families: [Family] = []

        if !covers(baseFont, scalar: 0x8BBE),           // 设
           let regular = firstAvailable(
            ["PingFang SC", "Hiragino Sans GB", "Heiti SC", "Arial Unicode MS"],
            size: size) {
            let bold = NSFontManager.shared.convert(regular, toHaveTrait: .boldFontMask)
            families.append(Family(regular: regular, bold: bold, matches: isCJK))
        }

        if !covers(baseFont, scalar: 0x1F600),          // 😀
           let emoji = NSFont(name: "Apple Color Emoji", size: size) {
            families.append(Family(regular: emoji, bold: emoji, matches: isEmoji))
        }

        return families
    }

    private static func firstAvailable(_ names: [String], size: CGFloat) -> NSFont? {
        for name in names {
            if let font = NSFont(name: name, size: size), covers(font, scalar: 0x8BBE) {
                return font
            }
        }
        // A system font always has CJK coverage on macOS.
        return NSFont.systemFont(ofSize: size)
    }

    private static func covers(_ font: NSFont, scalar: UInt32) -> Bool {
        var units: [UniChar] = []
        if scalar <= 0xFFFF {
            units = [UniChar(scalar)]
        } else {
            let value = scalar - 0x10000
            units = [UniChar(0xD800 + (value >> 10)), UniChar(0xDC00 + (value & 0x3FF))]
        }
        var glyphs = [CGGlyph](repeating: 0, count: 1)
        return CTFontGetGlyphsForCharacters(font as CTFont, units, &glyphs, 1)
    }

    /// CJK ideographs, kana, hangul, full-width forms and CJK punctuation
    /// （）、。：「」 etc. These are exactly the characters that disappeared
    /// when the monospaced font had no fallback.
    private static func isCJK(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x11FF, 0x2E80...0x2EFF, 0x2F00...0x2FDF,
             0x3000...0x303F, 0x3040...0x30FF, 0x3100...0x312F,
             0x3130...0x318F, 0x3190...0x319F, 0x31A0...0x31BF,
             0x31C0...0x31EF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA960...0xA97F, 0xAC00...0xD7AF, 0xF900...0xFAFF,
             0xFE10...0xFE1F, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    /// Supplementary-plane emoji. BMP dingbats are left alone so common
    /// Markdown symbols such as ✓ or ★ keep the monospace look.
    private static func isEmoji(_ value: UInt32) -> Bool {
        (0x1F000...0x1FAFF).contains(value)
    }
}

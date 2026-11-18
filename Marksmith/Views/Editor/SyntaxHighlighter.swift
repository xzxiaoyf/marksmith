import AppKit

struct HighlightTheme {
    let text: NSColor
    let heading: NSColor
    let marker: NSColor
    let quote: NSColor
    let code: NSColor
    let codeBackground: NSColor
    let link: NSColor
    let emphasis: NSColor
    let strike: NSColor
    let comment: NSColor

    static func make(dark: Bool) -> HighlightTheme {
        if dark {
            return HighlightTheme(
                text: NSColor(calibratedWhite: 0.86, alpha: 1),
                heading: NSColor(srgbRed: 0.47, green: 0.72, blue: 1.0, alpha: 1),
                marker: NSColor(srgbRed: 0.96, green: 0.70, blue: 0.42, alpha: 1),
                quote: NSColor(srgbRed: 0.56, green: 0.76, blue: 0.62, alpha: 1),
                code: NSColor(srgbRed: 0.77, green: 0.60, blue: 0.91, alpha: 1),
                codeBackground: NSColor(calibratedWhite: 0.16, alpha: 0.65),
                link: NSColor(srgbRed: 0.42, green: 0.81, blue: 0.94, alpha: 1),
                emphasis: NSColor(srgbRed: 0.94, green: 0.80, blue: 0.52, alpha: 1),
                strike: NSColor(calibratedWhite: 0.52, alpha: 1),
                comment: NSColor(calibratedWhite: 0.47, alpha: 1)
            )
        }
        return HighlightTheme(
            text: NSColor(calibratedWhite: 0.16, alpha: 1),
            heading: NSColor(srgbRed: 0.11, green: 0.35, blue: 0.78, alpha: 1),
            marker: NSColor(srgbRed: 0.72, green: 0.36, blue: 0.10, alpha: 1),
            quote: NSColor(srgbRed: 0.20, green: 0.48, blue: 0.28, alpha: 1),
            code: NSColor(srgbRed: 0.53, green: 0.20, blue: 0.63, alpha: 1),
            codeBackground: NSColor(calibratedWhite: 0.93, alpha: 0.9),
            link: NSColor(srgbRed: 0.05, green: 0.42, blue: 0.78, alpha: 1),
            emphasis: NSColor(srgbRed: 0.62, green: 0.38, blue: 0.05, alpha: 1),
            strike: NSColor(calibratedWhite: 0.55, alpha: 1),
            comment: NSColor(calibratedWhite: 0.52, alpha: 1)
        )
    }
}

/// Regex-based Markdown syntax highlighting applied to the edited paragraph
/// range. Priority order matters: front matter and fenced code are laid down
/// first so inline patterns do not override them.
enum SyntaxHighlighter {

    private struct Rule {
        let pattern: String
        let color: (HighlightTheme) -> NSColor
        let bold: Bool
        let options: NSRegularExpression.Options

        init(_ pattern: String,
             color: @escaping (HighlightTheme) -> NSColor,
             bold: Bool = false,
             options: NSRegularExpression.Options = [.anchorsMatchLines]) {
            self.pattern = pattern
            self.color = color
            self.bold = bold
            self.options = options
        }
    }

    private static let rules: [Rule] = [
        Rule("^---[\\s\\S]*?\\n---", color: { $0.comment }),
        Rule("^(#{1,6})\\s+.*$", color: { $0.heading }, bold: true),
        Rule("^\\s{0,3}>.*$", color: { $0.quote }),
        Rule("^\\s{0,3}(?:[-*+]|\\d+[.)])\\s", color: { $0.marker }, bold: true),
        Rule("^\\s{0,3}(?:[-*_] *)(?:[-*_] *){2,}$", color: { $0.comment }),
        Rule("`+[^`\\n]+`+", color: { $0.code }),
        Rule("\\*\\*[^*\\n]+\\*\\*|__[^_\\n]+__", color: { $0.emphasis }, bold: true),
        Rule("~~[^~\\n]+~~", color: { $0.strike }),
        Rule("!\\[[^\\]]*\\]\\([^)]*\\)|\\[[^\\]]+\\]\\([^)]*\\)", color: { $0.link }),
        Rule("https?://[^\\s)>]+", color: { $0.link }),
        Rule("</?[A-Za-z][^>]*>", color: { $0.comment }),
        Rule("(?<!\\*)\\*[^*\\n]+\\*(?!\\*)|(?<!_)_[^_\\n]+_(?!_)", color: { $0.emphasis })
    ]

    /// Resets base attributes in `range`, then applies all rules.
    static func apply(to storage: NSMutableAttributedString,
                      range: NSRange,
                      baseFont: NSFont,
                      theme: HighlightTheme) {
        let full = storage.string as NSString
        guard full.length > 0, range.location != NSNotFound,
              NSMaxRange(range) <= full.length else { return }

        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: theme.text,
            .paragraphStyle: NSParagraphStyle.default
        ], range: range)

        // Fenced code blocks: shade entire lines, including the fence markers.
        for lineRange in fencedCodeLineRanges(in: full, upTo: NSMaxRange(range)) {
            guard let intersection = lineRange.clampedIntersection(range) else { continue }
            storage.addAttribute(.backgroundColor, value: theme.codeBackground, range: intersection)
            storage.addAttribute(.foregroundColor, value: theme.code, range: intersection)
        }

        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else { continue }
            regex.enumerateMatches(in: full as String, options: [], range: range) { match, _, _ in
                guard let match else { return }
                storage.addAttribute(.foregroundColor, value: rule.color(theme), range: match.range)
                if rule.bold, let bold = baseFont.boldVariant {
                    storage.addAttribute(.font, value: bold, range: match.range)
                }
            }
        }

        // A monospaced Latin font has no CJK/emoji glyphs. Relying on
        // NSLayoutManager's automatic substitution is unsafe here because a
        // custom NSTextStorage subclass rewrites attributes during editing;
        // when substitution is missed those characters get zero-width glyphs
        // and disappear. Assign a font that really contains them instead.
        EditorFonts.apply(to: storage, range: range, baseFont: baseFont)
    }

    private static func fencedCodeLineRanges(in string: NSString, upTo limit: Int) -> [NSRange] {
        var ranges: [NSRange] = []
        var inside = false
        var location = 0
        while location < string.length, location < limit {
            let line = string.lineRange(for: NSRange(location: location, length: 0))
            let text = string.substring(with: line) as NSString
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let isFence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
            if isFence { inside.toggle() }
            if inside || isFence { ranges.append(line) }
            location = NSMaxRange(line)
        }
        return ranges
    }
}

private extension NSFont {
    var boldVariant: NSFont? {
        NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask)
    }
}

private extension NSRange {
    func clampedIntersection(_ other: NSRange) -> NSRange? {
        let lower = max(location, other.location)
        let upper = min(NSMaxRange(self), NSMaxRange(other))
        guard upper > lower else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }
}

import Foundation

/// Recursive-descent inline Markdown parser.
///
/// Supported: code spans, strong/emphasis, strikethrough, inline links and
/// images, autolinks, bare URLs, backslash escapes, hard/soft line breaks and
/// a safe subset of HTML entities. Raw HTML tags are preserved as *text* and
/// escaped by the renderer, which neutralises `<script>`/`<iframe>` payloads.
enum InlineParser {
    static func parse(_ text: String) -> [InlineNode] {
        InlineEngine(text).parse(until: nil)
    }
}

private final class InlineEngine {
    private let chars: [Character]
    private var i = 0

    init(_ text: String) { chars = Array(text) }

    private var isAtEnd: Bool { i >= chars.count }

    private func matches(_ token: String, at index: Int) -> Bool {
        let t = Array(token)
        guard index >= 0, index + t.count <= chars.count else { return false }
        for k in 0..<t.count where chars[index + k] != t[k] { return false }
        return true
    }

    private func slice(_ range: Range<Int>) -> String { String(chars[range]) }

    // MARK: - Main loop

    /// Parses until `stopToken` is reached at the current nesting level.
    /// The stop token is *not* consumed; the caller advances past it.
    func parse(until stopToken: String?) -> [InlineNode] {
        var nodes: [InlineNode] = []
        var buffer = ""

        func flush() {
            guard !buffer.isEmpty else { return }
            nodes.append(.text(EntityDecoder.decode(buffer)))
            buffer = ""
        }

        while !isAtEnd {
            if let stopToken, matches(stopToken, at: i) { break }
            let c = chars[i]

            switch c {
            case "\\":
                if i + 1 < chars.count, isEscapable(chars[i + 1]) {
                    buffer.append(chars[i + 1])
                    i += 2
                } else {
                    buffer.append(c)
                    i += 1
                }

            case "\n":
                if buffer.hasSuffix("  ") {
                    buffer.removeLast(2)
                    flush()
                    nodes.append(.hardBreak)
                } else if buffer.hasSuffix("\\") {
                    buffer.removeLast()
                    flush()
                    nodes.append(.hardBreak)
                } else {
                    flush()
                    nodes.append(.softBreak)
                }
                i += 1

            case "`":
                if let (node, next) = parseCodeSpan() {
                    flush()
                    nodes.append(node)
                    i = next
                } else {
                    buffer.append(c)
                    i += 1
                }

            case "!" where matches("![", at: i):
                if let (node, next) = parseImage() {
                    flush()
                    nodes.append(node)
                    i = next
                } else {
                    buffer.append(c)
                    i += 1
                }

            case "[":
                if let (node, next) = parseLink() {
                    flush()
                    nodes.append(node)
                    i = next
                } else {
                    buffer.append(c)
                    i += 1
                }

            case "<":
                if let (node, next) = parseAngle() {
                    flush()
                    nodes.append(node)
                    i = next
                } else {
                    buffer.append(c)
                    i += 1
                }

            case "~" where matches("~~", at: i):
                flush()
                if let (node, next) = parseDelimited("~~") {
                    nodes.append(node)
                    i = next
                } else {
                    buffer.append("~~")
                    i += 2
                }

            case "*", "_":
                let double = matches(String(repeating: c, count: 2), at: i)
                let delim = double ? String(repeating: c, count: 2) : String(c)
                if canOpen(delim, character: c), let (node, next) = parseDelimited(delim, double: double) {
                    flush()
                    nodes.append(node)
                    i = next
                } else {
                    buffer.append(c)
                    i += 1
                }

            case "$":
                // Keep `$…$` / `$$…$$` verbatim. LaTeX backslashes, braces and
                // `_`/`*` must NOT be re-read as Markdown escapes or emphasis;
                // KaTeX renders the untouched delimiters in the preview (and
                // in HTML/PDF exports).
                if let (raw, next) = mathSpan() {
                    buffer.append(raw)
                    i = next
                } else {
                    buffer.append(c)
                    i += 1
                }

            case "h" where (matches("http://", at: i) || matches("https://", at: i)):
                let prev: Character = i > 0 ? chars[i - 1] : " "
                if prev.isWhitespace || "([{<\"'".contains(prev) {
                    let start = i
                    i += 1
                    while !isAtEnd, !chars[i].isWhitespace, !"<>\"]".contains(chars[i]) { i += 1 }
                    var url = slice(start..<i)
                    while let last = url.last, ".,;:!?".contains(last) { url.removeLast() }
                    flush()
                    nodes.append(.link([.text(url)], destination: url, title: nil))
                } else {
                    buffer.append(c)
                    i += 1
                }

            default:
                buffer.append(c)
                i += 1
            }
        }

        flush()
        return nodes
    }

    private func isEscapable(_ c: Character) -> Bool {
        "\\`*_{}[]()#+-.!>~|/\"'$&<=".contains(c)
    }

    private func canOpen(_ delim: String, character: Character) -> Bool {
        let after = i + delim.count
        guard after < chars.count, !chars[after].isWhitespace else { return false }
        // Intraword underscores are not emphasis in GFM.
        if character == "_", i > 0 {
            let prev = chars[i - 1]
            if prev.isLetter || prev.isNumber { return false }
        }
        return true
    }

    // MARK: - Delimited spans

    private func parseDelimited(_ delim: String, double: Bool = true) -> (InlineNode, Int)? {
        guard let close = findClosing(delim, from: i + delim.count) else { return nil }
        let inner = slice((i + delim.count)..<close)
        let children = InlineEngine(inner).parse(until: nil)
        let node: InlineNode
        if delim == "~~" {
            node = .strikethrough(children)
        } else if double {
            node = .strong(children)
        } else {
            node = .emphasis(children)
        }
        return (node, close + delim.count)
    }

    private func findClosing(_ delim: String, from start: Int) -> Int? {
        let width = delim.count
        let marker = Array(delim)[0]
        var j = start
        while j + width <= chars.count {
            if matches(delim, at: j) {
                let prev: Character = j > 0 ? chars[j - 1] : " "
                if !prev.isWhitespace {
                    if width == 1, j + 1 < chars.count, chars[j + 1] == marker {
                        j += 1
                        continue
                    }
                    if width == 2, j + 2 < chars.count, chars[j + 2] == marker {
                        j += 1
                        continue
                    }
                    return j
                }
            }
            j += 1
        }
        return nil
    }

    // MARK: - Math spans (KaTeX)

    /// Mirrors the preview's guarded delimiters: display `$$…$$` may span
    /// lines, inline `$…$` may not, and neither may start with whitespace or
    /// (for inline) a digit — that is the `$5 / $10` price protection.
    private func mathSpan() -> (String, Int)? {
        let display = matches("$$", at: i)
        let delimiter = display ? "$$" : "$"
        let start = i + delimiter.count
        guard start < chars.count else { return nil }
        if !display {
            let first = chars[start]
            // A `$` followed by whitespace or a digit is currency, not math.
            guard !first.isWhitespace, !first.isNumber else { return nil }
        }

        var j = start
        while j + delimiter.count <= chars.count {
            if !display, chars[j] == "\n" { return nil }
            if matches(delimiter, at: j) {
                if display {
                    // `$$\n … \n$$` is the normal form, so leading/trailing
                    // newlines are allowed; only an empty body is rejected.
                    let inner = slice(start..<j)
                    guard !inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return nil
                    }
                } else {
                    guard j > start, !chars[j - 1].isWhitespace else { return nil }
                }
                let next = j + delimiter.count
                return (slice(i..<next), next)
            }
            j += 1
        }
        return nil
    }

    // MARK: - Code spans

    private func parseCodeSpan() -> (InlineNode, Int)? {
        var run = 0
        var j = i
        while j < chars.count, chars[j] == "`" { run += 1; j += 1 }
        guard run > 0 else { return nil }

        var k = j
        while k < chars.count {
            if chars[k] == "`" {
                var closeRun = 0
                while k + closeRun < chars.count, chars[k + closeRun] == "`" { closeRun += 1 }
                if closeRun == run {
                    var body = slice(j..<k)
                    body = body.replacingOccurrences(of: "\n", with: " ")
                    if body.hasPrefix(" "), body.hasSuffix(" "), body.trimmingCharacters(in: .whitespaces).count > 0 {
                        body = String(body.dropFirst().dropLast())
                    }
                    return (.code(body), k + closeRun)
                }
                k += closeRun
            } else {
                k += 1
            }
        }
        return nil
    }

    // MARK: - Links and images

    private func parseLink() -> (InlineNode, Int)? {
        guard matches("[", at: i) else { return nil }
        guard let labelEnd = findClosingBracket(from: i + 1) else { return nil }
        let label = slice((i + 1)..<labelEnd)
        let cursor = labelEnd + 1
        guard cursor < chars.count, chars[cursor] == "(" else { return nil }
        guard let (destination, title, after) = parseDestination(after: cursor + 1) else { return nil }
        let children = InlineEngine(label).parse(until: nil)
        return (.link(children, destination: destination, title: title), after)
    }

    private func parseImage() -> (InlineNode, Int)? {
        guard matches("![", at: i) else { return nil }
        guard let labelEnd = findClosingBracket(from: i + 2) else { return nil }
        let alt = EntityDecoder.decode(slice((i + 2)..<labelEnd))
        let cursor = labelEnd + 1
        guard cursor < chars.count, chars[cursor] == "(" else { return nil }
        guard let (destination, title, after) = parseDestination(after: cursor + 1) else { return nil }
        return (.image(alt: alt, destination: destination, title: title), after)
    }

    private func findClosingBracket(from start: Int) -> Int? {
        var depth = 1
        var j = start
        while j < chars.count {
            if chars[j] == "\\" { j += 2; continue }
            if chars[j] == "[" { depth += 1 }
            if chars[j] == "]" {
                depth -= 1
                if depth == 0 { return j }
            }
            j += 1
        }
        return nil
    }

    /// Parses `(destination "title")` starting just after the opening paren.
    private func parseDestination(after start: Int) -> (String, String?, Int)? {
        var j = start
        while j < chars.count, chars[j].isWhitespace { j += 1 }
        var destination = ""
        if j < chars.count, chars[j] == "<" {
            j += 1
            while j < chars.count, chars[j] != ">" { destination.append(chars[j]); j += 1 }
            guard j < chars.count, chars[j] == ">" else { return nil }
            j += 1
        } else {
            var depth = 0
            while j < chars.count {
                let c = chars[j]
                if c == "(" { depth += 1 }
                if c == ")" {
                    if depth == 0 { break }
                    depth -= 1
                }
                if c.isWhitespace { break }
                destination.append(c)
                j += 1
            }
        }

        while j < chars.count, chars[j].isWhitespace { j += 1 }
        var title: String?
        if j < chars.count, chars[j] == "\"" || chars[j] == "'" || chars[j] == "(" {
            let opener = chars[j]
            let closer: Character = opener == "(" ? ")" : opener
            j += 1
            var collected = ""
            while j < chars.count, chars[j] != closer {
                if chars[j] == "\\", j + 1 < chars.count { j += 1 }
                collected.append(chars[j]); j += 1
            }
            if j < chars.count, chars[j] == closer {
                title = EntityDecoder.decode(collected)
                j += 1
            } else {
                return nil
            }
            while j < chars.count, chars[j].isWhitespace { j += 1 }
        }
        guard j < chars.count, chars[j] == ")" else { return nil }
        return (destination, title, j + 1)
    }

    // MARK: - Autolinks / raw HTML

    private func parseAngle() -> (InlineNode, Int)? {
        guard matches("<", at: i) else { return nil }
        var j = i + 1
        while j < chars.count, chars[j] != ">", chars[j] != "\n" { j += 1 }
        guard j < chars.count, chars[j] == ">" else { return nil }
        let body = slice((i + 1)..<j)
        let lower = body.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") ||
           lower.hasPrefix("ftp://") || lower.hasPrefix("mailto:") {
            let text = body.hasPrefix("mailto:") ? String(body.dropFirst(7)) : body
            return (.link([.text(text)], destination: body, title: nil), j + 1)
        }
        if body.contains("@"), !body.contains(" "), lower.hasPrefix("mailto:") == false,
           body.first != "/", body.first != "!" {
            return (.link([.text(body)], destination: "mailto:" + body, title: nil), j + 1)
        }
        // Anything else is raw HTML: keep it as text so the renderer escapes it.
        return (.text("<" + body + ">"), j + 1)
    }
}

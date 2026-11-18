import Foundation

/// Block-level Markdown parser producing a renderer-agnostic AST.
///
/// GFM coverage: ATX/setext headings, fenced and indented code, blockquotes,
/// nested ordered/unordered lists, task lists, tables with column alignment,
/// thematic breaks, YAML front matter and raw-HTML neutralisation.
/// The parser has no AppKit/SwiftUI dependency and is fully unit-testable.
struct MarkdownParser {

    func parse(_ source: String) -> MarkdownModel {
        var text = source
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { expandLeadingTabs(String($0)) }

        var model = MarkdownModel()
        let frontMatter = stripFrontMatter(&lines)
        model.frontMatter = frontMatter
        model.blocks = parseBlocks(lines)
        return model
    }

    // MARK: - Normalisation

    private func expandLeadingTabs(_ line: String) -> String {
        var prefix = ""
        var column = 0
        var rest = line[...]
        while let first = rest.first, first == "\t" || first == " " {
            if first == "\t" {
                let spaces = 4 - (column % 4)
                prefix += String(repeating: " ", count: spaces)
                column += spaces
            } else {
                prefix.append(" ")
                column += 1
            }
            rest = rest.dropFirst()
        }
        return prefix + String(rest)
    }

    private func stripFrontMatter(_ lines: inout [String]) -> [String: String] {
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var end: Int?
        for idx in 1..<min(lines.count, 60) {
            let t = lines[idx].trimmingCharacters(in: .whitespaces)
            if t == "---" || t == "..." { end = idx; break }
        }
        guard let end else { return [:] }

        var result: [String: String] = [:]
        if end > 1 {
            for idx in 1..<end {
                let line = lines[idx]
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                                     (value.hasPrefix("'") && value.hasSuffix("'")) {
                    value = String(value.dropFirst().dropLast())
                }
                if !key.isEmpty { result[key] = value }
            }
        }
        lines = Array(lines[(end + 1)...])
        return result
    }

    // MARK: - Block loop

    private func parseBlocks(_ lines: [String]) -> [BlockNode] {
        var blocks: [BlockNode] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            if isBlank(line) { i += 1; continue }

            if let fence = fenceOpening(line) {
                var body: [String] = []
                i += 1
                while i < lines.count {
                    if isFenceClosing(lines[i], opening: fence) { i += 1; break }
                    body.append(lines[i])
                    i += 1
                }
                let info = fence.info.trimmingCharacters(in: .whitespaces)
                let language = info.split(separator: " ").first.map(String.init)
                blocks.append(.codeBlock(language: language, code: body.joined(separator: "\n")))
                continue
            }

            if indent(of: line) >= 4, !isBlank(line) {
                var body: [String] = []
                while i < lines.count, indent(of: lines[i]) >= 4 || isBlank(lines[i]) {
                    body.append(String(lines[i].dropFirst(min(4, lines[i].count))))
                    i += 1
                }
                while body.last == "" { body.removeLast() }
                blocks.append(.codeBlock(language: nil, code: body.joined(separator: "\n")))
                continue
            }

            if let heading = atxHeading(line) {
                var content = heading.text
                // Strip an optional closing hash sequence.
                let trimmed = content.trimmingCharacters(in: .whitespaces)
                if trimmed.hasSuffix("#") {
                    var stripped = trimmed
                    while stripped.hasSuffix("#") { stripped.removeLast() }
                    if stripped.trimmingCharacters(in: .whitespaces).isEmpty == false,
                       stripped.hasSuffix(" ") {
                        content = String(stripped.dropLast())
                    }
                }
                blocks.append(.heading(level: heading.level,
                                       inline: InlineParser.parse(content.trimmingCharacters(in: .whitespaces))))
                i += 1
                continue
            }

            if isThematicBreak(line) {
                blocks.append(.thematicBreak)
                i += 1
                continue
            }

            if isQuoteLine(line) {
                var quoted: [String] = []
                while i < lines.count {
                    let current = lines[i]
                    if isQuoteLine(current) {
                        var stripped = current.drop(while: { $0 == " " })
                        stripped = stripped.dropFirst() // '>'
                        if stripped.first == " " { stripped = stripped.dropFirst() }
                        quoted.append(String(stripped))
                        i += 1
                    } else if !isBlank(current), !isBlockStart(current) {
                        // Lazy continuation.
                        quoted.append(current)
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.blockquote(parseBlocks(quoted)))
                continue
            }

            if i + 1 < lines.count, let alignments = tableDelimiter(lines[i + 1]),
               line.contains("|") {
                let headers = splitTableRow(line, count: alignments.count).map { InlineParser.parse($0) }
                i += 2
                var rows: [[[InlineNode]]] = []
                while i < lines.count, !isBlank(lines[i]), lines[i].contains("|") {
                    rows.append(splitTableRow(lines[i], count: alignments.count).map { InlineParser.parse($0) })
                    i += 1
                }
                blocks.append(.table(headers: headers, rows: rows, alignments: alignments))
                continue
            }

            if listMarker(line) != nil {
                var cursor = i
                if let list = parseList(lines, &cursor) {
                    blocks.append(list)
                    i = cursor
                    continue
                }
            }

            if isHTMLBlockStart(line) {
                var body: [String] = []
                while i < lines.count, !isBlank(lines[i]) {
                    body.append(lines[i])
                    i += 1
                }
                blocks.append(.rawHTML(body.joined(separator: "\n")))
                continue
            }

            // Paragraph (with setext heading detection on the following line).
            var paragraph = [line]
            i += 1
            var detectedSetextLevel: Int?
            while i < lines.count, !isBlank(lines[i]) {
                if let level = setextLevel(of: lines[i]) {
                    detectedSetextLevel = level
                    i += 1
                    break
                }
                if isBlockStart(lines[i]) { break }
                paragraph.append(lines[i])
                i += 1
            }
            let inline = InlineParser.parse(paragraph.joined(separator: "\n"))
            if let detectedSetextLevel {
                blocks.append(.heading(level: detectedSetextLevel, inline: inline))
            } else {
                blocks.append(.paragraph(inline))
            }
        }

        return blocks
    }

    // MARK: - Block recognisers

    private func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func indent(of line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private func isBlockStart(_ line: String) -> Bool {
        if fenceOpening(line) != nil { return true }
        if atxHeading(line) != nil { return true }
        if isThematicBreak(line) { return true }
        if isQuoteLine(line) { return true }
        if listMarker(line) != nil { return true }
        if tableDelimiter(line) != nil { return true }
        return false
    }

    private func atxHeading(_ line: String) -> (level: Int, text: String)? {
        let trimmed = line.drop(while: { $0 == " " })
        guard trimmed.first == "#" else { return nil }
        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard level >= 1, level <= 6 else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        return (level, String(rest).trimmingCharacters(in: .whitespaces))
    }

    private func setextLevel(of line: String) -> Int? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t.allSatisfy({ $0 == "=" }) { return 1 }
        if t.allSatisfy({ $0 == "-" }), t.count >= 1 { return 2 }
        return nil
    }

    private func isThematicBreak(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.count >= 3 else { return false }
        let marker = t.first!
        guard marker == "-" || marker == "*" || marker == "_" else { return false }
        let significant = t.filter { $0 != " " && $0 != "\t" }
        return significant.count >= 3 && significant.allSatisfy { $0 == marker }
    }

    private func isQuoteLine(_ line: String) -> Bool {
        line.drop(while: { $0 == " " }).first == ">"
    }

    private struct Fence {
        let character: Character
        let count: Int
        let info: String
    }

    private func fenceOpening(_ line: String) -> Fence? {
        let t = line.drop(while: { $0 == " " })
        guard let first = t.first, first == "`" || first == "~" else { return nil }
        let count = t.prefix(while: { $0 == first }).count
        guard count >= 3 else { return nil }
        let info = String(t.dropFirst(count))
        if first == "`", info.contains("`") { return nil }
        return Fence(character: first, count: count, info: info)
    }

    private func isFenceClosing(_ line: String, opening: Fence) -> Bool {
        let t = line.drop(while: { $0 == " " })
        guard t.first == opening.character else { return false }
        let count = t.prefix(while: { $0 == opening.character }).count
        guard count >= opening.count else { return false }
        return t.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func tableDelimiter(_ line: String) -> [TableAlignment]? {
        guard line.contains("|") else { return nil }
        let cells = splitTableRow(line, count: Int.max)
        guard cells.count >= 1 else { return nil }
        var alignments: [TableAlignment] = []
        for raw in cells {
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard t.count >= 1 else { return nil }
            var core = t
            if core.hasPrefix(":") { core = String(core.dropFirst()) }
            if core.hasSuffix(":") { core = String(core.dropLast()) }
            guard core.count >= 1, core.allSatisfy({ $0 == "-" }) else { return nil }
            let left = t.hasPrefix(":")
            let right = t.hasSuffix(":")
            alignments.append(left && right ? .center : left ? .left : right ? .right : .none)
        }
        return alignments
    }

    /// Splits a table row on unescaped pipes, then pads/truncates to `count`.
    private func splitTableRow(_ line: String, count: Int) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t = String(t.dropFirst()) }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t = String(t.dropLast()) }

        var cells: [String] = []
        var current = ""
        var idx = t.startIndex
        while idx < t.endIndex {
            let ch = t[idx]
            if ch == "\\", t.index(after: idx) < t.endIndex, t[t.index(after: idx)] == "|" {
                current.append("\\|")
                idx = t.index(idx, offsetBy: 2, limitedBy: t.endIndex) ?? t.endIndex
                continue
            }
            if ch == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
            idx = t.index(after: idx)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        if count != Int.max {
            while cells.count < count { cells.append("") }
            if cells.count > count { cells = Array(cells.prefix(count)) }
        }
        return cells
    }

    private func isHTMLBlockStart(_ line: String) -> Bool {
        let t = line.drop(while: { $0 == " " })
        guard t.first == "<" else { return false }
        let lower = t.lowercased()
        let tags = ["<div", "<table", "<pre", "<script", "<style", "<iframe",
                    "<section", "<article", "<header", "<footer", "<nav", "<ul",
                    "<ol", "<h1", "<h2", "<h3", "<p ", "<p>", "<!--", "<details", "<figure"]
        return tags.contains { lower.hasPrefix($0) }
    }

    // MARK: - Lists

    private struct Marker {
        let indent: Int
        let ordered: Bool
        let number: Int
        let width: Int      // characters consumed by marker + separator
        var content: String
    }

    private func listMarker(_ line: String) -> Marker? {
        let leading = indent(of: line)
        guard leading <= 3 else { return nil }
        let t = String(line.dropFirst(leading))
        guard let first = t.first else { return nil }

        if first == "-" || first == "*" || first == "+" {
            guard t.count >= 2, t[t.index(after: t.startIndex)] == " " else { return nil }
            let content = String(t.dropFirst(2))
            return Marker(indent: leading, ordered: false, number: 1, width: 2, content: content)
        }
        if first.isNumber {
            var j = 0
            while j < t.count, t[t.index(t.startIndex, offsetBy: j)].isNumber { j += 1 }
            guard j > 0, j <= 9, j < t.count else { return nil }
            let punct = t[t.index(t.startIndex, offsetBy: j)]
            guard punct == "." || punct == ")" else { return nil }
            var k = j + 1
            var spaces = 0
            while k < t.count, t[t.index(t.startIndex, offsetBy: k)] == " " {
                spaces += 1; k += 1
            }
            guard spaces >= 1 else { return nil }
            let width = k
            let number = Int(t.prefix(j)) ?? 1
            let content = String(t.dropFirst(width))
            return Marker(indent: leading, ordered: true, number: number, width: width, content: content)
        }
        return nil
    }

    private func parseList(_ lines: [String], _ cursor: inout Int) -> BlockNode? {
        guard cursor < lines.count, let first = listMarker(lines[cursor]) else { return nil }
        let baseIndent = first.indent
        var contentIndent = baseIndent + first.width
        let ordered = first.ordered
        let start = first.number

        var items: [ListItem] = []
        var current: [String] = []
        var currentChecked: Bool?

        func commit() {
            while current.last == "" { current.removeLast() }
            guard !current.isEmpty else { return }
            let blocks = parseBlocks(current)
            items.append(ListItem(blocks: blocks, isChecked: currentChecked))
            current = []
            currentChecked = nil
        }

        var i = cursor
        while i < lines.count {
            let line = lines[i]

            if isBlank(line) {
                // Keep the blank only when the list clearly continues afterwards.
                if i + 1 < lines.count {
                    let next = lines[i + 1]
                    let nextMarker = listMarker(next)
                    if indent(of: next) > baseIndent ||
                       (nextMarker?.indent ?? Int.max) <= baseIndent + 3 {
                        current.append("")
                        i += 1
                        continue
                    }
                }
                i += 1
                break
            }

            // A marker indented at least as far as the current item's content
            // column belongs to a *nested* list, not to this list's siblings.
            if let marker = listMarker(line), marker.indent < contentIndent,
               marker.indent <= baseIndent + 3, marker.ordered == ordered {
                commit()
                contentIndent = marker.indent + marker.width
                var content = marker.content
                if content.hasPrefix("[ ] ") || content.hasPrefix("[  ] ") {
                    currentChecked = false
                    content = String(content.dropFirst(4))
                } else if content.hasPrefix("[x] ") || content.hasPrefix("[X] ") {
                    currentChecked = true
                    content = String(content.dropFirst(4))
                }
                current = [content]
                i += 1
                continue
            }

            let lineIndent = indent(of: line)
            if lineIndent >= contentIndent {
                current.append(String(line.dropFirst(min(contentIndent, line.count))))
                i += 1
                continue
            }
            if lineIndent > baseIndent {
                current.append(String(line.dropFirst(min(lineIndent, line.count))))
                i += 1
                continue
            }
            if !current.isEmpty, !isBlockStart(line) {
                // Lazy continuation of the current item's paragraph.
                current.append(line)
                i += 1
                continue
            }
            break
        }
        commit()
        guard !items.isEmpty else { return nil }
        cursor = i
        return .list(ordered: ordered, start: start, items: items)
    }
}

import Foundation

// MARK: - AST → Markdown
//
// Importers never assemble Markdown strings by hand. They build a
// `MarkdownModel` (the very same AST produced by `MarkdownParser`) and this
// serializer turns it into text. That keeps escaping rules, table syntax and
// fenced-code rules in one place, and guarantees that imported documents
// behave exactly like hand-written Markdown in the preview, PDF and DOCX
// pipelines.

enum MarkdownSerializer {

    static func serialize(_ model: MarkdownModel) -> String {
        var parts: [String] = []

        if !model.frontMatter.isEmpty {
            var yaml = "---\n"
            for key in model.frontMatter.keys.sorted() {
                yaml += "\(key): \(escapeYAML(model.frontMatter[key] ?? ""))\n"
            }
            yaml += "---"
            parts.append(yaml)
        }

        for block in model.blocks {
            let rendered = serialize(block)
            if !rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(rendered)
            }
        }
        return parts.joined(separator: "\n\n") + (parts.isEmpty ? "" : "\n")
    }

    // MARK: Blocks

    static func serialize(_ block: BlockNode) -> String {
        switch block {
        case .heading(let level, let inline):
            let hashes = String(repeating: "#", count: max(1, min(level, 6)))
            return hashes + " " + inlineText(inline, inTable: false).replacingOccurrences(of: "\n", with: " ")

        case .paragraph(let inline):
            return protectLineStarts(inlineText(inline, inTable: false))

        case .thematicBreak:
            return "---"

        case .rawHTML(let raw):
            // Raw HTML is deliberately neutralised by the renderer; emit it as
            // escaped plain text so an import can never inject markup.
            return protectLineStarts(escapeText(raw, inTable: false))

        case .codeBlock(let language, let code):
            let body = code.replacingOccurrences(of: "\r\n", with: "\n")
            let fenceLength = max(3, longestBacktickRun(in: body) + 1)
            let fence = String(repeating: "`", count: fenceLength)
            let lang = (language ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespaces)[0]
            let safeLang = lang.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "+" }
                ? lang : ""
            return fence + safeLang + "\n" + body + (body.hasSuffix("\n") ? "" : "\n") + fence

        case .blockquote(let children):
            let inner = children.map { serialize($0) }.joined(separator: "\n\n")
            return inner.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in line.isEmpty ? ">" : "> " + line }
                .joined(separator: "\n")

        case .list(let ordered, let start, let items):
            return serializeList(ordered: ordered, start: start, items: items)

        case .table(let headers, let rows, let alignments):
            return serializeTable(headers: headers, rows: rows, alignments: alignments)
        }
    }

    private static func serializeList(ordered: Bool, start: Int, items: [ListItem]) -> String {
        var lines: [String] = []
        for (index, item) in items.enumerated() {
            let marker = ordered ? "\(start + index). " : "- "
            let task = item.isChecked.map { $0 ? "[x] " : "[ ] " } ?? ""
            let indent = String(repeating: " ", count: (marker + task).count)
            let body = item.blocks.map { serialize($0) }.joined(separator: "\n\n")
            let bodyLines = body.split(separator: "\n", omittingEmptySubsequences: false)
            for (lineIndex, rawLine) in bodyLines.enumerated() {
                let line = String(rawLine)
                if lineIndex == 0 {
                    lines.append(marker + task + line)
                } else if line.isEmpty {
                    lines.append("")
                } else {
                    lines.append(indent + line)
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func serializeTable(headers: [[InlineNode]], rows: [[[InlineNode]]],
                                       alignments: [TableAlignment]) -> String {
        guard !headers.isEmpty else { return "" }
        let columns = headers.count

        func cells(_ row: [[InlineNode]]) -> [String] {
            var values = row.map { inlineText($0, inTable: true) }
            while values.count < columns { values.append("") }
            if values.count > columns { values = Array(values.prefix(columns)) }
            return values
        }

        let head = cells(headers)
        let separators: [String] = (0..<columns).map { index in
            let alignment: TableAlignment = index < alignments.count ? alignments[index] : .none
            switch alignment {
            case .none: return "---"
            case .left: return ":---"
            case .center: return ":---:"
            case .right: return "---:"
            }
        }

        var lines = ["| " + head.joined(separator: " | ") + " |",
                     "| " + separators.joined(separator: " | ") + " |"]
        for row in rows {
            lines.append("| " + cells(row).joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Inline

    static func inlineText(_ nodes: [InlineNode], inTable: Bool) -> String {
        nodes.map { inlineText($0, inTable: inTable) }.joined()
    }

    static func inlineText(_ node: InlineNode, inTable: Bool) -> String {
        switch node {
        case .text(let value):
            return escapeText(value, inTable: inTable)

        case .strong(let children):
            let inner = inlineText(children, inTable: inTable)
            return inner.isEmpty ? "" : "**" + inner + "**"

        case .emphasis(let children):
            let inner = inlineText(children, inTable: inTable)
            return inner.isEmpty ? "" : "*" + inner + "*"

        case .strikethrough(let children):
            let inner = inlineText(children, inTable: inTable)
            return inner.isEmpty ? "" : "~~" + inner + "~~"

        case .code(let value):
            return codeSpan(value)

        case .link(let children, let destination, let title):
            let inner = inlineText(children, inTable: inTable)
            guard let safe = URLPolicy.linkDestination(destination) else { return inner }
            var body = "[" + inner + "](" + escapeDestination(safe)
            if let title, !title.isEmpty {
                body += " \"" + title.replacingOccurrences(of: "\"", with: "&quot;") + "\""
            }
            return body + ")"

        case .image(let alt, let destination, let title):
            guard let safe = URLPolicy.imageDestination(destination) else { return "" }
            var body = "![" + escapeText(alt, inTable: inTable) + "](" + escapeDestination(safe)
            if let title, !title.isEmpty {
                body += " \"" + title.replacingOccurrences(of: "\"", with: "&quot;") + "\""
            }
            return body + ")"

        case .hardBreak:
            return inTable ? " " : "  \n"

        case .softBreak:
            return inTable ? " " : "\n"
        }
    }

    // MARK: Escaping helpers

    /// Escapes characters that would otherwise be re-parsed as Markdown
    /// syntax. Deliberately conservative: the output must round-trip through
    /// `MarkdownParser` as plain text, not as new markup.
    static func escapeText(_ value: String, inTable: Bool) -> String {
        let decoded = EntityDecoder.decode(value)
        var out = ""
        out.reserveCapacity(decoded.count + 8)
        for ch in decoded {
            switch ch {
            case "\\", "`", "*", "_", "[", "]", "~", "<", ">":
                out.append("\\")
                out.append(ch)
            case "|" where inTable:
                out.append("\\")
                out.append(ch)
            case "\r":
                break
            case "\n":
                out.append(inTable ? " " : "\n")
            default:
                out.append(ch)
            }
        }
        return out
    }

    /// A paragraph whose first line begins with a block marker would be parsed
    /// as a heading/quote/list. Escape only that first character.
    private static func protectLineStarts(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return lines.map { line -> String in
            guard let first = line.first else { return line }
            let ns = line as NSString
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let looksLikeBlock = first == "#" || first == ">" || first == "-" ||
                first == "+" || first == "*" || trimmed == "---" || trimmed == "***" ||
                isOrderedListStart(line)
            guard looksLikeBlock else { return line }
            // The character may already be escaped by `escapeText`.
            if ns.length >= 2, ns.substring(to: 2) == "\\" + String(first) { return line }
            return "\\" + line
        }.joined(separator: "\n")
    }

    private static func isOrderedListStart(_ line: String) -> Bool {
        var digits = 0
        for ch in line {
            if ch.isNumber { digits += 1 } else { break }
        }
        guard digits > 0, line.count > digits + 1 else { return false }
        let rest = line.dropFirst(digits)
        return (rest.first == "." || rest.first == ")") && rest.dropFirst().first == " "
    }

    private static func codeSpan(_ value: String) -> String {
        let flattened = value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
        let fence = String(repeating: "`", count: max(1, longestBacktickRun(in: flattened) + 1))
        let pad = flattened.first == "`" || flattened.last == "`" ||
            flattened.first == " " || flattened.last == " " ? " " : ""
        return fence + pad + flattened + pad + fence
    }

    private static func longestBacktickRun(in string: String) -> Int {
        var best = 0, current = 0
        for ch in string {
            if ch == "`" { current += 1; best = max(best, current) } else { current = 0 }
        }
        return best
    }

    private static func escapeDestination(_ value: String) -> String {
        value.replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: "<", with: "%3C")
            .replacingOccurrences(of: ">", with: "%3E")
    }

    private static func escapeYAML(_ value: String) -> String {
        let needsQuotes = value.contains(":") || value.contains("#") ||
            value.contains("\n") || value.hasPrefix(" ") || value.hasSuffix(" ")
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}

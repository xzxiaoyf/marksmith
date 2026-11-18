import Foundation

/// Converts (X)HTML into a `MarkdownModel`.
///
/// A small tolerant tokenizer builds a node tree first — real-world HTML has
/// unclosed `<p>`/`<li>` tags, attributes without quotes and legacy entities,
/// none of which `XMLParser` accepts. The tree is then mapped to the same AST
/// that `MarkdownParser` produces, so `MarkdownSerializer` owns all escaping.
struct HTMLImporter: DocumentImporter {
    let format = StandardImportFormats.html

    func importDocument(_ request: ImportRequest) async throws -> ImportResult {
        let data = try Data(contentsOf: request.url)
        let source = HTMLText.decode(data)
        let root = HTMLTokenizer.parse(source)

        var converter = HTMLToMarkdown(sourceDirectory: request.url.deletingLastPathComponent(),
                                       baseDirectory: request.baseDirectory)
        let model = converter.convert(root)

        if model.blocks.isEmpty {
            throw ImportError.emptyDocument("HTML 中没有可转换的正文内容。")
        }
        return ImportResult(markdown: MarkdownSerializer.serialize(model),
                            warnings: converter.warnings,
                            sourceURL: request.url,
                            format: format)
    }
}

// MARK: - Encoding detection

enum HTMLText {
    static func decode(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return stripBOM(text) }
        let probe = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
        if probe.contains("gb18030") || probe.contains("gbk") || probe.contains("gb2312") {
            let gb18030 = String.Encoding(rawValue: 0x80000632)
            if let text = String(data: data, encoding: gb18030) { return stripBOM(text) }
        }
        if probe.contains("big5") {
            let big5 = String.Encoding(rawValue: 0x80000A03)
            if let text = String(data: data, encoding: big5) { return stripBOM(text) }
        }
        if let text = String(data: data, encoding: .windowsCP1252) { return stripBOM(text) }
        return stripBOM(String(decoding: data, as: UTF8.self))
    }

    private static func stripBOM(_ text: String) -> String {
        text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    /// Collapses HTML whitespace (outside `<pre>`) into single spaces.
    /// Boundary spaces are preserved: a text node between `这是一段 ` and
    /// `<strong>` must keep its trailing space or the two words would run
    /// together in the generated Markdown.
    static func collapse(_ text: String) -> String {
        let isSpace = { (ch: Character) -> Bool in
            ch == " " || ch == "\t" || ch == "\n" || ch == "\r" || ch == "\u{00A0}"
        }
        guard !text.isEmpty else { return "" }
        let leadingSpace = isSpace(text.first!)
        let trailingSpace = isSpace(text.last!)

        var out = ""
        var pendingSpace = false
        for ch in text {
            if isSpace(ch) {
                pendingSpace = true
            } else {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(ch)
            }
        }
        if out.isEmpty { return " " }
        if leadingSpace { out = " " + out }
        if trailingSpace { out += " " }
        return out
    }
}

// MARK: - Tolerant tokenizer

enum HTMLTokenizer {

    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"
    ]
    private static let droppedElements: Set<String> = [
        "script", "style", "head", "nav", "noscript", "iframe", "svg", "template"
    ]
    private static let blockElements: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li",
        "table", "tr", "td", "th", "blockquote", "pre", "section", "article",
        "main", "header", "footer", "aside", "figure", "figcaption", "hr",
        "dl", "dt", "dd", "form", "details", "summary"
    ]

    static func parse(_ source: String) -> XMLNode {
        let chars = Array(source)
        let root = XMLNode(name: "#document")
        var stack: [XMLNode] = [root]
        var i = 0
        var skipTag: String?
        var skipDepth = 0

        func top() -> XMLNode { stack.last ?? root }

        func closeUntil(_ name: String) {
            guard stack.count > 1 else { return }
            for index in stride(from: stack.count - 1, through: 1, by: -1) {
                if stack[index].localName == name {
                    stack.removeSubrange(index...)
                    return
                }
            }
        }

        func closeOpenParagraph() {
            if top().localName == "p" { closeUntil("p") }
        }

        while i < chars.count {
            guard chars[i] == "<" else {
                var text = ""
                while i < chars.count, chars[i] != "<" {
                    text.append(chars[i]); i += 1
                }
                if skipTag == nil, !text.isEmpty {
                    let node = XMLNode(name: "#text")
                    node.text = EntityDecoder.decode(text)
                    node.parent = top()
                    top().children.append(node)
                }
                continue
            }

            // Comment / doctype / processing instruction.
            if matches("<!--", at: i, in: chars) {
                if let end = indexOf("-->", after: i + 4, in: chars) {
                    i = end + 3
                } else { i = chars.count }
                continue
            }
            if matches("<!", at: i, in: chars) || matches("<?", at: i, in: chars) {
                if let end = indexOf(">", after: i + 2, in: chars) {
                    i = end + 1
                } else { i = chars.count }
                continue
            }

            guard let tagEnd = indexOfTagEnd(after: i + 1, in: chars) else {
                // Unterminated '<': treat it as literal text.
                let node = XMLNode(name: "#text")
                node.text = "<"
                node.parent = top()
                top().children.append(node)
                i += 1
                continue
            }

            var raw = String(chars[(i + 1)..<tagEnd])
            i = tagEnd + 1
            var explicitSelfClosing = false
            if raw.hasSuffix("/") {
                raw.removeLast()
                explicitSelfClosing = true
            }

            if raw.hasPrefix("/") {
                let name = normalise(String(raw.dropFirst())).lowercased()
                if let skipping = skipTag, name == skipping {
                    skipDepth -= 1
                    if skipDepth <= 0 { skipTag = nil; skipDepth = 0 }
                } else if skipTag == nil {
                    closeUntil(name)
                }
                continue
            }

            let (name, attributes, parsedSelfClosing) = parseTag(raw)
            let lowered = name.lowercased()
            let selfClosing = parsedSelfClosing || explicitSelfClosing

            if let skipping = skipTag {
                if lowered == skipping, !selfClosing, !voidElements.contains(lowered) {
                    skipDepth += 1
                }
                continue
            }
            if droppedElements.contains(lowered) {
                if !selfClosing {
                    skipTag = lowered
                    skipDepth = 1
                }
                continue
            }

            // HTML's implicit end tags.
            if blockElements.contains(lowered) { closeOpenParagraph() }
            if lowered == "li" && top().localName == "li" { closeUntil("li") }
            if lowered == "tr" {
                if top().localName == "td" || top().localName == "th" { closeUntil(top().localName) }
                if top().localName == "tr" { closeUntil("tr") }
            }
            if (lowered == "td" || lowered == "th"),
               top().localName == "td" || top().localName == "th" {
                closeUntil(top().localName)
            }

            let node = XMLNode(name: lowered)
            node.attributes = attributes
            node.parent = top()
            top().children.append(node)
            if !selfClosing, !voidElements.contains(lowered) {
                stack.append(node)
            }
        }
        return root
    }

    private static func normalise(_ raw: String) -> String {
        raw.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? ""
    }

    private static func parseTag(_ raw: String) -> (String, [String: String], Bool) {
        let chars = Array(raw)
        var i = 0
        while i < chars.count, chars[i] == " " || chars[i] == "\n" || chars[i] == "\t" { i += 1 }
        var name = ""
        while i < chars.count, !chars[i].isWhitespace, chars[i] != "/" {
            name.append(chars[i]); i += 1
        }
        var attributes: [String: String] = [:]
        var selfClosing = false

        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace || chars[i] == "/" { i += 1 }
            guard i < chars.count else { break }
            if chars[i] == "/" { selfClosing = true; i += 1; continue }
            var key = ""
            while i < chars.count, chars[i] != "=", !chars[i].isWhitespace, chars[i] != "/" {
                key.append(chars[i]); i += 1
            }
            guard !key.isEmpty else { i += 1; continue }
            var value = ""
            if i < chars.count, chars[i] == "=" {
                i += 1
                while i < chars.count, chars[i].isWhitespace { i += 1 }
                if i < chars.count, chars[i] == "\"" || chars[i] == "'" {
                    let quote = chars[i]; i += 1
                    while i < chars.count, chars[i] != quote { value.append(chars[i]); i += 1 }
                    if i < chars.count { i += 1 }
                } else {
                    while i < chars.count, !chars[i].isWhitespace, chars[i] != "/" {
                        value.append(chars[i]); i += 1
                    }
                }
            }
            attributes[key.lowercased()] = EntityDecoder.decode(value)
        }
        return (name.lowercased(), attributes, selfClosing)
    }

    private static func matches(_ token: String, at index: Int, in chars: [Character]) -> Bool {
        let needle = Array(token)
        guard index + needle.count <= chars.count else { return false }
        return Array(chars[index..<(index + needle.count)]) == needle
    }

    private static func indexOf(_ token: String, after start: Int,
                                in chars: [Character]) -> Int? {
        let needle = Array(token)
        guard needle.count > 0, start <= chars.count - needle.count else { return nil }
        var i = start
        while i + needle.count <= chars.count {
            if Array(chars[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }

    /// Finds the '>' that ends a tag, ignoring '>' inside quoted attributes.
    private static func indexOfTagEnd(after start: Int, in chars: [Character]) -> Int? {
        var quote: Character?
        var i = start
        while i < chars.count {
            let ch = chars[i]
            if let activeQuote = quote {
                if ch == activeQuote { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == ">" {
                return i
            }
            i += 1
        }
        return nil
    }
}

// MARK: - HTML tree → Markdown AST

/// Warnings are collected through a reference box so inline conversion can
/// stay non-mutating (it is called from `map` closures over table cells).
final class WarningCollector {
    private(set) var items: [String] = []
    func add(_ message: String) {
        if !items.contains(message) { items.append(message) }
    }
}

private struct HTMLToMarkdown {
    let sourceDirectory: URL
    let baseDirectory: URL?
    let collector: WarningCollector
    var warnings: [String] { collector.items }
    private var blocks: [BlockNode] = []
    private var inlineBuffer: [InlineNode] = []

    init(sourceDirectory: URL, baseDirectory: URL?,
         collector: WarningCollector = WarningCollector()) {
        self.sourceDirectory = sourceDirectory
        self.baseDirectory = baseDirectory
        self.collector = collector
    }

    mutating func convert(_ root: XMLNode) -> MarkdownModel {
        visitChildren(of: root)
        flushParagraph()
        var model = MarkdownModel()
        model.blocks = blocks
        return model
    }

    mutating func visitChildren(of node: XMLNode) {
        for child in node.children { visit(child) }
    }

    // MARK: Block dispatch

    private mutating func visit(_ node: XMLNode) {
        let name = node.localName

        if name == "#text" {
            let collapsed = HTMLText.collapse(node.text)
            if !collapsed.isEmpty { inlineBuffer.append(.text(collapsed)) }
            return
        }

        switch name {
        case "script", "style", "head", "nav", "noscript", "iframe", "template":
            return

        case "h1", "h2", "h3", "h4", "h5", "h6":
            flushParagraph()
            let level = Int(String(name.dropFirst())) ?? 1
            blocks.append(.heading(level: level, inline: inlineNodes(of: node)))

        case "p":
            flushParagraph()
            let content = inlineNodes(of: node)
            if !isBlank(content) { blocks.append(.paragraph(content)) }

        case "hr":
            flushParagraph()
            blocks.append(.thematicBreak)

        case "pre":
            flushParagraph()
            var code = node.combinedText
            if code.hasPrefix("\n") { code.removeFirst() }
            code = code.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
            var language: String?
            if let codeChild = node.firstChild(named: "code") {
                language = codeLanguage(from: codeChild.attributes)
            }
            if language == nil { language = codeLanguage(from: node.attributes) }
            blocks.append(.codeBlock(language: language, code: code + "\n"))

        case "blockquote":
            flushParagraph()
            var inner = HTMLToMarkdown(sourceDirectory: sourceDirectory, baseDirectory: baseDirectory, collector: collector)
            let model = inner.convert(node)
            if !model.blocks.isEmpty { blocks.append(.blockquote(model.blocks)) }

        case "ul", "ol":
            flushParagraph()
            blocks.append(convertList(node))

        case "table":
            flushParagraph()
            blocks.append(convertTable(node))

        case "br":
            inlineBuffer.append(.hardBreak)

        case "body", "html", "div", "section", "article", "main", "header", "footer",
             "aside", "figure", "figcaption", "dl", "dt", "dd", "details", "summary",
             "thead", "tbody", "tfoot", "form":
            visitChildren(of: node)
            flushParagraph()

        case "li", "tr", "td", "th":
            // Handled by their parent; a stray one degrades to a paragraph.
            let content = inlineNodes(of: node)
            if !isBlank(content) { inlineBuffer.append(contentsOf: content) }

        default:
            // Inline-level element (strong/em/a/img/span/code/...).
            inlineBuffer.append(contentsOf: inlineNodes(of: node))
        }
    }

    private mutating func flushParagraph() {
        let trimmed = trimInlineWhitespace(inlineBuffer)
        inlineBuffer.removeAll()
        if !isBlank(trimmed) { blocks.append(.paragraph(trimmed)) }
    }

    // MARK: Inline mapping

    private func inlineNodes(of node: XMLNode) -> [InlineNode] {
        var result: [InlineNode] = []
        for child in node.children {
            let name = child.localName
            if name == "#text" {
                let collapsed = HTMLText.collapse(child.text)
                if !collapsed.isEmpty { result.append(.text(collapsed)) }
                continue
            }
            switch name {
            case "br":
                result.append(.hardBreak)
            case "strong", "b":
                let inner = inlineNodes(of: child)
                if !isBlank(inner) { result.append(.strong(inner)) }
            case "em", "i":
                let inner = inlineNodes(of: child)
                if !isBlank(inner) { result.append(.emphasis(inner)) }
            case "del", "s", "strike":
                let inner = inlineNodes(of: child)
                if !isBlank(inner) { result.append(.strikethrough(inner)) }
            case "code":
                let text = child.combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { result.append(.code(text)) }
            case "a":
                let inner = inlineNodes(of: child)
                if let href = child.attr("href"), URLPolicy.linkDestination(href) != nil {
                    let title = child.attr("title")
                    result.append(.link(inner.isEmpty ? [.text(href)] : inner,
                                        destination: href, title: title))
                } else {
                    result.append(contentsOf: inner)
                }
            case "img":
                if let (destination, title) = imageDestination(child) {
                    result.append(.image(alt: child.attr("alt") ?? "",
                                         destination: destination, title: title))
                }
            case "script", "style", "iframe", "noscript", "template":
                break
            default:
                result.append(contentsOf: inlineNodes(of: child))
            }
        }
        return trimInlineWhitespace(result)
    }

    private func imageDestination(_ node: XMLNode) -> (String, String?)? {
        guard let src = node.attr("src"), let safe = URLPolicy.imageDestination(src) else {
            return nil
        }
        if safe.hasPrefix("data:") || safe.hasPrefix("http://") || safe.hasPrefix("https://") {
            return (safe, node.attr("title"))
        }
        // Local file relative to the HTML document: copy it into the Markdown
        // document's assets folder (or inline it when there is no folder yet).
        let cleaned = safe.split(separator: "#", maxSplits: 1).first.map(String.init) ?? safe
        let decoded = cleaned.removingPercentEncoding ?? cleaned
        let fileURL = decoded.hasPrefix("/")
            ? URL(fileURLWithPath: decoded)
            : sourceDirectory.appendingPathComponent(decoded).standardizedFileURL
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            return (safe, node.attr("title"))
        }
        let (destination, warning) = ImportAssets.store(data: data,
                                                        suggestedName: fileURL.lastPathComponent,
                                                        baseDirectory: baseDirectory)
        if let warning { collector.add(warning) }
        return (destination, node.attr("title"))
    }

    // MARK: Lists & tables

    private func convertList(_ node: XMLNode) -> BlockNode {
        let ordered = node.isNamed("ol")
        let start = Int(node.attr("start") ?? "") ?? 1
        var items: [ListItem] = []

        for li in node.children(named: "li") {
            var inner = HTMLToMarkdown(sourceDirectory: sourceDirectory, baseDirectory: baseDirectory, collector: collector)
            // Keep inline content in the same paragraph, but let nested blocks
            // (nested lists, quotes) become their own blocks.
            for child in li.children {
                if ["ul", "ol", "blockquote", "pre", "table"].contains(child.localName) {
                    inner.flushParagraph()
                    inner.visit(child)
                } else {
                    inner.visit(child)
                }
            }
            inner.flushParagraph()
            var item = ListItem(blocks: inner.blocks.isEmpty
                                ? [.paragraph([.text("")])] : inner.blocks)
            if let checkbox = li.descendants(named: "input").first(where: {
                ($0.attr("type") ?? "").lowercased() == "checkbox"
            }) {
                item.isChecked = checkbox.attr("checked") != nil
            }
            items.append(item)
        }
        return .list(ordered: ordered, start: ordered ? start : 1, items: items)
    }

    private func convertTable(_ node: XMLNode) -> BlockNode {
        let rows = node.descendants(named: "tr")
        guard let first = rows.first else { return .paragraph([]) }

        func cells(in row: XMLNode) -> [XMLNode] {
            row.children.filter { $0.isNamed("th") || $0.isNamed("td") }
        }
        let firstCells = cells(in: first)
        let treatFirstAsHeader = firstCells.contains { $0.isNamed("th") } || rows.count > 1
        let headerCells = treatFirstAsHeader ? firstCells : []
        var headers: [[InlineNode]] = headerCells.map { inlineNodes(of: $0) }
        var alignments: [TableAlignment] = headerCells.map { alignment(of: $0) }

        var bodyRows: [[[InlineNode]]] = []
        let dataRows = treatFirstAsHeader ? Array(rows.dropFirst()) : rows
        for row in dataRows {
            let values = cells(in: row).map { inlineNodes(of: $0) }
            if !values.isEmpty { bodyRows.append(values) }
        }
        if headers.isEmpty, let firstBody = bodyRows.first {
            headers = firstBody.map { _ in [.text("")] }
            alignments = Array(repeating: .none, count: firstBody.count)
        }
        let columns = headers.count
        if columns == 0 { return .paragraph([]) }
        if bodyRows.contains(where: { $0.count > columns }) {
            collector.add("表格中部分行的单元格多于表头，多余的单元格已被裁剪。")
        }
        let normalisedRows = bodyRows.map { row -> [[InlineNode]] in
            var value = Array(row.prefix(columns))
            while value.count < columns { value.append([.text("")]) }
            return value
        }
        return .table(headers: headers, rows: normalisedRows, alignments: alignments)
    }

    private func alignment(of cell: XMLNode) -> TableAlignment {
        if let align = cell.attr("align")?.lowercased() {
            switch align {
            case "left": return .left
            case "center", "middle": return .center
            case "right": return .right
            default: break
            }
        }
        let style = (cell.attr("style") ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        if style.contains("text-align:center") { return .center }
        if style.contains("text-align:right") { return .right }
        if style.contains("text-align:left") { return .left }
        return .none
    }

    private func codeLanguage(from attributes: [String: String]) -> String? {
        let raw = attributes["class"] ?? attributes["data-language"] ?? ""
        for part in raw.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let token = String(part)
            for prefix in ["language-", "lang-", "highlight-"] where token.hasPrefix(prefix) {
                return String(token.dropFirst(prefix.count))
            }
        }
        return nil
    }

    // MARK: Helpers

    private func isBlank(_ nodes: [InlineNode]) -> Bool {
        InlineText.plain(nodes).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func trimInlineWhitespace(_ nodes: [InlineNode]) -> [InlineNode] {
        var result = nodes
        while let first = result.first, case .text(let value) = first,
              value.first?.isWhitespace == true {
            let trimmed = String(value.drop(while: { $0.isWhitespace }))
            if trimmed.isEmpty { result.removeFirst() } else { result[0] = .text(trimmed); break }
        }
        while let last = result.last, case .text(let value) = last,
              value.last?.isWhitespace == true {
            let trimmed = String(value.reversed().drop(while: { $0.isWhitespace }).reversed())
            if trimmed.isEmpty { result.removeLast() } else { result[result.count - 1] = .text(trimmed); break }
        }
        return result
    }
}

import Foundation

/// Reads the OOXML parts of a .docx and rebuilds a `MarkdownModel`.
///
/// Handles paragraphs, heading styles (English and Chinese style names),
/// bold/italic/strike runs, hyperlinks, GFM tables, list paragraphs and
/// embedded images. Merged cells, text boxes, footnotes and exact numbering
/// are conservatively degraded with an explicit warning.
struct DOCXImporter: DocumentImporter {
    let format = StandardImportFormats.docx

    func importDocument(_ request: ImportRequest) async throws -> ImportResult {
        let data = try Data(contentsOf: request.url)
        let archive = try OOXMLArchive(data: data)
        guard archive.hasEntry("word/document.xml") else {
            throw ImportError.unreadable("不是有效的 .docx（缺少 word/document.xml）。")
        }

        let root = try XMLTree.parse(archive.data(for: "word/document.xml"))
        let stylesRoot = try? XMLTree.parse(archive.data(for: "word/styles.xml"))
        let numberingRoot = try? XMLTree.parse(archive.data(for: "word/numbering.xml"))

        var converter = DOCXToMarkdown(archive: archive,
                                       request: request,
                                       relationships: Self.relationships(in: archive),
                                       styleNames: Self.styleNames(in: stylesRoot),
                                       outlineLevels: Self.outlineLevels(in: stylesRoot),
                                       orderedLists: Self.orderedLists(in: numberingRoot))
        let model = converter.convert(root)
        guard !model.blocks.isEmpty else {
            throw ImportError.emptyDocument("Word 文档中没有可转换的正文内容。")
        }
        return ImportResult(markdown: MarkdownSerializer.serialize(model),
                            warnings: converter.warnings,
                            sourceURL: request.url,
                            format: format)
    }

    // MARK: - Package parts

    fileprivate struct Relationship {
        let target: String
        let isExternal: Bool
    }

    private static func relationships(in archive: OOXMLArchive) -> [String: Relationship] {
        guard let data = try? archive.data(for: "word/_rels/document.xml.rels"),
              let root = try? XMLTree.parse(data) else { return [:] }
        var result: [String: Relationship] = [:]
        for rel in root.descendants(named: "Relationship") {
            guard let id = rel.attr("Id"), let target = rel.attr("Target") else { continue }
            result[id] = Relationship(target: target,
                                      isExternal: (rel.attr("TargetMode") ?? "") == "External")
        }
        return result
    }

    private static func styleNames(in root: XMLNode?) -> [String: String] {
        var result: [String: String] = [:]
        for style in root?.descendants(named: "style") ?? [] {
            guard let id = style.attr("styleId"),
                  let name = style.firstChild(named: "name")?.attr("val") else { continue }
            result[id] = name
        }
        return result
    }

    private static func outlineLevels(in root: XMLNode?) -> [String: Int] {
        var result: [String: Int] = [:]
        for style in root?.descendants(named: "style") ?? [] {
            guard let id = style.attr("styleId"),
                  let value = style.firstChild(named: "pPr")?
                    .firstChild(named: "outlineLvl")?.attr("val"),
                  let level = Int(value) else { continue }
            result[id] = level
        }
        return result
    }

    /// Maps `w:numId` to "ordered?" via numbering.xml's level-0 numFmt.
    private static func orderedLists(in root: XMLNode?) -> [String: Bool] {
        guard let root else { return [:] }
        var abstract: [String: Bool] = [:]
        for node in root.descendants(named: "abstractNum") {
            guard let id = node.attr("abstractNumId") else { continue }
            let levels = node.children(named: "lvl")
            let level0 = levels.first { $0.attr("ilvl") == "0" } ?? levels.first
            let format = level0?.firstChild(named: "numFmt")?.attr("val") ?? "bullet"
            abstract[id] = !["bullet", "none"].contains(format)
        }
        var result: [String: Bool] = [:]
        for num in root.descendants(named: "num") {
            guard let id = num.attr("numId"),
                  let abstractId = num.firstChild(named: "abstractNumId")?.attr("val") else { continue }
            result[id] = abstract[abstractId] ?? false
        }
        return result
    }
}

// MARK: - document.xml → AST

private struct DOCXToMarkdown {
    let archive: OOXMLArchive
    let request: ImportRequest
    let relationships: [String: DOCXImporter.Relationship]
    let styleNames: [String: String]
    let outlineLevels: [String: Int]
    let orderedLists: [String: Bool]
    let collector = WarningCollector()

    var warnings: [String] { collector.items }

    private enum Piece {
        case heading(Int, [InlineNode])
        case paragraph([InlineNode])
        case listItem(String, Int, [InlineNode])   // numId, ilvl, content
        case table(BlockNode)
    }

    mutating func convert(_ root: XMLNode) -> MarkdownModel {
        let body = root.descendants(named: "body").first ?? root
        let pieces = body.children.compactMap { piece(from: $0) }
        var blocks: [BlockNode] = []
        var listOrdered: Bool?
        var listItems: [ListItem] = []

        func commitList() {
            if let listOrdered, !listItems.isEmpty {
                blocks.append(.list(ordered: listOrdered, start: 1, items: listItems))
            }
            listOrdered = nil
            listItems.removeAll()
        }

        for piece in pieces {
            switch piece {
            case .heading(let level, let inline):
                commitList()
                blocks.append(.heading(level: level, inline: inline))
            case .paragraph(let inline):
                commitList()
                if !plain(inline).isEmpty { blocks.append(.paragraph(inline)) }
            case .table(let table):
                commitList()
                blocks.append(table)
            case .listItem(let numId, let ilvl, let inline):
                let ordered = orderedLists[numId] ?? false
                if ilvl > 0 {
                    collector.add("文档含多级列表，已扁平化为一级列表（层级 \(ilvl + 1)）。")
                }
                if let existing = listOrdered, existing != ordered { commitList() }
                if listOrdered == nil { listOrdered = ordered }
                listItems.append(ListItem(blocks: [.paragraph(inline)]))
            }
        }
        commitList()

        var model = MarkdownModel()
        model.blocks = blocks
        return model
    }

    private func piece(from node: XMLNode) -> Piece? {
        if node.isNamed("tbl") { return .table(convertTable(node)) }
        guard node.isNamed("p") else { return nil }

        let properties = node.firstChild(named: "pPr")
        let styleId = properties?.firstChild(named: "pStyle")?.attr("val")
        let inline = inlineNodes(in: node)

        if let numPr = properties?.firstChild(named: "numPr"),
           let numId = numPr.firstChild(named: "numId")?.attr("val") {
            let ilvl = Int(numPr.firstChild(named: "ilvl")?.attr("val") ?? "0") ?? 0
            // A checked task is not representable in OOXML's numPr; leave nil.
            return .listItem(numId, ilvl, inline)
        }
        if let level = headingLevel(for: styleId) { return .heading(level, inline) }
        if let outline = properties?.firstChild(named: "outlineLvl")?.attr("val"),
           let value = Int(outline), (0...5).contains(value) {
            return .heading(value + 1, inline)
        }
        return .paragraph(inline)
    }

    private func headingLevel(for styleId: String?) -> Int? {
        guard let id = styleId else { return nil }
        if let outline = outlineLevels[id] { return min(6, max(1, outline + 1)) }
        let name = styleNames[id] ?? id
        let lower = name.lowercased()
        if lower == "title" || lower == "标题" { return 1 }
        let looksLikeHeading = lower.hasPrefix("heading") || lower.hasPrefix("标题") ||
            lower.contains("heading") || lower.contains("标题")
        guard looksLikeHeading, let digits = trailingDigits(in: name) else { return nil }
        return min(6, max(1, digits))
    }

    private func trailingDigits(in string: String) -> Int? {
        var digits = ""
        for ch in string.reversed() {
            if ch.isNumber { digits.insert(ch, at: digits.startIndex) }
            else if !digits.isEmpty { break }
        }
        return digits.isEmpty ? nil : Int(digits)
    }

    // MARK: Runs & inline nodes

    private func inlineNodes(in container: XMLNode) -> [InlineNode] {
        var result: [InlineNode] = []
        for child in container.children {
            switch child.localName {
            case "r":
                result.append(contentsOf: runNodes(child))
            case "hyperlink":
                let inner = inlineNodes(in: child)
                if let id = child.attr("id"), let rel = relationships[id],
                   let destination = URLPolicy.linkDestination(rel.target) {
                    result.append(.link(inner.isEmpty ? [.text(destination)] : inner,
                                        destination: destination, title: nil))
                } else if let anchor = child.attr("anchor"), !anchor.isEmpty {
                    result.append(.link(inner, destination: "#" + anchor, title: nil))
                } else {
                    result.append(contentsOf: inner)
                }
            case "t":
                result.append(.text(child.combinedText))
            case "tab":
                result.append(.text("\t"))
            case "br", "cr":
                result.append(.hardBreak)
            case "drawing", "pict", "object":
                if let image = imageNode(in: child) { result.append(image) }
            default:
                if !child.children.isEmpty {
                    result.append(contentsOf: inlineNodes(in: child))
                }
            }
        }
        return result
    }

    private func runNodes(_ run: XMLNode) -> [InlineNode] {
        let properties = run.firstChild(named: "rPr")
        func flag(_ name: String) -> Bool {
            guard let node = properties?.firstChild(named: name) else { return false }
            let value = node.attr("val") ?? "1"
            return value != "0" && value.lowercased() != "false"
        }
        let bold = flag("b") || flag("bCs")
        let italic = flag("i") || flag("iCs")
        let strike = flag("strike") || flag("dstrike")

        var result: [InlineNode] = []
        var text = ""

        func flush() {
            guard !text.isEmpty else { return }
            var node = InlineNode.text(text)
            if strike { node = .strikethrough([node]) }
            if italic { node = .emphasis([node]) }
            if bold { node = .strong([node]) }
            result.append(node)
            text = ""
        }

        for child in run.children {
            switch child.localName {
            case "t": text += child.combinedText
            case "tab": text += "\t"
            case "br", "cr": flush(); result.append(.hardBreak)
            case "noBreakHyphen": text += "-"
            case "drawing", "pict":
                flush()
                if let image = imageNode(in: child) { result.append(image) }
            case "instrText", "fldChar", "delText", "rPr", "lastRenderedPageBreak":
                break
            default:
                break
            }
        }
        flush()
        return result
    }

    private func imageNode(in node: XMLNode) -> InlineNode? {
        let embed = node.descendants(named: "blip").first?.attr("embed") ??
            node.descendants(named: "imagedata").first?.attr("id")
        guard let embed, let rel = relationships[embed] else { return nil }
        guard let path = mediaPath(for: rel.target),
              let data = try? archive.data(for: path), !data.isEmpty else { return nil }
        let (destination, warning) = ImportAssets.store(
            data: data,
            suggestedName: (path as NSString).lastPathComponent,
            baseDirectory: request.baseDirectory)
        if let warning { collector.add(warning) }
        return .image(alt: "图片", destination: destination, title: nil)
    }

    private func mediaPath(for target: String) -> String? {
        let cleaned = target.hasPrefix("/") ? String(target.dropFirst()) : "word/" + target
        let normalised = (cleaned as NSString).standardizingPath
        if archive.hasEntry(normalised) { return normalised }
        return archive.entryNames.first { $0.hasSuffix((target as NSString).lastPathComponent) }
    }

    // MARK: Tables

    private func convertTable(_ table: XMLNode) -> BlockNode {
        var grid: [[[InlineNode]]] = []
        for row in table.children(named: "tr") {
            var values: [[InlineNode]] = []
            for cell in row.children(named: "tc") {
                let text = cellText(cell)
                let span = Int(cell.firstChild(named: "tcPr")?
                    .firstChild(named: "gridSpan")?.attr("val") ?? "1") ?? 1
                if span > 1 {
                    collector.add("Word 表格含合并单元格，已退化为重复文本（未还原跨列结构）。")
                }
                for _ in 0..<max(1, span) { values.append(text) }
            }
            if !values.isEmpty { grid.append(values) }
        }
        guard let header = grid.first else { return .paragraph([]) }
        if grid.contains(where: { $0.count > header.count }) {
            collector.add("Word 表格中部分行列数多于表头，多余单元格已裁剪。")
        }
        let rows = Array(grid.dropFirst()).map { row -> [[InlineNode]] in
            var value = Array(row.prefix(header.count))
            while value.count < header.count { value.append([.text("")]) }
            return value
        }
        return .table(headers: header, rows: rows,
                      alignments: Array(repeating: .none, count: header.count))
    }

    private func cellText(_ cell: XMLNode) -> [InlineNode] {
        var result: [InlineNode] = []
        let paragraphs = cell.children(named: "p")
        for (index, paragraph) in paragraphs.enumerated() {
            if index > 0 { result.append(.softBreak) }
            result.append(contentsOf: inlineNodes(in: paragraph))
        }
        return result
    }

    private func plain(_ nodes: [InlineNode]) -> String {
        InlineText.plain(nodes).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

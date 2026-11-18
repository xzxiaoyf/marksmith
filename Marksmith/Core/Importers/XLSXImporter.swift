import Foundation

/// Converts every worksheet of an .xlsx workbook into a GFM table.
///
/// Values come from `sharedStrings.xml`, inline strings, cached formula
/// results and numeric cells. Excel stores formatting separately from content,
/// so styles, charts, conditional formatting and merged cells cannot survive;
/// a warning is emitted for each degraded feature.
struct XLSXImporter: DocumentImporter {
    let format = StandardImportFormats.xlsx

    func importDocument(_ request: ImportRequest) async throws -> ImportResult {
        let archive = try OOXMLArchive(data: try Data(contentsOf: request.url))
        guard let workbookData = try? archive.data(for: "xl/workbook.xml") else {
            throw ImportError.unreadable("不是有效的 .xlsx（缺少 xl/workbook.xml）。")
        }
        let workbook = try XMLTree.parse(workbookData)
        let sharedStrings = Self.sharedStrings(in: archive)
        let dateStyles = Self.dateStyleIDs(in: archive)
        let rels = Self.sheetRelationships(in: archive)
        let collector = WarningCollector()

        var blocks: [BlockNode] = []
        let sheetNodes = workbook.descendants(named: "sheet")
        for sheet in sheetNodes {
            let name = sheet.attr("name") ?? "Sheet"
            let relID = sheet.attr("id") ?? ""
            guard let target = rels[relID],
                  let path = Self.resolveSheetPath(target, in: archive),
                  let sheetData = try? archive.data(for: path),
                  let sheetRoot = try? XMLTree.parse(sheetData) else { continue }

            blocks.append(.heading(level: 2,
                                   inline: [.text(name)]))
            let table = Self.convertSheet(sheetRoot, sharedStrings: sharedStrings,
                                          dateStyles: dateStyles, collector: collector)
            if case .table(let headers, _, _) = table, !headers.isEmpty {
                blocks.append(table)
            } else {
                blocks.removeLast()
            }
        }

        guard blocks.contains(where: { if case .table = $0 { return true }; return false }) else {
            throw ImportError.emptyDocument("工作簿中没有可读取的数据表。")
        }
        var model = MarkdownModel()
        model.blocks = blocks
        return ImportResult(markdown: MarkdownSerializer.serialize(model),
                            warnings: collector.items,
                            sourceURL: request.url,
                            format: format)
    }

    // MARK: - Package parts

    private static func sharedStrings(in archive: OOXMLArchive) -> [String] {
        guard let data = try? archive.data(for: "xl/sharedStrings.xml"),
              let root = try? XMLTree.parse(data) else { return [] }
        return root.descendants(named: "si").map { $0.combinedText }
    }

    private static func dateStyleIDs(in archive: OOXMLArchive) -> Set<Int> {
        guard let data = try? archive.data(for: "xl/styles.xml"),
              let root = try? XMLTree.parse(data) else { return [] }
        // Built-in date formats (14–22, 45–47) plus custom formats whose
        // formatCode contains date/time tokens.
        var builtins: Set<Int> = Set(14...22).union(Set(45...47))
        var custom: Set<Int> = []
        for fmt in root.descendants(named: "numFmt") {
            guard let id = Int(fmt.attr("numFmtId") ?? "") else { continue }
            let code = (fmt.attr("formatCode") ?? "").lowercased()
            if code.contains("yy") || code.contains("dd") || code.contains("mm") ||
                code.contains("hh") || code.contains("ss") {
                custom.insert(id)
            }
        }
        builtins.formUnion(custom)
        // Cell style indices are positions in <cellXfs>, not the numFmtId.
        guard let xfs = root.descendants(named: "cellXfs").first else { return [] }
        var indices: Set<Int> = []
        for (index, xf) in xfs.children(named: "xf").enumerated() {
            if let id = Int(xf.attr("numFmtId") ?? ""), builtins.contains(id) {
                indices.insert(index)
            }
        }
        return indices
    }

    private static func sheetRelationships(in archive: OOXMLArchive) -> [String: String] {
        guard let data = try? archive.data(for: "xl/_rels/workbook.xml.rels"),
              let root = try? XMLTree.parse(data) else { return [:] }
        var result: [String: String] = [:]
        for rel in root.descendants(named: "Relationship") {
            guard let id = rel.attr("Id"), let target = rel.attr("Target") else { continue }
            result[id] = target
        }
        return result
    }

    private static func resolveSheetPath(_ target: String,
                                         in archive: OOXMLArchive) -> String? {
        var candidate = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
        candidate = (candidate as NSString).standardizingPath
        if archive.hasEntry(candidate) { return candidate }
        let fileName = (target as NSString).lastPathComponent
        return archive.entryNames.first { $0.hasSuffix(fileName) }
    }

    // MARK: - Worksheet → table

    private static func convertSheet(_ root: XMLNode, sharedStrings: [String],
                                     dateStyles: Set<Int>,
                                     collector: WarningCollector) -> BlockNode {
        guard let sheetData = root.descendants(named: "sheetData").first else {
            return .table(headers: [], rows: [], alignments: [])
        }
        var grid: [[String]] = []
        var maxColumns = 0
        var sawFormula = false

        for row in sheetData.children(named: "row") {
            var values: [String] = []
            for cell in row.children(named: "c") {
                let column = columnIndex(cell.attr("r") ?? "")
                while values.count < column { values.append("") }
                let value = cellValue(cell, sharedStrings: sharedStrings,
                                      dateStyles: dateStyles)
                if cell.firstChild(named: "f") != nil { sawFormula = true }
                values.append(value)
            }
            maxColumns = max(maxColumns, values.count)
            grid.append(values)
        }
        if sawFormula {
            collector.add("公式按 Excel 保存的缓存结果导入，公式本身不会保留。")
        }
        if root.descendants(named: "mergeCell").first != nil {
            collector.add("合并单元格未还原，仅保留左上角的值。")
        }
        if maxColumns > 12 {
            collector.add("表格宽达 \(maxColumns) 列，Markdown 表格阅读体验会明显下降。")
        }

        while maxColumns > 0, grid.allSatisfy({ row in
            (maxColumns - 1) >= row.count || row[maxColumns - 1].isEmpty
        }) {
            maxColumns -= 1
        }
        guard maxColumns > 0, let header = grid.first else {
            return .table(headers: [], rows: [], alignments: [])
        }
        func normalise(_ row: [String]) -> [[InlineNode]] {
            (0..<maxColumns).map { index in
                index < row.count ? [.text(row[index])] : [.text("")]
            }
        }
        let headers = normalise(header)
        let rows = Array(grid.dropFirst()).map(normalise)
        return .table(headers: headers, rows: rows,
                      alignments: Array(repeating: .none, count: maxColumns))
    }

    private static func cellValue(_ cell: XMLNode, sharedStrings: [String],
                                  dateStyles: Set<Int>) -> String {
        let type = cell.attr("t") ?? "n"
        let rawValue = cell.firstChild(named: "v")?.combinedText ?? ""

        switch type {
        case "s":
            guard let index = Int(rawValue), sharedStrings.indices.contains(index) else { return "" }
            return sharedStrings[index]
        case "inlineStr":
            return cell.firstChild(named: "is")?.combinedText ?? ""
        case "str", "e", "d":
            return rawValue
        case "b":
            return rawValue == "1" ? "TRUE" : "FALSE"
        default:
            guard let number = Double(rawValue) else { return rawValue }
            if let style = Int(cell.attr("s") ?? ""), dateStyles.contains(style) {
                return excelDate(number)
            }
            if number == number.rounded(), abs(number) < 1e15 {
                return String(Int64(number))
            }
            return String(number)
        }
    }

    private static func excelDate(_ serial: Double) -> String {
        // Excel's serial 0 is 1899-12-30 for dates after the 1900 leap-year
        // bug. Fractional part is the time of day.
        let seconds = (serial - 25569) * 86400   // 25569 = days to 1970-01-01
        let date = Date(timeIntervalSince1970: seconds)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = abs(serial - serial.rounded()) > 0.00001
            ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func columnIndex(_ reference: String) -> Int {
        var value = 0
        for ch in reference.uppercased() {
            guard ch.isLetter, let scalar = ch.unicodeScalars.first?.value,
                  scalar >= 65, scalar <= 90 else { break }
            value = value * 26 + Int(scalar - 64)
        }
        return max(0, value - 1)
    }
}

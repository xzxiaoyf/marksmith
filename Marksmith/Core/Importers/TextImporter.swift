import Foundation

// MARK: - Plain-text decoding
//
// A `.txt` on a Chinese Mac is not necessarily UTF-8: Windows exports are
// often GBK/GB18030, older tools write UTF-16 with a BOM, and CRLF line
// endings are common. This decoder resolves all of those before the content
// ever reaches the editor, so importing never produces 乱码 or stray \r.

struct DecodedTextFile {
    let text: String
    let encodingLabel: String
    let hadBOM: Bool
    let normalisedLineEndings: Bool
}

enum TextFileDecoder {

    static let maximumBytes = 32 * 1024 * 1024

    private static let gb18030 = String.Encoding(rawValue: 0x80000632)
    private static let big5 = String.Encoding(rawValue: 0x80000A03)

    static func decode(_ data: Data) throws -> DecodedTextFile {
        guard !data.isEmpty else {
            throw ImportError.unreadable("文件为空。")
        }
        guard data.count <= maximumBytes else {
            throw ImportError.unreadable("文件超过 32 MB，请先拆分后再导入。")
        }

        let head = Array(data.prefix(4))
        var bomLength = 0
        var bomEncoding: String.Encoding = .utf8
        var label = "UTF-8"

        if head.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            bomLength = 4; bomEncoding = .utf32BigEndian; label = "UTF-32BE"
        } else if head.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            bomLength = 4; bomEncoding = .utf32LittleEndian; label = "UTF-32LE"
        } else if head.starts(with: [0xEF, 0xBB, 0xBF]) {
            bomLength = 3; bomEncoding = .utf8; label = "UTF-8"
        } else if head.starts(with: [0xFE, 0xFF]) {
            bomLength = 2; bomEncoding = .utf16BigEndian; label = "UTF-16BE"
        } else if head.starts(with: [0xFF, 0xFE]) {
            bomLength = 2; bomEncoding = .utf16LittleEndian; label = "UTF-16LE"
        }

        var decoded: String?
        if bomLength > 0 {
            decoded = String(data: data.dropFirst(bomLength), encoding: bomEncoding)
        } else if data.prefix(8192).contains(where: { $0 == 0 }) {
            // No BOM but NUL bytes: either BOM-less UTF-16/32, or a binary file.
            let candidates: [(String, String.Encoding)] = [
                ("UTF-16LE", .utf16LittleEndian), ("UTF-16BE", .utf16BigEndian),
                ("UTF-32LE", .utf32LittleEndian), ("UTF-32BE", .utf32BigEndian)
            ]
            for (name, encoding) in candidates {
                if let value = String(data: data, encoding: encoding), isPlausible(value) {
                    decoded = value
                    label = name
                    break
                }
            }
            if decoded == nil {
                throw ImportError.unreadable("文件含有 NUL 字节，看起来不是纯文本（可能是二进制文件）。")
            }
        } else if let utf8 = String(data: data, encoding: .utf8) {
            decoded = utf8
        } else {
            // Pick the most plausible legacy decoding instead of guessing once.
            var best: (label: String, text: String, score: Int)?
            // GB18030 covers GBK/GB2312 and is by far the most common legacy
            // encoding on a Chinese Mac, so give it a small tie-break bias:
            // a Big5 byte stream misread as GBK often scores similarly.
            let candidates: [(String, String.Encoding, Int)] = [
                ("GB18030 / GBK", gb18030, 3), ("Big5", big5, 0),
                ("Windows-1252", String.Encoding.windowsCP1252, 0)
            ]
            for (name, encoding, bias) in candidates {
                guard let value = String(data: data, encoding: encoding) else { continue }
                let score = plausibility(value) + bias
                if best == nil || score > best!.score {
                    best = (name, value, score)
                }
            }
            if let best {
                decoded = best.text
                label = best.label
            } else {
                decoded = String(decoding: data, as: UTF8.self)
                label = "UTF-8（含替换字符）"
            }
        }

        var text = decoded ?? ""
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        // CRLF is ONE Swift `Character` (grapheme cluster), so `contains("\r")`
        // would be false on a Windows text file. Work on unicode scalars.
        let hadCR = text.unicodeScalars.contains("\r")
        if hadCR {
            let lf: Unicode.Scalar = "\n"
            let cr: Unicode.Scalar = "\r"
            let scalars = Array(text.unicodeScalars)
            var normalised = ""
            var index = 0
            while index < scalars.count {
                if scalars[index] == cr {
                    normalised.unicodeScalars.append(lf)
                    if index + 1 < scalars.count, scalars[index + 1] == lf { index += 1 }
                } else {
                    normalised.unicodeScalars.append(scalars[index])
                }
                index += 1
            }
            text = normalised
        }
        return DecodedTextFile(text: text,
                               encodingLabel: label,
                               hadBOM: bomLength > 0,
                               normalisedLineEndings: hadCR)
    }

    /// Used by the import panel when a file has no registered extension (or an
    /// unknown one): only clearly textual files are handed to `TextImporter`.
    static func probablyText(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return false }
        let sample = data.prefix(64 * 1024)
        guard !sample.isEmpty else { return false }
        if sample.starts(with: [0xEF, 0xBB, 0xBF]) ||
            sample.starts(with: [0xFF, 0xFE]) || sample.starts(with: [0xFE, 0xFF]) {
            return true
        }
        if sample.contains(where: { $0 == 0 }) { return false }
        // A whole (small) UTF-8 file decodes cleanly. For a large file the
        // sample can end mid-way through a UTF-8 sequence, so retry with the
        // last few bytes dropped before giving up.
        if String(data: Data(sample), encoding: .utf8) != nil { return true }
        let probe = Data(sample.dropLast(min(4, sample.count)))
        if !String(decoding: probe, as: UTF8.self).contains("\u{FFFD}") { return true }
        if let legacy = String(data: probe, encoding: gb18030), plausibility(legacy) > 0 {
            return true
        }
        return false
    }

    private static func isPlausible(_ value: String) -> Bool {
        !value.contains("\u{0000}") && plausibility(value) > 0
    }

    private static func plausibility(_ value: String) -> Int {
        var score = 0
        for scalar in value.unicodeScalars.prefix(20_000) {
            let v = scalar.value
            if v == 0xFFFD { score -= 20 }
            else if v < 0x20, v != 9, v != 10, v != 13 { score -= 20 }
            else if v < 0x80 { score += 1 }
            else if (0x3400...0x9FFF).contains(v) { score += 3 }
            else if (0x3000...0x303F).contains(v) || (0xFF00...0xFFEF).contains(v) { score += 2 }
        }
        return score
    }
}

// MARK: - Text importer

/// Imports plain-text and Markdown-family files.
///
/// Markdown-looking files are kept verbatim (only encoding / line endings are
/// normalised). Everything else goes through the shared AST → `MarkdownSerializer`
/// path: every line becomes a hard break and Markdown punctuation is escaped,
/// so a .txt with `*` or `#` is displayed as text instead of accidentally
/// turning into formatting. CSV/TSV get a GFM table instead of prose.
struct TextImporter: DocumentImporter {
    let format = StandardImportFormats.text

    private static let markdownExtensions: Set<String> =
        ["md", "markdown", "mdown", "mkd", "mdx"]
    private static let maximumTableRows = 500

    func importDocument(_ request: ImportRequest) async throws -> ImportResult {
        let data = try Data(contentsOf: request.url)
        let file = try TextFileDecoder.decode(data)
        guard !file.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.emptyDocument("文本文件没有内容（只有空白字符）。")
        }

        let ext = request.url.pathExtension.lowercased()
        var notes: [String] = []
        let markdown: String

        if let table = Self.makeTable(file.text, extension: ext) {
            var model = MarkdownModel()
            model.blocks = [table.block]
            markdown = MarkdownSerializer.serialize(model)
            notes.append("\(ext.uppercased()) 已转换为 GFM 表格，第一行作为表头。")
            if table.truncated {
                notes.append("行数较多，仅导入前 \(Self.maximumTableRows) 行数据。")
            }
        } else if Self.looksLikeMarkdown(ext: ext, text: file.text) {
            markdown = file.text
            notes.append("按 Markdown 原文导入（仅统一编码与换行），语法标记保持原样。")
        } else {
            var model = MarkdownModel()
            model.blocks = Self.plainTextBlocks(file.text)
            markdown = MarkdownSerializer.serialize(model)
            notes.append("已按纯文本导入：每个换行转为 Markdown 硬换行（行尾两个空格），并转义 Markdown 特殊字符，避免被误当成语法。")
            notes.append("若要逐字保留原文，请直接用「文件 → 打开」打开 .txt —— Marksmith 本身就能打开纯文本文件。")
        }

        var warnings: [String] = []
        if file.encodingLabel != "UTF-8" {
            warnings.append("编码识别为 \(file.encodingLabel)，已按该编码解码；若出现乱码请先把文件另存为 UTF-8。")
        }
        if file.hadBOM { warnings.append("已自动移除文件开头的 BOM。") }
        if file.normalisedLineEndings { warnings.append("已把 CRLF / CR 换行统一为 LF。") }
        warnings.append(contentsOf: notes)

        return ImportResult(markdown: markdown,
                            warnings: warnings,
                            sourceURL: request.url,
                            format: format)
    }

    // MARK: Markdown detection

    private static func looksLikeMarkdown(ext: String, text: String) -> Bool {
        if markdownExtensions.contains(ext) { return true }
        var score = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(200) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { score += 4; continue }
            if line.hasPrefix("# ") || line.hasPrefix("## ") || line.hasPrefix("### ") { score += 2 }
            if line.hasPrefix("> ") { score += 1 }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { score += 1 }
            if line.hasPrefix("|"), line.contains("---") { score += 4 }
            if line.contains("](") { score += 1 }
        }
        return score >= 4
    }

    // MARK: Plain text → paragraph AST

    private static func plainTextBlocks(_ text: String) -> [BlockNode] {
        var blocks: [BlockNode] = []
        var paragraph: [String] = []

        func commit() {
            guard !paragraph.isEmpty else { return }
            var nodes: [InlineNode] = []
            for (index, line) in paragraph.enumerated() {
                if index > 0 { nodes.append(.hardBreak) }
                nodes.append(.text(line))
            }
            blocks.append(.paragraph(nodes))
            paragraph.removeAll()
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                commit()
            } else {
                paragraph.append(line)
            }
        }
        commit()
        return blocks
    }

    // MARK: CSV / TSV → GFM table

    private static func makeTable(_ text: String, extension ext: String) -> (block: BlockNode, truncated: Bool)? {
        let separator: Character
        switch ext {
        case "csv": separator = ","
        case "tsv": separator = "\t"
        default: return nil
        }

        let rows = parseDelimited(text, separator: separator)
            .filter { row in row.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard let header = rows.first, !header.isEmpty else { return nil }
        let body = rows.dropFirst()
        let truncated = body.count > maximumTableRows
        let columns = header.count

        func cells(_ row: [String]) -> [[InlineNode]] {
            var values = row.prefix(columns).map { [InlineNode.text($0)] }
            while values.count < columns { values.append([.text("")]) }
            return values
        }

        let table = BlockNode.table(
            headers: cells(header),
            rows: Array(body.prefix(maximumTableRows)).map(cells),
            alignments: []
        )
        return (table, truncated)
    }

    /// Small RFC 4180-ish reader: quoted fields, escaped `""` and embedded
    /// newlines inside quotes are handled.
    private static func parseDelimited(_ text: String, separator: Character) -> [[String]] {
        let chars = Array(text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var i = 0

        func endField() { row.append(field); field = "" }
        func endRow() { endField(); rows.append(row); row = [] }

        while i < chars.count {
            let ch = chars[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 2
                        continue
                    }
                    inQuotes = false
                    i += 1
                    continue
                }
                field.append(ch)
                i += 1
                continue
            }
            if ch == "\"", field.isEmpty {
                inQuotes = true
                i += 1
            } else if ch == separator {
                endField()
                i += 1
            } else if ch == "\n" {
                endRow()
                i += 1
            } else if ch == "\r" {
                i += 1
            } else {
                field.append(ch)
                i += 1
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}

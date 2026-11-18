import XCTest
@testable import Marksmith

/// Plain-text import: encoding detection (UTF-8 / BOM / UTF-16 / GB18030),
/// line-ending normalisation, Markdown-vs-prose handling and CSV→table.
final class TextImporterTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarksmithTextTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    @discardableResult
    private func write(_ data: Data, named name: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func write(_ text: String, named name: String,
                       encoding: String.Encoding = .utf8) throws -> URL {
        guard let data = text.data(using: encoding) else {
            throw NSError(domain: "TextImporterTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "encoding failed"])
        }
        return try write(data, named: name)
    }

    private func importText(_ url: URL) async throws -> ImportResult {
        try await TextImporter().importDocument(ImportRequest(url: url, baseDirectory: nil))
    }

    // MARK: - Plain text

    func testPlainTextKeepsLineBreaksAndEscapesSyntax() async throws {
        let url = try write("第一行\n第二行 *不是斜体*\n\n# 这不是标题\n新的段落 # 标题",
                            named: "notes.txt")
        let result = try await importText(url)

        XCTAssertEqual(result.format.id, "text")
        XCTAssertTrue(result.markdown.contains("第一行  \n第二行"), "single newlines must become hard breaks")
        XCTAssertTrue(result.markdown.contains("\\*不是斜体\\*"))
        XCTAssertTrue(result.markdown.contains("\\# 这不是标题"), "a leading # must not become a heading")
        XCTAssertTrue(result.markdown.contains("新的段落 # 标题"), "mid-line # needs no escaping")
        XCTAssertTrue(result.markdown.contains("\n\n\\# 这不是标题"))
        XCTAssertTrue(result.warnings.contains { $0.contains("硬换行") })

        let model = MarkdownParser().parse(result.markdown)
        XCTAssertEqual(model.blocks.count, 2)
        guard case .paragraph(let inline) = model.blocks[0] else { return XCTFail("paragraph") }
        XCTAssertTrue(inline.contains { if case .hardBreak = $0 { return true }; return false })
    }

    func testMarkdownFileIsImportedVerbatim() async throws {
        let source = "# 标题\n\n**粗体** 与 `代码`\n\n- 甲\n- 乙\n"
        let url = try write(source, named: "doc.md")
        let result = try await importText(url)
        XCTAssertEqual(result.markdown, source)
        XCTAssertTrue(result.warnings.contains { $0.contains("原文导入") })
    }

    func testCRLFAndBOMAreNormalised() async throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("第一行\r\n第二行\r\n".utf8)
        let url = try write(data, named: "bom.txt")
        let result = try await importText(url)

        XCTAssertFalse(result.markdown.unicodeScalars.contains("\r"))
        XCTAssertFalse(result.markdown.contains("\u{FEFF}"))
        XCTAssertTrue(result.markdown.contains("第一行  \n第二行"))
        XCTAssertTrue(result.warnings.contains { $0.contains("BOM") })
        XCTAssertTrue(result.warnings.contains { $0.contains("换行") })
    }

    func testGB18030ChineseTextIsDecoded() async throws {
        let gb18030 = String.Encoding(rawValue: 0x80000632)
        let url = try write("中文测试：第一行\n第二行", named: "gbk.txt", encoding: gb18030)
        let result = try await importText(url)

        XCTAssertTrue(result.markdown.contains("中文测试：第一行"), "GBK text must not become 乱码")
        XCTAssertTrue(result.warnings.contains { $0.contains("GB18030") })
    }

    func testUTF16LEWithBOMIsDecoded() async throws {
        let body = "UTF-16 中文\n第二行".data(using: .utf16LittleEndian)!
        let url = try write(Data([0xFF, 0xFE]) + body, named: "utf16.txt")
        let result = try await importText(url)

        XCTAssertTrue(result.markdown.contains("UTF-16 中文"))
        XCTAssertFalse(result.markdown.contains("\u{FEFF}"))
        XCTAssertTrue(result.warnings.contains { $0.contains("BOM") })
        XCTAssertTrue(result.warnings.contains { $0.contains("UTF-16LE") })
    }

    // MARK: - CSV / TSV

    func testCSVbecomesGFMTable() async throws {
        let url = try write("姓名,分数,备注\n张三,95,优\n李四,88,良\n", named: "scores.csv")
        let result = try await importText(url)

        XCTAssertTrue(result.markdown.contains("| 姓名 | 分数 | 备注 |"))
        XCTAssertTrue(result.markdown.contains("| --- | --- | --- |"))
        XCTAssertTrue(result.markdown.contains("| 张三 | 95 | 优 |"))
        XCTAssertTrue(result.warnings.contains { $0.contains("GFM 表格") })
        let model = MarkdownParser().parse(result.markdown)
        XCTAssertTrue(model.blocks.contains { if case .table = $0 { return true }; return false })
    }

    func testCSVQuotedFieldsWithCommaAndNewline() async throws {
        let csv = "名称,备注\n\"甲,乙\",\"第一行\n第二行\"\n"
        let url = try write(csv, named: "quoted.csv")
        let result = try await importText(url)

        XCTAssertTrue(result.markdown.contains("甲,乙"))
        XCTAssertTrue(result.markdown.contains("第一行 第二行"))
        XCTAssertEqual(MarkdownParser().parse(result.markdown).blocks.count, 1)
    }

    func testTSVbecomesGFMTable() async throws {
        let url = try write("A\tB\n1\t2\n", named: "sheet.tsv")
        let result = try await importText(url)
        XCTAssertTrue(result.markdown.contains("| A | B |"))
        XCTAssertTrue(result.markdown.contains("| 1 | 2 |"))
    }

    // MARK: - Error paths & sniffing

    func testEmptyAndBinaryFilesAreRejected() async throws {
        XCTAssertThrowsError(try TextFileDecoder.decode(Data())) { error in
            XCTAssertTrue(error.localizedDescription.contains("为空"))
        }

        let binary = try write(Data([0x00, 0x01, 0x02, 0x00, 0x03]), named: "binary.txt")
        do {
            _ = try await importText(binary)
            XCTFail("binary file should be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("NUL") ||
                          error.localizedDescription.contains("纯文本"))
        }
        XCTAssertFalse(TextFileDecoder.probablyText(binary))
    }

    @MainActor
    func testExtensionlessTextFileIsSniffedAsText() throws {
        let url = try write("README 内容\n第二行", named: "README")
        XCTAssertTrue(TextFileDecoder.probablyText(url))
        XCTAssertNil(ImportRegistry.shared.importer(forExtension: url.pathExtension))
    }

    // MARK: - Registry

    @MainActor
    func testTextImporterIsRegistered() {
        ImportRegistry.shared.bootstrap()
        XCTAssertNotNil(ImportRegistry.shared.importer(forExtension: "txt"))
        XCTAssertNotNil(ImportRegistry.shared.importer(forExtension: "TXT"))
        XCTAssertNotNil(ImportRegistry.shared.importer(forExtension: "md"))
        XCTAssertNil(ImportRegistry.shared.importer(forExtension: "docx-old"))
        XCTAssertTrue(ImportRegistry.shared.allowedExtensions.contains("csv"))
    }
}

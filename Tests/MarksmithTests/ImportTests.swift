import XCTest
@testable import Marksmith

@MainActor
final class ImportTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarksmithImportTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func write(_ text: String, named name: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func write(_ data: Data, named name: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - HTML

    func testHTMLImportKeepsStructureAndDropsScripts() async throws {
        let html = """
        <!doctype html><html><head><title>T</title><script>alert('xss')</script>
        <style>p{color:red}</style></head><body>
        <h1>标题一</h1>
        <p>这是一段 <strong>加粗</strong> 与 <em>斜体</em> 以及 <del>删除</del>，还有 <code>x = 1</code>。</p>
        <ul><li>项目 A</li><li><input type="checkbox" checked> 已完成</li></ul>
        <ol start="3"><li>第三步</li></ol>
        <table><thead><tr><th>列 A</th><th align="right">列 B</th></tr></thead>
        <tbody><tr><td>1</td><td>2</td></tr></tbody></table>
        <blockquote><p>引用内容</p></blockquote>
        <pre><code class="language-swift">let a = 1
        let b = 2</code></pre>
        <p><a href="javascript:alert(1)">危险链接</a> <a href="https://example.com">安全链接</a></p>
        <hr><script>document.body.innerHTML='pwn'</script>
        </body></html>
        """
        let url = try write(html, named: "sample.html")
        let result = try await HTMLImporter().importDocument(
            ImportRequest(url: url, baseDirectory: nil))

        XCTAssertTrue(result.markdown.contains("# 标题一"))
        XCTAssertTrue(result.markdown.contains("这是一段 **加粗** 与 *斜体*"))
        XCTAssertTrue(result.markdown.contains("**加粗**"))
        XCTAssertTrue(result.markdown.contains("*斜体*"))
        XCTAssertTrue(result.markdown.contains("~~删除~~"))
        XCTAssertTrue(result.markdown.contains("`x = 1`"))
        XCTAssertTrue(result.markdown.contains("- 项目 A"))
        XCTAssertTrue(result.markdown.contains("[x]"))
        XCTAssertTrue(result.markdown.contains("3. 第三步"))
        XCTAssertTrue(result.markdown.contains("| 列 A | 列 B |"))
        XCTAssertTrue(result.markdown.contains("---:"))
        XCTAssertTrue(result.markdown.contains("> 引用内容"))
        XCTAssertTrue(result.markdown.contains("```swift"))
        XCTAssertTrue(result.markdown.contains("https://example.com"))

        XCTAssertFalse(result.markdown.contains("javascript:"))
        XCTAssertFalse(result.markdown.contains("xss"))
        XCTAssertFalse(result.markdown.contains("pwn"))
        XCTAssertFalse(result.markdown.contains("color:red"))
    }

    func testHTMLRoundTripThroughParserDoesNotLoseBlocks() async throws {
        let url = try write("<h2>概述</h2><p>正文 <b>重点</b></p><ul><li>甲</li><li>乙</li></ul>",
                            named: "simple.html")
        let markdown = try await HTMLImporter().importDocument(
            ImportRequest(url: url, baseDirectory: nil)).markdown
        let model = MarkdownParser().parse(markdown)
        let kinds = model.blocks.map { block -> String in
            switch block {
            case .heading: return "heading"
            case .paragraph: return "paragraph"
            case .list: return "list"
            default: return "other"
            }
        }
        XCTAssertEqual(kinds, ["heading", "paragraph", "list"])
        let rendered = HTMLRenderer().render(model)
        XCTAssertTrue(rendered.contains("重点"))
        XCTAssertTrue(rendered.contains("<table") == false)
    }

    // MARK: - DOCX (round-trip through this project's own exporter)

    func testDOCXImportFromGeneratedDocument() async throws {
        let source = """
        # 项目说明

        包含 **加粗** 与 `代码`。

        | 名称 | 数量 |
        | :--- | ---: |
        | 苹果 | 12 |

        - 第一项
        - 第二项
        """
        let model = MarkdownParser().parse(source)
        let data = try DOCXExporter().export(
            model: model,
            options: DOCXOptions(baseDirectory: nil, documentTitle: "项目说明"))
        let url = try write(data, named: "generated.docx")
        let result = try await DOCXImporter().importDocument(
            ImportRequest(url: url, baseDirectory: nil))

        XCTAssertTrue(result.markdown.contains("# 项目说明"))
        XCTAssertTrue(result.markdown.contains("| 苹果 | 12 |"))
        XCTAssertTrue(result.markdown.contains("**加粗**"))
        XCTAssertTrue(result.markdown.contains("第一项"))
    }

    /// A hand-built WordprocessingML fixture exercises the paths a real Word
    /// file uses: pStyle headings, numPr lists, hyperlinks, tables and images.
    func testDOCXImportFromNativeWordStructure() async throws {
        let documentXML = """
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><w:body>
        <w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>二级标题</w:t></w:r></w:p>
        <w:p><w:r><w:t>普通段落 </w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>加粗</w:t></w:r><w:r><w:t> 结尾</w:t></w:r></w:p>
        <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>第一项</w:t></w:r></w:p>
        <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>第二项</w:t></w:r></w:p>
        <w:p><w:hyperlink r:id="rIdLink"><w:r><w:t>链接</w:t></w:r></w:hyperlink></w:p>
        <w:tbl><w:tr><w:tc><w:p><w:r><w:t>A</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>B</w:t></w:r></w:p></w:tc></w:tr><w:tr><w:tc><w:p><w:r><w:t>1</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>2</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        <w:p><w:r><w:drawing><a:blip r:embed="rIdImage"/></w:drawing></w:r></w:p>
        </w:body></w:document>
        """
        let entries: [ZIPWriter.Entry] = [
            .init(path: "word/document.xml", data: Data(documentXML.utf8)),
            .init(path: "word/styles.xml", data: Data("""
            <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:style w:styleId="Heading2"><w:name w:val="heading 2"/></w:style></w:styles>
            """.utf8)),
            .init(path: "word/numbering.xml", data: Data("""
            <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num></w:numbering>
            """.utf8)),
            .init(path: "word/_rels/document.xml.rels", data: Data("""
            <Relationships><Relationship Id="rIdLink" Target="https://example.com" TargetMode="External"/><Relationship Id="rIdImage" Target="media/image1.png"/></Relationships>
            """.utf8)),
            .init(path: "word/media/image1.png", data: Data([0x89, 0x50, 0x4E, 0x47]))
        ]
        let url = try write(ZIPWriter.archive(entries: entries), named: "native.docx")
        let result = try await DOCXImporter().importDocument(
            ImportRequest(url: url, baseDirectory: tempDirectory))

        XCTAssertTrue(result.markdown.contains("## 二级标题"))
        XCTAssertTrue(result.markdown.contains("**加粗**"))
        XCTAssertTrue(result.markdown.contains("1. 第一项"))
        XCTAssertTrue(result.markdown.contains("2. 第二项"))
        XCTAssertTrue(result.markdown.contains("[链接](https://example.com)"))
        XCTAssertTrue(result.markdown.contains("| A | B |"))
        XCTAssertTrue(result.markdown.contains("assets/image1.png"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDirectory.appendingPathComponent("assets/image1.png").path))
    }

    func testHTMLImportCopiesLocalImageIntoAssets() async throws {
        let image = tempDirectory.appendingPathComponent("pic.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        let url = try write("<p><img src=\"pic.png\" alt=\"示意图\"></p>", named: "with-image.html")
        let result = try await HTMLImporter().importDocument(
            ImportRequest(url: url, baseDirectory: tempDirectory))
        XCTAssertTrue(result.markdown.contains("assets/pic.png"))
        XCTAssertTrue(result.markdown.contains("![\u{793A}\u{610F}\u{56FE}]"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDirectory.appendingPathComponent("assets/pic.png").path))
    }

    // MARK: - XLSX (minimal OOXML fixture)

    func testXLSXImportBuildsGFMTable() async throws {
        let entries: [ZIPWriter.Entry] = [
            .init(path: "xl/workbook.xml", data: Data("""
            <workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="成绩" sheetId="1" r:id="rId1"/></sheets></workbook>
            """.utf8)),
            .init(path: "xl/_rels/workbook.xml.rels", data: Data("""
            <Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"/></Relationships>
            """.utf8)),
            .init(path: "xl/sharedStrings.xml", data: Data("""
            <sst><si><t>姓名</t></si><si><t>分数</t></si><si><t>张三</t></si></sst>
            """.utf8)),
            .init(path: "xl/worksheets/sheet1.xml", data: Data("""
            <worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row><row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>95</v></c></row></sheetData></worksheet>
            """.utf8))
        ]
        let url = try write(ZIPWriter.archive(entries: entries), named: "sample.xlsx")
        let result = try await XLSXImporter().importDocument(
            ImportRequest(url: url, baseDirectory: nil))

        XCTAssertTrue(result.markdown.contains("## 成绩"))
        XCTAssertTrue(result.markdown.contains("| 姓名 | 分数 |"))
        XCTAssertTrue(result.markdown.contains("| 张三 | 95 |"))
    }

    // MARK: - PDF (plain text + mandatory degradation warning)

    func testPDFImportWarnsAboutLayoutLoss() async throws {
        let html = HTMLDocumentBuilder.make(
            bodyHTML: "<h1>PDF 导入测试</h1><p>Hello PDF world 123</p>",
            options: HTMLDocumentBuilder.Options())
        let pdfData = try await PDFRenderer.render(html: html)
        let url = try write(pdfData, named: "sample.pdf")
        let result = try await PDFImporter().importDocument(
            ImportRequest(url: url, baseDirectory: nil))

        XCTAssertFalse(result.markdown.isEmpty)
        XCTAssertTrue(result.warnings.contains { $0.contains("仅提取纯文本") })
        XCTAssertTrue(result.markdown.contains("Hello") || result.markdown.contains("PDF"))
    }

    // MARK: - ZIP reader (deflate path)

    func testArchiveReadsDeflatedEntries() throws {
        let source = tempDirectory.appendingPathComponent("hello.txt")
        try "Hello deflate 中文".write(to: source, atomically: true, encoding: .utf8)
        let zipURL = tempDirectory.appendingPathComponent("probe.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-j", zipURL.path, source.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let archive = try OOXMLArchive(data: try Data(contentsOf: zipURL))
        let text = String(data: try archive.data(for: "hello.txt"), encoding: .utf8)
        XCTAssertEqual(text, "Hello deflate 中文")
    }

    // MARK: - Serializer & registry

    func testSerializerRoundTripPreservesBlockKinds() {
        let source = """
        # 标题

        段落 **强调** 与 `代码`。

        | A | B |
        | :--- | ---: |
        | 1 | 2 |

        - 甲
        - 乙

        > 引用
        """
        let original = MarkdownParser().parse(source)
        let text = MarkdownSerializer.serialize(original)
        let reparsed = MarkdownParser().parse(text)
        XCTAssertEqual(reparsed.blocks.count, original.blocks.count)
        guard case .heading(let level, _) = reparsed.blocks[0] else { return XCTFail("heading") }
        XCTAssertEqual(level, 1)
        XCTAssertTrue(reparsed.blocks.contains { if case .table = $0 { return true }; return false })
        XCTAssertTrue(reparsed.blocks.contains { if case .list = $0 { return true }; return false })
    }

    func testImportRegistryCoversFiveFamilies() {
        ImportRegistry.shared.bootstrap()
        let ids = Set(ImportRegistry.shared.formats.map { $0.id })
        XCTAssertEqual(ids, Set(["html", "docx", "xlsx", "pdf", "text"]))
        XCTAssertNil(ImportRegistry.shared.importer(forExtension: "doc"))
        XCTAssertNotNil(ImportRegistry.shared.importer(forExtension: "HTML"))
        XCTAssertNotNil(ImportRegistry.shared.importer(forExtension: "txt"))
        XCTAssertEqual(StandardImportFormats.pdf.note.contains("不还原排版"), true)
    }
}

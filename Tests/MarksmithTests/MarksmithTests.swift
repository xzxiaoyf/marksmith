import XCTest
@testable import Marksmith

final class MarkdownParserTests: XCTestCase {

    private let parser = MarkdownParser()

    func testATXAndSetextHeadings() {
        let model = parser.parse("# Title\n\nSubtitle\n--------\n\n### Third")
        XCTAssertEqual(model.blocks.count, 3)
        guard case .heading(let l1, let i1) = model.blocks[0] else { return XCTFail("h1") }
        XCTAssertEqual(l1, 1)
        XCTAssertEqual(InlineText.plain(i1), "Title")
        guard case .heading(let l2, _) = model.blocks[1] else { return XCTFail("h2") }
        XCTAssertEqual(l2, 2)
        guard case .heading(let l3, _) = model.blocks[2] else { return XCTFail("h3") }
        XCTAssertEqual(l3, 3)
    }

    func testFencedCodeKeepsContentAndLanguage() {
        let model = parser.parse("```swift\nlet x = 1 < 2\n```")
        guard case .codeBlock(let lang, let code) = model.blocks.first else { return XCTFail("code") }
        XCTAssertEqual(lang, "swift")
        XCTAssertEqual(code, "let x = 1 < 2")
        XCTAssertTrue(parser.html("```swift\nlet x = 1 < 2\n```").contains("&lt; 2"))
    }

    func testInlineEmphasisAndCode() {
        let nodes = InlineParser.parse("**bold** and *em* and `a*b` and ~~gone~~")
        let html = HTMLRenderer().renderInline(nodes)
        XCTAssertEqual(InlineText.plain(nodes), "bold and em and a*b and gone")
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<em>em</em>"))
        XCTAssertTrue(html.contains("<code>a*b</code>"))
        XCTAssertTrue(html.contains("<del>gone</del>"))
        XCTAssertFalse(html.contains("<code>a<em>b</em></code>"), "code spans must not be re-parsed")
    }

    func testLinkImageAndUnsafeURL() {
        let html = parser.html("[site](https://example.com \"t\") ![alt](pic.png) [bad](javascript:alert(1))")
        XCTAssertTrue(html.contains("href=\"https://example.com\""))
        XCTAssertTrue(html.contains("title=\"t\""))
        XCTAssertTrue(html.contains("<img src=\"pic.png\" alt=\"alt\">"))
        XCTAssertFalse(html.contains("javascript:"))
        XCTAssertTrue(html.contains("bad"))
    }

    func testRawHTMLIsNeutralised() {
        let html = parser.html("<script>alert('x')</script>\n\n<iframe src=\"x\"></iframe>")
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("<iframe"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    func testTaskListAndNestedList() {
        let model = parser.parse("- [x] done\n- [ ] todo\n  - nested\n- plain")
        guard case .list(let ordered, _, let items) = model.blocks.first else { return XCTFail("list") }
        XCTAssertFalse(ordered)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].isChecked, true)
        XCTAssertEqual(items[1].isChecked, false)
        XCTAssertNil(items[2].isChecked)
        XCTAssertEqual(items[1].blocks.count, 2, "nested list should be a second block")
    }

    func testTableWithAlignment() {
        let model = parser.parse("| A | B |\n| :-- | --: |\n| 1 | 2 |")
        guard case .table(let headers, let rows, let alignments) = model.blocks.first else { return XCTFail("table") }
        XCTAssertEqual(headers.count, 2)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(alignments, [.left, .right])
        XCTAssertTrue(parser.html("| A | B |\n| :-- | --: |\n| 1 | 2 |").contains("align=\"right\""))
    }

    func testBlockquoteAndThematicBreak() {
        let model = parser.parse("> quoted **text**\n\n---")
        XCTAssertEqual(model.blocks.count, 2)
        guard case .blockquote(let inner) = model.blocks[0] else { return XCTFail("quote") }
        XCTAssertEqual(inner.count, 1)
        guard case .thematicBreak = model.blocks[1] else { return XCTFail("hr") }
    }

    func testFrontMatterIsStripped() {
        let model = parser.parse("---\ntitle: Hello\nauthor: XY\n---\n\n# Body")
        XCTAssertEqual(model.frontMatter["title"], "Hello")
        XCTAssertEqual(model.frontMatter["author"], "XY")
        XCTAssertEqual(model.blocks.count, 1)
        XCTAssertFalse(parser.html("---\ntitle: X\n---\n\nBody").contains("title:"))
    }

    func testBOMAndCRLF() {
        let model = parser.parse("\u{FEFF}# Title\r\n\r\nLine\r\n")
        XCTAssertEqual(model.blocks.count, 2)
        guard case .heading(_, let inline) = model.blocks[0] else { return XCTFail("heading") }
        XCTAssertEqual(InlineText.plain(inline), "Title")
    }

    func testEscapingAndEntities() {
        let html = parser.html("AT&amp;T and 5 < 6 and \\*literal\\*")
        XCTAssertTrue(html.contains("AT&amp;T"))
        XCTAssertTrue(html.contains("5 &lt; 6"))
        XCTAssertTrue(html.contains("*literal*"))
        XCTAssertFalse(html.contains("<em>literal</em>"))
    }

    func testSlugGeneration() {
        let nodes = InlineParser.parse("Hello, 世界 & Code!")
        XCTAssertEqual(InlineText.slug(nodes), "hello-世界-code")
    }
}

final class ExportSupportTests: XCTestCase {

    func testJSStringLiteralIsSafe() {
        let literal = HTML.jsStringLiteral("a `b` ${c} \\ \"quote\" \u{2028}")
        XCTAssertTrue(literal.hasPrefix("\""))
        XCTAssertTrue(literal.hasSuffix("\""))
        XCTAssertTrue(literal.contains("\\u2028"))
        XCTAssertTrue(literal.contains("\\\"quote\\\""))
    }

    func testStandaloneHTMLContainsInlinedRuntime() {
        var options = HTMLDocumentBuilder.Options()
        options.embedScripts = true
        options.embedFonts = false
        let doc = HTMLDocumentBuilder.make(bodyHTML: "<p>hello</p>", options: options)
        XCTAssertTrue(doc.contains("updateContent"))
        XCTAssertTrue(doc.contains("hljs"))
        XCTAssertTrue(doc.contains("<p>hello</p>"))
    }

    func testPreviewResourcesArePresent() {
        XCTAssertNotNil(AppResources.url("preview.html"))
        XCTAssertNotNil(AppResources.url("preview-runtime.js"))
        XCTAssertNotNil(AppResources.url("vendor/mermaid/mermaid.min.js"))
    }

    func testDOCXPackageIsAValidZIP() throws {
        let markdown = """
        # Title

        A **bold** paragraph with a [link](https://example.com).

        | A | B |
        | -- | -- |
        | 1 | 2 |

        - [x] done
        - [ ] todo
        """
        let model = MarkdownParser().parse(markdown)
        let data = try DOCXExporter().export(model: model, options: DOCXOptions(documentTitle: "Test"))

        XCTAssertEqual(String(data: data.prefix(2), encoding: .ascii), "PK")
        let xml = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(xml.contains("word/document.xml"))
        XCTAssertTrue(xml.contains("[Content_Types].xml"))
        XCTAssertTrue(xml.contains("word/styles.xml"))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("marksmith-test-\(UUID().uuidString).docx")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-t", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "unzip -t output: \(output)")
        XCTAssertTrue(output.contains("No errors detected"))
    }

    func testZIPWriterRoundTripCRC() throws {
        let entries = [
            ZIPWriter.Entry(path: "a.txt", data: Data("hello".utf8)),
            ZIPWriter.Entry(path: "nested/b.txt", data: Data("world".utf8))
        ]
        let archive = ZIPWriter.archive(entries: entries)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("marksmith-zip-\(UUID().uuidString).zip")
        try archive.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-t", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

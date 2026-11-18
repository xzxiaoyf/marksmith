import XCTest
@testable import Marksmith

@MainActor
final class ExportRuntimeTests: XCTestCase {

    private let sample = """
    # 导出冒烟测试

    这是 **加粗** 与 `代码`，以及 [链接](https://example.com)。

    | 列 A | 列 B |
    | :--- | ---: |
    | 1 | 2 |

    - [x] 已完成
    - [ ] 待办

    ```mermaid
    graph LR
      A --> B
    ```

    公式 $x^2 + y^2 = z^2$
    """

    private func context() -> ExportContext {
        ExportContext.make(markdown: sample, title: "Smoke Test",
                           baseDirectory: nil, theme: .light)
    }

    func testHTMLExportIsSelfContained() async throws {
        let data = try await HTMLFileExporter().export(context: context())
        let html = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(html.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("data:font/woff2;base64,"), "KaTeX fonts must be inlined")
        XCTAssertTrue(html.contains("marksmithRenderDone"))
        XCTAssertFalse(html.contains("src=\"vendor/"), "no external script references allowed")
    }

    func testDOCXExportContainsNativeTable() async throws {
        let data = try await DOCXFileExporter().export(context: context())
        let raw = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(raw.contains("word/document.xml"))
        XCTAssertTrue(raw.contains("<w:tbl>"))
        XCTAssertTrue(raw.contains("Heading1"))
    }

    func testPDFExportProducesPDFHeader() async throws {
        let data = try await PDFFileExporter().export(context: context())
        XCTAssertGreaterThan(data.count, 1000)
        let prefix = String(decoding: data.prefix(4), as: UTF8.self)
        XCTAssertEqual(prefix, "%PDF")
    }
}

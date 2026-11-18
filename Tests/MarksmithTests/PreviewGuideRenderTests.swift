import XCTest
import WebKit
@testable import Marksmith

/// End-to-end check that the snippets offered by the 公式 / 流程图 buttons
/// really become KaTeX / Mermaid output in the actual preview shell — not just
/// plausible-looking HTML fragments.
@MainActor
final class PreviewGuideRenderTests: XCTestCase {

    func testInsertedTemplatesRenderInTheRealPreviewShell() async throws {
        guard let templateURL = AppResources.url("preview.html"),
              let root = AppResources.previewRoot else {
            XCTFail("preview.html / resource bundle missing")
            return
        }

        let source = [
            "行内公式 \(InsertTemplates.inlineMath.snippet)",
            InsertTemplates.summation.snippet,
            InsertTemplates.aligned.snippet,
            InsertTemplates.flowchartTD.snippet,
            InsertTemplates.sequenceDiagram.snippet
        ].joined(separator: "\n\n")
        let body = HTMLRenderer().render(MarkdownParser().parse(source))

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let loader = PreviewLoader()
        webView.navigationDelegate = loader
        await withCheckedContinuation { continuation in
            loader.onFinish = { continuation.resume() }
            webView.loadFileURL(templateURL, allowingReadAccessTo: root)
        }

        _ = try? await webView.evaluateJavaScript("window.updateContent(\(HTML.jsStringLiteral(body)))")

        var counts = (katex: 0, diagrams: 0)
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            let raw = await Self.evaluate(
                "String(document.querySelectorAll('.katex').length) + '|' + " +
                "String(document.querySelectorAll('.marksmith-mermaid svg').length)",
                in: webView)
            let parts = raw.split(separator: "|").map { Int($0) ?? 0 }
            if parts.count == 2 { counts = (parts[0], parts[1]) }
            if counts.katex >= 3, counts.diagrams >= 2 { break }
        }

        XCTAssertGreaterThanOrEqual(counts.katex, 3,
                                    "inline + two display formulas must render via KaTeX")
        XCTAssertGreaterThanOrEqual(counts.diagrams, 2,
                                    "flowchart + sequence diagram must render via Mermaid")
    }

    private static func evaluate(_ script: String, in webView: WKWebView) async -> String {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value as? String ?? "")
            }
        }
    }
}

private final class PreviewLoader: NSObject, WKNavigationDelegate {
    var onFinish: (() -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish?()
        onFinish = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onFinish?()
        onFinish = nil
    }
}

import SwiftUI
import WebKit
import AppKit

/// WKWebView preview. The shell HTML lives in the resource bundle; Swift only
/// injects rendered fragments through `updateContent()`.
struct PreviewWebView: NSViewRepresentable {
    let htmlBody: String
    let theme: ColorTheme

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let linkHandler = LinkMessageHandler()
        configuration.userContentController.add(linkHandler, name: "marksmithLink")
        context.coordinator.linkHandler = linkHandler

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false

        if let templateURL = AppResources.url("preview.html"),
           let root = AppResources.previewRoot {
            webView.loadFileURL(templateURL, allowingReadAccessTo: root)
        } else {
            webView.loadHTMLString(Self.fallbackHTML, baseURL: nil)
        }

        context.coordinator.pendingHTML = htmlBody
        context.coordinator.pendingTheme = theme
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.isLoaded else {
            coordinator.pendingHTML = htmlBody
            coordinator.pendingTheme = theme
            return
        }
        if coordinator.lastTheme != theme {
            coordinator.lastTheme = theme
            webView.evaluateJavaScript("window.setTheme && window.setTheme('\(theme.rawValue)')")
        }
        if coordinator.lastHTML != htmlBody {
            coordinator.lastHTML = htmlBody
            let literal = HTML.jsStringLiteral(htmlBody)
            webView.evaluateJavaScript("window.updateContent(\(literal))") { _, error in
                if let error { NSLog("[Marksmith] preview update failed: \(error.localizedDescription)") }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var isLoaded = false
        var pendingHTML: String?
        var pendingTheme: ColorTheme = .light
        var lastHTML: String?
        var lastTheme: ColorTheme?
        /// WKUserContentController does not retain handlers; keep it alive here.
        var linkHandler: LinkMessageHandler?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            if lastTheme != pendingTheme {
                lastTheme = pendingTheme
                webView.evaluateJavaScript("window.setTheme && window.setTheme('\(pendingTheme.rawValue)')")
            }
            if let html = pendingHTML {
                lastHTML = html
                let literal = HTML.jsStringLiteral(html)
                webView.evaluateJavaScript("window.updateContent(\(literal))")
                pendingHTML = nil
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            NSLog("[Marksmith] preview load failed: \(error.localizedDescription)")
        }
    }

    /// Minimal shell used only when the resource bundle is missing.
    private static let fallbackHTML = """
    <!DOCTYPE html><html><head><meta charset="utf-8">
    <style>
    body { font-family: -apple-system, "PingFang SC", sans-serif; line-height: 1.6;
           padding: 24px; max-width: 820px; margin: 0 auto; }
    pre { background: #f6f8fa; padding: 12px; border-radius: 6px; overflow: auto; }
    blockquote { border-left: 4px solid #ddd; padding-left: 14px; color: #666; }
    table { border-collapse: collapse; } th, td { border: 1px solid #ddd; padding: 6px 12px; }
    </style></head><body><div id="content"></div>
    <script>
    window.setTheme = function () {};
    window.updateContent = function (html) {
        var el = document.getElementById('content');
        if (el) { el.innerHTML = html; }
    };
    </script></body></html>
    """
}

/// Opens external links in the user's default browser instead of navigating
/// the preview away from the document.
final class LinkMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let value = message.body as? String,
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }
}

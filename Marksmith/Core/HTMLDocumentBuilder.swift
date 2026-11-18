import Foundation

enum ColorTheme: String, CaseIterable, Identifiable {
    case light, dark
    var id: String { rawValue }
}

/// Builds a complete, single-file HTML document used by HTML export and PDF
/// rendering. All CSS and (optionally) all JavaScript is inlined, so exported
/// files work offline with math, diagrams and code highlighting intact.
enum HTMLDocumentBuilder {

    struct Options {
        var theme: ColorTheme = .light
        var title: String = AppMetadata.displayName
        /// Inline KaTeX / highlight.js / Mermaid / the Marksmith runtime.
        var embedScripts: Bool = true
        /// Inline KaTeX font files as base64 data URIs.
        var embedFonts: Bool = true
    }

    static func make(bodyHTML: String, options: Options = Options()) -> String {
        let themeCSS = AppResources.string("preview-\(options.theme.rawValue).css")
            ?? "body { font-family: -apple-system, sans-serif; color: #24292f; background: #fff; }"
        let hljsCSS = AppResources.string("vendor/highlight/github\(options.theme == .dark ? "-dark" : "").min.css") ?? ""

        var head = """
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="\(HTML.attribute(AppMetadata.name + " " + AppMetadata.version))">
        <title>\(HTML.escape(options.title))</title>
        <style>
        \(themeCSS)
        \(hljsCSS)
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", Helvetica, Arial, sans-serif;
            line-height: 1.65;
            max-width: 820px;
            margin: 0 auto;
            padding: 24px 28px 60px;
            -webkit-font-smoothing: antialiased;
        }
        #content { overflow-wrap: break-word; }
        .marksmith-mermaid { text-align: center; margin: 1.2em 0; overflow-x: auto; }
        .marksmith-mermaid svg { max-width: 100%; height: auto; }
        @media print {
            body { max-width: none; padding: 0 12mm; }
            pre, blockquote, table, .marksmith-mermaid { break-inside: avoid; }
            h1, h2, h3, h4, h5, h6 { break-after: avoid; }
        }
        </style>
        """

        if options.embedScripts {
            let katexCSS = AppResources.string("vendor/katex/katex.min.css") ?? ""
            head += "\n<style>\n" + (options.embedFonts ? inlineFonts(katexCSS) : katexCSS) + "\n</style>\n"
            for path in ["vendor/katex/katex.min.js",
                         "vendor/katex/auto-render.min.js",
                         "vendor/highlight/highlight.min.js",
                         "vendor/mermaid/mermaid.min.js",
                         "preview-runtime.js"] {
                if let js = AppResources.string(path) {
                    head += "<script>\n" + escapeForScriptTag(js) + "\n</script>\n"
                }
            }
            head += """
            <script>
            document.addEventListener('DOMContentLoaded', function () {
                var el = document.getElementById('content');
                if (el && typeof window.updateContent === 'function') {
                    window.updateContent(el.innerHTML);
                }
            });
            </script>
            """
        }

        return """
        <!DOCTYPE html>
        <html lang="zh-CN">
        <head>
        \(head)
        </head>
        <body>
        <div id="content">
        \(bodyHTML)
        </div>
        </body>
        </html>
        """
    }

    // MARK: - Helpers

    private static func escapeForScriptTag(_ script: String) -> String {
        script.replacingOccurrences(of: "</script", with: "<\\/script", options: [.caseInsensitive])
    }

    /// Rewrites `url(fonts/...)`
    /// inside KaTeX CSS into data URIs so the exported file is self-contained.
    private static func inlineFonts(_ css: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "url\\(fonts/([^)]+)\\)", options: []) else {
            return css
        }
        let nsRange = NSRange(css.startIndex..<css.endIndex, in: css)
        var result = css
        // Iterate in reverse so replacement ranges stay valid.
        let matches = regex.matches(in: css, options: [], range: nsRange)
        for match in matches.reversed() {
            guard let nameRange = Range(match.range(at: 1), in: css),
                  let fullRange = Range(match.range, in: css) else { continue }
            let name = String(css[nameRange])
            guard let data = AppResources.data("vendor/katex/fonts/" + name) else { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            let mime: String
            switch ext {
            case "woff2": mime = "font/woff2"
            case "woff": mime = "font/woff"
            default: mime = "font/ttf"
            }
            result.replaceSubrange(fullRange,
                                   with: "url(data:\(mime);base64,\(data.base64EncodedString()))")
        }
        return result
    }
}

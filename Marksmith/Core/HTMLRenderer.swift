import Foundation

struct HTMLRenderOptions {
    /// Folder of the source document; relative image paths resolve from here.
    var baseDirectory: URL?
    /// Inline local images as data URIs (makes preview/export self-contained).
    var embedLocalImages: Bool = true
}

/// Renders the shared AST into an HTML fragment consumed by the preview,
/// standalone HTML export and PDF export.
struct HTMLRenderer {
    var options: HTMLRenderOptions

    init(options: HTMLRenderOptions = HTMLRenderOptions()) {
        self.options = options
    }

    func render(_ model: MarkdownModel) -> String {
        renderBlocks(model.blocks)
    }

    // MARK: - Blocks

    func renderBlocks(_ blocks: [BlockNode]) -> String {
        blocks.map(renderBlock).joined(separator: "\n")
    }

    func renderBlock(_ block: BlockNode) -> String {
        switch block {
        case .heading(let level, let inline):
            let id = HTML.attribute(InlineText.slug(inline))
            return "<h\(level) id=\"\(id)\">\(renderInline(inline))</h\(level)>"

        case .paragraph(let inline):
            return "<p>\(renderInline(inline))</p>"

        case .codeBlock(let language, let code):
            let lang = (language ?? "").trimmingCharacters(in: .whitespaces)
            let classAttr = lang.isEmpty ? "" : " class=\"language-\(HTML.attribute(lang))\""
            return "<pre><code\(classAttr)>\(HTML.escape(code))</code></pre>"

        case .blockquote(let children):
            return "<blockquote>\n\(renderBlocks(children))\n</blockquote>"

        case .list(let ordered, let start, let items):
            let hasTasks = items.contains { $0.isChecked != nil }
            let tag = ordered ? "ol" : "ul"
            let startAttr = (ordered && start != 1) ? " start=\"\(start)\"" : ""
            let classAttr = (!ordered && hasTasks) ? " class=\"contains-task-list\"" : ""
            let body = items.map { item in
                var content = ""
                if let checked = item.isChecked {
                    content += "<input type=\"checkbox\" disabled\(checked ? " checked" : "")> "
                }
                if item.blocks.count == 1, case .paragraph(let inline) = item.blocks[0] {
                    content += renderInline(inline)
                } else {
                    content += renderBlocks(item.blocks)
                }
                return "<li>\(content)</li>"
            }.joined(separator: "\n")
            return "<\(tag)\(startAttr)\(classAttr)>\n\(body)\n</\(tag)>"

        case .table(let headers, let rows, let alignments):
            var html = "<table>\n<thead>\n<tr>"
            for (index, cell) in headers.enumerated() {
                html += "<th\(alignAttribute(alignments, index))>\(renderInline(cell))</th>"
            }
            html += "</tr>\n</thead>\n"
            if !rows.isEmpty {
                html += "<tbody>\n"
                for row in rows {
                    html += "<tr>"
                    for (index, cell) in row.enumerated() {
                        html += "<td\(alignAttribute(alignments, index))>\(renderInline(cell))</td>"
                    }
                    html += "</tr>\n"
                }
                html += "</tbody>\n"
            }
            html += "</table>"
            return html

        case .thematicBreak:
            return "<hr>"

        case .rawHTML(let text):
            return "<p>\(HTML.escape(text))</p>"
        }
    }

    private func alignAttribute(_ alignments: [TableAlignment], _ index: Int) -> String {
        guard index < alignments.count else { return "" }
        switch alignments[index] {
        case .none: return ""
        case .left: return " align=\"left\""
        case .center: return " align=\"center\""
        case .right: return " align=\"right\""
        }
    }

    // MARK: - Inline

    func renderInline(_ nodes: [InlineNode]) -> String {
        nodes.map(renderInline).joined()
    }

    func renderInline(_ node: InlineNode) -> String {
        switch node {
        case .text(let text):
            return HTML.escape(text)

        case .strong(let children):
            return "<strong>\(renderInline(children))</strong>"

        case .emphasis(let children):
            return "<em>\(renderInline(children))</em>"

        case .strikethrough(let children):
            return "<del>\(renderInline(children))</del>"

        case .code(let code):
            return "<code>\(HTML.escape(code))</code>"

        case .link(let children, let destination, let title):
            guard let safe = URLPolicy.linkDestination(destination) else {
                return renderInline(children)
            }
            let titleAttr = title.map { " title=\"\(HTML.attribute($0))\"" } ?? ""
            return "<a href=\"\(HTML.attribute(safe))\"\(titleAttr) rel=\"noopener noreferrer\">\(renderInline(children))</a>"

        case .image(let alt, let destination, let title):
            guard let safe = URLPolicy.imageDestination(destination) else {
                return "<span>\(HTML.escape(alt))</span>"
            }
            let resolved = options.embedLocalImages
                ? ImageResolver.resolve(safe, baseDirectory: options.baseDirectory)
                : safe
            // A broken local path used to render as an unexplained empty box.
            // Mark it so the preview can show a dashed placeholder + tooltip.
            let missing = options.embedLocalImages && resolved == safe &&
                ImageResolver.isMissingLocalImage(safe, baseDirectory: options.baseDirectory)
            let titleValue = title ?? (missing ? "图片未找到：\(safe)" : nil)
            let titleAttr = titleValue.map { " title=\"\(HTML.attribute($0))\"" } ?? ""
            let missingAttr = missing ? " data-marksmith-missing=\"1\"" : ""
            return "<img src=\"\(HTML.attribute(resolved))\" alt=\"\(HTML.attribute(alt))\"\(titleAttr)\(missingAttr)>"

        case .hardBreak:
            return "<br>\n"

        case .softBreak:
            return "\n"
        }
    }
}

// MARK: - Convenience

extension MarkdownParser {
    /// Parses and renders in one call.
    func html(_ source: String, options: HTMLRenderOptions = HTMLRenderOptions()) -> String {
        HTMLRenderer(options: options).render(parse(source))
    }
}

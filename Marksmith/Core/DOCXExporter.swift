import Foundation
import AppKit

struct DOCXOptions {
    var baseDirectory: URL?
    var documentTitle: String = "Marksmith Document"
}

enum DOCXError: LocalizedError {
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .encodingFailed: return "DOCX 内容无法编码为 UTF-8。"
        }
    }
}

/// Builds a native OOXML (.docx) package directly from the shared AST.
/// This produces real Word paragraphs, tables and inline images, rather than
/// relying on `NSAttributedString`'s lossy HTML → RTF → OOXML conversion.
struct DOCXExporter {

    func export(model: MarkdownModel, options: DOCXOptions = DOCXOptions()) throws -> Data {
        var builder = BodyBuilder(baseDirectory: options.baseDirectory)
        let body = builder.render(model.blocks, indent: 0, quoteDepth: 0)
        let title = model.frontMatter["title"] ?? options.documentTitle
        return try package(body: body, images: builder.images, title: title)
    }

    // MARK: - Run model

    private struct StyledRun: Equatable {
        var text: String = ""
        var bold = false
        var italic = false
        var strike = false
        var code = false
        var link: String?
        var color: String?
        var hardBreak = false
    }

    private enum Chunk {
        case run(StyledRun)
        case image(String)
        case lineBreak
    }

    private enum ParagraphStyle {
        case normal
        case heading(Int)
        case code
        case quote
        case listItem(depth: Int, bullet: String?)
        case rule
    }

    private struct EmbeddedImage {
        let data: Data
        let relationshipID: String
        let fileName: String
        let contentType: String
    }

    // MARK: - Body builder

    private struct BodyBuilder {
        let baseDirectory: URL?
        var images: [EmbeddedImage] = []

        mutating func render(_ blocks: [BlockNode], indent: Int, quoteDepth: Int) -> String {
            blocks.map { render($0, indent: indent, quoteDepth: quoteDepth) }.joined()
        }

        mutating func render(_ block: BlockNode, indent: Int, quoteDepth: Int) -> String {
            switch block {
            case .heading(let level, let inline):
                return paragraphs(from: flatten(inline), style: .heading(level), indent: indent, quoteDepth: quoteDepth)

            case .paragraph(let inline):
                return paragraphs(from: flatten(inline), style: .normal, indent: indent, quoteDepth: quoteDepth)

            case .codeBlock(_, let code):
                let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                return lines.map { line in
                    let run = StyledRun(text: line, code: true)
                    return paragraphXML([run], style: .code, indent: indent + 360, quoteDepth: quoteDepth)
                }.joined()

            case .blockquote(let children):
                return render(children, indent: indent + 420, quoteDepth: quoteDepth + 1)

            case .list(let ordered, let start, let items):
                var result = ""
                for (index, item) in items.enumerated() {
                    let bullet: String? = {
                        if let checked = item.isChecked { return checked ? "☑ " : "☐ " }
                        return ordered ? "\(start + index). " : "• "
                    }()
                    for (blockIndex, child) in item.blocks.enumerated() {
                        switch child {
                        case .paragraph(let inline):
                            let prefix = (blockIndex == 0) ? bullet : nil
                            result += paragraphs(from: flatten(inline),
                                                 style: .listItem(depth: indent / 360, bullet: prefix),
                                                 indent: indent + 360,
                                                 quoteDepth: quoteDepth)
                        case .list:
                            result += render(child, indent: indent + 360, quoteDepth: quoteDepth)
                        default:
                            result += render(child, indent: indent + 360, quoteDepth: quoteDepth)
                        }
                    }
                }
                return result

            case .table(let headers, let rows, let alignments):
                return tableXML(headers: headers, rows: rows, alignments: alignments)

            case .thematicBreak:
                return paragraphXML([], style: .rule, indent: indent, quoteDepth: quoteDepth)

            case .rawHTML(let text):
                return paragraphXML([StyledRun(text: text, code: true)],
                                    style: .normal, indent: indent, quoteDepth: quoteDepth)
            }
        }

        // MARK: Flattening

        private func flatten(_ nodes: [InlineNode], inherited: StyledRun = StyledRun()) -> [Chunk] {
            var chunks: [Chunk] = []
            for node in nodes {
                switch node {
                case .text(let text):
                    var run = inherited
                    run.text = text
                    chunks.append(.run(run))

                case .strong(let children):
                    var run = inherited; run.bold = true
                    chunks += flatten(children, inherited: run)

                case .emphasis(let children):
                    var run = inherited; run.italic = true
                    chunks += flatten(children, inherited: run)

                case .strikethrough(let children):
                    var run = inherited; run.strike = true
                    chunks += flatten(children, inherited: run)

                case .code(let code):
                    var run = inherited; run.text = code; run.code = true
                    chunks.append(.run(run))

                case .link(let children, let destination, _):
                    var run = inherited
                    run.link = URLPolicy.linkDestination(destination)
                    chunks += flatten(children, inherited: run)

                case .image(_, let destination, _):
                    chunks.append(.image(URLPolicy.imageDestination(destination) ?? ""))

                case .hardBreak, .softBreak:
                    chunks.append(.lineBreak)
                }
            }
            return mergeRuns(chunks)
        }

        private func mergeRuns(_ chunks: [Chunk]) -> [Chunk] {
            var result: [Chunk] = []
            for chunk in chunks {
                if case .run(let run) = chunk,
                   case .run(let last)? = result.last,
                   last.bold == run.bold, last.italic == run.italic,
                   last.strike == run.strike, last.code == run.code,
                   last.link == run.link, last.color == run.color,
                   !last.hardBreak, !run.hardBreak {
                    var merged = last
                    merged.text += run.text
                    result[result.count - 1] = .run(merged)
                } else {
                    result.append(chunk)
                }
            }
            return result
        }

        // MARK: Paragraph generation

        private mutating func paragraphs(from chunks: [Chunk],
                                        style: ParagraphStyle,
                                        indent: Int,
                                        quoteDepth: Int) -> String {
            var result = ""
            var pending: [StyledRun] = []

            func flush() {
                guard !pending.isEmpty else { return }
                if case .listItem(_, let bullet?) = style {
                    let prefix = StyledRun(text: bullet)
                    result += paragraphXML([prefix] + pending, style: style, indent: indent, quoteDepth: quoteDepth)
                } else {
                    result += paragraphXML(pending, style: style, indent: indent, quoteDepth: quoteDepth)
                }
                pending = []
            }

            for chunk in chunks {
                switch chunk {
                case .run(let run):
                    pending.append(run)
                case .lineBreak:
                    var run = StyledRun()
                    run.hardBreak = true
                    pending.append(run)
                case .image(let source):
                    flush()
                    result += imageParagraph(source, indent: indent)
                }
            }
            flush()
            if case .listItem(_, let bullet?) = style, result.isEmpty {
                result = paragraphXML([StyledRun(text: bullet)], style: style,
                                      indent: indent, quoteDepth: quoteDepth)
            }
            return result
        }

        private func paragraphXML(_ runs: [StyledRun],
                                  style: ParagraphStyle,
                                  indent: Int,
                                  quoteDepth: Int) -> String {
            var pPr = ""
            switch style {
            case .heading(let level):
                pPr += "<w:pStyle w:val=\"Heading\(min(max(level, 1), 6))\"/>"
                pPr += "<w:keepNext/><w:spacing w:before=\"240\" w:after=\"120\"/>"
            case .normal:
                pPr += "<w:spacing w:after=\"120\"/>"
            case .code:
                pPr += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F3F4F6\"/>"
                pPr += "<w:spacing w:after=\"0\"/>"
            case .quote:
                pPr += "<w:spacing w:after=\"120\"/>"
            case .listItem:
                pPr += "<w:spacing w:after=\"60\"/>"
            case .rule:
                pPr += "<w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"D0D7DE\"/></w:pBdr>"
            }
            if indent > 0 {
                pPr += "<w:ind w:left=\"\(indent)\"/>"
            }
            if quoteDepth > 0 {
                pPr += "<w:pBdr><w:left w:val=\"single\" w:sz=\"18\" w:space=\"8\" w:color=\"C8CDD2\"/></w:pBdr>"
            }
            return "<w:p><w:pPr>\(pPr)</w:pPr>" + runs.map(runXML).joined() + "</w:p>"
        }

        private func runXML(_ run: StyledRun) -> String {
            var rPr = ""
            if run.code {
                rPr += "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\" w:eastAsia=\"PingFang SC\"/>"
                rPr += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"EEF0F2\"/>"
            } else {
                rPr += "<w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\" w:eastAsia=\"PingFang SC\"/>"
            }
            if run.bold { rPr += "<w:b/>" }
            if run.italic { rPr += "<w:i/>" }
            if run.strike { rPr += "<w:strike/>" }
            if let color = run.color { rPr += "<w:color w:val=\"\(color)\"/>" }
            if let link = run.link { rPr += "<w:rStyle w:val=\"Hyperlink\"/><w:color w:val=\"0563C1\"/><w:u w:val=\"single\"/>"; _ = link }
            let properties = rPr.isEmpty ? "" : "<w:rPr>\(rPr)</w:rPr>"
            if run.hardBreak { return "<w:r>\(properties)<w:br/></w:r>" }
            let text = HTML.xml(run.text)
            return "<w:r>\(properties)<w:t xml:space=\"preserve\">\(text)</w:t></w:r>"
        }

        // MARK: Tables

        private func tableXML(headers: [[InlineNode]],
                              rows: [[[InlineNode]]],
                              alignments: [TableAlignment]) -> String {
            let columnCount = max(headers.count, rows.first?.count ?? 1, 1)
            let width = 9360 / columnCount
            var xml = """
            <w:tbl>
              <w:tblPr>
                <w:tblW w:w="5000" w:type="pct"/>
                <w:tblBorders>
                  <w:top w:val="single" w:sz="4" w:color="BFBFBF"/>
                  <w:left w:val="single" w:sz="4" w:color="BFBFBF"/>
                  <w:bottom w:val="single" w:sz="4" w:color="BFBFBF"/>
                  <w:right w:val="single" w:sz="4" w:color="BFBFBF"/>
                  <w:insideH w:val="single" w:sz="4" w:color="BFBFBF"/>
                  <w:insideV w:val="single" w:sz="4" w:color="BFBFBF"/>
                </w:tblBorders>
              </w:tblPr>
              <w:tblGrid>
            """
            for _ in 0..<columnCount { xml += "<w:gridCol w:w=\"\(width)\"/>" }
            xml += "</w:tblGrid>"

            func cell(_ nodes: [InlineNode], header: Bool, index: Int) -> String {
                let text = InlineText.plain(nodes)
                var run = StyledRun(text: text)
                run.bold = header
                let align = index < alignments.count ? alignments[index] : .none
                let jc: String
                switch align {
                case .center: jc = "<w:jc w:val=\"center\"/>"
                case .right: jc = "<w:jc w:val=\"right\"/>"
                default: jc = ""
                }
                let shading = header ? "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F3F5\"/>" : ""
                return """
                <w:tc><w:tcPr><w:tcW w:w="\(width)" w:type="dxa"/>\(shading)</w:tcPr>
                <w:p><w:pPr>\(jc)</w:pPr>\(runXML(run))</w:p></w:tc>
                """
            }

            if !headers.isEmpty {
                xml += "<w:tr><w:trPr><w:tblHeader/></w:trPr>"
                for (index, node) in headers.enumerated() { xml += cell(node, header: true, index: index) }
                xml += "</w:tr>"
            }
            for row in rows {
                xml += "<w:tr>"
                for (index, node) in row.enumerated() { xml += cell(node, header: false, index: index) }
                xml += "</w:tr>"
            }
            xml += "</w:tbl><w:p/>"
            return xml
        }

        // MARK: Images

        private mutating func imageParagraph(_ source: String, indent: Int) -> String {
            guard let (data, contentType) = ImageResolver.localImageData(source, baseDirectory: baseDirectory) else {
                return paragraphXML([StyledRun(text: "[图片: \(source)]")],
                                    style: .normal, indent: indent, quoteDepth: 0)
            }
            let pixels = ImageResolver.pixelSize(of: data) ?? (width: 480, height: 320)
            let emuPerPixel = 9525
            let maximumWidth = 5_943_600
            var cx = pixels.width * emuPerPixel
            var cy = pixels.height * emuPerPixel
            if cx > maximumWidth {
                cy = max(1, cy * maximumWidth / max(cx, 1))
                cx = maximumWidth
            }
            let ext = contentType == "image/jpeg" ? "jpg" :
                      contentType == "image/gif" ? "gif" :
                      contentType == "image/bmp" ? "bmp" : "png"
            let number = images.count + 1
            let rId = "rIdImg\(number)"
            let fileName = "image\(number).\(ext)"
            images.append(EmbeddedImage(data: data, relationshipID: rId,
                                        fileName: fileName, contentType: contentType))
            let id = 1000 + number

            let drawing = """
            <w:r><w:drawing>
              <wp:inline distT="0" distB="0" distL="0" distR="0">
                <wp:extent cx="\(cx)" cy="\(cy)"/>
                <wp:docPr id="\(id)" name="Marksmith Image \(number)"/>
                <a:graphic>
                  <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
                    <pic:pic>
                      <pic:nvPicPr><pic:cNvPr id="0" name="\(fileName)"/><pic:cNvPicPr/></pic:nvPicPr>
                      <pic:blipFill><a:blip r:embed="\(rId)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>
                      <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm>
                        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>
                    </pic:pic>
                  </a:graphicData>
                </a:graphic>
              </wp:inline>
            </w:drawing></w:r>
            """
            return "<w:p><w:pPr><w:ind w:left=\"\(indent)\"/></w:pPr>\(drawing)</w:p>"
        }
    }

    // MARK: - OOXML package

    private func package(body: String, images: [EmbeddedImage], title: String) throws -> Data {
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
                    xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
                    xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                    xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
          <w:body>
            \(body)
            <w:sectPr>
              <w:pgSz w:w="12240" w:h="15840"/>
              <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"
                       w:header="720" w:footer="720" w:gutter="0"/>
            </w:sectPr>
          </w:body>
        </w:document>
        """

        let contentTypes = contentTypesXML(images: images)
        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1"
            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
            Target="word/document.xml"/>
          <Relationship Id="rId2"
            Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties"
            Target="docProps/core.xml"/>
          <Relationship Id="rId3"
            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties"
            Target="docProps/app.xml"/>
        </Relationships>
        """

        var documentRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rIdStyles"
            Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"
            Target="styles.xml"/>
        """
        for image in images {
            documentRels += """
            <Relationship Id="\(image.relationshipID)"
              Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
              Target="media/\(image.fileName)"/>
            """
        }
        documentRels += "</Relationships>"

        let core = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:dcterms="http://purl.org/dc/terms/"
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <dc:title>\(HTML.xml(title))</dc:title>
          <dc:creator>Marksmith</dc:creator>
          <cp:lastModifiedBy>Marksmith</cp:lastModifiedBy>
          <dcterms:created xsi:type="dcterms:W3CDTF">\(isoTimestamp())</dcterms:created>
          <dcterms:modified xsi:type="dcterms:W3CDTF">\(isoTimestamp())</dcterms:modified>
        </cp:coreProperties>
        """

        let app = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">
          <Application>Marksmith</Application>
          <AppVersion>\(AppMetadata.version)</AppVersion>
        </Properties>
        """

        var entries: [ZIPWriter.Entry] = [
            .init(path: "[Content_Types].xml", data: Data(contentTypes.utf8)),
            .init(path: "_rels/.rels", data: Data(rootRels.utf8)),
            .init(path: "word/document.xml", data: Data(document.utf8)),
            .init(path: "word/_rels/document.xml.rels", data: Data(documentRels.utf8)),
            .init(path: "word/styles.xml", data: Data(stylesXML().utf8)),
            .init(path: "docProps/core.xml", data: Data(core.utf8)),
            .init(path: "docProps/app.xml", data: Data(app.utf8))
        ]
        for image in images {
            entries.append(.init(path: "word/media/" + image.fileName, data: image.data))
        }
        guard entries.allSatisfy({ !$0.data.isEmpty }) else { throw DOCXError.encodingFailed }
        return ZIPWriter.archive(entries: entries)
    }

    private func contentTypesXML(images: [EmbeddedImage]) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
        """
        var seen = Set<String>()
        for image in images {
            let ext = (image.fileName as NSString).pathExtension
            guard !seen.contains(ext) else { continue }
            seen.insert(ext)
            xml += "<Default Extension=\"\(ext)\" ContentType=\"\(image.contentType)\"/>"
        }
        xml += """
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
          <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
          <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
          <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
        </Types>
        """
        return xml
    }

    private func stylesXML() -> String {
        var styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:docDefaults><w:rPrDefault><w:rPr>
            <w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="PingFang SC"/>
            <w:sz w:val="22"/>
          </w:rPr></w:rPrDefault></w:docDefaults>
          <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
            <w:name w:val="Normal"/><w:qFormat/>
          </w:style>
          <w:style w:type="character" w:styleId="Hyperlink">
            <w:name w:val="Hyperlink"/><w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr>
          </w:style>
        """
        let sizes = [32, 28, 25, 23, 22, 21]
        for level in 1...6 {
            styles += """
            <w:style w:type="paragraph" w:styleId="Heading\(level)">
              <w:name w:val="heading \(level)"/>
              <w:basedOn w:val="Normal"/><w:qFormat/>
              <w:pPr><w:outlineLvl w:val="\(level - 1)"/></w:pPr>
              <w:rPr><w:b/><w:color w:val="1F2328"/><w:sz w:val="\(sizes[level - 1])"/></w:rPr>
            </w:style>
            """
        }
        styles += "</w:styles>"
        return styles
    }

    private func isoTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}

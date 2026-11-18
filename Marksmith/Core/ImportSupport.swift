import Foundation
import AppKit

// MARK: - Tiny XML DOM (shared by DOCX and XLSX importers)
//
// Foundation's `XMLParser` is SAX-based; the importers need random access to
// paragraphs, rows and cells, so this builds a minimal tree first. Namespace
// prefixes are preserved in `name` but matching is prefix-insensitive.

final class XMLNode {
    let name: String
    var attributes: [String: String] = [:]
    var text = ""
    var children: [XMLNode] = []
    weak var parent: XMLNode?

    init(name: String) { self.name = name }

    var localName: String {
        name.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init) ?? name
    }

    func isNamed(_ candidate: String) -> Bool {
        name == candidate || localName == candidate
    }

    func attr(_ key: String) -> String? {
        if let exact = attributes[key] { return exact }
        let wanted = key.split(separator: ":").last.map(String.init) ?? key
        for (candidate, value) in attributes where
            candidate.split(separator: ":").last.map(String.init) == wanted {
            return value
        }
        return nil
    }

    func children(named name: String) -> [XMLNode] {
        children.filter { $0.isNamed(name) }
    }

    func firstChild(named name: String) -> XMLNode? {
        children.first { $0.isNamed(name) }
    }

    func descendants(named name: String) -> [XMLNode] {
        var result: [XMLNode] = []
        for child in children {
            if child.isNamed(name) { result.append(child) }
            result.append(contentsOf: child.descendants(named: name))
        }
        return result
    }

    /// All text below this node in document order. OOXML splits a paragraph
    /// into many `w:r`/`w:t` runs, so this is the normal way to read a value.
    var combinedText: String {
        var out = text
        for child in children { out += child.combinedText }
        return out
    }
}

private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    let root = XMLNode(name: "#document")
    private var stack: [XMLNode]

    override init() {
        stack = [root]
        super.init()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let node = XMLNode(name: qName ?? elementName)
        node.attributes = attributeDict
        node.parent = stack.last
        stack.last?.children.append(node)
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if stack.count > 1 { stack.removeLast() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) {
            stack.last?.text += string
        }
    }
}

enum XMLTree {
    static func parse(_ data: Data) throws -> XMLNode {
        let parser = XMLParser(data: data)
        let builder = XMLTreeBuilder()
        parser.delegate = builder
        guard parser.parse() else {
            throw ImportError.unreadable("XML 解析失败：\(parser.parserError?.localizedDescription ?? "未知错误")")
        }
        return builder.root
    }
}

// MARK: - Image assets extracted from imported documents

enum ImportAssets {

    /// Returns a Markdown image destination. When the current document has a
    /// folder, the binary is written to `assets/`; unsaved documents fall back
    /// to an inline `data:` URI so the image is never silently lost.
    static func store(data: Data, suggestedName: String, baseDirectory: URL?) -> (String, String?) {
        let mime = mimeType(for: suggestedName)
        let cleaned = safeFileName(suggestedName, mime: mime)

        if let baseDirectory {
            let directory = baseDirectory.appendingPathComponent("assets", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory,
                                                        withIntermediateDirectories: true)
                var destination = directory.appendingPathComponent(cleaned)
                var suffix = 1
                while FileManager.default.fileExists(atPath: destination.path) {
                    let ext = destination.pathExtension
                    let stem = destination.deletingPathExtension().lastPathComponent
                    destination = directory.appendingPathComponent("\(stem)-\(suffix).\(ext)")
                    suffix += 1
                }
                try data.write(to: destination, options: .atomic)
                return ("assets/" + destination.lastPathComponent, nil)
            } catch {
                return (dataURI(data, mime: mime),
                        "图片「\(cleaned)」无法写入 assets/（\(error.localizedDescription)），已内联为 data URI。")
            }
        }
        return (dataURI(data, mime: mime),
                "当前文档尚未保存，导入的图片已内联为 data URI；保存后可改用「插入图片」写入 assets/。")
    }

    static func dataURI(_ data: Data, mime: String) -> String {
        "data:\(mime);base64,\(data.base64EncodedString())"
    }

    static func mimeType(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "svg": return "image/svg+xml"
        case "tif", "tiff": return "image/tiff"
        default: return "image/png"
        }
    }

    private static func safeFileName(_ name: String, mime: String) -> String {
        let raw = (name as NSString).lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        var cleaned = ""
        for ch in raw where ch.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            cleaned.append(ch)
        }
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            cleaned = "imported-\(UUID().uuidString.prefix(8))"
        }
        let ext = (cleaned as NSString).pathExtension
        if ext.isEmpty {
            let fallback = mime == "image/jpeg" ? "jpg" : "png"
            cleaned += "." + fallback
        }
        return cleaned
    }
}

// MARK: - Shared import errors

enum ImportError: LocalizedError {
    case unreadable(String)
    case unsupported(String)
    case emptyDocument(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let detail): return "无法读取文件：\(detail)"
        case .unsupported(let detail): return detail
        case .emptyDocument(let detail): return detail
        }
    }
}

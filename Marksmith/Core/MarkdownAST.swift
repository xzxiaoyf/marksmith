import Foundation

// MARK: - Inline AST

/// A node in the inline (within-a-paragraph) syntax tree.
/// `Equatable` conformance makes the parser straightforward to unit-test.
indirect enum InlineNode: Equatable {
    case text(String)
    case strong([InlineNode])
    case emphasis([InlineNode])
    case strikethrough([InlineNode])
    case code(String)
    case link([InlineNode], destination: String, title: String?)
    case image(alt: String, destination: String, title: String?)
    case hardBreak
    case softBreak
}

enum TableAlignment: Equatable {
    case none, left, center, right
}

struct ListItem: Equatable {
    var blocks: [BlockNode]
    /// `nil` = ordinary item, `.some(true/false)` = GFM task-list item.
    var isChecked: Bool?
}

// MARK: - Block AST

indirect enum BlockNode: Equatable {
    case heading(level: Int, inline: [InlineNode])
    case paragraph([InlineNode])
    case codeBlock(language: String?, code: String)
    case blockquote([BlockNode])
    case list(ordered: Bool, start: Int, items: [ListItem])
    case table(headers: [[InlineNode]], rows: [[[InlineNode]]], alignments: [TableAlignment])
    case thematicBreak
    /// Raw HTML is never emitted as markup; it is kept as text for safe display.
    case rawHTML(String)
}

/// The single intermediate representation consumed by every renderer
/// (preview HTML, standalone HTML, PDF and DOCX).
struct MarkdownModel: Equatable {
    var frontMatter: [String: String] = [:]
    var blocks: [BlockNode] = []
}

// MARK: - Inline helpers

enum InlineText {

    /// Flattens inline nodes into plain text, used for heading anchors,
    /// table-of-contents entries and Word export.
    static func plain(_ nodes: [InlineNode]) -> String {
        nodes.map { plain($0) }.joined()
    }

    static func plain(_ node: InlineNode) -> String {
        switch node {
        case .text(let s): return s
        case .strong(let c), .emphasis(let c), .strikethrough(let c), .link(let c, _, _):
            return plain(c)
        case .code(let s): return s
        case .image(let alt, _, _): return alt
        case .hardBreak, .softBreak: return " "
        }
    }

    /// Generates a stable, URL-safe anchor for a heading.
    static func slug(_ nodes: [InlineNode]) -> String {
        let raw = plain(nodes)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        var lastWasDash = false
        for ch in raw {
            if ch.isLetter || ch.isNumber {
                result.append(ch)
                lastWasDash = false
            } else if ch == "-" || ch == "_" || ch == " " || ch == "\n" || ch == "\t" {
                if !lastWasDash && !result.isEmpty {
                    result.append("-")
                    lastWasDash = true
                }
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

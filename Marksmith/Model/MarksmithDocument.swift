import SwiftUI
import UniformTypeIdentifiers
import Combine

/// Document model for SwiftUI's `DocumentGroup`.
/// A single published string is the source of truth; the AST is always derived
/// from it, never stored, which keeps undo/save semantics simple.
final class MarksmithDocument: ReferenceFileDocument, ObservableObject {

    @Published var text: String

    static var readableContentTypes: [UTType] {
        var types: [UTType] = [.plainText, .text]
        if let md = UTType(AppMetadata.editorUTI) { types.append(md) }
        for ext in ["md", "markdown", "mdown", "mkd", "mdx"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }
        return types
    }

    static var writableContentTypes: [UTType] { readableContentTypes }

    init(text: String = MarksmithDocument.starterText) {
        self.text = text
    }

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var content = String(data: data, encoding: .utf8)
        if content == nil {
            content = String(decoding: data, as: UTF8.self)
        }
        // A UTF-8 BOM must not become part of the document text.
        if content?.hasPrefix("\u{FEFF}") == true { content?.removeFirst() }
        text = content ?? ""
    }

    typealias Snapshot = String

    func snapshot(contentType: UTType) throws -> String { text }

    func fileWrapper(snapshot: String, configuration: WriteConfiguration) throws -> FileWrapper {
        guard let data = snapshot.data(using: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return FileWrapper(regularFileWithContents: data)
    }

    static let starterText = """
    # 欢迎使用 Marksmith

    一款原生 macOS Markdown 编辑器：**编辑、实时预览、导出 PDF / HTML / Word**。

    ## 功能一览

    - 左右分栏 / 仅编辑 / 仅预览（`⌘1` `⌘2` `⌘3`）
    - GFM 表格、任务列表、代码块、引用
    - 数学公式 $x^2 + y^2 = z^2$ 与 $$E = mc^2$$
    - Mermaid 图表、代码高亮
    - 文件夹侧栏（`⌘⇧O`）、查找替换（`⌘F`）
    - 图片粘贴 / 拖拽

    ```swift
    let greeting = "Hello, Marksmith"
    print(greeting)
    ```

    ```mermaid
    graph LR
        A[Markdown] --> B[AST]
        B --> C[HTML / PDF]
        B --> D[DOCX]
    ```

    | 导出格式 | 说明 |
    | :--- | :--- |
    | PDF | 预览所见即所得 |
    | HTML | 单文件、离线可用 |
    | Word | 原生表格 .docx |

    > 提示：在「设置」中可以调整字号、字体、Vim 模式与默认视图。

    ---

    *按 ⌘N 新建文档，开始写作。*
    """
}

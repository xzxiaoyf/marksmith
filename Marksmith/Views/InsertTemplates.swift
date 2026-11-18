import Foundation
import AppKit

// MARK: - Guided insertion templates
//
// The two new toolbar buttons (公式 / 流程图) are not simple one-shot inserts:
// they open a small guide menu with ready-to-edit snippets plus a cheat-sheet
// dialog. Data lives here, away from SwiftUI, so the snippets and the
// placeholder rules can be unit-tested and reused by the 「格式」menu.
//
// Insertion itself still happens in exactly one place —
// `MarkdownEditorTextView.apply(_:)` — via `InsertCommand.template`.

enum TemplateKind: String, Sendable {
    case math
    case diagram
}

/// A ready-to-edit Markdown snippet.
///
/// `placeholder` must be a substring of `snippet`. After insertion that
/// substring is selected, so the user can type over it; if text was already
/// selected, that text replaces the placeholder instead.
struct InsertTemplate: Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let snippet: String
    let placeholder: String?
    let kind: TemplateKind

    /// UTF-16 range of the placeholder inside `snippet`.
    var placeholderRange: NSRange? {
        guard let placeholder else { return nil }
        let found = (snippet as NSString).range(of: placeholder)
        return found.location == NSNotFound ? nil : found
    }

    /// Block snippets must start on a fresh line; inline math must not.
    var isBlock: Bool {
        snippet.hasPrefix("$$") || snippet.hasPrefix("```")
    }
}

enum InsertTemplates {

    // MARK: Math (KaTeX)

    static let inlineMath = InsertTemplate(
        id: "math.inline",
        title: "行内公式 $…$",
        detail: "夹在句子中间，如 $E = mc^2$",
        snippet: "$E = mc^2$",
        placeholder: "E = mc^2",
        kind: .math)

    static let displayMath = InsertTemplate(
        id: "math.display",
        title: "独立公式 $$…$$",
        detail: "独占一块并居中显示",
        snippet: "$$\nE = mc^2\n$$\n",
        placeholder: "E = mc^2",
        kind: .math)

    static let fraction = InsertTemplate(
        id: "math.fraction",
        title: "分数与上下标",
        detail: "\\frac{a}{b} + x_i^2 = c",
        snippet: "$$\n\\frac{a}{b} + x_i^2 = c\n$$\n",
        placeholder: "\\frac{a}{b} + x_i^2 = c",
        kind: .math)

    static let summation = InsertTemplate(
        id: "math.sum",
        title: "求和公式",
        detail: "\\sum_{i=1}^{n} 与分数联用",
        snippet: "$$\n\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}\n$$\n",
        placeholder: "\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}",
        kind: .math)

    static let aligned = InsertTemplate(
        id: "math.aligned",
        title: "多行对齐 / 方程组",
        detail: "\\begin{aligned} … \\end{aligned}",
        snippet: "$$\n\\begin{aligned}\nE &= mc^2 \\\\\na^2 + b^2 &= c^2\n\\end{aligned}\n$$\n",
        placeholder: "E &= mc^2",
        kind: .math)

    static let math: [InsertTemplate] = [inlineMath, displayMath, fraction, summation, aligned]

    // MARK: Diagrams (Mermaid)

    static let flowchartTD = InsertTemplate(
        id: "diagram.flowchart.td",
        title: "流程图 · 自上而下",
        detail: "flowchart TD，含判断分支与回环",
        snippet: """
        ```mermaid
        flowchart TD
            A[开始] --> B{条件判断}
            B -->|是| C[处理完成]
            B -->|否| D[返回修改]
            D --> B
        ```
        """ + "\n",
        placeholder: "开始",
        kind: .diagram)

    static let flowchartLR = InsertTemplate(
        id: "diagram.flowchart.lr",
        title: "流程图 · 从左到右",
        detail: "flowchart LR，适合管线 / 步骤",
        snippet: """
        ```mermaid
        flowchart LR
            A[输入] --> B[处理] --> C[输出]
        ```
        """ + "\n",
        placeholder: "输入",
        kind: .diagram)

    static let sequenceDiagram = InsertTemplate(
        id: "diagram.sequence",
        title: "时序图",
        detail: "sequenceDiagram，展示消息往返",
        snippet: """
        ```mermaid
        sequenceDiagram
            participant U as 用户
            participant S as 系统
            U->>S: 提交请求
            S-->>U: 返回结果
        ```
        """ + "\n",
        placeholder: "提交请求",
        kind: .diagram)

    static let gantt = InsertTemplate(
        id: "diagram.gantt",
        title: "甘特图 / 项目排期",
        detail: "gantt，任务依赖与时间轴",
        snippet: """
        ```mermaid
        gantt
            title 项目排期
            dateFormat YYYY-MM-DD
            section 设计
            需求梳理 :a1, 2026-01-01, 3d
            原型设计 :a2, after a1, 5d
            section 开发
            编码实现 :a3, after a2, 10d
        ```
        """ + "\n",
        placeholder: "需求梳理",
        kind: .diagram)

    static let diagram: [InsertTemplate] = [flowchartTD, flowchartLR, sequenceDiagram, gantt]

    // MARK: Cheat sheets

    static func cheatSheet(for kind: TemplateKind) -> String {
        switch kind {
        case .math:
            return """
            公式写在 $...$（行内）或 $$...$$（独立成行）之间，预览、HTML 与 PDF 由内置 KaTeX 渲染，完全离线。

            常用命令
            · 上下标：x_i^2、a^{n+1}        分数：\\frac{a}{b}
            · 根号：\\sqrt{x}               求和 / 积分：\\sum_{i=1}^{n}、\\int_0^1
            · 希腊字母：\\alpha \\beta \\pi \\Delta
            · 关系符：\\leq \\geq \\neq \\approx \\times \\pm \\to
            · 多行对齐：\\begin{aligned} … \\end{aligned}，行间用 \\\\ 换行

            小提示
            · 先选中一段文字再点模板，选中的文字会直接套进公式。
            · $5 / $10 这类价格不会被误判为公式（行内公式首字符不能是数字）。
            · 导出 Word 时不生成原生公式对象，文档里保留 LaTeX 源文本。
            """
        case .diagram:
            return """
            图表写在 ```mermaid 代码块中，预览、HTML 与 PDF 由内置 Mermaid 渲染为矢量图，完全离线。

            流程图语法
            · 方向：flowchart TD（自上而下）/ flowchart LR（从左到右）
            · 节点：A[方形]  B(圆角)  C{判断}  D((圆形))
            · 连线：A --> B   带文字：A -->|是| B   虚线：A -.-> B
            · 分组：subgraph 名称 … end

            其它图表类型（把代码块第一行换成对应关键字）
            · sequenceDiagram  时序图
            · gantt            甘特图
            · mindmap          思维导图
            · classDiagram     类图

            小提示
            · 点击工具栏的流程图按钮可直接插入以上模板，再改动节点文字即可。
            · 导出 Word 时图表保留为代码块文本，不会转成图片。
            """
        }
    }

    /// Modal cheat sheet. `insert` lets the dialog offer an "插入示例" button
    /// so a beginner can go from reading to editing in one click.
    @MainActor
    static func showCheatSheet(for kind: TemplateKind,
                               insert: ((InsertTemplate) -> Void)? = nil) {
        let alert = NSAlert()
        alert.messageText = kind == .math ? "公式语法速查（KaTeX）" : "图表语法速查（Mermaid）"
        alert.informativeText = cheatSheet(for: kind)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        if insert != nil { alert.addButton(withTitle: "插入示例") }
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        insert?(kind == .math ? inlineMath : flowchartTD)
    }
}

import SwiftUI
import AppKit

/// Top-window format bar.
///
/// Every control here dispatches an `InsertCommand` — the exact same enum used
/// by the 「格式」menu and its keyboard shortcuts. There is deliberately no
/// insertion logic in this file: selection wrapping, Chinese placeholders and
/// caret placement all stay in `MarkdownEditorTextView.apply`, which also
/// returns first responder to the editor after each command.
///
/// The bar is intentionally compact (five icon buttons + four pull-down menus)
/// so macOS does not collapse the window toolbar into an overflow menu on a
/// normal-width window. Less common commands live in the overflow menu.
/// 公式 / 流程图 are guide menus: each entry inserts a ready-to-edit snippet
/// and the last entry opens a syntax cheat sheet.
struct FormatToolbar: View {
    @ObservedObject var settings: AppSettings
    let insert: (InsertCommand) -> Void
    /// Formatting needs a live text view (the "preview only" mode has none).
    var enabled: Bool = true

    var body: some View {
        HStack(spacing: 2) {
            headingMenu
            toolbarDivider

            iconButton("bold", help: "加粗 (⌘B)") { insert(.bold) }
            iconButton("italic", help: "斜体 (⌘I)") { insert(.italic) }
            iconButton("strikethrough", help: "删除线") { insert(.strikethrough) }
            iconButton("link", help: "插入链接 (⌘K)") { insert(.link) }
            iconButton("tablecells", help: "插入表格") { insert(.table) }
            toolbarDivider

            mathMenu
            diagramMenu
            toolbarDivider

            moreMenu
        }
        .disabled(!enabled)
    }

    // MARK: - Menus

    private var headingMenu: some View {
        Menu {
            Button("一级标题") { insert(.heading(1)) }
            Button("二级标题") { insert(.heading(2)) }
            Button("三级标题") { insert(.heading(3)) }
            Button("正文（清除标题）") { insert(.heading(0)) }

            Divider()

            // Markdown is semantic markup: it has no font syntax. "字体" is a
            // display preference, so these items change the editor appearance
            // rather than writing anything into the document.
            Button("增大字号") { changeFontSize(1) }
            Button("减小字号") { changeFontSize(-1) }
            Button("字体与显示设置…") { openSettings() }
        } label: {
            Label("标题与字体", systemImage: "textformat.size")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 30)
        .help("标题级别 / 编辑器字号（Markdown 无字体语法）")
    }

    /// 「公式」guide: templates + a modal KaTeX cheat sheet. Every entry is a
    /// plain `InsertCommand`, so insertion/caret behaviour stays in the editor.
    private var mathMenu: some View {
        Menu {
            Text("插入公式模板（可先选中文字）")
            ForEach(InsertTemplates.math) { template in
                Button(template.title) { insert(.template(template)) }
            }

            Divider()

            Button("公式语法速查…") {
                InsertTemplates.showCheatSheet(for: .math) { insert(.template($0)) }
            }
        } label: {
            Label("公式", systemImage: "sum")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 30)
        .help("插入数学公式 / LaTeX 模板（∑）")
    }

    /// 「流程图」guide: Mermaid snippets + a modal syntax cheat sheet.
    private var diagramMenu: some View {
        Menu {
            Text("插入 Mermaid 图表模板")
            ForEach(InsertTemplates.diagram) { template in
                Button(template.title) { insert(.template(template)) }
            }

            Divider()

            Button("图表语法速查…") {
                InsertTemplates.showCheatSheet(for: .diagram) { insert(.template($0)) }
            }
        } label: {
            Label("流程图", systemImage: "flowchart")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 30)
        .help("插入流程图 / 时序图 / 甘特图模板")
    }

    private var moreMenu: some View {
        Menu {
            Button("行内代码") { insert(.inlineCode) }
            Button("代码块") { insert(.codeBlock) }
            Button("引用") { insert(.quote) }
            Button("分割线") { insert(.horizontalRule) }

            Divider()

            Button("无序列表") { insert(.unorderedList) }
            Button("有序列表") { insert(.orderedList) }
            Button("任务列表") { insert(.task) }

            Divider()

            Button("插入图片…") { insert(.image) }
        } label: {
            Label("更多格式", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 30)
        .help("更多 Markdown 格式")
    }

    // MARK: - Parts

    private func iconButton(_ systemName: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private var toolbarDivider: some View {
        Divider().frame(width: 1, height: 18).padding(.horizontal, 4)
    }

    // MARK: - Display preferences

    private func changeFontSize(_ delta: Double) {
        // @AppStorage inside an ObservableObject does not publish by itself.
        settings.objectWillChange.send()
        settings.editorFontSize = min(36, max(9, settings.editorFontSize + delta))
    }

    private func openSettings() {
        let selector = Selector(("showSettingsWindow:"))
        if NSApp.responds(to: selector) {
            NSApp.sendAction(selector, to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}

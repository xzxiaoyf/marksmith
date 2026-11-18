import SwiftUI
import AppKit

// MARK: - Focused values
//
// Menu commands live in the App scene; document windows publish their state
// through these keys so each command targets exactly the focused window.

struct FocusedDocumentContext {
    let markdown: String
    let title: String
    let baseDirectory: URL?
    let theme: ColorTheme

    func exportContext() -> ExportContext {
        ExportContext.make(markdown: markdown,
                           title: title,
                           baseDirectory: baseDirectory,
                           theme: theme)
    }
}

struct OpenFolderAction {
    let run: (URL) -> Void
}

struct FindAction {
    let run: (Bool) -> Void   // `true` = show the Replace row
}

/// One command per formatting operation. Menus, keyboard shortcuts and the
/// top-window format bar all funnel through this enum, so the insertion logic
/// lives in exactly one place (`MarkdownEditorTextView.apply`).
/// `heading(0)` clears a heading marker instead of adding one.
/// `template` carries a whole guided snippet (公式 / 流程图); keeping the
/// payload in the command means menus and toolbar need no insertion code.
enum InsertCommand: Hashable, Sendable {
    case bold, italic, strikethrough, inlineCode, link, codeBlock, quote
    case heading(Int), table, horizontalRule, unorderedList, orderedList, task
    case image
    case template(InsertTemplate)
}

struct InsertAction {
    let run: (InsertCommand) -> Void
}

struct ImportAction {
    let run: () -> Void
}

private struct DocumentContextKey: FocusedValueKey { typealias Value = FocusedDocumentContext }
private struct ImportActionKey: FocusedValueKey { typealias Value = ImportAction }
private struct ViewModeKey: FocusedValueKey { typealias Value = Binding<ViewMode> }
private struct SidebarVisibilityKey: FocusedValueKey { typealias Value = Binding<Bool> }
private struct OpenFolderActionKey: FocusedValueKey { typealias Value = OpenFolderAction }
private struct FindActionKey: FocusedValueKey { typealias Value = FindAction }
private struct InsertActionKey: FocusedValueKey { typealias Value = InsertAction }

extension FocusedValues {
    var documentContext: FocusedDocumentContext? {
        get { self[DocumentContextKey.self] }
        set { self[DocumentContextKey.self] = newValue }
    }
    var viewMode: Binding<ViewMode>? {
        get { self[ViewModeKey.self] }
        set { self[ViewModeKey.self] = newValue }
    }
    var sidebarVisible: Binding<Bool>? {
        get { self[SidebarVisibilityKey.self] }
        set { self[SidebarVisibilityKey.self] = newValue }
    }
    var openFolderAction: OpenFolderAction? {
        get { self[OpenFolderActionKey.self] }
        set { self[OpenFolderActionKey.self] = newValue }
    }
    var findAction: FindAction? {
        get { self[FindActionKey.self] }
        set { self[FindActionKey.self] = newValue }
    }
    var insertAction: InsertAction? {
        get { self[InsertActionKey.self] }
        set { self[InsertActionKey.self] = newValue }
    }
    var importAction: ImportAction? {
        get { self[ImportActionKey.self] }
        set { self[ImportActionKey.self] = newValue }
    }
}

/// Hand-off used when "Open Folder" is invoked with no document window focused.
enum PendingFolderOpen {
    static var url: URL?
}

// MARK: - Menu commands

struct AppCommands: Commands {
    @FocusedValue(\.documentContext) var documentContext
    @FocusedValue(\.viewMode) var viewMode
    @FocusedValue(\.sidebarVisible) var sidebarVisible
    @FocusedValue(\.openFolderAction) var openFolderAction
    @FocusedValue(\.findAction) var findAction
    @FocusedValue(\.insertAction) var insertAction
    @FocusedValue(\.importAction) var importAction

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("打开文件夹…") { openFolderPanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandGroup(after: .importExport) {
            Button("导入文件并转换为 Markdown…") { importAction?.run() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(importAction == nil)

            Menu("导出") {
                ForEach(ExportRegistry.shared.formats, id: \.id) { format in
                    Button("导出为 \(format.displayName)…") { export(format) }
                }
            }
            .disabled(documentContext == nil)
        }

        CommandMenu("视图") {
            Button("分栏") { viewMode?.wrappedValue = .sideBySide }
                .keyboardShortcut("1", modifiers: .command)
            Button("仅编辑") { viewMode?.wrappedValue = .editorOnly }
                .keyboardShortcut("2", modifiers: .command)
            Button("仅预览") { viewMode?.wrappedValue = .previewOnly }
                .keyboardShortcut("3", modifiers: .command)

            Divider()

            Button("显示/隐藏侧栏") { sidebarVisible?.wrappedValue.toggle() }
                .keyboardShortcut("\\", modifiers: .command)
        }

        CommandGroup(after: .textEditing) {
            Button("查找…") { findAction?.run(false) }
                .keyboardShortcut("f", modifiers: .command)
            Button("查找并替换…") { findAction?.run(true) }
                .keyboardShortcut("f", modifiers: [.command, .option])
        }

        CommandMenu("格式") {
            Button("加粗") { insertAction?.run(.bold) }
                .keyboardShortcut("b", modifiers: .command)
            Button("斜体") { insertAction?.run(.italic) }
                .keyboardShortcut("i", modifiers: .command)
            Button("删除线") { insertAction?.run(.strikethrough) }
            Button("行内代码") { insertAction?.run(.inlineCode) }
                .keyboardShortcut("`", modifiers: .command)
            Button("链接") { insertAction?.run(.link) }
                .keyboardShortcut("k", modifiers: .command)

            Divider()

            Button("一级标题") { insertAction?.run(.heading(1)) }
            Button("二级标题") { insertAction?.run(.heading(2)) }
            Button("正文（清除标题）") { insertAction?.run(.heading(0)) }
            Button("代码块") { insertAction?.run(.codeBlock) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("引用") { insertAction?.run(.quote) }
            Button("表格") { insertAction?.run(.table) }
            Button("分割线") { insertAction?.run(.horizontalRule) }

            Divider()

            Button("无序列表") { insertAction?.run(.unorderedList) }
            Button("有序列表") { insertAction?.run(.orderedList) }
            Button("任务列表") { insertAction?.run(.task) }
            Button("插入图片…") { insertAction?.run(.image) }

            Divider()

            // Guided templates mirror the two new toolbar buttons, so the same
            // snippets are reachable from the menu bar / keyboard users.
            Menu("插入公式") {
                ForEach(InsertTemplates.math) { template in
                    Button(template.title) { insertAction?.run(.template(template)) }
                }
                Divider()
                Button("公式语法速查…") {
                    InsertTemplates.showCheatSheet(for: .math) { template in
                        insertAction?.run(.template(template))
                    }
                }
            }
            Menu("插入图表") {
                ForEach(InsertTemplates.diagram) { template in
                    Button(template.title) { insertAction?.run(.template(template)) }
                }
                Divider()
                Button("图表语法速查…") {
                    InsertTemplates.showCheatSheet(for: .diagram) { template in
                        insertAction?.run(.template(template))
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func export(_ format: ExportFormat) {
        guard let documentContext else { return }
        ExportService.shared.export(format, context: documentContext.exportContext())
    }

    private func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.title = "打开文件夹"
        panel.message = "选择包含 Markdown 文件的文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let openFolderAction {
            openFolderAction.run(url)
        } else {
            PendingFolderOpen.url = url
            _ = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
        }
    }
}

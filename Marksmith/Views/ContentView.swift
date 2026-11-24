import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var document: MarksmithDocument
    /// URL of THIS window's document, injected by `DocumentGroup`. It is `nil`
    /// for a new, unsaved document. Every relative-path resolution (preview
    /// images, exports, pasted-image `assets/`) derives from this value.
    let documentURL: URL?
    @ObservedObject private var settings = AppSettings.shared

    @Environment(\.openDocument) private var openDocument
    @Environment(\.colorScheme) private var colorScheme

    @StateObject private var bridge = EditorBridge()
    @StateObject private var findController = FindController()
    @StateObject private var folderModel = FolderTreeModel()

    @State private var viewMode: ViewMode = .sideBySide
    @State private var previewHTML = ""
    @State private var sidebarVisible = false
    /// Used to reject a pending "import into a new document" payload that was
    /// staged after this window already existed.
    @State private var viewCreatedAt = Date()
    @State private var cursor = CursorPosition()
    @State private var vimMode: VimMode = .normal
    @State private var debounceTask: Task<Void, Never>?
    /// Base directory used by the most recent render. Lets the deferred
    /// self-heal pass know a later URL-driven render already succeeded, so it
    /// must not overwrite correct HTML with a stale, URL-less snapshot.
    @State private var renderedFolder: URL?

    var body: some View {
        NavigationSplitView(columnVisibility: sidebarVisibility) {
            sidebar
        } detail: {
            detail
        }
        .toolbar { toolbarContent }
        .onAppear(perform: initialise)
        .onChange(of: document.text) { _, newValue in
            // The preview and the editor are refreshed from the same signal.
            // A direct AppKit sync is kept alongside SwiftUI's representable
            // update so a document that finishes loading into an existing
            // window can never leave the editor empty.
            bridge.syncText(newValue)
            schedulePreviewUpdate(for: newValue)
        }
        .onChange(of: documentURL) { _, _ in
            // A document URL can arrive after onAppear (opening from Finder),
            // and it changes on Save As. Relative images must be re-embedded
            // against the new folder even when the text itself did not change.
            refreshPreview()
        }
        .onChange(of: settings.defaultViewModeRaw) { _, _ in viewMode = settings.defaultViewMode }
        .onChange(of: settings.vimModeEnabled) { _, enabled in
            if !enabled { vimMode = .normal }
        }
        // The format bar now also carries the 公式 / 流程图 guide menus. Give
        // the toolbar enough room so macOS never folds items into an overflow
        // menu at the smallest allowed window size.
        .frame(minWidth: 880, minHeight: 440)
        .focusedValue(\.documentContext, focusedContext)
        .focusedValue(\.viewMode, $viewMode)
        .focusedValue(\.sidebarVisible, $sidebarVisible)
        .focusedValue(\.openFolderAction, OpenFolderAction { url in
            folderModel.load(url)
            sidebarVisible = true
        })
        .focusedValue(\.findAction, FindAction { replace in
            bridge.showFind(replace: replace)
        })
        .focusedValue(\.insertAction, InsertAction { command in
            bridge.applyInsert(command)
        })
        .focusedValue(\.importAction, ImportAction { presentImport() })
    }

    // MARK: - Subviews (kept separate so SwiftUI type-checking stays fast)

    private var sidebar: some View {
        FolderSidebarView(model: folderModel, onOpen: openFileInDocument)
            .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 400)
    }

    private var detail: some View {
        VStack(spacing: 0) {
            EditorContainer(
                text: $document.text,
                viewMode: viewMode,
                htmlBody: previewHTML,
                theme: theme,
                isDarkEditor: colorScheme == .dark,
                imageBaseURL: documentFolder,
                settings: settings,
                bridge: bridge,
                findController: findController,
                onCursorChange: { line, column in
                    cursor = CursorPosition(line: line, column: column)
                },
                onVimModeChange: { mode in vimMode = mode }
            )
            Divider()
            StatusBarView(
                stats: DocumentStats(text: document.text),
                cursor: cursor,
                vimMode: vimMode,
                vimEnabled: settings.vimModeEnabled,
                viewMode: viewMode,
                appearance: theme
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { sidebarVisible.toggle() } label: {
                Image(systemName: "sidebar.left")
            }
            .help("显示/隐藏文件侧栏 (⌘\\)")
        }

        ToolbarItem(placement: .automatic) {
            viewModePicker
        }

        // New format bar. The three items above/below (sidebar, view-mode
        // picker, export menu) are unchanged and keep their original order.
        ToolbarItem(placement: .automatic) {
            FormatToolbar(settings: settings,
                          insert: { bridge.applyInsert($0) },
                          enabled: viewMode != .previewOnly)
        }

        ToolbarItem(placement: .automatic) {
            importButton
        }

        ToolbarItem(placement: .automatic) {
            exportMenu
        }
    }

    private var viewModePicker: some View {
        Picker("视图模式", selection: $viewMode) {
            ForEach(ViewMode.allCases) { mode in
                Label(mode.localized, systemImage: mode.systemImage).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .help("分栏 / 仅编辑 / 仅预览")
    }

    private var importButton: some View {
        Button(action: presentImport) {
            Label("导入", systemImage: "square.and.arrow.down")
        }
        .help("导入 文本 / Markdown / HTML / Word / Excel / PDF 并转换为 Markdown (⌘⇧I)")
    }

    private var exportMenu: some View {
        Menu {
            ForEach(ExportRegistry.shared.formats, id: \.id) { format in
                Button("导出为 \(format.displayName)…") {
                    ExportService.shared.export(format, context: exportContext())
                }
            }
        } label: {
            Label("导出", systemImage: "square.and.arrow.up")
        }
        .help("导出 PDF / HTML / Word")
    }

    // MARK: - Derived state

    private var theme: ColorTheme {
        settings.appearance.resolved(systemDark: colorScheme == .dark)
    }

    private var documentFolder: URL? {
        ImageResolver.documentDirectory(for: documentURL)
    }

    private var documentTitle: String {
        ImageResolver.documentTitle(for: documentURL)
    }

    private var focusedContext: FocusedDocumentContext {
        FocusedDocumentContext(markdown: document.text,
                               title: documentTitle,
                               baseDirectory: documentFolder,
                               theme: theme)
    }

    private var sidebarVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { sidebarVisible ? .all : .detailOnly },
            set: { sidebarVisible = ($0 != .detailOnly) }
        )
    }

    // MARK: - Preview pipeline

    private func initialise() {
        viewMode = settings.defaultViewMode

        // Consume a staged new-document import *before* any deferred editor
        // sync. The old code queued a snapshot of the starter text here; that
        // queued value landed after the import and overwrote the editor while
        // the preview (assigned directly) stayed correct.
        let imported = ImportService.consumePendingImport(
            into: document, bridge: bridge, viewCreatedAt: viewCreatedAt)
        let currentText = imported ?? document.text
        previewHTML = renderPreview(currentText)
        bridge.syncText(currentText)

        // `makeNSView` wires the bridge on the next run-loop turn. Replay the
        // newest value afterwards; `flush()` carries no captured snapshot, so
        // a late pass can never restore stale text.
        let editorBridge = bridge
        DispatchQueue.main.async { [weak editorBridge] in editorBridge?.flush() }

        // Self-heal for the narrow window where SwiftUI has not yet exposed
        // the document URL. The guard reads current @State, so if a URL-driven
        // re-render already happened this pass becomes a no-op instead of
        // overwriting correct HTML with a stale, URL-less snapshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard renderedFolder == nil else { return }
            refreshPreview()
        }

        if let pending = PendingFolderOpen.url {
            PendingFolderOpen.url = nil
            folderModel.load(pending)
            sidebarVisible = true
        }
    }

    private func renderPreview(_ markdown: String) -> String {
        let folder = documentFolder
        renderedFolder = folder
        let options = HTMLRenderOptions(baseDirectory: folder, embedLocalImages: true)
        return HTMLRenderer(options: options).render(MarkdownParser().parse(markdown))
    }

    /// Re-renders with the current document text and URL, without capturing a
    /// text/URL snapshot in a closure (the 1.2.1 import race was caused by
    /// exactly that pattern).
    private func refreshPreview() {
        let html = renderPreview(document.text)
        if html != previewHTML { previewHTML = html }
    }

    private func schedulePreviewUpdate(for text: String) {
        debounceTask?.cancel()
        let milliseconds = Int(settings.previewDebounceMs)
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(milliseconds))
            guard !Task.isCancelled else { return }
            previewHTML = renderPreview(text)
        }
    }

    private func exportContext() -> ExportContext {
        ExportContext.make(markdown: document.text,
                           title: documentTitle,
                           baseDirectory: documentFolder,
                           theme: theme)
    }

    private func presentImport() {
        ImportService.shared.run(document: document,
                                 bridge: bridge,
                                 baseDirectory: documentFolder)
    }

    // MARK: - Folder sidebar

    private func openFileInDocument(_ url: URL) {
        Task { @MainActor in
            do {
                // Open through DocumentGroup so the file gets its own document
                // and Cmd+S stays bound to the correct path.
                try await openDocument(at: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "打开文件失败"
                alert.informativeText = "无法打开「\(url.lastPathComponent)」：\(error.localizedDescription)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        }
    }
}

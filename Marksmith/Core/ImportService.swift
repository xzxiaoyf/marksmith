import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - Extensible import API
//
// Mirror image of `ExportRegistry`: add a type conforming to
// `DocumentImporter`, register it once in `ImportRegistry.bootstrap()`, and
// the open panel + File menu pick it up automatically.
//
// Importers build a `MarkdownModel` and hand it to `MarkdownSerializer`; they
// never concatenate Markdown strings themselves. That means imported content
// follows exactly the same parse → render path as hand-written Markdown.

struct ImportFormat: Hashable, Identifiable, Sendable {
    let id: String
    let fileExtensions: [String]
    let displayName: String
    /// Explains the fidelity a user should expect; shown in the open panel.
    let note: String
}

enum StandardImportFormats {
    static let html = ImportFormat(id: "html", fileExtensions: ["html", "htm"],
                                   displayName: "HTML 网页",
                                   note: "标题、强调、列表、表格、链接与图片可较好还原")
    static let docx = ImportFormat(id: "docx", fileExtensions: ["docx"],
                                   displayName: "Word (.docx)",
                                   note: "段落、标题、强调、表格、列表与图片")
    static let xlsx = ImportFormat(id: "xlsx", fileExtensions: ["xlsx"],
                                   displayName: "Excel (.xlsx)",
                                   note: "每个工作表转换为一节 GFM 表格")
    static let pdf = ImportFormat(id: "pdf", fileExtensions: ["pdf"],
                                  displayName: "PDF 文档",
                                  note: "仅提取纯文本，不还原排版、表格与标题层级")
    static let text = ImportFormat(
        id: "text",
        fileExtensions: ["txt", "text", "md", "markdown", "mdown", "mkd", "mdx",
                         "log", "csv", "tsv", "json", "yaml", "yml", "xml",
                         "ini", "cfg", "conf", "rst", "tex"],
        displayName: "纯文本 / Markdown",
        note: "自动识别 UTF-8 / UTF-16 / GB18030 / Big5；纯文本换行转硬换行，CSV/TSV 转表格")
}

struct ImportRequest: Sendable {
    let url: URL
    /// Folder of the current document, used for extracted image assets.
    let baseDirectory: URL?
}

struct ImportResult: Sendable {
    var markdown: String
    var warnings: [String] = []
    var sourceURL: URL
    var format: ImportFormat
}

protocol DocumentImporter: Sendable {
    var format: ImportFormat { get }
    func importDocument(_ request: ImportRequest) async throws -> ImportResult
}

@MainActor
final class ImportRegistry {
    static let shared = ImportRegistry()

    private var importers: [any DocumentImporter] = []

    var formats: [ImportFormat] { importers.map { $0.format } }

    var allowedExtensions: [String] {
        importers.flatMap { $0.format.fileExtensions }
    }

    var allowedContentTypes: [UTType] {
        allowedExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    func register(_ importer: any DocumentImporter) {
        importers.removeAll { $0.format.id == importer.format.id }
        importers.append(importer)
    }

    func importer(forExtension extension: String) -> (any DocumentImporter)? {
        let lower = `extension`.lowercased()
        return importers.first { $0.format.fileExtensions.contains(lower) }
    }

    /// Called once from `MarksmithApp`. Add custom importers here.
    func bootstrap() {
        guard importers.isEmpty else { return }
        register(HTMLImporter())
        register(DOCXImporter())
        register(XLSXImporter())
        register(PDFImporter())
        register(TextImporter())
    }
}

// MARK: - Where imported Markdown goes

enum ImportTarget {
    case newDocument
    case replace
    case append
}

// MARK: - UI facade

/// Hand-off for "import into a new document". SwiftUI's `DocumentGroup` owns
/// the new `MarksmithDocument`, so the window consumes this value on appear.
/// A payload records when it was staged: only a window created *after* that
/// moment may consume it, so an existing window that happens to re-appear
/// while the new one opens cannot steal the import.
enum PendingImport {
    struct Payload {
        let id: UUID
        let markdown: String
        let stagedAt: Date
    }

    static var payload: Payload?

    @discardableResult
    static func stage(_ markdown: String) -> UUID {
        let pending = Payload(id: UUID(), markdown: markdown, stagedAt: Date())
        payload = pending
        return pending.id
    }

    static func consume(viewCreatedAt: Date) -> String? {
        guard let pending = payload, pending.stagedAt <= viewCreatedAt else { return nil }
        payload = nil
        return pending.markdown
    }

    static func cancel(_ id: UUID) {
        if payload?.id == id { payload = nil }
    }
}

@MainActor
final class ImportService {
    static let shared = ImportService()

    /// Full import flow: choose file → convert off the main thread → ask for a
    /// destination → write into `document.text`, which is the single source of
    /// truth that drives editor, preview and status bar.
    func run(document: MarksmithDocument, bridge: EditorBridge, baseDirectory: URL?) {
        guard let url = presentOpenPanel() else { return }
        // Files with no / an unusual extension are still accepted when they
        // sniff as text — common for README, CHANGELOG, .gitignore, logs...
        let importer: (any DocumentImporter)? =
            ImportRegistry.shared.importer(forExtension: url.pathExtension)
            ?? (TextFileDecoder.probablyText(url) ? TextImporter() : nil)
        guard let importer else {
            presentUnsupported(url)
            return
        }

        let request = ImportRequest(url: url, baseDirectory: baseDirectory)
        Task { @MainActor in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await importer.importDocument(request)
                }.value
                apply(result, to: document, bridge: bridge)
            } catch {
                present(error, title: "导入失败")
            }
        }
    }

    private func presentOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "导入文件并转换为 Markdown"
        panel.message = "支持 文本 / Markdown、HTML、Word (.docx)、Excel (.xlsx)、PDF"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ImportRegistry.shared.allowedContentTypes
        panel.allowsOtherFileTypes = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func apply(_ result: ImportResult, to document: MarksmithDocument,
                       bridge: EditorBridge) {
        guard let target = chooseTarget(for: result) else { return }

        switch target {
        case .replace:
            if !confirmOverwriteIfEdited() { return }
            Self.writeImportedText(result.markdown, to: document, bridge: bridge,
                                   target: .replace)

        case .append:
            Self.writeImportedText(result.markdown, to: document, bridge: bridge,
                                   target: .append)

        case .newDocument:
            let id = PendingImport.stage(result.markdown)
            guard (try? NSDocumentController.shared.openUntitledDocumentAndDisplay(true)) != nil else {
                PendingImport.cancel(id)
                present(ImportError.unreadable("无法新建文档"), title: "导入失败")
                return
            }
            // If no window appears, do not let a stale payload leak into a
            // later unrelated new document. Only cancels this exact payload.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                PendingImport.cancel(id)
            }
        }

        if !result.warnings.isEmpty {
            let alert = NSAlert()
            alert.messageText = "已导入「\(result.sourceURL.lastPathComponent)」"
            alert.informativeText = result.warnings.joined(separator: "\n\n")
            alert.alertStyle = .informational
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    /// Single write path for imports into an existing document. Calling the
    /// bridge explicitly (instead of relying only on SwiftUI's `onChange`)
    /// keeps the editor and the preview on the same value even when the
    /// document mutation is coalesced into an already-running update cycle.
    static func writeImportedText(_ markdown: String, to document: MarksmithDocument,
                                  bridge: EditorBridge, target: ImportTarget) {
        switch target {
        case .newDocument:
            return
        case .replace:
            document.text = markdown
            bridge.syncText(markdown)
        case .append:
            let current = document.text as NSString
            let offset = min(max(0, bridge.cursorLocation()), current.length)
            let insertion = "\n\n" + markdown
            let updated = current.replacingCharacters(in: NSRange(location: offset, length: 0),
                                                      with: insertion)
            document.text = updated
            bridge.syncText(updated)
            bridge.moveCursor(to: offset + (insertion as NSString).length)
        }
    }

    /// Consumes a staged "import into a new document" payload for a window
    /// created after the import began. Returns the Markdown so `ContentView`
    /// can refresh the preview immediately; document and editor are both
    /// updated here from the same authoritative value.
    static func consumePendingImport(into document: MarksmithDocument,
                                     bridge: EditorBridge,
                                     viewCreatedAt: Date) -> String? {
        guard let imported = PendingImport.consume(viewCreatedAt: viewCreatedAt) else { return nil }
        document.text = imported
        bridge.syncText(imported)
        return imported
    }

    private func chooseTarget(for result: ImportResult) -> ImportTarget? {
        let alert = NSAlert()
        alert.messageText = "导入「\(result.sourceURL.lastPathComponent)」"
        var info = "已转换为 Markdown（\(result.format.displayName)）。选择导入方式："
        if let first = result.warnings.first {
            info += "\n\n注意：\(first)"
            if result.warnings.count > 1 { info += "（另有 \(result.warnings.count - 1) 条说明）" }
        }
        alert.informativeText = info
        alert.alertStyle = .informational
        alert.addButton(withTitle: "新建文档")
        alert.addButton(withTitle: "覆盖当前文档")
        alert.addButton(withTitle: "追加到光标处")
        alert.addButton(withTitle: "取消")

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .newDocument
        case .alertSecondButtonReturn: return .replace
        case .alertThirdButtonReturn: return .append
        default: return nil
        }
    }

    /// Never silently discard unsaved work.
    ///
    /// `NSDocumentController.shared.currentDocument` is nil under SwiftUI's
    /// DocumentGroup (measured while fixing 1.2.2), which silently disabled
    /// this guard. `NSWindow.isDocumentEdited` is per-window and is maintained
    /// by DocumentGroup, so ask the active window instead.
    private func confirmOverwriteIfEdited() -> Bool {
        let edited = NSApp.keyWindow?.isDocumentEdited
            ?? NSApp.mainWindow?.isDocumentEdited
            ?? false
        guard edited else { return true }
        let alert = NSAlert()
        alert.messageText = "当前文档有未保存的修改"
        alert.informativeText = "覆盖后这些内容将无法恢复。建议先保存，或选择「新建文档」/「追加到光标处」。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "仍然覆盖")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentUnsupported(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        let legacy = ["doc", "xls", "rtf", "pages", "numbers"].contains(ext)
        let alert = NSAlert()
        alert.messageText = legacy ? "旧版格式暂不支持" : "不支持该文件类型"
        alert.informativeText = legacy
            ? "「\(url.lastPathComponent)」是旧版二进制格式。请在原应用中另存为 .docx / .xlsx（或导出 HTML / .txt）后重新导入；加密、受保护的文档也无法读取。"
            : "「\(url.lastPathComponent)」没有对应的导入器，或看起来不是文本文件。目前支持 .txt / .md 等文本文件、HTML、.docx、.xlsx 与 .pdf。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func present(_ error: Error, title: String) {
        let alert = NSAlert(error: error)
        alert.messageText = title
        alert.informativeText = error.localizedDescription + "\n\n原文档保持不变。"
        alert.alertStyle = .warning
        alert.runModal()
    }
}

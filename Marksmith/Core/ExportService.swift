import Foundation
import AppKit
import WebKit
import UniformTypeIdentifiers

// MARK: - Extensible export API
//
// To add a new format later:
//   1. Create a type conforming to `DocumentExporter`.
//   2. Register it once in `ExportRegistry.bootstrap()`.
// No changes to menus, commands or the UI are needed — the Export menu is
// generated from the registry.

struct ExportFormat: Hashable, Identifiable {
    let id: String
    let fileExtension: String
    let displayName: String
}

enum StandardFormats {
    static let pdf = ExportFormat(id: "pdf", fileExtension: "pdf", displayName: "PDF 文档")
    static let html = ExportFormat(id: "html", fileExtension: "html", displayName: "独立 HTML")
    static let docx = ExportFormat(id: "docx", fileExtension: "docx", displayName: "Word (.docx)")
}

/// Everything an exporter needs. Parsing and HTML rendering happen once, so
/// every format sees exactly the same content.
struct ExportContext {
    var markdown: String
    var model: MarkdownModel
    var bodyHTML: String
    var title: String
    var baseDirectory: URL?
    var theme: ColorTheme

    static func make(markdown: String,
                     title: String,
                     baseDirectory: URL?,
                     theme: ColorTheme) -> ExportContext {
        let model = MarkdownParser().parse(markdown)
        let options = HTMLRenderOptions(baseDirectory: baseDirectory, embedLocalImages: true)
        let body = HTMLRenderer(options: options).render(model)
        return ExportContext(markdown: markdown, model: model, bodyHTML: body,
                             title: title, baseDirectory: baseDirectory, theme: theme)
    }
}

@MainActor
protocol DocumentExporter {
    var format: ExportFormat { get }
    func export(context: ExportContext) async throws -> Data
}

@MainActor
final class ExportRegistry {
    static let shared = ExportRegistry()

    private var exporters: [any DocumentExporter] = []

    var formats: [ExportFormat] { exporters.map { $0.format } }

    func register(_ exporter: any DocumentExporter) {
        exporters.removeAll { $0.format.id == exporter.format.id }
        exporters.append(exporter)
    }

    func exporter(for id: String) -> (any DocumentExporter)? {
        exporters.first { $0.format.id == id }
    }

    /// Called once from `MarksmithApp`. Add custom exporters here.
    func bootstrap() {
        guard exporters.isEmpty else { return }
        register(HTMLFileExporter())
        register(PDFFileExporter())
        register(DOCXFileExporter())
    }
}

// MARK: - HTML

struct HTMLFileExporter: DocumentExporter {
    let format = StandardFormats.html

    func export(context: ExportContext) async throws -> Data {
        var options = HTMLDocumentBuilder.Options()
        options.theme = context.theme
        options.title = context.title
        options.embedScripts = true
        options.embedFonts = true
        let document = HTMLDocumentBuilder.make(bodyHTML: context.bodyHTML, options: options)
        return Data(document.utf8)
    }
}

// MARK: - DOCX

struct DOCXFileExporter: DocumentExporter {
    let format = StandardFormats.docx

    func export(context: ExportContext) async throws -> Data {
        let options = DOCXOptions(baseDirectory: context.baseDirectory,
                                  documentTitle: context.title)
        return try DOCXExporter().export(model: context.model, options: options)
    }
}

// MARK: - PDF

struct PDFFileExporter: DocumentExporter {
    let format = StandardFormats.pdf

    func export(context: ExportContext) async throws -> Data {
        var options = HTMLDocumentBuilder.Options()
        options.theme = context.theme
        options.title = context.title
        options.embedScripts = true
        options.embedFonts = true
        let document = HTMLDocumentBuilder.make(bodyHTML: context.bodyHTML, options: options)
        return try await PDFRenderer.render(html: document)
    }
}

enum PDFExportError: LocalizedError {
    case loadFailed

    var errorDescription: String? {
        switch self {
        case .loadFailed: return "PDF 渲染页面加载失败或超时。"
        }
    }
}

@MainActor
enum PDFRenderer {
    static func render(html: String) async throws -> Data {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 820, height: 1100),
                                configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")

        let coordinator = LoadCoordinator()
        webView.navigationDelegate = coordinator
        webView.loadHTMLString(html, baseURL: nil)

        guard await coordinator.waitForLoad() else { throw PDFExportError.loadFailed }

        // Mermaid renders asynchronously. Poll an explicit readiness flag:
        // `callAsyncJavaScript` is imported inconsistently across SDKs, while
        // `evaluateJavaScript` is stable and sufficient here.
        for _ in 0..<60 {
            if let done = try? await webView.evaluateJavaScript("window.marksmithRenderDone === true"),
               let flag = done as? Bool, flag {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(120))

        let data = try await webView.pdf()
        withExtendedLifetime(webView) {}
        return data
    }
}

@MainActor
private final class LoadCoordinator: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var finished = false

    func waitForLoad() async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                self?.finish(false)
            }
        }
    }

    private func finish(_ success: Bool) {
        guard !finished else { return }
        finished = true
        let pending = continuation
        continuation = nil
        pending?.resume(returning: success)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        finish(false)
    }
}

// MARK: - Save panel facade

@MainActor
final class ExportService {
    static let shared = ExportService()

    /// Host window's document folder, used to resolve relative image paths.
    static func currentDocumentFolder() -> URL? {
        NSDocumentController.shared.currentDocument?.fileURL?.deletingLastPathComponent()
    }

    static func currentDocumentTitle() -> String {
        NSDocumentController.shared.currentDocument?
            .fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    func export(_ format: ExportFormat, context: ExportContext) {
        Task { @MainActor in
            guard let url = presentSavePanel(for: format, suggestedName: context.title) else { return }
            do {
                guard let exporter = ExportRegistry.shared.exporter(for: format.id) else {
                    throw ExportError.missingExporter(format.displayName)
                }
                let data = try await exporter.export(context: context)
                try data.write(to: url, options: .atomic)
            } catch {
                let alert = NSAlert(error: error)
                alert.messageText = "导出失败"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func presentSavePanel(for format: ExportFormat, suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "导出为 \(format.displayName)"
        panel.nameFieldStringValue = sanitisedFileName(suggestedName) + "." + format.fileExtension
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func sanitisedFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    enum ExportError: LocalizedError {
        case missingExporter(String)

        var errorDescription: String? {
            switch self {
            case .missingExporter(let name): return "未注册 \(name) 导出器。"
            }
        }
    }
}

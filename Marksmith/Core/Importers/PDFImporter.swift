import Foundation
import AppKit
import PDFKit
import Vision

/// Extracts plain text from a PDF.
///
/// A PDF is a *layout* artefact: it contains no notion of headings, lists or
/// tables. This importer therefore never pretends to rebuild structure — it
/// returns one paragraph per page plus an explicit, always-present warning.
/// Pages without a text layer are passed through Vision OCR (zh-Hans + en-US).
struct PDFImporter: DocumentImporter {
    let format = StandardImportFormats.pdf

    private static let maximumOCRPages = 20

    func importDocument(_ request: ImportRequest) async throws -> ImportResult {
        // PDFKit is an AppKit-adjacent framework; keep every PDFPage/NSImage
        // interaction on the main actor even though parsing runs detached.
        let extracted = try await MainActor.run { () throws -> (String, [String]) in
            guard let document = PDFDocument(url: request.url) else {
                throw ImportError.unreadable("无法打开 PDF（可能已加密或文件损坏）。")
            }
            guard document.pageCount > 0 else {
                throw ImportError.emptyDocument("PDF 没有页面。")
            }

            var paragraphs: [String] = []
            var warnings: [String] = []
            var usedOCR = false
            var ocrPages = 0

            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                var text = Self.normalise(page.string ?? "")
                if text.isEmpty {
                    if ocrPages < Self.maximumOCRPages {
                        ocrPages += 1
                        usedOCR = true
                        text = Self.normalise(Self.recognise(page))
                    }
                }
                if !text.isEmpty { paragraphs.append(text) }
            }

            warnings.append("PDF 是排版结果，本次仅提取纯文本：标题层级、表格、粗体、图片与双栏阅读顺序均未还原。")
            if usedOCR {
                warnings.append("部分页面没有文本层，已用系统 OCR（简体中文 + 英文）识别，结果可能存在错字。")
            }
            if document.pageCount > Self.maximumOCRPages, usedOCR {
                warnings.append("最多对前 \(Self.maximumOCRPages) 页无文本页面执行 OCR，其余页面已跳过。")
            }
            guard !paragraphs.isEmpty else {
                throw ImportError.emptyDocument("未提取到任何文字：该 PDF 可能是扫描件或纯图片，且 OCR 未识别出内容。")
            }

            var model = MarkdownModel()
            model.blocks = paragraphs.map { .paragraph([.text($0)]) }
            return (MarkdownSerializer.serialize(model), warnings)
        }

        return ImportResult(markdown: extracted.0,
                            warnings: extracted.1,
                            sourceURL: request.url,
                            format: format)
    }

    // MARK: - Text cleanup

    private static func normalise(_ raw: String) -> String {
        var lines: [String] = []
        var sawBlank = false
        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                sawBlank = true
                continue
            }
            if sawBlank, !lines.isEmpty { lines.append("") }
            sawBlank = false
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - OCR fallback

    private static func recognise(_ page: PDFPage) -> String {
        let box = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let image = page.thumbnail(of: NSSize(width: max(800, box.width * scale),
                                              height: max(800, box.height * scale)),
                                   for: .mediaBox)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return ""
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        return request.results?
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n") ?? ""
    }
}

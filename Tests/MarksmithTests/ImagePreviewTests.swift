import XCTest
import WebKit
import AppKit
@testable import Marksmith

/// Regression suite for "preview shows a broken image box".
///
/// The defect was NOT in the renderer: `ImageResolver` inlines relative
/// images correctly when it receives the source document's folder. The bug
/// was `ContentView` asking `NSDocumentController.shared.currentDocument`
/// (nil / wrong window under SwiftUI `DocumentGroup`) for that folder.
/// These tests lock down both halves of the fix: per-window folder routing
/// and the whole render → WKWebView pipeline.
final class ImagePreviewTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        ImageResolver.clearCache()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MarksmithImageTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        ImageResolver.clearCache()
        super.tearDown()
    }

    // MARK: - Helpers

    private func pngData(width: Int = 6, height: Int = 4) throws -> Data {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ImagePreviewTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "cannot build test PNG"])
        }
        return data
    }

    @discardableResult
    private func write(_ data: Data, at relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func render(_ markdown: String, base: URL?, embed: Bool = true) -> String {
        let options = HTMLRenderOptions(baseDirectory: base, embedLocalImages: embed)
        return HTMLRenderer(options: options).render(MarkdownParser().parse(markdown))
    }

    private func fourImageMarkdown() -> String {
        ["a", "b", "c", "d"].map { "![\($0)](Support/\($0).png)" }.joined(separator: "\n\n")
    }

    // MARK: - 1. Core regression: correct base directory

    func testRelativeImagesAreEmbeddedWhenDocumentURLIsKnown() throws {
        let png = try pngData()
        for name in ["a", "b", "c", "d"] { try write(png, at: "Support/\(name).png") }

        let documentURL = root.appendingPathComponent("doc.md")
        let folder = ImageResolver.documentDirectory(for: documentURL)
        XCTAssertEqual(folder?.path, root.path)

        let html = render(fourImageMarkdown(), base: folder)
        XCTAssertEqual(html.components(separatedBy: "data:image/png;base64,").count - 1, 4,
                       "all four relative images must be inlined")
        XCTAssertFalse(html.contains("src=\"Support/"),
                       "no relative src may survive: WKWebView can only read the resource bundle")
        XCTAssertFalse(html.contains("data-marksmith-missing"))
    }

    func testMissingBaseDirectoryKeepsRelativePathWithoutMissingFlag() throws {
        let png = try pngData()
        try write(png, at: "Support/a.png")
        let html = render("![a](Support/a.png)", base: nil)
        XCTAssertTrue(html.contains("<img src=\"Support/a.png\" alt=\"a\">"))
        XCTAssertFalse(html.contains("data:image"))
        XCTAssertFalse(html.contains("data-marksmith-missing"),
                       "without a base directory we cannot claim the file is missing")
    }

    // MARK: - 2. The exact document reported by the user

    func testPhotoScopeDocumentEmbedsAllFourScreenshots() throws {
        let url = URL(fileURLWithPath:
            "/Volumes/machack2/download/swift_program/PhotoScope/PhotoScope-操作与功能说明.md")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("sample document only exists on the author's machine")
        }
        let markdown = try String(contentsOf: url, encoding: .utf8)
        let html = render(markdown, base: ImageResolver.documentDirectory(for: url))

        XCTAssertEqual(html.components(separatedBy: "data:image/png;base64,").count - 1, 4)
        XCTAssertFalse(html.contains("src=\"Support/"))
        XCTAssertTrue(html.contains("alt=\"PhotoScope 主界面\""))
        XCTAssertTrue(html.contains("alt=\"双张并排对比\""))
    }

    // MARK: - 3. Real WKWebView rendering

    @MainActor
    func testEmbeddedImagesActuallyDisplayInPreviewShell() async throws {
        let png = try pngData(width: 12, height: 8)
        for name in ["a", "b", "c", "d"] { try write(png, at: "Support/\(name).png") }
        let body = render(fourImageMarkdown(),
                          base: ImageResolver.documentDirectory(for: root.appendingPathComponent("doc.md")))

        guard let templateURL = AppResources.url("preview.html"),
              let resourcesRoot = AppResources.previewRoot else {
            XCTFail("preview.html / resource bundle missing")
            return
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let loader = ImagePreviewLoader()
        webView.navigationDelegate = loader
        await withCheckedContinuation { continuation in
            loader.onFinish = { continuation.resume() }
            webView.loadFileURL(templateURL, allowingReadAccessTo: resourcesRoot)
        }
        _ = try? await webView.evaluateJavaScript("window.updateContent(\(HTML.jsStringLiteral(body)))")

        let script = "Array.from(document.querySelectorAll('#content img'))" +
            ".map(function(i){return (i.complete && i.naturalWidth > 0) ? '1' : '0';}).join('')"
        var state = ""
        for _ in 0..<24 {
            state = await Self.evaluate(script, in: webView)
            if state == "1111" { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(state, "1111", "every embedded image must finish decoding in WKWebView")
    }

    @MainActor
    private static func evaluate(_ script: String, in webView: WKWebView) async -> String {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value as? String ?? "")
            }
        }
    }

    // MARK: - 4. Destination variants

    func testPathVariantsResolveCorrectly() throws {
        let png = try pngData()
        try write(png, at: "docs/中文 目录/图 片.png")
        try write(png, at: "up.png")
        let absolute = try write(png, at: "absolute.png")

        let markdown = """
        ![space](中文%20目录/图%20片.png)

        ![parent](../up.png)

        ![absolute](\(absolute.path))

        ![fragment](中文%20目录/图%20片.png#zoom)

        ![embedded](data:image/png;base64,AAAA)

        ![remote](https://example.com/photo.png)

        ![blocked](file:///etc/hosts)
        """
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        let html = render(markdown, base: docs)

        for alt in ["space", "parent", "absolute", "fragment"] {
            let snippet = html.split(separator: "\n").first { $0.contains("alt=\"\(alt)\"") }
            XCTAssertTrue(String(snippet ?? "").contains("src=\"data:image/png;base64,"),
                          "\(alt) must be embedded: \(String(snippet ?? ""))")
        }
        XCTAssertTrue(html.contains("src=\"data:image/png;base64,AAAA\""))
        XCTAssertTrue(html.contains("src=\"https://example.com/photo.png\""))
        XCTAssertNil(URLPolicy.imageDestination("file:///etc/hosts"))
        XCTAssertTrue(html.contains("<span>blocked</span>"), "file: URLs stay blocked by URLPolicy")
    }

    // MARK: - 5. Missing / empty images are visible instead of a blank box

    func testMissingAndEmptyImagesAreMarked() throws {
        try write(Data(), at: "Support/empty.png")
        let html = render("![gone](Support/missing.png)\n\n![empty](Support/empty.png)",
                          base: root)
        XCTAssertTrue(html.contains("src=\"Support/missing.png\""))
        XCTAssertTrue(html.contains("src=\"Support/empty.png\""))
        XCTAssertEqual(html.components(separatedBy: "data-marksmith-missing=\"1\"").count - 1, 2)
        XCTAssertTrue(html.contains("图片未找到"))
        XCTAssertFalse(html.contains("data:image/png;base64,"))
    }

    func testZeroByteImageIsNotEmbeddedForDOCX() throws {
        try write(Data(), at: "Support/empty.png")
        XCTAssertNil(ImageResolver.localImageData("Support/empty.png", baseDirectory: root))
    }

    // MARK: - 6. Cache

    func testImageCacheAvoidsRepeatedDiskReadsAndInvalidatesOnEdit() throws {
        let first = try pngData(width: 6, height: 4)
        let file = try write(first, at: "Support/cached.png")
        let before = ImageResolver.cacheStatistics()

        let one = ImageResolver.resolve("Support/cached.png", baseDirectory: root)
        let two = ImageResolver.resolve("Support/cached.png", baseDirectory: root)
        let after = ImageResolver.cacheStatistics()

        XCTAssertTrue(one.hasPrefix("data:image/png;base64,"))
        XCTAssertEqual(one, two)
        XCTAssertEqual(after.misses - before.misses, 1, "only the first lookup reads the PNG")
        XCTAssertEqual(after.hits - before.hits, 1, "second lookup must be a cache hit")

        // Different length (and mtime) must invalidate the cached data URI.
        let bigger = try pngData(width: 40, height: 20)
        try bigger.write(to: file)
        let three = ImageResolver.resolve("Support/cached.png", baseDirectory: root)
        XCTAssertNotEqual(three, one)
        XCTAssertEqual(ImageResolver.cacheStatistics().misses - before.misses, 2)
    }

    // MARK: - 7. Per-window document identity (the actual root cause)

    func testDocumentDirectoryIsPerWindow() {
        let first = URL(fileURLWithPath: "/tmp/work/first/report.md")
        let second = URL(fileURLWithPath: "/tmp/other/second/notes.md")

        XCTAssertEqual(ImageResolver.documentDirectory(for: first)?.path, "/tmp/work/first")
        XCTAssertEqual(ImageResolver.documentDirectory(for: second)?.path, "/tmp/other/second")
        XCTAssertNotEqual(ImageResolver.documentDirectory(for: first),
                          ImageResolver.documentDirectory(for: second),
                          "two open windows must never share a base directory")
        XCTAssertNil(ImageResolver.documentDirectory(for: nil))
        XCTAssertEqual(ImageResolver.documentTitle(for: first), "report")
        XCTAssertEqual(ImageResolver.documentTitle(for: second), "notes")
        XCTAssertEqual(ImageResolver.documentTitle(for: nil), "Untitled")
    }
}

private final class ImagePreviewLoader: NSObject, WKNavigationDelegate {
    var onFinish: (() -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish()
    }

    private func finish() {
        onFinish?()
        onFinish = nil
    }
}

import Foundation

/// Single source of truth for app identity. Rename the product here (plus
/// `Package.swift`, `Info.plist` and `scripts/build-app.sh`) if you rebrand.
enum AppMetadata {
    static let name = "Marksmith"
    static let displayName = "Marksmith"
    static let bundleIdentifier = "local.marksmith.Marksmith"
    static let version = "1.2.2"
    static let resourceBundleName = "Marksmith_Marksmith"
    static let editorUTI = "net.daringfireball.markdown"
}

/// Resolves the SwiftPM resource bundle both inside a packaged .app and when
/// running straight from `swift build` / `swift test`.
///
/// A packaged app has no `Bundle.main` resource bundle by default, so checking
/// `Bundle.module` alone fails (it looks next to the executable at the .app
/// root). We probe the known locations explicitly, then fall back.
enum AppResources {

    static let bundle: Bundle = resolveBundle()

    private static func resolveBundle() -> Bundle {
        let name = AppMetadata.resourceBundleName
        let main = Bundle.main
        var candidates: [URL] = []
        candidates.append(main.bundleURL.appendingPathComponent(name + ".bundle"))
        if let resourceURL = main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent(name + ".bundle"))
        }
        candidates.append(main.bundleURL.appendingPathComponent("Contents/Resources/" + name + ".bundle"))

        for candidate in candidates {
            if let bundle = Bundle(url: candidate) { return bundle }
        }
        return Bundle.module
    }

    /// Returns the URL for a resource path relative to `Resources/`.
    static func url(_ relativePath: String) -> URL? {
        let components = relativePath.split(separator: "/").map(String.init)
        let directory = components.dropLast().joined(separator: "/")
        let filename = components.last ?? relativePath
        let ext = (filename as NSString).pathExtension
        let basename = ext.isEmpty ? filename : (filename as NSString).deletingPathExtension
        let subdirectory = directory.isEmpty ? "Resources" : "Resources/" + directory

        if let url = bundle.url(forResource: basename,
                                withExtension: ext.isEmpty ? nil : ext,
                                subdirectory: subdirectory) {
            return url
        }
        // Flat layout fallback (some build scripts copy Resources/ contents directly).
        if let url = bundle.url(forResource: basename,
                                withExtension: ext.isEmpty ? nil : ext) {
            return url
        }
        if let root = bundle.resourceURL {
            let candidate = root.appendingPathComponent("Resources").appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let flat = root.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: flat.path) { return flat }
        }
        return nil
    }

    static func data(_ relativePath: String) -> Data? {
        guard let url = url(relativePath) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func string(_ relativePath: String) -> String? {
        guard let data = data(relativePath) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Directory containing `preview.html`; used as WKWebView's read-access root.
    static var previewRoot: URL? {
        url("preview.html")?.deletingLastPathComponent()
    }
}

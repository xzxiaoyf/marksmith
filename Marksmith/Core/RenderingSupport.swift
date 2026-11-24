import Foundation
import AppKit

// MARK: - HTML escaping

enum HTML {
    /// Escapes text content. Note: `'` is intentionally left alone because
    /// text nodes are not quoted attribute values.
    static func escape(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.count)
        for ch in string {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: out.append(ch)
            }
        }
        return out
    }

    /// Escapes a value used inside a double-quoted HTML attribute.
    static func attribute(_ string: String) -> String {
        var out = ""
        out.reserveCapacity(string.count)
        for ch in string {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    static func xml(_ string: String) -> String { attribute(string) }

    /// JSON-encodes a Swift string into a JavaScript string literal.
    /// Used instead of fragile manual backslash escaping in WKWebView calls.
    static func jsStringLiteral(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [string], options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        // json is `["..."]`; strip the surrounding array brackets.
        let literal = String(json.dropFirst().dropLast())
        // U+2028/U+2029 are legal in JSON but terminate JS string literals.
        return literal
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}

// MARK: - Entity decoding

enum EntityDecoder {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "copy": "©", "reg": "®", "trade": "™",
        "mdash": "—", "ndash": "–", "hellip": "…", "laquo": "«", "raquo": "»",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "middot": "·"
    ]

    /// Decodes a small, safe subset of HTML entities. Unknown entities are
    /// returned verbatim so they display literally (and are re-escaped later).
    static func decode(_ string: String) -> String {
        guard string.contains("&") else { return string }
        var out = ""
        var i = string.startIndex
        while i < string.endIndex {
            guard string[i] == "&" else { out.append(string[i]); i = string.index(after: i); continue }
            guard let semi = string[i...].firstIndex(of: ";"),
                  distance(string, from: i, to: semi) <= 12 else {
                out.append("&"); i = string.index(after: i); continue
            }
            let body = String(string[string.index(after: i)..<semi])
            var decoded: String?
            if let value = named[body] {
                decoded = value
            } else if body.hasPrefix("#") {
                let digits = body.dropFirst()
                let scalar: UInt32?
                if digits.hasPrefix("x") || digits.hasPrefix("X") {
                    scalar = UInt32(digits.dropFirst(), radix: 16)
                } else {
                    scalar = UInt32(digits)
                }
                if let scalar, let unicode = Unicode.Scalar(scalar), unicode.value != 0 {
                    decoded = String(Character(unicode))
                }
            }
            if let decoded {
                out += decoded
                i = string.index(after: semi)
            } else {
                out.append("&")
                i = string.index(after: i)
            }
        }
        return out
    }

    private static func distance(_ s: String, from: String.Index, to: String.Index) -> Int {
        s.distance(from: from, to: to)
    }
}

// MARK: - URL policy

enum URLPolicy {
    private static let forbidden = ["javascript:", "vbscript:", "file:", "about:"]

    /// Returns a safe href, or `nil` when the destination must be dropped.
    static func linkDestination(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased().replacingOccurrences(of: " ", with: "")
        if forbidden.contains(where: { lowered.hasPrefix($0) }) { return nil }
        return EntityDecoder.decode(trimmed)
    }

    static func imageDestination(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased().replacingOccurrences(of: " ", with: "")
        if forbidden.contains(where: { lowered.hasPrefix($0) }) { return nil }
        return EntityDecoder.decode(trimmed)
    }
}

// MARK: - Local image embedding

/// Converts relative image paths to `data:` URIs so previews and exports are
/// self-contained and do not depend on WKWebView sandbox file-access rules.
enum ImageResolver {
    // MARK: - Per-window document identity
    //
    // Pure functions so the multi-window behaviour (each window resolves
    // against its OWN document folder) can be unit tested without AppKit.

    static func documentDirectory(for documentURL: URL?) -> URL? {
        documentURL?.deletingLastPathComponent()
    }

    static func documentTitle(for documentURL: URL?) -> String {
        documentURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    // MARK: - data-URI cache
    //
    // A four-screenshot document already produces ~4 MB of HTML. Re-reading
    // and re-encoding every PNG on each debounced keystroke is wasteful, so
    // cache by path + size + mtime (editing the file invalidates the entry).
    // NSCache is thread-safe; cost is the raw byte count, capped at 64 MB.

    private static let cache: NSCache<NSString, NSString> = {
        let value = NSCache<NSString, NSString>()
        value.totalCostLimit = 64 * 1024 * 1024
        return value
    }()
    private static let statsLock = NSLock()
    private static var hits = 0
    private static var misses = 0

    static func clearCache() {
        cache.removeAllObjects()
        statsLock.lock()
        hits = 0
        misses = 0
        statsLock.unlock()
    }

    static func cacheStatistics() -> (hits: Int, misses: Int) {
        statsLock.lock()
        defer { statsLock.unlock() }
        return (hits, misses)
    }

    private static func recordHit() {
        statsLock.lock()
        hits += 1
        statsLock.unlock()
    }

    private static func recordMiss() {
        statsLock.lock()
        misses += 1
        statsLock.unlock()
    }

    /// Resolves a Markdown image destination to a local file URL.
    /// Returns nil for remote / data URIs and when no base directory exists.
    static func localFileURL(for source: String, baseDirectory: URL?) -> URL? {
        guard let baseDirectory,
              !source.hasPrefix("data:"),
              !source.hasPrefix("data%3A"),
              !source.hasPrefix("http://"), !source.hasPrefix("https://") else { return nil }

        let pathPart: String
        if source.hasPrefix("file://"), let url = URL(string: source), url.isFileURL {
            pathPart = url.path
        } else {
            // Strip a fragment (#anchor) before decoding %20 and friends.
            let parts = source.split(separator: "#", maxSplits: 1)
            let raw = String(parts[0])
            pathPart = raw.removingPercentEncoding ?? raw
        }
        guard !pathPart.isEmpty else { return nil }
        if pathPart.hasPrefix("/") {
            return URL(fileURLWithPath: pathPart).standardizedFileURL
        }
        return baseDirectory.appendingPathComponent(pathPart).standardizedFileURL
    }

    /// True when a local image destination cannot be embedded: missing file,
    /// directory, or zero-byte file. Remote, data and URL-less destinations
    /// are deliberately NOT flagged.
    static func isMissingLocalImage(_ source: String, baseDirectory: URL?) -> Bool {
        guard let url = localFileURL(for: source, baseDirectory: baseDirectory) else {
            return false
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.int64Value > 0,
              let type = attributes[.type] as? FileAttributeType, type != .typeDirectory else {
            return true
        }
        return false
    }

    static func resolve(_ source: String, baseDirectory: URL?) -> String {
        guard let fileURL = localFileURL(for: source, baseDirectory: baseDirectory),
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber, size.int64Value > 0,
              let modified = attributes[.modificationDate] as? Date else { return source }

        let key = "\(fileURL.path)|\(size.int64Value)|\(modified.timeIntervalSince1970)"
        if let cached = cache.object(forKey: key as NSString) {
            recordHit()
            return cached as String
        }
        recordMiss()
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return source }
        let uri = "data:\(mimeType(for: fileURL.pathExtension));base64,\(data.base64EncodedString())"
        cache.setObject(uri as NSString, forKey: key as NSString,
                        cost: min(Int(size.int64Value), Int.max))
        return uri
    }

    static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "bmp": return "image/bmp"
        case "tiff", "tif": return "image/tiff"
        case "heic": return "image/heic"
        default: return "image/png"
        }
    }

    /// Reads a local image for DOCX embedding. Returns nil for remote/data URLs.
    static func localImageData(_ source: String, baseDirectory: URL?) -> (Data, String)? {
        guard let url = localFileURL(for: source, baseDirectory: baseDirectory),
              let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let ext = url.pathExtension.lowercased()
        let contentType: String
        switch ext {
        case "jpg", "jpeg": contentType = "image/jpeg"
        case "gif": contentType = "image/gif"
        case "webp": contentType = "image/webp"
        case "bmp": contentType = "image/bmp"
        default: contentType = "image/png"
        }
        return (data, contentType)
    }

    /// Pixel dimensions used by the OOXML drawing extent (in EMU).
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return (rep.pixelsWide, rep.pixelsHigh)
    }
}

import Foundation
import zlib

/// Read-only ZIP reader for OOXML packages (.docx / .xlsx).
///
/// Uses the system zlib module (no SwiftPM dependency) and only supports the
/// two methods OOXML ever emits: stored (0) and raw deflate (8). Central
/// directory metadata is authoritative, so files written with a data
/// descriptor (streaming writers) are handled correctly.
struct OOXMLArchive {

    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let bytes: [UInt8]
    private let entries: [String: Entry]

    /// Upper bound for a single inflated member; guards against zip bombs.
    private static let maxMemberSize = 64 * 1024 * 1024

    init(data: Data) throws {
        bytes = [UInt8](data)
        var parsed: [String: Entry] = [:]

        guard let eocd = Self.findEOCD(bytes) else {
            throw OOXMLArchiveError.invalidArchive("未找到 ZIP 结束记录")
        }
        let count = Int(Self.u16(bytes, eocd + 10))
        var cursor = Int(Self.u32(bytes, eocd + 16))
        guard count > 0, cursor >= 0, cursor + 46 <= bytes.count else {
            throw OOXMLArchiveError.invalidArchive("ZIP 中央目录为空或越界")
        }

        for _ in 0..<count {
            guard cursor + 46 <= bytes.count,
                  Self.u32(bytes, cursor) == 0x02014b50 else {
                throw OOXMLArchiveError.invalidArchive("ZIP 中央目录损坏")
            }
            let method = Self.u16(bytes, cursor + 10)
            let compressed = Self.u32(bytes, cursor + 20)
            let uncompressed = Self.u32(bytes, cursor + 24)
            let nameLength = Int(Self.u16(bytes, cursor + 28))
            let extraLength = Int(Self.u16(bytes, cursor + 30))
            let commentLength = Int(Self.u16(bytes, cursor + 32))
            let localOffset = Int(Self.u32(bytes, cursor + 42))
            let nameStart = cursor + 46

            guard compressed != 0xFFFFFFFF, uncompressed != 0xFFFFFFFF,
                  localOffset != 0xFFFFFFFF else {
                throw OOXMLArchiveError.unsupported("不支持 ZIP64 格式的文档")
            }
            guard nameStart + nameLength + extraLength + commentLength <= bytes.count else {
                throw OOXMLArchiveError.invalidArchive("ZIP 文件名越界")
            }
            let nameBytes = bytes[nameStart..<(nameStart + nameLength)]
            let name = String(decoding: nameBytes, as: UTF8.self)
            parsed[name] = Entry(name: name,
                                 method: method,
                                 compressedSize: Int(compressed),
                                 uncompressedSize: Int(uncompressed),
                                 localHeaderOffset: localOffset)
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        entries = parsed
    }

    var entryNames: [String] { Array(entries.keys) }

    func hasEntry(_ path: String) -> Bool { entries[path] != nil }

    func data(for path: String) throws -> Data {
        guard let entry = entries[path] else {
            throw OOXMLArchiveError.missingEntry(path)
        }
        let header = entry.localHeaderOffset
        guard header + 30 <= bytes.count, Self.u32(bytes, header) == 0x04034b50 else {
            throw OOXMLArchiveError.invalidArchive("本地文件头损坏：\(path)")
        }
        let nameLength = Int(Self.u16(bytes, header + 26))
        let extraLength = Int(Self.u16(bytes, header + 28))
        let start = header + 30 + nameLength + extraLength
        let end = start + entry.compressedSize
        guard start >= 0, end <= bytes.count, entry.compressedSize >= 0 else {
            throw OOXMLArchiveError.invalidArchive("文件数据越界：\(path)")
        }
        guard entry.uncompressedSize <= Self.maxMemberSize else {
            throw OOXMLArchiveError.unsupported("单个成员超过 64 MB，已拒绝解压：\(path)")
        }
        let raw = Data(bytes[start..<end])

        switch entry.method {
        case 0:
            return raw
        case 8:
            guard let inflated = Self.inflateRaw(raw, expected: max(1, entry.uncompressedSize)) else {
                throw OOXMLArchiveError.invalidArchive("deflate 解压失败：\(path)")
            }
            return inflated
        default:
            throw OOXMLArchiveError.unsupported("不支持的 ZIP 压缩方式 (\(entry.method))：\(path)")
        }
    }

    func string(for path: String) throws -> String {
        let data = try data(for: path)
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Raw deflate (windowBits = -15)

    private static func inflateRaw(_ input: Data, expected: Int) -> Data? {
        let capacity = max(1, expected)
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { output.deallocate() }

        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        let result: Int32 = input.withUnsafeBytes { rawInput -> Int32 in
            stream.next_in = UnsafeMutablePointer<Bytef>(
                mutating: rawInput.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(input.count)
            stream.next_out = UnsafeMutablePointer<Bytef>(output)
            stream.avail_out = uInt(capacity)
            return inflate(&stream, Z_FINISH)
        }
        guard result == Z_STREAM_END else { return nil }
        return Data(bytes: output, count: capacity - Int(stream.avail_out))
    }

    // MARK: - Little-endian byte helpers

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) |
            (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func findEOCD(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        let lowerBound = max(0, bytes.count - 22 - 65535)
        var index = bytes.count - 22
        while index >= lowerBound {
            if bytes[index] == 0x50, bytes[index + 1] == 0x4B,
               bytes[index + 2] == 0x05, bytes[index + 3] == 0x06 {
                return index
            }
            index -= 1
        }
        return nil
    }
}

enum OOXMLArchiveError: LocalizedError {
    case invalidArchive(String)
    case missingEntry(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidArchive(let detail): return "文件不是有效的 OOXML 包：\(detail)。"
        case .missingEntry(let path): return "文档缺少必需的条目 \(path)。"
        case .unsupported(let detail): return detail
        }
    }
}

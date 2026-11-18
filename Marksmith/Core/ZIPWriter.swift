import Foundation

/// Minimal, dependency-free ZIP writer using the "stored" (uncompressed)
/// method. Sufficient for OOXML packages, and avoids shelling out to
/// `/usr/bin/zip` (which would break under App Sandbox / hardened runtime).
enum ZIPWriter {

    struct Entry {
        let path: String
        let data: Data
    }

    static func archive(entries: [Entry]) -> Data {
        let (dosTime, dosDate) = dosTimestamp()
        var output = Data()
        var central = Data()
        var offsets: [UInt32] = []

        for entry in entries {
            let name = Data(entry.path.utf8)
            let payload = entry.data
            let crc = crc32(payload)
            let offset = UInt32(output.count)
            offsets.append(offset)

            // Local file header
            appendUInt32(&output, 0x04034B50)
            appendUInt16(&output, 20)                     // version needed
            appendUInt16(&output, 0x0800)                 // UTF-8 filename flag
            appendUInt16(&output, 0)                      // stored
            appendUInt16(&output, dosTime)
            appendUInt16(&output, dosDate)
            appendUInt32(&output, crc)
            appendUInt32(&output, UInt32(payload.count))
            appendUInt32(&output, UInt32(payload.count))
            appendUInt16(&output, UInt16(name.count))
            appendUInt16(&output, 0)                      // extra length
            output.append(name)
            output.append(payload)

            // Central directory header
            appendUInt32(&central, 0x02014B50)
            appendUInt16(&central, 20)                    // version made by
            appendUInt16(&central, 20)                    // version needed
            appendUInt16(&central, 0x0800)
            appendUInt16(&central, 0)
            appendUInt16(&central, dosTime)
            appendUInt16(&central, dosDate)
            appendUInt32(&central, crc)
            appendUInt32(&central, UInt32(payload.count))
            appendUInt32(&central, UInt32(payload.count))
            appendUInt16(&central, UInt16(name.count))
            appendUInt16(&central, 0)                     // extra
            appendUInt16(&central, 0)                     // comment
            appendUInt16(&central, 0)                     // disk number
            appendUInt16(&central, 0)                     // internal attrs
            appendUInt32(&central, 0)                     // external attrs
            appendUInt32(&central, offset)
            central.append(name)
        }

        let centralOffset = UInt32(output.count)
        output.append(central)

        appendUInt32(&output, 0x06054B50)
        appendUInt16(&output, 0)
        appendUInt16(&output, 0)
        appendUInt16(&output, UInt16(entries.count))
        appendUInt16(&output, UInt16(entries.count))
        appendUInt32(&output, UInt32(central.count))
        appendUInt32(&output, centralOffset)
        appendUInt16(&output, 0)
        return output
    }

    // MARK: - Byte helpers

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func dosTimestamp() -> (UInt16, UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        let year = max(1980, comps.year ?? 2026)
        let time = UInt16((comps.hour ?? 0) << 11 | (comps.minute ?? 0) << 5 | ((comps.second ?? 0) / 2))
        let date = UInt16(((year - 1980) << 9) | (comps.month ?? 1) << 5 | (comps.day ?? 1))
        return (time, date)
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

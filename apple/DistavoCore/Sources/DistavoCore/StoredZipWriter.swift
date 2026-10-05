import Foundation

/// A tiny dependency-free ZIP writer: every entry is STORED (no compression),
/// which is all a .docx needs and keeps this ~60 lines. Correct CRC-32,
/// local headers, central directory and end-of-central-directory record.
/// Timestamps are fixed (1980-01-01) so output is byte-reproducible.
/// Limits: no ZIP64, so total size and entry count must stay under 4 GiB / 65535.
struct StoredZipWriter {
    private var body = Data()
    private var central = Data()
    private var count: UInt16 = 0

    /// Standard CRC-32 (IEEE 802.3, reflected, poly 0xEDB88320).
    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    private static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    private static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }

    mutating func add(name: String, data: Data) {
        let nameBytes = Data(name.utf8)
        let crc = Self.crc32(data)
        let size = UInt32(data.count)
        let offset = UInt32(body.count)
        let dosTime: UInt16 = 0, dosDate: UInt16 = 0x0021   // 1980-01-01 00:00:00
        let flags: UInt16 = 0x0800                           // names are UTF-8

        var local = Data()
        local += Self.le32(0x0403_4B50)                      // local file header signature
        local += Self.le16(20) + Self.le16(flags) + Self.le16(0)   // version, flags, method 0 = stored
        local += Self.le16(dosTime) + Self.le16(dosDate)
        local += Self.le32(crc) + Self.le32(size) + Self.le32(size)
        local += Self.le16(UInt16(nameBytes.count)) + Self.le16(0)
        body += local + nameBytes + data

        var entry = Data()
        entry += Self.le32(0x0201_4B50)                      // central directory header signature
        entry += Self.le16(20) + Self.le16(20) + Self.le16(flags) + Self.le16(0)
        entry += Self.le16(dosTime) + Self.le16(dosDate)
        entry += Self.le32(crc) + Self.le32(size) + Self.le32(size)
        entry += Self.le16(UInt16(nameBytes.count)) + Self.le16(0) + Self.le16(0)   // name, extra, comment lengths
        entry += Self.le16(0) + Self.le16(0) + Self.le32(0) + Self.le32(offset)    // disk, int attrs, ext attrs, offset
        central += entry + nameBytes
        count += 1
    }

    /// The finished archive.
    func finish() -> Data {
        var end = Data()
        end += Self.le32(0x0605_4B50)                        // end of central directory
        end += Self.le16(0) + Self.le16(0) + Self.le16(count) + Self.le16(count)
        end += Self.le32(UInt32(central.count)) + Self.le32(UInt32(body.count)) + Self.le16(0)
        return body + central + end
    }
}

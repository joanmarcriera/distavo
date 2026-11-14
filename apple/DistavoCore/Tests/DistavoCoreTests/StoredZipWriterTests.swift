import XCTest
@testable import DistavoCore

/// StoredZipWriter backs the .docx export: CRC-32 must be standard and the archive
/// must be readable by the system `unzip`.
final class StoredZipWriterTests: XCTestCase {

    func testCRC32MatchesTheStandardCheckValue() {
        XCTAssertEqual(StoredZipWriter.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(StoredZipWriter.crc32(Data()), 0)
    }

    func testEmptyArchiveIsJustTheEndRecord() {
        let data = StoredZipWriter().finish()
        XCTAssertEqual(data.count, 22)
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x05, 0x06])
    }

    func testOutputIsByteReproducible() {
        func build() -> Data {
            var z = StoredZipWriter()
            z.add(name: "a.txt", data: Data("hello".utf8))
            return z.finish()
        }
        XCTAssertEqual(build(), build())
    }

    func testArchivePassesUnzipTestAndRoundTrips() throws {
        var z = StoredZipWriter()
        z.add(name: "word/document.xml", data: Data("<w:document>é ü 日本</w:document>".utf8))
        z.add(name: "empty.txt", data: Data())
        z.add(name: "[Content_Types].xml", data: Data(repeating: 0x41, count: 5000))
        let dir = TestTemp.root.appendingPathComponent("zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = dir.appendingPathComponent("t.zip")
        try z.finish().write(to: zip)

        let test = try run("/usr/bin/unzip", ["-t", zip.path])
        XCTAssertEqual(test.status, 0, test.output)
        XCTAssertTrue(test.output.contains("No errors detected"), test.output)

        let cat = try run("/usr/bin/unzip", ["-p", zip.path, "word/document.xml"])
        XCTAssertEqual(cat.output, "<w:document>é ü 日本</w:document>")
    }

    private func run(_ tool: String, _ args: [String]) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

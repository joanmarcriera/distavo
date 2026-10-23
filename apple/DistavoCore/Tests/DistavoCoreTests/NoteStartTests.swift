import XCTest
@testable import DistavoCore

/// #4018: how a note's date is chosen (name stamp > container creation_time minus duration > file date).
final class NoteStartTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    private func deps(created: Date?, duration: Double?) -> PipelineDeps {
        PipelineDeps(convertToWav: { _, _ in }, transcribe: { _, _ in [:] },
                     ollamaReachable: { _ in true }, summarise: { _, _, _, _ in "" },
                     audioDurationSeconds: { _ in duration },
                     containerCreationDate: { _ in created })
    }

    func testNameStampBeatsContainer() async {
        let url = URL(fileURLWithPath: "/nonexistent/interview-22-10-2026-10.00.mp4")
        let d = deps(created: Date(timeIntervalSince1970: 1), duration: 60)
        let got = await Pipeline.noteStart(for: url, deps: d, timeZone: utc)
        XCTAssertEqual(got, RecordingStamp.parse("interview-22-10-2026-10.00", timeZone: utc))
    }

    func testContainerCreationMinusDurationWhenNameHasNoStamp() async {
        let url = URL(fileURLWithPath: "/nonexistent/call-with-anna.mp4")
        let end = Date(timeIntervalSince1970: 1_792_000_000)
        let got = await Pipeline.noteStart(for: url, deps: deps(created: end, duration: 3600), timeZone: utc)
        XCTAssertEqual(got, end.addingTimeInterval(-3600))
    }

    func testNoContainerDateFallsBackToFileSystem() async {
        let url = URL(fileURLWithPath: "/nonexistent/call-with-anna.mp4")
        let got = await Pipeline.noteStart(for: url, deps: deps(created: nil, duration: 3600), timeZone: utc)
        XCTAssertNil(got, "a missing file has no file-system date either")
    }

    func testUnknownDurationDoesNotUseContainerDate() async {
        let url = URL(fileURLWithPath: "/nonexistent/call-with-anna.mp4")
        let got = await Pipeline.noteStart(for: url, deps: deps(created: Date(), duration: nil), timeZone: utc)
        XCTAssertNil(got)
    }
}

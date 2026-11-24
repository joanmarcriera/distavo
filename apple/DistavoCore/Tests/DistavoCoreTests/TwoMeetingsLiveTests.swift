import AVFoundation
import Accelerate
import XCTest
@testable import DistavoCore

/// Runs the "Was this two meetings?" rule on the per-second levels of real recordings. Skipped unless
/// `DISTAVO_TWO_MEETINGS_LIVE_AUDIO` names one or more stereo files (":"-separated, read as one recording
/// end to end). Prints times and counts only, never anything from the audio.
final class TwoMeetingsLiveTests: XCTestCase {

    func testRuleOnRealLevels() throws {
        guard let paths = ProcessInfo.processInfo.environment["DISTAVO_TWO_MEETINGS_LIVE_AUDIO"], !paths.isEmpty else {
            throw XCTSkip("set DISTAVO_TWO_MEETINGS_LIVE_AUDIO to run")
        }
        var detector = TwoMeetingsDetector(now: 0)
        var t = 0.0
        var joins: [Double] = []
        for path in paths.split(separator: ":") {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: String(path)), commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = file.processingFormat
            let second = AVAudioFrameCount(format.sampleRate)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: second))
            while file.framePosition < file.length {
                try file.read(into: buffer, frameCount: second)
                guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
                var mic: Float = 0, system: Float = 0
                vDSP_rmsqv(data[0], 1, &mic, vDSP_Length(buffer.frameLength))
                if format.channelCount > 1 { vDSP_rmsqv(data[1], 1, &system, vDSP_Length(buffer.frameLength)) }
                t += Double(buffer.frameLength) / format.sampleRate
                detector.ingest(mic: mic, system: system, at: t)
            }
            joins.append(t)
        }
        print("[two-meetings] duration \(TwoMeetingsSplit.clock(t)), files end at \(joins.map(TwoMeetingsSplit.clock))")
        if let s = detector.suggestion() {
            print("[two-meetings] gap \(TwoMeetingsSplit.clock(s.gap.start))-\(TwoMeetingsSplit.clock(s.gap.end)) "
                  + "(\(Int(s.gap.duration)) s); first half ends \(TwoMeetingsSplit.clock(s.cut.first.upperBound)), "
                  + "second starts \(TwoMeetingsSplit.clock(s.cut.second.lowerBound))")
        } else {
            print("[two-meetings] no gap offered")
        }
    }
}

import Foundation
import Accelerate
import AudioToolbox
import AVFoundation
import DistavoCore

/// Records a meeting = system audio (the other participants, from any app —
/// Zoom/Meet/Teams/browser) + this Mac's microphone (the user), with **no
/// driver, no BlackHole, no multi-output device**:
///
/// - A global **Core Audio process tap** (macOS 14.4+ API) captures the
///   digital audio other apps play, at the OS mixer — Distavo's own pid is
///   excluded. First use triggers the "System Audio Recording" permission.
/// - A **private aggregate device** combines the default output (clock) +
///   the default microphone + the tap, with drift compensation, so one IOProc
///   delivers aligned buffers. Private = invisible in Audio MIDI Setup.
/// - Output is a **stereo WAV**: left = microphone, right = system audio.
///   Everything is torn down on stop; the only persistent artifacts are the
///   two permission toggles in System Settings.
///
/// Tap/aggregate sequence adapted from insidegui/AudioCap (BSD-2 — NOTICES.md).
@available(macOS 14.2, *)
final class MeetingRecorder {

    private let queue = DispatchQueue(label: "distavo.meeting-recorder", qos: .userInitiated)

    private var tapID: AudioObjectID = .unknown
    private var aggregateID: AudioObjectID = .unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var outputBuffer: AVAudioPCMBuffer?
    private var micChannelCount = 1

    // Written on `queue` while recording, read after stop — used to tell the
    // user when a permission problem produced a silent track (a denied
    // system-audio permission yields zeros, not an error).
    private var micPeak: Float = 0
    private var tapPeak: Float = 0

    private(set) var isRecording = false
    private(set) var fileURL: URL?

    struct Outcome {
        let url: URL
        let microphoneHeard: Bool
        let systemAudioHeard: Bool
    }

    static func fileName(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Meeting \(formatter.string(from: date)).wav"
    }

    func start(into folder: URL) throws {
        guard !isRecording else { return }

        // 1. Global tap of everything except our own process. Creating the tap
        // is what triggers the System Audio Recording permission prompt.
        let ownProcess = try AudioObjectID.translatePIDToProcessObjectID(
            pid: ProcessInfo.processInfo.processIdentifier)
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted
        tapDescription.isPrivate = true
        var newTapID = AudioObjectID.unknown
        let tapErr = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard tapErr == noErr, newTapID.isValid else {
            throw CaptureError.coreAudio("create system-audio tap", tapErr)
        }
        tapID = newTapID

        do {
            // 2. Private aggregate: default output (clock source — a tap-only
            // aggregate silently yields zeros) + default mic + the tap.
            let outputDevice = try AudioObjectID.readDefaultSystemOutputDevice()
            let outputUID = try outputDevice.readDeviceUID()
            let inputDevice = try AudioObjectID.readDefaultInputDevice()
            let inputUID = try inputDevice.readDeviceUID()
            micChannelCount = max(1, (try? inputDevice.readInputChannelCount()) ?? 1)

            let description: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Distavo Meeting Recorder",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUID],
                    [kAudioSubDeviceUIDKey: inputUID,
                     kAudioSubDeviceDriftCompensationKey: true],
                ],
                kAudioAggregateDeviceTapListKey: [
                    [kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                     kAudioSubTapDriftCompensationKey: true],
                ],
            ]
            var newAggregateID = AudioObjectID.unknown
            let aggErr = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
            guard aggErr == noErr, newAggregateID.isValid else {
                throw CaptureError.coreAudio("create aggregate device", aggErr)
            }
            aggregateID = newAggregateID

            // 3. Output file: stereo float32 WAV at the tap's sample rate
            // (mic = left, system audio = right; transcription downmixes).
            let sampleRate = try tapID.readAudioTapStreamBasicDescription().mSampleRate
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
                throw CaptureError.setup("could not create output format @ \(sampleRate) Hz")
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(Self.fileName())
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
            ]
            file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
            fileURL = url
            micPeak = 0
            tapPeak = 0
            let micChannels = micChannelCount

            // 4. One IOProc reads the aggregate's aligned input buffers:
            // the mic's channels come first (sub-device order), the tap's
            // stereo mixdown after — mix each group down to one file channel.
            var newProcID: AudioDeviceIOProcID?
            let procErr = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, queue) {
                [weak self] _, inInputData, _, _, _ in
                guard let self, let file = self.file else { return }
                let buffers = UnsafeMutableAudioBufferListPointer(
                    UnsafeMutablePointer(mutating: inInputData))
                self.writeMixed(buffers: buffers, micChannels: micChannels,
                                format: format, to: file)
            }
            guard procErr == noErr, let procID = newProcID else {
                throw CaptureError.coreAudio("create IO proc", procErr)
            }
            ioProcID = procID

            let startErr = AudioDeviceStart(aggregateID, procID)
            guard startErr == noErr else { throw CaptureError.coreAudio("start device", startErr) }
            isRecording = true
        } catch {
            teardown()
            throw error
        }
    }

    /// Stops, tears down the tap + aggregate completely, and reports whether
    /// each side of the recording actually contained signal.
    func stop() -> Outcome? {
        guard isRecording, let url = fileURL else { return nil }
        isRecording = false
        teardown()
        return Outcome(url: url,
                       microphoneHeard: micPeak > 0.001,
                       systemAudioHeard: tapPeak > 0.001)
    }

    private func teardown() {
        if aggregateID.isValid {
            if let procID = ioProcID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
                ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
        // Flush any in-flight IO block before closing the file.
        queue.sync { [weak self] in
            self?.file = nil
            self?.outputBuffer = nil
        }
    }

    /// Runs on `queue`. Splits the aggregate's input channels into microphone
    /// (first `micChannels`) and tap (the rest), averages each group into one
    /// channel of the stereo output buffer, tracks peaks, writes to the file.
    private func writeMixed(buffers: UnsafeMutableAudioBufferListPointer,
                            micChannels: Int, format: AVAudioFormat, to file: AVAudioFile) {
        guard let firstBuffer = buffers.first(where: { $0.mDataByteSize > 0 }) else { return }
        let frames = Int(firstBuffer.mDataByteSize) /
            (MemoryLayout<Float>.size * max(1, Int(firstBuffer.mNumberChannels)))
        guard frames > 0 else { return }

        if outputBuffer == nil || Int(outputBuffer!.frameCapacity) < frames {
            outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        }
        guard let out = outputBuffer, let outData = out.floatChannelData else { return }
        out.frameLength = AVAudioFrameCount(frames)
        vDSP_vclr(outData[0], 1, vDSP_Length(frames))
        vDSP_vclr(outData[1], 1, vDSP_Length(frames))

        var globalChannel = 0
        var micMixed = 0
        var tapMixed = 0
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let available = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let count = min(frames, available)
            for channel in 0..<channels {
                let isMic = globalChannel < micChannels
                let target = outData[isMic ? 0 : 1]
                for frame in 0..<count {
                    target[frame] += data[frame * channels + channel]
                }
                if isMic { micMixed += 1 } else { tapMixed += 1 }
                globalChannel += 1
            }
        }
        if micMixed > 1 {
            var scale = 1 / Float(micMixed)
            vDSP_vsmul(outData[0], 1, &scale, outData[0], 1, vDSP_Length(frames))
        }
        if tapMixed > 1 {
            var scale = 1 / Float(tapMixed)
            vDSP_vsmul(outData[1], 1, &scale, outData[1], 1, vDSP_Length(frames))
        }

        var peak: Float = 0
        vDSP_maxmgv(outData[0], 1, &peak, vDSP_Length(frames))
        micPeak = max(micPeak, peak)
        vDSP_maxmgv(outData[1], 1, &peak, vDSP_Length(frames))
        tapPeak = max(tapPeak, peak)

        try? file.write(from: out)
    }
}

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
/// - Output is a **stereo WAV**: left = microphone, right = system audio,
///   loudness-balanced on stop (`StereoBalancer`) so a quiet speaker isn't
///   drowned by the meeting side. Everything is torn down on stop; the only
///   persistent artifacts are the two permission toggles in System Settings.
///
/// Tap/aggregate sequence adapted from insidegui/AudioCap (BSD-2 — NOTICES.md).
@available(macOS 14.2, *)
final class MeetingRecorder {

    private let queue = DispatchQueue(label: "distavo.meeting-recorder", qos: .userInitiated)

    private var tapID: AudioObjectID = .unknown
    private var aggregateID: AudioObjectID = .unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var partURL: URL?
    private var outputBuffer: AVAudioPCMBuffer?
    private var micChannelCount = 1
    private var skipChannelCount = 0          // input channels of the output device (not the mic)
    private var tapUUIDString = ""
    private var outputFormat: AVAudioFormat?
    /// Name/UID of the input currently recorded (menu label, provenance), nil until started (#4039).
    private(set) var inputName: String?
    private(set) var inputUID: String?

    // Written on `queue` while recording, read after stop — used to tell the
    // user when a permission problem produced a silent track (a denied
    // system-audio permission yields zeros, not an error).
    private var micPeak: Float = 0
    private var tapPeak: Float = 0

    // Level metering for silence handling (Vikunja #2665): sum of squares and
    // frame count per output channel since the last `drainLevels()`. Touched
    // only on `queue` (the IOProc runs there), so no locks in the callback.
    private var micSumSq: Double = 0
    private var tapSumSq: Double = 0
    private var levelFrames = 0

    private(set) var isRecording = false
    private(set) var fileURL: URL?
    /// When the device was started, i.e. when audio began going into the file: the
    /// zero of the recording offsets that key-moment markers use (#2950).
    private(set) var startedAt: Date?

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
            try buildAggregate(inputDevice: try AudioObjectID.readDefaultInputDevice(),
                               tapUUID: tapDescription.uuid.uuidString)

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
            // Record under a .part name the folder scanner ignores; stop()
            // balances the channels and renames to the final .wav, so the
            // pipeline can never pick up a half-written or unbalanced file.
            let part = url.appendingPathExtension("part")
            file = try AVAudioFile(forWriting: part, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
            partURL = part
            fileURL = url
            micPeak = 0
            tapPeak = 0
            queue.sync { micSumSq = 0; tapSumSq = 0; levelFrames = 0 }
            self.outputFormat = format
            try installIOProc()

            startedAt = Date()
            let startErr = AudioDeviceStart(aggregateID, ioProcID!)
            guard startErr == noErr else { throw CaptureError.coreAudio("start device", startErr) }
            isRecording = true
        } catch {
            teardown()
            throw error
        }
    }


    // MARK: aggregate + IOProc (also used to move to another microphone, #4039)

    /// Create the private aggregate (default output as clock + `inputDevice` + the tap) and remember
    /// the channel split. Throws without leaving an aggregate behind.
    private func buildAggregate(inputDevice: AudioDeviceID, tapUUID: String) throws {
        let outputDevice = try AudioObjectID.readDefaultSystemOutputDevice()
        let outputUID = try outputDevice.readDeviceUID()
        let inputUID = try inputDevice.readDeviceUID()
        let mic = max(1, (try? inputDevice.readInputChannelCount()) ?? 1)
        // A pro-audio interface can be the system OUTPUT and still expose input channels; those
        // appear before the mic's in the aggregate's buffer list and must not be counted as mic.
        let skip = (outputDevice == inputDevice) ? 0 : ((try? outputDevice.readInputChannelCount()) ?? 0)

        var subDevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: outputUID]]
        if inputUID != outputUID {
            subDevices.append([kAudioSubDeviceUIDKey: inputUID,
                               kAudioSubDeviceDriftCompensationKey: true])
        }
        // No kAudioAggregateDeviceTapAutoStartKey: that key makes AudioDeviceStart WAIT for the first
        // tapped audio, so nothing (including the mic) would be recorded until some app plays sound.
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Distavo Meeting Recorder",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUUID, kAudioSubTapDriftCompensationKey: true],
            ],
        ]
        var newAggregateID = AudioObjectID.unknown
        let aggErr = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        guard aggErr == noErr, newAggregateID.isValid else {
            throw CaptureError.coreAudio("create aggregate device", aggErr)
        }
        aggregateID = newAggregateID
        tapUUIDString = tapUUID
        // The IOProc reads these on `queue`; set them there.
        queue.sync { micChannelCount = mic; skipChannelCount = skip }
        self.inputUID = inputUID
        inputName = (try? inputDevice.readDeviceName()) ?? inputUID
    }

    /// One IOProc reads the aggregate's aligned input buffers in sub-device order: any input
    /// channels of the output device (skipped), then the mic's, then the tap's stereo mixdown.
    private func installIOProc() throws {
        guard let format = outputFormat else { throw CaptureError.setup("no output format") }
        var newProcID: AudioDeviceIOProcID?
        let procErr = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, queue) {
            [weak self] _, inInputData, _, _, _ in
            guard let self, let file = self.file else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            self.writeMixed(buffers: buffers, skipChannels: self.skipChannelCount,
                            micChannels: self.micChannelCount, format: format, to: file)
        }
        guard procErr == noErr, let procID = newProcID else {
            throw CaptureError.coreAudio("create IO proc", procErr)
        }
        ioProcID = procID
    }

    /// Record the microphone channel from another input without ending the take (#4039): the
    /// aggregate and IOProc are rebuilt on the new input; the tap, the file and the system channel
    /// continue (the mic channel has a gap of well under a second). The macOS default input is not
    /// changed. On failure the previous input is restored when possible. Returns the new input name.
    @discardableResult
    func switchInput(toUID uid: String) throws -> String {
        guard isRecording else { throw CaptureError.setup("not recording") }
        guard let device = AudioInputDevices.deviceID(forUID: uid) else {
            throw CaptureError.setup("input device is no longer available")
        }
        let previous = inputUID
        stopIOAndAggregate()
        do {
            try buildAggregate(inputDevice: device, tapUUID: tapUUIDString)
            try installIOProc()
            let err = AudioDeviceStart(aggregateID, ioProcID!)
            guard err == noErr else { throw CaptureError.coreAudio("start device", err) }
        } catch {
            stopIOAndAggregate()
            // Try to get the old input back so the recording continues.
            if let previous, let old = AudioInputDevices.deviceID(forUID: previous),
               (try? buildAggregate(inputDevice: old, tapUUID: tapUUIDString)) != nil,
               (try? installIOProc()) != nil, let proc = ioProcID {
                AudioDeviceStart(aggregateID, proc)
            }
            throw error
        }
        return inputName ?? uid
    }

    private func stopIOAndAggregate() {
        if aggregateID.isValid {
            if let procID = ioProcID {
                AudioDeviceStop(aggregateID, procID)
                queue.sync {}
                AudioDeviceDestroyIOProcID(aggregateID, procID)
                ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
    }

    /// Stops, tears down the tap + aggregate completely, and reports whether
    /// each side of the recording actually contained signal. The file appears
    /// under its final `.wav` name only after the (asynchronous) channel
    /// balance finishes, so the folder scanner never sees it early.
    ///
    /// With `deferFinalize`, the take stays a `.part` (invisible to the
    /// scanner) until `finalizeDeferred()` — so the UI can ask the owner about
    /// the speakers first and have the answer on disk before the pipeline can
    /// possibly pick the recording up (Vikunja #2182).
    func stop(deferFinalize: Bool = false) -> Outcome? {
        guard isRecording, let url = fileURL, let part = partURL else { return nil }
        isRecording = false
        teardown()  // closes `file`, so `part` is fully flushed
        if deferFinalize {
            deferred = (part, url)
        } else {
            queue.async { Self.finalize(part: part, to: url) }
        }
        return Outcome(url: url,
                       microphoneHeard: micPeak > 0.001,
                       systemAudioHeard: tapPeak > 0.001)
    }

    private var deferred: (part: URL, url: URL)?

    /// Balance and publish a take held back by `stop(deferFinalize: true)`,
    /// under `url` when given (a calendar-event name, Vikunja #2946). In that
    /// case `CalendarRename` has already renamed the `.part` to `<url>.part`
    /// together with the sidecars, so the part is found under the new name.
    func finalizeDeferred(as url: URL? = nil) {
        guard let pending = deferred else { return }
        deferred = nil
        let target = url ?? pending.url
        let part = target == pending.url ? pending.part : target.appendingPathExtension("part")
        queue.async { Self.finalize(part: part, to: target) }

    }

    /// Stop and throw the take away (Vikunja #2068): the `.part` file is
    /// deleted before it could ever be renamed to a `.wav` the folder scanner
    /// would pick up, so nothing is transcribed. Returns the discarded name.
    func discard() -> String? {
        guard isRecording, let url = fileURL, let part = partURL else { return nil }
        isRecording = false
        teardown()  // closes `file`
        try? FileManager.default.removeItem(at: part)
        try? FileManager.default.removeItem(at: url)  // never exists yet; belt and braces
        return url.lastPathComponent
    }

    /// Whether the system-audio tap has delivered any signal so far — read
    /// while recording so the UI can warn early that the meeting side is
    /// silent (Vikunja #2060), instead of only after the call has ended.
    var systemAudioHeardSoFar: Bool {
        queue.sync { tapPeak > 0.001 }
    }

    /// RMS of the mic (left) and system-audio (right) output channels since
    /// the previous call, measured on the mixed-down samples before any
    /// loudness balancing, then reset. `(0, 0)` when no frames arrived (a
    /// stalled device counts as silence). Same `queue.sync` pattern as
    /// `systemAudioHeardSoFar`; called once a second by the controller.
    func drainLevels() -> (mic: Float, system: Float) {
        queue.sync {
            defer { micSumSq = 0; tapSumSq = 0; levelFrames = 0 }
            guard levelFrames > 0 else { return (0, 0) }
            let n = Double(levelFrames)
            return (Float((micSumSq / n).squareRoot()), Float((tapSumSq / n).squareRoot()))
        }
    }

    /// Balance mic vs system-audio loudness and move `part` to its final
    /// name. If balancing fails, deliver the raw recording — never lose a
    /// meeting to post-processing.
    private static func finalize(part: URL, to url: URL) {
        do {
            try StereoBalancer.balance(from: part, to: url)
            // A long silent tail (after an auto-stop) is cut so Whisper has nothing to invent over (#2677).
            // Best effort: on any failure the balanced recording stays exactly as it is.
            _ = try? TrailingSilence.trim(url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.moveItem(at: part, to: url)
        }
    }

    /// Startup recovery: a crash mid-recording or mid-finalise leaves a
    /// `.wav.part` behind. Finalise it now so the pipeline picks it up.
    /// Returns the recovered final URLs.
    static func recoverOrphanedRecordings(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }
        var recovered: [URL] = []
        for name in names where name.hasSuffix(".wav.part") {
            let part = folder.appendingPathComponent(name)
            let url = part.deletingPathExtension()
            if fm.fileExists(atPath: url.path) {
                // Finalise had already produced the .wav; the .part is a
                // leftover duplicate.
                try? fm.removeItem(at: part)
                continue
            }
            finalize(part: part, to: url)
            if fm.fileExists(atPath: url.path) { recovered.append(url) }
        }
        return recovered
    }

    private func teardown() {
        if aggregateID.isValid {
            if let procID = ioProcID {
                AudioDeviceStop(aggregateID, procID)
                // Drain any already-dispatched IO block BEFORE destroying the
                // HAL objects whose buffers that block reads.
                queue.sync {}
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
        queue.sync { [weak self] in
            self?.file = nil
            self?.outputBuffer = nil
        }
    }

    /// Runs on `queue`. Splits the aggregate's input channels into ignored
    /// (`skipChannels` — input channels of the output device, if any),
    /// microphone (the next `micChannels`) and tap (the rest), averages mic
    /// and tap into one channel each of the stereo output buffer, tracks
    /// peaks, writes to the file.
    private func writeMixed(buffers: UnsafeMutableAudioBufferListPointer,
                            skipChannels: Int, micChannels: Int,
                            format: AVAudioFormat, to file: AVAudioFile) {
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
                defer { globalChannel += 1 }
                guard globalChannel >= skipChannels else { continue }
                let isMic = globalChannel < skipChannels + micChannels
                let target = outData[isMic ? 0 : 1]
                for frame in 0..<count {
                    target[frame] += data[frame * channels + channel]
                }
                if isMic { micMixed += 1 } else { tapMixed += 1 }
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

        // Sum of squares for the silence monitor (no allocation, on `queue`).
        var sumSq: Float = 0
        vDSP_svesq(outData[0], 1, &sumSq, vDSP_Length(frames))
        micSumSq += Double(sumSq)
        vDSP_svesq(outData[1], 1, &sumSq, vDSP_Length(frames))
        tapSumSq += Double(sumSq)
        levelFrames += frames

        try? file.write(from: out)
    }
}

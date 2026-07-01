import Foundation
import AudioToolbox

// Core Audio property-access helpers for the meeting recorder.
// Adapted from insidegui/AudioCap (BSD-2-Clause, © 2024 Guilherme Rambo) —
// see NOTICES.md. The private-TCC permission probe from AudioCap is
// deliberately NOT ported (App Store safe): the system permission prompt
// fires on first tap use instead.

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = kAudioObjectUnknown

    var isValid: Bool { self != Self.unknown }

    /// The Core Audio process object for a pid (needed to exclude Distavo's
    /// own audio from the global tap).
    static func translatePIDToProcessObjectID(pid: pid_t) throws -> AudioObjectID {
        let object: AudioObjectID = try AudioObjectID.system.read(
            kAudioHardwarePropertyTranslatePIDToProcessObject,
            defaultValue: AudioObjectID.unknown,
            qualifier: pid)
        guard object.isValid else { throw CaptureError.setup("no audio process object for pid \(pid)") }
        return object
    }

    static func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
        try AudioObjectID.system.read(
            kAudioHardwarePropertyDefaultSystemOutputDevice, defaultValue: AudioDeviceID.unknown)
    }

    static func readDefaultInputDevice() throws -> AudioDeviceID {
        try AudioObjectID.system.read(
            kAudioHardwarePropertyDefaultInputDevice, defaultValue: AudioDeviceID.unknown)
    }

    func readDeviceUID() throws -> String {
        try read(AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain), defaultValue: "" as CFString) as String
    }

    func readAudioTapStreamBasicDescription() throws -> AudioStreamBasicDescription {
        try read(AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain), defaultValue: AudioStreamBasicDescription())
    }

    /// Total input channels of a device (mic), read from its input-scope
    /// stream configuration. Used to split the aggregate's input buffers into
    /// "microphone" vs "system audio (tap)".
    func readInputChannelCount() throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize)
        guard err == noErr else { throw CaptureError.coreAudio("stream config size", err) }
        let listPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { listPointer.deallocate() }
        err = AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, listPointer)
        guard err == noErr else { throw CaptureError.coreAudio("stream config", err) }
        let buffers = UnsafeMutableAudioBufferListPointer(
            listPointer.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    // MARK: generic reads (fixed-size properties)

    func read<T, Q>(_ selector: AudioObjectPropertySelector, defaultValue: T, qualifier: Q) throws -> T {
        var inQualifier = qualifier
        let qualifierSize = UInt32(MemoryLayout<Q>.size(ofValue: qualifier))
        return try withUnsafeMutablePointer(to: &inQualifier) { pointer in
            try read(AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain),
                defaultValue: defaultValue, qualifierSize: qualifierSize, qualifierData: pointer)
        }
    }

    func read<T>(_ selector: AudioObjectPropertySelector, defaultValue: T) throws -> T {
        try read(AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain), defaultValue: defaultValue)
    }

    func read<T>(_ inAddress: AudioObjectPropertyAddress, defaultValue: T,
                 qualifierSize: UInt32 = 0, qualifierData: UnsafeRawPointer? = nil) throws -> T {
        var address = inAddress
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, qualifierSize, qualifierData, &dataSize)
        guard err == noErr else { throw CaptureError.coreAudio("property size", err) }
        var value: T = defaultValue
        err = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(self, &address, qualifierSize, qualifierData, &dataSize, pointer)
        }
        guard err == noErr else { throw CaptureError.coreAudio("property read", err) }
        return value
    }
}

enum CaptureError: LocalizedError {
    case setup(String)
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .setup(let message):
            return "Recording setup failed: \(message)"
        case .coreAudio(let what, let status):
            return "Recording setup failed (\(what), Core Audio error \(status))."
        }
    }
}

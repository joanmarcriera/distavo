// DuplicateCallLink.swift — wiring half of #4014 (the same call captured on phone and Mac).
//
// `DuplicateCallDetector` decides WHICH recordings are one call. This file keeps the small per-recording
// record that decision needs, finds a twin among the records already in the work dir, reuses the twin's
// participants sheet for a recording that has none, and writes the "also captured as" link.
//
// Sidecars (work dir, keyed by base like the others):
//  - `<base>.call.json`           CallRecord: container time, duration, live-capture flag. No audio or text.
//  - `<base>.also-captured.json`  AlsoCaptured: the twin's base and whether this note is the primary.
// Only base names are stored, never titles or content. Reusing a sheet copies `<twin>.speakers.json`
// to `<base>.speakers.json` and never overwrites an existing one (an answered sheet always wins).
//
// Time convention: the Mac recorder's name gives the START. A dropped phone file's container
// `creation_time` is the UTC END on Android but the START elsewhere, so for a non-live record both
// readings are tried and a twin is accepted if either one matches (`CallRecord.candidates`).
import Foundation

public struct CallRecord: Codable, Equatable, Sendable {
    public var base: String
    /// The time the container/name reports (see the convention above).
    public var time: Date
    public var durationSeconds: Double
    /// Recorded by Distavo's own recorder: `time` is the start, with no ambiguity.
    public var isLiveCapture: Bool

    public init(base: String, time: Date, durationSeconds: Double, isLiveCapture: Bool) {
        self.base = base; self.time = time; self.durationSeconds = max(0, durationSeconds)
        self.isLiveCapture = isLiveCapture
    }

    /// The readings of this record as detector input: one for a live capture, two (end / start) otherwise.
    public func candidates(hasSheet: Bool) -> [CapturedCall] {
        let asStart = CapturedCall(base: base, start: time, durationSeconds: durationSeconds,
                                   hasParticipantsSheet: hasSheet, isLiveCapture: isLiveCapture)
        if isLiveCapture { return [asStart] }
        let asEnd = CapturedCall(base: base,
                                 start: CapturedCall.startFromContainerEnd(time, durationSeconds: durationSeconds),
                                 durationSeconds: durationSeconds, hasParticipantsSheet: hasSheet,
                                 isLiveCapture: false)
        return [asEnd, asStart]
    }
}

public struct AlsoCaptured: Codable, Equatable, Sendable {
    public var otherBase: String
    public var isPrimary: Bool
}

public enum DuplicateCallLink {
    static func recordURL(_ workDir: URL, _ base: String) -> URL { workDir.appendingPathComponent("\(base).call.json") }
    static func linkURL(_ workDir: URL, _ base: String) -> URL { workDir.appendingPathComponent("\(base).also-captured.json") }

    public static func saveRecord(_ r: CallRecord, workDir: URL) throws {
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try enc.encode(r).write(to: recordURL(workDir, r.base), options: .atomic)
    }

    public static func loadRecord(workDir: URL, base: String) -> CallRecord? {
        guard let data = try? Data(contentsOf: recordURL(workDir, base)) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(CallRecord.self, from: data)
    }

    public static func loadLink(workDir: URL, base: String) -> AlsoCaptured? {
        guard let data = try? Data(contentsOf: linkURL(workDir, base)) else { return nil }
        return try? JSONDecoder().decode(AlsoCaptured.self, from: data)
    }

    /// Every record in the work dir except `base` itself, in name order.
    static func otherRecords(workDir: URL, excluding base: String) -> [CallRecord] {
        let suffix = ".call.json"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: workDir.path)) ?? []
        return names.filter { $0.hasSuffix(suffix) }
            .map { String($0.dropLast(suffix.count)) }
            .filter { $0 != base }.sorted()
            .compactMap { loadRecord(workDir: workDir, base: $0) }
    }

    /// The best twin of `record` among `others` (largest overlap), judged by the detector. nil when none.
    public static func twin(of record: CallRecord, among others: [CallRecord], sheetBases: Set<String>) -> CallRecord? {
        var best: (record: CallRecord, overlap: Double)?
        for o in others {
            for mine in record.candidates(hasSheet: sheetBases.contains(record.base)) {
                for theirs in o.candidates(hasSheet: sheetBases.contains(o.base))
                where DuplicateCallDetector.isSameCall(mine, theirs) {
                    let ov = DuplicateCallDetector.overlap(mine, theirs)
                    if best == nil || ov > best!.overlap { best = (o, ov) }
                }
            }
        }
        return best?.record
    }

    /// Record this recording, look for a twin and, when found, link both sidecars and copy the twin's
    /// sheet if this recording has none. Returns the link (nil when no twin). Safe to call twice.
    @discardableResult
    public static func register(_ record: CallRecord, workDir: URL) -> AlsoCaptured? {
        try? saveRecord(record, workDir: workDir)
        let others = otherRecords(workDir: workDir, excluding: record.base)
        let sheets = Set((others.map(\.base) + [record.base]).filter {
            SpeakerHints.load(workDir: workDir, base: $0).map { !$0.isEmpty } ?? false })
        guard let other = twin(of: record, among: others, sheetBases: sheets) else { return nil }
        // Primary by the detector's own rules (first reading is enough: sheet / duration / live decide).
        let mine = record.candidates(hasSheet: sheets.contains(record.base))[0]
        let theirs = other.candidates(hasSheet: sheets.contains(other.base))[0]
        let iAmPrimary = DuplicateCallDetector.primaryFirst(mine, theirs).0.base == record.base
        // Reuse the twin's sheet only when this one has none (names, count, terms).
        if !sheets.contains(record.base), sheets.contains(other.base),
           let hints = SpeakerHints.load(workDir: workDir, base: other.base) {
            try? hints.save(workDir: workDir, base: record.base)
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        for (b, o, p) in [(record.base, other.base, iAmPrimary), (other.base, record.base, !iAmPrimary)] {
            if let d = try? enc.encode(AlsoCaptured(otherBase: o, isPrimary: p)) {
                try? d.write(to: linkURL(workDir, b), options: .atomic)
            }
        }
        return AlsoCaptured(otherBase: other.base, isPrimary: iAmPrimary)
    }
}

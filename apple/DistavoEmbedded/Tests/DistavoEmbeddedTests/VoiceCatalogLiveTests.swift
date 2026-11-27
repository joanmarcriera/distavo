import XCTest
@testable import DistavoEmbedded
import DistavoCore

/// Review Voices with the real voice engine, on a COPY of the owner's data. Prints ONLY numbers (voices by
/// index, similarities, counts): no name, no title, no text. SKIPPED unless `DISTAVO_TEST_HOME` points at a
/// test home (`Config.homeDir`); it never runs on the real folders. Every change it makes is undone.
///
///   DISTAVO_TEST_HOME=<copy> swift test --filter VoiceCatalogLiveTests
final class VoiceCatalogLiveTests: XCTestCase {
    /// For each remembered voice: how close its speaker in the newest meetings is to the stored samples, and
    /// "not this person" with real samples takes out the samples learnt from that meeting, then undo restores.
    func testNotThisPersonWithRealSamplesAndUndo() throws {
        let real = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        try XCTSkipUnless(Config.homeDir.path != real, "no DISTAVO_TEST_HOME")
        // A plain async test "passed" without running its body on the Nov 2026 toolchain: wait for a task.
        let done = expectation(description: "voices")
        Task { await self.run(); done.fulfill() }
        wait(for: [done], timeout: 1_800)
    }

    private func run() async {
        guard let cfg = try? Config.load(from: Config.defaultConfigURL) else { return XCTFail("no config in the test home") }
        let notes = Config.resolvePath(cfg.notesDir), work = Config.resolvePath(cfg.workDir), rec = Config.resolvePath(cfg.recordingsDir)
        let support = NameGlossary.defaultSupportDir, model = VoiceProfileStore.builtInModel
        for dir in [notes, work, rec, support] where !dir.path.hasPrefix(Config.homeDir.path) { return XCTFail("a folder is outside the test home") }
        var audio: [String: URL] = [:]
        let walker = FileManager.default.enumerator(at: rec, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            if supportedExtensions.contains("." + url.pathExtension.lowercased()) { audio[DistavoState.baseFor(recordingsDir: rec, path: url)] = url }
        }
        let store = VoiceProfileStore.load(supportDir: support, model: model)
        let meetings = NotesLibrary.scan(notesDir: notes, workDir: work).filter { !$0.isVariant }
            .map { VoiceCatalog.Meeting(base: $0.base, title: $0.title, date: $0.date) }
        let people = VoiceCatalog.people(store: store, meetings: meetings, workDir: work)
        let storeFile = VoiceProfileStore.url(supportDir: support)
        let before = try? Data(contentsOf: storeFile)
        let c = VoiceCatalog.Context(notesDir: notes, workDir: work, supportDir: support, model: model)
        var tried = 0, removedSomething = 0
        for (i, p) in people.enumerated() {
            guard let profile = store.profiles.first(where: { $0.name == p.name }) else { continue }
            var scores: [String] = [], newest: (base: String, sample: [Float])?
            for clip in p.clips.prefix(3) {
                guard let source = audio[LanguageOverride.sourceBase(from: clip.base)],
                      let (speaker, ranges) = VoiceCatalog.sampleRanges(name: p.name, base: clip.base, workDir: work),
                      let sample = await VoiceEmbedder.embeddings(audio: source, ranges: [speaker: ranges])[speaker] else { scores.append("-"); continue }
                let best = profile.samples.map { VoiceProfileStore.cosine($0, sample) }.max() ?? -1
                scores.append(String(format: "%.2f%@", best, clip.guessed ? "g" : ""))
                if newest == nil { newest = (clip.base, sample) }
            }
            print("LIVE voice \(i): \(p.bases.count) meetings, \(profile.samples.count) samples, newest meetings vs profile: \(scores.joined(separator: " "))")
            guard let newest else { continue }
            do {
                let out = try VoiceCatalog.separate(name: p.name, meetings: [newest.base], embeddings: [newest.base: newest.sample],
                                                    to: nil, remember: false, renameNotes: true, context: c)
                tried += 1
                if out.samplesRemoved > 0 { removedSomething += 1 }
                let after = VoiceProfileStore.load(supportDir: support, model: model)
                XCTAssertEqual(after.profiles.first { $0.name == p.name }?.samples.count ?? 0, profile.samples.count - out.samplesRemoved)
                XCTAssertEqual(out.voiceForgotten, out.samplesRemoved == profile.samples.count)
                print("LIVE voice \(i): not-this-person removed \(out.samplesRemoved) of \(profile.samples.count) samples, forgotten \(out.voiceForgotten)")
                _ = try VoiceCatalog.undo(context: c)
            } catch { XCTFail("voice \(i): \(type(of: error))") }
            XCTAssertEqual(try? Data(contentsOf: storeFile), before, "voice \(i): the voice file is not back after undo")
        }
        print("LIVE voices: \(people.count) remembered, not-this-person tried on \(tried), took a sample out on \(removedSomething), all undone")
    }
}

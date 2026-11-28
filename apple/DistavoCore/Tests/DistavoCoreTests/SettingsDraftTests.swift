import XCTest
@testable import DistavoCore

/// The Settings draft follows what the menu changed (`SettingsDraft`), so saving or closing the window never
/// puts an older value back. Found 2026-11-27: a pause chosen in the menu was undone by closing Settings.
final class SettingsDraftTests: XCTestCase {
    func testAPauseChosenInTheMenuIsNotUndoneByTheOpenSettingsWindow() {
        let atOpen = Config()
        XCTAssertTrue(atOpen.watchEnabled)
        var draft = atOpen
        draft.noteOwner = "Petra"               // typed in the window, not saved yet
        var live = atOpen
        live.watchEnabled = false               // "Pause watching" in the menu
        let followed = SettingsDraft.following(draft: draft, was: atOpen, now: live)
        XCTAssertFalse(followed.watchEnabled, "the draft must not hold the old value, or Save/close resumes watching")
        XCTAssertEqual(followed.noteOwner, "Petra", "what the owner typed stays")
        var expected = draft; expected.watchEnabled = false
        XCTAssertEqual(followed, expected, "nothing else moved")
    }

    func testEveryKindOfSettingFollowsTopLevelNestedAndLists() {
        let was = Config()
        var now = was
        now.watchIntervalSeconds = was.watchIntervalSeconds + 60          // the menu's interval
        now.summarise.allowLocalFallback.toggle()                         // "Use local Ollama"
        now.transcribe.vocabulary = ["Distavo", "Parakeet"]
        var draft = was
        draft.transcribe.numSpeakers = 3
        draft.transcribe.spokenLanguages = ["en", "ca"]
        let out = SettingsDraft.following(draft: draft, was: was, now: now)
        XCTAssertEqual(out.watchIntervalSeconds, now.watchIntervalSeconds)
        XCTAssertEqual(out.summarise.allowLocalFallback, now.summarise.allowLocalFallback)
        XCTAssertEqual(out.transcribe.vocabulary, ["Distavo", "Parakeet"])
        XCTAssertEqual(out.transcribe.numSpeakers, 3)
        XCTAssertEqual(out.transcribe.spokenLanguages, ["en", "ca"])
    }

    func testNothingChangedOutsideLeavesTheDraftExactlyAsItIs() {
        let live = Config()
        var draft = live
        draft.watchEnabled = false; draft.noteOwner = "Petra"; draft.transcribe.vocabulary = ["a"]
        XCTAssertEqual(SettingsDraft.following(draft: draft, was: live, now: live), draft)
    }

    func testSavingTheDraftIsNotAnOutsideChange() {
        // Save: the live config becomes the draft. The draft must come back as it is.
        let was = Config()
        var draft = was
        draft.watchEnabled = false; draft.watchIntervalSeconds += 30
        XCTAssertEqual(SettingsDraft.following(draft: draft, was: was, now: draft), draft)
    }

    func testAnUntouchedDraftBecomesTheLiveConfig() {
        let was = Config.recommendedForThisMac()
        var now = was
        now.watchEnabled.toggle(); now.summarise.allowLocalFallback.toggle(); now.noteOwner = "Someone"
        now.transcribe.vocabulary = []; now.transcribe.spokenLanguages = ["es"]
        XCTAssertEqual(SettingsDraft.following(draft: was, was: was, now: now), now)
        XCTAssertEqual(SettingsDraft.following(draft: now, was: now, now: was), was, "and back")
    }

    func testWhenBothChangedTheSameSettingTheMenuWins() {
        // The menu is the later, deliberate action; the window shows the value it now has.
        let was = Config()
        var draft = was; draft.watchIntervalSeconds = 111
        var now = was; now.watchIntervalSeconds = 222
        XCTAssertEqual(SettingsDraft.following(draft: draft, was: was, now: now).watchIntervalSeconds, 222)
    }

    func testThePauseSurvivesASaveAndLoadOfTheConfigFile() throws {
        let url = TestTemp.root.appendingPathComponent("distavo-watch-\(UUID().uuidString)/watcher-config.json")
        var cfg = Config.recommendedForThisMac()
        XCTAssertTrue(cfg.watchEnabled, "fresh installs watch the folder")
        cfg.watchEnabled = false
        try Config.save(cfg, to: url)
        XCTAssertFalse(try Config.load(from: url).watchEnabled, "a pause is kept across a relaunch")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("\"watch_enabled\" : false"))
        cfg.watchEnabled = true
        try Config.save(cfg, to: url)
        XCTAssertTrue(try Config.load(from: url).watchEnabled)
    }

    func testPausedHoldsTheTimerButNeverADeliberateAction() {
        // What `watch_enabled = false` means at launch: the same rule as the menu pause.
        let paused = !Config(watchEnabled: false).watchEnabled
        XCTAssertFalse(PausePolicy.mayStart(.automatic, paused: paused))
        XCTAssertTrue(PausePolicy.mayStart(.userInitiated, paused: paused))
        XCTAssertTrue(PausePolicy.mayStart(.automatic, paused: !Config().watchEnabled))
    }

    func testSavingSettingsStartsNothingWhileWatchingIsOff() {
        // Switching "Watch the folder" off and pressing Save must not process what is pending.
        XCTAssertFalse(PausePolicy.rescansAfterSettingsSaved(paused: true))
        XCTAssertTrue(PausePolicy.rescansAfterSettingsSaved(paused: false), "watching: new settings may fix a failure, as before")
    }
}

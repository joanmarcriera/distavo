# Changelog

All notable changes to Distavo. This file is generated from the commit history by
[git-cliff](https://git-cliff.org) (`git cliff -o CHANGELOG.md`, config in `cliff.toml`); do not
edit it by hand. Task numbers link to the Vikunja board.

## [1.21.0] - 2026-11-14

### Features

- **capture**: Warn after 10 s when the microphone is silent but the call is audible ([#3930](https://familia.riera.co.uk/tasks/3930))
- **vocabulary**: Seed the glossary from participant names; strip blank entries on Settings save ([#3950](https://familia.riera.co.uk/tasks/3950))
- **capture**: Prefill the end-of-recording sheet from last used / calendar / same contact ([#3943](https://familia.riera.co.uk/tasks/3943))
- **guard**: Warn in the Notes window when the offensive-word guard replaced words ([#3951](https://familia.riera.co.uk/tasks/3951))
- **capture**: Pure MeetingEndPolicy, stop when the call ends not at the calendar end ([#4007](https://familia.riera.co.uk/tasks/4007))
- **schedule**: Pure MeetingSchedule core, candidates and per-meeting record plan ([#4004](https://familia.riera.co.uk/tasks/4004))
- **schedule**: Wire MeetingEndPolicy to a RecordCandidate and the stop behaviour ([#4007](https://familia.riera.co.uk/tasks/4007))
- **stamp**: Date dropped recordings from the file name or container time, PhaseTimings log line ([#4018](https://familia.riera.co.uk/tasks/4018))
- **summary**: Flag a recording that stops mid-conversation, tell the summariser, never invent next steps ([#4013](https://familia.riera.co.uk/tasks/4013))
- **vocabulary**: Opt-in fuzzy post-pass snaps near-miss spellings to the vocabulary, reaches Parakeet ([#3950](https://familia.riera.co.uk/tasks/3950))
- **capture**: End-of-recording box shows only when no call audio was heard, with help and tooltip ([#4023](https://familia.riera.co.uk/tasks/4023))
- **capture**: AskLaterPolicy, reminders with give-up rule and persistence, fake-clock tested ([#4020](https://familia.riera.co.uk/tasks/4020))
- **capture**: Shared MicSilenceSignal, mic_silence_warning_seconds, Ignore and live 'mic silent' label ([#3930](https://familia.riera.co.uk/tasks/3930))
- **pipeline**: Date dropped files from container creation_time minus duration when the name has no stamp ([#4018](https://familia.riera.co.uk/tasks/4018))
- **speakers**: Honour a <name>.speakers.json beside a dropped file ([#4012](https://familia.riera.co.uk/tasks/4012))
- **capture**: MicFallback policy, real-input candidates and recording.mic_auto_switch ([#4039](https://familia.riera.co.uk/tasks/4039))
- **capture**: Switch microphone live when the selected one is silent, menu shows the input ([#4039](https://familia.riera.co.uk/tasks/4039))
- **speakers**: Source line and recent-people quick-pick on the end-of-recording sheet ([#3943](https://familia.riera.co.uk/tasks/3943))
- **capture**: Global record start/stop shortcut, off by default, with clash check ([#4001](https://familia.riera.co.uk/tasks/4001))
- **capture**: Opt-in browser (Google Meet) call detection and activeCalls in MeetingDetector ([#4002](https://familia.riera.co.uk/tasks/4002))
- **site**: Draft Catalan and Spanish landing pages, example note, check-site.sh ([#4083](https://familia.riera.co.uk/tasks/4083))
- **ops**: Add read-only weekly-metrics.sh with fixture test ([#4087](https://familia.riera.co.uk/tasks/4087))
- **schedule**: Pure morning digest model and at-meeting remind/auto-start policy ([#4005](https://familia.riera.co.uk/tasks/4005), [#4006](https://familia.riera.co.uk/tasks/4006))
- **summary**: Opt-in gate for non-meeting audio and solo memos ([#4015](https://familia.riera.co.uk/tasks/4015))
- **schedule**: Configurable morning digest time ([#4005](https://familia.riera.co.uk/tasks/4005))
- **capture**: Pure detector for the same call captured twice ([#4014](https://familia.riera.co.uk/tasks/4014))
- **speakers**: Pure recall aids for the deferred who-was-there form ([#4021](https://familia.riera.co.uk/tasks/4021))
- **capture**: Link a call captured twice and reuse the twin's participants sheet ([#4014](https://familia.riera.co.uk/tasks/4014))
- **summarise**: Low-speaker-confidence signal in the non-meeting gate ([#4015](https://familia.riera.co.uk/tasks/4015))
- **speakers**: Assemble the deferred-question context from calendar, quick notes, key moments and speaker lines ([#4021](https://familia.riera.co.uk/tasks/4021))
- **site**: WCAG 2.2 AA checker, skip links, focus rings, reduced motion, contrast fixes ([#4372](https://familia.riera.co.uk/tasks/4372))
- **site**: Sitemap, robots, JSON-LD, canonical and OG on every page, check-seo.py with weight budget ([#4373](https://familia.riera.co.uk/tasks/4373))
- **market**: Summary requirement in the first 300 chars of listing and site, en/ca/es ([#4661](https://familia.riera.co.uk/tasks/4661))
- **site**: Setup page with 16/24/32 GB Ollama model table, sitemap, JSON-LD, footer link ([#4662](https://familia.riera.co.uk/tasks/4662))
- **site**: MacWhisper alternatives page, every cell sourced and dated, with checker and fail fixture ([#4663](https://familia.riera.co.uk/tasks/4663))
- **ops**: Pricing-experiments E1-E5, weekly-metrics rival price line and site/appcast status ([#4666](https://familia.riera.co.uk/tasks/4666))
- **ops**: Site deploy.sh, dry-run by default, --go to copy, post-deploy probe, with local-dir test ([#4667](https://familia.riera.co.uk/tasks/4667))
- **diarisation**: Label words owner/remote from stereo channel energy ([#6353](https://familia.riera.co.uk/tasks/6353))
- **diarisation**: Wire channel speaker labels into the pipeline behind transcribe.channel_speakers ([#6353](https://familia.riera.co.uk/tasks/6353))
- **summary**: Apply the note's Possible transcription corrections to the body ([#6354](https://familia.riera.co.uk/tasks/6354))
- **summary**: Advice call template for accountant, lawyer and adviser calls ([#6355](https://familia.riera.co.uk/tasks/6355))
- **vocabulary**: Role term packs from the participants line; feat(capture): pure mic-silence diagnosis ([#3950](https://familia.riera.co.uk/tasks/3950), [#3930](https://familia.riera.co.uk/tasks/3930))
- **capture**: Mic-silent notification says why (permission or input name) via MicDiagnosis ([#3930](https://familia.riera.co.uk/tasks/3930))
- **pipeline**: A finished file reports per-phase timings in the log and on ProcessResult ([#4018](https://familia.riera.co.uk/tasks/4018))
- **capture**: Stop a recording when the call ends, behind meeting_detection.stop_when_call_ends ([#4007](https://familia.riera.co.uk/tasks/4007))
- **speakers**: DroppedFileSheet core, when to offer the participants sheet for dropped files and what it starts with ([#4012](https://familia.riera.co.uk/tasks/4012))
- **templates**: Project_meeting template, auto rule and opt-in neutral default ([#6666](https://familia.riera.co.uk/tasks/6666))
- **recorder**: Stop sheet offers Auto first, preselects folder pick or rule, logs the template used ([#6667](https://familia.riera.co.uk/tasks/6667))
- **recorder**: Opt-in recording.storage_format int16 halves the WAV size, findings on 16 kHz ([#6670](https://familia.riera.co.uk/tasks/6670))
- **split**: Pure core to find the silence between two meetings and cut a recording there ([#6668](https://familia.riera.co.uk/tasks/6668))
- **capture**: Stop a recording automatically at 8 hours, a setting, warned 10 minutes before
- **notes**: Notes.link_duplicate_calls switches duplicate-call linking, off for old configs (review B)
- **core**: RecordingStorage folder size and free disk helpers, search keywords ([#6670](https://familia.riera.co.uk/tasks/6670))
- **settings**: Recording format picker, folder size and free disk ([#6670](https://familia.riera.co.uk/tasks/6670))


### Bug fixes

- **capture**: Return keeps the recording in the delete confirmation ([#3929](https://familia.riera.co.uk/tasks/3929))
- **transcript**: Guard against a mis-heard slur reaching the note ([#3951](https://familia.riera.co.uk/tasks/3951))
- **summary**: Scrub leaked prompt scaffolding from saved notes ([#4010](https://familia.riera.co.uk/tasks/4010))
- **capture**: Never open System Settings unasked after Save; rate-limited notice policy ([#4022](https://familia.riera.co.uk/tasks/4022))
- **summary**: Retry a repetition collapse once, then write a transcript-only note ([#4011](https://familia.riera.co.uk/tasks/4011))
- **ledger**: Validate figures, speaker and trivia on every facts-ledger row, cap at 15 ([#4017](https://familia.riera.co.uk/tasks/4017))
- **router**: A strict majority of confident windows picks the engine; strip hallucinated sound tags ([#4016](https://familia.riera.co.uk/tasks/4016))
- **ops**: Compare the published appcast byte for byte; refresh RELEASE.md merge state; note that the site is deployed by hand ([#4071](https://familia.riera.co.uk/tasks/4071))
- **diarisation**: Raise a too-low num_speakers when the participants list names more people ([#3953](https://familia.riera.co.uk/tasks/3953))
- **core**: Report swallowed marker/quarantine/config failures instead of dropping them ([#4374](https://familia.riera.co.uk/tasks/4374))
- **config**: Corrupt config falls back to plain defaults, not fresh-install ones; one .broken copy per content ([#4504](https://familia.riera.co.uk/tasks/4504))
- **summarise**: No diarisation labels is a meeting, not a solo memo; count only substantial voices ([#4503](https://familia.riera.co.uk/tasks/4503))
- **ops**: A failing check-seo.py stops site deploy.sh, with stub test ([#5025](https://familia.riera.co.uk/tasks/5025))
- **pipeline**: Terminal .unreadable marker after two identical conversion failures ([#5283](https://familia.riera.co.uk/tasks/5283))
- **pipeline**: Defer on context-too-small, fall back to WhisperKit on empty Parakeet output ([#5284](https://familia.riera.co.uk/tasks/5284))
- **menu**: Retry and Move to Bin for unreadable recordings; Process now revives them ([#5404](https://familia.riera.co.uk/tasks/5404))
- **gemma**: ContextTooSmall is a hard failure on the Gemma path, not an endless deferral ([#5405](https://familia.riera.co.uk/tasks/5405))
- **pipeline**: A terminal unreadable file is not also listed as failed ([#5477](https://familia.riera.co.uk/tasks/5477))
- **config**: A server target with no model key defaults to gemma4:26b, not llama3.1:8b ([#3952](https://familia.riera.co.uk/tasks/3952))
- **ops**: Site deploy ships assets/example-note.md despite the *.md exclude ([#5717](https://familia.riera.co.uk/tasks/5717))
- **capture**: Keep the recent-people popup target alive for the modal ([#5717](https://familia.riera.co.uk/tasks/5717))
- **diarisation**: Cut a gap-free word group at a speaker-turn boundary ([#3953](https://familia.riera.co.uk/tasks/3953))
- **diarisation**: Leading uncovered words take the first covered speaker ([#5934](https://familia.riera.co.uk/tasks/5934))
- **regenerate**: Recompute the recording-may-be-truncated flag from the saved segments and source length ([#4013](https://familia.riera.co.uk/tasks/4013))
- **diarisation**: Channel relabel keeps detections/engine keys so language and provenance survive ([#6353](https://familia.riera.co.uk/tasks/6353))
- **diarisation**: Channel relabel keeps untimed words, streams the file, defers to the diariser on 3+ person calls ([#6353](https://familia.riera.co.uk/tasks/6353))
- **release**: Refuse a release whose tag disagrees with MARKETING_VERSION ([#6070](https://familia.riera.co.uk/tasks/6070))
- **release**: Anchor the version match, cover release-appstore, extend the tag check tests ([#6070](https://familia.riera.co.uk/tasks/6070))
- **summary**: Verify the ledger before applying corrections; never double an already-corrected form ([#6354](https://familia.riera.co.uk/tasks/6354))
- **summary**: Corrections get an opt-out, skip URLs and code, and find their section reliably ([#6354](https://familia.riera.co.uk/tasks/6354))
- **summary**: Advice-call auto-pick wins the adviser tie, plurals, no generic finance words ([#6355](https://familia.riera.co.uk/tasks/6355))
- Review follow-ups (EOF-tolerant envelope read, exact hop rate, untimed words are not evidence, indented headings) ([#6353](https://familia.riera.co.uk/tasks/6353) [#6354](https://familia.riera.co.uk/tasks/6354))
- Review follow-ups (EOF-tolerant envelope read, exact hop rate, untimed words are not evidence, indented headings) ([#6353](https://familia.riera.co.uk/tasks/6353) [#6354](https://familia.riera.co.uk/tasks/6354))
- **diarisation**: Channel relabel keeps segments without words; auto speaker count honours the participants sheet ([#6353](https://familia.riera.co.uk/tasks/6353))
- **pipeline**: Reviewer findings verified by test, one failing test each ([#1793](https://familia.riera.co.uk/tasks/1793))
- **pipeline**: Reviewer follow-ups for the verified findings ([#1793](https://familia.riera.co.uk/tasks/1793))
- **regenerate**: Keep the channel-labelled owner speaker across a regenerate ([#1793](https://familia.riera.co.uk/tasks/1793))
- **pipeline**: Cap transient convert failures at five in a row ([#1793](https://familia.riera.co.uk/tasks/1793))
- **pipeline**: Partial WAV removal, live capture in the rejected-summary note, cancel is not a failure ([#1793](https://familia.riera.co.uk/tasks/1793))
- **speakers**: Channel relabel steps aside for 3+ diarised voices and one-sided files, back-fills leading words ([#1793](https://familia.riera.co.uk/tasks/1793))
- **pipeline**: Disk-full and permission errors never make a recording terminal ([#1793](https://familia.riera.co.uk/tasks/1793))
- **corrections**: Never rewrite the typed Highlights section of the owner ([#1793](https://familia.riera.co.uk/tasks/1793))
- **review**: Fence-aware Highlights chunking, integer side share with word floor, docs ([#1793](https://familia.riera.co.uk/tasks/1793))
- **review**: Role terms stay out of fuzzy vocabulary and after global terms; regenerate parity; unanswered mic permission ([#3950](https://familia.riera.co.uk/tasks/3950), [#3930](https://familia.riera.co.uk/tasks/3930))
- **vocab**: Role phrase in parentheses is not a participant term (test + fix, not yet compiled)
- **vocab**: Split role phrase on for only when a role precedes it, case-insensitive (review)
- **capture**: Restricted mic access has its own message, unknown cause mentions muting (review, [#3930](https://familia.riera.co.uk/tasks/3930))
- **guard**: Wider monitoring context for the offensive-word guard, sibling tools before/after ([#3951](https://familia.riera.co.uk/tasks/3951))
- **guard**: Context never crosses a sentence or line break; drop generic words (review, [#3951](https://familia.riera.co.uk/tasks/3951))
- **summary**: A prompt the tokenizer says overflows is chunked, not failed ([#5284](https://familia.riera.co.uk/tasks/5284))
- **cleaner**: Drop whole segments that are Whisper silence phrases ([#4025](https://familia.riera.co.uk/tasks/4025))
- **summary**: Context too small defers only while the window is 0 (review, [#5284](https://familia.riera.co.uk/tasks/5284))
- **ops**: App Store string checks no longer pass when the string is found (review)
- **pipeline**: Disk-full and transient conversion failures defer, not fail (review)
- **speakers**: A loose duplicate-call match never copies another recording's names (review, [#4014](https://familia.riera.co.uk/tasks/4014))
- **vocabulary**: "(CEO of Acme)" keeps Acme as a spelling term (review, [#3950](https://familia.riera.co.uk/tasks/3950))
- **summary**: An overflowing map chunk is split once; reduce keeps its budget (review, [#5284](https://familia.riera.co.uk/tasks/5284))
- **state**: Transient conversion failures count at most once an hour (review)
- **summary**: A collapse that survives the stiff retry is summarised part by part before the transcript-only fallback ([#4011](https://familia.riera.co.uk/tasks/4011))
- **summary**: Chunked collapse fallback keeps cancel/outage deferrable, falls back on a bad merge, cleans part notes ([#4011](https://familia.riera.co.uk/tasks/4011))
- **summary**: Scaffolding scrubber keeps "none" answers, ordinary lines and real Step headings ([#4010](https://familia.riera.co.uk/tasks/4010))
- **guard**: Regenerate, Ask and Summarise together guard text cached before the guard; hyphen/slash tool forms ([#3951](https://familia.riera.co.uk/tasks/3951))
- **capture**: End policy treats a free mic before any call as no signal, not an ended call ([#4007](https://familia.riera.co.uk/tasks/4007))
- **pipeline**: Timings on every done exit, last lap named summarise+note ([#4018](https://familia.riera.co.uk/tasks/4018))
- **ledger**: Real-name speaker fields are corrected from names learned across the ledger and first names of renamed labels ([#4017](https://familia.riera.co.uk/tasks/4017))
- **speakers**: User_speaker that is not a turn label of the transcript reads as unknown in the prompt ([#3857](https://familia.riera.co.uk/tasks/3857))
- **review**: Owner label resolves a first name, ledger skips SPEAKER_UNKNOWN holders and placeholder names, unicode-ellipsis quotes ([#3857](https://familia.riera.co.uk/tasks/3857), [#4017](https://familia.riera.co.uk/tasks/4017))
- **prompt**: SPEAKER ROLES block no longer says 'unknown IS <owner>' when the owner label is unknown ([#3857](https://familia.riera.co.uk/tasks/3857))
- **review**: Unknown owner label trims newlines, tests pin the ca/es unknown wording ([#3857](https://familia.riera.co.uk/tasks/3857))
- **review**: Opus review of o: "any speaker", newline-trimmed owner label, templated unknown test ([#3857](https://familia.riera.co.uk/tasks/3857), [#6647](https://familia.riera.co.uk/tasks/6647))
- **test**: TestTemp registers its observer on the main thread; async tests touched it off main ([#6647](https://familia.riera.co.uk/tasks/6647))
- **capture**: Call-end stop needs 90 s of unbroken call capture, resets while disarmed ([#4007](https://familia.riera.co.uk/tasks/4007))
- **review**: Invented fixture strings, markOffered reports failure, prefill takes its base, stronger tests, design note on register copy ([#4012](https://familia.riera.co.uk/tasks/4012) [#3934](https://familia.riera.co.uk/tasks/3934))
- **summary**: Summarise together reduces partials in bounded batches so a merge prompt never overflows the window ([#6070](https://familia.riera.co.uk/tasks/6070))
- **ops**: Pre-tag-check restores Package.resolved files it touches so the run leaves the tree as it found it ([#2679](https://familia.riera.co.uk/tasks/2679))
- **review**: Pre-tag-check snapshot uses the repo root, merge group budget leaves room for the shortened marker ([#2679](https://familia.riera.co.uk/tasks/2679) [#6070](https://familia.riera.co.uk/tasks/6070))
- **review**: No sticky root template pick, split temp is .part, speakers.json not inherited, gap-window speaker compare, stricter project auto-pick
- **capture**: Stop and tell the user when a microphone switch loses the device
- **settings**: Log a failed settings save instead of dropping it
- **pipeline**: Long recordings in bounded parts, long transcripts summarised in parts, no crash loop ([#6759](https://familia.riera.co.uk/tasks/6759))
- **pipeline**: Long-recording review follow-ups ([#6759](https://familia.riera.co.uk/tasks/6759))
- **capture**: Recording-cap review follow-ups
- **config**: Apply_corrections is off for configs that predate it, never rewrites ledger quotes (review A)
- **vocabulary**: Role-term packs are skipped for non-English meetings (review C)
- **vocabulary**: Role terms follow the language the transcriber runs with; corrections default off in SummaryChecks (review A, C)
- **core**: RecordingStorage allocated size, cancellation, entry cap, full-disk zero ([#6670](https://familia.riera.co.uk/tasks/6670))
- **settings**: Cancel the folder walk, cache it 60 s, hide size line without a recorder ([#6670](https://familia.riera.co.uk/tasks/6670))
- **speakers**: Seed the note owner's name and never infer the owner from "standing in for" ([#6772](https://familia.riera.co.uk/tasks/6772))
- **speakers**: Owner never creates a transcriber prompt, softer rule, capped merge ([#6772](https://familia.riera.co.uk/tasks/6772))


### Tooling

- Origin/main (PR #16 codex fixes) into the feedback drive
- Long recordings in bounded parts and the crash-loop guard ([#6759](https://familia.riera.co.uk/tasks/6759))
- Stop a recording automatically at 8 hours
- New behaviour keys inert for existing configs (drive review decisions A-C)
- Recording format picker, folder size and free disk in Settings ([#6670](https://familia.riera.co.uk/tasks/6670))
- Seed the note owner's name and stop inferring the owner from "standing in for" ([#6772](https://familia.riera.co.uk/tasks/6772))


### Documentation

- Refresh PROJECT_STATE for 1.20.0
- **drafts**: 1.20 addendum to the ca/es/en store listing draft ([#2140](https://familia.riera.co.uk/tasks/2140))
- **drafts**: App Store refresh pack: screenshot audit, shot list, vendor-number gate ([#3739](https://familia.riera.co.uk/tasks/3739))
- **release**: RELEASE.md runbook for 1.21 with pre-flight evidence and ordered commands ([#4064](https://familia.riera.co.uk/tasks/4064))
- **calendar**: EventKit vs Google spike, recommendation and the checks left for a signed build ([#4003](https://familia.riera.co.uk/tasks/4003))
- **listing**: Index of ca/es/en store copy drafts ([#2140](https://familia.riera.co.uk/tasks/2140))
- **ops**: Key inventory (names only) and incident runbook ([#4088](https://familia.riera.co.uk/tasks/4088))
- **speakers**: Edition-gated plan for persistent voice profiles ([#2944](https://familia.riera.co.uk/tasks/2944))
- **embedded**: Spike note mapping the macOS 27 LanguageModel protocol onto the summariser seam ([#2198](https://familia.riera.co.uk/tasks/2198))
- **embedded**: Note that CoreAI.framework has no language-model type, MLX vs CoreAI runner both external ([#2198](https://familia.riera.co.uk/tasks/2198))
- **changelog**: Generate CHANGELOG.md with git-cliff, add cliff.toml ([#4370](https://familia.riera.co.uk/tasks/4370))
- **quality**: Clean-clone quickstart check, architecture map, unify macOS 14+ ([#4371](https://familia.riera.co.uk/tasks/4371))
- Error-handling audit of discarded try? in the pipeline path ([#4374](https://familia.riera.co.uk/tasks/4374))
- **outreach**: AlternativeTo, OpenAlternative, Hugging Face and Softcatala drafts with checker ([#4664](https://familia.riera.co.uk/tasks/4664))
- **market**: First-run summariser fallback design note and checker ([#4665](https://familia.riera.co.uk/tasks/4665))
- **listing**: Localised App Store copy draft (en/ca/es full, de/fr/it fields) with character-limit checker ([#2972](https://familia.riera.co.uk/tasks/2972))
- **verify**: Scope and verification status for meeting detection and transcript viewer ([#2945](https://familia.riera.co.uk/tasks/2945), [#2951](https://familia.riera.co.uk/tasks/2951))
- **architecture**: Archify architecture diagram (json, html, png) and README link ([#3752](https://familia.riera.co.uk/tasks/3752))
- **setapp**: Submission packet index with requirements checklist, screenshots and 1.20 release notes ([#1958](https://familia.riera.co.uk/tasks/1958))
- Deferred/tooShort statuses, call sidecars, CI and version-bump are workflow_dispatch only ([#5717](https://familia.riera.co.uk/tasks/5717))
- **memory**: Findings and proposed fix for the 9.6 GB growth, by code reading ([#4019](https://familia.riera.co.uk/tasks/4019))
- **summary**: Name the sole caller of SummaryDriverError.deferral; Gemma hard-fails by design ([#5536](https://familia.riera.co.uk/tasks/5536))
- **summary**: Name Advice call in the template help text and add its manual check ([#6355](https://familia.riera.co.uk/tasks/6355))
- **summary**: Manual check states the adviser tie as the tests do ([#6355](https://familia.riera.co.uk/tasks/6355))
- **summary**: Use the adviser-plus-profession example from the tests ([#6355](https://familia.riera.co.uk/tasks/6355))
- **review**: Drive review of the h chain with merge recommendation and by-eye checklist
- **review**: Second review round, counts and open lows
- **state**: Next action is the review doc and the j merge
- **summary**: Evidence and recommendation on defaulting embedded_enabled ([#1793](https://familia.riera.co.uk/tasks/1793))
- **review**: Review of k and the l fixes, next action names the l branch
- **remotes**: Remote direction map and merge-order checklist ([#1925](https://familia.riera.co.uk/tasks/1925))
- **state**: Next action names branch p and the merge checklist ([#1925](https://familia.riera.co.uk/tasks/1925))
- Keep the already-published Setapp listing draft and trademark note
- **claude**: Long recordings, crash-loop guard, recording cap and part caches ([#6759](https://familia.riera.co.uk/tasks/6759))
- **state**: Checkpoint of the 2026-11-14 feedback drive


### Tests

- **pipeline**: DISTAVO_LIVE footprint guard, 30 synthetic runs stay flat ([#4019](https://familia.riera.co.uk/tasks/4019))
- **summary**: Pin the action-deadline rule in map and shared prompts ([#1793](https://familia.riera.co.uk/tasks/1793))
- **summary**: Give the solo-memo fixture enough words ([#4015](https://familia.riera.co.uk/tasks/4015))
- **core**: Coverage floor script and unit tests for HTTPSupport, NoteAssembly, StoredZipWriter, SummaryRouting, SummaryGenerator ([#4367](https://familia.riera.co.uk/tasks/4367))
- **vocab**: Correct expected term order for role-phrase test (compiled, 1561 tests pass)
- Every DistavoCore test uses a per-test temp dir removed when the test ends ([#6647](https://familia.riera.co.uk/tasks/6647))
- **embedded**: Every DistavoEmbedded test uses a per-test temp dir removed when the test ends ([#6647](https://familia.riera.co.uk/tasks/6647))
- **quality**: Synthetic panel fixture pins ledger checks and records the open gaps ([#3934](https://familia.riera.co.uk/tasks/3934))
- **summary**: Catalan repetition-collapse fixture pins the validator; findings table updated ([#3931](https://familia.riera.co.uk/tasks/3931))


### CI and build

- **ops**: Fast smoke script and a smoke job in CI ([#4368](https://familia.riera.co.uk/tasks/4368))
- Pin checkout by SHA in ci.yml, same pin as ci/gitleaks-pins-2026-10-24 ([#4369](https://familia.riera.co.uk/tasks/4369))
- **release**: Run the tag/version check before building ([#6070](https://familia.riera.co.uk/tasks/6070))
- **release**: Submit-appstore checks the version against MARKETING_VERSION; document the tag rule ([#6070](https://familia.riera.co.uk/tasks/6070))


### Maintenance

- **ops**: Pre-tag check script, static/default/full modes ([#2679](https://familia.riera.co.uk/tasks/2679))
- **ops**: Lint-scripts.sh (set -u, bash -n, shellcheck, no swallowed Python exceptions) with negative tests ([#4374](https://familia.riera.co.uk/tasks/4374))
- Restore Package.resolved accidentally included in the previous commit
- Restore main's DistavoEmbedded Package.resolved, the toolchain rewrote it to v3 and dropped the Sparkle pin
- **release**: Bump version to 1.21.0 (build 24), What's New for 1.21 [skip version bump]

## [1.20.0] - 2026-10-21

### Features

- **vocabulary**: Offer to clear unheard terms when participants or language change
- **summary**: Pure core for "Summarise together" - batching, map-reduce, citation check, output note ([#3199](https://familia.riera.co.uk/tasks/3199))
- **notes**: "Summarise Together…" action, title sheet and cited project note ([#3199](https://familia.riera.co.uk/tasks/3199))


### Documentation

- **release**: What's New for 1.20.0


### Maintenance

- **release**: Bump version to 1.20.0 (build 23) [skip version bump]

## [1.19.0] - 2026-10-16

### Features

- **summary**: LedgerVerifier drops or flags facts-ledger rows the transcript does not support
- **speakers**: Derive the speaker count from the participants list, warn on mismatch, default to auto
- **templates**: Pick the summary template per recording (Auto) and add a Consultancy template
- **summary**: Make note_language stick for non-English notes
- **vocabulary**: Per-meeting terms, a Catalan IT replacement pack, glossary as a spelling aid
- **capture**: Trim a long silent tail off a finished recording
- **settings**: Roomier first-launch Settings window
- **transcribe**: Re-decode audible speech the first pass dropped
- **vocabulary**: Learn replacements from transcript-editor corrections; show last-heard per term ([#3584](https://familia.riera.co.uk/tasks/3584))
- **recording**: Warn when nothing is heard in the first 15 seconds ([#3502](https://familia.riera.co.uk/tasks/3502))


### Bug fixes

- **prompt**: Remove IR35/Slurm/EMBL/date examples from the default facts_first prompt
- **summary**: LedgerVerifier number-word parser cannot overflow
- **state**: Retry sets a leftover failed note aside instead of skipping the recording
- **capture**: Language-sample footer, in-person (mic only) mode, 'The note owner (me)' label
- **transcribe**: Repair zero-length word timings and mid-sentence speaker flips
- **transcribe**: Join short flips inside an unfinished sentence ([#3583](https://familia.riera.co.uk/tasks/3583))
- **transcribe**: Re-decode dropped speech without the vocabulary prompt ([#3579](https://familia.riera.co.uk/tasks/3579))
- **summary**: On-device reminder, speaker-label repair, defer on zero context ([#1793](https://familia.riera.co.uk/tasks/1793))
- **transcribe**: Give a lowercase continuation of an unfinished sentence back to its speaker ([#3583](https://familia.riera.co.uk/tasks/3583))
- **transcribe**: Find prompt-collapsed chunks by word count and drop re-decoded duplicates ([#3579](https://familia.riera.co.uk/tasks/3579))
- **embedded**: HoleRecovery compiles on Xcode 26 (release archive)


### Refactoring

- **pipeline**: Shared post-summary checks and a two-part note footer
- **transcribe**: One wording for engine and language in log and note footer ([#2675](https://familia.riera.co.uk/tasks/2675))


### Documentation

- **ci**: Workflow headers say GitHub is primary and Forgejo a read-only mirror
- **release**: Release docs and skill match the manual-dispatch CI
- CLAUDE.md lists the 2026-10-16 modules
- **setapp**: Re-verify the Setapp edition and move the runbook to Single App Distribution
- **setapp**: Refresh the listing draft for 1.19
- **marketing**: Refresh the App Review rejection LinkedIn draft for October 2026 ([#1008](https://familia.riera.co.uk/tasks/1008))
- **manual-checks**: 1.19 stop dialog, templates and transcription checks
- **release**: What's New for 1.19.0
- CLAUDE.md describes the reconciled hole recovery and turn repair


### Tests

- **embedded**: Gated probe that decodes the app's VAD chunks several ways
- **summary**: LedgerVerifier checks asterisk-bullet ledger rows ([#3581](https://familia.riera.co.uk/tasks/3581))


### Maintenance

- **release**: Bump version to 1.19.0 (build 22) [skip version bump]

## [1.18.0] - 2026-10-07

### Features

- **notes**: NotesLibrary lists notes with per-action availability
- **queue**: A waiting or running regenerate is a row in the queue
- **settings**: Name what Settings holds and compare Ollama model sizes
- **recorder**: Say what "Default from Settings" is for note language and template
- **settings**: Choose the bigger model from the server's list, with a size verdict
- **notes**: Notes window with every per-note action on the selected note
- **automation**: Distavo://notes opens the Notes window


### Bug fixes

- **regenerate**: Give an extra instruction somewhere to go in the note
- **notes**: Keep command names whole and give the detail pane the room
- **notes**: Review fixes for the Notes window and regenerate queue rows
- **convert**: Converting a recording no longer opens an audio device
- **export**: The save panel starts with the note's name, not "Untitled"


### Documentation

- **notes**: Notes window guide, changed manual checks, project guide
- **release**: What's New for 1.18.0


### Maintenance

- **release**: Bump version to 1.18.0 (build 21) [skip version bump]

## [1.17.0] - 2026-10-05

### Features

- **settings**: Sidebar Settings window with one view per pane
- **notes**: Write notes in any language, fixed or matching the meeting
- **summarise**: Honour note language on Apple's on-device model when supported
- **settings**: Note-language picker with fixed languages and per-recording override
- **core**: Regenerate a note from its cached transcript ([#2947](https://familia.riera.co.uk/tasks/2947))
- **app**: Regenerate Note… menu action and window ([#2947](https://familia.riera.co.uk/tasks/2947))
- **transcript**: Persist timed segments sidecar after transcription ([#2943](https://familia.riera.co.uk/tasks/2943))
- **export**: SRT, WebVTT, JSON, HTML, DOCX and PDF transcript exporters ([#2943](https://familia.riera.co.uk/tasks/2943))
- **menu**: Export Transcript As… with format picker ([#2943](https://familia.riera.co.uk/tasks/2943))
- **vocabulary**: Custom glossary and replacement dictionary in core ([#2939](https://familia.riera.co.uk/tasks/2939))
- **vocabulary**: Feed glossary to built-in engines, summarisers and Settings ([#2939](https://familia.riera.co.uk/tasks/2939))
- **summarise**: Summary templates per meeting type and per recordings subfolder ([#2940](https://familia.riera.co.uk/tasks/2940))
- **regenerate**: Template picker in the Regenerate Note window ([#2940](https://familia.riera.co.uk/tasks/2940))
- **core**: FTS5 search index over notes and transcripts ([#2942](https://familia.riera.co.uk/tasks/2942))
- **app**: Search Notes window, index on note write and reconcile at launch ([#2942](https://familia.riera.co.uk/tasks/2942))
- **core**: Automation URL parser and queued-file naming ([#2953](https://familia.riera.co.uk/tasks/2953))
- **app**: App Intents, distavo:// URL scheme and Finder Service ([#2953](https://familia.riera.co.uk/tasks/2953))
- **detect**: Pure meeting-detection policy and opt-in config section ([#2945](https://familia.riera.co.uk/tasks/2945))
- **detect**: Offer to record when a listed call app uses the mic ([#2945](https://familia.riera.co.uk/tasks/2945))
- **speakers**: Rename speakers across note, transcript and timed sidecar ([#2944](https://familia.riera.co.uk/tasks/2944))
- **speakers**: Rename Speakers window and menu action ([#2944](https://familia.riera.co.uk/tasks/2944))
- **actions**: Action items parser, toggle, scan, Tasks prompt and Reminders export logic ([#2941](https://familia.riera.co.uk/tasks/2941))
- **actions**: Open Action Items window, Reminders sink and Notes-pane toggle ([#2941](https://familia.riera.co.uk/tasks/2941))
- **actions**: Reminders usage strings and Calendars entitlement for all editions ([#2941](https://familia.riera.co.uk/tasks/2941))
- **transcript**: Timeline lookup, edit model and save/revert with originals ([#2951](https://familia.riera.co.uk/tasks/2951))
- **transcript**: Audio-synced transcript viewer window with click-to-seek, editing and re-summarise ([#2951](https://familia.riera.co.uk/tasks/2951))
- **summary**: Typed scratchpad notes steer the note and surface as Highlights ([#2949](https://familia.riera.co.uk/tasks/2949))
- **capture**: Quick Notes panel types scratchpad lines during a recording ([#2949](https://familia.riera.co.uk/tasks/2949))
- **queue**: Processing-queue reducer, ETA learning, sequential scan loop and single-base retry ([#2952](https://familia.riera.co.uk/tasks/2952))
- **queue**: Processing Queue window with drag-and-drop, pause, skip, single-file retry and reprocess ([#2952](https://familia.riera.co.uk/tasks/2952))
- **bookmarks**: Key-moment markers, note section and m4a clip export in DistavoCore ([#2950](https://familia.riera.co.uk/tasks/2950))
- **capture**: Mark Key Moment menu item, global hotkey, clip export and Settings section ([#2950](https://familia.riera.co.uk/tasks/2950))
- **ask**: Retrieval, budgeted prompt, citations and local-only guard for Ask Your Notes ([#2948](https://familia.riera.co.uk/tasks/2948))
- **ask**: Generic completion on Apple Foundation Models and Gemma ([#2948](https://familia.riera.co.uk/tasks/2948))
- **ask**: Ask Your Notes chat window and menu item ([#2948](https://familia.riera.co.uk/tasks/2948))
- **calendar**: Match recordings to calendar events in DistavoCore ([#2946](https://familia.riera.co.uk/tasks/2946))
- **calendar**: EventKit provider, recorder rename, Settings section, usage strings, manual checks ([#2946](https://familia.riera.co.uk/tasks/2946))
- **notes**: Obsidian-friendly frontmatter, auto title/tags, tracked terms, vault export logic ([#2954](https://familia.riera.co.uk/tasks/2954))
- **settings**: Obsidian & frontmatter section, vault folder bookmark, vault copy after each note ([#2954](https://familia.riera.co.uk/tasks/2954))


### Bug fixes

- **settings**: Keep model download state across pane switches; fix filter selection
- **notes**: Only follow the sidecar spoken language when transcription honoured it
- **summarise**: Count the note-language rule in the final prompt budget
- **core**: Regenerate keeps the detected note language and honours the on-device kill switch ([#2947](https://familia.riera.co.uk/tasks/2947))
- **transcript**: Remove a stale segments sidecar when a base is re-processed ([#2943](https://familia.riera.co.uk/tasks/2943))
- **export**: Clamp corrupt timings, monotonic cues, escape VTT voice names ([#2943](https://familia.riera.co.uk/tasks/2943))
- **menu**: Keep typed export filename, render export off the main thread ([#2943](https://familia.riera.co.uk/tasks/2943))
- **vocabulary**: Narrow echo detection, use variant glossary, fit prompt by tokens
- **vocabulary**: Lenient config decode, encode + in initial_prompt, unspaced scripts, compile rules once
- **vocabulary**: Regenerate passes the glossary, composes with custom instruction
- **vocabulary**: Apply replacements to the timed transcript sidecar
- **summarise**: Window guard counts glossary and instruction; compose tests ([#2940](https://familia.riera.co.uk/tasks/2940))
- **search**: Keep rows of unlistable folders, never delete a busy index, opt-in gate, heading titles
- **search**: Opt-in on first open, dedicated work queue, cancel on delete; docs
- **automation**: Temp-copy naming, source checks and URL throttle helpers ([#2953](https://familia.riera.co.uk/tasks/2953))
- **automation**: Safer record prompt, background copies, source validation ([#2953](https://familia.riera.co.uk/tasks/2953))
- **detect**: Per-app capture signal, monotonic clock, gap handling in the policy ([#2945](https://familia.riera.co.uk/tasks/2945))
- **detect**: Per-process capture signal, start-only Record, stale-offer withdrawal ([#2945](https://familia.riera.co.uk/tasks/2945))
- **speakers**: Track merge targets in the mapping sidecar ([#2944](https://familia.riera.co.uk/tasks/2944))
- **speakers**: Rename label positions only, strict file handling, merge backups, reset ([#2944](https://familia.riera.co.uk/tasks/2944))
- **speakers**: Merge confirmation, reset action, search re-index, no note cap ([#2944](https://familia.riera.co.uk/tasks/2944))
- **speakers**: Safe reset, narrower attribution rules, template label shapes, dry run ([#2944](https://familia.riera.co.uk/tasks/2944))
- **speakers**: Note-change preview, safe reset action and merge copies in the window ([#2944](https://familia.riera.co.uk/tasks/2944))
- **actions**: In-place tick, parser edge cases, scan cap, verbatim stock rules, no crash on prompt mismatch ([#2941](https://familia.riera.co.uk/tasks/2941))
- **actions**: Serialise Reminders export, keep a corrupt ledger aside ([#2941](https://familia.riera.co.uk/tasks/2941))
- **actions**: Ticks via controller lock and serial queue, search re-index, tasks log line, disabled send buttons ([#2941](https://familia.riera.co.uk/tasks/2941))
- **transcript**: Refuse save/revert when files changed on disk since load ([#2951](https://familia.riera.co.uk/tasks/2951))
- **transcript**: Stale highlight/seek with unsaved edits, busy picker, replay at end, cached headers ([#2951](https://familia.riera.co.uk/tasks/2951))
- **transcript**: Revert keeps speaker renames, restores text only ([#2951](https://familia.riera.co.uk/tasks/2951), [#2944](https://familia.riera.co.uk/tasks/2944))
- **transcript**: Ask Save/Discard/Cancel for unsaved edits on quit ([#2951](https://familia.riera.co.uk/tasks/2951))
- **summary**: Consistent Highlights instructions, tolerant duplicate detection, pinned prompt digests ([#2949](https://familia.riera.co.uk/tasks/2949))
- **capture**: Commit draft on stop, debounced off-main writes, hide panel from screen share, drop notes with binned recording ([#2949](https://familia.riera.co.uk/tasks/2949))
- **queue**: Pause policy table, testable batch coordinator, cap on finished rows ([#2952](https://familia.riera.co.uk/tasks/2952))
- **queue**: Pause holds automatic work only, private(set) scan state, trash drops queued retry, probe unreadable durations once ([#2952](https://familia.riera.co.uk/tasks/2952))
- **bookmarks**: Never duplicate Key moments, stop at first sidecar match, add golden tests ([#2950](https://familia.riera.co.uk/tasks/2950))
- **capture**: Cache export state off-main, recorder-start marker clock, live hotkey config, private notifier ([#2950](https://familia.riera.co.uk/tasks/2950))
- **network**: Classify local hosts by IP literal, not hostname prefix
- **ask**: No redirects, no live links, cancel-safe stop, busy check at point of use
- **network**: Parse the connection host once; judge numeric forms and zone ids on the real address
- **ask**: Pin the request to the validated address, no proxy, resolve names
- **ask**: Single immutable pinned endpoint; validate every resolver result
- **network**: Fail closed on any unreadable or over-long resolver answer; keep userinfo classification for summary callers
- **ask**: Local-only check before any network call, one bounded resolution, scoped link-local, safe refusal text
- **calendar**: Derive the recorder-name meeting date with the time zone in force now
- **calendar**: Treat events as untrusted, fold titles to ASCII, rank by overlap/union, crash-safe rename
- **calendar**: Trust filter in the provider, lookup after Stop off-main with timeout, Settings caption, docs
- **calendar**: Fail-closed trust allow-list and allow-list attendee-name sanitiser
- **calendar**: Restore main's recorder-name date rule; matched recordings carry their own start
- **calendar**: Calendar-lookup evidence accepts only the recorder's exact name or media metadata
- **calendar**: Reject punctuation-led or fragmented attendee names and mark floods
- **calendar**: Treat delegate-source calendars as not owned; document the missing shared-calendar API
- **calendar**: Unconfirmed calendar attendees go in their own untrusted-data prompt block, never the authoritative participants
- **search**: Index note bodies without frontmatter and use its title ([#2954](https://familia.riera.co.uk/tasks/2954))
- **notes**: Strict frontmatter fence; speaker rename rewrites only the body and attendees ([#2954](https://familia.riera.co.uk/tasks/2954))
- **notes**: Fixed note order, vault never inside scanned folders, title without frontmatter, byte-limited names, vault refresh after rename ([#2954](https://familia.riera.co.uk/tasks/2954))
- **calendar**: List unconfirmed attendee names one quoted item per line
- **actions**: Keep a task's due date when the model annotates it


### Tooling

- Main ([#2954](https://familia.riera.co.uk/tasks/2954) frontmatter, [#2948](https://familia.riera.co.uk/tasks/2948)) into feature/2946-calendar-titles


### Documentation

- **settings**: Redesign checklist and manual checks
- **notes**: Manual checks for note language
- **manual**: Checks for regenerate note ([#2947](https://familia.riera.co.uk/tasks/2947))
- **app**: Note legacy-language caveat in the regenerate window ([#2947](https://familia.riera.co.uk/tasks/2947))
- **search**: Search.md, manual checks, runtime data location ([#2942](https://familia.riera.co.uk/tasks/2942))
- **detect**: Manual verification checklist for meeting detection ([#2945](https://familia.riera.co.uk/tasks/2945))
- **detect**: Update verification checklist for the per-process signal ([#2945](https://familia.riera.co.uk/tasks/2945))
- **actions**: Manual checks for action items and Reminders export ([#2941](https://familia.riera.co.uk/tasks/2941))
- **transcript**: Manual checks for the transcript viewer ([#2951](https://familia.riera.co.uk/tasks/2951))
- **transcript**: Describe edit/original files in the sidecar doc ([#2951](https://familia.riera.co.uk/tasks/2951))
- **ask**: Manual checks for Ask Your Notes ([#2948](https://familia.riera.co.uk/tasks/2948))
- **notes**: Document the fixed note section order ([#2954](https://familia.riera.co.uk/tasks/2954))
- **release**: What's New for 1.17.0
- **claude**: Describe the 1.17 modules, sidecars and behaviours to preserve


### Tests

- **core**: Regenerate language parity, kill-switch fallback, rollback, variant base ([#2947](https://familia.riera.co.uk/tasks/2947))
- **export**: Regenerate keeps the segments sidecar ([#2943](https://familia.riera.co.uk/tasks/2943))
- **notes**: Review-fix coverage for order, conflicts, titles, fence, rename, names ([#2954](https://familia.riera.co.uk/tasks/2954))


### CI and build

- **release**: Allow the App Store archive step 30 min (MLX build exceeded 10)


### Maintenance

- **repo**: Union-merge the shared manual-checks file
- **release**: Bump version to 1.17.0 (build 20) [skip version bump]

## [1.16.0] - 2026-10-04

### Features

- **log**: Add per-recording routing trace line to the activity log
- **config**: Add summarise.embedded_model and summary model catalogue
- **pipeline**: Carry the embedded summary model through the DI seam
- **embedded**: MLX Gemma summary generator with loop guard and failure policy
- **embedded**: Download, verify and route the local Gemma summary model
- **settings**: Local Gemma summary model picker, download controls and routing trace


### Bug fixes

- **ci**: Notarise Direct DMG with the ASC API key; allow release.yml dispatch for an existing tag
- **summary**: Count end-of-turn block in budget and harden cleanup helpers
- **embedded**: Require sha256 in model manifests and hash every summary file
- **embedded**: Recover from unreadable weights, widen Key-people matching, tighten removal
- **embedded**: Never call into MLX unless a model was loaded
- **embedded**: Inject memory/CPU into SummaryModelManager so tests do not depend on the host


### Refactoring

- **summary**: Engine-agnostic SummaryGenerator driver with loop guard and cleanup helpers
- **embedded**: Make the Gemma pipeline route and edition gate testable


### Documentation

- **claude**: Bump to v1.15.0, note SilenceMonitor
- **release**: ASC-key notarisation, release_tag dispatch, CI appcast publish
- **release**: What's New for 1.16.0


### Tests

- **embedded**: Headless pipeline tests for the local Gemma summary path


### CI and build

- **release**: Publish the signed appcast to distavo.com from release.yml


### Maintenance

- Ignore .secrets-local/ (local deploy key material)
- **release**: Bump version to 1.16.0 (build 19) [skip version bump]

## [1.15.0] - 2026-09-29

### Features

- **ops**: Submit-when-review-clears — dispatch the App Store submission once the previous version leaves App Review
- **site**: Lead with the languages other transcribers skip
- **settings**: Checkboxes for actions when a recording finishes ([#2205](https://familia.riera.co.uk/tasks/2205))
- **capture**: Confirm the detected meeting language after Stop ([#2202](https://familia.riera.co.uk/tasks/2202))
- **compare**: Compare two models side by side ([#2201](https://familia.riera.co.uk/tasks/2201))
- **router**: Detect language for pinned models and report it in the note footer
- **config**: Silence suggest/auto-stop options, off by default ([#2665](https://familia.riera.co.uk/tasks/2665))
- **core**: SilenceMonitor policy for recorder silence handling ([#2665](https://familia.riera.co.uk/tasks/2665))
- **capture**: Suggest or auto-stop a recording after silence ([#2665](https://familia.riera.co.uk/tasks/2665))


### Bug fixes

- **embedded**: Gate nextBigger() by memory floor and pack opt-in
- **capture**: Only an explicit language pick writes the override sidecar
- **ollama**: Send think:false so gemma4 does not degenerate
- **validator**: Make word regex Unicode-aware for ca/es notes
- **validator**: Keep combining marks inside words (Tamil/Thai/NFD)
- **pipeline**: Quarantine failed summaries in the work dir
- **pipeline**: Say where the rejected summary was kept
- **embedded**: Never leave WhisperKit with neither a language nor detection
- **router**: Do not force an uncovered language onto a pinned fine-tune
- **capture**: Skip speakers dialog on silence auto-stop, avoid modal from queued jobs ([#2665](https://familia.riera.co.uk/tasks/2665))


### Documentation

- **skill**: Distavo-release — one version in review at a time, and the poller
- **skills**: Fix StatusMenu.swift line ref for the DONATE_ENABLED gate
- **drafts**: Backlog drafts for [#2601](https://familia.riera.co.uk/tasks/2601) [#2140](https://familia.riera.co.uk/tasks/2140) [#2198](https://familia.riera.co.uk/tasks/2198) [#1793](https://familia.riera.co.uk/tasks/1793)
- **plan**: Silence auto-stop design ([#2665](https://familia.riera.co.uk/tasks/2665))
- **capture**: Manual checks for silence handling ([#2665](https://familia.riera.co.uk/tasks/2665))


### Maintenance

- Record the Vikunja project this folder belongs to
- **tracker**: Reconcile plans with vikunja
- **release**: Bump version to 1.15.0 (build 18) [skip version bump]

## [1.14.0] - 2026-09-17

### Features

- **packs**: Tamil pack on vasista22/whisper-tamil-large-v2 ([#2128](https://familia.riera.co.uk/tasks/2128))
- **packs**: Norwegian (Bokmål + Nynorsk) pack on NbAiLab/nb-whisper-large-verbatim ([#2129](https://familia.riera.co.uk/tasks/2129))


### Bug fixes

- **settings**: Pinned Save bar, unsaved-changes state, save on close, no stale "Saved" message
- **summarise**: Reject truncated notes and retry once ([#2203](https://familia.riera.co.uk/tasks/2203))
- **summarise**: Facts-first never leaks its working steps into the note ([#2203](https://familia.riera.co.uk/tasks/2203))


### Documentation

- **testing**: Scripted test meeting with a tick list of facts the note must carry


### Maintenance

- **release**: Bump version to 1.14.0 (build 17) and write What's New [skip version bump]

## [1.13.0] - 2026-09-17

### Features

- **settings**: Toggle for on-device summaries (embedded_enabled), still off by default
- **release**: App Store screenshots recaptured from the sandboxed App Store build (1.12)
- **packs**: Opt-in language packs — catalog, config key, router rule and Settings toggles ([#2124](https://familia.riera.co.uk/tasks/2124))
- **capture**: Mono + loudness fallback when the system-audio channel is silent ([#2060](https://familia.riera.co.uk/tasks/2060))
- **packs**: Welsh, Icelandic and Norwegian (Bokmål + Nynorsk) language packs ([#2129](https://familia.riera.co.uk/tasks/2129))
- **packs**: Tagalog, Gujarati, Tamil and Malayalam language packs ([#2128](https://familia.riera.co.uk/tasks/2128))
- **tools**: PSNR_THR override for fine-tunes whose fp16 decoder sits below the converter's 35 dB gate
- **settings**: Open the note or transcript when a recording finishes ([#2199](https://familia.riera.co.uk/tasks/2199))
- **summarise**: Notes written in the meeting's language for Catalan and Spanish ([#2147](https://familia.riera.co.uk/tasks/2147))


### Bug fixes

- **summarise**: Facts-first keeps the IR35 qualifier and derives the contracting-structure action ([#2057](https://familia.riera.co.uk/tasks/2057))
- **tools**: Fill in alignment_heads before converting, so fine-tunes without it get a text decoder
- **summarise**: Stop the on-device stamp from covering every action row ([#1793](https://familia.riera.co.uk/tasks/1793))
- **tools**: Strip _from_model_config so the added alignment_heads survive loading
- **transcribe**: Run the Whisper text decoder on the GPU instead of the Neural Engine ([#2158](https://familia.riera.co.uk/tasks/2158))
- **packs**: Withdraw the Norwegian pack from 1.13 — NB-Whisper's no-captions token starves WhisperKit decoding
- **packs**: No Tagalog pack — the small fine-tune loses to stock turbo on real code-switched speech ([#2128](https://familia.riera.co.uk/tasks/2128))
- **packs**: Withdraw Gujarati and Malayalam — their medium decoders do not survive Core ML conversion ([#2128](https://familia.riera.co.uk/tasks/2128))
- **packs**: Withdraw Tamil — the fine-tune hallucinates a fluent off-topic passage where stock turbo stays on topic ([#2128](https://familia.riera.co.uk/tasks/2128))
- **packs**: Withdraw Icelandic — the v1-based fine-tune replaces a passage with invented numbers ([#2129](https://familia.riera.co.uk/tasks/2129))


### Documentation

- Describe the opt-in language packs and their memory floors
- Classic prompt is no longer verbatim after the [#1793](https://familia.riera.co.uk/tasks/1793) tuning
- **tools**: Record the 1.13 language-pack conversions and the converter traps
- CLAUDE.md version 1.13.0
- README memory-floor line matches the three shipped packs
- **marketing**: Draft the App Review rejection follow-up post ([#1008](https://familia.riera.co.uk/tasks/1008))
- **marketing**: Draft 1.13 store listing copy in Catalan, Spanish and English ([#2140](https://familia.riera.co.uk/tasks/2140))
- **spec**: Local Gemma summaries via the macOS 27 LanguageModel protocol — design spike ([#2198](https://familia.riera.co.uk/tasks/2198))
- **release**: What's New covers meeting-language notes and open-when-done


### Maintenance

- **release**: Bump version to 1.13.0 (build 16) and write What's New [skip version bump]

## [1.12.0] - 2026-09-16

### Features

- **site**: Lead the hero with the App Store, de-emphasize the direct build
- **site**: 1.11 product shot — Settings with Automatic engine and language, Catalan model, Download now
- **site**: Show the tier-1 languages in their own language under the hero
- **site**: Greet visitors in their own language on landing
- **site**: Say plainly that Apple does not do Catalan and Distavo does
- **core**: Set aside too-short recordings, speaker hints, recording compaction, detections on the result
- **capture**: Stop-and-delete, early silent-system-audio warning, and the "who was in this meeting?" question
- **menu**: Offer to delete too-short recordings; show detected language; new recording settings
- "Process a recording with…" — pick a file, model and language; note written beside the normal one
- **summarise**: Facts-first prompt (bake-off variant D), gemma4:26b default, NoteContext
- **settings**: Prompt-style picker; keep the summariser regression harness in-repo (transcripts stay out)
- **settings**: "Benchmark this Mac" — time each downloaded engine, measured model suggestion


### Bug fixes

- **site**: Collapse the mobile nav into one scrollable row
- **core**: Compaction is opt-in for existing configs; fingerprint too-short markers by file size
- **pipeline**: Set a too-short recording aside before choosing the summariser
- **summarise**: Facts-first prompt is a fresh-install default, classic for existing configs
- **benchmark**: Two passes per model, keep the warm one


### Documentation

- **claude**: Record the too-short marker, speaker hints and compaction behaviours


### Maintenance

- **release**: Bump version to 1.12.0 (build 15) [skip version bump]


### Style

- Drop the blank lines an edit helper doubled

## [1.11.0] - 2026-09-10

### Features

- **catalog**: Add Parakeet and the two BSC Catalan models with engine, repo, language coverage and memory floor
- **config**: Preferred Catalan model, and automatic engine/language for fresh installs only
- **router**: Pure engine routing with Catalan-first mixture rules and the 16 GB gate
- **core**: Word-to-speaker aligner with SpeakerKit's subsegment semantics
- **embedded**: Model coordinator actor — per-model readiness, exclusive access, free-space check
- **transcribe**: WhisperKit engine takes the router's model and language, loads custom repos, and frees the model before diarisation
- **embedded**: Whisper-tiny language detector over three speech windows
- **embedded**: Parakeet transcriber via FluidAudio with SpeakerKit speakers
- **app**: Detect, route and dispatch between WhisperKit, the BSC models and Parakeet
- **settings**: Grouped engine picker with Automatic, preferred Catalan model and Download now
- **embedded**: Verify custom model downloads against their manifest
- **pipeline**: Back off deferrals and skip re-converting a fresh WAV
- **embedded**: Two-strike manifest failures, verify-once sentinel
- **notes**: Append a provenance footer naming the transcription engine


### Bug fixes

- **ci**: Build each edition with its own scheme, not the Direct scheme relabelled
- **pipeline**: Defer, don't fail, when a transcription dependency is temporarily unavailable
- **transcribe**: An offline model download now defers the recording instead of failing it
- **embedded**: FreeSpaceBytes falls back to nearest existing ancestor
- **transcribe**: Throw a typed error for a Parakeet model instead of crashing, and stop the download-progress race
- **embedded**: Release audio buffer before model load; fix window-grid fallback
- **embedded**: Stop a late download-progress callback from resurrecting "downloading"
- **app**: Decouple the 'Using …' engine line from language detection
- **settings**: Keep the Model picker's selection valid and make prefetch cancellation truthful
- **embedded**: Only verify manifest after a fresh download, and surface a failed cleanup
- **transcribe**: Never leak the "auto" language sentinel to WhisperX
- **embedded**: A broken language detector must not fail the recording
- **ci**: Keep the trait-check step's shell script valid YAML
- **detector**: Convert WhisperKit log-probabilities so detections can clear the router's floor
- **notes**: One detection per language in the provenance footer; scope the What's New line to built-in engines
- **release**: Keep entitlements and the App Store profile off SwiftPM resource bundles


### Tooling

- **models**: WhisperKit conversion script and manifest generator for the BSC models
- **models**: Create the Hugging Face repo before uploading
- **models**: Re-save BSC .bin weights as safetensors before converting (torch 2.5 refuses .bin)
- **models**: Prove the BSC Catalan model through Distavo's engine and document the pipeline


### Documentation

- **spec**: Design for 1.11 — BSC Catalan models and Parakeet as built-in engines
- **spec**: V2 of the 1.11 engines design after the Codex review
- **plan**: Implementation plan for the 1.11 engines (16 TDD tasks)
- **plan**: Fold in the pre-flight findings — WhisperKit layout, FluidAudio model dir and init, aligner unknown rule, fixture arithmetic
- **plan**: Aligner uses SpeakerKit's 0.15 s grouping gap and a separate 1.0 s carry gap
- Record the measured 3.1 GB BSC model size and the conversion facts
- **plan**: Drop the unused InsufficientDiskSpace type from Task 8's interface list
- **plan**: Prefetch primes and resets download tracking per the Task 11 ruling
- **spec**: §5.9 detects only when both settings are automatic, matching §5.2; report the chosen engine whenever the model is automatic
- **plan**: Task 14 records the out-of-band conversions and narrows to the in-app proof and README
- The shipped engine translates non-English meetings under language=en; redesign the bake-off around like-for-like language settings
- **plan**: Bake-off scoring — score.py for the English call, a counted checklist for the Catalan notes, Marc's read as the go/no-go
- **store**: Describe 1.11 built-in Catalan/Spanish and Fast engines
- Correct README and site copy for the built-in transcription engines
- **claude**: MacOS 14 floor from the project's deployment target; Foundation Models is an opt-in preview
- **store**: Drop the Foundation Models preview from public copy; align the macOS floor
- **setapp**: Current marketing version is 1.11.0
- **skills**: Release gotcha — global xcodebuild overrides leak to SwiftPM resource bundles


### Tests

- **core**: Guard the NOTICES.md, engine-router, and speaker-carry claims
- **embedded**: Add a gated live test for the language detector
- **core**: NOTICES guard checks repository names


### CI and build

- **embedded**: Add FluidAudio (Parakeet) pinned by revision with its text-normalisation binary disabled; tools 6.2, Swift 5 mode


### Maintenance

- **release**: 1.11.0 — credits for FluidAudio, NVIDIA Parakeet and BSC; What's New; bake-off results
- Cheap review minors (M7, M8, M10)

## [1.10.1] - 2026-09-06

### Features

- **pricing**: Set Distavo to $29 one-time and state it on every channel
- **menu**: Surface recordings that are permanently stuck failed


### Bug fixes

- **release**: Select the edition by scheme, not by a -xcconfig override
- **ui**: Stop blocking the main actor on getaddrinfo when warning about Local Network
- **network**: Don't re-resolve a host whose resolution just failed
- **pipeline**: Defer, don't fail, when the on-device summariser is only temporarily unavailable
- **summarise**: Keep the smaller text when a condense round stops shrinking
- **ci**: Never leave the Sparkle EdDSA private key on the runner disk
- **summarise**: Blame the context window, not the model, when no chunk can fit
- **release**: Close the gap that leaves the hosted Sparkle appcast stale
- **release**: Publish the appcast by atomic rename, not in-place overwrite
- **menu**: Seed "last note" from disk so the menu items work after a relaunch
- **transcribe**: Lead with "no internet" when a model download fails offline


### Documentation

- **distavo**: Refresh CLAUDE.md for v1.10.0 and append docs-pass note
- **marketing**: Add 2026-09-06 screenshot walkthrough + UI-health triage
- **handoff**: Record the 2026-09-06 screenshot walkthrough session
- **marketing**: Refresh the store screenshots from the 2026-09-06 walkthrough
- **skills**: Record the new deferral rule, the scheme trap, and edition-specific screenshots
- **release**: Add the 1.10.1 user-facing changes to What's New
- **handoff**: Record the 2026-09-06 review-fixes and 1.10.1 session


### Maintenance

- **release**: Bump version to 1.10.1 (build 13)

## [1.10.0] - 2026-09-05

### Features

- **menu**: Add Direct-edition "Send Feedback…" link
- **core**: Add embedded-summarisation seam, budgeting and chunk planner
- **summarise**: On-device summarisation via Apple Foundation Models


### Bug fixes

- **summarise**: Correct token budgeting that overflowed on a real recording


### Documentation

- **state**: Record 1.9.1 App Store submission
- **summarise**: Decide embedded summarisation engine (AFM over llama.cpp)
- **skills**: Record edition-gate proof and build gotchas in native-verify
- **release**: Prepare What's New for the next App Store version
- **handoff**: Session note for 2026-09-05
- **summarise**: Record field results from a real 97-minute meeting
- **handoff**: Add the real-recording field test and its findings
- **skills**: Correct the Forgejo/GitHub direction for this repo


### Maintenance

- **release**: Bump version to 1.10.0 (build 12) [skip version bump]

## [1.9.1] - 2026-08-11

### Features

- **site**: Link the live Mac App Store listing, drop stale in-review copy
- **skills**: Add distavo-native-verify + distavo-release (repo-local)


### Bug fixes

- **appstore**: Use neutral permission prompt actions


### Documentation

- **setapp**: Setapp submission review pack (checklist, blockers, runbook, listing draft)
- **marketing**: Draft LinkedIn launch post for App Store release
- **marketing**: Record LinkedIn post scheduled via Postiz for 2026-07-22


### Maintenance

- **setapp**: Add Setapp listing assets (icon + 4 styled screenshots)
- **release**: Bump version to 1.9.1 (build 11) [skip version bump]

## [1.9.0] - 2026-07-16

### Features

- **core**: Endpoint diagnosis for Test Connections (loopback-down ≠ failure)


### Bug fixes

- **settings**: Present no-server state as guidance, not failure (App Review 2.1a)


### Documentation

- **appstore**: Add 1.8.0 connection-reliability line to What's New [skip version bump]
- State live deployment URL in README
- **appstore**: Review notes + fresh-install verification for the 2.1(a) fix


### Maintenance

- **release**: Bump version to 1.9.0 (build 10) [skip version bump]
- **plist**: Declare NSBonjourServices for the Local Network prompt trigger

## [1.8.0] - 2026-07-08

### Features

- **settings**: In-app Permissions helper + LAN-failure guidance


### Bug fixes

- **network**: Detect LAN endpoints by DNS resolution, not just hostname


### Documentation

- **spec**: Permissions helper + LAN-resolution diagnosis design
- Manual verification checklist for permissions helper + LAN diagnosis


### Maintenance

- **release**: Bump version to 1.8.0 (build 9) [skip version bump]

## [1.7.0] - 2026-07-07

### Features

- **updates**: In-app 'Check for Updates' via Sparkle (Direct edition)
- **updates**: Set Sparkle SUPublicEDKey (Direct edition)


### CI and build

- Split editions into targets; link Sparkle into Direct only
- Sign+publish Sparkle appcast on release; verification + setup docs


### Maintenance

- **release**: Bump version to 1.7.0 (build 8) [skip version bump]

## [1.6.0] - 2026-07-07

### Features

- **core**: Pipeline stage-phase callback + Whisper language catalog
- **menu**: Five-state menu-bar icon (idle/recording/loading/transcribing/done)
- **settings**: Language dropdown replaces free-text field


### Documentation

- **specs**: Menu-bar state indicator, language picker, Direct Sparkle auto-update
- **metadata**: App Store What's New for 1.6.0 (icon states + language dropdown)


### Maintenance

- **release**: Bump version to 1.6.0 (build 7) [skip version bump]

## [1.5.0] - 2026-07-07

### Features

- **release**: Declare ITSAppUsesNonExemptEncryption=false
- **release**: Script the App Store review submission via the ASC API
- **ci**: Manual dispatch workflow to submit an App Store build for review
- **ci**: Gate App Review submission behind the app-store-submission environment
- **release**: Script the one-time App Store listing setup
- **release**: App Store desktop screenshots (menu + settings)
- **capture**: StereoBalancer — auto-balance mic vs system-audio loudness


### Bug fixes

- **release**: Only set What's New once a previous version has shipped
- **release**: Rename the existing editable version record instead of creating
- **release**: Guard against submitting a stale draft item; retry network errors
- **release**: Declare content rights and no demo account in listing setup
- **capture**: Record the mic from t=0 and auto-balance channel loudness


### Documentation

- **site**: Add og:image so shared links get a preview card


### Tests

- **capture**: Make the gain-cap test actually reach the cap


### CI and build

- Temporary push trigger to exercise submit-appstore pre-merge
- Staged live test — run to attach (no submission) on branch push
- Revert staged-test env to dry-run defaults (idempotence check run)
- Remove temporary push trigger — staged live test complete


### Maintenance

- Gitignore local AI-tooling artifacts
- **release**: Bump version to 1.5.0 (build 6)

## [1.4.0] - 2026-07-02

### Features

- **core**: Add embedded-transcription config backend, model catalog and hardware recommender
- **embedded**: Add DistavoEmbedded package — on-device WhisperKit+SpeakerKit engine
- **app**: Route transcription to built-in engine, hardware-fit settings UI, macOS 14 floor
- **capture**: Built-in meeting recorder — system audio + mic via Core Audio taps
- **site**: Add Distavo favicon (SVG + ico fallback), fixing the /favicon.ico 404


### Bug fixes

- **app**: Review follow-ups — modern onChange form, skip WhisperX probe in embedded mode
- **capture**: Drain IO queue before destroying HAL objects; handle output devices with input channels


### Documentation

- Add embedded transcription + meeting capture design spec
- MacOS 14 floor + App Review notes for runtime model download
- **site**: Advertise built-in recorder + on-device transcription, macOS 14 floor


### CI and build

- Stop CI and version-bump firing on GitHub mirror pushes


### Maintenance

- **release**: Bump version to 1.3.0 [skip version bump]
- **links**: Point donate checkout at the live Lemon Squeezy product
- **release**: Bump version to 1.4.0 [skip version bump]

## [1.2.0] - 2026-06-29

### Bug fixes

- **ci**: App Store archive — drop conflicting CODE_SIGN_IDENTITY pin
- **ci**: Upload App Store pkg via altool --apiKey (export then upload)
- **ci**: Stage ASC API key in ~/.appstoreconnect/private_keys before export
- **ci**: App Store — fully manual offline signing (certs + installed profile)
- **ci**: App Store signing — import installer cert + explicit-cert export
- **ci**: Move ExportOptions comment outside the heredoc
- **ci**: Unblock App Store package export
- **ci**: Embed App Store provisioning profile
- **ci**: Fail App Store release on ITMS-90889 missing-profile warning


### Documentation

- Add recording guidance to website


### CI and build

- Bump minor version after main merges


### Maintenance

- **release**: Bump version to 1.1.0
- Update website and Setapp packaging
- **release**: Bump version to 1.2.0 [skip version bump]

## [1.0.0] - 2026-06-29

### Features

- **support**: Add gated Lemon Squeezy donate link
- **macos**: Scaffold native Swift menu-bar app (Xcode/XcodeGen)
- **macos**: Port pipeline core to Swift (ScribedCore) with parity tests
- **support**: Set live Lemon Squeezy donate URL
- **macos**: Add WhisperX + Ollama clients to ScribedCore
- **macos**: AVFoundation AudioConverter + Pipeline orchestration
- **macos**: Wire real watcher loop, settings UI, notifications, login item
- **macos**: Gated live E2E harness + apple/ build README
- **macos**: App Store sandbox entitlements, bookmark folders, notarize script
- **macos**: Reliable settings window, onboarding, status badges, icon, help
- **macos**: Settings (?) help + install assist, clearer errors, auto-retry
- **macos**: Timestamped activity log + in-menu Activity view
- **macos**: Local Network permission — usage string, pre-warning, clear error
- **core**: Add testable GitHub new-issue URL builder
- **macos**: Add "Report an Issue…" menu item with diagnostics pre-fill
- **helper-program**: Design + buildable artifacts for feedback→credit loop


### Bug fixes

- **macos**: Isolate edition compilation flags so Setapp/App Store don't ship the donate link
- **macos**: Persist App Store folder access across launches
- **macos**: Exclude Terminal automation from the sandboxed App Store build
- **core**: Atomic config save + surface Ollama non-JSON responses
- Address PR review — ASCII URL encoding, canonical slug, CI all editions


### Refactoring

- [**breaking**] Rename product Scribed -> Seshat
- **macos**: Simplify menu/settings — dedupe interval label, drop dead code


### Documentation

- Add CLAUDE.md for future Claude Code sessions
- Trademark assessment + distribution/notarization checklist
- **claude.md**: Document the native apple/ app + build commands
- Finish Scribed→Seshat rename (changelog, trademark notes)
- **helper-program**: EspoCRM built — record C-prefixed entity names + status
- **helper-program**: N8n award→CRM wired (CFeedback event-log + credential)
- **helper-program**: Thank-you email live — full reward loop complete


### CI and build

- Install ffmpeg on the runner; skip ffmpeg-resolve test when absent
- Unattended release pipelines (Direct DMG + App Store) and Setapp guide


### Maintenance

- **macos**: Set LSApplicationCategoryType for App Store Connect
- Remove Python reference implementation; ship native app only
- **macos**: Bump marketing version to 1.0.0 for first store release
- Rename product Seshat → Distavo
- **helper-program**: Wire live deploy — distavo.com + n8n capture webhook

## [0.1.0] - 2026-06-24

### Documentation

- Add settings-page screenshot to README



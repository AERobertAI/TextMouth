# Where things stood, earlier campaigns

Part of [working on TextMouth with coding agents](../../AGENTS.md).

The status sections AGENTS.md carried at the end of earlier campaigns, newest first. AGENTS.md keeps only the latest.

## Where things stood on October 13, 2026

Main holds the record of the REV16 fixes, then, from the evening:
- the Ogg and Nothing Imported fix (9528b7a5, suite 6124 tests, 64 skipped, 0 failures, no Swift warnings), done by the orchestrator directly: a ZIP of Ogg tracks imports as one audiobook, and a ZIP import that brings nothing in says so in the library's alert;
- the documentation reorganized into docs/ (this file's older status sections are in `docs/agents/history.md`), with the audiobook manifest's full reference at `docs/user/audiobook-manifest.md`;
- FR15, FR16, and FR17 in the TODO, with the user's answers from `humanQuestions/2026-10-13.md`.
- the REV16 fixes' documentation pass (100db7a5).

- FR15, the manifest's tracks list, group headings, and pauses between tracks (e2ab40d9, October 14, suite 6192 tests, 64 skipped, 0 failures), by agent `manifesttracks`, with its documentation.

- FR17, Edit Manifest, the title and author kept in the manifest, the audio editor's fix, and Import Folder… (5d9caee3, October 14, suite 6221 tests, 67 skipped, 0 failures), by agent `editmanifest`, with its documentation.

- FR18, a manifest edited outside TextMouth taken as Edit Manifest takes a save, with a one-time pass keeping earlier hand edits (1744021a, October 14, suite 6230 tests, 67 skipped, 0 failures), by agent `outsideedits`, with its documentation.

- B07, the playback watchdog, memory guard, and sound effects off the main thread (d7f4f527, suite 6259 tests, 67 skipped, 0 failures), by agent `playbackwatch`; and B06, Ogg audio converted to AAC at import and once for the library (70a74208, suite 6284 tests, 64 skipped, 0 failures), by agent `oggtoaac`, after Apple's Vorbis decoder locked up in AVPlayer on October 14 and took the Mac down (see the TODO's B06 and B07). Never play Ogg through Apple's players in any test or experiment.

B08, rendered speech's crash when the audio output stops cycling, was fixed the same evening (32dc2036, suite 6293 tests, 67 skipped, 0 failures) by a Sonnet agent the orchestrator reviewed. No agent is in flight.

**Pending:**
- the user's answers in `humanQuestions/2026-10-12.md` (13 small choices);
- the user's push and install. Main is far ahead of origin/main, and agents' worktrees start at origin/main.

The weekly window stood at 20% left; the user's floor is about 10%.

## Where things stood on October 7, 2026 (evening)

Main at the docs merge b165940c and its record, suite 4857 tests, 54 skipped, 0 failures, no Swift warnings (after the text-field keys merge; the documentation passes ran no suite). The orchestrator ran on Opus 5.5 and every agent on Opus. Merged that evening, each recorded in the TODO with its agent's notes in `AGENT-NOTES-2026-10-04.md` under "Agent notes, October 7, 2026 (evening)": the afternoon's documentation pass (5d6227cb), a feed's counts and its folder's row (9ae7becc), the reading list (01197eb1) and reading a book from it (9a61278d; FR09 done), four follow-ups (cb134bb1: #1290, #1291, #1308, #1296), the speech refusal follow-ups (6b78bd4c), ZIP import progress (f2b39d7f; FR10's first half), the keys a focused text field keeps (5b137a63; B03), the evening's documentation pass (b165940c), and two design notes, `FEED-ITEMS-RESEARCH-2026-10-07.md` (FR11) and `KEYBOARD-SHORTCUTS-RESEARCH-2026-10-07.md` (FR12). Two read-only reviewers read every line of the afternoon's five merges first; the TODO's REV07 entry lists each finding and where it went. Pending: the user's answers to the ten questions ending each design note (all recommended yes), then FR11's and FR12's builds in the branches the notes plan; the queued briefs `editbaselines.md` and `finishedbook.md` in `Scripts/agents/briefs/2026-10-07/`; an unbriefed bundle of REV07's Speak Info items and cleanups; B04 (the user's Shift-Command-B on two actions; a config.json workaround awaits the user's yes) and the Shift-Command-T clash (#1451); FR10's feed-download half after FR11's second branch. The merge chain's one red run that evening was a test host that received an ordinary quit while it was the frontmost app (no crash); xcodebuild restarted the rest and the interrupted class passed alone, which is how such a run is settled. The installed app was still the October 5 build until the user pushes and installs.

**Later that night.** The user answered every question in `humanQuestions/2026-10-07-evening.md`, and a second batch merged: the editor save baselines (afde34e4), a finished book's controls (377edc97; its merge chain's suite failed four tests under another suite's load, each passing alone or on a quiet Mac), and FR12's branch A, the record of the shortcuts the user edited (094dd885, which ends B04); main's suite counts 4943 tests, 70 skipped, 0 failures. FR11's design addendum (`FEED-ITEMS-ADDENDUM-2026-10-07.md`, 7c78d8af) measured and recommends the user's layout, a package per feed item in a folder of the feed's own with the feed's own index; its six questions wait in `humanQuestions/2026-10-07-late.md`. Work stopped there at 30 percent of the weekly all-models window left, the user's line. Next: those answers, then FR11's five branches; FR12's branches B, C, D, and E; B05; a documentation pass for the second batch (the wording is in the agent notes); the `FeedUIAddFeedTests` stray-save leak; FR10's feed half after FR11's choice branch.

## Where things stood on October 7, 2026

Main at 1059a8ed, suite 4687 tests, 56 skipped, 0 failures. Merged that day: the EPUB author reading and the versioned metadata refresh (3d52c08b), the Unopened category (1790ae21), hand-edited metadata flags (065ec6a0), the speech markup guard (aec5c91b), the AirPods rewind after a finished book (f5273ba2), and Speak Info (33219144), each recorded in the TODO with its FR or B entry ticked. Pending for the next session: the documentation pass for those five afternoon branches (every README and ARCHITECTURE sentence is in `AGENT-NOTES-2026-10-04.md` under "Agent notes, October 7, 2026"); the reading list, FR09, from `Scripts/agents/briefs/2026-10-07/readinglist-core.md` and then a reader branch; the FR03 follow-ups and FR10 in the TODO's October 7 section; the small follow-ups #1290 (ReaderView passes `handEdits:`), #1291 (an import sets `.noneSinceImport`), #1308 (the reader takes `onSpeechRefused`). The usage stop of October 7: the weekly Fable window reached 10% because the task agents ran on Fable; the rule above fixes that. The installed app was still the October 5 build (fe84085b) until the user pushed and installed.

## Where things stood on October 4, 2026

Main held, all with green suites: the cloud data directory (FR02), the performance work (PERF01 to PERF33), Swift 6, the smaller app and its size guard, recording and the audio editor (FR04), transcription with its cleanup command (FR05), the feed reader (FR03), Export and Edit Text, and the AirPods fix. The evening's four polish branches are on main too, each merged after a green suite on the merged tree: `fix/reader-polish-october-4` (6308e97b), `fix/audio-editor-polish` (5a9176df), and the two that were in flight when the weekly budget ran out, `feature/feed-search-and-polish` (eeb8a0b5: podcast search, JSON Feed, resume data at quit, video re-import, failures reported, Stats by kind) and `feature/recording-polish-and-mp3` (b5a6dd75: recovered takes, quit asks, readers pause, exported originals, LAME MP3 as a vendored C target), after which the suite on main counted 4535 tests, 50 skipped, 0 failures. No feature branch is in flight; `docs/october-4-wave-4` describes the four in README.md and ARCHITECTURE.md. The user's open decisions: P07 (the end-of-book position), P08 (the audiobook jump time convention), and merging what two Macs wrote.

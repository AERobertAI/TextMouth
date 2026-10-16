# Task pauses-and-cloud: no pause is one value, and Edit Manifest's check never reads a track that is only in the cloud

Worker slug `importsafe-checks`, branch `importsafe/checks` (from `team/importsafe`), lead `importsafe-lead`. Read "The worker's part", "Rules for everyone", "The board", and "Builds" of `Scripts/agents/briefs/2026-10-16/teams-common.md`; read nothing else beyond what this brief names. The usage rule is overridden tonight (see your launch prompt).

This task closes findings 4 and 5 of REV17b, in two commits. Both are small; each ends with the proof that its test fails without the fix.

## Finding 4: TextMouth's own manifest is taken for an edit (low)

`ChapterPauses` (`TextMouth/Models/ChapterPauses.swift`, 37 lines) stores `seconds: [TimeInterval]` and is a plain `Equatable` struct. `ChapterPauses.none` is `ChapterPauses(afterEachChapter: [])`, but `ChapterPauses.betweenTracks(of:inAudioFolder:)` (`TextMouth/Parsers/AudioManifest.swift`, the extension near line 295) returns an all-zero list of one entry per chapter as soon as any manifest exists (the last entry is 0 too), so `none != betweenTracks(...)` for a book whose manifest gives no pause (REV17b compiled the real struct: `equal: false`). Two places compare them:
- `BookManifestEditSessions.manifest(_:at:arranges:as:tracks:showingPauses:)` in `TextMouth/Services/BookManifestEditing.swift`, its last test, `if let pauses, pauses != ChapterPauses.betweenTracks(of: shown, inAudioFolder: book.bookFileURL) { return false }`;
- `ReaderViewModel.showRearrangedTracks` in `TextMouth/ViewModels/ReaderViewModel+ManifestEdit.swift:36`, `|| chapterPauses != edit.pauses`.

An open reader of a book that had NO manifest when it loaded keeps `.none` (`ReaderViewModel.swift:302`, `:1427`). When Edit Manifest then writes the book its generated manifest (`BookManifestFile.generated(for:names:)`, `pauseBetweenTracksMs: 0`, "opening it for editing must not change that"), the next look with `showingPauses: .none` finds `none != [0, 0, …]`, takes the unchanged manifest as an edit, rebuilds the reader, and VoiceOver says "Manifest updated" for a book that did not change.

Fix, in ONE place, `ChapterPauses` itself (neither comparison changes): `init(afterEachChapter:)` drops trailing zero entries after it cleans the values, so every list that gives the same pause after every chapter is the same value, and "no pause anywhere" is `[]`, equal to `.none`. Update the type's and `none`'s doc comments to say two values are equal when they give the same pause after every chapter. `after(chapter:)` is unchanged (a chapter past the list has none).

Tests:
- In `TextMouthProductionTests/AudioManifestTests.swift`, beside `testAChaptersPauseIsNeverBelowZero` (:398-404), `testNoPauseAnywhereIsOneValueWhateverItsSource`: `ChapterPauses.none == ChapterPauses(afterEachChapter: [0, 0, 0])`; `[-1, .nan, .infinity] == .none`; `[0.5, 0] == [0.5]`; `[0, 0.5] != [0.5]`; `[0.5] != .none`; and `after(chapter:)` is unchanged for them.
- In `TextMouthProductionTests/BookManifestEditTests.swift`, in the section `// MARK: - Edits Made Outside a Session (FR18, Item 1)`, right after `testAManifestThatMatchesItsBookTakesNothingAndWritesNothing` (that test passes `betweenTracks`' own result as the reader's pauses, which hides the bug): `testTextMouthsGeneratedManifestIsNotTakenForAnEditByAReaderThatShowsNoPauses`: a book of silent tracks WITHOUT a manifest (`makeSilentAudioBook`), whose reader shows `ChapterPauses.none` (assert `ChapterPauses.betweenTracks` is `.none` before the manifest exists); write the generated manifest as Edit Manifest does (`BookManifestFile.write(BookManifestFile.generated(for:names:), at: AudioManifestLocation.forNewManifest(in:), of:, sessions: BookManifestEditSessions())`, as :987-992 does); then `editor.sessions.look(at: book, showingPauses: .none)` is `.unchanged`, and the record and the manifest are byte-identical afterwards (as :997-1007 checks). It must fail without the fix; write it first, run it, keep that run's result line for your report.

## Finding 5: Edit Manifest's check downloads every track of a book in the cloud (low)

`BookManifestEditSessions.look(at:…)` (static) refuses to take when a track is only in the cloud: after the manifest comparison it does `guard !read.tracks.contains(where: { isDataless(folder.appendingPathComponent($0)) }) else { return .inCloud }` with the comment "The take reads every track, so it waits until all are on this Mac". The session's check, the static `check(_:against:owed:hasher:isDataless:)` (the function its instance `check(_:)` and `scheduleCheck` call; it gained `owed:` in the integrated owed-fields task), has no such guard: after the folder and manifest tests it goes on to `take(_:manifestAt:digest:owed:)`, which calls `BookContentAnalysisService.analyzeAudio(book:url:)` and reads (probes) every track. Its own doc comment says "one only in the cloud is left alone, and nothing is downloaded". So saving a manifest edit of a cloud book whose tracks are evicted downloads all of them unasked (FR02 forbids that).

Fix:
1. One private static helper in `BookManifestEditing.swift`, with a doc comment, used by BOTH `look` and `check` (DRY): `hasTrackOnlyInCloud(_ tracks: [String], in folder: URL, isDataless: (URL) -> Bool) -> Bool`. `look`'s inline `contains(where:)` becomes a call to it.
2. In the static `check`, right before `let found = take(...)` (a take is about to read the tracks), list the tracks as `look` does, with downloading off: `try DatalessFiles.withoutDownloading { try AudioBookParser.trackPaths(in: folder) }`. A download refusal (`DatalessFiles.isDownloadRefusal`) or a track `hasTrackOnlyInCloud` returns `(.inCloud, nil)`: nothing is taken, the baseline stays, so the next check tries again once the tracks are back. Any other listing error is left to the take, which refuses it in the import's words. `BookManifestEditor.handle` ignores `.inCloud` (no announcement), as it should.
3. Update `check`'s doc comment (the bullet list above it) with the new rule. Do not wrap `take` itself in `withoutDownloading`: a refusal inside it would surface as a "not taken" message instead of `.inCloud`; report it as a follow-up if you think it needed.

Tests, in `BookManifestEditTests.swift`, right after `testAManifestOnlyInTheCloudIsNotLookedAt` (that test shows the `isDataless:` closure style):
- `testASavedManifestWaitsWhileATrackIsOnlyInTheCloud`: a book of three silent tracks; baseline `FileFingerprint(of: manifestURL, hasher: .md5)` of its manifest (write one first with `save(_:to:)`); the user saves a reordered manifest; `BookManifestEditSessions.check(book, against: baseline, isDataless: { $0.lastPathComponent == "02.wav" })` is `(.inCloud, nil)` and the stored index (`book.storedBookInfo()?.contentIndex?.chapters.map(\.audioFilePath)`) is unchanged; positive control: the same call with `isDataless: { _ in false }` finds `.adopted` with the new order. It must fail without the fix (without it, the first call adopts): write it first, run it, keep that run's result line for your report.
- `testAFolderInsideTheAudioFolderOnlyInTheCloudAlsoWaits` if the track listing can be refused by a cloud subfolder in the test (use the closure to say a track's folder is dataless); otherwise say in your report why not.

Run: `-only-testing:TextMouthProductionTests/BookManifestEditTests -only-testing:TextMouthProductionTests/AudioManifestTests -only-testing:TextMouthProductionTests/ReaderChapterPauseTests -only-testing:TextMouthProductionTests/SpeechPreparationPauseAndSymbolTests`.

## Commits (each ends with the Co-Authored-By line)
1. "Treat no pause anywhere as one value, so TextMouth's own manifest is not taken for an edit" (finding 4).
2. "Leave a manifest edit alone while a track is only in the cloud" (finding 5).

## Not to touch
`AudioManifest.swift` (team fixes works there; finding 4 needs no change in it), `ReaderViewModel+ManifestEdit.swift`, `ReaderViewModel.swift`, `LibraryViewModel+ManifestEdits.swift`, `FileImportService.swift`, `Book.swift`. In `BookManifestEditing.swift` change only `look`'s inline cloud-track test, the static `check`, and the new helper: the owed-fields work (`ManifestOwedFields`, `settleOwedFields`, `owed:` parameters) is already integrated on your branch's base; leave it as it is. Every `*.md` file.

## Report
At most 15 lines, as the pattern says, plus the two failing-run result lines (each test before its fix).

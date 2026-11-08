# speechexport/job: the speech export job (FMT43, step 4b)

Slug `speechexport-job`; branch `speechexport/job`, made with `git checkout -b speechexport/job team/speechexport`. Team `speechexport`, lead `speechexport-lead`. Follow "The worker's part" of `Scripts/agents/briefs/2026-10-30/teams-common.md`, and the build section at the end of this brief, which overrides its build-folder rules.

## Goal

Join the parts the team branch now holds into the job that exports a text book, or a range of its headings, as one spoken audio file: read the text as the reader speaks it (`SpeechExportText`), refuse what cannot be done before starting (`SpeechExportError`: a Personal Voice, no voice, too little disk, another export running), keep the Mac awake (`SpeechExportPower`), speak each chapter into a file of its own (`SpeechChapterRenderer`), keeping the finished ones so a stopped export goes on from its next chapter (`SpeechExportStore`), then encode them into one M4B, M4A, or MP3 with a chapter per heading (`SpeechExportEncoder`), reporting progress all along. The Export dialog calls it in later tasks (`service`, `dialog`).

## Read first (only these)

The team branch's `TextMouth/Services/SpeechExport/` files, whole (they are new and short): `SpeechExportText.swift`, `SpeechBufferSynthesizer.swift`, `SpeechChapterRenderer.swift`, `SpeechExportEncoder.swift`, `SpeechExportVoice.swift`, `SpeechExportError.swift`, `SpeechExportStore.swift`, `SpeechExportSpace.swift`, `SpeechExportPower.swift`; and `TextMouthProductionTests/FakeSpeechBufferSynthesizer.swift`. Then `TextMouth/Services/BookExportService.swift` 175-200 (`BookExportCancellation`) and the `readingContent(fromMarkdown:at:title:)` function; `TextMouth/Services/DiagnosticLog.swift` 60-90 (categories); `TextMouthProductionTests/LogContentPolicyTests.swift` 205-222 and 265-390 (what a log line may hold, and the event tag registry).

## What to make: `TextMouth/Services/SpeechExport/SpeechExportJob.swift` (new)

1. `struct SpeechExportRequest: Equatable, Sendable`, everything one export reads, made on the main actor by the dialog:
   `var bookID: UUID`, `var bookTitle: String` (names the chapter of the text before the first heading), `var fileTitle: String` (the exported file's name, without its extension), `var titleTag: String` (the file's title tag), `var author: String?` (its artist tag), `var format: SpeechExportFormat`, `var range: SpeechExportRange`, `var voice: SpeechExportVoiceSettings` (its speed and pitch are the dialog's sliders), `var skippedHeadingIDs: Set<String>`, `var preparation: SpeechPreparationSettings`.
2. `enum SpeechExportProgress: Equatable, Sendable`: `case speaking(done: Int, total: Int, fraction: Double)` (`done` chapters finished of `total`, kept ones included; `fraction` of the whole export's speech, 0...1) and `case encoding(chapters: Int, fraction: Double)`.
3. `struct SpeechExportEnvironment: Sendable`: `var synthesizer: any SpeechBufferSynthesizing`, `var voiceInfo: @Sendable (String) -> SpeechExportVoiceInfo?`, `var power: SpeechExportPower`, `var freeSpace: @Sendable (URL) -> Int64?`, `var sameVolume: @Sendable (URL, URL) -> Bool`, `var storeRoot: URL`; `static var live`: `SystemSpeechBufferSynthesizer()`, `SpeechExportVoiceInfo.installed`, `.live`, `ArchiveLimits.volumeFreeSpace(at:)`, `ImportScratchSpace.areOnSameVolume`, `SpeechExportStore.liveRoot`.
4. `struct SpeechExportContext: Sendable { var environment: SpeechExportEnvironment; var progress: @Sendable (SpeechExportProgress) -> Void }` with `static var live` (the live environment, progress going nowhere): what the Export job runner hands a speech export.
5. `enum SpeechExportJob` with `static let chapterGap: TimeInterval = 0.5` (silence closing every chapter but the last), `static let progressInterval: TimeInterval = 0.25`, and
   `static func run(_ request: SpeechExportRequest, markdown: Data, source: URL, to destination: URL, context: SpeechExportContext, cancellation: BookExportCancellation) throws`
   which does, in order:
   1. `SpeechExportStore.claim()`, or throw `SpeechExportError.busy`; released however the job ends.
   2. `BookExportService.readingContent(fromMarkdown: markdown, at: source, title: request.bookTitle)`.
   3. `SpeechExportText.sections(...)` with the request's range, skipped headings, preparation, and book title; `.headingNotFound` becomes `SpeechExportError.headingsChanged`; no section throws `.nothingToSpeak`.
   4. The voice: no identifier, or `environment.voiceInfo` finding none, throws `.noVoice`; a Personal Voice throws `.personalVoice(name:)` with its name. Nothing has been spoken or held yet.
   5. The store: `SpeechExportStore(root: environment.storeRoot, key: SpeechExportStore.key(bookID:voiceIdentifier:wordsPerMinute:pitch:sections:))`, each section given as `[title] + texts`; `kept = min(try store.open(), sections.count)`. (The format is not in the key: changing only the format still goes on from the kept chapters.)
   6. The disk: `SpeechExportSpace.check(speechSeconds:fileSeconds:speechFolder:fileFolder:freeSpace:sameVolume:)` with the seconds of the chapters still to speak and of all of them (`SpeechExportSpace.seconds(wordCount:wordsPerMinute:)` over their word counts at the request's speed), `store.root`, and `destination`'s folder.
   7. Everything below runs inside `environment.power.whileHeld(reason: "TextMouth is exporting a book as spoken audio")`.
   8. Progress: first `.speaking(done: kept, total: n, fraction: <the kept chapters' share>)`. A chapter's share of `fraction` is its `utf16Length` over all chapters'; while one is spoken, its part is its share times `min(0.99, framesWritten / estimatedFrames)`, with `estimatedFrames` its seconds (as above) times the rate of 22,050 frames a second. Report at most once every `progressInterval` seconds (a lock-protected time of the last report; the renderer's callback comes for every buffer, tens a second), and always when a chapter ends (`done` + 1).
   9. Chapters `kept..<n`: `SpeechChapterRenderer.render(title:texts:voiceIdentifier:wordsPerMinute:pitch:trailingSilence:to:synthesizer:cancellation:framesWritten:)` into `store.partURL(i)`, with `chapterGap` after every chapter but the last; then `store.finishChapter(i)`. A Stop (`CancellationError`) or failure leaves the chapters finished so far kept.
   10. `.encoding(chapters: n, fraction: 0)`, then `SpeechExportEncoder.encode` of every chapter (`SpeechExportChapterFile(name: store.chapterName(i), title: sections[i].title)`) in `store.folder`, in the request's format, with `AudioRenderMetadata(title: request.titleTag, author: request.author)`, to `destination`, its progress reported as `.encoding` (throttled as above, and once at 1 when it ends).
   11. Only after a finished encode: `store.removeAll()`.
   12. However it ends (finished, stopped, or failed), one event line: `DiagnosticLog.event(.storage, "SPEECH_EXPORT: <finished|stopped|failed> after <k> of <n> chapters (<kept> kept from an earlier export) in <s> s")`, counts and seconds only (never a title, text, voice, or path), and no line for a refusal before step 5 other than this one with 0 chapters. Add `"SPEECH_EXPORT"` to `LogContentPolicyTests.eventTags` with a one-line comment in the style of its neighbours (that is the only change to that test file).
6. Errors pass through as they are: `SpeechExportError`, `SpeechRenderFailure`, `AudioEditError`, `CancellationError`, and the file system's.

Comment every type, property, and function, and each non-obvious block. Avoid `@unchecked Sendable` and `nonisolated(unsafe)`.

## Tests: `TextMouthProductionTests/SpeechExportJobTests.swift` (new)

Use `FakeSpeechBufferSynthesizer`, a fake `voiceInfo` (a voice "Test Voice", not personal), a fake `SpeechExportPower` that records holds and releases, free space of 100 GB, `sameVolume` true, and a sandbox `storeRoot` and destination folder (`makeSandboxDirectory`). The book is Markdown bytes in the test (content.md's form: `<!-- chapter: Title -->` markers and `#` headings, as `BookExportConvertToTests.twoChapters`), with text before its first heading, three or four headings over two chapters, and a level-2 heading; `source` is any sandbox URL. Pin at least:

1. A whole-book export makes an M4B whose chapters (`AudioPlaybackService.extractChapters(from:)`) are the book's title then each heading, in order; progress starts with `.speaking(done: 0, ...)`, reaches every `done`, never lowers `fraction`, and ends with `.encoding(... fraction: 1)`; the power is held once and released once; the store's root is gone afterwards.
2. Stop (the fake's `beforeWrite` cancelling the token at the third chapter's text) throws `CancellationError`, leaves nothing at the destination, keeps two chapter files, and releases the power. Running the same request again with a new token speaks only the chapters after the kept ones (the fake's record), and makes the whole file with every chapter.
3. The same range at another pitch, after a stop, speaks every chapter again, and the old kept chapters are gone. Another format only (MP3) goes on from the kept chapters.
4. A Personal Voice throws `.personalVoice(name: "Test Personal")`; no voice throws `.noVoice`; in both, nothing is spoken and the power is never held.
5. Too little space (free space just under the need plus the reserve) throws `.notEnoughSpace`, speaking nothing.
6. While `SpeechExportStore.claim()` is held by the test, a run throws `.busy` (release it in a `defer`).
7. A reversed range throws `.nothingToSpeak`; an unknown heading ID throws `.headingsChanged`.
8. A chapter whose text the fake refuses (both guards) throws `.refused(<its title>)`, the chapters before it kept.
9. An M4A and an MP3 export have the same chapters.

## Run

`SpeechExportJobTests LogContentPolicyTests UncheckedConcurrencyPolicyTests export speech`. Report the exact `Executed N tests, with S tests skipped and F failures` line.

## Do not

- Change the files the other tasks made, except to fix a bug you find, which you report to `speechexport-lead` before fixing (`--file <path>`).
- Use a real synthesizer in a test, touch Personal Voice, or play a sound.
- Read or write anything under `~/.TextMouth`. Edit any `*.md` file, or any file not named here.

## Build and test (this team's rules; they override teams-common.md's build folder rules)

- The team shares ONE build folder, used by one teammate at a time: `/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-speechexport`. Never make another and never delete it: the lead deletes it at the end.
- Disk: before each build, `df -g /System/Volumes/Data` must show at least 2 GB available when that folder exists, 5 GB when it does not. Otherwise post to `speechexport-lead` and wait (`python3 .claude/skills/agent-bbs/scripts/bbs.py watch <slug> --timeout 600`), then check again.
- Build in the background, through the team's lock, which queues you behind a teammate's build (waiting is normal):
  `BBS_AGENT=<slug> /usr/bin/lockf -k /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-speechexport-build.lock python3 Scripts/test/run-area.py --derived-data /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-speechexport --log <your scratchpad>/<slug>-run.log <names>`
  Check on it no more often than every 4 minutes, with one short command.
- New files need `/opt/homebrew/bin/xcodegen generate`; commit the regenerated `TextMouth.xcodeproj/project.pbxproj` with them.
- Before reporting, `make lint-tests LINT_BASE=team/speechexport` must be clean, and the build must add no Swift warning.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

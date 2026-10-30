# speechexport/dialog: spoken audio in the Export dialog (FMT43, step 6b)

Slug `speechexport-dialog`; branch `speechexport/dialog`, made with `git checkout -b speechexport/dialog team/speechexport`. Team `speechexport`, lead `speechexport-lead`. Follow "The worker's part" of `Scripts/agents/briefs/2026-10-30/teams-common.md`, and the build section at the end of this brief, which overrides its build-folder rules.

## Goal

The last step of FMT43: the Export dialog's model and sheet take the "Text as spoken audio" kind the job runner now offers for one text book. While it is checked, its options (`SpeechExportOptionsView`) show under it; Export makes the `.speech` conversion from them and runs it; the progress bar and its words say which chapter is being spoken, then that the file is being encoded; Stop keeps the chapters spoken so far, and the words at the end say so. The user is blind and uses VoiceOver and a braille display: VoiceOver hears the progress as it hears the other kinds' (the progress bar's label), and the end once, in the dialog's one announcement.

## Read first

- `TextMouth/ViewModels/BookExportModel.swift` (all, about 530 lines) and `TextMouth/Views/Export/BookExportSheet.swift` (all, 217 lines).
- `TextMouth/ViewModels/SpeechExportOptionsState.swift`, `TextMouth/Views/Export/SpeechExportOptionsView.swift`, `TextMouth/Models/SpeechExportWording.swift`: the options, made by the `options` task.
- `TextMouth/Services/SpeechExport/SpeechExportJob.swift` (request, progress, environment, context), `SpeechExportVoice.swift`, `SpeechExportText.swift` (`SpeechPreparationSettings.current`).
- `TextMouth/Services/BookExportService.swift`: `BookExportConversion` (its `.speech` case), `readingContent(fromMarkdown:at:title:)`, and `export(...)`'s `speech:` parameter.
- `TextMouth/Models/BookExportWording.swift` 160-200 and 225-260 (`stopHint`, `progress`, `finished`).
- `TextMouthProductionTests/BookExportConvertToTests.swift` 500-669 and `SpeechExportServiceTests.swift`: how the dialog is tested, and how a speech export is faked.

## What to make

### 1. `TextMouth/ViewModels/BookExportModel.swift`

1. New `init` parameters, last, with defaults: `speechEnvironment: SpeechExportEnvironment = .live`, `speechDefaults: UserDefaults = .standard` (the global voice, speed, pitch, and pause level), `substitutionService: TextSubstitutionService = .shared`. Keep them in private lets.
2. `@Published private(set) var speechOptions: SpeechExportOptionsState?`: made by `load()` once the choices hold an available `.spokenAudio` (there is one book): off the main thread, its content.md read through `access.read` and `BookExportService.readingContent(fromMarkdown:at:title:)` for `content.allHeadings`; on the main actor, `SpeechExportVoiceSettings.of(book, defaults: speechDefaults, isInstalled: { speechEnvironment.voiceInfo($0) != nil })`, its voice's `speechEnvironment.voiceInfo`, and `SpeechExportOptionsState(headings:skippedHeadingIDs:voice:settings:)` with `Set(book.skippedHeadingIDs ?? [])`. When the text cannot be read, there are no options and the `.spokenAudio` choice is taken out of `choices`. All this before `phase` becomes `.ready`.
3. `optionsView(for: .spokenAudio)`: `AnyView(SpeechExportOptionsView(state:))` while the kind is checked and the options exist; nil otherwise. Every other kind is as before.
4. `conversions`: also `.spokenAudio: .speech(request)` while it is checked and the options exist, the request made on the main actor from the library's copy of the book (`currentBooks(books).first`): `bookID`, `bookTitle`, `fileTitle: options.fileTitle(bookTitle:)`, `titleTag` (the book's title for the whole book, else `fileTitle`), `author: ExportBookDetails(book).author`, the options' format and range, `voice: SpeechExportVoiceSettings(voiceIdentifier: options.voice?.identifier, wordsPerMinute: <the Rate slider>, pitch: <the Pitch slider>)`, `skippedHeadingIDs`, and `preparation: SpeechPreparationSettings.current(substitutions: substitutionService, defaults: speechDefaults)`.
5. Progress: `@Published private(set) var speechProgress: SpeechExportProgress?`. `export(announcingFrom:)` passes `BookExportService.export(..., speech: SpeechExportContext(environment: speechEnvironment, progress: ...))`, whose progress closure records each value synchronously in a small `Sendable` record (a final class over an `OSAllocatedUnfairLock<SpeechExportProgress?>`, private to this file), then shows it on the main actor (`Task { @MainActor in ... }`, ignored once the export has ended, as `showProgress` does). `speechProgress` is nil before and after an export.
6. `progressText`: while exporting with a `speechProgress`, `SpeechExportWording.progress(_:)`; otherwise as before. New `var progressFraction: Double?`: the speech's `fraction` while it has one; else `done / total` while exporting with a total; else nil.
7. The end: once the export returns, the recorded last progress decides one more sentence after `BookExportWording.finished(...)`, in the summary and in the one announcement: when the outcome was stopped or met a failure, and the last progress was `.speaking(done: k, total: n, _)` with `k > 0`, or `.encoding(chapters: n, fraction:)` below 1 (all `n` kept), `SpeechExportWording.kept(done:total:)`. Nothing else in the end changes.
8. `var isExportingSpeech: Bool`: exporting, with `.spokenAudio` among the kinds this export took.

### 2. `TextMouth/Views/Export/BookExportSheet.swift`

1. The progress bar: `ProgressView(value: fraction, total: 1)` labelled with `progressText` while `progressFraction` has a value, the indeterminate one otherwise, `.accessibilityLabel` as before. Replace the `done`/`total` reading in `progressBar(_:)` with `progressFraction`, so the two kinds of progress take one path.
2. Stop's hint: `SpeechExportWording.stopHint` while `isExportingSpeech`, else `BookExportWording.stopHint`.
3. Update the type's doc comment: the spoken audio options under their checkbox.

### 3. `TextMouth/Models/SpeechExportWording.swift`: add

- `func progress(_ progress: SpeechExportProgress) -> String`: "Speaking chapter \(min(done + 1, total)) of \(total)…" and "Encoding the audio file…".
- `func kept(done: Int, total: Int) -> String?`: nil for 0; "Kept \(done) of \(total) chapters: export the same range at the same rate and pitch to go on from chapter \(done + 1)."; all of one: "Kept the spoken chapter: export the same range at the same rate and pitch to make the audio file from it."; all of several: "Kept all \(total) spoken chapters: export the same range at the same rate and pitch to make the audio file from them."
- `stopHint`: "Stops the export. The chapters already spoken are kept, so exporting the same range again goes on from there."

Comment every new property and function, and each non-obvious block.

## Tests: `TextMouthProductionTests/SpeechExportDialogTests.swift` (new, `@MainActor`)

The book comes from an integration world with headings (as `SpeechExportServiceTests`); the model gets a sandbox destination, `FakeSpeechBufferSynthesizer`, a fake voice that the book's `localVoiceID` names, a fake power, 100 GB free, a sandbox store root, sandboxed preferences (`makeSandboxedPreferences`), and `TextSubstitutionService(rules:)`; announcements are captured (`AnnouncementCapture`). Pin at least:
1. One text book: "Text as spoken audio" is listed after "Text as plain text", unchecked; its options start at the book's own speed and pitch (give the book `localWPM` 300 and `localPitch` 1.2) with its headings; `optionsView(for: .spokenAudio)` is nil until it is checked. Two books: no such checkbox and no options.
2. `conversions[.spokenAudio]` is `.speech` of exactly the request item 4 describes, after the sliders, the format, and the range are changed in the options.
3. Export with only it checked writes "<stem> - Audio.m4b" with a chapter per heading, announces "Exported 1 item to <folder>.", and closes (`didEverything`). While it speaks, `progressText` is "Speaking chapter 1 of <n>…" and `progressFraction` is between 0 and 1 (hold the fake in `beforeWrite` on a semaphore, with a timeout, until the test has looked).
4. Stop during the third chapter: the summary and the announcement end with "Kept 2 of <n> chapters: export the same range at the same rate and pitch to go on from chapter 3."; a second export speaks only the rest (the fake's record) and writes the file.
5. A Personal Voice: the summary names the file with `SpeechExportError.personalVoice`'s sentence; no kept sentence.
6. Drawn (`withHostedView`): checking the kind draws the options' three pop-ups and two sliders under it; unchecking takes them away; while an export runs they are disabled, with Stop's hint `SpeechExportWording.stopHint`.
7. The sheet with the options shown and a heading of 300 characters is no wider than 560 points and no taller than 700 (`NSHostingView(rootView:).fittingSize`).
8. The new words, exactly.

## Run

`SpeechExportDialogTests SpeechExportOptionsTests SpeechExportServiceTests BookExportSheetTests BookExportConvertToTests export sheets`, and `make lint-a11y LINT_BASE=team/speechexport` (clean; say so). Report the exact `Executed N tests, with S tests skipped and F failures` line.

## Do not

- Change the job runner, the job, or the options beyond what is named here; change no existing test.
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

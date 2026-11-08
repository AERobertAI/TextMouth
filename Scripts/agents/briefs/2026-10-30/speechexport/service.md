# speechexport/service: spoken audio as a kind of the Export job runner (FMT43, step 6a)

Slug `speechexport-service`; branch `speechexport/service`, made with `git checkout -b speechexport/service team/speechexport`. Team `speechexport`, lead `speechexport-lead`. Follow "The worker's part" of `Scripts/agents/briefs/2026-10-30/teams-common.md`, and the build section at the end of this brief, which overrides its build-folder rules.

## Goal

The Export dialog's job runner (`BookExportService`) lists what a book can export by kind, plans each file's name, and writes each file through a scratch folder, never replacing anything. It was built to take an audio conversion later ("An audio kind can gain a case of its own later (FMT30, FMT43) without the job runner changing shape"). This task adds the kind "Text as spoken audio" for a text book, the conversion `.speech(SpeechExportRequest)` that makes its file by running `SpeechExportJob`, its file's name, and the progress channel the job reports through. The dialog's model and sheet come in the next task (`dialog`).

## Read first

- `TextMouth/Services/BookExportService.swift`: 1-260 (kinds, files, items, offers, outcome, cancellation, `BookExportConversion`), 280-345 (`offer(for:access:)`), 690-900 (`plan`, `files(of:for:conversions:)`, `export`, `write`, `writeConverted`, `writeThroughScratchFile`).
- `TextMouth/Models/BookExportWording.swift` 1-45 and 120-160 (`name(of:)`, `hint(for:)`, `choiceLabel`).
- `TextMouth/ViewModels/BookExportModel.swift` 17-76 (`BookExportChoice.choices(for:)`).
- `TextMouth/Services/SpeechExport/SpeechExportJob.swift` (the request, progress, environment, context, and `run`), `SpeechExportEncoder.swift` (`SpeechExportFormat`).
- `TextMouthProductionTests/BookExportServiceTests.swift` and `BookExportConversionTests.swift`: their setup helpers only, to make books and offers the same way.

## What to make

### 1. `TextMouth/Services/BookExportService.swift`

1. `BookExportKind`: a case `spokenAudio` right after `plainText` (the dialog lists kinds in `allCases` order), its doc comment: a text book's reading text, or a range of its headings, spoken by its voice into one audio file with a chapter per heading (FMT43), made by `SpeechExportJob`; never copied, so a book offers it only with its text cache, and only a `.speech` conversion makes its file.
2. `BookExportFile.Source`: a case `spoken(fromMarkdown: URL)`, the text cache a speech export reads, planned only through a `.speech` conversion; `url` gives that URL.
3. `offer(for:access:)`: inside `if hasMarkdown && !book.format.isAudio`, after the plain text item, a standalone `.spokenAudio` item of one file, `BookExportFile(source: .spoken(fromMarkdown: markdown), path: "\(stem) - Audio.\(SpeechExportFormat.m4b.fileExtension)", byteCount: 0)` (its size is not known before it is spoken). A content.md only in the cloud makes the item in the cloud, as for the Markdown.
4. `BookExportConversion`: a case `speech(SpeechExportRequest)`. `fileExtension` is the request's format's; `applies(to:)` is true for `.spokenAudio` alone (and `.text` stays as it is); `name` is the format's `title`.
5. `files(of:for:conversions:)`: a `.spokenAudio` item is planned only with a `.speech` conversion whose request's `bookID` is the book's: its `.spoken` file becomes `BookExportFile(source: .converted(from: <the text cache>, book: ExportBookDetails(book), by: <the conversion>), path: "\(request.fileTitle).\(request.format.fileExtension)", byteCount: 0)`; otherwise nothing is planned for it (no file, no failure). The planned name is then made unique like any other ("Moby-Dick - Audio 2.m4b"). A `.spoken` source met by the generic mapping is left out.
6. `export(...)`: a new last parameter `speech: SpeechExportContext = .live`, passed through `write` to `writeConverted`.
7. `write`: the `.spoken` placeholder (never planned) is a failure, not a crash: throw `CocoaError(.featureUnsupported)` into the usual failure handling.
8. `writeConverted`: `case .speech(let request)`: `try writeThroughScratchFile(to: target, cancellation: cancellation) { scratch in try SpeechExportJob.run(request, markdown: bytes, source: source, to: scratch, context: speech, cancellation: cancellation) }`. The job's errors pass as the other kinds' do: Stop (`CancellationError`) marks the outcome stopped; any other error names the file with its sentence ("Couldn't export Moby-Dick - Audio.m4b: …").
9. Update the doc comments that say the audio case comes later (`BookExportConversion`, `writeThroughScratchFile`) to say it is here.

### 2. `TextMouth/Models/BookExportWording.swift`

- `name(of: .spokenAudio)` "Text as spoken audio"; `hint(for: .spokenAudio)` "The book's text spoken by its voice into one audio file, with a chapter for each heading."
- `choiceLabel`: for `.spokenAudio`, no size (its size is unknown until it is spoken) and no file count; the rest as for any kind ("Text as spoken audio", or "Text as spoken audio, in the cloud").

### 3. `TextMouth/ViewModels/BookExportModel.swift`: one line of `BookExportChoice.choices(for:)` only

`.spokenAudio` is offered when the dialog exports one book, never for several (its range and sliders are one book's). Leave the rest of the file to the `dialog` task.

Comment every new case and function, and each non-obvious block.

## Tests: `TextMouthProductionTests/SpeechExportServiceTests.swift` (new)

Books come from an integration world (`makeIntegrationWorld`, `world.importBook(from:)`, a Markdown source in a sandbox folder, as `BookExportConvertToTests` makes them); every export goes to a sandbox folder; the speech context uses `FakeSpeechBufferSynthesizer`, a fake non-personal voice, a fake power, 100 GB free, and a sandbox store root (as `SpeechExportJobTests` does: share nothing with it but the fake synthesizer). Pin at least:
1. A text book's offer has the `.spokenAudio` item, "<stem> - Audio.m4b", from a `.spoken` source; an audiobook's has none; a text cache in the cloud makes it in the cloud.
2. `choices(for:)` lists it for one book and not for two.
3. The plan with a `.speech` conversion names the file `fileTitle` plus the format's extension (MP3 too), made unique when the name is taken; without the conversion, or with one for another book, nothing is planned for the kind; the other kinds' plans are unchanged.
4. `export` with the conversion writes the file into the folder, with a chapter per heading (`AudioPlaybackService.extractChapters(from:)`), and the context's progress hears `.speaking` and `.encoding`; the outcome lists the file.
5. Stop during the speech (the fake cancelling the token) leaves nothing in the folder, and the outcome says it was stopped, with no failure.
6. A refusal (a Personal Voice) is a failure naming the file with the error's sentence (`BookExportWording.failureSentence`).
7. The kind's name, hint, and label (no size).

## Existing tests that change (the lead's decision, made here)

Every text book now offers one more kind, so the assertions below, which list a text book's kinds, labels, or names, or count its dialog's checkboxes, gain exactly the new kind and nothing else: `.spokenAudio` after `.plainText`, the label "Text as spoken audio", the name "<stem> - Audio.m4b", one more checkbox. Change only these, in one commit of their own whose message names each, and list them in your report:
- `BookExportServiceTests`: the text books' `offer.items.map(\.kind)` (about lines 31, 136, 150, 174) and the `suggestedName` list after the first (about line 33).
- `BookExportSheetTests`: `testListingGivesACheckboxForEachKindWithItsSize`'s labels (about line 37); `testTheDialogDrawsACheckboxPerKindTheFirstTakingFocus`'s count, states, and enabled states (about lines 214-218: four checkboxes, the new one unchecked and, its text cache being in the cloud there, unavailable).
- `BookExportConvertToTests`: each `until: { self.checkboxes(in: $0).count == 3 }` (about lines 320, 384, 423, 474) and `XCTAssertEqual(withMarkdown, 3, ...)` (about line 391) become 4.
Any other existing test that fails means stop and ask (teams-common.md).

## Run

`SpeechExportServiceTests BookExportServiceTests BookExportConversionTests BookExportConvertToTests BookExportSheetTests export`. Report the exact `Executed N tests, with S tests skipped and F failures` line.

## Do not

- Change the model beyond the one line, the sheet, or the SpeechExport files; or any existing test beyond the list above.
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

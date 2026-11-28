# Export on the iPhone: design (November 24, 2026)

Part of [the research folder](README.md).
Issue: FR31; it builds on DR34 (braille translated in the app), FR32 (the iPhone's Braille setting), and FR40 (every liblouis table in the iPhone's pack).
Written before any change; no code was touched.
Read on main at 4c5dbd644 and on FR40's branch, `feature/braille-tables-finish`, at 59bcbbab7.
The sizes come from the symbols of two existing Release builds, and Apple's documentation is listed under Sources.

## What this design decides

- The iPhone gets the Mac's Export over the same shared code, `BookExportModel`, `BookExportService`, and every writer, with a sheet of its own in the Mac's words.
- Every format the Mac writes works on the iPhone without a new writer, except Word 97-2003, which needs AppKit; the iPhone leaves it out until the user decides (question 4).
- Export… is a command of a book's row in the Library and a control of the reader, after Book Info.
- The files go to a folder the person chooses with the system's folder picker, which TextMouth remembers, as the Mac's Choose Folder… does.
  Each file is made inside the app and copied in under a file coordinator, never over a file that is there.
- The braille options are rows of the sheet, the braille code chosen from the Braille setting's list of every table, the 44 that only write braille included.
- A spoken audio export goes on with the screen locked and with the sheet closed: an iOS 26 continued processing task, with the system's Live Activity, and a card at the top of the Library.
- The phases: everything but spoken audio (1), spoken audio (2), several books and Share… (3), and Word only if the user asks for it (4).
- The brief's "Convert To" is the Mac's Convert to pop-up, the choice of format beside Text as Markdown, so it comes with the text formats in phase 1, as do Convert transcript to and Convert headings to.
- New interface text: 1 line in phase 1, 4 in phase 2 (8 if question 6 is yes), 2 in phase 3, and 1 in phase 4.
- The iPhone app grows by about 0.9 MB over phases 1 to 3, to about 16.6 MB.

## What the iPhone build holds today

- The iPhone target compiles every shared file, the export's among them: the service, the writers, the speech export, the braille writers, the model, and the Mac's sheets.
- These places branch for the Mac:
  - `TextExportWriters.all` leaves out `WordDocExportWriter`, which is in `TextMouth/Platform/macOS/Services/Export/` and calls AppKit's `.docFormat` writer;
  - `SpeechExportPower.live` holds no assertion on iOS, which has no IOKit;
  - on iOS, `BookExportModel` has no one to ask about a chapter nested too deeply, and its `chooseDestination(from:)` does nothing;
  - `BookExportSheet.export()` and `ExportCommandRouting.openWindows(_:)` read the Mac's windows;
  - only the Mac's `AppDelegate` sweeps the kept spoken chapters at launch (`SpeechExportStore.sweepInBackground()`).
- `TextutilConverter` serves the import alone: no part of the export starts a program.
- Nothing on the iPhone opens the export, so the linker leaves most of it out.
  The device build of November 18, before full LTO, holds no symbol of `BookExportService`, `ExportDocumentWalker`, `RTFExportWriter`, `EPUBPackageBuilder`, `BRFExportWriter`, or `BrailleDocumentWriter`, and none of LAME's functions, though the app links LAME.
- What the iPhone has that export uses:
  - braille translated in the app, `BrailleTranslator` through `InProcessEngine` (DR34), with every table once FR40 merges;
  - speech written into buffers: the reader's look-ahead renders already call `AVSpeechSynthesizer.write(_:toBufferCallback:)` on the phone (`AudioEngineService`, `SpeechRenderCoordinator`);
  - `PhoneLogShareSheet` (Share Logs…), the file exporter of Export Interface Text…, `PhoneChoiceSheet`, `PhoneSheetButton`, and `PhoneImportProgressCard`;
  - a background task for each hold (`PhoneLifeCycle.beginHold`), and `RunningClock`, which counts only the time the app runs (B18).

## The text formats and braille

- Markdown, HTML, RTF, EPUB, and plain text are TextMouth's own writers, written from one walk of content.md (`ExportDocumentWalker`), with no Apple writer and no Mac code: they work on the iPhone as they are.
  - RTF is TextMouth's own because Apple's RTF writer drops outline levels; iOS has that writer too (`.rtf`, since iOS 7), and it stays unused.
- BRF and PEF are the shared writers `BRFExportWriter` and `PEFExportWriter`, over `BrailleDocumentWriter`.
  - On the iPhone the translation runs in the app, the Mac's records sent in batches of 256 KB (`BrailleTranslator.batchBytes`), within the time the Mac's watchdog allows its helper (`BrailleTranslator.limits(for:bytes:)`).
  - The export's Stop reaches the library between records, through `ImportCancellation.$current`, which the engine's call reads.
  - FR40's catalog lists every table for export, those that only write braille too (`BrailleTableCatalog.exportCodes`).
  - Only the options are new, as rows of the sheet (The braille rows, below).
- Convert to's choices come from the shared model (`BookExportModel.conversionChoices(for:)`): Markdown, then the iPhone's writers, HTML, RTF, EPUB, BRF, and PEF.

## Word, spoken audio, and the rest

- Word 97-2003 is the Mac's alone: `WordDocExportWriter` makes the .doc with `.docFormat`, which Apple documents for macOS only, as it does `.officeOpenXML`.
  - The choices are question 4's: none, since RTF opens in Word with its headings at their outline levels, which the Mac's .doc lacks; TextMouth's own Word (.docx) writer for both apps, about 600 lines; or TextMouth's own .doc writer.
  - A .doc is a compound file of interlocking tables, which the Mac writer's comment declines to write by hand.
- Spoken audio is shared: `SpeechExportJob` speaks with `AVSpeechSynthesizer.write(_:toBufferCallback:)`, in iOS since 13, and encodes through the audio editor's renderer: AAC in M4B or M4A by `AVAssetWriter` with a chapter track, and MP3 by the LAME built in.
  - Mac-only, and what replaces it: the power assertion, by a continued processing task (phase 2); the Mac's launch sweep, by the same call in the iPhone's app delegate.
  - Words that name macOS, System Settings, or the Mac take the iPhone's, as `SpeechRefusalWording.runsOnPhone` chooses them for the refusal report: two refusals and the licence line, and, by question 6, the kept chapters.
- Captions (WebVTT, SubRip) and chapter lists (CUE sheets, Audacity labels) are shared writers, `TimedTextWriters` and `ChapterListWriters`, and the copies are file copies: nothing in them is new.
- FFmpeg plays no part in export.

## The size cost

- The shared code the iPhone will reach, measured by symbol sizes in the dSYM of the Mac's Release build of November 23 (before full LTO):
  - phase 1: the service 140 KB, the walk and its document 77 KB, the model 61 KB, EPUB 33 KB, the other text writers 21 KB, the braille writers 18 KB, the wording 12 KB, and captions and chapter lists 9 KB;
  - phase 2: the speech export 46 KB, the audio editor's renderer 103 KB, some of which the iPhone already holds, and LAME, 151 KB of code and 70 KB of data in the iPhone's static library.
- Full LTO took about a sixth off the iPhone app (research/SWIFT-SIZE-FLAGS-2026-11-23.md).
- The iPhone's own code comes to about 2,000 lines over the three phases, half of it views; the Mac's export views are 65 KB for 667 lines of code.
- So, about: phase 1, 0.45 MB; phase 2, 0.4 MB; phase 3, under 0.05 MB; phase 4, 0.05 MB.
- The iPhone app was 15.7 MB on FR40's branch (its train of November 24), so about 16.6 MB after phase 3, against the 30 MB limit.
- Each phase measures it on GitHub (`build-train.py request --ios-size`) against main's figure.
- The new text, 12 lines at most in 25 languages, adds a few kilobytes to `Strings.pack`.

## Where Export lives

- In the Library: "Export…", the Mac's command, in a book's row's actions and its context menu, after Move to Folder... as on the Mac, and before Move Up, Move Down, and the removal.
- In the reader: a control after Book Info, the third of the grid's fifth row (`PhoneReaderControl.gridRows`), so the grid keeps its shape and the two skips stay last.
  - Its label is the Mac's toolbar button's, "Export this book", its visible title "Export", and its hint the Mac's, "Opens the Export dialog: the book's audio, its text, or its own file."
  - VoiceOver's order then ends: Voice, Book Info, Export this book, Skip backward, Skip forward.
  - The Mac's toolbar button waits for a setting, since File > Export… is always in the Mac's menu; the iPhone has no menu (question 2).
- Several books, in phase 3: "Export 12 Books…", the Mac's command for a selection, on a folder's row, exports the folder's books, each into a folder of its own.
  The iPhone selects no several rows (the interface spec defers Edit Mode), and a folder is a group the listener has already made (question 3).
- Spoken audio is offered for one book alone, as on the Mac.
- The sheet returns focus to the control that opened it when it closes, as every sheet does (`PhoneFocusPolicy`).

## The Export sheet

The sheet is the Mac's dialog rebuilt for the phone, over the shared `BookExportModel`: a `NavigationStack` holding one `List`, its buttons placed by `PhoneSheetButton`.
VoiceOver's order:

1. The title: the Mac's "Export Moby-Dick", or "Export 12 Books".
2. Cancel; Stop while an export runs; Close once one has ended, or while a spoken audio export goes on (phase 2).
3. Export.
4. "What to export", a heading, then a switch for each kind, each followed, while it is on, by its format row and its options.
5. The folder row.
6. While an export runs, the progress row, and for spoken audio a Stop row (phase 2).
7. What the last export did.

- Focus lands on the first kind 0.35 seconds after the books are listed, as the Mac's dialog starts on its first checkbox.
- While an export runs, the sheet can't be swiped away (`interactiveDismissDisabled`), and VoiceOver's escape gesture presses Stop, as Escape does on the Mac.
- The sheet stays open once an export has ended, showing what it did, where the Mac's dialog closes: on the phone, what is announced can also be read (the interface spec's principle 4).
- Over the reader, the sheet is one of its panels (a new `PhoneReaderSheet.export`), so a speech refusal's report waits for it to close (`PhoneSpeechRefusalPresentation`).
- The Mac's `BookExportSheet`, `BrailleExportOptionsView`, and `SpeechExportOptionsView` stay the Mac's; the iPhone's rows read the same model and options.

## Every control as VoiceOver reads it

Each gives the label, the value, the hint, and the traits; every word is the Mac's unless it says new.

- Cancel, Stop, and Close: buttons; Stop's hint is "Stops the export.
  The file being made is not kept."
- Export: a button, hinted "Exports the checked items to the folder.", dimmed until a folder is chosen and an available kind is on.
- A kind: a switch labeled as the Mac's checkbox, as in "Text as Markdown, about 12 KB", "Text as HTML", or "Audio, 12 files, 340 MB", valued on or off, and hinted as the Mac's checkbox is for the kind and its format, as in "The book's text as HTML, made from its Markdown."
- A format row, while its kind is on: a button labeled "Convert to", "Convert transcript to", or "Convert headings to", valued with the choice, as in "HTML", and hinted with the choice's hint, as in "A web page of the book's text, with a contents list linking each heading."
  It opens a choice sheet of that title, a row for each choice with its hint, the current one selected and focused.
- The folder row: a button, "Choose Folder…" until a folder is chosen, then "Export to: Downloads", hinted "Chooses the folder the checked items are exported to."
- The progress row: a progress view labeled with the Mac's words, "Exporting 3 of 40 items…", "Speaking chapter 2 of 12…", or "Encoding the audio file…", and valued with its percent, which VoiceOver gives.
- What the export did: text, the Mac's sentence, such as "Exported 3 items to Downloads." or "Couldn't export Moby-Dick - Text.brf: TextMouth could not translate this braille."
- While the books are listed, "Finding what can be exported…"; with nothing to export, "There is nothing to export."
- The Library's row action: "Export…", on the Actions rotor and in the context menu, with no hint, as the row's other commands.
- The reader's control: a button, "Export this book", with no value and the Mac's hint above.
- In phase 3, a folder's row action "Export 12 Books…", and a "Share…" button after what the export did, with a new hint, "Sends the files just exported to another app or person."

## The braille rows

While BRF or PEF is the choice, these rows follow Convert to, in the Mac's order and in its words:

- "Braille code": a choice row valued with the table in words and its language, as the Braille setting says it ("Unified English Braille, contracted (Grade 2), in English"), and hinted "The braille code the book is written in."
  - It opens the Braille setting's list of every table, under a heading for each language (`PhoneSettingsModel.brailleTableGroups(codes:)`), here given `BrailleTableCatalog.exportCodes`, so the 44 tables that only write braille are offered, as on the Mac.
  - One list stands for the Mac's three pop-ups, Language, Braille code, and Contraction, as in the iPhone's Braille setting since FR32: each row names all three.
- The Mac's sentence for a Settings table the export can't use, when there is one: "TextMouth can't use the braille table chosen in Settings, “French braille”, so this export starts from Unified English Braille, contracted (Grade 2)."
- "Cells per line": a stepper, adjustable, valued "40 cells", hinted "How many braille cells each line holds, from 18 to 80."
- "Lines per page": a stepper, adjustable, valued "25 lines", hinted "How many lines each braille page holds, from 4 to 50."
- "Braille page numbers": a switch, hinted "Whether each page's last line carries its braille page number."
- For a BRF only, "Line ends": a choice row of "CR LF" and "LF", hinted "CR LF suits most braille displays and embossers."
- For a BRF only, "Braille file characters": a choice row of North American Braille ASCII, Eurobraille six-dot, and Unicode braille patterns, with the Mac's hint, which says to export a PEF to share with a reader elsewhere.
- They start from the Braille setting and stay until the sheet closes, dimmed while an export runs.
- The iPhone has only its pack's tables, which need no check, so an export never waits for one, and the Mac's hint for that wait never shows.
- The rows bind the writer's `BrailleExportOptions` through a typed accessor on `TextExportOptionsEditing`.
- Phase 1 starts once FR40 is on main, since these rows use its catalog and the grouped choice sheet (`PhoneChoiceGroup`).

## The spoken audio rows

In phase 2, while Text as spoken audio is on, these rows follow it, as the Mac's options follow its checkbox:

- "Format": a choice row of the three formats, valued as in "M4B Audiobook (AAC)", with the Mac's hint; the Mac's MP3 sentence follows it for a range of more than 255 headings.
- "From": a choice row of "Beginning of the book" and each heading as the Mac names it, as in "Chapter 3 - level 1", hinted "Where the audio begins: the book's beginning, or a heading."
- "To": a choice row of each heading and "End of the book", hinted "The heading whose section ends the audio, with its subheadings, or the end of the book."
- For a book without headings, the Mac's sentence: "This book has no headings, so all of it is exported."
- "Speed": a slider, adjustable, valued as in "200 words per minute", stepping as Settings' sliders do, with the Mac's hint.
- "Pitch": a slider, adjustable, valued as in "Normal (1.0x)", with the Mac's hint.
- "Voice: Moira", as text, then the licence line in the iPhone's words (new): "Speech from the iPhone's voices is for personal, non-commercial use, under Apple's licence."
- While the headings are read, "Reading the book's headings…", and for text that can't be read, the Mac's sentence.

## The folder the files go to

- The recommendation (question 1) is the Mac's own way: a folder chosen once, and kept.
  - The folder row opens the system's folder picker (`fileImporter` with the folder type), whose `onCancellation` (iOS 17) brings focus back to the row, as Export Interface Text… does.
  - The folder is kept as a bookmark in the preferences for every later export; one that no longer resolves is forgotten, and the row reads "Choose Folder…" again.
- How each file gets there:
  - The export holds the folder's security scope for its whole run, and plans its names against what the folder holds, as the Mac does: nothing is replaced, and a taken name gets a number.
  - Each file is made in a scratch folder inside the app's temporary folder: on iOS, `makeScratchFolder(near:)` asks for no item-replacement folder near the target, which might be made in a file provider's folder and sync a half-made file (unverified).
  - The whole file is then copied into place under a file coordinator, as Apple's guide to chosen folders says, created exclusively as `copyExclusively(_:to:)` creates it, and its scratch copy is removed: a rename from the app's container into a provider's folder is not relied on.
  - One shared seam holds both ways, a `BookExportDelivery` value that `BookExportService.export` is given: the Mac keeps its move, and the Mac's host tests the iPhone's copy too.
  - A spoken audio file is delivered by the same step before its chapters are let go, as on the Mac, so a file in place is never lost to a later end of the app.
  - The folder's name, in the row and in "Exported 3 items to Downloads.", is its localized name (`URLResourceValues.localizedName`): `FileManager.displayName(atPath:)`, which the Mac uses, may give an iCloud Drive folder's name as its path spells it (unverified).
- Not chosen, and why:
  - The share sheet alone: its Save to Files copies, a folder handed to it is unverified, and the Mac's folders (an audiobook's tracks, a DAISY book's files, a folder for each book) need a place to go; Share… comes in phase 3, for the files written.
  - Exporting into the app, then the system's move picker (`fileMover`, iOS 17): a finished file would wait inside the app until moved, lost if iOS ended the app first, and a forum report has a folder handed to the exporting picker arrive empty.
  - A TextMouth folder in Files as the default, as Documents is the Mac's: it needs the Files folder the interface spec deferred (question 7).

## Progress, Stop, and errors

- The progress and the end are in the Mac's words (above); the end is announced, then kept in the sheet.
- Errors are the Mac's sentences, each after "Couldn't export" and the file's name: a writer's, the braille translator's and its engine's, and the speech refusals.
- A folder that can't be written fails each file with the system's words, as on the Mac.
- New in phase 1, checked before a book's walk: a book too large for the memory left fails with "The iPhone has too little memory free to convert this book now.
  Close other apps, then export again.", and the other books still export.
- A chapter nested too deeply (FR24) is put in an alert over the sheet, the Mac's question in the Mac's words, through a prompt of the iPhone's own (`PhoneExportQuestion`), the counterpart of the Mac's `ExportDeepChapterAlert`:
  - its title, and its message, which says what each button does, since an iOS alert's buttons have no hints;
  - Export as Written, the default; Export Every Such Chapter as Written, while more may follow; and Cancel Export, with the cancel role, which the escape gesture presses;
  - Stop answers it Cancel Export, as on the Mac.
- The Mac's sentence for an export with no one to ask, which names Edit Text, never shows: the iPhone always asks.
- The cloud notice never shows: the iPhone's library is in its own container, never in the cloud.

## Running in the background in phase 1

- An export holds a background task while it runs (`PhoneLifeCycle.beginHold`), so locking the screen does not cut a file off.
- Apple gives such a task a finite time, and says work that needs more belongs to the BackgroundTasks framework.
- A text export takes seconds.
- A braille export of a long book can outlast the task, and then waits, suspended, until the person returns; its translation's limit counts only the time the app runs (`RunningClock`).
- Phase 1's hand check times a braille export of a long book on a phone; if it passes 30 seconds, phase 2's continued task takes braille exports too, since Apple's engineer sees no use for one in less.

## Spoken audio in the background

- The audio background mode keeps an app running while it plays audible content, in Apple's words, and a speech export plays none.
- So phase 2 runs a spoken audio export as a continued processing task, new in iOS 26:
  - submitted as Export is pressed, since Apple requires a person's action, with the strategy fail;
  - under `com.textmouth.TextMouth.iOS.export.` and a UUID, which a wildcard in `BGTaskSchedulerPermittedIdentifiers` permits, its handler registered just before, as Apple's engineer says a dynamic identifier is;
  - titled as the sheet is ("Export Moby-Dick"), its subtitle the progress words, updated at each chapter;
  - its progress the export's fraction, since the system expires a task that reports none.
- The person sees it as a Live Activity and can cancel it there, which runs its expiration handler: the export's Stop, which keeps the chapters spoken.
- When the task does not start, the export runs anyway, held by a background task, as Apple's engineer advises.
- Closing the app in the app switcher cancels the task without telling the app; the chapters spoken stay in Caches (question 6).
- The sheet can close: while the spoken audio file is made, Close takes Stop's place in the bar, and Stop moves to a row under the progress.
  - Close's hint is new: "Closes Export.
    The export goes on, and the Library shows how far it has come."
  - A card at the top of the Library then shows the export, after the title and before the search field, as the import's card does: the sheet's title, the progress words, and Stop.
  - At the end it shows the Mac's sentence and Close, and the end is announced at low priority, as a background result is.
- Only the speech part lets the sheet close: the other kinds come first in an export, and only they can ask about a deep chapter, which needs the sheet.

## Phase 1: what it builds

The person gets Export… in every book's row and in the reader, a book at a time, into a folder they choose: the book's own file, its text in six formats with the braille options, its plain text, an audiobook's audio, headings, bookmarks, and originals, and a transcript as JSON, text, or captions.
Each step is a commit:

1. `TextMouth/Services/BookExportService.swift`: the `BookExportDelivery` seam, and the iPhone's scratch folder.
2. New plain types in `TextMouth/Phone/`:
   - `PhoneExportOffer`: the kinds the iPhone offers (all but `.spokenAudio` until phase 2), the bar's buttons in each state, and the folder row's words;
   - `PhoneExportFolder`: the kept bookmark, its name, and a lost one;
   - `PhoneExportQuestion`, `PhoneExportMemoryCheck`, and `PhoneExportWording`, which holds the new line.
3. `TextMouth/ViewModels/BookExportModel.swift`: the iPhone's prompt in `.standard`, `optionsState(for:)`, which `optionsView(for:)` then uses, and the finished words kept for the sheet.
   `TextMouth/Services/Export/TextExportWriter.swift`: the typed accessor on `TextExportOptionsEditing`.
4. `TextMouth/Platform/iOS/Views/Export/PhoneExportSheet.swift` (new): the list, the bar, the kinds, the format rows, the folder row, the progress, the end, and the alert.
5. `TextMouth/Platform/iOS/Views/Export/PhoneBrailleExportRows.swift` (new).
6. The entry points:
   - `PhoneLibraryOffer` (`.export`), `PhoneLibrarySheets.swift`, and `PhoneLibraryView.swift` (`.export(UUID)`);
   - `PhoneReaderState.swift` (`.export` after `.bookInfo`), `PhoneControlKind.swift`, `PhoneReaderControls.swift`, `PhoneReaderSheet.swift`, and `PhoneReaderSheetContent.swift`.
7. `TextMouth/Phone/PhoneLaunchRequest.swift`: a third debug-only variable, `TEXTMOUTH_EXPORT_TO`, naming a sandbox folder as the folder, so an interface test exports without the system's picker.
8. `project.yml`, `Scripts/test/areas.conf`, and the catalog: `make l10n-sync`, then `l10n.py todo` and `apply` for the 24 languages.

The memory check's factor comes from each writer's peak, measured on the Mac with the largest fixture through `run_locked.py` before the check is set.

## Phase 1: its tests, text, and size

- On the Mac's host, in the `phone` area: `PhoneExportOfferTests`; `PhoneExportFolderTests` (a sandbox folder's bookmark round trips, and a lost one is forgotten); `PhoneExportQuestionTests` (each answer, and a dismissal is Cancel Export); `PhoneExportMemoryCheckTests`.
- Changed there: `PhoneLibraryOfferTests` (Export… in the row's order) and `PhoneReaderControlsTests.testTheGridRowsKeepOrderAndPairs` (a fifth row of three).
- `BookExportDeliveryTests`, shared with the iPhone: the coordinated copy never replaces, numbers a taken name, copies a folder whole, and leaves no scratch folder.
- The writers on iOS: the Mac's files join `TextMouthiOSTests` in `project.yml`, each passing the sound check of `Scripts/agents/tests/test_run_ios_ui_tests.py`:
  - `MarkdownExportWriterTests`, `HTMLExportWriterTests`, `RTFExportWriterTests`, `EPUBExportWriterTests`, `EPUBExportWriterNavigationTests`, `EPUBExportRoundTripTests`, `BrailleExportWriterTests`, `ChapterListExportTests`, and `TranscriptExportTests`;
  - `ExportDocumentWalkerTests`, `ExportDocumentWalkerStructureTests`, `ExportDocumentWalkerNestingTests`, `ExportDeepChapterWalkerTests`, `BookExportServiceTests`, and `BookExportNestingTests`;
  - their Mac parts behind `#if os(macOS)`: `RTFExportWriterTests`' Word tests, and the tests of `TranscriptExportTests` and `BrailleExportWriterTests` that host the Mac's dialog.
- The iPhone's own unit test, `PhoneExportSheetTests`, hosts the sheet as `PhoneTextFieldScalingTests` hosts sheets: the rows' order, labels, values, and hints, the braille rows under BRF, and no Line ends under PEF.
- Interface tests on GitHub, `ExportUITests`, with alice.epub, pressing nothing that sounds and typing nothing:
  - the row's Export… opens the sheet: its order, its words, and its audit; Convert to lists Markdown, HTML, RTF, EPUB, BRF, and PEF; BRF's rows come in order;
  - with `TEXTMOUTH_EXPORT_TO`, Export writes, and the sheet reads "Exported 1 item to" and the folder's name;
  - the reader's Export this book opens the sheet, `ReaderUITests` reads the reader's new order, and the sheet holds at the largest text size.
- Hand checks on a phone: VoiceOver's order and focus; an iCloud Drive folder and an On My iPhone folder; the folder's name; a braille export of a long book with the screen locked, timed; a large book's memory.
- New text: 1 line, the memory sentence.
- Size: about 0.45 MB, from about 1,000 new lines of code.

## Phase 2: what it builds

The person gets Text as spoken audio for a text book, or a range of its headings, spoken by its voice into an M4B, M4A, or MP3 with a chapter for each heading, going on with the screen locked and with the sheet closed; Stop keeps the chapters spoken for the next export.
Each step is a commit:

1. `TextMouth/Services/SpeechExport/SpeechBufferSynthesizer.swift`: `SpeechBufferDelivery` times its stall limits by a clock it is given, `RunningClock.app` on the iPhone, where `DispatchTime` counts a suspension and would end a chapter as stalled after a minute away.
2. `TextMouth/Services/SpeechExport/SpeechExportError.swift` and `TextMouth/Models/SpeechExportWording.swift`: the iPhone's sentences, chosen by an `onPhone` parameter whose default is `SpeechRefusalWording.runsOnPhone`.
3. `SpeechExportStore.swift` and `TextMouth/Platform/iOS/App/TextMouthAppDelegate.swift`: the launch sweep on the iPhone, keeping a week's chapters if question 6 says so.
4. `TextMouth/Platform/iOS/Views/Export/PhoneSpeechExportRows.swift` (new), over the shared `SpeechExportOptionsState`.
5. The continued processing task:
   - `TextMouth/Platform/iOS/Services/PhoneExportBackgroundTask.swift` (new), the task;
   - `TextMouth/Phone/PhoneExportTaskMirror.swift` (new), its progress and subtitle from `SpeechExportProgress`;
   - the wildcard identifier, through `IOS_ONLY_KEYS` in `Scripts/ios/sync-info-plist.py`, into `TextMouth/Platform/iOS/Info.plist`.
6. `TextMouth/Phone/PhoneExportSession.swift` (new), held by `PhoneAppModel`: the export under way, its folder's scope, and its end; and `TextMouth/Platform/iOS/Views/Library/PhoneExportProgressCard.swift` (new), in `PhoneLibraryView.swift`.
7. The kind turned on in `PhoneExportOffer`, the tests, and the translations.

## Phase 2: its tests, text, and size

- On the Mac's host:
  - the speech export's suites as they stand (`SpeechExportJobTests`, `SpeechExportEncoderTests`, `SpeechExportOptionsTests`, `SpeechExportDialogTests`), since the iPhone runs the same code;
  - a stall timed by a scripted clock that skips a suspension, the iPhone's sentences, and the week's sweep;
  - `PhoneExportTaskMirrorTests`, and the card's plain model.
- The iPhone's unit bundle can't take the speech export's suites: its sound check refuses a file that names `AVAudio` or `AVSpeech`, and their fakes make `AVAudioPCMBuffer`s.
- On the iPhone: `IOSInfoPlistTests` reads the identifier, and `PhoneExportSheetTests` hosts the spoken audio rows.
- Interface tests on GitHub read the rows' order, words, and audit, with Export unpressed.
- Hand checks on a phone:
  - an export with the screen locked, and the Live Activity read by VoiceOver, with Stop from it;
  - the app closed in the app switcher during an export, then the same export asked again;
  - a book playing in TextMouth, and Music playing, during an export;
  - a Personal Voice, refused before any sound.
- New text: 4 lines (the licence line, the two refusals, and Close's hint), and 4 more if question 6 is yes (Stop's hint and the three kept sentences).
- Size: about 0.4 MB, LAME the most of it, from about 800 new lines of code.

## Phase 3: several books, and Share…

The person gets a folder's books exported at once from the folder's row, each into a folder of its own, and Share… after an export, which sends the files just written to another app or person.

- Files:
  - `PhoneLibraryOffer.folderCommands(offersDelete:)` gains "Export 12 Books…", and `PhoneLibrarySheets.swift` and `PhoneLibraryView.swift` present the sheet for the folder's books;
  - `PhoneShareSheet.swift`, made from `PhoneLogShareSheet` for any files, which Share Logs… then uses too.
- Tests: `PhoneLibraryOfferTests` (the folder's command and its count); `BookExportServiceTests`' plans for several books, already shared with the iPhone; an interface test that opens the share sheet and cancels it, as `InterfaceTextExportUITests` does the exporter.
- New text: "Share…" and its hint.
- Size: under 0.05 MB, from about 150 new lines of code.
- On an iPad the share sheet fills a SwiftUI sheet, as Share Logs… does, where Apple asks for a popover: on the hand-check list.

## Phase 4: Word, if the user asks for it

- It waits for question 4.
- TextMouth's own Word (.docx) writer, `TextMouth/Services/Export/DOCXExportWriter.swift`, in `TextExportWriters.all` on both apps, after RTF: the walk's blocks as WordprocessingML with the heading styles 1 to 6, zipped with ZIPFoundation as `EPUBPackageBuilder` packs.
- Tests: a round trip through TextMouth's own Word reader on both platforms, the headings at their levels; the file opened in Word and Pages by hand.
- New text: its hint; its name, "Word (.docx)", stays untranslated, as Word 97-2003's does.
- Size: about 0.05 MB.

## Risks: memory, braille, and disk

- Memory with a large book:
  - The walk holds the whole of content.md and its `ExportDocument`, and RTF, HTML, and EPUB build their output in memory, so a book of 32 MB of text, the size the braille review E5 measured, could peak near a gigabyte.
  - iOS ends an app past a limit it does not publish (`PhoneMemoryPolicy` cites reports of 900 MB to 5 GB), and the playback guard stops a playing book under 150 MB left (`PhoneMemoryPolicy.stopPlaybackBelow`).
  - So phase 1 measures each writer's peak, and refuses, before its walk, a book whose estimate would leave less than 512 MB, the in-app converter's floor (`SessionMemoryFloor`); the other books export.
- A long braille translation:
  - The limit is the Mac helper's, 10 seconds and 6 more for each MB of input, over all the batches; the Mac did 10 MB to Grade 2 in 15.3 seconds, and a phone may be slower.
  - A large table that only writes braille, such as `zh-tw.ctb` (53,810 lines), is unpacked and compiled at its first use, within the same limit.
  - A call that runs past its grace is abandoned, and the engine then refuses braille, imports included, until TextMouth is closed and opened again (DR34): phase 1's hand check times the longest books and tables on a phone.
  - The engine runs one call at a time, so a braille import waits behind an export's translation.
- Disk:
  - Each file is made in the app's temporary folder and then copied, so it takes its size twice until the copy ends; the spoken audio check counts the file once, and keeps 1 GB free (`ArchiveLimits.standard.freeSpaceReserve`).
  - A ten-hour book's spoken chapters take about 1.6 GB until its file is made, and iOS may empty Caches meanwhile, after which they are spoken again.

## Risks: speech, sound in tests, and folders

- Speech to a file in the background:
  - Without the continued task, iOS suspends the app soon after it leaves the screen, unless a book plays.
  - The task can be refused, or expired by the system under load; the export then goes on in the foreground only.
  - Whether the speech service delivers buffers to an app in the background is unverified; the reader's look-ahead renders do it while a book plays.
  - `usesApplicationAudioSession` decides whether the synthesizer shares the app's audio session; whether writing to buffers interrupts or ducks a playing book or Music is unverified.
  - macOS speaks a Personal Voice aloud rather than into buffers, iOS is taken to do the same, and the export refuses one before anything is spoken, so no phone reads a book aloud by mistake.
  - Listening during a spoken audio export is an open caution on the Mac too.
- Sound in a test:
  - No test runs a real voice: the shared tests' synthesizer is a fake that makes a quiet tone in memory, and those tests stay on the Mac's host.
  - No interface test presses Export with spoken audio; one that someday does needs a debug-only fake synthesizer and `requireSound`.
  - No test plays Ogg, and nothing here reads one.
- Writing into a folder outside the app:
  - File providers differ: iCloud Drive, On My iPhone, and a third party's provider each need the hand check.
  - A bookmark can go stale, and its folder be deleted or moved; the row then asks for a folder again.

## Questions for the user

1. Should exports go to a folder you choose once, which TextMouth remembers, as on the Mac, with Share… after an export in phase 3, rather than to the share sheet alone?
   Recommended: yes.
2. Should the reader have an Export control after Book Info, "Export this book", as well as the Library's row command?
   Recommended: yes.
3. Should a folder's row export its books at once, "Export 12 Books…", each into a folder of its own, while Edit Mode stays deferred?
   Recommended: yes, in phase 3.
4. Word on the iPhone: leave it out, since RTF opens in Word with its headings; TextMouth's own .docx writer, for both apps; or its own Word 97-2003 writer?
   Recommended: leave it out now, and the .docx writer if you want Word files from the iPhone.
5. Should a spoken audio export go on with the sheet closed, with a card in the Library and the system's Live Activity?
   Recommended: yes.
6. Should the iPhone keep spoken chapters for a week, through a close of the app, so an export that iOS ended goes on next time, in place of the Mac's "until TextMouth quits"?
   It costs 4 new lines, and up to 1.6 GB for a ten-hour book until the week is out.
   Recommended: yes.
7. Should exports default to a TextMouth folder in Files, as the Mac's default is Documents?
   It needs the Files folder the interface spec deferred.
   Recommended: not now.

Only phase 4 waits, for question 4; every other phase is built with the recommended answers, and question 6 changes only phase 2's words and sweep.

## Sources

Read on November 24, 2026:

- `.docFormat`, macOS only: https://developer.apple.com/documentation/foundation/nsattributedstring/documenttype/docformat
- `.officeOpenXML`, macOS only: https://developer.apple.com/documentation/foundation/nsattributedstring/documenttype/officeopenxml
- `.rtf`, iOS 7: https://developer.apple.com/documentation/foundation/nsattributedstring/documenttype/rtf
- `write(_:toBufferCallback:)`, iOS 13: https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write(_:tobuffercallback:)
- `usesApplicationAudioSession`: https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/usesapplicationaudiosession
- The continued task, iOS 26, its Live Activity, and its progress: https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask
- Its request, after a person's action: https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest
- Its strategies and the app switcher's silent cancel: https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados
- Its wildcard, its handler, and its expiry without progress: https://developer.apple.com/videos/play/wwdc2025/227/
- Apple's engineer on 30 seconds, and on going on without it: https://developer.apple.com/forums/thread/796944
- Apple's engineer on dynamic identifiers: https://developer.apple.com/forums/thread/799126
- The audio background mode: https://developer.apple.com/documentation/xcode/configuring-background-execution-modes
- A background task's finite time: https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(withname:expirationhandler:)
- A chosen folder's scope, coordinator, and bookmark: https://developer.apple.com/documentation/uikit/providing-access-to-directories
- `fileImporter` with `onCancellation`, iOS 17: https://developer.apple.com/documentation/swiftui/view/fileimporter(ispresented:allowedcontenttypes:allowsmultipleselection:oncompletion:oncancellation:)
- `fileMover`, iOS 17: https://developer.apple.com/documentation/swiftui/view/filemover(ispresented:files:oncompletion:oncancellation:)
- The exporting picker, iOS 14: https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller/init(forexporting:ascopy:)
- A developer's folder exported empty: https://developer.apple.com/forums/thread/125005
- The share sheet, a popover on an iPad: https://developer.apple.com/documentation/uikit/uiactivityviewcontroller

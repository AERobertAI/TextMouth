# Task `fixdialog` (team export, review round, October 19, 2026): the Convert to picker survives new writers, says no wrong size, and is still while exporting

Worker `export-fixdialog`, branch `export/fixdialog` from `team/export`. Review items M2 (its dialog half), L2, and L3 of the two Opus reviewers. Three commits, one per item, each with its tests.

## Read first (only these)
- `TextMouth/ViewModels/BookExportModel.swift` lines 130 to 190 (state and `init`) and 258 to 345 (`// MARK: Converting`).
- `TextMouth/Views/Export/BookExportSheet.swift` lines 60 to 125.
- `TextMouth/Models/BookExportWording.swift` lines 60 to 160.
- `TextMouth/Services/Export/TextExportWriter.swift` lines 20 to 80 (the protocol, with `Options`, `defaultOptions()`, and `optionsView(_:)`).
- `TextMouthProductionTests/BookExportConvertToTests.swift` (whole, 383 lines): the tests you change.

## M2 (commit 1): the tests pin tonight's writers without forbidding new ones
Team braille will add BRF and PEF writers with one new file and one line in `TextExportWriters.all`; that must not turn these tests red.
1. `testThePickersChoicesAreMarkdownThenEachWriter` (lines 107 to 136): pin the first four choices, in order, exactly as now (Markdown, HTML, RTF, "Word 97-2003 (.doc)", with their hints); and check that the choices after Markdown are exactly `TextExportWriters.all`, in order, by id, name, and hint (so a new writer's entry is checked against its writer, not against a list).
2. `testNoOptionsViewShowsForTonightsWriters` (lines 188 to 198): check only the writers whose ids are "html", "rtf", and "doc".
3. Change no other test's meaning.

## L2 (commit 2): a converted checkbox says no size
The size in "Text as HTML, about 1.2 MB" is content.md's, and a converted file's is not: RTF of Cyrillic text is 3.2 times larger and of Chinese 2.7 times, since each such character becomes an escape; Word 97-2003 is 2 to 2.9 times larger for English and never under about 19 KB. A size that misleads is worse than none.
1. In `BookExportWording.choiceLabel(…, convertedTo:)` (line 128), a conversion name leaves the size out entirely: "Text as HTML" for one book, "Text as HTML, 2 books" for several, "Text as RTF, 2 books, 1 book in the cloud" with books in the cloud. Without a conversion, every label is exactly as today ("Text as Markdown, 1.2 MB"; "Text as plain text, about 1.2 MB").
2. Its comment says why, in a sentence: a converted file's size is not known until it is written, and the Markdown's would mislead.
3. **Tests:** update the pins in `testAConvertedChoiceLabel` and `testChoosingAWriterChangesTheCheckboxWords` to the new names, exactly; the labels without a conversion stay pinned as they are.

## L3 (commit 3): the options view is disabled while an export runs, as the checkbox and picker are
1. **The model takes its writers.** `BookExportModel.init` gains a last parameter `writers: [any TextExportWriter] = TextExportWriters.all`, kept in `let writers`. `conversionChoices(for:)` becomes an instance method reading `writers` (Markdown first, then each writer), and `setConversionID(_:for:)` and the conversion's name look writers up in `writers`, through one private `writer(id:)` (DRY). The sheet calls `model.conversionChoices(for:)`. The parameter's comment: the app always passes all; a test passes writers of its own, such as one with options.
2. **The sheet:** the options view under the row (line 98) gets `.disabled(model.isExporting)`, as the checkbox (line 91) and the picker (line 116) have it.
3. **Tests** (in `BookExportConvertToTests.swift`, a new `// MARK: - A Writer With Options` part), with a private test writer that has options: `struct Options: TextExportOptions { var isOn = false }`, `defaultOptions()` giving them, and an `optionsView(_:)` of one `Toggle("Test option", isOn: options.isOn).toggleStyle(.checkbox)` with `.accessibilityHint("A test option.")`. Its `write` writes a short file; for the export test it first signals that it has started and then waits, at most 10 seconds, until the test lets it go (a `DispatchSemaphore` each way, so a failing test can never hang).
   - **Drawn:** a hosted dialog (`withHostedView`) on a model with `writers: [the test writer]`: with "Text as Markdown" checked and the test writer chosen, one more checkbox (the option) is drawn than with Markdown chosen; unchecking the kind takes it away. `optionsView(for: .markdown)` is not nil while the writer is chosen and the kind checked, and nil on Markdown.
   - **Disabled while exporting:** in the hosted dialog, with the test writer chosen, start `Task { await model.export() }`; wait until the writer has started and `model.isExporting` is true (`waitUntil`, spinning the run loop); the option's checkbox `isEnabled` is false; then let the writer go, wait until the export has ended, and the option's checkbox `isEnabled` is true again. The export writes the test writer's file into the sandbox folder.
   - The options a test sets in the view (`state.options.isOn = true` through the drawn checkbox's `performClick` or the model's state) reach the writer's `write`: record the options it was given and assert `isOn` is true.

## Build and test
`BBS_AGENT=export-fixdialog python3 Scripts/test/run-area.py BookExportConvertToTests BookExportSheetTests KeyboardReachabilityTests` (read `-h` first), with your own build folder as `teams-common.md` says. Then `make lint-a11y LINT_BASE=team/export` and `make lint-tests LINT_BASE=team/export`.

## Do not touch
Anything but `BookExportModel.swift`, `BookExportSheet.swift`, `BookExportWording.swift`, and `BookExportConvertToTests.swift`. Another worker is changing `BookExportService.swift` and its tests, and the lead the files under `TextMouth/Services/Export/` and the writers' tests. A failing existing test means stop and ask `export-lead`.

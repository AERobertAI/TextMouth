# Task `dialog` (team export, October 19, 2026): the Convert to picker in the Export dialog

Worker `export-dialog`, branch `export/dialog` from `team/export`. FMT18. The job runner already converts (`BookExportService.export(_:kinds:conversions:to:access:cancellation:progress:)`), and three writers are registered (HTML, RTF, Word 97-2003). You give the Export dialog its Convert to picker: beside the "Text as Markdown" checkbox, offered only while it is checked, with Markdown (today's export, the default) first and then every writer of `TextExportWriters.all`, and, under the picker, the chosen writer's options view when it has one (none tonight; team braille's BRF and PEF will). The user is blind and works with VoiceOver and a braille display: every word is spoken as shown and pinned by a test.

## Read first (only these)
- `TextMouth/ViewModels/BookExportModel.swift` (378 lines): the dialog's model.
- `TextMouth/Views/Export/BookExportSheet.swift` (162 lines): the dialog.
- `TextMouth/Models/BookExportWording.swift` lines 1 to 125: the words.
- `TextMouth/Services/Export/TextExportWriter.swift` lines 150 to 250: `TextExportOptionsEditing`, `TextExportOptionsState`, and `TextExportWriters` (`all`, `markdownID`, `writer(id:)`, `optionsState(for:)`).
- `TextMouth/Services/BookExportService.swift` lines 195 to 240: `BookExportKind.convertsText` and `BookExportConversion`.
- `TextMouthProductionTests/BookExportSheetTests.swift` lines 1 to 75, 200 to 265, and 420 to 455: how the dialog is tested (`AnnouncementCapture` is shared; `withHostedView` and `descendants(of:as:)` are in `AccessibilityTestSupport.swift`).

## The changes
1. **Wording** (`BookExportWording.swift`, a new `// MARK: Convert To` part, plus the two functions changed):
   - `static let convertToLabel = "Convert to"`;
   - `static let markdownChoiceName = "Markdown"` and `static let markdownChoiceHint = "The book's text as Markdown, the file TextMouth reads it from, as it is."`;
   - `name(of:convertedTo:)`: with a conversion name, "Text as \(name)" for a kind that `convertsText` (so "Text as HTML", "Text as RTF", "Text as Word 97-2003 (.doc)"); without one, `name(of:)` as today;
   - `hint(for:convertedTo:)`: with a conversion name, for a kind that converts text, "The book's text as \(name), made from the Markdown TextMouth reads it from."; without one, `hint(for:)` as today;
   - `choiceLabel(…)` gains `convertedTo: String? = nil` as its last parameter: the label's name is `name(of:convertedTo:)`, and its size reads "about" for a conversion as it does for plain text. Called without it, every label is exactly as today.
2. **A choice of the picker.** In `BookExportModel.swift`: `struct BookExportConversionChoice: Identifiable, Equatable` with `id` (the writer's id, or `TextExportWriters.markdownID`), `name`, and `hint`; and `static func conversionChoices(for kind: BookExportKind) -> [BookExportConversionChoice]`: for a kind that `convertsText`, Markdown (`markdownChoiceName`, `markdownChoiceHint`) and then each writer of `TextExportWriters.all` in order (its `name` and `hint`); for every other kind, none.
3. **The model's state** (`BookExportModel`):
   - `@Published private(set) var conversionIDs: [BookExportKind: String] = [:]`: the picker's choice per kind; a kind not in it is on Markdown. Every dialog starts on Markdown, so an export made as before gives the same file.
   - `func conversionID(for:) -> String`, and `func setConversionID(_:for:)`, which ignores a kind with no choices and an id not among its choices, and makes the writer's options state on first choosing it (`TextExportWriters.optionsState(for:)`), kept in a private dictionary by writer id for the dialog's life, so choosing another writer and coming back finds the options as they were.
   - `func conversionChoice(for:) -> BookExportConversionChoice?`: the choice the picker shows, nil for a kind with no choices.
   - `func label(for choice: BookExportChoice) -> String` and `func hint(for kind: BookExportKind) -> String`: the checkbox's words, with the conversion's name when a writer is chosen, from item 1. Give `BookExportChoice` a `func label(convertedTo:) -> String`, with today's `label` calling it with nil (DRY).
   - `func optionsView(for:) -> AnyView?`: the chosen writer's options view when the kind is checked and the writer `hasOptions`; nil otherwise.
   - `var conversions: [BookExportKind: BookExportConversion]`: for each checked kind on a writer, `.text(<its options state>.conversion())`.
   - `export(announcingFrom:)` takes `conversions` on the main actor with `kinds` and `folder`, before the work goes off the main thread, and passes it to `BookExportService.export`.
4. **The sheet** (`BookExportSheet.swift`). In the checkboxes' `ForEach`, for each choice:
   - the `Toggle`'s label is `model.label(for: choice)` and its hint `model.hint(for: choice.kind)`;
   - beside it, in an `HStack`, while `model.isChecked(choice.kind)` and the kind has choices: a `Picker(BookExportWording.convertToLabel, selection:)` over `BookExportModel.conversionChoices(for:)`, each `Text(name).tag(id)`, `.pickerStyle(.menu)`, `.fixedSize()`, `.disabled(model.isExporting)`, `.accessibilityLabel(BookExportWording.convertToLabel)`, `.accessibilityValue(<the choice's name>)`, and `.accessibilityHint(<the choice's hint>)`; its binding reads `conversionID(for:)` and writes `setConversionID(_:for:)`;
   - under the row, indented by 24 points, `model.optionsView(for: choice.kind)` when it is not nil.
   - The first checkbox keeps VoiceOver's initial focus; the header comment of the sheet says what the picker does.
5. Comment every function and non-obvious block. Keep the body's views small: put the picker in a private function of the sheet.

## Tests: `TextMouthProductionTests/BookExportConvertToTests.swift` (new; `xcodegen generate`, commit `project.pbxproj`)
`@MainActor final class BookExportConvertToTests: XCTestCase`, books in `makeIntegrationWorld(_:)`'s library, exports into `makeSandboxDirectory(_:)`, with a source writer of the test's own (copy the pattern of `BookExportSheetTests.writeSource(named:)`, which is private).
1. The picker's choices for `.markdown` are exactly Markdown, HTML, RTF, and "Word 97-2003 (.doc)", with their hints exactly (the writers' hints are "A web page of the book's text, with a contents list linking each heading.", "Rich text, with each heading at its outline level, for Word, Pages, and TextEdit.", and "Word 97-2003 document. Its headings are plain text, so Word's navigation pane does not list them."); every other kind has none.
2. A new dialog is on Markdown; `setConversionID("html", for: .markdown)` changes the checkbox's label to "Text as HTML, about <size>" and its hint; back on Markdown, the label is today's exactly; an unknown id and a kind without choices are ignored.
3. Export with HTML chosen writes "<stem> - Text.html" (and no ".md"), announces "Exported 1 item to <folder>.", and the dialog has nothing to say (it closes); with Markdown chosen the file is ".md" and byte for byte the book's content.md.
4. Unchecking "Text as Markdown" leaves its choice as it was; the export of a dialog whose only conversion is on an unchecked kind passes no conversion (`model.conversions` is empty).
5. `optionsView(for:)` is nil for Markdown and for each of tonight's writers.
6. **Drawn:** a hosted dialog (`withHostedView`) with "Text as Markdown" unchecked draws no `NSPopUpButton`; checked, it draws one, whose selected item's title is "Markdown"; after `setConversionID("rtf", for: .markdown)`, "RTF". Use `until:` to wait for the drawing, as `BookExportSheetTests` does.
7. Every new word of item 1, pinned exactly: `convertToLabel`, `markdownChoiceName`, `markdownChoiceHint`, `name(of:convertedTo:)` and `hint(for:convertedTo:)` for HTML and for "Word 97-2003 (.doc)", and a `choiceLabel` with `convertedTo` for one book and for several.

## Build and test
Through `python3 Scripts/test/run-area.py BookExportConvertToTests BookExportSheetTests BookExportServiceTests KeyboardReachabilityTests` (read `-h` first), with your own build folder as `teams-common.md` says. Then `make lint-a11y LINT_BASE=team/export` and `make lint-tests LINT_BASE=team/export`, and fix what they find in your lines.

## Do not touch
`BookExportService.swift`, the files under `TextMouth/Services/Export/`, the existing tests (`BookExportSheetTests` must pass as it is: every label without a conversion stays exactly as today), or any `*.md` file. If one of them seems to need a change, stop and ask `export-lead` on the board.

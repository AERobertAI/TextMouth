# Task `runner` (team export, October 19, 2026): the export's job runner converts

Worker `export-runner`, branch `export/runner` from `team/export`. FMT18. Export copies files today. You teach it to convert: the "Text as Markdown" item of each book, when a writer is chosen, is walked from content.md into an `ExportDocument` and written by that writer, off the main thread, one book at a time, under the existing progress and Stop, never replacing a file, and leaving no half-written file. The dialog's picker is another task's; you give it the parameter it passes.

## Read first (only these)
- `TextMouth/Services/BookExportService.swift`: lines 49 to 77 (`BookExportFile` and its `Source`), 169 to 240 (`BookExportCancellation`, `BookExportKind.convertsText`, `BookExportConversion`), and 636 to 824 (`PlannedFile`, `plan`, `export`, `write`, `logOutcome`, and the reading text).
- `TextMouth/Services/Export/TextExportWriter.swift` lines 1 to 150: the writer protocol, `TextExportError`, `TextExportConversion`.
- `TextMouth/Services/Export/ExportDocumentWalker.swift`: only its two entry points' comments (`document(fromContentBytes:at:book:cancellation:)`).
- `TextMouth/Services/Export/ExportDocument.swift`: only `ExportBookDetails` (its `init(_ book: Book)`).
- `TextMouthProductionTests/BookExportServiceTests.swift` lines 1 to 50 and 276 to 340, for how a test makes a library, imports a book, and exports into a sandbox folder.

## The changes, all in `BookExportService.swift`
1. **A converted file.** `BookExportFile.Source` gains `case converted(from: URL, book: ExportBookDetails, by: BookExportConversion)`, whose `url` is the file read (content.md). Its comment: the file at `from`, made into another by the conversion, for the book `book`.
2. **The plan.** `plan(_:kinds:conversions:in:fileExists:)` gains `conversions: [BookExportKind: BookExportConversion] = [:]` right after `kinds`.
   - For each item of a kind with a conversion, each file whose source is `.copy(url)` becomes `BookExportFile(source: .converted(from: url, book: ExportBookDetails(book), by: conversion), path: <its path with its extension replaced by the conversion's>, byteCount: <the same>)`, as in "Moby-Dick - Text.md" becoming "Moby-Dick - Text.html". Names are then made unique exactly as today (`UniqueNames.claim`), so a name never replaces a file.
   - A `.text` conversion applies only to a kind whose `convertsText` is true; given for any other kind, it is ignored and that kind is exported as today.
   - Write it as one private function (the file of an item, converted when its kind has a conversion), called where the plan walks the items' files.
3. **The export.** `export(_:kinds:conversions:to:access:cancellation:progress:)` gains the same `conversions` parameter, after `kinds`, and passes it to `plan`. Everything else about it stays: the files in the plan's order, the cancellation checked before each, `progress` after each.
4. **Writing a converted file** (in `write`, which now also takes the cancellation; pass `cancellation ?? BookExportCancellation()` from `export`):
   - read the source's bytes through `access.read`, as the reading text is read (so nothing in the cloud is downloaded);
   - `try cancellation.checkCancelled()`;
   - for `.text(let conversion)`: `ExportDocumentWalker.document(fromContentBytes:at:book:cancellation:)`, then the conversion writes the document into a **scratch file**, a file of the target's name in a new scratch folder: `FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: <the target's folder>, create: true)`, or, when that throws, a new folder "TextMouth Export <UUID>" in `FileManager.default.temporaryDirectory`;
   - `try cancellation.checkCancelled()` once the writer returns;
   - `FileManager.default.moveItem(at: scratchFile, to: target)`, which fails rather than replace a file that appeared since the plan;
   - the scratch folder is removed in every case (a `defer`), so a stopped or failed conversion leaves nothing behind, and nothing is ever removed from the folder chosen (a conversion's target exists only once it is whole);
   - then the target is recorded in `outcome.exported`, as a copy is.
   Put the scratch-and-move steps in one private function taking the target, the cancellation, and a closure that writes to the scratch URL, so an audio conversion (FMT30, FMT43) can use it later; say so in its comment.
5. **Stop.** A `CancellationError` thrown while writing any file (caught before the other errors) sets `outcome.wasCancelled` and ends the export, as a Cancel between files does: the file is neither exported nor a failure.
6. **Failures.** Any other error of a conversion is a `BookExportFailure` named for the target's file name (which carries the book's title), with the error's `localizedDescription` as its reason (a `TextExportError` gives its sentence), and the export goes on with the next file, as today. A download refusal still notes the book as in the cloud.
7. Comment every new function and case; update the comments of `plan`, `export`, and `BookExportFile.Source` to say what converting does. Log nothing new.

## Tests: `TextMouthProductionTests/BookExportConversionTests.swift` (new; `xcodegen generate`, commit `project.pbxproj`)
`@MainActor final class BookExportConversionTests: XCTestCase`, each book in `makeIntegrationWorld(_:)`'s library, each export into `makeSandboxDirectory(_:)`. HTML is `BookExportConversion.text(TextExportConversion(HTMLExportWriter(), options: NoTextExportOptions()))`. Test writers are private structs in the test file conforming to `TextExportWriter`.
1. A text book whose Markdown has "## Notes" three times, exported with `.markdown` converted to HTML and `.plainText` alongside: the folder holds "<stem> - Text.html" and "<stem> - Text.txt" and no ".md"; the page parses with `XMLParser`; it has three `<h2` with three distinct ids and a contents link to each.
2. With no conversion, the "<stem> - Text.md" written is byte for byte the book's content.md (today's export, unchanged).
3. Two books converted: each book's folder holds its own "<stem> - Text.html"; exporting again writes "<stem> - Text 2.html" beside the first, which is unchanged.
4. Hand edits: replace a book's content.md with edited Markdown (write the bytes into its package, as Edit Text leaves them), export to HTML: the page holds the edited words and not the old ones.
5. A failing conversion: a writer that throws `TextExportError("The test writer refuses this book.")` for the book titled "Refused Harbour" and writes for the other: the outcome's failures are exactly `[BookExportFailure(name: "Refused Harbour - Text.test", reason: "The test writer refuses this book.")]`, the other book's file is written, and `BookExportWording.finished(outcome, folderName: "Folder")` is exactly "Exported 1 item to Folder. Couldn't export Refused Harbour - Text.test: The test writer refuses this book."
6. Stop partway through a book: a writer that writes some bytes to its URL, records the URL, calls `cancellation.cancel()` (Stop pressed then), and calls `try cancellation.checkCancelled()`. Three books: the outcome `wasCancelled`, the folder holds no file of that book or of the books after it, and neither the recorded URL nor its folder exists any more.
7. Stop just after a book's writer finished (it writes the whole file, then calls `cancel()` and returns): still no file of that book in the folder.
8. A book whose content.md is not UTF-8 (overwrite it with `Data([0xFF, 0xFE, 0x41])`): a failure naming "<stem> - Text.html", and another book still exports.
9. A text conversion given for `.plainText`: the reading text is written as ".txt", as today.
10. `plan` with a `fileExists` that finds "<stem> - Text.html": the planned target is "<stem> - Text 2.html", and its source is `.converted` with the book's `ExportBookDetails`.
11. Progress: with two books converted, `progress` hears (1, 2) and (2, 2) (collect them thread-safely, for example with `OSAllocatedUnfairLock`).

## Build and test
Through `python3 Scripts/test/run-area.py BookExportConversionTests BookExportServiceTests ConvertedOriginalTests BookExportSheetTests` (read `-h` first), with your own build folder as `teams-common.md` says.

## Do not touch
`ExportDocument.swift`, `TextExportWriter.swift`, the walker and writers, `BookExportModel.swift`, `BookExportSheet.swift`, `BookExportWording.swift` (another task's), the existing tests, or any `*.md` file. If something there seems to need a change, stop and ask `export-lead` on the board.

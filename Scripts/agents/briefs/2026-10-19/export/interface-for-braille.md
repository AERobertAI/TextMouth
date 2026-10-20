# The export interface, for team braille (October 19, 2026)

From `export-lead`, on `team/export`. The model and the writer interface are committed at `cee0eb42` ("Add the export document model and the text writer interface (FMT18)"); the walker, the HTML, RTF, and Word writers, the job runner, and the dialog's Convert to picker followed on the same branch the same night, all under the names below. Code your BRF and PEF writers against the names below: they do not change. Plug in once `team/export` is merged into main.

## Where things are

- `TextMouth/Services/Export/ExportDocument.swift`: the model.
- `TextMouth/Services/Export/TextExportWriter.swift`: the writer protocol, its options, its error, the erased conversion, the dialog's options state, and the registry.
- `TextMouth/Services/Export/ExportDocumentWalker.swift`: the one walker of `content.md`.
- `TextMouth/Services/Export/HTMLExportWriter.swift`, `RTFExportWriter.swift`, `WordDocExportWriter.swift`: the first writers, examples to copy.
- `BookExportService.swift`: `BookExportCancellation.checkCancelled()` and `BookExportConversion` (the runner's conversion; text now, audio later).

## The model: `ExportDocument`

Markdown is the base: every text book becomes `content.md`, and every writer reads this model of it. No writer parses Markdown.

- `ExportDocument`
  - `book: ExportBookDetails`: `title: String`, `author: String?` (nil when unknown), `language: String?` (a checked language tag such as "en" or "fr-CA", or nil).
  - `titleHeading: ExportHeading?`: the book's title as a level-1 heading when the text has no level-1 heading of its own; nil otherwise. Writers that open with a title write it first.
  - `blocks: [ExportBlock]`, in reading order.
  - `headings: [ExportHeading]`: every heading of `blocks` at any depth, in order (not `titleHeading`).
  - `static let maximumNesting = 8`: lists and quotes never nest deeper in the model, so you may recurse freely.
- `ExportBlock` (an enum):
  - `.heading(ExportHeading)`: `level` 1 to 6, `runs`, `id` (unique, ASCII letters, digits, hyphens), `plainText`.
  - `.paragraph([ExportRun])`.
  - `.list(ExportList)`: `isOrdered`, `start` (first number), `depth` (0 for a list in no other list, 1 inside an item of one, and so on), `items: [ExportListItem]`. Each item has `blocks` (its paragraphs and any list inside it) and `plainText` (its own words, without the lists inside it).
  - `.blockQuote([ExportBlock])`.
  - `.codeBlock(String)`: lines joined by line feeds, none at the end.
  - `.thematicBreak`.
  - `.table(ExportTable)`: `rows: [[String]]` (cells as plain text), `hasHeaderRow`.
  - `plainText`: one call away for every block (a heading's or paragraph's runs joined; a list's items one a line; and so on, as its comment says).
- `ExportRun`: `text` (a line feed in it is a hard line break), `isEmphasis`, `isStrong`, `isCode`, `link: String?` (only http, https, and mailto addresses; any other link is plain text). `[ExportRun].plainText` joins the texts, and `[ExportRun].linkGroups` gives them grouped as the HTML and RTF writers write them (`ExportRunGroup`: a link's neighbouring runs together, every other run alone).
- **XML.** PEF is XML: put every text and attribute through `XMLEscaping.text(_:)` and `XMLEscaping.attribute(_:)` (`TextMouth/Services/Export/XMLEscaping.swift`), which also leave out the characters XML 1.0 forbids, as the HTML writer does.

What the model leaves out: `content.md`'s marker lines (`<!-- chapter: Title -->`), the navigation annotations, and any raw HTML. A chapter with a title and no heading of its own gets its title as a level-1 heading, as the reader's heading list shows it. Images are their alternative text, as plain runs.

## The walker: `ExportDocumentWalker`

    static func document(fromMarkdown markdown: String, book: ExportBookDetails,
                         cancellation: BookExportCancellation? = nil) throws -> ExportDocument
    static func document(fromContentBytes bytes: Data, at url: URL, book: ExportBookDetails,
                         cancellation: BookExportCancellation? = nil) throws -> ExportDocument

The second decodes the bytes as the reader decodes `content.md` and throws for bytes that are not UTF-8. Both throw `CancellationError` once `cancellation` is set. `ExportBookDetails(book)` gives a `Book`'s details as the library holds them.

## The writer interface: `TextExportWriter`

    protocol TextExportWriter: Sendable {
        associatedtype Options: TextExportOptions = NoTextExportOptions
        associatedtype OptionsView: View = EmptyView
        var id: String { get }            // "brf": unique, never "markdown"
        var name: String { get }          // the Convert to picker's words: "BRF"
        var hint: String { get }          // the picker's hint while it is chosen
        var fileExtension: String { get } // "brf", no dot
        @MainActor func defaultOptions() -> Options
        @MainActor func optionsView(_ options: Binding<Options>) -> OptionsView
        func write(_ document: ExportDocument, options: Options, to url: URL,
                   cancellation: BookExportCancellation) throws
    }

- **Options.** A struct conforming to `TextExportOptions` (`Sendable`, `Hashable`). Each Export dialog starts with `defaultOptions()` (read your Braille settings there if you want the dialog to start from them). The dialog keeps the options of each writer chosen while it is open, in a `TextExportOptionsState<YourWriter>`, and hands the export a copy.
- **The options view.** `optionsView(_:)` returns your SwiftUI view, bound to the options; the dialog shows it under the Convert to picker while your writer is chosen. Every control needs a label, a hint, and a spoken value, and must be reachable by the keyboard. A writer without options leaves out `Options`, `defaultOptions()`, and `optionsView(_:)`: the protocol's defaults give none and draw nothing.
- **`write`.** Runs off the main thread, one book at a time. `url` is a new file in a scratch folder where nothing is yet; the export moves it into the chosen folder under its planned name ("<title> - Text.brf", made unique, never replacing a file) only after `write` returns. Call `try cancellation.checkCancelled()` between blocks or pages: it throws `CancellationError` once Stop is pressed, and the export removes what you wrote. For a book you cannot write, throw `TextExportError("A sentence, ending with its period.")`: the dialog says "Couldn't export <file name>: <your sentence>." and the other books still export.
- **Registration.** One line in `TextExportWriters.all` (in `TextExportWriter.swift`), where the picker's order is the array's order; Markdown, the copy of `content.md` as it is, always comes first and is not a writer. BRF and PEF go after the Word writer.

## Testing a writer

- Build an `ExportDocument` by hand, or walk Markdown with `ExportDocumentWalker.document(fromMarkdown:book:)`.
- Call `YourWriter().write(document, options: ..., to: <a sandbox URL>, cancellation: BookExportCancellation())`, then read the file back.
- A cancelled `BookExportCancellation()` (call `cancel()` first) must make `write` throw `CancellationError`.
- For the whole export path: `BookExportService.export(offers, kinds: [.markdown], conversions: [.markdown: .text(TextExportConversion(YourWriter(), options: ...))], to: folder)`.

## Not yours, and not ours

Team export does not touch liblouis, the braille readers or layout, the Braille settings tab, `BookFormat`, `XMLDocumentSniffer.swift`, `BookParser.swift`, `Info.plist`, or `project.yml`. Team braille's writers touch, of export's files, only their own new files and their lines in `TextExportWriters.all`.

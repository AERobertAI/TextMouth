# textfmt-wirewebssml: web archives and SSML files become books (FMT03 and FMT07, part 2)

Slug `textfmt-wirewebssml`, branch `textfmt/wirewebssml` from `team/textfmt`. Read `Scripts/agents/briefs/2026-10-18/textfmt/shared.md` first.

## Why

The first wave built `WebArchiveReader` (a Safari web archive's main page, read with `PropertyListSerialization`, never WebKit) and `SSMLReader` (an SSML file as simple HTML, its markup removed, never handed to the speech engine). This task makes both formats books like any other, through the HTML path every HTML book takes, so headings, lists, tables, and emphasis arrive as they do in an HTML book.

## The cases (stored raw values)

`BookFormat` is written into the library index by its raw value and decoded strictly, so add exactly these, after `case html`, and never change an existing raw value:

| Case (raw value) | `displayName` | `fileExtensions` |
| --- | --- | --- |
| `webarchive` | "Web Archive" | `["webarchive"]` |
| `ssml` | "SSML" | `["ssml"]` |

## Read first (by line range)

- `TextMouth/Models/Book.swift` lines 18-70 (`BookFormat`; never touch the `.audio` case or its doc comment).
- `TextMouth/Parsers/WebArchiveReader.swift` and `TextMouth/Parsers/SSMLReader.swift`, whole.
- `TextMouth/Parsers/BookParser.swift` (whole) and `TextMouth/Parsers/HTMLParser.swift` (whole, 48 lines).
- `TextMouth/Services/MarkdownCacheService.swift`'s `extractCache` (grep `private static func extractCache`).
- `TextMouth/Services/FileImportService.swift`: `ImportedFileMetadata.readsFile(of:)` and `read(from:format:fallbackTitle:)` (grep `struct ImportedFileMetadata`), `formatsRefusedWhenBlank` (grep it), and `supportedTypes` (grep it).
- `TextMouth/Views/Library/LibraryBookInfoLoader.swift`: grep `return .simple`.
- `TextMouth/Parsers/PlainTextParser.swift`: grep `static func markdown(text:` and `static func parse(text:`.

## What to build

1. **The cases**, as in the table.
2. **Web archive.** `BookParser.parse`: the main page (`WebArchiveReader.mainPage(of:)`), an HTML page through `HTMLParser.parse(html:title:)` and a text page through `PlainTextParser.parse(text:title:)`, titled by the file's name as an HTML book is. `MarkdownCacheService.extractCache`: an HTML page through `HTMLToMarkdownConverter.convert(_:stripDuplicateNavigation: true)`, exactly as `.html` is converted, and a text page through `PlainTextParser.markdown(text:)`, exactly as `.txt` is. Write the choice between page and text once (a small function), not in each switch.
3. **SSML.** `BookParser.parse`: `HTMLParser.parse(html: SSMLReader.html(from: url), title:)` with the file's name. `extractCache`: `HTMLToMarkdownConverter.convert(SSMLReader.html(from: url))`. Comment, at the case, that an SSML file is read as text and never handed to the speech engine as SSML (`AVSpeechUtterance(ssmlRepresentation:)` crashed on emphasis in the research), nor as text with tags.
4. **Title and author.** Neither format keeps a title or author TextMouth reads, as an HTML file keeps none: `ImportedFileMetadata.readsFile(of:)` is false for both and `read(from:format:fallbackTitle:)` reads nothing for them (they join the `.txt, .markdown, .html` cases). A web archive saved by Safari is named after its page.
5. **Blank text.** Both join `formatsRefusedWhenBlank`.
6. **Book Info.** Both give `.simple` in `LibraryBookInfoLoader`. Find any other exhaustive `switch` over `BookFormat` the compiler names, and treat both as `.html` is treated there.
7. **The Open Book panel.** `supportedTypes` adds `com.apple.webarchive` and `org.w3.ssml` (declared in `Info.plist` by another task; `UTType("org.w3.ssml")` may be dynamic until then, so append it with `if let`, as the other declared types are appended), with a comment.

About 60 lines with comments.

## Tests

A new file `TextMouthProductionTests/WebArchiveAndSSMLImportTests.swift`, class `WebArchiveAndSSMLImportTests` (run `xcodegen generate`), every import of a copy through `importedForTest`, read with `openedContent`:

1. `webarchive/headings.webarchive` imports as `.webarchive`, titled "headings" (its file name), and opens with the page's headings (pin `headingLines`: its h1 and h2s) and text, the list's items, and the table's "Departs".
2. A web archive whose main resource is text (built in the test as `WebArchiveReaderTests` builds one; move its builder into `FormatSampleFixtures.swift` if it is private, and use it from both) opens as that text; one whose main resource is an image is refused with the reader's sentence after "Could not import “…”. Reading its text failed: ", pinned whole.
3. `ssml/passage.ssml` imports as `.ssml`, titled "passage", and opens as two paragraphs of text: no `<`, `>`, `*`, or "W3C", and "World Wide Web Consortium", "9:30am", "It is not a long crossing." in it, with no heading.
4. An SSML file whose `speak` holds no words is refused: "This file has no text to read." after the import's words, pinned whole; so is an HTML-rooted file named .ssml, with the reader's sentence.
5. Both reopen from content.md as they first read: remove content.md and load with `BookContentAnalysisService.load(book:regenerateTextCache: true)`, and the text and headings are the same.
6. The raw values and display names are pinned, and a `Book` of each encodes and decodes with its format.
7. `supportedTypes` holds `com.apple.webarchive`.

Run `WebArchiveAndSSMLImportTests`, `WebArchiveReaderTests`, `SSMLReaderTests`, `BookFormatTests`, `DAISYPackageImportTests`, `ImportAndShortcutPolicyTests`, `IntegrationImportTests`, and the HTML converter's tests (`grep -l HTMLToMarkdownConverter TextMouthProductionTests/*.swift`, by class name).

## Not yours

`Info.plist` (another task), the readers themselves (post a finding to `textfmt-lead` if one is wrong), and the textutil formats.

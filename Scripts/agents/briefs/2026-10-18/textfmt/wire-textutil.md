# textfmt-wiretextutil: RTF, RTFD, .doc and .dot, ODT and OTT, and WordML become books (FMT13, part 4)

Slug `textfmt-wiretextutil`, branch `textfmt/wiretextutil` from `team/textfmt`. Read `Scripts/agents/briefs/2026-10-18/textfmt/shared.md` first.

## Why

The first wave built the pieces, each in files of its own: `TextutilConverter` (textutil under the watchdog), `TextutilHTMLStructure` (headings, lists, and pictures restored in textutil's HTML), `TextutilSourceCheck` (RTF under another name, and passwords), and `XMLDocumentSniffer` (an .xml file's kind by its root). This task makes the five textutil formats books like any other: a `BookFormat` case each, the import, the Markdown cache, the direct reader, the title and author, and the refusals, with tests of every sample through the import. The user asked for "rtf, dot, .doc" by name.

## The cases (stored raw values)

`BookFormat` is written into the library index by its raw value and decoded strictly: an older build that meets an unknown value cannot open the library (it keeps the file, quarantines a copy, and suspends index writes, so nothing is lost). So add exactly these, after `case docx`, and never change an existing raw value:

| Case (raw value) | `displayName` (Book Info says it) | `fileExtensions` |
| --- | --- | --- |
| `rtf` | "Rich Text" | `["rtf"]` |
| `rtfd` | "Rich Text with Attachments" | `["rtfd"]` |
| `doc` | "Word 97-2003 Document" | `["doc", "dot"]` (a .dot is a .doc with its template bit set, read exactly as one) |
| `odt` | "OpenDocument Text" | `["odt", "ott"]` (a template differs only by its mimetype entry) |
| `wordml` | "Word 2003 XML" | `[]`: WordML is an .xml file, known by its root element through `XMLDocumentSniffer`, never by an extension; say so in a comment |

## Read first (by line range)

- `TextMouth/Models/Book.swift` lines 18-99 (`BookFormat`; the `.audio` case and its doc comment are team audiofmt's: do not touch them).
- The four first-wave files, whole: `TextMouth/Services/TextutilConverter.swift`, `TextMouth/Parsers/TextutilHTMLStructure.swift`, `TextMouth/Parsers/TextutilSourceCheck.swift`, `TextMouth/Parsers/XMLDocumentSniffer.swift`.
- `TextMouth/Parsers/BookParser.swift` (whole, 36 lines) and `TextMouth/Parsers/DOCXParser.swift` lines 53-70 (how a document's direct reading takes its title and author).
- `TextMouth/Services/MarkdownCacheService.swift` lines 394-436 (`extractCache`).
- `TextMouth/Services/FileImportService.swift` lines 104-186 (`ImportedFileMetadata`), 763-875 (`importFileWithReport`), 885-900 (`importHash`), 1095-1104 (`folderHash`), 1220-1280 (`readableContent` and `plainTextFormats`), 1786-1803 (`md5Hash`), and 2042-2080 (`supportedTypes`).
- `TextMouth/Views/Library/LibraryBookInfoLoader.swift` lines 66-94.
- `TextMouth/Services/ImportStaging.swift` lines 160-167 (`isStagedPackageName`).
- `TextMouthProductionTests/BookFormatTests.swift` lines 1-32, and `TextMouthProductionTests/DAISYPackageImportTests.swift` lines 663-682.

## What to build

1. **The cases**, as in the table, with their `displayName`s and `fileExtensions`.
2. **Detection.** `XMLDocumentSniffer.bookFormat(ofFileAt:)` returns `.wordml` for `.wordML` (and keeps `.daisy` for a DTBook); update its comment.
3. **The reader**, a new file `TextMouth/Parsers/TextutilDocumentReader.swift`:
   - `extension TextutilInputFormat { init?(_ format: BookFormat) }`: the five cases, nil for every other format.
   - `enum TextutilDocumentReader` with `extractMarkdown(from:bookFormat:)`, `parse(url:bookFormat:)`, and `readMetadata(from:bookFormat:) -> (title: String, author: String)`. Each throws `FileImportError.unsupportedFormat(format.rawValue)` for a format that is not textutil's (it never happens; it keeps the switches free of force unwraps).
   - One private function gives textutil's HTML for a file, in this order:
     1. The format textutil is told: `.rtf` when `TextutilSourceCheck.beginsAsRTF(url)` says the content is RTF (never for an `.rtfd` folder), else the book's own.
     2. A password: for `.doc`, `isEncryptedWordDocument`; for `.odt`, `isEncryptedOpenDocument`; either throws `PasswordProtectedDocument()`.
     3. The working folder for textutil's temporary output: the folder holding the book's file when that folder is a staged package (`ImportStaging.isStagedPackageName` of its name), so an import's output is in its staging folder and goes with it should the import fail or be cancelled; otherwise a new folder `TextMouth-textutil-<UUID>` in `FileManager.default.temporaryDirectory`, removed afterwards with `defer`, so neither the library's packages (perhaps in a cloud folder) nor the folder of a file being imported ever receives one.
     4. `TextutilConverter.html(of:as:workingIn:)`.
   - `extractMarkdown`: the HTML parsed by SwiftSoup, `TextutilHTMLStructure.restore(in:)`, then `HTMLToMarkdownConverter.convert(document:readingFlow:)` with `PublicationSemantics.ReadingFlow(source: html)` and no duplicate-navigation stripping (textutil writes no navigation).
   - `parse`: as `DOCXParser.parse(url:)` does: the Markdown through `MarkdownDocParser.parse(markdown:title:)`, titled and authored from the same HTML's head (one conversion, not two), the file's name and `Book.unknownAuthor` when the head names none.
   - `readMetadata`: from the head alone: the `<title>` text and the `content` of `<meta name="Author">` (the name compared case-insensitively), each with white space collapsed and trimmed, empty when absent. Parse only the text before `</head>` (found case-insensitively), so a large document's body is never parsed for its title.
4. **The switches.** `BookParser.parse`: the five cases call `TextutilDocumentReader.parse(url:bookFormat:)`. `MarkdownCacheService.extractCache`: they call `extractMarkdown(from:bookFormat:)`, in one `case` line; both run off the main thread wherever DOCX's regeneration runs today (the import queue, startup maintenance, Redo Text Extraction, and the reader's background load); add that to the cache's doc comment. `ImportedFileMetadata.readsFile(of:)` is true for them, and `read(from:format:fallbackTitle:)` adopts `readMetadata` (with `try?`: reading metadata never fails an import). `LibraryBookInfoLoader` gives them `.simple`. Find any other exhaustive `switch` over `BookFormat` the compiler names and give each the five cases as `.docx` is treated there.
5. **Blank text.** `plainTextFormats` in `readableContent(of:run:refusingBlankText:)` becomes `formatsRefusedWhenBlank`, holding the five formats too, its comment saying why: a document whose text is only white space is refused as having no text ("This file has no text to read."), never added as a silent book.
6. **An RTFD's checksum.** `importHash(of:package:)` meets an .rtfd folder, which `md5Hash(of:)` cannot read (a `FileHandle` on a folder raises an exception, which would crash the import). For an `.rtfd` source (by `BookFormat.detect(from:)`), the checksum is `folderHash(of:in:)` of the regular files anywhere inside it (relative paths; never following a symbolic link). Check whether anything else in the import or the cache reads a book's file with a `FileHandle` or `Data(contentsOf:)` (the cache's `FileFingerprint(of:hasher:)` at `MarkdownCacheService.swift` line 141 above all): a folder must make it return nil or skip, never raise. Test each place you find.
7. **The Open Book panel.** `supportedTypes` adds `.rtf`, `.rtfd`, `com.microsoft.word.doc`, `com.microsoft.word.dot`, `org.oasis-open.opendocument.text`, `org.oasis-open.opendocument.text-template`, and `.xml` (for WordML and DTBook files, which the sniff tells apart), with one comment each line or block. Replace the comment above the .docx line that says .doc is unsupported with one saying .doc and .dot go to textutil, never to `DOCXParser`.
8. **Two existing tests describe what this task changes on purpose, by the user's request** (your lead authorizes exactly these edits, and no other edit of an existing test):
   - `BookFormatTests.testLegacyDocIsNotAdvertisedAsDOCX`: keep its point, that a .doc is never taken for DOCX, and update its facts: `BookFormat.detect(from: legacy.doc)` is `.doc`; `BookFormat.docx.fileExtensions` still lacks "doc"; `supportedTypes` now holds `com.microsoft.word.doc`. Rename it `testLegacyDocIsReadByTextutilNeverAsDOCX` and rewrite its comment to match.
   - `DAISYPackageImportTests.testOpenBookPanelOffersFilesOnly`: its point is that Return on a folder in the Open Book panel keeps opening the folder, so no type it allows is a plain folder. An RTFD is a package, which the panel shows as a single file, as it shows TextMouth's own package; so the directory types it allows become TextMouth's package and `.rtfd`. Update the assertion and the comment's sentence to say so.

About 150 lines with comments.

## Tests

A new file `TextMouthProductionTests/TextutilImportTests.swift`, class `TextutilImportTests` (run `xcodegen generate`). Every import is of a copy (`copyOfFormatSample`) through `importedForTest`, read with `openedContent`; compare `headingLines` whole, so every heading and level is pinned. Use one table-driven test per format family, the expected values beside each sample, rather than one test per sample.

1. Each sample imports as its format, titled and authored as its document says, and opens with its headings and text:
   - `rtf/headings.rtf` (`.rtf`, author "A. Sample", titled by its file name, since it names no title): headings "1: Harbour Notes", "2: Morning Tides", "2: Timetable"; the list's "Bread from the bakery on Rue Ménard" and the table's "Departs" are text, and no heading.
   - `rtf/word-styles.rtf` ("Word Styles Sample"), `rtf/word-list-table.rtf` ("List and Table"): pin their headings.
   - `rtfd/headings.rtfd` and `rtfd/with-image.rtfd` (`.rtfd`): headings as the RTF's; with-image holds "After the picture" and no "Attachment"; the package holds the .rtfd folder whole.
   - `doc/headings.doc`, `dot/headings-synthetic.dot`, `dot/libreoffice-tdf120761_zOrder.dot` ("Blah blah blah") (`.doc`): the bullet list's items read without "•".
   - `doc/libreoffice-tdf104239_chapterNumbering.doc`: "1: Heading 1" to "4: Heading 4", then "5: Heading 5" and "5: Heading 6".
   - `doc/libreoffice-tdf81705_outlineLevel.doc`: imports; pin what it shows.
   - `odt/handwritten.odt` (title "Harbour Notes"), `odt/headings.odt`, `ott/handwritten.ott` (`.odt`).
   - `wordml/headings.wordml` copied as `headings.xml` (`.wordml`): pin its headings (its table comes back flattened, so its bold header cells may read as headings: pin what the reader shows, and say so in a comment).
2. `rtf/headings.rtf` copied as `notes.doc` imports as `.doc` and reads as the RTF does.
3. Refusals, each sentence pinned whole as the listener hears it ("Could not import “…”. Reading its text failed: …"): a copy of `doc/headings.doc` with the FIB's `fEncrypted` bit set (find the FIB as `TextutilSourceCheck` does); a copy of `odt/handwritten.odt` with an encryption-data manifest (reuse the helper `TextutilSourceCheckTests` has, moved into `FormatSampleFixtures.swift` if it is private); random bytes named `.doc`; an empty `.rtf`; an RTF holding only white space (`{\rtf1\ansi \par \par }`); and an RTF past a bound `DocumentByteLimit.$current`. After each, nothing is left in the library, and no `.textutil.html` file is left in `MachineLocalPaths.importStaging` or `FileManager.default.temporaryDirectory`.
4. A successful import leaves no `.textutil.html` file in its package, and no `TextMouth-textutil-` folder in the temporary directory.
5. Regeneration: for an imported RTF and an imported RTFD, remove content.md and load with `BookContentAnalysisService.load(book:regenerateTextCache: true)`: the same headings, and nothing left behind in the package or the temporary directory.
6. The raw values are pinned (`BookFormat(rawValue: "rtf") == .rtf`, and the four others), and so are the five `displayName`s; a `Book` of each new format encodes and decodes through `JSONEncoder`/`JSONDecoder` with its format.
7. `importHash(of:)` of an .rtfd copy is stable, changes when its TXT.rtf changes, and never throws.

Run `TextutilImportTests`, `TextutilConverterTests`, `TextutilHTMLStructureTests`, `TextutilSourceCheckTests`, `XMLDocumentSnifferTests`, `DTBookImportTests`, `BookFormatTests`, `DAISYPackageImportTests`, `ImportAndShortcutPolicyTests`, `IntegrationImportTests`, `ImportStagingTests`, `StagedImportTests`, `DOCXStructureTests`, `LogContentPolicyTests`, and `UncheckedConcurrencyPolicyTests`.

## Not yours

`Info.plist` (another task adds every document type), folder and ZIP discovery of an .rtfd (another task), web archives and SSML (another task), and the readers themselves (if one is wrong, post a finding to `textfmt-lead` with the file and line, and wait).

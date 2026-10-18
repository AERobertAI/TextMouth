# textfmt-dtbook: a DTBook file on its own, NIMAS, and the .xml sniff (FMT04, with FMT13's sniff)

Slug `textfmt-dtbook`, branch `textfmt/dtbook` from `team/textfmt`. Read `Scripts/agents/briefs/2026-10-18/textfmt/shared.md` first.

## Why

The DAISY reader already reads DTBook (DAISY 3's XML text) inside a DAISY 3 package, and finds a DTBook in a ZIP or folder without an OPF. What fails is a DTBook file on its own: an .xml file, which `BookFormat` does not list. NIMAS packages (a DTBook, an OPF, and images, which reach students through their schools and Bookshare) should import today as DAISY folders, but no test shows it. And WordML, Word 2003's single-file XML, is an .xml file too, which a later task hands to textutil. So one function reads the start of an .xml file and names its kind by its root element, never by the extension alone: DTBook goes to the DAISY reader, WordML to textutil (later), and any other XML is refused by name.

## Read first (by line range)

- `TextMouth/Models/Book.swift` lines 72-98 (`BookFormat.detect(from:)`).
- `TextMouth/Parsers/DAISYParser.swift` lines 53-75 (`DAISYFileProvider`), 204-262 (`DirectoryFileProvider`), 273-335 (the public API), 362-405 (`makeFileProvider(from:)`), 409-440 (`detectVersion`), 441-460 and 523-551 (the OPF-less DTBook path, `findDTBookXML`, and `readDAISY3Metadata`).
- `TextMouth/Parsers/DAISYParser+SAXParser.swift` (whole, 23 lines) and `DAISYParser+OPFParser.swift` lines 20-83: the SAX pattern.
- `TextMouth/Parsers/DAISYParser+PackageInventory.swift` lines 20-50 and 215-230 (`isPackageEntryFile`, `ofSource`): a loose .xml file is not a package, so it imports as one file, as it should.
- `TextMouth/Services/FileImportService.swift` lines 1-45 (`FileImportError`) and 950-967 (`unsupportedSourceError(for:)`).
- The samples `dtbook/harbour-standalone.xml` and `dtbook/nimas-style-package/` (an OPF listing `harbour-dtbook.xml` as `application/x-dtbook+xml`, and a `pier.png` that is not there).

## What to build

1. **The sniff.** A new file `TextMouth/Parsers/XMLDocumentSniffer.swift`:
   - `enum XMLRootKind: Equatable, Sendable { case dtbook, wordML, other }`.
   - `enum XMLDocumentSniffer` with `static let scanLength = 65_536`, `static func rootKind(ofFileAt url: URL) -> XMLRootKind` (reads at most `scanLength` bytes with a `FileHandle`; a missing file, a folder, or an unreadable one is `.other`), and `static func rootKind(of prefix: Data) -> XMLRootKind`.
   - An `XMLParser` over the prefix with `shouldProcessNamespaces = true` and `shouldResolveExternalEntities = false`, whose delegate records the first element's local name and namespace URI and calls `abortParsing()`. The prolog (XML declaration, processing instructions, comments, a DOCTYPE naming a DTD by URL) is passed over and the DTD never fetched. Its parse error after the abort, or a cut-off prefix, does not matter once the first element is known.
   - `.dtbook` for the local name `dtbook`, in any namespace or none. `.wordML` for the local name `wordDocument` in the namespace `http://schemas.microsoft.com/office/word/2003/wordml`. `.other` for anything else, for no element, and for bytes that are not XML.
   - `static func bookFormat(ofFileAt url: URL) -> BookFormat?`: `.daisy` for a DTBook, nil otherwise. A later task makes WordML `.wordml` here; say so in its comment.
2. **Detection.** In `BookFormat.detect(from:)`, right after the ncc.html check: an .xml file (extension compared lowercased) returns `XMLDocumentSniffer.bookFormat(ofFileAt: url)`, with a comment saying a loose XML file is read by what its root element says it is (FMT04, FMT13), never by its extension alone.
3. **Other XML is refused by name.** A new `FileImportError` case, `.unsupportedXML`, with the sentence "This XML file is neither a DTBook book nor a Word 2003 XML document, the kinds of XML file TextMouth reads." `unsupportedSourceError(for:)` returns it for an .xml source that is not a folder. Comment it as the cases around it are commented.
4. **A one-file provider.** In `DAISYParser.swift`, after `DirectoryFileProvider`: `final class SingleFileProvider: DAISYFileProvider` for one DTBook file. `listFiles()` is its name alone; `readFile(at:)` reads it through `DocumentByteLimit.contents(of:)` and throws `DAISYParserError.missingContent` for any other path, so nothing beside the file is ever read; `copyFile(at:to:)` likewise. In `makeFileProvider(from:)`, a file (not a folder) with the .xml extension whose `XMLDocumentSniffer.rootKind(ofFileAt:)` is `.dtbook` gets one, before the ZIP fallback. The existing OPF-less path (`detectVersion`, then `extractDAISY3Markdown` without an OPF) then reads it unchanged.
5. **A loose DTBook's title and author.** `readDAISY3Metadata(from:)` returns nil today without an OPF. Without one, it reads the DTBook that `findDTBookXML` finds, with a new `DAISYSAXParser` subclass (in a new file `TextMouth/Parsers/DAISYParser+DTBookHeadParser.swift`): the title is the first `meta` in `head` whose `name` is `dc:Title` (compared case-insensitively) with its `content`, else the text of the first `doctitle`; the author is the first `meta` named `dc:Creator`, else the first `docauthor`'s text; white space collapsed and trimmed; empty when absent. A damaged DTBook makes the metadata nil (the import then names the book by its file), never a failed import here: the text extraction reports damage in its own words.

About 140 lines with comments.

## Tests

New file `TextMouthProductionTests/XMLDocumentSnifferTests.swift` (class `XMLDocumentSnifferTests`) and `TextMouthProductionTests/DTBookImportTests.swift` (class `DTBookImportTests`); run `xcodegen generate`.

Sniffer, on byte strings:
1. A DTBook with an XML declaration, a comment, a processing instruction, and a DOCTYPE naming an http DTD is `.dtbook`; with a namespace and without one.
2. The start of the WordML sample (a copy, read as bytes) is `.wordML`; a `wordDocument` root in another namespace, an `html` root, a `catalog` root, garbage bytes, and empty data are `.other`.
3. A root element that begins only after `scanLength` bytes of comment is `.other` (documented as the limit).
4. `bookFormat(ofFileAt:)` is `.daisy` for the DTBook sample's copy and nil for the WordML sample copied as `notes.xml`; `BookFormat.detect(from:)` agrees for both and for a copy of the DTBook sample named `BOOK.XML`.

Import, through `importedForTest`, from copies:
5. `dtbook/harbour-standalone.xml` imports as `.daisy`, titled "Harbour Notes" by "A. Sample"; the reader (`openedContent`) shows the headings Preface, The Ferry, Morning Tides, Timetable, and The Return (pin the exact `headingLines` the reader gives, with their levels) and the words "Café tables", "Arrive early for a window seat", and the table's "Departs"; the package holds the .xml file and its content.md.
6. The same DTBook with its `dc:Title` meta removed is titled by its `doctitle`; with both removed, by its file name.
7. `dtbook/nimas-style-package/` (the folder) and its `harbour-nimas.opf` each import as `.daisy` titled "Harbour Notes (NIMAS-style sample)" by "A. Sample", with the same headings, although `pier.png` is missing.
8. An .xml file whose root is `catalog` is refused: the import throws, and its `localizedDescription` is pinned word for word (it begins "Could not import “catalog.xml”. "), and nothing is left in the library.
9. A DTBook past a bound `DocumentByteLimit.$current` is refused with the limit's sentence, and a truncated copy of the sample with the DAISY reader's damage sentence (pin what it says).

Run `XMLDocumentSnifferTests`, `DTBookImportTests`, `DAISYPackageImportTests`, `DAISYMalformedXMLTests`, `DAISYPackageInventoryTests`, `BookFormatTests`, `ZIPImportTests`, and `ImportAndShortcutPolicyTests`.

## Not yours

No WordML wiring (another task adds `.wordml`), no `Info.plist` or Open panel change (another task adds the .xml document type), and no change to `DTBookToMarkdownConverter`. Do not touch the `fileExtensions` lines of `BookFormat` (another task edits the `.docx` line at the same time).

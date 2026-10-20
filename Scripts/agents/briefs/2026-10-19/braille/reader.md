# Task `reader`: read BRF, BRL, and PEF files into pages of braille (FMT20)

- **Slug:** `braille-reader`. **Branch:** `braille/reader`, made with `git checkout -b braille/reader team/braille`.
- Read `Scripts/agents/briefs/2026-10-19/braille/common.md` first.
- **Files (yours alone):** new `TextMouth/Parsers/BrailleFileReader.swift`; new `TextMouthProductionTests/BrailleFileReaderTests.swift`; the regenerated `TextMouth.xcodeproj/project.pbxproj`.
- **Read first:** `TextMouth/Parsers/BrailleCells.swift` (all); `TextMouth/Parsers/DocumentByteLimit.swift` lines 30 to 68 (`contents(of:)` and `DocumentTooLargeError`); `TextMouth/Parsers/XMLDocumentSniffer.swift` lines 74 to 124 (how an `XMLParser` is set up safely, and a delegate class); `TextMouth/Services/FileImportService.swift` lines 40 to 50 (`FileImportError.noTextToRead`'s sentence).
- **Not yours:** the page layout (headings, paragraphs, page numbers) is task `pages`; `BookFormat`, `XMLDocumentSniffer`, and the import are task `import`. Touch none of them.

## What to build
This reader turns a file's bytes into pages of rows of Unicode braille, and nothing more: no layout is interpreted here.

1. **The result type**, in `BrailleFileReader.swift`:
   ```swift
   /// The kinds of braille file TextMouth reads (FMT20).
   enum BrailleFileKind: Equatable, Sendable {
       case brf   // braille ASCII in finished pages
       case brl   // braille ASCII, unformatted
       case pef   // Portable Embosser Format: XML of Unicode braille rows
   }

   /// A braille file's pages, before their layout is read (FMT20).
   struct BrailleFilePages: Equatable, Sendable {
       var kind: BrailleFileKind
       /// Each page's rows, top to bottom; a row is its cells as the file
       /// wrote them, blank cells (U+2800) included, trailing ones too.
       var pages: [[String]]
       /// A PEF's dc:title, dc:creator, and dc:language; nil for BRF and
       /// BRL, and for a PEF that names none.
       var title: String? = nil
       var author: String? = nil
       var language: String? = nil
   }
   ```
2. **`BrailleFileReader.read(_ url: URL, as kind: BrailleFileKind) throws -> BrailleFilePages`** reads the file's bytes with `DocumentByteLimit.contents(of:)` (which refuses an empty file with `FileImportError.noTextToRead` and one past 64 MB with `DocumentTooLargeError`), then calls one of the two functions below by kind.
3. **`BrailleFileReader.pages(fromASCII data: Data, kind: BrailleFileKind) throws -> BrailleFilePages`**, for `.brf` and `.brl`:
   1. A last byte 0x1A (Ctrl-Z, an old DOS end-of-file mark) is dropped. A 0x1A anywhere else is refused as below.
   2. Allowed bytes: 0x20 to 0x7E, each converted with `BrailleCells.cell(forASCII:)` (which reads 0x60 to 0x7E as 0x40 to 0x5E: lowercase as uppercase); a tab (0x09), which is one blank cell; CR (0x0D), LF (0x0A), and form feed (0x0C).
   3. Lines end at CR LF, at a lone LF, or at a lone CR. The text after the last line end is a line only if it is not empty.
   4. **BRF pages:** a form feed ends a page; the line it interrupts (form feed with no line end before it) ends there too. A form feed at the very end of the file adds no empty page after it. Two form feeds in a row make an empty page (kept: a blank braille page is still a page). A file with no form feed at all is cut into pages of 25 lines, the last page holding what is left.
   5. **BRL:** form feeds are ignored (as page breaks and as characters), and the whole file is one page holding every line.
   6. **Any other byte is refused** with `BrailleFileError.notBrailleASCII(_, line:)`, naming the first such character and its line. Lines are numbered from 1 by line ends (CR LF, LF, or lone CR, each counted once); a form feed does not start a line. The character is found by decoding the line from the bad byte on as UTF-8: a valid character is named as itself, a control character (Unicode general category Cc) by its code, and a byte that begins no valid UTF-8 character by its value (see item 6's sentences).
   7. A file whose bytes are all allowed but that holds no line at all (only form feeds, say) gives zero pages; the caller refuses it as empty.
4. **`BrailleFileReader.pages(fromPEF data: Data) throws -> BrailleFilePages`**, with `XMLParser`:
   1. `shouldProcessNamespaces = true`, `shouldResolveExternalEntities = false`; a delegate class collects what is below. The parse must end without error (`parse()` returns true), else `BrailleFileError.damagedPEF`.
   2. The root element must be `pef` in the namespace `http://www.daisy.org/ns/2008/pef`, else `damagedPEF`.
   3. **Metadata:** inside `head` > `meta`, the first `title`, `creator`, and `language` in the Dublin Core namespace `http://purl.org/dc/elements/1.1/`, each with its surrounding white space trimmed and nil when that leaves nothing. Ignore every other element there.
   4. **Pages:** every `page` element in the PEF namespace, in document order, across all volumes and sections, is a page; every `row` inside it is a row, in order. A `row` outside a `page` is `damagedPEF`.
   5. **Rows** hold only Unicode braille patterns. White space characters (space, tab, CR, LF) inside a row are ignored. A pattern from U+2840 to U+28FF (dots 7 or 8) is refused with `BrailleFileError.eightDotBraille`. Any other character is `damagedPEF`. An empty `<row/>` is the row "".
   6. A PEF with no `page` gives zero pages; the caller refuses it as empty.
5. **`BrailleFileReader.pefMetadata(of url: URL) -> (title: String?, author: String?, language: String?)`** reads only the metadata, for the import's title and author: it parses the file's first 65,536 bytes with the same delegate and aborts the parse at the end of `head` (an error after the metadata is read is then moot, as in `XMLDocumentSniffer.rootKind(of:)`). It never throws; a file that cannot be read gives three nils.
6. **The refusals**, an `enum BrailleFileError: LocalizedError, Equatable`. Each sentence is read to the listener after the import's own ("Could not import “book.brf”. Reading its text failed: "), so none names the file. Exactly these words:
   - `notBrailleASCII`, for a printable character, such as é on line 12: `Line 12 holds “é”, which is not braille ASCII.`
   - for a control character, such as U+0007: `Line 12 holds the control character U+0007, which is not braille ASCII.` (the code as `U+` and four or more uppercase hexadecimal digits)
   - for a byte that is not valid UTF-8, such as 0xE9: `Line 12 holds the byte 0xE9, which is not braille ASCII.`
   - `damagedPEF`: `This file could not be read as a PEF braille file. It may be damaged, or another kind of file.`
   - `eightDotBraille`: `This file is eight-dot braille, which TextMouth does not read.`
   Model the first three as one case holding the line and an enum of what was found (`.character(Character)`, `.controlCharacter(UInt32)`, `.byte(UInt8)`), so each sentence is made in one place.

## Tests (`BrailleFileReaderTests`)
Each one pins a behaviour above; name them as sentences, as the other test files do.
1. The BRF sample gives 2 pages of 25 rows; its first row is `BrailleCells.spaced`-equal to `"         ⠠⠏⠗⠊⠙⠑ ⠁⠝⠙ ⠠⠏⠗⠑⠚⠥⠙⠊⠉⠑"` (nine blank cells first), row 25 of page 1 is 38 blank cells then `⠼⠁`, and every row of both pages equals, cell for cell, the PEF sample's row at the same place (read with `pages(fromPEF:)`). Kind `.brf`, no title.
2. The PEF sample gives the same 2 pages of 25 rows, with title `Pride and Prejudice, Chapter I (Grade 1 UEB sample)`, author `Jane Austen`, language `en`; `pefMetadata(of:)` gives the same three.
3. The BRL sample gives one page of 14 rows, row 1 being `,PRIDE AND ,PREJUDICE` converted.
4. The Grade 2 sample: one page of 25 rows, row 1 `⠠⠮ ⠃⠕⠽ ⠯ ⠛⠊⠗⠇ ⠉ ⠛ ⠾ ⠽⠲` (spaced).
5. Line ends: the same text with LF, with lone CR, and with CR LF gives the same rows; text after the last line end is a row; a final line end adds no empty row.
6. Pages: a file with no form feed and 60 lines gives pages of 25, 25, and 10 rows; a form feed after a line's end, one in mid-line, one at the very end, and two in a row each do as item 3.4 says; a BRL with form feeds is one page.
7. Lowercase: `,pride` reads as `,PRIDE`; a tab is one blank cell; a final Ctrl-Z is dropped, and a Ctrl-Z elsewhere is refused on its line.
8. Each refusal sentence, exactly, through `errorDescription`: é on line 3 (as UTF-8 bytes), U+0007 on line 1, the byte 0xE9 on line 2 (a lone Latin-1 byte), and a refusal on line 4 after a mix of CR LF and lone CR line ends (so lines are counted as item 3.6 says).
9. PEF refusals: not XML at all, a root of another name or namespace, a row outside a page, a row holding a letter: each `damagedPEF`; a row holding U+2841: `eightDotBraille`. White space inside a row is ignored. Two volumes with a section each give their pages in order.
10. `read(_:as:)` on an empty copy throws `FileImportError.noTextToRead`; under `DocumentByteLimit.$current.withValue(10)` a longer file throws `DocumentTooLargeError`.

Run `BrailleFileReaderTests` and `BrailleCellsTests`.

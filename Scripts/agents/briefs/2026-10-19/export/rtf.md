# Task `rtf` (team export, October 19, 2026): RTF with outline levels, and Word 97-2003

Worker `export-rtf`, branch `export/rtf` from `team/export`. FMT19. You write two text writers that read the `ExportDocument` model: RTF written by TextMouth, with a style sheet whose headings carry real outline levels (Apple's own RTF writer drops them, which is why TextMouth writes its own), and Word 97-2003 (.doc) through Apple's `.docFormat` writer. Two commits: the RTF writer with its tests, then the Word writer with its tests.

## Read first (only these)
- `TextMouth/Services/Export/ExportDocument.swift` (whole, about 330 lines): the model you read.
- `TextMouth/Services/Export/TextExportWriter.swift` (whole, about 250 lines): the protocol, `TextExportError`, and `TextExportWriters.all`.
- `TextMouth/Services/Export/HTMLExportWriter.swift` (whole): the first writer, already merged; follow its shape (a static function making the text, `write` putting it in the file).
- `TestData/format-samples/rtf/word-styles.rtf` (25 lines): the form Word writes, which yours follows.
- `TextMouth/Parsers/TextutilHTMLStructure.swift` lines 234 to 284: how TextMouth's own reader finds headings in RTF (larger sizes ranked, largest first, as levels 1, 2, 3; bold text at the body's size takes the next level), which your sizes must suit.

## Commit 1: `TextMouth/Services/Export/RTFExportWriter.swift` (new)
`struct RTFExportWriter: TextExportWriter`: `id` "rtf", `name` "RTF", `fileExtension` "rtf", `hint` exactly "Rich text, with each heading at its outline level, for Word, Pages, and TextEdit.", no options. `static func rtf(of document: ExportDocument, cancellation: BookExportCancellation? = nil) throws -> String` makes the text, calling `try cancellation?.checkCancelled()` before each top-level block; `write` writes it as UTF-8 (it is all ASCII) with `.withoutOverwriting`. Add `RTFExportWriter(),` to `TextExportWriters.all` right after `HTMLExportWriter(),`.

### The text, exactly
Each line below ends with a line feed (RTF ignores them; they keep the file readable).

    {\rtf1\ansi\ansicpg1252\deff0\uc1
    {\fonttbl{\f0\fswiss\fcharset0 Helvetica;}{\f1\fmodern\fcharset0 Courier New;}}
    {\stylesheet
    {\s0\sa120\f0\fs24 Normal;}
    {\s1\sb240\sa120\keepn\outlinelevel0\b\f0\fs44\sbasedon0\snext0 heading 1;}
    … one line per level N from 1 to 6: \sN, \outlinelevel(N-1), sizes \fs44, \fs38, \fs34, \fs30, \fs28, \fs26 …
    }
    {\info{\title TITLE}[{\author AUTHOR}]}
    PARAGRAPHS
    }

- **Sizes.** Body 12 pt (`\fs24`); headings 22, 19, 17, 15, 14, and 13 pt, all bold: each larger than the body and than the next level, so a reader that ignores styles (textutil, and TextMouth's own reader) still ranks them as levels 1 to 6. Keep the sizes in one table both the style sheet and the paragraphs read (DRY).
- **Paragraph forms** (`INDENT` is the indent in twips from quotes and lists, written as `\liN` only when not 0):
  - heading of level N: `\pard\plain\sN\sb240\sa120\keepn\outlinelevel(N-1)\b\f0\fsSIZE RUNS\par`;
  - paragraph: `\pard\plain\s0\sa120[\liINDENT]\f0\fs24 RUNS\par`;
  - list item: `\pard\plain\s0\sa60\liINDENT\fi-360\f0\fs24 MARK\tab RUNS\par`, where INDENT is 360 times (the list's `depth` + 1) plus the quotes' indent, and MARK is `\u8226?` (•) for an unordered list or "N." for an ordered one, N being `start` plus the item's place; the item's first block, when a paragraph, gives RUNS; its other paragraphs follow as `\pard\plain\s0\sa60\liINDENT\f0\fs24 RUNS\par`; a list inside it follows at its own depth; an item that does not begin with a paragraph writes MARK and `\tab` alone and then its blocks;
  - block quote: its blocks with 720 more twips of indent;
  - code block: `\pard\plain\s0\sa120[\liINDENT]\f1\fs24 CODE\par`, its line feeds as `\line `;
  - thematic break: `\pard\plain\s0\sa120\brdrb\brdrs\brdrw10\brsp20\f0\fs24\par`;
  - table: for each row, `\trowd\trgaph108\trleftINDENT[\trhdr]\cellxW1\cellxW2…` then, for each cell, `\pard\plain\intbl\s0\f0\fs24 TEXT\cell` (the header row's text as `{\b TEXT}`), then `\row`. The columns are the most cells any row has; each is (9360 minus INDENT) divided by the columns, at least 1, and `\cellx` counts from INDENT. A table of more than 63 columns (Word's limit) is written instead as one paragraph per row, its cells apart by `\tab `.
  - The title heading, when `document.titleHeading` is not nil, is the first paragraph, a heading of level 1.
- **Runs.** A plain run is its escaped text; any other is a group `{` + `\b` (strong) + `\i` (emphasis) + `\f1` (code), a space, its escaped text, `}`. A run of a link that may be a link (check `ExportRun.isAllowedLinkAddress` again) is inside `{\field{\*\fldinst{HYPERLINK "ADDRESS"}}{\fldrslt{\ul RUNS}}}`, neighbouring runs of one link sharing one field; ADDRESS is escaped as text and its `"` written as `%22`.
- **Escaping** (one function, used for every text, the title and author too), scalar by scalar: `\`, `{`, and `}` with a backslash before them; a line feed as `\line `; a tab as `\tab `; other characters below U+0020, and U+007F, left out; U+0020 to U+007E as they are; every character above as `\uN?`, once for each of its UTF-16 code units, with N the unit when it is at most 32767 and the unit minus 65536 when above (RTF's signed 16-bit numbers). So "é" is `\u233?`, "€" `\u8364?`, "가" (U+AC00) `\u-21504?`, and "😀" `\u-10179?\u-8704?`.
- Comment every function and non-obvious block.

### Tests: `TextMouthProductionTests/RTFExportWriterTests.swift` (new; `xcodegen generate`, commit `project.pbxproj`)
1. The exact RTF for a fixture with an author, a title heading, headings of levels 1 to 3, a paragraph with every style, a link, "Café €5 가 😀", and a backslash and braces, a list holding a numbered list starting at 3, a quote, a code block of two lines, a thematic break, and a table with a header row: pin the whole string.
2. The escaping rules one by one, the four examples above included.
3. **Read back by Apple's reader:** `NSAttributedString(data:options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)` of the fixture: its string, split on white space, equals the fixture's words (every block's plain text, with "•" or "N." before each list item's words, split the same way); and for a document of one heading and one paragraph, pin its exact string (expected "HEADING\nPARAGRAPH\n"; if Apple's reader gives otherwise, pin what it gives and say so in your report).
4. **A round trip through TextMouth's own reader:** write a fixture with headings of levels 1, 2, and 3 (twice each, in the order 1, 2, 3, 2, 3, 1) and a body paragraph of at least 30 words after each, to a sandbox file "Round Trip.rtf" (`makeSandboxDirectory`), read it with `TextutilDocumentReader.parse(url:bookFormat: .rtf)` (the textutil child process, as `TextutilImportTests` runs it), and `headingLines(of:)` (in `FormatSampleFixtures.swift`) must be exactly the fixture's headings as "level: text".
5. The style sheet and the heading paragraphs carry `\sN` and `\outlinelevel(N-1)` for each level.
6. A link to `https://example.com/a"b` is a HYPERLINK field with `%22`; a `javascript:` link given by hand is plain text.
7. A table of 64 columns is written as paragraphs with `\tab `, not as `\trowd`.
8. `write`: a second write to the same URL throws and keeps the first file; a cancelled `BookExportCancellation` makes `write` throw `CancellationError` and writes no file.
9. The writer's `id`, `name`, `hint`, and `fileExtension` exactly.

## Commit 2: `TextMouth/Services/Export/WordDocExportWriter.swift` (new)
`struct WordDocExportWriter: TextExportWriter`: `id` "doc", `name` "Word 97-2003 (.doc)", `fileExtension` "doc", `hint` exactly "Word 97-2003 document. Its headings are plain text, so Word's navigation pane does not list them.", no options. Add `WordDocExportWriter(),` to `TextExportWriters.all` right after `RTFExportWriter(),`.
- Its comment says why: Word's binary format is not written by TextMouth (unwise to write ourselves); Apple's `.docFormat` writer is used, and it writes headings as larger bold text with no heading style.
- `write`: the attributed string Apple's RTF reader makes of `RTFExportWriter.rtf(of:cancellation:)` (so the two writers can never differ in how a book looks; the walker's document is its only source), checked for Stop, then `data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.docFormat, .title: …, .author: …])` (the author only when there is one), written with `.withoutOverwriting`. Apple's RTF reader and `.docFormat` writer need no main thread (only its HTML reader does).
- An error from Apple's reader or writer becomes `TextExportError("The book's text could not be made into a Word 97-2003 document.")`; a `CancellationError` passes through as it is.

### Tests: in `RTFExportWriterTests.swift`, a `// MARK: - Word 97-2003` part
10. The file begins with the bytes D0 CF 11 E0 A1 B1 1A E1 (the compound file of Word 97-2003).
11. Read back with `NSAttributedString` (`.docFormat`): its string equals, exactly, the string Apple's RTF reader gives for the same document's RTF.
12. `write`: no overwrite; cancelled before the call throws `CancellationError` with no file.
13. The writer's `id`, `name`, `hint`, and `fileExtension` exactly; `TextExportWriters.all.map(\.id)` is `["html", "rtf", "doc"]`.

## Build and test
Through `python3 Scripts/test/run-area.py RTFExportWriterTests HTMLExportWriterTests` (read `-h` first), with your own build folder as `teams-common.md` says.

## Do not touch
`ExportDocument.swift`, `TextExportWriter.swift` beyond your two lines, `HTMLExportWriter.swift`, `XMLEscaping.swift`, `ExportDocumentWalker.swift`, any `BookExport*` file, the parsers, or any `*.md` file. If the model seems to need a change, stop and ask `export-lead` on the board.

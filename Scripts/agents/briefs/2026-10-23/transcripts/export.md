# Brief: `transcripts-export`, exported Markdown escapes only what Markdown needs (T3)

Worker slug `transcripts-export`, branch `transcripts/export` (`git checkout -b transcripts/export team/transcripts`), lead `transcripts-lead`. Follow "The worker's part" of `Scripts/agents/briefs/2026-10-19/teams-common.md`. Three commits, as below.

## Why
The user, October 23: "when exporting every , and . character seems to be escaped in the markdown, not sure if thats entensional". The source: every writer of content.md escapes every ASCII punctuation character (`MarkdownLiteral.escaped`, `TextMouth/Parsers/MarkdownLiteral.swift`), the transcript's text builder included (`TranscriptTextBuilder.markdown(of:)`, lines 240-252), and Export copies content.md as it is, both for a text book's "Text as Markdown" (`BookExportService.offer`, the `.markdown` item, "Title - Text.md") and for a transcribed audiobook's "Transcript" (`transcriptItem`, "Title - Transcript.md"). content.md must stay as it is (changing how a text book's content.md is written is a cache-format change that re-reads the whole library). So the export writes the Markdown afresh, through the walk every other text writer already reads (`ExportDocumentWalker` into `ExportDocument`), escaping only what Markdown needs.

## Read first (by line range)
- `TextMouth/Parsers/MarkdownLiteral.swift` (all, 100 lines) and `TextMouth/Parsers/MarkdownEmphasis.swift` (all, 110 lines).
- `TextMouth/Services/Export/ExportDocument.swift` 1-60 and 105-326; `ExportDocumentWalker.swift` 20-60 and 280-399.
- `TextMouth/Services/Export/TextExportWriter.swift` 20-160 and 210-250; `HTMLExportWriter.swift` 1-80 (a writer to model yours on).
- `TextMouth/Services/BookExportService.swift` 36-75, 186-250, 280-370, 715-760 (`files(of:for:conversions:)`), 830-880.
- `TextMouth/Models/BookExportWording.swift` 1-60.

## Commit 1: escaping only what Markdown needs
In `MarkdownLiteral`, two new functions, each with a doc comment that states its rules, beside `escaped` (which stays exactly as it is, for content.md):

1. `static func minimallyEscaped(_ text: String, smartPunctuation: Bool = false) -> String` escapes one piece of one line (no line feed; the caller splits lines) so that a CommonMark reader with GitHub's tables, strikethrough, and task lists reads it back as exactly its characters, wherever in a line it stands. Escape with a backslash:
   - always: `` ` ``, `*`, `[`, `]`, `|`, `~`;
   - `_`, unless the characters on both sides of it in the piece are letters, digits, or marks (`isFlankingSafe`): an underscore inside a word never makes emphasis;
   - `\`, when the next character in the piece is ASCII punctuation, or it ends the piece;
   - `<`, when the next character is an ASCII letter, `/`, `!`, or `?`, or it ends the piece (raw HTML and autolinks);
   - `&`, when what follows it is a character reference's body: `#` and 1-7 digits and `;`, `#x` or `#X` and 1-6 hex digits and `;`, or an ASCII letter, then ASCII letters or digits, and `;` ("AT&T" and "Q&A" stay as they are, "&amp;" becomes "\&amp;");
   - `#`, when it is the first `#` of a run of `#` that ends the piece (with only spaces or tabs after it) and has a space or tab, or nothing, before it: an ATX heading's closing sequence ("Issue #" becomes "Issue \#"; "C#" and "#378" stay);
   - with `smartPunctuation` (TextMouth's own reader, which substitutes curly quotes, dashes, and ellipses): also `"` and `'` always, and `-` or `.` when the character before or after it in the piece is the same character, or it is at either end of the piece.
   - U+FEFF is written as `&#xFEFF;`, as `escaped` writes it.
   Nothing else is escaped: never `,` `.` `:` `;` `?` `!` `(` `)` `/` `%` `$` `@` `^` `{` `}` `=` `+` `-` `>` `'` `"` mid-line (quotes and dashes aside under `smartPunctuation`).
2. `static func guardingLineStart(_ line: String) -> String` takes a line already written (from pieces `minimallyEscaped` wrote, and emphasis or link syntax) and adds the one backslash its start needs so that it cannot begin a block: before a leading `#` run of 1-6 followed by a space, a tab, or the end; before a leading `-` or `+` followed by a space, a tab, or the end; before a leading `-` or `=` when the whole line is that character with spaces or tabs; before a leading `>`; and before the `.` or `)` that follows 1-9 leading digits when a space, a tab, or the end comes after it ("2019. That" becomes "2019\. That"; "1.5 million" stays). A line that begins with spaces is the caller's concern, as for `escaped`.

## Commit 2: the Markdown writer
3. New file `TextMouth/Services/Export/MarkdownExportWriter.swift`: `struct MarkdownExportWriter: TextExportWriter` (no options), `id` `"md"`, `name` `"Markdown"`, `hint` `BookExportWording.markdownChoiceHint`, `fileExtension` `"md"`. It is not in `TextExportWriters.all` (the picker lists Markdown first, by `TextExportWriters.markdownID`). Also `static func markdown(of document: ExportDocument, cancellation: BookExportCancellation? = nil) throws -> String`, which `write` calls and tests use; `write` writes its UTF-8 bytes to `url` with `.withoutOverwriting`. It checks cancellation before each top-level block. It never writes `titleHeading` (the export is the book's text as content.md holds it).
4. What it writes, blocks apart by one blank line, the file ending in one line feed (an empty document is an empty file):
   - heading: `#` times its level, a space, its runs (a line feed in a heading becomes a space); no `guardingLineStart`.
   - paragraph: its runs; a line feed in a run is a hard break, written as `\` and a line feed; every line of the paragraph goes through `guardingLineStart`.
   - runs: plain and emphasised text through `MarkdownEmphasis` with `minimallyEscaped` as its literal writer: give `MarkdownEmphasis.markdown` a `literal: (String) -> String` parameter whose default is `MarkdownLiteral.escaped`, so every existing caller writes byte for byte what it writes today. A code run is a code span: a backtick string one longer than the longest run of backticks in it, padded with one space on each side when the code begins or ends with a backtick, or begins and ends with a space and is not all spaces; line feeds in it become spaces; its emphasis is not written. Consecutive runs with the same `link` are one link: `[`, their Markdown, `](<`, the address with `\`, `<`, and `>` backslash-escaped, `>)`.
   - list: unordered items begin `- `; ordered items begin with their number, `.`, and a space, numbering from `start` (kept within 0 to 999,999,999, as CommonMark reads at most nine digits). An item's blocks are written as Markdown lines; its first line follows the marker, the others are indented by the marker's width; blocks inside an item are apart by a blank line; items are apart by a line feed; an item with no blocks is its marker alone.
   - block quote: its blocks' lines, each after `> ` (a blank line becomes `>`).
   - code block: fenced with backticks, as many as the longest run of backticks in it plus one, at least three; its lines as they are.
   - thematic break: `---`.
   - table: GitHub's form; read `ExportDocumentWalker.table(of:)` (line 289) and mirror how it decides `hasHeaderRow`, so a table walks back as it was; every row has as many cells as the longest; a cell's text goes through `minimallyEscaped`, its line feeds as spaces; the delimiter row is `| --- |` per column.
5. `BookExportConversion` gains `static let markdown = BookExportConversion.text(TextExportConversion(MarkdownExportWriter(), options: NoTextExportOptions()))`, doc commented.

## Commit 3: Export writes it
6. In `BookExportService.offer(for:access:)`, the `.markdown` item's file is `BookExportFile(source: .converted(from: markdown, book: ExportBookDetails(book), by: .markdown), path: "\(stem) - Text.md", byteCount: byteCount(of: markdown))`. In `transcriptItem`, an audiobook's "\(stem) - Transcript.md" is made the same way; its "\(stem) - Transcript.json" stays a copy.
7. In `files(of:for:conversions:)`, a conversion chosen in the picker (HTML, RTF, Word, BRF, PEF) replaces the source of a `.converted` file as well as a `.copy` one: `case .copy(let url), .converted(let url, _, _)`. Only the `.markdown` kind has a picker, so the Transcript's files are never converted again.
8. `BookExportWording`: the `.markdown` kind's description and `markdownChoiceHint` both become exactly `"The book's text as Markdown, with its headings, lists, and emphasis."` (the description returns `markdownChoiceHint`, DRY). Update every doc comment that says Markdown is content.md "copied as it is" or "with a line marking each chapter": `BookExportKind.markdown`, `BookExportWording.markdownChoiceName`'s doc, `TextExportWriters.markdownID`, `BookExportConversionChoice`, `BookExportModel.conversionChoices`.

## Tests (none may trap, play sound, record, or touch `~/.TextMouth` or `UserDefaults.standard`)
New file `TextMouthProductionTests/MarkdownExportWriterTests.swift` (run `/opt/homebrew/bin/xcodegen generate` and commit the regenerated `project.pbxproj` with it), two classes, each test doc commented:
- `MarkdownMinimalEscapingTests`:
  - examples, as literal strings, for each rule above, both ways, including the user's case: `minimallyEscaped("Hello, world. It's 3:00; really? Yes!") == "Hello, world. It's 3:00; really? Yes!"`, and with `smartPunctuation: true`, `"It\\'s"` and `"well\\.\\.\\. no \\-\\- yes"`.
  - a round trip through swift-markdown itself: every string of one or two characters over the alphabet `a`, `1`, `é`, a space, and the 32 ASCII punctuation characters, and every string of three over the punctuation alone plus `a` and a space, skipping those that begin or end with a space: as a paragraph (`guardingLineStart(minimallyEscaped(s))`), as an ATX heading (`"# " + minimallyEscaped(s)`), and as a list item's text (`"- " + guardingLineStart(minimallyEscaped(s))`), the parsed block holds only `Text` children whose strings join to exactly `s`. Parse with smart punctuation off for the plain form and on for `smartPunctuation: true`. swift-markdown 0.9.0 is in your build folder's `SourcePackages/checkouts/swift-markdown`: check `ParseOptions` there for `disableSmartOpts`. If it does not exist, test the plain form only on strings with no `"`, no `'`, and no two `-` or `.` side by side, and say so in your report.
- `MarkdownExportWriterTests`:
  - one exact expected string per block kind and run style above, a table with a `|` and a `\` in its cells and a code block holding three backticks and backslashes included;
  - a round trip: a rich content.md made in the test (two chapter markers, headings of levels 1 to 3, paragraphs with emphasis, strong, code, a web link, and a hard break, nested ordered and unordered lists, a quote holding a list, a code block, a thematic break, a table, and a paragraph with every ASCII punctuation character escaped as content.md writes it) walks into a document whose `blocks` equal those of the walk of `MarkdownExportWriter.markdown(of:)` of it;
  - Stop: a cancelled `BookExportCancellation` makes `markdown(of:cancellation:)` throw `CancellationError`.
- In `BookExportServiceTests` (or `BookExportConvertToTests`, beside the existing export-by-kind tests): a text book's "Text as Markdown" exports a "Title - Text.md" with no backslash before a comma or a period, its exact text pinned; a transcribed silent audiobook (as `BookExportServiceTests` line 49 makes one, with `TranscriptStore.install(try TranscriptFixtures.transcript(of: book, sentences: TranscriptionUIScripts.twoTracks), for: book)`) exports "Title - Transcript.md" whose text holds "Gannet wings fold over the breakwater. Rope coils dry on the pier." unescaped, and "Title - Transcript.json" byte for byte as transcript.json; choosing HTML for "Text as Markdown" still writes "Title - Text.html".
Exact-output tests you may change, and only as said: those asserting that the `.markdown` or `.transcript` item's Markdown file is a `.copy` of content.md or that the exported file's bytes equal content.md's, and those pinning the two old hint sentences. No other existing test, and no golden (`TextPipelineGoldenTests`, `MarkdownEmphasisTests`, `ParserContentFidelityTests` must pass unchanged).

Run: `python3 Scripts/test/run-area.py MarkdownExportWriterTests MarkdownEmphasisTests ParserContentFidelityTests TextPipelineGoldenTests ExportDocumentWalkerTests HTMLExportWriterTests RTFExportWriterTests BrailleExportWriterTests BookExportServiceTests BookExportConversionTests BookExportConvertToTests BookExportSheetTests`, then `python3 Scripts/test/run-area.py export`, then `python3 Scripts/test/run-area.py --unassigned` and report what it lists.

## Builds
At most two of this team's workers build at once. Before each build: `df -g /System/Volumes/Data` must show at least 4 GB available, and `python3 .claude/skills/agent-bbs/scripts/bbs.py agents | grep -E "^transcripts-[a-z]+: building"` must list at most one other worker; otherwise wait with `bbs watch transcripts-export --timeout 240`, never a sleep loop. Write commits 1 and 2 before your first build, so you build fewer times.

## Do not touch
`MarkdownLiteral.escaped` and every writer of content.md (`TranscriptTextBuilder`, `PlainTextParser`, `HTMLToMarkdownConverter`, the DOCX and DAISY converters): no cache-format change. Not the reader, the search, or the transcription commands (other workers' files), and no `*.md`.

## Completion check
`grep -rn "copied as it is\|a line marking each chapter" TextMouth` finds nothing.

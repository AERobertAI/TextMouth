# Task `walker` (team export, October 19, 2026): the one walker of content.md

Worker `export-walker`, branch `export/walker` from `team/export`. FMT18. You write the walker that turns a book's `content.md` into the `ExportDocument` model every text writer reads. The model is already written: you fill it, you do not change it.

## Read first (only these)
- `TextMouth/Services/Export/ExportDocument.swift` (whole file, about 330 lines): the model. Do not edit it.
- `TextMouth/Services/MarkdownCacheService.swift` lines 501 to 615: `parseMultiChapterMarkdown` (how the reader gives a chapter without a heading its title as a level-1 heading, lines 539 to 544) and `splitChapters` (the marker lines).
- `TextMouth/Parsers/MarkdownParser.swift` lines 60 to 244: the reader's own walk, which you mirror in what it keeps and drops. Note how it names swift-markdown's types: `Markdown.Heading`, `Markdown.Paragraph`, `Markdown.Text`, `Markdown.Table`. TextMouth has types of its own with some of these names, so qualify every swift-markdown type with `Markdown.`.
- `TextMouth/Parsers/MarkdownHeadingAnnotation.swift` lines 1 to 45, for one test.

## The file you write: `TextMouth/Services/Export/ExportDocumentWalker.swift`
`import Foundation` and `import Markdown` only. Its header comment says, in these words or close: "Markdown is the base, and stays the base: every text book becomes content.md, and every writer starts from it through this walk. HTML is the first writer made from it, not a new base (the user's answer to Q21, October 17, 2026)."

    enum ExportDocumentWalker {
        static func document(fromMarkdown markdown: String, book: ExportBookDetails,
                             cancellation: BookExportCancellation? = nil) throws -> ExportDocument
        static func document(fromContentBytes bytes: Data, at url: URL, book: ExportBookDetails,
                             cancellation: BookExportCancellation? = nil) throws -> ExportDocument
    }

    struct ExportHeadingIDs {
        mutating func claim(_ text: String) -> String
        static func slug(_ text: String) -> String
    }

The walk's mutable state (the ids) lives in a `private struct` of your own in the same file. These names are fixed: team braille codes against them.

## Behavior
1. **Decoding.** `document(fromContentBytes:at:book:cancellation:)` decodes with `MarkdownCacheService.cacheText(from:at:)` (it throws for bytes that are not UTF-8) and calls `document(fromMarkdown:book:cancellation:)`.
2. **Chapters.** Split with `MarkdownCacheService.splitChapters(_:)`. When it gives no section, the whole text is one section with no title. Text before the first marker is left out, as the reader leaves it out. Call `try cancellation?.checkCancelled()` before each section. Parse each section's content with `Markdown.Document(parsing:)`, no options.
3. **A chapter's title.** A section whose title is not empty and whose blocks hold no heading at any depth (`ExportBlock.headings(in:)` is empty) begins with a level-1 heading of its title, one plain run, whose id is claimed after the section's blocks are made (they hold no heading, so the order of ids stays the reading order).
4. **Blocks**, from each container's children in order (a private `blocks(in:nesting:listDepth:)`):
   - `Markdown.Heading` becomes `.heading` with its level clamped to 1...6, its runs (item 6), and `ids.claim(plainText)`. A heading with no runs left after trimming is dropped, as the reader's heading list drops it.
   - `Markdown.Paragraph` becomes `.paragraph(runs)`; one with no runs left is dropped.
   - `Markdown.UnorderedList` and `Markdown.OrderedList` become `.list` with `isOrdered`, `start` (`Int(startIndex)` clamped to `0...1_000_000_000`; 1 for unordered), `depth: listDepth`, and an `ExportListItem` per `Markdown.ListItem`, whose blocks are its children's at `nesting + 1` and `listDepth + 1`. A task-list checkbox is ignored.
   - `Markdown.BlockQuote` becomes `.blockQuote` of its children's blocks at `nesting + 1` (same `listDepth`).
   - **Nesting cap.** A list or quote met when `nesting == ExportDocument.maximumNesting` is not opened: its blocks (for a list, each item's blocks in turn) are walked at the same `nesting` and `listDepth` and joined to the blocks being made. The document's body is `nesting` 0, `listDepth` 0.
   - `Markdown.CodeBlock` becomes `.codeBlock(code)` with one trailing line feed removed; one with nothing left is dropped.
   - `Markdown.ThematicBreak` becomes `.thematicBreak`.
   - `Markdown.Table` becomes `.table`: the head row's cells (`table.head.cells`), then each body row's (`table.body.rows`, `row.cells`), each cell its runs' plain text with every line feed a space, trimmed. When every head cell is empty the head row is left out and `hasHeaderRow` is false; otherwise it is the first row and `hasHeaderRow` is true. A table with no row left is dropped.
   - `Markdown.HTMLBlock` is dropped: TextMouth's marker comments, its heading annotations, and any raw HTML never reach the output, as the reader never reads them.
   - Any other block that is a `BlockContainer` is walked for its children at the same `nesting`; any other block is dropped.
5. **No other filtering.** Hand edits in content.md reach the document as the reader reads them; nothing is rewritten.
6. **Runs**, from an inline container's children, carrying a style down (a private `runs(of:style:)`, the style an `ExportRun` with empty text):
   - `Markdown.Text`: its `string`.
   - `Markdown.Emphasis` sets `isEmphasis`; `Markdown.Strong` sets `isStrong`; `Markdown.Strikethrough` keeps the style.
   - `Markdown.InlineCode`: its `code`, with `isCode`.
   - `Markdown.Link`: its children, with `link` set to the destination trimmed of white space when `ExportRun.isAllowedLinkAddress(destination)`; any other link's children keep the style they had (plain text).
   - `Markdown.Image`: its children, its alternative text, in the style it is in; never its source.
   - `Markdown.SoftBreak`: a space. `Markdown.LineBreak`: a line feed.
   - `Markdown.InlineHTML`: nothing (this check comes before the next).
   - Any other `InlineContainer`: its children. Any other inline: nothing.
   - Then neighbouring runs with the same style (`hasSameStyle(as:)`) are joined into one, and runs with no text dropped.
   - A heading's and a paragraph's runs are trimmed of white space and line feeds at both ends: the first run's start, the last run's end, dropping any run that trimming empties, until the ends have text.
7. **The title heading.** After every section: when no heading in the blocks, at any depth, is of level 1, and the book's title trimmed is not empty, `titleHeading` is a level-1 heading of that title, one plain run, with `ids.claim(title)`. Otherwise nil.
8. **Ids** (`ExportHeadingIDs`):
   - `slug(_:)`: take the first 200 characters; fold to ASCII with `applyingTransform(.toLatin, reverse: false)` and then `applyingTransform(.stripDiacritics, reverse: false)` (each falling back to its input when nil); lowercase; turn each run of characters that are not ASCII letters or digits into one hyphen; drop hyphens at both ends; cut to 64 characters and drop a hyphen left at the end. Nothing left gives "heading"; a result that begins with a digit gets "heading-" before it.
   - `claim(_:)`: the slug when not yet taken; otherwise the first of "slug-2", "slug-3", and so on that is not taken (keep a next number per slug, so claiming stays linear). The id returned is taken from then on. So three headings "Notes" are "notes", "notes-2", "notes-3"; and with "Notes", "Notes 2", "Notes" the third is "notes-3".
9. Comment every function and non-obvious block. Keep it DRY: one runs function for headings, paragraphs, and cells.

## Tests: `TextMouthProductionTests/ExportDocumentWalkerTests.swift` (new; run `/opt/homebrew/bin/xcodegen generate` and commit `project.pbxproj` with it)
A `final class ExportDocumentWalkerTests: XCTestCase`, `@testable import TextMouth`. Pin exact models with `XCTAssertEqual` on whole values wherever you can.
1. Two chapters made with `MarkdownCacheService.chapterMarker(title:)`: no run, code, or cell holds "<!--" or "chapter:"; the exact blocks are pinned.
2. A chapter with no heading begins with its title as a level-1 heading; a chapter that has a heading (even a level-2 one, even inside a quote) gets none.
3. Headings: levels, runs, and ids; the "Notes" cases of item 8 exactly; a heading "Notes <!-- old annotation -->" reads "Notes".
4. Slugs: "Café au lait" is "cafe-au-lait"; "1984" is "heading-1984"; "!!!" is "heading"; a 300-character heading gives at most 64 characters; a Greek or Chinese heading gives an id that is not empty, is ASCII letters, digits, and hyphens only, and begins with a letter (do not pin the transliteration).
5. Runs: emphasis, strong, strong inside emphasis, code, a link to `https://example.com/a?b=1&c=2` kept with its address, `mailto:` kept, `javascript:alert(1)`, `file:///etc/passwd`, `#chapter-2`, and `chapter2.html` all plain text, an image's alternative text (and never its source) as a plain run, a soft break as a space, a hard break (two spaces before a line feed) as "\n", inline HTML (`<span>`) dropped with the words around it joined as the reader joins them, and neighbouring same-style runs joined.
6. Lists: an unordered list holding an ordered list starting at 3 (`depth` 0 and 1, `start` 1 and 3); an item of two paragraphs; `ExportListItem.plainText` and `ExportBlock.plainText` of the list exactly.
7. A block quote, a code block (exact, the trailing line feed gone), a thematic break, a table with a header row, and a table whose head cells are all empty (`hasHeaderRow` false, no empty first row).
8. Dropped: an HTML block (`<div>raw</div>`, its word "raw" gone too), a plain HTML comment block, and a heading annotation (`MarkdownHeadingAnnotation(level: 2, text: "Hidden").markdown` on a line of its own): none reaches the document.
9. The nesting cap: 20 nested quotes around a paragraph and a list nested 12 deep: no quote or list in the model nests more than `ExportDocument.maximumNesting` deep, no list's `depth` is above it, and every word survives (write a small recursive helper in the test that measures depth).
10. The title heading: present with the book's title when the text has only level-2 headings, with an id different from a level-2 heading of the same text; nil with a level-1 heading anywhere; nil for a blank title.
11. `document(fromContentBytes:at:book:)` throws for bytes that are not UTF-8 (`Data([0xFF, 0xFE, 0x41])`); a `BookExportCancellation` cancelled before the call makes both entry points throw `CancellationError`.
12. The model's helpers, in a `// MARK: - The Model` part: `ExportBookDetails.languageTag` ("en", " fr-CA ", "en_US" as "en-US", "zh-Hant-TW" kept; "English", "e", "", a 36-character tag, "en--US", and "en-ÜS" refused); `ExportBookDetails(book)` gives nil for the author "Unknown" and for an `epubLanguage` that is no tag (make a `Book` with `Book(title:author:format:filePath:md5Hash:)` and set `epubLanguage`); `ExportRun.isAllowedLinkAddress` ("HTTPS://x", " mailto:a@b " allowed; "javascript:x", "ftp://x", "#x", "x" refused); `ExportDocument.headings` finds a heading inside a quote inside a list item.
13. **Real samples** (the lessons' rule: prove what a reader gets on real books). For `TestData/alice.epub` (chapters with markers) and `TestData/sample.md` (none), each copied into a sandbox folder (`makeSandboxDirectory`) and imported with `importedForTest(_:)` (in `FormatSampleFixtures.swift`; `requireFile("alice.epub")` finds the original):
    - no run, code block, or cell of the walk of its content.md holds "<!--" or "-->";
    - the words of the reader's own parse of the same content.md (`MarkdownCacheService.parseMultiChapterMarkdown(markdown, bookTitle: book.title, bookAuthor: "")`, every chapter's `text`, split on white space) appear, in order, among the words of the walk (every block's `plainText`, split on white space); write the in-order check as a small helper that reports the first word missing.

## Build and test
Through `python3 Scripts/test/run-area.py ExportDocumentWalkerTests` (read `-h` first), with your own build folder as `teams-common.md` says. Before your final commit, also run `MarkdownCacheServiceTests` if it exists (`ls TextMouthProductionTests | grep -i markdowncache`), to show the reader is untouched.

## Do not touch
`ExportDocument.swift`, `TextExportWriter.swift`, `BookExportService.swift`, any `BookExport*` file, the parsers, `MarkdownCacheService.swift`, or any `*.md` file. If the model seems to need a change, stop and ask `export-lead` on the board.

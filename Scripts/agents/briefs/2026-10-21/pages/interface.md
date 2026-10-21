# Pages: the shared interface (PG01, October 21, 2026)

PG01 (task `marker`) makes these types; every other pages task uses them and redefines none. Names, signatures, and rules here are settled. The design is `PAGES-RESEARCH-2026-10-21.md` sections 2 and 4.

## 1. The marker in content.md

`<!-- page: LABEL -->` marks where a page begins. It is never spoken, adds no reading text, and so moves no saved place.

**`MarkdownPageMarker`** (new, `TextMouth/Parsers/MarkdownPageMarker.swift`): `struct MarkdownPageMarker: Equatable, Sendable`
- `static let maximumLabelLength = 32`
- `let label: String`: the page's label as the source names it ("12", "xii", "A-3"): never empty.
- `init(label: String, ordinal: Int)`: the label normalized (whitespace at the ends trimmed, each inner run of whitespace and newlines made one space, cut to 32 Characters, trimmed again); when nothing is left, the label is `String(ordinal)`, the page's 1-based number among the book's pages.
- `var markdown: String`: `"<!-- page: " + escaped label + " -->"`. Escaping is percent-encoding of the UTF-8 bytes of only these: `%`, `<`, `>`, every scalar of general category Cc (controls, tab, line feed), Zl, or Zp, and every `-` that immediately follows another `-` in the label ("a--b" is written `a-%2Db`, "---" is `-%2D%2D`). So "12", "xii", "A-3", "S 4" are written as they are.
- `static func decode(_ comment: String) -> MarkdownPageMarker?`: the marker a complete comment holds, after trimming whitespace and newlines from the comment; nil unless it begins with exactly `<!-- page: ` and ends with exactly ` -->`, the text between them is not empty and holds no raw `<`, `>`, or `--`, its percent-decoding (each `%` followed by two hexadecimal digits is that byte; any other `%` stays a `%`) is valid UTF-8, and the normalized label is not empty.

**`MarkdownMarkerWriter`** (new, `TextMouth/Parsers/MarkdownMarkerWriter.swift`): `enum MarkdownMarkerWriter`, the "never begins a line" placement that `HTMLToMarkdownConverter` used for heading annotations, moved here so every converter writes markers alike. CommonMark opens an HTML block at any line beginning with `<!--`, and that block swallows the rest of the line, so a marker never begins a line of text.
- `enum LinePosition: Equatable { case withinLine, continuationLine, blockStart }` and `static func linePosition(of markdown: String) -> LinePosition` (moved unchanged).
- `static func write(_ marker: String, inline: Bool, keepingWordsApart: Bool = false, into markdown: inout String)`:
  - `inline: false`, or a line position of `.blockStart`: `ensureBlankLine`, the marker, then `"\n\n"`: a block of its own, which names the same place as the block after it.
  - `.withinLine`: the marker right there. With `keepingWordsApart`, a space first unless the Markdown already ends in whitespace: for a source whose page break joined two words (a DOCX page `w:br`, textutil's HTML).
  - `.continuationLine` (after a hard break): four spaces, then the marker, which keeps it inside the paragraph.
- `static func ensureBlankLine(_ markdown: inout String)` (moved from the converter): ends the Markdown with a blank line unless it is empty or already does.

**How a format writes a page**, and only while `includesPages` is true:
`MarkdownMarkerWriter.write(MarkdownPageMarker(label: label, ordinal: n).markdown, inline: …, into: &markdown)`
- a page that begins a paragraph, list item, table row, or heading: `inline: false`, before it (never inside a heading line, code block, or code span);
- a page that begins mid-paragraph: `inline: true`, immediately before the page's first character;
- a page that begins a chapter: the first thing in that chapter's Markdown, right after its `<!-- chapter: -->` line;
- formats paginated throughout (PDF, DOCX, textutil's) give page 1 a marker at the book's start; a break before the first words merges with it;
- several pages at one place (blank pages) keep a marker each, in order.

## 2. The page model

All in the new `TextMouth/Models/BookPages.swift`.

**`PageBreak`**: `struct PageBreak: Equatable, Hashable, Sendable`
- `var label: String`, `var chapterIndex: Int`, `var characterOffset: Int` (UTF-16, into the chapter's reading text, at the start of the page's first word).
- `init(label: String, chapterIndex: Int = 0, characterOffset: Int)`
- `func startsAtOrBefore(chapterIndex: Int, characterOffset: Int) -> Bool`, as `Heading`'s.

**`Chapter.pages: [PageBreak]`** (`Models/DocumentContent.swift`; `Chapter.init` gains `pages: [PageBreak] = []` last). Filled by the parse, in order, with `chapterIndex` 0, as `Chapter.headings` carry 0.

**`BookPages`**: `struct BookPages: Equatable, Sendable`, a book's pages in book order.
- `static let none = BookPages(breaks: [])`
- `let breaks: [PageBreak]`: sorted by (chapter, offset, the order given), so pages at one place keep their order.
- `let total: Int`: N of "Page 12 of N": the largest label that is a whole number (only ASCII digits, and `Int` can hold it), so a book numbered i to xiv and then 1 to 300 says "of 300"; the number of pages when no label is one; 0 with no pages.
- `init(breaks: [PageBreak])`, `var isEmpty: Bool`, `var count: Int`
- `func index(ofPageAtChapter chapterIndex: Int, offset characterOffset: Int) -> Int?`: the index in `breaks` of the page holding a place, the last break at or before it (binary search); nil before the first page. Where several breaks share an offset, the last of them holds the place.
- `func position(atChapter chapterIndex: Int, offset characterOffset: Int) -> PagePosition`
- `static func wholeNumber(_ label: String) -> Int?`

**`DocumentContent.pages: BookPages`** (`let`), built once in `DocumentContent.init` from `chapters`, each break given its chapter's index in `chapters`. Every path that makes a `DocumentContent` (content.md, an EPUB's prepared chapters, the reading-text cache) therefore has pages.

**`PagePosition`**: `struct PagePosition: Equatable, Sendable`, a place described by pages, modelled on `HeadingPosition`.
- `let page: PageBreak?` (nil before the first page, and in a book without pages), `let number: Int?` (1-based index in `breaks`), `let count: Int`, `let total: Int`, `let firstLabel: String?` (the first page's label).
- `var label: String`: `"Page 12 of 300"` (`"Page \(page.label) of \(total)"`); `"Before page 1"` (`"Before page \(firstLabel)"`) before the first page; `""` for a book without pages, which callers leave out rather than speak.

## 3. The parse

`MarkdownDocParser.parseChapter` reads markers only where it reads heading annotations (`includeNavigationHeadings`: content.md and an EPUB's prepared chapters); everywhere else a marker is an ordinary comment, unseen.
- A marker in a block takes the offset of the block after it (the extractor's `separateBlock()` first, as for an annotation); an inline one takes its exact place, or the heading's start inside a heading line.
- Offsets are shifted by the trimmed leading whitespace and clamped to the chapter's text, as navigation headings are.
- **A page that begins inside a word begins at that word's start** (`ReaderViewModel.snappedWordStart(in:at:)`), so the place a listener lands on and the page shown agree, and Next Page never lands short of the page it names.

## 4. `includesPages`

Every text extraction takes `includesPages: Bool = true`. With false a format writes exactly what it wrote before pages (cache format 3.0.7): no marker, and no change to its words. PG09 compares the two readings to find text changed by hand. PG01 passes it from `MarkdownCacheService`'s private `extractCache(from:format:brailleTable:brailleTableVersion:includesPages:)` (which `writeCache` calls with `true`) to:
- `EPUBParser.prepareBook(url:includesPages:)`
- `HTMLToMarkdownConverter.convert(_:stripDuplicateNavigation:headingTargets:includesPages:)` and `convert(document:readingFlow:stripDuplicateNavigation:headingTargets:includesPages:)`, held in its `Context.includesPages` (the `.html` case passes it; webarchive and SSML keep the default)
- `PDFTextParser.extract(from:recognizer:includesPages:)`
- `DOCXParser.extractMarkdown(from:includesPages:reportIncompleteContent:)`
- `DAISYParser.extractMarkdown(from:includesPages:reportIncompleteContent:)`
- `TextutilDocumentReader.extract(from:bookFormat:includesPages:)`
- `PlainTextParser.markdown(text:includesPages:)`

Braille's reader takes none yet (PG12). After PG01 nothing uses the value: each format task makes its own format honor it.

## 5. Goldens and digests

- `DocumentDump` writes golden format 2, adding one line per page after the headings: `page: LABEL | CHAPTER:OFFSET | OPENING`, where OPENING is the 24 Unicode scalars of the chapter's reading text from the page's offset; label and opening escaped as every golden value is.
- A format task records its own fixtures' goldens again with `BBS_AGENT=<slug> Scripts/test/update-goldens.sh` and commits only its own fixtures' `.golden` files (`git status --short TestData/golden` lists what changed; any other golden changing is a finding to report).
- `TextPipelineGoldenTests` records each fixture's content.md digest (`recordedCaches`) and reading digest (`recordedReadings`): a format that writes markers changes its fixtures' content.md digests, and one whose reading text changes (EPUB page-break numbers, DAISY's "[Page N]") changes their reading digests too. Replace exactly those entries with the digests the failure messages print, after checking the new output.
- Export never carries pages (`ExportDocumentWalker` drops raw HTML) until PG15.

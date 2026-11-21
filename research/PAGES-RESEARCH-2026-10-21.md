# Pages across formats: research (October 21, 2026)

A design note for the TODO's new section, "Pages across formats (researched October 21)", items PG01 to PG15, written before anything is built. It draws on the code on main at 43c9583c and on probes run on copies of the repository's samples in the gitignored `build/pages-research/`: `textutil` conversions, PDFKit's page labels on a PDF made here, and a read-only scan of the fixtures for page markup. Nothing in the app was changed, nothing was built with xcodebuild, no test ran, `~/.TextMouth` was not touched, and nothing played a sound.

The request, in the user's words (October 21, 2026): "For pages It might be a good idea but it would also open up a big can of worms... sense many other formats (Epub, pdf, docx / doc) at least are separated into pages and I think it would be reasonable if all of them supported them(including updating the parsers the text schema to have a special page tag or simular) so we can "go to page" or rewind and fastforward by page (I think page should just be a navigation unit like the others if you can get that working generally) and a optional page number/count on the reader screen / wear am I speech... Please make a feature section of TODOs for this if you think it would be good and lets make that the feature set implemented first today for the formats using pages."

## Summary

- **It is worth doing, and the can of worms is small.** content.md already carries an inline marker that the reader never speaks: `<!-- textmouth-heading: … -->`, which places a table-of-contents entry at an exact reading-text offset (`MarkdownHeadingAnnotation.swift`, `MarkdownParser.swift:229–243`). A page marker built the same way is never spoken, never splits a paragraph, and changes no reading-text offset, so no saved place moves because of it. Export already drops it (`ExportDocumentWalker.swift:243–246, 368–369`).
- **The schema: `<!-- page: 12 -->`,** an HTML comment holding the page's label as the source names it ("12", "xii", "A-3"), escaped only where a comment needs it. It sits inline at the exact place where a page begins mid-paragraph, or on its own line where a page begins a paragraph, and it never begins a line of text, by the rule the converter already follows for heading annotations (`HTMLToMarkdownConverter.swift:312–331`). Inline markers beat a sidecar index: they travel with the text through Edit Text, cache rebuilds, and every change to how reading text is derived, where a sidecar's offsets would go stale.
- **What the formats hold, and what TextMouth keeps today:**
  - **EPUB:** the EPUB 3 page list and the EPUB 2 NCX `pageList` are deliberately skipped (3.0.5, `EPUBParser+Navigation.swift:305–310`). Page-break elements are not recognized, so a page break that holds its number as text is read aloud.
  - **PDF:** each page is already read on its own and joined with a blank line (`PDFTextParser.swift:118–150`). `PDFPage.label` gives the PDF's own labels, verified here as "i", "ii", "1", "2", "A-1", and gives "1", "2", "3" for a PDF with none.
  - **DOCX:** every `w:br`, page breaks included, becomes a newline (`DOCXParser+Converter.swift:180–183`). `w:pageBreakBefore`, section breaks, and `w:lastRenderedPageBreak` are ignored, though alice.docx holds 19 `w:pageBreakBefore`.
  - **DOC, RTF, and WordML:** `textutil`'s HTML drops every page break and runs together the words on either side of one ("runs on andcontinues", verified). Its plain text keeps the break as a form feed.
  - **DAISY:** a DTBook `pagenum` becomes the spoken text "[Page 1]" on a line of its own (`DAISYParser+TextExtraction.swift:163–166, 270–271`). The DAISY 2.02 NCC's page spans and the NCX `pageList` are ignored.
  - **Braille:** `BraillePageAnalyzer` finds every page's braille and print numbers, and `BrailleBookReader` throws them away (line 97).
- **Navigation:** Page becomes a navigation unit like the others (`SkipUnit.page`, between Paragraph and Heading), with Next Page and Previous Page (Option-Command-Right and Left Arrow), and Go to Page… (Option-Command-G). Go to Page… opens a page field in the reader's status row, beside the existing Go to Percent and Go to Time fields, where a "Page 12 of 300" button opens the same field. Where Am I? says "Page 12 of 300" after the heading number. There are two settings, both on: show the page on the reader screen, and say it in Where Am I?.
- **Existing books** gain pages by being read again at the next launch, format by format, through a page-reader version stamped on each row, as the metadata refresh does. T06's relocation keeps places where the reading text changes (page numbers that are no longer read aloud). A book whose text was changed with Edit Text keeps its text, and gains no pages, rather than lose the edit.
- **Order:** the schema (PG01); then, in parallel, the reader's navigation and display (PG02–PG04, one worker) and EPUB, PDF, DOCX, and DAISY text (PG05–PG08, a worker each); then existing books (PG09) and the documentation (PG10). Later: DOC, RTF, and WordML through textutil (PG11), braille after the `brailleemphasis` merge (PG12), plain text's form feeds (PG13), DAISY audiobooks (PG14), and pages in export (PG15).
- **Four questions** end the document (section 10), each with a recommended answer.

## 1. The text schema today

### 1.1 content.md and its markers

- **Every text book becomes one Markdown file,** content.md, in its package (`MarkdownCacheService.swift:4–8`), stamped with the extraction's version, 3.0.7 (`:25`; the history is at `:16–24`, and version 3.0.5 is the one that stopped reading EPUB page lists as headings or speech).
- **Chapters:** each begins with `<!-- chapter: Title -->` on a line of its own (`chapterMarker(title:)`, `:34–43`). `splitChapters(_:)` (`:598–630`) finds whole lines with that prefix and suffix, and each section is parsed on its own.
- **Navigation annotations:** a table-of-contents destination that is not a real heading is written as `<!-- textmouth-heading: <base64 JSON of level and text> -->` (`MarkdownHeadingAnnotation.swift:9–16`).
  - It is decoded only when complete and well formed (`:32–39`), and only for generated content.md (`includeNavigationHeadings`, `MarkdownParser.swift:77–80`).
  - Ordinary HTML comments from a source never reach content.md. The converter writes nothing for comments (`HTMLToMarkdownConverter.swift:133–141`), and a source's text is written as escaped Markdown literals (3.0.6 and 3.0.7), so a source cannot forge a marker.
- **The "never begins a line" rule** (`HTMLToMarkdownConverter.swift:312–331`): CommonMark opens an HTML block at any line that begins with `<!--`, and the block swallows the rest of the line. So an annotation is written inline after text on the same line; after a hard break it is written behind four spaces, which keeps it inside the paragraph; and at a block boundary it is a block of its own, followed by a blank line.

### 1.2 From content.md to the reader's model

- **Parsing:** `MarkdownCacheService.parseMultiChapterMarkdown` (`:521–571`) parses each chapter with `MarkdownDocParser.parseChapter` (`MarkdownParser.swift:18–57`).
  - Its walker, `PlainTextExtractor`, writes the reading text and records each heading's UTF-16 offset in the same walk, "so coordinates come from the same walk that produces speech" (`:40–42`).
  - The leading whitespace is trimmed, and every offset is shifted by what was trimmed (`:29–38`).
  - An annotation adds no text. In a block, it takes the offset of the block that follows (`visitHTMLBlock`, `:229–234`). Inline, it takes its exact place in the paragraph (`visitInlineHTML`, `:239–243`).
- **The model:** `DocumentContent` holds `Chapter`s (`DocumentContent.swift:90–93`: title, text, headings), and a `Heading` is a level, a label, a chapter, and an offset into that chapter's reading text (`:155–164`).
  - Paragraphs and sentences are not stored. They are found in the reading text when needed: `nextParagraphStart` and `nextSentenceStart`, at `ReaderViewModel+Navigation.swift:496–575`.
- **Two stored copies of the parse:**
  - The content index (`BookContentIndex`, version 1.0.0, `:10`) keeps each chapter's headings for the library and for audiobooks.
  - `ReadingTextCache` (`ReadingTextCache.swift:100–175`) keeps, for books over 1 MB, each chapter's title, length, headings, and text, in this Mac's Caches folder, keyed by build. Pages must be added to its header (layout 1 to 2).

### 1.3 How places are stored

From `TEXT-ANCHORS-RESEARCH-2026-10-10.md` §1 and §5, and the code merged since:

- **Positions and bookmarks** are a chapter index and a UTF-16 offset into that chapter's **reading text**, not into content.md, plus since T06 a text anchor: the 64 units of text before and after the place.
- **Skipped headings** are heading IDs (`"<chapter>-<offset>-<level>-<label>"`), now with anchors.
- **The sleep timer's End of heading** finds its next heading again at each load (`ReaderViewModel+Playback.swift:1043–1046, 3028`).
- **So a marker that adds no reading text moves nothing.** Only changes to the words themselves move places: a page number that was read aloud and now is not. Those are handled by T06's relocation at every cache rebuild (`MarkdownCacheService.GeneratedCache.movedPlaces`, `:68–72`) and at every load.

### 1.4 Edit Text, the relocator, and export

- **Edit Text** opens content.md in the user's editor and tells them: "Each line beginning with <!-- chapter: starts a chapter; keep those lines" (`BookTextEditWording.swift:22–26`, `docs/user/editing-book-text.md:6`).
  - Heading annotations are shown as they are, and so would page markers be.
  - A deleted page marker only removes that page. A marker the user types adds one.
- **The relocator** compares words: runs of letters and digits between whitespace (T06 §5). A marker is not in the reading text, so it never enters an anchor.
- **Export** builds `ExportDocument` from content.md and drops "content.md's own marker lines … and any other raw HTML" (`ExportDocument.swift:17–21`; `ExportDocumentWalker.swift:243–246` drops HTML blocks and `:368–369` inline HTML). So pages leave export unchanged until PG15 chooses to carry them, for braille's print page indicators.
- **Hand-edited text and re-extraction.** Only an edit session that is open is protected: `BookTextEditSessions.permitTextRebuild(of:writing:)`, "while the book's text is being edited in the user's editor" (`MarkdownCacheService.swift:120–123, 200–205`), and the batch's `isEditing` check (`LibraryViewModel+Migration.swift:512`). `Book` records no committed text edit; its `handEdits` (`Book.swift:286–296`) covers metadata. So every cache-version bump so far has replaced hand-edited text with the source's (section 5).

## 2. The page marker

### 2.1 Inline marker or sidecar index

| | Inline marker in content.md | Sidecar index (pages.json: chapter, offset, label) |
|---|---|---|
| Existing books' places | Unchanged: the marker adds no reading text | Unchanged: content.md is unchanged |
| Edit Text | The marker moves with its words; the user can see, keep, delete, or add pages | Offsets go stale with every edit; each page would need T06 anchors and relocation, about 300 a book |
| Reading text derived again (a new index version, table rows, and so on) | Offsets are recomputed in the same walk that makes the text | Offsets can silently stop matching, as places did before T06 |
| Export | Already dropped; can later be carried to braille print page indicators | Needs its own alignment to the exported text |
| Edit Text with VoiceOver | Noise: about one comment every 2,000 to 3,000 characters | None |
| Cost | About 20 bytes a page: 2,000 pages is 40 KB | A second file per book, written and read beside content.md |

**Recommendation: the inline marker.** It is the heading annotation's design, which already works and is tested, and it makes pages part of the text that every path already carries. The sidecar's one advantage, a cleaner Edit Text, is smaller than its cost. That cost is a second set of offsets that every text change would have to move.

### 2.2 The recommended form

- **`<!-- page: LABEL -->`**, beside `<!-- chapter: Title -->`, readable by eye, by VoiceOver, and on a braille display.
  - Not base64: a book has hundreds of pages, and a 30-character blob in the middle of each page would fill a 40-cell line.
- **The label** is the page's own label as the source names it, trimmed, at most 32 characters (longer labels are cut, since the input is untrusted).
  - It is escaped with percent-encoding of its UTF-8 for only these: `%`, `<`, `>`, every control character, line break, or tab, and the second `-` of any `--`. Comment syntax requires those, since a comment's text may not contain `--`, and swift-markdown's cmark-gfm follows the older CommonMark comment rule.
  - So "12", "xii", "A-3", and "S 4" are written as they are.
  - An empty label is replaced by the page's number in its chapter sequence, counted from 1 through the book.
- **Decoding** accepts only a complete comment with that exact prefix and suffix, after the same trimming `MarkdownHeadingAnnotation.decode` does, and only where navigation annotations are read (`includeNavigationHeadings`). Anything else is an ordinary comment, unseen as before.
- **Types (new):** `MarkdownPageMarker` (Parsers), with `markdown` and `static func decode(_:) -> MarkdownPageMarker?`. And `MarkdownMarkerWriter` (Parsers), the "never begins a line" placement moved out of `HTMLToMarkdownConverter` (`linePosition`, `emit`), so that every converter writes markers alike.

### 2.3 Where it sits

- **A page that begins a paragraph, list item, table row, or heading:** a block before it (`marker` + blank line). That is the same place the paragraph already begins, so no paragraph break is added.
- **A page that begins mid-paragraph:** inline, immediately before the first character of the page.
  - If the source runs two words together across the break, which Word's and RTF's page breaks do through textutil, the writer adds one space before the marker.
  - If a page begins mid-word, as an EPUB page break inside a hyphenated word can, nothing is added. The word stays one word.
- **Never inside a heading line, a code block, or a code span.** The marker goes before them, as heading annotations do (`HTMLToMarkdownConverter.swift:171–178, 250–266`).
- **A page that begins a chapter** is written after its `<!-- chapter: -->` line, so that it belongs to that chapter at offset 0.
- **Formats paginated throughout** (PDF, Word, the textutil formats, plain text, and braille) give page 1 a marker at the book's start. A break before the first words, such as `w:pageBreakBefore` on the first paragraph, merges with it rather than making an empty page. EPUB and DAISY have pages only where their source marks them.
- **Several pages at one place** (blank pages, picture-only pages) keep a marker each, in order. Section 2.4 says which one names the place.

### 2.4 What the reader does with it

- **Never spoken:** `PlainTextExtractor` writes nothing for it, as for a heading annotation.
- **Never splits a paragraph or a sentence:** an inline marker is inside the paragraph, and a block marker stands only where a block boundary already is.
- **A position maps to the page that holds it:** the last page break at or before it, in book order (chapter, then offset). Where several share an offset, the last of them names the place.
  - Before the first page (a cover, a title page) there is no page, and the reader says "Before page 1", naming the first page's label.
- **"Page 12 of N":** N is the largest page label that is a whole number, so a book numbered i to xiv and then 1 to 300 says "of 300". When no label is a whole number, N is the number of pages.

### 2.5 The page model (new)

- **`PageBreak`:** `label: String`, `chapterIndex: Int`, `characterOffset: Int` (UTF-16, into the chapter's reading text). It lives in a new `TextMouth/Models/BookPages.swift`.
- **`Chapter.pages: [PageBreak]`,** filled by the parse.
- **`DocumentContent.pages`** is stored once, at init, in book order, since the status row asks often.
- **`PagePosition`,** modelled on `HeadingPosition` (`DocumentContent.swift:195`): the page holding a place, found by binary search; its 1-based number; the count; the total, N; and the words "Page 12 of 300".
- **`ReadingTextCache`** writes each chapter's pages in its header (`formatVersion` 2).
- **The content index** stays as it is. Only audiobooks (PG14) need pages in it.

## 3. Each format's pages

| Format | What the source holds | What TextMouth keeps today | What it takes | Item |
|---|---|---|---|---|
| EPUB 3 | nav `epub:type="page-list"` / `role="doc-pagelist"`: a link per page to its place; `epub:type="pagebreak"` / `role="doc-pagebreak"` elements, labelled by `aria-label`, `title`, or their text | Page list excluded on purpose (`PublicationSemantics.swift:44–62`, `EPUBParser+Navigation.swift:305–310`); page-break elements unknown, so their text ("12") is read aloud | Read the page list as page targets (id → label), emitted at the target element by the converter as TOC targets are; page-break elements as a fallback when there is no list; their text never read | PG05 |
| EPUB 2 | NCX `pageList` of `pageTarget`s (navLabel, content src) | Not read (the NCX reader takes the navMap only) | The same targets from the NCX | PG05 |
| HTML | Rarely, the same page-break roles; CSS `page-break-*` for print | Nothing | The roles come free with PG05's converter; CSS print breaks are not worth doing | PG05 |
| PDF | Every PDFKit page; `/PageLabels` gives labels (verified: i, ii, 1, 2, A-1; without labels, 1, 2, 3) | Each page read on its own and joined with a blank line (`PDFTextParser.swift:118–150`); with an outline, headings first (`:734–774`) | A block marker before each page's text (and before its outline headings), labelled by `PDFPage.label`; pages without text keep their marker | PG06 |
| DOCX | `w:br w:type="page"`; `w:pageBreakBefore` (direct or by style); `w:sectPr` of type nextPage (the default), oddPage, or evenPage; `w:lastRenderedPageBreak` (Word's last layout); `w:pgNumType w:start` and `w:fmt` | Every `w:br` is a newline (`DOCXParser+Converter.swift:180–183`); the rest ignored | All of them, merged (below); labels counted from 1 with section restarts and formats | PG07 |
| DOC, DOT, RTF, WordML | Explicit page breaks only (Word's layout is not stored in a .doc) | textutil's HTML drops them and joins the words around them | A second watched textutil run to plain text, whose form feeds are aligned to the HTML's text | PG11 |
| ODT, OTT | `fo:break-before="page"` and soft page breaks | Through textutil: not verified (below) | Later, with FMT27's own ODT reader | none |
| DAISY 3, NIMAS, DTBook | `pagenum` elements (front, normal, special) in the text; NCX `pageList` | `pagenum` becomes spoken "[Page 1]" on its own line (`DAISYParser+TextExtraction.swift:163–166, 270–271`) | Marker labelled by the `pagenum`'s text, never spoken | PG08 |
| DAISY 2.02 | NCC `span class="page-normal"`, `page-front`, `page-special`, each linking to its SMIL `par`, whose text points into the content | NCC read for h1–h6 only (`DAISYParser+NCCParser.swift:21, 38`); page fragments read as text | The NCC's page spans give labels and targets; a page's text fragment becomes a marker | PG08 |
| DAISY audio | The same page targets, resolved to audio clip times | Not read | Pages as audio places, in the content index | PG14 |
| BRF, PEF | Braille pages (form feeds or PEF `page`), each with a braille page number, and often print page numbers and print page change lines | Found by `BraillePageAnalyzer` (`:5–25`), dropped by `BrailleBookReader.markdown` (`:96–97`) | A marker where each page begins, by splitting the back-translation of a block at the page's start | PG12 |
| BRL | No pages (`BrailleFileReader.swift:344–357`) | Not applicable | Nothing | none |
| Plain text | Form feeds, in old printouts and some generated text | Read as whitespace | Each form feed starts a page, numbered from 1. Cheap, but rarely useful | PG13 |
| Audiobooks | None, except DAISY | Not applicable | Nothing | none |

### 3.1 EPUB details

- **Precedence:** the page list names the pages when the book has one; it is the publisher's list, in its order, with its labels. Page-break elements not in the list are ignored then. Without a list, every page-break element is a page.
- **The page-break element's text** (often the number itself, hidden by CSS that TextMouth does not apply) is never read. That changes the reading text of such books (section 5).
- **Targets in content outside the reading flow** (the `hidden` attribute) are dropped with that content. A target naming a document without a fragment is a page at that chapter's start. A duplicate id takes the first element.

### 3.2 DOCX: which breaks to trust

- **Every page start counts:** explicit breaks (`w:br w:type="page"`, `w:pageBreakBefore` direct or from the paragraph's style chain, and a page-starting section break) and `w:lastRenderedPageBreak`.
  - Page starts with no letter or digit between them are merged into one, so a Word file that writes a rendered break after its own explicit one does not count the page twice.
  - Whether Word does that was not verified; the merge makes it not matter.
- **Why both:** a file Word laid out has `w:lastRenderedPageBreak` at each page start, so its pages match what Word showed. A file that Word never laid out (made by textutil, pandoc, Google Docs, or a script) has only its explicit breaks, so it has fewer pages than Word would show. The user documentation says so.
- **Labels** are counted from 1. A section's `w:pgNumType w:start` restarts the count, and its `w:fmt` writes it: decimal, lowerRoman, upperRoman, lowerLetter, or upperLetter, and any other format as decimal.
  - A section's `w:sectPr` comes at the section's end. So a light first pass over document.xml collects the sections, or the labels are filled in after the walk.
- **Words stay apart:** a page-type `w:br` inside a paragraph is written as a space and an inline marker. Today it is a newline, which reads as a space, so the reading text is unchanged.

### 3.3 textutil formats (verified on copies)

The probe wrote an RTF with three kinds of break: `\page` in the middle of a paragraph, `\pagebb` on a paragraph, and `\sect`. It converted the RTF to every format textutil writes, read each of those back, and also read copies of all 20 word-processor samples:

- **textutil reads `\page`** and writes it back out as `<w:br w:type="page"/>` in DOCX and WordML, and as a form feed in plain text.
- **`\pagebb` and `\sect` are lost on reading.** No format kept them.
- **textutil's HTML keeps no page break from any source:** no form feed, no CSS. It also joins the words around the break into one: "First page paragraph two runs on andcontinues here", and "Third page text.Fourth page" for `\sect`. TextMouth reads that HTML today, so such a document is heard with run-together words.
- **textutil's plain text keeps every `\page` as a form feed (U+000C)** when it reads RTF, DOC, DOCX, and WordML, at exactly the break's place: "runs on and\fcontinues".
- **ODT:** textutil's ODT writer dropped the break, so the probe had no ODT holding one, and whether textutil reads an ODT's page breaks is not known.
- **None of the 20 samples holds a page break.**

So PG11 runs textutil a second time, to plain text: 0.04 to 0.16 seconds for ordinary files, under the same watchdog (FMT13). It counts the letters and digits before each form feed, and has the HTML-to-Markdown pass write a marker after the same count, with a space where the words would run together.

- **An alignment check:** the 16 letters and digits on each side of the break must match. A break that fails the check is dropped and logged rather than placed wrongly.
- **Labels** are 1 to N; a .doc holds no page numbering that textutil passes on.

### 3.4 Braille

- **Every BRF page has a braille page number;** transcriptions of print books add print page numbers and print page change lines, which the analyzer already reads (`BraillePageNumbers`: `braillePageNumber`, `printPageNumber`, `printPageChanges`, `firstBlockIndex`).
- **A page always begins at a line start,** so at a word boundary.
  - The analyzer adds, for each page, the cell offset in its first block where the page begins.
  - The reader back-translates a block in pieces split at those offsets, and joins the pieces with an inline marker. The helper already splits long paragraphs at blank cells, so this is the same operation.
  - Word counts are no answer here: UEB joins "and the" into one braille word.
- **Labels:** the number read back as print: "⠼⠁⠃" is 12, "⠏⠼⠁" is p1. Anything else falls back to the page's ordinal.
- **Which number is "the page"** is question 2. The recommendation is braille pages.
- **`BrailleBookReader.swift` is `brailleemphasis`'s file today,** and that brief keeps it out of `BraillePageAnalyzer.swift`. So PG12 starts after that merge.

## 4. Navigation

### 4.1 Units today

- **`SkipUnit`** (`SettingsViewModel.swift:38–126`): 10, 15, 30, and 60 seconds, Sentence, Paragraph, Heading, Subheading, and Bookmark.
  - Its order is the cycle's order (`nextNavigationUnit`, `:95–103`).
  - Every picker lists `SkipUnit.allCases`: the playback bar (`PlaybackControlsView.swift:172, 194, 203`) and Settings (`SettingsView.swift:275–312`).
  - Its raw values are what config.json and the book records keep (`SettingsPolicy.swift:423–429`).
- **Skip Forward and Skip Backward** (Command-Right and Left Arrow, L and J) run `performSkip(unit:forward:)` (`ReaderViewModel+Navigation.swift:224–259`) with the book's own unit or the global one (`PlaybackSkipUnitPolicy`). F and B cycle the unit (`cyclePlaybackSkipUnit`, `:54–76`).
- **Heading jumps** go through `navigatePreservingReturnPosition`, so Go Back returns from them, and announce "Heading: …" (`:825–858`). Previous jumps back past a place 10 units behind the cursor (`:312`).
- **RewindUnit** (rewind on resume: none, sentence, paragraph, heading) is a separate setting. A page is too long to rewind on resume, so it stays as it is.

### 4.2 Page as a unit

- **`SkipUnit.page = "Page"`,** between Paragraph and Heading, so the cycle runs 10s, 15s, 30s, 60s, Sentence, Paragraph, Page, Heading, Subheading, Bookmark. `wordCount` returns nil, and `iconName` needs a symbol available on the deployment target, such as `doc.text`.
- **`nextPage()` and `previousPage()`** (new, `ReaderViewModel+Pages.swift`), modelled on `nextHeading`:
  - the first page break after the cursor, or the last one more than 10 units before it;
  - the jump goes through `navigatePreservingReturnPosition`;
  - it lands at the word's start when a page begins mid-word (`snappedWordStart`, `:1074`);
  - it announces "Page 13";
  - at the first or last page nothing moves and nothing is said, as with headings.
- **Skipped sections:** a page whose start lies in a skipped heading's section (`SkippedSectionFilter`) is passed over, as speech passes over the section.
- **A book without pages:** the F and B cycle passes over Page, since most of the library (audiobooks, plain text) has none and a unit that does nothing would be a trap. If Page is the saved unit anyway, a skip says "This book has no pages." and moves nothing.
- **Commands** (new `ShortcutAction`s in the Navigation category): "Next Page", "Previous Page", and "Go to Page…".
  - They go in the Navigate menu after Next and Previous Heading (`MenuCommands.swift:220–226`).
  - They are disabled while the key reader's book has no pages, through a `FocusedValue` like `readsFromReadingList` (`:202`).
  - Like Next Heading, they duplicate no existing command. The skip unit and these keys are two ways to the same move that the user asked for by name, as headings have both today.

### 4.3 Keys

- **Taken in the app's scope** (`KeyboardShortcut.swift:1489–1655`):
  - Space, K, J, L, F, B, W (and W twice);
  - Command with Right Arrow, Left Arrow, Up Arrow, +, -, B, F, L, I, E, A, O, R, P, period, Delete, [, and ];
  - Shift-Command with P, H, B, T, R, I, N, M, O, F, Up Arrow, and Down Arrow;
  - Option-Command with Up Arrow, Down Arrow, B, and N, and Option-Shift-Command-B;
  - Return.
- **Taken in the audio editor's scope** (`:1682–1725`): Option-Command-Up and Down Arrow, among others.
- **Proposed:**
  - **Next Page: Option-Command-Right Arrow. Previous Page: Option-Command-Left Arrow.** They are free in both scopes and pair with Next and Previous Heading on Option-Command-Down and Up.
  - **Go to Page…: Option-Command-G.** It is free; Command-G and Shift-Command-G stay with Find Next and Find Previous in the text views.
- **VoiceOver's modifier** is Control-Option, which none of these uses. With the Command key held, the manager takes the key even in a focused text field (`KEYBOARD-SHORTCUTS-RESEARCH-2026-10-07.md` §1.2), which is harmless here.

### 4.4 Go to Page… and the status row

- **The status row** (`BookInfoBar`, `ReaderView.swift:1190–1360`) holds the percent button (Go to Percent), the time-left button (Go to Time), the total, and the sleep timer.
  - Each button opens one field below the row (`ExpandedPanel`, `:1217–1220`; `JumpFieldPanel`, `ReaderJumpPanels.swift:182–292`).
  - Its hints follow a three-state pattern (`:1344–1360`).
- **A page button** goes after the percent, for books with pages while the setting is on.
  - It shows "Page 12 of 300" and VoiceOver hears the same.
  - It opens `JumpToPagePanel`, `ExpandedPanel.page`.
  - Its hints: "Opens jump to page controls", "Hides jump to page controls", and "Switches to jump to page controls". The percent and time hints gain the page case.
- **Go to Page…** (the command) opens the same panel, with a notification the bar observes, even while the setting hides the button. There is one field, reachable from the menu, its key, and the row.
- **The field** (`JumpInputValidator.page`, `ReaderPageWording`):
  - Label "Page", hint "Type a page as the book numbers it, such as 12 or xii.", starting at the current page's label.
  - It matches labels ignoring case and spaces at the ends.
  - A label used more than once is taken at its first page after the current page, else at its first in the book, so asking again reaches the next one.
  - Empty: "Type a page number." No match: "There is no page 400 in this book. Its pages run from i to 300."
  - After the jump: "Jumped to page 12."
- **Where Am I?** (`ReaderViewModel+WhereAmI.swift:130–152, 190–223`): "Page 112 of 300" after the heading number, in both summaries.
  - For example: "Dune. The Battle. Heading 26 of 412. Page 112 of 300. 30 percent. 3 hours remaining."
  - The words come from `PagePosition`, and are left out for a book without pages, or while the setting is off.

### 4.5 Settings

Both are in the Playback tab, in a "Pages" group beside "Times" (`SettingsView.swift:514`), are kept by `SettingsPolicy` boolean rules, and are mirrored in config.json:

- **"Show the page on the reader screen"** (`showsPageInReader`, on). Hint: "Shows the page being read, such as Page 12 of 300, beside the percent, for books with pages."
- **"Say the page in Where Am I?"** (`saysPageInWhereAmI`, on). Hint: "Adds the page, such as Page 12 of 300, to Where Am I?'s summaries, for books with pages."

## 5. Existing books

- **How a book could gain pages:**
  - (a) a cache-version bump, which re-reads every text book (October 3 rewrote 625);
  - (b) a per-format page-reader version stamped on each row (`Book.pageReaderVersion`), checked by the startup batch, as the metadata refresh checks `Book.metadataReaderVersion` (`LibraryViewModel+MetadataRefresh.swift:47–56, 210`; `Book.swift:285`);
  - (c) a command, per book;
  - (d) new imports only.
- **Recommended: (b).** It re-reads only books of formats that gained pages. A format added later (DOC, braille) re-reads only its own books, without another pass over 730 EPUBs.
- **Places** are kept as follows:
  - **Only markers added** (PDF, most DOCX, EPUBs whose page breaks are empty): every chapter's reading text is identical, so T06's direct check finds every place where it was.
  - **Words removed or added** (an EPUB page break's visible number; DAISY's "[Page 12]"; and, with PG11, a space between two words that ran together): T06 branch D's relocation in `writeCache` moves positions, bookmarks, and skipped headings, measured on far larger changes (0 wrong placements in 59,300 places, T06 §4).
- **Hand-edited text:** as section 1.4 found, a re-read replaces it. So the re-read for pages first reads the book again with pages turned off.
  - Every format item puts its changes behind one option, `includesPages`, which with false does exactly what 3.0.7 did. That is also a test seam.
  - If that reading text differs from the book's content.md's reading text, the book was changed by hand (or by an older TextMouth on another Mac). Its content.md is then kept as it is, without pages; the row is stamped so that the check runs once; and `PAGES_SKIPPED_CHANGED_TEXT: <title>` is logged.
  - Redo Text Extraction still re-reads such a book on request.
  - Books only in the cloud are skipped as the batch skips them today.
- **Cost:** one launch re-reads about 730 EPUBs and the rest of the text books with pages, as on October 3, and reads each twice where pages remove words (EPUB and DAISY). For PDFs it compares markers removed, which needs no second OCR.

## 6. Samples

The scan counted page markup in every fixture, read only:

| Exists | What it has | For |
|---|---|---|
| `TestData/alice.docx` | 19 `w:pageBreakBefore`, and the body's closing `w:sectPr` (not a break) | PG07 (its golden gains about 20 pages) |
| `TestData/lathe_of_heaven_daisy.zip` | 1 DTBook `pagenum`, 1 NCX `pageTarget` | PG08 |
| `TestData/wipo-treaty-d202-text-only.zip` | 4 NCC page spans | PG08 (2.02) |
| `format-samples/dtbook/harbour-standalone.xml` | 2 `pagenum` (its golden reads "[Page 1]" and "[Page 3]" aloud today) | PG08 |
| `format-samples/brf/pride-and-prejudice-ch1-grade1.brf` | 2 pages, braille page numbers #A and #B | PG12 |
| `format-samples/brf/wrapped-titles.brf` | 233 pages | PG12 (and many pages) |
| `format-samples/pef/pride-and-prejudice-ch1-grade1.pef` | 2 pages | PG12 |
| `TestData/test_with_outline.pdf`, `test_formatted.pdf` | 3 pages, no labels (PDFKit: 1, 2, 3) | PG06 |

**No page data:** alice.epub, the read-along EPUB, frankenstein.html, pride.txt, daisy202_test.zip, hyperion_daisy.zip, and all 20 word-processor samples.

To make, each recorded in `samples.tsv` with how it was made:

- **`epub3-pages/page-list.epub`.** A nav page list, with:
  - page-break spans, one holding visible text "12";
  - a page beginning mid-paragraph, one inside a word, and one at a heading;
  - labels i, ii, 1, 2, …, with one label repeated.
- **`epub3-pages/pagebreaks-only.epub`:** page-break elements and no list.
- **`epub2-pages/pagelist.epub`:** an NCX `pageList`.
- **`pdf/labelled-pages.pdf`:** five pages labelled i, ii, 1, 2, A-1. It was made here by a 60-line Python writer with the page-label tree `<< /Nums [0 << /S /r >> 2 << /S /D >> 4 << /S /D /P (A-) >>] >>`, and PDFKit read exactly those labels.
- **A 2,000-page PDF,** made at test time and never committed, for performance.
- **`docx/page-breaks.docx`.** Made the way FMT01's synthetic samples were. It holds:
  - a page `w:br` in the middle of a paragraph;
  - a style with `w:pageBreakBefore`;
  - a nextPage section with `w:pgNumType w:fmt="lowerRoman"`, then one restarting at 1;
  - `w:lastRenderedPageBreak` runs, one right after an explicit break.
- **`rtf/page-breaks.rtf`:** the probe's RTF, holding `\page` mid-paragraph, `\pagebb`, and `\sect`. Also `doc/page-breaks.doc` and `wordml/page-breaks.wordml`, made from it by `textutil -convert`, as headings.doc was.
- **`dtbook/pages-front-and-inline.xml`:** a front-matter `pagenum` labelled "ii", and a `pagenum` inline in the middle of a paragraph.
- **`brf/print-pages.brf`:** print page numbers in the top-right corner and a print page change line, for question 2.
- **`txt-pages/form-feeds.txt`,** if PG13 is built.

## 7. Risks

- **A marker at the start of a line** would swallow the line's words (CommonMark's HTML block). Every converter writes markers only through `MarkdownMarkerWriter`, and tests cover each placement: inline, after a hard break, at a block, at a chapter start, and at a heading.
- **Labels** that repeat (front matter and body both from 1), run out of order, are not numbers, are empty, are long, or hold `--`.
  - Next and Previous Page go by position, never by label value.
  - Go to Page matches labels as section 4.4 says, and "of N" takes the largest whole number.
- **Pages beginning mid-word:** the jump lands at the word's start, and the page shown changes at the marker.
- **Pages without text** (blank pages, pictures that recognition finds nothing in) put several markers at one offset. The last one names the place, and Next Page passes the others.
- **Performance:**
  - A 2,000-page PDF writes 2,000 markers, about 40 KB, and parses as fast as before, with offsets taken in the existing walk.
  - The status row finds the page by binary search, and only when the position changes.
  - OCR is unchanged and remains the PDF's real cost.
- **Reading-text changes for EPUB, DAISY, and textutil books** move places, which T06 relocates (section 5). Goldens change: PG01 moves every golden to format 2 with `page:` lines, and each format item updates its own fixtures' goldens.
- **DOCX without Word's layout** has fewer pages than Word would show. DOC has explicit breaks only. Both are said in the documentation.
- **textutil alignment** can fail where its plain text and HTML differ, for example around list markers, tables, and attachments. A break that fails the 16-character check is dropped and logged, never misplaced.
- **Edit Text with VoiceOver:** markers are heard as punctuation in the editor. The documentation says what they are, and that deleting one deletes that page.
- **A library shared with an older TextMouth:** an older build's parser ignores unknown comments (`visitHTMLBlock` returns), so it reads such content.md as before, without pages.
- **Other agents:**
  - `racefix` edits the reader's load path, which may include `ReaderViewModel.swift`. The reader worker's change there is a few lines of notification subscriptions, so merge `racefix` first and rebase.
  - `brailleemphasis` owns `BrailleBookReader.swift`, `BrailleTranslator.swift`, `TextMouthBraille/main.c`, and the export writers. PG12 and PG15 wait for its merge, and PG01 leaves braille alone.

## 8. TODO section draft

In the TODO, this becomes a section of its own, headed "## Pages across formats (researched October 21)".

### Pages across formats (researched October 21)

- [ ] **PG01 — The page marker and the page model.** Difficulty M · Impact 5 · The user's wish ("updating the parsers the text schema to have a special page tag"). The foundation for every other item.
  - **What:** `<!-- page: LABEL -->`, escaped as in section 2.2 (`MarkdownPageMarker`, new, Parsers), and `MarkdownMarkerWriter` (new, Parsers). The writer holds the "never begins a line" placement, moved out of `HTMLToMarkdownConverter` (`linePosition`, `emit`); the converter's heading annotations call it, with their output byte for byte the same.
  - **The parse:** `PlainTextExtractor` records page markers in `visitHTMLBlock` and `visitInlineHTML` as it records annotations, offsets shifted by the trimmed prefix and clamped. `Chapter.pages` and `PageBreak`, `DocumentContent.pages`, and `PagePosition` go in a new `Models/BookPages.swift`. `parseMultiChapterMarkdown` sets each page's chapter. `ReadingTextCache` stores pages (layout 2).
  - **The `includesPages` option** (default true) runs from `MarkdownCacheService`'s extraction to each parser's entry point: EPUB, PDF, DOCX, DAISY, textutil, and plain text, never braille's yet. For now it changes nothing.
  - **Goldens** move to format 2 with `page:` lines (`DocumentDump.swift`, whose header is "format 1" at `:51`), regenerated by `Scripts/test/update-goldens.sh`.
  - **No cache version change.**
  - **Files:** `Parsers/MarkdownPageMarker.swift` (new), `Parsers/MarkdownMarkerWriter.swift` (new), `Parsers/MarkdownParser.swift`, `Parsers/HTMLToMarkdownConverter.swift` (the move only), `Models/BookPages.swift` (new), `Models/DocumentContent.swift`, `Services/MarkdownCacheService.swift`, `Services/ReadingTextCache.swift`, the entry-point signatures of `EPUBParser.swift`, `PDFTextParser.swift`, `DOCXParser.swift`, `DAISYParser.swift`, `TextutilDocumentReader.swift`, and `PlainTextParser.swift`, `TextMouthProductionTests/DocumentDump.swift`, and `TestData/golden/*`.
  - **Tests:** new `MarkdownPageMarkerTests` (labels, escaping, forged and broken comments ignored); new `PageModelTests`:
    - reading text identical with and without markers;
    - every placement;
    - position to page, before the first page, several pages at one offset, and "of N".
  - **Existing classes:** `TextPipelineGoldenTests`, `DocumentDumpTests`, `ReadingTextCacheTests`, `ReadingTextOpenTests`, `UnicodeCoordinateTests`, `LegacyMarkdownCacheTests`, `LegacyDocumentContentModelTests`, `MarkdownTableReadingTests`, `EPUBHeadingRecoveryTests` (the moved writer), `ExportDocumentWalkerTests`, `PlaceRelocatorTests`, `PlaceRelocationAtRebuildTests`, `BookContentIndexTests`, `ContentIndexValidationTests`.
  - **Risks:** offsets after the trimmed prefix; UTF-16 with emoji; golden churn.
  - **Samples:** none (strings in tests). About 400 lines plus tests.
- [ ] **PG02 — Page as a navigation unit, with Next Page and Previous Page.** Difficulty M · Impact 5 · The user's wish ("rewind and fastforward by page… a navigation unit like the others"). After PG01.
  - **What:** `SkipUnit.page` between Paragraph and Heading. `performSkip` calls `nextPage()` and `previousPage()` (new, `ReaderViewModel+Pages.swift`, modelled on `nextHeading`), as section 4.2 says: Go Back returns, it lands at word starts, skipped sections are passed over, and it announces "Page 13". The F and B cycle passes over Page in a book without pages, and a Page skip there says "This book has no pages."
  - **Commands:** "Next Page" (Option-Command-Right Arrow), "Previous Page" (Option-Command-Left Arrow), and "Go to Page…" (Option-Command-G; PG03 makes what it opens), in the Navigate menu, disabled for a book without pages (a `FocusedValue`).
  - **Files:** `ViewModels/SettingsViewModel.swift`, `ViewModels/ReaderViewModel+Navigation.swift`, `ViewModels/ReaderViewModel+Pages.swift` (new), `ViewModels/ReaderViewModel.swift` (subscriptions), `Models/KeyboardShortcut.swift`, `App/MenuCommands.swift`, `Models/ReaderPageWording.swift` (new).
  - **Tests:** new `PageNavigationTests`; existing:
    - navigation: `LegacyNavigationAlgorithmTests`, `LegacySentenceParagraphSkipTests`;
    - settings: `SettingsPolicyTests`, `ConfigSyncTests`;
    - shortcuts: `ShortcutManagerTests`, `ShortcutListingTests`, `ShortcutConfigFileTests`, `MenuKeyShortcutTests`, `KeyboardReachabilityTests`, `WindowScopeShortcutTests`, `SpeakInfoShortcutTests` (no default key on two actions), `LegacyKeyboardShortcutScenarioTests`, `LegacyMenuVisibilityScenarioTests`.
  - **Risks:** a new `SkipUnit` raw value read by an older build falls back to the global unit (`SkipUnit(rawValue:)` is nil). The cycle's order changes by one stop.
  - **Samples:** built in tests. About 300 lines plus tests.
- [ ] **PG03 — Go to Page… and the page on the reader screen.** Difficulty M · Impact 5 · The user's wish ("go to page", "an optional page number/count on the reader screen"). After PG02, by the same worker.
  - **What:**
    - the status row's "Page 12 of 300" button and `JumpToPagePanel`, as section 4.4 says, with the four-way hints;
    - `JumpInputValidator.page`, its matching, refusals, and announcement;
    - Go to Page… opening the panel;
    - the setting "Show the page on the reader screen" (`showsPageInReader`, on), with its config.json key and a Pages group in the Playback tab.
  - **Files:** `Views/Reader/ReaderView.swift`, `Views/Reader/ReaderJumpPanels.swift`, `ViewModels/ReaderViewModel+Pages.swift`, `Models/ReaderPageWording.swift`, `ViewModels/SettingsViewModel.swift`, `Models/SettingsPolicy.swift`, `Views/Settings/SettingsView.swift`, `Services/ConfigService.swift`.
  - **Tests:** new `GoToPageTests` (validator, repeated labels, case, refusals); `JumpToTimeTests`, `SettingsPolicyTests`, `ConfigSyncTests`, `SettingsTabFitTests`, `ReaderTextAreaAccessibilityTests`; a hosted accessibility test of the button and field, which calls `skipUnlessHostedWindowsExposeAccessibility()` first; `make lint-a11y`.
  - **Risks:** the row's width at large text sizes (`SettingsTabFitTests`' approach).
  - **Samples:** none. About 300 lines plus tests.
- [ ] **PG04 — The page in Where Am I?.** Difficulty S · Impact 4 · The user's wish ("wear am I speech"). After PG03, by the same worker.
  - **What:** "Page 112 of 300" after the heading number in the brief and full summaries, from `PagePosition`, or "Before page 1". The setting "Say the page in Where Am I?" (`saysPageInWhereAmI`, on).
  - **Files:** `ViewModels/ReaderViewModel+WhereAmI.swift`, `Models/ReaderPageWording.swift`, and the PG03 settings files.
  - **Tests:** `WhereAmIPolicyTests`, `LegacyWhereAmIProductionTests`, `WhereAmIAnnouncementEndTests`, `SpeedBesideTimesTests`, `SettingsPolicyTests`, `ConfigSyncTests`.
  - **Risks:** a longer brief summary (question 3).
  - **Samples:** none. About 100 lines plus tests.
- [ ] **PG05 — EPUB page lists and page-break markup (and HTML's).** Difficulty M · Impact 5 · The user's wish (EPUB first). After PG01.
  - **Page targets:** the EPUB 3 nav page list and the EPUB 2 NCX `pageList`, read as page targets (id → label) beside the TOC targets. The converter writes `<!-- page: label -->` at the target element by the TOC targets' rules. Page-break elements (`PublicationSemantics.isPageBreak`: `epub:type="pagebreak"`, `role="doc-pagebreak"`) are pages when there is no list, labelled by `aria-label`, then `title`, then their text. Their text is never read.
  - **Standalone HTML** gets the roles through the same converter.
  - **`includesPages: false`** reads as 3.0.7 did.
  - **Files:** `Parsers/EPUBParser+Navigation.swift`, `Parsers/EPUBParser.swift`, `Parsers/HTMLToMarkdownConverter.swift`, `Parsers/PublicationSemantics.swift`, and `Parsers/HTMLParser.swift` if it needs the option.
  - **Tests:** new `EPUBPageListTests`; `EPUBHeadingRecoveryTests`, `EPUBPartialExtractionTests`, `PackageNavigationAuditTests`, `ParserContentFidelityTests`, `MarkdownTableReadingTests`, `TextPipelineGoldenTests` (area `import`).
  - **Risks:** targets in hidden content; a page list in another order than the spine; page breaks with visible numbers changing the reading text (PG09).
  - **Samples:** `epub3-pages/`, `epub2-pages/` (section 6). About 350 lines plus tests.
- [ ] **PG06 — PDF pages with their labels.** Difficulty S · Impact 5 · The user's wish (PDF). After PG01.
  - **What:** a block marker before each page's text, and before that page's outline headings, labelled by `PDFPage.label` (verified: `/PageLabels` labels, else 1 to N). Pages without text keep their marker.
  - **Unchanged:** a page boundary stays a paragraph boundary, as today, so the reading text is unchanged. Joining a sentence that runs across pages is a follow-up, since it would move places.
  - **Files:** `Parsers/PDFTextParser.swift`.
  - **Tests:** new `PDFPageLabelTests`; the `pdf` area (`PDFExtractionDiagnosticsTests`, `PDFImportReportTests`, `PDFPageTextMergerTests`, `PDFShortEmbeddedTextTests`, `PDFRecognitionPlanTests`, `PDFPageImageScannerTests`, `PDFTextRecognizerTests`); `TextPipelineGoldenTests`.
  - **Risks:** a 2,000-page PDF (made at test time); labels repeated across parts.
  - **Samples:** `pdf/labelled-pages.pdf`. About 120 lines plus tests.
- [ ] **PG07 — DOCX pages.** Difficulty M · Impact 4 · The user's wish (DOCX). After PG01.
  - **What:** page 1 at the start, then page starts from `w:br w:type="page"` (a space and an inline marker), `w:pageBreakBefore` (direct and by style), section breaks of type nextPage, oddPage, or evenPage, and `w:lastRenderedPageBreak`, merged where no letter or digit lies between them. Labels count from 1 with `w:pgNumType w:start` and `w:fmt`, through a first pass over the sections.
  - **Files:** `Parsers/DOCXParser+Converter.swift`, `Parsers/DOCXParser.swift`, `Parsers/DOCXParser+Styles.swift`.
  - **Tests:** new `DOCXPageTests`; `DOCXStructureTests`, `DOCXMalformedXMLTests`, `ParserContentFidelityTests`, `TextPipelineGoldenTests` (alice.docx gains about 20 pages from its 19 `w:pageBreakBefore`; test_book.docx and the docm, dotx, and dotm goldens gain only page 1).
  - **Risks:** files Word never laid out show fewer pages; Word's rendered break after an explicit one (merged).
  - **Samples:** alice.docx; `docx/page-breaks.docx`. About 250 lines plus tests.
- [ ] **PG08 — DAISY text books' pages.** Difficulty M · Impact 4 · After PG01.
  - **DTBook:** a `pagenum` (DAISY 3, NIMAS, standalone DTBook) becomes a marker labelled by its text, no longer the spoken "[Page 1]".
  - **DAISY 2.02:** the NCC's page spans (`page-normal`, `page-front`, `page-special`) give labels and SMIL targets, and a page's text fragment becomes a marker. This is handled before HTML conversion, so `HTMLToMarkdownConverter.swift` stays PG05's.
  - **Files:** `Parsers/DAISYParser+TextExtraction.swift`, `Parsers/DAISYParser+NCCParser.swift`, `Parsers/DAISYParser.swift`.
  - **Tests:** `DAISYInlineFragmentTests`, `DAISYMalformedXMLTests`, `DAISYPackageImportTests`, `DAISYPackageInventoryTests`, `DAISYMultiClipSectionTests`, `TextPipelineGoldenTests` (lathe, harbour, nimas-style-package, daisy202_test, hyperion).
  - **Risks:** the reading text changes where "[Page N]" was (PG09).
  - **Samples:** lathe_of_heaven_daisy.zip, wipo-treaty-d202-text-only.zip, harbour-standalone.xml; `dtbook/pages-front-and-inline.xml`. About 200 lines plus tests.
- [ ] **PG09 — Existing books gain pages.** Difficulty M · Impact 5 · After PG05 to PG08.
  - **What:** `Book.pageReaderVersion` (decoded if present), and a table of page-reader versions by format (`PageReaderVersions`, new) listing the formats merged so far. The startup batch re-reads a book whose format's version is newer than its stamp.
  - **Edited text is never replaced:** before writing, it reads the book again with `includesPages: false`. If that reading text differs from content.md's, it keeps content.md, stamps the row, and logs `PAGES_SKIPPED_CHANGED_TEXT` (section 5).
  - **Places:** T06's relocation moves the rest.
  - **Files:** `Services/MarkdownCacheService.swift`, `ViewModels/LibraryViewModel+Migration.swift`, `Models/Book.swift`, `Models/PageReaderVersions.swift` (new).
  - **Tests:** new `PagesUpgradeTests`:
    - an edited content.md is kept;
    - an EPUB whose page break read "12" has its places moved and none lost;
    - a PDF's places stay byte-exact.
  - **Existing classes:** `PlaceRelocationAtRebuildTests`, `PlaceRelocatorBookTests`, `TextCacheVerificationTests`, `TextCacheFingerprintTests`, `MetadataReaderVersionTests`, `MetadataRefreshTests`, `BookTextEditTests`; areas `places` and `storage`.
  - **Risks:** launch time (about 730 EPUBs, as on October 3); books only in the cloud; a second Mac with an older build.
  - **Samples:** the PG05 to PG08 samples. About 250 lines plus tests.
- [ ] **PG10 — Documentation of pages.** Difficulty S · Impact 3 · After PG09.
  - **What:** the user guide's reading and navigation pages (Page unit, Next Page, Previous Page, Go to Page…, the status row, Where Am I?, the two settings, which formats have pages and why a DOCX or DOC may show fewer than Word). The Edit Text page and `BookTextEditWording.explanation` add "Each <!-- page: … --> marks where a page begins." Also the keyboard list, an architecture page for content.md's markers, the README index, and the TODO records.
  - **Files:** `docs/user/*`, `docs/architecture/*`, `README.md`, `ARCHITECTURE.md`, `Models/BookTextEditWording.swift`.
  - **Tests:** `BookTextEditTests` and the wording pins.
  - **Risks:** none.
  - **Samples:** none.
- [ ] **PG11 — DOC, DOT, RTF, and WordML pages through textutil's plain text.** Difficulty M · Impact 3 · The user's wish ("docx / doc"). After PG05, whose converter it extends.
  - **What:** a second watched textutil run to plain text. Its form feeds (verified: `\page`, a DOC's break, a WordML break) are aligned by letter and digit counts with a 16-character check, and written as markers with a space where textutil joined the words. Labels are 1 to N. The format's line is added to `PageReaderVersions`.
  - **Files:** `Parsers/TextutilDocumentReader.swift`, `Parsers/TextutilHTMLStructure.swift`, `Parsers/HTMLToMarkdownConverter.swift`, `Models/PageReaderVersions.swift`.
  - **Tests:** `TextutilConverterTests`, `TextutilHTMLStructureTests`, `TextutilImportTests`, `TextutilSourceCheckTests`, `TextPipelineGoldenTests`.
  - **Risks:** alignment around lists, tables, and attachments; `\pagebb` and `\sect` are lost by textutil itself.
  - **Samples:** `rtf/page-breaks.rtf`, `doc/page-breaks.doc`, `wordml/page-breaks.wordml`. About 250 lines plus tests.
- [ ] **PG12 — Braille pages (BRF and PEF).** Difficulty M · Impact 4 · After `brailleemphasis` merges, and question 2.
  - **What:** the analyzer records where each page begins inside its first block. The reader back-translates blocks split there and joins them with the marker, labelled by the page number read as print, or the page's ordinal. It gets `includesPages`, and its line in `PageReaderVersions`.
  - **Files:** `Parsers/BraillePageAnalyzer.swift`, `Parsers/BrailleBookReader.swift`, `Services/MarkdownCacheService.swift` (the option's one line), `Models/PageReaderVersions.swift`.
  - **Tests:** the `braille` area (`BraillePageAnalyzerTests`, `BrailleImportTests`, `BrailleFileReaderTests`, `BrailleCellsTests`, `BrailleTranslatorTests`).
  - **Risks:** a translation split at a page boundary differing from the whole, which needs a test per bundled table.
  - **Samples:** the BRF and PEF samples; `brf/print-pages.brf`. About 200 lines plus tests.
- [ ] **PG13 — Plain text form feeds.** Difficulty S · Impact 1 · Optional.
  - **What:** each form feed starts a page, numbered from 1.
  - **Files:** `Parsers/PlainTextParser.swift`.
  - **Tests:** `TextFileDecoderTests`, `TextEncodingFidelityTests`, `TextPipelineGoldenTests`.
  - **Samples:** `txt-pages/form-feeds.txt`. About 60 lines plus tests.
- [ ] **PG14 — Pages in DAISY audiobooks.** Difficulty M · Impact 2 · After PG02.
  - **What:** the NCC's page spans (2.02) and the NCX `pageList` (3), resolved through SMIL to clip times, become pages at audio places (time × 10 characters). They are kept in the content index's audio chapters (`BookContentIndex` 1.0.0 to 1.1.0), since an audiobook has no content.md. Navigation and display work unchanged.
  - **Files:** `Parsers/DAISYParser+Audio.swift`, `Parsers/DAISYParser+NCCParser.swift`, `Parsers/DAISYParser+NCXParser.swift`, `Models/BookContentIndex.swift`.
  - **Tests:** the `analysis` area and `DAISYMultiClipSectionTests`.
  - **Samples:** an audio-only DAISY 2.02 with page spans and silent clips.
- [ ] **PG15 — Pages in export.** Difficulty M · Impact 2 · After PG12.
  - **What:** `ExportDocumentWalker` keeps page markers. BRF and PEF write BANA print page indicators (the print page number at the top right, and print page change lines), HTML writes `role="doc-pagebreak"` spans, and RTF and Word write nothing.
  - **Files:** `Services/Export/ExportDocument.swift`, `Services/Export/ExportDocumentWalker.swift`, `Services/Export/BrailleExportWriters.swift`, `Services/Export/HTMLExportWriter.swift`.
  - **Tests:** the `export` area.

## 9. Team plan

1. **Phase 1, one worker, sequential: PG01.** It is the only item that touches the parsers' entry points, the parse, and the goldens all at once. It goes first, merges into the team branch, and the rest start from it.
2. **Phase 2, five workers in parallel**, each on its own files:

| Worker | Items | Files it alone edits |
|---|---|---|
| reader | PG02, then PG03, then PG04 | `SettingsViewModel.swift`, `SettingsPolicy.swift`, `SettingsView.swift`, `ConfigService.swift`, `KeyboardShortcut.swift`, `MenuCommands.swift`, `ReaderViewModel.swift`, `ReaderViewModel+Navigation.swift`, `ReaderViewModel+Pages.swift` (new), `ReaderViewModel+WhereAmI.swift`, `ReaderView.swift`, `ReaderJumpPanels.swift`, `ReaderPageWording.swift` (new), `PlaybackControlsView.swift` if needed |
| epub | PG05 | `EPUBParser.swift`, `EPUBParser+Navigation.swift`, `HTMLToMarkdownConverter.swift`, `PublicationSemantics.swift`, `HTMLParser.swift`, goldens of alice.epub and frankenstein.html, `epub3-pages/`, `epub2-pages/` |
| pdf | PG06 | `PDFTextParser.swift`, a new PDF golden, `pdf/` |
| docx | PG07 | `DOCXParser.swift`, `DOCXParser+Converter.swift`, `DOCXParser+Styles.swift`, goldens of alice.docx, test_book.docx, docm, dotx, and dotm, `docx/` |
| daisy | PG08 | `DAISYParser.swift`, `DAISYParser+TextExtraction.swift`, `DAISYParser+NCCParser.swift`, goldens of the DAISY and DTBook fixtures, `dtbook/` |

   `samples.tsv` is shared, so each worker adds its rows in one commit, and the lead merges conflicts there by keeping both.
3. **Phase 3, one worker:** PG09, then PG10, after phase 2 merges.
4. **Later:** PG11 (after PG05's merge), PG12 (after `brailleemphasis`'s merge and question 2), then PG13, PG14, and PG15.
5. **Every worker:**
   - claims its files on the board and builds through the wrapper;
   - writes tests that never trap, play a sound, or touch `~/.TextMouth` or `UserDefaults.standard`;
   - runs, in one `run-area.py` call, its item's classes listed above, plus `TextPipelineGoldenTests`, `ReadingTextCacheTests`, `PlaceRelocatorTests`, and `ExportDocumentWalkerTests` (pages must never reach export);
   - runs `make lint-tests LINT_BASE=main`, and `make lint-a11y LINT_BASE=main` for the reader worker.
   - The reader worker also runs the `shortcuts`, `settings`, `headings`, and `reader-text` areas. Format workers run the `import` area, and the PDF worker the `pdf` area.
   - Merge `racefix` before the reader worker's branch, which edits `ReaderViewModel.swift` too.

## 10. Questions for you

1. **Existing books.** Books already in your library gain pages only by being read again from their files, which once replaced text changed with Edit Text. Should every EPUB, PDF, Word, and DAISY book be read again at the next launch, with your places, bookmarks, and skipped headings kept, and any book whose text was changed by hand left as it is, without pages, until you choose Redo Text Extraction for it?
   - **Recommended: yes.**
2. **Braille page numbers.** A BRF transcribed from a print book carries two page numbers: the braille page's, at the bottom right, and the print book's, at the top right, which changes partway down some pages. Which should "page" mean for a braille book?
   - **Recommended: the braille page.** Every BRF has it, and it matches the file's own pages and what an embosser or a braille display's page count shows. Print pages could follow as a second choice.
3. **Where Am I? and the screen.** Should the brief Where Am I? (W) also say "Page 112 of 300", after the heading number, and should the reader screen show it, both as settings that start on?
   - **Recommended: yes to both.** At 500 words a minute it adds under a second to the brief summary, and either can be turned off.
4. **Keys.** Next Page Option-Command-Right Arrow, Previous Page Option-Command-Left Arrow, and Go to Page… Option-Command-G?
   - **Recommended: yes.** They pair with Next and Previous Heading on Option-Command-Down and Up, and none is in use. All three can be changed in the Shortcuts tab.

## What I could not verify

- **The comment rule in swift-markdown's cmark-gfm** for text containing `--`. The marker escapes `--`, so neither rule matters.
- **Whether Word writes `w:lastRenderedPageBreak` after its own explicit page breaks.** PG07 merges page starts with nothing between them, so either way counts once.
- **Whether textutil reads an ODT's page breaks.** Its own ODT writer dropped the break, so no ODT holding one was at hand.
- **Whether a committed Edit Text change leaves any trace** a rebuild could check without re-reading the book (`BookTextEditing.swift` fingerprints were not read in full). PG09's comparison does not depend on it.
- **An SF Symbol for the Page unit** on the deployment target, and how VoiceOver in TextEdit reads an inline comment. Neither was tried.
- **Probe artifacts** (the RTF, the conversions, the labelled PDF, and the scripts) are in `build/pages-research/`, which is gitignored. The RTF's text and the PDF's label tree are given above so that the team can make them again.

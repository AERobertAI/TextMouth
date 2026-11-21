# epubexport: Export a text book as EPUB 3 (branch `export/epub3`, FMT28)

Read `Scripts/agents/briefs/2026-11-06/common.md` first. You are `epubexport`. You own `TextMouth/Services/Export/`, `BookExportService.swift`, and the Export dialog's Convert to choice. Parts of `readers-common.md` are about readers and don't apply; its builds, tests, board, and rules do.

The user wished for export in any supported format. The Export dialog's Convert to menu already makes a text book's text HTML, RTF, Word 97-2003, BRF, or PEF as well as Markdown. Add EPUB. An EPUB holds the book's structure, so a blind reader's headings, pages, and contents go with it to any reading system.

## What to read

- `FORMATS-RESEARCH-2026-10-17.md`, §7.3 and the summary at its top (`grep -n "EPUB 3\|FMT28"`). A prototype passed EPUBCheck there with no errors or warnings.
- The TODO's line for FMT28 (`grep -n "FMT28" TODO-2026-09-04.md`).
- `TextMouth/Services/Export/` and `BookExportService.swift`: how a conversion runs, shows progress, stops, and leaves nothing partial behind. Use all of it. A new format joins the existing path. It isn't a path of its own.
- How the HTML conversion walks a book's Markdown. Reuse that walker for the chapters' XHTML. Don't write a second one.
- `docs/user/` on Export, for how it's described today.

## What to build

- **The file:**
  - `mimetype` first and stored, then `META-INF/container.xml`, with ZIPFoundation.
  - A package document: identifier, title, creator, language, modified date.
  - `nav.xhtml` from the headings, nested by level, and correct when levels skip.
  - An XHTML file per chapter.
  - A `page-list` nav, and page break elements with `epub:type="pagebreak"` and `role="doc-pagebreak"`, when the book has pages. Every page marker in the Markdown becomes a target, so Page works in a reading system.
- **Accessibility metadata, stated truthfully:** `schema:accessMode` textual, `schema:accessModeSufficient` textual, `schema:accessibilityFeature` (tableOfContents, readingOrder, structuralNavigation, and pageNavigation only when there are pages), `schema:accessibilityHazard` none, and a plain `schema:accessibilitySummary`. Don't claim conformance to a standard with `dcterms:conformsTo`, because nothing here certifies it. `lang` and `xml:lang` on the documents, from the book's language where known, and say what you chose where it isn't. A `<title>` in every document. Real `<h1>` to `<h6>`, lists, tables, and emphasis.
- **Identifier:** a stable `urn:uuid` for the book, so exporting it twice gives the same identifier. The modified date is the export's own, injected in tests so a test can be deterministic.
- **Long books:** a chapter at a time, to a temporary place, with no whole-book string in memory where the existing path avoids one. Stop works as it does for other conversions, and a stopped or failed export leaves nothing behind. Every string escaped for XML, including a title holding `&` or `<`, and characters XML 1.0 forbids dropped, not written.
- **The dialog:** one more choice in Convert to, named "EPUB", in the same words and order of importance as its neighbors, with an extension of `.epub`. It's offered only for text books, as the other conversions are. VoiceOver reads it like the others. No other wording changes.
- **Both apps:** the code compiles for iOS. `make typecheck-ios` stays at 0 errors and 0 warnings.

## Tests

- Structure: `mimetype` first and stored, and the rest as the research describes.
- **The round trip:** export, then import the file through TextMouth's own EPUB reader, and compare the reading text through `MarkdownDocParser.parseChapter`: the same words in order, the same headings at the same levels, the same pages.
- Hostile titles and text; an empty book; a book with no headings; one chapter of many; heading levels that skip; a heading that's only punctuation; a page marker at the very start and very end.
- Stop partway through, and a failing destination, leave nothing behind.
- Tests never depend on `epubcheck` being installed. They use a sandbox of their own, never the live library.

## EPUBCheck

`/opt/homebrew/bin/epubcheck` is on this Mac. By hand, under the lock, run it on real exports of at least 10 varied books made from `TestData/` samples: an EPUB, a DOCX, a long plain text, a book with pages, a right-to-left or non-Latin text if a sample has one, and so on. Every one must show 0 errors and 0 warnings. Give the table in your report. If `epubcheck` gives a warning you think is wrong, say so with its message. Don't dismiss it.

## Report

Add to the common list: the EPUBCheck table, the round trip's results, what's lost in an export (pictures, for one, if the book's Markdown has none), and whether a book's cover or images could follow later.

# Brief: `stable020-parsers` (ST02, ST05, ST09)

- **Slug:** `stable020-parsers`. **Branch:** `stable020/parsers`, made with `git checkout -b stable020/parsers team/stable020`. **Team:** `stable020`, lead `stable020-lead`.
- **Read first:** `Scripts/agents/briefs/2026-10-19/teams-common.md`, its sections "The worker's part", "Rules for everyone", "The board", "Builds", and "Lessons every brief applies". Nothing else of it.
- **Why:** the user's official 0.2.0 install reads every EPUB again at its first launch (the page re-read). These three fixes keep words from being lost. Plan: `PLAN-0.2.0-2026-10-23.md` §3.2 items 2, 5, and 9.
- **Register with:** `--files TextMouth/Parsers/MarkdownPageMarker.swift,TextMouth/Parsers/HTMLToMarkdownConverter.swift,TextMouth/Parsers/DAISYParser.swift,TextMouth/Parsers/ArchiveEntryReader.swift,TextMouth/Parsers/EPUBParser.swift,TextMouth/Parsers/EPUBParser+Navigation.swift,TextMouth/Parsers/MarkdownParser.swift`
- **Three commits, in this order:** ST02, then ST05, then ST09. Each with its tests.
- **Disk:** before every build, `df -g /System/Volumes/Data` must show at least 4 GB available; if not, post to `stable020-lead` and wait for an answer (`bbs watch stable020-parsers --timeout 240`). Your build folder is `/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-stable020-parsers`. Write all three commits' code and tests before your first build if you can; fewer builds is better.

## Commit 1: ST02, a page-break element that holds words

**The bug.** `HTMLToMarkdownConverter.convertElement` (`TextMouth/Parsers/HTMLToMarkdownConverter.swift:196-225`) skips every child of a page-break element when pages are read (`isPageBreakElement`, line 421, true only then). An EPUB that wraps real words in such an element loses them in the reading with pages. The reading without pages (cache format 3.0.7, `includesPages: false`) reads them, so the first launch's compare finds content.md unchanged, keeps no copy, and the words are gone. DAISY 2.02 already has the guard this lacks: `DAISY202PageMarker.isNumber(in:)` (`TextMouth/Parsers/DAISYParser.swift:944-967`), used at :785-795.

**Do:**
1. Add to `MarkdownPageMarker` (`TextMouth/Parsers/MarkdownPageMarker.swift`) one static function, the single rule both formats use:
   ```swift
   static func isNoMoreThanLabel(_ text: String, label: String) -> Bool
   ```
   Collapse every run of whitespace in both strings to one space and trim them (`split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")`). Then: an empty text is true; a text longer than `maximumLabelLength` Characters is false; an empty label is true; otherwise true exactly when the text contains the label or the label contains the text, ignoring case (`localizedCaseInsensitiveContains`). Doc comment: what it is for (ST02, PG08), each case with an example ("12" or "Page 12" under the label "12"; "12" under the label "Page 12"), and that longer or other text is real words a listener must hear.
2. `DAISY202PageMarker.isNumber(in:)` returns `MarkdownPageMarker.isNoMoreThanLabel(fragmentText, label: label)`. Update its doc comment: the label holding the text counts too.
3. In the HTML converter, a page-break element's own text is skipped only when it is no more than its page's label; otherwise its page's marker (if any) is written before it, as now, and the element is converted like any other element of its tag (the `switch tag` below the skip), so its words, emphasis, and inner destinations are read.
   - The element's text is `HTMLReadingText.inlineText(of: element)`.
   - Its page's label: the label of the page marker the element writes, when it writes one; otherwise its own attribute label (below); otherwise "".
   - Compute the element's page marker exactly once (`namedPageMarker` records the id as written, so a second call loses the page): change `destinationMarkers(for:tag:isPageBreak:context:)` to take the computed `page: MarkdownPageMarker?` instead of computing it, and have both callers (`convertElement`, and `destinationMarkers(inside:context:)` at :398-413) call `pageMarker(...)` first.
   - One private helper decides, used in both places: `readsOwnText(ofPageBreak element: Element, page: MarkdownPageMarker?) -> Bool`, true when the element's text is more than its label. `convertElement` skips the children only when `isBreak && !readsOwnText(...)`. `destinationMarkers(inside:)` recurses into a page-break element exactly when `readsOwnText(...)` is true.
4. `pageMarker(for:tag:isPageBreak:context:)` (:431-455): factor the `aria-label`, then `title`, lookup into one private helper `attributeLabel(of element: Element) -> String?` (the first that is not blank, else nil), used by `pageMarker` and by the label rule above. A page-break element without either attribute takes its text as its page's label only when that text could be a label: not blank, and no longer than `maximumLabelLength` after collapsing whitespace. A longer text is real words: such an element begins no page unless the page list names it, and its words are read. (A page label made of a paragraph's first 32 characters would be read out by Go to Page.)
5. Correct every comment that says a page-break element's text is never read: `HTMLPageTargets.pageBreaksArePages` (:12-15), `Context.includesPages` (:160-162), the comment above the skip (:219-220), `destinationMarkers(inside:)`'s doc (:395-397), `isPageBreakElement`'s doc (:417-420), and `PublicationSemantics.isPageBreak`'s ("Its own text is usually the page's number" may stay).
6. No `PageReaderVersions` bump: no installed TextMouth has stamped any book with a page reader (the user's installed build, 0.1.1, predates pages), so 0.2.0's first launch reads every EPUB with this reader. Say so in the commit message.

**Tests,** in `TextMouthProductionTests/EPUBPageListTests.swift`, a new `// MARK: - Page-break elements holding words (ST02)`, using the class's own helpers (`parsed(_:includesPages:)`, `text(from:in:)`, `assertPages(of:_:)`, `makeEPUB(manifest:spine:spineAttributes:members:)`, `xhtml(_:)`):
- `testAPageBreakHoldingAParagraphIsReadAfterItsPage`: `<p>Before.</p><div epub:type="pagebreak" title="12"><p>The war began in the spring of that year, and nobody was ready for it.</p></div><p>After.</p>`: the text contains that sentence whole; the pages' labels are `["12"]`; page 12's text begins "The war began".
- `testShortWordsUnlikeTheLabelAreRead`: `<p>One <span epub:type="pagebreak" title="12">Hello there</span> two</p>`: the text contains "Hello there"; pages `["12"]`, page 12's text begins "Hello".
- `testANumberUnderALongerLabelIsNotRead`: `<p>One <span role="doc-pagebreak" aria-label="Page 12">12</span>two</p>`: text `"One two"`; pages `["Page 12"]`.
- `testACaptionedNumberIsNotRead`: `<p>One <span epub:type="pagebreak" title="xii">Page XII</span> two</p>`: the text does not contain "XII" and contains "One" and "two"; pages `["xii"]`.
- `testAnUnlabelledPageBreakHoldingAParagraphIsReadAndIsNoPage`: `<div epub:type="pagebreak"><p>The war began in the spring of that year, and nobody was ready for it.</p></div>`: the text contains the sentence; no pages; the Markdown has no `<!-- page:`.
- `testAnUnlabelledShortNumberIsStillAPageAndNotRead`: `<p>One <span epub:type="pagebreak">xii</span>two</p>`: text `"One two"`; pages `["xii"]`.
- `testAListedPageBreakHoldingAParagraphIsRead`: an EPUB 3 book (as `testTheNavigationDocumentsPageListWinsOverTheNCXs` builds one) whose nav page list names `ch1.xhtml#p7` as "7", with the chapter `<h1>Title</h1><p>Alpha.</p><p id="p7" epub:type="pagebreak">The war began in the spring of that year, and nobody was ready for it.</p>`: `assertPages(of: first, [("7", "The war began")])`, and the text contains the sentence.
- `testWithoutPagesAPageBreakHoldingWordsReadsAsBefore`: the first test's HTML with `includesPages: false`: the same reading text as with pages, and no marker.

In `TextMouthProductionTests/MarkdownPageMarkerTests.swift`: `testNoMoreThanLabel`, a table of `(text, label, expected)`: `("", "12", true)`, `("  ", "12", true)`, `("12", "12", true)`, `("Page 12", "12", true)`, `("12", "Page 12", true)`, `("p. XII", "xii", true)`, `("Hello there", "12", false)`, `("Chapter One", "", true)`, `(String(repeating: "a", count: 33), "", false)`, `("12\n  ", "12", true)`, `("Page\n12", "Page 12", true)`. Each failure message names the row.

**Existing test you may re-document, not change:** `EPUBPageListTests.testAPageBreaksOwnTextIsNeverRead`: rename it `testAPageBreaksOwnNumberIsNotRead` and say in its doc comment that a page-break element's own number is not read; its assertions stay exactly as they are.

**Prove it on the real samples** (not committed): with a throwaway test or script run once, count the page-break elements in every EPUB under `TestData/format-samples` (copied to a temporary folder first; never change that folder) whose text is more than their label. Report the count and which samples, in your report.

## Commit 2: ST05, a marker at a line's start in content.md

**The bug.** CommonMark makes a line that begins with `<!--` an HTML block, the whole line included. `PlainTextExtractor.visitHTMLBlock` (`TextMouth/Parsers/MarkdownParser.swift:247-258`) keeps only a block that is exactly one marker, so the words after a marker on that line are not read, and the page or heading is lost too. TextMouth's writers never begin a line with a marker followed by words (`MarkdownMarkerWriter.swift:38-45`), but an Edit Text change can: deleting the text before an inline marker, or joining lines. After the first launch every text book's content.md holds markers.

**Do:**
1. In `visitHTMLBlock`: when the block's raw HTML, after up to three leading spaces, begins with one or more complete markers of ours, each a comment from `<!--` to its first `-->` that `MarkdownHeadingAnnotation.decode` or `MarkdownPageMarker.decode` accepts, separated only by spaces or tabs, and something other than whitespace follows the last of them:
   - each such marker is taken exactly as a block holding only that marker is taken now (`separateBlock()`, then the heading or page), and only when `includeNavigationHeadings` is true;
   - then the rest of the block's raw HTML is parsed as Markdown on its own (`Document(parsing:)`), and each of its blocks is visited with this same extractor, as any block is, so its words, emphasis, and offsets are read in place. Its words are read whether or not `includeNavigationHeadings` is true.
   - Peel the leading markers in a loop, never by recursion (a line of ten thousand markers must not deepen the stack).
2. A block that is exactly one marker, and a block that begins with any other comment (not ours), read exactly as now.
3. Doc comment on `visitHTMLBlock`: why (ST05), what an edit can make, and that the writers never write such a line, so nothing they wrote parses differently.
4. No version bump: every content.md TextMouth wrote parses as before, and the reading-text cache never serves another build's reading (`ReadingTextCache`'s `producer`). Say so in the commit message.
5. Look, without changing it, at how `MarkdownCacheService` splits content.md at a chapter line (`<!-- chapter: `, `MarkdownCacheService.swift:36`) followed by words on the same line, and say in your report what becomes of those words.

**Tests,** in the class that already tests `MarkdownDocParser.parseChapter(markdown:title:includeNavigationHeadings:)` with markers (find it with `grep -ln "includeNavigationHeadings: true" TextMouthProductionTests`; use `MarkdownPageMarkerTests` if several do), a `// MARK: - A marker at a line's start (ST05)`:
- `testWordsAfterAPageMarkerAtALineStartAreRead`: `"First line.\n<!-- page: 12 -->Second line words.\n"` with navigation: the text contains "First line." and "Second line words."; one page, labelled "12", at the offset of "Second".
- `testWordsAfterAHeadingAnnotationAtALineStartAreRead`: a heading annotation's own `markdown` (build it as the class builds one), then `"Words after."` on the same line: the text contains "Words after."; a navigation heading at the offset of "Words".
- `testWordsAfterTwoMarkersAreRead`: `"<!-- page: 3 --> <!-- page: 4 -->Both pages here.\n"`: pages "3" and "4", both at "Both"; the words read.
- `testWordsAfterAMarkerAreReadWithoutNavigation`: the first test's Markdown with `includeNavigationHeadings: false`: the words read, no page.
- `testWordsAfterAMarkerInAListItemAreRead`: `"- <!-- page: 3 -->Item words\n"`: "Item words" read, page "3" there.
- `testEmphasisAfterAMarkerIsRead`: `"<!-- page: 4 -->Some *emphasised* words\n"`: the text contains "Some emphasised words".
- `testAMarkerAloneOnItsLineReadsAsBefore`: `"Alpha.\n\n<!-- page: 5 -->\n\nBeta.\n"`: text and page exactly as before your change (state the expected values from a run on the team branch before your change).

## Commit 3: ST09, EPUB members looked up by exact case

**The bug.** `EPUBParser.extractString(archive:path:)` (`TextMouth/Parsers/EPUBParser.swift:496-507`) and `EPUBParser+Navigation.swift:258` and `:311` look a member up with `archive[path]` alone, so a badly made EPUB whose manifest names `Text/Chapter1.xhtml` for the member `text/chapter1.xhtml` loses that chapter at import, with a warning. DAISY already falls back to a case-insensitive match (`DAISYParser.entry(at:)`, `TextMouth/Parsers/DAISYParser.swift:181-190`).

**Do:**
1. Add to `IndexedArchive` (`TextMouth/Parsers/ArchiveEntryReader.swift:145-191`): `func file(at path: String) -> Entry?`: the entry at exactly `path`, or else the first file entry whose path matches it without regard to case (`self[path] ?? file(matchingCaseInsensitively: path)`). Doc comment.
2. `DAISYParser.entry(at:)` uses it (DRY).
3. For a plain `Archive`, add in the same file `extension Archive { func file(at path: String) -> Entry? }` with the same rule: `self[path] ?? first { $0.type == .file && $0.path.lowercased() == path.lowercased() }`. First check (`grep -rn "func file(at" TextMouth`) that nothing else has that name; if something does, name both `memberFile(at:)` instead.
4. Every lookup of an EPUB member by its path uses them: the two `extractString` overloads (:498-507), `readSpineDocument` (:258), and the fragment conversion (:311). Find any others with `grep -n -E "archive\[|\.archive\[" TextMouth/Parsers/EPUBParser*.swift TextMouth/Services/MarkdownCacheService.swift`, and switch each lookup by path (not an enumeration of entries).
5. **Completion check:** `grep -n -E "archive\[" TextMouth/Parsers/EPUBParser*.swift` finds nothing.
6. Say in the commit message: a book already in the library changes only when it is read again; at the first launch of 0.2.0 an EPUB whose spine named a member in another case gains that chapter, and since its content.md then differs from the reading without pages, the batch keeps a copy of the old text (`content.md.edited-…`) and counts it as replaced.

**Tests:** in the test class that builds EPUBs from members and checks a missing spine member (find it: `grep -rln -E "missingMember|omitted" TextMouthProductionTests`; if none fits, `EPUBPageListTests`):
- `testASpineMemberNamedInAnotherCaseIsRead`: the manifest's item `href="Text/Chapter1.xhtml"`, the ZIP member `text/chapter1.xhtml` holding `<h1>One</h1><p>Words of the first chapter.</p>`: the book has that chapter, its text contains "Words of the first chapter.", and no missing-member warning is reported.
- `testAnExactMatchWinsOverACaseInsensitiveOne`: two members, `ch1.xhtml` and `CH1.xhtml`, with different words, the manifest naming `ch1.xhtml`: the words of `ch1.xhtml` are read.
- `testThePackageDocumentNamedInAnotherCaseIsFound`: `container.xml` names `OEBPS/Content.opf`, the member is `OEBPS/content.opf`: the book opens with its chapter.

## Test classes to run
`EPUBPageListTests`, `MarkdownPageMarkerTests`, `DAISYPageTests`, `EPUBHeadingRecoveryTests`, `TextPipelineGoldenTests`, the class your ST05 and ST09 tests are in, then the `pages` area (`python3 Scripts/test/run-area.py -h` lists the areas; add the area holding `EPUBParserTests` or the EPUB parser classes). Run `make lint-tests LINT_BASE=team/stable020` before you report.

## Do not touch
Any file not named above, `*.md`, `Scripts/test/areas.conf`, and the transcripts team's files. An exact-output test other than the one named above that fails means stop and ask your lead.

## Report
teams-common's form, and also: the sample count from commit 1, and what becomes of words after a chapter line (commit 2).

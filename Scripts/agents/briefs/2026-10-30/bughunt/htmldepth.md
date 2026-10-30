# bughunt-htmldepth: deeply nested HTML must not overflow the stack

Worker slug `bughunt-htmldepth`, branch `bughunt/htmldepth` (from `team/bughunt`). Read `README.md` beside this file first.

## The bug (verified by the lead)
Both HTML walkers recurse once per element level, with no bound:
- `TextMouth/Parsers/HTMLToMarkdownConverter.swift`: `convertNode` (line 184) → `convertChild` (192) → `convertElement` (201) → `convertNode` again (354; also the recursions at 273, 287, 292, 313, and `convertListItems` at 541). Its state travels in `Context` (156-181).
- `TextMouth/Parsers/HTMLReadingText.swift`: `appendChildren(of:)` (176) → `append(_:)` (183) → `appendElement(_:tag:)` (217) → `appendChildren` again (234).

SwiftSoup 2.13.9 builds a tree of any depth (its insertion and its `Node.deinit` are iterative), so markup with 20,000 unclosed `<div>`s, about 100 KB, reaches these walkers whole. They run on 512 KiB GCD worker stacks: a feed merge (`FeedRefresher.swift:453`, `OffMainWork.run(on: .global(qos: .utility))`, through `FeedReconciler` → `FeedTextConverter.read(html:)` line 63), every import (the import queue), and a fetched article page (`FeedEpisodeImporter.swift:387`). A few thousand levels overflow the stack and TextMouth crashes; for a feed, Refresh at Launch makes it crash again at every launch. The team already made `TextutilPageBreaks.walk` (`TextutilPageBreaks.swift:182`), `TextutilHTMLStructure`, the feed's tidy walk, and `FeedOPML` iterative for this reason; these two walkers were missed.

## What to build
1. **One limit, in one place.** In `HTMLReadingText.swift` (which already holds `HTMLReadingBoundary`, shared by both walkers), add a small type holding the deepest element nesting the walkers follow, **100 levels**, with a comment saying why (worker stacks of 512 KiB; far deeper than any real page or book; the Markdown the converter writes stays shallow enough for swift-markdown, which also recurses).
2. **One iterative reading of a too-deep subtree, shared by both walkers.** Beside it, a function that returns the words of an element's whole subtree as one line of plain text, walking with an explicit stack (never recursion): text nodes in document order; nothing from `script` or `style`; nothing from an element the caller's exclusion test leaves out (pass it in, since the converter asks `context.readingFlow.excludes(_:)` and the direct reader asks `PublicationSemantics.isExcludedFromReadingFlow(_:)`); an `img`'s `alt`; a space wherever a boundary (`HTMLReadingBoundary.of(_:tag:)` other than `.none`, and `br`) would separate words; the result's whitespace collapsed with `HTMLReadingText.collapsingWhitespace(_:)`.
3. **The converter.** `Context` carries the element depth. Converting an element at a depth past the limit writes, instead of recursing, the subtree's words from item 2 as one block of its own (a paragraph, separated as a block element is), escaped as the converter escapes text (`appendText` / `MarkdownLiteral`), and nothing else of that subtree (no heading, list, link, page marker, or destination). Nothing changes for any element within the limit.
4. **The direct reader.** `HTMLReadingText` counts element depth the same way and, past the limit, writes the same words as one paragraph, so a direct reading and a cached reading of the same deep page agree, as they do today for every page within the limit.
5. Nothing else changes: every golden and every existing test must pass unchanged.

## Tests
- A helper in `TextMouthProductionTests/DamagedFileTestSupport.swift` (an `XCTestCase` extension for damaged input): runs a `@Sendable` body on a `Thread` whose `stackSize` is 512 KiB, the size of a GCD worker's stack, waits for it with a timeout (60 s), records an `XCTFail` on timeout rather than trapping, and returns the body's result. The project builds in Swift 6 with complete concurrency checking and targets macOS 14: hand the result back through something Sendable (such as `OSAllocatedUnfairLock`), not an `@unchecked Sendable` box; if you must add `@unchecked Sendable` or `nonisolated(unsafe)`, run `UncheckedConcurrencyPolicyTests` and `LogContentPolicyTests` too. Later depth fixes will reuse this helper, so name and comment it for any parser.
- In `LegacyHTMLToMarkdownTests` (`TextMouthProductionTests/LegacyParserAndHashTests.swift:109`):
  - the crash test: `String(repeating: "<div>", count: 20_000) + "Deep words"` converted on the 512 KiB stack contains "Deep words";
  - the test that fails without the fix and never crashes: 150 nested `<blockquote>`s around "Deep words", converted on the main thread, contains "Deep words" and no line with more than 100 `>` markers (today the line has 150).
- In `FeedParserTests`: `FeedTextConverter.read(html:)` of the 20,000-`<div>` markup, on the 512 KiB stack, returns text whose plain text contains "Deep words".
- For the direct reader, in `ParserContentFidelityTests`: the 20,000-`<div>` markup written as `deep.html` in the test's temporary folder and read with `BookParser.parse(url:format: .html)` on the 512 KiB stack contains "Deep words"; and for the 150-blockquote page, the direct reading's text equals the plain text the cached path gives (`HTMLToMarkdownConverter.convert` then `MarkdownDocParser.parseChapter(markdown:)`), compared as the existing agreement tests compare them (grep `IntegrationReadingTextTests` for how).
- Run: `LegacyHTMLToMarkdownTests FeedParserTests ParserContentFidelityTests IntegrationReadingTextTests TextPipelineGoldenTests DocumentGoldenTests EPUBHeadingRecoveryTests EPUBPageListTests`.

## Do not touch
Anything outside the two parsers and the test files named. `EPUBParser+Navigation.swift`, `DAISYParser+NCCParser.swift`, `PDFTextParser.swift`, and `MarkdownParser.swift` have their own depth fixes in other tasks.

## Completion check
`grep -n "maximumDepth\|depth" TextMouth/Parsers/HTMLToMarkdownConverter.swift TextMouth/Parsers/HTMLReadingText.swift` shows the one limit used by both walkers, and the limit's number appears in exactly one place.

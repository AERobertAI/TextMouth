# bughunt-navdepth: navigation and outline walkers without recursion, and EPUB XML that never loads external entities

Worker slug `bughunt-navdepth`, branch `bughunt/navdepth` (from `team/bughunt`). Read `README.md` beside this file first. Three commits, each with its tests.

## 1. Four walkers recurse once per level of their document's nesting (verified by the lead)
- `TextMouth/Parsers/EPUBParser+Navigation.swift:569-581`, `ncxTargets(in:relativeTo:level:)`, calls itself for every nested `navPoint`. The NCX is read with Foundation's `XMLDocument(xmlString:)` (`:436`), which builds a tree of any depth (`XMLParser` stops at about 256 levels; `XMLDocument` does not).
- `EPUBParser+Navigation.swift:586-614`, `linkedTargets(in:relativeTo:level:insideTOC:readingFlow:)`, calls itself for every element of a navigation document (SwiftSoup, any depth).
- `TextMouth/Parsers/DAISYParser+NCCParser.swift:99-117`, `collect(from:into:)`, calls itself for every element of a DAISY 2.02 `ncc.html` that is not a heading, `meta`, or page entry.
- `TextMouth/Parsers/PDFTextParser.swift:730-751`, `traverseOutline(_:depth:document:entries:)`, calls itself for every outline level; it is the first thing `extract(from:)` does (`:113`, through `extractOutline`, `:721`), and PDFKit serves an outline of any depth.

Imports run on the import queue, a GCD worker thread with a 512 KiB stack, so an EPUB, DAISY book, or PDF whose navigation or outline nests a few thousand deep crashes TextMouth during its import.

Fix each with an explicit stack of the nodes still to visit (with their level and, for `linkedTargets`, their `insideTOC`), pushing children in reverse so they are visited in document order, exactly as `elements(in:pruning:)` in the same file (`:656-668`) and the converter's `collectNavigationDetails` (team branch, `HTMLToMarkdownConverter.swift`) already do. Every target, heading, page, and outline entry comes out in the same order with the same level as today: the result of every existing test must not change. Keep each function's doc comment true (say it walks without recursion, and why).

## 2. EPUB's XML is read with external entities allowed (the tests team's audit item U01, handed to bughunt, board #4095)
`TextMouth/Parsers/EPUBParser.swift:134`, `:264`, `:403`, `:431`, and `EPUBParser+Navigation.swift:436` call `XMLDocument(xmlString:)` with no options, so a crafted EPUB's `<!ENTITY x SYSTEM "file:///...">` can put a local file's text into the title, author, or headings, then into library.json, and, on Edit Metadata, into the EPUB itself. Every other XML reader in the app refuses them (`FeedParser.swift:244`, `FeedOPML.swift:117`: `.nodeLoadExternalEntitiesNever`).

Fix: one shared way to read EPUB XML, a small static function in `EPUBParser` (for example `xmlDocument(_ xml: String) throws -> XMLDocument`) that passes `options: [.nodeLoadExternalEntitiesNever]`, with a doc comment saying why; every one of the five calls uses it (DRY), and no `XMLDocument(xmlString:` is left in the two files without that option.

## Tests
Use the helper `onWorkerSizedStack(timeout:_:)` in `TextMouthProductionTests/DamagedFileTestSupport.swift` (added by the htmldepth fix on the team branch) to run each parse on a 512 KiB stack. The deep tests crash without the fix: per the README, never run them before the fix is in. Each walker also gets a shallow test that pins the order and levels (several nested and sibling levels), which must pass before and after.
- `EPUBHeadingRecoveryTests` (beside `testNestedNCXUsesDeclaredSpineTOCAndCanonicalPaths`; grep how its EPUBs are built in the test's folder): an EPUB whose toc.ncx nests 5,000 `navPoint`s, each with a label and a `content src` naming the one chapter, imports or parses (whichever that test calls) on the worker stack without crashing, with its chapter's words; a navigation document (EPUB 3 `nav`) nesting 20,000 `<ol><li>` levels the same.
- `DAISYMalformedXMLTests`: an `ncc.html` nesting 20,000 `<div>`s around an `<h1>` gives that heading.
- `LegacyPDFParserTests`: build a `PDFDocument` with one page (grep the class for how it makes a PDF) and an outline 5,000 levels deep (each `PDFOutline` the only child of the one before, each with a label and a destination on the page), and call `PDFTextParser.extractOutline(from:)` on the worker stack; it returns without crashing, with the 5,000 entries in order and levels 0 through 4,999, as the recursion gave them (only the recursion goes; whatever caps a level later stays as it is). Keep the `PDFDocument` referenced by the test itself until the test ends, so its outline is released on the main thread, never on the 512 KiB one.
- U01, in `EPUBMetadataTests` (grep how it builds an EPUB): write a text file holding "SECRET-FILE-TEXT" in the test's folder, and an EPUB whose OPF declares `<!DOCTYPE package [<!ENTITY leak SYSTEM "file:///<that path>">]>` and titles the book `&leak;`; the parsed title does not contain "SECRET-FILE-TEXT" (an entity that is never loaded reads as empty or as nothing; assert only that the text is absent and that the parse does not throw, or, if Foundation refuses the document outright, that the import reports a damaged EPUB rather than crashing; settle which on the real behavior and say so in your report).
- Run: `EPUBHeadingRecoveryTests DAISYMalformedXMLTests LegacyPDFParserTests EPUBMetadataTests EPUBPageListTests EPUBPartialExtractionTests TextPipelineGoldenTests DocumentGoldenTests DAISYPackageImportTests`.

## Do not touch
`HTMLToMarkdownConverter.swift` and `HTMLReadingText.swift` (done on the team branch), `MarkdownParser.swift`, and anything else in the parsers.

## Completion check
`grep -n "XMLDocument(xmlString" TextMouth/Parsers/EPUBParser.swift TextMouth/Parsers/EPUBParser+Navigation.swift` finds only the one shared function's call, with the option; and none of `ncxTargets`, `linkedTargets`, `collect(from:`, `traverseOutline` calls itself.

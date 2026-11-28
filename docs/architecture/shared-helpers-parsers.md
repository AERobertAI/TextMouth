# Shared helpers: readers and markup guards
<!-- id: shared-helpers-parsers; keys: SwiftSoup, XML, Kindle, parser, guard, untrusted markup; src: -->

Part of [TextMouth's architecture](../../ARCHITECTURE.md).

## ImportCancellation.throwIfCancelled
<!-- id: importcancellation-throwifcancelled; keys: cooperative cancellation, abort import, long loop, cancel check; src: TextMouth/Services/ArchiveExtraction.swift -->

ImportCancellation.throwIfCancelled() (Services/ArchiveExtraction.swift): the one question a reader that starts no helper process asks to hear Cancel in the import overlay.
It throws ImportCancelled, as a cancelled textutil conversion ends, and does nothing outside an import (a reader window, startup maintenance, Redo Text Extraction).
Call it in a loop of a reader that can run long.
The rich text, DOCX, MOBI, KFX, OpenDocument, Word 2003 XML, and Word 97-2003 readers ask it.

## Office XML readers and XMLInputGuard
<!-- id: office-xml-readers-xmlinputguard; keys: XXE, billion laughs, DTD refusal, entity expansion; src: TextMouth/Parsers/XMLInputGuard.swift, TextMouth/Parsers/OfficeXMLReader.swift, TextMouth/Parsers/PackageSAXParser.swift, TextMouth/Parsers/OfficeBlockWriter.swift, TextMouth/Parsers/OfficeStyleChain.swift, TextMouth/Services/FileImportService.swift -->

OfficeXMLReader, XMLInputGuard, OfficeBlockWriter, and OfficeStyleChain (Parsers/): the base and writer of the OpenDocument and Word 2003 XML readers.
OfficeXMLReader reads names by namespace and refuses a document type declaration and a nesting past 200 elements.
XMLInputGuard checks the raw bytes of a part before XMLParser or XMLDocument sees it, each check one linear pass.
Since 0.4.1 the DOCX, EPUB, DAISY, SSML, and PEF readers, the ODT manifest check, the SMIL source scan, and the feed and OPML readers ask it too.
SMILTextSources.scan, which tells whether a DAISY archive holds text beyond its audio, reads the text elements of a file the guard refuses as text, one linear regular-expression pass with no XML parser, so that the archive holding the only copy of that text is still kept.
The guard checks three things:
- the document type in the prolog, found in any encoding (declaresDocumentType, which OfficeXMLReader refuses whole, and declaresInternalSubset, the definitions of its own that problem(with:) refuses, a name of an external type being read);
- the encoding the part declares, allowed only for the names the guard can see through, in any capitals (seesThrough(_:width:)):
  - UTF-8, UTF-16 and UTF-32 in a part of that shape, US-ASCII, ISO-8859-n, Windows-125n, KOI8-R and KOI8-U, Macintosh, Shift_JIS, EUC-JP, EUC-KR, GB2312, GBK, GB18030, Big5, and their aliases;
  - a list of names to refuse always misses an alias, so EBCDIC and every other name are refused;
  - and any XML white space may stand around the =;
- and the attributes of any start tag, counted outside the quotes of their values (hasTag(withMoreAttributesThan:in:), at most 1,024 = mostAttributesInATag, 27 times the most in any real tag).
  XMLParser's time grows with the square of a tag's attributes, and the length of a value costs nothing, so the 1,000,000-byte limit on a start tag is gone.

Since 0.4.5 PackageSAXParser.parseDocument asks problem(throwingWhenCancelled:isDecodedText:), whose scan stops when its import is cancelled and throws ImportCancelled, so Cancel is heard during a large part's scan and a scan cut short never counts as a pass.
XMLInputGuard.problem(with:isDecodedText:) asks the encoding first, since the other checks read the part as ASCII, then the internal subset, then the attributes, for PackageSAXParser.parseDocument and EPUBParser.readingXML.
The parts these two read are the container, package document, and navigation files, which are decoded text.
XMLInputGuard.problemLeavingDefinitions(with:) asks the encoding and the attributes only, for FeedParser.parse and the OPML reader, since old RSS feeds declare entities of their own.
XMLInputGuard.reason(for:) completes their "is damaged at line 1" sentence.
The sentences are refusalSentence(for:file:in:original:) for an internal subset or an encoding (SSML has its own, whose next step is a text editor) and tooManyAttributesProblem, which is damage (PackageDamage.message).
XMLInputGuard.walkStartTags is the one scan that finds the tags, shared with DOCXPictureAttribute, which empties every o:gfxdata value before DOCXSAXParser's parse, since XMLParser stops at an attribute of more than 10 MB and loses the words after it.
OfficeBlockWriter holds a paragraph until it ends and writes what is anchored in it, a text box's paragraphs, a picture's description, and the notes whose references it holds, right after it.
OfficeStyleChain walks a style's based-on chain.
Both readers write through the rich text reader's RTFBlockBuilder, RTFHTMLWriter, and RTFSizeHeadings, which they reuse unchanged: a change to those reaches the OpenDocument and Word 2003 XML readers too (see [Imports: DOCX, OpenDocument, and Word 2003 XML](state/imports-office-xml.md)).

## MarkupGuard, MarkupScanner, and tree models
<!-- id: markupguard-markupscanner-tree-models; keys: HTML parser, tokeniser, untrusted markup, crash, tree builder, depth model; src: TextMouth/Parsers/MarkupGuard.swift, TextMouth/Parsers/MarkupScanner.swift, TextMouth/Parsers/MarkupNesting.swift, Vendor/SwiftSoup/README.md -->

MarkupGuard (Parsers/MarkupGuard.swift), MarkupScanner (Parsers/MarkupScanner.swift), and XMLOpenElements and HTMLTreeModel (Parsers/MarkupNesting.swift): the one way markup reaches SwiftSoup, since 0.4.1.
SwiftSoup is the copy vendored in `Vendor/SwiftSoup` (see [Third-party code](../developer/third-party-code.md)), which builds the same trees as the package did.
A book's markup is untrusted, and three things in it took the whole app down, or the Mac's memory with it:

- SwiftSoup's XML parser traps on a declaration it takes apart and finds no element in, such as `<?a>` or a torn `<?xml version="1.0"`.
  The guard rewrites any such declaration as `<!---->` before the parser sees it, which SwiftSoup 2.14 does too, and changes no other byte, so no book that could be read reads differently.
- SwiftSoup walks up an element's parents by recursion, and an import runs on a 512 KiB stack, so markup nested thousands of levels deep overflows it.
- An element takes a kilobyte or two of memory however few bytes its tag has, so a limit on bytes is no limit on memory.

## MarkupGuard entry points
<!-- id: markupguard-entry-points; keys: parser entry, lenient XML, body fragment, policy test, guard bypass; src: TextMouth/Parsers/MarkupGuard.swift, TextMouthProductionTests/MarkupGuardTests.swift, TextMouth/Parsers/HTMLToMarkdownConverter.swift, TextMouth/Parsers/TextutilDocumentReader.swift -->

MarkupGuard's entry points are `parse(_:baseURI:deepestNesting:)`, which picks SwiftSoup's XML parser when the markup opens with `<?xml` (by `opensAsXML`, SwiftSoup's own idea of whitespace) and its HTML parser otherwise, `parseXML(_:baseURI:deepestNesting:)`, and `parseBodyFragment(_:)`.
`MarkupGuardTests.testEveryParseGoesThroughTheGuard` fails on any `SwiftSoup.parse`, `Parser.parse`, `Parser.xmlParser`, `Parser.htmlParser`, `.parseInput(`, or `XmlTreeBuilder(` in the app's sources outside MarkupGuard.swift, so a new reader cannot leave the guard behind.
The readers that ask it are the EPUB, HTML, DAISY, Kindle (through HTMLToMarkdownConverter), and TextutilDocumentReader paths, the portable XML tree's lenient reader, and the feed code's discovery, article, and title reads.

## MarkupGuard's two layers of depth guard
<!-- id: markupguard-two-layers-depth-guard; keys: nesting depth, HTML5 tree builder, stack overflow, linear pass; src: TextMouth/Parsers/MarkupGuard.swift, TextMouth/Parsers/MarkupNesting.swift, TextMouth/Parsers/MarkupScanner.swift -->

The two layers hold the depth, so that one slip of the first cannot crash the app:

- Before the parse, `inspect(_:as:limits:)` makes one pass over the bytes, linear in their size.
  MarkupScanner finds the tags SwiftSoup 2.13.9's tokeniser finds, in the same places (a map of `TokeniserState`, MIT, with its oddities: a declaration ends at its first `>`, quoted or not).
  XMLOpenElements follows `XmlTreeBuilder` exactly: a start tag that does not close itself pushes its name, and an end tag pops to the nearest open element of the same name and letter case.
  HTMLTreeModel follows `HtmlTreeBuilder` and `HtmlTreeBuilderState`, mode by mode, with the open elements, the formatting list, foster parenting, the adoption agency, and the form and head pointers, and counts the depth of the deepest element, `html` at 1, never less than the real tree.
  It copies SwiftSoup's own slips and not the HTML standard: the body has no `frameset` rule, `generateImpliedEndTags()` with nothing to exclude does nothing, and the body reads the current node once as a start tag begins.
  `p` is in button scope whenever one stands above the last `button` while every open element has a tag id, and an end tag of `applet`, `marquee`, or `object` does nothing while an element named "name" is in scope.
  `InTableBody` asks for `tfoot` in the ordinary scope, `InSelect` serves every select, and the adoption agency looks only at the first 64 stack entries.
  Where the markup cannot say which way the parser goes (a character reference that may decode to whitespace), the model takes the deeper way; where it cannot follow tags (a head's `noscript` holding raw-text tags), `tagsAreCertain` is false and the pass counts every tag ahead as open.
- After the parse, `MarkupGuard.requireDepth(of:atMost:)` walks the parsed tree with a stack of its own and throws `MarkupRefusal.nestedTooDeeply` when an element is deeper than the limit, before the converter or any other reader that calls itself for each level sees the tree.
  `parse`, `parseXML`, and `parseBodyFragment` all end with it.

## MarkupGuard's big stack
<!-- id: markupguard-big-stack; keys: stack overflow, stack memory, SwiftSoup recursion; src: TextMouth/Parsers/MarkupGuard.swift -->

The big stack (0.4.2): `MarkupGuard.onLargeStack(_:)` runs SwiftSoup's parse, the depth walk after it, and the release of a refused tree on a `pthread` of its own, so that a wrong count in the first layer cannot overflow SwiftSoup's recursion up a tree's parents.
All three entry points use it.

- The size: `stackBytes(forTreeDepth:)` gives 512 bytes (`stackBytesPerLevel`) for each of 1,000,000 levels (`deepestTreeParsed`, the most the memory limit lets through, since every node counts as at least one unit of 1,000,000) and a megabyte more, in whole megabytes, which is 490 MiB.
  The worst shape measured, an inline element or a list closed again, touches about 200 bytes a level in a debug build and 160 to 190 in Release; the release of a tree touches none, because SwiftSoup 2.13.9's `Node.deinit` takes a deep tree apart in a loop.
  512 is two and a half times the worst, measured on 12 shapes and not on all.
- If the system refuses a stack, the size drops to a quarter, in whole megabytes, while it is at least 8 MiB (`smallestStack`): with today's limits 490, 122, and 30 MiB, the last holding about 59,000 levels.
  Then the body runs on the caller's thread, with the first layer's count as the only guard.
  The sizes below 30 MiB are never tried, since 7 MiB is under the floor.
- Waiting: the caller blocks in `pthread_join` until the thread ends, as it was blocked while the parse ran on its own stack.
  The thread takes no lock and waits for nothing the caller holds.
  It has the caller's quality of service.
  `pthread` is used, not `Thread`, because a failed `pthread_create` with no fallback would leave the caller waiting for ever.
- The job and its result cross the C interface as an address, so Swift 6 does not check them.
  `outcome` is written by the thread alone before it ends, and read by the caller alone after the join.
  `withExtendedLifetime(job)` keeps the job alive until then.
  There is no `@unchecked Sendable`.
- The task-local limits are read on the caller's thread and passed in as constants, since a task-local does not follow a `pthread`.
- `MarkupGuard.Limits.deepestTree` (nil in the app) sets the second layer's limit apart from `deepestNesting`, which `deepestParsedTree` falls back to.
  Without it, lifting the first layer's count lifted the second layer too, and the second layer could never be seen refusing a tree the count let through.
- Cost: about 55 microseconds more a chapter in a Release build (`alice.epub`: 266 to 321 microseconds a chapter), and about 22 microseconds more for each of 20,000 short feed fragments.
  A 300-chapter book costs about 7 ms more.
  Peak memory is the same.
- Not checked: shapes beyond the 12 measured; HTML trees past 50,000 levels, because the lifted first-layer count is quadratic (the stack use of HTML was measured to 20,000 levels, and of XML to about a million, where it showed none); and iOS.
  The iOS stack is described under The portable XML tree in [The two apps and the platform folders](platforms.md).

## MarkupGuard's four limits
<!-- id: markupguard-four-limits; keys: thresholds, hostile markup, memory limit, 128 levels; src: TextMouth/Parsers/MarkupGuard.swift -->

The four limits are set from 3,236 documents of 327 real files and from how deep a tree each reading path survives on the 512 KiB stack of an import.
A test binds others with `MarkupGuard.$limits.withValue(_:operation:)`, a task-local that changes only the reading that operation does:

- Nesting, 128 (`deepestNesting`).
  The deepest real book nests 12 levels and the deepest web page tried 36.
  The converter's recursion reads at least 552 levels in a Release build (nested quotes, where the Markdown parser runs out), 862 of lists, and about 1,190 of most other shapes, and a tree can go twice as deep as the count, and two more, so the deepest tree at 128 is 258 levels.
  A debug build reads only 108 levels of lists and 117 of divisions, so a hostile file nested 108 to 128 deep can overflow a developer's debug build and never the app.
- Memory, 1,000,000 units (`mostMemoryUnits`), where a unit is `tags + 2 * tagsWithAttributes + attributes / 3` (about 800 bytes of SwiftSoup's tree for a node with text).
  The most in a real document is 431,296, Webster's Unabridged Dictionary as one 32 MB HTML file.
- Attributes on one tag, 1,000 (`mostAttributesOnATag`).
  No real tag has more than 7; SwiftSoup's time grows with the square of them.
- Work, 30,000,000,000 (`mostWork`), what SwiftSoup spends where its time grows with the square of the markup, about half a minute.
  The most in a real document is 1,300.

## Feed discovery's nesting limit
<!-- id: feed-discovery-nesting-limit; keys: feed autodiscovery, link rel alternate, HTML page, discover feeds, web page; src: TextMouth/Services/Feeds/FeedDiscovery.swift -->

Feed discovery (`FeedDiscovery.deepestNesting`) has a limit of its own, 512, passed as `deepestNesting`, because it walks the page with a stack of its own and converts nothing.
What still calls itself for each level is SwiftSoup's own recursion, which reads at least 3,002 levels in Release and 2,002 in debug, so at 512 the deepest tree is 1,026.

## MarkupRefusal cases
<!-- id: markuprefusal-cases; keys: refusal message, damaged file, error sentence, LocalizedError, import error; src: TextMouth/Parsers/MarkupGuard.swift, TextMouth/Parsers/XMLInputGuard.swift -->

MarkupRefusal has four cases, each a sentence a listener can act on that never calls the file damaged: `nestedTooDeeply(limit:)`, `tooMuchMarkup`, `tooManyAttributes(limit:)`, and `tooMuchWork` (the sentences are in [Import progress and errors](../user/import-progress-and-errors.md)).
The pass costs 13% of an HTML parse and under 2% of an XML one, and 0.133 seconds on Webster's 32 MB against the parse's 0.944.

## DOCX list counting and number formats
<!-- id: docx-list-counting-number-formats; keys: Roman numerals, list numbers, Word lists, page number format, lowerLetter; src: TextMouth/Parsers/DOCXParser+Numbering.swift, TextMouth/Parsers/DOCXParser.swift, TextMouth/Parsers/DOCXParser+Sections.swift -->

DOCXListCounter, DOCXNumbering, and DOCXPageNumberFormat (Parsers/DOCXParser+Numbering.swift and DOCXParser+Sections.swift): the one counting of a list's numbers and the one writing of Roman, letter, and decimal formats.
The Word 97-2003 reader builds a DOCXNumbering from Word's list tables and counts with the DOCX counter, so the two agree; DOCXListCounter.startLevels(moreSignificantThan:numId:) is the one accessor that only the Word 97-2003 reader calls.

## MarkdownEmphasis
<!-- id: markdownemphasis; keys: asterisk, tilde, strikethrough, style runs, emphasis markers; src: TextMouth/Parsers/MarkdownEmphasis.swift -->

MarkdownEmphasis (Parsers/MarkdownEmphasis.swift) is how the DOCX converter, as the braille reader, writes bold and italic, so no `*` or `~` is ever a spoken mark: runs are gathered as raw text with a style for each scalar, and the marks are written around a stretch only where Markdown allows them.

## KFX and MOBI preparedBook
<!-- id: kfx-mobi-preparedbook; keys: AZW3, shared ending, Amazon, ebook format; src: TextMouth/Parsers/KFXParser.swift, TextMouth/Parsers/MOBIParser.swift -->

KFXParser and MOBIParser.preparedBook (Parsers/KFXParser.swift, Parsers/MOBIParser.swift): a KFX book ends in the same function a MOBI book ends in, so a Kindle book of either format is cut into the same chapters, headings, and Markdown.

## KF8Book and the guard
<!-- id: kf8book-guard; keys: Kindle KF8, AZW3, fuzz, big stack policy; src: TextMouth/Parsers/KF8Book.swift, TextMouth/Parsers/KF8Layout.swift, TextMouth/Parsers/HTMLToMarkdownConverter.swift, TextMouth/Parsers/MarkupGuard.swift, TextMouth/Parsers/MOBIParser.swift -->

KF8Book and the guard (Parsers/KF8Book.swift, Parsers/KF8Layout.swift): a KF8 book's sections reach SwiftSoup only through HTMLToMarkdownConverter.convert, which calls MarkupGuard.parse, so the guard settles the nesting, declaration, and size inputs of a KF8 part as it does a MOBI 6 section's.
KF8Book and KF8Layout call no SwiftSoup parse of their own, which the policy test that holds each parse to the big stack needs.
KF8 also ends in MOBIParser.preparedBook, where a section that continues the chapter before it (Section.continuesPrevious) is joined to it.

## ByteSearch and String.forEachCharacter
<!-- id: bytesearch-foreachcharacter; keys: memchr, containsUTF8Byte, containsByte, splitAtLineFeeds, white space count, import speed-up, Character stepping; src: TextMouth/Parsers/ByteSearch.swift, TextMouth/Models/DocumentContent.swift, TextMouth/Parsers/TextFileDecoder.swift, TextMouth/Parsers/TextEncodingGuesser.swift, TextMouth/Parsers/PlainTextParser.swift, TextMouthProductionTests/ByteSearchTests.swift, TextMouthProductionTests/ImportSpeedUpPinTests.swift -->

`ByteSearch.contains(_:in:count:)` (Parsers/ByteSearch.swift) is the C library's `memchr`, and three extensions give its answer the shape a reader needs: `String.containsUTF8Byte(_:)`, `Data.containsByte(_:)`, and `String.splitAtLineFeeds()`.
Each gives exactly the answer of the plain walk it replaces (`utf8.contains`, `contains`, and `split(separator: "\n", omittingEmptySubsequences: false)`); a string that is not contiguous UTF-8 is walked as before, so the answer never depends on how the text is stored.
Callers: the text decoders' ESC (0x1B) and carriage return (0x0D) tests, the plain text reader's form feed (0x0C) test, and the DOCX converter's split of each run.
`splitAtLineFeeds()` relies on a line feed Character being a 0x0A byte that no carriage return precedes, so a string with no 0x0A byte is the one line it is.

`String.forEachCharacter(_:)` (Models/DocumentContent.swift) steps a string's Characters over its UTF-8 bytes and says for each whether it is white space.
An ASCII byte followed by another ASCII byte, or by the end, is a whole Character and is judged alone; CR LF is stepped as one; any other Character is read whole from its first byte.
The word count of a book's text and the RTF heading census use it, and both give the count the Character split gives.
`ByteSearchTests` and `ImportSpeedUpPinTests` compare each with the plain expression on random texts, and on the edge cases by name.

## PlainTextLines
<!-- id: plaintextlines; keys: newlines, trimming, line split, plain text import, CharacterSet.newlines; src: TextMouth/Parsers/PlainTextLines.swift, TextMouth/Parsers/PlainTextParser.swift, TextMouthProductionTests/PlainTextLinesTests.swift -->

`PlainTextLines.trimmedLines(of:)` (Parsers/PlainTextLines.swift) splits a plain text book into its trimmed lines in one pass over its UTF-8 bytes.
It makes what `components(separatedBy: .newlines)` and `trimmingCharacters(in: .whitespaces)` made: a line ends at each scalar of `CharacterSet.newlines` (U+000A to U+000D, U+0085, U+2028, and U+2029), each by itself, and the text always has a last line, empty when it ends with a line ending.
The space and the tab are trimmed as bytes; a line with any other byte at an edge is trimmed by Foundation, so the whitespace set is not restated.
`PlainTextLines.referenceLines(of:)` is the Foundation form, which the tests hold the pass to on each edge and on 20,000 random texts (`PlainTextLinesTests`).

## XMLElementIndex
<!-- id: xmlelementindex; keys: XPath, local-name, XMLDocument, EPUB package, NCX, page list, childElements, firstNavLabelText; src: TextMouth/Parsers/XMLElementIndex.swift, TextMouth/Parsers/EPUBParser.swift, TextMouth/Parsers/EPUBParser+Navigation.swift, TextMouthProductionTests/EPUBXMLIndexTests.swift -->

`XMLElementIndex` (Parsers/XMLElementIndex.swift) lists a document's elements by local name in one walk, in document order, with the local name of each one's parent.
`elements(named:)` is what `//*[local-name()='name']` returned, and `elements(named:insideParentNamed:)` what `//*[local-name()='parent']/*[local-name()='name']` returned.
`XMLElement.childElements(localName:)` and `firstNavLabelText` replace the two relative paths the NCX entries used.
The EPUB reader makes one index for its package document, and one for each NCX and page list, instead of 21 XPath queries that each tested every element; `authorName(in:index:)` takes the caller's index and makes its own when not given one.
The walk keeps its own stack, since a document may nest thousands deep and an import runs on a worker thread's small stack.
An index is a picture of the tree when it was made, so it is made again after any change.
`EPUBXMLIndexTests` keeps the old XPath as the reference and compares the two on 1,000 random packages, the container, an NCX, and a 2,000-deep document.

## Blank chapters and EPUB types by name
<!-- id: blank-chapters-epub-types-by-name; keys: holdsOnlyWhitespaceAndPageMarkers, typeAttributeNames, ReadingFlow.typeNames, epub:type, page marker, blank chapter; src: TextMouth/Parsers/EPUBParser+Navigation.swift, TextMouth/Parsers/PublicationSemantics.swift, TextMouth/Parsers/MarkdownPageMarker.swift, TextMouthProductionTests/EPUBBlankChapterTests.swift, TextMouthProductionTests/PublicationSemanticsTypeNamesTests.swift -->

`EPUBParser.holdsOnlyWhitespaceAndPageMarkers(_:)` says a converted chapter is blank by reading it from its start, skipping white space and page markers, until the first other character.
A marker is `MarkdownPageMarker.prefix`, one or more characters that are neither "<" nor ">", and `MarkdownPageMarker.suffix`; a chapter with words is judged by its first few characters, and no copy of it is made.
`PublicationSemantics.typeAttributeNames(in:)` lists the attribute names of a document that end in ":type", from its markup, or nil when the markup is not plain enough to say for certain.
`ReadingFlow.typeNames` holds the list, and the page break, page list, and navigation rules ask an element for those names alone.
With nil (`ReadingFlow.unknownSource`), every attribute of the element is searched, as before.
`EPUBBlankChapterTests` compares the blank test with the old regular expression on 20,000 random texts, and `PublicationSemanticsTypeNamesTests` the names with the full search.


## VisionTextRecognition
<!-- id: vision-text-recognition; keys: Vision, OCR, text recognition, RecognizedTextLine, scanned PDF, VNRecognizeTextRequest; src: TextMouth/Parsers/VisionTextRecognition.swift, TextMouth/Parsers/PDFTextRecognizer.swift, TextMouth/Parsers/PageImageReader.swift -->

VisionTextRecognition is the one text recognition TextMouth runs: Vision's accurate recognizer with language correction, in the languages Vision reads when none are named.
A scanned PDF's pages (VisionPDFTextRecognizer) and pictures of pages (PageImageReader) both read through it, so both read text in the same order.
It returns RecognizedTextLine values, each with a box as fractions of the picture, the origin at the bottom left.
Error codes that mean recognition cannot run in the process at all (unavailableCodes) are told apart from a failure on one picture.

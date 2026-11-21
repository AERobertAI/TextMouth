# Tests of the markup guard, Kindle, and MOBI readers
<!-- id: format-reader-tests; keys: Kindle, KF8, KFX, MOBI, AZW3, SwiftSoup, format samples; src: TestData/format-samples/, TestData/format-samples/samples.tsv, Scripts/test/areas.conf -->

Part of [TextMouth's documentation](../../README.md).

`MarkupGuardTests` is in the `import` area of `Scripts/test/areas.conf`, and the KF8, KFX, and MOBI classes are in its `readers` area.

## The markup guard tests
<!-- id: markup-guard-tests; keys: SwiftSoup, nesting depth, stack overflow, onLargeStack, MarkupGuard.Limits, fuzz, trap, big stack; src: TextMouth/Parsers/MarkupGuard.swift, TextMouth/Parsers/HTMLParser.swift, TextMouthProductionTests/MarkupGuardTests.swift, TextMouthProductionTests/MarkupFuzzGenerator.swift, TextMouthProductionTests/EPUBHeadingRecoveryTests.swift, TextMouthProductionTests/EPUBPageListTests.swift, TextMouthProductionTests/DAISYMalformedXMLTests.swift -->

`MarkupGuardTests` (TextMouthProductionTests/MarkupGuardTests.swift, with `MarkupFuzzGenerator`) tests the guard that every SwiftSoup parse goes through (see Shared helpers, in [Architecture](../../ARCHITECTURE.md)).
Its documents are made so that a failure is a failed assertion and not a trapped test host, which a trap would end:

- Every shape of broken declaration reads with the words around it, `testWhichDeclarationsTrap` holds the table of which trap SwiftSoup, and `testTheParserIsTheOneSwiftSoupWouldChoose` holds the choice of parser.
- `testTheDepthLimitIsExact` checks the guard's own count at the limit and one level past it, without converting more than 38 levels.
  The cases count what SwiftSoup's HTML parser builds, tag by tag, in `testThePassCountsWhatTheHTMLParserBuilds` and exactly for XML in `testThePassCountsWhatTheXMLParserBuildsExactly`.
  `testRandomMarkupGoesNoDeeperThanThePassCounts` holds random documents from `MarkupFuzzGenerator` to the count.
  `MarkupFuzzGenerator` is SplitMix64, so a document depends only on its seed and round.
- The repeated-unit test, `testRepeatedUnitsAreCountedAsDeepAsTheParserBuildsThem`, takes 15 units of one to three tags that walked past the first count (`<frameset><table>`, `<marquee><table><tfoot>`, `<form><div></form>`, and the like) in three heads, 30 times over.
  It requires the count to be at least the real tree's depth.
  The harness holds every unit of one to three of 108 tags, in three contexts and in a body fragment (5,085,936 units), to the same at 40 and at 2,000 repeats.
- The second-layer test, `testTheParsedTreeIsHeldToTheLimitToo`, calls `MarkupGuard.requireDepth(of:atMost:)` on a tree of 32 levels and requires it to read at 32 and to throw `nestedTooDeeply(limit: 31)` at 31.
- To test a limit a test lifts or lowers it for one operation: `try MarkupGuard.$limits.withValue(MarkupGuard.Limits(deepestNesting: 32, mostMemoryUnits: .max, mostAttributesOnATag: .max, mostWork: .max)) { … }` binds a task-local.
  So the limits change only the reading that closure does on its own thread.
  `testTheStandardLimitsArePinned` pins 128, 1,000,000, 1,000, and 30,000,000,000; `testTheRefusalsSpeakPlainly` pins the four sentences; `testTheLimitsInForceReachTheRealPath` binds small limits and requires the converter, `HTMLParser`, and the guard's three parses to refuse.
- The reading paths are held through each format's own code: an EPUB reads around a refused chapter, a Kindle book, a DAISY navigation file, a web archive's page, feed discovery, and a feed's title and text meet the guard (`testAnEPUBReadsAroundWhatItsChaptersHold` and its neighbours).
- `testEveryParseGoesThroughTheGuard` reads the app's sources and fails on any SwiftSoup parse outside MarkupGuard.swift.
- The big stack (0.4.2) has its own tests:
  - `testTheBigStackHoldsTheDeepestTreeThePassLetsThrough` (its size, a whole number of megabytes, from the measured cost of a level),
  - `testTheBodyRunsOnAThreadWithTheBigStackAndItsResultComesBack`,
  - a parse from a 512 KiB worker thread that gives the same tree as SwiftSoup alone in each of the three parsers, and
  - `testTheSecondLayerHasALimitOfItsOwnWhenOneIsSet`, which sets `Limits.deepestTree` apart from `deepestNesting` on a tree of 60 levels.
- The policy test of the stack is `testEverySwiftSoupParseInTheGuardRunsOnTheBigStack`.
  It reads MarkupGuard.swift without its line comments and requires 3 `SwiftSoup.parse` calls, each the argument of `requireDepth(of:atMost:)` inside an `onLargeStack` closure, so that neither a parse nor a depth walk can leave the big stack, and a refused tree is released there.
  It does not strip block comments, and `testEveryParseGoesThroughTheGuard` matches fixed names only, so a typealias would evade it.
### Proof outside the test host
<!-- id: markup-stack-proof; keys: stack overflow, child process, 512 KiB, measure, proof, heavy-work lock; src: Scripts/test/markup-stack-proof.py, Scripts/test/markup-stack-proof/measure/main.swift, Scripts/test/markup-stack-proof/proof/main.swift, TextMouth/Parsers/MarkupGuard.swift -->

- `Scripts/test/markup-stack-proof.py` (with the programs in `Scripts/test/markup-stack-proof/measure` and `proof`) proves in child processes what the test host cannot, that the guard's parse does not overflow a stack:
  - `build` compiles the two programs against the committed MarkupGuard sources and the SwiftSoup of the last build, in debug, Release, or both.
  - `measure` parses a deep document on a 4 GiB stack and counts the pages touched, which gives the bytes a level costs each shape.
  - `proof` calls the guard from a 512 KiB thread with the first layer's limit lifted and the second layer's at 128, and requires the depth sentence and no crash.
    A control calls SwiftSoup alone and overflows.
  - It takes the heavy-work lock, writes to `build/markup-stack/` in the main checkout, and runs with `python3 -I -B`.
  - Its raw closed-span case is 5,000 levels deep and overflows, which is the control's point.
- A debug build converts only about 108 levels of lists and 117 of divisions on an import's 512 KiB stack, so no in-process test converts more than 40 levels.
  The tests of other readers that need a tree thousands of levels deep (deep navigation files in `EPUBHeadingRecoveryTests`, `EPUBPageListTests`, and `DAISYMalformedXMLTests`, 5,000 levels in two of them) lift only the depth.
  They use `MarkupGuard.Limits.withoutDepthLimit` (defined at the top of MarkupGuardTests.swift) under `MarkupGuard.$limits.withValue`, on `onWorkerSizedStack`, to hold the reader's own walk to itself, since the guard would refuse such a file first.
- Proof that a document cannot crash is never made in the test host.
  A document whose count or parse is in doubt is first run in a harness in a child process with a stack of 512 KiB and memory and time limits, and only then written into a test.
  The runs over millions of units are made the same way (in the last round, 5,085,936 units at 40 repeats, and 2,154,267 read with 2,931,669 refused at 2,000, in Release, with 0 faults).

## KFX tests
<!-- id: kfx-tests; keys: Kindle Previewer, Amazon Ion, KFX, kfx-features, alice.kfx, Kindle, KFXFixture, KFXTestBook; src: TextMouthProductionTests/KFXRecognitionTests.swift, TextMouthProductionTests/KFXContainerTests.swift, TextMouthProductionTests/KFXIonTests.swift, TextMouthProductionTests/KFXWalkTests.swift, TextMouthProductionTests/KFXNavigationTests.swift, TextMouthProductionTests/KFXSetTests.swift, TextMouthProductionTests/KFXInlineBookTests.swift, TextMouthProductionTests/KFXFixRoundTests.swift, TextMouthProductionTests/KFXHostileFileTests.swift, TextMouthProductionTests/KFXVerifyRoundTests.swift, TextMouthProductionTests/KFXEPUBComparisonTests.swift, TextMouthProductionTests/KFXPrivateBooksTests.swift, TextMouthProductionTests/KFXFixture.swift, TextMouthProductionTests/KFXTestBook.swift, Scripts/make-kfx-sample.py, TestData/format-samples/kfx/, TestData/format-samples/samples.tsv -->

The KFX tests are `KFXRecognitionTests`, `KFXContainerTests`, `KFXIonTests`, `KFXWalkTests`, `KFXNavigationTests`, `KFXSetTests`, `KFXInlineBookTests`, `KFXFixRoundTests`, `KFXVerifyRoundTests`, and `KFXHostileFileTests`, on books that `KFXFixture` and `KFXTestBook` build in code.
`KFXVerifyRoundTests` holds the limits no other test touches: positions near `Int.max` on every path a position can take, a work bound that follows the file's size, and the caps on archives, sidecars, units, and pages.
`KFXEPUBComparisonTests` reads `kfx/kfx-features.kfx` and `kfx/alice.kfx` and requires the words and headings of the EPUB each was made from (and, for the feature book, its chapters and its 5 pages).
It names two differences:
- the title of a chapter with no words, which the EPUB takes from the document's title and the KFX book does not have;
- in the inline book, the EPUB sets math apart as a block where the KFX book reads the author's name for it.
The samples in `TestData/format-samples/kfx` are made with `Scripts/make-kfx-sample.py`, which writes a small EPUB with everything the walk meets and converts it with Amazon's Kindle Previewer and a packaging tool.
Both are run as black boxes by a wrapper script in the main checkout's gitignored build folder.
The reader was written from the format notes and the public Ion specification, not from either tool's code, and Previewer stamps a new identifier into every run, so the books' bytes differ at each run and their SHA-256 in `samples.tsv` is the sample in the repository.
`KFXPrivateBooksTests` reads books that the developer places by hand in a gitignored folder of the main checkout, never committed, and reports only counts (books, words, headings, pages) and, for each refusal, its sentence; it skips when the folder is absent or empty, as it does in a worktree.

## Kindle samples without goldens
<!-- id: kindle-samples-without-goldens; keys: MOBI 6, Gutenberg, calibre, ebook-convert, encrypted, ferry-notes-ncx, Kindle samples; src: TextMouthProductionTests/MOBIReaderTests.swift, TextMouthProductionTests/KF8RealBookTests.swift, Scripts/make-mobi-ncx-sample.py, TestData/format-samples/mobi/, TestData/format-samples/samples.tsv -->

The Kindle samples in `TestData/format-samples/mobi` have no goldens.
MOBIReaderTests reads two of them:
- Project Gutenberg's MOBI 6 book, and
- `ferry-notes-ncx.mobi`, a small book with a table of contents that `Scripts/make-mobi-ncx-sample.py` makes with calibre's `ebook-convert` (calibre writes a new identifier into every conversion, so the script's output never matches the sample byte for byte).

It checks that a copy of the MOBI 6 book marked as encrypted, which is not really encrypted, is refused.
`KF8RealBookTests`, below, reads Gutenberg's KF8 book.

## KF8 tests
<!-- id: kf8-tests; keys: KF8, AZW3, Kindle, FMT48, KF8Fixture, hybrid; src: TextMouthProductionTests/KF8LayoutTests.swift, TextMouthProductionTests/KF8BookTests.swift, TextMouthProductionTests/KF8HostileFileTests.swift, TextMouthProductionTests/KF8ReviewFixTests.swift, TextMouthProductionTests/KF8RealBookTests.swift, TextMouthProductionTests/KF8Fixture.swift -->

The KF8 tests (FMT48, 0.4.2) read Kindle books in KF8 and are `KF8LayoutTests`, `KF8BookTests`, `KF8HostileFileTests`, `KF8ReviewFixTests`, and `KF8RealBookTests`, on books that `KF8Fixture` builds in code and on the samples below.

### What the KF8 classes pin
<!-- id: what-kf8-classes-pin; keys: KF8 layout, KF8 sections, generated contents page, fragments, label cap, hybrid fallback; src: TextMouthProductionTests/KF8LayoutTests.swift, TextMouthProductionTests/KF8BookTests.swift, TextMouthProductionTests/KF8ReviewFixTests.swift -->

- `KF8LayoutTests` pin the tables, the end-to-end layout check, and the join.
  `KF8BookTests` pin the sections, titles, headings, pages, and metadata.
- `KF8ReviewFixTests` pin what the review asked for:
  - the generated contents page and the real last page it must not take,
  - fragments that go backward or leave a gap,
  - the 1 KB label cap,
  - the fallback from a hybrid's KF8 half to its MOBI 6 half in every way short of protection and a cancel,
  - SVG words,
  - navigation lists,
  - the continuation rule, and
  - a damaged contents or guide.

### The chapter rules
<!-- id: chapter-rules; keys: openingContainer, calibre pieces, header rule, footer exemption, Modest Proposal, Pride and Prejudice, licence; src: TextMouthProductionTests/KF8ReviewFixTests.swift, TextMouthProductionTests/KF8RealBookTests.swift, TextMouthProductionTests/KF8Fixture.swift, TextMouth/Parsers/KF8Book.swift, TestData/format-samples/mobi/pg1080-modest-proposal-kf8.mobi, TestData/format-samples/azw3/pg1080-modest-proposal.epub -->

- The chapter rules of 0.4.3 (see the continuation rule in [Imports](../architecture/state/imports-kindle.md)) are pinned in three places:
  - `KF8RealBookTests.testAModestProposalReadsAsItsEPUBsThreeChaptersWithTheLicensesOpeningInTheLicense` reads the real pair: 3 chapters of 169, 3,386, and 2,906 words, with the titles, word counts, words, and headings of the EPUB.
    The samples are `mobi/pg1080-modest-proposal-kf8.mobi` (422,746 bytes) and `azw3/pg1080-modest-proposal.epub` (263,753 bytes), each under 500 KB and in `samples.tsv`.
    The Yellow Wallpaper's test expects a start entry before the licence's heading.
  - `KF8ReviewFixTests.testAnEssayAfterAWholeHeaderIsItsOwnChapterAndALicenseKeepsItsOpeningWords` builds the same shape with `KF8Fixture`.
  - `KF8ReviewFixTests.testPiecesInTheSameSectionOrAfterAFooterOrBeforeAHeadingInAnotherSectionStillGoOn` holds what the rules leave alone: the review's two sections cut inside the second (one chapter ending "Second half."), a piece after a footer, and a plain `div` after a section (two chapters).
  - Breaking each rule in a scratch copy moved the real numbers:
    - without the header rule Modest Proposal is 2 chapters;
    - without the shared-container rule the licence's opening lands in the essay (3,599 and 2,693 words);
    - without the continuation it is 4 chapters;
    - without the footer exemption Pride and Prejudice is 67 chapters, not 66.

    The two-section cut was proven with a throwaway program, not an XCTest run.
    The `<a>` skip in `openingContainer` has no test.

### Soft hyphens and the portable XML differences
<!-- id: soft-hyphens-portable-xml-differences; keys: soft hyphen, SHY, removingSoftHyphens, toc.xhtml, toc.ncx, page reader version, knownDifferences; src: TextMouthProductionTests/SoftHyphenEffectTests.swift, TextMouthProductionTests/KF8ReviewFixTests.swift, TextMouth/Parsers/ParserUtilities.swift, TextMouthProductionTests/MOBIBookStructureTests.swift, TextMouthProductionTests/MOBIReaderTests.swift, TextMouthProductionTests/PagesUpgradeTests.swift, TextMouthProductionTests/OnDiskContractTests.swift, TextMouthProductionTests/PortableXMLDifferentialTests.swift -->

- The soft hyphens (0.4.3) are pinned
  - by `SoftHyphenEffectTests` (the measured effects on search and braille, see Shared helpers in [Architecture](../../ARCHITECTURE.md)),
  - by `KF8ReviewFixTests.testEverySpellingOfASoftHyphenIsLeftOut` (every spelling `ParserUtilities.removingSoftHyphens` catches, and the ones it leaves alone: `&SHY;`, `&Shy;`, `&shy1`, `&shyx`, other numbers, and a huge one), and
  - by `MOBIBookStructureTests` for a MOBI 6 book's words, labels, Windows-1252 text, and plain PalmDOC text.

  `MOBIReaderTests`, `PagesUpgradeTests`, and `OnDiskContractTests` expect the `.mobi` page reader line "1.1.0".
- `PortableXMLDifferentialTests` lists two known differences for the new EPUB, its `toc.xhtml` and `toc.ncx`: they write the title across two lines with `&#13;`, which Foundation's tidy reading keeps and the portable tree collapses.
  The strict reading, which the EPUB reader uses on both platforms, agrees.
  The evidence is the root element's text, so the two entries also pass any other tidy difference in those two files.

### Hostile files and real books
<!-- id: hostile-files-real-books; keys: damaged book, typed refusal, MarkupRefusal, prepareBook, Standard Ebooks, quay-almanac, Gutenberg, azw3; src: TextMouthProductionTests/KF8HostileFileTests.swift, TextMouthProductionTests/KF8RealBookTests.swift, TextMouth/Parsers/MOBIParser.swift, TextMouth/Parsers/MarkupGuard.swift, Scripts/make-kf8-samples.py, TestData/format-samples/azw3/, TestData/format-samples/mobi/ -->

- `KF8HostileFileTests` damage a book so that a table, a count, a place, or a length lies, and require a typed refusal (or a read) in well under a second, with no trap.
  They import through `MOBIParser.prepareBook`, so a section's markup meets the markup guard and the nesting and declaration inputs end in `MarkupRefusal.nestedTooDeeply` or a normal read.
  The flip and truncation tests import every fourth or eighth copy that opens.
- `KF8RealBookTests` read the samples in `TestData/format-samples/azw3` and `mobi` as an import does and compare each with the same book as an EPUB through the EPUB reader: the same words in the same order, the same headings, and the same pages, with the differences named in the test.
  The samples are
    - Standard Ebooks' The Time Machine (`se-the-time-machine.azw3`),
    - `quay-almanac` (an EPUB, an .azw3 and a calibre hybrid, made by `Scripts/make-kf8-samples.py`),
    - Gutenberg's Yellow Wallpaper in KF8,
    - Gutenberg's A Modest Proposal in KF8 with its EPUB (0.4.3),
    - Gutenberg's Ghosts as kindlegen made it (a hybrid), and
    - the edge books.

### Edge samples
<!-- id: edge-samples; keys: edge samples, kindlegen, calibre, toc-last, page-list, svg-words, samples.tsv, hybrid; src: TextMouthProductionTests/MOBIReaderTests.swift, Scripts/make-kf8-edge-samples.py, Scripts/make-kf8-edge-samples-2.py, TestData/format-samples/azw3/edge/, TestData/format-samples/mobi/edge/ -->

- The edge samples are in `TestData/format-samples/azw3/edge` (an EPUB and its .azw3 each, made with calibre) and `mobi/edge` (a calibre hybrid and a kindlegen hybrid each): `toc-last`, `toc-mixed`, `toc-epilogue`, `toc-single`, `page-list`, `svg-words`, `nav-in-spine`, and `page-break-style`.
  `Scripts/make-kf8-edge-samples.py` and `Scripts/make-kf8-edge-samples-2.py` write their EPUBs, every word of whose prose is a unique token, and convert them with calibre's `ebook-convert` and Amazon's kindlegen (Kindle Previewer 4's copy), both run as black boxes.
  Their bytes change at each conversion, so the SHA-256 in `samples.tsv` is the sample in the repository.
- `testKindleBooksAreRecognizedByTheirExtensions` and the Finder test treat `.azw3` as a Kindle extension.
- The hosted tests (the upgrade of a stored hybrid without a kept copy, the 70 MB picture-file test, the sparse 600 MB file refusal, the Info.plist and project checks) need the train.

### The KF8 fuzz kit
<!-- id: kf8-fuzz-kit; keys: fuzz, swiftc, KF8_FUZZ_BUILD, reader program, damaged copy, seed, trap; src: Scripts/test/kf8-fuzz/build-reader.py, Scripts/test/kf8-fuzz/fuzz.py, Scripts/test/kf8-fuzz/Main.swift, Scripts/test/kf8-fuzz/Stubs.swift, TextMouth/Parsers/MOBIParser.swift, TextMouth/Parsers/KF8Book.swift, TextMouth/Parsers/MarkupGuard.swift, Scripts/agents/run_locked.py -->

- `Scripts/test/kf8-fuzz` (`build-reader.py`, `fuzz.py`, `Main.swift`, `Stubs.swift`) is a fuzz kit that damages books at random with a seed and reads each in a child process.
  It is not part of the suite.
  - `build-reader.py OUTPUT [WORKFOLDER]` builds the reader program with `swiftc`, from the repository's sources and the packages an earlier Release build left in `build/DerivedData/Build/Products/Release`.
    In a worktree with none, set `KF8_FUZZ_BUILD` to another checkout's `build` folder.
    It is heavy: run it under `run_locked.py`.
    Its files are overwritten by every build.
  - The reader program has three modes.
    `reader kf8 BOOK` reads a book as an import does, and prints OK and counts, or ERR and the sentence a listener would hear.
    `reader sections BOOK` (an .azw3, a .mobi, or an .epub) prints each chapter's number, words, title, and first and last six words, each heading, the words' SHA-256, and the count of soft hyphens left, so two files of one book can be compared with `diff`.
    `reader sections6 BOOK` reads a hybrid's MOBI 6 half.
  - `fuzz.py --reader PATH --work FOLDER --seed N --rounds N BOOK...` changes one to four bytes of a copy of a book each round, half in the first 6 KB or the last 40 KB, and runs the reader with a time limit (`--seconds`, 5 by default) and a memory limit (`--megabytes`, 1024).
    A signal, a time over the limit, or a peak memory over it fails the round, and a trapping round's file is kept as `trap-<round>.bin`.
    It deletes nothing.

## Text without a byte-order mark
<!-- id: text-without-byte-order-mark; keys: BOM, UTF-16, UTF-32, unmarkedUnicode, NUL, encoding guess, ISO-2022-JP, text encoding; src: TextMouthProductionTests/TextFileDecoderTests.swift, TextMouth/Parsers/TextFileDecoder.swift, TextMouth/Models/TextEncodingChoice.swift, TextMouthProductionTests/PagesUpgradeTests.swift, TextMouthProductionTests/OnDiskContractTests.swift -->

`TextFileDecoderTests` pin how text without a byte-order mark is read (0.4.3; see `unmarkedUnicode(in:)` under Imports in [Architecture](../../ARCHITECTURE.md)).

- `testUnmarkedUnicodeInEveryScriptIsRecognizedByItsBytes` and `testTheShortestUnmarkedTextsThatAreRecognized` pin what is found and how short it may be.
- Four tests pin what must not be taken for UTF-16 or UTF-32:
  - `testBytesThatAreNotUnmarkedUnicodeAreNotReadAsIt`,
  - `testTextInOtherEncodingsIsNeverTakenForUnmarkedUnicode` (the same sentences in more than 20 encodings),
  - `testTheTextSamplesInTestDataAreNeverTakenForUnmarkedUnicode` (89 samples, about 124,000 windows), and
  - the two sweeps with one to four NULs put in at random, `testTheTextSamplesInTestDataWithStrayNULsAreNeverTakenForUnmarkedUnicode` and `testStrayNULsDoNotTurnTextIntoUnmarkedUnicode`.

  The NUL sweeps are the ones that can fail: without a zero byte the rules for other scripts cannot fire.
- `testARecordedEncodingAndTheLegacyEvidenceAskOnlyTheOldRule` pins that a book's recorded encoding, and the web archive and web-page .doc readers, ask for Latin UTF-16 alone.
  `testAUTF16ColumnOfSingleCharactersIsNotTakenForUTF32` pins a column of one character to a line.
- The ISO-2022-JP tests pin the declaration of an HTML file.
- Left unfound on purpose, and so untested as found: UTF-16 in the scripts of India, and Chinese, Japanese, or Korean UTF-16 with fewer than 8 spaces, digits, or line ends.

## MOBI tests on real books
<!-- id: mobi-tests-real-books; keys: libmobi, HUFF/CDIC, Mobipocket, PalmDOC, mobi.js, SHA-256, Gutenberg, Afrikaans; src: TextMouthProductionTests/MOBIRealBookTests.swift, TestData/format-samples/mobi/, TestData/format-samples/samples.tsv -->

MOBIRealBookTests reads five real books from other makers, each pinned by the SHA-256 of its decoded text, which a decoder written apart from TextMouth's (a Python port of mobi.js) computed, and by its names and some of its words.
Three are libmobi's test samples, under libmobi's LGPL-3.0, whose text and the GPL-3.0 it builds on are beside them as `libmobi-COPYING.LESSER` and `libmobi-COPYING`:
- a kindlegen book compressed with HUFF/CDIC, whose digest is also that of the same book stored uncompressed, so it proves the HUFF reading;
- a Windows-1252 book with a short header; and
- an early Mobipocket book whose PalmDOC text is HTML.

The other two are Gutenberg's Ghosts as kindlegen made it, a book holding both MOBI 6 and KF8, and a book in Afrikaans in the older Mobipocket style, whose records carry two trailing entries.
Of more than 40 real books checked when these were chosen, none decoded to less text than it declared, and two dictionaries decoded to 166 bytes more, which the reader cuts off.
`samples.tsv` gives each one's source.

## MOBI tests built in code
<!-- id: mobi-tests-built-code; keys: MOBIFixture, PalmDOC, HUFF/CDIC, NCX, damaged copies, fixture; src: TextMouthProductionTests/MOBIFixture.swift, TextMouthProductionTests/MOBIHostileFileTests.swift -->

Every other MOBI test reads books that `MOBIFixture` builds in code, with PalmDOC or HUFF/CDIC compression, an NCX index, and damaged copies of each.

## Pictures, playlists, lexicons, and refusal advice
<!-- id: tests-pictures-playlists-lexicons; keys: PageImageReaderTests, PageImageArchiveTests, PLSAndXSPFPlaylistTests, PronunciationLexiconTests, RefusedFormatAdviceTests, scripted recognizer; src: TextMouthProductionTests/PageImageReaderTests.swift, TextMouthProductionTests/PageImageArchiveTests.swift, TextMouthProductionTests/PageImageDecoderTests.swift, TextMouthProductionTests/PageImageImportTests.swift, TextMouthProductionTests/PageImageProgressTests.swift, TextMouthProductionTests/PageImageTextTests.swift, TextMouthProductionTests/PageImageWordingTests.swift, TextMouthProductionTests/PageImageScriptedRecognizer.swift, TextMouthProductionTests/PageImageTestFixtures.swift, TextMouthProductionTests/PLSAndXSPFPlaylistTests.swift, TextMouthProductionTests/PronunciationLexiconTests.swift, TextMouthProductionTests/RefusedFormatAdviceTests.swift -->

- The PageImage tests make their pictures and archives in the test (PageImageTestFixtures) and replace Vision with a scripted recognizer (PageImageScriptedRecognizer, through PageImageReader.defaultRecognizer), so they depend on no recognition model
  There are no golden files for picture samples.
- PageImageDecoderTests cover the limits: the 100-megapixel check (a TIFF that claims it with no data proves it comes before decoding), orientation, and transparency.
- PageImageArchiveTests cover the order, ComicInfo.xml, and the 2,000-page cap; PageImageImportTests the import end to end, with the ZIP rules for a picture among other files.
- PLSAndXSPFPlaylistTests read both formats and import them end to end; PronunciationLexiconTests cover the W3C sample, a round trip, XML escaping, an external entity left unresolved, and the 5,000-rule cap; RefusedFormatAdviceTests pin each sentence of the table and that both alerts use it.

## Cue sheets, markers, and label files
<!-- id: tests-cue-sheets-markers-labels; keys: CueSheetTests, CueSheetArrangementTests, CueSheetImportTests, FLACCueSheetReaderTests, AudioMarkerListTests, OggChapterCommentTests, AudacityLabelsTests; src: TextMouthProductionTests/CueSheetTests.swift, TextMouthProductionTests/CueSheetArrangementTests.swift, TextMouthProductionTests/CueSheetImportTests.swift, TextMouthProductionTests/FLACCueSheetReaderTests.swift, TextMouthProductionTests/AudioMarkerListTests.swift, TextMouthProductionTests/OggChapterCommentTests.swift, TextMouthProductionTests/ChapterTrackWriterTests.swift, TextMouthProductionTests/AudacityLabelsTests.swift, TextMouthProductionTests/ChapterListExportTests.swift, TextMouthProductionTests/AudioEditorSavingTests.swift, TextMouthProductionTests/AudioFileInfoTests.swift -->

- CueSheetTests read the sheet text, CueSheetArrangementTests make the sections from folders (Finder's order, a sheet's places, a sheet past its audio, files outside the folder), and CueSheetImportTests import a sheet, a folder, and a ZIP end to end.
- FLACCueSheetReaderTests read the CUESHEET block and an embedded sheet; AudioMarkerListTests read the Broadcast Wave sample's two cue points, write markers into WAVE, AIFF, and CAF files made in the test and read them back, and compare afinfo's list.
  AudioFileInfoTests list the markers of all 18 samples.
- OggChapterCommentTests read CHAPTERnnn comments; ChapterTrackWriterTests write a chapter track and check the packets of the copy against the source's.
- AudacityLabelsTests and ChapterListExportTests read and write label files and the exported chapter lists, and AudioEditorSavingTests and AudioEditorEndToEndTests check that a save and an export keep their chapter markers.
- Not covered: other programs reading the markers written, cue sheets from the wild, and the labels checkbox with VoiceOver.

## Formats only ffmpeg reads
<!-- id: tests-ffmpeg-import; keys: FFmpegImportSnifferTests, FFmpegImportPlanTests, FFmpegHelperStreamTests, FFmpegHelperHostileFileTests, stand-in helper, PlayReady; src: TextMouthiOSTests/FFmpegInAppTests.swift, TextMouthProductionTests/RunningClockTests.swift, TextMouthProductionTests/FFmpegImportSnifferTests.swift, TextMouthProductionTests/FFmpegImportPlanTests.swift, TextMouthProductionTests/FFmpegImportConversionTests.swift, TextMouthProductionTests/FFmpegImportRealTests.swift, TextMouthProductionTests/FFmpegHelperProtocolTests.swift, TextMouthProductionTests/FFmpegHelperStreamTests.swift, TextMouthProductionTests/FFmpegHelperHostileFileTests.swift, TextMouthProductionTests/FFmpegTestSupport.swift, Scripts/make-form-change-sample.sh, Scripts/make-big-frame-sample.sh, Scripts/make-bad-packet-samples.py, Scripts/vendor/ffmpeg/test_build.py, TextMouthProductionTests/RefusedFormatAdviceTests.swift; status: incomplete; issues: Q13 -->

- The Mac carries its FFmpeg helper (TextMouthFFmpeg) and the iPhone links the same session, so every test of the import, the real ones too, runs on GitHub's runners as on a Mac, and none needs an installed ffmpeg.
  The FFmpeg classes below are shared with the iPhone's unit bundle, so each shows that both platforms make the same stream, book, and sentences from each sample.
- FFmpegImportSnifferTests tell each sample's container from its first bytes and pin the protection check of ASF files on bytes made in the test, one object at a time, PlayReady's among them.
- FFmpegHelperStreamTests read streams written by hand (FFmpegTestStream, which spells the protocol's letters and numbers out, so a change to the header that its comment does not follow fails them) and refuse every way a stream can break the protocol, each by name.
- FFmpegHelperProtocolTests run the real helper on real samples: the stream it writes, the exit status of each refusal, the 4 KB cut of a tag, and the import's Stop.
  Its Debug-only `confinement` mode proves that the sandbox leaves the open file readable and refuses the hosts file and a network connection.
- FFmpegImportPlanTests are pure functions of the helper's reports: the target of each sound, the limits of a source with no length, the formats' names, the failure each way a run can end in, and every sentence a listener hears.
- FFmpegImportConversionTests drive the import through FFmpegAudioConverter.Tool stand-ins, a script in front of the real helper where a run must end otherwise (a probe written by hand, a hang, a crash, an early end, a damaged stream).
  They cover the tracks a book leaves out, with and without the helper.
- FFmpegImportRealTests import every sample with the real helper, confined as in the app: each becomes an .m4a of the codec its source calls for, with its chapters and tags, as long as its sound.
  The samples are in TestData/format-samples, among them a WMA 1 and 2, a WMV, an AVI, an FLV, WebM, Matroska with chapters and several tracks, Speex, and RealMedia (.rm).
- FFmpegHelperHostileFileTests give the helper a damaged copy of every sample (cut, bytes flipped, a stretch zeroed or repeated) and demand an end by the protocol and an import that ends in a conversion or a failure by name.
  A damaged file could crash the helper, so they run on GitHub only (`TestMachine.skipUnlessGitHubRunner`; see [The hosted test suite](testing.md)).
- `Scripts/vendor/ffmpeg/test_build.py`, in `make check-selftest`, tests the build script without downloading.
  It covers the pins and the second source, a release that matches no pin, the patches' order and place in the key, the configure line, and that no path of the building Mac is left in the result.
- PhoneImportBranchTests pin that a book leaves out what only FFmpeg reads and can't be converted, before the iPhone refuses the rest of its converted audio; RefusedFormatAdviceTests pin the copy-protection sentence, with an .aax as its example.
- Not run anywhere yet: a real PlayReady file, and a Musepack sample (Q13), since no encoder made one, and the guard on the decoder's errors in a row, which no file can reach (see Confining and watching the helper in [Exports: audio only FFmpeg reads](../architecture/state/imports-audio-ffmpeg.md)).
- The form-change and edge samples, each made on this Mac by a script that only makes the file (the import reads it with the app's own FFmpeg):
  - `mka/mp3-form-changes.mka` (`Scripts/make-form-change-sample.sh`, which needs an ffmpeg with LAME): three one-second MP3 stretches joined byte for byte, 22,050 Hz mono (440 Hz), 44,100 Hz stereo (880 Hz), and 22,050 Hz mono (660 Hz).
    `FFmpegHelperProtocolTests` expect it converted to 22,050 Hz mono, exactly 70,272 frames (END's count equal, within 2), each stretch's pitch and the 880 Hz tone ending within 6 frames of frame 46,656, and `FFmpegImportRealTests` a book of 3.19 s within 0.02 s.
  - `ffmpeg-edge/mp3-ends-in-a-changed-form.mka` (the same script, its first two stretches): the sound ends in a converted stretch, so the resampler's final flush is read (exactly 46,656 frames).
  - `ffmpeg-edge/flac-7.1-24bit-65535.mka` (`Scripts/make-big-frame-sample.sh`, 802 bytes): 7.1, 24 bits, blocks of 65,535 samples, each channel a constant, so a frame over 1 MB must be split across PCM records and no channel's value may move.
  - `ffmpeg-edge/flac-900-bad-packets.mka`, `flac-1200-bad-packets.mka`, and `flac-all-bad-packets.mka` (`Scripts/make-bad-packet-samples.py`, which needs ffmpeg and ffprobe): 1,400 packets of which 900, 1,200, or all are refused.
    Those run on GitHub only (`FFmpegHelperHostileFileTests`): the first two end with status 0 and the good sound whole, and the last with exit 6, the import saying damaged.
  - `FFmpegHelperProtocolTests.testTheBoundsOfTheConversionOnMadeUpFrames` runs the Debug helper's `formcheck` mode, which needs no file; a PCM record of 1,048,576 bytes is read whole by the reader and one of 1,048,580 refused (`FFmpegHelperStreamTests`).
  - Each is listed in `TestData/format-samples/samples.tsv` with its size and SHA-256.
- The SharedSourceTests of `test_build.py` cover the shared source: a second build folder unpacks and copies nothing, an unwritable shared folder falls back to the work folder, an older copy is taken over, the archive is hashed once, and a two-process test of the lock.

### FFmpeg in the iPhone app
<!-- id: tests-ffmpeg-in-app; keys: FFmpegInAppTests, RunningClockTests, flvOfOnePCMTag, matroskaOfOnePCMBlock, countingSessionStarts, M4ASampleEntry, liblouis; src: TextMouthiOSTests/FFmpegInAppTests.swift, TextMouthProductionTests/RunningClockTests.swift, TextMouthProductionTests/FFmpegTestSupport.swift, TextMouthProductionTests/InProcessEngineTests.swift -->

- FFmpegInAppTests (`TextMouthiOSTests`) test what is the iPhone's own, on GitHub's simulator only:
  - where the session runs and its engine;
  - the stop check that reads, seeks, and FFmpeg's interrupt callback ask;
  - a call that hangs abandoned and every later call refused;
  - each call's time and the run's whole time;
  - the memory floor, where 0 left means no limit only in the simulator;
  - a frame past the bound refused before any allocation (exit status 13).
  Every call goes through an engine of the test's own (the app's is never refused for the tests after one), and hung work waits on a gate the test opens at its end.
- RunningClockTests (shared with the iPhone) script the clock's uptime to prove that a gap longer than a step counts only the step, and test the heartbeat with two holders and a hold right after a release.
- FFmpegTestSupport makes what a test needs of any size or count:
  - `flvOfOnePCMTag` and `matroskaOfOnePCMBlock` write one tag or block of PCM, with as many samples and channels as a bound test needs;
  - `countingSessionStarts` counts the session's opens, where the Mac counts launches;
  - `M4ASampleEntry` reads a converted .m4a's codec, channels, and rate from its boxes, since the iPhone has no afinfo to ask.
  The sample tones-aac.mka (AAC in Matroska) has its recipe in `samples.tsv`.
- No test may let a real liblouis call be abandoned (see [A test that may crash the host](testing.md#a-test-that-may-crash-the-host)).

## TextMouth's own TTA, WavPack, and Monkey's Audio readers
<!-- id: tests-own-audio-readers; keys: OwnAudioTrueAudioTests, OwnAudioWavPackTests, OwnAudioMonkeysAudioTests, OwnAudioTagTests, OwnAudioImportTests, make-own-audio-samples, pcm.tsv, fuzz; src: TextMouthProductionTests/OwnAudioTrueAudioTests.swift, TextMouthProductionTests/OwnAudioWavPackTests.swift, TextMouthProductionTests/OwnAudioMonkeysAudioTests.swift, TextMouthProductionTests/OwnAudioTagTests.swift, TextMouthProductionTests/OwnAudioImportTests.swift, TextMouthProductionTests/OwnAudioSampleSupport.swift, Scripts/make-own-audio-samples.py -->

- The samples are made by Scripts/make-own-audio-samples.py from tones made in the script, so every file is CC0, and encoded by the format's own BSD encoder built from its pinned source, or by ffmpeg run as a program.
  Each folder of TestData/format-samples (tta, wv, ape) holds a pcm.tsv with the shape of every file's audio and the SHA-256 of the samples its source held.
  The WavPack samples include hybrid files with their .wvc, files of 12, 20, and 24-in-32 valid bits (the header shift), floats, and files from ffmpeg's encoder.
- Each reader's test class decodes every sample and compares the samples with pcm.tsv bit for bit, so a change to a reader's arithmetic fails it: OwnAudioTrueAudioTests, OwnAudioWavPackTests, and OwnAudioMonkeysAudioTests.
  The WavPack shift samples are also checked end to end, the converted .m4a compared with the source's digest, not with what the decoder gives.
- Each class also damages the files (cut short, flipped bytes, crafted headers) and requires an OwnAudioError, never a trap, error of another kind, or hang.
  The Monkey's Audio fuzz pass takes samples of at most 9,000 samples, so it leaves out the multichannel, 24-bit stereo, and multi-frame files.
- OwnAudioTagTests read APEv2, ID3v2, and ID3v1 tags by hand, and OwnAudioImportTests import each format through ImportAudioConverter: a lossless file's .m4a holds the source's samples exactly, a hybrid file becomes AAC, and a refused file fails with its sentence.
- Nothing is played, and the only files Apple's frameworks open are the .m4a files the conversion wrote.
- Not covered: Monkey's Audio 3.93 to 3.98 files (refused, as no encoder at hand writes one), the iPhone build running the readers, and decoding speed on slow Macs.

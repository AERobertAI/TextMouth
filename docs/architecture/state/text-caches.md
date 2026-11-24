# Text caches and content indexes
<!-- id: text-caches-content-indexes; keys: cache, content.md, reading text, Markdown cache, fingerprint, index; src:  -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## content.md, the text cache
<!-- id: content-md-text-cache; keys: Markdown cache, regenerate, cache version, update queue, hidden elements, slow import, outdated cache; src: TextMouth/Services/MarkdownCacheService.swift, TextMouth/Services/TextCacheUpdateQueue.swift, TextMouth/Services/BookContentAnalysisService.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift, TextMouth/Parsers/EPUBParser.swift, TextMouth/Parsers/EPUBParser+Navigation.swift, TextMouth/Parsers/PublicationSemantics.swift, TextMouth/Parsers/HTMLToMarkdownConverter.swift, TextMouth/Models/SemanticVersion.swift, TextMouth/Services/BookTextEditing.swift -->

content.md: each text book's text cache, its text as Markdown.
A transcribed audiobook's content.md is its transcript's text instead (see [Transcripts](package-records-places-and-files.md)).
- Owner: MarkdownCacheService.
  The format's version is MarkdownCacheService.currentCacheVersion ("3.0.7"), and a book whose recorded cacheFormatVersion is older (SemanticVersion.isOutdated, which judges the metadata reader's version the same way; see [Metadata reader version](package-records.md)) is extracted again.
- Who may write it: MarkdownCacheService, which writes a new cache only after extraction succeeds and replaces the old one atomically (writeCache), and, through Edit Text, the user's own editor (see [Edited text](text-caches-rereads-edits.md)).
  Before it replaces the content.md of a book being edited, writeCache asks BookTextEditSessions (permitTextRebuild(of:writing:)), and afterwards tells it what it wrote (textRebuilt(_:writing:fingerprint:)).
  MarkdownCacheService.generateCacheContent runs inside BookContentAnalysisService.load: when an import reads its new book, when a reader opens a book whose cache is missing or outdated, and when a stale cache is rebuilt.
  MarkdownCacheService.generateCacheAnalyzeAndStamp runs for startup maintenance (extractMissingContentCaches, through TextCacheUpdateQueue), for Redo Text Extraction in Storage settings, and for the legacy migration.
  TextCacheUpdateQueue runs ordinary EPUBs on two utility workers and everything else one at a time.
  Maintenance leaves a book whose files are in the cloud as it is (see [Maintenance in a cloud library](cloud-state.md)).
  The extraction a cache is written from parses each EPUB document once: EPUBParser converts a document to Markdown from the DOM its contents scan parsed, and again only when a contents page later in the book names a new destination in it.
  It asks whether an element is hidden only in markup that holds the word (PublicationSemantics.mayCarryHiddenAttribute(_:)).
  HTMLToMarkdownConverter wraps emphasis and links in time that grows with what they wrap, not with what was converted before them.
- How others observe it: BookContentAnalysisService.load reads it and parses it into DocumentContent, splitting it into chapters over Substrings of the cache, one copy per chapter (MarkdownCacheService.splitChapters(_:)).

## Encoding a text file is read in
<!-- id: encoding-text-file-read; keys: character set, charset, mojibake, wrong characters, decoding failure, code page, UTF-8; src: TextMouth/Services/MarkdownCacheService.swift, TextMouth/Services/BookContentAnalysisService.swift, TextMouth/Parsers/BookParser.swift, TextMouth/Parsers/TextFileDecoder.swift, TextMouth/Models/Book.swift, TextMouth/Models/TextEncodingRecord.swift, TextMouth/Models/BookInfo.swift, TextMouth/ViewModels/LibraryViewModel+TextEncoding.swift -->

The encoding a text file is read in (FMT16): a plain text, Markdown, or HTML book's content.md is built from its file, whose bytes may name no encoding.
Every build of it reads the file in the encoding the book recorded when it was imported, or that the listener chose (encodingchoice), so a rebuild never moves the text under the book's saved places (the guess and the choice, in [Imports](imports-text-encodings.md)).
- Owner: the book, as Book.textEncodingRecord on its row (Book.textEncoding and textEncodingSource: the encoding, and who decided it) and BookMetadata.textEncodingRecord in its package record (Book.recordedTextEncodingRecord() gives the row's, else the record's).
  It is set by the import that guessed it, and again by the listener's re-read in another encoding.
  It is empty (TextEncodingRecord.unrecorded) for a book whose bytes named their encoding or that Windows-1252 reads right, and for every book imported before guesses were recorded.
- Who may write it: MarkdownCacheService.generateReportedCacheAnalyzeAndStamp, from the guess an import with guessingEncoding made (GeneratedCache.guessedEncoding) or, for a row that lost the encoding, from the record.
  LibraryViewModel.readTextAgain also writes it: it records the listener's choice, or the guess Automatic makes, with the text it reads (see [Reading a book again in another encoding](text-caches-rereads-edits.md)).
  No rebuild or migration guesses.
- How others observe it: MarkdownCacheService.encodingPolicy(of:decidingEncoding:) turns the book into the policy of a read.
  It is .guess for an import or an Automatic re-read (decidingEncoding set and no encoding or decision on the row), otherwise book.recordedTextEncodingRecord().policy.
  That policy is .chosen(identifier) for an encoding the listener chose, the recorded encoding (TextFileDecoder.EncodingPolicy.forBook(recording:)) for a guess, or the Windows-1252 fallback for a book with none.
  The two places that read a text file for a book both ask it: writeCache, which every generation passes through (the import, startup maintenance, Redo Text Extraction, the legacy migration, and the reader's regeneration), and extractedText(for:includesPages:).
  The launch's re-read for pages compares content.md with the text extractedText(for:includesPages:) reads, so the compare reads the file as the generation that wrote content.md did.
  When BookContentAnalysisService.load cannot write a cache for a book that has none, it parses the file straight (BookParser.parse(url:format:...encodingPolicy:)) with the same recorded policy, so the direct parse and the cache never start from different text.
  A book with no recorded encoding is read by the fallback, as every book was before guesses, so no rebuild changes a book already in the library.
  A recorded encoding that the bytes are not valid in, as a file changed since is, leaves them to the fallback too, and so does a book that lost the encoding from its row and its record both, as an older TextMouth's saves leave it: its next rebuild reads Windows-1252.
  A chosen encoding that the bytes are not valid in, as a file changed since is, is refused instead (TextEncodingError.invalidForChosenEncoding), never read by the fallback.

## Markdown parsed and refused for nesting
<!-- id: markdown-parsed-refused-nesting; keys: nested lists, deep nesting, parse limit, block quotes, recursion, too many levels; src: TextMouth/Services/MarkdownCacheService.swift, TextMouth/Parsers/MarkdownParser.swift, TextMouth/Parsers/MarkdownNesting.swift, TextMouth/Parsers/RawChapterLines.swift, TextMouthProductionTests/MarkdownNestingTests.swift, TextMouthProductionTests/MarkdownNestingCacheTests.swift -->

Markdown parsed from content.md and Markdown refused for nesting: MarkdownCacheService has two parses of a cached Markdown file, both through MarkdownDocParser.parseChapter, which refuses past the nesting limit (MarkdownNesting, in [Shared helpers](../shared-helpers.md)).
MarkdownCacheService.parseMultiChapterMarkdown, which Edit Text, rebuilds, the pages' re-read, and the exports commit text from, never drops a chapter that is refused and never reads it for a shorter text.
The chapter keeps its words as written as its text (`RawChapterLines.readingText`, B16: content.md's marker comments and backslash escapes left out).
One line is logged for the whole parse, MARKDOWN_NESTING_KEPT_RAW, counting the chapters kept raw of all the chapters and naming no title or word (see [Logs](logs.md)).
MarkdownCacheService.parseMultiChapterMarkdownRefusing, which writeCache calls for a text about to be written to content.md, throws the first refusal instead.
MarkdownCacheService.parseMultiChapterMarkdownNamingRefusal does the same for Edit Text and throws a RefusedChapter, which carries the refused chapter's number, so the refusal can name it ([Edited text](text-caches-rereads-edits.md)).
So an import of a file nested too deeply is refused with the guard's sentence before anything is written, no content.md is left behind, and a refused rebuild keeps the old cache.
Tests: MarkdownNestingTests and MarkdownNestingCacheTests (the import area of Scripts/test/areas.conf).

## Page markers in content.md
<!-- id: page-markers-content-md; keys: page break, page label, Go to Page, print page, pagination, comment marker; src: TextMouth/Parsers/MarkdownPageMarker.swift, TextMouth/Parsers/MarkdownMarkerWriter.swift, TextMouth/Parsers/MarkdownParser.swift, TextMouth/Models/BookPages.swift, TextMouth/Models/DocumentContent.swift, TextMouth/Parsers/EPUBParser.swift, TextMouth/Parsers/EPUBParser+Navigation.swift, TextMouth/Parsers/HTMLToMarkdownConverter.swift, TextMouth/Parsers/HTMLReadingText.swift, TextMouth/Parsers/PDFTextParser.swift, TextMouth/Parsers/DOCXParser+Converter.swift, TextMouth/Parsers/DOCXParser+Sections.swift, TextMouth/Parsers/DAISYParser.swift, TextMouth/Parsers/DAISYParser+TextExtraction.swift, TextMouth/Parsers/TextutilDocumentReader.swift, TextMouth/Parsers/TextutilPageBreaks.swift, TextMouth/Parsers/BraillePageAnalyzer.swift, TextMouth/Parsers/BrailleBookReader+Pages.swift, TextMouth/Parsers/PlainTextParser.swift, TextMouth/Services/Export/ExportDocumentWalker.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouth/Parsers/RTFDocumentReader.swift, TextMouth/Parsers/WordDocumentReader.swift -->

Pictures and comic book archives write a marker for every picture and TIFF page (PageImageText, page reader 1.0.0).
Page markers in content.md (PG01): `<!-- page: LABEL -->`, an inert HTML comment that names a page of the book and adds no reading text, so writing, moving, or deleting one moves no saved place.
- Owner: content.md, in the one form of MarkdownPageMarker (Parsers/MarkdownPageMarker.swift).
  Its label is the page's name as its source gives it, trimmed, with each inner run of white space made one space and cut to maximumLabelLength (32) Characters.
  A leading word "Page" is taken off when a name follows it (MarkdownPageMarker.withoutPagePrefix: "Page 12", "page xii", "PAGE: 3", and "Page12" are the pages 12, xii, 3, and 12, since the reader says "Page" itself; "Pages 4" and "Pageant" stay).
  It is taken off in decode as in the writer, so a content.md written with "Page 12" reads as page 12.
  A label that names no page takes the page's 1-based ordinal (MarkdownPageMarker.namesNoPage, asked after the word is taken off: nothing left, a lone period, or only the word "Page" in any capitals, which a generator writes as aria-label="Page " when it has no number for the page).
  A marker's markdown writes each %, <, >, control, line separator, and paragraph separator as % and two uppercase hexadecimal digits, and the second of two hyphens too, since CommonMark ends or refuses a comment at "--".
  MarkdownPageMarker.decode accepts only that exact form and refuses a comment with a raw <, >, or -- in its label, so a comment the source itself carried stays invisible (research/PAGES-RESEARCH-2026-10-21.md, section 2.2).
  MarkdownPageMarker.isNoMoreThanLabel(_:label:) is the one rule for whether text found where a page begins is no more than that page's label, so that the marker stands in for it (ST02).
  Text is no more than the label when it is empty, or at most maximumLabelLength Characters and, when there is a label, containing it or contained in it ignoring case.
  It is also no more than the label when it is only a page number in another numbering (looksLikeAPageNumber: numbers, Roman numeral letters, white space, and punctuation, as "V" under the label "5").
  Longer or other text is words, never dropped.
  EPUB's page-break elements (HTMLToMarkdownConverter.readsOwnText(ofPageBreak:page:)) and DAISY 2.02's page fragments (DAISY202PageMarker.isNumber(in:)) both ask it, and an element with no aria-label or title is a page by its text only when the text could be a label.
  An aria-label or title that names no page is passed over for the next one (HTMLToMarkdownConverter.attributeLabel).
  An element whose attributes say only "Page" is a page by its text only when the text is a page number (MarkdownPageMarker.isPageNumber: ASCII digits or a canonical Roman numeral).
  Its other words stay words, since readsOwnText compares them with the attributes' own text (attributeText), so "Page " over "Chapter One" begins no page and is read.
  The converter keeps each page's label as its source spelled it (HTMLToMarkdownConverter.PageStart, and HTMLPageTargets.sourceLabels for a page list's), and an element's text that is no more than either form is not read.
  So "Page 12" under "Page 12" stays unread, a number under "Page 12" is the page's own and is not read, and a caption "Page 12" under a label of "12" alone is read (stable020's rule).
  A heading that holds such an element leaves its number out of its label as the body text does.
  HTMLToMarkdownConverter.destinationMarkers(inside:) returns the page-break elements whose text is not read (EnclosedDestinations.unreadPageBreaks) with the markers it writes before the heading.
  HTMLReadingText.label(of:leavingOut:) skips them, so `Part <page 9>Two` is the heading "Part Two" with page 9 written before it.
  An element that holds words other than its page's number keeps them, and a read without pages (includesPages: false) writes the label as cache format 3.0.7 did.
  A PDF's label is the one PDFKit gives, except that PDFTextParser.plainNumberLabel(_:ordinal:) writes a page's own number as plain digits when PDFKit grouped it for the locale, as it does for a PDF that names no labels ("1,000", "1.000", "1 000"), so that the N of "Page 1000 of N" counts it.
  Any other label stays, and so does "1.100" on page 100, which only looks grouped.

### Who may write page markers
<!-- id: page-markers-writers; keys: marker writer, RunMemo, block placement, hard break, CommonMark comment; src: TextMouth/Parsers/MarkdownMarkerWriter.swift, TextMouth/Parsers/MarkdownPageMarker.swift -->

- Who may write it: the converters, only through MarkdownMarkerWriter.write (Parsers/MarkdownMarkerWriter.swift), which places heading annotations too.
  A caller that writes many markers in a row (the DTBook converter, and the HTML converter for the trailing markers of a run) passes a MarkdownMarkerWriter.RunMemo, remembering: &memo, which keeps where the last marker went, so the next goes just after it while nothing else has been written.
  The Markdown's length is the memo's, and the marker before the offset is the one remembered.
  Anything else is placed from the line as ever and forgets the memo.
  Placing from the line is linear in the line, so 5,000 markers after a 2 MB line took 15.7 seconds and 80 seconds or more in a DTBook.
  With the memo the same take under half a second, and the scan back to the line's last line feed stops at the first scalar only a word can hold, which the marker just written supplies.
  The output is byte for byte the writer's without a memo (compared on millions of random sequences).
  CommonMark opens an HTML block at "<!--", in a list item or quote too, and the block swallows the rest of the line, so a marker never begins a line that words follow: inside running text it stands where the page begins.
  At a block boundary it is a block of its own.
  At the opening of a list item or quote it is a block of its own inside it.
  At the opening of a heading it is written in the heading.
  After a hard break it is written at the end of the line before; and on a line indented four columns or more it is a block of its own at the margin.

### Which converters write page markers
<!-- id: page-markers-converters; keys: converters, form feed pages, page limit, page list, includesPages; src: TextMouth/Parsers/EPUBParser.swift, TextMouth/Parsers/HTMLToMarkdownConverter.swift, TextMouth/Parsers/PDFTextParser.swift, TextMouth/Parsers/DAISYParser.swift, TextMouth/Parsers/TextutilDocumentReader.swift, TextMouth/Parsers/BrailleBookReader+Pages.swift, TextMouth/Parsers/PlainTextParser.swift -->

  These converters write them:

  - EPUBParser (the page list, else the page-break elements; see EPUBParser.readPageList and givenPageLabel).
    A page list entry whose text is only the id it links to or carries gives no label unless the id is a page number, an NCX pageTarget's value standing in, and a list that labels none of its pages is passed over, for the NCX's and then the page-break elements.
  - HTMLToMarkdownConverter,
  - PDFTextParser,
  - DOCXParser (DOCXPageTracker),
  - DAISYParser,
  - TextutilDocumentReader (a second textutil run, TextutilPageBreaks, now only for a compound-file Word document older than Word 6, the one thing textutil still reads),
  - RTFDocumentReader and WordDocumentReader (the page-break spans of their own HTML; see Own readers of rich text and Word 97-2003, in [Imports](imports-rtf-and-word.md)),
  - BrailleBookReader (the braille pages of a file that marks them, a PEF's or a BRF's, BrailleBookReader+Pages.swift, PG12: Braille files, in [Imports](imports-braille.md)), and
  - PlainTextParser (the pages of form feeds, PG13).

  PlainTextParser.pagedBlocks(in:) finds a form feed's page: a form feed (U+000C) ends a line as it always did, so the reading text is the same with pages and without them.
  A form feed also begins a page at the first line after it that is read, a heading or a paragraph's line, not an empty line and not the underline a setext heading took.
  Several form feeds before one line begin a page each there, a blank page kept in its order; one with no words before it or none after it begins none.
  A book has at most MarkdownPageMarker.maximumPagesPerBook (100,000) pages, page 1 among them, the limit textutil's reader keeps (TextutilPageBreaks.maximumPages).
  Past it a form feed begins no page, though it still ends its line, so the text is unchanged, and a megabyte of form feeds between two words cannot write a million pages.
  Page 1 stands at the book's start and the markers are labelled 1, 2, 3 on from it, a block of their own before the block a page begins and, inside a paragraph, at the end of the line before.
  A text whose form feeds begin no page, and a read without pages (includesPages: false; the direct parse reads no pages either), write what cache format 3.0.7 wrote.
  Every extraction takes includesPages: true for every cache the app writes (MarkdownCacheService.writeCache).
  With includesPages: false it writes what cache format 3.0.7 wrote, which the tests that pin a parser's exact Markdown read with, and which PG09 compares a content.md with to find text changed by hand (MarkdownCacheService.readingTextsWithoutPages).
  The user's editor may delete, rename, or add one (see [Edited text](text-caches-rereads-edits.md)).

### How page markers are read
<!-- id: page-markers-observed; keys: PageBreak, BookPages, exports, HTML block, splitChapters; src: TextMouth/Parsers/MarkdownParser.swift, TextMouth/Models/DocumentContent.swift, TextMouth/Services/Export/ExportDocumentWalker.swift, TextMouth/Services/MarkdownCacheService.swift -->

- How others observe it: MarkdownParser turns each marker into a PageBreak in Chapter.pages, at the first whole word it stands before or in (PageBreak.firstWordStart: white space moves it forward to the next word, the middle of a word back to its start).
  DocumentContent gathers the chapters' into BookPages (a book's pages, in [The reader](reader.md)).
  The exports leave markers out (ExportDocumentWalker, which every export writer reads, the Markdown writer included).
  An HTML block that begins with one or more complete markers of ours and then holds words (CommonMark swallows the rest of such a line, and an Edit Text change can make one) is read as its markers followed by the Markdown of the rest (PlainTextExtractor.visitHTMLBlock, ST05).
  The rest's words, emphasis, and offsets are read in place.
  MarkdownParser.isReadingRestOfMarkerLine bounds it to one level, so a second marker-led block inside the rest reads as before.
  MarkdownCacheService.splitChapters does the same for a chapter line with words after it (chapterMarkerFollowedByWords, ST05b): the marker begins its chapter and the words are the chapter's first line.

## The page reader's version
<!-- id: page-reader-version; keys: version bump, upgrade pages, stale pages, format version, pages re-read, wasted re-read; src: TextMouth/Models/PageReaderVersions.swift, TextMouth/Models/Book.swift, TextMouth/Models/BookInfo.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouth/Services/LibraryPersistenceService.swift, TextMouth/Services/BookContentAnalysisService.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift, TextMouth/Services/BookTextEditing.swift, TextMouth/Parsers/TextFileDecoder.swift, TextMouth/Parsers/WebArchiveReader.swift, TextMouth/Parsers/PlainTextParser.swift, TextMouth/ViewModels/LibraryBookUpdates.swift, TextMouth/Services/AudioEditing/AudioEditActivity.swift, TextMouth/Services/StorageGeneration.swift, TextMouth/ViewModels/ReaderViewModel+EditedText.swift, TextMouthProductionTests/TextPipelineGoldenTests.swift -->

The page reader's version (PG09): which page reader wrote a book's content.md.
- Owner: the package record and the library row, as Book.pageReaderVersion (BookInfo.state.pageReaderVersion), an analysis-owned field (Book.ContentAnalysisFields, in [Package records](package-records.md)) that is nil until a generation stamps it.
  PageReaderVersions.current(for:) gives each format's version, and its comments say what each bump changed and which books it read again.
  EPUB is at "1.0.3" and HTML at "1.0.4".
  HTML was split from EPUB at 1.0.4: the text decoder then began to read unmarked UTF-16 and UTF-32 in every script, and an HTML file that declares ISO-2022-JP, unless the book recorded its encoding (TextFileDecoder.unmarkedUnicode(in:latinOnly:) and Evidence).
  That changes the text of HTML books and of no EPUB.
  DOCX, DOC, and WordML are at "1.3.0", RTF and RTFD at "1.2.0", ODT and MOBI at "1.1.0", DAISY and plain text at "1.0.1", braille at "1.1.2", and PDF and KFX at "1.0.0".
  A PDF's changed labels leave its reading text alone, so a PDF already in the library keeps its old labels until Redo Text Extraction.
  Markdown has no page reader and no version, so its books read the new way whenever their text is built again.
  A format without pages has nil, and its books are never read again for them.
  A format that gains pages later adds a case of its own, which reads again only its own books (V07), as braille did (PG12) and plain text did for its form feeds (PG13).
  A braille book with no pages (a BRL's) and a plain text book with no form feed between words, most of them, are read again once, their content.md byte for byte as before, and stamped.
  A web archive's text page writes no pages (WebArchiveReader.MainPage.markdown() asks PlainTextParser for none).
  That is because a web archive has no page reader line of its own (PageReaderVersions.current(for:) is nil for it) and no book of it is read again for pages, so its books would differ by when they were read.
- Who may write it: every generation records its format's current version (MarkdownCacheService.GeneratedCache.pageReaderVersion, committed with the analysis through LibraryPersistenceService.saveContentAnalysis(…pageReaderVersion:)), since every generation writes pages.
  When textutil's run for the pages failed or timed out, the generation records a note after the version instead (PageReaderVersions.stamp(for:pageRunFailed:previous:), PG16): "1.0.0+failed-once", which the next launch reads again, then "1.0.0+failed", which no launch reads again.
  Only a compound-file Word document older than Word 6, the one thing textutil still reads since 0.4.1, has such a run; an own reading makes no second run, so its book is never noted this way.
  The launch's batch also stamps a book whose content.md it keeps, through BookTextEditSessions.settleKeptText: the format's version, with "+failed" (PageReaderVersions.failedStamp(for:)) for a book whose file is missing.
  A book whose file could not be read gets "+failed-once" and then "+failed" (PageReaderVersions.failureStamp(for:previous:)).
  An analysis that carries none leaves the record's own (Book.applyContentAnalysis): an analysis says nothing about which page reader wrote content.md.

### How the page reader's version is read
<!-- id: page-reader-version-read; keys: isDueForPages, launch re-read, pageUpgradeCheck, PAGES_UPGRADE_SUMMARY, V05; src: TextMouth/Models/PageReaderVersions.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift, TextMouth/Services/BookContentAnalysisService.swift, TextMouth/Services/BookTextEditing.swift -->

- How others observe it: PageReaderVersions.isDueForPages(_:) is true for a book whose version is behind its format's (PageReaderVersions.isOutdated, which reads a note apart from its version and takes "+failed-once" as behind) while the launch re-read is on.
  It is on since PG16 (PageReaderVersions.launchRereadIsOn).
  Then booksNeedingCacheUpdate chooses the book, and BookContentAnalysisService.recoveredTextCache does not recover a record that predates its format's page reader.
  A book whose stamp notes success (PageReaderVersions.notesSuccess: an earlier page reader read its pages) and whose content.md is as its record describes it is read again without the compare below (V05).
  A build that records every edit wrote it, and compared, it would differ from what the newer reader writes, so the first bump of a format's page reader would keep a copy of every book of the format (EPUB at 1.0.1, 1.0.2, and 1.0.3, and HTML at those and 1.0.4, keep none).
  A book with no stamp, as every braille and plain text book has when its format gains its reader (V07), or whose stamp notes a failure, is compared as ever, so a braille book whose reading changed meanwhile keeps a copy.
  For a book behind only in its pages (isBehindOnlyInPages) that holds no edit taken, the batch compares the whole content.md, byte for byte, with the book's file read again (pageUpgradeCheck), before it looks for an edit saved while TextMouth was closed.
  A content.md that is the file's text without pages is read again with them.
  The file's text with pages, which a batch stopped before its commit leaves, only has its record stamped.
  Any other text, which nothing can tell from an edit made before B12-OCT, is copied beside content.md as `content.md.edited-<UTC time>` (PageUpgradeCopies, through BookTextEditSessions.keepCopy), logging PAGES_REPLACED_TEXT, and read again with pages, its places relocated.
  When no copy can be made, it is kept, recorded as edited (Book.editedText, B12-OCT) and stamped, logging PAGES_SKIPPED_CHANGED_TEXT.
  A book whose file is missing is stamped "+failed", and one whose file could not be read, with pages or without, "+failed-once" and then "+failed" (PageReaderVersions.failureStamp), logging PAGES_SKIPPED_UNREADABLE.
  A read with pages whose textutil run failed never matches: a content.md changed since its record is then left unstamped for the next launch (PAGES_DEFERRED).
  A changed source, or a content.md changed since its record that is not the text with pages, is left to the stale-cache and FR05 checks.
  A book a reader has open gets its new text handed over (ST01): the batch reads open books first (LibraryViewModel.openBooksFirst(_:open:)).
  The batch's updateTextCache returns a TextCacheUpdate: its summary and, for a book open in a reader (asked of the worker through AudioEditActivity.isOpenInReader), its textForOpenReader, the text parsed and indexed as it was written.
  The batch's updateProgress, through applyTextCacheUpdate(_:atOnce:) (which a re-read in another encoding calls too; see [Reading a book again in another encoding](text-caches-rereads-edits.md)), applies the analysis to the row on the main actor and calls LibraryBookUpdates.textReplaced.
  The reader then shows the text with its pages in place of the one it loaded, its cursor on the same words (the edited-text path, ReaderViewModel+EditedText).
  Every other book's update keeps no text. pageUpgradeCheck rebases the book to the data directory's current place itself (StorageBoundary.rebasedToCurrent), as the queue does for each book it hands over, so the check is right for any caller.
  The batch ends with one PAGES_UPGRADE_SUMMARY line counting the books given pages, replaced keeping a copy, kept as changed, skipped (in the cloud, missing), and failed.
  TextPipelineGoldenTests pins that includesPages: false still writes the content.md recorded before pages for the golden books that gained them.
  The review that kept the re-read off until PG16 is restated in the comment on launchRereadIsOn; the re-read's tests switch it off with _setLaunchRereadForTesting(_:) to check that the batch then chooses nothing.

## The content index
<!-- id: content-index; keys: table of contents, outline, stale index, golden digests, audiobook layout, chapter list; src: TextMouth/Models/BookContentIndex.swift, TextMouth/Models/DocumentContent.swift, TextMouth/Services/BookContentAnalysisService.swift, TextMouth/Models/BookInfo.swift, TextMouth/Services/LibraryPersistenceService.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouthProductionTests/TextPipelineGoldenTests.swift, TextMouthProductionTests/TextPipelineFixtures.swift -->

The content index (BookContentIndex): chapter starts and lengths, word counts, headings with their offsets, totals, and, for audiobooks, the media layout and timing, with every clip of a chapter that plays several.
For a transcribed audiobook it also holds its transcript text's layer (BookContentIndex.transcript; see [Transcripts](package-records-places-and-files.md)).
- Owner: the package record, as its contentIndex.json (BookInfo.contentIndex), beside bookInfo.json.
  Its version is BookContentIndex.currentVersion ("1.0.0"). library.json keeps only the totals and contentIndexVersion, so launch never decodes every heading in the library.
- Who may write it: BookContentAnalysisService builds it (BookContentIndex.build) from parsed content, its word counts counted as the runs of Characters that are not whitespace (Chapter.wordCount(of:), which reads a Character whole only around non-ASCII bytes and makes no substring per word).
  It is saved only through LibraryPersistenceService (saveContentAnalysis or saveBookInfo(for:contentIndex:)).
- How others observe it: BookContentAnalysisService.load uses a saved index only when it passes validationFailure(for:audioBaseURL:) and, for a text book, alignmentFailure(with:countingWords:) against the parsed chapters.
  One that fails is logged as CONTENT_INDEX_REJECTED and replaced by a fresh index.
  The reader takes headings, chapter offsets, and totals from the index inside its DocumentContent.
- Which version to change: a change to source extraction changes MarkdownCacheService.currentCacheVersion.
  A change only to how the reading text or the index is derived changes BookContentIndex.currentVersion instead, so existing Markdown is indexed again without converting every source.
  Reading Markdown tables a row at a time (each row a paragraph, its cells one space apart, the table set apart from the text around it, as HTMLReadingText reads an HTML table) changed neither version.
  The content.md is unchanged, and the change only adds breaks and spaces, so the saved index of every book it affects, a DOCX or Markdown book holding a Markdown table, no longer lines up with its reading text, fails the alignment check once (CONTENT_INDEX_REJECTED), and is rebuilt from the cache.
- What guards the output: TextPipelineGoldenTests hold the digests of what the text pipeline produced on main before the performance work, for TestData's books (its two untracked DAISY audio ZIPs only where a checkout has them), synthetic books, and generated EPUBs.
  The digests cover every content.md an import writes, the reading each book opens to (titles, text, headings, and word counts), and the converters' own output.
  A change meant to keep the output must leave them passing.
  A deliberate change of output, which changes one of the versions above, records the new digests, which each failure names, once the new output has been checked.
  TextPipelineBefore (TextMouthProductionTests/TextPipelineFixtures.swift) keeps the code each change replaced, for these tests and the benchmarks to compare with.

## Text cache fingerprints
<!-- id: text-cache-fingerprints; keys: change detection, mtime, iCloud placeholder, evicted file, file size; src: TextMouth/Models/TextCacheFingerprint.swift, TextMouth/Services/BookContentAnalysisService.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift, TextMouth/Services/FileImportService.swift, TextMouth/Services/BookTextEditing.swift -->

Text cache fingerprints (TextCacheFingerprint): for the source and for content.md, the size, the modification time, and the MD5 digest, as they were when the cache was written.
Times are kept in nanoseconds but compared to the microsecond (FileStamp.hasSameModificationTime(as:)), since a sync service can give a file back with its time moved by a fraction of a microsecond.
An RTFD, being a folder, is stamped by the regular files in it (FileStamp(of:): their total size and latest modification time) and digested by its checksum (FileImportService.contentChecksum(of:format:)).
Both come from the walk its import used (regularFilePaths(in:)), which passes over hidden items and symbolic links.
Browsing the folder changes neither, and changing, adding, or removing a file in it changes both.
- Owner: the package record (state.textCacheFingerprint, also copied into the index), mirrored on the library row.
- Who may write it: MarkdownCacheService records them when it writes a cache, and BookTextEditSessions when it takes an edit.
  BookContentAnalysisService fingerprints a current cache written before fingerprints existed, once, the first time the cache passes every check; that result is saved by the usual save.
- How others observe it: BookContentAnalysisService.loadExistingCache compares the files' sizes and dates with the record before it trusts the cache or its index, and reads a file for its digest only when the size is unchanged but the date is not.
  A changed file is logged as CACHE_STALE and the cache is rebuilt from the source.
  Startup maintenance compares the sizes the library row recorded with the files, two stat calls a book, to find stale caches without reading anything.
  It reads for its digest only a content.md of the recorded size with another date (hasRedatedTextCache), which may hold an edit saved while TextMouth was closed (see [Edited text](text-caches-rereads-edits.md)).
  One only touched keeps its digest, and the row records its new stamps, so the next launch reads nothing.
  A package's record is checked by completedTextCacheIndex when recovering an interrupted batch.
  A dataless file, whose content is only in the cloud, is never judged by the size and date it reports, since an evicted iCloud Drive file can report 0 bytes, and never read for its digest (FileStampComparison.dataless).

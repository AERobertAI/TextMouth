# Document goldens
<!-- id: document-goldens; keys: golden file, DocumentDump, regression, snapshot test, baseline output; src: TextMouthProductionTests/DocumentGoldenTests.swift, TextMouthProductionTests/DocumentDump.swift -->

Part of [TextMouth's documentation](../../README.md).

Document goldens: `DocumentGoldenTests` compares every document in TestData with `TestData/golden/<file name>.golden`, and names every difference in words.
A golden records the file's format, title, author, chapter and word counts, the length and checksum of its reading text, the first and last 300 characters of that text, its headings with their levels, and, for a book with audio, its tracks.
The test takes about 1 second.

## Recording new goldens
<!-- id: recording-new-goldens; keys: re-record, update goldens, record goldens, heavy lock; src: Scripts/test/update-goldens.sh, Scripts/test/run-area.py, Scripts/agents/heavy_lock.py, TextMouthProductionTests/DocumentGoldenTests.swift -->

`Scripts/test/update-goldens.sh` records new goldens after a deliberate change to what a parser, the text pipeline, or heading detection produces.
It runs `DocumentGoldenTests` alone with `TEXTMOUTH_UPDATE_GOLDENS=1`, which writes the goldens into the source tree instead of comparing, and then lists the goldens that changed.
Review the diff of `TestData/golden` and commit it with the change it records; a golden that looks wrong, such as a missing heading or a wrong title, is a bug to report, not a record to commit.
The two large optional DAISY books are never recorded.
The script builds, through `run-area.py`, and neither takes the machine-wide heavy-work lock (`Scripts/agents/heavy_lock.py`; see [The heavy-work lock](building-ios.md#the-heavy-work-lock)), which only the build train and the iOS type-checks take for themselves.
So run it under the lock: import `heavy_lock.py` by path (`python3 -I` leaves a script's own folder out of `sys.path`) and run the script inside `with held(owner, wait_seconds):`, so that it does not build beside a train or another build.

## The PDF golden's macOS version
<!-- id: pdf-golden-macos-version; keys: XCTSkip, isMacOSDependentFormatSample, skipped test, macOS major version, Vision OCR; src: TextMouthProductionTests/DocumentGoldenTests.swift, TextMouthProductionTests/TextPipelineFixtures.swift -->

A PDF's golden notes the macOS version it was recorded on, and its test skips on a Mac of another major version, since PDFKit and Vision change what they read with macOS.
So do the goldens of the format samples in the pdf, rtf, rtfd, doc, dot, odt, ott, and wordml folders (`macOSDependentFormatSampleFolders`), recorded on macOS 26.3; the other format samples are compared on every Mac.
The list still names the folders other than pdf, though TextMouth's own readers now read nearly all of their samples.

## Format samples with goldens
<!-- id: format-samples-goldens; keys: formatSamplesPrefix, formatSampleGoldenName, samples folder, sample list; src: TextMouthProductionTests/TextPipelineFixtures.swift, TextMouthProductionTests/ODTTestSupport.swift, TextMouthProductionTests/DocumentGoldenTests.swift, TextMouthProductionTests/RTFTextutilComparisonTests.swift, TextMouthProductionTests/DOCXRealFileTests.swift, TextMouthProductionTests/WordDocumentReaderTests.swift, TextMouthProductionTests/WordDocumentComparisonTests.swift, TextMouthProductionTests/ODTTextutilComparisonTests.swift, Scripts/test/update-goldens.sh -->

The format samples in `TestData/format-samples` that TextMouth reads as text have goldens too.
They are 46 of the 91 samples of the rich text, RTFD, Word, Word 97-2003, Word template, OpenDocument, Word 2003 XML, web archive, SSML, and DTBook folders (and the EPUB and PDF page samples), each named by its path inside that folder with every `/` written `__`, as in `rtf__headings.rtf.golden`.
`TextPipelineFixtures.formatSampleNames` lists them, and `DocumentGoldenTests` fails when a sample of those folders is missing from it.
`TextPipelineFixtures.formatSamplesHeldBack` names any sample whose golden is neither recorded nor compared, and why:

- one whose golden showed a reader bug, until the bug is fixed, and
- the 12 real RTF files from LibreOffice (`rtf/libreoffice-*.rtf`), held back because
  - `RTFTextutilComparisonTests` compares their reading with textutil's word for word and names every difference, and
  - a golden of textutil's reading would pin what TextMouth's own reader replaces (textutil refuses three of them outright).

Three more groups are held back or left to a comparison test.
The 9 real DOCX files from LibreOffice (`docx/libreoffice-*.docx`) are held back because `DOCXRealFileTests` asks them, by name, what hidden text, notes, and text boxes read as, where a failure says what changed.
The 10 Word 97-2003 files of `TextPipelineFixtures.wordFollowUpSamples` are held back because `WordDocumentReaderTests` and `WordDocumentLegacyTests` pin what each reads as.
`WordDocumentComparisonTests` (Word 97-2003) or `WordDocumentLegacyComparisonTests` (Word 6 and Word 95) also compares each file's words with textutil's.
And the 15 real OpenDocument files from LibreOffice (`odt/libreoffice-*.odt`) have no goldens (`TextPipelineFixtures.isComparedByODTTests`, which is not part of `formatSamplesHeldBack`), since `ODTTextutilComparisonTests` compares their reading with textutil's and names every difference.
The other real .doc and .dot files from LibreOffice are not held back: they have goldens, recorded again for the own reader.
`Scripts/test/update-goldens.sh` records these goldens with the others.
Only the Word 95 file `doc/libreoffice-tdf150197_anlv2ListFormat.doc` adds a textutil run; every other format sample is read by TextMouth's own readers and starts no textutil (the odt, ott, and wordml samples among them since 0.4.0).

## Comparison tests for rich text and Word
<!-- id: comparison-tests-rich-text-word; keys: RTFDocumentReader, reference reader, diff table, OwnDocumentReaders switch, textutil replacement; src: TextMouthProductionTests/RTFTextutilComparisonTests.swift, TextMouthProductionTests/WordDocumentComparisonTests.swift, TextMouthProductionTests/WordDocumentLegacyComparisonTests.swift, TextMouth/Parsers/OwnDocumentReaders.swift, TextMouth/Parsers/RTFDocumentReader.swift, TextMouth/Parsers/WordDocumentReader.swift, TextMouth/Services/Export/RTFExportWriter.swift -->

`RTFTextutilComparisonTests` and `WordDocumentComparisonTests` (Mac only) are the check that let the Mac read rich text and Word 97-2003 with TextMouth's own readers in place of textutil.
Each reads a sample both ways, textutil with `OwnDocumentReaders.$forcesTextutil` bound to true and the own reader directly, turns both into reading text with the converter an import uses, and compares them.
Every difference is named in a table in the test, with the reason a listener would accept it; any other difference fails the test and is listed in its message.

- `RTFTextutilComparisonTests`
  - compares the RTF samples `headings`, `page-breaks`, `word-list-table`, and `word-styles` and the two RTFD samples by their words (runs of letters and digits, in order) and requires every heading of textutil's reading in the own one;
  - compares pages (every page that textutil finds, the own reading finds before the same words, and it may find more);
  - compares the output of `RTFExportWriter` the same way; and
  - tests the routing and the test hook.

  Its `realFiles` table lists the 12 real files, each with its words only textutil has, its words only the own reader has, its headings, its pages, and why.
  The reasons are that
  - the own reader reads what textutil drops (the notes, and the words of a text box),
  - it begins a page at a section break that textutil's plain text loses,
  - textutil runs a shape's property names into the first word of each text box, and
  - textutil refuses three files the own reader reads.

  No list's number is in the reading text, so the table names no difference in one (the number of a list item in a table cell is in the Markdown).
- `WordDocumentComparisonTests` reads every sample of the `doc` and `dot` folders.
  One test requires that the samples the reader leaves to textutil (it answers nil) are exactly `leftToTextutil`, the Word 95 files `libreoffice-tdf150197_anlv2ListFormat.doc` and `poi-Bug51944.doc` (an identifier of 0xA699 and a version of 0x68, a layout of Word 95 or older).
  The test reads with `readsOldLayout: false`, so these two stay with textutil here, and `WordDocumentLegacyComparisonTests` (see [Word 6 and Word 95 tests](#word-6-and-word-95-tests)) reads them with the old layout.
  The others compare the words in order, textutil's headings (all must be the reader's, at any level), and the number of pages.
  Its named differences are tables in the test, each with its sample names and reason in the code:
  - `wordsOnlyTextutilReads`: the header and footer text that textutil adds at the end of a document and the reader leaves out;
  - `wordsOnlyTextutilJoins`: the words the reader keeps apart that textutil runs into one, such as the nine one-letter cells of IDENTICAL in a table;
  - `instructionWordsOnlyTextutilReads`: the field instructions that textutil reads as words (TITLE, SAVEDATE, LASTSAVEDBY, PRINTDATE, MERGEFORMAT, and SHAPE);
  - `headingsOnlyTextutilFinds`: the headings of textutil's size guess that the reader does not make, since the reader trusts the author's styles and never guesses a heading inside a table that lays the page out; and
  - `listNumbersOnlyReaderReads`: the numbers the reader would write with `WordDocumentReader.speaksListNumbers` on, which is off (the comparison of the words form takes each off the front of its paragraph, and the samples read as textutil's words by default).

## Word 6 and Word 95 tests
<!-- id: word-6-word-95-tests; keys: legacy Word, Word for DOS, fuzz, OLE; src: TextMouthProductionTests/WordDocumentLegacyTests.swift, TextMouthProductionTests/WordDocumentLegacyFeatureTests.swift, TextMouthProductionTests/WordDocumentLegacyHostileTests.swift, TextMouthProductionTests/WordDocumentLegacyComparisonTests.swift, TextMouthProductionTests/WordDocumentSymbolTests.swift, TextMouthProductionTests/WordDocumentSymbolFontTests.swift, TextMouthProductionTests/WordLegacyTestSupport.swift -->

Word 6 and Word 95 (0.4.1):

- `WordDocumentLegacyTests` and `WordDocumentLegacyFeatureTests` read documents built in code in the order Word writes them (`WordLegacyTestSupport`),
- `WordDocumentLegacyHostileTests` gives the old layout hostile files (every FIB field at its extremes, truncations, byte flips, and a loop of styles), and
- `WordDocumentLegacyComparisonTests` (Mac only) reads the samples of `TestData/format-samples/doc6` and the two old-layout files of `doc` with the reader and with textutil, and compares
  - their words in order (the code-page rows of its table are the files textutil reads in the wrong code page),
  - their brackets,
  - their headings (the reader's must include textutil's), and
  - their pages (a continuous section break begins none in the reader).

`WordDocumentSymbolTests` and `WordDocumentSymbolFontTests` pin the reading of a symbol by its font in both layouts, each WordPerfect code, the picture fonts, the clones of Symbol, and text typed in a symbol font.
The figures of a real-file comparison against textutil, of 312 old-layout and 340 Word 97 government documents the repository does not hold, are in [Imports: rich text and Word documents](../architecture/state/imports-rtf-and-word.md).

## Reader tests for rich text and Word
<!-- id: reader-tests-rich-text-word; keys: OLE, CFB, fuzz, performance, numbering; src: TextMouthProductionTests/RTFReaderTests.swift, TextMouthProductionTests/WordDocumentReaderTests.swift, TextMouthProductionTests/WordDocumentListTests.swift, TextMouthProductionTests/WordDocumentTestSupport.swift, TextMouthProductionTests/CompoundFileTestSupport.swift, TextMouthProductionTests/CompoundFileTests.swift, TextMouthProductionTests/RTFHostileReaderTests.swift, TextMouthProductionTests/WordDocumentHostileTests.swift -->

`RTFReaderTests` (55 tests) and `WordDocumentReaderTests` (129) test the readers on the samples and on documents built in code, for the structures the samples lack.
`WordDocumentTestSupport` writes a Word 97-2003 document from a description of its paragraphs, styles, and sections, on `CompoundFileBuilder`'s compound file.
`RTFHostileReaderTests`, `WordDocumentHostileTests`, and `CompoundFileTests` give them hostile files, which must end with a document or a typed failure, never a crash, in well under a second.
`WordDocumentListTests` (43) reads Word's list tables in both forms, the numbers silent and spoken, with hostile list inputs, and times the two hangs the review found (a style chain walked for every character, and every piece walked for every note).

## Where the real sample files come from
<!-- id: where-real-sample-files-come; keys: provenance, attribution, third-party samples, downloaded samples, licensing; src: TestData/format-samples/samples.tsv -->

The real files are from the LibreOffice core repository's test data, under MPL-2.0, and from Apache POI's test documents, under Apache-2.0 (the five `doc/poi-*.doc` files, the first POI files here).
`TestData/format-samples/samples.tsv` lists each with its source, licence, size, SHA-256, and what it exercises, besides the files made on this Mac:

- 12 RTF files,
- 9 DOCX files,
- 15 OpenDocument files, and
- the Word 97-2003 files:
  - `libreoffice-*.doc` and `.dot`, of which `libreoffice-tdf150197_anlv2ListFormat.doc` is Word 6 or Word 95,
  - the five POI files, of which `poi-Bug51944.doc` is also a layout of Word 95 or older, and
  - the 16 files of the `doc6` folder, from POI and LibreOffice, of Word 6 and Word 95.

Each downloaded file was fetched into a folder of its own and read by a script run with `python3 -I`.
The audio samples made on this Mac for the FFmpeg import (`mka/mp3-form-changes.mka` and the folder `ffmpeg-edge`) are in the same list, with the three `Scripts/make-*sample*` scripts that make them, described in [Formats only ffmpeg reads](testing-formats.md#formats-only-ffmpeg-reads).

## DOCX tests built in code
<!-- id: docx-tests-built-code; keys: DOCXParser, w:vanish, endnotes, text frame; src: TextMouthProductionTests/DOCXTestPackages.swift, TextMouthProductionTests/DOCXHiddenTextTests.swift, TextMouthProductionTests/DOCXNotesTests.swift, TextMouthProductionTests/DOCXTextBoxTests.swift, TextMouthProductionTests/DOCXEmphasisTests.swift, TextMouthProductionTests/DOCXRealFileTests.swift -->

The DOCX tests build packages in code (`DOCXTestPackages`) for the cases the samples lack.

- `DOCXHiddenTextTests` pins hidden text through a run, its character style, and the paragraph style by the toggle rule of ECMA-376 17.7.3, and the text hidden only on the web;
- `DOCXNotesTests` pins the notes parts (separators skipped, only the notes a read reference points to, a damaged notes part losing only its notes);
- `DOCXTextBoxTests` pins a text box written twice, read once and after its paragraph;
- `DOCXEmphasisTests` requires that no `*` or `~` is spoken, with a sweep of 2,128 paragraphs of runs in every emphasis; and
- `DOCXRealFileTests` reads the 9 real files by name.

Against the repository's 1,472 Word files (the 9 above, the DOCX, DOCM, DOTX, and DOTM samples, and 1,447 LibreOffice test documents under 60 KB), seven refuse to open, as they did before, and none speaks a mark that is not a character of its text.

## Symbols of Word documents
<!-- id: symbols-word-documents; keys: Wingdings, Webdings, mutation test, symbol character, charmap; src: TextMouthProductionTests/DOCXSymbolTests.swift, TextMouthProductionTests/DOCXTestPackages.swift -->

The symbols of Word documents are pinned by `DOCXSymbolTests` and `WordMLSymbolTests` (TextMouthProductionTests/DOCXSymbolTests.swift), which build their packages in code (`makeDOCXPackage` takes `otherParts:` for `word/fontTable.xml`).

- They cover
  - a `w:sym` in the Symbol font, in a font of pictures, in a WordPerfect font, and in an ordinary font, and symbol text typed in each;
  - the order of a run's font (its own, its character style's, its paragraph style's, the default paragraph style's, the defaults');
  - a damaged font table never losing the book; and
  - the Word 2003 XML half (`w:h-ansi`, `w:docDefaults`, `w:charset`).
- Four tests pin guards that deleting would not fail the other tests:
  - `testAHostileSymbolCharacterNeverTraps` (a `w:char` with a sign, a space, no digits, five digits, or 100,000 digits),
  - `testASymbolInANotesCustomMarkIsSkippedWithTheMark`,
  - `testASymbolInADeletionOrAMoveAwayIsNotRead`, and
  - `testStylesBasedOnEachOtherInALoopEnd`.

## Speech export tests
<!-- id: speech-export-tests; keys: FMT43, audiobook export, test area, fake synthesizer; src: Scripts/test/areas.conf, Scripts/test/run-area.py, TextMouthProductionTests/SpeechBufferSynthesizerTests.swift, TextMouthProductionTests/SpeechChapterRendererTests.swift, TextMouthProductionTests/SpeechExportDialogTests.swift, TextMouthProductionTests/SpeechExportEncoderTests.swift, TextMouthProductionTests/SpeechExportJobTests.swift, TextMouthProductionTests/SpeechExportOptionsTests.swift, TextMouthProductionTests/SpeechExportServiceTests.swift, TextMouthProductionTests/SpeechExportSupportTests.swift, TextMouthProductionTests/SpeechExportTextTests.swift, TextMouthProductionTests/ConfigTestSupport.swift, TextMouth/Services/SpeechExport/SpeechBufferSynthesizer.swift -->

The speech export has its own area, `[speech-export]` in Scripts/test/areas.conf, with nine classes, which that file lists.
Run it with `python3 Scripts/test/run-area.py speech-export`.

- `SpeechChapterRendererTests` has an opt-in test that writes a real voice into a file.
  It runs only with `TEXTMOUTH_REAL_SPEECH_EXPORT=1`, which the test runner receives as `TEST_RUNNER_TEXTMOUTH_REAL_SPEECH_EXPORT=1`, so it is skipped in an ordinary run.
- The synthesizer sits behind `SpeechBufferWriting`, so `SpeechBufferSynthesizerTests` scripts it: a refusal, the stall limits, Stop, and the Personal Voice check, with no voice speaking.
- The tests of the sheet that host it (`testTheSheetDrawsTheOptionsWhileCheckedAndDisablesThemWhileExporting`, `testTheSheetWithTheOptionsFits`) were never run against a deliberate break; only a train shows they pass.
  No test reads the MP3 line, "Reading the book's headings…", or the unreadable-text line from the drawn sheet.
- The shared helper `debugLogLines(writtenWhile:)` (ConfigTestSupport.swift) reads the bytes the debug log gained while an export ran, since a log line's time is to the second only and an older line could look the same.

## Rich text follow-up tests
<!-- id: rich-text-follow-up-tests; keys: tracked changes, cancel import, list number, undo plain; src: TextMouthProductionTests/RTFTrackedChangesTests.swift, TextMouthProductionTests/RTFNotesTests.swift, TextMouthProductionTests/RTFTableListTests.swift, TextMouthProductionTests/OwnReaderCancellationTests.swift, TextMouth/Services/ArchiveExtraction.swift -->

`RTFTrackedChangesTests`, `RTFNotesTests`, and `RTFTableListTests` pin the rich text follow-ups (a deletion left out and `\plain` undoing it, notes after the body and only those whose reference is read, a list item's number in a table cell).
`OwnReaderCancellationTests` pins the shared cancellation check, `ImportCancellation.throwIfCancelled()`, in the rich text, DOCX, OpenDocument, Word 2003 XML, and MOBI readers: it ends a read when an import is cancelled and does nothing outside an import.

## OpenDocument and Word 2003 XML readers
<!-- id: opendocument-word-2003-xml-readers; keys: ODF, XML bomb, entity expansion, OfficeXMLReader, sync-info-plist, Info.plist; src: TextMouthProductionTests/ODTReaderTests.swift, TextMouthProductionTests/WordMLReaderTests.swift, TextMouthProductionTests/ODTHostileReaderTests.swift, TextMouthProductionTests/OfficeXMLGuardTests.swift, TextMouthProductionTests/XMLInputGuardTests.swift, TextMouthProductionTests/ODTTextutilComparisonTests.swift, TextMouthProductionTests/DOCXHiddenTextTests.swift, TextMouthProductionTests/DOCXPictureAttributeTests.swift, TextMouthProductionTests/MarkdownPageMarkerTests.swift, TextMouthProductionTests/IOSInfoPlistTests.swift, TextMouth/Parsers/XMLInputGuard.swift, Scripts/ios/sync-info-plist.py -->

The OpenDocument and Word 2003 XML readers have `ODTReaderTests`, `WordMLReaderTests`, `ODTHostileReaderTests`, and `OfficeXMLGuardTests`.
`OfficeXMLGuardTests` tests the shared XML base: escaping and name scopes are linear in their input, a document type is found in every encoding, a tag of more than 1,024 attributes is refused and one with a very long attribute is not.
`XMLInputGuardTests` pins the guard on tags of 1,024 and 1,025 attributes, hostile shapes refused within 10 ms (an attribute flood, a subset, an encoding spelled with an alias or with a newline around the =), the encodings allowed, and the sentences.
See [Shared helpers: readers and markup guards](../architecture/shared-helpers-parsers.md) for the guard.
The readers that ask it (the feed, OPML, SMIL, PEF, and ODT manifest reads) have a test of their own that the guard is asked.

- `DOCXHiddenTextTests` pins the hiding rule's levels (the 243 combinations of the five levels were also compared, once, with a table built from the clauses of MS-OI29500 by a separate script),
- `DOCXPictureAttributeTests` the strip of `o:gfxdata`, and
- `MarkdownPageMarkerTests` that 20,000 page markers written in one paragraph take linear time, by a limit checked as it goes.

`make check-ios-plist` and `IOSInfoPlistTests` check the iOS plist (see [Make targets](building.md#make-targets)).
`ODTTextutilComparisonTests` reads the 15 real files with the reader and with textutil, and requires the same words, textutil's headings, and at least textutil's pages, except for named differences:

- the note bodies and text boxes the reader reads and textutil drops,
- the footnote marks textutil runs into words,
- the hidden sections textutil reads, and,
- in three files, the first and last words of the counted differences are pinned.

`WordMLReaderTests` has no real Word 2003 XML sample: the two samples were written by textutil, and the reader was written from the format and checked on a hand-made document that covers every rule.
A real sample was not added because the one candidate is over the size preference and has no licence file.

## Import speed-up tests
<!-- id: import-speed-up-tests; keys: ByteSearchTests, PlainTextLinesTests, differential test, random texts, reference expression, import area; src: TextMouthProductionTests/ByteSearchTests.swift, TextMouthProductionTests/ImportSpeedUpPinTests.swift, TextMouthProductionTests/PlainTextLinesTests.swift, TextMouthProductionTests/RTFSizeHeadingsTests.swift, TextMouthProductionTests/EPUBBlankChapterTests.swift, TextMouthProductionTests/EPUBXMLIndexTests.swift, TextMouthProductionTests/PublicationSemanticsTypeNamesTests.swift, Scripts/test/areas.conf -->

Each import speed-up keeps the expression it replaced as a reference, and its tests hold the two to the same answer on named edge cases and on thousands of random inputs; the goldens (`DocumentGoldenTests`, `TextPipelineGoldenTests`) hold the books' output.
The classes, each placed in an area of `Scripts/test/areas.conf`:
- `ByteSearchTests`: the `memchr` search, `splitAtLineFeeds()`, and `String.forEachCharacter(_:)` against `utf8.contains`, `split`, and the Character walk;
- `ImportSpeedUpPinTests`: the prefix strip at the last colon and the line endings;
- `PlainTextLinesTests`: every edge of the line split by name, and 20,000 random texts;
- `RTFSizeHeadingsTests`: the 120 and 121 character boundary, kinds of white space, CJK, emoji, accents, and bold, against the old expressions;
- `EPUBBlankChapterTests`: named and long chapters, and 20,000 random texts against the old regular expression;
- `EPUBXMLIndexTests`: the index against the old XPath on 1,000 random packages, the container, an NCX, and a 2,000-deep document;
- `PublicationSemanticsTypeNamesTests`: the type names against the full attribute search.

Harnesses that mirror the tests, run on a copy with a deliberate fault (an off-by-one length, a missing last line, a wrong white space set), showed that the byte searches, line split, prefix strip, blank test, index, and white space set fail them.
The type names and the portable tree were checked by reading only.


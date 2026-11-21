# Imports: documents textutil reads
<!-- id: imports-documents-textutil-reads; keys: textutil, RTF, Word 97-2003, wordml, webarchive, SSML, DTBook, .doc; src:  -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## Documents textutil reads, web archives, SSML, DTBooks
<!-- id: documents-textutil-reads-web-archives; keys: .doc, .rtf, .odt, .webarchive, .ssml, DTBook, Word 97-2003, Document import; src: TextMouth/Parsers/TextutilDocumentReader.swift, TextMouth/Services/TextutilConverter.swift, TextMouth/Parsers/OwnDocumentReaders.swift, TextMouth/Platform/iOS/IOSUnavailable.swift, TextMouth/Parsers/BookParser.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouth/Models/TextCacheFingerprint.swift -->

Documents that textutil reads, web archives, SSML files, and DTBooks (FMT13, FMT01, FMT03, FMT07, FMT04): text books that become Markdown, are indexed, and are fingerprinted as a Word document is.
Since 0.4.1 textutil reads only a compound-file Word document older than Word 6, and only on the Mac.
The formats rtf, rtfd, odt, wordml, and every doc from Word 6 on go to the own readers ([Imports: rich text and Word documents](imports-rtf-and-word.md)).
iOS, which starts no child process, reads none with textutil (a run throws IOSUnavailable).

### The formats
<!-- id: textutil-formats; keys: BookFormat, detect(from:), .xml sniffer, Word template, .dotx, .docm, document types, PEF; src: TextMouth/Models/Book.swift, TextMouth/Parsers/DOCXParser.swift, TextMouth/Parsers/XMLDocumentSniffer.swift, TextMouth/Services/FileImportService.swift, TextMouth/Resources/Info.plist -->

The formats: BookFormat gained rtf, rtfd, doc, odt, wordml, webarchive, and ssml.
Their raw values are written into library.json and bookInfo.json and never changed, and a build that does not know one cannot decode the index (Index-write suspension, in [The library index](library-index.md)).
A build with V03 keeps such a row as it was read (Rows this TextMouth cannot read, there).
A Word template or macro document (.dotx, .docm, .dotm) is a docx, which DOCXParser reads by opening only the XML parts it needs, so word/vbaProject.bin is never opened; a .dot is a doc, an .ott an odt, and a DTBook a daisy.
BookFormat.detect(from:) names an .xml file by XMLDocumentSniffer.bookFormat(ofFileAt:), which parses the first 64 KB (scanLength) only as far as the root element:
- dtbook, in any namespace, gives daisy;
- wordDocument in Word 2003's namespace gives wordml;
- pef in PEF 2008-1's namespace gives braille (FMT20);
- anything else gives nil.

FileImportService.supportedTypes offers the matching types in Open Book, and Info.plist makes each a document type at Alternate rank (org.w3.ssml is imported there).

### The path through textutil
<!-- id: path-through-textutil; keys: textutil pipeline, HTML to Markdown, encrypted Word, password protected, page breaks, field codes, heading guess, Word 6; src: TextMouth/Parsers/TextutilDocumentReader.swift, TextMouth/Parsers/TextutilSourceCheck.swift, TextMouth/Services/TextutilConverter.swift, TextMouth/Parsers/TextutilHTMLStructure.swift, TextMouth/Parsers/TextutilFieldCodes.swift, TextMouth/Parsers/TextutilPageBreaks.swift, TextMouth/Parsers/HTMLToMarkdownConverter.swift, TextMouth/Parsers/OwnDocumentReaders.swift, TextMouth/Parsers/WordDocumentStructure.swift, TextMouth/Parsers/XMLDocumentSniffer.swift, TextMouth/Parsers/DocumentByteLimit.swift, TextMouth/Platform/macOS/Services/WatchedProcess.swift, TextMouth/Parsers/BookParser.swift, TextMouth/Services/MarkdownCacheService.swift -->

The path of the five formats (rtf, rtfd, doc, odt, and wordml) runs through TextutilDocumentReader, whose parse(url:bookFormat:) serves BookParser and whose extract(from:bookFormat:) serves MarkdownCacheService.extractCache.
After step 1, htmlText(of:bookFormat:includesPages:) asks OwnDocumentReaders for the HTML (Own readers of rich text and Word documents, in [Imports: rich text and Word documents](imports-rtf-and-word.md)).
Steps 2 and 3 are textutil's, and run only when it answers nil, which is for a compound-file Word document older than Word 6 alone (WordFileInformationBlock.read answers nil for an nFib under 0x0065):

1. TextutilSourceCheck, through reading(of:bookFormat:): the file's first bytes decide how it is read, in this order.
   An .rtfd is read as one.
   A file that begins with {\rtf is rtf, whatever its name (beginsAsRTF).
   A file that begins as an HTML page goes to TextMouth's own HTML reader and never to textutil (beginsAsHTML).
   An XML file with Word 2003's root is wordml (XMLDocumentSniffer).
   Any other file is read as its book's format.
   A Word 97-2003 document whose File Information Block says it is encrypted (isEncryptedWordDocument), and an OpenDocument package whose META-INF/manifest.xml holds an encryption-data element (isEncryptedOpenDocument), throw PasswordProtectedDocument.
2. TextutilConverter.html(of:as:workingIn:using:) sizes the document (documentSize(of:), which for an RTFD sums its regular files and follows no link inside it), checks DocumentByteLimit, and runs /usr/bin/textutil under WatchedProcess.
   The arguments are -convert html -noload -nostore, -format and the format's name, -encoding UTF-8, and -output.
   Its limits(forBytes:) gives it 30 seconds and 1 more for each million bytes, 1 GiB, and the default processor-time allowance of four times the time.
   Since textutil exits 0 and writes nothing for a file it cannot read, a missing output is unreadable (TextutilConverter.Failure.unreadable).
   A kill is Failure.stopped, worded by KillReason.words.
   The HTML it wrote is held to the byte limit too.
3. TextutilHTMLStructure.restore(in:beforeFieldRemoval:):
   - removes pictures,
   - counts the body's characters by size and weight,
   - runs its closure (TextutilPageBreaks.insertPageBreaks puts the page breaks of textutil's plain text into the HTML there),
   - removes Word field instructions (TextutilFieldCodes, which keeps a block that holds a page break),
   - turns tab-bullet-tab paragraphs into lists, and
   - turns each paragraph of at most 120 characters that lies outside lists and tables into h1 to h6, by the rank of its size when it is larger than the body, and, when the body is not mostly bold, by being bold throughout at the body's size, after the larger sizes.

   The page breaks go in before the instructions are removed because textutil writes a field's instruction as bare text into both its HTML and its plain text, so the two agree until the instructions go.
   Lined up after that, every page after the first field would be dropped as unaligned (ST10).
4. HTMLToMarkdownConverter writes the Markdown.

### Names
<!-- id: textutil-names; keys: title and author, document metadata, Author meta, launch refresh, hand-edited title, file name as title, Extraction; src: TextMouth/Parsers/TextutilDocumentReader.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouth/Services/FileImportService.swift -->

Names: one run makes the Markdown and the title and author (TextutilDocumentReader.Extraction: the title element and the Author meta of textutil's HTML head, with white space collapsed and the control characters that textutil writes for some Word documents removed).
MarkdownCacheService.extractCache returns them, and importFileWithReport adopts them (adoptingDocumentNames, through publishReadableBook and readableContent); a regeneration never does, since the book's title and author may have been edited by hand.
Until then ImportedFileMetadata.read(readingTextutilNames: false) lists the book by its file's name; the launch refresh reads with the default, true, which costs a run of textutil for a Word document older than Word 6 and a read by the own reader for every other.

### Where textutil writes
<!-- id: where-textutil-writes; keys: temporary output, hidden html file, working folder, staged package, failed import leftovers; src: TextMouth/Services/TextutilConverter.swift, TextMouth/Services/ImportStaging.swift, TextMouth/Parsers/TextutilDocumentReader.swift -->

Where textutil writes: withWorkingFolder(for:) puts the hidden `.<UUID>.textutil.html` (TextutilConverter.temporarySuffix) in the staged package when the book's file is in one (ImportStaging.isStagedPackageName), so the output goes with the package should the import fail or be cancelled.
Otherwise it puts it in a new `TextMouth-textutil-<UUID>` folder in TextutilDocumentReader.temporaryRoot (the temporary directory), removed afterwards.
No library package and no folder of an imported file ever receives one.

### Cancel
<!-- id: textutil-cancel; keys: Cancel button, cancel import, kill child process, ZIP batch, no alert, cancellation checks, Redo Text Extraction; src: TextMouth/Services/ArchiveExtraction.swift, TextMouth/Services/AsyncBridge.swift, TextMouth/Services/TextutilConverter.swift, TextMouth/Services/ImportFailure.swift, TextMouth/ViewModels/LibraryViewModel+Import.swift, TextMouth/Parsers/TextutilDocumentReader.swift, TextMouth/Parsers/RTFInterpreter.swift, TextMouth/Parsers/DOCXParser.swift, TextMouth/Parsers/OfficeXMLReader.swift, TextMouth/Parsers/MOBIParser.swift, TextMouth/Parsers/KFXWalk.swift, TextMouth/Parsers/WordDocumentReader.swift, TextMouth/Parsers/WordDocumentProperties.swift, TextMouth/Parsers/DOCXParser+Converter.swift -->

Cancel: SerialImportQueue.enqueue binds the queue's cancellation as ImportCancellation.current around each import.
TextutilConverter.html reads it on the import's thread and waits through AsyncBridge.waitForResult(cancelledBy:), which cancels the detached task, and so kills the child, when ImportCancellation.cancel() runs the handlers that whileRunning(_:then:) registered.
The import throws ImportCancelled, which ImportRun.perform passes on after an IMPORT_CANCELLED line, presentImportError ignores, so there is no alert, and a ZIP batch turns into a cancelled result (.afterBooks) with that book left out.
A conversion outside an import (the reader, startup maintenance, Redo Text Extraction) finds no current cancellation, and no import's Cancel stops it.
An own reader starts no child, so Cancel reaches it only through ImportCancellation.throwIfCancelled() (Services/ArchiveExtraction.swift), which throws ImportCancelled as a cancelled textutil conversion ends, and does nothing outside an import.
The readers that ask it:

- RTF (before the read and every RTFInterpreter.tokensBetweenCancellationChecks, 4,096 tokens),
- DOCX (before each part and every 1,024 elements, ending the parse with abortParsing),
- OfficeXMLReader.stopIfCancelled() for the OpenDocument and Word 2003 XML readers (at every start tag and every run of text),
- the Word 97-2003 reader (WordDocumentReader, at the start, between the pages of formatting, and every 4,096 characters written; WordDocumentProperties between pages of runs),
- MOBIParser (before each section),
- KFXWalk (with its counter of work), and
- TextutilDocumentReader between the steps after a document's own reading.

### Web archives, SSML, and DTBooks
<!-- id: web-archives-ssml-dtbooks; keys: .webarchive, Safari web archive, .ssml, speech markup, DTBook, DAISY XML, dtbook.xml, text encoding; src: TextMouth/Parsers/WebArchiveReader.swift, TextMouth/Parsers/SSMLReader.swift, TextMouth/Parsers/DAISYParser.swift, TextMouth/Parsers/DAISYParser+DTBookHeadParser.swift, TextMouth/Parsers/XMLDocumentSniffer.swift, TextMouth/Parsers/BookParser.swift, TextMouth/Parsers/TextFileDecoder.swift -->

Web archives, SSML, and DTBooks: WebArchiveReader.mainPage(of:) reads the property list's WebMainResource alone (WebResourceData, WebResourceMIMEType, WebResourceTextEncodingName).
A type of text/html, application/xhtml+xml, or none is a page for the HTML path, text/plain a text page for the plain-text path (MainPage.parsed(title:) and markdown(), in BookParser.swift), and any other type throws Failure.notAPage.
WebSubresources, WebSubframeArchives, and every address are never read, and WebKit is not used.
The archive's encoding name wins when the bytes read in it, ISO Latin 1 and ASCII as Windows-1252, by the one rule TextFileDecoder.decodedText(_:in:) gives every labelled encoding.
SSMLReader.html(from:) is a PackageSAXParser that
- wants the root speak,
- writes a paragraph for each p or paragraph,
- keeps words apart at break, voice, audio, s, and sentence,
- writes emphasis as em,
- speaks a sub's alias in place of its text,
- drops desc, meta, metadata, and lexicon, and
- never reads an audio's src.

The file is never handed to the speech engine as SSML, since AVSpeechUtterance(ssmlRepresentation:) ignores the book's rate and crashed on an emphasis element.
- A DTBook on its own goes to DAISYParser through SingleFileProvider, which lists that file alone, held to the byte limit;
- DAISYDTBookHeadParser takes its title and author (the dc:Title and dc:Creator metas, else doctitle and docauthor) when no OPF is there; and
- findDTBookXML finds a DTBook inside a package by the same sniffer, whatever its encoding, prolog, or name.

### The byte limit
<!-- id: textutil-byte-limit; keys: 64 MB, size limit, too large, empty file, symbolic link, text file limit, No Text to Read; src: TextMouth/Parsers/DocumentByteLimit.swift, TextMouth/Parsers/ArchiveEntryReader.swift, TextMouth/Services/TextutilConverter.swift, TextMouth/Parsers/WebArchiveReader.swift, TextMouth/Parsers/SSMLReader.swift, TextMouth/Parsers/TextutilDocumentReader.swift, TextMouth/Parsers/DAISYParser.swift -->

The byte limit: DocumentByteLimit is 64 MB (ArchiveEntryLimits.standard.text, narrowed by tests through its task-local current).
TextutilConverter holds the source and the HTML to it, and DocumentByteLimit.contents(of:) serves WebArchiveReader, SSMLReader, the web-page branch of TextutilDocumentReader, and SingleFileProvider:
- a symbolic link is sized by its target,
- an empty file is FileImportError.noTextToRead, and
- DocumentTooLargeError names the limit.

### An RTFD is a folder
<!-- id: rtfd-folder; keys: .rtfd, RTFD bundle, content checksum, attachment, original kept, keep original, DAISY ZIP with audio, duplicate check; src: TextMouth/Services/FileImportService.swift, TextMouth/Services/FileImportService+Packages.swift, TextMouth/Models/TextCacheFingerprint.swift, TextMouth/Models/ImportDecision.swift, TextMouth/ViewModels/LibraryViewModel+Import.swift -->

An RTFD is the one text book whose file is a folder.
The test isRTFDFolder(_:) names it.
Its checksum is contentChecksum(of:format:), the MD5 of its regular files' sorted relative paths and their MD5s (regularFilePaths(in:) passes over hidden items and symbolic links).
FileStamp(of:) and FingerprintHasher.md5 use the same walk, so a text cache's fingerprints notice a changed attachment (see [Text caches and content indexes](text-caches.md)).
- The package checks (inspectContent, holdsSameContent, reconstructedBook, and contentHash(of:bookID:)) treat it as a document, not a folder of tracks;
- stageContent(of:format:package:in:) copies a text document that is a symbolic link as its target and removes every link inside a staged RTFD;
- importCandidates lists an .rtfd folder in a ZIP as one book; and
- md5Hash(of:) refuses a folder rather than crash.

ImportedBook.isFromFolder is set, so mayDeleteOriginal is false, and when importDeleteBehavior is not keepOriginal, importWarning(for:) tells the reader ImportedBook.originalKeptNotice once, which also keeps the book from opening after the import.
ImportedBook.tookOnlyPartOfOriginal, set by importDAISYAudioZipWithReport, is the other cause mayDeleteOriginal honors: a ZIP's DAISY book with audio imports as its audio alone.
The archive is scanned without extracting anything (DAISYArchiveLeftovers), so that the original is kept only when something is left, and the notice is DAISYArchiveWording.originalKept(bookTitle:leftovers:).
DAISYArchiveLeftovers has holdsText, for a DTBook or a text document a SMIL file names other than the navigation file, and otherBookCount, for books outside the DAISY folder.

### Refusals
<!-- id: textutil-refusals; keys: blank document, empty document, No Text to Read, unsupported XML, FileImportError, checkingFormat, docx blank; src: TextMouth/Services/FileImportService.swift, TextMouth/Parsers/XMLDocumentSniffer.swift -->

Refusals: formatsRefusedWhenBlank (rtf, rtfd, doc, docx, odt, wordml, braille, webarchive, ssml, and the plain three) and refusesBlankText(_:) make readableContent throw noTextToRead.
The format docx, which also covers .dotx, .docm, and .dotm, is in formatsRefusedWhenBlank since a Word document of only empty paragraphs converts without error.
The test refusesBlankText(_:) holds for those, and for a daisy book whose file is an .xml, a DTBook on its own.
A DAISY package whose DTBook holds no words still imports.
An .xml file that no format claims throws FileImportError.unsupportedXML, or noTextToRead when XMLDocumentSniffer.holdsNoText(fileAt:) finds it empty or blank, both at the checkingFormat step, before anything is copied.

### Logs and the sweep
<!-- id: textutil-logs-sweep; keys: textutil leftovers, orphan sweep, storage log, hidden .textutil.html, reaper, launch cleanup, log events; src: TextMouth/Services/TextutilConverter.swift, TextMouth/Platform/macOS/Services/OrphanedConversionSweep+Textutil.swift, TextMouth/Platform/macOS/Services/WatchedProcess.swift, TextMouth/Platform/macOS/App/AppDelegate.swift -->

Logs and the sweep: TextutilConverter writes TEXTUTIL_KILLED (the watchdog's reason) and TEXTUTIL_FAILED (wrote nothing, exited with status N, or could not start) as import events.
OrphanedConversionSweep+Textutil, run by applicationDidFinishLaunching through sweepTextutilInBackground() and never in a hosted test, kills with SIGKILL each /usr/bin/textutil that:

- is run by the current user,
- is an orphan (parent pid 1), and
- has a -output argument, read before the --, naming a hidden `.<name>.textutil.html` (shouldKillTextutil).

It also removes each real `TextMouth-textutil-<UUID>` folder in the temporary directory that is over an hour old (sweepTextutilFolders).
It logs one TEXTUTIL_LEFTOVERS_SWEPT line, in the storage category, when it did either.
WatchedProcess's reaper and terminateAll() end a running textutil with TextMouth, as they end afconvert.

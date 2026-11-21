# Imports: Kindle books
<!-- id: imports-kindle-books; keys: Kindle, Amazon, AZW, KFX, MOBI, KF8, e-book, DRM; src: -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## Kindle KFX books
<!-- id: kindle-kfx-books; keys: Amazon Kindle, Amazon Ion, DRM, Kindle Previewer, print replica, comic, KPF, calibre; src: TextMouth/Parsers/KFXParser.swift, TextMouth/Parsers/KFXSignature.swift, TextMouth/Parsers/KFXPackage.swift, TextMouth/Parsers/KFXSidecar.swift, TextMouth/Parsers/KFXContainer.swift, TextMouth/Parsers/KFXView.swift, TextMouth/Parsers/KFXIon.swift, TextMouth/Parsers/KFXSymbol.swift, TextMouth/Parsers/KFXSymbols.swift, TextMouth/Parsers/KFXFragments.swift, TextMouth/Parsers/KFXMetadata.swift, TextMouth/Parsers/KFXNavigation.swift, TextMouth/Parsers/KFXTargets.swift, TextMouth/Parsers/KFXBook.swift, TextMouth/Parsers/KFXWalk.swift, TextMouth/Parsers/KFXInlineText.swift, TextMouth/Parsers/KFXStyles.swift, TextMouth/Parsers/KFXError.swift, TextMouth/Parsers/MOBIParser.swift, TextMouth/Parsers/MOBIError.swift, TextMouth/Parsers/BookParser.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouth/Services/FileImportService.swift, TextMouth/Models/Book.swift, TextMouth/Models/Library.swift, TextMouth/Models/PageReaderVersions.swift, TextMouth/Resources/Info.plist, TextMouth/Services/ArchiveExtraction.swift -->

Kindle KFX books (FMT52): DRM-free KFX books, read by TextMouth's own reader, the same in both apps, with no helper process.

- The format: BookFormat.kfx (raw value "kfx", displayName "Kindle Book (KFX)", extensions kfx, kfx-zip, azw8, and kpf, the last taken only to be refused) is written into library.json and bookInfo.json and never changed.
  A build from 0.2.1 on keeps a library that holds one and leaves that book out (UnreadableLibraryRow, V03); an older build cannot decode the index.
  Info.plist makes it a document type at Alternate rank and imports the type com.textmouth.kfx.
  Its page reader line is "1.0.0" (PageReaderVersions.current(for: .kfx)), a case of its own, so only KFX books are read again for pages.
  An .azw file holding KFX bytes is a BookFormat.mobi book that MOBIParser hands to KFXParser by its bytes, and it is read without pages.
- Recognizing: KFXSignature decides by the first bytes, never the name:
  - CONT is a KFX container,
  - DRMION is a copy-protected container (refused, never opened: MOBIError.copyProtected), and
  - PK is a ZIP that KFXPackage looks at by member names and first bytes only (a .kfx-zip set, or a .kpf with a .kdf database, which is KFXError.kindleCreatePackage).

  KFXSidecar looks beside the book for a Book.sdr folder and a Book.voucher (a voucher or a protected member anywhere is copyProtected), following no symbolic link, visiting at most 200 names, going no deeper than 3 levels, and reading at most 16 containers.
  A sidecar's fragments never override the main file's.
  FileImportService refuses a protected book at import before its size is asked.
  A nonzero compression or DRM field in a container is refused (the format notes find both 0 in every readable file); a nonzero compression is MOBI's "compressed in a way TextMouth can't read yet".
### Reading a KFX book
<!-- id: reading-kfx-book; keys: KFXContainer, Ion, KFXSymbols, KFXMetadata, KFXWalk, noFlowingText, partOfABook, refusals; src: TextMouth/Parsers/KFXContainer.swift, TextMouth/Parsers/KFXView.swift, TextMouth/Parsers/KFXIon.swift, TextMouth/Parsers/KFXSymbols.swift, TextMouth/Parsers/KFXFragments.swift, TextMouth/Parsers/KFXMetadata.swift, TextMouth/Parsers/KFXNavigation.swift, TextMouth/Parsers/KFXTargets.swift, TextMouth/Parsers/KFXWalk.swift, TextMouth/Parsers/KFXInlineText.swift, TextMouth/Parsers/KFXStyles.swift, TextMouth/Parsers/KFXError.swift, TextMouth/Parsers/MOBIParser.swift, TextMouth/Parsers/MOBIError.swift -->

- Reading: KFXContainer opens a container with every offset and length checked through KFXView, which throws MOBIError.damaged on any field that points outside the data.
  KFXIon reads binary Ion from the public specification, with an explicit stack and a budget of values, never recursion.
  KFXSymbols knows the shared table by number and the container's local symbols, which start after the import's max_id (860 when max_id is 859).
  KFXFragments indexes the fragments of all a book's containers by type and name.
  KFXMetadata reads the title, author (a book made by Kindle Previewer spells every name "Last, First", which is flipped back for that tool alone), and language.
  It also reads the capability marks that say a book has no flowing text (fixed layout, textbook, publisher panels, facing page, double-page spread, text popups, dictionary, a magazine's content type, a comic's panel mode, a notebook).
  They throw KFXError.noFlowingText, as does a book whose every section is fixed layout or only pictures.
  KFXError.partOfABook is a container with no sections, storylines, or document data.
- KFXNavigation reads the table of contents, the print page list (a list named APPROXIMATE_PAGE_LIST is a machine's and is passed over), and the heading levels the headings container gives (levels 1 to 6), at most 200,000 units.
  KFXTargets turns each into an anchor at a node and an offset in code points.
  KFXWalk walks each section of the reading order with its own stack and one counter of work against one limit, and writes HTML:
  - paragraphs,
  - headings,
  - emphasis (KFXStyles: bold by weight, italic, and a heading hint),
  - links,
  - lists,
  - tables (a caption, thead, tbody, and cells that hold text blocks), and
  - a picture's alt text.

  KFXInlineText writes one text block's string, cutting it at every run boundary so overlapping runs nest, and the HTML of inline nodes (pictures, math, floated spans).
  A footnote's body is a node at the end of its chapter.
  Sections the producer left uncut are joined when the producer writes the auxiliary fragments that mark the cuts.
  The sections end in MOBIParser.preparedBook, the same function a MOBI book ends in, so the chapters, headings, and Markdown are made the same way.
- The refusals:
  - protected (MOBIError.copyProtected: "This Kindle book is copy-protected, and TextMouth can't read copy-protected books."),
  - damaged or not a Kindle book (MOBIError, the MOBI sentences),
  - no flowing text (KFXError.noFlowingText: "This Kindle book has no flowing text to read, such as a comic or a print replica, so TextMouth can't read it."),
  - a Kindle Create package (KFXError.kindleCreatePackage: "This file is a Kindle Create package, which TextMouth can't read yet."), and
  - a partial container (KFXError.partOfABook: "This file holds only part of a Kindle book.
  Open the book's main .kfx file.").
- Cancellation: KFXWalk asks ImportCancellation.throwIfCancelled() as it works.
  The sample books and their tests are in [Tests of the markup guard, Kindle, and MOBI readers](../../developer/testing-formats.md).

## Kindle MOBI 6 and KF8 books
<!-- id: kindle-mobi-6-kf8-books; keys: Mobipocket, AZW3, PRC, PalmDOC, Amazon Kindle, kindlegen, e-book, DRM; src: TextMouth/Parsers/MOBIParser.swift, TextMouth/Parsers/MOBIBook.swift, TextMouth/Parsers/BookParser.swift -->

Kindle books (FMT42): DRM-free MOBI 6 books, read by TextMouth's own reader, the same in both apps, with no helper process and no textutil.

### The format
<!-- id: mobi-format; keys: BookFormat, UTType, UTI, Open Book, Mobipocket, file extension, page reader version, version stamp; src: TextMouth/Models/Book.swift, TextMouth/Models/Library.swift, TextMouth/Services/FileImportService.swift, TextMouth/Services/TextutilConverter.swift, TextMouth/Models/PageReaderVersions.swift, TextMouth/Resources/Info.plist -->

The format: BookFormat.mobi (raw value "mobi", displayName "Kindle Book (MOBI)", extensions mobi, prc, azw, and azw3) is written into library.json and bookInfo.json and never changed.
A build from 0.2.1 on keeps a library that holds one and leaves that book out (UnreadableLibraryRow, V03); an older build cannot decode the index.
Info.plist makes it a document type at Alternate rank and imports the type com.textmouth.mobi (public.data, with the MIME types application/x-mobipocket-ebook and application/vnd.amazon.ebook), which FileImportService.supportedTypes offers in Open Book.
TextutilInputFormat has no case for it, so it never reaches textutil, and its page reader line is "1.1.0" (PageReaderVersions.current(for: .mobi)): "1.0.0" came with 0.4.2, for the KF8 reader below, and "1.1.0" with 0.4.3, for the chapter rules and the soft hyphens below.
The first launch of each reads every .mobi book (.azw3, .azw, and .prc included) again once.
Before 0.4.2 it had no page reader.

### Reading a MOBI 6 book
<!-- id: reading-mobi-6-book; keys: Mobipocket, Palm OS, Huffman, decompression, encryption, table of contents, chapters, TEXtREAd; src: TextMouth/Parsers/MOBIParser.swift, TextMouth/Parsers/MOBIBook.swift, TextMouth/Parsers/MOBIPalmDatabase.swift, TextMouth/Parsers/MOBIHeaders.swift, TextMouth/Parsers/MOBIText.swift, TextMouth/Parsers/MOBIHuffman.swift, TextMouth/Parsers/MOBIIndex.swift, TextMouth/Parsers/MOBIMarkup.swift, TextMouth/Parsers/MOBIError.swift, TextMouth/Parsers/BookParser.swift, TextMouth/Parsers/DocumentByteLimit.swift, TextMouth/Parsers/MarkupGuard.swift, TextMouth/Parsers/HTMLToMarkdownConverter.swift, TextMouth/Parsers/MarkdownParser.swift, TextMouth/Parsers/ParserUtilities.swift, TextMouth/Services/MarkdownCacheService.swift, Vendor/SwiftSoup/README.md, TextMouthProductionTests/SwiftSoupCorpusTests.swift -->

Reading: BookParser and MarkdownCacheService.extractFromKindle call MOBIParser, which reads the file's bytes, held to DocumentByteLimit, into a MOBIBook:

1. MOBIPalmDatabase reads the Palm database's header and record list; its type and creator must be BOOKMOBI or TEXtREAd (else MOBIError.notAKindleBook).
   Every read of the file goes through MOBIView, which checks an offset and a length against the data without adding values the file gives, so no field read from it can overflow or reach past its end.
2. MOBIHeaders reads record 0: the PalmDOC header (compression, text length, text record count, record size, and encryption) and, in a BOOKMOBI book, the MOBI header (its length, encoding, version, Huffman records, EXTH flag, DRM offset, extra-data flags, and NCX index record) and its EXTH records.
   A field past the end of a shorter, older header reads as absent.
3. MOBIBook.refuseProtected refuses an encryption field that is not 0 or a DRM offset that is not 0xFFFFFFFF (copyProtected, before any text record is read; nothing removes protection), in the book's first half and in the KF8 half of a hybrid, whichever is read.
   Then MOBIText refuses a compression other than none, PalmDOC, and HUFF/CDIC (unsupportedCompression).
4. MOBIText joins the text records.
   It takes each record's trailing entries (by the extra-data flags) and multibyte overlap off its end, decompresses it with PalmDOC's LZ77, whose back-references may not reach before the record's own output, or with MOBIHuffman (HUFF/CDIC).
   A text that decompresses past the length the header declares is cut there, as two real dictionaries need, and one that comes up short throws damaged, as a broken download would.
   The records' bytes are joined before they are decoded, as UTF-8 (encoding 65001) or Windows-1252, so no character is split.
   A TEXtREAd book, which has no MOBI header, is one section of plain text, unless MOBIMarkup.looksLikeHTML finds an html or body tag in its first 4,096 bytes, as in an early Mobipocket book: such a text goes through the markup path below.
5. MOBIIndex reads the NCX index (the INDX, TAGX, IDXT, and CNCX records) into entries of offset, label, and depth.
   MOBIMarkup scans the text for filepos targets (none inside a comment, a declaration, or a quoted attribute) and mbp:pagebreak tags, puts an anchor, filepos-N, at each target, takes the Mobipocket tags out, and cuts the text into sections:
   - one for each top-level entry, with the words before the first entry a section of their own, or,
   - with no index, one for each page break.
   No section begins before Scan.bodyStart, the first body tag, else the end of the head, else the text's start, so the head (an OEB metadata block, a guide) is never read: SwiftSoup would move a head element it doesn't know into the body.
   A deeper entry is a heading annotation (level depth + 1, at most 6) at its anchor.
   MOBIMarkup checks no nesting of its own.
   A section's markup reaches SwiftSoup only through MarkupGuard, in HTMLToMarkdownConverter.convert.
   The guard refuses markup nested more than 128 levels deep, with too many tags, too many attributes on one tag, or too much work, by throwing MarkupRefusal before SwiftSoup builds anything.
   See [Shared helpers: readers and markup guards](../shared-helpers-parsers.md) and, for the sentences, [Import progress and errors](../../user/import-progress-and-errors.md).
   A section that opens as XML goes to SwiftSoup's XML parser, and a broken declaration in it is rewritten as an empty comment.
   SwiftSoup is the vendored copy in Vendor/SwiftSoup, not a Swift package, and builds the same trees as the package did (SwiftSoupCorpusTests).
6. Each section's HTML goes to HTMLToMarkdownConverter with its heading targets, and MarkdownDocParser makes it a chapter.
   A chapter with no heading at its start gets a heading annotation, which is never read aloud, of its entry's title, or "Chapter N", N counting the chapters that hold text.
7. Soft hyphens (0.4.3): the section's markup, the NCX entries' labels, and the plain text of a TEXtREAd book go through ParserUtilities.removingSoftHyphens (MOBIBook), as KF8's already did, so a MOBI 6 book no longer has the U+00AD that a publisher put inside words.
   The plain text is escaped first and cleaned after, so an author's own "&shy;" in a plain book stays as the five characters.
   The effects are in Shared helpers.

### KF8 books and hybrids
<!-- id: kf8-books-hybrids; keys: combo file, dual format, kindlegen, AZW3, fallback, upgrade, MOBI 6 half, KF8 half; src: TextMouth/Parsers/MOBIBook.swift, TextMouth/Services/MarkdownCacheService.swift -->

KF8 (FMT48): MOBIBook also reads a KF8 book (an .azw3, or a KF8 file named .mobi or .azw; the MOBI header's version, 8 or more, decides, never the name).
It is read by TextMouth's own code, written from the format's published description with foliate-js's mobi.js as a map (see [Third-party code](../../developer/third-party-code.md)), with no helper process.

1. Hybrids: a file that holds a MOBI 6 book first and the same book in KF8 after the boundary EXTH 121 names (MOBIBook.secondHalf) is read from its KF8 half (MOBIBook.hybridChoice is .kf8).
   A boundary that names no KF8 header leaves the file the MOBI 6 book it opens as.
   Protection is looked at in both halves (copyProtected), whichever is read.
2. The fallback rule: a KF8 half that does not read, for any reason but protection or a cancel, leaves the MOBI 6 half.
   MOBIBook.HybridChoice.mobi6 reads that half on purpose; MarkdownCacheService.extractedText(for:includesPages:kindleHalf:) passes it for the upgrade of an unstamped .mobi book, which is compared with the half it was stored from (S6), so a hybrid stored by 0.4.1 is read again without a kept copy.
   A hybrid's title and author come from the half read, the KF8 half first, then the MOBI 6 half where the KF8 half names nothing.

### KF8 tables and the text
<!-- id: kf8-tables-text; keys: skeleton, fragment table, flow table, memory map, SVG flows, size limit, kindlegen, markup flow; src: TextMouth/Parsers/KF8Layout.swift, TextMouth/Parsers/MOBIText.swift, TextMouth/Parsers/MOBIParser.swift, TextMouth/Parsers/MOBIError.swift, TextMouth/Parsers/DocumentByteLimit.swift -->

3. KF8Layout reads the three tables: the flow table (FDST), the skeleton index (SKEL), and the fragment index (FRAG).
   The documents (a skeleton and its fragments) must lie end to end from the start of the markup flow to its end, each place and length inside the flow, else MOBIError.damaged (an end-to-end layout check, which holds the HTML written for them to the size of the text).
   The join of a document is a piece table, and a join that would take more than KF8Layout.maximumJoiningSteps (2,000,000) is refused.
   The markup is the first flow.
   A flow table that is missing or odd leaves the whole text.
4. The text: MOBIText.bytes(of:headers:through:) reads the text through the flow table's end (KF8Layout.flowTableEnd) when that is past the length the header declares, as kindlegen's KF8 headers declare only the markup and leave their SVG flows after it.
   KF8Layout.flowTableEnd is 0 above DocumentByteLimit.current, and DocumentByteLimit.check runs on the larger length, so the 64 MB cap holds.
5. The file: MOBIParser.mappedContents memory-maps the file, held to MOBIParser.maximumFileBytes (512 MB), so a kindlegen hybrid with its pictures twice (111 MB for 1 MB of words) costs no allocation of that size.
   DocumentByteLimit is held to the text, not the file.

### KF8 sections and the continuation rule
<!-- id: kf8-sections-continuation-rule; keys: chapters, calibre, Project Gutenberg, split files, chapter boundary, licence, headings, NCX; src: TextMouth/Parsers/KF8Book.swift, TextMouth/Parsers/MOBIMarkup.swift, TextMouth/Parsers/MOBIIndex.swift, TextMouth/Parsers/MOBIParser.swift -->

6. KF8Book makes the sections, one for each document, in reading order.
   A contents entry (NCX) that names the very start of a document's first fragment titles the document; one that names a place inside it is a heading there (level depth + 1, at most 6) at an anchor (MOBIMarkup.anchors, one for all the places inside one tag).
   A contents or guide that does not read names nothing, and the book is read without it.
   An index may claim at most 2,000,000 numbers, an index row's label is cut at 1,024 bytes (MOBIIndex.maximumLabelBytes).
7. The continuation rule: a document that no contents entry names, that opens with no heading before any word (documentOpening, within 4,096 bytes), and that follows a document with words (hasChapterBefore), may join the chapter before it (Section.continuesPrevious).
   It joins only when the title in its head equals the previous document's, or equals the heading the next document opens with (openingHeading, within 8,192 bytes).
   Both are exact comparisons after readableLabel: references read, soft hyphens left out, white space collapsed, case kept; openingHeadingBounds is the one scan both use, and passes over a comment or any other tag before the heading.
   A document that joins makes no heading of its title; any other is a chapter of its own, titled by displayTitle.
   A cut that fell inside a paragraph joins the two halves into one (joinsParagraph).
   MOBIParser.preparedBook groups the sections, so a MOBI 6 book and a KFX book, which never continue, end in the same function.
   - The repeated-title exception (Container.endsBefore, 0.4.3): calibre gives every piece it cuts from one file that file's title, so a piece with the title of the piece before it normally goes on with it.
     It does not when the piece before opens in a section element (Container.names: header, section, article, aside, nav, main) that is not a footer, and this piece opens in no section element at all.
     Project Gutenberg's header page is such a section, and the essay after it, in a div, is a chapter of its own: A Modest Proposal reads as 3 chapters, as its EPUB does, and not 2.
   - The exception is narrow on purpose.
     A piece that opens in another section element still goes on, since a document of two sections that is cut inside the second reopens that section in the new piece, and its second half must not become a chapter.
     A piece after a footer goes on too, so Gutenberg's back page stays with the licence.
   - The licence-opening rule: a piece with no heading whose title is the heading the next piece opens with, and that is inside the same element as the next piece, is not the end of the chapter before.
     It is the opening of the next piece's section, so the next piece goes on with it (previousOpensThisSection).
     Where the two pieces are not in one element, the piece goes on with the chapter before, as before.
     A section element is found by Container.names and its id, and openingContainer passes over anchors and comments to find it.
     Such an element has an id, as Gutenberg's footer#pg-footer does, which calibre opens again in the next piece.
   - Measured on the real books: Pride and Prejudice's last chapter went from 1,461 to 1,248 words and its licence from 2,694 to 2,907.
     Moby Dick's Epilogue went from 482 to 267 and its licence from 2,693 to 2,908.
     The Yellow Wallpaper's last chapter went from 6,295 to 6,082 and its licence from 2,693 to 2,906.
     Every book's words are the same, and the edge samples and The Time Machine read as before.
   - Not settled: a wrapper such as main with an id around several chapters would move the end of one chapter into the next, no sample has one, and boilerplate written as a section with the id pg-footer, not a footer, would make the back page a chapter of one word.

### KF8 endings: rewriting, pages, and refusals
<!-- id: kf8-endings-rewriting-pages-refusals; keys: contents page, generated contents, SVG, epub:type, page list, soft hyphen, MarkupRefusal, cancel; src: TextMouth/Parsers/KF8Book.swift, TextMouth/Parsers/MarkupGuard.swift, TextMouth/Parsers/HTMLToMarkdownConverter.swift, TextMouth/Parsers/ParserUtilities.swift, TextMouth/Parsers/MOBIParser.swift, TextMouth/Parsers/MOBIError.swift, TextMouth/Services/FileImportService.swift, TextMouth/Services/ArchiveExtraction.swift -->

8. The last document is left out when the guide names its start as the book's contents page (generatedContentsCandidate) and KF8Book.isGeneratedContents holds:
   - its only words outside its links are its own title,
   - every link goes to a place in the book (kindle:pos), and
   - each link's words are a label of the contents.

   A last page with words of its own is read.
9. Rewriting: kindle:flow SVG pictures are put back where they stood, once each, and only a small flow that is an SVG picture is put back.
   The words in them are read.
   epub:type values calibre strips of their prefix (type="pagebreak", page-list, landmarks, toc) are put back whole-attribute only, so the shared reading rules find the page breaks and leave the navigation lists unread.
   Soft hyphens are removed by ParserUtilities.removingSoftHyphens, in a document's markup and in a contents entry's label (see Shared helpers and the MOBI 6 item above); the EPUB reader keeps them.
   Links (kindle:pos) are never followed, and pictures are read by description.
10. Pages: the page-break elements a KF8 book kept are pages (the includesPages flag reaches MOBIParser.prepareBook and the converter), and its page list is not kept.
    A MOBI 6 book and a KFX book named .azw have none.
11. Every document's markup reaches SwiftSoup only through HTMLToMarkdownConverter.convert and MarkupGuard, so the guard's refusals (MarkupRefusal) settle a KF8 part as they do a MOBI 6 section.
    No KF8 or MOBI file calls SwiftSoup's parse itself, which the large-stack policy test requires.
12. Cancel is asked before each document is joined (KF8Book.sections' checkCancellation, ImportCancellation.throwIfCancelled by default), and a test proves the read stops partway.
13. The refusals are the MOBI ones: copyProtected, unsupportedCompression, damaged, notAKindleBook, and FileImportError.noTextToRead for a book whose documents hold no words.

### Names, limits, and files
<!-- id: mobi-names-limits-files; keys: metadata, EXTH 503, title and author, foliate-js, limits, hostile files, MIT licence, readMetadata; src: TextMouth/Parsers/MOBIError.swift, TextMouth/Parsers/MOBIPalmDatabase.swift, TextMouth/Parsers/MOBIHeaders.swift, TextMouth/Parsers/MOBIText.swift, TextMouth/Parsers/MOBIHuffman.swift, TextMouth/Parsers/MOBIIndex.swift, TextMouth/Parsers/MOBIMarkup.swift, TextMouth/Parsers/MOBIBook.swift, TextMouth/Parsers/KF8Layout.swift, TextMouth/Parsers/KF8Book.swift, TextMouth/Parsers/MOBIParser.swift, TextMouth/Parsers/BookParser.swift, TextMouth/Parsers/DocumentByteLimit.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouth/Services/FileImportService.swift, TextMouth/Models/Book.swift, TextMouth/Resources/Info.plist -->

Names: MOBIBook.Metadata takes the title from EXTH 503, else the MOBI header's full name, else the database's name; the author from EXTH 100, the names joined with commas; and the language from EXTH 524.
FileImportService adopts the title and author through MOBIParser.readMetadata, which never fails an import, so a book that is then refused is refused by its own reading.

- Limits, besides DocumentByteLimit for the file and the declared text: 10,000 EXTH records, 100,000 index entries, 32 string records, 64 tags, HUFF tables of at most 256 records and 2^20 entries with an entry coded at most 8 levels deep, and 500,000 filepos targets, past which no anchor is put.
- MOBIText, MOBIIndex, MOBIHuffman, and KF8Layout follow foliate-js's mobi.js (MIT) closely; its licence ships in the app (see [Third-party code](../../developer/third-party-code.md)).

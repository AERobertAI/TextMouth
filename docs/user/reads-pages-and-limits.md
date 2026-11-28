# What TextMouth reads: pages, tables, and limits
<!-- id: reads-pages-limits; keys: page navigation, Go to Page, page break, doc-pagebreak, tables, 64 MB; src: TextMouth/Models/BookPages.swift, TextMouth/Models/ReaderPageWording.swift, TextMouth/Models/PageReaderVersions.swift -->

Part of [TextMouth's documentation](../../README.md).
Every format TextMouth reads, with how well each is tested, is in [the list of formats](formats-list.md).

## Pages
<!-- id: pages; keys: Page unit, Go to Page, page labels, re-read, page reader version; src: TextMouth/Models/BookPages.swift, TextMouth/Models/PageReaderVersions.swift, TextMouth/Models/ReaderPageWording.swift -->

- Pages, which the Page navigation unit and Go to Page… move by (see [Reader windows](reader-pages.md)), are numbered as each format numbers them.
- A book already in your library gains pages when its text is read again (see [Where TextMouth keeps your library](book-packages.md)).

### Pages in EPUB books
<!-- id: pages-epub-books; keys: page-list, pagebreak, doc-pagebreak, pagenum, aria-label, epub:type; src: TextMouth/Parsers/EPUBParser+Navigation.swift, TextMouth/Parsers/EPUBParser.swift, TextMouth/Parsers/PublicationSemantics.swift -->

- In an EPUB, pages are the book's page list or, when it has none, its page-break marks.
- A page list that gives none of its pages a number, such as one whose only entry is named by its link ("pagenum_000000"), counts as none, and a mark named only "Page" names no page.
- A page any book names "Page 12" is page 12, and a page number printed at its mark is not read aloud.
- A mark's own text is not read aloud when it is no more than its page's label, the print page's number and perhaps a caption of up to 32 characters.
- Any longer or other text in a mark is read, after its page marker.
- A mark with no aria-label or title that holds more than that begins no page.

### Pages in HTML files and web archives
<!-- id: pages-html-files-web-archives; keys: pagebreak role, heading page number, page marker; src: TextMouth/Parsers/HTMLToMarkdownConverter.swift, TextMouth/Parsers/MarkdownPageMarker.swift -->

- In HTML files, and in Safari web archives read as HTML files, pages are the page-break marks.
- In an EPUB and in an HTML book alike, a page break's number inside a heading is left out of the heading's name too (see [Reader windows](reader-pages.md)).

### Pages in PDF files
<!-- id: pages-pdf-files; keys: PDF page label, PDFPage, blank page, roman page; src: TextMouth/Parsers/PDFTextParser.swift -->

- In a PDF, every page is a page, with the page labels the PDF gives, such as i, ii, 1, 2, and A-1, or its number when it gives none.
- A page with no text is still a page.

### Pages in Word documents
<!-- id: pages-word-documents; keys: .docx, page break, pageBreakBefore, sectPr, lastRenderedPageBreak, page number format; src: TextMouth/Parsers/DOCXParser+Sections.swift, TextMouth/Parsers/DOCXParser+Converter.swift -->

- In Word documents, templates, and macro documents, pages are the page breaks the author wrote, paragraphs set to start a page, sections that start a page, and the page breaks Word recorded when it last laid the document out.
- Pages are numbered from 1.
- A section can restart the number and set its format (decimal, lower or upper case roman numerals, or lower or upper case letters; any other format counts as decimal).
- A document Word never laid out, such as one another program made, holds only its author's page breaks, so TextMouth shows fewer pages than Word would.

### Pages in DAISY books
<!-- id: pages-daisy-books; keys: pagenum, page-front, page-normal, DTBook, SMIL, page reader 1.0.1; src: TextMouth/Parsers/DAISYParser+TextExtraction.swift, TextMouth/Parsers/DAISYParser.swift, TextMouth/Models/PageReaderVersions.swift -->

- In a DAISY book, pages are the page numbers the book gives, which are not read aloud as "[Page 12]".
- A DAISY 3 book of several DTBook files numbers a page that holds no words by its place in the whole book: 1, 2, then 3, 4.
- The first launch of version 0.4.7 reads every DAISY book again, once, as the DAISY page reader changed (version 1.0.1), and your place follows its words.
  Only a DAISY 3 book of several DTBook files, with a page that holds no words after an earlier page or with files that were read out of order, ends with another text; every other DAISY book reads byte for byte as before.
- A DAISY 2.02 page entry's own number or caption, as "12" under the label "Page 12", is not read either.
- Any longer or other text a DAISY 2.02 page entry points at is read.

### Pages in rich text
<!-- id: pages-rich-text; keys: pagebb, sbknone, sbkcol, section break, break limit; src: TextMouth/Parsers/RTFInterpreter.swift, TextMouth/Parsers/RTFBlockBuilder.swift, TextMouth/Parsers/RTFDocumentReader.swift -->

- In rich text and rich text with attachments, a page begins at each \page, each paragraph set to start a page (\pagebb, directly or by its style), and each section that starts a page (a \sect followed by a section of the kinds that start one, which is the default, but not \sbknone or \sbkcol).
- Pages are numbered from 1, and a page begins at its first letter or digit, so a break with no words after it begins none.
- A paragraph set to start a page before any words begins the first page, which is page 1 already.
- A document with 100,000 or more breaks has no pages, and the text is read as before.

### Pages in Word 97-2003 documents
<!-- id: pages-word-97-2003-documents; keys: page break before, section break, new page, even page, odd page, continuous; src: TextMouth/Parsers/WordDocumentSections.swift, TextMouth/Parsers/WordDocumentHTMLWriter.swift -->

- In Word 97-2003 documents and templates, pages are the page breaks the author wrote, a paragraph set to start a page ("Page break before"), directly or by its style, outside a table, and a section that starts a page.
- A section starts a page if its break is of the kind that starts a new, even, or odd page, which a section that says nothing is.
  A continuous section break or a new column does not.
- Pages are numbered from 1, and a page begins at its first letter or digit.
- TextMouth reads no layout of Word's own, so a .doc shows fewer pages than Word would.

### Pages in OpenDocument text
<!-- id: pages-opendocument-text; keys: master page, break-before, break-after, soft-page-break; src: TextMouth/Parsers/ODTContentReader.swift, TextMouth/Parsers/ODTStyles.swift -->

- In OpenDocument text, pages are the page breaks the author wrote (a paragraph or table style that breaks before or after it), a paragraph or table that names a master page, and the soft page breaks that the program which last laid the document out recorded.
- Pages are numbered from 1, with no restarts or formats, and a page begins at its first letter or digit.
- A page cannot begin inside a table or a text box.
- A document that no program laid out holds only its author's breaks, so it shows fewer pages than the author's program would.

### Pages in Word 2003 XML
<!-- id: pages-word-2003-xml; keys: w:br, pageBreakBefore, sectPr, WordML; src: TextMouth/Parsers/WordMLReader.swift, TextMouth/Parsers/WordMLDocumentReader.swift -->

- In Word 2003 XML, pages are the page breaks the author wrote, paragraphs set to start a page, and sections that start a page, numbered from 1.

### Pages in Word 6 and Word 95 documents
<!-- id: pages-word-6-word-95; keys: continuous section break, textutil page break; src: TextMouth/Parsers/WordDocumentSections.swift -->

- In Word 6 and Word 95 documents, a page break, a section that starts a page, and a paragraph set to start a page begin pages, as in a Word 97-2003 document.
- A continuous section break begins none, where textutil began a page.

### Pages in a Word document older than Word 6
<!-- id: pages-word-document-older-than; keys: textutil second run, page break, field instructions, dropped break; src: TextMouth/Parsers/TextutilPageBreaks.swift, TextMouth/Parsers/TextutilDocumentReader.swift -->

- On the Mac, a Word document older than Word 6 has the page breaks textutil reports in a second run, numbered from 1, with the words textutil ran together at a break kept apart.
- A break whose surroundings differ in textutil's two readings is dropped, never placed wrongly.
- A Word field such as a table of contents or a link does not put the two readings out of step, since the breaks are placed before textutil's field instructions are removed.

### Pages in braille files
<!-- id: pages-braille-files; keys: braille page number, form feed, print page, preliminary page, p1; src: TextMouth/Parsers/BrailleBookReader+Pages.swift, TextMouth/Parsers/BraillePageAnalyzer.swift -->

- In BRF and PEF braille files, every braille page is a page, the pages an embosser or a braille display counts.
- A page is named by its braille page number read as print, as ⠼⠁⠃ reads 12 and ⠏⠼⠁, a preliminary page, reads p1.
- A page with no braille page number, or none that TextMouth can read, is named by its place among the book's pages, the first being 1.
- A print page number, such as a transcription of a print book carries, is no page here, and is left out of the text.
- A page that begins in the middle of a paragraph begins at its first word there.
- A page with neither words nor a number, such as the blank back of a two-sided page or the empty page a form feed leaves at a file's start or end, is not a page.
- A BRF without form feeds, which TextMouth cuts every 25 lines only to read its layout, has pages only when braille page numbers end most of those 25-line pieces.
- A form feed only at a file's start or end counts as none.
- A BRL file has no pages.
- In a BARD braille book, each volume's heading follows the marker of the volume's first page, so going to that page lands on the heading (see [DAISY and braille books](reads-daisy-and-braille.md)).

### Pages in plain text
<!-- id: pages-plain-text; keys: form feed, FF, blank page, page limit; src: TextMouth/Parsers/MarkdownPageMarker.swift, TextMouth/Parsers/PlainTextParser.swift -->

- In plain text, each form feed between the words begins a page, numbered from 1, at the first line after it that is read.
- A form feed before the first words or after the last begins none, so a text without one between words has no pages.
- Two form feeds in a row make a blank page, which counts in the numbering and begins where the page after it does.
- A text has at most 100,000 pages, the most a book may have.
  A form feed past them begins none, and the text is read as before.
- A Safari web archive whose page is plain text has no pages.

### Pages in SSML and Markdown
<!-- id: pages-ssml-markdown; keys: page lines, Markdown page marker, SSML; src: TextMouth/Parsers/MarkdownPageMarker.swift, TextMouth/Parsers/MarkdownMarker.swift -->

- SSML files have no pages.
- A Markdown file has pages only where it holds page lines (see [Editing a book's text](editing-book-text.md)).

### Pages in MOBI books
<!-- id: pages-mobi-books; keys: APNX, .apnx, page list, Kindle page numbers; src: TextMouth/Parsers/MOBIParser.swift; status: incomplete; issues: DR13 -->

- Kindle books in the MOBI format have no pages.
- The Kindle keeps a book's page numbers in a separate .apnx file beside it, which TextMouth does not read yet.

### Pages in KF8 books
<!-- id: pages-kf8-books; keys: pagebreak, EPUB page breaks, hybrid, MOBI 6 half; src: TextMouth/Parsers/KF8Book.swift, TextMouth/Parsers/MOBIParser.swift -->

- In Kindle books in the KF8 format, pages are the page breaks the book kept from the EPUB it was made from, when it has them.
- KF8 keeps no page list, so a book that has page breaks in its text has pages, and one without them has none.
- A book that holds both MOBI 6 and KF8 has pages from its KF8 half only.

### Pages in KFX books
<!-- id: pages-kfx-books; keys: print page list, machine-made pages, approximate pages; src: TextMouth/Parsers/KFXNavigation.swift, TextMouth/Parsers/KFXTargets.swift -->

- In Kindle books in the KFX format, pages are the book's print page list, when it has one and a person made it.
- A KFX book with no print page list, or with only a machine's approximate one, has no pages.

## Tables
<!-- id: tables; keys: table row, cell, pause after a row, td, tr, row at a time; src: TextMouth/Parsers/HTMLToMarkdownConverter.swift, TextMouth/Parsers/MarkdownParser.swift -->

- In EPUB, HTML, Word, and Markdown books, a table is read a row at a time: each row is a paragraph of its own, with a pause after it, and the cells in a row are separate words.

## The 64 MB limit
<!-- id: 64-mb-limit; keys: DocumentTooLargeError, ArchiveEntryLimits, 512 MB, byte limit, too large; src: TextMouth/Parsers/DocumentByteLimit.swift, TextMouth/Parsers/ArchiveEntryReader.swift, TextMouth/Parsers/MOBIParser.swift -->

- A rich text, Word 97-2003, OpenDocument, or Word 2003 XML document, a web archive, an SSML file, a DTBook on its own, or a Kindle book that holds more than 64 MB is refused, since that is the most TextMouth reads from one document.
- For a Kindle book the limit is on its text.
  A hybrid file that holds its pictures twice can be larger than 64 MB, and is read, up to 512 MB in all.
- For an .rtfd the limit is on its text file, TXT.rtf, alone: the attachments are not read, and do not count toward it.

## How the Library window names a format
<!-- id: how-library-window-names-format; keys: Format column, displayName, Kindle Book, Rich Text, Word Document; src: TextMouth/Models/Book.swift -->

- In the Library window, a book's row names its format:
  - "Rich Text" for an .rtf.
  - "Rich Text with Attachments" for an .rtfd.
  - "Word 97-2003 Document" for a .doc or .dot.
  - "OpenDocument Text" for an .odt or .ott.
  - "Word 2003 XML", "Web Archive", and "SSML" for those formats.
  - "Kindle Book (MOBI)" for a .mobi, .prc, .azw, or .azw3.
  - "Kindle Book (KFX)" for a .kfx, .kfx-zip, or .azw8.
  - "Braille" for a BRF, BRL, or PEF.
- A Word template or macro document says "Word Document", and a DTBook says "DAISY".

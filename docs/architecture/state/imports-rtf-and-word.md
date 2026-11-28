# Imports: rich text and Word documents
<!-- id: imports-rich-text-word-documents; keys: RTF, RTFD, doc, odt, wordml, OpenDocument, Word 2003 XML, textutil; src: -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## Own readers of rich text and Word documents
<!-- id: own-readers-rich-text-word; keys: Microsoft Word, OpenDocument Text, WordprocessingML 2003, kill switch, textutil fallback, no helper process, OwnDocumentReaders, comparison test; src: TextMouth/Parsers/OwnDocumentReaders.swift, TextMouth/Parsers/RTFDocumentReader.swift, TextMouth/Parsers/WordDocumentReader.swift, TextMouth/Parsers/ODTDocumentReader.swift, TextMouth/Parsers/WordMLDocumentReader.swift, TextMouth/Parsers/TextutilDocumentReader.swift -->

Own readers of rich text, Word 97-2003, OpenDocument text, and Word 2003 XML (FMT47 and FMT27, FMT53): TextMouth's own code reads rtf, rtfd, doc, odt, and wordml documents, the same in both apps, with no helper process and no textutil.
The rich text and Word 97-2003 readers replaced textutil in 0.3.1, and the OpenDocument and Word 2003 XML readers in 0.4.0.
Each came after its comparison test (RTFTextutilComparisonTests, WordDocumentComparisonTests, ODTTextutilComparisonTests, WordMLReaderTests), which found the same words as textutil's in every sample and at least its headings and pages.
(see [Testing](../../developer/testing-goldens.md)).

### The route and the switches
<!-- id: route-switches; keys: dispatch, kill switch, feature flag, fallback, encrypted doc, TaskLocal, withValue, PhoneImportRefusal; src: TextMouth/Parsers/OwnDocumentReaders.swift, TextMouth/Parsers/TextutilDocumentReader.swift, TextMouth/Parsers/TextutilSourceCheck.swift, TextMouth/Parsers/RTFDocumentReader.swift, TextMouth/Parsers/WordDocumentReader.swift, TextMouth/Parsers/ODTDocumentReader.swift, TextMouth/Parsers/WordMLDocumentReader.swift -->

The route: TextutilDocumentReader.htmlText(of:bookFormat:includesPages:) decides how the file is read (reading(of:bookFormat:), in [The path through textutil](imports-textutil.md)).
It throws PasswordProtectedDocument for a doc whose File Information Block says it is encrypted (TextutilSourceCheck.isEncryptedWordDocument) and for an encrypted odt (TextutilSourceCheck.isEncryptedOpenDocument), and only then asks OwnDocumentReaders.html(of:as:includesPages:) for the HTML.
A string is a reader's answer, and htmlText returns it as Source(html:, isOwnReading: true); nil means this platform reads the format with textutil, and the textutil path follows.
The router switches on the format as reading(of:) found it, not as the book's name says:

- .rtf and .rtfd go to RTFDocumentReader.html(of:as:includesPages:), behind RTFDocumentReader.isOn.
- .doc goes to WordDocumentReader.html(of:includesPages:), behind WordDocumentReader.isOn, which answers nil for a compound-file document older than Word 6 alone.
  (it reads Word 6 and Word 95 documents with the old layout, behind WordDocumentReader.readsWord6AndWord95, `static var readsWord6AndWord95: Bool { true }`, on for the Mac and for iOS).
  (its own entry points read the old layout whatever it says, so the tests can).
- .odt goes to ODTDocumentReader.html(of:includesPages:), behind ODTDocumentReader.isOn, and .wordml to WordMLDocumentReader.html(of:includesPages:), behind WordMLDocumentReader.isOn.
  Both answer a string for every file; only a compound-file doc older than Word 6 answers nil now.
- The switches: RTFDocumentReader.isOn, WordDocumentReader.isOn, ODTDocumentReader.isOn, and WordMLDocumentReader.isOn are `static var isOn: Bool { true }`, on for the Mac and for iOS.
  Each was off on the Mac until its comparison test passed.
  Set to false, a switch sends its format to textutil on the Mac, and on iOS to a refusal, since iOS runs no textutil.
- OwnDocumentReaders.$forcesTextutil is a test-only task-local, false unless a test binds it with withValue(true).
  While it is true html(of:as:includesPages:) answers nil for every format, before it looks at any switch.
  So a test can pin textutil's own behavior (its second run for pages, its one run per import, its refusal wording, the cancelling of its child) and the comparison tests can read a sample with both readers.
  It is read on the caller's thread, where the route is decided, as DocumentByteLimit.current is.
  Nothing in the app sets it.

### What the readers hand back
<!-- id: what-readers-hand-back; keys: HTML contract, page markers, Markdown conversion, ReadingFlow, page limit, escaping, metadata, headings; src: TextMouth/Parsers/OwnDocumentReaders.swift, TextMouth/Parsers/TextutilDocumentReader.swift, TextMouth/Parsers/TextutilPageBreaks.swift, TextMouth/Parsers/TextutilHTMLStructure.swift, TextMouth/Parsers/PublicationSemantics.swift, TextMouth/Parsers/HTMLToMarkdownConverter.swift, TextMouth/Parsers/MarkdownPageMarker.swift, TextMouth/Models/PageReaderVersions.swift -->

What the reader hands back: one HTML document in the form OwnDocumentReaders describes.
Its head names the title (title) and the author (meta name author) the file gives, which TextutilDocumentReader.metadata(in:) reads as it reads textutil's.
Its body holds h1 to h6, p, em and strong, ul, ol, and li, and table, tr, and td, all text escaped.
When includesPages is true, it also holds an empty span with role doc-pagebreak and an aria-label of the page's number before each page's first letter or digit, page 1 at the start of the body of a document that holds a letter or digit.
A document with 100,000 breaks or more (TextutilPageBreaks.maximumPages, which is MarkdownPageMarker.maximumPagesPerBook) is written without pages.

- Source.isOwnReading: markdown(from:source:fileName:includesPages:) sends the HTML straight to HTMLToMarkdownConverter.convert(document:readingFlow:includesPages:), with the reading flow of PublicationSemantics.ReadingFlow(source: source.html).
  It skips TextutilHTMLStructure.restore (the pictures, field instructions, bullets, and size headings that restore finds in textutil's HTML) and TextutilPageBreaks.insertPageBreaks, since the reader's markup holds its headings, lists, and pages already.
  An own reading runs no second pass for pages, so Source.plainText is nil and pageRunFailed false: its book never gets a "+failed" stamp (PageReaderVersions).

### The page reader
<!-- id: page-reader; keys: reader version, version stamp, re-read, outdated book, upgrade, semantic version, launch re-read, stale pages; src: TextMouth/Models/PageReaderVersions.swift, TextMouth/Models/SemanticVersion.swift -->

The page reader: PageReaderVersions.current(for:) is "1.2.0" for rtf and rtfd, "1.3.0" for doc, docx, and wordml, "1.1.0" for odt, and "1.0.0" for kfx.
The launch re-read (launchRereadIsOn) reads again once each such book whose stamp is behind its format's line or missing; a book stamped without a failure note skips PG16's compare of its text (V05), and one with no stamp goes through it.
A book stamped "1.2.0" by a newer TextMouth is not outdated for an older one (SemanticVersion.isOutdated compares the three numbers), which leaves the book as it is.

### The rich text reader
<!-- id: rich-text-reader; keys: Rich Text Format, TextEdit, RTFD package, tokenizer, code page, list table, heading guess, footnotes; src: TextMouth/Parsers/OwnDocumentReaders.swift, TextMouth/Parsers/RTFDocumentReader.swift, TextMouth/Parsers/RTFTokenizer.swift, TextMouth/Parsers/RTFInterpreter.swift, TextMouth/Parsers/RTFGroupState.swift, TextMouth/Parsers/RTFEncodings.swift, TextMouth/Parsers/RTFStyleSheet.swift, TextMouth/Parsers/RTFListTable.swift, TextMouth/Parsers/RTFBlockBuilder.swift, TextMouth/Parsers/RTFDocumentModel.swift, TextMouth/Parsers/RTFSizeHeadings.swift, TextMouth/Parsers/RTFHTMLWriter.swift, TextMouth/Parsers/DocumentByteLimit.swift, TextMouth/Parsers/TextutilSourceCheck.swift, TextMouth/Parsers/TextutilHTMLStructure.swift, TextMouth/Services/TextutilConverter.swift, TextMouth/Services/FileImportService.swift -->

The rich text reader (RTFDocumentReader, written from Microsoft's RTF 1.9.1 specification), in steps:

1. html(of:as:includesPages:) picks the file: for an .rtfd that is a folder, the file named TXT.rtf (matched without regard to case; a link, or no such file, is TextutilConverter.Failure.unreadable(.rtfd)), and otherwise the file itself.
   DocumentByteLimit.contents(of:) reads it (empty is FileImportError.noTextToRead, past the limit DocumentTooLargeError), and TextutilSourceCheck.beginsAsRTF must find {\rtf at its start, else Failure.unreadable.
   An rtfd's attachments are never opened and do not count toward the limit.
2. RTFTokenizer turns the bytes into group starts and ends, control words (names of at most 32 letters, parameters of at most 10 digits clamped to 32 bits), control symbols, \'hh bytes, and runs of text.
   It skips the bytes of a \binN, and a \binN that claims more bytes than remain ends the document.
3. RTFInterpreter walks the tokens with its own array for the group stack, so no recursion follows the file's depth; a nesting of more than 10,000 groups (deepestNesting) throws Failure.unreadable(.rtf).
   Each group carries an RTFGroupState.
   Its destination (RTFDestination: body, skipped, attachment, shape, font table, style sheet, style entry, info, title, author, list table, list text), bold, italic, hidden, font size, font, the \uc skip, and the paragraph's style, outline level, list, list level, and table flag.
   Text goes only to the body: skipped destinations (pictures, objects, headers, footers, comments, field instructions, bookmarks, and every unknown starred destination) read nothing.
   Hidden text (\v) and deleted text (\deleted, which includes a moved-away \mvf; \revised is read) read nothing: RTFGroupState.isDeleted sits beside the hidden flag, isUnreadRun is true for either, and it governs text, \line, \page, and a bullet and tab.
   Both \plain and \deleted0 undo \deleted, as the group's end does.
   A \page, \pagebb, or \sect in unread text begins no page.
   A footnote or endnote (\footnote, \ftnalt) is a .note destination, read by a second RTFBlockBuilder that the interpreter swaps in while the note lasts (the budget is taken from what is left and charged back at the end):
   - the notes follow the body in file order (RTFDocument.notes),
   - a note's reference mark (the reference run, or the up to 10 characters before the note's first \pard) is not read and is never a heading,
   - a note is read only when its reference stands in read text,
   - an unterminated note is closed at the document's end, and
   - a note nested in a note, or in a header, title, or list marker, is skipped.
   A shape's text box (\shptxt, \dptxbxtext) is read by the same swap, except in a header or footer, and its blocks wait in the interpreter (RTFBlockBuilder's text boxes) and are written right after the paragraph or cell that holds its anchor.
   A field's \fldrslt is read and its \fldinst is not.
   The \info group gives the title and the author.

### The rich text reader's code page, styles, and blocks
<!-- id: rich-text-code-page-styles-blocks; keys: code page, ansicpg, RTFEncodings, style sheet, list table, block builder, size headings, byte budget; src: TextMouth/Parsers/RTFEncodings.swift, TextMouth/Parsers/RTFStyleSheet.swift, TextMouth/Parsers/RTFListTable.swift, TextMouth/Parsers/RTFBlockBuilder.swift, TextMouth/Parsers/RTFSizeHeadings.swift, TextMouth/Parsers/RTFHTMLWriter.swift, TextMouth/Parsers/DocumentByteLimit.swift -->

4. The code page: \ansi is 1252, \mac 10000, \pc 437, \pca 850, and \ansicpgN wins.
   A font's \fcharset or \cpg gives the code pages of the text set in it (RTFEncodings: ANSI, Mac Roman, Shift-JIS 932, Korean 949 and Johab 1361, GBK 936, Big5 950, Greek, Turkish, Vietnamese, Hebrew, Arabic, Baltic, Cyrillic, Thai, Eastern European, and the two PC pages).
   Bytes wait in a run and are decoded together, so the two bytes of a double-byte character are one, even when the second is ASCII (isMultibyte).
   A run invalid in its code page is read byte by byte as Windows-1252, and a number with no encoding is 1252.
   A \uN is a signed 16-bit value, a surrogate pair is two \u, and the \ucN characters after it are skipped.
5. RTFStyleSheet records each paragraph style (at most 100,000) with its name, outline level, \sbasedon, and \pagebb.
   RTFStyleSheet.headingLevel(ofStyle:) follows the chain in a loop to the first style that says anything, and a loop or an undefined style gives no heading.
   An outline level of 0 to 8 is level 1 to 6 (deeper is 6) and wins over a name; "heading 1" to "heading 9" are the names, "Title" level 1, and "Subtitle" level 2.
   RTFListTable maps \lsN through \listid to the \levelnfc of each level (23 is a bullet, 255 none), at most 10,000 lists.
   A paragraph is a list item when it has a list or a \listtext or \pntext marker; the marker's text is never read; a bullet and a tab at the start of a paragraph make one too.
   A paragraph in a table cell carries its RTFListPosition, and the cell is written through the same list writer as the body, so an item in a cell is a list in the Markdown (an export shows its number), and no list's number is in the reading text.
6. RTFBlockBuilder
   - gathers the paragraphs, runs of one style joined;
   - places the page breaks;
   - groups cells into rows and tables (a table in which no cell holds a word is dropped; the words of a nested table stay in the cell around it); and
   - keeps the budget: the limit in bytes, charged the text's bytes, 16 for each piece of text, 64 for each paragraph, and 81 for each cell (64 and its word's 17), past which DocumentTooLargeError (a table of about 790,000 cells, 5.5 MB of rich text, is the most a document may hold).
   A \page, a \pagebb (directly, or by its style), and a \sect whose section starts a page (\sbkpage, \sbkeven, \sbkodd, and \sectd's default; not \sbknone or \sbkcol) each add a pending break, written before the next letter or digit; a \pagebb or style break before any letter or digit adds none.
7. When no paragraph is a heading by a style or an outline level, RTFSizeHeadings.apply guesses them by TextutilHTMLStructure's rule over the RTFBlocks.
   Its census counts each paragraph's characters that are not white space with `String.forEachCharacter(_:)`.
   It judges a long paragraph by `RTFParagraph.plainText(stoppingAfter:)`, its first 480 bytes (four for each of a heading's at most 120 characters), when that beginning alone is already too long to be a heading.
   The answer is the whole text's, and `RTFSizeHeadingsTests` compares both with the old expressions (see [Shared helpers: readers and markup guards](../shared-helpers-parsers.md)).
   (the body size by characters, a paragraph of 1 to 120 characters that is not one letter, larger sizes by rank, bold at the body size unless the body is mostly bold).
   Never in a table or a list.
8. RTFHTMLWriter writes the HTML (a heading carries no emphasis; consecutive list items share their lists by level; a list can begin no deeper than one level below the open list).
- Limits: DocumentByteLimit for the file, the budget above for the text, 10,000 groups of nesting, 100,000 fonts, 100,000 styles, 10,000 lists, names and list text of at most 1,000 characters.
  The cancellation check is above, under Cancel.

### The Word 97-2003 reader
<!-- id: word-97-2003-reader; keys: Microsoft Word, binary doc, OLE2, structured storage, PlcPcd, sprm, footnotes, tracked changes; src: TextMouth/Parsers/OwnDocumentReaders.swift, TextMouth/Parsers/WordDocumentReader.swift, TextMouth/Parsers/CompoundFile.swift, TextMouth/Parsers/WordDocumentStructure.swift, TextMouth/Parsers/WordDocumentPieces.swift, TextMouth/Parsers/WordDocumentStyles.swift, TextMouth/Parsers/WordDocumentProperties.swift, TextMouth/Parsers/WordDocumentSections.swift, TextMouth/Parsers/WordDocumentLists.swift, TextMouth/Parsers/WordDocumentNotes.swift, TextMouth/Parsers/WordDocumentHTMLWriter.swift, TextMouth/Parsers/WordDocumentHeadingGuess.swift, TextMouth/Parsers/WordDocumentSummary.swift, TextMouth/Parsers/TextutilDocumentReader.swift, TextMouth/Parsers/TextutilSourceCheck.swift, TextMouth/Parsers/DocumentByteLimit.swift, TextMouth/Parsers/DOCXParser+Numbering.swift, TextMouth/Parsers/DOCXParser+Sections.swift, TextMouth/Parsers/TextutilHTMLStructure.swift, TextMouth/Parsers/RTFSizeHeadings.swift, TextMouth/Models/PageReaderVersions.swift -->

The Word 97-2003 reader (WordDocumentReader, written from [MS-DOC], [MS-CFB], and [MS-OLEPS]), in steps:

1. html(of:includesPages:) reads the file with DocumentByteLimit.contents(of:) and calls read(_:includesPages:), which CompoundFile opens.
   The header, the FAT and DIFAT, the mini FAT, and the directory tree, each followed with a set of what was seen so a loop ends the read, every sector index and a stream's declared size checked against the file.
   It takes the WordDocument stream.
   Any OLEDamage becomes Failure.unreadable(.doc).
2. WordFileInformationBlock.read(from:) reads the FIB: it
   - reads a Word 97-2003 FIB (an identifier of 0xA5EC, whatever its nFib: Word installs a special empty document with an nFib of 0x00C0) as the modern layout,
   - a Word 6 or Word 95 FIB (an identifier of 0xA5DC, or an older one, such as 0xA697 to 0xA699, with an nFib under 0x00C1; the nFib must be 0x0065 to 0x00C0) as the legacy one (readLegacy, below),
   - answers nil for an nFib under 0x0065 or, with the identifier 0xA5DC, past 0x00C0, which the router passes to textutil, and
   - throws OLEDamage for an nFib past 0x0200.
   A document whose flags say encrypted throws PasswordProtectedDocument (TextutilSourceCheck.isEncryptedWordDocument has thrown it already, before the reader is asked, from the file's first 8 MB).
   The flags name the table stream, 0Table or 1Table.

### The Word 97-2003 reader's table stream and writer
<!-- id: word-97-table-stream-writer; keys: CLX, piece table, bin table, sprm, style sheet, sections, lists, WordHTMLWriter; src: TextMouth/Parsers/WordDocumentPieces.swift, TextMouth/Parsers/WordDocumentStyles.swift, TextMouth/Parsers/WordDocumentProperties.swift, TextMouth/Parsers/WordDocumentSections.swift, TextMouth/Parsers/WordDocumentLists.swift, TextMouth/Parsers/WordDocumentHTMLWriter.swift, TextMouth/Parsers/DOCXParser+Numbering.swift -->

3. The table stream's structures, each located by the FIB's pairs and checked against the stream:
   - WordPieceTable (the CLX, whose pieces are 8-bit Windows-1252 or UTF-16LE and may lie in any order in the file, and whose RgPrc groups hold each piece's property modifiers, Pcd.prm:
     - Prm0 maps an index to the sprms the reader uses, Prm1 names a group, and a Prm1 index naming no group, or a group past the CLX, is damage;
     - the modifiers are applied after the PAPX and CHPX through the same functions, a character taking its own piece's and a paragraph those of the piece holding its last character;
     - forEachCharacter finds its first piece by halving, and a style's chain is resolved once when the sheet is read, WordStyleSheet.Resolved),
   - WordStyleSheet (the styles by index: built-in identifier, based-on, outline level, bold, italic, size, page break before),
   - WordDocumentProperties (the bin tables of paragraph and character formats, as runs of character positions:
     - style, outline level, table and row flags, table depth, page break before;
     - bold, italic, size, character style, special, hidden (sprmCFVanish, a toggle read through direct formatting, the character style, the paragraph style, and the styles they are based on), and tracked-deletion flags;
     - sprmCFRMarkDel is a toggle too, deleted only at 1 and 0x81), and
   - WordSections (where each section ends and whether it starts a page; a section that says nothing does).
4. WordHTMLWriter takes the characters of the main story in order, from WordPieceTable.forEachCharacter.
   0x0D and 0x07 end paragraphs and cells, 0x0C is a page or section break, 0x0B a line break, and 0x13, 0x14, and 0x15 begin, divide, and end a field, whose instruction part is dropped and result kept (at most 10,000 fields deep).
   A tracked deletion, hidden text, a picture's anchor, and the other control characters are not text: a paragraph of only hidden or deleted words writes nothing and no heading, and a page break or page-break-before in unread text begins no page.
   A numbered or bulleted paragraph that Word's list tables (WordDocumentLists, from PlfLst and PlfLfo, each length checked) name is an li of an ol or ul, nested by level, counted by DOCXListCounter over a DOCXNumbering built from those tables.
   DOCXPageNumberFormat writes the Roman and letter formats.
   Ordinal and word formats read as Arabic.
   With WordDocumentReader.speaksListNumbers false, its default, no number is written into the reading text and a numbered heading is its words alone, while with it true the number is written as words before the paragraph.
   A question for the user, humanQuestions/2026-11-06.md, is open on which to keep.
   A paragraph is
   - a heading by WordStyleSheet.headingLevel(styleIndex:directOutlineLevel:) (the paragraph's outline level, then each style up the chain: an outline level, or sti 1 to 9, 62 Title, and 74 Subtitle),
   - a bulleted item when it begins with a bullet character and a space (the dash and asterisk only before a tab, by TextutilHTMLStructure.bulletCharacters),
   - a cell of a table or of a table nested in one when it says so, and
   - otherwise p.
   A paragraph that begins a page by its direct property or its style, outside a table and after the first words, adds a page, as a form feed that WordSections.formFeedStartsPage says starts one does.
   With 100,000 page breaks or more the writer throws PageLimitExceeded and the document is written again without pages.

### The Word 97-2003 reader's stories, headings, and properties
<!-- id: word-97-stories-headings; keys: footnote story, endnote story, text boxes, heading guess, SummaryInformation, WordNotes, ccpText; src: TextMouth/Parsers/WordDocumentStructure.swift, TextMouth/Parsers/WordDocumentNotes.swift, TextMouth/Parsers/WordDocumentHeadingGuess.swift, TextMouth/Parsers/WordDocumentSummary.swift, TextMouth/Parsers/WordDocumentReader.swift -->

5. The stories: the main story (ccpText) is written, and, by fib.stories(limit:) (WordDocumentStructure.swift), the footnote story, the endnote story, and the main text boxes (ccpTxbx) follow it in that order, each story numbering its lists again from the start.
   The header, macro, comment, and header text box stories are left out.
   A note is written only if its reference mark is shown (WordNotes.shownRanges, in WordDocumentNotes.swift: PlcffndRef and PlcffndTxt, PlcfendRef and PlcfendTxt, the i-th mark belonging to the i-th note; tables that do not fit read the whole story); a custom mark is read as typed.
   The main text boxes are cut by WordNotes.boxRanges.
   The heading guess, the census, hasRealHeading, and the pages come from the main story alone.
   When the main story, its notes, and its boxes hold no words, everything is written, in the order the file keeps it, so a document whose words are in a header is not an empty book.
   The writer's output is held to twice DocumentByteLimit.
6. A document with no heading by a style or an outline level (a heading in a text box, or one written with only hidden words, does not count) has WordHeadingGuess.levels over the paragraphs of at most 120 characters that are not one letter, in no table or list.
   (the rule of RTFSizeHeadings, by the document's census of characters by size and weight).
7. WordSummaryInformation takes the title (property 2) and the author (property 4) from the SummaryInformation property set (at most 1,000 properties, names of at most 4,096 characters; a damaged stream gives none).
   WordDocumentReader.page(body:title:author:) writes the document.
- Limits: DocumentByteLimit for the file, twice that for the HTML, the compound file's checks, 10,000 nested fields, and the 100,000 pages.

### The Word 6 and Word 95 layout
<!-- id: word-6-word-95-layout; keys: Word 6.0, old Word files, legacy doc, Macintosh Word, Far East, code page guess, nFib, government samples; src: TextMouth/Parsers/WordDocumentReader.swift, TextMouth/Parsers/WordDocumentStructure.swift, TextMouth/Parsers/WordDocumentPieces.swift, TextMouth/Parsers/WordDocumentStyles.swift, TextMouth/Parsers/WordDocumentProperties.swift, TextMouth/Parsers/WordDocumentSections.swift, TextMouth/Parsers/WordDocumentLists.swift, TextMouth/Parsers/WordDocumentNotes.swift, TextMouth/Parsers/WordDocumentHTMLWriter.swift, TextMouth/Parsers/WordDocumentLegacyText.swift, TextMouth/Parsers/WordDocumentLegacyCodePages.swift, TextMouth/Parsers/WordDocumentLegacySprm.swift, TextMouth/Parsers/WordDocumentLegacyNumbering.swift, TextMouth/Parsers/WordDocumentFonts.swift, TextMouth/Parsers/WordSymbolFontEncodings.swift, TextMouth/Parsers/AdobeSymbolEncoding.swift -->

The Word 6 and Word 95 layout (0.4.1; the same reader, `WordFileInformationBlock.layout == .legacy`): no published description of it exists, so it was worked out from 312 real government files and Apache POI's and LibreOffice's samples, which textutil also read.
TestData/format-samples/doc6 holds 16 of them; the 312 US government files used for the comparison are not in the repository.
[MS-DOC] is evidence only where the samples agreed with it (its Prm0 table disagrees at sprms 12, 15, 80, and 81).
It differs from Word 97's in these steps:

1. The FIB (readLegacy) holds the flags at 10, the language at 6, the character set at 0x14, the first and the end of the text at 0x18 and 0x1C, the lengths of the stories from 0x34, and the structures' offsets and sizes from 0x58.
   There is no table stream: the structures lie in the WordDocument stream, and the text between the two offsets is one range, or, for a document saved with Fast Save, in pieces of a piece table of plain offsets.
2. WordLegacyCharacters reads the text one byte a character in a code page, or two (fExtChar: the Far East editions and files saved with them; a 16-bit unit with a zero above a Latin byte, or the lead byte of a double-byte character above its trail byte).
   WordLegacyCodePages chooses the code page for each run of one-byte text, in this order:
   - text in the Symbol font is the Adobe Symbol encoding;
   - the run's own mark (sprmCChse, 256 for Macintosh, else the FIB's mark for a Macintosh document);
   - the character set of the run's font (direct, character style, paragraph style, sheet default);
   - an explicit Windows mark in a Macintosh document; and
   - the document's default, the non-Western code page whose fonts hold over half of the characters above 0x7F, else the language's.
   A double-byte document's code page is the document's.
   One sweep over the run boundaries with a cursor keeps the cost linear.
3. WordLegacySprm turns the properties into Word 97's sprms (translation) so the readers of properties, styles, and sections are one for both.
   A property modifier is one opcode byte and an operand whose size the opcode gives, so a table of sizes (fixedSizes, a size byte first for the sprms whose operand varies, a 16-bit size for sprmTDefTable) is how a list is walked.
   It holds only established sizes, and an opcode it does not hold ends the walk of that list, which costs a toggle at worst.
   The sizes of 22 sprms and the section sprms 142, 147, and 164 to 169 were confirmed by walking every list in the real files to its exact end; italic (86), hidden (92), and deleted (65) rest on the fixed offset from Word 97's order alone.

### The Word 6 and Word 95 layout's numbering, bin tables, and switch
<!-- id: word-6-numbering-bin-tables; keys: ANLD, sprmPAnld, include previous, bin table, Fast Save, hostile files, comparison with textutil, speaksListNumbers; src: TextMouth/Parsers/WordDocumentLegacyNumbering.swift, TextMouth/Parsers/WordDocumentLists.swift, TextMouth/Parsers/WordDocumentProperties.swift, TextMouth/Parsers/WordDocumentSections.swift, TextMouth/Parsers/WordDocumentNotes.swift, TextMouth/Parsers/WordDocumentReader.swift -->

4. Numbering has no list tables.
   A numbered paragraph carries an ANLD of 52 bytes (sprmPAnld) and a level (sprmPNLvlAnm: 1 to 9 an outline, 10 a simple list, 11 a bullet), from the paragraph or else its style.
   WordLegacyNumbering turns them into the list tables Word 97 has, so the same counter and the same switch (speaksListNumbers) apply.
   The outline levels are one list for the document.
   A level whose ANLD says "include previous" (fPrev) writes the number of the level above first.
   A simple list or bullet is a list for each different ANLD and begins again after a paragraph of ordinary text.
   A simple list stands in for a missing first outline level only within the same run of numbered paragraphs.
   A paragraph with an ANLD and no level is not numbered.
   The numbering a style carries is not followed.
5. Bin tables (the pages of formatting) are read page by page, each page's count checked, and pages that follow the last the table lists are read from the counts at 0x18E and 0x190, in a file saved without Fast Save; a Fast Save file's formatting comes from the pieces' own Prm0 and Prm1.
   A style sheet, bin table, or section table that does not fit loses its formatting, not the document.
   Footnotes (table offsets 0x68 and 0x70, confirmed by 26 real files), endnotes, and text boxes are read as in Word 97, each as one range after the main text; no real file has endnotes.
   Cancellation is asked at the start, between pages of formatting, and in the main loop, for both layouts.
   A Word 1 or Word 2 document is a bare stream, not a compound file, and is refused as unreadable; a compound file older than Word 6 goes to textutil.
6. The switch to this reader on the Mac was justified by a comparison with textutil of 312 real files:
   - the same words in 108; the others differ by textutil's field instructions, joined cells, and upper-cased text, and by no-break spaces and U+2011 where this reader writes a space and a hyphen,
   - the same headings but for a guess it does not make in a table or a list (and 2,044 headings in documents with styles of their own), and
   - the same pages but for a continuous section break.
   Five files read better (Russian, Korean, and Chinese code pages, one that textutil read as nothing).
   Hostile files (truncated, every FIB field at its extremes, byte flips, a loop of 3,000 styles, 65,535 declared bin pages) read or throw in well under a second, but for bins-20000.doc, which takes 2.5 to 3.9 seconds and about 1 GB.

### Symbols
<!-- id: symbols; keys: Insert Symbol, special character, dingbats, font encoding, private use area, Greek letters, bullet glyph, WP fonts; src: TextMouth/Parsers/WordDocumentFonts.swift, TextMouth/Parsers/WordDocumentHTMLWriter.swift, TextMouth/Parsers/WordSymbolFontEncodings.swift, TextMouth/Parsers/AdobeSymbolEncoding.swift, TextMouth/Parsers/WordDocumentStructure.swift, TextMouth/Parsers/WordDocumentProperties.swift, TextMouth/Parsers/WordDocumentLegacySprm.swift -->

Symbols (0.4.1, both layouts): a symbol is stored as the text "(" with sprmCSymbol (74 in Word 6 and Word 95, 0x6A09 in Word 97), which names the font and the code.
WordHTMLWriter.symbol(replacing:in:paragraph:) replaces the "(" with the character WordFontTable.symbolScalar(forCode:inFont:isPrivateUse:) gives, or a space where it gives none, so the words on either side do not run together.
WordFontTable (WordDocumentFonts.swift) reads the font table once for both layouts (SttbfFfn: the name and character set of each font, every size checked).
WordSymbolFontEncodings.reading(ofFontNamed:characterSet:) says how a font's codes are read:
- .adobeSymbol for Symbol, MT Symbol, and SymbolPS (AdobeSymbolEncoding holds the whole Adobe table; code 190 is U+2014, as real files use it between two words);
- .table for WP TypographicSymbols (0x3D U+2019, 0x3E U+2018, 0x41 U+201C, 0x40 U+201D, 0x24 U+2022, 0x27 U+00A7, 0x29 U+00BF, 0x43 U+2014), WP MathA (0x45 U+00B0, 0x43 U+2022, 0x46 U+00B5), and WP Greek Courier and Century (0x3A U+00B5).
  Each code settled from the real text around it (a letter on both sides is an apostrophe; a code that opens and one that closes a quotation are the two quotation marks) and a code with no such reading left out;
- .pictures for Wingdings, Webdings, Zapf Dingbats, Monotype Sorts, any other font whose name begins "WP ", and any font of character set 2; and
- .text, the character of the font's own code page, for any other font.

Word 97 stores text typed in a symbol font as U+F020 to U+F0FF (its code plus 0xF000).
The same function reads it through the run's font (sprmCRgFtc0, then the character style, the paragraph style, and the sheet default; 1,638 such characters in 47 files showed sprmCRgFtc0 and sprmCRgFtc2 name the same font).
In an ordinary text font it is read through the Symbol table (isPrivateUse), as textutil reads it.
That rule costs a checkbox set in Arial, which reads as theta, and buys mu and pi typed in an ordinary font (a measure: of 134 such characters in 11 real documents about half are maths); 78 words in 10 files still differ from textutil's reading, none a regression against a "(".
A paragraph of only a picture symbol is no longer written; a bullet character at a paragraph's start, from a symbol, makes a list item (bulletItem needs a first character in textutil's set and a following space; only U+2022 is ever one).

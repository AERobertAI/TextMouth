# Imports: DOCX, OpenDocument, and Word 2003 XML
<!-- id: imports-docx-opendocument-word-2003; keys: DOCX, .docx, ODT, .odt, OpenDocument, Word 2003 XML, wordml, Office XML; src:  -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## The DOCX reader's reading policy
<!-- id: docx-reader-reading-policy; keys: .docx, Word 2007, hidden text, Wingdings, footnotes, track changes, text box, list numbering; src: TextMouth/Parsers/DOCXParser.swift, TextMouth/Parsers/DOCXParser+Converter.swift, TextMouth/Parsers/DOCXParser+Styles.swift, TextMouth/Parsers/DOCXParser+Numbering.swift, TextMouth/Parsers/DOCXParser+SAXParser.swift, TextMouth/Parsers/MarkdownEmphasis.swift, TextMouth/Parsers/WordSymbolFontEncodings.swift, TextMouth/Parsers/WordDocumentFonts.swift, TextMouth/Parsers/WordDocumentLists.swift, TextMouth/Parsers/OwnDocumentReaders.swift -->

The DOCX reader's reading policy (0.4.0; DOCXParser and its extensions, which turn a Word document into Markdown directly, not through the HTML of OwnDocumentReaders).
The converter holds a paragraph's state in one struct (ParagraphState) and gathers a paragraph's runs as raw text with a style for each scalar, a stretch at a time (StyledLine), writing emphasis through MarkdownEmphasis so that no mark is spoken.
A page break, a line break, or a link ends a stretch, and strikethrough is written plain.
A run's text is split at its line feeds by `String.splitAtLineFeeds()`, which finds none with one `memchr` and gives the run whole.
`ParserUtilities.stripNamespacePrefix(_:)` cuts an ASCII element name at its last colon byte, and gives any other name to Foundation (see [Shared helpers: readers and markup guards](../shared-helpers-parsers.md)).

- Hidden text: w:vanish is resolved by DOCXHiding.isHidden(documentDefaults:table:paragraph:character:direct:) (0.4.1; DOCXParser+Styles) from five levels, each keeping its stated value (true, or false for a w:val of 0):
  - the document defaults (w:docDefaults),
  - the table's style (a w:tblStyle, or the default table style, w:default="1", for a table that names none; a nested table takes its own style, not the outer one's; a w:tblStyle inside w:tblPrChange is ignored),
  - the paragraph style,
  - the run's w:rStyle (each through w:basedOn, the nearest winning; a style based on a style of another kind takes nothing from it), and
  - the run's own w:vanish, which decides alone.

  When the defaults say true, a level with no value takes true, and the text is hidden if and only if an even number of the table, paragraph, and character levels are false (MS-OI29500 17.7.3(a) and (b)).
  Otherwise the state starts false and a table style, then a paragraph style, reset it to what they state (MS-OI29500 17.7.6(b) and 17.7.8(a)), and a character style that says true toggles it.
  The 243 combinations were checked against a table built from the clauses by a separate script.
  A row marked w:trPr/w:hidden hides nothing of its own (the hidden row rule of DOCXHiding, citing §17.4.20, not checked in Word).
  The default paragraph style is used for a paragraph naming none.
  A table style's conditional formatting (w:tblStylePr, wholeTable included) is not applied, which nobody has checked against Word. w:webHidden is read; w:specVanish and a paragraph mark's w:vanish hide nothing; a vanish inside w:rPrChange or a table style's conditional formatting is ignored.
  A hidden run adds no text, tab, break, page, or heading words, and a w:pageBreakBefore waits for a run that is read.
### Symbols, notes, text boxes, and cancellation
<!-- id: docx-symbols-notes-boxes; keys: w:sym, tracked changes, footnotes, endnotes, text box, Cancel, DOCXSAXParser, o:gfxdata; src: TextMouth/Parsers/DOCXParser.swift, TextMouth/Parsers/DOCXParser+Converter.swift, TextMouth/Parsers/DOCXParser+Styles.swift, TextMouth/Parsers/DOCXParser+Numbering.swift, TextMouth/Parsers/DOCXParser+SAXParser.swift, TextMouth/Parsers/WordSymbolFontEncodings.swift, TextMouth/Parsers/WordDocumentFonts.swift -->

- Symbols (0.4.2): a w:sym (w:font, w:char) and w:t text at U+F020 to U+F0FF are read through WordXMLFonts (Parsers/WordSymbolFontEncodings.swift), which turns a font name, a character set, and a code into a character.
  It calls WordSymbolFontEncodings.scalar(forCode:inFontNamed:characterSet:isPrivateUse:), the one table the Word 97 reader's WordFontTable.symbolScalar also calls, so there is no second table.
  A run's font is DOCXStyles.fontName:
  - the run's w:rFonts (w:ascii, else w:hAnsi), else
  - its character style's, else
  - its paragraph style's (the default paragraph style's when it names none), else
  - the document defaults'.

  Each goes through w:basedOn within one kind of style, stopping on a loop.
  The part word/fontTable.xml is read for each font's w:charset (2 is a font of pictures).
  Its parseFontTable catches every error but ImportCancelled, so a missing, damaged, or refused part loses only the character sets.
  A w:char is up to four hexadecimal digits and nothing else (a sign once reached Unicode.Scalar and would have trapped); anything else, and a code no table settles, is a space.
  A hidden, deleted, or moved-from run's symbol is not read, and the first run of a note in the reference style (its custom mark) is skipped.
  Not done: a table style's font, a theme-only font, w:cs and w:eastAsia fonts.
- Tracked changes: the w:t of a w:del and everything in w:moveFrom are not read; inserted and moved-to text is.
- Notes: footnotes.xml then endnotes.xml go through the same converter (readsNotes) after the body, skipping the separator, continuationSeparator, and continuationNotice entries, and only the notes that DOCXNoteReferences records for a reference the converter read, in the file's order.
  Both w:customMarkFollows and a note's first run in a reference style are the mark and are not read.
  A damaged, empty, or oversized notes part is reported through reportIncompleteContent and the body is read; one damaged before any text throws malformedXML naming the part.
  A hyperlink in a note keeps its label only.
- Text boxes: an mc:AlternateContent reads the first mc:Choice whose Requires prefixes are all wps, wpg, or wpc, else the next, else the Fallback, so a box is read once.
  The outer paragraph, run, and link are set aside while w:txbxContent is read, and the box's words wait in a side buffer to be written right after the paragraph that holds the anchor.
  A box in an unread run is not read.
- Cancellation: before each part and every 1,024 elements (elementsBetweenCancellationChecks, so that Cancel waits under half a second at the worst case the guard allows, 62 MB of tags of 1,024 attributes each), ending the parse with abortParsing.
  Every part is parsed through DOCXSAXParser, which first takes the value out of every o:gfxdata attribute (DOCXPictureAttribute), since XMLParser stops at an attribute of more than 10 MB.
- DOCXListCounter (DOCXParser+Numbering.swift) has an additive accessor, startLevels(moreSignificantThan:numId:), that DOCX itself does not call and the Word 97-2003 reader does.

## OpenDocument text and Word 2003 XML readers
<!-- id: opendocument-text-word-2003-xml; keys: .odt, OpenDocument 1.3, .ott, Word 2003 XML, wordml, content.xml, office text reader, DOCTYPE refusal; src: TextMouth/Parsers/OfficeXMLReader.swift, TextMouth/Parsers/OfficeParagraph.swift, TextMouth/Parsers/OfficeBlockWriter.swift, TextMouth/Parsers/OfficeStyleChain.swift, TextMouth/Parsers/XMLInputGuard.swift, TextMouth/Parsers/PackageSAXParser.swift, TextMouth/Parsers/ODTXMLReader.swift, TextMouth/Parsers/ODTStyles.swift, TextMouth/Parsers/ODTContentReader.swift, TextMouth/Parsers/ODTDocumentReader.swift, TextMouth/Parsers/WordMLReader.swift, TextMouth/Parsers/WordMLStyles.swift, TextMouth/Parsers/WordMLDocumentReader.swift, TextMouth/Parsers/OwnDocumentReaders.swift, TextMouth/Parsers/RTFBlockBuilder.swift, TextMouth/Parsers/RTFDocumentModel.swift, TextMouth/Parsers/RTFHTMLWriter.swift, TextMouth/Parsers/RTFSizeHeadings.swift, TextMouth/Parsers/WordSymbolFontEncodings.swift, TextMouth/Parsers/DocumentByteLimit.swift, TextMouth/Parsers/TextutilSourceCheck.swift, TextMouth/Services/TextutilConverter.swift, TextMouth/Services/Export/XMLEscaping.swift -->

Own readers of OpenDocument text and Word 2003 XML (FMT27 and FMT53): ODTDocumentReader and WordMLDocumentReader write the HTML of OwnDocumentReaders from the specifications (OpenDocument 1.3; the Office 2003 XML Reference Schemas), with no other reader's code.
They share a base and a writer, and reuse the rich text reader's RTFBlockBuilder, RTFDocumentModel, RTFHTMLWriter, and RTFSizeHeadings unchanged, so a change to those four reaches both.

- The base: OfficeXMLReader drives XMLParser through PackageSAXParser, with:
  - names read by namespace (OfficeNameScope, which records only the prefixes an element changes),
  - a refusal of any document type declaration (XMLInputGuard.declaresDocumentType, which reads the prolog in UTF-8, UTF-16, and UTF-32, with or without a mark, and skips comments and processing instructions),
  - the refusals of XMLInputGuard.problem(with:) that PackageSAXParser.parseDocument makes for every part, each as Failure.unreadable(format) here (an internal subset, an encoding the guard cannot see through, and a start tag of more than 1,024 attributes),
  - a nesting limit of 200 elements,
  - skipSubtree(), fail(_:), and
  - the cancellation check (stopIfCancelled(), about 16 ns) at every start tag and every run of text the parser delivers, so a tag that costs the parser seconds is stopped between tags.

  [Shared helpers: readers and markup guards](../shared-helpers-parsers.md) says what each refusal is.
  XMLEscaping is one linear pass.
  OfficeStyleChain walks a style's based-on chain, cut at 64 styles, and a part with more than 100,000 styles is refused (checked where a style ends).
- The writer: OfficeBlockWriter and OfficeParagraph gather the words, pages, tables, and lists in reading order.
  A paragraph is held until it ends, so a hidden one is dropped whole.
  What is anchored in it (a text box's or shape's paragraphs and tables, a picture's description) and the notes whose references it holds wait with it, and are written right after it in file order, and not at all if the paragraph is hidden.
  OfficeFlow keeps the main text and each note apart.
  A repeated cell is read up to OfficeBlockWriter.mostRepeatedCells (16) times; lists are capped at 40 levels (their words still read); a table in a text box is written after its paragraph.
  A page cannot begin in a table or text box.
- ODTDocumentReader reads the ZIP with ZIPFoundation (each part held to DocumentByteLimit as it inflates and to the size the archive records; a part whose checksum is not the archive's is refused) and the parts
  - content.xml (ODTContentReader),
  - styles.xml (ODTStyles, for styles alone: headers and footers live there and are not read), and
  - meta.xml (the title and the author, dc:creator).

  A mimetype entry that is damaged, long, or junk is ignored; only the media type of another kind of document refuses.
  A damaged, cut, or oversized styles.xml or meta.xml is reported to a closure (the console and the debug log, tag ODT_DAMAGED_PART) and the body is read; only content.xml or the ZIP refuses.
  A package whose ZIP entries are encrypted is refused as `PasswordProtectedDocument`, or opened once unlocked ([Password-protected books](protected-books.md)); one encrypted by its own manifest is refused earlier (TextutilSourceCheck.isEncryptedOpenDocument).
  An empty file is noTextToRead, and a file, content.xml, or text past DocumentByteLimit is DocumentTooLargeError.
- ODT headings are text:h with text:outline-level, a paragraph whose style has style:default-outline-level, and the styles Title (1), Subtitle (2), and Heading (the base of Writer's headings) when the style names no outline level.
  The size guess (RTFSizeHeadings) runs only when the document names none.
  Text under text:tracked-changes is skipped, as are text:display="none", text:hidden-paragraph, text:hidden-text, a hidden text:section, comments, ruby text, and text:script. text:note bodies follow in file order if their paragraph is read.
  A picture, formula, or chart (draw:frame, draw:object) is its svg:desc, else svg:title, as a paragraph after the anchor's paragraph.
  Automatic numbers (text:number) are not words.
  Pages: a style's fo:break-before and fo:break-after, a master page named on a paragraph or table (a paragraph naming one breaks every time), and text:soft-page-break, labelled 1 to N; a soft break between letters adds no space, and one at the start of a paragraph begins a page.
### The Word 2003 XML reader
<!-- id: word-2003-xml-reader; keys: wordml, w:wordDocument, Word.Insertion, WordMLSectionScanner, hidden row, symbols; src: TextMouth/Parsers/WordMLReader.swift, TextMouth/Parsers/WordMLStyles.swift, TextMouth/Parsers/WordMLDocumentReader.swift, TextMouth/Parsers/WordSymbolFontEncodings.swift, TextMouth/Services/TextutilConverter.swift -->

- WordMLDocumentReader reads symbols (0.4.2) as the DOCX reader does, through WordXMLFonts, with w:h-ansi for w:hAnsi, a run's font taken as direct, else character style, else paragraph style, else w:docDefaults, and the character sets from the w:fonts of the head (w:charset).
  Its tests are the only proof for a symbol in a real Word 2003 XML file: none of the 2,244 documents compared held one.
- WordMLDocumentReader reads one XML file (w:wordDocument).
  Headings are the styles "heading 1" to "heading 9" (at most level 6), "title" (1), and "subtitle" (2), and outline levels read as values (0 to 8 is a heading, anything else body text, overriding a style).
  Hidden, bold, and italic are settled per run: the paragraph style XOR the character style unless the run says so, and w:val="off" turns it off.
  Word.Deletion annotations, w:delText, w:del, and w:moveFrom are not read, only Word.Insertion; comments and other annotations are skipped; w:txbxContent is read after its paragraph, and w:pict in a hidden run is skipped.
  A list by paragraph style is a list; a row marked w:trPr/w:hidden hides nothing of its own (the hidden row rule of DOCXHiding: ECMA-376 §17.4.20 says Word shows a row any part of which is visible, so the words in it are read unless their runs hide them).
  Pages: w:br of the page type, w:pageBreakBefore, and next-page sections (WordMLSectionScanner, a first pass).
- Refusals (TextutilConverter.Failure.unreadable(.odt) and (.wordml)): not a ZIP; a media type of another document; no content.xml; a part damaged, cut off, with a document type declaration, nested past 200 elements, or with more than 100,000 styles; a wordml with another root.

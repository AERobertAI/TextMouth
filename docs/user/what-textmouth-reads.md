# What TextMouth reads: EPUB and word-processor documents
<!-- id: reads-documents; keys: supported formats, file types, own readers, textutil, import; src: TextMouth/Models/Book.swift, TextMouth/Parsers/BookParser.swift, TextMouth/Parsers/OwnDocumentReaders.swift -->

Part of [TextMouth's documentation](../../README.md).
Every format TextMouth reads, with how well each is tested, is in [the list of formats](formats-list.md).

## EPUB files
<!-- id: epub-files; keys: ZIP member, letter case, XML entity, external entity, title author headings; src: TextMouth/Parsers/EPUBParser.swift, TextMouth/Parsers/ArchiveEntryReader.swift, TextMouth/Parsers/XMLInputGuard.swift -->

- A member the book names in another letter case than its ZIP spells it, as a badly made book may, is found all the same: the exact spelling is looked for first.
- An EPUB never brings in the text of a file on your Mac: an XML entity that names a file, which a crafted book could use to put one into its title, author, or headings, reads as nothing, and the book still reads.

## Word documents and Word templates
<!-- id: word-documents-word-templates; keys: .docx, .dotx, .docm, .dotm, macro, vbaProject.bin, Office Open XML; src: TextMouth/Parsers/DOCXParser.swift, TextMouth/Models/Book.swift -->

- This covers Word documents (.docx) and Word templates and macro documents (.dotx, .docm, .dotm), which are read the same way and listed as Word documents.
- No part of a macro project is read, and no macro ever runs.

## Rich text, Word 6 to Word 2003, OpenDocument text, and Word 2003 XML
<!-- id: rich-text-word-6-word; keys: RTF, RTFD, .doc, .odt, WordML, TXT.rtf, re-read, launch; src: TextMouth/Parsers/OwnDocumentReaders.swift, TextMouth/Parsers/RTFDocumentReader.swift, TextMouth/Parsers/WordDocumentReader.swift, TextMouth/Parsers/ODTDocumentReader.swift, TextMouth/Parsers/WordMLDocumentReader.swift, TextMouth/Models/PageReaderVersions.swift; status: incomplete; issues: DR17 -->

- Rich text (.rtf), rich text with attachments (.rtfd), Word 6 to Word 2003 documents and templates (.doc, .dot), OpenDocument text and its templates (.odt, .ott), and Word 2003 XML (.xml, see [XML files](reads-daisy-and-braille.md)), which TextMouth reads with code of its own.
  TextMouth reads them the same on the Mac as on iOS, where Apple's textutil tool does not exist.
- Word 6 and Word 95 documents, which textutil read on the Mac until version 0.4.1, are described below.
- Each becomes a text book like any other, so it reopens, searches, and keeps its place, bookmarks, and skipped headings.
- An .rtfd is a package that the Finder shows as one file, and it imports as one book: TextMouth reads the text file in it, TXT.rtf, and leaves its attachments alone.
- No helper process runs.
- A rich text or Word 97-2003 book already in your library was read again once, at the first launch of version 0.3.1, so that it gained its headings and pages.
- Every rich text, rich text with attachments, Word 97-2003, Word, OpenDocument text, and Word 2003 XML book is read again once more, at the first launch of version 0.4.0, for what the readers now find.
  See What every document reader reads, below, [Pages](reads-pages-and-limits.md), and [Where TextMouth keeps your library](book-packages.md).
  Your place follows its words, and text you changed with Edit Text is kept as it is.
- At the first launch of version 0.4.1 every .doc book is read again once more, for Word 6 and Word 95 documents and for symbols, and every .docx and .wordml book once more, for hidden text, in the same way.
- At the first launch of version 0.4.2 every .docx and .wordml book is read again once more, for the symbols they now read (see Other limits of each, below), in the same way.

### How headings are found
<!-- id: how-headings-are-found; keys: heading style, outline level, outlineLvl, Title, Subtitle, based on; src: TextMouth/Parsers/RTFStyleSheet.swift, TextMouth/Parsers/WordDocumentStyles.swift, TextMouth/Parsers/ODTStyles.swift, TextMouth/Parsers/WordMLStyles.swift, TextMouth/Parsers/DOCXParser+Styles.swift -->

- Headings are the document's own:
  - In rich text, a paragraph in a style named "heading 1" to "heading 9" (in any capitals), "Title" (level 1), or "Subtitle" (level 2), or with an outline level of 1 to 9, is a heading.
  - In a Word 97-2003 document, a heading is a paragraph in the built-in styles Heading 1 to Heading 9, Title, or Subtitle, or with an outline level of 1 to 9.
  - In OpenDocument text, a heading is one the document marks as one with its outline level, a paragraph whose style gives an outline level, or a paragraph in the style Title (level 1), Subtitle (level 2), or Heading, which Writer's headings and titles are based on.
  - In Word 2003 XML, a heading is a paragraph in a style named "heading 1" to "heading 9", "Title" (level 1), or "Subtitle" (level 2), or with an outline level.
- In all four, a style that says nothing takes what the style it is based on says, and an outline level, in the paragraph or in its style, wins over a style's name.
- An outline level that says body text makes the paragraph none, even in a style based on a heading.
- Levels deeper than 6 are level 6.
- A heading carries no emphasis, since its style makes the whole line bold.
- The document's own headings are all you hear as headings.
  A heading that a document gives only by direct formatting, such as a bold line of large letters in the normal style, is a heading only in a document that names none.

### Headings guessed from font size and bold
<!-- id: headings-guessed-from-font-size; keys: font size, bold, heading guess, body size, RTFSizeHeadings; src: TextMouth/Parsers/RTFSizeHeadings.swift, TextMouth/Parsers/WordDocumentHeadingGuess.swift, TextMouth/Parsers/OfficeBlockWriter.swift -->

- A document that names no heading by a style or an outline level has its headings guessed from font sizes and bold, in all four of these formats.
- The body size is the commonest size, counted by characters.
- A paragraph of 1 to 120 characters, not a single letter, that is larger than the body is a heading, and so is one that is bold throughout at the body's size, unless more than half of the body is bold.
- A heading's level comes from its size's rank, the largest size being level 1, in at most six levels, and a heading found from bold follows the larger sizes.
- Text in a table or a list is never a heading.
- A document that names even one heading keeps exactly the headings it names.

### Emphasis, lists, tables, pictures, and fields
<!-- id: emphasis-lists-tables-pictures-fields; keys: bold, italic, bullet, numbering, field result, HYPERLINK, TOC; src: TextMouth/Parsers/RTFBlockBuilder.swift, TextMouth/Parsers/RTFListTable.swift, TextMouth/Parsers/WordDocumentLists.swift, TextMouth/Parsers/WordDocumentHTMLWriter.swift; status: incomplete; issues: DR35 -->

- Bold and italic text keeps its emphasis, as in the other text formats, and the marks that show it are never spoken.
- A list is a list, and the number or bullet it shows is not read as one of its words.
- In rich text, a paragraph in a list, or one that begins with a bullet and a tab, is an item, numbered or bulleted as the list says.
- In a Word 97-2003 document, a paragraph that begins with a bullet character and a space is a bulleted item (a dash or an asterisk counts only before a tab).
  A paragraph that Word numbers or bullets through its own list definitions is a real list item too, numbered or bulleted as the list says, with its number in the book's stored text, so an export shows it.
- As in every format, the number is not read aloud, and a numbered heading reads its words alone.
- Whether Word 97-2003 numbers should be read aloud is a question for you that is still open.
- A table is a table, read a row at a time (see [Tables](reads-pages-and-limits.md)).
  In a nested table, the words stay in the cell around it.
- Pictures and embedded objects are silent, except in OpenDocument text, where a picture, formula, or chart is read as its description (see What every document reader reads, below).
- A field is read for its result, as Word shows it, and never for its instruction: the result of a table of contents or a link is read, and its code (TOC, HYPERLINK, PAGE, MERGEFORMAT) is not.

### What every document reader reads
<!-- id: what-every-document-reader-reads; keys: hidden text, vanish, tracked changes, footnotes, text box, comments; src: TextMouth/Parsers/DOCXParser+Converter.swift, TextMouth/Parsers/DOCXParser+Styles.swift, TextMouth/Parsers/WordDocumentNotes.swift, TextMouth/Parsers/ODTContentReader.swift, TextMouth/Parsers/WordMLReader.swift; status: incomplete; issues: DR15, DR16, DR35 -->

Rich text, Word 97-2003, Word, OpenDocument text, and Word 2003 XML documents follow one policy: TextMouth reads what a person reading the document sees in its ordinary view, in reading order.

- Hidden text is not read.
- Text that is hidden only on the web is read, since it shows in print and in the normal view.
- A hidden paragraph mark alone joins nothing: the paragraphs stay separate, so a heading run into its paragraph stays a heading.
- In a Word document (.docx), whether text is hidden follows Word's rule for a property that styles toggle, from Microsoft's and ECMA's documents and not from trying Word.
  The run's own setting decides alone.
  Otherwise the document defaults, a table style, a paragraph style, and a character style are settled together, a table style and a paragraph style resetting the state to what they say and a character style toggling it, so a hiding character style inside a hiding paragraph style shows its text.
- A table style's conditional formatting (its first row, say) is not applied.
- A row marked hidden hides nothing of its own, in a .docx or in Word 2003 XML: Word shows a row that has any visible part, so the words in it are read unless their own formatting hides them.
- A paragraph whose every word is hidden is no paragraph and no heading, and a page break inside hidden text begins no page.
- A tracked deletion is not read, and a tracked insertion is.
  Text a tracked change moved is read once, in its new place.
- Footnotes and endnotes follow the main text, in the order the file keeps them, with no invented heading and without their reference marks, a custom mark included.
- In a Word 97-2003 document the symbol an author typed in place of a number is read, since the file does not say how long it is.
- A note is read only if a person would see its reference: a note whose reference is hidden or deleted is left out.
- Comments, headers, and footers are not read.
- A text box, or a shape that holds text, is read.
- Word, Word 2003 XML, OpenDocument text, and rich text read a box right after the paragraph that holds its anchor, so a sentence stays whole around it.
- A Word 97-2003 document keeps its text boxes in a story of their own, and they are read after the notes.
- A Word text box that the file writes twice, once for newer programs and once for older, is read once.
- A field's instruction, such as TOC, HYPERLINK, PAGE, or MERGEFORMAT, is never read, and a field's result is.
- Pictures are silent in Word and rich text documents.
  In OpenDocument text, a picture, formula, or chart is read as its description (its title, if it has no description), as a paragraph right after the paragraph that holds it, and nothing if it has neither.
- The marks that show bold, italic, and strikethrough are never spoken.

### Other limits of each
<!-- id: other-limits-each; keys: symbol font, w:sym, Wingdings, Symbol encoding, fontTable, .fodt, .sxw; src: TextMouth/Parsers/WordSymbolFontEncodings.swift, TextMouth/Parsers/AdobeSymbolEncoding.swift, TextMouth/Parsers/WordDocumentFonts.swift, TextMouth/Parsers/DOCXParser+Converter.swift, TextMouth/Parsers/ODTDocumentReader.swift; status: incomplete; issues: DR20 -->

- In rich text, the title and author come from the document's own information group.
- In Word 97-2003, a document whose main text holds no words at all, such as one whose text is all in a text box or a header, is read from every part of it after the main text, in the order the file keeps them, so it is not an empty book.
  Its title and author come from the document's summary information.
  Word's fast-saved formatting, which a document that was saved quickly keeps in its pieces, is read.
- Symbols, in Word 6, Word 95, and Word 97-2003 documents, are read by their font, since the file stores a symbol as an opening parenthesis with the font and the code of the character it shows:
  - In the font Symbol (and MT Symbol and SymbolPS) the code is the Adobe Symbol encoding, so Greek letters, mathematical signs, and bullets read as themselves.
  - In WordPerfect's WP TypographicSymbols the codes read as the curly quotation marks, bullet, section sign, inverted question mark, and em dash.
  - In WP MathA they read as the degree sign, bullet, and micro sign, and in WP Greek Courier and Century as the micro sign.
  - Real documents settled these codes one by one.
  - In a picture font (Wingdings, Webdings, Zapf Dingbats, Monotype Sorts, any other WordPerfect font, or any font of the symbol character set), or for a code no table settles, a symbol reads as a space, so the words on either side do not run together.
  - In an ordinary text font, a symbol reads as the character of its code page.
- Text typed in a symbol font, which Word 97 stores as a private-use character, is read the same way.
  In an ordinary text font it is read through the Symbol table as textutil read it, so a letter that stands for mu or pi reads as one, and a checkbox set in Arial reads as a Greek theta.
- A bullet made by a symbol, at a paragraph's start, makes the paragraph a list item, and a paragraph of only a picture symbol, such as a checkbox, is not written.
- Symbols in Word documents (.docx) and Word 2003 XML are read from version 0.4.2, by the same rules:
  - A symbol is a w:sym element, which names a font and a character code.
    It reads as the character that font shows for the code.
  - The font of a run is the run's own, else its character style's, else its paragraph style's, else the document defaults'.
    Each style is followed through the style it is based on.
  - A .docx also reads word/fontTable.xml, which says which fonts hold pictures.
    If that part is missing or damaged, only that knowledge is lost and the book is still read.
  - Text typed in a symbol font, stored as a private-use character, is read through the font in the same way.
    When no font is named anywhere, such characters stay as they are.
  - A symbol in a hidden run, or in a deleted or moved-from run, is not read.
    A symbol in a footnote is read, except in a note's custom mark.
  - A code that is not four hexadecimal digits, or that no table settles, reads as a space.
  - Not read: a font a table style names, a font a theme names alone, and the complex-script and East Asian fonts of a run.
- In OpenDocument text, flat .fodt files and OpenOffice 1.x .sxw files are not read.
- In OpenDocument text, hyperlink addresses are not read, only the links' words.
- In OpenDocument text, a merged table cell leaves no cell of its own.
- In OpenDocument text, the title and author come from the document's own information, so an .odt's author is read.
- A damaged styles or information part loses only itself, and the body is read.
  Only the content part, or the ZIP, makes the document unreadable.

### Code pages of rich text
<!-- id: code-pages-rich-text; keys: ansicpg, Mac Roman, code page 437, code page 850, Shift-JIS, double-byte; src: TextMouth/Parsers/RTFEncodings.swift, TextMouth/Parsers/RTFInterpreter.swift, TextMouth/Parsers/RTFDocumentReader.swift -->

- Rich text is read in the code page the file names: Windows-1252 for \ansi, Mac Roman for \mac, code page 437 for \pc and 850 for \pca, any other that \ansicpg gives, and the code page of a font's character set for the text set in that font.
- A character that takes two bytes, as in Shift-JIS (Japanese), GBK (Simplified Chinese), Big5 (Traditional Chinese), and Korean, is read whole, and Unicode characters written \u are read as themselves.
- A byte that is not valid in its code page is read as Windows-1252, so no word is lost.
- A file that begins {\rtf with no version number, which textutil refused, is read.

### The content decides, not the extension
<!-- id: content-decides-not-extension; keys: sniffing, wrong extension, Save as RTF, .doc is HTML, XMLDocumentSniffer; src: TextMouth/Parsers/TextutilSourceCheck.swift, TextMouth/Parsers/XMLDocumentSniffer.swift, TextMouth/Parsers/OwnDocumentReaders.swift -->

- A file whose content is rich text is read as rich text whatever its name, so a .doc that Word saved with "Save as RTF" is read as rich text.
- A .doc that is really a web page is read as what it is, by TextMouth's own HTML reader.
- A .doc that is really Word 2003 XML is read as that, by TextMouth's own Word 2003 XML reader.
- A file named .rtf or .doc that is none of these is refused (see [Adding books](import-progress-and-errors.md)).

## Word 6 and Word 95 documents
<!-- id: word-6-word-95-documents; keys: .doc, .dot, WinWord 6, compound file, own reader, textutil; src: TextMouth/Parsers/WordDocumentReader.swift, TextMouth/Parsers/WordDocumentStructure.swift, TextMouth/Parsers/CompoundFile.swift, TextMouth/Parsers/WordDocumentLegacyText.swift -->

- TextMouth reads Word 6 and Word 95 documents (.doc and .dot) with code of its own since version 0.4.1, the same on the Mac as on iOS, as it reads a Word 97-2003 one.
- The format has no published description, so the layout was worked out from real files.
- A document older than Word 6 is the only Word document left to textutil, below.
- TextMouth tells a Word 6 or Word 95 document from a Word 97-2003 one by the file's own bytes, not its name.
- Each becomes a text book like any other, so it reopens, searches, and keeps its place, bookmarks, and skipped headings.
- No helper process runs.

### Word 6 and Word 95 headings
<!-- id: word-6-word-95-headings; keys: heading styles, outline levels, font size guess; src: TextMouth/Parsers/WordDocumentStyles.swift, TextMouth/Parsers/WordDocumentHeadingGuess.swift -->

- Headings are the document's own heading styles (Heading 1 to 9, Title, Subtitle, and outline levels), and a document that names even one keeps exactly the headings it names.
- A document that names none gets its headings guessed from font sizes and bold, as in the other Word formats.
- Text in a table or a list is never a heading, so a few documents have fewer headings than textutil guessed.

### Word 6 and Word 95 text and code pages
<!-- id: word-6-word-95-text; keys: code page, Cyrillic, Greek, Central European, double-byte, Far East, Symbol font; src: TextMouth/Parsers/WordDocumentLegacyCodePages.swift, TextMouth/Parsers/WordDocumentLegacyText.swift -->

- The text is read in the code page of each run, in this order:
  - The run's own mark (Macintosh text in a Windows document, and the reverse).
  - The character set of the run's font (a Cyrillic, Greek, or Central European font).
  - The document's default, which is the foreign code page whose fonts hold over half the accented characters, else the language's.
- Far East documents are read as double-byte text, a document at a time.
- Text in the Symbol font is read as Greek letters and mathematical signs.

### Word 6 and Word 95 emphasis, notes, tables, and lists
<!-- id: word-6-word-95-emphasis; keys: bold, italic, hidden text, tracked deletion, footnote, list numbering; src: TextMouth/Parsers/WordDocumentNotes.swift, TextMouth/Parsers/WordDocumentLegacyNumbering.swift, TextMouth/Parsers/WordDocumentLists.swift, TextMouth/Parsers/WordDocumentLegacySprm.swift; status: incomplete; issues: DR21 -->

- Bold and italic keep their emphasis and the marks that show it are never spoken.
- Hidden text and tracked deletions are not read, and a note is read only if its reference is shown.
- Footnotes, endnotes, and text boxes follow the main text.
- A table is a table.
- A paragraph that Word numbers or bullets is a real list item, with its number silent.
- A numbering that a style carries is not followed, so a numbered heading reads without its number.
- A field's result is read and its instruction never.

### What Word 6 and Word 95 reading leaves out
<!-- id: what-word-6-word-95; keys: headers, footers, comments, pictures, Wingdings, custom note mark; src: TextMouth/Parsers/WordDocumentLegacyText.swift, TextMouth/Parsers/WordDocumentNotes.swift, TextMouth/Parsers/WordDocumentFonts.swift; status: incomplete; issues: DR35 -->

- Headers, footers, comments, and pictures are not read.
- Text typed in Wingdings reads as the letters of its bytes.
- A custom note mark (an asterisk, say) is read as typed.

### Word 1 and Word 2 documents
<!-- id: word-1-word-2-documents; keys: WinWord 1, WinWord 2, refused, not a compound file, unreadable; src: TextMouth/Parsers/WordDocumentReader.swift, TextMouth/Parsers/OwnDocumentReaders.swift -->

- Word 1 and Word 2 documents are not compound files, and are refused at once with the unreadable sentence of a Word document (see [Adding books](import-progress-and-errors.md)).

### Word 6 and Word 95 file type
<!-- id: word-6-word-95-file; keys: file type, bytes, not the name, Word 97-2003; src: TextMouth/Parsers/WordDocumentStructure.swift, TextMouth/Parsers/TextutilSourceCheck.swift -->

- The content decides, not the extension, as for a Word 97-2003 document.

## Documents that Apple's textutil tool still reads
<!-- id: documents-that-apple-textutil-tool; keys: textutil, older than Word 6, Word 2, Mac only, iOS refusal; src: TextMouth/Parsers/TextutilDocumentReader.swift, TextMouth/Services/TextutilConverter.swift, TextMouth/Parsers/TextutilSourceCheck.swift -->

- On the Mac only, textutil reads a compound-file Word document older than Word 6, which TextMouth's reader does not know the layout of.
- On iOS such a document is refused, since iOS runs no helper program (see [Adding books](import-progress-and-errors.md)).

### How textutil is run
<!-- id: how-textutil-run; keys: separate process, WatchedProcess, timeout, cancel, second run, page breaks; src: TextMouth/Services/TextutilConverter.swift, TextMouth/Platform/macOS/Services/WatchedProcess.swift, TextMouth/Parsers/TextutilPageBreaks.swift -->

- textutil runs in a separate process that TextMouth watches, never inside TextMouth, so a hang or a crash in Apple's readers costs that process and never TextMouth or the import.
- It loads nothing that the document links to and fetches nothing from the network.
- It converts the document once for each import, and the book's title and author come from that same run.
  A second run reads the page breaks (see [Pages](reads-pages-and-limits.md)).
- Cancel in the import overlay stops it at once (see [Adding books](import-progress-and-errors.md)).
- [Where TextMouth keeps your library](helper-programs.md) gives the limits of time, memory, and processor time at which TextMouth stops it, where it writes, and what stops one that a crash left behind.

### Headings in a document textutil reads
<!-- id: headings-document-textutil-reads; keys: font size, bold, heading guess, textutil HTML; src: TextMouth/Parsers/TextutilHTMLStructure.swift, TextMouth/Parsers/TextutilDocumentReader.swift -->

- Headings in such a document are found from font sizes and bold, since textutil writes every heading as an ordinary paragraph.
- The body size is the commonest size, counted by characters.
- A paragraph of at most 120 characters that is larger than the body is a heading, and so is one that is bold throughout at the body's size, unless more than half of the body is bold.
- A heading's level comes from its size's rank, the largest size being level 1, in at most six levels, and a heading found from bold follows the larger sizes.
- Text in a table or a list is never a heading.
- Bold and italic keep their emphasis, pictures are silent, and a field's instruction is never read.

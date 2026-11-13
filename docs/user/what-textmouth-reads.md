# What TextMouth reads

Part of [TextMouth's documentation](../../README.md).

## Text books, spoken with any system voice

### EPUB files

- A member the book names in another letter case than its ZIP spells it, as a badly made book may, is found all the same: the exact spelling is looked for first.
- An EPUB never brings in the text of a file on your Mac: an XML entity that names a file, which a crafted book could use to put one into its title, author, or headings, reads as nothing, and the book still reads.

### Word documents and Word templates

- This covers Word documents (.docx) and Word templates and macro documents (.dotx, .docm, .dotm), which are read the same way and listed as Word documents.
- No part of a macro project is read, and no macro ever runs.

### Rich text, Word 6 to Word 2003, OpenDocument text, and Word 2003 XML

- Rich text (.rtf), rich text with attachments (.rtfd), Word 6 to Word 2003 documents and templates (.doc, .dot), OpenDocument text and its templates (.odt, .ott), and Word 2003 XML (.xml, below), which TextMouth reads with code of its own, the same on the Mac as on iOS, where Apple's textutil tool does not exist.
- Word 6 and Word 95 documents, which textutil read on the Mac until version 0.4.1, are described below.
- Each becomes a text book like any other, so it reopens, searches, and keeps its place, bookmarks, and skipped headings.
- An .rtfd is a package that the Finder shows as one file, and it imports as one book: TextMouth reads the text file in it, TXT.rtf, and leaves its attachments alone.
- No helper process runs.
- A rich text or Word 97-2003 book already in your library was read again once, at the first launch of version 0.3.1, so that it gained its headings and pages.
- Every rich text, rich text with attachments, Word 97-2003, Word, OpenDocument text, and Word 2003 XML book is read again once more, at the first launch of version 0.4.0, for what the readers now find (see What every document reader reads, below, Pages, below, and [Where TextMouth keeps your library](where-your-library-lives.md)). Your place follows its words, and text you changed with Edit Text is kept as it is.
- At the first launch of version 0.4.1 every .doc book is read again once more, for Word 6 and Word 95 documents and for symbols, and every .docx and .wordml book once more, for hidden text, in the same way.
- At the first launch of version 0.4.2 every .docx and .wordml book is read again once more, for the symbols they now read (see Other limits of each, below), in the same way.

#### How headings are found

- Headings are the document's own:
  - In rich text, a paragraph in a style named "heading 1" to "heading 9" (in any capitals), "Title" (level 1), or "Subtitle" (level 2), or with an outline level of 1 to 9, is a heading.
  - In a Word 97-2003 document, a heading is a paragraph in the built-in styles Heading 1 to Heading 9, Title, or Subtitle, or with an outline level of 1 to 9.
  - In OpenDocument text, a heading is one the document marks as one with its outline level, a paragraph whose style gives an outline level, or a paragraph in the style Title (level 1), Subtitle (level 2), or Heading, which Writer's headings and titles are based on.
  - In Word 2003 XML, a heading is a paragraph in a style named "heading 1" to "heading 9", "Title" (level 1), or "Subtitle" (level 2), or with an outline level.
- In all four, a style that says nothing takes what the style it is based on says, and an outline level, in the paragraph or in its style, wins over a style's name.
- An outline level that says body text makes the paragraph none, even in a style based on a heading.
- Levels deeper than 6 are level 6.
- A heading carries no emphasis, since its style makes the whole line bold.
- The document's own headings are all you hear as headings. A heading that a document gives only by direct formatting, such as a bold line of large letters in the normal style, is a heading only in a document that names none.

#### Headings guessed from font size and bold

- A document that names no heading by a style or an outline level has its headings guessed from font sizes and bold, in all four of these formats.
- The body size is the commonest size, counted by characters.
- A paragraph of 1 to 120 characters, not a single letter, that is larger than the body is a heading, and so is one that is bold throughout at the body's size, unless more than half of the body is bold.
- A heading's level comes from its size's rank, the largest size being level 1, in at most six levels, and a heading found from bold follows the larger sizes.
- Text in a table or a list is never a heading.
- A document that names even one heading keeps exactly the headings it names.

#### Emphasis, lists, tables, pictures, and fields

- Bold and italic text keeps its emphasis, as in the other text formats, and the marks that show it are never spoken.
- A list is a list, and the number or bullet it shows is not read as one of its words.
- In rich text, a paragraph in a list, or one that begins with a bullet and a tab, is an item, numbered or bulleted as the list says.
- In a Word 97-2003 document, a paragraph that begins with a bullet character and a space is a bulleted item (a dash or an asterisk counts only before a tab). A paragraph that Word numbers or bullets through its own list definitions is a real list item too, numbered or bulleted as the list says, with its number in the book's stored text, so an export shows it.
- As in every format, the number is not read aloud, and a numbered heading reads its words alone.
- Whether Word 97-2003 numbers should be read aloud is a question for you that is still open.
- A table is a table, read a row at a time (below). In a nested table, the words stay in the cell around it.
- Pictures and embedded objects are silent, except in OpenDocument text, where a picture, formula, or chart is read as its description (see What every document reader reads, below).
- A field is read for its result, as Word shows it, and never for its instruction: the result of a table of contents or a link is read, and its code (TOC, HYPERLINK, PAGE, MERGEFORMAT) is not.

#### What every document reader reads

Rich text, Word 97-2003, Word, OpenDocument text, and Word 2003 XML documents follow one policy: TextMouth reads what a person reading the document sees in its ordinary view, in reading order.

- Hidden text is not read.
- Text that is hidden only on the web is read, since it shows in print and in the normal view.
- A hidden paragraph mark alone joins nothing: the paragraphs stay separate, so a heading run into its paragraph stays a heading.
- In a Word document (.docx), whether text is hidden follows Word's rule for a property that styles toggle, from Microsoft's and ECMA's documents and not from trying Word. The run's own setting decides alone. Otherwise the document defaults, a table style, a paragraph style, and a character style are settled together, a table style and a paragraph style resetting the state to what they say and a character style toggling it, so a hiding character style inside a hiding paragraph style shows its text.
- A table style's conditional formatting (its first row, say) is not applied.
- A row marked hidden hides nothing of its own, in a .docx or in Word 2003 XML: Word shows a row that has any visible part, so the words in it are read unless their own formatting hides them.
- A paragraph whose every word is hidden is no paragraph and no heading, and a page break inside hidden text begins no page.
- A tracked deletion is not read, and a tracked insertion is. Text a tracked change moved is read once, in its new place.
- Footnotes and endnotes follow the main text, in the order the file keeps them, with no invented heading and without their reference marks, a custom mark included, except in a Word 97-2003 document, where the symbol an author typed in place of a number is read, since the file does not say how long it is.
- A note is read only if a person would see its reference: a note whose reference is hidden or deleted is left out.
- Comments, headers, and footers are not read.
- A text box, or a shape that holds text, is read.
- Word, Word 2003 XML, OpenDocument text, and rich text read a box right after the paragraph that holds its anchor, so a sentence stays whole around it.
- A Word 97-2003 document keeps its text boxes in a story of their own, and they are read after the notes.
- A Word text box that the file writes twice, once for newer programs and once for older, is read once.
- A field's instruction, such as TOC, HYPERLINK, PAGE, or MERGEFORMAT, is never read, and a field's result is.
- Pictures are silent in Word and rich text documents. In OpenDocument text, a picture, formula, or chart is read as its description (its title, if it has no description), as a paragraph right after the paragraph that holds it, and nothing if it has neither.
- The marks that show bold, italic, and strikethrough are never spoken.

#### Other limits of each

- In rich text, the title and author come from the document's own information group.
- In Word 97-2003, a document whose main text holds no words at all, such as one whose text is all in a text box or a header, is read from every part of it after the main text, in the order the file keeps them, so it is not an empty book. Its title and author come from the document's summary information. Word's fast-saved formatting, which a document that was saved quickly keeps in its pieces, is read.
- Symbols, in Word 6, Word 95, and Word 97-2003 documents, are read by their font, since the file stores a symbol as an opening parenthesis with the font and the code of the character it shows:
  - In the font Symbol (and MT Symbol and SymbolPS) the code is the Adobe Symbol encoding, so Greek letters, mathematical signs, and bullets read as themselves.
  - In WordPerfect's WP TypographicSymbols the codes read as the curly quotation marks, bullet, section sign, inverted question mark, and em dash.
  - In WP MathA they read as the degree sign, bullet, and micro sign, and in WP Greek Courier and Century as the micro sign.
  - Real documents settled these codes one by one.
  - In a picture font (Wingdings, Webdings, Zapf Dingbats, Monotype Sorts, any other WordPerfect font, or any font of the symbol character set), or for a code no table settles, a symbol reads as a space, so the words on either side do not run together.
  - In an ordinary text font, a symbol reads as the character of its code page.
- Text typed in a symbol font, which Word 97 stores as a private-use character, is read the same way. In an ordinary text font it is read through the Symbol table as textutil read it, so a letter that stands for mu or pi reads as one, and a checkbox set in Arial reads as a Greek theta.
- A bullet made by a symbol, at a paragraph's start, makes the paragraph a list item, and a paragraph of only a picture symbol, such as a checkbox, is not written.
- Before version 0.4.1 a Word 97-2003 document's symbol read as "(".
- Symbols in Word documents (.docx) and Word 2003 XML are read from version 0.4.2, by the same rules:
  - A symbol is a w:sym element, which names a font and a character code. It reads as the character that font shows for the code.
  - The font of a run is the run's own, else its character style's, else its paragraph style's, else the document defaults'. Each style is followed through the style it is based on.
  - A .docx also reads word/fontTable.xml, which says which fonts hold pictures. If that part is missing or damaged, only that knowledge is lost and the book is still read.
  - Text typed in a symbol font, stored as a private-use character, is read through the font in the same way. When no font is named anywhere, such characters stay as they are.
  - A symbol in a hidden run, or in a deleted or moved-from run, is not read. A symbol in a footnote is read, except in a note's custom mark.
  - A code that is not four hexadecimal digits, or that no table settles, reads as a space.
  - Not read: a font a table style names, a font a theme names alone, and the complex-script and East Asian fonts of a run.
  - Before version 0.4.2 these symbols were lost: a check box in Wingdings made the words either side run together, and a bullet typed in Symbol was a private-use character.
- In OpenDocument text, flat .fodt files and OpenOffice 1.x .sxw files are not read.
- In OpenDocument text, hyperlink addresses are not read, only the links' words.
- In OpenDocument text, a merged table cell leaves no cell of its own.
- In OpenDocument text, the title and author come from the document's own information, so an .odt's author is read.
- A damaged styles or information part loses only itself, and the body is read. Only the content part, or the ZIP, makes the document unreadable.

#### Code pages of rich text

- Rich text is read in the code page the file names: Windows-1252 for \ansi, Mac Roman for \mac, code page 437 for \pc and 850 for \pca, any other that \ansicpg gives, and the code page of a font's character set for the text set in that font.
- A character that takes two bytes, as in Shift-JIS (Japanese), GBK (Simplified Chinese), Big5 (Traditional Chinese), and Korean, is read whole, and Unicode characters written \u are read as themselves.
- A byte that is not valid in its code page is read as Windows-1252, so no word is lost.
- A file that begins {\rtf with no version number, which textutil refused, is read.

#### The content decides, not the extension

- A file whose content is rich text is read as rich text whatever its name, so a .doc that Word saved with "Save as RTF" is read as rich text.
- A .doc that is really a web page is read as what it is, by TextMouth's own HTML reader.
- A .doc that is really Word 2003 XML is read as that, by TextMouth's own Word 2003 XML reader.
- A file named .rtf or .doc that is none of these is refused (see [Adding books](adding-books.md)).

### Word 6 and Word 95 documents

- TextMouth reads Word 6 and Word 95 documents (.doc and .dot) with code of its own since version 0.4.1, the same on the Mac as on iOS, as it reads a Word 97-2003 one.
- The format has no published description, so the layout was worked out from real files.
- A document older than Word 6 is the only Word document left to textutil, below.
- TextMouth tells a Word 6 or Word 95 document from a Word 97-2003 one by the file's own bytes, not its name.
- Each becomes a text book like any other, so it reopens, searches, and keeps its place, bookmarks, and skipped headings.
- No helper process runs.

#### Word 6 and Word 95 headings

- Headings are the document's own heading styles (Heading 1 to 9, Title, Subtitle, and outline levels), and a document that names even one keeps exactly the headings it names.
- A document that names none gets its headings guessed from font sizes and bold, as in the other Word formats.
- Text in a table or a list is never a heading, so a few documents have fewer headings than textutil guessed.

#### Word 6 and Word 95 text and code pages

- The text is read in the code page of each run, in this order:
  - The run's own mark (Macintosh text in a Windows document, and the reverse).
  - The character set of the run's font (a Cyrillic, Greek, or Central European font).
  - The document's default, which is the foreign code page whose fonts hold over half the accented characters, else the language's.
- Far East documents are read as double-byte text, a document at a time.
- Text in the Symbol font is read as Greek letters and mathematical signs.

#### Word 6 and Word 95 emphasis, notes, tables, and lists

- Bold and italic keep their emphasis and the marks that show it are never spoken.
- Hidden text and tracked deletions are not read, and a note is read only if its reference is shown.
- Footnotes, endnotes, and text boxes follow the main text.
- A table is a table.
- A paragraph that Word numbers or bullets is a real list item, with its number silent.
- A numbering that a style carries is not followed, so a numbered heading reads without its number.
- A field's result is read and its instruction never.

#### What Word 6 and Word 95 reading leaves out

- Headers, footers, comments, and pictures are not read.
- Text typed in Wingdings reads as the letters of its bytes.
- A custom note mark (an asterisk, say) is read as typed.

#### Word 1 and Word 2 documents

- Word 1 and Word 2 documents are not compound files, and are refused at once with the unreadable sentence of a Word document (see [Adding books](adding-books.md)).

#### Word 6 and Word 95 file type

- The content decides, not the extension, as for a Word 97-2003 document.

### Documents that Apple's textutil tool still reads

- On the Mac only, textutil reads a compound-file Word document older than Word 6, which TextMouth's reader does not know the layout of.
- On iOS such a document is refused, since iOS runs no helper program (see [Adding books](adding-books.md)).

#### How textutil is run

- textutil runs in a separate process that TextMouth watches, never inside TextMouth, so a hang or a crash in Apple's readers costs that process and never TextMouth or the import.
- It loads nothing that the document links to and fetches nothing from the network.
- It converts the document once for each import, and the book's title and author come from that same run. A second run reads the page breaks (see Pages, below).
- Cancel in the import overlay stops it at once (see [Adding books](adding-books.md)).
- [Where TextMouth keeps your library](where-your-library-lives.md) gives the limits of time, memory, and processor time at which TextMouth stops it, where it writes, and what stops one that a crash left behind.

#### Headings in a document textutil reads

- Headings in such a document are found from font sizes and bold, since textutil writes every heading as an ordinary paragraph.
- The body size is the commonest size, counted by characters.
- A paragraph of at most 120 characters that is larger than the body is a heading, and so is one that is bold throughout at the body's size, unless more than half of the body is bold.
- A heading's level comes from its size's rank, the largest size being level 1, in at most six levels, and a heading found from bold follows the larger sizes.
- Text in a table or a list is never a heading.
- Bold and italic keep their emphasis, pictures are silent, and a field's instruction is never read.

### Kindle books in the MOBI format

- TextMouth reads Kindle books in the MOBI format (.mobi, .prc, and .azw) that are not copy-protected, with code of its own, the same on the Mac as on iOS.
- It reads the older format, MOBI 6, which Mobipocket books and the Kindle used before KF8.
- It also reads the newer format, KF8, which is what an .azw3 is (see Kindle books in the KF8 format, below).
- The Library window names all of them "Kindle Book (MOBI)".
- A copy-protected book is refused, never read: TextMouth does not try to remove copy protection (see [Adding books](adding-books.md) for the sentences).

#### MOBI chapters

- Chapters come from the book's own table of contents, and an entry under a chapter's entry is a heading in that chapter, as in an EPUB.
- Words before the first entry are a chapter of their own.
- A book with no table of contents is a chapter for each page break its maker wrote.
- A chapter that begins with no heading is named by its entry, or "Chapter" and its number when it has none, and the name is never read aloud.

#### MOBI title and author

- The title and author come from the book's own record of them.
- A book that gives no title is named by the title in its header, or by the file's name.
- What a book's head says about it, such as the title and publisher in an older book's metadata, is never read aloud: the words start where its body does.

#### MOBI text and emphasis

- The text is read in the encoding the book names, UTF-8 or Windows-1252 (Western European).
- Bold and italic text keeps its emphasis, as in the other text formats.
- A picture's description, when it has one, is read like the words around it, and a picture without one is silent, as calibre's are.
- The table of contents that calibre adds at the end of a book it converts is read as text at the end of the last chapter.

#### PalmDOC books

- A PalmDOC book (.prc), the plain-text Palm format that MOBI grew from, is read as paragraphs of text in Windows-1252, unless its text is HTML, as an early Mobipocket book's is.
- A PalmDOC book whose text is HTML is read like any other Kindle book, so its markup is never spoken.

### Kindle books in the KF8 format

- TextMouth reads Kindle books in the KF8 format (.azw3, and a KF8 book named .mobi or .azw) that are not copy-protected, with code of its own, the same on the Mac as on iOS.
- The book's own headers decide the format, never its name.
- A KF8 book is made of the web pages of an EPUB, so it is read like one: a chapter for each page, with the headings the book's contents names.
- A copy-protected book is refused, never read (see [Adding books](adding-books.md) for the sentences).

#### Hybrid Kindle books

- Many .mobi files made for the Kindle hold a book twice: in MOBI 6, and in KF8.
- TextMouth reads such a file from its KF8 half, which keeps the book's structure and the levels its author gave the headings.
- The MOBI 6 half of such a file puts every heading at level 1 when calibre made it, and has no pages.
- When the KF8 half can't be read, for any reason except copy protection, TextMouth reads the MOBI 6 half instead.
- Copy protection is checked in both halves, so a book that is protected in either is refused.

#### KF8 chapters

- Chapters come from the book's own pages: each page that holds words is a chapter.
- An entry in the book's table of contents that names a whole page titles that chapter.
- An entry that names a place inside a page is a heading there, at the level the book gives it, and in at most six levels.
- A chapter with no entry is titled by the title in its page's head, unless that repeats the book's own title, and otherwise "Chapter" and its number.
- A piece of a KF8 book that opens with no heading of its own, and that no entry of the contents names, joins the chapter before it only when it has the same title as the piece before it, or its title is the heading the next piece opens with. A piece that joins adds no heading of its own. Any other such piece is a chapter of its own, named by its title, and the book's first piece with words never joins anything.
- Tools such as calibre cut a long chapter into several pieces, and this rule puts the pieces back together. A paragraph that was cut in two is read as one paragraph.
- A page of links that a converter added to the end of a book, headed "Table of Contents", is left out, so it is not read aloud at the end. A last page that an author wrote, with words of its own, is always read.
- A contents or a guide that is damaged is left out, and the book is read without it.

#### KF8 text and emphasis

- The title, author, and language come from the book's own record of them, and a hybrid file is named from the half that is read.
- Bold and italic text keeps its emphasis, and lists and tables are read as in the other text formats.
- A picture's description, when it has one, is read like the words around it, and a picture without one is silent.
- The words in a picture drawn as SVG, which the Kindle's tools keep apart from the page, are read once, where the picture stood.
- Soft hyphens are left out of the text and of the headings.
- Lists of links that only help a person move through the book (its page list, its landmarks, and its contents) are not read aloud.
- Links are kept as written and never read aloud, and pictures, fonts, and style sheets are not read.
- A book with no text to read, such as one made only of pictures, is refused with "This file has no text to read."

### Kindle books in the KFX format

- TextMouth reads Kindle books in the KFX format (.kfx, .kfx-zip, .azw8, and an .azw file that holds KFX, as Kindle's apps name their KFX books) that are not copy-protected, with code of its own, the same on the Mac as on iOS, and the Library window names the format "Kindle Book (KFX)".
- A KFX book is read like a MOBI book, and into the same kind of chapters.
- A .kfx-zip, a ZIP that holds the parts of one book, is read as that one book.

#### KFX chapters and headings

- Chapters come from the book's own table of contents, and an entry under a chapter's entry is a heading in that chapter, as in a MOBI book.
- A heading's level is the one the book gives it, from 1 to 6.
- A chapter that begins with no heading is named by its entry, and the name is never read aloud.
- A part of the book that no entry starts and that begins with no heading continues the chapter before it, so a forced page break makes no new chapter.
- A first chapter that nothing names takes the book's title, and no heading is ever made up.

#### KFX pages

- Pages are the book's print page list, when it has one, as an EPUB's are, so Page works as it does there (see Pages, below).
- A page list that a machine made to approximate pages, which the book marks as such, is not read as pages.
- A KFX book that is an .azw file is read without pages.

#### KFX emphasis, lists, and tables

- Bold and italic text keeps its emphasis, and lists and tables are lists and tables, a table being read a row at a time.
- A footnote's text is read at the end of its chapter.
- A picture's description, when the book gives one, is read like the words around it, and a picture without one is silent.
- The title and author come from the book's own record of them.

#### KFX copy protection

- A copy-protected book is refused, never read, and TextMouth never tries to remove the protection: "This Kindle book is copy-protected, and TextMouth can't read copy-protected books."
- This holds whether the protection is in the book's file, in a license file that sits beside it, or in any part of a book made of several.

#### KFX books with no flowing text

- A book with no flowing text to read is refused: a fixed-layout book, a print replica, a comic, a magazine, a children's book, a textbook, a notebook, or a book whose pages are only pictures.
- The sentence is "This Kindle book has no flowing text to read, such as a comic or a print replica, so TextMouth can't read it."

#### Kindle Create packages

- A Kindle Create package (.kpf), the file an author makes before a book is published, is refused with its own sentence: "This file is a Kindle Create package, which TextMouth can't read yet."
- [Adding books](adding-books.md) gives every sentence.

### DAISY books

- TextMouth reads DAISY books, versions 2.02 and 3: a book's folder, its navigation or package file (ncc.html or a .opf file), or a ZIP holding the book.
- A DTBook file on its own (.xml) imports as a book too, and so does a NIMAS package, which is a DTBook with its package file.
- A DAISY 3 book that holds several DTBook files is read in one order every time (since November 13, 2026): the package's reading order, else the order its SMIL files point at the files, else the order the package lists them. A file that none of these places comes last.
- A DAISY book's audio times may be written as clock values, as 0:02:43.650, as seconds, or, as SMIL allows, with a unit: "500ms", "38.228s", "2min", or "1h". Each unit reads as the time it names; "500ms" used to read as no time. A book's audio times are measured when it is imported, so a DAISY book gains them when it is imported again.

### XML files

- TextMouth reads the start of each .xml file and names its kind by the element it begins with:
  - A DTBook goes to the DAISY reader.
  - Word 2003 XML goes to TextMouth's own Word 2003 XML reader.
  - A PEF braille file goes to the braille reader (below).
  - Any other XML is refused by name.

### Braille files

- TextMouth reads BRF files (.brf), BRL files (.brl), and PEF files (.pef).
- It translates them to print with liblouis, using the braille code chosen in the Braille tab of Settings (see [Settings](settings.md)), and the print becomes a text book like any other, so it reopens, searches, and keeps its place, bookmarks, and skipped headings.
- A book keeps the code it was imported with, through Remove from Library Only and adding it back too, so changing the setting never changes what an imported book says.
- A book read with one of this Mac's tables (see [Settings](settings.md)) also keeps the liblouis version of this Mac's tables, and if a macOS update changes them, TextMouth refuses to rebuild that book's text and keeps the text as it was, with this sentence: "This Mac's braille table “mac:fr-bfu-g2.ctb” has changed since the book was read with it, from liblouis 3.34.0 to 3.35.0, so TextMouth keeps the book's text as it was."
- When this Mac's tables name no version now, it says the table "may have changed since the book was read with liblouis 3.34.0" instead.
- A book that recorded no version is never refused for this.
- Book Info and Speak Info name the code, and Book Information's Braille Code pop-up reads one book again with another braille code (see [The Library window](library-window.md)).

#### Braille file characters

- A BRF or BRL file is read in one of three codes, which the book records:
  - North American Braille ASCII is the default and the code of nearly every file.
  - Eurobraille, six-dot (German-speaking countries) is the other seven-bit code.
  - Unicode braille patterns write each cell as a character from U+2800 to U+28FF, in UTF-8.
- TextMouth recognizes Unicode braille patterns by the file's bytes, from the first character after any blank lines in the first 64 KB, and reads such a file as them whatever the Braille tab says.
- It guesses nothing else, since every printable ASCII character is a cell in every seven-bit code: a file read in the wrong seven-bit code gives wrong numbers and punctuation, with no error.
- The Braille tab chooses the seven-bit code for the books you add from then on (see [Settings](settings.md)), and Book Information's Braille File Characters pop-up reads one book again with another code (see [The Library window](library-window.md)).
- A PEF always holds Unicode braille and needs no choice.

#### Books that record no braille code

- A book that records no code, as every book added before TextMouth recorded them, is read as North American Braille ASCII, unless its first character is a braille pattern, which can only be Unicode braille patterns: such a book is read as them.
- A BRF or BRL file of Unicode braille patterns that uses dot 7 or 8 is eight-dot braille, which TextMouth refuses. So is a file of eight-bit computer braille, and so is a file in UTF-16, each refused by name (see [Adding books](adding-books.md) for the sentences).

#### What a BRF or BRL file holds

- A BRF or BRL file holds one character for each braille cell, in the braille file characters above, in upper or lower case for braille ASCII, with each line ended by CR LF, LF, or CR.
- A tab counts as one blank cell.
- A BRF ends each page with a form feed, and a BRF with none is cut into pieces of 25 lines to read its layout (see Pages, below).
- A BRL has no layout, so each of its lines that is not blank is a paragraph and it has no headings.
- A PEF file must be six-dot braille: eight-dot PEF is refused.

#### Braille layout

- Headings, paragraphs, and list items are found from the layout, as BANA's Braille Formats (2016) lays it out.
- A centered line, or a centered run of lines, is a level-1 heading.
- A line at cell 5 is a level-2 heading, and a line at cell 7 is level 3.
- Paragraphs and list items are found from their indents, and each list item is read as a paragraph.
- Page numbers are left out of the text, so they are never spoken.

#### Braille emphasis

- Reading Unified English Braille (UEB) keeps what its emphasis signs say, and reading English Braille, American Edition (EBAE) keeps what its signs say where they are certain.
- In UEB, italic and bold come into the book's text as italic and bold, and both together as both.
- In UEB, underline, script, and the typefaces a transcriber defines come in as italic, the nearest thing the text holds.
- As in the other text formats, the marks that show emphasis are never spoken.
- Contracted (Grade 2) UEB reads a whole-word contraction just before an emphasis end sign as the word it is: "people" comes back as "people", not "p", and "his" as "his", not a double quotation mark.
- In EBAE, italic and bold are read where the sign is certain: words that start with l or with n to z, capitals, numbers, and most contractions.
- In EBAE, a passage of several words ends where its last sign says.
- The signs liblouis writes for bold italic, which BANA's EBAE has not got, are not read as bold italic.
- No word of an EBAE book differs from before. The emphasis is what is new.
- Where a sign cannot be told from print, it is left as it was:
  - An emphasized word that starts with a to j still reads with a stray period, as in ".cat" for an italic "cat".
  - One that starts with k reads with an equals sign, as in "=ite" for "kite".
  - One that starts with m reads with µ, as in "µe" for "me".
  - The emphasis on those words is lost.
- TextMouth checks each paragraph against liblouis's own reading, and a paragraph whose words would differ in any character is read without emphasis.
- Most of this Mac's tables are read as plain braille, since liblouis cannot read their emphasis back exactly.
- The EBAE reading applies to a table of this Mac's that writes EBAE's signs and reads the sign alone as punctuation, as its English EBAE tables do.
- TextMouth's braille helper tests each table for this when the table is used, so none is picked out by name.
- The faults of liblouis itself in reading EBAE remain, as a decimal such as 3.5 that comes back as "3.e".
- A braille book is read again once at the first launch after the update of October 24, 2026, and gets this reading then.
- A book whose new reading differs from its text keeps a copy of its old text beside it, and its saved places follow their words (see [Where TextMouth keeps your library](where-your-library-lives.md)).
- Redo Text Extraction reads a book again at any time.
- Export writes a book's emphasis into braille in UEB, and writes none in EBAE (see [Exporting books](exporting-books.md)).

#### PEF titles and authors

- A PEF names its book's title and author in its head, and the import reads them from the first 64 KB of the file.
- A BRF or BRL names neither, so its book is titled by its file's name without the extension, and its author is Unknown.

#### Braille file limits

- A braille file of more than 32 MB is refused, and so is one of more than 100,000 pages or 4,000,000 lines (see [Adding books](adding-books.md) for the words of each refusal).

#### Braille not read yet

- Running heads, Roman-numeral page numbers, and words divided at a line's end are not read yet.
- A list laid out by another tool may read as plain paragraphs.

#### The braille helper process

- liblouis runs in a separate process that TextMouth watches, never inside TextMouth, so a hang or a crash in liblouis costs that process and never TextMouth or the import.
- [Where TextMouth keeps your library](where-your-library-lives.md) gives its limits.

### PDF files

- A page that holds only a scanned image is read with the Mac's own text recognition.

### HTML, Markdown, and plain text files

- TextMouth reads HTML, Markdown, and plain text files, whatever their text encoding and line endings.

#### Where a file's text encoding comes from

- TextMouth takes a file's text encoding from the file where it can, using the first of these that applies:
  - A byte-order mark for UTF-8, UTF-16, or UTF-32.
  - UTF-16 or UTF-32 without a mark, found by the pattern of its bytes (since 0.4.3), as described in the next section.
  - For an HTML file that declares ISO-2022-JP (Japanese in 7-bit text) and holds its escape codes, that encoding, since such a file is valid UTF-8 too.
  - Bytes that are valid UTF-8.
  - For an HTML file, an encoding other than Unicode that its first 1,024 bytes declare, where ISO Latin 1 and ASCII are read as Windows-1252, as web browsers read them.

#### UTF-16 and UTF-32 without a mark

- Since 0.4.3 TextMouth finds these by the pattern of their bytes:
  - UTF-16 in Latin letters, which shows in its zero bytes, as before;
  - UTF-32, in either byte order;
  - UTF-16 in Greek, Cyrillic, Armenian, Hebrew, or Arabic, from 16 bytes up;
  - UTF-16 in other scripts, such as Chinese, Japanese, or Korean, when the text also holds at least 8 ordinary characters (spaces, digits, or line ends).
- A reading counts only if the result is plain text. A few stray zero bytes in a UTF-8 or 8-bit file do not make it UTF-16.
- What it does not find:
  - UTF-16 in the scripts of India (Devanagari, Bengali, and the others near them).
  - Short Chinese, Japanese, or Korean UTF-16 with few spaces, digits, or line ends. In testing, a Chinese file needed about 46 characters and a Korean one about 28, and a Japanese file with only 5 spaces, digits, or line ends was not found.
  - Chinese, Japanese, or Korean UTF-16 with no such characters at all, whose bytes look the same as Shift JIS, GBK, or EUC text.
  - A file that is not found is read as one of the other encodings, with the wrong letters, or as Windows-1252.
- UTF-16 and UTF-32 have no item in the Text Encoding pop-up (see [The Library window](library-window.md)), so a file that is not found cannot be set right there. Save it as UTF-8, or in UTF-16 with a byte-order mark, and add it again.
- A book that recorded its encoding when you added it is read again in that encoding, and only UTF-16 in Latin letters can overrule it. A web archive's page that names no encoding is read as it was before. Your own choice in Text Encoding overrules all of this.
- The first time 0.4.3 opens, every plain text and HTML book is read again once, and your place follows its words. A book whose file reads as it did before has the same text. A Markdown book is read the new way when it is added, or when its text is built again, as Redo Text Extraction does.

#### A file that none of these settles

- A file that none of these settles, because it is neither UTF-8, UTF-16, nor UTF-32 and names no encoding, was always read as Windows-1252, so a file in an encoding that Windows-1252 does not match, such as Mac Roman, Cyrillic, or Japanese, had the wrong letters.
- Since the update of October 24, 2026, TextMouth guesses its encoding when you add the file with Open Book…, from Finder, or in a ZIP of books, and a book whose encoding it guessed is read in that encoding from then on.
- Only a file you add yourself is guessed at: a feed's article is read as it always was.

#### The encodings TextMouth guesses among

- TextMouth guesses among the encodings below.
- Book Information and Speak Full Info name the one it chose as written here, then "guessed", and one you chose the same way, then "chosen" (see [The Library window](library-window.md)).
- Windows-1252 is not among them: a file is read as Windows-1252 when no guess can be trusted, though you can choose it.
- The two DOS code pages and Mac Central European, added on November 13, 2026, are taken only when macOS's own guess names one of them. TextMouth does not try them itself, so a book already in the library is not read differently; the Text Encoding pop-up in Book Information offers all three for you to choose.
- The encodings, by script:
  - Western European: "Mac Roman (Western European)", "ISO 8859-15 (Western European)", "CP437 (US DOS)", and "CP850 (Western European DOS)".
  - Central European: "Windows-1250 (Central European)", "ISO 8859-2 (Central European)", and "Mac Central European".
  - Cyrillic: "Windows-1251 (Cyrillic)", "KOI8-R (Russian)", "KOI8-U (Ukrainian)", "CP866 (Russian DOS)", "ISO 8859-5 (Cyrillic)", and "Mac Cyrillic".
  - Greek: "Windows-1253 (Greek)" and "ISO 8859-7 (Greek)".
  - Turkish: "Windows-1254 (Turkish)" and "ISO 8859-9 (Turkish)".
  - Hebrew: "Windows-1255 (Hebrew)" and "ISO 8859-8 (Hebrew)".
  - Arabic: "Windows-1256 (Arabic)" and "ISO 8859-6 (Arabic)".
  - Baltic: "Windows-1257 (Baltic)" and "ISO 8859-13 (Baltic)".
  - Thai: "Windows-874 (Thai)".
  - Japanese: "Shift JIS (Japanese)", "EUC-JP (Japanese)", and "ISO 2022-JP (Japanese)".
    - ISO 2022-JP writes only 7-bit bytes, so it is valid UTF-8 too.
    - TextMouth looks for it, by its escape sequences, before it takes bytes for UTF-8.
  - Chinese: "GB 18030 (Simplified Chinese)", "GBK (Simplified Chinese)", "GB 2312 (Simplified Chinese)", and "Big5 (Traditional Chinese)".
  - Korean: "EUC-KR (Korean)".

#### When TextMouth guesses

- TextMouth guesses only when it can trust the guess more than Windows-1252, since a wrong guess turns text that was right into text that is not, which the book keeps, while a missed guess leaves a book as garbled as it was.
- You can mend either by choosing the book's encoding yourself (see Choosing the encoding, below).
- It examines the lines that hold a byte beyond plain ASCII, about 64 KB of them from the start, and takes a guess only when all of these hold:
  - The Windows-1252 reading shows that it is wrong:
    - It holds at least three characters that real writing almost never holds (symbols inside words, control characters, and the like), not all the same character.
    - Or it holds at least five capitals inside lowercase words.
    - Or a fifth or more of its letters beyond plain ASCII lie outside the alphabet of the one language that fits them best, where the other reading's letters fit one language.
  - Another encoding reads them clearly better, with almost nothing odd left. When other encodings read them as well but differently, the file stays Windows-1252, unless macOS's own guess names one of exactly two of them.
  - The whole file, not only the lines examined, reads in that encoding with no byte dropped or replaced, and writes back to exactly the same bytes.

#### The same bytes give the same guess

- The same bytes always give the same guess.

#### Files that stay Windows-1252

- Some files stay Windows-1252, as they were read before, until you choose their encoding (see Choosing the encoding, below):
  - Short texts, which show too little to guess from. A Cyrillic note of a line or two may stay garbled, though a paragraph of Cyrillic is read right.
  - Text in some languages: Hungarian, Croatian, Slovenian, and Latvian, and French saved in ISO 8859-15.
  - Short sentences in Mac Roman, in Spanish, Portuguese, Italian, Dutch, Danish, or German.
  - A file whose only accented letters are capitals inside program names, such as "zeigeÜbersicht", when it is not in Windows-1252: read right, those capitals look as odd as they do read wrong.
  - Hebrew text, which is guessed only when macOS's own guess names Hebrew, so a short Hebrew text may stay as it was.
  - A file in an encoding that is not listed above, or in CP437, CP850, or Mac Central European when macOS's own guess does not name it, since TextMouth does not try those three itself.

#### A guess can be wrong

- A guess can still be wrong, most often for a text of only a few lines, and, rarely, for a Windows-1252 file of program code with several accented capitals inside its names, which can be read as Mac Roman.
- Book Information names the encoding a book was read in, so a book whose letters read oddly can be checked there, and set right there with its Text Encoding pop-up (see Choosing the encoding, below).

#### Books already in your library

- A book already in your library keeps its text.
- TextMouth records a guess with the book when the book is added, and an encoding you choose when you choose it, and reads the book in it every time its text is built again, after an update or with Redo Text Extraction.
- A book added before then, and a book whose file named its encoding or read right as Windows-1252, has no record and is read as it always was (see [Where TextMouth keeps your library](where-your-library-lives.md)).

#### Choosing the encoding

- The Text Encoding pop-up in Book Information reads a book's file again in the encoding you choose, or, with Automatic, as TextMouth reads a file you add.
- Use it for a book whose letters read oddly, whether the guess was wrong or missed.
- Its items, and every sentence it says, are under Text Encoding in [The Library window](library-window.md).
- A book you added from a file has it. Text you typed in with New from Text, a feed's article, and a book of another format do not.
- A chosen encoding is read whatever the file's bytes say of themselves: a byte-order mark, bytes that are valid UTF-8, and an HTML file's own declaration do not overrule it, since you choose it for a file that read wrong.
- It is read strictly: every byte must belong to a character of the encoding, and none is dropped or replaced. UTF-8 refuses a file that is not valid UTF-8, and an encoding of one byte to a character refuses a byte it leaves undefined, such as 0x98 in Windows-1251. Windows-1252 gives every byte a character, so it refuses nothing.
- A file that is not valid in the encoding chosen is refused, and nothing changes: not the book's text, its saved places, nor its record. The sentence names the book and the encoding (see Text Encoding in [The Library window](library-window.md)).
- Limits, since macOS's own readers decide which characters an encoding defines:
  - Characters of JIS X 0212 in EUC-JP, which it writes with the byte 0x8F before two bytes, are refused, because macOS reads them as other characters.
  - The euro sign in Big5 and in EUC-KR is refused.
  - Big5-HKSCS characters, the Hong Kong additions to Big5, are refused.
  - A GB 18030 file that holds the replacement character itself, U+FFFD, is refused.
  - In Big5 as Windows writes it, the two bytes 0xA2 0xCC are read as 十 followed by a character from a private-use area, which a braille display shows.
- A book recorded as read in an encoding this TextMouth does not know, as a choice made on a Mac that knows more encodings, or in a later TextMouth, can be, is refused when its text is read: "The file “Moby-Dick.txt” is set to be read as “x-cp1999”, a text encoding this version of TextMouth can't read. Choose another in Book Information."

### Safari web archives

- TextMouth reads Safari web archives (.webarchive).
- Only the archive's main page is read, as an HTML file is read (or a text file, for a text page), so its headings, lists, and tables read as in an HTML book.
- The archive's pictures, scripts, style sheets, and frames, and every address it names, are never read, decoded, or fetched, and WebKit is not used.

### SSML files

- TextMouth reads SSML files (.ssml) as text: the markup is removed, and the paragraphs and sentences are kept.
- A sub element's alias is read in place of its written text: <sub alias="World Wide Web Consortium">W3C</sub> reads "World Wide Web Consortium".
- The text of desc, meta, metadata, and lexicon elements is left out.
- An audio element's sound file is never read or fetched, and only the text inside the element is read.
- A break, a change of voice, or a sentence's start keeps the words on either side of it apart.
- The file is never given to the speech engine as SSML, which would ignore the speed you set.
- Its words are spoken in your voice at your speed, whatever voice, speed, or pitch the markup asks for.

### New from Text

- TextMouth reads text you type or paste with New from Text.

### Pages

- Pages, which the Page navigation unit and Go to Page… move by (see [Reader windows](reader-windows.md)), are numbered as each format numbers them.
- A book already in your library gains pages when its text is read again (see [Where TextMouth keeps your library](where-your-library-lives.md)).

#### Pages in EPUB books

- In an EPUB, pages are the book's page list or, when it has none, its page-break marks.
- A page list that gives none of its pages a number, such as one whose only entry is named by its link ("pagenum_000000"), counts as none, and a mark named only "Page" names no page.
- A page any book names "Page 12" is page 12, and a page number printed at its mark is not read aloud.
- A mark's own text is not read aloud when it is no more than its page's label, the print page's number and perhaps a caption of up to 32 characters.
- Any longer or other text in a mark is read, after its page marker.
- A mark with no aria-label or title that holds more than that begins no page.

#### Pages in HTML files and web archives

- In HTML files, and in Safari web archives read as HTML files, pages are the page-break marks.
- In an EPUB and in an HTML book alike, a page break's number inside a heading is left out of the heading's name too (see [Reader windows](reader-windows.md)).

#### Pages in PDF files

- In a PDF, every page is a page, with the page labels the PDF gives, such as i, ii, 1, 2, and A-1, or its number when it gives none.
- A page with no text is still a page.

#### Pages in Word documents

- In Word documents, templates, and macro documents, pages are the page breaks the author wrote, paragraphs set to start a page, sections that start a page, and the page breaks Word recorded when it last laid the document out.
- Pages are numbered from 1.
- A section can restart the number and set its format (decimal, lower or upper case roman numerals, or lower or upper case letters; any other format counts as decimal).
- A document Word never laid out, such as one another program made, holds only its author's page breaks, so TextMouth shows fewer pages than Word would.

#### Pages in DAISY books

- In a DAISY book, pages are the page numbers the book gives, which are no longer read aloud as "[Page 12]".
- A DAISY 3 book of several DTBook files numbers a page that holds no words by its place in the whole book: 1, 2, then 3, 4, where each file used to begin again at 1.
- The first launch after the update of November 13, 2026 reads every DAISY book again, once, as the DAISY page reader changed (version 1.0.1), and your place follows its words. Only a DAISY 3 book of several DTBook files, with a page that holds no words after an earlier page or with files that were read out of order, ends with another text; every other DAISY book reads byte for byte as before.
- A DAISY 2.02 page entry's own number or caption, as "12" under the label "Page 12", is not read either.
- Any longer or other text a DAISY 2.02 page entry points at is read.

#### Pages in rich text

- In rich text and rich text with attachments, a page begins at each \page, each paragraph set to start a page (\pagebb, directly or by its style), and each section that starts a page (a \sect followed by a section of the kinds that start one, which is the default, but not \sbknone or \sbkcol).
- Pages are numbered from 1, and a page begins at its first letter or digit, so a break with no words after it begins none.
- A paragraph set to start a page before any words begins the first page, which is page 1 already.
- A document with 100,000 or more breaks has no pages, and the text is read as before.

#### Pages in Word 97-2003 documents

- In Word 97-2003 documents and templates, pages are the page breaks the author wrote, a paragraph set to start a page ("Page break before"), directly or by its style, outside a table, and a section that starts a page.
- A section starts a page if its break is of the kind that starts a new, even, or odd page, which a section that says nothing is. A continuous section break or a new column does not.
- Pages are numbered from 1, and a page begins at its first letter or digit.
- TextMouth reads no layout of Word's own, so a .doc shows fewer pages than Word would.

#### Pages in OpenDocument text

- In OpenDocument text, pages are the page breaks the author wrote (a paragraph or table style that breaks before or after it), a paragraph or table that names a master page, and the soft page breaks that the program which last laid the document out recorded.
- Pages are numbered from 1, with no restarts or formats, and a page begins at its first letter or digit.
- A page cannot begin inside a table or a text box.
- A document that no program laid out holds only its author's breaks, so it shows fewer pages than the author's program would.

#### Pages in Word 2003 XML

- In Word 2003 XML, pages are the page breaks the author wrote, paragraphs set to start a page, and sections that start a page, numbered from 1.

#### Pages in Word 6 and Word 95 documents

- In Word 6 and Word 95 documents, a page break, a section that starts a page, and a paragraph set to start a page begin pages, as in a Word 97-2003 document.
- A continuous section break begins none, where textutil began a page.

#### Pages in a Word document older than Word 6

- On the Mac, a Word document older than Word 6 has the page breaks textutil reports in a second run, numbered from 1, with the words textutil ran together at a break kept apart.
- A break whose surroundings differ in textutil's two readings is dropped, never placed wrongly.
- A Word field such as a table of contents or a link does not put the two readings out of step, since the breaks are placed before textutil's field instructions are removed.

#### Pages in braille files

- In BRF and PEF braille files, every braille page is a page, the pages an embosser or a braille display counts.
- A page is named by its braille page number read as print, as ⠼⠁⠃ reads 12 and ⠏⠼⠁, a preliminary page, reads p1.
- A page with no braille page number, or none that TextMouth can read, is named by its place among the book's pages, the first being 1.
- A print page number, such as a transcription of a print book carries, is no page here, and is left out of the text.
- A page that begins in the middle of a paragraph begins at its first word there.
- A page with neither words nor a number, such as the blank back of a two-sided page or the empty page a form feed leaves at a file's start or end, is not a page.
- A BRF without form feeds, which TextMouth cuts every 25 lines only to read its layout, has pages only when braille page numbers end most of those 25-line pieces.
- A form feed only at a file's start or end counts as none.
- A BRL file has no pages.

#### Pages in plain text

- In plain text, each form feed between the words begins a page, numbered from 1, at the first line after it that is read.
- A form feed before the first words or after the last begins none, so a text without one between words has no pages.
- Two form feeds in a row make a blank page, which counts in the numbering and begins where the page after it does.
- A text has at most 100,000 pages, the most a book may have. A form feed past them begins none, and the text is read as before.
- A Safari web archive whose page is plain text has no pages.

#### Pages in SSML and Markdown

- SSML files have no pages.
- A Markdown file has pages only where it holds page lines (see [Editing a book's text](editing-book-text.md)).

#### Pages in MOBI books

- Kindle books in the MOBI format have no pages.
- The Kindle keeps a book's page numbers in a separate .apnx file beside it, which TextMouth does not read yet.

#### Pages in KF8 books

- In Kindle books in the KF8 format, pages are the page breaks the book kept from the EPUB it was made from, when it has them.
- KF8 keeps no page list, so a book that has page breaks in its text has pages, and one without them has none.
- A book that holds both MOBI 6 and KF8 has pages from its KF8 half only.

#### Pages in KFX books

- In Kindle books in the KFX format, pages are the book's print page list, when it has one and a person made it.
- A KFX book with no print page list, or with only a machine's approximate one, has no pages.

### Tables

- In EPUB, HTML, Word, and Markdown books, a table is read a row at a time: each row is a paragraph of its own, with a pause after it, and the cells in a row are separate words.

### The 64 MB limit

- A rich text, Word 97-2003, OpenDocument, or Word 2003 XML document, a web archive, an SSML file, a DTBook on its own, or a Kindle book that holds more than 64 MB is refused, since that is the most TextMouth reads from one document.
- For a Kindle book the limit is on its text. A hybrid file that holds its pictures twice can be larger than 64 MB, and is read, up to 512 MB in all.
- For an .rtfd the limit is on its text file, TXT.rtf, alone: the attachments are not read, and do not count toward it.

### How the Library window names a format

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

## Audiobooks, played at the speed you choose

### Single audio and video files

- TextMouth plays single files in MP3, M4A, M4B, WAV (RF64 and BWF too), AIFF, FLAC, ALAC, or AAC format, and video files in MPEG-4 (.mp4), M4V, or QuickTime (.mov) format, whose sound alone plays.
- It plays these as they are, except an MPEG-4 or QuickTime file whose sound is not AAC, Apple Lossless, or MP3, which it converts like the audio below.

### Audio that TextMouth converts as it is imported

- TextMouth converts audio as it is imported, since macOS can decode it but TextMouth does not play it as it is, in these formats:
  - Ogg (.ogg, .oga, or .opus, holding Vorbis, Opus, or FLAC audio).
  - AC-3 (.ac3).
  - E-AC-3 (.ec3, .eac3).
  - MP1 and MP2 (.mp1, .mp2, .mpa).
  - AMR (.amr, .awb).
  - 3GPP audio (.3gp, .3g2, .3ga).
  - NeXT/Sun audio (.au, .snd).
  - AIFC (.aifc).
  - CAF (.caf).
  - Wave64 (.w64).
- Each file becomes an .m4a file in the book's package, and only that file is played.
- A file is converted wherever it comes from: a single file, a ZIP, a folder, a playlist, or a feed's episode.
- The book's package keeps only the converted file, unless Keep originals of converted audio is on in the Storage tab of Settings (see [Settings](settings.md)).

#### What a file holds decides

- What a file holds decides, not its extension.
- An Ogg file named .m4a, or an MP2 feed episode saved as .mp3, is converted all the same.
- TextMouth does not open an Ogg file under another name, an .mp3 or .m4a, with Apple's audio code to read its tags, which is what hung the Mac on October 14, 2026: it reads them from the file's own bytes, and names the book for the file when they can't be read.
- An audio file whose header claims an absurd length, past a year, or an absurd sample rate is refused rather than crashing the import.

#### Lossy audio

- Lossy audio becomes AAC at about its own bit rate: it stays near its size, but a second lossy encoding can lose a little.
- The rate is the next standard AAC rate at or above the source's average (64 to 192 kbit/s for stereo, half that for mono).
- Lossless audio that TextMouth converts (PCM in CAF, AIFC, AU, or Wave64; Apple Lossless or FLAC in CAF; Ogg FLAC) becomes Apple Lossless at its own bit depth (16, 20, 24, or 32 bits) and loses nothing.
- Plain WAV, AIFF, and FLAC files are not converted at all.

#### Channels

- TextMouth writes at most two channels, so audio of more than two channels is mixed to stereo as it is converted, with Apple's standard mix: the centre channel, where speech usually is, keeps its place in both ears.
- Such a book plays about 11 to 14 dB quieter than a stereo book: 11 when the source is linear PCM and 14 when it is AC-3.
- A file of more than two channels that does not say which is which can't be mixed, and is refused.

#### Ogg audio

- TextMouth converts Ogg audio on macOS 15.4 and later, which can read it.
- It never plays Ogg itself, since macOS's Vorbis decoder can lock up while playing (October 14, 2026).
- It does not ask macOS's audio to open an Ogg file for anything else either: it reads the file's title, artist, album, genre, year, and length from the file's own bytes with code of its own, and only afconvert, run as a separate process that TextMouth watches, decodes it.
- An Ogg file that claims to last more than a year is refused as unreadable.
- A file cut from a longer stream, as a live broadcast joined part way through is, reports the length it holds, not the length counted from the start of the broadcast.
- A file that carries an Ogg Skeleton track beside its audio is read for its audio and imports like any other.

#### Every other converted format

- Every other converted format is read by Apple's afinfo tool, which says what the file holds, and then converted by afconvert, each run as a separate process that TextMouth watches (see [Where TextMouth keeps your library](where-your-library-lives.md)).
- A file of one of them that claims to last more than a year, or a length that its size cannot hold, is refused as unreadable.
- A Mac that can't read or convert a format refuses a file of it by name when it is imported, and nothing is added.

### Chapter lists in Nero format

- An M4B, M4A, MP4, M4V, or MOV file whose only chapter list is a Nero list (some audiobook tools write only that) has its chapters as headings, an untitled one called "Chapter" and its number.

### M3U and M3U8 playlists

- An M3U or M3U8 playlist (.m3u, .m3u8) becomes one audiobook of the files it lists, a heading for each, in the playlist's order (see [Adding books](adding-books.md)).

### A ZIP of audio tracks

- A ZIP of audio tracks becomes one book with a heading for each track.
- A manifest.json in the ZIP, at its top level or inside the one folder that holds everything, as Finder's Compress command makes it, can name the book and its author, put the tracks in your order with titles of their own, group them under headings, and set the pauses between them.
- An import whose manifest has a mistake stops and says what is wrong and where (see [The audiobook manifest](audiobook-manifest.md)).

### A DAISY audio book in a ZIP

- A DAISY audio book in a ZIP becomes one audiobook whose sections are its headings.
- A section plays all of its heading's narration, even where it runs on into other audio files.
- A DAISY audiobook imported by an earlier version keeps one stretch of audio per section until it is imported again.

## Transcripts of audiobooks, on macOS 26 and later

### Transcribing an audiobook

- Transcribe Audio… transcribes an audiobook with the Mac's own speech recognizer (SpeechAnalyzer), which asks no permission and sends nothing anywhere: the book's audio never leaves this Mac (see [Transcribing an audiobook](transcribing.md)).
- The transcript becomes the book's text: the reader shows it around the sentence being narrated, following the narration as the book plays, while positions and bookmarks go on counting time.
- Where Am I? ends with the sentence being heard, the one the text is shown around, quoting up to 40 words of it.
- Edit Text opens that text in your own editor (see [Editing a book's text](editing-book-text.md)).

### The language of a transcript

- Transcripts are in English unless you choose another language in Settings, under Playback, Transcription, or with transcriptionLocale in config.json (see [Editing settings in config.json](config-json.md)).
- The English is as this Mac's region writes it when the Mac is set to English, such as en-GB in the United Kingdom, and otherwise US English.
- Each language needs its speech model, which macOS downloads from Apple only when you ask for it in the Transcribe Audio sheet, and keeps for other apps too.

### Cleaning up a transcript

- Clean Up Transcript (Experimental)… corrects, by rules you write, words the recognizer always writes another way, such as a name in a series of books.
- The last cleanup can be undone (see [Transcribing an audiobook](transcribing.md)).
- TextMouth comes with no rules of its own: measured on 38,834 words read aloud, no correction was right in every book.
- TRANSCRIPT-CLEANUP-RESEARCH-2026-10-04.md, in the same folder as this file, says which words the recognizer gets wrong, and what a cleanup can fix.

### macOS 14 and 15

- TextMouth itself still runs on macOS 14 and 15, which can't transcribe: there Transcribe Audio… only says that transcription needs macOS 26 or later.

## Podcasts and article feeds

- TextMouth reads podcasts and article feeds in RSS 2.0, RSS 1.0, Atom, or JSON Feed (1.0 and 1.1), with Apple's podcast elements and Podcasting 2.0's.

### Subscribing to a feed

- TextMouth can subscribe to a feed by its address, by a feed:, pcast:, or itpc: link, by a web page that names its feed, or by searching Apple's podcast directory, and lists the feed's episodes and articles in a library folder of its own, named after it (see [Podcasts and article feeds](feeds.md)).
- An episode downloads as an audiobook, a video episode as an audiobook that plays its sound, and an article as an HTML book.
- An article is read from its web page when the feed gives only a short summary that links one, though an article TextMouth downloads by itself reads its page only on a network without data limits, and otherwise holds the feed's own text.
- Each download is kept in the feed's own folder in the data directory, apart from the library's books (see Feeds, under [Where TextMouth keeps your library](where-your-library-lives.md)).

### Refreshing feeds

- Feeds refresh when TextMouth opens and every hour while it runs, unless the Feeds tab of Settings says otherwise, skipping an hour in Low Power Mode.
- A feed you unsubscribed from is never refreshed, at launch, every hour, or by Refresh All Feeds, until you choose Resubscribe (see Commands, under [Podcasts and article feeds](feeds.md)).
- Each feed's List and download choice decides which of its episodes and articles are listed and which download by themselves: unless you choose otherwise, every one the feed lists is listed, and those of the newest 5 not yet played are kept downloaded (see Listing and downloading, under [Podcasts and article feeds](feeds.md)).
- Those refreshes, and the episodes TextMouth downloads by itself, never use a network with data limits, such as Low Data Mode or a phone's hotspot: such an episode waits, its row saying "Waiting to Download, it downloads once this Mac is on a network without data limits", and is asked for again after the next refresh TextMouth makes by itself on a network without them.
- A finished episode or article counts among Books Finished.
- Its download's file is deleted for good a day after it finished, or as the Feeds tab of Settings says, unless it is open in a reader, being transcribed, or being exported, when it goes at a later pass.
- Its place and bookmarks are kept should you download it again (see Commands, under [Podcasts and article feeds](feeds.md)).

### What reaches the network

- The feeds, and a search of Apple's podcast directory, are the only things TextMouth itself reaches the network for, and its connections keep no cookies and cache nothing on disk.
- A feed or episode at a plain http address loads too, since many still use one.
- A transcription language's speech model is downloaded by macOS, and only when you ask for it (see [Transcribing an audiobook](transcribing.md)).

## TextMouth packages

- TextMouth reads TextMouth packages (.tmb folders) from another TextMouth library.
- A package keeps its reading position, bookmarks, and per-book settings.

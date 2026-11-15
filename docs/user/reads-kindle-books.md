# What TextMouth reads: Kindle books
<!-- id: what-textmouth-reads-kindle-books; keys: ; src: -->

## Kindle books in the MOBI format
<!-- id: kindle-books-mobi-format; keys: ; src: -->

- TextMouth reads Kindle books in the MOBI format (.mobi, .prc, and .azw) that are not copy-protected, with code of its own, the same on the Mac as on iOS.
- It reads the older format, MOBI 6, which Mobipocket books and the Kindle used before KF8.
- It also reads the newer format, KF8, which is what an .azw3 is (see Kindle books in the KF8 format, below).
- The Library window names all of them "Kindle Book (MOBI)".
- A copy-protected book is refused, never read: TextMouth does not try to remove copy protection (see [Adding books](adding-books.md) for the sentences).

### MOBI chapters
<!-- id: mobi-chapters; keys: ; src: -->

- Chapters come from the book's own table of contents, and an entry under a chapter's entry is a heading in that chapter, as in an EPUB.
- Words before the first entry are a chapter of their own.
- A book with no table of contents is a chapter for each page break its maker wrote.
- A chapter that begins with no heading is named by its entry, or "Chapter" and its number when it has none, and the name is never read aloud.

### MOBI title and author
<!-- id: mobi-title-author; keys: ; src: -->

- The title and author come from the book's own record of them.
- A book that gives no title is named by the title in its header, or by the file's name.
- What a book's head says about it, such as the title and publisher in an older book's metadata, is never read aloud: the words start where its body does.

### MOBI text and emphasis
<!-- id: mobi-text-emphasis; keys: ; src: -->

- The text is read in the encoding the book names, UTF-8 or Windows-1252 (Western European).
- Bold and italic text keeps its emphasis, as in the other text formats.
- A picture's description, when it has one, is read like the words around it, and a picture without one is silent, as calibre's are.
- The table of contents that calibre adds at the end of a book it converts is read as text at the end of the last chapter.

### PalmDOC books
<!-- id: palmdoc-books; keys: ; src: -->

- A PalmDOC book (.prc), the plain-text Palm format that MOBI grew from, is read as paragraphs of text in Windows-1252, unless its text is HTML, as an early Mobipocket book's is.
- A PalmDOC book whose text is HTML is read like any other Kindle book, so its markup is never spoken.

## Kindle books in the KF8 format
<!-- id: kindle-books-kf8-format; keys: ; src: -->

- TextMouth reads Kindle books in the KF8 format (.azw3, and a KF8 book named .mobi or .azw) that are not copy-protected, with code of its own, the same on the Mac as on iOS.
- The book's own headers decide the format, never its name.
- A KF8 book is made of the web pages of an EPUB, so it is read like one: a chapter for each page, with the headings the book's contents names.
- A copy-protected book is refused, never read (see [Adding books](adding-books.md) for the sentences).

### Hybrid Kindle books
<!-- id: hybrid-kindle-books; keys: ; src: -->

- Many .mobi files made for the Kindle hold a book twice: in MOBI 6, and in KF8.
- TextMouth reads such a file from its KF8 half, which keeps the book's structure and the levels its author gave the headings.
- The MOBI 6 half of such a file puts every heading at level 1 when calibre made it, and has no pages.
- When the KF8 half can't be read, for any reason except copy protection, TextMouth reads the MOBI 6 half instead.
- Copy protection is checked in both halves, so a book that is protected in either is refused.

### KF8 chapters
<!-- id: kf8-chapters; keys: ; src: -->

- Chapters come from the book's own pages: each page that holds words is a chapter.
- An entry in the book's table of contents that names a whole page titles that chapter.
- An entry that names a place inside a page is a heading there, at the level the book gives it, and in at most six levels.
- A chapter with no entry is titled by the title in its page's head, unless that repeats the book's own title, and otherwise "Chapter" and its number.
- A piece of a KF8 book that opens with no heading of its own, and that no entry of the contents names, joins the chapter before it only when it has the same title as the piece before it, or its title is the heading the next piece opens with. A piece that joins adds no heading of its own. Any other such piece is a chapter of its own, named by its title, and the book's first piece with words never joins anything.
- Tools such as calibre cut a long chapter into several pieces, and this rule puts the pieces back together. A paragraph that was cut in two is read as one paragraph.
- A page of links that a converter added to the end of a book, headed "Table of Contents", is left out, so it is not read aloud at the end. A last page that an author wrote, with words of its own, is always read.
- A contents or a guide that is damaged is left out, and the book is read without it.

### KF8 text and emphasis
<!-- id: kf8-text-emphasis; keys: ; src: -->

- The title, author, and language come from the book's own record of them, and a hybrid file is named from the half that is read.
- Bold and italic text keeps its emphasis, and lists and tables are read as in the other text formats.
- A picture's description, when it has one, is read like the words around it, and a picture without one is silent.
- The words in a picture drawn as SVG, which the Kindle's tools keep apart from the page, are read once, where the picture stood.
- Soft hyphens are left out of the text and of the headings.
- Lists of links that only help a person move through the book (its page list, its landmarks, and its contents) are not read aloud.
- Links are kept as written and never read aloud, and pictures, fonts, and style sheets are not read.
- A book with no text to read, such as one made only of pictures, is refused with "This file has no text to read."

## Kindle books in the KFX format
<!-- id: kindle-books-kfx-format; keys: ; src: -->

- TextMouth reads Kindle books in the KFX format (.kfx, .kfx-zip, .azw8, and an .azw file that holds KFX, as Kindle's apps name their KFX books) that are not copy-protected, with code of its own, the same on the Mac as on iOS, and the Library window names the format "Kindle Book (KFX)".
- A KFX book is read like a MOBI book, and into the same kind of chapters.
- A .kfx-zip, a ZIP that holds the parts of one book, is read as that one book.

### KFX chapters and headings
<!-- id: kfx-chapters-headings; keys: ; src: -->

- Chapters come from the book's own table of contents, and an entry under a chapter's entry is a heading in that chapter, as in a MOBI book.
- A heading's level is the one the book gives it, from 1 to 6.
- A chapter that begins with no heading is named by its entry, and the name is never read aloud.
- A part of the book that no entry starts and that begins with no heading continues the chapter before it, so a forced page break makes no new chapter.
- A first chapter that nothing names takes the book's title, and no heading is ever made up.

### KFX pages
<!-- id: kfx-pages; keys: ; src: -->

- Pages are the book's print page list, when it has one, as an EPUB's are, so Page works as it does there (see Pages, below).
- A page list that a machine made to approximate pages, which the book marks as such, is not read as pages.
- A KFX book that is an .azw file is read without pages.

### KFX emphasis, lists, and tables
<!-- id: kfx-emphasis-lists-tables; keys: ; src: -->

- Bold and italic text keeps its emphasis, and lists and tables are lists and tables, a table being read a row at a time.
- A footnote's text is read at the end of its chapter.
- A picture's description, when the book gives one, is read like the words around it, and a picture without one is silent.
- The title and author come from the book's own record of them.

### KFX copy protection
<!-- id: kfx-copy-protection; keys: ; src: -->

- A copy-protected book is refused, never read, and TextMouth never tries to remove the protection: "This Kindle book is copy-protected, and TextMouth can't read copy-protected books."
- This holds whether the protection is in the book's file, in a license file that sits beside it, or in any part of a book made of several.

### KFX books with no flowing text
<!-- id: kfx-books-no-flowing-text; keys: ; src: -->

- A book with no flowing text to read is refused: a fixed-layout book, a print replica, a comic, a magazine, a children's book, a textbook, a notebook, or a book whose pages are only pictures.
- The sentence is "This Kindle book has no flowing text to read, such as a comic or a print replica, so TextMouth can't read it."

### Kindle Create packages
<!-- id: kindle-create-packages; keys: ; src: -->

- A Kindle Create package (.kpf), the file an author makes before a book is published, is refused with its own sentence: "This file is a Kindle Create package, which TextMouth can't read yet."
- [Adding books](adding-books.md) gives every sentence.

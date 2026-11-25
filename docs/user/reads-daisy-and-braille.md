# What TextMouth reads: DAISY and braille books
<!-- id: reads-daisy-braille; keys: talking book, DTBook, NIMAS, BRF, BRL, PEF, liblouis; src: TextMouth/Parsers/DAISYParser.swift, TextMouth/Parsers/BrailleBookReader.swift, TextMouth/Parsers/XMLDocumentSniffer.swift -->

Part of [TextMouth's documentation](../../README.md).
Every format TextMouth reads, with how well each is tested, is in [the list of formats](formats-list.md).

## DAISY books
<!-- id: daisy-books; keys: DAISY 2.02, DAISY 3, ncc.html, OPF, SMIL, clock value, reading order; src: TextMouth/Parsers/DAISYParser.swift, TextMouth/Parsers/DAISYParser+SMILParser.swift, TextMouth/Parsers/DAISYParser+OPFParser.swift, TextMouth/Parsers/DAISYParser+TextExtraction.swift -->

- TextMouth reads DAISY books, versions 2.02 and 3: a book's folder, its navigation or package file (ncc.html or a .opf file), or a ZIP holding the book.
- A DTBook file on its own (.xml) imports as a book too, and so does a NIMAS package, which is a DTBook with its package file.
- A DAISY 3 book that holds several DTBook files is read in one order every time (since version 0.4.7): the package's reading order, else the order its SMIL files point at the files, else the order the package lists them.
  A file that none of these places comes last.
- A DAISY book's audio times may be written as clock values, as 0:02:43.650, as seconds, or, as SMIL allows, with a unit: "500ms", "38.228s", "2min", or "1h".
  Each unit reads as the time it names.
  A book's audio times are measured when it is imported, so a DAISY book gains them when it is imported again.

## XML files
<!-- id: xml-files; keys: DTBook, Word 2003 XML, PEF, root element, sniffing, refused; src: TextMouth/Parsers/XMLDocumentSniffer.swift, TextMouth/Services/FileImportService.swift -->

- TextMouth reads the start of each .xml file and names its kind by the element it begins with:
  - A DTBook goes to the DAISY reader.
  - Word 2003 XML goes to TextMouth's own Word 2003 XML reader.
  - A PEF braille file goes to the braille reader (below).
  - Any other XML is refused by name.

## Braille files
<!-- id: braille-files-read; keys: BRF, BRL, PEF, liblouis, Braille tab, table changed, Book Information; src: TextMouth/Parsers/BrailleBookReader.swift, TextMouth/Parsers/BrailleFileReader.swift, TextMouth/Services/BrailleTranslator.swift, TextMouth/Models/BrailleTableCatalog.swift, TextMouth/Phone/PhoneImportRefusal.swift, TextMouth/Services/BrailleTranslator.swift; status: incomplete; issues: FR33 -->

- TextMouth reads BRF files (.brf), BRL files (.brl), and PEF files (.pef), and BARD braille books of several BRF volumes (see BARD braille books, below).
- It translates them to print with liblouis, using the braille code chosen in the Braille tab of Settings (see [Settings](settings-braille.md)), and the print becomes a text book like any other, so it reopens, searches, and keeps its place, bookmarks, and skipped headings.
- A book keeps the code it was imported with, through Remove from Library Only and adding it back too, so changing the setting never changes what an imported book says.
- A book read with one of this Mac's tables (see [Settings](settings-braille.md)) also keeps the liblouis version of this Mac's tables, and if a macOS update changes them, TextMouth refuses to rebuild that book's text and keeps the text as it was, with this sentence.
  "This Mac's braille table “mac:fr-bfu-g2.ctb” has changed since the book was read with it, from liblouis 3.34.0 to 3.35.0, so TextMouth keeps the book's text as it was."
- When this Mac's tables name no version now, it says the table "may have changed since the book was read with liblouis 3.34.0" instead.
- A book that recorded no version is never refused for this.
- Each device keeps the version of the liblouis it read the book with, and is held to it.
  A table both apps carry, the four English ones, keeps none.
  A book read on an iPhone with another table keeps liblouis 3.39.0, the version inside the app.
  When the iPhone reads such a book again and its recorded version is another, as one a Mac read with VoiceOver's 3.34.0 is, it keeps the book's text as it was.
  It says "The braille table “mac:fr-bfu-g2.ctb” on this iPhone is liblouis 3.39.0, not liblouis 3.34.0 as when the book was read, so TextMouth keeps the book's text as it was."
- A table's stored value goes between a Mac and an iPhone as it is, and each device reads it with its own table of that name (see Braille settings in [Editing settings in config.json](config-json.md)).
- Book Info and Speak Info name the code, and Book Information's Braille Code pop-up reads one book again with another braille code (see [The Library window](book-information.md)).
- The iPhone reads BRF, BRL, and PEF books too, with liblouis inside the app, since an iPhone app can start no helper program.
  It reads with the table chosen in the Braille section of its Settings (see The iPhone's Braille section, in [Settings](settings-braille.md)), which offers the tables the app carries for many languages.
  It has no Braille Code pop-up in Book Information yet.
  A book from a Mac, sent in a TextMouth package or in a shared library, whose stored table is one of the Mac's own, is read with the iPhone's table of the same file name when the iPhone has one.
  When it has none, the iPhone refuses the book with "“NAME” needs “ru.tbl”, one of a Mac's own braille tables, which TextMouth on iPhone doesn't have.
  Add it on your Mac, then send the book here."
  The iPhone stops a translation by the same limits as the Mac, and one that runs 5 seconds past its limit is abandoned.
  Every later translation then says "TextMouth stopped the braille translation earlier because it took too long, and won't try again until TextMouth is closed and opened again."

### Guessing the braille code when a book is added
<!-- id: guessing-braille-code-when-book; keys: EBAE, UEB, auto-detect, guessed table, guess switch, Braille tab; src: TextMouth/Parsers/BrailleCodeDetector.swift, TextMouth/Models/BrailleTableOrigin.swift, TextMouth/Views/Settings/BrailleSettingsView.swift -->

- Many BRF files are old transcriptions in English Braille, American Edition, the code before Unified English Braille.
  Read as Unified English Braille, such a book reads wrongly with no error, as "to the sea" reading "!the sea".
- When you add a BRF or BRL file and the Braille tab's code is contracted Unified English Braille, TextMouth checks the braille for the signs of English Braille, American Edition.
  If the book clearly shows them, it is read with TextMouth's own contracted table for that code, English Braille, American Edition, contracted (Grade 2), in place of the Braille tab's code.
  - TextMouth counts only signs that Unified English Braille dropped: "to" or "by" joined to the next word, and "ation" or "ally" inside a word.
  - Clearly means at least 40 words with those signs, at least one in 50 of all the book's words, and, of those, at least 5 words joined with "to" and at least 5 joined with "by".
  - When TextMouth is unsure, nothing changes: the book is read with the Braille tab's code, and Book Information may still suggest English Braille, American Edition (see [The Library window](book-information.md)).
- The switch "Guess the braille code of new books" in the Braille tab turns the guess off (see [Settings](settings-braille.md)).
  It is on by default.
- Only a book being added is guessed.
  A book already in the library keeps its code, and the launch's reading again of braille books never guesses.
- A PEF file is never guessed, and neither is a book read with a code other than contracted Unified English Braille.
- A guessed book's title and author, read from its title page, are read with the guessed code too.
- Book Info, Speak Info, and Book Information say the code was guessed: "English Braille, American Edition, contracted (Grade 2), guessed".
  Book Information can keep the guess or correct it (see [The Library window](book-information.md)).
- A guessed book that you remove with Remove from Library Only and add back keeps its code and the word "guessed", without a new guess.
  A book you chose a code for, in Book Information, is never said to be guessed.

### Braille file characters
<!-- id: braille-file-characters; keys: Braille ASCII, Eurobraille, Unicode braille patterns, U+2800, seven-bit, ascii-na; src: TextMouth/Parsers/BrailleFileCode.swift, TextMouth/Models/BrailleFileCodeRecord.swift, TextMouth/ViewModels/BrailleFileCodeChoiceModel.swift -->

- A BRF or BRL file is read in one of three codes, which the book records:
  - North American Braille ASCII is the default and the code of nearly every file.
  - Eurobraille, six-dot (German-speaking countries) is the other seven-bit code.
  - Unicode braille patterns write each cell as a character from U+2800 to U+28FF, in UTF-8.
- TextMouth recognizes Unicode braille patterns by the file's bytes, from the first character after any blank lines in the first 64 KB, and reads such a file as them whatever the Braille tab says.
- It guesses nothing else, since every printable ASCII character is a cell in every seven-bit code: a file read in the wrong seven-bit code gives wrong numbers and punctuation, with no error.
- The Braille tab chooses the seven-bit code for the books you add from then on (see [Settings](settings-braille.md)), and Book Information's Braille File Characters pop-up reads one book again with another code (see [The Library window](book-information.md)).
- A PEF always holds Unicode braille and needs no choice.

### Books that record no braille code
<!-- id: books-that-record-no-braille; keys: eight-dot, dot 7, dot 8, computer braille, UTF-16, refused, old books; src: TextMouth/Parsers/BrailleFileReader.swift, TextMouth/Parsers/BrailleFileCode.swift -->

- A book that records no code, as every book added before TextMouth recorded them, is read as North American Braille ASCII, unless its first character is a braille pattern, which can only be Unicode braille patterns: such a book is read as them.
- A BRF or BRL file of Unicode braille patterns that uses dot 7 or 8 is eight-dot braille, which TextMouth refuses.
  So is a file of eight-bit computer braille, and so is a file in UTF-16, each refused by name (see [Adding books](import-progress-and-errors.md) for the sentences).

### What a BRF or BRL file holds
<!-- id: what-brf-brl-file-holds; keys: CR LF, form feed, 25 lines, tab, eight-dot PEF; src: TextMouth/Parsers/BrailleFileReader.swift, TextMouth/Parsers/BrailleCells.swift, TextMouth/Parsers/BrailleBookReader.swift -->

- A BRF or BRL file holds one character for each braille cell, in the braille file characters above, in upper or lower case for braille ASCII, with each line ended by CR LF, LF, or CR.
- A tab counts as one blank cell.
- A BRF ends each page with a form feed, and a BRF with none is cut into pieces of 25 lines to read its layout (see [Pages](reads-pages-and-limits.md)).
- A BRL has no layout, so each of its lines that is not blank is a paragraph and it has no headings.
- A PEF file must be six-dot braille: eight-dot PEF is refused.

### Braille layout
<!-- id: braille-layout; keys: BANA Braille Formats, centered, cell 5, cell 7, indent, running head, print page; src: TextMouth/Parsers/BraillePageAnalyzer.swift, TextMouth/Parsers/BrailleBookReader.swift, TextMouth/Parsers/BrailleBookReader+Pages.swift; status: incomplete; issues: DR08 -->

- Headings, paragraphs, and list items are found from the layout, as BANA's Braille Formats (2016) lays it out.
- The width of a page is measured from the book's own pages: from the page numbers at the right margin where the pages have them, else from the longest lines.
  A few stray long lines, on up to one page in twenty, are left out of that measure, so they no longer widen the page and leave centered headings and page numbers out of their place.
- A centered line, or a centered run of lines, is a level-1 heading.
- A line at cell 5 is a level-2 heading, and a line at cell 7 is level 3.
- Paragraphs and list items are found from their indents, and each list item is read as a paragraph.
- Page numbers are left out of the text, so they are never spoken.
- A running head is left out of the text too.
  A running head is the line at the top of each page that repeats the book's title or the chapter's, with a page number at one end of it.
  TextMouth takes it for one only when its words repeat on three or more pages, so a line of the book's own text is never left out for looking like one.
  A head that changes from page to page only by a part or volume number, such as "life of pi. part1" and "life of pi. part2", counts as one head, and a line with no page number at either end is never taken for one.
- A page number at the left of the top line becomes the braille page number when the page's last line has none.
- A line that marks where a print page changes, a row of dashes with a number after it, is left out of the text, whether the number is Arabic or Roman, as in ";IX" for the print page ix.
- A chapter heading that stands on the line above its text is a heading.
  When one to three centered lines run straight into a line indented to cell 3, with no blank line between, they are a level-1 heading, as "Chapter 1" on the line above a paragraph.
  A row of dashes or other rule marks that sets the heading off is never part of its words.

### Braille emphasis
<!-- id: braille-emphasis; keys: typeform, italic, bold, UEB, EBAE, emphasis end sign, TextMouthBraille; src: TextMouth/Parsers/BrailleEmphasis.swift, TextMouth/Services/BrailleTranslator.swift, TextMouthBraille/main.c; status: incomplete; issues: DR10 -->

- Reading Unified English Braille (UEB) keeps what its emphasis signs say, and reading English Braille, American Edition (EBAE) keeps what its signs say where they are certain.
- In UEB, italic and bold come into the book's text as italic and bold, and both together as both.
- In UEB, underline, script, and the typefaces a transcriber defines come in as italic, the nearest thing the text holds.
- As in the other text formats, the marks that show emphasis are never spoken.
- Contracted (Grade 2) UEB reads a whole-word contraction just before an emphasis end sign as the word it is: "people" comes back as "people", not "p", and "his" as "his", not a double quotation mark.
- In EBAE, italic and bold are read where the sign is certain: words that start with l or with n to z, capitals, numbers, and most contractions.
- In EBAE, a passage of several words ends where its last sign says.
- The signs liblouis writes for bold italic, which BANA's EBAE has not got, are not read as bold italic.
- Emphasis changes no word of an EBAE book: the emphasis is what is new.
  The fixes below do change words, in contracted EBAE only.
- Where a sign cannot be told from print, it is left as it was:
  - An emphasized word that starts with a to j still reads with a stray period, as in ".cat" for an italic "cat".
  - One that starts with k reads with an equals sign, as in "=ite" for "kite".
  - One that starts with m reads with µ, as in "µe" for "me", in uncontracted EBAE.
    In contracted EBAE an italic word that begins with m is read as italic, so "mama" is italic "mama" (see English Braille, American Edition words, below).
  - The emphasis on those words is lost.
- TextMouth checks each paragraph against liblouis's own reading, and a paragraph whose words would differ in any character is read without emphasis.
- Most of this Mac's tables are read as plain braille, since liblouis cannot read their emphasis back exactly.
- The EBAE reading applies to a table of this Mac's that writes EBAE's signs and reads the sign alone as punctuation, as its English EBAE tables do.
- TextMouth's braille helper tests each table for this when the table is used, so none is picked out by name.
- The faults of liblouis itself in reading EBAE remain, as a decimal such as 3.5 that comes back as "3.e".
- A braille book is read again once at the first launch of version 0.2.2, and gets this reading then.
- A book whose new reading differs from its text keeps a copy of its old text beside it, and its saved places follow their words (see [Where TextMouth keeps your library](book-packages.md)).
- Redo Text Extraction reads a book again at any time.
- Export writes a book's emphasis into braille in UEB, and writes none in EBAE (see [Exporting books](exporting-braille.md)).

### English Braille, American Edition words
<!-- id: english-braille-american-edition-words; keys: EBAE fixes, en_US table, initials, St., still, before, micro sign; src: TextMouthBraille/main.c, TextMouth/Services/BrailleTranslator.swift; status: incomplete; issues: DR12 -->

- A book in contracted (Grade 2) English Braille, American Edition, read with a table that writes it, such as an English EBAE table of this Mac's, is read with fixes for what liblouis's own EBAE table misreads.
  Uncontracted EBAE, Unified English Braille, and every other table are read as they were.
- Words that EBAE writes joined are read as separate words: "of the", "and the", "of a", "with a", "for the", and "with the", where they read run together as "ofthe".
  A name such as Thea, which is the signs for "the" and "a" with a capital, stays one word.
- "ing" before a hyphen or dash is read as "ing": "moving-in", where it read "mov±in".
- Initials with periods between single letters are read as letters and periods: "p.b.u.h." reads "p. b. u. h.", where the table read each period between letters as "dd".
  Each letter and its period are now a word apart, so the book's text holds "e. g." with a space, and a search in the book or the library for "e.g." won't find it: search for "e. g." instead.
- "St." and "Still." are told apart.
  "St." is read only where it stands before a capitalized word ("St. Paul") or after a capitalized word that does not end a sentence ("Main St.").
  Any other such sign is "still."
- The sign for "before" at the start of a longer word is read as "bef", as in "befuddled", where it read "beforeuddled".
  "Beforehand", "beforetime", and "beforetimes" keep "before".
- A micro sign before a unit stays µ: "5 µm", "10 µmol", and units written with it, as µg, µs, µL, and µHz.
  An italic word of two or more letters that begins with m, and does not follow a number, is read as italic: "mama", and not "µama".
  A micro unit with no number before it cannot be told from such a word, so it reads as italic.
- Computer braille, between its begin and end signs, is left as it was.
- A braille book is read again once for these, with the page and title changes above, at the first launch after the update that added them (0.4.8).

### Titles and authors of PEF, BRF, and BRL files
<!-- id: titles-authors-pef-brf-brl; keys: title page, by, Unknown author, metadata refresh, first 64 KB; src: TextMouth/Parsers/BrailleTitlePage.swift, TextMouth/Parsers/BrailleFileReader.swift -->

- A PEF names its book's title and author in its head, and the import reads them from the first 64 KB of the file.
- A BRL names neither, so its book is titled by its file's name without the extension, and its author is Unknown.
- A BRF names them on its title page, if it has one, and the import and the launch read them there:
  - The title page is the first page with anything on it, and TextMouth reads its centered lines.
  - A line that holds the word "by" divides the title from the author: "Life of Pi" above "by Yann Martel", or "Life of Pi by Yann Martel" on one line.
    "By" is read as a braille word, spelled in both codes and as its own sign in English Braille, American Edition.
  - A title page with no "by" names a title only when it has three or more centered lines and a rule line that sets the title off.
    A page that is only a part title, a chapter heading, and an epigraph names nothing, so a chapter saved alone keeps its file's name.
  - What the page names, with no title or no author, leaves that one as it was: the file's name or Unknown.
  - The title and author are read with the book's own braille code, and they are never longer than a title could be: anything over 200 characters is a paragraph, not a name.
  - A title or author you changed yourself is never replaced.
    For a book added before TextMouth kept a record of your edits, the launch fills in only an author that says Unknown, and leaves the title alone.
- Every braille book is read again once for this, at the first launch after the update that added it (0.4.8), so a BRF added before it gets its title and author, and its text loses its running heads and change lines.
  Every braille book is read again once more at the first launch of 0.4.9 (braille page reader 1.1.1), for the running heads that differ only by a number.
  Every braille book is read again once more at the first launch of 0.5.11 (braille page reader 1.1.2), so a few stray long lines no longer widen its pages (see Braille layout, above).

### BARD braille books
<!-- id: bard-braille-books; keys: BARD, .bopf, braille package, volumes, NLS BARD Braille Package, Volume 1, spine, Import Folder; src: TextMouth/Parsers/BardBraillePackage.swift, TextMouth/Parsers/BrailleBookReader+Pages.swift, TextMouth/Parsers/BrailleFileReader.swift, TextMouth/Models/Book.swift, TextMouth/Services/FileImportService.swift -->

- A BARD braille book is a braille book in volumes, as the BARD service gives it: one BRF file for each volume, and one package file ending in .bopf that names the volumes, puts them in order, and describes the book.
  Finder calls a .bopf file an "NLS BARD Braille Package".
- TextMouth imports the volumes and their package as one braille book, whichever you give it:
  - the ZIP of the download, with Open Book…;
  - the folder it unpacks to, with Import Folder…;
  - or, on the Mac, the .bopf file itself, with Open Book…, in which case TextMouth keeps the volumes the package lists, from beside it, and nothing else of the folder.
- The iPhone takes the ZIP, or the folder with Import Folder… in the Add to Library sheet, and offers no lone .bopf, since it copies only the file you choose, and a package file alone would arrive without its volumes.
- The volumes are read in the order the package gives, and each begins with a level-1 heading, "Volume 1", "Volume 2", and so on, in English whatever the book's language.
  The book's own headings sit one level below, so its level-1 headings are level 2, and none is deeper than level 6.
- Its title and author come from the package, not from a title page, and its publisher, date, language, and identifier are kept with the book, as an EPUB's are.
- Its braille code comes from the package, whatever the Braille tab says, and is never said to be guessed.
  - English Braille, American Edition, contracted (Grade 2) or uncontracted (Grade 1).
  - Unified English Braille, contracted (Grade 2) or uncontracted (Grade 1).
  - For any other code, or none, the book is read as any BRF is, with the Braille tab's code or the guess described above.
- The width of a page is measured from the volumes' own pages (see Braille layout, above), and never taken from the package, whose line length need not be the width the braille was laid out in.
- A ZIP and its folder are one book: whichever you add second is found a duplicate of the first (see [Duplicate books](duplicate-books.md)).
- A volume that the package lists and the book lacks, an empty volume, or one that is not braille in the book's code is refused by name, as in "The file “NAME.brf” in this book is damaged or incomplete: the book's package lists it, but it is not there.
  Get a fresh copy of the book, then import it again."
- A ZIP with two package files side by side is refused, since no one book is meant: "The file “NAME.bopf” in this book is damaged or incomplete: it is one of 2 package files at the same level, so no one book is meant.
  Get a fresh copy of the book, then import it again."
  NAME is one of the two; the number is how many stand at that level.
- The volumes together are held to the 32 MB limit of a braille file (see Braille file limits, below).

### Braille file limits
<!-- id: braille-file-limits; keys: 32 MB, page limit, row limit, refusal; src: TextMouth/Parsers/BrailleFileReader.swift, TextMouth/Parsers/BrailleBookReader.swift -->

- A braille file of more than 32 MB is refused, and so is one of more than 100,000 pages or 4,000,000 lines (see [Adding books](import-progress-and-errors.md) for the words of each refusal).

### Braille not read yet
<!-- id: braille-not-read-yet; keys: hyphenated words, divided words, lists, plain paragraphs; src: TextMouth/Parsers/BraillePageAnalyzer.swift, TextMouth/Parsers/BrailleBookReader.swift; status: incomplete; issues: DR07, DR08 -->

- Words divided at a line's end are not read yet.
- A list laid out by another tool may read as plain paragraphs.

### The braille helper process
<!-- id: braille-helper-process; keys: TextMouthBraille, helper, separate process, timeout, hang; src: TextMouth/Services/BrailleTranslator.swift, TextMouthBraille/main.c -->

- liblouis runs in a separate process that TextMouth watches, never inside TextMouth, so a hang or a crash in liblouis costs that process and never TextMouth or the import.
- [Where TextMouth keeps your library](helper-programs.md) gives its limits.

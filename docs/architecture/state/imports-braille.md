# Imports: braille files
<!-- id: imports-braille-files; keys: Braille Ready Format, Portable Embosser Format, embosser, braille book, Unicode braille, braille import; src: -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## Braille files
<!-- id: braille-files; keys: embosser file, braille book, braille import, liblouis, fingerprint; src: TextMouth/Parsers/BrailleBookReader.swift, TextMouth/Parsers/BrailleFileReader.swift, TextMouth/Services/BrailleTranslator.swift, TextMouth/Services/FileImportService.swift -->

Braille files (FMT20, FMT21): BRF, BRL, and PEF books, which become Markdown through liblouis, are indexed, and are fingerprinted as a Word document is.
Exports writes braille too (see [Exports](exports.md)); the Braille setting is under [Preferences](preferences.md).

### The format
<!-- id: format; keys: UTType, UTI, document types, file extensions, XML root; src: TextMouth/Models/Book.swift, TextMouth/Parsers/XMLDocumentSniffer.swift, TextMouth/Services/FileImportService.swift, TextMouth/Resources/Info.plist, TextMouthProductionTests/DocumentTypeDeclarationTests.swift -->

The format: BookFormat.braille (raw value "braille", displayName "Braille", extensions brf, brl, and pef) is written into library.json and bookInfo.json and never changed, and a build from before it cannot decode the index (Index-write suspension, in [The library index](library-index.md)).
BookFormat.detect(from:) names a .brf, .brl, .pef, or .bopf by its extension, and a loose .xml by XMLDocumentSniffer, whose pef root gives braille.
Its extensions also name bopf, a BARD braille book's package file, and a folder or ZIP of such a book is braille too (BARD braille books, below).
Info.plist makes BRF, BRL, and PEF document types at Alternate rank and imports the types com.textmouth.brf and com.textmouth.brl (conforming to public.plain-text) and org.daisy.pef (public.xml).
FileImportService.supportedTypes offers them in Open Book with whatever type the system gives a .pef, which macOS takes for a Pentax raw photo, and the reading tells the two apart.

### Reading a braille file
<!-- id: reading-braille-file; keys: read braille book, BRF parser, PEF parser, braille page, heading detection, 32 MB limit, Markdown cache; src: TextMouth/Parsers/BrailleBookReader.swift, TextMouth/Parsers/BrailleBookReader+Pages.swift, TextMouth/Parsers/BrailleFileReader.swift, TextMouth/Parsers/BraillePageAnalyzer.swift, TextMouth/Parsers/BrailleFileCode.swift, TextMouth/Models/BrailleFileCodeRecord.swift, TextMouth/Services/BrailleTranslator.swift, TextMouth/Parsers/BrailleEmphasis.swift, TextMouth/Parsers/MarkdownEmphasis.swift, TextMouth/Parsers/MarkdownLiteral.swift, TextMouth/Parsers/BookParser.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouth/Services/BookContentAnalysisService.swift, TextMouth/Parsers/DocumentByteLimit.swift, TextMouth/Models/PageReaderVersions.swift, TextMouthProductionTests/BrailleFileReaderTests.swift, TextMouthProductionTests/BraillePageAnalyzerTests.swift, TextMouthProductionTests/BrailleBookPageTests.swift, TextMouthProductionTests/BrailleImportTests.swift -->

Reading: BookParser.parse(url:format:brailleTable:brailleTableVersion:brailleFileCode:encodingPolicy:), through BrailleBookReader.parse, and MarkdownCacheService.extractCache both read through BrailleBookReader.markdown(of:table:recordedVersion:fileCode:includesPages:).
So the direct parse and the cache read the same text.
For a BRF or BRL the book's braille file code is resolved first, by BrailleFileCode.code(forStored:) (nil or empty is North American Braille ASCII), and an id this TextMouth does not know is refused by name, BrailleFileError.unknownFileCode, before the file is read; a PEF ignores the code.
The cache passes the row's code when the read decides the code (an import, a re-read with other braille file characters) and Book.recordedBrailleFileCode() otherwise.
A book that records none is read through Book.brailleFileCodeForReading(), which asks BrailleFileReader.certainCode(ofFileAt:) and gives unicode only when the file's first character is a braille pattern.
So a Unicode book whose code an earlier TextMouth dropped heals at its next rebuild.
The three rebuild paths of MarkdownCacheService and BookContentAnalysisService use it.

1. requireSizeWithinLimit(of:) refuses a file over maximumFileBytes, 32 MB, by the size of its target (a link is sized by what it points to), before a byte is read (BrailleFileError.fileTooLarge).
2. BrailleFileReader.read(_:as:) reads the file, held to DocumentByteLimit too, into BrailleFilePages: one buffer of cell bytes with 32-bit offsets for its rows and pages, at most maxPages (100,000) pages and maxRows (4,000,000) rows (tooManyPages and tooManyRows).
   BrailleBookReader.kind(of:) gives .brl for brl, .pef for pef and xml, and .brf for any other.
   A BRF or BRL goes through one TextScanner for every braille file code, read by BrailleFileReader.read(_:as:code:) and pages(fromText:kind:code:).
   A seven-bit code is a table lookup for each byte, SevenBitBrailleTable, aliases and either case included, and Unicode braille patterns are three bytes each, with the space as a blank cell.
   A line ends at CR LF, LF, or CR.
   A tab is a blank cell.
   A form feed between braille text ends a BRF page and marks its pages (BrailleFilePages.marksItsPages), while a BRF with none, a form feed only at its start or end being none, is cut into pieces of 25 rows (linesPerUnmarkedPage) only so that its layout can be read.
   A UTF-8 byte order mark and a final Ctrl-Z are dropped.
   A PEF goes through an XMLParser (PEFCollector, with no external entities).
   Both stop at the first refusal (BrailleFileError, each case with its conditions in BrailleFileReader.swift; utf16Text, for a byte order mark, is checked first).
   The words of the refusals are in [Adding books](../../user/import-progress-and-errors.md).
   BrailleFileReader.certainCode(of:) reads the first 64 KB (detectionByteCount) and gives unicode when the first character after the blank lines is a braille pattern, and nothing else, since the seven-bit codes' bytes are the same printable characters.
### Finding the blocks of a braille file
<!-- id: braille-blocks; keys: BraillePageAnalyzer, running head, page number, print page change, chapter row, heading level, block structure; src: TextMouth/Parsers/BraillePageAnalyzer.swift, TextMouthProductionTests/BraillePageAnalyzerTests.swift -->

3. BraillePageAnalyzer.structure(of:), pure and bounded, finds the blocks.
   A BRL is unformatted: each row that is not blank is a paragraph.
   Otherwise it takes the line width from a PEF's cols, else from the rows that end in page numbers, else from the longest line, which leaves out the longest lines of up to one page in twenty (`longestLine(ofPages:)`), or the centered headings.
   It takes each page's braille page number, print page number, and print-page change lines out of its rows (BraillePageNumbers, with where the page begins: its first block, and the cell of that block's braille its first row begins at, firstCellOffset, PG12).
   BraillePageNumbers.braillePageLabel reads the braille page number as print through BraillePageAnalyzer.printLabel(of:), cell by cell.
   The cells are letters, then the number sign with its digits (a to j for 1 to 9 and 0), then letters, a capital sign or a letter sign standing where one is needed, as "⠼⠁⠃" reads 12 and "⠏⠼⠁" reads p1.
   The label is nil for a word with a second number, a cell outside these, an indicator with no letter after it, or no digit, and the page is then labelled by its place among the pages kept.
   BraillePageNumbers.hasText says whether the page holds text.
   The print page numbers are kept for a later move by print page, and a page is a braille page whatever print pages it holds.
   The analyzer reads centered runs of rows first, so a title of several lines is one level-1 heading, then rows at cell 5 and cell 7 as level-2 and level-3 headings, and the rest as paragraphs, with the runovers of paragraphs and list items.
   It drops the blank rows at a page's top, except in a book of block-style paragraphs.
   It also applies three rules of layout.
   (a) Running heads (see Running heads, below): extractNumbers(fromPage:width:dropsTopBlankRows:runningHeads:) takes the head's row out of the page's text, and takes its left number word as the braille page number when the page's last row held none.
   (b) Print-page change lines: a Roman numeral word (isRomanNumeralWord: a letter sign or a capital sign, then one to maxNumberWordLength of i, v, x, l, c, d, and m) ends a change line like a number word, so ------;IX is left out of the text.
   (c) Chapter rows: a centered run of at most maxRunOnHeadingRows (3) rows of text that no blank row follows and that runs straight into an indented row (indent 2, cell 3) is a level-1 heading (runsOnIntoIndentedText(_:)), as a transcriber writes "Chapter 1" on the line above its text.
   A rule row (isRule(_:in:): at least minRuleCells (4) of one cell among dots 5, 2-5, 3-6, 4-5-6, and all six) is never part of a heading's text, and a run of rules alone makes no heading.

### Translating a braille file and marking its pages
<!-- id: braille-translating-pages; keys: markdown, emphasis, includesPages, page marker, PagedTranslation, form feed, Markdown literal; src: TextMouth/Parsers/BrailleBookReader.swift, TextMouth/Parsers/BrailleBookReader+Pages.swift, TextMouth/Services/BrailleTranslator.swift, TextMouth/Parsers/BrailleEmphasis.swift, TextMouth/Parsers/MarkdownEmphasis.swift, TextMouth/Parsers/MarkdownLiteral.swift, TextMouthProductionTests/BrailleBookPageTests.swift, TextMouthProductionTests/BrailleImportTests.swift -->

4. BrailleTranslator.translate turns each block's cells into print ([The translator and the helper](imports-braille-tables.md)).
   BrailleBookReader.markdown(of:table:recordedVersion:) then trims each translation, writes a heading as an ATX heading of its level and every other block as a paragraph, each as a Markdown literal (MarkdownLiteral.escaped) so text that looks like Markdown reads as written.
   It joins the blocks with a blank line.
   It writes the emphasis the helper read from the braille's indicators as Markdown's own (markdownLine(of:)).
   BrailleEmphasis.markdownStyle maps italic, underline, script, and the transcriber typefaces to Markdown's italic, bold to its bold, and both to both, through MarkdownEmphasis.markdown, whose delimiters CommonMark always pairs, so none is spoken.
   Keeping emphasis changes no word by itself, since Markdown's delimiters are never text (BrailleImportTests pins it), and the helper's pass for EBAE's signs ([The EBAE fix pass](imports-braille-tables.md)) keeps every word liblouis reads alone.
   Only its pass for UEB's emphasis terminators changes words, where liblouis misread them, so a book's text can change with the better reading, by its emphasis or, in contracted UEB, by a word.
   No cache version was raised: a braille book imported before keeps its content.md until something rebuilds it, which braille's page reader line does once at the next launch (V07, in [Text caches](text-caches.md)).
   PG16's compare then keeps a copy of the old text of a book whose new reading differs, even by emphasis alone, and its saved places move with the text.
   A book with no blocks or no print text throws FileImportError.noTextToRead.
5. With includesPages, which only MarkdownCacheService asks for (it is false otherwise, so the direct parse reads the text alone), each braille page of a file that marks its pages is a page marker (BrailleBookReader+Pages.swift, PG12).
   BrailleBookReader.marksItsPages(_:_:) says which files do: a PEF by its page elements, a BRF by the form feeds between its braille text, or, in a BRF with none, braille page numbers that end more than half of its 25-row pieces.
   That shows the cut matches its layout, since the pieces are otherwise no pages an embosser counts and naming them would invent pages.
   A BRL has none.
   BrailleBookReader.pageStarts(of:) leaves out a page with neither text nor a braille page number, such as the blank back of a two-sided page or the empty page a form feed leaves at a file's start or end.
   It labels the others by BraillePageNumbers.braillePageLabel or, without one, by their place among the pages kept, so a book without numbers reads from 1 up to the number of pages kept.
   BrailleBookReader.PagedTranslation puts the markers between block lines, never inside one, writing the markers that share a place at once and looking each page's cut up, so many pages cost linear time.
   A page that begins a block, or begins inside a heading, is a marker of its own before it.
   One that begins inside a paragraph splits the paragraph's Markdown into lines there, each its own literal with its own emphasis, the marker after the words of the line before, so the lines read as one paragraph.
   Every block is still translated whole, so pages change no word.
   Each paragraph a page begins inside is also sent in pieces cut at those pages' first cells, in the same run of the helper.
   BrailleBookReader.places(ofCutsIn:pieces:) finds each page in the whole paragraph's print, from the start and then from the end, or else places it at the last place found before it, never after its first word.
   That happens, for example, when an indicator's passage goes on over the page and only the piece that holds the indicator reads it.
   Nothing is logged then.
   A BRL has no pages, and its book is read again with the other braille books when braille gains its page reader (PageReaderVersions, in [Text caches](text-caches.md)).

### The table
<!-- id: table; keys: braille table setting, stored value, liblouis table, Braille Code pop-up, mac prefix, table choice; src: TextMouth/Models/BrailleTableCatalog.swift, TextMouth/Models/Book.swift, TextMouth/Models/BookInfo.swift, TextMouth/Models/RemovedFromLibraryMarker.swift, TextMouth/Services/FileImportService.swift, TextMouth/ViewModels/LibraryViewModel+TextEncoding.swift, TextMouth/Phone/PhoneImportRefusal.swift; status: incomplete; issues: FR33 -->

The table: Book.brailleTable, a stored value (BrailleTableSource) such as "en-ueb-g2.ctb" for a bundled table or "mac:fr-bfu-g2.ctb" for one of this Mac's, which names the "mac:" prefix in one place, in the row and in BookMetadata.brailleTable, is the table the book was imported with.
FileImportService.importFileWithReport stamps the table that FileImportService.brailleReading(ofImported:) decides: BraillePreferences.importTable(), the Braille setting at that import.
When the guess applies ([The guess of English Braille, American Edition](imports-braille-tables.md)), it stamps the bundled contracted EBAE table instead.
Every later reading uses the stamped table, the cache's rebuild included, so a change of the setting never moves a book's text under its places.
Only the listener's own choice changes it later: Book Information's Braille Code pop-up reads the book again with another table (TextRereadChoice.brailleTable, in [Text caches](text-caches-rereads-edits.md)), which Replace Existing then carries to a new copy of the same bytes.
Nil reads as BrailleTableCatalog.defaultTableID.
On the iPhone the same reading runs inside the app (see [The translator on the iPhone](imports-braille-tables.md#the-translator-on-the-iphone)): BrailleBookReader.markdown first refuses a stored "mac:" table whose file name the iPhone's pack lacks (PhoneImportRefusal.refuseMacBrailleTable).
It reads any other with the pack's table of that name.
The iPhone's setting is chosen in its Settings, and it has no pop-up that changes a book's table (FR33).
A platform never rewrites a stored value it reads (see [Stored values on each platform](braille-table-pack.md#stored-values-on-each-platform)).
The record keeps it (see [Package records](package-records.md)), and so does the removal marker (Retirement markers, in [The library index](library-index.md)).

### The file code
<!-- id: file-code; keys: braille file characters, Braille ASCII, Eurobraille, Unicode braille, character set, braille encoding; src: TextMouth/Parsers/BrailleFileCode.swift, TextMouth/Models/BrailleFileCodeRecord.swift, TextMouth/Models/Book.swift, TextMouth/Models/BookInfo.swift, TextMouth/Models/RemovedFromLibraryMarker.swift, TextMouth/Models/TextEncodingChoice.swift, TextMouth/Models/BrailleTableCatalog.swift, TextMouth/Services/FileImportService.swift, TextMouth/ViewModels/LibraryViewModel+TextEncoding.swift, TextMouth/ViewModels/BrailleFileCodeChoiceModel.swift, TextMouth/Views/Library/LibrarySheetViews.swift, TextMouth/Services/DuplicateReplacement.swift, TextMouth/Parsers/BraillePageAnalyzer.swift, TextMouthProductionTests/BrailleFileCodeTests.swift, TextMouthProductionTests/BrailleFileCodeRecordTests.swift -->

The file code: Book.brailleFileCode, a stored id (BrailleFileCode.id: ascii-na, ascii-eurobraille, or unicode), kept in the row, in BookMetadata, and in the removal marker, for a BRF or BRL book (Book.offersBrailleFileCodeChoice: not a PEF, never a feed's item).
FileImportService.brailleFileCode(ofImported:) gives it at an import: the code the file's bytes say for certain (certainCode(ofFileAt:)), else BraillePreferences.importFileCode(), the Braille setting's.
That setting reads only the two seven-bit codes (BrailleFileCode.importChoices) and is North American Braille ASCII otherwise, by an explicit id, North American's included, so a later change of the setting never moves a book's text.
A PEF records none.
A value of nil is a book that records no code.
The record decides apart from the row.
The standing rule is the record's code when it names one, else the row's (BrailleFileCodeRecord.standing(row:recorded:)), and a re-read with other characters is the one save that decides anew (decidingBrailleFileCode, beside decidingTextEncoding; see [Package records](package-records.md)).
Book Information changes it through BookRereadPopUp and BrailleFileCodeChoiceModel, which share the Text Encoding pop-up's re-read, LibraryViewModel.readTextAgain(bookID:choosing:access:) for a TextRereadChoice (see [Windows](windows-sheets.md)).
Replace Existing keeps it, unless the copy's bytes are certainly Unicode (DuplicateReplacement.brailleFileCodeToReadAgain(replacing:with:), in [Reading the new copy again](imports-duplicates.md)).
BraillePageAnalyzer.printLabel(of:) reads a page number's cells through SevenBitBrailleTable.northAmerican by name, whatever the book's code, since the cells are what count, so a Eurobraille book's pages get the same labels.

### The version
<!-- id: version; keys: liblouis version, table version, rebuild refusal, property list, system update; src: TextMouth/Models/BrailleTableCatalog.swift, TextMouth/Parsers/BrailleBookReader.swift, TextMouth/Parsers/BookParser.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouth/Models/Book.swift, TextMouthProductionTests/MacBrailleTableBookTests.swift -->

The version: Book.brailleTableVersion, kept the same three ways, is the liblouis version the book's table was read with on the platform that read it (BrailleTableCatalog.versionToRecord(forTable:), from liblouisVersionRead(forTable:)).
- A table read from this Mac's folder, a "mac:" value or a bare one only VoiceOver has, records the Mac's version (the OpenSourceVersion of the property list beside the Mac's tables).
- Any other table the iPhone reads records BrailleTableCatalog.bundledLiblouisVersion, a "mac:" value the iPhone reads with its own table included.
- Nil for a table both apps carry (tablesOfEveryPack), for a bundled table on the Mac, and when the Mac's tables name none.

A rebuild reads through BrailleBookReader.requireUnchangedTable(_:recordedVersion:), which BookParser.parse and MarkdownCacheService.extractCache reach through markdown(of:table:recordedVersion:).
It compares the recorded version with the one this platform reads the table with now, and throws Failure.changedTable when they differ, or when the Mac's names none; the old content.md stays.
Failure.changedTable is worded by the platform that reads: the iPhone's sentence names this iPhone and its own liblouis, never "This Mac's".
A book with no recorded version is not refused.
Book.bookInfo(replacing:) keeps the stored record's version only when the row names the same table as the record, so a book read again from one of this Mac's tables to a bundled one records no version, and never keeps the Mac table's, which would have refused its later rebuilds.

### Names
<!-- id: names; keys: title page, braille title, metadata refresh, Unknown author, reader stamp; src: TextMouth/Parsers/BrailleTitlePage.swift, TextMouth/Parsers/BrailleFileReader.swift, TextMouth/Parsers/BraillePageAnalyzer.swift, TextMouth/Services/FileImportService.swift, TextMouth/Services/FileImportService+Packages.swift, TextMouth/ViewModels/LibraryViewModel+MetadataRefresh.swift, TextMouthProductionTests/BraillePageAnalyzerTests.swift, TextMouthProductionTests/MetadataRefreshTests.swift -->

Names: ImportedFileMetadata.read takes a PEF's title and author from its head (BrailleFileReader.pefMetadata(of:), the first 65,536 bytes: dc:title and dc:creator).
A BRL names neither, so the book keeps its file's name and the unknown author, and a BRF names them on its title page (BrailleTitlePage).
BraillePageAnalyzer.centeredRowsOfFirstPage(of:) gives the centered rows of the first page with anything on it, as Unicode braille, an empty string between two stretches that rows of another kind (blank, a rule, or not centered) part, and whether a centered rule row stands there (hasRule).
BrailleTitlePage.names(inRows:hasRule:) reads at most maxRowsLooked (8) rows of the first two stretches:
- a row that begins with "by", other than the first row, is the author's, and failing that the first row of the first stretch that has "by" inside it is a "Title by Author" row, so "Stand by Me" above "by Stephen King" is a title of its own;
- the rows before it and the words before "by" are the title (at most maxTitleRows, 3, else the first row alone), and the words after it, or the next row when "by" ends its row, are the author.

"By" is read in braille, where it is two cells spelled (⠃⠽, with or without a capital sign) in UEB and EBAE alike, and one sign, ⠴, in EBAE, alone or written against a capital sign (⠴⠠⠽⠁⠝⠝).
With no "by" the first row is the title only when the page has minRowsOfTitlePage (3) centered rows and a rule row, so a page of a part title, a chapter heading, and an epigraph names nothing and a chapter exported alone keeps its file's name.
BrailleTitlePage.names(ofFileAt:table:fileCode:) translates what the page names, together, in one run of the helper with the book's table, and cleaned(_:) refuses a name with no letter or digit or longer than maxPrintLength (200); reading a title page never fails an import.
ImportedFileMetadata.read takes brailleReading, the book's table and file characters, from the launch refresh (LibraryViewModel+MetadataRefresh) and, at an import, takes the reading the import decided once (FileImportService.brailleReading(ofImported:)).
(the setting's table or the guessed one, and the file's own characters).
So a guessed book's title page is read with the table the book is.
Where a caller gives none, ImportedFileMetadata.read decides the same way itself, and adding a book back from its removal marker passes the marker's table and characters (a marker with no table, the setting's), so it runs no guess.
A braille row is stamped with ImportedFileMetadata.brailleReaderVersion, "1.1.0", read through readerVersion(for:), so the launch refresh reads each braille book once and no other format's book.
The refresh (refreshedValues(of:from:)) replaces, as for every format, any unedited value of a row whose hand edits have been recorded since its import, and in any other row only an author at the placeholder, and never a field edited by hand.

### The reader version
<!-- id: reader-version; keys: page reader version, launch re-read, version bump, re-read once, stamp; src: TextMouth/Models/PageReaderVersions.swift, TextMouthProductionTests/PagesUpgradeTests.swift, TextMouthProductionTests/OnDiskContractTests.swift -->

The reader version: PageReaderVersions.current(for:) names "1.1.2" for braille ("1.1.1", which shipped in 0.4.9, "1.1.0", which shipped in 0.4.8, and "1.0.0" before).
The running heads, the Roman change lines, and the chapter rows change what a braille book's pages and text are, so every braille book is read again once at the launch re-read, and once more for 1.1.1 (the heads keyed without their numbers, below).
1.1.2 reads every braille book once more, for the stray long lines a width leaves out (FMT56).
A book with none of those reads byte for byte as before (PagesUpgradeTests, OnDiskContractTests.testThePageReaderVersions).
The braille helper's EBAE fixes ([The EBAE fix pass](imports-braille-tables.md)) ride on this bump and raise no version of their own.

### Running heads
<!-- id: running-heads; keys: page header, running title, page number word, repeated heading, volume number; src: TextMouth/Parsers/BraillePageAnalyzer.swift, TextMouthProductionTests/BraillePageAnalyzerTests.swift -->

Running heads: pageHead(ofRows:width:) reads the first row with text on a page as a head only when it has a number word at either end (a print page number at its right, ending the line, or a braille page number at its left).
A print page number is a number word that ends a full-width row, and the head's text is the row less the number words at its two ends.
A braille page number at the left is isLeftPageNumber: at most one letter cell, the number sign, and one to four digit cells, so a list item's number sign, digit, and period is none.
A row with neither, a print page change line, or a number word alone with no text is no head.
The analyzer's runningHeads(width:) counts the heads by headKey(of:), the head's cells with each number (a number sign and the digit cells after it) taken out.
So heads that differ only by a part or volume number are one head and repeat across parts ("life of pi. part1" and "life of pi. part2").
A key left empty by the numbers (a head of numbers alone) names no head, and a key counts as a running head at BraillePageAnalyzer.minHeadRepeats (3) pages.
The analyzer's extractNumbers matches each page's head by the same key.
A plain row of text with no number word is never a head, however often it repeats.

### Suggesting English Braille, American Edition
<!-- id: suggesting-english-braille-american; keys: EBAE detection, wrong table, suggestion, hint text, announcement; src: TextMouth/Parsers/BrailleCodeDetector.swift, TextMouth/Models/LibraryInfoWording.swift, TextMouth/ViewModels/BrailleCodeChoiceModel.swift, TextMouth/Views/Library/LibrarySheetViews.swift, TextMouth/Services/StorageDestinationAssessment.swift, TextMouth/Services/VoiceOverAnnouncer.swift, TextMouthProductionTests/BrailleCodeBookInfoTests.swift -->

The suggestion of English Braille, American Edition: BrailleCodeDetector (Parsers/BrailleCodeDetector.swift) tells from a braille book's cells alone whether a book read as UEB is written in EBAE, which nothing else checks.
So a BRF of an old transcription reads "to the sea" as "!the sea" with no error.
It counts the words (runs of cells between blanks) that show EBAE's signs:
- ⠖ (dots 2-3-5, "to") or ⠴ (dots 3-5-6, "by") joined to a letter or a capital sign after it, counted at each place; and
- a capital sign after a letter in the middle of a word, then n or y, EBAE's "ation" and "ally", which UEB dropped (BANA's Overview of Changes from EBAE to UEB), counted once for each distinct word (at most maxDistinctInsideWords, 5,000).
  That is because a name with a capital inside it, "McNeil", repeats and EBAE's words are many.

Count.looksLikeEBAE is true at minimumWords (10) of them and one in wordsPerHit (100) words.
BrailleCodeChoiceModel.load() asks it off the main actor (looksLikeEBAE(_:), through OffMainWork, for a book read with a UEB table, whose file is on this Mac, never downloading it), and keeps showsEBAESigns.
The suggestion is LibraryInfoWording's BrailleCodeWording.suggestsEnglishBrailleAmericanEdition, shown only while the book's table is UEB (system "ueb"), and the Book Information sheet (LibrarySheetViews.swift) draws it as a secondary Text under the Braille Code pop-up.
Its words are two sentences: "This braille looks like English Braille, American Edition." and "Choose its Braille Code in Book Information."
The suggestion changes nothing by itself, and load() announces the sentence once as it appears (announceSuggestionOnce(), through VoiceOverAnnouncer, guarded by hasAnnouncedSuggestion so a second load() says nothing), since the sheet shows it late.
VoiceOver also reads it as the item after the pop-up.
The detector also runs at import, by a stricter rule ([The guess of English Braille, American Edition](imports-braille-tables.md)).

### BARD braille books
<!-- id: bard-braille-books-reader; keys: BARD, .bopf, braille package, volumes, spine, brl:brailleCode, volume heading, FMT56; src: TextMouth/Parsers/BardBraillePackage.swift, TextMouth/Parsers/DAISYParser+OPFParser.swift, TextMouth/Parsers/DAISYParser+PackageInventory.swift, TextMouth/Parsers/BrailleFileReader.swift, TextMouth/Parsers/BraillePageAnalyzer.swift, TextMouth/Parsers/BrailleBookReader+Pages.swift, TextMouth/Services/FileImportService.swift, TextMouth/Models/Book.swift, Scripts/ios/sync-info-plist.py, TextMouthProductionTests/BardBrailleTests.swift -->

BardBraillePackage reads a BARD braille book (FMT56): a `.bopf` package, an Open eBook package of the form of DAISY 3's OPF, and the BRF volumes it lists.
The package file is parsed by DAISYOPFParser, which also keeps the Dublin Core description, publisher, date, language, identifier, and subjects, and every `meta` by its lowercase name (`metas`).
The files are reached through the DAISY file providers (ZIP, folder, or a package file with its folder), which answer `byteCount(of:)`, so a volume's size is known before it is read.
- Finding one: `isPackage(at:)` is true for a `.bopf` file, a folder whose package files are all `.bopf`, and a ZIP that `holdsPackage(inArchivePaths:)`.
  - That is: no TextMouth package in it, and every package or navigation file in it a `.bopf` (so a DAISY book, which has its own, is not one), standing in one folder or at the top level, as `DAISYParser.isDAISYZip` asks of a DAISY book's.
  - BookFormat.detect(from:) tests it before the DAISY checks and gives `.braille`, and BookFormat.braille's extensions name bopf.
- Opening: `open(at:)` takes the package file chosen, else the shallowest in the folder or ZIP, ignoring hidden paths (`isHiddenPackagePath`: a part that begins with a dot, or `__MACOSX`).
  Two at the shallowest depth throw `DAISYParserError.malformedXML` naming one, "it is one of N package files at the same level, so no one book is meant", which PackageDamage words as a damaged book.
- The volumes are the manifest items of a BRF or BRL media type or name, in the spine's order, or, when the spine names none, the manifest's.
  Each path is found as the package spells it, else in any letter case, and listed once; a package that lists none is refused, "it lists no braille volume".
- `readPages(code:)` reads every volume as a BRF in North American Braille ASCII (`brailleFileCode(ofImported:)` says so for a package), through `BrailleFileReader.pages(fromText:kind:code:)`.
  - A listed volume that is missing, an empty one, and one that is not braille in the code are each refused by name, as above.
  - The sizes are added from `byteCount(of:)` and held to `BrailleBookReader.maximumFileBytes` before any volume is read, and the bytes read are held to it again.
  - `BrailleFilePages.append(volume:number:)` joins the volumes, recording `volumeStarts` and `volumeNumbers`, the place in the spine; the line width is the first volume's, and the pages are marked only if every volume's are.
- The width is measured, never taken from the package:
  - `BraillePageAnalyzer.structure(of:)` lays each volume out alone, at `commonWidth(ofVolumesIn:)`, the width most volumes measure, the longer on a tie, and returns each volume with text as a `BrailleVolumeStart`.
  - `brl:lineLength`, and the page count `brl:pages` (which leaves out each volume's empty last page), are only compared with what was read, and a difference is logged (BARD_BRAILLE_WIDTH, BARD_BRAILLE_PAGES).
  - For every BRF, `longestLine(ofPages:)` leaves out the longest line on each of the longest 1 in 20 pages (`count / 20`) when it takes the longest line, the width of a book with no numbered last rows, so a stray long line cannot widen the page.
- `PagedTranslation` writes `# Volume N` (`volumeHeading(number:)`, English and never translated) after the marker of the volume's first page, so Go to Page lands on it, and writes every other heading at `min(level + 1, 6)`.
- The table comes from `brl:brailleCode` and `brl:contractionLevel` (`tableID(brailleCode:contractionLevel:)`): EBAE at level 2 is `BrailleTableGuess.ebaeTableID` (en_US.tbl), EBAE at 1 en-us-g1.ctb, UEB at 2 en-ueb-g2.ctb, UEB at 1 en-ueb-g1.ctb.
  `FileImportService.brailleReading(ofImported:)` stamps it with no origin, so it is never a guess; for any other code, or a table the catalog lacks, the book is read as a plain BRF is.
- The title and author are the package's (the first creator; "Unknown" is none), and its publisher, date, language ("und" is none), and identifier become the row's EPUB metadata.
- `contentHash()` is made by `DAISYPackageInventory.contentHash(entryDigest:files:)`, so a ZIP and its folder have one checksum and the second added is a duplicate.
- The iPhone offers no lone `.bopf`, since its picker copies only the file chosen, which would arrive without its volumes.
  `Scripts/ios/sync-info-plist.py` lists "NLS BARD Braille Package" in `REFUSED`, which leaves the type and its declaration out of the iOS plist ([The iOS Info.plist](../platforms.md#the-ios-infoplist)), and `FileImportService.supportedTypes` names the type under `#if os(macOS)`.
  A BARD ZIP, and a folder chosen with Import Folder…, import there as on the Mac.
- Tests: BardBrailleTests, in the import and braille areas, builds a package of TextMouth's own text, and a private test reads a sample kept out of the repository, skipped where there is none.

# Exports
<!-- id: exports; keys: export, Export dialog, File > Export, BRF, EPUB, speech export, captions; src: -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## An export and its dialog
<!-- id: export-dialog; keys: Export command, Export button, overwrite, atomic rename, scratch folder, Stop button, unique names, export log; src: TextMouth/Services/BookExportDelivery.swift, TextMouth/Services/BookExportService.swift, TextMouth/ViewModels/BookExportModel.swift, TextMouth/Models/BookExportWording.swift, TextMouth/Models/LibraryCloudWording.swift, TextMouth/Views/Export/BookExportSheet.swift, TextMouth/Views/Export/BookExportPresentation.swift, TextMouth/Views/Reader/ReaderBookCommands.swift, TextMouth/Views/Library/LibraryView.swift, TextMouth/Views/Library/LibrarySubviews.swift, TextMouth/App/MenuCommands.swift, TextMouth/App/TextMouthRuntime.swift, TextMouth/Services/MaintenanceFileAccess.swift, TextMouth/Parsers/DAISYParser+PackageInventory.swift, TextMouth/Services/AudioEditing/AudioEditPackage.swift -->

An export (FR05): what the Export dialog offers, what is checked, where it goes, and how far it has got.

- Owner: BookExportModel, one for each Export dialog, on the main actor: the books, what they offer (BookExportOffer), a choice for each kind any of them holds (BookExportChoice), the kinds checked, the destination, and the phase (listing, ready, exporting, or finished).
  The destination starts at the folder last exported to this session, kept only in memory, or else at Documents, in the home TextMouthRuntime names, so a test exports into its sandbox.
- Who may write it: the dialog's controls, and BookExportService, which never downloads (MaintenanceFileAccess).
  BookExportService.offer(for:access:) lists, off the main thread, what a book's package holds, from what the file system says.
  For a folder of tracks it also reads the saved content index (audioFileOrder(listed:index:): the files in the order the chapters and their clips play them, then any others in Finder's order), and for a DAISY book kept as loose files its inventory (DAISYPackageInventory).
  It lists, too, the originals the audio editor keeps in the package's audioEdits/originals folder (AudioEditPackage.folder, originalsFolderName) as BookExportKind.originalAudio: one file as "TITLE - Original Audio" with its own extension.
  Or it lists a book's tracks' originals in a folder of that name, each under its path in the book's audio folder.
  Both are copied as they are.
  Export never makes one, and a recording's take stays its Original recording (originalRecording).
  BookExportService.plan(_:kinds:conversions:in:fileExists:) names every file.
  One book's items go in the destination, its tracks and a loose DAISY book's files in a folder named after it.
  Several books get a folder each.
  A name already taken is followed by a number (UniqueNames, compared without case), so nothing is replaced.
  When Export is pressed, the model lists the books again as the library holds them, and runs export(_:kinds:conversions:to:access:cancellation:progress:) off the main thread.
  It leaves out books and items only in the cloud, copies each file with dataless files left in the cloud, and writes the plain text (plainText(fromMarkdown:at:title:): the chapters as the reader parses them).
  The Text as Markdown item, and the Markdown of a transcribed audiobook's Transcript, are made from content.md, not copied.
  BookExportService.markdownFile(of:from:as:) lists each as a .converted source by BookExportConversion.markdown, with content.md's size as the offer's.
  Only transcript.json is copied byte for byte.
  Every file, whether copied, plain text, or converted (text export, below), is made at a scratch URL in a new scratch folder (writeThroughScratchFile); the scratch folder and move below are the Mac's (BookExportDelivery.moving), and the iPhone's way is in [Exports on the iPhone](exports-iphone.md).
  The folder is the system's item-replacement folder on the volume of the nearest existing folder that holds the target (makeScratchFolder(near:)), or, when the system makes none, a new "TextMouth Export `<UUID>`" folder in the temporary directory.
  When the file is whole and Stop has not been pressed, moveExclusively moves it to its target, and the target's folder is made only then.
  The move is an exclusive rename (renamex_np with RENAME_EXCL, which the file system makes atomic).
  FileManager.moveItem is not used, since it checks and then renames, so a file made between the two would be replaced.
  Where the volume cannot do that (EXDEV, ENOTSUP, or EINVAL), the move is an exclusive copy (copyfile with COPYFILE_EXCL) and then the removal of the source.
  A target that exists, even one made an instant ago, fails that file with fileWriteFileExists and is left as it was, and the scratch folder is removed in every case.
  So an export never replaces a file in the chosen folder, removes none that was there before it began, and leaves no half-written file after a Stop or a failure.
  The one thing it removes in the folder is the partial file that copyExclusively created itself, when an exclusive copy fails for a reason other than an existing target (an open follow-up in the TODO, from team export).
  Stop (BookExportCancellation) is read before each file and, through checkCancelled(), between a conversion's steps and a writer's blocks, so a conversion ends partway.
  A copy already begun finishes in the scratch folder, and writeThroughScratchFile, checking once more before the move, does not move it.
  Either way the file is neither exported nor a failure, and the files after it are not started.
  A destination inside the data directory is refused (BookExportModel.isInsideDataDirectory).
- How others observe it: BookExportSheet shows the model, VoiceOver's focus on its first checkbox.
  LibraryExportSupport presents it on a Library window, for the selection File > Export… finds or the books a row's context menu acts on, and ReaderBookCommandsSupport on a reader, for its book, from File > Export… or the toolbar's Export button.
  The end is announced once (BookExportWording.finished); the dialog closes when everything was exported (didEverything), and keeps its summary otherwise.
  Each export writes one BOOK_EXPORT line, and each file that couldn't be written a BOOK_EXPORT_FAILED line.

## Text export and its writers
<!-- id: text-export-writers; keys: Convert to picker, text writers, conversion, writer options, export formats, iOS Word writer; src: TextMouth/ViewModels/BookExportModel.swift, TextMouth/Services/BookExportService.swift, TextMouth/Services/Export/TextExportWriter.swift, TextMouth/Views/Export/BookExportSheet.swift -->

Text export (FMT18, FMT19, FMT22): what the Convert to picker, beside Text as Markdown, makes of a text book's content.md in place of its Markdown (T3: Markdown is written too, and no export copies content.md).
What each format keeps and leaves out is in [Exporting books](../../user/exporting-books.md).

- Owner: BookExportModel keeps the Convert to choice of each kind whose text a writer can convert (conversionIDs: a writer's id, or TextExportWriters.markdownID until another is chosen).
  BookExportKind.convertsText is true for .markdown alone.
  BookExportModel keeps each writer's options too (optionsStates, one TextExportOptionsState for each writer chosen, kept for the dialog's life).
  BookExportSheet draws the picker beside the checked checkbox, with the chosen writer's options view under it.
  TextMouth/Services/Export/ holds the writers and what they read:

### The document, the walker, and the first writers
<!-- id: document-walker-first-writers; keys: ExportDocument, MarkdownTree, chapter markers, HTML export, RTF export, Word export, page breaks, BCP 47; src: TextMouth/Services/Export/ExportDocument.swift, TextMouth/Services/Export/ExportDocumentWalker.swift, TextMouth/Services/Export/TextExportWriter.swift, TextMouth/Services/Export/HTMLExportWriter.swift, TextMouth/Services/Export/RTFExportWriter.swift, TextMouth/Platform/macOS/Services/Export/WordDocExportWriter.swift, TextMouth/Services/Export/XHTMLMarkup.swift, TextMouth/Services/Export/XMLEscaping.swift, TextMouth/Parsers/MarkdownMarker.swift -->

- ExportDocument, the model every writer reads.
  For a writer that asks (EPUB, since 0.4.1) it also says where each chapter begins (chapterStarts, ExportChapterStart).
  It says where each page begins (ExportPageBreak: the block case .pageBreak between blocks, ExportRun.pageBreak inside text, and ExportTable.cellPages for a page that starts in a table cell, ExportCellPage).
  It says the places the book's contents point at (ExportNavigationTarget: .navigationTarget between blocks and ExportRun.navigationTarget inside text).
  The target is a heading annotation of content.md that a converted book carries for a contents entry naming a styled paragraph, an anchor, or a deeper entry of a Kindle book.
  ExportContentsItem is one entry of the contents, a heading or a target.
  All three are read where the reader reads them.
- ExportDocumentWalker, the one walk of content.md, which reads cmark-gfm's own tree (MarkdownTree), since Markdown stays the base.
  It splits the text into chapters at the markers exactly as the reader does, so text before the first marker is left out, as the reader leaves it out.
  ExportWalkOptions says what the walk keeps besides the words: keepsChapters and keepsPageMarkers, off in .plain (HTML, RTF, Word, and braille get the document they always did) and on in .bookStructure, which a writer asks for in TextExportWriter.walkOptions.
  The decoding of a marker line is MarkdownMarker (Parsers/MarkdownMarker.swift), shared with the reader and the exporters; the walk keeps the words that follow a marker on the same line.
  A target in a table cell is a place before the table; a page that starts in a cell stays in it.
  The walk holds the reader's nesting limit, 128 quotes or lists and 272 levels of tree ([MarkdownNesting](../shared-helpers.md)), and runs on MarkupGuard.onLargeStack, since content.md is untrusted: Edit Text and a file's own text can put any depth in it.
  A chapter that nests past it throws ExportWalkError.nestedTooDeeply(chapter:limit:), naming the chapter by its number, or none for a text with no chapter markers.
  BookExportWording.nestedTooDeeply(chapter:limit:) words it: "Chapter 1 of this book nests quotes, lists, or emphasis more than 128 levels deep, which TextMouth can't export safely.
  Choose Edit Text, flatten the nesting, and save; then export again."
  A walk with no decider, where nobody can be asked, names it after the file like any writer's failure, writes nothing for the book, and exports the others (BookExportNestingTests).
  A walk with one asks it what to do with the chapter (see [Exports: a chapter nested too deeply](exports-deep-chapter.md)).
- TextExportWriter, the writer protocol, with the TextExportWriters.all registry, the TextExportConversion erasure, and the dialog's options state (TextExportOptionsState).
- HTMLExportWriter with XMLEscaping, RTFExportWriter, and WordDocExportWriter, which is Apple's .docFormat from TextMouth's RTF.
  HTMLExportWriter and EPUBExportWriter write their blocks through XHTMLMarkup (Services/Export/XHTMLMarkup.swift), so a heading, a list, or a table is written once.
  They write their contents lists through ExportContentsList (the same file): one list for each item, a heading that rises out of a skipped level joining its sibling's list and an entry above the outermost level lowering it.
  ExportBookDetails.languageTag accepts a language only if it is a well-formed BCP 47 tag, for HTML, PEF, and EPUB.

### The EPUB package
<!-- id: epub-package; keys: EPUB export, OPF, nav document, EPUB 3, ZIP, right to left, accessibility metadata, file splitting; src: TextMouth/Services/Export/EPUBExportWriter.swift, TextMouth/Services/Export/EPUBPackageBuilder.swift, TextMouth/Services/Export/XHTMLMarkup.swift, TextMouth/Services/Export/TextExportWriter.swift -->

- EPUBExportWriter (FMT28, 0.4.1), registered after WordDocExportWriter and before BRFExportWriter in TextExportWriters.all.
  An existing test pins the first choices.
  The order is html, rtf, doc, epub, brf, pef, and without the Word writer, which iOS lacks, html, rtf, epub, brf, pef.
  It asks for .bookStructure and writes the package through EPUBPackageBuilder:
  - `mimetype`, stored and first, and META-INF/container.xml.
  - OEBPS/chapter-N.xhtml for each chapter:
    - A long chapter continues in another file past maximumFileBytes, 256,000 by default, ending the file where a heading begins when it can, else past four times that.
    - A chapter of only page markers joins the next file, or the previous one at the end.
  - OEBPS/nav.xhtml: the contents nested by level from ExportContentsList, and the hidden page list.
  - OEBPS/content.opf:
    - The identifier: urn:uuid and the book's library identity in lower case, or a new UUID for a book without one.
    - The title and creator.
    - The language: "und" and dir="auto" on every block when the book names none or says "und".
    - The modified date.
    - The accessibility metadata, which the summary follows by the entries written.
    - The words the writer writes itself (the contents and page-list headings, the accessibility summary) are in the interface language at the time of the export, marked with `lang` and `xml:lang` of EPUBPackageBuilder.ownLanguage, which is the app's first preferred localization, or "en".
      The book's own `dc:language` is the book's, never the interface's.
    - page-progression-direction="rtl" with dir="rtl" for a right-to-left language or script (EPUBPackageBuilder.isWrittenRightToLeft: the script subtag when there is one, else the language, ku, sd, ks, and ug being assumed neither way).

### EPUB links and targets
<!-- id: epub-links-targets; keys: EPUBCheck, RSC-020, URL escaping, navigation target, Untitled, contents entry, anchor; src: TextMouth/Services/Export/EPUBExportWriter.swift, TextMouth/Services/Export/EPUBLinkAddress.swift -->

- EPUBExportWriter, links and targets:
  - EPUBLinkAddress.url(from:) percent-encodes a link's address for EPUBCheck's RSC-020: ASCII hexadecimal digits only, a port up to 65535, a host of letters, digits, dots, and hyphens.
  - It answers nil for an address that is not a URL, when the link's words are written without the link.
  - A navigation target becomes an empty target with an id and a contents entry at its level.
    The reader reads that entry back at its depth in the contents, so levels 3 to 6 alone under a chapter come back as 2, and one in a table cell comes back a few words early.
  - A chapter that opens with text gets an entry named for the chapter or the book.
  - A heading of only forbidden or zero-width characters is a target, named "Untitled".

### EPUB writing and checking
<!-- id: epub-writing-checking; keys: ZIPFoundation, checksum, verify, write failure, disk full, read-only volume, EPUBCheck; src: TextMouth/Services/Export/EPUBExportWriter.swift, TextMouthProductionTests/EPUBCheckRunner.swift -->

- EPUBExportWriter, writing and checking:
  - write(_:options:to:cancellation:) refuses a file already there, writes the package, and opens it again in verify(_:holds:).
  - verify checks the entries and their order, and each entry's checksum, which ZIPFoundation's extract returns and leaves its caller to compare.
    Any failure removes the file.
  - Archive.ArchiveError and Data.DataError become "The EPUB file could not be written." or, from writeFailureSentence(errno:), a sentence naming a full disk or the system's own words for a read-only volume or a missing permission.
  - `afterEachFile` exists only so a test can stop or fail the export after a given file.
  - Nothing is checked in Apple Books or by VoiceOver.
    EPUBCheck 5.2.1 reports nothing on the exports of the test books.

### The Markdown writer, and adding a writer
<!-- id: markdown-writer-adding-writer; keys: Markdown export, md, escaping, backslash, content.md, new writer, picker order; src: TextMouth/Services/Export/MarkdownExportWriter.swift, TextMouth/Services/Export/TextExportWriter.swift, TextMouth/Parsers/MarkdownLiteral.swift, TextMouth/Parsers/MarkdownEmphasis.swift -->

- MarkdownExportWriter is the Markdown choice, listed first by TextExportWriters.markdownID and not in TextExportWriters.all (its id is "md").
  It writes headings, paragraphs, lists, quotes, code, breaks, and tables, with emphasis (MarkdownEmphasis.markdown(_:styles:literal:), given MarkdownLiteral.minimallyEscaped as its literal writer) and web and mail links, and no title heading.
  So the file is the book's text as content.md holds it, without its marker lines.
  It writes only the backslashes Markdown needs (MarkdownLiteral.minimallyEscaped, and guardingLineStart for each line's start, which also guards a line that would read as a table's delimiter row, and an exclamation mark that ends the words before a link is escaped).
  The file content.md, TextMouth's own cache, escapes every ASCII punctuation character so that its reader reads exactly a book's characters, and stays as it is.
  No export copies it.
- Adding a writer: one new file plus one line in TextExportWriters.all, where the picker's order is the array's order.
  Scripts/agents/briefs/2026-10-19/export/interface-for-braille.md describes the interface.

### Braille writers
<!-- id: braille-writers; keys: BRF, PEF, braille export, BANA, six-dot cells, liblouis, embosser, braille pages; src: TextMouth/Services/Export/BrailleExportWriters.swift, TextMouth/Services/BrailleDocumentWriter.swift, TextMouth/Services/BrailleLayout.swift, TextMouth/Services/BrailleFileWriter.swift, TextMouth/Parsers/BrailleEmphasis.swift, TextMouth/Parsers/BrailleFileCode.swift, TextMouth/Views/Export/BrailleExportOptionsView.swift, TextMouth/Services/Export/TextExportWriter.swift -->

- Braille (FMT22): BRFExportWriter and PEFExportWriter (Services/Export/BrailleExportWriters.swift), last in TextExportWriters.all, write a book as braille.
  What the files hold and the layout's rules are in [Exporting books](../../user/exporting-braille.md); the translator and its helper are under Braille files in [Imports](imports-braille-tables.md).
  The table catalog, with the export list that adds the tables that only write braille, is in [Braille table pack](braille-table-pack.md).
  - Blocks: BrailleExportBlocks.blocks(of:) turns an ExportDocument into BrailleBlocks, and printBlocks(of:) gives each its emphasis (BraillePrintBlock).
    A block's print keeps its runs' italic (isEmphasis) and bold (isStrong) as flags on each scalar (EmphasizedText(runs:)), and a link's address is not written.
    The text of a table's cells, a code block's lines, an ordered item's number, and the title carries no emphasis.
    The title heading comes first, as level 1, when the document has one;
    - a heading keeps its level;
    - a paragraph is a paragraph;
    - a list item is a list item at its depth, an ordered list's beginning with its number and a period;
    - a quote is the text of its blocks;
    - a code block is a paragraph for each of its lines that has text;
    - a table is a paragraph for each row, its cells joined by semicolons;
    - a thematic break is nothing.
  - Writing: BrailleExportWriting.write checks the cancellation.
    It binds BookExportCancellation.childProcesses, the ImportCancellation that Stop sets with the export's own flag, as ImportCancellation.current around the translation.
    So Stop kills the braille helper at once instead of waiting for a translation that can run for up to a minute on a long book (TODO 3985).
    It asks BrailleDocumentWriter for the file's bytes (its translator's hidden files go in the scratch folder that holds the target), checks again, and writes them with .withoutOverwriting.
    A BrailleTranslator.Failure becomes a TextExportError with its sentence.
    BrailleDocumentWriter translates the blocks' text, with its emphasis, to braille (BrailleTranslator, print to braille, with the options' table).
    Liblouis writes the table's emphasis indicators for the classes the helper finds liblouis reads back exactly (the helper, in [Imports](imports-braille-tables.md)), UEB's.
    EBAE's italic and bold, which liblouis misreads, and most of this Mac's tables write plain braille, byte for byte as without emphasis, although the helper reads EBAE's signs in a braille book.
    BrailleDocumentWriter lays the cells out with BrailleLayout.pages(of:format:).
    It frames the pages with BrailleFileWriter: brf(pages:lineEnd:code:).
    Each row's cells are written in the options' braille file code (BrailleFileCode: a byte of North American Braille ASCII or of Eurobraille, which are ASCII only, or Unicode braille patterns in UTF-8 with no byte order mark and the blank cell as U+2800).
    The line end goes after each row, and one form feed between pages.
    Or it frames them with pef(pages:metadata:format:), PEF 2008-1 XML in one volume of the options' cells and lines (PEFExportWriter.metadata(of:): the title, the author or none, the language or "en", a urn:uuid identifier, and the day).
    Both write six-dot cells only (sixDotCells(of:)), so the eight-dot cell liblouis writes for the backslash of an escape becomes ⠳ and TextMouth reads its own files.
    Any other eight-dot cell is refused, never written as its six-dot part: sixDotCell(of:) throws EightDotCell, whose sentence names the print character the table writes with it (BrailleDocumentWriter finds it by translating each distinct character of the block alone).
    BrailleExportWriting turns it into a TextExportError.
    No table writes an emphasis indicator in eight dots (all 328 of macOS 26's were measured), so emphasis adds no such failure.
    Before translating, BrailleDocumentWriter.printForBraille(_:) writes an eight-dot braille pattern already in the print as its six-dot part and removes Unicode's noncharacters.
    The PEF escapes its head's text with an escaped(_:) of its own (see [Known duplication](../known-duplication.md)).

### Braille layout and options
<!-- id: braille-layout-options; keys: BrailleLayout, BraillePageFormat, cells per line, BrailleLineEnd, BrailleFileCode, replacedTable, BrailleTablePicker; src: TextMouth/Services/BrailleLayout.swift, TextMouth/Services/BrailleDocumentWriter.swift, TextMouth/Views/Export/BrailleExportOptionsView.swift, TextMouth/ViewModels/BookExportModel.swift, TextMouth/Views/Export/BookExportSheet.swift -->

- Layout: BrailleLayout is pure Swift over translated cells: BANA's margins, each list set apart by blank lines (setListsApart), pagination (Paginator), and the cuts of a word too long for a line (cutLength(of:room:)).
- Options: BrailleExportOptions (a BraillePageFormat with the cells per line, 18 to 80, the lines per page, 4 to 50, and whether pages are numbered; the table; the BRF's BrailleLineEnd, and the BRF's fileCode, a BrailleFileCode) is the two writers' Options.
  It is started by BrailleExportOptions.standard() from BraillePreferences.importTable() and, for the file code, the Braille setting's, BraillePreferences.importFileCode() (never Unicode braille patterns, which the Export dialog offers but the setting does not).
  Or it is started from the default table, with replacedTable set, when that is one of this Mac's tables (BrailleTableCatalog.readsFromMacFolder).
  That is when this Mac does not offer it for export or a kept verdict refused it this session (BrailleDocumentWriter.exportCannotStart(from:); a too-slow refusal and a check that could not be made are not kept).
  On the iPhone, which has no folder of the Mac's tables, a Settings table that no export list can use, because the translator would refuse it (BrailleTableCatalog.bundledID(forStored:) finds none in the pack), is replaced by the default the same way, with the Mac's sentence.
  The options view then says BrailleExportWording.startsFromDefault(replacing:) until another table is chosen.
  BrailleExportOptionsView draws them under the picker, with the words in BrailleExportWording and no line ends or braille file characters for a PEF.
  A BRF's two own pop-ups, drawn by one menuPopUp builder, come last, the braille file characters (BrailleFileCode.all) after the line ends, so every other control keeps its place in the reading order.
  Its language, code, and contraction pop-ups are BrailleTablePickers, which the Braille tab of Settings draws too, each with hints of its own (see [Preferences](preferences.md)).
  The export's pop-ups are given BrailleTableCatalog.exportCodes, which add the tables that only write braille, and the Braille tab's are given offeredCodes, which do not (see [Braille table pack](braille-table-pack.md#the-catalogs-lists)).
  A Mac table chosen there is checked off the main thread (The check of this Mac's tables, in [Imports](imports-braille-tables.md)) through BrailleTableChoiceChecks.shared.
  BookExportModel.export waits on it in its exporting phase (finished(unless:), ended at once by Stop or the dialog closing).
  So the export writes with the table the pop-ups show.
  BookExportSheet gives the Export button BookExportWording.exportWaitsHint meanwhile.

### How the dialog and the job use the writers
<!-- id: how-dialog-job-use-writers; keys: BookExportConversion, converted files, failure sentence, picker choices, export tests, EPUBCheck tests, Word export failure; src: TextMouth/Services/BookExportService.swift, TextMouth/ViewModels/BookExportModel.swift, TextMouth/Models/BookExportWording.swift, TextMouth/Views/Export/BookExportSheet.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouth/Services/Export/TextExportWriter.swift, TextMouth/Platform/macOS/Services/Export/WordDocExportWriter.swift, Scripts/test/areas.conf, TextMouthProductionTests/EPUBExportWriterTests.swift, TextMouthProductionTests/EPUBExportWriterNavigationTests.swift, TextMouthProductionTests/EPUBLinkAddressTests.swift, TextMouthProductionTests/ExportContentsListTests.swift, TextMouthProductionTests/ExportDocumentWalkerStructureTests.swift, TextMouthProductionTests/EPUBExportRoundTripTests.swift, TextMouthProductionTests/EPUBExportRealBooksTests.swift, TextMouthProductionTests/EPUBCheckTests.swift, TextMouthProductionTests/MarkdownExportWriterTests.swift -->

- Who may write it: BookExportService, as above, off the main thread and one book at a time.
  BookExportService.plan(_:kinds:conversions:in:fileExists:) plans a converted kind's files as .converted sources (BookExportFile.Source), each named with the writer's extension in place of the Markdown's and made unique like any other name.
  BookExportConversion is the job runner's conversion, text now and audio later: it gives the extension, the kinds it applies to, and the name the picker says.
  BookExportConversion.markdown, the Markdown writer with no options, is what the offer's Markdown files are converted by.
  BookExportService.files(of:for:conversions:) converts a copied or an already converted file, so that choosing another writer replaces the Markdown the offer lists.
  BookExportService.writeConverted reads content.md as the reader does (MarkdownCacheService.cacheText), walks it, and has the writer write it to a scratch file, which is moved into place as above.
  A writer that cannot write a book throws a TextExportError, whose sentence the export names after the file, as in "Couldn't export FILE NAME: SENTENCE" (BookExportWording.failureSentence), and the other books still export.
  WordDocExportWriter.failureSentence is the Word writer's, for a book Apple's reader or writer refuses.
  The sentence is in the interface language; BookExportFailure.logReason is its English, which BOOK_EXPORT_FAILED writes, so the debug log stays English.
- How others observe it: the checkbox's words follow the picker (BookExportWording.name(of:convertedTo:), hint(for:convertedTo:), and choiceLabel(kind:bookCount:availableItemCount:fileCount:byteCount:inCloudCount:convertedTo:)).
  BookExportWording.choiceLabel gives no size while a writer is chosen, since a converted file's size is known only once it is written.
  The picker lists BookExportConversionChoice values: Markdown (BookExportWording.markdownChoiceName and markdownChoiceHint, which is also the Text as Markdown checkbox's hint while Markdown is chosen: hint(for:)), then each writer's name and hint.
- Tests:
  - the export area of Scripts/test/areas.conf (`python3 Scripts/test/run-area.py export`), with the dialog's sheet in the sheets area and the braille writers also in the braille area.
  - The EPUB writer's tests are:
    - EPUBExportWriterTests (the package, with the clock fixed so the bytes are the same each run, the failures, and, in EPUBExportWriterNavigationTests, its contents and page list),
    - EPUBLinkAddressTests,
    - ExportContentsListTests (the structure of skipped levels, and 300 seeded random sequences),
    - ExportDocumentWalkerStructureTests,
    - ExportDocumentWalkerNestingTests, MarkdownDepthLimitTests, and BookExportNestingTests (the nesting limit, each walk at its edge, and the refusal's sentence; the two that measure a walk's stack run on GitHub only, see [A test that may crash the host](../../developer/testing.md)),
    - EPUBExportRoundTripTests and EPUBExportRealBooksTests (each of 17 real books exported, imported again with EPUBParser.prepareBook, and compared with the reader's own reading: the words, the pages with the same word before each, the headings), and
    - EPUBCheckTests, which runs `epubcheck` where /opt/homebrew/bin/epubcheck exists, skips where it does not, and fails when it ran and gave no summary.
  - MarkdownMinimalEscapingTests reads every string of one or two characters over a, 1, é, a space, and the 32 ASCII punctuation characters, and every three-character string over the punctuation, a, and a space.
    It reads them back through MarkdownTree as a paragraph, a heading, and a list item, in the plain form and with smart punctuation.
  - MarkdownExportWriterTests writes each kind of block and run, and walks the file back to the blocks it was written from.

## Transcripts as captions
<!-- id: transcripts-as-captions; keys: WebVTT, SubRip, SRT, captions, subtitles, timed text, transcript.json; src: TextMouth/Services/Export/TimedTextWriters.swift, TextMouth/ViewModels/BookExportModel.swift, TextMouth/Models/BookExportWording.swift, TextMouth/Parsers/TimedTextMarkup.swift -->

Transcripts as captions (FMT23; 0.4.2).

- Owner: BookExportModel offers the Convert transcript to picker beside the Transcript checkbox (transcriptConversionChoices): JSON and Markdown (TranscriptExportFormat.jsonAndMarkdownChoiceID, the default), each text writer, then each TranscriptExportFormat (webVTT, subRip).
  EPUB stays among the text writers, since it writes the transcript's text as every other text writer does.
- Who may write it: TimedTextWriters (Services/Export/TimedTextWriters.swift).
  WebVTTWriter escapes a cue's text as XML does and writes a cue ending where it begins as ending a millisecond later.
  SubRipWriter ends lines with CR LF, starts the file with the UTF-8 byte-order mark (TranscriptExportFormat.fileBytes).
  It writes as character references what a reader would take for structure: the ">" of "-->", a "<" with a ">" after it, "{" before a backslash, and an "&" that begins a reference TimedTextMarkup decodes.
  A cue left with no text is passed over, and SubRip numbers count only the cues written.
- A Transcript item that holds Markdown and no transcript.json is a failure the export reads out: BookExportWording.noTimedTranscriptReason.
  A transcript only in the cloud is noted, with the book named, as any cloud kind is.

## Headings and bookmarks as chapter lists
<!-- id: headings-bookmarks-chapter-lists; keys: CUE sheet, Audacity labels, ChapterListFormat, CueSheetWriter, chapterListItems, FMT24, FMT06, Convert headings to; src: TextMouth/Services/Export/ChapterListWriters.swift, TextMouth/Services/BookExportService.swift, TextMouth/ViewModels/BookExportModel.swift, TextMouth/Models/BookExportWording.swift -->

Headings and bookmarks as chapter lists (FMT24, FMT06).

- Owner: BookExportService.chapterListItems offers a Headings item (BookExportKind.headings) for an audiobook whose saved index holds more than one chapter, and a Bookmarks item for one with bookmarks.
  Each is one file, named for the picker's first format (chapterListItem: "Title.cue", or "Title - Bookmarks.txt").
  BookExportModel offers Convert headings to (ChapterListFormat.formats(for:): CUE sheet first, then Audacity labels); bookmarks have one format, Audacity labels, so no picker.
  The checkbox says the format and no size, since a chapter list is written, not copied (writesChapterList).
- Who may write it: ChapterListFormat.fileBytes(of:book:) for the ChapterListEntry list that chapterListEntries(of:ofAudioAt:stem:access:) reads from the book's saved record in its package.
  - Headings begin where the chapter's first clip does in a book of sections, at its file's start in a book of tracks, and, for a book of one file, as the file's own chapter list read them, since the index keeps only lengths rounded down to a tenth of a second.
  - Bookmarks sit where the reader plays them (bookmarkPlace), named by their name or "Bookmark N".
  - CueSheetWriter writes the book's TITLE and PERFORMER, a FILE line for each exported audio file (typed MP3, AIFF, or WAVE by extension), and a track for each chapter with INDEX 01 at its start to the nearest 1/75 s.
    The file is UTF-8 with a byte-order mark and CRLF line ends, and a quotation mark in a value becomes an apostrophe.
  - Audacity labels are points, one for each entry; entries in more than one file throw ChapterListExportError.severalFiles, and a book with no saved index throws noHeadings.
- How others observe it: CueSheet and CueSheetArrangement read a written sheet back as the same headings.

## Spoken audio export
<!-- id: spoken-audio-export; keys: Text as spoken audio, M4B, M4A, MP3, text to speech export, AVSpeechSynthesizer, quit hold, Caches; src: TextMouth/Services/SpeechExport/, TextMouth/Models/SpeechExportWording.swift, TextMouth/Views/Export/BookExportSheet.swift, TextMouth/ViewModels/BookExportModel.swift, TextMouth/Services/BookExportService.swift, TextMouth/App/QuitHold.swift, TextMouth/Platform/macOS/App/AppDelegate.swift -->

Spoken audio (FMT43; 0.4.2): a text book, or a range of its headings, spoken by its voice into one M4B, M4A, or MP3 with a chapter for each heading.

- Owner: BookExportKind.spokenAudio ("Text as spoken audio").
  BookExportModel holds the speech options (SpeechOptionsMaking), which it makes the first time the kind is checked and not when the dialog opens, so the dialog opens without reading the book's text; Export waits for them, and the dialog says "Reading the book's headings…" meanwhile.
  SpeechExportText.headingPlaces works the range's headings out once, for the text and for the options.
  SpeechExportStore holds the kept chapters and allows one export at a time (claim()).
- Who may write it: SpeechExportJob speaks the chapters one by one through SpeechChapterRenderer, which writes buffers from AVSpeechSynthesizer behind SpeechBufferWriting (AVSpeechBufferWriter in the app, a scripted writer in tests) and so can be tested.
  A chapter's loudest sample must rise above silenceCeiling, 0.001 (-60 dBFS), or the chapter fails.
  Waits are bounded by StallLimits: the first buffer gets 2 ms for each UTF-16 unit of the utterance and never less than 3 minutes, and the gap between buffers is 60 seconds.
  SpeechExportEncoder writes M4B, M4A, and MP3 (MP3Tag.maximumChapters is 255; the range's headings beyond it have no chapter).
  The file is moved into the chosen folder as the job's last step, so the chapters stay until it is in place. copyExclusively fails, removing what it made, when close() fails.
- The kept chapters: one file for each chapter in this Mac's Caches folder, in Speech Export, matched by the book's text, voice, rate, and pitch, so a stale chapter is never used.
  They end when TextMouth quits, a different export starts, or the book's voice, text, substitution rules, or pauses change, and SpeechExportStore.sweep empties the folder at the Mac's launch. iOS does not sweep yet.
  Export refuses a destination in this folder, for any kind of export.
- A quit: SpeechExportsUnderWay is a QuitHold.Work (kind "speech exports") in AppDelegate's held work, beside feed downloads and re-reads.
  The whole quit is in [Launch](../launch.md).
  - It stops every export as Stop does, with the chapters it finished kept, and waits at most 5 seconds (SpeechExportsUnderWay.longestQuitWait).
  - A quit the person asks for is cancelled while it does, and TextMouth asks to quit again afterwards (0.4.4).
    It says "TextMouth is finishing up before it quits: stopping a speech export with the chapters it finished kept.
    It will quit as soon as that is done." in a panel and through VoiceOver.
    With several exports under way it says "stopping 2 speech exports with the chapters they finished kept", counting them.
  - A second Command-Q or the Dock's Quit meanwhile is cancelled too and says the same words again, so it no longer quits at once and cuts the export off.
  - The system ending the session is answered later with the same words, and replied to when the exports have stopped or after 5 seconds.
- How others observe it: a power assertion (SpeechExportPower) holds the Mac awake while it runs, and holds nothing on iOS, which has no IOKit.
  The debug log records a SPEECH_EXPORT line when it ends (finished, stopped, or failed), with the chapters done and kept.
  The model's progress is "Speaking chapter N of M…" and "Encoding the audio file…".
  Every sentence is in SpeechExportWording.
- The render coordinator is not used: measured, overlapping writes of different and of the same voices wrote the same samples as each alone.
  A speech export's writes beside the reader speaking aloud in direct mode were not measured, and a background render of a very long chapter made speak() loop back to text it had spoken (62fc142e).
- Not done: encoding each chapter while the next is spoken; resuming per heading; WAV, AIFF, CAF, Apple Lossless, FLAC, time ranges, and a selection (FMT44).

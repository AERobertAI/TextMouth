# Kept texts, re-reads, and edited text
<!-- id: text-caches-rereads-edits; keys: kept text, re-read, edit, search text; src:  -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## Kept reading text
<!-- id: kept-reading-text; keys: parse cache, large book, opening speed, machine-local, Caches folder, reading text file, performance; src: TextMouth/Services/ReadingTextCache.swift, TextMouth/Services/BookContentAnalysisService.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/ViewModels/LibraryViewModel+BookOperations.swift, TextMouth/ViewModels/LibraryViewModel+Feeds.swift, TextMouth/Models/CloudStorageContract.swift, TextMouth/Services/BookTextEditing.swift -->

Kept reading text (ReadingTextCache, PERF22): this Mac's copy of a large text book's reading text (each chapter's title, text, and headings as parsed), at `MachineLocalPaths.readingTextCache/<book ID>.readingtext`, for a content.md of at least 1 MiB.
The file is a prefix ("TMRT", the layout version, the header length), a JSON header (the producer, the ReadingTextKey, the chapter entries, each with its title, UTF-8 length, headings, and pages), then the UTF-8 chapter texts.
The layout is ReadingTextCache.formatVersion, 2 since each chapter's pages (PG01); a file of layout 1 is never read, and is removed as unusable.
- Who may write it: BookContentAnalysisService.loadExistingCache, only when given the cache (only ReaderViewModel.readContent passes it), after parsing a content.md its record vouches for, in the background (storeInBackground: a partial file renamed into place).
  MarkdownCacheService.writeCache, LibraryViewModel.removeDeletedBook, BookTextEditSessions, when it takes an edit, and LibraryViewModel.settleFeedFileRemovals(_:failures:), with which every removal of a feed item's file ends (FR11's branches A2 and B), remove a book's file.
  ReadingTextCache.removeExpired removes files unused for a day (by modification time, which each use refreshes), at startLibrary and after each store.
- How others observe it: used instead of parsing when the fingerprints verify, the saved index validates and was measured from the same content.md, and the key matches.
  The key is the record's content.md digest, its ContentFileIdentity of size, modification time, inode, and status-change time, and the book title, together with the producer (BookContentIndex.currentVersion and the build identity) and the layout.
  The chapters must pass alignmentFailure(with:countingWords: false).
  Otherwise the book is parsed; a damaged or mismatched file is logged as READING_TEXT_CACHE_REJECTED and removed. content.md is read only for a digest or a parse.

## Search Library's search texts
<!-- id: search-library-search-texts; keys: full-text search, find in library, search index, warm-up, searchable text, disk cache; src: TextMouth/Services/TextSearch/LibrarySearchText.swift, TextMouth/Services/TextSearch/LibrarySearchEngine.swift, TextMouth/Services/TextSearch/LibrarySearchPreparer.swift, TextMouth/Models/CloudStorageContract.swift, TextMouth/App/BuildIdentity.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/ViewModels/LibrarySearchModel.swift, TextMouth/Services/MaintenanceFileAccess.swift, TextMouth/Services/ArchiveBudget.swift, TextMouth/Models/LibrarySearchWording.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouthProductionTests/LibrarySearchTextStoreTests.swift, TextMouthProductionTests/LibrarySearchPreparerTests.swift, TextMouthProductionTests/LibrarySearchEngineTests.swift -->

Search Library's search texts (libsearch): this Mac's copy of each book's reading text, laid out to be searched; the design, with its measurements, is research/LIBRARY-SEARCH-RESEARCH-2026-11-13.md (in the repository's root).
- Owner: LibrarySearchTextStore (Services/TextSearch/LibrarySearchText.swift), a struct over MachineLocalPaths.librarySearchText, ~/Library/Caches/com.textmouth.TextMouth/Search Text, one file named `<book ID>.searchtext` for each book with a content.md.
  A file is the prefix "TMLS", the layout (LibrarySearchTextStore.formatVersion, 1), and the header's length, a JSON header (the producer, the LibrarySearchTextKey, each chapter's title, UTF-8 and UTF-16 lengths, and headings), then the chapters' UTF-8 texts one after another.
  It is not in the data directory, so a cloud library never uploads it, a move never copies it, and the File Size sort never counts it.
  Under hosted tests the folder is in the test sandbox.
- What it is made from: the reader's own parse of content.md, never the raw file (MarkdownCacheService.parseMultiChapterMarkdown, which splits the chapters and takes each one's plain text).
  That is because the reader shows neither the Markdown marks nor our own markers, and an offset into content.md is not an offset into the reader's text.
- Who may write it: LibrarySearchPreparing (Services/TextSearch/LibrarySearchEngine.swift), whose lookUp(_:fileAccess:) answers for a book from the store (a look for the cloud, a stat, a header read) and whose prepare(...) parses and stores one.
  It stores through store(_:for:key:), which writes a partial file, synchronizes it to the disk, and renames it into place.
  Two callers: a search (LibrarySearchEngine.search, from LibrarySearchModel) for a book it finds missing or unusable, in parallel with DispatchQueue.concurrentPerform and never in Swift's concurrency pool, and the background preparer (below).
  A book whose package or content.md is only in the cloud is counted and not read (MaintenanceFileAccess.isInCloud, reads with dataless files left in the cloud), so nothing is downloaded.
  A parse is let in only while the content.md being parsed adds up to at most 32 MB for a search, 16 MB for the preparer (LibrarySearchPreparingGate), a larger book alone, since parsing holds 5 to 22 times the text; a gate wait checks for cancel every 20 ms.
- When a file is used (open(bookID:key:)): only for exactly its key, which is the content.md's ContentFileIdentity (size, modification and status-change times, inode, taken before the read) and the book's title, and its producer.
  The producer is LibrarySearchTextStore.currentProducer: the layout, BookContentIndex.currentVersion, BuildIdentity.current.cacheProducer (the version, build number, commit, and date, as ReadingTextCache keys on), and parserFingerprint, a digest of the parser's reading of a fixed sample.
  Each new installation therefore reads nothing an earlier one stored (the content index's version was never raised for a parser change, and ST05 changed how a line led by a marker reads); the sample stays for development builds, which carry no commit or date.
  A file for another key, layout, or producer is removed.
  When it opens, every length in the header is checked against the file (none below zero, no UTF-16 length above its UTF-8 length, headings within their chapters, the lengths adding up to the file's size exactly): a file that fails is removed and the book made again, never read past its end.
- Room: a file is kept only while the volume keeps ArchiveLimits.standard.freeSpaceReserve (1 GB) free after it (LibrarySearchTextSpace, which asks for the free space at most every 5 seconds, counting purgeable space as imports do).
  Otherwise a search works from its parse and keeps nothing, and the preparer ends before a parse it could not keep.
  LibrarySearchTextStore.removeFiles(notFor:now:partialFileAge:) sweeps the files of books no longer in the library, of another data directory's books, and the partial files a quit or a crash left more than 10 minutes ago.
  A finished search and a finished pass each sweep.
- The preparer: LibrarySearchPreparer (Services/TextSearch/LibrarySearchPreparer.swift) walks LibrarySearchModel.searchableBooks(in:) (every book of the library's own with a package, feed items left out, in title order), two lanes at a time (laneCount).
  It runs at background priority, which it enforces, so a pass started from the main thread never runs at it.
  It never reads a book in the cloud, ends before a parse the disk has no room for, ends in Low Power Mode, pauses for every search (pause(), resume()), and logs one LIBRARY_SEARCH_PREPARATION line when a pass ends, with counts only (see [Logs](logs.md)).
  LibrarySearchPreparation (Mac only, and never in a process hosting tests: preparesInThisProcess) is its coordinator.
  LibraryViewModel.startupMaintenanceDidEnd() (after the passes that rebuild books' texts; see [Launch](../launch.md)) calls libraryIsReady(books:moves:), whose first call counts and starts a pass.
  A data-directory move (dataDirectoryMove) stops the pass and starts a fresh one when it ends.
  A power-state change stops it or restarts it; searchWindowOpened() raises its priority and starts a pass if none runs; searchWindowClosed() lowers it.
- How others observe it: nothing reads a search text but the engine.
  The Search Library window's status says "Preparing 120 of 737 books…" while a search must prepare books on its way (LibrarySearchWording.preparing(_:of:)), which the background pass makes rare.
  Cost, measured on the user's library (737 books, 676.3 MB, read only, under the heavy-work lock): 650.2 MB in 737 files.
  Preparing every book from an empty store took 8.2 s as the first search (50.6 s of processor time, a 527 MB footprint) and 50.5 s as the background pass (200 MB).
  A pass over the unchanged library 0.44 to 0.55 s.
- Tests: LibrarySearchTextStoreTests, LibrarySearchPreparerTests (which holds the preparer's and the coordinator's), and LibrarySearchEngineTests, in the reader-text area of Scripts/test/areas.conf (`python3 Scripts/test/run-area.py reader-text`).

## Reading a book again in another encoding
<!-- id: reading-book-again-another-encoding; keys: change encoding, re-extract, wrong characters, TextRereads, re-read; src: TextMouth/ViewModels/LibraryViewModel+TextEncoding.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift, TextMouth/ViewModels/LibraryViewModel+Duplicates.swift, TextMouth/Platform/macOS/Services/BookTextEditor.swift, TextMouth/Services/DuplicateReplacement.swift, TextMouth/Services/TranscriptInstallation.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouth/Services/LibraryPersistenceService.swift, TextMouth/Models/LibraryInfoWording.swift, TextMouth/Models/BookTextEditWording.swift, TextMouth/Views/Settings/StorageSettingsView.swift -->

Reading a book again in another encoding (encodingchoice): the one-book form of Redo Text Extraction that the listener asks for from Book Information's Text Encoding pop-up (the sheet and its model, in [Windows](windows-sheets.md); the decoding, in [Imports](imports-text-encodings.md)).

### Owner and the steps of a re-read
<!-- id: owner-steps-re-read; keys: re-read steps, rollback, restore content.md, main thread; src: TextMouth/ViewModels/LibraryViewModel+TextEncoding.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift, TextMouth/Services/StorageGeneration.swift, TextMouth/Models/LibraryInfoWording.swift, TextMouth/Models/BookTextEditWording.swift, TextMouth/Platform/macOS/Services/BookTextEditor.swift, TextMouth/Services/TranscriptInstallation.swift, TextMouth/ViewModels/BookExportModel.swift, TextMouth/Models/LibraryCloudWording.swift, TextMouth/Services/DuplicateReplacement.swift, TextMouth/Services/BookTextEditing.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouth/Services/LibraryPersistenceService.swift, TextMouth/ViewModels/LibraryBookUpdates.swift, TextMouth/Models/Book.swift -->

- Owner: LibraryViewModel.booksBeingReadAgain (ViewModels/LibraryViewModel.swift), a Set of book IDs on the main actor, not published: the books whose text is being read again, from the moment the listener confirms until the library row has the new reading.

#### The steps of a re-read
<!-- id: re-read-steps; keys: readTextAgain, rereadText, rereadFiles, validatedChoice, rollback, announcement; src: TextMouth/ViewModels/LibraryViewModel+TextEncoding.swift, TextMouth/Services/TranscriptInstallation.swift, TextMouth/Models/BookTextEditWording.swift, TextMouth/Services/LibraryPersistenceService.swift -->

- Who may write it: LibraryViewModel.readTextAgain(bookID:as:access:) (ViewModels/LibraryViewModel+TextEncoding.swift), on the main actor, in this order.
  1. It refuses a book that has left the library (TextEncodingWording.bookGoneRefusal) and one that no longer offers the choice (failedRefusal).
     It then refuses whatever textEncodingChangeRefusal(of:) says, which the pop-up asked too before it confirmed:
     - another operation holding the storage work (StorageBoundary.shared.heldFor, worded by StorageBusyError, as Replace Existing words it),
     - the library's text being read again (isExtracting: the launch's batch, Redo Text Extraction),
     - the book being read again already, and
     - the book being exported (BookExportModel.booksBeingExported).
  2. It adds the book to booksBeingReadAgain, which a defer removes again however the work ends.
  3. A book being edited with Edit Text is no refusal.
     BookTextEditor.pauseEditing(of:) lets a check running finish, takes an edit saved and not yet checked, and ends the session, since the session watches the content.md that is about to be replaced and would take the new reading for an edit.
     A re-read that is refused afterwards begins the session again from a fresh baseline (resumeEditing(of:)), so the listener's later saves are still taken; one that goes ahead leaves it ended, and the one announcement says so (BookTextEditWording.stoppedBookReadAgain).
  4. rereadText(of:as:access:isOpenInReader:) does the work off the main actor (OffMainWork), in one piece of storage work (StorageBoundary.shared.perform(.textExtraction)).
     So a folder edit or a data-directory move that begins meanwhile waits for it, and the book's package never moves between content.md's write and the record's commit.
     It rebases the book to the data directory in use now, refuses a book with a file only in the cloud (LibraryCloudWording.notDownloaded(titles:)) before it reads anything, and reads through the access, so nothing is downloaded.
  5. rereadFiles(of:as:access:isOpenInReader:) goes in this order:
     - (a) for a choice, validatedChoice(of:for:) reads the file strictly in each identifier of the option's name before anything is written, and gives the record of the first that reads every byte, as chosen, or the not-valid refusal naming the encoding, "Nothing was changed.";
     - (b) keptUnwrittenText(of:access:) keeps content.md beside the new text when it holds text TextMouth did not write, an edit on record (Book.editedText) or a save no edit took (DuplicateReplacement.holdsUnwrittenText(_:of:hasher:), which Replace Existing asks too).
       The copy is named as BookTextEditSessions.keepCopy(of:bytes:) names the copies Edit Text keeps, and the step throws UnwrittenTextNotKept when it can't;
     - (c) MarkdownCacheService.generateReportedCacheAnalyzeAndStamp(for:replacingEditedText: true, decidingEncoding:) reads the file again with the record set on the book, a choice's, or an empty one with guessing on for Automatic.
       It moves the book's places with the text (T06, in [Package records](package-records-places-and-files.md));
     - (d) the record Automatic keeps is the guess it made, if any, with the source automatic (TextEncodingRecord(identifier: updated.textEncoding, source: .automatic)), so a choice made before it leaves the row and the record alike;
     - (e) after access.requireOnThisMac(book, reading: .all) has checked that no file went to the cloud meanwhile, LibraryPersistenceService.saveContentAnalysis(…textEncoding:) commits the analysis, the moved places, and the encoding in one write of the book's record.
       The encoding is committed as a decision that replaces the record's (Book.bookInfo(replacing:contentIndex:revisionFloor:decidingTextEncoding:), in [Package records](package-records.md)).
  6. If anything after content.md's write throws, or the record takes nothing (CommitDropped: its file was replaced or moved), PackageFileBeforeInstall (Services/TranscriptInstallation.swift) puts the old content.md back, its bytes and its dates.
     A transcript's install uses it to put back what it wrote.
     The old content.md goes back since the record still describes it and no later load should take the new reading for text changed by hand.
     Committing the record first would not do, because the record's fingerprint of content.md exists only after the write.
     A put-back that fails logs a line with the tag TEXT_ENCODING_CHANGED.
  7. The result, a TextEncodingReread (readAgain, with a TextCacheUpdate, the reading for VoiceOver, and the copy kept, or refused, with the sentence), returns to the main actor.
     LibraryViewModel.applyTextCacheUpdate(_:atOnce: true) gives the row the analysis whether or not a reader has the book open, after flushing the summaries waiting for it (analysisSummaries.flush()) so none lands over it.
     It tells a reader that has the book open through LibraryBookUpdates.textReplaced.
     Which readers have it open is asked at the commit, from the work's thread (audioEditActivity.isOpenInReader, as the batch asks it), so a reader opened during the read is given the new text too.
     The batch's updateProgress calls the same method without atOnce.
  8. The announcement (TextEncodingWording.readAgainAnnouncement(bookTitle:reading:keptCopy:stoppedEditing:)) is spoken once for the whole, and returned as the outcome, which the pop-up's sheet shows only when it is a failure.
     One TEXT_ENCODING_CHANGED line goes to the storage log (textEncodingLogLine(title:record:keptCopy:)).
     It holds the title, then "read again as IDENTIFIER, chosen", "read again automatically, as IDENTIFIER, guessed", or "read again automatically, with no encoding to record", and "; its earlier text was kept as COPY NAME" when a copy was kept.
     It holds no text of the book.

### Braille file characters and tables
<!-- id: braille-file-characters-tables; keys: liblouis, braille tables, BRF code, table choice; src: TextMouth/ViewModels/LibraryViewModel+TextEncoding.swift, TextMouth/Models/BrailleTableCatalog.swift, TextMouth/Services/LibraryPersistenceService.swift, TextMouth/ViewModels/ContentAnalysisSummaryBuffer.swift, TextMouth/Models/Book.swift -->

- Other kinds of re-read: readTextAgain(bookID:choosing:access:) takes a TextRereadChoice (ViewModels/LibraryViewModel+TextEncoding.swift), one of .textEncoding, .brailleFileCode, .brailleTable, and .brailleFileCodeAndTable.
  The .brailleFileCode choice is a BRF or BRL book's file characters.
  The .brailleTable choice is a braille book's braille code (FMT21), from the Braille Code pop-up, on any braille book that is not a feed's item (Book.offersBrailleTableChoice).
  The .brailleFileCodeAndTable choice is both in one re-read, which Replace Existing uses when the listener chose both for the old copy.
  Each is offered by isOffered(to:), refused by what textEncodingChangeRefusal(of:) says, and run through the same steps 1 to 8.
  A table is set on the book (settingBrailleTable(_:on:): the row's table and its version, BrailleTableCatalog.versionToRecord(forTable:)) before the file is read.
  LibraryPersistenceService.saveContentAnalysis(…brailleTable:) commits the table and its version with the analysis and the moved places, as a decision that replaces the record's (BrailleTableDecision).
  ContentAnalysisSummary carries the table and its version to the row, committed and recovered, and Book.LibraryFields carries them to an open reader, so it follows a re-read.
  Book.bookInfo(replacing:) keeps the stored record's table version only when the row names the same table, so a book read again from one of this Mac's tables to a bundled one keeps none of the Mac table's.
  The announcement says "“Ledger” is now read as THE TABLE'S WORDS."
  (BrailleTableCatalog.description(ofTableID:)), and one BRAILLE_TABLE_CHANGED line goes to the storage log (brailleTableLogLine(title:table:keptCopy:)), after BRAILLE_FILE_CODE_CHANGED for the file characters, in that order for the two in one (rereadLogLines(title:choice:update:keptCopy:)).
  Both name the title and the stored value, and no text of the book.

### Refusals while a re-read runs
<!-- id: refusals-while-re-read-runs; keys: busy, concurrent, error message, blocked; src: TextMouth/ViewModels/LibraryViewModel+TextEncoding.swift, TextMouth/Models/LibraryInfoWording.swift, TextMouth/Platform/macOS/Services/BookTextEditor.swift, TextMouth/Services/DuplicateReplacement.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift -->

- How others observe it: readingAgainRefusal(of:) says "TextMouth is reading “TITLE” again in another encoding.
  Try again when that finishes."
  (TextEncodingWording.readingAgainRefusal(bookTitle:)) for a book in booksBeingReadAgain, or, with no ID, for any, and names the work under way.
  TextRereads.begin(_:for:) records a TextRereadWork for each book (.encoding, .brailleFileCode, .brailleCode, or .replacement, TextRereads.works, forgotten once the book leaves bookIDs).
  Its refusal(bookTitle:) is the encoding's sentence, "TextMouth is reading “TITLE” again with other braille file characters.
  Try again when that finishes.", "TextMouth is reading “TITLE” again with another braille code.
  Try again when that finishes.", or, for Replace Existing, "TextMouth is replacing “TITLE” with the new copy.
  Try again when that finishes."; a book marked by setting bookIDs directly, with no work, is worded by its format as before.
  The quit panel's sentence still says "again in another encoding" for every kind of re-read and for a replacement.
  Four entry points ask it, so each waits in the same words and none leaves a content.md from one run beside the record of another:
  - a second re-read (textEncodingChangeRefusal(of:));
  - Edit Text (BookTextEditor.edit(_:choosingApp:in:from:), which announces it and opens nothing, before it looks at the book and again after its dialogs, since a re-read may begin while they are open);
  - Redo Text Extraction (redoAllTextExtraction starts no pass, and redoAllTextExtractionReturningOutcome returns the failure, which Storage settings' status line shows and VoiceOver announces; it said nothing before); and
  - Replace Existing (replacementRefusal(of:), asked last, since a re-read ends by itself in a moment, as DuplicateReplacement.Refusal.readingAgain, whose sentence is said as it is).

### A quit while a re-read runs
<!-- id: quit-while-re-read-runs; keys: shut down, Command Q, shutdown, delay quit; src: TextMouth/ViewModels/LibraryViewModel+TextEncoding.swift, TextMouth/App/QuitHold.swift -->

- A quit (0.4.4): TextRereads.quitWork is a QuitHold.Work (kind "text re-reads") that a quit waits for, until every re-read has written its text and its record, for 10 seconds at most (TextRereads.longestQuitWait).
  The whole quit is in [Launch](../launch.md).
  - A quit the person asks for is cancelled while it waits, and TextMouth asks to quit again afterwards.
    It says "TextMouth is finishing up before it quits: reading a book's text again in another encoding.
    It will quit as soon as that is done." in a panel and through VoiceOver, or "reading the text of 3 books again in another encoding" when several run.
  - A second Command-Q or the Dock's Quit meanwhile is cancelled too and says the same words again, so it no longer quits at once and cuts the re-read off.

## Edited text
<!-- id: edited-text; keys: external editor, hand edit, kept copy, text editor, word processor, backup copy, Edit With; src: TextMouth/Services/BookTextEditing.swift, TextMouth/Platform/macOS/Services/BookTextEditor.swift, TextMouth/Models/BookTextEditWording.swift, TextMouth/Services/TranscriptEdit.swift, TextMouth/Services/TranscriptEditAlignment.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouth/Services/LibraryIndexQuarantine.swift, TextMouth/Services/SavedFile.swift, TextMouth/Services/TextMouthPaths.swift, TextMouth/Services/FileImportService+Packages.swift, TextMouth/ViewModels/LibraryViewModel+TextEdits.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift, TextMouth/ViewModels/LibraryBookUpdates.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/ViewModels/ReaderViewModel+EditedText.swift, TextMouth/ViewModels/ReaderViewModel+LibraryUpdates.swift, TextMouth/Views/Reader/ReaderBookCommands.swift, TextMouth/App/MenuCommands.swift, TextMouth/Models/Book.swift, TextMouth/Services/TranscriptTextLoader.swift, TextMouth/Services/TranscriptStore.swift, TextMouth/Services/TranscriptTextBuilder.swift, TextMouth/Models/PlaceRelocator.swift, TextMouth/Services/LibraryPersistenceService.swift, TextMouth/Models/BookInfo.swift, TextMouth/Services/FileImportService.swift, TextMouth/Models/LibraryInfoWording.swift, TextMouth/Services/FileEventWatcher.swift -->

Edited text (FR05): a text book's content.md, or a transcribed audiobook's, an episode's in its feed included, since a transcript is the listener's own work and stays in the episode's package when its download goes, never a feed article's (BookTextEditor.canEditText(of:isTranscribed:), FR11).
The user edits it in an editor of their own (Edit Text in Default Editor and Edit Text With…).
- Owner: BookTextEditSessions.shared, one session for each book being edited.
  Its baseline is BookTextBaseline: the fingerprints of the source, a text book's own file or a transcribed audiobook's transcript.json, as BookTextEditSessions.sourceURL(of:) names it, and of content.md, taken when the edit began, or when TextMouth last took or rebuilt the text.
  A session also holds the edit the last check refused, and a copy a rebuild under way kept.
  BookTextEditor.shared, on the main actor, starts sessions, for a text book or an audiobook whose package holds a transcript (looked for off the main thread), and for no book that is being read again in another encoding (LibraryViewModel.readingAgainRefusal(of:), asked again after its dialogs).
  It watches each content.md with the app's shared FileEventWatcher (see [The config.json mirror](preferences.md#the-configjson-mirror)), which checks 0.75 seconds after the last change, follows a file an editor's save replaces, and listens to no file only in the cloud, and says what happened.
  A session ends when its book leaves the library (a check that finds no row, as for a feed episode whose download was deleted, announces BookTextEditWording.stoppedBookGone once: endBecauseBookIsGone).
  It also ends when Replace Existing puts a new copy in its place (ST04, in [Imports](imports-duplicates.md)).
  The book keeps its ID, so no check finds it gone, but the text being edited went with the old copy: BookTextEditor.endBecauseBookWasReplaced(_:title:) announces BookTextEditWording.stoppedBookReplaced once.
  It also ends when its transcript is replaced or deleted (BookTextEditor.pauseEditing(of:), which lets a check running finish, takes an edit saved but not yet checked through BookTextEditSessions.settlePendingEdit(of:), and ends the session).
  A change that fails calls resumeEditing(of:), which begins the session again from a fresh baseline.
  It also ends when the listener has its file read again in another encoding (LibraryViewModel.readTextAgain pauses the session the same way; see Reading a book again in another encoding, above).
  So a re-read that is refused begins it again and one that goes ahead leaves it ended, with BookTextEditWording.stoppedBookReadAgain in the announcement.
  It also ends when TextMouth quits.
  The record of an edit taken, for a text book, is Book.editedText (B12-OCT): an EditedText, the digest of the content.md the edit left and when it was taken.
  The check that takes the edit sets it (LibraryPersistenceService.saveContentAnalysis(…editedText:)).
  The package record keeps it (BookInfo.state.editedText), so a library rebuilt from its records still keeps the user's text.
  It is an analysis-owned field, which Book.applyContentAnalysis drops once an analysis records a content.md digest other than the edit's, as when Redo Text Extraction wrote the source's text or another edit was taken.

### Who may write edited text
<!-- id: edited-text-writers; keys: edit check, settlePendingEdit, TEXT_EDIT_KEPT, keepCopy, held edit; src: TextMouth/Services/BookTextEditing.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouth/Services/TranscriptEdit.swift, TextMouth/ViewModels/LibraryViewModel+TextEdits.swift -->

- Who may write it: the user's editor.
  Checks run on the sessions' serial queue, as storage work (StorageBoundary.perform(.contentAnalysis)): when content.md settles, when TextMouth becomes active, and before a reader reads the book.
  A check takes an edit when content.md changed and the source did not: it parses it, saves the new index with new fingerprints at the current cache format (LibraryPersistenceService.saveContentAnalysis), and drops the book's kept reading text.
  A transcribed audiobook's edit is taken into its transcript instead (TranscriptStore.takeEdit): TranscriptEditing.apply lays the parsed chapters over the transcript's sentences (TranscriptEditAlignment).
  Each sentence takes the words that stand for it and keeps its time, a changed one drops its words' timings (TranscriptSentence.rewrite(as:)), and one whose every word went is removed.
  The file transcript.json is written with editedAt, and the audio index's layer is saved with that transcript.json as its source and the user's content.md, unchanged, as its cache, so no load writes the text again over the edit.
  A layer the index or the record refuses puts transcript.json back as it was.
  Before any sentence is aligned, TranscriptEditing.checkOutsideSentences refuses what the transcript has nowhere to keep.
  That is a chapter heading that is not the one the text builder writes from the audio's chapter title (TranscriptTextBuilder.headingTitle(of:number:)), renamed, removed, or added (TranscriptEditError.headingChanged).
  It is also words besides the heading in a chapter without sentences (wordsWithoutSentences).
  An edit it can't take (a BookTextEditRefusal; failed covers an audiobook whose audio changed since it was transcribed) is first kept beside content.md as content.md.edited- and the time.
  The copy is made by keepCopy(of:bytes:), through SavedFile.preserveUnusable and LibraryIndexQuarantine under TextMouthPaths.keptTextCopyMarker.
  An earlier copy of the same bytes is used again.
  A chapter that nests quotes, lists, or emphasis past the reader's limit is one such refusal, since the exports cannot walk it.
  The check parses through MarkdownCacheService.parseMultiChapterMarkdownNamingRefusal, which throws a RefusedChapter in place of keeping the chapter raw as a read does, and BookTextEditing refuses with .nestedTooDeeply(chapter:limit:).
  BookTextEditWording names the chapter by its number: "Text not updated: chapter 3 of the edited text of TITLE nests quotes, lists, or emphasis more than 128 levels deep, which TextMouth can't read safely."
  Its second sentence says to flatten it in the editor and save again, or undo the change, and that until then the book keeps the text it had.
  A text with no chapter markers says "the edited text of TITLE", and the held book's reason says "its chapter 3 nests", or "it nests".
  - While an edit not taken stands beside an unchanged source, nothing replaces content.md.
    ReaderViewModel.readContent asks settlePendingEdit(of:), which answers readTaken, readAsUsual, or hold.
    The answer hold throws BookTextEditPending for a text book, which the reader shows in place of the book (loadHeldByTextEdit) until an edit is taken, and leaves out only an audiobook's transcript text, its audio loading and playing as ever.
    For an audiobook the reader keeps the reason (ReaderViewModel.transcriptWithheld, TranscriptTextWithheld.editHeld(_:keptCopy:)), which Search in Book says (see [The reader](reader-navigation.md); BookTextEditWording.heldReason(_:forAudiobook:)).
  - MarkdownCacheService.writeCache, the one path every rebuild of a text book's content.md takes, calls permitTextRebuild(of:writing:) before it replaces the file.
    That keeps any other text it would replace (TEXT_EDIT_KEPT) and refuses over an edit not taken (TEXT_EDIT_HELD), so the cache batch and Redo Text Extraction skip that book.
    Redo counts the books it left so (HeldTextEditTally), and Storage settings say how many (textReextractionOutcome(skippedInCloud:heldByEdits:)).
    BookTextEditSessions.textRebuilt(_:writing:fingerprint:) then makes the written text the session's baseline.
    TranscriptTextLoader.writeText calls it too, for the text of a transcript it writes again (its sessions argument: the app's for the loader's rebuild, none for an install, which pauses the session first), so TextMouth's own rewrite is never taken for the listener's edit.
    For a book no session watches, it keeps the text content.md holds beside it before the rebuild (keepTextSavedWithoutSession(of:replacedBy:), TEXT_EDIT_KEPT).
    It does so when that isn't what the book's record says TextMouth last wrote or took there, and also when it is an edit taken (Book.editedText, B12-OCT), which only Redo Text Extraction replaces.
    It refuses the rebuild when no copy can be made.
  - A finished edit is kept by automatic re-reads (B12-OCT): BookTextEditSessions.holdsTakenEdit(_:access:) is true when the book records an edit taken (Book.editedText) and content.md still has exactly that edit's digest.
    It reads nothing of a book that records no edit, and counts a content.md only in the cloud, missing, or unreadable as not matching.
    Then no automatic generation replaces the text: MarkdownCacheService.writeCache throws EditedTextKept before it reads the source, and logs one TEXT_EDIT_KEPT line naming the title only.
    It does so unless replacingEditedText is set, which only Redo Text Extraction (updateTextCache's force) and a re-read in another encoding (readTextAgain) set.
    The launch batch's committedTextCache indexes the text as it is and commits it with the current cache format once (keptText), so the batch does not visit the book at every launch, and a reader that meets EditedTextKept reads content.md as it is.
    Redo Text Extraction reads the file over the edit after keepTextSavedWithoutSession has kept the text as content.md.edited- and the time, and refuses the rebuild when no copy can be made; TextMouth deletes no copy itself.
    A re-read in another encoding keeps the copy itself first (keptUnwrittenText, above) and refuses when it can't (TextEncodingWording.editNotKeptRefusal(bookTitle:)).

### Edits saved while no session watched
<!-- id: edited-text-launch; keys: launch batch, TEXT_EDIT_ADOPTED, statistics pass, kept copies, saved while closed; src: TextMouth/Services/BookTextEditing.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift, TextMouth/Services/FileImportService.swift -->

  - Launch's cache batch takes an edit saved while no session watched, as while TextMouth was closed.
    For a book whose content.md no longer matches its row's fingerprints, and which no earlier run committed, it checks content.md as a session's save is checked.
    It checks against the fingerprints the book's record keeps (BookTextEditSessions.settleEditSavedWhileClosed, recordedTextCacheFingerprint(of:access:)).
    An edit beside an unchanged source is taken when it parses, logged as TEXT_EDIT_ADOPTED and announced to no one; any other is kept beside content.md, and the cache is rebuilt from the source.
  - The statistics pass skips books being edited (commitStatistics).
  - FileImportService.isPackageContentName (TextMouthPaths.isKeptTextCopy) keeps the copies out of the candidates for the book's own file.

### How readers see an edit
<!-- id: edited-text-readers; keys: text replaced, cursor follows, Text updated, announcement, unsessioned edit; src: TextMouth/ViewModels/LibraryViewModel+TextEdits.swift, TextMouth/ViewModels/ReaderViewModel+EditedText.swift, TextMouth/ViewModels/LibraryBookUpdates.swift, TextMouth/Models/BookTextEditWording.swift -->

- How others observe it: LibraryViewModel.commitTextEdit applies the analysis to the row and sends what the edit holds (BookTextEdit.text).
  It sends LibraryBookUpdates.textReplaced for a text book's DocumentContent, and transcriptReplaced for an audiobook's TranscriptText, which ReaderViewModel.showTranscript(_:) shows as the book plays on.
  Readers show a text book's new text (ReaderViewModel+EditedText), the cursor at the same words (PlaceRelocator.relocate(_:from:to:), with the places, in [Moving places at every load and Edit Text edit](package-records-places-and-files.md)), playing on if they were.
  A reader still loading shows it once loaded, and a reader held over an edit opens the book with it.
  VoiceOver hears "Text updated" (a feed episode's first edit taken in a session adds where its transcript stays: BookTextEditWording.updatedInFeed, with BookTextEditor.announcedFeedNotes keeping the episodes told of).
  It also hears why an edit wasn't taken, with the copy's name, once for each saved version, and where a rebuild kept replaced text, once for each copy.
  Each is heard only while TextMouth is active, or as soon as it becomes so.
  An edit saved while TextMouth isn't running has no session: a text book's is taken by the next launch's batch, or kept beside content.md by whatever rebuilds the text first, as a reader that opens the book before the batch reaches it does.
  A transcribed audiobook's edit is rebuilt over once TranscriptTextLoader has kept it beside content.md (see [Transcripts](package-records-places-and-files.md)).

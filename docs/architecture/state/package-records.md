# Package records
<!-- id: package-records; keys: package, tmb, per-book state; src: -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## The book record files
<!-- id: book-record-files; keys: package record, BookState, Codable, JSON file, storage, package folder; src: TextMouth/Models/BookInfo.swift, TextMouth/Models/Book.swift, TextMouth/Models/TextEncodingRecord.swift, TextMouth/Models/LenientFields.swift, TextMouth/Services/LibraryPersistenceService.swift, TextMouth/Services/TextMouthPaths.swift, TextMouth/Services/FileImportService.swift, TextMouth/ViewModels/LibraryViewModel+TextEncoding.swift, TextMouth/ViewModels/ContentAnalysisSummaryBuffer.swift -->

bookInfo.json and contentIndex.json: each package's record of its book (BookInfo), in two files.
bookInfo.json holds the metadata, the reading state, and the bookmarks, about a kilobyte, pretty-printed with sorted keys.
Beside it, contentIndex.json holds the content index alone, compact with sorted keys, since it can run to hundreds of kilobytes and changes only when the book is imported or analyzed.

- Owner: LibraryPersistenceService's metadata queue, for every save the running library makes.
  The record is built from a Book by Book.bookInfo(replacing:contentIndex:revisionFloor:).
  A braille book's table (BookMetadata.brailleTable, FMT21) and, for a Mac table, the liblouis version of this Mac's tables it was read with (BookMetadata.brailleTableVersion) are the row's, else the stored record's, so a row that lost either never erases it.
  Who chose the table (BookMetadata.brailleTableOrigin, brfguess, "guessed" or absent, an @LenientOptional) goes with it, but by the row's table.
  The row's origin is used when the row holds a table, so a choice in Book Information, which clears the origin, replaces a guess the record holds.
  The stored record's origin is used only when the row holds none (The guess of English Braille, American Edition, in [Imports](imports-braille-tables.md)).
  A text book's guessed or chosen encoding (BookMetadata.textEncoding, FMT16) and who decided it (BookMetadata.textEncodingSource, encodingchoice) are kept as one (TextEncodingRecord), by a rule of their own.
  A decision the stored record holds is a re-read's, which LibraryViewModel.readTextAgain writes with the new text, through saveContentAnalysis(…textEncoding:), before the library row takes it, so only a write that decides anew (decidingTextEncoding, which only that save passes) replaces it.
  Any other save, a reading checkpoint among them, whether the row it writes lags behind the re-read or not and with or without a content index, writes the stored record's encoding and source back as they are, and never the old encoding beside the new text.
  Crash recovery followed the same rule already (ContentAnalysisSummary.apply(to:), below).
  Over a stored record that names no decision, only a guess or nothing, a row that holds either writes its own, its nil encoding included, and only a row that holds neither takes the stored record's.
  Both are @LenientOptional properties (Models/LenientFields.swift).
  A value that cannot be read decodes as none, logged as a repair, without failing the record around it, and a nil one is left out of the file.
  So the record of a book with neither is exactly as it was (Text files in other encodings, in [Imports](imports-text-encodings.md)).
- Who may write it: saveBookInfo(for:) and saveBookInfo(for:contentIndex:), which hold each book's newest snapshot for half a second and write only it; saveContentAnalysis (below); and flushPendingSave().
  A save of a book's state writes over the package's record (BookInfo.saveRecord(to:)).
  A record carrying an index writes contentIndex.json first, so bookInfo.json never names an index that is not on disk yet.
  One without leaves contentIndex.json as it is, so a reading checkpoint writes about a kilobyte.
  The record such a save replaces is read as a StoredBookRecord, bookInfo.json and whether the package keeps an index, never reading contentIndex.json.
  A package written whole, by an import or a repair that separates a shared package, replaces both files (BookInfo.save(to:)), removing contentIndex.json when the record has no index; an import writes its new package's record so and reads it back (FileImportService.writeVerifiedRecord).
  Folder moves, migrations, and data-directory moves write records directly with Book.saveBookInfoThrowing, under the same revision rules but outside the queue's order.
  A move writes each staged copy's record as a save of its book does (saveBookInfoThrowing(contentIndex:inPackageAt:)), so the contentIndex.json it copied stays as it was, byte for byte.
  A record that is only in the cloud, or whose package or removal marker is, is neither read nor written by the queue, since reading it would download it.
  The book's saves go to library.json alone until the record is on this Mac again, with one BOOK_RECORD_IN_CLOUD line, and an analysis result for it is dropped.
- How others observe it: BookInfo.load(from:) reads bookInfo.json with the index from contentIndex.json.
  An index an older version kept inside bookInfo.json wins, and the next save moves it into its own file, while an older version reading a record written since finds no index and builds one once.
  A missing or damaged contentIndex.json leaves the record without an index, which the book's next load builds afresh, and a read refused because either file is only in the cloud is passed up rather than downloading it.
  Content analysis reads the saved index and fingerprints from the record (Book.storedBookInfo()), and saveContentAnalysis reads it back as a Book (Book(record:filePath:folderPath:tmbDirectoryName:)) to merge an analysis into.
  Orphan adoption, which also builds the provisional library while the index cannot be read, and importing a .tmb package (FileImportService.bookFromPackageInfo) rebuild library rows from records with that initializer too.
  Each leaves out the feed link its record may hold (Book.placedInLibraryFolder(), FR11), since a package in the Library folder is a book of the library's own.
  A feed's index rebuilds its rows the same way, keeping the link (see [Feed records](feeds.md)).

## Revisions
<!-- id: revisions; keys: revision counter, revisionFloor, record version, monotonic; src: TextMouth/Models/BookInfo.swift, TextMouth/Models/Book.swift, TextMouth/Services/LibraryPersistenceService.swift -->

Revisions.

- Owner: BookState.revision, in each record.
- Who may write it: every write stores one more than the record it replaces, and never less than one more than the highest revision this process has written for the book, so a book's revisions only rise, across restarts too.
- How others observe it: no decision rests on a revision.
  Whether an analysis still applies is decided by the book's content (below).

## Analysis-owned fields
<!-- id: analysis-owned-fields; keys: word count, extraction progress, analysis result, text extraction; src: TextMouth/Models/Book.swift, TextMouth/Models/TextEncodingRecord.swift, TextMouth/Services/LibraryPersistenceService.swift, TextMouth/ViewModels/LibraryViewModel+BookOperations.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift, TextMouth/ViewModels/ContentAnalysisSummaryBuffer.swift, TextMouth/ViewModels/TextExtractionProgress.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/Views/ContentView.swift -->

Analysis-owned fields.

- Owner: the content analysis.
  Book.ContentAnalysisFields travel together with the content index.
  They are the word and character counts, the audio duration, the content index version, the cache format version, the text cache fingerprint, the record of an edit taken (Book.editedText, B12-OCT), and the page reader that wrote content.md (Book.pageReaderVersion, PG09).
  The cache, its fingerprint, and the page reader are described in [Text caches and content indexes](text-caches.md), and the edit taken in [Edited text](text-caches-rereads-edits.md).
  Book.applyContentAnalysis drops editedText once an analysis records a content.md digest other than the edit's, and leaves pageReaderVersion as it is, since only a generation says which page reader wrote the text.
- Who may write it: LibraryPersistenceService.saveContentAnalysis merges a finished analysis into the book's latest durable state, on the metadata queue: the snapshot still waiting there, or else the record on disk.
  Only the analysis fields and the index change, and, when the caller passes one (textEncoding, which a re-read in another encoding does), the book's encoding and who decided it.
  A result is dropped, with one CONTENT_ANALYSIS_DROPPED log line, when that state describes other content: another MD5 hash, format, or file path, or another book's record.
  A save that carries no index keeps the stored index and its fields, so neither kind of write undoes the other.
  The reader commits a fresh index of its own through LibraryViewModel.updateContentIndex.
- How others observe it: a library row takes the committed fields and keeps its own reading state, settings, and metadata.
  The text cache batch and the statistics pass hand each finished book's fields to LibraryViewModel.analysisSummaries (ContentAnalysisSummaryBuffer).
  It gives the rows all that arrived in one change of library and one save, at most half a second after the first of them (flushInterval), when a pass ends, and when TextMouth quits.
  A summary a crash loses is recovered from the book's record by the next launch's batch.
  A summary also carries the encoding the book's record keeps for a text file, and who decided it (ContentAnalysisSummary.textEncoding and textEncodingSource, FMT16 and encodingchoice).
  A row that holds no encoding and no decision takes them, and so does a row whose record holds the listener's own decision.
  A re-read writes that decision into the record with its new text before the row takes it, so a row a stop left behind catches up when its analysis is recovered.
  A row that holds a guess of its own otherwise keeps it; a recovered summary takes the pair only from the book's own record (Text files in other encodings, in [Imports](imports-text-encodings.md)).
  The batch's progress is an object of its own, LibraryViewModel.textExtraction (TextExtractionProgress), which only the Library windows' overlay and Storage settings observe (ProgressObserver, the generic observer the import overlay uses too), so a finished book redraws only them.

## Metadata reader version
<!-- id: metadata-reader-version; keys: EPUB author, Unknown author, launch refresh, outdated metadata; src: TextMouth/Services/FileImportService.swift, TextMouth/Models/Book.swift, TextMouth/Models/BookInfo.swift, TextMouth/Models/SemanticVersion.swift, TextMouth/Parsers/EPUBParser.swift, TextMouth/Parsers/BrailleFileReader.swift, TextMouth/ViewModels/LibraryViewModel+MetadataRefresh.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift, TextMouth/ViewModels/ReaderViewModel+LibraryUpdates.swift, TextMouth/Services/StorageGeneration.swift, TextMouth/Services/MaintenanceFileAccess.swift -->

The metadata reader's version: which reader last read a book's file for its title and author.

- Owner: ImportedFileMetadata.readerVersion(for:), the version of the reader every import uses: "1.0.0", and "1.1.0" for braille books (brailleReaderVersion, since a BRF's title and author come from its braille title page), so that a better reader of one format reads only that format's books again.
  ImportedFileMetadata.read opens EPUB, Word, PDF, DAISY, and audio files, and, through TextMouth's own readers, rich text, RTFD, Word 6 to Word 2003, OpenDocument, and Word 2003 XML documents and KFX books.
  On the Mac it also reads a compound-file Word document older than Word 6 through textutil; an import leaves the textutil run out and takes their names from the conversion that reads their text (see [Imports](imports-textutil.md)).
  It reads a PEF braille file's head (BrailleFileReader.pefMetadata(of:)) and a BRF's braille title page (BrailleTitlePage.names(ofFileAt:table:fileCode:)); a BRL names neither title nor author, so it is read for nothing.
  It never reads a plain text, Markdown, HTML, web archive, or SSML file (readsFile(of:)).
  The version is stamped on the row as Book.metadataReaderVersion and, with the book's next save, in its record (BookMetadata.metadataReaderVersion), so a library rebuilt from its records reads again only the books saved before that.
  SemanticVersion.isOutdated(stored:current:) judges it as it judges the text cache's format version, so a stamp a newer TextMouth left in a shared library is never undone.
  An EPUB's author is EPUBParser.authorName(in:): the dc:creator with the author role (EPUB 2 opf:role, EPUB 3 a meta refining it), else the first dc:creator naming anyone, else a dcterms:creator meta element, else a dc:contributor with the author role.
  The name is trimmed, and an element holding only the placeholder Book.unknownAuthor names no one.
  All of parseOPF, readMetadata, and the editor's write (updateOPFMetadata, which writes into that creator or adds one) share the choice.
- Who may write it: an import stamps the row it makes (importFileWithReport).
  The launch's metadata refresh (LibraryViewModel.refreshOutdatedMetadata, in LibraryViewModel+MetadataRefresh.swift) reads the file of every row an older reader stamped, or none, but a feed item's (FR11), whose title and author come from its feed.
  It reads off the main thread with the same reader, each read as storage work a data-directory move waits for (StorageWork.metadataRefresh), and stamps every row read.
  Each file is read with an empty fallback title (ImportedFileMetadata.read(from:format:fallbackTitle:)), so a file that names no title names none.
  What it names for the fields the refresh may replace goes into a MetadataReading (Book.MetadataField.refreshable: the title, the author, and an EPUB's publisher and publication date), an author only when it names someone.
  The values a row takes are decided on the main actor, of the row as it is then, so a field edited by hand while the pass ran stays (refreshedValues(of:from:)).
  A row takes no field its record of hand edits names (hand edits, below).
  A row whose record has been kept since its import (Book.HandEdits.sinceImport) takes every other refreshable field whose value differs.
  Any other row, whose unrecorded fields may hold edits nothing recorded, takes only an author still at the placeholder, and only with a name.
  FileImportService.importFileWithReport begins such a record on every book it makes (hand edits, below); every other row can take nothing but an author in the placeholder's place.
  The refresh records no edit of its own, and a row with a field replaced has its record written as any edit of it would.
  A book whose files are in the cloud is left unstamped and counted in the pass's CloudSkips (MaintenancePass.metadataRefresh; see [Maintenance in a cloud library](cloud-state.md)).
  A book whose format keeps no metadata in its file, or whose content is a folder (of tracks, or an RTFD), is stamped without a look.
- How others observe it: updateContentCachesAndStatistics runs the refresh first, then the text cache batch, then the statistics.
  The rows take what was read in one change of the library and one save (applyMetadataReadings), and one METADATA_REFRESH line in the debug log counts the books read, the fields replaced, and the rows they were replaced on (metadataRefreshLogLine(read:replaced:rows:)).
  A reader follows a new author as it follows any edit (ReaderViewModel+LibraryUpdates).

## Hand edits
<!-- id: hand-edits; keys: manual edit, user-edited fields, edit flags, metadata override; src: TextMouth/Models/Book.swift, TextMouth/Models/BookInfo.swift, TextMouth/Models/LenientFields.swift, TextMouth/Services/FileImportService.swift, TextMouth/Services/FileImportService+Packages.swift, TextMouth/Services/FileImportService+Recording.swift, TextMouth/Services/Feeds/FeedEpisodeImporter.swift, TextMouth/ViewModels/LibraryViewModel+BookOperations.swift, TextMouth/ViewModels/LibraryViewModel+MetadataRefresh.swift, TextMouth/ViewModels/ReaderViewModel+Bookmarks.swift, TextMouth/Views/Reader/MetadataEditorView.swift, TextMouth/Views/Reader/ReaderView.swift, TextMouth/Views/Library/LibrarySheetViews.swift, TextMouth/Views/Library/LibraryView.swift, TextMouth/Views/Library/LibraryBookInfoLoader.swift, TextMouth/Views/Library/FeedItemBookInfoSheet.swift, TextMouth/Views/Feeds/FeedInfoSheet.swift -->

Hand edits (FR06): which of a book's metadata fields the user edited by hand.

- Owner: Book.handEdits, a Book.HandEdits (Models/Book.swift, under Hand Edits), on the row and, as BookMetadata.handEdits, in bookInfo.json.
  It holds the Book.MetadataFields edited (title, author, publisher, publicationDate, audioAlbum, audioGenre, and audioYear), kept in MetadataField.allCases order, each once, so a record is always written as the same bytes.
  It also holds sinceImport, whether the record has been kept since the book's import, so that it names every hand edit.
  A nil record means nothing was recorded: every row saved before the record existed, and every book since that the file import did not make, until an editor's save begins its record.
  library.json decodes it leniently (LenientFields.optionalValue), a record that can't be read counting as none.
  A field name a later TextMouth writes is dropped, and a record without sinceImport reads as begun by an edit. makeBookInfo() and Book(record:filePath:folderPath:tmbDirectoryName:) carry it both ways, and Book.EditableMetadata carries it, so a reader's copy takes the row's through libraryFields.
- Who may write it: LibraryViewModel.updateBookMetadata(_:of:contentHash:), the one save every metadata editor goes through.
  The editors that call it are the Book Info sheet of a plain text, Markdown, or HTML book (LibraryBookInfoSheet), the EPUB editor, and the audio editor.
  The EPUB editor is the library's and the reader's (ReaderViewModel.saveEPUBMetadata(_:openedAs:writeToFile:writer:)), through LibraryViewModel.saveEPUBMetadata(_:openedAs:for:writingToFile:writer:).
  The audio editor is the library's directly and the reader's through saveAudioMetadata(_:openedAs:).
  It takes a Book.MetadataEdit: the values of the fields the editor shows, as it opened with them and as they were saved.
  Its changes (MetadataEdit.changes) are the fields saved with a value other than the one the editor opened with, a field it opened without counting as opened empty, and each is saved without the blanks and line breaks around it.
  A field is a change only when the typed text differs from what the editor opened with and so does the trimmed text, so blanks over an empty field are no change and mark nothing, "Press " saves as "Press", and a value an older version saved with blanks, left alone, is not rewritten.
  The trimming is in changes and not in the edit's init, which would have made every such untouched field a change.
  An editor shows a value nothing knew as empty (Book.storedEPUBMetadata and storedAudioMetadata, which Book Info shows for a book only in the cloud), so such a field saved empty is no change and stays nil, and the book's file gives its value once the book is downloaded.
  Book.applyMetadataEdit(_:) applies the changes alone to the row as it is at the save, and marks exactly those through Book.markEditedByHand(_:), which begins a record with sinceImport false on a row without one; nothing removes a field.
  Every other field keeps the row's value, so a change another window or the launch metadata refresh made while the editor was open is neither put back nor marked, and the row's record keeps every field it gained meanwhile.
  A save with no change and no new content hash writes nothing.
  Every editor keeps what it opened with in @State, since whoever shows it may make it again with newer values, as the reader's Book Info does when the library changes the book.
  MetadataEditorView hands openedEPUBMetadata or openedAudioMetadata to its save beside the edits.
  LibraryBookInfoSheet keeps its title and author trimmed as Save trims them (values(title:author:)), from which edit(from:title:author:) makes its edit, or nil for a blank title.
  LibraryViewModel.saveEPUBMetadata, asked to write the library's copy of the EPUB file, writes it with the row as the edit leaves it laid over the editor's metadata (mergingEditableEPUBMetadata(_:)), and passes the written file's hash as contentHash.
  The save returns the row as saved, whose record the reader's copy takes.
  The reader's saves then show the saved row over the edit, and its audio save of a book no longer in the library changes nothing and says so (MetadataEditorWording.notInLibrary(title:), the sentence every metadata editor's save says when the book has left the library).
  HandEdits.noneSinceImport is the record FileImportService.importFileWithReport begins on every book it makes (each single-file format, a DAISY book's folder, package file, or navigation file, a text-only DAISY archive, and each book of a ZIP batch), beside the metadata reader version it stamps.
  It does so since that reader read its title and author in the very file the launch refresh reads again.
  New from Text (importText), recordings (importRecording), a feed's downloads (FeedEpisodeImporter), and archives of audio tracks or of a DAISY audio book (stagedAudioBook) begin none, and a package keeps what its record carries (bookFromPackageInfo, orphan adoption; reconstructedBook has none).
  An episode's or article's Book Info while it is in its feed (Book.hasReadOnlyBookInfo, FR11's branch C) has no editor and saves nothing.
  LibraryView.bookInfoSheet(for:) and the reader's ReaderBookInfoSheet show FeedItemBookInfoSheet (Views/Library/FeedItemBookInfoSheet.swift).
  Its details (FeedItemBookInfoWording.details(of:info:feedTitle:), each a BookInfoDetail) are drawn by FeedInfoValue as one element whose value can be selected, with a spoken value where it differs, as a duration does.
  LibraryViewModel.feedTitle(of:) names the feed, for Book Info and Speak Info, and the reader's Book Info button is labelled by readerButtonLabel(readOnly:).
### How hand edits are shown
<!-- id: hand-edits-shown; keys: edited by hand, accessibility label, recorded field, metadata editor label; src: TextMouth/Views/Reader/MetadataEditorView.swift, TextMouth/Views/Reader/ReaderView.swift, TextMouth/Views/Library/LibrarySheetViews.swift, TextMouth/Views/Library/LibraryView.swift -->

- How others observe it: the launch metadata refresh never replaces a recorded field (the metadata reader's version, above).
  MetadataEditorWording.fieldLabel(_:for:in:) (Views/Reader/MetadataEditorView.swift) adds MetadataEditorWording.editedByHand, "edited by hand", to the accessibility label of a recorded field's control, as in "Book title, edited by hand".
  It does so in MetadataEditorView, which takes handEdits:, and in LibraryBookInfoSheet, which reads its book's.
  The Library window passes handEdits: to both of its editors, and so does the reader's Book Info, ReaderBookInfoSheet (Views/Reader/ReaderView.swift), which observes the reader and passes its copy's record, which every save of the row, the reader's own included, brings up to date.
  For an episode or article in its feed (Book.hasReadOnlyBookInfo) it shows the read-only FeedItemBookInfoSheet, and for any other plain text, Markdown, or HTML book LibraryBookInfoSheet, which reads the reader's copy.

## The reading state of a record and its row
<!-- id: reading-state-record-row; keys: stale row, cloud library, two Macs, later place, movedToLibrary, Replace Existing, positionClock, takeNewerRecordedState; src: TextMouth/Models/Book+ReadingState.swift, TextMouth/Models/Book.swift, TextMouth/Models/BookInfo.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/ViewModels/ReaderViewModel+SavedPlaces.swift, TextMouth/ViewModels/LibraryViewModel+Duplicates.swift, TextMouth/ViewModels/LibraryViewModel+FeedItemMove.swift, TextMouthProductionTests/StaleRowGuardTests.swift -->

A library in the cloud shared by two Macs can leave a Mac's library row behind its book's record, which the other Mac wrote.
`Book.ReadingState` (Models/Book+ReadingState.swift) is a view of fields `Book` already keeps, so it adds nothing to a file: the place, the playback times, the bookmarks, the skipped headings (their three lists), and the book's own settings.
`Book.readingState(standingAgainst:)` is the one rule that weighs a row against its record:
- The record's state stands only when its place was saved later than the row's, compared to the second (`ReadingPosition.isSavedLater(than:)`, since both files keep the date to the second); a tie keeps the row's, and a place beats none.
  Going back is a later place too.
- The bookmarks, skipped headings, playback times, and settings go with the later place as one, not merged: a union of bookmarks would bring back each one deleted where the book was read last, since nothing marks a deletion yet.
  A bookmark or setting changed, without moving, on the Mac whose place is the earlier gives way to the other Mac's.
- The last-opened date is the later of the two.
- On one Mac the record is written from the row, so the row's state stands, as it always did.

It runs at every write of the record (`Book.bookInfo(replacing:contentIndex:revisionFloor:…)`), so a row that lags never writes its older state over the record's, and when a reader opens the book (`ReaderViewModel.takeNewerRecordedState(_:)`, from `LoadedContent.recordedState`).
Only the first load of a reader, the opening (`hasOpened`), weighs the record: a later load, as after an edit of the text, keeps this reader's own saves.
A place saved without moving keeps the date it was saved with, so opening a book never makes an old place the later one, and `close()` saves only a place that moved (`savePositionIfMoved()`), as a quit does.
A moved place is dated by `positionClock`, but never earlier than a second after the place it moves on from, so a clock set back cannot date a move before the last save.
A live place published while nothing plays and the cursor rests at the saved place is no move.

`BookMetadata.movedToLibrary` is the time Move to Library… made a feed's download the library's own.
It is record-only, like the transcript note: the move's write passes it, and every other write keeps the stored record's.
The launch's move of downloads into their feeds refuses a book whose record holds it, whatever a feed's record says, and a book whose record is only in the cloud waits for a later launch (`FEED_DOWNLOAD_MOVE_REFUSED`, see [Feed items](library-index-reading-feeds.md)).
Replace Existing reads the old record's note before the old package goes and writes it into the new record.
A move made before the note existed carries none, and none is added.


## Keys a later TextMouth adds
<!-- id: unknown-keys-kept; keys: V04, UnknownKeys, StoredKeyScan, JSONValue, forward compatibility, downgrade, unknown member; src: TextMouth/Models/UnknownKeys.swift, TextMouth/Models/StoredKeyScan.swift, TextMouth/Models/JSONValue.swift, TextMouth/Models/Book.swift, TextMouth/Models/BookInfo.swift, TextMouth/Services/ConfigService.swift, TextMouth/Services/DuplicateReplacement.swift, TextMouthProductionTests/UnknownKeysTests.swift -->

A key a later TextMouth adds is read with its object, held beside its fields as UnknownKeys, and written back as it was, so saving in an older TextMouth loses nothing (V04).
- It keeps them for a library row (Book and every record in it), a package record (BookInfo's top level, metadata, state, and the transcript note), config.json's top level, library.json's sections, folders and reading list, reading_stats.json's top level, and a feed index's rows.
- A known key always wins: unknown members are written first, then the type's own fields.
- An object changed in place keeps its keys; one made anew (a reading position at another place, fingerprints of rewritten files) starts with none, since a later version's note would describe the old object.
  A position saved again at its place keeps its keys (ReadingPosition.keepingUnknownKeys(ofSamePlaceIn:)), so a later TextMouth must treat its own keys as possibly stale.
- Unknown keys take part in == (a change only in one must be noticed by a save) and not in hashing; FeedBookLink's == stays feed and item.
- Values are JSONValue: exact above Int64.max, not kept to the last place past UInt64 or past 17 fraction places; keys are written sorted.
- Each hand-written encoder is held to the bytes and field list of a plain struct's, so a file with no unknown keys is written exactly as before.
- Merges carry them (bookInfo(replacing:), the standing reading state, Move to Library's note, config's save and merge); Replace Existing keeps the old row's, not the old package record's.
- StoredKeyScan looks through a file's bytes first for a name its schema lacks, and only a file that may hold one is decoded key by key (about 5 ms for 2.4 MB, against 14 ms on a 22 ms decode); it answers "may hold" whenever unsure.
- Not kept: feed records (Feeds/ID.json), substitutions.json, config.json's keyboard-shortcut and sound-assignment maps, removedFromLibrary.json, and Book.HandEdits' field names.
- UnknownKeysTests loads TestData/stored-v0.4.11 (files written by v0.4.11's own writers) and saves them byte for byte; a setting added since goes in its settingsAddedSince0411.

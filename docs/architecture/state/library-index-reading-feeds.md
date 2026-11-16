# The reading list and feed items
<!-- id: library-index-reading-feeds; keys: reading list, feed items, FeedShelf, feed index, podcast, playlist; src: -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## The reading list
<!-- id: reading-list; keys: playlist, queue, Continue to Next Book, Add to Reading List, Remove from Reading List, Next in Reading List, Library menu, finished books; src: TextMouth/Models/ReadingList.swift, TextMouth/Models/ReadingListCommand.swift, TextMouth/Models/ReadingListWording.swift, TextMouth/Models/ReadingListPlace.swift, TextMouth/Models/Library.swift, TextMouth/Models/LibrarySortState.swift, TextMouth/Models/ImportDecision.swift, TextMouth/Models/LibraryInfoWording.swift, TextMouth/Models/KeyboardShortcut.swift, TextMouth/ViewModels/LibraryViewModel+ReadingList.swift, TextMouth/ViewModels/LibraryViewModel+SortAndOrder.swift, TextMouth/ViewModels/LibraryViewModel+Import.swift, TextMouth/ViewModels/LibraryViewModel+Duplicates.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/ViewModels/LibraryListCache.swift, TextMouth/ViewModels/ReaderViewModel+ReadingList.swift, TextMouth/Services/ReadingStatsService.swift, TextMouth/Views/Library/ReadingListOptionsBar.swift, TextMouth/Views/Library/LibraryView.swift, TextMouth/Views/Library/LibrarySubviews.swift, TextMouth/Views/Library/LibraryInfoRow.swift, TextMouth/Views/ContentView.swift, TextMouth/App/MenuCommands.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/Views/Library/LibrarySheetViews.swift, TextMouth/Services/Feeds/FeedLifecycle.swift -->

The reading list (FR09): books from any folder, in an order the user arranges, and what a book opened from it does when it ends.

- Owner: Library.readingList, a ReadingList (Models/ReadingList.swift), saved in library.json with the rest of the index:
  - the books' IDs in reading order, each once,
  - and three options,
    - continuation (ReadingList.Continuation: playBookBelow, the default, playBookAbove, or stop, saved by its raw value, never by the words the options bar shows)
    - skipsFinished (true until cleared),
    - and removesFinished (false until set: a finished book on the list leaves it).

  It is read leniently: an ID that can't be read is skipped, one listed twice is kept where it first appears, an option missing or unknown reads as its default, and a list that can't be read at all is left empty, so it never makes the index unreadable.
- Who may write it: LibraryViewModel+ReadingList, every change through editReadingList(_:), which edits the list as the window shows it, any ID naming no book left out, and makes a change one change of library and one save, and a request that changes nothing no save:
  - addToReadingList and removeFromReadingList, whose announcing forms serve a row's, a selection's, the edit-mode bar's, and the Library menu's commands and say what they did, or why nothing changed, in ReadingListWording's words, each through LibraryView's changeReadingList(_:with:).
    At the Reading List it also takes the books taken off the list out of both selections, so the edit-mode bar counts the books still shown;
  - moveInReadingList and reorderReadingList, for Move Book Up and Down and a drag;
  - and setReadingListContinuation, setReadingListSkipsFinished, and setReadingListRemovesFinished, for the options bar.

  removeFinishedBookFromReadingList(_:) takes a just-finished book off the list when removesFinished is on, through removeFromReadingList(_:), silently.
  LibraryViewModel.observeFinishedBooks(of:), which startLibrary starts, hears ReadingStatsService.markBookFinished's .bookDidFinish, which is posted for every end it is told of and not for a rewind's replay, and receives it on DispatchQueue.main, so the removal never comes within the telling.
  Two things order the removal.
  A reader of a book from the list asks readingListContinuation(after:) in the turn it tells the end, and that answers only for a book still on the list, so the finished book is still there to be asked about.
  And a reader that reads its book from the list holds it at its end (ReaderViewModel.holdFinishedBookOnReadingList(), made before the end is told, counted in LibraryViewModel.readingListHoldCounts).
  The book is still the list's for that reader, whose replayed end, Play at the end, and Next in Reading List all ask the list, and the list overrides the book's own end rule.
  While a hold stands, a finished book is noted (finishedBooksAwaitingRelease) and stays.
  The reader releases the hold (releaseFinishedBookOnReadingList(), then LibraryViewModel.releaseFinishedBookFromReadingList(_:)) when it goes on to another book through the list (continueThroughReadingList(to:), openFromReadingList(_:)) or closes (close()), and the book leaves then.
  A book no reader holds, finished elsewhere, leaves one turn after the telling.
  A feed episode marked played by hand is finished the same way but at once (FeedLifecycle, then LibraryViewModel.booksMarkedPlayedByHand(_:)), after a reader reading it from the list holds it (ReaderViewModel.restOnBookMarkedPlayedByHand()).
  Mark Unplayed lets a waiting one stay, and puts none back (booksMarkedUnplayedByHand(_:)).
  The reader then reads its book as any book (ReaderViewModel.followReadingList(in:)).
  Turning the option on takes off none of the books already finished.
  An older TextMouth ignores the key and reads the option as off, and drops the key at its next save of library.json (a playing book saves within five minutes), which turns the option off for every Mac sharing the library.
### Imports, removals, and how the list is seen
<!-- id: reading-list-imports-removals; keys: import at the Reading List, Replace, Keep Both, finished books, Speak Info, In reading list; src: TextMouth/Models/ReadingList.swift, TextMouth/Models/ReadingListCommand.swift, TextMouth/Models/ReadingListWording.swift, TextMouth/Models/Library.swift, TextMouth/ViewModels/LibraryViewModel+ReadingList.swift, TextMouth/ViewModels/LibraryViewModel+Import.swift, TextMouth/ViewModels/LibraryViewModel+Duplicates.swift, TextMouth/Views/Library/ReadingListOptionsBar.swift, TextMouth/Views/Library/LibraryView.swift -->

  An import made at the Reading List (ImportRequest.addsToReadingList, set through the addingToReadingList: parameter of importFiles, importDAISYFolders, importZipAsync, importSingleFileAsync, and createBookFromText) adds its books to the list's end.
  It does so at every place its books join the library, a ZIP batch's together, through addImportedBooksToReadingList(_:request:), which announces ReadingListWording.importedAnnouncement(added:folderPath:), naming the folder the books went to, or LibraryFolderOption.rootLabel.
  A book already in the list stays where it is, and nothing is said when none joins.
  A duplicate's Replace calls ReadingList.replace(_:with:) before removeDeletedBook, so the new copy takes the old one's place before the old one leaves; a Replace at the Reading List of a book not on the list adds the copy to its end, as Keep Both does.
  Library.removeBook(id:) and removeFolderAndContents(id:) take a removed book off the list, so every way a book leaves the library ends there, the books Remove from Library Only retired included (see [Retirement markers](library-index.md)).
  The list's order is its own: moving a book in it never touches a folder's manual order.
- How others observe it: LibraryCategory.readingList, the Library window's fifth category, lists readingListBooks, which a search narrows and nothing sorts.
  A book row carries ReadingListCommand values (Add to Reading List for its books not in the list, Remove from Reading List for those in it, each counting a selection's books), as context menu items and as its last VoiceOver actions.
  And, in edit mode, EditModeBar shows ReadingListCommand.editBarCommands(for:inList:atReadingList:) beside Move.
  It shows those a selection's row would offer, or, with nothing selected, the one the view suggests, acting on no book and so dimmed (Remove at the Reading List, Add elsewhere).
  The commands are worded by ReadingListWording.editBarTitle, editBarLabel(_:count:), which counts the books as Move's label does, and editBarHint, and run through LibraryView's performReadingListCommand.
  A book row also says, outside the Reading List, "In reading list" (ReadingListWording.inReadingListNote) in its accessibility label, right after the title and author (BookRow.rowAccessibilityLabel), so it is in the same place on every row.
  The row has no accessibility value.
  At the Reading List, ReadingListOptionsBar shows the options, the Sort menu's one item is ReadingListWording.orderName, checked, the window is titled "Library: Reading List", and an empty list shows ReadingListWording.emptyList as a row.
  Speak Info says a book's place in the list in every view, the brief summary and the full alike (BookInfoFacts.readingListPlace, a ReadingListPlace, which LibraryInfoWording.briefParts(of:) says through readingListNote(_:) after the place note, "In reading list, 3 of 12").
  LibraryOrderCommandsSupport (Views/Library/LibraryView.swift) takes the Library menu's Move Book Up and Down and Add to and Remove from Reading List, which post addToReadingList and removeFromReadingList, for the Library window that takes the command (WindowCommandRouting).
  ShortcutAction.addToReadingList and .removeFromReadingList are in the Library group, with no default keys.
  LibraryViewModel.readingListNeighbor(of:direction:skippingFinished:) and readingListContinuation(after:) answer what a reader of a book from the list asks (see [Reading from the reading list](reader-navigation.md)).
  A book counts as finished by LibraryViewModel.finishedBookIDs, what Books Finished records (ReadingStats.finishedBookIDs), which tests replace: a deliberate record, unlike a position near the end (P07), kept when the book is read again.

## Feed items
<!-- id: feed-items; keys: podcast, RSS, episode, article, download, Feeds folder, feed index; src: TextMouth/Models/LibraryFeedShelf.swift, TextMouth/Services/Feeds/FeedIndex.swift, TextMouth/Services/LibraryPersistenceService.swift -->

Feed items (FR11): the episodes and articles a feed downloaded, their packages, and each feed's own index.

### Who owns feed items
<!-- id: who-owns-feed-items; keys: feedLink, FeedItemRows, shelf, kept row, feed folder, layout version; src: TextMouth/Models/FeedBookLink.swift, TextMouth/Models/Book.swift, TextMouth/Models/BookInfo.swift, TextMouth/Models/Library.swift, TextMouth/Models/LibraryFeedShelf.swift, TextMouth/Models/FeedItem.swift, TextMouth/Services/Feeds/FeedIndex.swift, TextMouth/Services/Feeds/FeedPaths+Items.swift, TextMouth/Services/Feeds/FeedStore.swift, TextMouth/Services/Feeds/FeedCenter.swift, TextMouth/ViewModels/LibraryViewModel+Feeds.swift -->

Owner: the library model, with each feed's index on disk.
A feed item's row is a Book whose feedLink (Models/FeedBookLink.swift: the feed's ID and the item's) names the feed and item it came from.
The link travels with the row's file location (Book.FileLocation, so a reader following a moved row finds the package).
It also travels with the package record (BookMetadata.feedLink, which makeBookInfo() and Book(record:filePath:folderPath:tmbDirectoryName:) carry both ways, a save writing the row's link or else keeping the record's).
And it makes tmbDirectory place the package in the feed's own folder, `Feeds/<feed ID>/`, beside the feed's record (Book.packageDirectory(inDataDirectory:)).
Services/Feeds/FeedPaths+Items.swift holds itemsFolder(of:in:), indexFile(of:in:), packageDirectory(named:of:in:), and feedID(ofItemsFolderNamed:), which takes a folder named by a feed's ID alone, so FeedStore never takes the folder for a record.
Each feed's index is `Feeds/<feed ID>/library.json` (FeedIndex, Services/Feeds/FeedIndex.swift: its layout version, 1, the feed's ID, and a row for each package, as library.json would hold the row, its link included).
FeedIndexFiles.encoded(_:) writes it as compact JSON with sorted keys and its rows by date added, so one index is always the same bytes.
Reading one checks its layout version first (FeedIndex.init(from:), a missing one read as 1), and one of a later version throws FeedIndexNewerLayout.
While TextMouth runs, a feed item's row is in one of two places in the Library:
- among books while its file is here, so the reader, positions, bookmarks, settings, the reading list, and Stats reach it as they reach any book;
- or else on Library.feedShelf (FeedShelf, Models/LibraryFeedShelf.swift).

FeedShelf is the rows held apart, which no list, count, or pass meets, among them, since FR11's branch A2, each row kept after its file went, holding the listener's place.
It also holds indexedFeedIDs, the feeds whose indexes the library keeps, so a feed whose last row left gets an empty index and a feed no library named is never written.
And indexesLeftAlone, the feeds whose index files no writer touches while TextMouth runs: one only in the cloud, one of a later layout, and a gone feed's while its downloads return to the library (leaveIndexAlone(of:) and forgetIndex(of:)).
And keepIndex(of:), for a feed whose index is written though its last row left, as Move to Library… leaves it.
Library.libraryBooks and libraryBookCount are the library's own books, every row without a link, and Library.feedIndexRows is each feed's rows, wherever they are, leaving out the feeds in FeedShelf.indexesLeftAlone, for every writer.
Each feed's rows by the identity of the item each came from are FeedItemRows (downloaded, among the books, and kept, on the shelf).
The model's FeedItemRowLookup works them out once for each change of the library, keyed by the list cache's content revision, for feedItemRows(of:) and feedBook(withID:).
So a feed's counts, an item's state (FeedCenter.state(of:in:) and downloadedRow(of:in:)), whether it is new, and a download restoring a kept row each find a row in one step rather than by a scan.

### Who may write feed items
<!-- id: who-may-write-feed-items; keys: download, delete download, Move to Library, remove file, replace package, startup repair, crash recovery, unsubscribe; src: TextMouth/Services/Feeds/FeedEpisodeImporter.swift, TextMouth/Services/Feeds/FeedItemPackage.swift, TextMouth/Services/Feeds/FeedIndex.swift, TextMouth/Services/Feeds/FeedLifecycle.swift, TextMouth/Services/Feeds/FeedReconciler.swift, TextMouth/Services/Feeds/FeedCenter.swift, TextMouth/Services/Feeds/FeedDownloadManager.swift, TextMouth/Services/LibraryPersistenceService.swift, TextMouth/Services/FileImportService.swift, TextMouth/Services/BookTextEditing.swift, TextMouth/ViewModels/LibraryViewModel+Feeds.swift, TextMouth/ViewModels/LibraryViewModel+FeedItemMove.swift, TextMouth/ViewModels/LibraryViewModel+FeedDownloadReturn.swift, TextMouth/ViewModels/LibraryViewModel+MoveToLibrary.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift, TextMouth/ViewModels/LibraryViewModel+IndexRecovery.swift, TextMouth/ViewModels/LibraryViewModel+BookOperations.swift, TextMouth/Models/LibraryFeedShelf.swift, TextMouth/Models/Library.swift, TextMouth/Models/Book.swift, TextMouth/Models/BookInfo.swift, TextMouth/Views/Feeds/FeedWording.swift, TextMouth/Services/Feeds/FeedStore.swift, TextMouth/Models/FeedItem.swift, TextMouth/Services/StorageGeneration.swift, TextMouth/Services/LibrarySessionLease.swift, TextMouth/Services/SavedFile.swift, TextMouth/Models/TranscriptTextIndex.swift, TextMouthProductionTests/FeedMoveToLibraryTests.swift -->

Who may write it: a download publishes its package into the feed's folder (FeedEpisodeImporter.destinationPackageURL, which makes the folder), and LibraryViewModel.addFeedBook(_:) adds its row with its link and no library folder (see [Downloads](feeds.md)).
Every save goes through LibraryPersistenceService.writeIndexFile, the one write path of library.json.
It first writes each feed's index from Library.feedIndexRows (writeFeedIndexes(of:), through FeedIndexFiles.encodedIndexes(of:placedIn:), each row placed where its package is by FeedIndexFiles.placed(_:in:of:), and FeedIndexFiles.write(_:in:fileManager:)).
It writes only an index whose bytes differ from what this process last read or wrote of it, or whose file is gone (feedIndexesOnDisk, a SavedFile.OnDiskMemory keyed by feed ID and confined to the save queue).
The library.json write uses the same memory, as [Who may write the library](library-index.md) says.
It then writes library.json, whose encoding (Library.encode(to:)) writes only libraryBooks, so no writer of library.json, a save, a checkpoint, the quit flush, a retry, Rebuild Library Index, or the data-directory move, can hold a feed item's row.
A feed's index that can't be written throws FeedIndexWriteError, naming its file, before library.json is touched, and is reported and retried as a failed library index write.
Reading library.json clears any link a row holds (Library's decoder, through Book.placedInLibraryFolder()), as orphan adoption and a package import do for a package found in the Library folder, whose record keeps the link: only a package in its feed's folder is a feed item's.
At launch, LibraryPersistenceService.load() reads every feed's folder onto the shelf (loadFeedShelf(fromPackages:reader:), FeedIndexFiles.readAll(in:fromPackages:reader:), reading each index without downloading it through an injectable reader), each row placed where its package is.
So moving the data directory or opening the library on another Mac rewrites no index first.
An index that can't be read is preserved beside itself (SavedFile.preserveUnusable, FEED_INDEX_UNREADABLE) and its rows rebuilt from the packages' records.
And a package the index doesn't list is read from its record too (FEED_INDEX).
An index only in the cloud, whose download is asked for (FEED_INDEX_IN_CLOUD), or of a later layout (FeedIndexNewerLayout, FEED_INDEX_NEWER) is left alone (FeedIndexFiles.Contents.isLeftAlone, kept in FeedShelf.indexesLeftAlone).
Its rows come from the packages' records, no writer writes it while TextMouth runs, and a library.json write meanwhile keeps the checkpoint journal.
The startup repair (migrateOldBooksIfNeeded) shelves every feed item's row first (Library.shelveFeedItems()), since its repairs reconcile the library's own books with the Library folder.
And at its end joinFeedItems(journaled:access:skips:) takes the newer positions the checkpoint journal names from their records for every shelf row, and moves the rows whose files are here, or in the cloud, to books.
A library.json row sharing a joining row's ID gives way to the feed item's, whose package is the one here, and a shelf row sharing a book's ID that stays is dropped.
While library.json can't be read, the provisional library takes each feed's rows from its packages' records, and Try Again and the data directory's return keep the session's (carryingRecoverySessionState(from:into:), through feedItems(of:over:), in LibraryViewModel+IndexRecovery.swift).
Once the feed engine's records load (moveFeedDownloadsOnceRecordsLoad()), LibraryViewModel+FeedItemMove.swift moves the downloads made before FR11 that a feed's record names as downloaded (FeedItemState.bookID), subscribed to or not, into their feeds' folders.
It does so through moveDownloadsIntoTheirFeeds(records:), holding the storage work as moving books between folders does.
It leaves a book where it is when its row names no package the library manages (FileImportService.namesManagedPackage(_:), FEED_DOWNLOAD_MOVE_REFUSED).
Each package moves in one rename, its row takes its link and its record is written there (moveIntoItsFeed(_:link:root:), through relocatePackage(of:as:root:)).
And LibraryPersistenceService.saveAndWait(_:) writes the feeds' indexes and then library.json at once, so a crash between any two steps is mended at the next launch (FEED_DOWNLOADS_MOVED, FEED_DOWNLOAD_MOVE_FAILED).
It then returns the downloads of each feed whose record is gone (below), and marks downloaded again each item an older TextMouth marked not downloaded, when its file is on this Mac (markFeedItemsDownloadedAgain(access:), FEED_ITEMS_DOWNLOADED_AGAIN).
A row whose file is not goes back to its feed's shelf as kept (FEED_ITEMS_KEPT).
### Moving downloads into the library
<!-- id: moving-downloads-into-library; keys: Move to Library, branch D, FeedDownloadReturn, feed record gone, stopgap, REV10; src: TextMouth/ViewModels/LibraryViewModel+MoveToLibrary.swift, TextMouth/ViewModels/LibraryViewModel+FeedDownloadReturn.swift, TextMouth/ViewModels/LibraryViewModel+FeedItemMove.swift, TextMouth/Models/LibraryFeedShelf.swift, TextMouth/Views/Feeds/FeedWording.swift -->

Move to Library… (FR11's branch D; ViewModels/LibraryViewModel+MoveToLibrary.swift: moveToLibraryReturningOutcome(_:toFolder:)) makes a feed's download a book of the library's own in an order whose every stop keeps the book.
It takes the rows booksMovableToLibrary(_:) keeps, each an item's download whose record says it is downloaded as that very row (.downloaded(bookID:)), so no two moves mark one item, or else a MoveToLibraryError.
It marks each item FeedItemState.inLibrary(bookID:), the listener's from then on, and waits for the record (FeedStore.flush(), before it holds the storage work, since a record's write is storage work itself), moving nothing when the record isn't saved (FEED_MOVE_TO_LIBRARY_PUT_OFF).
That write is the move's commit point, ahead of the rename where the addendum had it after, so a crash never lets the launch's move of downloads carry the book back into its feed.
Then, holding StorageWork.movingBooksBetweenFolders, it renames each package into the chosen folder (moveIntoTheLibrary(_:folderPath:root:), through relocatePackage(of:as:root:)).
It refuses a row that names no managed package (namesManagedPackage(_:)), the row losing its link while its record keeps it.
It tells readers (bookUpdates.packagesWillMove and packagesDidMove).
It makes each row a book of the library's own in that folder, the feed's index written without it even when it was the feed's last (FeedShelf.keepIndex(of:)), and saves and waits (saveAndWait(_:); FEED_ITEM_MOVED_TO_LIBRARY).
A package that can't move has its item's mark put back (unmarkInLibrary, FEED_MOVE_TO_LIBRARY_FAILED).
And a move whose packages moved only in part is a failure worded by FeedWording.partlyMovedToLibrary(moved:noun:folderPath:stayed:), what moved and then what stayed, grouped by reason, so the sheet stays open saying both.
A stop before the rename leaves the item In Library with its download in its feed, which markFeedItemsDownloadedAgain(access:) heals at the next launch.
A stop after it leaves the package under Library/, which the startup repair adopts under its own book ID (joinFeedItems(journaled:access:skips:)).
And the launch's move of downloads passes over an item In Library, reading only FeedItemState.bookID (FeedMoveToLibraryOperationTests).
It also passes over a book whose own record says Move to Library… made it the library's own (BookMetadata.movedToLibrary, through whatTheRecordSays(of:access:)), however another Mac's stale feed record names it.
A book whose record is only in the cloud waits for a later launch.
A feed whose record is truly gone, lost outside TextMouth or deleted by an Unsubscribe of a build before branch D, gets its downloads back as books at launch, a stopgap of REV10's item 3 (LibraryViewModel+FeedDownloadReturn.swift).
It runs through returnDownloadsOfFeedsWithoutRecords(knownFeeds:absence:removingWith:) and returnDownloads(ofFeed:toFolderID:removingWith:), holding the storage work as the move does:
- each package moves to the library's top level in one rename (moveIntoTheLibrary(_:folderPath:root:));
- library.json is written and waited for while the feed's index, which still lists them, is left alone (FeedShelf.leaveIndexAlone(of:));
- only then do the packages kept for removed downloads go, through FeedEnvironment.removeItem, and, once no download stayed, the feed's folder with its index (forgetIndex(of:); FEED_DOWNLOADS_RETURNED, FEED_DOWNLOAD_RETURN_FAILED).

LibraryViewModel.feedsTakenForGone(knownFeeds:absence:) chooses those feeds, never one the listener unsubscribed from, which keeps its record.
They are each feed whose folder was read while no record of it is loaded, only in the cloud, or in the Feeds folder, a sync service's placeholder of one counting as one (feedsWithoutRecords(knownFeeds:), FeedRecordAbsence.placeholderName(of:)).
It chooses them at once in a data directory outside a cloud location, and in a cloud one only when a note this Mac left at an earlier launch that found the record missing is in the feed's folder (FeedRecordAbsence).
That is because a feed subscribed on another Mac can arrive before its record.
The note is named .record-absent- followed by this Mac's ID, LibrarySessionLease's, and the launch's.
FEED_RECORD_ABSENT, as one is left, and FEED_RECORD_BACK, as the record's return takes this Mac's notes away, are both storage events.
LibraryViewModel.returnDownloads(ofFeed:toFolderID:removingWith:) does nothing, holding no storage work and saving nothing, for a feed that left nothing (leftSomething(feedID:)).
### Removing and restoring a feed item's file
<!-- id: removing-restoring-feed-item-file; keys: Delete Download, Delete Episode, newest-N rule, kept row, set aside, RENAME_SWAP; src: TextMouth/Services/Feeds/FeedItemPackage.swift, TextMouth/Services/Feeds/FeedEpisodeImporter.swift, TextMouth/Services/Feeds/FeedReconciler.swift, TextMouth/ViewModels/LibraryViewModel+Feeds.swift, TextMouth/Services/FileImportService.swift -->

Removing a feed item's file (FR11's branch A2), by Delete Download, the library's Remove of a feed item (FeedCenter.deleteDownload(ofBook:in:)), or Delete Episode, goes through LibraryViewModel.removeFeedFiles(of:keepingPackages:remove:).
The engine's own rules, the after-playing sweep and the newest-N rule (FR11's branch B), go through its two halves, readyFeedFilesForRemoval(of:keepingPackages:) and settleFeedFileRemovals(_:failures:).
The files are removed between them, off the main thread (removeDue, in [Played downloads and their deletion](feeds.md)).
All of these go in the order that never loses the listener's place.
First, a package holding the listener's state has its record written at once (writePendingBookInfoNow) and its row moved to the shelf, while a package holding none, or any package when Delete Episode passes keepingPackages false, goes whole.
A package holds the listener's state (FeedItemPackage.holdsListenerState(_:package:)) when it is opened, or has a place, playback times, bookmarks, a setting of its own, a field edited by hand, or files of the listener's, a transcript, a copy of one, or a copy Edit Text kept.
A package that cannot be listed is taken to hold them (holdsListenersFiles(_:)).
Then the indexes are written and waited for (LibraryPersistenceService.saveAndWait(_:), which returns whether every index reached the disk).
Only then does the caller's remove closure remove the file and what it made, keeping the record, the content index, content.md, the transcript's files, and Edit Text's copies, whatever the format (FeedItemPackage.staysWithoutTheFile(_:) and removeWhatTheFileMade(of:from:)).
Delete Download and the library's Remove take an article's file and its content.md together, moved by rename into a hidden .removing- folder beside the package and removed as one item through FeedEnvironment.removeItem (FeedItemPackage.removeFileAndText(of:in:remove:)).
So the Trash holds one item, a folder holding both, whose own place is gone once the holder is removed (a refusal puts both back in the package, and anything that can't go back stays in the holder, FEED_DOWNLOAD_HELD_ASIDE).
For a package that goes whole, the closure removes the whole package instead.
A failed index write throws FeedItemPackageError.indexNotWritten before any file is removed.
The library is put back as it was and saved again, and only the records written first, which hold the rows' own state, have changed.
A file that can't be removed puts its row back.
A removed row leaves the reading list.
And every package is checked against its feed's own folder before anything in it goes (FeedItemPackage.packageForRemoval(of:in:)), never the Library folder, so a download made before FR11 that has not moved yet is refused (FeedItemPackageError.notAFeedPackage).
Remove from Library Only refuses a feed item (staysInItsFeed), since retiring its package would delete its record.
Delete Download, the library's Remove, and Delete Episode remove the file, with an article's content.md, which may hold an edit, as one item, or the whole package through FeedEnvironment.removeItem, which follows the Trash setting (FileImportService.removeItemRespectingTrashSetting(at:)).
They delete anything else the file made for good (removeWhatTheFileMade(of:from:)).
The sweep and the newest-N rule delete for good (FeedItemPackage.removeForGood(_:in:), on the imports' queue), keeping an article's content.md in a kept package.
Downloading an item whose row is kept restores the same book (FeedEpisodeImporter.restoreBook, FeedDownloadManager passing the kept row from feedItemRows(of:)): the same ID, package name, date added, place, bookmarks, and settings, with the new file.
### Downloading an item whose row is kept
<!-- id: downloading-item-row-kept; keys: restoreBook, kept row, RENAME_SWAP, set aside, .replaced-, .edited- copy, FEED_PACKAGE_SWAP_FAILED; src: TextMouth/Services/Feeds/FeedItemPackage.swift, TextMouth/Services/Feeds/FeedEpisodeImporter.swift, TextMouth/Services/Feeds/FeedReconciler.swift, TextMouth/Services/FileImportService.swift -->

What a crash left set aside is put right first (FeedItemPackage.recoverSetAside(of:)).
Then the transcript's files and Edit Text's copies are copied into the staged package (FeedItemPackage.copyWhatANewDownloadKeeps(from:to:), which lists the kept package with listedEntryNames(of:), so one that cannot be listed fails the download and stays as it was).
And the book is read, recorded, and published as every import's is (FileImportService.publishReadableBook(_:from:run:feedLink:replacing:publish:)).
Its record's revision is raised above the kept record's and its transcript note follows the new index (writeVerifiedRecord(of:contentIndex:into:feedLink:replacing:)).
The publish step puts the new package in the kept one's place (FeedItemPackage.putInPlace(_:of:swap:)):
- in one step, renamex_np with RENAME_SWAP (swapItems(_:_:)),
- or, when the swap fails, as on a volume that cannot swap two folders, with one FEED_PACKAGE_SWAP_FAILED line giving the errno:
  - the kept package set aside beside it as .replaced- and its name (setAsideURL(of:)) while the new one is published,
  - removed once it is,
  - and put back should publishing fail.

What a crash in between leaves, the item's next download puts right (FEED_PACKAGE_PUT_BACK, FEED_PACKAGE_SET_ASIDE_REMOVED, FEED_PACKAGE_SET_ASIDE_LEFT).
An article's text kept by the rules is replaced by the new download's, and kept beside it as an .edited- copy when the two differ (FeedItemPackage.keepEarlierText(_:in:), through BookTextEditSessions.keepCopy(of:bytes:); REV11).
A copy that can't be written fails the download, the kept package staying as it was.
An episode's content.md, which the new package does not carry (its text is written from its transcript when it opens), is kept the same way only when it holds a save no session took.
FeedItemPackage.unrecordedTranscriptText(of:) returns its bytes when their digest differs from the one its record's transcript layer recorded for the content.md TextMouth wrote or took (BookContentTranscriptIndex.textCacheFingerprint).
That is how a save made to the text of an episode whose download a rule had meanwhile removed leaves it.
LibraryViewModel.addFeedBook(_:) then takes the kept row off the shelf as the restored row joins the books (FEED_DOWNLOAD_RESTORED).
A transcript of other audio, as when a host inserts other advertisements, is kept, and found stale as the episode opens.
FeedReconciler.kept keeps every played item and every item whose row is kept (keepingRecordsOf:, from FeedCenter.keptRecordItemIDs(of:)), whatever number of entries the feed's listing keeps (see [List and download choice, newest-N rule](feeds-interface.md)).

### How others observe feed items
<!-- id: how-others-observe-feed-items; keys: feed counts, Recently Opened, Move to Folder, Delete Download, Library menu, duplicates, summary bar, data directory move; src: TextMouth/Models/Library.swift, TextMouth/Models/LibraryBookSorter.swift, TextMouth/Models/CountWording.swift, TextMouth/Models/RemovalWording.swift, TextMouth/Models/FolderNavigationHistory.swift, TextMouth/ViewModels/LibraryListCache.swift, TextMouth/ViewModels/LibraryViewModel+SortAndOrder.swift, TextMouth/ViewModels/LibraryViewModel+BookOperations.swift, TextMouth/ViewModels/LibraryViewModel+MoveToLibrary.swift, TextMouth/ViewModels/LibraryViewModel+Feeds.swift, TextMouth/Views/Feeds/MoveToLibrarySheet.swift, TextMouth/Views/Feeds/FeedCommandRunner.swift, TextMouth/Views/Feeds/FeedCommands.swift, TextMouth/Views/Feeds/FeedLibraryPresentation.swift, TextMouth/Views/Feeds/FeedWording.swift, TextMouth/Views/Feeds/LibraryFeedFolders.swift, TextMouth/Views/Library/LibrarySubviews.swift, TextMouth/Views/Settings/StorageSettingsView.swift, TextMouth/Services/DataDirectoryMigrator.swift, TextMouth/Services/DataDirectoryAvailability.swift, TextMouth/Services/StorageDestinationAssessment.swift, TextMouth/Services/VoiceOverAnnouncer.swift -->

How others observe it: the library's lists, counts, and passes leave feed items out, reading libraryBooks:
- All Items,
- Unopened (Library.unopenedBooks()),
- folder trees and their counts,
- the duplicate rules (the import's question, a ZIP import's existing files, the one-book-per-file rule, and Find Duplicate Books, through booksForDuplicateScan),
- the metadata refresh,
- Rebuild Directory (Library.withFeedItemsSetAside(_:)),
- and a folder edit's transition, which keeps a feed item's location as it is.

### Move to Folder, Move to Library, and Remove for feed items
<!-- id: feed-items-move-remove-commands; keys: Move to Folder, Move to Library, Delete Download, Remove from Library Only, announceAfterSheetCloses; src: TextMouth/Models/RemovalWording.swift, TextMouth/ViewModels/LibraryViewModel+BookOperations.swift, TextMouth/ViewModels/LibraryViewModel+MoveToLibrary.swift, TextMouth/Views/Feeds/MoveToLibrarySheet.swift, TextMouth/Views/Feeds/FeedWording.swift, TextMouth/Services/VoiceOverAnnouncer.swift -->

Move to Folder… is not offered for feed items alone (LibraryTransitionWording.moveToFolderTitle(for:)), and LibraryView's moveToFolder(_:) opens no sheet for them.
And moveBooksReturningOutcome(_:toFolder:) moves only a selection's own books, announcing the items it left (LibraryTransitionWording.feedItemsLeft(titles:)).
Move to Library… is offered on a download's book row (FeedItemCommand.moveToLibrary, while canMoveToLibrary), as ShortcutAction.moveToLibrary (under Library, with no default key), whose key moves the selected downloads of the Library window that takes it, or a reader's book.
And it is offered in the reader's Book menu, enabled by the canMoveBookToLibrary scene value.
MoveToLibraryRequest and MoveToLibrarySheet (Views/Feeds/MoveToLibrarySheet.swift) wrap MoveFolderSheet with a heading and an explanation (FeedWording.moveToLibraryHeading(titles:noun:) and moveToLibraryHint(count:noun:)), read once, as text, the Move button giving no hint that repeats it.
The move's outcome is worded by FeedWording.movedToLibrary(titles:noun:folderPath:), which MoveToLibrarySheetPresentation, the one modifier the Library and reader windows present the sheet through, says 0.6 seconds after the sheet has closed (AnnouncementAfterSheet).
The library's Remove of feed items alone is worded as Delete Download (LibraryRemoveCommandWording.feedDownloads, REV11 F2).
The context menu's commandTitle(asksFirst:), "Delete 3 Downloads…", and the edit bar's shortTitle(asksFirst:), "Delete Downloads…" or "Delete Download…", carry the ellipsis only while the removal asks first.
A single feed item's row offers no Remove at all, its own Delete Download standing for it (isOfferedOnRow(for:feedActions:)).
And the Library menu's Remove reads the same with only feed items selected (menuBarTitle(preferences:selection:), from the LibraryRemovalSelection each Library window publishes as FocusedValues.libraryRemovalSelection through focusedSceneValue).
The question offers no Remove from Library Only (RemovalChoiceWording.feedDownloads, a FeedDownloadRemovalWording, and offersLibraryOnly).
And what the removal did is reported through VoiceOver (LibraryViewModel.removalCompletion(_:mode:kept:), naming only what each kept package holds, FeedDownloadRemovalWording.completionMessage(kept:)), once the question has closed (VoiceOverAnnouncer.announceAfterSheetCloses(_:from:)).
Or it is reported at once when no question was asked.
### Feed folders, counts, and the data-directory move
<!-- id: feed-items-folders-counts-move; keys: feedItems(listedIn:), FeedFolderListing, Recently Opened, CountWording, Library Statistics, stageFeedIndexes; src: TextMouth/Models/Library.swift, TextMouth/Models/LibraryBookSorter.swift, TextMouth/Models/CountWording.swift, TextMouth/ViewModels/LibraryListCache.swift, TextMouth/Views/Feeds/LibraryFeedFolders.swift, TextMouth/Models/FolderNavigationHistory.swift, TextMouth/Views/Settings/StorageSettingsView.swift, TextMouth/Services/DataDirectoryMigrator.swift -->

A feed's folder lists its items beside its books by feed ID (feedItems(listedIn:), through feedID(listedIn:)), so renaming or moving the folder, or Feed Info's choice of another, takes them along without changing a row.
And FeedFolderListing.make pairs each item with its book through FeedItemState.linkedBookID, a download or the book Move to Library… made of it, so a book moved into its own feed's folder is listed once, as its book's row with its item's commands.
LibraryListCache.Key holds the feed whose folder is shown, so a feed given another folder derives the list again.
Recently Opened lists, of each feed's items, the one opened last (LibraryBookSorter.recent(_:limit:)), and the reading list any it holds.
What follows a feed's item when it ends, the next item its feed's folder lists that way, downloaded or not, is the reader's to find (LibraryViewModel.succession(after:going:skippingFinished:); see [The reader](reader-navigation.md)).
The counts name the feeds beside the books (CountWording.booksAndFeeds(books:feeds:), "743 books, 2 feeds"):
- the summary bar (TimeRemainingBar.countText, through CountWording.listItems(of:feeds:), which in Recently Opened and the Reading List counts the episodes and articles they list apart from the books, "9 books, 1 article", its feedCount the feeds the Feeds section lists there),
- the Books section's heading in those two (CountWording.booksHeader(of:), "Books (9), Articles (1)"),
- entering a folder (FolderNavigationHistory.announcement(for:library:feedCount:)),
- a folder's row (FolderRow's feedsBelow, from LibraryFeedFolders.feedCount(below:)),
- Storage settings' Library Statistics (LibraryStatistics, with a Feeds line),
- and Use This Library's confirmation (StorageChoice.CurrentLibrary.feedCount).

Rebuild Directory says the books alone (rebuildDirectoryDoneMessage(_:)).
The data-directory move stages each package where Book.packageDirectory(inDataDirectory:) puts it in the copy.
It also writes each feed's index that holds rows there (DataDirectoryMigrator.stageFeedIndexes(of:at:in:fileManager:), through FeedIndexFiles.encodedIndexes(of:placedIn:) and write(_:in:fileManager:), as a save writes them), an index left alone keeping its copy.

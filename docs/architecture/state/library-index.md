# The library index
<!-- id: library-index; keys: library.json, folders, sort order, persistence; src: -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## The library
<!-- id: library; keys: library model, sort settings, autosave, debounce, ObservableObject; src: TextMouth/Models/Library.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/Services/LibraryPersistenceService.swift -->

The library: every book's row, the folders, each location's sort, and the reading list (see [The reading list](library-index-reading-feeds.md)).

### Who owns the library and its sort keys
<!-- id: who-owns-library-sort-keys; keys: sort settings key, reserved folder names, folder name, view sort, FolderSortSetting; src: TextMouth/Models/Library.swift, TextMouth/Models/LibrarySortState.swift, TextMouth/Models/LibraryViewDefinition.swift, TextMouth/Models/BookFolder.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/ViewModels/LibraryViewsSettingsActions.swift -->

Owner: LibraryViewModel.library, published on the main actor.
It is the live copy; library.json, with each feed's own index (see [Feed items](library-index-reading-feeds.md)), is its saved form.
Each location's sort is kept in folderSortSettings under the location's key (LibraryLocation.sortSettingsKey).
The key is a folder's path in Folders, and in every other category a reserved key (LibraryCategory.sortSettingsKey: __allItems__, __unopened__, __recent__, and __readingList__, under which nothing is saved).
No folder may take a reserved key as its name (BookFolder.reservedNames, made from those keys and the former No Folder category's __noFolder__).
The Feeds view and each view the listener made (LibraryViewDefinition.sortSettingsKey) keep their sorts under "/views/" and the view's stored identity (LibraryViewDefinition.sortSettingsKeyPrefix), as "/views/Feeds" or "/views/" and a UUID.
A folder path never begins with "/", so no folder can take such a key and BookFolder.reservedNames needs no more names.
And renaming, moving, deleting, and repairing folders never touch these keys, which are not valid library paths.
The Library tab's commands write them through LibraryViewsSettingsActions: Duplicate copies the sort shown to the copy's key, Delete removes the deleted view's key, and Restore Default removes the restored view's key, or, for Unopened, writes its shipped sort under __unopened__.
The editor's Sort By and Order save under the same key as the Sort menu.
An older TextMouth keeps these keys, reading every key of folderSortSettings and writing them back.

### Who may write the library
<!-- id: who-may-write-library; keys: save queue, debounce, atomic write, library index, checkpoint journal, flush, autosave, OnDiskMemory; src: TextMouth/Services/LibraryPersistenceService.swift, TextMouth/Services/SavedFile.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/ViewModels/LibraryViewModel+BookOperations.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift, TextMouth/Services/LibraryLoadResult.swift -->

Who may write it: LibraryViewModel and its extensions, on the main actor.
Each change is followed by save(), which hands a snapshot to LibraryPersistenceService.save(_:).
That waits half a second on the service's serial queue, and only the newest snapshot is written, so an older snapshot never lands after a newer one.
A reading checkpoint goes through saveReadingCheckpoint(_:of:writingWithin:) instead, which lets its snapshot wait up to five minutes (readingCheckpointDelay), since the book's record holds the checkpoint meanwhile.
Any ordinary save writes it sooner, and writePendingIndexSoon() brings it forward when a reader closes (unregisterOpenBook) and when a record cannot take its checkpoint, being only in the cloud or failing to be written.
Until an index write holds every checkpoint, ReadingCheckpointJournal names the books whose records are ahead in reading-checkpoints.json, noting each before its record is written.
And launch's repair gives each book it names its record's newer position and last-opened date (booksWithCheckpointsAhead() and adoptNewerRecordedPositions). flushPendingSave() writes a waiting snapshot before the app quits.
Every write first writes each feed's index whose bytes changed or whose file is gone (see [Feed items](library-index-reading-feeds.md)), then replaces library.json atomically, as compact JSON with sorted keys (encodedIndex(_:)), unless it holds those bytes already.
They equal what this process last read or wrote of it, and the file is still there (writeLibraryFileIfChanged(_:), through libraryIndexOnDisk, a SavedFile.OnDiskMemory confined to the save queue like the feed indexes' memory).
A save that changes nothing of the library's own books, as the reading checkpoints of a feed episode do while it plays (its row is in its feed's index), therefore writes nothing to library.json.
The keys are sorted because Library.folderSortSettings is a dictionary, whose order can differ between two equal ones; the first save after upgrading from a release that wrote them unsorted rewrites the file once.
A write skipped so still counts as a save.
It settles an earlier failed write (failureCenter.recordSuccess(.libraryIndex)), such as a feed's index that could not be written and is written by the retry while library.json is unchanged, and clears the checkpoint journal, as a write does.
A write of library.json that throws, as a write of a feed's index does, forgets what the file was remembered to hold (SavedFile.OnDiskMemory.write(_:for:using:), in [shared helpers](../shared-helpers.md)), since the file's state is then unknown.
The retry, and any later save whatever it holds, writes again.
Reading library.json notes its bytes (rememberLibraryIndex(_:readFrom:)), so the first save after launch writes nothing when it changes nothing.
A library.json that cannot be read or decoded is forgotten, so the next save writes it whatever it would encode to.

### How others observe the library
<!-- id: how-others-observe-library; keys: ObservableObject, Published, sort setting, sort order, FolderSortSetting, Sort menu, manual order; src: TextMouth/Models/Library.swift, TextMouth/Models/LibrarySortState.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/ViewModels/LibraryViewModel+BookOperations.swift, TextMouth/ViewModels/LibraryViewModel+SortAndOrder.swift, TextMouth/ViewModels/LibraryBookUpdates.swift -->

How others observe it: SwiftUI views observe LibraryViewModel.
A reader takes a copy of its book when it opens and reports back through LibraryViewModel.
It calls updateLiveReadingPosition (live reading positions, below, which change nothing in the library), persistReadingPosition (the row and the package record at once, library.json within five minutes), and updateContentIndex.
Every change of library is offered first to LibraryViewModel.listCache (the lists Library windows show, below), then to LibraryViewModel.bookUpdates, which keeps the copies of open readers current (a reader's copy of its book, below).
No timer republishes the library: nothing a Library window shows depends on the clock, and a value that ever does should use a TimelineView rather than a tick that redraws every window.
Every window, menu, and list reads a location's sort through Library.sortState(at:), from Library.sortSetting(at:) (Models/LibrarySortState.swift).
At the Reading List, which shows an order of its own (LibraryLocation.keepsItsOwnOrder), that is always FolderSortSetting.readingListOrder, shown as manual order, and userChangedSort(_:at:) saves nothing there.
Anywhere else it is the first of these that exists:
- the setting saved under the location's key;
- in Unopened alone, which took No Folder's place, the setting saved under No Folder's key, __noFolder__, unless its field is manual order, which was the arrangement of the root's books alone;
- and the category's default (title ascending; last opened descending in Recently Opened; date added descending in Unopened, FolderSortSetting.unopenedDefault, since no unopened book has been opened).

Nothing is written under __noFolder__ again, so a sort chosen in Unopened, saved under __unopened__, takes that one's place for good.
Outside the Reading List, userChangedSort(_:at:) saves only a sort that LibrarySortState.applying(_:) changed.
Choosing the field shown again returns the sort unchanged (A11), so nothing is saved, and only LibrarySortChange.reverseDirection, the menu's Sort Ascending or Sort Descending, reverses a direction.

### A book's row in memory
<!-- id: book-row-memory; keys: copy-on-write, add a field, new field, Book fields, Mirror, memory size; src: TextMouth/Models/Book.swift, TextMouthProductionTests/BookBoxTests.swift, TextMouthProductionTests/OnDiskContractTests.swift, TextMouthProductionTests/UncheckedConcurrencyPolicyTests.swift -->

A book's row in memory (audit C13): struct Book keeps its whole API, but its stored fields live in one private final class, Book.Storage.
Every copy of a Book shares that box until one copy is written.
Each setter and `_modify` calls makeUnique() first, which copies the box with Storage.copy() when isKnownUniquelyReferenced says it is shared.
Copying the library's array of 1,500 books then copies 1,500 references rather than 1,500 sets of 51 fields, and the Release app is about 0.9 MB smaller.
The value witness functions (copy, destroy) of Book and of every type that holds one, as LatestDurableState and LoadedContent do, now handle one reference instead of about 30 fields.
Writing a field of a shared book copies its box once; nothing writes every book of a copy often (the launch refresh, renumbering and a folder rename write only the books they change).
Storage is `@unchecked Sendable` because a shared box is never written (UncheckedConcurrencyPolicyTests pins it).

- Book's Codable, `==` and hash(into:) are written out by hand, field by field, in declaration order.
  The encoder uses encodeIfPresent for exactly the optional fields, so library.json and each record are byte for byte what the synthesized versions wrote (OnDiskContractTests).
- Adding a field to Book: add it to Storage with its default and to Storage.copy(), give Book an accessor (get, set and `_modify`, each calling makeUnique()), and add it to CodingKeys, init(from:), encode(to:), `==`, hash(into:), and the initializers.
  BookBoxTests fails when a field is missing from `==` (testEqualityComparesEveryField, whose edit list testTheEditsNameEveryField pins to the fields) or from copy() (testCopyOnWriteKeepsEveryOtherField), and OnDiskContractTests fails when the contract does not name it.
  The tests read the fields through Book.reflectedFields (in BookBoxTests.swift), which looks inside the box.

## Live reading positions
<!-- id: live-reading-positions; keys: playback position, time remaining, summary bar, LiveReadingPosition, ObservableObject, checkpoint; src: TextMouth/ViewModels/LiveReadingPositions.swift, TextMouth/ViewModels/TimeRemainingTally.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/ViewModels/LibraryViewModel+BookOperations.swift, TextMouth/Views/Library/LibrarySubviews.swift -->

Live reading positions: where readers are in their books between checkpoints, for the rows and the summary bar.

- Owner: LibraryViewModel.livePositions, a LiveReadingPositions on the main actor, holding one LiveReadingPosition for each book, kept for the session.
- Who may write it: readers, about once a second while they play, through LibraryViewModel.updateLiveReadingPosition; a book no longer in the library changes nothing.
  When openBookIDs changes, a book no reader has open drops its entry (keepOnly), its reader having saved its position to the library as it closed.
- How others observe it: a book's row (BookRow) observes its own book's entry, so a live position redraws that row alone, and the summary bar (TimeRemainingBar) observes the store; the library model publishes nothing.
  The store keeps liveBookIDs, the books whose entries hold a live position, which entries a reader's report adds to and keepOnly removes from, and estimatedTimeRemaining(of:wpm:) answers a book with none from the book itself, without copying it.
  The bar adds the list up through a TimeRemainingTally (ViewModels/TimeRemainingTally.swift, the audit's C7), a @State of the bar.
  Its sum(of:wpm:livePositions:) estimates every book once, at the positions the list shows, and keeps each book's time left, in the list's order.
  A redraw then takes the kept figures and estimates again only the books in liveBookIDs, so the total is the one a full addition gives, to the last bit.
  What is kept is good for the same array of books, told by its storage (which the tally holds, so it is never another array's), at the same speed; a library change makes a list anew and the next addition is made afresh.
  The static sum(of:wpm:livePositions:) adds a list from nothing, for a folder's facts and the phone's spoken summary.
  A live position carries no anchor, the words around the place, which only a checkpoint takes (makeCurrentReadingPosition(withAnchor:)).
  A live position is shown in place of the row's own only while it is the newer (ReadingPosition.lastUpdated), so a checkpoint, or a position another window saved, takes over at once.

## Lists Library windows show
<!-- id: lists-library-windows-show; keys: list cache, sorted list, search results, derived list, Recently Opened, Unopened, Move Book Up, drag to reorder; src: TextMouth/ViewModels/LibraryListCache.swift, TextMouth/ViewModels/LibraryViewModel+FolderManagement.swift, TextMouth/ViewModels/LibraryViewModel+SortAndOrder.swift, TextMouth/ViewModels/LibraryViewModel+ReadingList.swift, TextMouth/Models/LibraryBookSorter.swift, TextMouth/Models/LibrarySortState.swift, TextMouth/Models/Library.swift, TextMouth/Views/Library/LibraryView.swift, TextMouth/ViewModels/LibraryViewModel.swift -->

The lists Library windows show: each location's books in its sort, narrowed by a search, and the book counts of folder trees.

- Owner: LibraryViewModel.listCache, a LibraryListCache on the main actor, which derives each list once and keeps it, at most LibraryListCache.entryLimit lists, until a change it depends on.
  It publishes nothing, so a window may derive and store a list while SwiftUI draws.
- Who may write it: the library itself, which offers every change of library to listCache.libraryDidChange(from:to:) before anything reads it.
  A change of membership (which books there are, their order in the library, their folders, and their feed links), or of the reading list's books or their order (LibraryListCache.readingListMayDiffer, which its options never change) drops every list.
  So does a change of a field a sort or a search reads (the title, the author, the metadata language whose articles a title may be read without, epubLanguage, the dates added and last opened, the manual order, and the book's file).
  Any other change, such as a word count or a voice setting, keeps every list's order and refreshes only its books' values.
  A reading checkpoint stamps the book's last-opened date, so it sorts the lists again.
  Folder trees are counted in one pass whenever the lists are dropped, from the library's own books, and the sizes a File Size sort reads are measured once per book, until its file changes.
  A list's key (LibraryListCache.Key) holds, for a feed's folder in Folders, the feed whose items it lists, so the list is derived again when that changes although no book did.
  So does the Leading articles setting it was sorted and searched by (LibraryListCache.Key.articles, read once for each derivation by LibraryViewModel.leadingArticles), so a change of the setting derives each list again without dropping the lists kept.
  And the lists kept for the old choice stay until entryLimit makes the cache start over.
- How others observe it: LibraryViewModel.bookByID(_:), which a reader asks for each live position it publishes, goes through listCache.book(withID:in:), the index of each book by ID that the cache keeps for each revision of the list (bookIndex(of:)), not a scan of every book.
  An index that does not point at the book it names falls back to the scan, so a wrong index can slow the answer but never change it.
  A Library window reads its list through displayedBooks(at:matching:) and bookCount(inFolderTree:) as often as it draws: the first read after the lists were dropped derives its list again, and the first after any other change refreshes the list's books.
  Before sorting, a location lists LibraryViewModel.booksForCategory's books:
  - a folder's in Folders, with its feed's items for a feed's folder (feedItems(listedIn:));
  - every book of the library's own in All Items (Library.libraryBooks);
  - in Unopened every book of its own never opened, from every folder (Library.unopenedBooks(), the books Book.isUnopened names, those whose lastOpened is nil, as a record's BookState.isNew says too);
  - in Recently Opened the ten rows opened last, books and feed items alike, of each feed's items only the one opened last, which takes one of the ten places (LibraryBookSorter.recent(_:limit:));
  - and at the Reading List the list's books in its order (readingListBooks), which displayedBooks(at:matching:) never sorts, a search narrowing that order.

  A feed's items are listed nowhere else (see [Feed items](library-index-reading-feeds.md)).
  Opening a book stamps its lastOpened, which the lists depend on, so the book leaves Unopened as the list is derived again.
  LibraryLocation.manualOrderFolder is nil in All Items, Unopened, Recently Opened, and the Reading List, whose books come from many folders that share no one order.
  What dragging and Move Book Up and Move Book Down rearrange is LibraryLocation.reorderTarget(sortedBy:), a LibraryReorderTarget: a folder's manual order in Folders, the root included, while the list shows it, or the reading list at the Reading List, always.
  LibraryViewModel.moveBook(_:direction:in:) and reorderBooks(in:from:to:) take a move or a drag there, and each move made from the Library menu, the keyboard, or a row's context menu is announced alike (ManualBookOrder.MoveResult.announcement).
  A row's Move Up and Move Down VoiceOver actions go through LibraryView's moveSayingPlace(_:direction:), which moves through moveBook(_:direction:in:) as well and announces the book's new place instead (MoveResult.placeAnnouncement, MoveResult.count being the order's length as the list shows it).
  Or, when the list changed after the row offered the move, ManualBookOrder.cannotMoveAnnouncement.

## Titles as the lists read them
<!-- id: titles-as-lists-read-them; keys: leading articles, articles setting, title sort, MARC 21, nonfiling, letter navigation, rotor, inverted title; src: TextMouth/Models/LeadingArticles.swift, TextMouth/Models/LeadingArticleWording.swift, TextMouth/Models/TitleTyping.swift, TextMouth/Models/LibraryBookSorter.swift, TextMouth/Models/LibrarySortState.swift, TextMouth/Models/LibraryViewFilterEvaluator.swift, TextMouth/ViewModels/LibraryListCache.swift, TextMouth/ViewModels/LibraryViewModel+SortAndOrder.swift, TextMouth/ViewModels/LibraryViewModel+FolderManagement.swift -->

Titles as the lists read them (the Leading articles setting): what a leading article does to a list's sort, rows, search, and letter navigation.

- Owner: LeadingArticles (Models/LeadingArticles.swift), the choice and what each choice does with a title: sortKey(of:language:), shownTitle(_:language:), and rowTitle(of:), which is nil for a list that shows titles as written.
  FilingTitle reads a title as a library files it (MARC 21's nonfiling characters).
  And ArticleLanguage lists the articles of English and of ten other languages (MARC 21 Appendix F), finds the language a book's metadata names, and gives a book English's articles, or its language's with English's "the" alone.
  LibraryBookSorter.SortKeys reads each book's titleKey once, and LibraryBookSorter.titleOrder compares by it for the Title sort and for every tie broken by title, and by the titles as written when two keys are the same, so "Hobbit" and "The Hobbit" never tie.
  LibraryListCache keeps each title's inverted form (rowTitle(of:articles:), by the title and the book's language, at most invertedTitleLimit), and the rows letter navigation compares typed letters with (typedRows(of:)), each title folded once.
  LibraryViewModel.rowTitle(of:articles:), booksRotorEntries(of:articles:), and typedRows(of:) are its windows' ways to them.
- Who may write it: nobody while TextMouth runs: FilingTitle, ArticleLanguage, and the cache's records are made from the titles and the setting.
  The setting itself is written through SettingsViewModel (see [Preferences](preferences.md)).
- How others observe it: every sort and search takes the setting as a parameter (articles:), read by LibraryViewModel.leadingArticles from the preferences store each time it is asked, and the iPhone's is always LeadingArticles.partOfTitle.
  A list's titles are read with the articles of English and of the book's epubLanguage, a feed's with English's alone (a feed names no language), and a folder's name with none.
  A search finds a book by its title as written, its author, or, while the setting shows titles inverted, its title as the row shows it (LibraryViewModel.book(_:isFoundBy:shownTitle:)).
  The Reading List is never sorted; a folder's manual order breaks the tie of books it has not numbered by title, so ManualBookOrder.orderedBooks, which Move Book Up and Down, a drag, and Continue to Next Book all follow, takes the setting too.
  TitleFolding folds typed letters and titles for comparison (case, accents, width, and apostrophes), counting its folds (foldCount) for the test that a key folds no title; a title's forms are folded once, when its row is made (TypedForms), and a key folds only the letters typed.
  LibraryListCache.typedRows(of:) keeps the rows of the last list asked for while the list revision and the books' IDs and order are the same, so a key typed in a Library of thousands of titles scans rows made before.
  A new list revision, which a renamed book or a change of its language causes, drops them (typedRowBuildCount counts the books' rows made).
  The rows follow no setting, so changing it makes none again.

## Index-write suspension
<!-- id: index-write-suspension; keys: unreadable library.json, quarantine, recovery banner, Try Again, Rebuild Library Index, Recovery Options, damaged index; src: TextMouth/Services/LibraryPersistenceService.swift, TextMouth/Services/LibraryIndexQuarantine.swift, TextMouth/ViewModels/LibraryViewModel+IndexRecovery.swift, TextMouth/Views/Library/LibraryIndexRecoveryViews.swift -->

Index-write suspension: what protects an index that cannot be read.

- Owner: LibraryPersistenceService.
  The flag lives on its save queue, beside the waiting snapshot.
- Who may write it: load() suspends index writes when library.json exists but cannot be read, after LibraryIndexQuarantine has preserved its bytes as library.json.unreadable- followed by the date and time.
  Only resumeIndexWrites() (Try Again, once the index reads) and replaceUnreadableIndex(with:) (Rebuild Library Index, which first preserves whatever is there) end it.
  LibraryViewModel+IndexRecovery drives both.
  A library.json that names a format this build does not know cannot be read either, since BookFormat decodes by raw value.
  A build that predates rtf, rtfd, doc, odt, wordml, webarchive, or ssml and meets one in an index, or one that predates braille and meets it, fails to decode it, preserves it, and suspends writes as for any damage.
  Its repair adopts no package whose bookInfo.json names such a format (orphanedBook gives nil when BookInfo.load fails), so its Rebuild Library Index leaves those books out, with the folder rows and manual order that only the index held (the preserved copy keeps them).
  Its package record writes go on, as the service's own comment says, and drop the fields it does not know (editedText and pageReaderVersion among them), which a newer build reads back as an edit not recorded and a book not yet given pages.
  So for mobi (0.3.0), kfx (0.4.0), picture and comic (0.5.0): a build from 0.2.1 on keeps their rows and leaves them out of its lists, and an older one cannot decode them.
  The raw values are therefore never changed (see [Imports](imports-textutil.md)).
  A build with V03 keeps such a row as it was read, as it keeps any row it cannot decode, and the index stays readable (Rows this TextMouth cannot read, below).
- How others observe it: LibraryViewModel.indexRecovery is set while recovering, and the Library window shows the recovery banner and its Recovery Options….
  LibraryViewModel.beginIndexRecovery gives the provisional library the arrangement recoveredArrangement(session:unreadableIndex:) finds (FR09).
  Each LibraryIndexArrangement part, .readingList and .sortSettings, comes from the session when it holds one, as when the data directory came back with an unreadable index.
  Otherwise it comes from SalvagedLibraryArrangement.read(from:) over the preserved bytes, or over the unreadable file itself when no copy could be made, each part read on its own and the sort settings entry by entry.
  LibraryIndexRecovery.arrangementNotKept records what neither gave.
  The .rebuilt and .savedProvisionalLibrary outcomes carry it as notKept, and LibraryIndexArrangement.notReadSentence(in:) words it for them and for the recovery sheet's Rebuild choice (LibraryIndexRecoveryText.rebuild(savedCopy:notKept:)).
  A reading list ID that names no book is kept, and dropped at the list's next change, as ever.
  Snapshots taken meanwhile are dropped, never kept for later, and no feed's index is written either, since each is written with library.json (see [Feed items](library-index-reading-feeds.md)). areIndexWritesSuspended makes data-directory moves refuse.
  Package records are still written, so reading positions are not lost.

## Rows this TextMouth cannot read
<!-- id: rows-this-textmouth-cannot-read; keys: downgrade, forward compatibility, newer TextMouth, unknown book format, preserved rows, V03; src: TextMouth/Models/Library.swift, TextMouth/Models/JSONValue.swift, TextMouth/Models/LibraryFeedShelf.swift, TextMouth/Services/Feeds/FeedIndex.swift, TextMouth/Services/LibraryPersistenceService.swift, TextMouth/ViewModels/LibraryViewModel+IndexRecovery.swift, TextMouth/Services/FileImportService.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/Views/Settings/StorageSettingsView.swift -->

Rows this TextMouth cannot read: the books a later TextMouth wrote, kept as they are (V03).

- Owner: Library.unreadableRows, an array of UnreadableLibraryRow (Models/Library.swift).
  The JSON object of a row of library.json that does not decode as a Book, kept as a JSONValue (Models/JSONValue.swift, any JSON value, bounded in depth by JSONValue.maximumDepth), with its id, tmbDirectoryName, and folderPath when they read.
  Library decodes its books one at a time (UnreadableLibraryRow.decodeRows(from:)): an element that decodes is a book and any other is kept, each in the file's order; an element that cannot be read even as a JSONValue still makes the library unreadable.
  FeedShelf.unreadableRows keeps the same for each feed's index, by feed ID, since FeedIndex reads its rows the same way (a feed with kept rows keeps its index: indexedFeedIDs), and Library.unreadableRowCount counts both.
  A FolderSortSetting whose sort field this version does not know keeps the name (unknownSortField), reads as the default field, and writes the name back until a field is chosen.
  KeptRowPackages (Library.keptRowPackages) says which packages the kept rows own.
  By folderPath and tmbDirectoryName when both read, by tmbDirectoryName alone in any folder when only that reads, compared as the library compares folders on a volume that ignores case, and in precomposed form, so that it can only own more, never less.
- Who may write it: the decoding of Library and FeedIndex, once, when an index is read; nothing changes a kept row.
  Every save writes the kept rows back after the books, unchanged, and a library that replaces the one loaded carries them over; Rebuild Library Index writes them back too (LibraryViewModel+IndexRecovery).
  A library without any is encoded exactly as before.
  Every walk of the packages asks keptRowPackages and leaves an owned package alone.
  The walks are orphan adoption and the startup repair (FileImportService, libraryFolderPath(ofPackageAt:libraryDirectory:)), Rebuild Directory, and the scan of a feed's folder (FeedIndex's rowsFromPackages(of:in:excluding:keptRows:)).
  A part of the index that is not a list of books, or whose folders are in a layout this version cannot read, still makes the whole index unreadable (index-write suspension, above).
  The gaps, open in the TODO:
  - Delete Folder (removeFolderAndEverything) and Delete Feed (FeedCenter+DeleteFeed) still remove a kept row's package;
  - renaming or moving a folder leaves a kept row's folderPath and filePath stale, and a data-directory move does not rebase its filePath (StorageGeneration);
  - if library.json cannot be parsed at all, the kept rows are unknown, so orphan adoption could adopt their packages, as it could before V03.
- How others observe it: LibraryPersistenceService logs LIBRARY_ROWS_KEPT once when library.json is read with kept rows, naming none; LibraryViewModel.booksNeedingNewerTextMouth gives Storage settings its sentence (StorageLocationWording.booksNeedingNewerTextMouth(_:)).
  A kept row is never shown, counted as a book, opened, or searched.

## The on-disk contract
<!-- id: disk-contract; keys: raw values, compatibility, config.json, library row keys, older build, pinned, schema version; src: TextMouthProductionTests/OnDiskContractTests.swift, Scripts/test/areas.conf -->

The on-disk contract (V02): what 0.2.0 writes, pinned so that a change is a deliberate step.

- Owner: OnDiskContractTests (TextMouthProductionTests/OnDiskContractTests.swift, in the analysis area of Scripts/test/areas.conf).
  It compares each value against a literal, never against the code's own constant, so a rename fails even when every other test passes.
  It pins:
  - every BookFormat, SkipUnit, LibrarySortField, and LibraryCategory raw value;
  - the shortcut action names, with their former names;
  - the keys of config.json, of a fully populated library row and package record, and of the records of a user's places;
  - the file and folder names a package and the data directory keep;
  - and the versions that say how a file was written.

  Among the keys of the row and the record are textEncodingSource, the optional note of who decided a text book's encoding, which an older TextMouth drops, and brailleTableOrigin, the optional note of whether a braille book's table was guessed, in the row, the record, and the removal marker alike.
  The record alone has movedToLibrary ([Package records](package-records.md)).
  Each assertion's message says what a change forces: an older build's refusal, a re-read of the library, or a re-index.
  What other tests pin already, as the text cache format and the metadata reader's version, is not pinned again.

## Retirement markers
<!-- id: retirement-markers; keys: tombstone, retired package, orphan adoption, reinstate, braille table, text encoding; src: TextMouth/Models/RemovedFromLibraryMarker.swift, TextMouth/Models/LenientFields.swift, TextMouth/Services/LibraryPersistenceService.swift, TextMouth/Services/FileImportService.swift, TextMouth/Services/FileImportService+Packages.swift -->

Retirement markers: books removed with Remove from Library Only.

- Owner: the marker file in the package, removedFromLibrary.json (RemovedFromLibraryMarker), together with LibraryPersistenceService's set of retired packages on its metadata queue.
- Who may write it: LibraryPersistenceService.retirePackage(of:) writes the marker first.
  Only once it is on disk does it cancel the writes queued for the book, remember the package, and delete bookInfo.json, a courtesy to older versions of TextMouth. reinstatePackage(of:) deletes the marker when the package is deliberately taken back, by importing it again or adopting it.
  The marker also carries:
  - a braille book's table (RemovedFromLibraryMarker.brailleTable, nil for any other book and absent from a marker written before braille books),
  - and, for a Mac table, the version of this Mac's tables it was read with (RemovedFromLibraryMarker.brailleTableVersion),
  - and who chose the table (RemovedFromLibraryMarker.brailleTableOrigin, brfguess, an @LenientOptional that never makes the marker unreadable, nil and absent for every other book).

  A book added back is therefore still said to be guessed and is not guessed again.
  That is because the removal deletes bookInfo.json, which holds it, and a book rebuilt from the marker (FileImportService.reconstructedBook(inPackage:marker:folderPath:dateAdded:)) would otherwise be read again with the default table.
  It also carries a text book's guessed or chosen encoding (RemovedFromLibraryMarker.textEncoding, FMT16) and who decided it (textEncodingSource, an @LenientOptional, encodingchoice), nil for a book with none and absent from a marker written before them.
  FileImportService.reconstructedBook gives them back to a book of a format that reads text files, since the book would otherwise be read by the Windows-1252 fallback and its text would change.
  The marker keeps no source path, so a book added back from it has the Text Encoding pop-up only when the marker recorded an encoding or a decision (Book.offersTextEncodingChoice; Text files in other encodings, in [Imports](imports-text-encodings.md)).
- How others observe it:
  - every package record write checks the set and drops writes into a retired package;
  - orphan adoption skips a package whose marker names its record's book;
  - launch's repair and Rebuild Directory remove retired books from an index saved before their removal, through RemovedFromLibraryMarker.removeRetiredBooks(from:sparing:), which takes each out through Library.removeBook(id:), so it leaves the reading list too (FR09);
  - the repair spares, unread, a book whose marker is only in the cloud, which a read would download.

## Duplicate books
<!-- id: duplicate-books; keys: duplicate finder, Scan for Duplicates, pagination, VoiceOver announcement; src: TextMouth/Views/Settings/DuplicateFinderView.swift, TextMouth/Views/Settings/StorageSettingsView.swift, TextMouth/Models/CountWording.swift, TextMouth/Models/RemovalWording.swift, TextMouth/ViewModels/LibraryViewModel+Duplicates.swift, TextMouth/ViewModels/LibraryViewModel+BookOperations.swift, TextMouth/Services/VoiceOverAnnouncer.swift -->

Duplicate books: what Find Duplicate Books, in Storage settings, groups and removes.

- Owner: DuplicateFinderView's @State, for as long as the sheet is open:
  - the criteria checked (DuplicateFilter: md5Hash, isbn, title, and author; Identical File (MD5) is checked at each opening, and nothing persists the choice),
  - the groups the last scan found (DuplicateGroup),
  - the page of them shown (pageIndex),
  - the books checked for removal, on every page,
  - and the ISBNs read from EPUB records when Same ISBN is first scanned.

  The criteria combine: DuplicateFinderEngine.findDuplicates puts a book in a group only when every checked criterion has a value for it, and books share a group only when every value matches.
  So the former titleAndAuthor case is gone, and a book without an author is left out while author is checked.
  DuplicateGroup.matchDescription names the criteria with ListFormatter, and its matchKey gives the values shared, a title and author matched together as "Title by Author"; the two make one heading.
- Who may write it: the sheet's checkboxes and its Scan for Duplicates, which runs the engine over the library's own books, never a feed's items (LibraryViewModel.booksForDuplicateScan, FR11).
  DuplicateRemoval.firstStep(removing:preferences:) decides from RemovalPreferences whether DuplicateRemovalButton asks first, and DuplicateRemoval.remove(_:from:) deletes the checked books through LibraryViewModel.removeBooksAndDeleteReturningOutcome, to the Trash or not as the preference says.
- How others observe it: DuplicateFinderWording makes each row's label and the scan-result phrase (scanResult(groupCount:), through CountWording).
  The results carry the phrase as their accessibility label, and VoiceOverAnnouncer announces it after a scan the user asks for (runScan()), not after the rescan that follows a removal (runScan(afterRemoval: true)), whose outcome is announced instead.
  That rescan keeps the page now holding the group that headed the page shown (DuplicateGroupPages.page(keeping:of:orElse:)).
  The groups are shown a page at a time (DuplicateGroupPages, REV13): whole groups in the scan's order, listing at most rowsPerPage (40) books, or one larger group alone.
  While there is more than one page, DuplicateGroupPager shows DuplicateFinderWording.pageLine(groups:of:), with Previous Groups and Next Groups, which announce it as they turn the page.
  The list is made anew for each page, so it opens at its top.

## Quit and recovery saves
<!-- id: quit-recovery-saves; keys: quit, terminate, flush, shared library, iCloud, Rebuild Library Index, merge, save on exit; src: TextMouth/App/UnsavedChangesTermination.swift, TextMouth/Services/PlaybackMemoryGuard.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/Models/Library.swift, TextMouth/ViewModels/LibraryViewModel+FolderManagement.swift, TextMouth/ViewModels/LibraryViewModel+IndexRecovery.swift, TextMouth/Services/LibraryPersistenceService.swift, TextMouth/Services/FileImportService.swift, TextMouth/Services/LibraryLoadResult.swift -->

Quit and recovery saves: what is saved at a quit, and what a recovery keeps.

- Owner: UnsavedChangesTerminationGuard.flushPendingWrites (App/UnsavedChangesTermination.swift), which first calls PlaybackMemoryGuard.saveEveryOpenReaderPosition(), every open reader being reported to the guard as it opens, whether or not the guard watches memory.
  And the library's flush that follows writes those places with the rest.
  Each reader answers savePositionIfMoved() (ReaderViewModel), which keeps its last saved chapter and offset and writes only when the cursor moved or playback published a live place since.
  So a reader at rest dates nothing and writes no library index over a newer one saved by another Mac on a shared library.
  A reader without that knowledge saves as before (the protocol's default).
- Who may write it: Library is Equatable, its synthesized == comparing every stored field.
  And library(after:current:) and library(afterMoving:from:current:) take the library a folder edit or a data-directory move made off the main actor whole only when the library is unchanged since its snapshot.
  Otherwise they merge into the library as it is now, so a Reading List change, a feed shelf change, or a kept row made meanwhile is kept.
  LibraryViewModel.saveReadingCheckpoint journals the book while an unreadable index is protected, as with a readable one, and none is journaled while the data directory is unavailable.
  Rebuild Library Index decodes the index a load would read now, library.json or the legacy index, first, and when it decodes, writes and preserves nothing and fails with LibraryIndexRecoveryError.indexReadableAgain.
  FileImportService.adoptLibraryFolders(library:libraryDirectory:includingFoldersOnDisk:) makes rows for every folder books name.
  And with includingFoldersOnDisk false, as the startup repair of a library whose index records the folders asks, only for the folders books lie in and their ancestors, the disk unwalked.

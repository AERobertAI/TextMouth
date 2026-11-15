# Shared helpers: values, ordering, and wording
<!-- id: shared-helpers-values; keys: ; src: -->

Part of [TextMouth's architecture](../../ARCHITECTURE.md).

## AudioSegment and AudioClipChain
<!-- id: audiosegment-audioclipchain; keys: ; src: TextMouth/Models/AudioSegment.swift, TextMouth/Services/AudioPlaybackService.swift -->

AudioSegment and AudioClipChain (Models/AudioSegment.swift, Services/AudioPlaybackService.swift): a segmented chapter's clips, never an empty list, and the one conversion between a time in the chapter and a time in a clip's file.

## TimeLeftEstimate and WorkTiming
<!-- id: timeleftestimate-worktiming; keys: ; src: TextMouth/Models/TimeLeftEstimate.swift, TextMouth/Models/ImportProgressWording.swift -->

TimeLeftEstimate and WorkTiming (Models/TimeLeftEstimate.swift): what the finished items of a run took, each by its size where that tells its time, and the time the items still to come should take, rounded as it is said: the one estimate the import overlay and the feed downloads section share, worded by ImportProgressWording.timeLeft(_:).

## PlaceClock
<!-- id: placeclock; keys: ; src: TextMouth/Models/PlaceClock.swift -->

PlaceClock (Models/PlaceClock.swift): the clock that names a book's places by times, an audiobook's recording or a text book's words at its speed, and finds the place a time names (P08): Go to Time, the Headings sheet's Time In, and Copy Reading Position's place count on it (the reader, above).
PlaceClock.end is its last chapter at its full length, at the clock's length; span(from:to:) adds a span chapter by chapter, so whole chapters last exactly their durations, where subtracting two times carries the rounding of the running total before them (the Headings sheet's Durations).

## TimeEntry
<!-- id: timeentry; keys: ; src: TextMouth/Models/TimeEntry.swift, TextMouth/Views/Reader/ReaderJumpPanels.swift -->

TimeEntry (Models/TimeEntry.swift): reads a time typed or pasted into one field as people write it, "1:02:03", "62:03", "3723", or "12:04.3", for the audio editor's Go to Time and Insert Silence and the reader's Go to Time (JumpInputValidator.time(_:length:count:)); it moved from the audio editor, where it was AudioEditorTimeEntry, with P08.

## ProgressObserver
<!-- id: progressobserver; keys: ; src: TextMouth/Views/ContentView.swift, TextMouth/Views/Feeds/FeedDownloadProgressSection.swift -->

ProgressObserver (Views/ContentView.swift): a view that observes one progress object alone and draws what its caller makes of it, so the window around it, and the library model, are never redrawn for the progress; the text cache's overlay and Storage rows, the import overlay, and the feed downloads section (FeedDownloadProgressObserver, since the feed follow-ups after FR14) use it.

## FeedDownloadWait.networkWait
<!-- id: feeddownloadwait-networkwait; keys: ; src: TextMouth/Services/Feeds/FeedDownloadManager.swift -->

FeedDownloadWait.networkWait (Services/Feeds/FeedDownloadManager.swift): the one wording of a wait for a network, "downloads once this Mac is on a network without data limits", which an item's row says as its reason and a download refused on a network with data limits says as its message (FR14, REV13 item 4).

## Book.hasOwnSettings
<!-- id: book-hasownsettings; keys: ; src: TextMouth/Services/Feeds/FeedItemPackage.swift, TextMouth/Views/Feeds/FeedWording.swift, TextMouth/Views/Feeds/FeedCommands.swift -->

Book.hasOwnSettings (Models/Book+OwnSettings.swift): whether a book keeps a setting of its own, a voice, speed, or pitch, skipped headings, its end-of-book choice, or a skip unit, the one rule by which a feed item's package is kept once its file goes (FeedItemPackage.holdsListenerState) and by which Delete Download and the library's Remove name its "own settings" (FeedWording.KeptParts).

## CountWording
<!-- id: countwording; keys: ; src: Scripts/test/kf8-fuzz/Stubs.swift, TextMouth/Models/CountWording.swift, TextMouth/Models/DocumentContent.swift, TextMouth/Views/ContentView.swift, TextMouth/Models/ImportProgressWording.swift -->

CountWording (Models/CountWording.swift): a count with the right singular or plural word, so the screen and VoiceOver say the same thing (hours(_:), minutes(_:), and seconds(_:), as in "1 minute", which TimeFormatting.spoken's durations use too, and part(_:of:singular:plural:), as in "0 of 1 book", the noun agreeing with the whole), a time kept in tenths of a second (secondsToTheTenth(_:), "0.5 seconds" or "2 seconds", for the gesture time window and the double-press time), how far a batch has got, as in "3 of 10 books processed" and "0 of 1 book processed" (part(_:of:_:), with the CountWording.Noun a progress overlay counts by, ProgressOverlay.itemNoun: ImportProgressWording.itemNoun and TextExtractionProgress.itemNoun, REV13), and the library's books with its feeds beside them, as in "743 books, 2 feeds" (booksAndFeeds(books:feeds:), FR11), which every count of the library's books uses; where episodes and articles are listed beside books, as in Recently Opened and the Reading List, each kind is counted apart, "9 books, 1 article" (listItems(books:episodes:articles:feeds:) and listItems(of:feeds:), of which booksAndFeeds is the case without feed items), and a section is headed the same way, "Books (9), Articles (1)" (booksHeader(of:)).
CountWording.list(_:) is the one "a, b, and c" joiner, which the cloud, removal, feed, shortcut, and filter wording use.

## ManualBookOrder and LibraryBookSorter
<!-- id: manualbookorder-librarybooksorter; keys: ; src: TextMouth/Models/LibraryBookSorter.swift, TextMouth/ViewModels/LibraryViewModel+SortAndOrder.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/Models/ReadingList.swift, TextMouth/Models/LibrarySortState.swift -->

ManualBookOrder and LibraryBookSorter (ViewModels/LibraryViewModel+SortAndOrder.swift, Models/LibraryBookSorter.swift): the library's orderings.
Manual order (by position, then title, then book ID) is the one order a folder's list, Move Book Up and Down, dragging, and Continue to Next Book all follow; the reading list keeps an order of its own (ReadingList), which Move Book Up and Down and dragging rearrange at the Reading List through the same LibraryReorderTarget.

## Stable sort helpers
<!-- id: stable-sort-helpers; keys: ; src: TextMouth/Models/StableSort.swift, TextMouth/Models/LibraryBookSorter.swift, TextMouth/Services/Feeds/FeedIndex.swift, TextMouth/Models/LibrarySortState.swift -->

sortedStably, sortStably (Models/StableSort.swift, audit C10, merged as perf/sort-helper): the one copy of the standard library's sort for the app's small and occasional sorts.
Use them in place of sorted(by:), sorted(), sort(by:), and sort(): there are four, `sortedStably(by:)` and `sortedStably()` on a Sequence (the second where Element is Comparable) and `sortStably(by:)` and `sortStably()` on a MutableCollection that is a RandomAccessCollection (the second where Element is Comparable); the parsers, services, models, view models, and views all use them.

- What each does: it calls the standard library's own sort, so the order is the standard library's, equal elements included.
- Why it is stable: Swift's sort is a stable merge sort in every current release, so equal elements keep their order, and the helpers' comments promise it; replacing a call with a helper changes no order.
- Why it is not specialized: each `sorted { … }` the compiler specializes copies the standard library's merge sort (`_stableSortImpl`, `_merge`, `_mergeTopRuns`, `_insertionSort`) for that closure and element type, 87 copies in all, and the helper keeps every call to one: each function is `@inline(never)` and carries `@_semantics("optimize.sil.specialize.generic.never")`, which stops the compiler cloning its body for each caller.
  That made the executable 378 KB smaller.
  What it costs is that a comparison goes through the closure's generic entry, which is slower for each comparison.
- Which sorts keep the standard library's: a sort on a hot path or of a whole list.
  LibraryBookSorter's sorts of the whole library (`sorted(_:by:ascending:fileSizes:articles:)` and `latestOpened`, which sort the positions of rows in keys read once) keep it, and so does FeedIndexFiles.encoded, which sorts every row of a feed's index (`ordered.books.sort(by: isInIndexOrder)`) at each library save; the performance baselines time the first, and FeedIndexFiles.encoded says in a comment why it keeps the standard sort.
  Write the helper for a new sort unless it is such a sort.

## ListNeighbors
<!-- id: listneighbors; keys: ; src: TextMouth/Models/ListNeighbors.swift -->

ListNeighbors (Models/ListNeighbors.swift): the one search for the element beside another in an ordered list, going down or up, which the reading list, a plain folder's books, and a feed's items all use to find what follows a finished book (FR19).

## EndOfBookRule
<!-- id: endofbookrule; keys: ; src: TextMouth/Models/EndOfBookRule.swift -->

EndOfBookRule (Models/EndOfBookRule.swift): the one place the order of the settings that decide what a book does at its end is written, and what that gives: the behavior, the direction, and the two options that go with it.
The reader's behavior and the settings sheet's picker come from it (see [The reader](state/reader.md)).

## Wording types for sentences
<!-- id: wording-types-sentences; keys: ; src: TextMouth/Models/RemovalWording.swift, TextMouth/Models/EndOfBookWording.swift, TextMouth/Models/ImportProgressWording.swift, TextMouth/Models/SpeechRefusalReport.swift, TextMouth/Models/OperationOutcome.swift -->

RemovalWording, FeedDownloadRemovalWording, OperationOutcome, ReadingStatsTileWording, ImportDecisionWording, BookExportWording, BookTextEditWording, TranscriptionWording, TranscriptCleanupWording, AudioEditWording, ReadingListWording, ReadingListReaderWording, EndOfBookWording, ListeningOptionsWording, FolderSettingsWording, AddToLibraryWording, ReaderTimeWording, ImportProgressWording, FeedDownloadProgressWording, and SpeechRefusalWording (Models/, FeedDownloadRemovalWording in RemovalWording.swift and the last in SpeechRefusalReport.swift): the wording of removals, the Remove of a feed's downloads, operation results, statistics, import questions, Export, Edit Text, transcription, the transcript cleanup, audio edits, the reading list, a book read from it, the listening options' controls, which Feed Info and Folder Settings share, the Folder Settings sheet, the Add to Library button and sheet, the end of a book, with the one word, "Finished" (EndOfBookWording.finishedProgress, P07), that the library row, Speak Info, Where Am I?, and Copy Reading Position say of a book resting at its end, while the reader's status row keeps its percent and time, the reader's times (its jump fields' labels, refusals, and announcements, the copied place, and the speed named beside time left and total), an import's progress, the feed downloads' progress, which says its sizes, its time left, and its lines to VoiceOver as an import's progress does (ImportProgressWording.spokenStatus(title:lines:)), and the report of a speech refusal, each built once for both the screen and VoiceOver.

## LibraryInfoWording
<!-- id: libraryinfowording; keys: ; src: TextMouth/Models/LibraryInfoWording.swift, TextMouth/Views/Feeds/FeedWording.swift, TextMouthProductionTests/LibraryInfoWordingTests.swift, Scripts/test/kf8-fuzz/Stubs.swift, TextMouth/Models/CountWording.swift -->

LibraryInfoWording (Models/LibraryInfoWording.swift): every sentence Speak Info says of a book, a folder, or a feed, brief or full, made from facts alone (BookInfoFacts, FolderInfoFacts, and FeedInfoFacts) and pinned by LibraryInfoWordingTests without a window: counts through CountWording, times through TimeFormatting, dates through FeedWording.moment, and a feed's counts through its row's own phrase, FeedWording.countsPhrase.

## TextEncodingWording
<!-- id: textencodingwording; keys: ; src: TextMouth/Models/LibraryInfoWording.swift, TextMouth/Parsers/TextFileDecoder.swift, TextMouthProductionTests/TextEncodingChoiceTests.swift -->

TextEncodingWording (Models/LibraryInfoWording.swift, beside LibraryInfoWording): every word of a text book's encoding, made once for the decoder, Speak Info, and Book Information's pop-up (encodingchoice): the label "Text Encoding", the notes that say what decided an encoding (describe(name:basis:): guessed, chosen, from its byte order mark, recognized by its bytes, declared in the file, the default), the pop-up's hint and values, the confirmation's title and message, the announcement when a book is read again, and the refusals, among them notValid(in:subject:), which the decoder's error (TextEncodingError.invalidForChosenEncoding) and Book Information's refusal both say, and readingAgainRefusal(bookTitle:), which every entry point that waits for a re-read says.
TextEncodingChoiceTests pins the words.

## Text TextMouth did not write
<!-- id: text-textmouth-did-not-write; keys: ; src: TextMouth/Services/DuplicateReplacement.swift, TextMouth/Services/TranscriptInstallation.swift, TextMouth/Models/BookTextEditWording.swift -->

DuplicateReplacement.holdsUnwrittenText(_:of:hasher:) (Services/DuplicateReplacement.swift), BookTextEditWording.earlierTextKept(_:), and PackageFileBeforeInstall (Services/TranscriptInstallation.swift): the rule for text TextMouth did not write, which is kept beside the text that replaces it (by Replace Existing and by a re-read in another encoding), the sentence that says where it was kept, "Its earlier text was kept as content.md.edited-…, in the book's package.", and the helper that puts back a file a failed step replaced, its bytes and its dates (a transcript's install and a re-read).

## Cloud, recording, editor, and settings wording
<!-- id: cloud-recording-editor-settings-wording; keys: ; src: TextMouth/Models/LibraryCloudWording.swift, TextMouth/Views/Library/DataDirectoryUnavailableView.swift, TextMouth/Views/Recording/RecordingWording.swift, TextMouth/Views/AudioEditor/AudioEditorWording.swift, TextMouth/Views/Reader/ReaderView.swift -->

LibraryCloudWording (Models/LibraryCloudWording.swift), ReaderCloudWording (ViewModels/ReaderViewModel+CloudDownload.swift), DataDirectoryUnavailableText (Views/Library/DataDirectoryUnavailableView.swift), RecordingWording (Views/Recording/RecordingWording.swift), AudioEditorWording (Views/AudioEditor/AudioEditorWording.swift), and BookSettingsWording (Views/Reader/ReaderView.swift): the wording of the list's cloud commands, of the refusal of books only in the cloud by operations that never download (LibraryCloudWording.downloadFirst(count:) and notDownloaded(titles:), which a move of the library, Export, and Edit Text share), of a reader's download, the Library Not Available screen, the Record window, the audio editor window, and a book's own settings, their sheet, toolbar button, and the saving and resetting of its voice, speed, and pitch, which the playback bar and the sheet share, each built once for both the screen and VoiceOver.

## FeedWording
<!-- id: feedwording; keys: ; src: TextMouth/Views/Feeds/FeedWording.swift -->

FeedWording (Views/Feeds/FeedWording.swift and the files beside it): every word of the feed reader's interface, its rows, sheets, commands, notifications, and announcements, each label made by a function so the hosted tests can pin it.

## FeedItemPackage.removeWhole
<!-- id: feeditempackage-removewhole; keys: ; src: TextMouth/Services/Feeds/FeedItemPackage.swift -->

FeedItemPackage.removeWhole(_:in:remove:) (Services/Feeds/FeedItemPackage.swift): the one whole-package removal; a package already gone counts as removed.

## Unopened books and a folder's tree
<!-- id: unopened-books-folder-tree; keys: ; src: -->

Book.isUnopened (Models/Book.swift) and Library.booksInFolderTree(_:) (Models/Library.swift) are the one definition of "never opened" and of "a folder's tree of books" (the library's own books in the folder and below it, never a feed's items): Book.isUnopened is read by the Unopened category, a row's New badge, Speak Info, a feed item's New and its kept package's test, and the recently opened sort; booksInFolderTree by a folder's emptiness test (hasBooks(inFolderTree:), which stops at the first book), its book counts, and its Speak Info.
Delete Folder… lists the books it removes with booksInFolderTree, and Library.removeFolderAndContents(id:) removes the same books, so a feed's item that names a folder is neither deleted nor dropped; Library.isPath(_:inTreeAt:) is the one "is this path the folder or below it" rule, by whole path components, which the folders, their sort settings, and the books all follow.

## Array subscript(safe:) in tests
<!-- id: array-subscript-safe-tests; keys: ; src: -->

Array's subscript(safe:) (TextMouthProductionTests/CollectionTestSupport.swift) is the tests' one way to read an element they have not proven is there, so a break in the code under test fails an assertion rather than trapping the test host.

## Audio manifest location and reading
<!-- id: audio-manifest-location-reading; keys: ; src: TextMouth/Parsers/AudioManifest.swift -->

AudioManifestLocation and AudioManifest.read(inAudioFolder:) (Parsers/AudioManifest.swift): where an audiobook's manifest lies, at the top of its audio folder or inside its one folder, and how its names are spelled from there.

## AudioTrackPlan
<!-- id: audiotrackplan; keys: ; src: TextMouth/Parsers/AudioManifest.swift, TextMouth/Models/ChapterPauses.swift -->

AudioTrackPlan (Parsers/AudioManifest.swift): the one arrangement of a multi-file audiobook's tracks, their order, titles, group headings and levels, and the pause after each, used by the parser and by ChapterPauses.

## ChapterPauses
<!-- id: chapterpauses; keys: ; src: TextMouth/Models/ChapterPauses.swift, TextMouth/Services/BookManifestEditing.swift -->

ChapterPauses (Models/ChapterPauses.swift): the reader's one source of pauses between chapters.
Two values are equal when they give the same pause after every chapter, whatever list made them: init(afterEachChapter:) drops trailing entries of no pause, so ChapterPauses.none equals every list of zeros, such as the one a manifest with no pause gives.
The manifest TextMouth writes for a book that had none (pauseBetweenTracksMs 0) is therefore no edit when BookManifestEditSessions.manifest(_:at:arranges:as:tracks:showingPauses:owed:) compares its pauses with an open reader's.

## Heading announcement
<!-- id: heading-announcement; keys: ; src: Scripts/test/kf8-fuzz/Stubs.swift, TextMouth/ViewModels/ReaderViewModel.swift -->

ReaderViewModel.headingAnnouncement(arrivingAt:in:): what a heading jump says, every heading at the place it reaches, the outermost first.

## PackageFileEditing
<!-- id: packagefileediting; keys: ; src: TextMouth/Platform/iOS/Services/PackageFileEditing+iOS.swift, TextMouth/Platform/macOS/Services/PackageFileEditing.swift -->

PackageFileEditing (Platform/macOS/Services/PackageFileEditing.swift) holds what Edit Text and Edit Manifest share: the first-use explanation, worded for each kind, the app chooser, the workspace opener, the watcher of a file in a book's package, TextMouth becoming active, and the announcements kept until it does.

## ObjCException.catching
<!-- id: objcexception-catching; keys: ; src: TextMouth/Services/ObjCException.swift -->

ObjCException.catching(_:) (Services/ObjCException.swift) runs a framework call that may raise an Objective-C exception and returns it, so a raise cannot end the app.
It wraps the ObjCExceptionCatcher static library in Vendor/, built as LAME is, with a module map; it is the only Swift file that imports it (B08).

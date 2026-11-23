# Shared helpers: values, ordering, and wording
<!-- id: shared-helpers-values; keys: numbers, wording, ordering, time, strings, sorting; src: -->

Part of [TextMouth's architecture](../../ARCHITECTURE.md).

## AudioSegment and AudioClipChain
<!-- id: audiosegment-audioclipchain; keys: chapter time, file time, split audio, offset; src: TextMouth/Models/AudioSegment.swift, TextMouth/Services/AudioPlaybackService.swift -->

AudioSegment and AudioClipChain (Models/AudioSegment.swift, Services/AudioPlaybackService.swift): a segmented chapter's clips, never an empty list, and the one conversion between a time in the chapter and a time in a clip's file.

## TimeLeftEstimate and WorkTiming
<!-- id: timeleftestimate-worktiming; keys: ETA, time remaining, rounding; src: TextMouth/Models/TimeLeftEstimate.swift, TextMouth/Models/ImportProgressWording.swift -->

TimeLeftEstimate and WorkTiming (Models/TimeLeftEstimate.swift): what the finished items of a run took, each by its size where that tells its time, and the time the items still to come should take, rounded as it is said.
It is the one estimate the import overlay and the feed downloads section share, worded by ImportProgressWording.timeLeft(_:).

## PlaceClock
<!-- id: placeclock; keys: timestamp, position to time, words per minute; src: TextMouth/Models/PlaceClock.swift -->

PlaceClock (Models/PlaceClock.swift): the clock that names a book's places by times, an audiobook's recording or a text book's words at its speed, and finds the place a time names (P08).
Go to Time, the Headings sheet's Time In, and Copy Reading Position's place count on it (see [The reader](state/reader.md)).
PlaceClock.end is its last chapter at its full length, at the clock's length; span(from:to:) adds a span chapter by chapter, so whole chapters last exactly their durations, where subtracting two times carries the rounding of the running total before them (the Headings sheet's Durations).

## TimeEntry
<!-- id: timeentry; keys: parse time, hh:mm:ss, time field, text input, seconds; src: TextMouth/Models/TimeEntry.swift, TextMouth/Views/Reader/ReaderJumpPanels.swift -->

TimeEntry (Models/TimeEntry.swift): reads a time typed or pasted into one field as people write it, "1:02:03", "62:03", "3723", or "12:04.3", for the audio editor's Go to Time and Insert Silence and the reader's Go to Time (JumpInputValidator.time(_:length:count:)).

## ProgressObserver
<!-- id: progressobserver; keys: progress bar, ObservableObject, SwiftUI, observation; src: TextMouth/Views/ContentView.swift, TextMouth/Views/Feeds/FeedDownloadProgressSection.swift -->

ProgressObserver (Views/ContentView.swift): a view that observes one progress object alone and draws what its caller makes of it, so the window around it, and the library model, are never redrawn for the progress.
The text cache's overlay and Storage rows, the import overlay, and the feed downloads section (FeedDownloadProgressObserver) use it.

## FeedDownloadWait.networkWait
<!-- id: feeddownloadwait-networkwait; keys: cellular, low data mode, constrained network, waiting, download reason; src: TextMouth/Services/Feeds/FeedDownloadManager.swift -->

FeedDownloadWait.networkWait (Services/Feeds/FeedDownloadManager.swift): the one wording of a wait for a network, "downloads once this Mac is on a network without data limits".
An item's row says it as its reason, and a download refused on a network with data limits says it as its message (FR14, REV13 item 4).

## Book.hasOwnSettings
<!-- id: book-hasownsettings; keys: per-book settings, kept package, listener state, overrides; src: TextMouth/Services/Feeds/FeedItemPackage.swift, TextMouth/Views/Feeds/FeedWording.swift, TextMouth/Views/Feeds/FeedCommands.swift, TextMouth/Models/Book+OwnSettings.swift -->

Book.hasOwnSettings (Models/Book+OwnSettings.swift): whether a book keeps a setting of its own, a voice, speed, or pitch, skipped headings, its end-of-book choice, or a skip unit.
It is the one rule by which a feed item's package is kept once its file goes (FeedItemPackage.holdsListenerState) and by which Delete Download and the library's Remove name its "own settings" (FeedWording.KeptParts).

## CountWording
<!-- id: countwording; keys: pluralization, count text, grammatical number, plural forms, localized list, FR34, TL14; status: incomplete; issues: FR34, TL14; src: TextMouth/Models/CountWording.swift, TextMouth/Models/DocumentContent.swift, TextMouth/Views/ContentView.swift, TextMouth/Models/ImportProgressWording.swift, TextMouth/ViewModels/TextExtractionProgress.swift -->

CountWording (Models/CountWording.swift): a count with the right singular or plural word, so the screen and VoiceOver say the same thing:
- hours(_:), minutes(_:), and seconds(_:), as in "1 minute", which TimeFormatting.spoken's durations use too, and part(_:of:singular:plural:), as in "0 of 1 book", the noun agreeing with the whole;
- a time kept in tenths of a second (secondsToTheTenth(_:), "0.5 seconds" or "2 seconds", for the gesture time window and the double-press time);
- how far a batch has got, as in "3 of 10 books processed" and "0 of 1 book processed" (part(_:of:_:), with the CountWording.Noun a progress overlay counts by, ProgressOverlay.itemNoun: ImportProgressWording.itemNoun and TextExtractionProgress.itemNoun, REV13);
- and the library's books with its feeds beside them, as in "743 books, 2 feeds" (booksAndFeeds(books:feeds:), FR11), which every count of the library's books uses.

Where episodes and articles are listed beside books, as in Recently Opened and the Reading List, each kind is counted apart, "9 books, 1 article" (listItems(books:episodes:articles:feeds:) and listItems(of:feeds:), of which booksAndFeeds is the case without feed items).
A section is headed the same way, "Books (9), Articles (1)" (booksHeader(of:)).
CountWording.list(_:) is the one "a, b, and c" joiner, which the cloud, removal, feed, shortcut, and filter wording use.
The named counts are localized plural strings: books, feeds, bookmarks, hours, minutes, seconds, episodes, and articles.
Each is one `InterfaceText.line` call with a number interpolation, and has its English `one` and `other` forms in the catalog (written with `l10n.py plural`), so each language counts by its own rules.
The number is written for the region, so 1,000 books has its separator.
A list of two reads "A and B", and a count of one reads "1 item", since every counted string has a `one` form.
list(_:), listItems, and booksAndFeeds join through the interface locale's list style (`.list(type: .and)`), so the English follows the region too.
In en_US that is "A, B, and C", and in en_GB "A, B and C".
booksHeader and the decimal of secondsToTheTenth are localized strings of their own.
phrase(_:singular:plural:) and part(_:of:singular:plural:) are still English, which is the limitation.
A caller that uses them has a sentence that is not whole, and the code marks them as not localized.
part needs a plural that agrees with a second number, which `l10n.py plural` does not write yet (TL14).
How a count becomes a plural line is in [Localizing TextMouth's code](../developer/localization.md#plural-lines).

## ManualBookOrder and LibraryBookSorter
<!-- id: manualbookorder-librarybooksorter; keys: drag reorder, library sort, tie-break; src: TextMouth/Models/LibraryBookSorter.swift, TextMouth/ViewModels/LibraryViewModel+SortAndOrder.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/Models/ReadingList.swift, TextMouth/Models/LibrarySortState.swift -->

ManualBookOrder and LibraryBookSorter (ViewModels/LibraryViewModel+SortAndOrder.swift, Models/LibraryBookSorter.swift): the library's orderings.
Manual order (by position, then title, then book ID) is the one order a folder's list, Move Book Up and Down, dragging, and Continue to Next Book all follow.
The reading list keeps an order of its own (ReadingList), which Move Book Up and Down and dragging rearrange at the Reading List through the same LibraryReorderTarget.

## Stable sort helpers
<!-- id: stable-sort-helpers; keys: stable sort, code size, generic specialization, binary size; src: TextMouth/Models/StableSort.swift, TextMouth/Models/LibraryBookSorter.swift, TextMouth/Services/Feeds/FeedIndex.swift, TextMouth/Models/LibrarySortState.swift -->

sortedStably, sortStably (Models/StableSort.swift, audit C10, merged as perf/sort-helper): the one copy of the standard library's sort for the app's small and occasional sorts.
Use them in place of sorted(by:), sorted(), sort(by:), and sort().
There are four: `sortedStably(by:)` and `sortedStably()` on a Sequence (the second where Element is Comparable), and `sortStably(by:)` and `sortStably()` on a MutableCollection that is a RandomAccessCollection (the second where Element is Comparable).
The parsers, services, models, view models, and views all use them.

- What each does: it calls the standard library's own sort, so the order is the standard library's, equal elements included.
- Why it is stable: Swift's sort is a stable merge sort in every current release, so equal elements keep their order, and the helpers' comments promise it; replacing a call with a helper changes no order.
- Why it is not specialized: each `sorted { … }` the compiler specializes copies the standard library's merge sort (`_stableSortImpl`, `_merge`, `_mergeTopRuns`, `_insertionSort`) for that closure and element type, 87 copies in all.
  The helper keeps every call to one: each function is `@inline(never)` and carries `@_semantics("optimize.sil.specialize.generic.never")`, which stops the compiler cloning its body for each caller.
  That made the executable 378 KB smaller.
  What it costs is that a comparison goes through the closure's generic entry, which is slower for each comparison.
- Which sorts keep the standard library's: a sort on a hot path or of a whole list.
  LibraryBookSorter's sorts of the whole library (`sorted(_:by:ascending:fileSizes:articles:)` and `latestOpened`, which sort the positions of rows in keys read once) keep it.
  So does FeedIndexFiles.encoded, which sorts every row of a feed's index (`ordered.books.sort(by: isInIndexOrder)`) at each library save.
  The performance baselines time the first, and FeedIndexFiles.encoded says in a comment why it keeps the standard sort.
  Write the helper for a new sort unless it is such a sort.

## ListNeighbors
<!-- id: listneighbors; keys: next book, previous book, following element; src: TextMouth/Models/ListNeighbors.swift -->

ListNeighbors (Models/ListNeighbors.swift): the one search for the element beside another in an ordered list, going down or up, which the reading list, a plain folder's books, and a feed's items all use to find what follows a finished book (FR19).

## EndOfBookRule
<!-- id: endofbookrule; keys: end of book, after book, what happens at end, stop, behavior order; src: TextMouth/Models/EndOfBookRule.swift -->

EndOfBookRule (Models/EndOfBookRule.swift): the one place the order of the settings that decide what a book does at its end is written, and what that gives: the behavior, the direction, and the two options that go with it.
The reader's behavior and the settings sheet's picker come from it (see [The reader's moves between books, and search](state/reader-navigation.md)).

## Wording types for sentences
<!-- id: wording-types-sentences; keys: UI strings, localization, SentenceWording, PhoneAppWording, messages, user-facing text, tested wording; src: TextMouth/Models/RemovalWording.swift, TextMouth/Models/EndOfBookWording.swift, TextMouth/Models/ImportProgressWording.swift, TextMouth/Models/SpeechRefusalReport.swift, TextMouth/Models/OperationOutcome.swift, TextMouth/Models/ImportDecision.swift, TextMouth/Models/ReadingStatsTile.swift, TextMouth/Models/BookExportWording.swift, TextMouth/Models/BookTextEditWording.swift, TextMouth/Models/TranscriptionWording.swift, TextMouth/Models/TranscriptCleanupWording.swift, TextMouth/Models/AudioEditWording.swift, TextMouth/Models/ReadingListWording.swift, TextMouth/Models/ReadingListReaderWording.swift, TextMouth/Models/ListeningOptionsWording.swift, TextMouth/Models/FolderSettingsWording.swift, TextMouth/Models/AddToLibraryWording.swift, TextMouth/Models/ReaderTimeWording.swift, TextMouth/Models/FeedDownloadProgressWording.swift, TextMouth/Models/SentenceWording.swift, TextMouth/Phone/PhoneAppWording.swift -->

The wording of each of these is built once for both the screen and VoiceOver, by a type in Models/ (FeedDownloadRemovalWording is in RemovalWording.swift, and SpeechRefusalWording in SpeechRefusalReport.swift):
- RemovalWording: removals;
- FeedDownloadRemovalWording: the Remove of a feed's downloads;
- OperationOutcome: operation results;
- ReadingStatsTileWording: statistics;
- ImportDecisionWording: import questions;
- BookExportWording: Export;
- BookTextEditWording: Edit Text;
- TranscriptionWording: transcription;
- TranscriptCleanupWording: the transcript cleanup;
- AudioEditWording: audio edits;
- ReadingListWording: the reading list;
- ReadingListReaderWording: a book read from it;
- ListeningOptionsWording: the listening options' controls, which Feed Info and Folder Settings share;
- FolderSettingsWording: the Folder Settings sheet;
- AddToLibraryWording: the Add to Library button and sheet;
- EndOfBookWording: the end of a book, with the one word, "Finished" (EndOfBookWording.finishedProgress, P07), that the library row, Speak Info, Where Am I?, and Copy Reading Position say of a book resting at its end, while the reader's status row keeps its percent and time;
- ReaderTimeWording: the reader's times (its jump fields' labels, refusals, and announcements, the copied place, and the speed named beside time left and total);
- ImportProgressWording: an import's progress;
- FeedDownloadProgressWording: the feed downloads' progress, which says its sizes, its time left, and its lines to VoiceOver as an import's progress does (ImportProgressWording.spokenStatus(title:lines:));
- SpeechRefusalWording: the report of a speech refusal;
- SentenceWording: `joined(_:)`, the one way to put whole sentences, each ended with its own full stop, into a longer text;
  an empty list is "", one sentence is returned as it is, and each pair is joined by a localized pattern (a space in English), so Japanese and Chinese can join with none;
- PhoneAppWording (Phone/PhoneAppWording.swift): the iPhone's shared words (the alert's title and button, Cancel, Close, Save, OK, Play, and the like), each a line whose ID begins with common (common.cancel, common.ok), so one translation serves both apps.

## LibraryInfoWording
<!-- id: libraryinfowording; keys: info sentence, full info, folder info, feed info; src: TextMouth/Models/LibraryInfoWording.swift, TextMouth/Views/Feeds/FeedWording.swift, TextMouthProductionTests/LibraryInfoWordingTests.swift, TextMouth/Models/CountWording.swift -->

LibraryInfoWording (Models/LibraryInfoWording.swift): every sentence Speak Info says of a book, a folder, or a feed, brief or full, made from facts alone (BookInfoFacts, FolderInfoFacts, and FeedInfoFacts) and pinned by LibraryInfoWordingTests without a window.
It words counts through CountWording, times through TimeFormatting, dates through FeedWording.moment, and a feed's counts through its row's own phrase, FeedWording.countsPhrase.

## TextEncodingWording
<!-- id: textencodingwording; keys: charset, Text Encoding pop-up, Latin-1, code page; src: TextMouth/Models/LibraryInfoWording.swift, TextMouth/Parsers/TextFileDecoder.swift, TextMouthProductionTests/TextEncodingChoiceTests.swift -->

TextEncodingWording (Models/LibraryInfoWording.swift, beside LibraryInfoWording): every word of a text book's encoding, made once for the decoder, Speak Info, and Book Information's pop-up (encodingchoice):
- the label "Text Encoding";
- the notes that say what decided an encoding (describe(name:basis:): guessed, chosen, from its byte order mark, recognized by its bytes, declared in the file, the default);
- the pop-up's hint and values;
- the confirmation's title and message;
- the announcement when a book is read again;
- and the refusals, among them notValid(in:subject:), which the decoder's error (TextEncodingError.invalidForChosenEncoding) and Book Information's refusal both say, and readingAgainRefusal(bookTitle:), which every entry point that waits for a re-read says.

TextEncodingChoiceTests pins the words.

## Text TextMouth did not write
<!-- id: text-textmouth-did-not-write; keys: kept copy, edited by user, backup; src: TextMouth/Services/DuplicateReplacement.swift, TextMouth/Services/TranscriptInstallation.swift, TextMouth/Models/BookTextEditWording.swift -->

- DuplicateReplacement.holdsUnwrittenText(_:of:hasher:) (Services/DuplicateReplacement.swift): the rule for text TextMouth did not write, which is kept beside the text that replaces it (by Replace Existing and by a re-read in another encoding);
- BookTextEditWording.earlierTextKept(_:): the sentence that says where it was kept, "Its earlier text was kept as content.md.edited-…, in the book's package.";
- and PackageFileBeforeInstall (Services/TranscriptInstallation.swift): the helper that puts back a file a failed step replaced, its bytes and its dates (a transcript's install and a re-read).

## Cloud, recording, editor, and settings wording
<!-- id: cloud-recording-editor-settings-wording; keys: iCloud message, download wording, recording sheet, audio editor strings, book settings strings; src: TextMouth/Models/LibraryCloudWording.swift, TextMouth/Views/Library/DataDirectoryUnavailableView.swift, TextMouth/Views/Recording/RecordingWording.swift, TextMouth/Views/AudioEditor/AudioEditorWording.swift, TextMouth/Views/Reader/ReaderView.swift, TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift -->

The wording of each of these is built once for both the screen and VoiceOver:
- LibraryCloudWording (Models/LibraryCloudWording.swift): the list's cloud commands, and the refusal of books only in the cloud by operations that never download (LibraryCloudWording.downloadFirst(count:) and notDownloaded(titles:), which a move of the library, Export, and Edit Text share);
- ReaderCloudWording (ViewModels/ReaderViewModel+CloudDownload.swift): a reader's download;
- DataDirectoryUnavailableText (Views/Library/DataDirectoryUnavailableView.swift): the Library Not Available screen;
- RecordingWording (Views/Recording/RecordingWording.swift): the Record window;
- AudioEditorWording (Views/AudioEditor/AudioEditorWording.swift): the audio editor window;
- BookSettingsWording (Views/Reader/ReaderView.swift): a book's own settings, their sheet, toolbar button, and the saving and resetting of its voice, speed, and pitch, which the playback bar and the sheet share.

## FeedWording
<!-- id: feedwording; keys: RSS strings, podcast, feed interface, labels; src: TextMouth/Views/Feeds/FeedWording.swift -->

FeedWording (Views/Feeds/FeedWording.swift and the files beside it): every word of the feed reader's interface, its rows, sheets, commands, notifications, and announcements, each label made by a function so the hosted tests can pin it.

## FeedItemPackage.removeWhole
<!-- id: feeditempackage-removewhole; keys: delete package, remove folder, idempotent removal, feed item delete; src: TextMouth/Services/Feeds/FeedItemPackage.swift -->

FeedItemPackage.removeWhole(_:in:remove:) (Services/Feeds/FeedItemPackage.swift): the one whole-package removal; a package already gone counts as removed.

## Unopened books and a folder's tree
<!-- id: unopened-books-folder-tree; keys: folder contents, descendants, subfolder, recursive; src: TextMouth/Models/Book.swift, TextMouth/Models/Library.swift -->

Book.isUnopened (Models/Book.swift) and Library.booksInFolderTree(_:) (Models/Library.swift) are the one definition of "never opened" and of "a folder's tree of books" (the library's own books in the folder and below it, never a feed's items).
Book.isUnopened is read by the Unopened category, a row's New badge, Speak Info, a feed item's New and its kept package's test, and the recently opened sort.
Library.booksInFolderTree is read by a folder's emptiness test (hasBooks(inFolderTree:), which stops at the first book), its book counts, and its Speak Info.
Delete Folder… lists the books it removes with booksInFolderTree, and Library.removeFolderAndContents(id:) removes the same books, so a feed's item that names a folder is neither deleted nor dropped.
Library.isPath(_:inTreeAt:) is the one "is this path the folder or below it" rule, by whole path components, which the folders, their sort settings, and the books all follow.

## Array subscript(safe:) in tests
<!-- id: array-subscript-safe-tests; keys: out of bounds, index safety, XCTest helper, optional element, test support; src: TextMouthProductionTests/CollectionTestSupport.swift -->

Array's subscript(safe:) (TextMouthProductionTests/CollectionTestSupport.swift) is the tests' one way to read an element they have not proven is there, so a break in the code under test fails an assertion rather than trapping the test host.

## Audio manifest location and reading
<!-- id: audio-manifest-location-reading; keys: manifest.json, track file names, folder layout, JSON; src: TextMouth/Parsers/AudioManifest.swift -->

AudioManifestLocation and AudioManifest.read(inAudioFolder:) (Parsers/AudioManifest.swift): where an audiobook's manifest lies, at the top of its audio folder or inside its one folder, and how its names are spelled from there.

## AudioTrackPlan
<!-- id: audiotrackplan; keys: track order, chapter levels, pause after track; src: TextMouth/Parsers/AudioManifest.swift, TextMouth/Models/ChapterPauses.swift -->

AudioTrackPlan (Parsers/AudioManifest.swift): the one arrangement of a multi-file audiobook's tracks, their order, titles, group headings and levels, and the pause after each, used by the parser and by ChapterPauses.

## ChapterPauses
<!-- id: chapterpauses; keys: silence between chapters, gap, pause after chapter, manifest pauses, equality; src: TextMouth/Models/ChapterPauses.swift, TextMouth/Services/BookManifestEditing.swift -->

ChapterPauses (Models/ChapterPauses.swift): the reader's one source of pauses between chapters.
Two values are equal when they give the same pause after every chapter, whatever list made them: init(afterEachChapter:) drops trailing entries of no pause, so ChapterPauses.none equals every list of zeros, such as the one a manifest with no pause gives.
The manifest TextMouth writes for a book that had none (pauseBetweenTracksMs 0) is therefore no edit when BookManifestEditSessions.manifest(_:at:arranges:as:tracks:showingPauses:owed:) compares its pauses with an open reader's.

## Heading announcement
<!-- id: heading-announcement; keys: VoiceOver, next heading, announce heading, outline levels, spoken heading; src: TextMouth/ViewModels/ReaderViewModel+Navigation.swift -->

ReaderViewModel.headingAnnouncement(arrivingAt:in:): what a heading jump says, every heading at the place it reaches, the outermost first.

## PackageFileEditing
<!-- id: packagefileediting; keys: external editor, file watcher, NSWorkspace, iOS stub; src: TextMouth/Platform/iOS/Services/PackageFileEditing+iOS.swift, TextMouth/Platform/macOS/Services/PackageFileEditing.swift -->

PackageFileEditing (Platform/macOS/Services/PackageFileEditing.swift) holds what Edit Text and Edit Manifest share:
- the first-use explanation, worded for each kind;
- the app chooser;
- the workspace opener;
- the watcher of a file in a book's package;
- TextMouth becoming active;
- and the announcements kept until it does.

## ObjCException.catching
<!-- id: objcexception-catching; keys: NSException, try catch, Objective-C bridge, crash guard, ObjCException.making, Raised; src: TextMouth/Services/ObjCException.swift -->

ObjCException.catching(_:) (Services/ObjCException.swift) runs a framework call that may raise an Objective-C exception and returns it, so a raise cannot end the app.
It wraps the ObjCExceptionCatcher static library in Vendor/, built as LAME is, with a module map; it is the only Swift file that imports it (B08).
ObjCException.making(_:) runs a call that makes a value through an API that raises for arguments it refuses (the initializers of AVAssetWriterInput and AVAssetReaderAudioMixOutput do, for a sample depth they don't take), and throws ObjCException.Raised instead.
Raised holds the exception's name and reason, and its summary is `<name>: <reason>` for the debug log and for AudioEditError.renderFailed ([The sample depth of a render](state/audio-edits.md)).

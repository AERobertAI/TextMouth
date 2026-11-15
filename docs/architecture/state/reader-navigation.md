# The reader's moves between books, and search
<!-- id: reader-navigation; keys: reader navigation, book moves, search; src:  -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## Autoplay requests
<!-- id: autoplay-requests; keys: autoplay, play next book, request store, hand-over, ReaderRequestStore, Continue to Next Book, open window; src: TextMouth/Services/ReaderRequestStore.swift, TextMouth/Services/ReaderAutoplayRequests.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift, TextMouth/ViewModels/LibraryViewModel+SortAndOrder.swift, TextMouth/ViewModels/LibraryViewModel+Succession.swift, TextMouth/Services/LibraryWindowRouter.swift, TextMouth/Views/ContentView.swift, TextMouth/Services/ReadingListOpenRequests.swift, TextMouth/Models/EndOfBookRule.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/Models/ListNeighbors.swift, TextMouth/Services/Feeds/FeedCenter.swift -->

Autoplay requests: Continue to Next Book.

- Owner: ReaderAutoplayRequests.shared, a ReaderRequestStore (Services/ReaderRequestStore.swift) of ReaderAutoplayRequest, the one shape the reading list's requests share (below).
  The store keeps at most one request per book, keyed by the book, claimed at most once (consume(for:)).
  A request is thrown away once older than ReaderRequestStore.lifetime, 30 seconds, unless its book's reader holds its requests (hold(for:) and release(for:)).
  Each is told as it is made (requestsMade), and dropped by discard(for:).
  ReaderAutoplayRequests and ReadingListOpenRequests are the store's two kinds, each with its shared store and its request(…) in a constrained extension.
- Who may write it: a reader whose book ends with Continue to Next Book, or with a feed's or folder's choice to play the book below or above (EndOfBookRule, below), asks LibraryViewModel.succession(after:going:skippingFinished:) what follows.
  It goes the rule's way and acts on the answer (goOnPastThisBook, below).
  For a plain folder's book the answer is nextBook(after:going:skippingFinished:), the first of booksBeyond(_:going:) that is wanted.
  Those are the books beyond it in the folder's manual order as the list shows it (ManualBookOrder.orderedBooks), found by ListNeighbors.beyond(_:going:in:), passing over those that rest at their end (Book.restsAtEnd) when the rule skips finished books.
  For a feed's item it is the next item the feed's folder lists that way (FeedCenter.listedItems(of:), newest first, FR11, leaving out items moved into the library): a downloaded item's book, or, for an item whose file is not here, the order to download it (BookSuccession.episodeToDownload, below).
  When the rule skips finished books, an item whose book rests at its end is passed over, and so is one with no file here that was played (FeedItem.playedDate).
  The reader hands over to a book (handOverToNextBook(to:titled:askingWith:), which takes back the finished state, shows the book paused in Now Playing, and announces the next book).
  Half a second later (continueToNextBookDelay), continueToNextBook(_:under:) leaves a request for it.
  Then showNextBook shows the book as the window choice says (a book moves in place or in a new window, 0.2.5, in [Windows](windows.md)).
  By default this reader's own window switches to it, the new reader there claiming the request once loaded.
  With A New Window, or whenever switching could lose work, it posts continueToNextBook, which LibraryWindowRouter turns into that book's reader, or brings it forward.
  With nothing to hand over to, the book says "No more books in folder" when no book lies that way and "Every book after it in the folder is finished" (EndOfBookWording.onlyFinishedBooksInFolderNote(going:), "before it" going up) when only finished books do.
  A book read from the reading list, and Next or Previous in Reading List from a playing book, leave a request the same way, through continueToNextBook(_:under:) (reading from the reading list, below).
- How others observe it: the next book's reader claims the request when it finishes loading, or at once when it was already open and loaded, and starts playing.
  A reader that cannot load its book discards the request.
  A reader that downloads its book from the cloud to open it holds its book's requests (FR02), from startDownload(.opening) until claimAutoplayRequest(), discardAutoplayRequest(), or endCloudWorkForClose().
  A failed or cancelled download and a failed load call discardAutoplayRequest().
  After endCloudWorkForClose() the request ages again from when it was made.
  So the next book starts once it has downloaded and loaded, however long that takes, and meanwhile a Play in the finished book's window still says "Still starting".
  A Library window that refuses an open while the library moves or the data directory is unavailable drops both kinds of request for the book (ReaderOpenRefusal.dropRequests(for:), from ContentView's two refusals).

## Library search requests
<!-- id: library-search-requests; keys: Search Library, search result jump, open at match, LibrarySearchJumpRequest, claim, VoiceOver announcement; src: TextMouth/Services/LibrarySearchJumpRequests.swift, TextMouth/ViewModels/ReaderViewModel+LibrarySearch.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/ViewModels/LibrarySearchModel.swift, TextMouth/Services/ReaderRequestStore.swift, TextMouth/Services/TextSearch/BookTextSearch.swift, TextMouth/Models/LibrarySearchWording.swift, TextMouth/Services/VoiceOverAnnouncer.swift, TextMouthProductionTests/LibrarySearchJumpTests.swift -->

Library search requests (libsearch): the move to a match that Search Library opened.

- Owner: LibrarySearchJumpRequests.shared, a ReaderRequestStore (Services/LibrarySearchJumpRequests.swift) of LibrarySearchJumpRequest, the same shape as the autoplay and reading list requests: at most one per book, claimed once, thrown away after 30 seconds.
  A request carries the book, the match's chapter, UTF-16 offset in it and in the book, the matched text, and the query and TextSearchOptions that found it.
  ReaderViewModel.libraryJumpRequests holds the store the reader reads (the shared one unless a test gives its own).
- Who may write it: LibrarySearchModel.open(_:), which makes the request and then posts .openBookWindow, so the router opens the book's reader window, or brings its open one forward, and refuses while the library moves.
  A book the library refuses to open drops its requests (ReaderOpenRefusal.dropRequests, with the reading list's and the autoplay's), so opening the book another way within 30 seconds never jumps to an old match.
- How others observe it: ReaderViewModel.claimLibrarySearchJump() (ReaderViewModel+LibrarySearch.swift) claims the request once the book has loaded, as its load ends for a new window, or at once for a reader open already (requestsMade).
  A closed reader claims nothing and a loading one leaves it waiting.
  A book with no text to search says so, as Search in Book does (announceNoTextToSearch).
  Otherwise LibrarySearchJumpPlace.atPlace(for:in:) checks the place on the main actor with one lookup, and moves at once when the place still holds the match.
  A literal query is looked up in a window one character either side.
  A regular expression takes one attempt anchored at the place (BookTextSearch.Matcher.regexMatch(at:in:), under 0.1 ms at the last match of a 19 MB chapter, where a scan took 0.1 s).
  Only when the text changed since the search (Edit Text, a rebuild) does the reader search the whole book off the main actor (searchWholeBook, up to libraryJumpMatchLimit, 100,000 matches, cancellable: a later claim, closing, or another book stops it).
  It then moves to the match nearest the old place (LibrarySearchJumpPlace.nearest, the earlier of two equal), or says the match is gone.
  The move goes through navigatePreservingReturnPosition, as Search in Book's pick does, so Go Back returns to where the reader was (for a book that was not open, to its saved reading position), and honours Auto-play on navigate.
  What VoiceOver hears (LibrarySearchWording.movedToMatch(location:), movedToMatchFoundAgain, matchGone) is said through afterReaderComesForward, once the reader's window is in front, VoiceOverAnnouncer.afterSheetDelay (0.6 s) after the move.
  It waits because an open reader claims the request inside the request, before the Search Library window brings it forward, and words said at once came while the window changed.
  They are not said once the reader has closed, has claimed a later request, or, for a move, once Go Back has undone it.
- Tests: LibrarySearchJumpTests, in the reader-text area of Scripts/test/areas.conf.

## What follows a finished book
<!-- id: what-follows-finished-book; keys: end of book, Continue to Next Book, next episode, EndOfBookBehavior, succession, predownload, FeedCenter; src: TextMouth/Models/EndOfBookRule.swift, TextMouth/Models/EndOfBookWording.swift, TextMouth/Models/ListNeighbors.swift, TextMouth/ViewModels/ReaderViewModel+GoingOn.swift, TextMouth/ViewModels/ReaderViewModel+EpisodeDownload.swift, TextMouth/ViewModels/ReaderViewModel+Predownload.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/ViewModels/ReaderViewModel+ReadingList.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/ViewModels/LibraryViewModel+Succession.swift, TextMouth/ViewModels/LibraryViewModel+SortAndOrder.swift, TextMouth/Services/Feeds/FeedCenter.swift, TextMouth/ViewModels/SettingsViewModel.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/Models/ReadingList.swift, TextMouth/Models/ListeningOptions.swift -->

What a finished book is followed by (FR19): the rule that weighs the settings, and the wait for a feed's next episode.

- Owner: EndOfBookRule (Models/EndOfBookRule.swift), a value that ReaderViewModel.endOfBookRule resolves each time it is asked.
  It resolves from the book's own end behavior (Book.localEndOfBookBehavior; a raw value that names no EndOfBookBehavior is ignored).
  It also takes the options of its feed or plain folder (LibraryViewModel.listeningOptions(of:), in [Feeds](feeds-interface.md)).
  It also takes the global setting (SettingsViewModel.endOfBookBehavior).
  It holds the behavior, the direction (ReadingList.Direction), skipsFinished, and predownloadsNext.
  EndOfBookRule.resolve is the one place the order is written: the book's own choice, which always goes down.
  Else the options' choice (play the book below is Continue to Next Book going down, play the book above is Continue to Next Book going up, and stop is Stop).
  Else the global setting, which goes down.
  The reading list, for a book opened from it, is asked first by the callers, and is no input. skipsFinished and predownloadsNext come from the options whichever layer decides, and are true when there are none.
  ReaderViewModel.effectiveEndOfBookBehavior is the rule's behavior alone, which the settings sheet's picker and the sleep timer's hints read.
  So the picker names Continue to Next Book for either direction, and its Use Global Default button falls back to the options' choice before the global setting.
  A reader that waits for an episode owns nextEpisodeWait, an AnyCancellable on the feed engine's events, and hasAskedForPredownload, with predownloadLeadTime (ListeningOptions.predownloadLeadTime, 10 minutes; a test lowers it).
- Who may write it: handleEndOfBook() and playFromTheEnd() ask the rule.
  With the reading list's followReadingListPastThisBook(sleepTimerEndsListening:sleepTimerStoppedHere:sayingNothingFollows:) each ends in goOnPastThisBook(to:in:startingWith:sleepTimerEndsListening:sleepTimerStoppedHere:sayingNothingFollows:) (ReaderViewModel+GoingOn).
  That is the one copy of the steps the reading list's end and Continue to Next Book once each carried.

### The next episode of a feed
<!-- id: what-follows-next-episode; keys: BookSuccession, NextEpisodeWait, episodeToDownload, predownload, goOnPastThisBook, FEED_PREDOWNLOAD; src: TextMouth/ViewModels/ReaderViewModel+GoingOn.swift, TextMouth/ViewModels/ReaderViewModel+EpisodeDownload.swift, TextMouth/ViewModels/ReaderViewModel+Predownload.swift, TextMouth/Models/EndOfBookRule.swift, TextMouth/ViewModels/ReaderViewModel.swift -->

The function goOnPastThisBook takes a BookSuccession: .book, which it hands over to unless this reader's sleep timer ends listening here (sleepTimerEndsListeningHere); .nothing(note:), which it says why; or .episodeToDownload(feedID:item:), a feed's next episode whose file is not here.
The timer ends listening here when it is fading out, or is set for the end of a heading or of the book, which this end reaches.
Then the reader says "Next book not started because of the sleep timer", and starts no download either.
A timer counting minutes goes on with the next book ([Timers and statistics](timers-and-statistics.md)).
For an .episodeToDownload it says, from EndOfBookWording.downloadingNextNote ("article" for an article), "Finished: TITLE.
Downloading the next episode: NEXT TITLE."
It then calls waitForNextEpisode(_:of:startingWith:) (ReaderViewModel+EpisodeDownload).
That notes a NextEpisodeWait: the item, its feed, and the closure that starts the book.
The wait also holds controlsOwner, the reader that held the media controls as the wait began (NowPlayingSession.activeOwnerID).
And it holds the NextEpisodeCause, .endOfBook or Next and Previous in Folder's .folderMove, and expiryMark, the sleep timer's expiry count as the wait began.
The function waitForNextEpisode listens to the feed engine's events first, then asks FeedCenter.download(_:of:startingNext:) with startingNext true, the listener's download (in [Feeds](feeds.md)).
So the newest-N rule never removes it, one already waiting or running is not started twice, and it is put ahead of the downloads queued before it, opening nothing since the wait hands over.
Then it looks at the item's state: downloading or waiting, it waits.
Already downloaded, it goes on at once.
Anything else, the engine refused, and the reader says EndOfBookWording.nextEpisodeNotDownloaded(reason:isArticle:) with EndOfBookWording.downloadNotStartedReason.
The item's downloadFinished event hands listening over as for any next book ("Starting: NEXT TITLE", goOnWithNextEpisode(as:during:)).
It does not when the listener has moved on (listenerHasMovedOn(_:)): the reader no longer rests finished, has closed, or plays, or another reader took the media controls since the wait began, by playing or by its window becoming the focused one.
The controls returning to this reader, or staying with the reader that held them, is no move.
Nor does it when this reader's sleep timer ran out since the wait began, whether it was set before or during the wait, or is fading out (SleepTimerService.endedListening(ownedBy:sinceExpiry:), against expiryMark).
In both cases the episode is not started and nothing is said but what the timer said as it ran out.
A running timer goes on with the episode, handOverToNextBook holding it for the book as for any next book.
When the wait is for Next or Previous in Folder, a book that was playing hands over to the episode and any other only opens it, and the wait's failure and cancel use the folder commands' sentences (below).
Its downloadFailed event says nextEpisodeNotDownloaded with the failure's own sentence.
Its downloadCancelled event, which FeedDownloadManager sends when the listener cancels the download, says EndOfBookWording.nextEpisodeDownloadCancelled ("Download cancelled, so playback stopped.", one sentence for an episode and an article).
Each ends the wait, and neither is said, only traced (DiagnosticLog.trace), when the listener has moved on.
The wait also ends when the reader closes (close() clears nextEpisodeWait), when another wait replaces it, and when a new end decision supersedes it.
On a new end decision, goOnPastThisBook clears it first, and playFromTheEnd() does as its first step, since its Stop, Starts Over, and Loop branches do not pass through goOnPastThisBook.
ReaderViewModel.predownloadNextEpisodeIfDue() (ReaderViewModel+Predownload) is called from publishLivePosition(now:) as the position publishes, cheapest guard first, and asks once for each reader: the reader is open, loaded, and playing.
Its book is a feed's item, not opened from the reading list.
The rule continues to the next book and predownloadsNext.
And timeRemaining is above 0 and at most predownloadLeadTime.
It then asks LibraryViewModel.succession.
For an .episodeToDownload whose item is not downloading already (FeedItemState.isDownloading) it logs FEED_PREDOWNLOAD and asks FeedCenter.download(_:of:).
One the newest-N rule put off, which waits for a network without data limits or for room, is fetched all the same, and this ask takes its place.
- How others observe it: the announcements through announceToVoiceOver(_:) and finishListening(announcing:), the wait through FeedEvent.downloadFinished, downloadFailed, and downloadCancelled, and the early download as any listener's download (the feed downloads' progress, in [Feeds](feeds.md)).

## Reading from the reading list
<!-- id: reading-from-reading-list; keys: Reading List, play list, Next in Reading List, window title, position in list, open request; src: TextMouth/ViewModels/ReaderViewModel+ReadingList.swift, TextMouth/Services/ReadingListOpenRequests.swift, TextMouth/Models/ReadingListPlace.swift, TextMouth/Models/ReadingListReaderWording.swift, TextMouth/Models/EndOfBookWording.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift, TextMouth/Views/Reader/BookReaderWindowView.swift, TextMouth/Views/Reader/ReaderView.swift, TextMouth/Views/Library/LibraryView.swift, TextMouth/App/MenuCommands.swift, TextMouth/Models/KeyboardShortcut.swift, TextMouth/Services/ReaderRequestStore.swift, TextMouth/Services/ReaderAutoplayRequests.swift, TextMouth/ViewModels/LibraryViewModel.swift -->

Reading from the reading list (FR09): whether a reader reads its book from the reading list, and where the book stands there.

- Owner: the reader's readingListPlace, a ReadingListPlace (Models/ReadingListPlace.swift: the book's position in the list as the Reading List shows it, from 1, and how many books the list shows), nil while it doesn't read from the list (isOpenedFromReadingList).
  And ReadingListOpenRequests.shared (Services/ReadingListOpenRequests.swift), the requests waiting for readers, a ReaderRequestStore of ReadingListOpenRequest, as ReaderAutoplayRequests is of its own (autoplay requests, above).
  It holds at most one request a book, usable for ReaderRequestStore.lifetime, 30 seconds, claimed at most once.
  The two kinds stay in stores of their own because a reader claims each at a different moment.
  A reader window's value is only its book's ID, so the mark can't ride on the window.
  A refused open drops the book's request (ReaderOpenRefusal.dropRequests(for:), above).
- Who may write it: LibraryView.openBook(_:), which a row's default action, its Open item, and the Open Selected Book key (Return) call, makes a request before onOpenBook at the Reading List alone, and not while the library moves (ReadingListOpenRequests.open(_:shownIn:libraryIsMoving:with:)).
  A book read from the list makes one for the book it continues to (continueThroughReadingList(to:)) or opens with Next or Previous in Reading List (openFromReadingList(_:)).
  The book's reader claims a request once: as it is created (observeReadingList()), so a long load or a cloud download can't outlive it, or, for a window already open, as the request is made (requestsMade).
  It then keeps the book's place current from LibraryViewModel.$library (followReadingList(in:)) until the book leaves the list or the library, and from then on reads as any reader does, even if the book is put back.
- How others observe it: BookReaderWindowView.windowTitle(for:readFromReadingList:) titles the window "Reading List: TITLE by AUTHOR" in place of "Book: …".
  ReaderLocationHeader shows the place under the title (ReadingListReaderWording.place, "Reading list, book 3 of 12"), and the full Where Am I? says it after the times (fullWhereAmISummary).
  At its end, handleEndOfBook() hands a book read from the list to finishBookReadFromReadingList(sleepTimerEndsListening:sleepTimerStoppedHere:replayingAFinishedEnd:), in place of the book's own end-of-book behavior.
  The book rests at its end and is counted finished, once (finishAtTheEnd(replayingAFinishedEnd:), P07).
  Then finishBookReadFromReadingList calls followReadingListPastThisBook(sleepTimerEndsListening:sleepTimerStoppedHere:sayingNothingFollows:), which Play on a finished book read from the list calls too (playFromTheEnd()).
  That asks readingListContinuation(after:) for the book that follows.
  Then continueThroughReadingList(to:) starts it as Continue to Next Book starts the next book in a folder, through the same hand-over (handOverToNextBook(to:titled:askingWith:)), unless this reader's sleep timer ends listening here (sleepTimerEndsListeningHere).
  Otherwise the reader stops, says why, and rests finished (ReadingListReaderWording.stopNote and endNote(_:going:)).
  ReaderViewModel.goThroughReadingList(_:) serves ShortcutAction.nextInReadingList and .previousInReadingList, under Navigation with no default keys, which the Navigate menu enables through the readsFromReadingList scene value the reader's window publishes.
  It pauses a playing book without the pause sound, counting a book Where Am I? will play as playing (whereAmIWillPlayBook).
  That pause ends whatever Where Am I? holds without resuming, even over a book that was not playing.
  It then announces the neighbor, and plays it when this book was playing, or else opens it, through the start every move shares (beginMoveToAnotherBook(), below).
  This reader's window's running sleep timer goes with the book (in [Timers and statistics](timers-and-statistics.md)): the window keeps it when the book changes in place, and a new window takes it once its book has loaded (each reader window has a timer of its own).
  The window a move through the list shows its book in follows the global Open the next book in, since the list has no choice of its own (readingListMoveWindowChoice).
  EndOfBookWording words every end of a book, the book's own end-of-book behavior's with the sentences it always had.

## Moving to another book
<!-- id: moving-another-book; keys: Next in Folder, Previous in Folder, Next in Reading List, BookMoveRoute, sleep timer hand-over, next book window; src: TextMouth/ViewModels/ReaderViewModel+BookMoves.swift, TextMouth/ViewModels/ReaderViewModel+FolderNavigation.swift, TextMouth/ViewModels/ReaderViewModel+SleepTimerHandOver.swift, TextMouth/ViewModels/ReaderViewModel+NextBookWindow.swift, TextMouth/ViewModels/ReaderViewModel+EpisodeDownload.swift, TextMouth/ViewModels/ReaderViewModel+ReadingList.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/Models/FolderNavigationWording.swift, TextMouth/Models/KeyboardShortcut.swift, TextMouth/App/MenuCommands.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/Models/SleepTimerHandOverWording.swift, TextMouth/Models/ReadingListReaderWording.swift, TextMouth/Models/EndOfBookWording.swift, TextMouth/Services/SleepTimerRegistry.swift -->

Moving to another book on a command, and Next in Folder and Previous in Folder (0.2.5): the one start every move shares, and the folder commands.

- Owner: the reader, in ReaderViewModel+BookMoves (BookMoveRoute, .readingList or .folder, says which way a command asks for its book; BookMoveStart is what a move found: wasPlaying, plays, and timerFadeEnded), ReaderViewModel+FolderNavigation, and ReaderViewModel+SleepTimerHandOver.
  The state of a move not yet finished is the reader's own: pendingMoveGeneration, pendingMovePlays, pendingMoveHold (what the move announced last did to the sleep timer's hold), askedMove, and episodeWaitPlays.
  The askedMove is the move asked for whose book has not claimed its request to play it: an AskedMove, its target, its hold, and requestMadeAt, the date of its request, so a request made later for the same book by another move never revives it.
  The words are FolderNavigationWording (Models/FolderNavigationWording.swift) and the reading list's and the end of a book's (ReadingListReaderWording.opening, EndOfBookWording.starting).
- Who may write it: beginMoveToAnotherBook() is the one start of every move, Next and Previous in Reading List (goThroughReadingList(_:)) and in Folder (goThroughFolder(_:)) alike; handOverToNextBook(to:titled:askingWith:), the end of a book's, starts with cancelPendingMoves() instead.
  It reads whether this book was playing, counting as playing:
  - a book Where Am I? will play;
  - one a move brought here whose request to play is still waiting;
  - an earlier move to play announced and not yet asked for (pendingMovePlays);
  - an episode wait that was to play (episodeWaitPlays);
  - a hand-over not yet asked (NextBookHandOver.isPendingAsk); and
  - an asked move whose book has not claimed its request (underWayAskedMove()).
  So a second move goes on to play its book.
  Discards the request waiting for this book.
  Cancels an earlier move, as the last move wins until its book has started (cancelPendingMoves()):
  - cancelAskedMoveUnderWay() discards the asked move's request, the book then opening in its window without playing, and undoes its hold;
  - then undoPendingMoveHold();
  - then it advances pendingMoveGeneration so the half second's ask of an earlier move does nothing; and
  - it cancels nextBookHandOver.
  Ends any episode wait (nextEpisodeWait = nil).
  Pauses without the pause sound.
  And ends the fade of a timer the move carries, its own or one held for this book, stopping it after the pause since a pause leaves a held fade alone, saying so afterwards when it did (announceTimerFadeEndedIfNeeded(by:), SleepTimerHandOverWording.fadeEndedByTheMove).
  Then announceMove(to:titled:start:through:) says "Starting: TITLE" or "Opening: TITLE", and notes the move (noteMoveAnnounced(to:), in [Timers and statistics](timers-and-statistics.md)).
  After continueToNextBookDelay, 0.5 s, it asks for the book (askForBook(_:plays:through:)).
  The reading list's route goes through continueThroughReadingList(to:) or openFromReadingList(_:), the folder's through continueToNextBook(_:under:) or openInFolder(_:), each ending in showNextBook (in [Windows](windows.md)), which makes the askedMove.
  A book that cannot be opened ends the move's timer through releaseSleepTimerHeld(forBook:afterTheReason:) (ReaderViewModel+SleepTimerHandOver), which asks the registry to stop the timer held for it in whichever window holds it.
  The sentence SleepTimerHandOverWording.noBook, "Sleep timer cancelled, because the next book could not be opened.", is then skipped when any window's timer has started, been held, or taken one since the stop (SleepTimerRegistry.timerChanges, in [Timers and statistics](timers-and-statistics.md)).
  So a timer the listener started in another window meanwhile is not contradicted.

### Next and Previous in Folder
<!-- id: moving-another-book-folder; keys: goThroughFolder, nextInFolder, previousInFolder, FolderNavigationWording, NextEpisodeCause; src: TextMouth/ViewModels/ReaderViewModel+FolderNavigation.swift, TextMouth/Models/FolderNavigationWording.swift, TextMouth/ViewModels/ReaderViewModel+BookMoves.swift -->

ReaderViewModel.goThroughFolder(_:) serves ShortcutAction.nextInFolder and .previousInFolder.
They are the notifications nextInFolder and previousInFolder, which every reader hears and the targeted one takes (isTargetedNotification).
They are in Navigation with no default keys, offered by the Navigate menu through the isReaderWindow scene value the reader's window publishes.
The way looked is the way the end of this book would go on (EndOfBookRule.direction, down for a book's own choice, a Stop, and the global setting) for Next, and the opposite way for Previous.
The item is LibraryViewModel.succession(after:going:skippingFinished:), the one search the end of a book asks, so a book read from the reading list goes through its own folder or feed.
For .nothing(note:), it says FolderNavigationWording.nothingThatWay(note) before any move begins and changes nothing.
For .book(_:), it goes on as above.
For .episodeToDownload(feedID:item:), it says FolderNavigationWording.downloading(_:going:), holds no sleep timer, and calls waitForNextEpisode(_:of:cause:startingWith:) with NextEpisodeCause.folderMove(direction:wasPlaying:).
That wait, when the episode arrives, makes the move that plays it (handOverToNextBook) or only opens it (announceMove).
Its failure and cancel are said by FolderNavigationWording.episodeNotDownloaded(reason:isArticle:going:playbackStopped:) and downloadCancelled(isArticle:going:playbackStopped:), saying that playback stopped only when the book was playing.
Two presses within half a second find the same item, since both look from this book.
- How others observe it: the announcements, through announceToVoiceOver(_:); the window the book shows in follows folderMoveWindowChoice.
A later move ends the wait for an episode, which goes on downloading but starts nothing, and so does closing the reader (close() clears nextEpisodeWait).

## Manifest edit while the book is open
<!-- id: manifest-edit-while-book-open; keys: manifest.json, rearranged tracks, tracksRearranged, track order, audiobook edit, live reader; src: TextMouth/ViewModels/LibraryBookUpdates.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/ViewModels/ReaderViewModel+ManifestEdit.swift -->

A manifest edit taken while the book is open (FR17): LibraryBookEvent.tracksRearranged brings it to the book's readers. showRearrangedTracks (ViewModels/ReaderViewModel+ManifestEdit.swift) maps the cursor by file and swaps the content, chapter files, pauses, and transcript.
It then listens again for the end of the play under way, as the play of its track's new chapter in the same generation, and names the next file again.
A reader still loading keeps the edit until its load ends.

## Search in Book on transcribed audiobooks
<!-- id: search-book-transcribed-audiobooks; keys: Find in book, transcript search, BookSearchModel, timed result, Go Back, canSearchText, search sheet; src: TextMouth/ViewModels/ReaderViewModel+Bookmarks.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/ViewModels/ReaderViewModel+Transcript.swift, TextMouth/Views/Reader/BookSearchView.swift, TextMouth/Views/Reader/ReaderView.swift, TextMouth/Services/TranscriptTextLoader.swift, TextMouth/Models/TranscriptTextIndex.swift, TextMouth/ViewModels/BookSearchModel.swift, TextMouth/ViewModels/TranscribedBooks.swift, TextMouth/Models/DocumentContent.swift, TextMouthProductionTests/TranscriptSearchTests.swift, Scripts/test/areas.conf -->

Search in Book on a transcribed audiobook, and Go Back (FR05): what the search reads, how a result is timed and chosen, and the jump's way back.

- Owner: ReaderViewModel, with the sheet's own BookSearchModel.
  ReaderViewModel.canSearchText says whether there is a text to search: a text book that has loaded, or an audiobook whose content holds a transcript's text (any other audiobook has only spacing that counts time).
  ReaderViewModel.searchCorpus copies what a search reads, so that it can run off the main actor.
  That is a text book's chapters with its headings, or the transcript's chapter texts, named by the audio chapters' titles alone, since an audiobook's headings count audio time.
  A transcript's corpus comes with a BookSearchTiming (Views/Reader/BookSearchView.swift: where each audio chapter begins, forTranscript(_:audioChapters:), and TranscriptText.chapterTime(atTextOffset:inChapter:)).
  So each BookSearchResult of a transcript carries the time it is heard (time, and timedLabel for its row and its rotor entry).
  ReaderViewModel.transcriptWithheld (a TranscriptTextWithheld) is why a book that has a transcript shows none of its text.
  It is set by the load (TranscriptTextLoader.Load.withheld, or editHeld when readContent holds a text edit for an audiobook) and cleared by showTranscript(_:).
  ReaderViewModel.pendingJumpAnnouncement holds what to say once the sheet has closed.
  The way back is the reader's saved place (savedChapterIndex, savedCharacterOffset, hasSavedPosition), which every jump that goes through navigatePreservingReturnPosition(chapterIndex:characterOffset:) sets.
- Who may write it: ReaderPanelCommands (ReaderView.swift) takes the searchInBook notification: it toggles the sheet while canSearchText holds, and for a loaded audiobook that cannot be searched says why instead (announceNoTextToSearch(hasTranscript:), BookSearchWording.noTextToSearch).
  BookSearchWording.noTextToSearch names Transcribe Audio only for a book that offers it, and takes a reason the load found as proof that the book has a transcript, whatever TranscribedBooks has noted of it yet.
  The toolbar's Search button is there only while canSearchText holds.
  The sheet (ReaderPanelSheets.searchSheet) hands a chosen result to navigateToTranscriptSearchResult(chapterIndex:textOffset:) for a transcript.
  That converts the text offset to an audio offset (TranscriptText.audioOffset(atTextOffset:inChapter:)) and jumps through navigatePreservingReturnPosition, honouring Auto-play on navigate (autoPlayIfEnabled()).
  It sets pendingJumpAnnouncement (BookSearchWording.movedTo(time:location:)), which the sheet's onDismiss speaks through announcePendingJump().
  The text book's counterpart is navigateToSearchResult.
  The goBack notification reaches the key Library window, for its folders, and the reader that takes it (shouldAcceptPanelCommand), which calls goBack(): returnToSavedPosition() while hasSavedPosition holds, otherwise BookSearchWording.nothingToGoBackTo.
  Return on a result row (an onKeyPress on the row's button, through choose(_:)) chooses the result, for every book.
- How others observe it: BookSearchView draws a timed result's row with its time as TimeFormatting.format, no Display picker (isTimed), and the field hint BookSearchWording.transcriptFieldHint; SearchResultRow's positionText and accessibilityDescription are internal, so tests read what a row says.
- Shared with the iPhone's Search in Book (0.4.4; the phone's side is in [The two apps and the platform folders](../platforms-phone-interface.md)), with the Mac's behavior unchanged:
  - The Mac's sheet hands a chosen result to goToSearchResult(chapterIndex:characterOffset:inTranscript:) (ReaderView.swift, searchSheet), which chooses between navigateToTranscriptSearchResult for a transcript and navigateToSearchResult for any other book.
    It is the one place that decides, so the phone's sheet moves the same way.
  - BookSearchWording (Views/Reader/BookSearchView.swift) now holds the sentences of the Mac's search that the phone shares, with their values unchanged: the search field's label and hints, the regular-expression switch's label and hint, the results label, and Back to Book's hint.
  - noTextToSearch(bookTitle:canTranscribe:hasTranscript:withheld:offersTranscription:) and announceNoTextToSearch(hasTranscript:offersTranscription:) take offersTranscription, true by default.
    The Mac passes nothing and says what it said.
    With false, no sentence names Transcribe Audio or tells the listener to transcribe again: "TITLE has no transcript to search." and the stale transcript's reason alone.
  - BookSearchModel takes a debounceInterval, init(corpus:debounceInterval:announce:).
    Its default, BookSearchModel.debounceInterval, is the Mac's 250 milliseconds, and the Mac's one call (BookSearchView) passes none.

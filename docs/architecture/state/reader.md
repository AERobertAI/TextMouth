# The reader
<!-- id: reader; keys: reader overview, reader window; src:  -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## Reader state
<!-- id: reader-state; keys: view model, UI refresh throttle, published properties, accessibility label, Go to Percent, Go to Time, visible text window, SwiftUI redraw; src: TextMouth/Views/Reader/, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/Views/Reader/ReaderView.swift, TextMouth/ViewModels/ReaderShownState.swift, TextMouth/Views/Reader/ReaderSnapshot.swift, TextMouth/Views/Reader/ReaderJumpPanels.swift, TextMouth/Models/PlaceClock.swift, TextMouth/Models/ReaderTimeWording.swift, TextMouth/Views/Reader/HeadingNavigatorView.swift, TextMouth/Views/Reader/BookmarkPanelView.swift, TextMouth/Views/Reader/BookSearchView.swift, TextMouth/Views/Settings/DuplicateFinderView.swift, TextMouth/ViewModels/ReaderViewModel+BookMoves.swift, TextMouth/ViewModels/ReaderViewModel+Bookmarks.swift, TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift, TextMouth/ViewModels/ReaderViewModel+EditedText.swift, TextMouth/ViewModels/ReaderViewModel+EpisodeDownload.swift, TextMouth/ViewModels/ReaderViewModel+FolderNavigation.swift, TextMouth/ViewModels/ReaderViewModel+GoingOn.swift, TextMouth/ViewModels/ReaderViewModel+Jump.swift, TextMouth/ViewModels/ReaderViewModel+LibrarySearch.swift, TextMouth/ViewModels/ReaderViewModel+LibraryUpdates.swift, TextMouth/ViewModels/ReaderViewModel+ManifestEdit.swift, TextMouth/ViewModels/ReaderViewModel+Navigation.swift, TextMouth/ViewModels/ReaderViewModel+NextBookWindow.swift, TextMouth/ViewModels/ReaderViewModel+OggConversion.swift, TextMouth/ViewModels/ReaderViewModel+Pages.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/ViewModels/ReaderViewModel+Predownload.swift, TextMouth/ViewModels/ReaderViewModel+ReadingList.swift, TextMouth/ViewModels/ReaderViewModel+SavedPlaces.swift, TextMouth/ViewModels/ReaderViewModel+SleepTimerHandOver.swift, TextMouth/ViewModels/ReaderViewModel+SpeakInfo.swift, TextMouth/ViewModels/ReaderViewModel+SpeechRefusal.swift, TextMouth/ViewModels/ReaderViewModel+Transcript.swift, TextMouth/ViewModels/ReaderViewModel+VoiceAndSpeed.swift, TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift -->

A reader's state: its content, cursor (chapter and character offset), headings, bookmarks, playback flags, and errors.

- Owner: one ReaderViewModel per reader window, on the main actor, created by BookReaderWindowView with a copy of the library's Book.
- Who may write it: the reader itself, in its ReaderViewModel+ extensions, which this section's src lists.
- How others observe it: ReaderView and its subviews observe the reader, refreshed at most every 0.12 seconds during playback (ReaderViewModel.playbackUIRefreshInterval), on the leading edge.
  ReaderViewModel.schedulePlaybackUIRefresh() runs a change that comes a whole interval or more after the last refresh (lastPlaybackUIRefresh, set as the refresh drains) on the main queue's next turn (main.async), where a chapter index and an offset set together are shown together.
  For a change inside the interval it waits out only what is left of it, never more than the interval, so a clock set back cannot make it wait longer.
  delayedPlaybackUIRefreshCount counts the waits, and playbackUIRefreshNow gives tests their own clock.
  The reader publishes only when what its window shows has changed (the audit's C3): displayChapterIndex, displayCharacterOffset, and displayVisibleTextWindow are plain private(set) properties, not @Published ones, so a mirror's change draws nothing by itself.
  Each refresh brings them up to date and then, in a defer of refreshPlaybackUI, announceShownStateIfChanged() builds a ReaderShownState and sends objectWillChange only when it differs from announcedShownState, the last one announced (nil until the first refresh).
  So the window is drawn about once a second while a book plays, not eight times.
  ReaderShownState is one Equatable value of everything a view of the window draws from the place: the chapter index, the heading position, headingsBehind, the status row's percentText and timeLeftText, the page position, hasNearbyBookmark, and the visible text window.
  ReaderShownState.headingsBehind is how many headings start at or before the place, which the Headings sheet marks its current heading from under each level filter.
  The spoken forms of percentText and timeLeftText are made from the same figures.
  ReaderShownState.hasNearbyBookmark is whether a bookmark is near, which the playback bar's bookmark button names.
  A value left out of ReaderShownState would go stale on the screen and to VoiceOver, which is why ReaderShownStateTests build every label from the raw cursor at each step and compare.
  The sleep timer's countdown is not in it: SleepTimerStatusLabel draws it ([Timers and statistics](timers-and-statistics.md)).
  ReaderViewModel.headings is the book's headings, in reading order, kept in step with content by its didSet, and Next Heading, Previous Heading, the jumps, and timeEstimateForHeading read it rather than ask the content index to build them again.
  ReaderView's body only puts its parts together, since the compiler type-checks a body as one expression.
  ReaderLocationHeader, ReaderTextArea, ReaderLoadFailureView, the toolbar's items, and the modifiers ReaderErrorAlert, ReaderPanelSheets, and ReaderPanelCommands are each type-checked on its own.
  ReaderPanelSheets and ReaderPanelCommands share one ReaderPanels, the panels showing.
  ReaderTextArea puts its label, ReaderTextArea.accessibilityLabel ("Book content"), on its ScrollView, never on the Text, since a label on a SwiftUI Text replaces the text's accessibility value (A11).
  The Text shows ReaderViewModel.displayVisibleTextWindow, which VisibleTextWindowPolicy.bounds(in:around:maximumLength:) cuts at most ReaderViewModel.maxDisplayChars (20,000 UTF-16 units) long, around the reading position, which it always holds.
  Each cut edge moves inward at most a quarter of the window, to a paragraph break, else a line break, else stays where it falls between words, else to a space; text with no space there is cut between whole characters.
  BookSettingsWording (Views/Reader/ReaderView.swift), which holds every word for a book's own settings, names their sheet (BookVoicePickerView) and the toolbar button that opens it: a text book's Voice ("Change voice for this book" to VoiceOver) and Voice & Speed.
  An audiobook's Audio Settings, the same on screen and to VoiceOver.
  And audioSpeedLabel, for the audiobook sheet's one speed control, a slider.

### Sheets, clocks, and what the library sees
<!-- id: reader-state-sheets-clocks; keys: ReaderSnapshot, Headings sheet, Go to Percent, Go to Time, PlaceClock, Search in Book, Find Duplicate Books, checkpoint; src: TextMouth/Views/Reader/ReaderSnapshot.swift, TextMouth/Views/Reader/ReaderJumpPanels.swift, TextMouth/Models/PlaceClock.swift, TextMouth/Models/ReaderTimeWording.swift, TextMouth/Views/Reader/HeadingNavigatorView.swift, TextMouth/Views/Reader/BookmarkPanelView.swift, TextMouth/Views/Reader/BookSearchView.swift, TextMouth/Views/Settings/DuplicateFinderView.swift, TextMouth/ViewModels/ReaderViewModel+Jump.swift -->

The Headings, Voice, and Bookmarks sheets observe a ReaderSnapshot of what they show instead, which reads the reader on the main queue's turn after each change and republishes only a value that differs.
As SheetOverOneReader views they compare equal while they show the same reader, so a playing reader's publishes redraw none of them.
When playback crosses into another heading, two of the Headings sheet's rows redraw.
SleepTimerView compares its reader and its auto-close setting.
HeadingNavigatorView labels its list's scroll area (listLabel(headingCount:)), since a label on the whole sheet renamed its pickers, and its level filter is one segmented picker labelled Show levels (levelFilterLabel, its choices filterChoiceTitle(maximumLevel:)).
Each heading's row offers Go To and Skip or Include Section as VoiceOver actions and in its context menu alike.
A bookmark's row shows and speaks the day it was added (Bookmark.dateText, the end of its label), and the empty Bookmarks list names the keys in force for adding one (BookmarkPanelView.emptyListHelp(keys:)).
A book's places are named by times on one clock (P08): ReaderViewModel.placeClock, a PlaceClock built from the content index on each use.
PlaceClock.recording(of:) is for an audiobook: its recording's own time whatever the speed.
Each chapter is as long as its index records it: one file's placeholders summed, as AudioLayout.chapterStartTime plays them; a file per chapter, each to the tenth of a second; a DAISY section, its clips' measured lengths.
PlaceClock.reading(of:readingTime:) is for a text book: its words at the reader's words per minute, as its times always counted.
The status row's percent and time left (BookInfoBar) open Go to Percent and Go to Time, each a JumpFieldPanel: one plain text field whose name is shown for the eye and set as its own label and hint, with Jump and Cancel.
JumpToPercentPanel's field, "Percent through the book", goes through goToPercent(typed:).
JumpToTimePanel's, "Time in the recording" or "Time at 500 words a minute" (ReaderTimeWording.timeFieldLabel(_:), from timeCount), goes through goToTime(typed:).
ReaderViewModel.goToTime(typed:) reads the time with JumpInputValidator.time(_:length:count:) and TimeEntry, refusing one past the clock's length by more than lengthTolerance, and jumps through jumpToTime(seconds:) to PlaceClock.place(forTypedTime:headings:).
That takes a heading starting less than a second after the time, the earliest of several.
The time panel's field starts at goToTimeStartingText, the place's time in whole seconds.
JumpFieldPanel keeps the text its field opened with and takes Jump and Return through JumpFieldOutcome.taking(_:startedAt:submit:): that text unchanged, spaces aside, is .unchanged and closes the panel through onCancel without calling submit; anything else is .jumped or .refused(String).
The Headings sheet's rows (HeadingNavigatorView.headingItems) give Time In on the same clock and Duration heard at the book's speed, PlaceClock.span(from:to:) from the heading to the next heading shown, or to PlaceClock.end after the last.
Copy Reading Position adds the place's time on it (ReaderTimeWording.copiedPlace(_:of:_:)).
The rows follow a speed change made while the sheet is open.
HeadingNavigatorView.RowTiming, the time count, the speed an audiobook's lengths are heard at, and the speed the setting names, is in the sheet's ReaderState, and the sheet rebuilds its rows when it changes.
A listener of its own on the settings model (objectWillChange) rebuilds only if the timing really changed.
One file's chapter marks are not on the clock as marked: the content index keeps no mark's own start, so each chapter there starts at the sum of the placeholders before it, up to a tenth of a second per chapter before its mark, which the Headings sheet's times and Next Heading follow.
Mending it needs the parser to keep mark starts and chaptered books analyzed again.
With SettingsViewModel.includeSpeedWithTimes on, namedListeningSpeed (a ReaderTimeWording.ListeningSpeed) names the speed beside the status row's time left and total, Where Am I?'s time left and total, and Copy Reading Position's time left.
It also names it beside the Headings sheet's durations (shownSpeed(_:), spokenSpeed(_:)), and an audiobook at 1x names none.
The Search in Book sheet (BookSearchView) lists at most BookSearchEngine.resultLimit, 500, matches, and keeps every result row alive in a VStack, as the headings and bookmarks panels do, so VoiceOver's cursor is not sent back up a long list.
A kept row costs about half a millisecond and a tenth of a megabyte to draw.
Find Duplicate Books' list (DuplicateGroupList) keeps every row of the page it shows the same way, and shows a scan's groups in pages of whole groups listing at most 40 books (DuplicateGroupPages).
Each book's native checkbox costs 4 to 8 ms and a quarter of a megabyte to draw, so an author scan of a 700-book library (688 books in 116 groups) took 4 to 5.4 seconds and 184 MB to show at once, and its first page 0.23 seconds and 10 MB (measured in a Debug build by an opt-in benchmark).
The library sees the cursor through LibraryViewModel: the live position about once a second (updateLiveReadingPosition, into live reading positions).
A durable checkpoint (persistReadingPosition) comes every 30 seconds of active playback (PlaybackCheckpointPolicy) and whenever the reader pauses, stops, closes, finishes a chapter, or navigates.

## A reader's copy of its book
<!-- id: reader-copy-book; keys: Book copy, library row, LibraryFields, metadata edit, stale update, text encoding, Book Information; src: TextMouth/ViewModels/LibraryBookUpdates.swift, TextMouth/ViewModels/ReaderViewModel+LibraryUpdates.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/ViewModels/LibraryViewModel+BookOperations.swift, TextMouth/ViewModels/LibraryViewModel+FolderManagement.swift, TextMouth/Models/Book.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/Models/TextEncodingRecord.swift -->

A reader's copy of its book.

- Owner: ReaderViewModel.book, a copy of the library's row taken when the reader opens.
  Its library fields (Book.LibraryFields: where the book's files are, its editable metadata with the record of hand edits, the content analysis fields, and the encoding its text file is read in with who decided it) follow the library.
  Because the encoding record (encodingchoice, a TextEncodingRecord) follows the library, the reader's Book Information shows a new choice and any reading of the file the reader makes uses it.
  The rest (the position, bookmarks, voice, speed, and other per-book settings) is the reader's own, and the reader writes each change of it through to the library.
- Who may write it: the reader, for its own fields and for the metadata its editor saves through the library.
  Otherwise the library fields change only through LibraryViewModel.bookUpdates (LibraryBookUpdates).
  LibraryViewModel offers it every change of library, and whenever a book open in a reader has library fields other than those its readers were last given, they receive its row with the book's next revision; no change to the reader's own fields is published, so those never come back to it.
  A package's move on disk is bracketed: commitLibraryTransition and performLibraryTransition, and a folder rename that only respells the folder, call packagesWillMove before anything moves and packagesDidMove once the library holds the new rows or the move has been put back.
- How others observe it: ReaderViewModel+LibraryUpdates applies only updates newer than the last it applied, without reloading the text or interrupting speech.
  A new path points the audio at the files where they are now, and new metadata reaches the metadata editor's starting values and Now Playing; the window title, Where Am I?, and announcements read the copy itself.
  Audio that is playing when a move is announced stops and releases its file, then plays on from the same place once the move ends.
  Paused audio loads again when it resumes: it is marked restartPlaybackBackendOnNextResume, as a change of the sound output marks a paused book (invalidatePlaybackBackendForAudioRouteChange()).
  Its next resume, Play's (resumeAudioPlayback(), resumeSpeechPlayback()) or a Where Am I? announcement's, plays it afresh from the cursor through restartPlaybackAtCursor(), which clears the mark.
  That plays an audiobook through restartAudioAtCursor(volume:), at its intended volume, and a text book through speakCurrentChapter(), always in direct speech.
  Meanwhile the audio set aside (audioPausedForMove) counts as playing (isPlaybackUnderWay), so playUnlessUnderWay() leaves it to the move's end and the Now Playing session reports it playing.
  Both pause(playingPauseSound:) and stopPlaybackForSleepTimer(waitingAt:characterOffset:) let it go with the other waits to play (stopAudioWaitingToPlay(because:)).
  And stop() lets it go (letGoOfAudioSetAsideForMove(because:)) and counts it as active.
  So a pause or stop made during an off-main move, as by Play/Pause, the AirPods, a recording or another book starting, or Release Media Controls, leaves the book as the listener left it when the move ends.
  Play pressed during the move waits in the same way (ST08): playAudioChapter() reads nothing while isPackageMoving, unless the book plays from its working copy.
  It sets the audio aside as a playing one is (audioPausedForMove, at its intended volume), so the reader shows Playing.
  The move's end plays the chapter from the cursor, from the package's new place, unless a pause or a stop has let it go.
  ReaderViewModel.resumeAudioAfterPackageMove() holds the audio as isChapterHeldByWhereAmI, at the volume it was set aside at, while Where Am I? speaks, and while the end sound of one that ended by itself plays (isWhereAmISpeakingOrSoundingItsEnd; [Where Am I announcement](reader-playback.md)).
  Audio playing from the book's working copy (below) reads none of the package's files, so it plays on undisturbed.
  LibraryBookUpdates.isPackageMoving(_:) is true for a book from its first packagesWillMove until its last packagesDidMove, whether a reader has the book open or not, so that a reader opened during a move knows too.
  A load never reads a package that is moving: beginReadingForLoad() reads nothing of it, and the load waits (loadWaitsForPackageMove) and starts again, from wherever the book is then, when the move is over.
  A load whose read met a move (loadMetPackageMove), or whose files the library gave another path meanwhile, starts again from where the book is now rather than show why it could not read them (loadAgainAfterMove(ofFilesReadAt:), logged as READER_LOAD_AFTER_MOVE), even when the move was put back.
  The cloud download's state check asks the same question (ReaderViewModel+CloudDownload).
  And a book that really is damaged still says so, in the same words.
  LibraryBookUpdates.textReplaced carries a text edit the library took, which the reader shows in place of its text ([Edited text](text-caches-rereads-edits.md)).
  Since ST01 it also carries the book's text read again by the launch's text cache batch while a reader has the book open ([content.md, the text cache](text-caches.md)).
  LibraryBookUpdates.transcriptReplaced carries an audiobook's transcript text, saved, edited, or deleted, which the reader shows in place of the text it had as the book plays on (ReaderViewModel+Transcript; [Transcripts](package-records-places-and-files.md)).

## Book pages
<!-- id: book-pages; keys: page markers, PageBreak, Go to Page, Next Page, Previous Page, page label, page position; src: TextMouth/Models/BookPages.swift, TextMouth/Models/ReaderPageWording.swift, TextMouth/Models/DocumentContent.swift, TextMouth/Parsers/MarkdownParser.swift, TextMouth/ViewModels/ReaderViewModel+Pages.swift, TextMouth/ViewModels/ReaderViewModel+Navigation.swift, TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift, TextMouth/ViewModels/SettingsViewModel.swift, TextMouth/Models/KeyboardShortcut.swift, TextMouth/Views/Reader/ReaderView.swift, TextMouth/Views/Reader/ReaderJumpPanels.swift, TextMouth/Views/Reader/PlaybackControlsView.swift, TextMouth/Views/Settings/SettingsView.swift, TextMouth/Views/Reader/BookReaderWindowView.swift, TextMouth/App/MenuCommands.swift, TextMouth/ViewModels/ReaderViewModel.swift -->

A book's pages (PG01 to PG04): where each page of the book begins, and the reader's moves by page.

- Owner: DocumentContent.pages, a BookPages built once in DocumentContent.init from the chapters' pages (Chapter.pages, which MarkdownParser reads from content.md's page markers: [Page markers in content.md](text-caches.md)) and never assigned afterwards, so it cannot go stale.
  A text edit or a rebuild gives the reader new content, and with it new pages.
  BookPages holds the PageBreaks (a label, the chapter's index, and the UTF-16 offset of the page's first whole word), sorted by chapter, offset, and the order given, and total, the N of "Page 12 of N": the largest label that is a whole number, else the number of pages.
  DocumentContent moves a page that a marker puts after its chapter's last word to the first word of the next chapter that has words, since the reader never rests at a chapter's end; after the book's last word such a page stays, a page without words.
  PagePosition, from BookPages.position(atChapter:offset:), describes a place by binary search: its label is "Page 12 of 300", "Before page i" before the first page, and empty for a book without pages.
  ReaderPageWording holds every sentence the pages say, shown and spoken alike.
- Who may write it: nothing writes pages; ReaderViewModel+Pages reads them.
  ReaderViewModel.nextPage(), previousPage(), and requestGoToPage() begin with pageCommandHasPages(): a reader whose content has not loaded does nothing and says nothing, since the book may have pages, and a loaded book without pages says ReaderPageWording.noPages and moves nothing.
  The commands nextPage() and previousPage() choose a page with nextPage(in:chapterIndex:characterOffset:isPassedOver:) and previousPage(in:chapterIndex:characterOffset:graceZone:isPassedOver:).
  The grace zone is 10 UTF-16 units, as Previous Heading's is, and both pass over a page that starts in a skipped section or at or after its chapter's end (withPassedOverCheck).
  Each of those moves goes through navigatePreservingReturnPosition and says ReaderPageWording.arrived(at:) with labelShown(afterMovingTo:).
  That is the label of the page holding the cursor once the move is done (currentPagePosition): the last of the pages that begin at that place, and so the page the status row and Where Am I? name, else the page's own label.
  The cursor is read after the move, since a move may stop short of a page's place (the book's last word is as far as the reader goes).
  ReaderViewModel.goToPage(typed:) takes JumpInputValidator.page(_:in:currentIndex:), which compares labels without case and takes a label that more than one page has at the first such page after the current one (currentPageIndex), else at the first, so it wraps after the last.
  JumpInputValidator.pageIndices(named:in:) is the one rule that picks a label's pages, which goToPageLabelIsRepeated(_:) and occurrence(ofPageAt:) count by too.
  ReaderViewModel.goToPage(typed:) navigates the same way and says jumpAnnouncement(toPage:at:), which once said the label it had matched, so a blank page that shares its place with the next said one page while the row named the other.
  With the cursor on the page asked for it says ReaderPageWording.jumped(to:occurrence:), the occurrence being which of the pages that carry its label it is, counted from 1 in book order and nil for a label of one page.
  With the cursor elsewhere it says where (ReaderPageWording.cursorPlace, from currentPagePosition) and why when the pages say, read from the pages and the skipped sections themselves and never from the cursor's being elsewhere, which after a jump while the book plays can have another reason.
  DocumentContent.pageHoldsWord(at:outside:) says whether the page holds a word of its own (hasNoWords: a blank page, which begins where the next page does, or a last page that begins after the book's last word, reached at that word).
  Outside the ranges the skipped sections take out (skippedRanges(inChapter:skipping:), the one place the page commands find them), it also says whether the page holds a word speech reads (isInSkippedSection).
  A jump while the book plays passes over a page that holds none to the next words speech reads, and a stopped book's cursor stays on it.
  With no reason in the pages, as when a text substitution deletes the page's words, cursorIs says only where the cursor is.
  A page asked for whose label other pages carry is named as which of them it is, so a reason never denies the words of another page of its label.
  The function goToPage(typed:) returns a refusal as the panel's error.
  requestGoToPage() counts goToPageRequests, which BookInfoBar answers by opening JumpToPagePanel, a JumpFieldPanel.
  A JumpFieldPanel takes the label it started at as no answer (JumpFieldOutcome.unchanged), unless goToPageLabelIsRepeated(_:) holds for it.
  The panel hands that to JumpFieldPanel.submitsUnchanged, and JumpFieldOutcome.taking(_:startedAt:submitsUnchanged:submit:) then submits the starting label.
  So Return goes to that label's next page, the only way on from one page of a label to the next without typing another first.
  The Page unit, SkipUnit.page, reaches nextPage() and previousPage() through performSkip(unit:forward:), and unit(after:bookHasPages:) passes it over in the unit cycle of a book without pages.

## Book pages: how others observe them
<!-- id: book-pages-observers; keys: page button, Go to Page, Navigation unit, SkipUnit, Where Am I? page label, ReaderHasPagesKey; src: TextMouth/ViewModels/ReaderViewModel+Pages.swift, TextMouth/ViewModels/ReaderViewModel+Navigation.swift, TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift, TextMouth/ViewModels/SettingsViewModel.swift, TextMouth/Models/KeyboardShortcut.swift, TextMouth/Views/Reader/ReaderView.swift, TextMouth/Views/Reader/PlaybackControlsView.swift, TextMouth/Views/Settings/SettingsView.swift, TextMouth/Views/Reader/BookReaderWindowView.swift, TextMouth/App/MenuCommands.swift -->

- How others observe it: BookInfoBar draws the page button from displayPagePosition, the throttled mirror of the cursor, while SettingsViewModel.showsPageInReader is on and the book has pages.
  Where Am I? puts currentPagePosition.label after the heading number while saysPageInWhereAmI is on (whereAmIPageLabel).
  And the Navigate menu's Go to Page… is enabled by the scene value ReaderHasPagesKey (readerHasPages), which BookReaderWindowView publishes.
  Its default is ShortcutAction's (Option-Command-G).
  Moving from page to page is the Page unit's, through nextPage() and previousPage(); there are no separate Next Page and Previous Page commands.
  The playback bar's three unit pickers (PlaybackControlsView: the shared Navigation unit, or the separate Forward navigation unit and Backward navigation unit) list ReaderViewModel.navigationUnitChoices(keeping:) for the unit each shows.
  The list is every SkipUnit but Page when the book has no pages and Page is not that unit (navigationUnitChoices(bookHasPages:keeping:), static for its tests).
  A unit in force stays in its list, since a picker whose selection is not among its choices shows no value, as a global default of Page leaves a book without pages with Page in force.
  Settings' four skip pickers choose the units of every book at once, and list every SkipUnit.

## A closed reader
<!-- id: closed-reader; keys: close window, release memory, window lifetime, retained reader, leak; src: TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/Services/SpeechService.swift, TextMouth/Views/Reader/BookReaderWindowView.swift, TextMouthProductionTests/ViewsAndWindowsClosedWindowTests.swift -->

A closed reader: what a reader keeps after its window closes.

- Owner: the reader itself.
  SwiftUI keeps a closed reader window, and with it the window's ReaderViewModel, for the rest of the session, as AppKit keeps every closed window that was ever key, so a closed reader must not hold what grows with its book.
- Who may write it: close(), once.
  After it ends the reader's cloud work, stops playback, saves the position, and releases its sessions, it lets go of everything that grows with the book (releaseWhatGrowsWithTheBook):
  - its subscriptions;
  - the look-ahead;
  - the text speech was speaking and the rendered audio of the chapter last played (SpeechService.releaseSpeech(), which makes no engine to do it);
  - the offset maps;
  - the text window shown;
  - an audiobook's lists of files and clips; and
  - the book's content with its headings.
  An audiobook's player and item went with stop(), which also empties the prepared speech.
  A background preparation that finishes afterwards keeps nothing.
  What is left is the reader and its services, whose size does not depend on the book.
- How others observe it: nothing reads a closed reader; ViewsAndWindowsClosedWindowTests checks that it keeps nothing that grows with its book.

## Getting a book from the cloud
<!-- id: getting-book-from-cloud; keys: iCloud, dataless file, download progress, ReaderCloudPhase, sync wait, BookCloudStates; src: TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/Views/Reader/ReaderView.swift, TextMouth/Services/ReaderWorkingCopy.swift, TextMouth/Models/CloudStorageContract.swift -->

Getting a book from the cloud: a reader's download, in a library in a cloud location.

- Owner: ReaderViewModel.cloudPhase (a ReaderCloudPhase: downloading, not downloaded after a cancel, failed, or waiting for sync), which ReaderView shows in place of the book (ReaderCloudPhaseView).
  The other owner is ReaderViewModel.cloudSession (a ReaderCloudSession): where the library was found, the download under way and what it is for, its announcements, and the working copy.
- Who may write it: ReaderViewModel+CloudDownload. loadContent reads where the library lives and, in a cloud location, the book's state, off the main thread; outside one it reads the book in the same step, as it always has.
  In a cloud location continueOpening loads a book that is on this Mac, downloads one with files in the cloud first (startDownload, iterating BookCloudStorage.download), or stops at waiting for sync.
  The function loadDownloadedBook reads the book inside DatalessFiles.withoutDownloading once LocalBookFiles.requireOnThisMac finds every file here.
  A read refused because a file went back to the cloud goes through the download once more, and a second refusal stops with the reason.
  For an audiobook without a working copy, chapterFilesReadyToPlay downloads the book before a chapter whose file is only in the cloud plays, the reader showing Playing meanwhile, and a failure stops at that chapter with an alert offering Try Again.
  Play/Pause pauses a reader waiting so (isWaitingForChapterDownload).
  A pause, whether from Play/Pause or a sleep timer that runs out, stops the waiting (stopAudioWaitingToPlay(because:), through stopWaitingForChapterDownload), so the chapter never starts by itself afterwards.
  A move of the book's package stops it too, but sets the audio aside (audioPausedForMove), so the chapter plays, or downloads again, from the package's new place once the move ends.
  Cancel, Download, Try Again, and closing the reader end or restart the work.
- How others observe it: the download's progress is recorded in BookCloudStates.shared between beginDownload and endDownload, so the library list shows it too, and after a cancel, a pause, or a close the state found afterwards is recorded.
  A part of the one file left that the sync service publishes gives the bar its percentage, and with it the milestones: VoiceOver hears the download start, 25, 50, and 75 percent, or the time waited every 30 seconds while there is no percentage, and the end.
  ReaderCloudWording words everything the view shows and speaks.
- A placeholder of library sync opens through the same download view: StoreBookStorage answers its state and fetches its files from the sync folder ([Library sync: books and rules](library-sync-store.md)).

## The cloud working copy
<!-- id: cloud-working-copy; keys: iCloud audiobook, APFS clone, local copy, playbackURL, package copy, MachineLocalPaths; src: TextMouth/Services/ReaderWorkingCopy.swift, TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/ViewModels/ReaderViewModel+LibraryUpdates.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/Models/CloudStorageContract.swift -->

The working copy: the files an open audiobook in a library in a cloud location plays.

- Owner: ReaderViewModel.cloudSession.workingCopy, a ReaderWorkingCopy: a copy of the book's package in a folder of its own (the book's ID and a UUID) in MachineLocalPaths.workingCopies, made by ReaderWorkingCopies.shared.
- Who may write it: loadDownloadedBook makes it, off the main thread, once the book is on this Mac: FileManager.copyItem, which clones the package on one APFS volume, one copy at a time under a lock, the session's first copy sweeping away any a crash left.
  A package on another volume, a failed clone, or a clone holding a file only in the cloud gets no copy (WORKING_COPY_SKIPPED), and the book plays from its package with each chapter checked first.
  A move of the book's files calls sourceMoved(to:), through followMovedFiles, and restarts nothing.
  Closing the reader deletes the copy off the main thread.
- How others observe it: playback reads the copy through playbackURL(for:), which maps a path in the package to the same place in the copy, where each chapter's files are chosen (chapterAudioSource(forChapterAt:) and audioClipChain(forChapterAt:)).
  The audiobook's tags are read from it too.
  The function pauseAudioForPackageMove leaves audio playing from it alone.
  Positions, bookmarks, and settings still save to the package through the library.

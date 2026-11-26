# Windows
<!-- id: windows-state; keys: scene, WindowGroup, NSWindow, Library window, reader window, router; src: TextMouth/Services/LibraryWindowRouter.swift, TextMouth/Views/ContentView.swift, TextMouth/Views/Reader/BookReaderWindowView.swift, TextMouth/Platform/macOS/App/TextMouthApp.swift -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## App-wide actions
<!-- id: app-wide-actions; keys: dispatch, front window, Finder double-click, window list, File menu, new window, Dock icon; src: TextMouth/Services/LibraryWindowRouter.swift, TextMouth/Platform/macOS/App/AppDelegate.swift, TextMouth/App/MenuCommands.swift, TextMouth/Views/ContentView.swift, TextMouth/Views/Reader/BookReaderWindowView.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/Views/Library/DataDirectoryUnavailableView.swift, TextMouth/ViewModels/DataDirectoryMoveProgress.swift -->

App-wide actions.

- Owner: LibraryWindowRouter.shared.
  It keeps weak references to every open Library window, each with its way of taking an action, and to every reader window, each with its way of opening another reader, and decides once which window takes each GlobalAction.
  An action that no open window can take waits while a Library window opens.
- Who may write it: Library windows register and unregister themselves (ContentView); reader windows register (BookReaderWindowView); AppDelegate supplies the way to open a Library window.
  Menu commands, keyboard shortcuts, finished books, and imports that open their book (LibraryViewModel.readerOpener) post notifications that the router listens for on the default center from launch (GlobalAction.routedNotificationNames), and AppDelegate hands over the files Finder opens.
  Each becomes one call of route(_:).
- How others observe it: only the chosen window performs the action.
  While the library is unavailable or moving, a Library window refuses the actions that add or open books and says why, on its Library Not Available screen or in the move's sheet (DataDirectoryUnavailableText.refusal(of:) and DataDirectoryMoveWording.refusal(of:)).
  Files opened from Finder during a move are imported once it ends.

## A reader window's book changes in place
<!-- id: reader-window-book-switch; keys: switch window, in-place book change, one window per book, window reuse, next book in window, open books registry, sleep timer hand over; src: TextMouth/Platform/macOS/App/TextMouthApp.swift, TextMouth/Views/Reader/BookReaderWindowView.swift, TextMouth/Services/SleepTimerRegistry.swift, TextMouth/Models/NextBookWindow.swift, TextMouth/ViewModels/ReaderViewModel+NextBookWindow.swift, TextMouth/Services/WindowSwitchRequests.swift, TextMouth/Platform/macOS/Views/SwitchedWindowFocus.swift, TextMouth/Platform/macOS/Views/VoiceOverFocus.swift, TextMouth/Services/LibraryWindowRouter.swift, TextMouth/ViewModels/LibraryViewModel+BookOperations.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/Services/SleepTimerService.swift, TextMouth/Models/ListeningOptions.swift, TextMouth/Models/SettingsPolicy.swift, TextMouth/ViewModels/ReaderViewModel+SleepTimerHandOver.swift, TextMouth/Services/BookTextEditing.swift, TextMouth/Services/NowPlayingService.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/ViewModels/SettingsViewModel.swift -->

A reader window's book changing in place (0.2.5): listening goes on to the next book in the window you are in, and the registry of open readers.

- Owner: the scene, the "Book Reader" WindowGroup(for: UUID.self) in Platform/macOS/App/TextMouthApp.swift, whose binding $bookID is the window's one book.
  It shows ReaderWindowContent (Views/Reader/BookReaderWindowView.swift), which hands BookReaderWindowView a showBook closure that sets $bookID, and gives the view .id(bookID).
  A new value is a new view identity, so SwiftUI makes a new @StateObject ReaderViewModel in the same NSWindow and tears the old one down.
  ReaderWindowContent sits above that identity and holds the window's sleep timer, a WindowSleepTimerHolder, as a @StateObject made once for the window.
  The holder is an ObservableObject that holds a SleepTimerService and publishes nothing, so a tick of the timer does not run the content's body.
  The content passes the timer to each BookReaderWindowView, which gives it to the reader it makes (ReaderViewModel.init(sleepTimer:)), so the window keeps its timer through the switch and the new reader takes it over (claimSleepTimerHandOver(), in [Timers and statistics](timers-and-statistics.md)).
  A window of another book, or one opened for the next book, has a timer of its own, which takes the running state of the one it is to go on from.
  The view stores the closure and gives it to its reader as nextBookWindowSwitcher as the reader is made (makeReader); a reader with no scene to set it in, as one made by a test, has none and always opens a new window.
  The registry of open readers is the library's: LibraryViewModel.openBookIDs, the books a reader is open for, counted per book (openReaderCounts).
  A reader registers its book as it is made (registerOpenBook(_:)) and unregisters it as it closes (unregisterOpenBook(_:)), and a book stays in openBookIDs until its last reader closes, so two readers of one book leave it open until both have closed.
  It publishes `openBookIDs` a turn late (see [The registry of open readers and when it publishes](#the-registry-of-open-readers-and-when-it-publishes)).
  It is the one registry there is: the sleep timer's last-resort deadline asks it (SleepTimerService.heldTimerDeadline, in [Timers and statistics](timers-and-statistics.md)), and so does showNextBook, to tell whether the next book is open in another window.
- Who may write it: the reader, in ReaderViewModel+NextBookWindow, once for every move to another book (the end of a book going on, Next and Previous in Reading List, Next and Previous in Folder).
  It calls showNextBook(_:under:openingANewWindowWith:), which asks the pure NextBookWindowRule (Models/NextBookWindow.swift) what to do, and does it.
  The choice is NextBookWindowRule.choice(options:global:globalEndOfBook:).
  The feed's or plain folder's own ListeningOptions.nextBookWindow when it has one and its items go on (ListeningOptions.goesOn(under:); a dimmed choice is not in effect).
  Else the global SettingsViewModel.nextBookWindow (SettingsPolicy.nextBookWindow, the config.json key nextBookWindow, defaulting to This Window).
  A move through the reading list passes no options and follows the global one (folderMoveWindowChoice, readingListMoveWindowChoice).
  NextBookWindowRule.action(choice:isBusy:canSwitch:nextBookIsOpenElsewhere:) gives:
  - .openANewWindow, today's post (.continueToNextBook or .openBookWindow), whenever the choice is A New Window, the reader has no switcher, or switchingTheWindowCouldLoseWork holds:
    - the reader has closed (hasClosed) or its window is not on screen,
    - a sheet or alert is attached, or a field editor is the first responder (windowStanding, a NextBookWindowStanding read from AppKit, which a test sets through windowStandingOverride; a minimized window, and every window of a hidden app, count as on screen),
    - this book's text is being edited in another app (BookTextEditSessions.isEditing), or the library is moving or unavailable (dataDirectoryMove, dataDirectoryUnavailability);
  - .switchThisWindow, which sets hasSwitchedWindow, leaves a WindowSwitchRequest for the book (WindowSwitchRequests.shared, a ReaderRequestStore), and calls the closure;
  - and .bringTheOpenWindowForwardThenClose when the book is open in another window already, which posts as today and closes this reader's hostWindow on the next turn of the main queue, so no two windows show one book.

  The window choice is read when the book is asked for, never earlier, after every request for the book (autoplay, reading list) has been made, which the new reader claims once loaded.

### How a switched window is observed
<!-- id: reader-window-switch-observed; keys: onDisappear, onWindowFound, registerReaderWindow, readerID teardown, VoiceOver focus, markBookOpened; src: TextMouth/Views/Reader/BookReaderWindowView.swift, TextMouth/Services/LibraryWindowRouter.swift, TextMouth/Services/NowPlayingService.swift, TextMouth/Services/SleepTimerService.swift, TextMouth/Services/WindowSwitchRequests.swift, TextMouth/Platform/macOS/Views/SwitchedWindowFocus.swift, TextMouth/Platform/macOS/Views/VoiceOverFocus.swift -->

- How others observe it: BookReaderWindowView's onDisappear leaves the window registered with LibraryWindowRouter when the reader has switched its window (hasSwitchedWindow), and closes the reader as before.
  The new view registers the same NSWindow in onWindowFound, and registerReaderWindow(_:openReader:) replaces any earlier entry for a window, so an ordinary close unregisters as always. markBookOpened runs in the new view's onAppear, and reader windows are still not restored.
  The teardown of the old reader is its own.
  NowPlayingService, the media coordinator, and the window's SleepTimerService key everything by readerID, so the old reader's close() clears, pauses, and unregisters only itself, and stops the window's timer only if it still owns it (the reader that took the window over owns it already).
  A switched window is the same window, which nothing announces, so the reader that takes it over:
  - claims the switch request in attach(to:) once its window is found (a reader made for a new window finds none)
  - and sees to the window's focus once its book has loaded (placeFocusAfterSwitchIfDue(), through windowAwaitingFocusAfterLoad):
    - SwitchedWindowFocus.place(in:) notes StandardVoiceOverFocusTriggerView.focusPostCount(of:) as the load ends,
    - and 1.6 seconds later (checkDelay) acts only in the key window and only when no trigger posted in that window since the load (shouldPlace(postsAtTheLoad:postsNow:windowIsKey:)),
    - finding the element marked voiceOverFocusID and placing focus once (placeFocus).

  The play button's own trigger does the same when it runs, so VoiceOver is never told twice; that a switched window's focus lands as a new window's does has not been checked by hand with VoiceOver.

### The registry of open readers and when it publishes
<!-- id: open-readers-registry-publish; keys: openBookIDs, isBookOpenNow, openBookIDsNow, openReaderCounts, StateObject, AttributeGraph, B22, publish; src: TextMouth/ViewModels/LibraryViewModel+BookOperations.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/Views/Reader/BookReaderWindowView.swift, TextMouthProductionTests/RunLoopWaiting.swift -->

A reader registers its book as it is made, and SwiftUI makes it inside its update, in the autoclosure of a `@StateObject`.
Changing another object's `@Published` state there starts a transaction in the middle of the update, which aborts the app in AttributeGraph (B22: opening a ZIP from Finder as TextMouth started).
So the registry has two faces:
- The truth, which changes at once: `openReaderCounts`, and FR04's audio activity (`audioEditActivity.setOpenInReader`), which `registerOpenBook(_:)` and `unregisterOpenBook(_:)` write.
- The published `openBookIDs`, which follows on the main queue's next turn.
  One publish serves every change made in a turn, reading the counts as they stand then, so a register followed by an unregister leaves no book behind; `openBookIDs` is set only when it changes.

Every check that decides something asks the truth, never the published set: `isBookOpenNow(_:)` for one book, and `openBookIDsNow` for all.
Moving, deleting, and editing the audio of a book, the cloud's removal of a download, the text cache's order, a feed's open-in-reader rule, the sleep timer's held-for-book check, and `showNextBook` all do.
What observes `openBookIDs` (the live reading positions, the audio activity mirror, a feed's publisher) is content to be one turn late.

The rule for new code: a model built in a `@StateObject` autoclosure (a reader, here) must not change another object's `@Published` state in its `init`, or in anything the view's `makeReader` calls.
Do it on the next turn (`DispatchQueue.main.async`), as the reader window does for a missing book's held sleep timer (`BookReaderWindowView.makeReader`), or make the truth synchronous and the published copy follow, as this registry does.
`ConfigService`'s `lastOpenedBookID` is written in the registration, which is safe only because no view observes `ConfigService` and its two subscribers filter to other fields.
A test that reads `openBookIDs` waits for the turn with `waitForMainQueueTurn()` (see [Tests in Spanish](../../developer/testing.md#tests-in-spanish)).

## Each Library window's place
<!-- id: library-window-place; keys: view picker, number keys, view switch, navigation stack, deleted folder, window state, per-window; src: TextMouth/Views/ContentView.swift, TextMouth/Views/Library/LibraryView.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/ViewModels/LibraryViewModel+Views.swift, TextMouth/Models/LibraryViewPickerWording.swift, TextMouth/Models/LibraryViewDefinition.swift, TextMouth/Models/LibrarySortState.swift, TextMouth/Models/FolderNavigationHistory.swift, TextMouth/Models/LibraryViewDefinitionStore.swift, TextMouth/Models/LibraryViewDefinitionList.swift, TextMouth/Models/KeyboardShortcut.swift, TextMouth/App/MenuCommands.swift -->

Each Library window's place.

- Owner: the window's own views: its folder path, view, search, selection, and back and forward history (FolderNavigationHistory).
  A second Library window keeps its own.
  The view is a LibraryViewID (Models/LibraryViewDefinition.swift): one of the five categories, a LibraryCategory (ViewModels/LibraryViewModel.swift: Folders, All Items, Unopened, Recently Opened, and Reading List), the Feeds view, or a view the listener made, by its UUID.
  And the Library's views, their order, and their settings are in LibraryViewDefinitionStore ([Editor, library, feed, and transcription preferences](preferences.md)).
  The window's identity of its view is ContentView's @State viewID, an optional that nothing saves:
  - nil until the window first appears, when it takes the first view the pop-up offers (LibraryViewModel.shownView(_:in:center:), Folders as the views ship),
  - and kept afterwards, even when the view is hidden in Settings or lists nothing, until the listener chooses another, so nothing moves under VoiceOver's cursor.

  LibraryView receives it as the binding shownViewID and makes a LibraryLocation of the view it names and the folder path (Models/LibrarySortState.swift), which every list, title, and sort of the window follows.
  A view deleted while the window shows it is no longer in the list: shownView falls back to the first view offered, LibraryView.followDeletedView sets shownViewID to it, and the window announces LibraryViewPickerWording.deletedView(nowShowing:), "The view this window showed was deleted.
  It now shows Folders." from itself.
  Unopened (LibraryCategory.unopened) replaced No Folder (noFolder), which listed the root's books, and the type's decoder reads a category saved under No Folder's name as Unopened.
  LibraryCategory.recent is named "Recently Opened" since FR13, in the picker and the window's title alike; the decoder reads the former name, Recent (formerRecentName), as it, and its sort is still saved under __recent__.
  The picker is a pop-up button, the View pop-up (LibraryView.viewPicker(offering:)), whose items are the names of the views LibraryViewModel.offeredViews(in:current:center:applicable:) offers.
  VoiceOver reading it as LibraryView.categoryPickerLabel, "Library view", the constant keeping the name the tests used, and its width bounded by LibraryViewPickerWording.pickerWidthLimit.
  Go to View 1 to Go to View 9 (ShortcutAction.goToView1, Command-1 to Command-9) and the Library menu's Go to View submenu post goToLibraryView with the number, which LibraryViewModel.goToView(numbered:in:folderPath:center:) answers in the window that takes commands.
- Who may write it: the window's own navigation, and, for its folder, the library's folders changing elsewhere.
  ShownFolderFollowing (Views/Library/LibraryView.swift) notes, by ID, the folder the window shows each time it shows another.
  When the library's folders change, as another window deletes, renames, or moves that folder, it puts the window where FolderSheetNavigation.folderPath(showing:folderID:in:) says:
  - the same path while a folder is there,
  - the folder's new path when it is there under another,
  - and otherwise the nearest folder above it still in the library, or the top level (the feed follow-ups after FR14).

  Nothing moves while the library's index is being recovered, when the list of folders is provisional.

## The list a Library window shows
<!-- id: library-window-list; keys: table, book row, reorder, performance, row identity, sort order; src: TextMouth/Views/Library/LibraryView.swift, TextMouth/Views/Library/LibrarySubviews.swift, TextMouth/Models/LibraryAudioCommand.swift, TextMouth/Models/EndOfBookWording.swift, TextMouth/Models/LibraryInfoWording.swift, TextMouth/Views/Library/LibraryInfoRow.swift -->

The list a Library window shows.

- Owner: LibraryView, which reads its list from the model once per draw ([Lists Library windows show](library-index.md)) and passes it down.
  Each row is a LibraryBookListRow, the unit SwiftUI compares: equal on everything it shows (LibraryBookListRow.==, which compares its book's live position object by identity), never on its actions (LibraryBookRowActions), which read the current state when they run.
  So one changed book redraws one row, and SwiftUI builds a row's context menu only when the row has something new to show.
  A book resting at its end (Book.restsAtEnd, P07) says EndOfBookWording.finishedProgress, "Finished", on screen and to VoiceOver, in place of its percent, with no time left (BookRow.progressText(for:), spokenProgress(for:besideDownloadPercentage:), and timeRemaining(for:wpm:)).
  And Speak Info's facts take the row's words (BookInfoFacts, from LibraryInfoRow.swift).
  Move Book Up and Move Down come from the order the list shows (LibraryManualMoves), a folder's manual order or the reading list's.
  LibraryManualMove names a row's Move Up and Move Down once, for its context menu items and its VoiceOver actions.
  LibraryManualMoves.offered lists those a single book's row offers, only the moves its book can make, which BookRow puts first among its actions (FR09), running them through LibraryBookRowActions.moveSayingPlace, while the context menu's run moveInManualOrder.
  A window's two selections, the list's own and edit mode's checks, select together the listed books LibrarySelectionPolicy.selected(in:native:edit:) returns, in the list's order.
  Those Move, Remove, and the reading list's commands act on (selectedBooks), which the edit bar (EditModeBar) and the Edit button's hint both count, folder and feed rows and books no longer listed left out (REV13).
  EditModeBar.offersDeselectAll(selectedCount:totalCount:) makes its Select All a Deselect All only while a book is listed and every one is selected, and Select All is dimmed while none is.

## Letter navigation in the Library list
<!-- id: library-letter-navigation; keys: type to find, typed letters, skip The, find by title, row jump, table keyboard; src: TextMouth/Views/Library/LibraryTitleTyping.swift, TextMouth/Models/TitleTyping.swift, TextMouth/Views/Library/LibraryView.swift, TextMouth/Services/KeyboardShortcutManager.swift, TextMouth/Models/LeadingArticles.swift, TextMouth/Views/Feeds/FeedLibraryPresentation.swift, TextMouth/ViewModels/LibraryViewModel+SortAndOrder.swift, TextMouth/Models/LeadingArticleWording.swift, TextMouthProductionTests/TitleTypingTests.swift, TextMouthProductionTests/LibraryTitleTypingTests.swift, TextMouthProductionTests/LibraryTypeSelectBehaviorTests.swift, TextMouthProductionTests/LibraryTypeSelectProbeTests.swift -->

Letter navigation in the Library list (the Leading articles setting): typing a title's first letters past its leading article.

- Owner: LibraryTitleTyping (Views/Library/LibraryTitleTyping.swift), a ViewModifier LibraryView puts on its list, inside a ScrollViewReader, with:
  - the setting read once for the draw (articles),
  - the window (hostWindow),
  - the list's selection (selectedBookIDs, bound),
  - and a rows closure, LibraryView's typedRows(folders:books:allBooks:feedID:articles:), called at each key and not at each draw:
    - the Folders section's folders by their names as written (TypedRow(id:name:)),
    - the Feeds section's feeds (LibraryFeedsSectionRows.rows),
    - and the books, which LibraryViewModel.typedRows(of:) keeps folded ([Titles as the lists read them](library-index.md)), in a feed's folder in the order FeedFolderListing.make lists them, items not downloaded left out.

  It holds a TitleTypingSearch (Models/TitleTyping.swift: the letters typed and when, which add up while each key comes within interval, 1.25 seconds, of the one before) and a count of rows reached.
  In the first choice (LeadingArticles.typesWithoutArticles false) every key is ignored and the list's own type select, AppKit's, works as it always did.
- Who may write it: its onKeyPress, for the .down and .repeat phases, in take(_:scrollingWith:), which acts only while:
  - articles.typesWithoutArticles
  - and tableHasKeyboard(in:) (the window's first responder is an NSTableView, so the Library's search field or a button keeps its own keys; always true off the Mac, where the setting is never on).

  A key that is not typing (isTyping(_:modifiers:): no Command or Control, and no control, private-use, or format scalar, so a function key is none) ends the search, releases the Space claim, and goes on to the list.
  A held key's repeat is handled and does nothing.
  A Space is taken only while the search has letters and TitleTypingSpaceClaim.shared.acceptsSpace(in:at:) says the window claimed it, and extends the search however late the clock is.
  TitleTyping.firstRow(reachedBy:in:selection:isNewSearch:showingInverted:) finds the row.
  The first row, from TitleTyping.searchStart, that TypedForms.begins(with:showingInverted:articleAloneCounts:) says the letters reach.
  TitleTyping.searchStart is the top with nothing selected, the selected row for a search that added letters, and the row after the last selected one, wrapping, for a new search, as AppKit's own type select, measured by LibraryTypeSelectProbeTests, searches.
  The letters reach a row when the filing text begins with them, or, past the article (more letters typed than the article and its space), the title as written does, or, while showingInverted (articles.sortsWithoutArticles), the inverted title does.
  The match replaces the selection, proxy.scrollTo(row) takes it to the table (on GitHub's runner a far row the list had never drawn stayed unselected without it).
  And a count of reaches starts .task(id:), scrollSelectedRowIntoView(), which looks at the window's table up to scrollLooks (4) times, scrollLookDelay (30 ms) apart, and scrolls the selected row whole with scrollRowToVisible (showsSelectedRow(of:), rowShowsWhole(_:in:)).
  Since SwiftUI's scrollTo and AppKit's type select both fell short of a row far down (row 62 selected with rows 47 to 54 in view).
  A key that reaches no row leaves the selection and says nothing.
  After each letter, TitleTyping.spaceGoesOn(after:in:showingInverted:) says whether a row goes on with the letters and a space ("the " into "The Hobbit", as TypedForms.begins with articleAloneCounts), and the claim is made until the key's time plus interval, or released.

### How the letter navigation is observed and tested
<!-- id: library-letter-navigation-observed; keys: selection, VoiceOver, space claim, acceptanceSlack, type select tests; src: TextMouth/Views/Library/LibraryTitleTyping.swift, TextMouth/Services/KeyboardShortcutManager.swift, TextMouthProductionTests/TitleTypingTests.swift, TextMouthProductionTests/LibraryTitleTypingTests.swift, TextMouthProductionTests/LibraryTypeSelectBehaviorTests.swift, TextMouthProductionTests/LibraryTypeSelectProbeTests.swift -->

- How others observe it: the selection, which VoiceOver follows and reads as it reads any row; nothing is announced for a reach.
  TitleTypingSpaceClaim (in LibraryTitleTyping.swift, @MainActor, TitleTypingSpaceClaim.shared) holds the claiming window weakly and the time, by TitleTypingSpaceClaim.clock (system uptime; a test sets its own).
  And KeyboardShortcutManager.handleKeyEvent asks it before the dispatcher (key presses, below).
  A Space with an NSTableView as the first responder, and takesSpace(in:) true, is returned unhandled to the list, so it is not Play / Pause.
  The list accepts it acceptanceSlack (0.5 seconds) past the claim's time, since the manager and the list read the clock a moment apart.
  The words of the pop-up are LeadingArticleWording's.
- Tests:
  - TitleTypingTests (folding, the forms a title is reached by, the search's clock, which row, the Space),
  - LibraryTitleTypingTests (hosted: the letters typed into a real window's list in each choice, the Space claim, the scroll into view, the search field left alone),
  - and LibraryTypeSelectBehaviorTests and LibraryTypeSelectProbeTests (what AppKit's type select does; developer testing, in [Testing](../../developer/testing.md)).

## A closed window
<!-- id: closed-window-cost; keys: close window, hidden window, memory use, window release, reopen, Dock click; src: TextMouth/Views/Library/LibraryView.swift, TextMouth/Views/Reader/BookReaderWindowView.swift, TextMouth/Platform/macOS/Views/VoiceOverFocus.swift -->

A closed window.

- Owner: the window's views.
  SwiftUI keeps a closed window and its views for the rest of the session, so a closed window must cost nothing.
  A closed Library window shows ClosedLibraryWindowPlaceholder, the word Library, in place of its list, from NSWindow.willCloseNotification until the window is key or visible again, as when SwiftUI shows it again for a book opened from Finder.
  A closed reader lets go of its book ([A closed reader](reader.md)).
  A VoiceOver focus request holds its window weakly and searches only a window still showing content, so a window closed within the request's delay is neither kept alive nor searched.

## Menus
<!-- id: window-menus; keys: menu bar, dimmed command, hidden menu, Playback menu, Record window menus, VoiceOver menu bar, command enabled; src: TextMouth/Platform/macOS/Services/MenuVisibilityManager.swift, TextMouth/Platform/macOS/Views/Recording/RecordingWindowController.swift, TextMouth/App/MenuCommands.swift, TextMouth/Views/Transcription/TranscriptCleanupCommands.swift, TextMouth/Views/AudioEditor/AudioEditorCommands.swift, TextMouth/Platform/macOS/Views/AudioEditor/AudioEditorEditMenu.swift, TextMouth/Platform/macOS/Views/AudioEditor/AudioEditorWindowController.swift, TextMouth/Views/Export/BookExportPresentation.swift, TextMouth/Views/Feeds/LibraryFeedsWindowSupport.swift, TextMouth/Models/KeyboardShortcut.swift, TextMouth/Platform/macOS/App/AppDelegate.swift, TextMouth/Models/TranscriptionWording.swift, TextMouth/Views/Library/LibraryView.swift, TextMouth/Models/BookExportWording.swift -->

Menus.

- Owner: MenuVisibilityManager, owned by AppDelegate.
  It hides the context-specific menus, such as Playback and Navigate, when the key window cannot use them, so VoiceOver never lands in an empty menu.
  The Record window counts as Settings does: its identifier, "new-recording", names neither a Library nor a reader window (detectWindowType returns nil for it), so every context-specific menu is hidden while it is in front.
  The audio editor's windows, whose identifier is "audio-editor", count the same way.
  BookCommands (App/MenuCommands.swift) adds the Book menu, one of the reader's menus (readerMenuTitles).
  Its Transcribe Audio… item is titled Retranscribe Audio… while canDeleteBookTranscript says the key reader's book has a transcript (TranscriptionWording.transcribeCommandTitle(hasTranscript:)).
  Its commands are enabled through the scene values the key reader publishes (canEditBookText, canTranscribeBookAudio, canCleanUpBookTranscript, canDeleteBookTranscript, canEditBookAudio, and canMoveBookToLibrary), so they stay available while VoiceOver reads the text without keyboard focus.
  NavigationCommands enables the Navigate menu's Next in Reading List and Previous in Reading List the same way, through the readsFromReadingList scene value ([Reading from the reading list](reader-navigation.md)).
  BookCommands also adds Export… to the File menu, after its import and export group.
  ExportCommandRouting.exportFromWindowInFront posts exportBooks when a Library or reader window, or a sheet over one, is key, and that window exports its selection or its book (WindowCommandRouting).
  Otherwise VoiceOver hears BookExportWording.noWindowOpen or noWindowInFront.
  LibraryCommands adds the feed commands to the Library menu:
  - Add Feed…, Refresh All Feeds, Import OPML…, and Export OPML…, which the Library window that takes commands runs ([The feed reader's interface](feeds-interface.md)),
  - Speak Info and Speak Full Info, which post speakInfo and speakFullInfo ([Speak Info](windows-sheets.md)),
  - Speak Import Progress, which posts speakImportProgress ([Import progress](imports.md)),
  - Speak Download Progress, which posts speakDownloadProgress ([Feed downloads' progress](feeds.md)),
  - Add to Reading List and Remove from Reading List, which post addToReadingList and removeFromReadingList ([The reading list](library-index-reading-feeds.md)),
  - Sync Now, which calls SyncCenter.shared.syncNow(), and Keep on All Devices and Stop Keeping on All Devices, which post keepOnAllDevices and stopKeepingOnAllDevices, all three shown only while sync is on ([Library sync](library-sync.md)),
  - and Folder or Feed Settings, which posts showFolderOrFeedSettings ([The Folder Settings and Add to Library sheets](windows-sheets.md)).

  PlaybackCommands offers Where Am I?
  Full Summary after Where Am I?, posting whereAmIFull ([Where Am I announcement](reader-playback.md)); no menu item shows a double press, so the two full summaries' menu items show no key.
  FileCommands, PlaybackCommands, and LibraryCommands give each menu command whose key is a shortcut action (ShortcutAction.keyEquivalentActions) View.menuCommandKey(_:shortcuts:frontKind:).
  The item shows the key in force while its action's scope admits the kind of window in front (FrontWindowKind.shared, ShortcutScope.admitsMenuCommand(in:), which admits every scope while no window is in front), and otherwise shows no key and is dimmed, so the key reaches that window's own shortcut.
  The Record window's Record, Pause or Resume, and Stop buttons take their keys from StoredKeyEquivalents, and their hints name the keys in force ([Keyboard shortcuts](preferences-shortcuts.md)).
  The File and Library menus' New Recording… and the Library menu's Add Feed… are titled by their actions (ShortcutAction.newRecording.title, ShortcutAction.addFeed.title), one name for the menu, the Shortcuts tab, and config.json.
  The Edit menu stays AppKit's: in an audio editor window its Undo, Redo, Cut, Copy, Paste, and Select All are the editor's ([The editor window](audio-edits.md)).

## Key presses
<!-- id: key-press-actions; keys: hotkey, keystroke, press twice, local monitor, edit field, Option key, Shift key; src: TextMouth/Services/KeyboardShortcutManager.swift, TextMouth/Services/ShortcutPressDispatcher.swift, TextMouth/Models/TextEditingKeys.swift, TextMouth/Models/KeyboardShortcut.swift, TextMouthProductionTests/TextFieldEditingKeysTests.swift, TextMouthProductionTests/ShortcutPressDispatcherTests.swift, TextMouth/Views/Library/LibraryView.swift, TextMouth/Models/ShortcutEdits.swift, TextMouth/Platform/macOS/Services/MenuVisibilityManager.swift, TextMouth/Views/Library/LibraryTitleTyping.swift -->

Key presses: which action a key press is, single or double, and the keys a text field keeps (B03).

- Owner: KeyboardShortcutManager (Services/KeyboardShortcutManager.swift), which every window shares.
  Its local event monitor sees each key press before the menus do and hands it to its ShortcutPressDispatcher (Services/ShortcutPressDispatcher.swift, FR12's branch B), which matches it against the manager's bindings, every action's keys in force ([Keyboard shortcuts](preferences-shortcuts.md)).
  A press it takes never reaches the menus, but a key equivalent's key is never the manager's.
  No other action holds it, once or twice, in a kind of window where its command works (KeyClaims), and elsewhere its menu item shows no key and is dimmed (menus, above), so Shift-Command-T is New from Text…'s in a Library window and Show Sleep Timer's in a reader (FR12's branch E).
- Who may write it: no one but the manager. handleKeyEvent(_:keyWindow:firstResponder:) takes each key-down with the key window and its first responder and, unless a recorder of the Shortcuts tab records or Try a Double Press runs, hands it to the dispatcher as a Press:
  - its stroke (KeyBinding.from(event:)), its timestamp, the key window,
  - the kind of window it was pressed in (windowKind(ofKeyWindow:), whose cases windowKind(of:) lists; a sheet, and a sheet over a sheet, count as the window under them all, found as menu commands are routed (WindowCommandRouting.rootWindow(for:))),
  - whether the key window is a dialog (isDialog(_:): a sheet, a window styled as one, or a modal session's window), whether text input has the keyboard, and whether it is a held key's repeat.

  A press has no kind (nil, so no shortcut matches) over an audio editor (pressKind(window:sheetParent:)), and in the Search Library window or a sheet over it; with no key window the kind is .other.

### How the dispatcher reads a press
<!-- id: key-press-dispatcher; keys: Press, Trigger, PressTimer, Index, double press, escalates, singleWaits, text field keys; src: TextMouth/Services/ShortcutPressDispatcher.swift, TextMouth/Models/TextEditingKeys.swift, TextMouth/Models/KeyboardShortcut.swift, TextMouth/Services/KeyboardShortcutManager.swift, TextMouthProductionTests/ShortcutPressDispatcherTests.swift, TextMouthProductionTests/TextFieldEditingKeysTests.swift -->

The dispatcher posts back a Trigger, at once or, for a single press that waits, when its PressTimer fires (MainQueuePressTimer in the app; the clock and the timer are injected, so its tests never wait).
Its Index is built in ShortcutAction.allCases order and rebuilt whenever the bindings in force change (rebuild(from:), from the manager's take(_:), which also runs a waiting single press at once).
It gives each kind of window's keys a single and a double action, each action's entered in every kind where its keys act (ShortcutScope.windowKinds(of:)), except that:
- a letter alone (KeyBinding.isLetterAlone: one letter, of any alphabet, with none of Command, Option, Shift, or Control, once or twice) is left out of every kind of window that navigatesByLetter (ShortcutWindowKind.navigatesByLetter, which only the Library's does).
  A sheet over a Library window counts as one.
- so the list takes it, no key of that kind waits on it, and Shift-J and Shift-L find no J or L there to fall back to (B10),
- and a key equivalent's noted there (isKeyEquivalent(_:in:)) and given to no action,

And marks singleWaits where the double action is neither the single one nor the action it escalates (ShortcutAction.escalates, read from the table ShortcutAction.escalations, in ShortcutPressDispatcher.swift: since FR12's branch C, Where Am I?
Full Summary escalates Where Am I?, and Speak Full Info escalates Speak Info, whatever keys they have, so the first W or Shift-Command-I acts at once).
Its rules: a second press of the same key, with the same modifiers, in the same kind of window and window, less than the double-press time after the first by the events' own timestamps, is the double press, and one at exactly the time a single press.
Another key, another window, or a key a text field keeps ends a wait at once, running the waiting single press.
A held key's repeats are ignored for a key with a double action, and act as its presses do for any other.
Once a double press has acted, each further press of its key within the time of the one before is ignored.
And a waiting single press acts in its own window, held weakly, or nowhere once that window is gone.
A press with Shift that matches no binding of its own matches its binding without Shift, and posts shiftHeld, only for an action that takes Shift along (ShortcutAction.actionsTakingShiftAlong, in ShortcutPressDispatcher.swift: Skip Forward, Skip Backward, and Increase Speed).
And never while text input has the keyboard.
No press matches a key equivalent's key in a kind of window where its action works, nor, while the key window is a dialog, one of KeyBinding.dialogKeys (Return, the keypad's Enter, Escape, and Command-Period, each with no other modifier), which press the dialog's own buttons.
The dispatcher asks shouldHandle(binding:whenTextInputIsFocused:) of each press's stroke.
While a text field or text view has the keyboard (isTextInput(_:): any text view, editable or only selectable, the field editor of a text field or a search field included, or a text field; SwiftUI's selectable text, which refuses the keyboard, is none of these), the field keeps:
- every key with neither Command nor Control,
- and every key TextEditingKeys (Models/TextEditingKeys.swift) lists:
  - Delete, Forward Delete, the arrows, Home, End, Page Up, and Page Down with any modifiers;
  - the Edit menu's Command-A, C, V, X, and Z and Shift-Command-Z, which KeyBinding.editMenuCommands writes once, with their names (KeyBinding.systemCommands and TextEditingKeys.editMenuKeys derive from it), matched by the binding's stroke (TextEditingKeys.contains(_:)).
    So a double press of such a key stays the field's;
  - and Control, without Command, with the letters AppKit's standard key bindings give a command.

For those the manager posts nothing and returns the event, so the Edit menu and then the field get it.
Every other Command or Control binding acts from a field too, as Command-I's Book Info does, and Shift-Command-T, which closes the sleep timer's panel from its own minutes field.
One Space is the Library list's, not Play / Pause's: with an NSTableView as the first responder and TitleTypingSpaceClaim.shared.takesSpace(in:) true for the key window, handleKeyEvent returns false before the dispatcher sees the press (letter navigation in the Library list, above).

### How others observe a key press
<!-- id: key-press-observers; keys: notification, shiftHeld, Shift units, WindowCommandRouting, test stand-in; src: TextMouth/Services/KeyboardShortcutManager.swift, TextMouthProductionTests/TextFieldEditingKeysTests.swift, TextMouthProductionTests/ShortcutPressDispatcherTests.swift -->

- How others observe it: a press the manager takes posts its action's notification, with the window it was pressed in as its source (WindowCommandRouting) and shiftHeld when Shift was held beyond the binding's own, on the notification center the manager was given, the default one in the app.
  A reader's Skip Forward and Skip Backward then go by the Playback tab's Shift units.
  TextFieldEditingKeysTests gives it one of its own and presses made-up key events with a stand-in first responder, so no key is really pressed and no window hears one, and ShortcutPressDispatcherTests drive the dispatcher with a clock and a timer of their own.

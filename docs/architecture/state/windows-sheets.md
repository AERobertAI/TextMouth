# Windows: the Library's sheets, search, and Speak Info
<!-- id: windows-sheets-state; keys: sheet, Book Info, Search Library, Speak Info, folder sheet, pop-up; src: TextMouth/Views/Library/LibrarySheetViews.swift, TextMouth/Platform/macOS/Views/LibrarySearch/LibrarySearchWindowController.swift, TextMouth/ViewModels/LibraryInfoSpeaker.swift -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## The library's folder and Book Info sheets
<!-- id: library-folder-book-info-sheets; keys: create folder, folder dialog, Get Info, Return button, make folder, Book Info window; src: TextMouth/Views/Library/LibrarySheetViews.swift, TextMouth/Views/Feeds/AddFeedSheet.swift, TextMouth/Views/Feeds/FeedInfoSheet.swift, TextMouth/Views/Feeds/OPMLImportSheet.swift, TextMouthProductionTests/LibraryFolderPickerTests.swift, TextMouth/Services/AsyncBridge.swift, TextMouth/Views/Library/FeedItemBookInfoSheet.swift, TextMouth/Views/Library/LibraryBookInfoLoader.swift, TextMouth/Views/Library/LibraryView.swift, TextMouthProductionTests/FeedUIAddFeedTests.swift, TextMouthProductionTests/FeedUIOPMLTests.swift, TextMouthProductionTests/FeedUICommandsTests.swift, TextMouthProductionTests/FeedUITestSupport.swift -->

The library's sheets: the folder edits and the Book Info a Library window asks in a sheet.

- Owner: the window's views.
  Views/Library/LibrarySheetViews.swift holds:
  - the folder sheets (NewFolderSheet, MoveFolderSheet, RenameFolderSheet, MoveFolderToParentSheet, and DeleteFolderMoveContentsSheet, for Delete Folder's Move Contents)
  - and LibraryBookInfoSheet, the Book Info of a plain text, Markdown, or HTML book of the library's own,
    - which a reader shows for such a book too (an article in its feed has the read-only FeedItemBookInfoSheet, as an episode does; [Hand edits](package-records.md)),
    - whose edit(from:title:author:) trims the title and author, refuses a blank title, and pairs them with the title and author the sheet opened with, trimmed the same way, for Save's availability and its action alike,
    - and whose fields say "edited by hand" for a field the book's record names ([Hand edits](package-records.md)),
    - and which holds the Text Encoding pop-up of a book that offers one (the next entry);
  - what Book Info shows is read by LibraryBookInfoReader (Views/Library/LibraryBookInfoLoader.swift), off the main thread,
    - which for an audiobook reads the tags through AsyncBridge.waitForResult(reading:timeLimit:abandoned:of:) with its audioTagsTimeLimit property (AsyncBridge.audioTagsTimeLimit, 30 seconds, which tests shorten) and its abandonedReads (AsyncBridge.AbandonedReads.session),
    - and when the read passes the limit, or an earlier read of the same file did, shows Book.storedAudioMetadata with isCloudOnly false,
    - so the sheet says nothing of a download;
  - OperationFailureNotice, whose run(_:isWorking:failureMessage:) clears the sheet's failure as an edit that moves books starts, keeps the sheet working until the edit answers, then shows any failure, which message(after:) announces once;
  - and LibraryFolderPicker, the folder chooser the Move sheet, Add Feed, Feed Info, and Import OPML share.

  Move to Folder… is shown by MoveToFolderSheetPresentation with a MoveToFolderRequest, the books that move, through .sheet(item:), and Rename Folder… and Move Folder… by their folder, through .sheet(item:) on LibraryView's folderToRename and folderToMove.
  A sheet's content never reads @State captured in its owner's body (B11): the Move sheet was once built from the state the body last captured, before the books were set, so its first presentation from a button-style action, the edit bar's Move or a row's Move to Folder…, was empty.
  MoveFolderSheet logs MOVE_SHEET_SHOWN as it appears, with counts only (see [Logs](logs.md)).

### How the folder sheets take keys, and how they are tested
<!-- id: folder-sheets-keys-tests; keys: Return key, Cancel New Folder, isMakingFolder, createTakesReturn, hosted tests, key helpers; src: TextMouth/Views/Library/LibrarySheetViews.swift, TextMouthProductionTests/AccessibilityTestSupport.swift -->

- Who may write it: the sheets' own controls.
  The picker's Create takes the Return key (keyboardShortcut(.defaultAction)) while its New Folder fields are shown, and its optional isMakingFolder binding tells an owner with a Return-key button of its own to stand that button down meanwhile, as the Move sheet does with Move.
  Add Feed and Import OPML pass the binding too, each holding the state the picker keeps current, and withdraw Subscribe's and Import's shortcut while the fields are shown, so no button takes Return until a name is typed and Create can act (measured in hosted windows, not in the live app).
  Add Feed resets that state as the picker disappears (onDisappear) when a page naming several feeds replaces the address step, so Subscribe takes Return back at the choice step; Import OPML's Done, shown once the import has ended, keeps Return, which the picker's disabled fields leave to it.
  Feed Info passes none: it has no Return-key button (Done takes Escape), so Create takes Return there while the fields are shown, from a number field too, whose number is entered as focus leaves it.
  Each feed sheet's init takes makingFolder: for the tests of the Return key (FeedUIAddFeedTests, FeedUIOPMLTests, FeedUICommandsTests), which are synchronous and start the engine through a Task they wait out, since an async test's run loop cannot run the main actor's work.
  The fields' Cancel is Cancel New Folder (cancelNewFolderTitle, cancelNewFolderHint), so VoiceOver tells it from the sheet's Cancel, which closes the whole sheet.
  It takes Escape (keyboardShortcut(.cancelAction)) while the fields are shown, closes them, clears the name, keeps the place chosen, and announces LibraryFolderPicker.newFolderCancelledAnnouncement(pickerLabel:chosen:) ("New Folder cancelled.
  Destination folder: Reports."); its Create announces LibraryFolderPicker.newFolderCreatedAnnouncement(name:pickerLabel:chosen:) ("Folder Q3 created.
  Destination folder: Reports/Q3.") at once, the new folder chosen in the pop-up.
  And the New Folder sheet's Create has the window say NewFolderSheet.createdAnnouncement(name:parentPath:) ("Folder Q3 created in Reports.", or "in Library Root.") once the sheet has closed (VoiceOverAnnouncer.announceAfterSheetCloses).
  The Move sheet's, Add Feed's, and Import OPML's own Cancel follow isMakingFolder and stand down meanwhile, so a second Escape closes the sheet.
  Feed Info's Done does the same since the feed follow-ups after FR14 (FeedInfoSheet binds the picker's isMakingFolder, and takes makingFolder: to open with the fields shown, as its test, which hosts Feed Info itself, does), so there a second Escape presses Done.
  The name field takes the keyboard as the fields appear (focusNameField(), from onAppear, on the next turn of the run loop), so VoiceOver, which follows the keyboard, lands there.
  The property createTakesReturn, true unless an owner says otherwise, lets an owner hand Return to a button of its own.
  Add Feed passes !searchFocused, so while the Search field has the keyboard, Search alone is the default button and Return never makes a folder, as it did on main before.
- How others observe it: a failure is read as text labelled as an error, and the sheet stays open with the input.
  Measured in hosted windows (LibraryFolderPickerTests): a Return offered as a key equivalent (performKeyEquivalent) reaches the default button alone and a focused field's onSubmit stays silent, while the key-down path alone (sendEvent) runs onSubmit, so one press does one thing.
  The key and typing helpers of these tests live in TextMouthProductionTests/AccessibilityTestSupport.swift (#1241).
  So do handleQueuedCallbacks(), which returns once the main queue has run what was queued before it, and control(labelled:in:), which finds a hosted control by its label and lists the labels there are when it finds none.
  The helper startTurningTheRunLoop(_:) is in FeedUITestSupport.swift.
  The legacy scenario files (TextMouthProductionTests/LegacyScenarioHarness.swift and the files beside it) have no canImport(TextMouth) conditionals, and dataFileURL(_:) in TestDataFiles.swift builds the TestData path for them (requireFile(_:) is its throwing form).

## Book Information's Text Encoding pop-up
<!-- id: book-info-text-encoding-popup; keys: charset, encoding guess, mojibake, Shift JIS, code page, reread alert, text encoding menu; src: TextMouth/Views/Library/LibrarySheetViews.swift, TextMouth/ViewModels/TextEncodingChoiceModel.swift, TextMouth/Models/TextEncodingChoice.swift, TextMouth/Models/LibraryInfoWording.swift, TextMouth/ViewModels/LibraryViewModel+TextEncoding.swift, TextMouthProductionTests/TextEncodingPopUpTests.swift, TextMouth/ViewModels/BookRereadChoosing.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/Services/MaintenanceFileAccess.swift, TextMouth/Services/StorageDestinationAssessment.swift, TextMouth/ViewModels/BrailleFileCodeChoiceModel.swift -->

Book Information's Text Encoding pop-up (encodingchoice): what the Book Info sheet of a plain text, Markdown, or HTML book from the listener's own file shows of the encoding its file is read in, and the choice of another.

- Owner: LibraryBookInfoSheet keeps a TextEncodingChoiceModel (ViewModels/TextEncodingChoiceModel.swift, on the main actor, an ObservableObject) in @StateObject for the book it shows,
  - made for every book
  - and drawn only for one with Book.offersTextEncodingChoice (which books have it, in [Imports](imports-text-encoding-choice.md)).

  The model holds the book's ID, the library that reads the book again, and the MaintenanceFileAccess that reaches its files (the app's, unless a test pretends files are in the cloud), and publishes four values:
  - state (a TextEncodingRowState: known, with a TextEncodingReading; unknown, with the words that say why; or checking),
  - pending (a Confirmation: the option chosen, keepsText, and stopsEditing, until it is answered),
  - isWorking (a re-read is under way),
  - and failureMessage (why the last choice changed nothing).
- Who may write it: the model alone, from the pop-up's choice and the alert's buttons.
  Its init(book:library:access:) shows an encoding the row records at once (state known) and otherwise checking.
  The sheet's .task calls load(), which reads the package record or the file off the main actor (OffMainWork.run of TextEncodingReading.current(of:access:)), so the sheet never waits on a large file.
  Its choose(_:) ignores the item already selected, the extra "current" item, and a pop-up that is not enabled (while checking or working).
  Otherwise it asks the library whether the book can be read again now (textEncodingChangeRefusal(of:)), and a refusal is shown and announced once through OperationFailureNotice.message(after:), with no confirmation.
  If the book can be, it asks off the main actor whether content.md holds text TextMouth did not write (LibraryViewModel.unwrittenText(of:access:), reading nothing from the cloud), and sets pending, with stopsEditing from library.textEditSessions.isEditing(_:).
  Its confirm(_:) clears pending and the failure, sets isWorking, awaits LibraryViewModel.readTextAgain(bookID:choosing:access:) (in [Text caches](text-caches-rereads-edits.md)), shows its failure the same way, loads the reading again, and ends isWorking.
  The re-read is called through RereadChoiceFlow, which the Braille File Characters and Braille Code pop-ups share.
  BookRereadPopUp is generic over BookRereadChoosing models (TextEncodingChoiceModel, BrailleFileCodeChoiceModel, and BrailleCodeChoiceModel, in ViewModels/BookRereadChoosing.swift).
  A TextRereadChoice is .textEncoding, .brailleFileCode, or .brailleTable.
  Each pop-up carries its own alert, and a stored code becomes words in BrailleFileCodeWording.name(ofStored:) only.
  The model's cancel() clears pending.
- How others observe it: LibraryBookInfoSheet draws the row as a BookRereadPopUp (Views/Library/LibrarySheetViews.swift) over the model, a Picker in the menu style whose label and hint are set for VoiceOver (TextEncodingWording.bookInfoLabel and popUpHint).
  That is because a pop-up button takes no label from the picker's title, and SwiftUI's accessibilityValue never reaches it (TextEncodingPopUpTests measured an empty value).
  The value VoiceOver speaks, before the label, is the selected item's title, so name(of:) names the selected item with what decided the encoding ("Windows-1251 (Cyrillic), guessed") and every other as the catalog does.
  The items are TextEncodingChoices.options, then one more, last, while no option names the encoding (UTF-16, an HTML declaration the catalog lacks) or the state is not known.
  The confirmation is the .alert that BookRereadPopUp carries, over the sheet: its title and message are TextEncodingWording.confirmTitle(bookTitle:option:) and confirmMessage(option:keepsText:stopsEditing:), its buttons Read Again, which reads the book again, and Cancel.
  While isWorking the sheet shows a SheetWorkIndicator ("Reading the book again...") and its Cancel and Save are disabled, so the sheet can neither start a second re-read nor close halfway; a failure shows below the form in an OperationFailureNotice, read as "Error: " and the sentence.
  TextEncodingPopUpTests host the sheet and read the pop-up's label, value, hint, and items from the accessibility tree, and check that text typed in has none.

## Book Information's Braille Code pop-up
<!-- id: book-info-braille-code-popup; keys: UEB, liblouis, translation table, BRF, table guess, Keep This Table, braille code menu; src: TextMouth/ViewModels/BrailleCodeChoiceModel.swift, TextMouth/ViewModels/BookRereadChoosing.swift, TextMouth/Views/Library/LibrarySheetViews.swift, TextMouth/Models/LibraryInfoWording.swift, TextMouth/Models/TextEncodingChoice.swift, TextMouth/ViewModels/LibraryViewModel+TextEncoding.swift, TextMouth/Models/BrailleTableCatalog.swift, TextMouth/Models/Book.swift, TextMouthProductionTests/BrailleCodeBookInfoTests.swift, TextMouthProductionTests/BrailleCodeRereadTests.swift, TextMouthProductionTests/BrailleFileCodeBookInfoTests.swift -->

Book Information's Braille Code pop-up (FMT21): what the Book Info sheet of a braille book shows of the braille table its text is translated to print by, and the choice of another.

- Owner: LibraryBookInfoSheet keeps a BrailleCodeChoiceModel (ViewModels/BrailleCodeChoiceModel.swift, on the main actor) in @StateObject beside the other two models, drawn for a book with Book.offersBrailleTableChoice (a braille book that is not a feed's item, a PEF included).
  A feed's item keeps the plain row (bookInfoBrailleCodeRow).
  It publishes storedTable (the book's Book.brailleTable, nil for the default), offered (BrailleTableCatalog.offeredTables, the tables that read braille back, never one that only writes it), names, and isLoaded.
  It also holds a `RereadChoiceFlow<BrailleTable>`, whose pending, isWorking, failureMessage, and failureStamp it passes on and whose changes it forwards, so the views observing it redraw.
- Who may write it: the model alone.
  Its currentTableID is the book's table in the lists' spelling (BrailleTableCatalog.listedID(forStored:)), so an iPhone's bare fr-bfu-g2.ctb finds its item on a Mac; the book keeps what it stored.
  Its load(), in the sheet's .task, lists the offered tables and the words each is named by (BrailleTableCatalog.description(ofTableID:), the words the book's row and Speak Info use) off the main actor, since reading this Mac's tables' headers is slow.
  Until then the pop-up is dimmed (isEnabled) and shows the book's own table.
  Its choose(_:) keeps a guessed table when the table already selected is chosen (keepGuessedTable(), which clears Book.brailleTableOrigin and announces it, with no re-read; the sheet's "Keep This Code" button does the same, under guessNote).
  Otherwise it ignores a choice of the table already selected, a choice while the pop-up takes none, and one this Mac does not offer for reading (an Item.unavailable, listed last only while it is the book's own, as a table that only writes braille is).
  Any other choice it asks the flow, which refuses with the library's reason or sets pending.
  Its confirm(_:) awaits flow.confirm(choosing: .brailleTable(table)), through LibraryViewModel.readTextAgain (in [Text caches](text-caches-rereads-edits.md)), then reads the book's table again from the row.
  The words are BrailleCodeWording (Models/LibraryInfoWording.swift):
  - the label "Braille Code",
  - the hint "Choose another braille code to read the book's file again with it.",
  - the alert's title and message (BrailleCodeWording.translatedAgainNote, then TextEncodingWording.replacedNote and BrailleFileCodeWording.placesNote, then the kept-text and Edit Text sentences),
  - and the busy sentence.
- How others observe it: the sheet draws it with BookRereadPopUp, as the other two.
  Its failure is shown only when it spoke last.
  RereadFailureOrder.latest(among:) picks, of the three models' (message, stamp) pairs, the message with the highest stamp, and each flow stamps its message and its clearing, so an older pop-up's refusal never shows over a newer choice.
  The property isReadingAgain, true while any of the three works, shows the work indicator and dims the sheet's buttons.
  An open reader follows the new table through Book.LibraryFields (brailleTable, brailleTableVersion).
- Tests: BrailleCodeBookInfoTests (the model, the sheet's one refusal, and the hosted label, value, and hint, which skip without an accessibility session), BrailleCodeRereadTests, and BrailleFileCodeBookInfoTests.

## The Search Library window
<!-- id: search-library-window; keys: search all books, full-text search, results list, jump to match, Find in Library, library-wide search, all-books search; src: TextMouth/Platform/macOS/Views/LibrarySearch/LibrarySearchWindowController.swift, TextMouth/Platform/macOS/Views/LibrarySearch/LibrarySearchWindowView.swift, TextMouth/ViewModels/LibrarySearchModel.swift, TextMouth/Models/LibrarySearchWording.swift, TextMouth/Services/TextSearch/LibrarySearchEngine.swift, TextMouth/Services/TextSearch/LibrarySearchPrefilter.swift, TextMouth/Services/TextSearch/LibrarySearchSpecials.swift, TextMouth/Services/TextSearch/BookTextSearch.swift, TextMouth/App/MenuCommands.swift, TextMouth/Models/KeyboardShortcut.swift, TextMouth/Platform/macOS/Services/MenuVisibilityManager.swift, TextMouth/Services/KeyboardShortcutManager.swift, TextMouth/Models/LibraryBookSorter.swift, TextMouth/Services/LibrarySearchJumpRequests.swift, TextMouth/Views/Reader/BookSearchView.swift, TextMouth/Services/VoiceOverAnnouncer.swift, TextMouthProductionTests/LibrarySearchModelTests.swift, TextMouthProductionTests/LibrarySearchEngineTests.swift, TextMouthProductionTests/LibrarySearchPrefilterTests.swift, TextMouthProductionTests/LibrarySearchSpecialsTests.swift -->

The Search Library window (libsearch): the one window that searches the text of every book; the user's page is [Search Library](../../user/search-library.md), the design research/LIBRARY-SEARCH-RESEARCH-2026-11-13.md in the repository's root.

- Owner: LibrarySearchWindowController.shared (Platform/macOS/Views/LibrarySearch/LibrarySearchWindowController.swift, on the main actor).
  An AppKit window, identifier "library-search" (windowIdentifier), titled LibrarySearchWording.windowTitle, hosting LibrarySearchWindowView, with a frame saved as LibrarySearchWindow.
  It holds the model, a LibrarySearchModel (ViewModels/LibrarySearchModel.swift), which outlives the window, so closing it keeps the query, the two options, and the results; attach(_:) gives it the library, once, as each Library window appears, and listens for .searchLibrary.
  The model owns the query, matchCase and useRegex (each change restarts the search after debounceInterval, 300 ms), the status, the groups of results, and the limits (shownPerBook 20, shownInAll 1,000; LibrarySearchLimits.library keeps 100 matches a book and counts to 1,000).
- Who may write it: the model alone: restartSearch() cancels the running search and starts a newer one, searches running one at a time on one queue, a generation number keeping a stale search's results from landing.
  LibrarySearchEngine.search (Services/TextSearch/LibrarySearchEngine.swift) reports each book from its threads into a locked LibrarySearchInbox, which the model takes every publishInterval, 150 ms, adding books in the title order (LibraryBookSorter) whatever order they finished in.
  Cancelling is asked before each book and chapter, inside each lookup (a regular expression through .reportProgress), while a book waits at the preparing gate, and once its content.md is read, so only a parse already under way runs to its end.
  The engine decides every match with BookTextSearch.Matcher over whole chapters, after LibrarySearchPrefilter (with LibrarySearchSpecials) has passed over the chapters that cannot hold one.
  An ASCII anchor taken from the query, matched by bytes, or a few non-ASCII characters Foundation matches against ASCII, which a sweep of all 1,111,936 scalars found.
  A regular expression, a query holding a line end, and a query with no ASCII anchor have no prefilter.
  A chapter the prefilter cannot pass over is searched whole, never line by line, because Foundation's case-insensitive search does not answer a range as it answers the same text inside a longer one.
  The model's showAllMatches(in:) lists up to 500 of a book's matches (Search in Book's limit) and takes the book's own count only when it saw every match.
  Its open(_:) makes the LibrarySearchJumpRequest ([Library search requests](reader-navigation.md)) and posts .openBookWindow, as opening from the Library does.
  A book that left the library is told with LibrarySearchWording.bookGone(title:).

### The Search Library window's controls and tests
<!-- id: search-library-controls-tests; keys: LibrarySearchWording, rotors, status line, Edit Find menu, searchLibrary; src: TextMouth/Models/LibrarySearchWording.swift, TextMouth/App/MenuCommands.swift, TextMouth/Platform/macOS/Views/LibrarySearch/LibrarySearchWindowController.swift -->

- How others observe it: the window's controls are all in LibrarySearchWording:
  - the field's label "Search the library", hint, and prompt,
  - the Match Case checkbox with Search in Book's own words (BookSearchWording.matchCaseLabel and matchCaseHint),
  - Regular Expression,
  - Close (Escape),
  - a progress bar and Stop (Command-Period) while a search runs,
  - and the results, a List labelled "Results" with the Books and Matches rotors (LibrarySearchRotors),
    - each book's heading a header
    - and each row one element whose label is the context, then where, then "in TITLE" (LibrarySearchWording.matchLabel(context:location:bookTitle:)), its default action opening the match.

  The status line is plain text read in place and announced once, as a search ends (announce, through VoiceOverAnnouncer from the window); its sentences are LibrarySearchWording's.
  The menu bar and the shortcut manager treat the window as neither a Library nor a reader window (MenuVisibilityManager, KeyboardShortcutManager.isLibrarySearchWindow), so no Library or reader menu shows while it is in front, and Return and Space act in its list.
  The command is Edit > Find > Search Library… (EditCommands in App/MenuCommands.swift: CommandGroup(after: .textEditing), a Find submenu, since the Library menu shows only while a Library window is in front).
  A key equivalent (ShortcutAction.searchLibrary, in keyEquivalentActions, default Option-Command-F, Library group, works in every window: menuCommandKey(.searchLibrary...)).
- Tests:
  - LibrarySearchModelTests,
  - LibrarySearchEngineTests,
  - LibrarySearchPrefilterTests,
  - and LibrarySearchSpecialsTests (whose sweep checks, on whichever macOS runs it, that each ASCII query Foundation finds in a scalar is made of what the scalar stands for), in the reader-text area of Scripts/test/areas.conf.

## The Folder Settings and Add to Library sheets
<!-- id: folder-settings-add-library-sheets; keys: listening options, New from Text, Import Folder, Open Book, plus button, feed options, folder options; src: TextMouth/Views/Library/FolderSettingsSheet.swift, TextMouth/Views/Library/LibraryFolderSettingsTarget.swift, TextMouth/Views/Library/AddToLibrarySheet.swift, TextMouth/Views/Library/AddToLibraryHost.swift, TextMouth/Models/FolderSettingsWording.swift, TextMouth/Models/AddToLibraryChoice.swift, TextMouth/Models/AddToLibraryWording.swift, TextMouth/Views/Library/LibraryView.swift, TextMouth/App/MenuCommands.swift, TextMouth/Models/KeyboardShortcut.swift, TextMouth/Models/SettingsPolicy.swift, TextMouth/Services/KeyboardShortcutManager.swift, TextMouth/Models/LibraryInfoWording.swift, TextMouth/Views/Feeds/FeedInfoSheet.swift -->

The Folder Settings sheet and the Add to Library sheet (FR19, FR20): what a Library window's toolbar opens, besides the folder edits.

- Owner: the window's views (Views/Library/LibraryView.swift).
  Its folderSettings, a FolderSettingsModel in @State, names the plain folder whose sheet shows, nil while none does.
  It keeps only the folder's ID, the library, the feed folders, the reading speed, and the preferences.
  It reads the rest from the library each time it is asked, so a rename or a choice made in another window shows.
  It reads the global When book ends and Open the next book in from the preferences (SettingsPolicy.endOfBookBehavior and SettingsPolicy.nextBookWindow, storedValue(in:)).
  Its addToLibrary, an AddToLibraryHost in @StateObject, owns an AddToLibraryModel (isPresented, and the choice made while the sheet closes) and a KeyboardShortcutManager of its own, made with installsEventMonitor false so that it reads the preferences store as the app's does and takes no key press.
  It has a manager of its own because the app's manager, read from the environment, broke existing tests, and the keys the sheet shows may lag a change made in Settings until the next window.
- Who may write it: the toolbar's Feed Settings or Folder Settings button and the Library menu's Folder or Feed Settings call LibraryView.openFolderSettings(_:).
  That menu command is ShortcutAction.folderOrFeedSettings, with no default key, posting showFolderOrFeedSettings, which LibraryFolderSettingsSupport hears for the window that takes commands.
  LibraryFolderSettingsTarget.of(category:folderPath:folders:feedID:feedTitle:) gives the folder the window shows:
  - nil unless the category is Folders and the path names a folder, so the top of the library and every other category have none;
  - .feed(feedID:title:) for a folder some feed's downloads go to, which opens Feed Info the way Command-I does;
  - and .folder(folderID:name:) for any other, which sets folderSettings.

  With no target the window says "Open a folder first to see its settings".
  The Add to Library button calls AddToLibraryHost.present(); a choice's button calls AddToLibraryModel.choose(_:), which closes the sheet and remembers the choice, and Cancel or Escape forgets it.
  The choice runs in the sheet's onDismiss (AddToLibraryModel.sheetDidDismiss(), exactly once), since a sheet or file panel it opens would be refused while this one was still closing.
  AddToLibraryRunner.run(_:sourceWindow:) posts what its menu command posts (openBookFile, importDAISYFolder, newFromText, or addFeed, which alone carries the window as sourceWindow, as the old Add Feed button did) or shows the Record window for New Recording….
  A choice is a case of AddToLibraryChoice (allCases is the sheet's order), and its title, key, and scope come from its ShortcutAction; it is enabled while that action's scope admits a Library window (ShortcutScope.admitsMenuCommand(in:)).
- How others observe it: FolderSettingsSheet shows:
  - the folder's name as a heading,
  - the facts (FolderSettingsWording.facts(of:parentPath:), made of LibraryInfoWording's phrases, which Speak Info says too) as FeedInfoValue rows, each one element, "Label, value",
  - the "Listening" heading with the three controls (ListeningOptionsWording, and NextBookWindowPicker, shared with Feed Info, for "Open the next book in", dimmed while the folder's books do not go on to another book),
  - and Done, on Return and Escape (SilentKeyEquivalent);
  - once the folder is gone it says "This folder is no longer in the library."

  AddToLibrarySheet draws each choice as one button labelled with its title and its key in words (AddToLibraryWording.label(_:key:)), its summary under it and spoken as its hint, or, dimmed, with "Not available in this window." after the summary; the first takes VoiceOver's initial focus.
  A window with no books and no Continue button starts VoiceOver on the Add to Library button (LibraryFocusTarget.importButton, whose name was kept).

## Speak Info
<!-- id: speak-info; keys: spoken summary, announce info, read info aloud, double press, say book info, VoiceOver speech; src: TextMouth/ViewModels/LibraryInfoSpeaker.swift, TextMouth/Models/SummaryPress.swift, TextMouth/Views/Library/LibraryInfoRow.swift, TextMouth/Models/LibraryInfoWording.swift, TextMouth/Views/Library/LibraryView.swift, TextMouth/Models/KeyboardShortcut.swift, TextMouth/App/MenuCommands.swift, TextMouthProductionTests/LibraryInfoSpeakerTests.swift, TextMouthProductionTests/LibraryInfoWordingTests.swift, TextMouthProductionTests/FullSummaryActionTests.swift, TextMouth/Services/KeyboardShortcutManager.swift, TextMouth/Services/SpeechMarkupGuard.swift, TextMouth/Services/SpeechService.swift, TextMouth/Views/Feeds/LibraryFeedFolders.swift, TextMouth/Views/Library/FeedItemBookInfoSheet.swift -->

Speak Info (FR07): the selected row's information, spoken in a Library window, brief or full, and Command-I for every kind of row.

- Owner: LibraryInfoSpeaker (ViewModels/LibraryInfoSpeaker.swift), on the main actor, one in each LibraryView's @State, never observed, since it draws nothing:
  - the announcement speaking (its summary, brief or full, the row it describes, by LibraryInfoRow.id, and its utterance),
  - and a synthesizer of its own, made at the first press by the factory passed to init(makingSynthesizersWith:) (LibraryInfoSpeaker.makeSynthesizer unless a test passes another, behind LibraryInfoSynthesizing, which tests replace with a recorder that plays nothing).

  It speaks in the voice and at the speed of the global settings, with prefersAssistiveTechnologySettings off, its text guarded by SpeechMarkupGuard, as Where Am I? speaks in a reader.
  Its press(_:about:voice:wordsPerMinute:now:subject:) follows SummaryPress, as Where Am I? does (FR12's branch C).
  A brief press stops a summary speaking, a full press switches the same row's brief summary to the full one and stops the full one, and a press about another row speaks that row's summary in place of the one speaking.
  No press depends on when the last came.
  LibraryInfoSpeechDelegate hands each finish and each cancel over with its utterance (ReportedUtterance), at once when the synthesizer calls it on the main thread, as it does, and otherwise on the next turn of the main queue.
  The end of an announcement stopped or replaced since changes nothing, and a cancel of the one speaking that nobody asked for, as the engine's refusal of its text makes, ends it and replaces the synthesizer, which would never speak again (SPEAK_INFO_CANCEL_UNEXPECTED).
  A summary that takes the place of one still speaking speaks on a fresh synthesizer too (replaceSynthesizer()).
- Who may write it: ShortcutAction.speakInfo (Shift-Command-I) and speakFullInfo (Shift-Command-I twice; a letter alone is the Library list's, in [Letter navigation in the Library list](windows.md)).
  They work by default in every window but an audio editor's (ShortcutScope.app), which the Works in pop-up can change, though only a Library window acts on them.
  They are listed under Information after Where Am I? and Where Am I?
  Full Summary, and Library > Speak Info and Speak Full Info, which post speakInfo and speakFullInfo for the Library window that takes the command (WindowCommandRouting, through LibraryView's takesCommand(_:)).
  Shift-Command-I holds Command, so KeyboardShortcutManager takes it from a focused text field too, as it takes Command-I, while a plain I is the field's.
  An action the user gave Shift-Command-I keeps it, Speak Info then having no key until that action lets it go ([Keyboard shortcuts](preferences-shortcuts.md)).
  Book Info, Command-I, posts showBookInfo, which LibraryView routes by LibraryInfoRow.infoCommand(feedInFolder:): Book Info for a book, Feed Info for a feed's row or a feed's folder, and the speaker's full summary for any other folder, which has no sheet; with nothing selected it does nothing.
  Book Info's menu item, which carries no shortcut, is the Navigate menu's, which a Library window hides; Command-I reaches every window but an audio editor's, where it is the editor's Audio Info, through KeyboardShortcutManager.

### How Speak Info picks and says a row
<!-- id: speak-info-row-wording; keys: LibraryInfoRow.selected, LibraryInfoSubject, BookInfoFacts, FolderInfoFacts, FeedInfoFacts, LibraryInfoWording; src: TextMouth/Views/Library/LibraryInfoRow.swift, TextMouth/Models/LibraryInfoWording.swift -->

- How others observe it: LibraryInfoRow.selected (Views/Library/LibraryInfoRow.swift) resolves the row both commands act on.
  The first selected row in the list's order, a folder's, of the folders the Folders section shows (LibraryFeedFolders.folderRows, [The feed reader's interface](feeds-interface.md)), then a feed's, then a book's, since the List selects a folder's or a feed's row by its ID as it does a book's.
  Or else the edit selection's first book.
  LibraryInfoSubject's initializer, in the same file, gathers that row's facts at the press, as the list shows them then:
  - a book's (BookInfoFacts) with
    - its reader's live position where that is newer,
    - its cloud note and kept state as its row has them,
    - the encoding its file was guessed to be in, or the listener chose, in words, when its record names one (BookInfoFacts.textEncoding, from Book.textEncodingDescription, which only the full summary says, from the row alone; Text files in other encodings, in [Imports](imports-text-encodings.md)),
    - and its file size, measured as the File Size sort measures it, only for the full summary and never for a book in the cloud;
  - for an episode or article in its feed, its feed's title (BookInfoFacts.feedTitle, from LibraryViewModel.feedTitle(of:)), which LibraryInfoWording.placeNote(of:) says in place of a folder, "In The Digital Antiquarian, a feed";
  - for a book in the reading list, its place there (BookInfoFacts.readingListPlace, said after the place note: [The reading list](library-index-reading-feeds.md));
  - a folder's (FolderInfoFacts) with the books and unopened books of its whole tree, the feeds the Feeds section lists inside it, its own subfolders, and the time left in all its books;
  - a feed's (FeedInfoFacts) with its counts and last check as its row shows them, its folder, and its address;
  - and a feed's folder as its feed.

  LibraryInfoWording (Models/LibraryInfoWording.swift) makes every sentence from those facts ([LibraryInfoWording](../shared-helpers-values.md)).

## Which audiobooks play a folder of tracks
<!-- id: track-folder-books; keys: manifest.json, track folder cache, Edit Manifest menu, multi-file audiobook, folder of mp3s, cached list; src: TextMouth/ViewModels/TrackFolderBooks.swift, TextMouth/ViewModels/TranscribedBooks.swift, TextMouth/Views/Transcription/TranscriptionPresentation.swift, TextMouth/Services/BookManifestEditing.swift -->

TrackFolderBooks (ViewModels/TrackFolderBooks.swift) records which audiobooks play a folder of tracks, refreshed off the main thread at the moments TranscribedBooks refreshes; the Edit Manifest commands read it.

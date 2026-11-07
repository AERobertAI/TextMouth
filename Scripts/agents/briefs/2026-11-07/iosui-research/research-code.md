# iPhone interface: what the code offers

Researcher: `iosui-research-code`, team `iosui`. Read from branch `ios/interface` at commit 1ad90f4b. Nothing was changed, and nothing was run on iOS. Where a claim about iOS rests on reading the code and not on running it, it says "not run".

How to read the references:

- Paths are relative to the `TextMouth/` source folder unless they begin with another top-level folder. Every `ReaderViewModel*.swift` and `LibraryViewModel*.swift` is in `ViewModels/`.
- `file:12` is a line; `file:12-20` is a range.
- "first" means in the first version, "later" means not.
- "Shared" wording lives in a type every target compiles and can be called from iOS. "Inline" wording is a string literal inside a Mac view: a worker must call that view, or move the string into a wording type and leave the Mac reading it from there.

## 0. Five facts that change the plan

1. The data directory is outside the iOS container today. `TextMouthRuntime.realHomeDirectory` (`App/TextMouthRuntime.swift:144-149`) reads `getpwuid(getuid())`. On a device that names `/var/mobile`, and in the Simulator it names the Mac user's real home, so `TextMouthPaths.defaultRoot` (`Services/TextMouthPaths.swift:22-24`) would be the user's live `~/.TextMouth`. This must change before anything runs (not run; section 4).
2. Importing an M4B, M4A, or MP4 audiobook fails on iOS today. The bytes leave MPEG-4 undecided (`Parsers/AudioContentSniffer.swift:115-116`), so the import asks `afinfo`, and the iOS stand-in throws where the Mac's caller expects no error but cancellation (`Platform/iOS/Services/WatchedProcess+iOS.swift:106-115`). Section 5 gives the one-line way out.
3. Import questions never appear on iOS. `ImportOrigin(window:)` is always nil there (`Views/Library/ImportDecisionPresenter.swift:15-24`), so `asksCurrentQuestion` is always false (`:85-90`). A duplicate's question waits for ever.
4. Nothing hears the app-wide notifications on iOS. Only `AppDelegate` starts the router (`Platform/macOS/App/AppDelegate.swift:19-23`). A book's end (`.continueToNextBook`) and an import's open (`.openBookWindow`, `ViewModels/LibraryViewModel.swift:232-234`) go nowhere until the iPhone app listens.
5. `ReaderViewModel` can outlive its view, and the iPhone design needs it to. It is an ordinary `ObservableObject`, but it dies only through an explicit `close()` (`ReaderViewModel.swift:2239`), which the Mac's `BookReaderWindowView` calls from `onDisappear` (`Views/Reader/BookReaderWindowView.swift:124-133`). The iPhone app must own it above its navigation and must not use that view.

## 1. Every Mac screen and command

### 1.1 Windows and screens

Library window (first, rebuilt for the phone).

- `LibraryWindowView`, `Views/ContentView.swift:5`, holds `LibraryView`, `Views/Library/LibraryView.swift:206`.
- Models and services: `LibraryViewModel`, `SettingsViewModel`, `LibraryWindowRouter.shared`, `LibraryViewDefinitionStore.shared`, `FolderNavigationHistory`, `RemovalPreferencesModel.shared`, `LibraryFeedFolders.shared`, `BookCloudStates.shared`, `KeptBooks.shared`, `TranscribedBooks.shared`, `TrackFolderBooks.shared`, `LibraryInfoSpeaker`, `AddToLibraryHost`, `TranscriptionPresenter`.
- Rows and bars, `Views/Library/LibrarySubviews.swift`: `EditModeBar:13`, `TimeRemainingBar:120`, `BreadcrumbBar:287`, `FolderRow:323`, `BookRow:390`, `LibraryBookListRow:794`.
- `ProgressOverlay`, `Views/ContentView.swift:515`: import, text extraction, and Ogg conversion progress (first).

Library sheets and alerts.

- `LibraryBookInfoSheet`, `Views/Library/LibrarySheetViews.swift:7`: title and author of a plain book (first).
- `MetadataEditorView`, `Views/Reader/MetadataEditorView.swift:16`: an EPUB's or an audiobook's details (first for reading them; saving is cheap to keep).
- `FeedItemBookInfoSheet`, `Views/Library/FeedItemBookInfoSheet.swift:45` (later, with feeds).
- `NewFolderSheet:353`, `LibraryFolderPicker:457`, `MoveFolderSheet:677`, `RenameFolderSheet:895`, `MoveFolderToParentSheet:951`, `DeleteFolderMoveContentsSheet:1033`, all in `Views/Library/LibrarySheetViews.swift` (first).
- `ImportDecisionSheet`, `Views/Library/ImportDecisionSheet.swift:18`, shown by `ImportDecisionPresenter`, `Views/Library/ImportDecisionPresenter.swift:48` (first, with a new presenter).
- `AddToLibrarySheet`, `Views/Library/AddToLibrarySheet.swift:82`, model `AddToLibraryModel:18`, host `AddToLibraryHost`, `Views/Library/AddToLibraryHost.swift:54` (first in a smaller form: Files only).
- `FolderSettingsSheet`, `Views/Library/FolderSettingsSheet.swift:117`, model `FolderSettingsModel:9` (later; first if the spec wants "When a book ends" per folder).
- `TextInputView`, `Views/Library/TextInputView.swift:137`: New from Text (later).
- `DataDirectoryUnavailableView`, `Views/Library/DataDirectoryUnavailableView.swift:103` (first, reworded: see section 7.27).
- `LibraryIndexRecoverySheet:63` and `LibraryIndexRecoveryBanner:174`, `Views/Library/LibraryIndexRecoveryViews.swift` (first: a damaged index must say so).
- `PersistenceFailureBanner`, `Views/Library/PersistenceFailureBanner.swift:14` (first).
- `DataDirectoryMoveSheet`, `Views/Library/DataDirectoryMoveSheet.swift:54` (never on the phone: no move).
- `ReadingListOptionsBar`, `Views/Library/ReadingListOptionsBar.swift` (first, with the Reading List view).

Reader window (first, rebuilt for the phone).

- `BookReaderWindowView`, `Views/Reader/BookReaderWindowView.swift:4`, holds `ReaderView`, `Views/Reader/ReaderView.swift:14`.
- Model: `ReaderViewModel`, `ViewModels/ReaderViewModel.swift:147`, and through it `SpeechService`, `AudioEngineService`, `AudioPlaybackService`, `NowPlayingSession`, `SleepTimerService.shared`, `ReadingStatsService.shared`, `TextSubstitutionService.shared`, `SpeechRenderCoordinator.shared`, `ReaderAutoplayRequests.shared`, `ReadingListOpenRequests.shared`, `WindowSwitchRequests.shared`, `PlaybackMemoryGuard.shared`.
- Parts of `Views/Reader/ReaderView.swift`: `ReaderWhereAmIToolbarButton:251`, `ReaderLoadFailureView:290`, `ReaderLocationHeader:316`, `ReaderTextArea:373`, `ReaderErrorAlert:416`, `ReaderPanelSheets:463`, `ReaderBookInfoSheet:558`, `ReaderPanelCommands:600`, `ReaderCloudPhaseView:673` (later), `BookVoicePickerView:822`, `BookInfoBar:1227`.
- `PlaybackControlsView`, `Views/Reader/PlaybackControlsView.swift:3`.
- `JumpToPercentPanel:161`, `JumpToTimePanel:193`, `JumpToPagePanel:221`, `JumpFieldPanel:269`, `Views/Reader/ReaderJumpPanels.swift` (first).
- `HeadingNavigatorView`, `Views/Reader/HeadingNavigatorView.swift:4` (first).
- `BookmarkPanelView`, `Views/Reader/BookmarkPanelView.swift:54` (first).
- `SleepTimerView`, `Views/Reader/SleepTimerView.swift:35` (first).
- `BookSearchView`, `Views/Reader/BookSearchView.swift:388`, model `BookSearchModel` (later; the brief lists only search of the library).
- `SpeechRefusalReportView`, `Views/Reader/SpeechRefusalReportSheet.swift:23` (later, but the stop itself must be said: section 7.26).
- `BookExportSheet`, `Views/Export/BookExportSheet.swift`, `MoveToLibrarySheet`, `Views/Feeds/MoveToLibrarySheet.swift`, and `TranscriptionPresentation`, `Views/Transcription/TranscriptionPresentation.swift` (later).

Settings window: `SettingsView`, `Views/Settings/SettingsView.swift:6`, eleven tabs (`SettingsTab:38`).

- Voice: `VoiceSettingsView:156`, `SettingsViewModel`, `VoiceCatalog.shared` (first).
- Playback: `PlaybackSettingsView:271`, `SettingsViewModel` (first, cut down: section 8).
- Stats: `ReadingStatsView`, `Views/Settings/ReadingStatsView.swift:21`, `ReadingStatsService.shared` (first).
- Sounds: `SoundEffectsSettingsView`, `SoundEffectService` (later: no sounds to offer, section 5).
- Shortcuts: `KeyboardShortcutsSettingsView`, `KeyboardShortcutManager` (never on the phone in this form).
- Text: `SubstitutionsSettingsView`, `RepeatedSymbolsSettingsView`, `TextSubstitutionService.shared` (later).
- Braille: `BrailleSettingsView`, `BrailleTableCatalog` (later).
- Library: `LibraryViewsSettingsView`, `LibraryViewEditorSheet`, `LibraryViewEditorModel`, `LibraryViewsSettingsActions` (later; the shipped views work without it).
- Feeds: `FeedSettingsView`, `FeedCenter` (later).
- Storage: `StorageSettingsView`, `LogsSettingsSection`, `AudioEditingSettingsSection`, `DuplicateFinderView` (later, except the Import Behavior and Removal Behavior choices).
- Miscellaneous: `MiscellaneousSettingsView`, `MediaGestureDetector` (later or never: section 8).

Later windows and sheets.

- Record window: `RecordingWindowView`, `Views/Recording/RecordingWindowView.swift`, `RecordingWindowModel`, `RecordingWindowController`, `Platform/macOS/Views/Recording/RecordingWindowController.swift`.
- Audio editor: `AudioEditorView`, `Views/AudioEditor/AudioEditorView.swift`, `AudioEditorModel`, `AudioEditorLauncher`, `AudioEditorWindowController`, `Platform/macOS/Views/AudioEditor/`.
- Feeds: `AddFeedSheet`, `FeedInfoSheet`, `OPMLImportSheet`, `FeedRows`, `FeedDownloadProgressSection`, `MoveToLibrarySheet`, all in `Views/Feeds/`, over `FeedCenter`, `Services/Feeds/FeedCenter.swift`.
- Export: `BookExportSheet`, `BrailleExportOptionsView`, `Views/Export/`, `BookExportModel`, `Services/Export/`.
- Transcription: `TranscriptionSheet`, `TranscriptCleanupSheet`, `Views/Transcription/`, `TranscriptionJobCenter`, `TranscriptionSheetModel`.
- Editing text and manifests: `BookTextEditor`, `BookManifestEditor`, `Platform/macOS/Services/`.

### 1.2 Menu commands

Almost every menu item posts a notification (`App/MenuCommands.swift`), and the window that takes it acts. Names are at `App/MenuCommands.swift:847-978`. Reader listeners are `setupNotifications()`, `ReaderViewModel.swift:1118-1401`, unless named otherwise.

File (`FileCommands`, `App/MenuCommands.swift:125-161`; plus `BookCommands:678-684`):

- `ShortcutAction.openBook.title` "Open Book…" posts `.openBookFile` to `LibraryWindowRouter`, then `LibraryWindowView.takeGlobalAction`, `Views/ContentView.swift:414-416`, sets `showFileImporter`. First.
- "New from Text…" posts `.newFromText`, `Views/ContentView.swift:417-419`. Later.
- "New Recording…" calls `RecordingWindowController.shared.show(library:)`. Later.
- `BookExportWording.commandTitle` calls `ExportCommandRouting.exportFromWindowInFront()`. Later.

Playback (`PlaybackCommands:163-249`):

- "Play / Pause": `.togglePlayback`, `ReaderViewModel.swift:1127`, `togglePlayPause()`, `ReaderViewModel+Playback.swift:366`. First.
- "Skip Forward": `.skipForward`, `:1141`, `skipForward(useShiftUnit:)`, `ReaderViewModel+Navigation.swift:130`. First.
- "Skip Backward": `.skipBackward`, `:1149`, `skipBackward(useShiftUnit:)`, `ReaderViewModel+Navigation.swift:145`. First.
- "Cycle Forward Navigation Unit": `.cycleForwardNavigationUnit`, `:1157`, `cyclePlaybackSkipUnit(direction:)`, `ReaderViewModel+Navigation.swift:58`. First.
- "Cycle Backward Navigation Unit": `.cycleBackwardNavigationUnit`, `:1164`, the same. First.
- "Increase Speed": `.increaseSpeed`, `:1171`, `stepSpeed(forward: true)`, `ReaderViewModel+VoiceAndSpeed.swift:16`. First.
- "Decrease Speed": `.decreaseSpeed`, `:1178`, `stepSpeed(forward: false)`. First.
- "Where Am I?": `.whereAmI`, `:1260`, `whereAmI(.brief)`, `ReaderViewModel+WhereAmI.swift:34`. First.
- "Where Am I? Full Summary": `.whereAmIFull`, `whereAmI(.full)`. First.
- "Release Media Controls" (while `canReleaseMediaControls`): `.releaseMediaControls`, `:1134`, `releaseMediaControls()`, `ReaderViewModel+Playback.swift:353`. First, as the phone's way to stop.
- "Copy Reading Position": `.copyReadingPosition`, `:1281`, `copyReadingPosition()`, `ReaderViewModel+WhereAmI.swift:773`. Works on iOS through `UIPasteboard` (`:780-782`). Cheap to keep.
- "Search in Book": `.searchInBook`, `Views/Reader/ReaderView.swift:619`. Later.

Navigate (`NavigationCommands:251-343`):

- "Go to Library": `.goToLibrary`, router. On the phone: back to the list.
- "Go Back": `.goBack`, `Views/Reader/ReaderView.swift:635`, `goBack()`, `ReaderViewModel+Bookmarks.swift:371`; in a Library window `Views/ContentView.swift:242`.
- "Go Forward": `.goForward`, `Views/ContentView.swift:247`, Library windows only.
- "Next Heading": `.nextHeading`, `:1185`, `nextHeading()`, `ReaderViewModel+Navigation.swift:833`. First.
- "Previous Heading": `.previousHeading`, `:1192`, `previousHeading()`, `:852`. First.
- "Go to Page…": `.goToPage`, `:1200`, `requestGoToPage()`, `ReaderViewModel+Pages.swift:332`. First.
- "Next in Reading List": `.nextInReadingList`, `:1208`, `goThroughReadingList(.down)`, `ReaderViewModel+ReadingList.swift:194`.
- "Previous in Reading List": `.previousInReadingList`, `:1215`, `goThroughReadingList(.up)`.
- "Next in Folder": `.nextInFolder`, `:1223`, `goThroughFolder(.down)`, `ReaderViewModel+FolderNavigation.swift:41`.
- "Previous in Folder": `.previousInFolder`, `:1230`, `goThroughFolder(.up)`.
- "Show Headings": `.showHeadingList`, `Views/Reader/ReaderView.swift:607`, sets `panels.headings`. First.
- "Show Sleep Timer": `.showSleepTimer`, `Views/Reader/ReaderView.swift:615`. First.
- "Book Info": `.showBookInfo`, `Views/Reader/ReaderView.swift:643`; in a Library window, by `LibraryInfoRow.infoCommand`. First.

Library (`LibraryCommands:345-567`). Each is answered in `LibraryView` through `takesCommand(_:)`, `Views/Library/LibraryView.swift:1667`.

- "Import Folder…": `.importDAISYFolder`, `presentDAISYFolderPanel()`, `Views/ContentView.swift:478`, an `NSOpenPanel` behind `#if os(macOS)`. Later.
- "Speak Import Progress": `.speakImportProgress`, `speakImportProgress()`, `LibraryViewModel+Import.swift:541`. First, as a button on the progress view.
- "Speak Download Progress", "Add Feed…", "Refresh All Feeds", "Import OPML…", "Export OPML…": later.
- "Speak Info", "Speak Full Info": `.speakInfo`, `.speakFullInfo`, `LibraryView.speakSelectedInfo(_:)`, `Views/Library/LibraryView.swift:1700`, `LibraryInfoSpeaker`; in a reader `speakInfo(_:now:)`, `ReaderViewModel+SpeakInfo.swift:27`. Optional first; row actions are the phone's place for it.
- "Edit Mode": `.toggleEditMode`, `Views/Library/LibraryView.swift:791-798`. First.
- "New Folder": `.newFolder`, `:768-773`. First.
- "Move to Folder...": `.moveToFolder`, `:774-778`, `moveToFolder(_:)`, `:1567`. First.
- "Move Book Up", "Move Book Down": `.moveBookUp`, `.moveBookDown`, `LibraryOrderCommandsSupport`, `:2170`. First as row actions.
- "Add to Reading List", "Remove from Reading List": `.addToReadingList`, `.removeFromReadingList`, `performReadingListCommand(_:)`, `:1503`. First.
- "Folder or Feed Settings": `.showFolderOrFeedSettings`, `openFolderSettings(_:)`, `:1754`. Later.
- "Go to View" submenu: `.goToLibraryView`, `goToView(numbered:)`, `:1847`. Never (a picker does it).
- "Keep on This Mac", "Stop Keeping on This Mac": later (cloud).
- Remove, titled by `LibraryRemoveCommandWording.menuBarTitle`: `.removeFromLibrary`, `:759-766`, `removeBooks(_:)`, `LibraryViewModel+BookOperations.swift:21`. First.

Bookmarks (`BookmarkCommands:572-594`):

- "Toggle Bookmark": `.addBookmark`, `:1237`, `toggleBookmarkAtCurrentPosition()`, `ReaderViewModel+Bookmarks.swift:69`. First.
- "Show Bookmarks": `.showBookmarkList`, `Views/Reader/ReaderView.swift:611`. First.
- "Next Bookmark": `.nextBookmark`, `:1244`, `goToNextBookmark()`, `ReaderViewModel+Bookmarks.swift:237`. First.
- "Previous Bookmark": `.previousBookmark`, `:1251`, `goToPreviousBookmark()`, `:248`. First.

Book (`BookCommands:668-749`), answered in `ReaderBookCommandsSupport`, `Views/Reader/ReaderBookCommands.swift:63-116`. All later:

- Edit Text in Default Editor, Edit Text With…: `editText(choosingApp:)`, `:209`.
- Edit Manifest in Default Editor, Edit Manifest With…: `editManifest(choosingApp:)`, `:220`.
- Transcribe Audio… or Retranscribe Audio…: `transcribe()`, `:159`.
- Clean Up Transcript (Experimental)…: `cleanUpTranscript()`, `:167`.
- Delete Transcript…: `deleteTranscript()`, `:198`.
- Edit Audio…: `editAudio()`, `:190`.
- Move to Library…: `requestMoveToLibrary()`, `:178`.

Actions with a key and no menu item (`Models/KeyboardShortcut.swift:8-146`): "Up One Level", "Restart Sleep Timer" (`:1301`, `restartOrStartLastSleepTimer()`, `ReaderViewModel+Playback.swift:3283`), "Open Selected Book", "Select All", "Go to View 1" to "Go to View 9". The Restart Sleep Timer action is worth a button on the phone.

The Mac's `KeyboardShortcutManager` (`Services/KeyboardShortcutManager.swift`) posts these same notifications from an `NSEvent` monitor, which exists only on the Mac (`:42-44`, `:109-113`, `:574-586`).

## 2. Feature to code

Every call below is `@MainActor`. A view reads the published state named and calls the function named.

### 2.1 Library list

- Holds the rows: `LibraryViewModel.library`, `ViewModels/LibraryViewModel.swift:117`, `@Published`.
- The list for a place: `displayedBooks(at:matching:)`, `LibraryViewModel+FolderManagement.swift:396`, with a `LibraryLocation`, `Models/LibrarySortState.swift:14`. Derived once and cached by `LibraryListCache`.
- Live time left in rows: `livePositions`, `ViewModels/LibraryViewModel.swift:154`, `entry(for:)`, `LiveReadingPosition`, `ViewModels/LiveReadingPositions.swift:86`.
- Open a book: `ReadingListOpenRequests.shared.open(_:shownIn:libraryIsMoving:with:)`, `Services/ReadingListOpenRequests.swift:79`, wraps the opener so the Reading List marks the open.
- Continue button: `lastOpenedBook`, `LibraryViewModel+BookOperations.swift:966`.
- Which books are open: `openBookIDs`, `ViewModels/LibraryViewModel.swift:173`.
- Remove: `removeBooks(_:)`, `LibraryViewModel+BookOperations.swift:21`, which either asks, through `showRemoveBookDialog` and `pendingRemoveBooks`, `ViewModels/LibraryViewModel.swift:206-207`, or removes; the dialog's answers are `removeBooksAndDelete(_:)`, `:111`, and `removeBooksFromLibraryOnly(_:)`, `:41`.
- Errors: `errorMessage`, `errorTitle`, `showError`, `ViewModels/LibraryViewModel.swift:155-167`. The root view must present them (`Views/ContentView.swift:187-191`).
- Plain types: `Book`, `Models/Book.swift`, with `isUnopened:248`, `estimatedTimeRemaining(wpm:):1028`, `percentComplete:1064`, `restsAtEnd:1085`; `BookFormat.displayName:64`; `CountWording`, `Models/CountWording.swift:10`; `LibrarySelectionPolicy`, `Views/Library/LibraryView.swift:80`.
- Static word helpers usable off the view: `BookRow.progressText(for:)`, `spokenProgress(for:besideDownloadPercentage:)`, `timeRemaining(for:wpm:)`, `remainingText(_:)`, `accessibilityHint(isEditMode:isEditSelected:)`, `Views/Library/LibrarySubviews.swift:568`, `:636-670`.

### 2.2 Folders

- List: `subfoldersOf(_:)`, `LibraryViewModel+FolderManagement.swift:378`; count: `bookCount(inFolderTree:)`, `:418`.
- Create: `createFolderReturningOutcome(name:parentPath:)`, `:27`.
- Rename: `renameFolderReturningOutcome(_:to:)`, `:238` (async).
- Move a folder: `moveFolderReturningOutcome(_:toParent:)`, `:208` (async).
- Delete: `folderHasContents(_:)`, `:302`; `offersDeleteFolder(_:)`, `:316`; `removeFolder(_:)`, `:372`; `removeFolderMovingContentsReturningOutcome(_:toPath:)`, `:100`; `removeFolderAndEverything(_:)`, `:138`. Dialog state: `showDeleteFolderDialog`, `pendingDeleteFolder`, `showDeleteFolderDestinationSheet`, `showDeleteEverythingConfirm`, `ViewModels/LibraryViewModel.swift:213-216`.
- Move books: `moveBooksReturningOutcome(_:toFolder:)`, `LibraryViewModel+BookOperations.swift:284`; default destination `lastMovedFolderPath`, `ViewModels/LibraryViewModel.swift:210`.
- Plain types: `BookFolder`, `Models/BookFolder.swift`; `FolderNavigationHistory`, `Models/FolderNavigationHistory.swift:8` (a class with no platform code; `parentPath(of:):76`, `announcement(for:library:feedCount:):92`); `FolderSheetNavigation`, `Views/Library/LibraryView.swift:123`; `OperationOutcome`, `Models/OperationOutcome.swift:9`; `FolderOperationConflict`.
- `announcement(for:library:feedFolders:)`, `Views/Feeds/FeedLibraryPresentation.swift:124`, is the one a window uses.

### 2.3 Sorting

- Read: `sortState(at:)`, `LibraryViewModel+SortAndOrder.swift:242`, returns `LibrarySortState`, `Models/LibrarySortState.swift:185`.
- Change: `userChangedSort(_:at:)`, `:255`, with `LibrarySortChange.choose(_)` or `.reverseDirection`, `Models/LibrarySortState.swift:140`; say `shown.changeAnnouncement`.
- To subfolders: `applySortToSubfolders(_:from:)`, `:282`.
- Manual order: `moveBook(_:direction:in:)`, `:338`, returns `MoveResult` with `placeAnnouncement`; `reorderBooks(in:from:to:)`, `:390`; `LibraryLocation.reorderTarget(sortedBy:)`, `Models/LibrarySortState.swift:107`; `LibraryManualMoves`, `Views/Library/LibrarySubviews.swift:697`.
- Plain types that need nothing else: `LibrarySortField`, `ViewModels/LibraryViewModel.swift:5`; `LibrarySortState` with all its words; `LibraryBookSorter`, `Models/LibraryBookSorter.swift`.

### 2.4 Library views

- Shipped views: `LibraryViewDefinition.shipped(_:)`, `Models/LibraryViewDefinition.swift:365`, `:384`.
- The list: `LibraryViewDefinitionStore.shared`, `Models/LibraryViewDefinitionStore.swift:20`, `list`, `:45`, `@Published`.
- What a picker offers: `applicableViews(in:center:)`, `LibraryViewModel+Views.swift:31`; `offeredViews(in:current:center:applicable:)`, `:39`; `shownView(_:in:center:)`, `:52`.
- Center: `LibraryFeedFolders.shared.center`, `Views/Feeds/LibraryFeedFolders.swift:22`, needed even with no feeds.
- Plain types: `LibraryViewID`, `LibraryCategory`, `ViewModels/LibraryViewModel.swift:22`, `LibraryViewFilterEvaluator`, `LibraryViewPickerWording`.
- Reuse the model. The picker itself is 15 lines (`Views/Library/LibraryView.swift:1859-1873`).

### 2.5 Book info

- Which editor: as `ReaderBookInfoSheet` chooses (`Views/Reader/ReaderView.swift:558-593`), or in a list `showBookInfo(for:)`, `bookInfoSheet(for:)`, `bookInfoEditor(for:)`, `Views/Library/LibraryView.swift:2048`, `:2065`, `:2077`.
- Reads off the main thread: `LibraryBookInfoLoader.info(for:)`, `Views/Library/LibraryBookInfoLoader.swift:68`, giving `LibraryBookInfo`, `:6`.
- Saves: `updateBookMetadata(_:of:contentHash:)`, `LibraryViewModel+BookOperations.swift:724`; `saveEPUBMetadata(_:openedAs:for:writingToFile:writer:)`, `:780`. Reader wrappers: `saveEPUBMetadata(_:openedAs:writeToFile:writer:)`, `ReaderViewModel+Bookmarks.swift:443`; `saveAudioMetadata(_:openedAs:)`, `:476`.
- On iOS `EPUBParser.updateOPFMetadata` throws `IOSUnavailable` for "Saving a book's details into its EPUB file" (`docs/architecture/platforms.md:67`), so hide "Also write to the library's copy of the EPUB file" there.
- Plain types: `BookInfoFacts`, `LibraryInfoWording`, `Models/LibraryInfoWording.swift:8`, `:617`; `MetadataEditorWording`, `Views/Reader/MetadataEditorView.swift:356`; `EPUBMetadata`, `AudioMetadata`.

### 2.6 Search of the library

- `displayedBooks(at:matching:)`, `LibraryViewModel+FolderManagement.swift:396`, with the search text. `LibraryView.filteredBooks`, `Views/Library/LibraryView.swift:2029`, is that one call. `.searchable(text:prompt:)` at `:503` works on iOS.

### 2.7 Importing

- Entry: `importFiles(urls:toFolder:from:addingToReadingList:)`, `LibraryViewModel+Import.swift:888`, as the Mac's `.fileImporter` calls it (`Views/ContentView.swift:167-186`), or `importAndOpenFiles(urls:from:)`, `:135`, for a file handed in from outside (share sheet, Open In). Pass `origin` nil.
- Types for the picker: `FileImportService.supportedTypes`, `Services/FileImportService.swift:2843`. Its `UTType(importedAs:)` entries (`:2874-2886`) and `UTType("com.textmouth...")` entries (`:2911-2920`) rely on declarations in `Resources/Info.plist`, which the iOS target leaves out (`project.yml:278-280`). Not run.
- Security scope: each async path takes it itself (`LibraryViewModel+Import.swift:293`, `:569`, `:660`), but `importSources(for:)`, `:157`, touches the folder first, outside any scope, through `DAISYParser.packageEntryPoints(in:)`.
- Progress: `isImporting`, `ViewModels/LibraryViewModel.swift:220`; `importProgress`, `:225`, `ImportProgress.state`, `ViewModels/ImportProgress.swift:232-249`, with `details(at:):179`, `lines(at:):201`, `spokenStatus(at:):210`. `LibraryWindowView.importProgressOverlay(for:at:)`, `Views/ContentView.swift:620`, builds the overlay.
- Cancel: `cancelImports()`, `LibraryViewModel+Import.swift:491`.
- Questions: `importDecisions`, `ViewModels/LibraryViewModel.swift:203`; `.current`, `Models/ImportDecisionQueue.swift:25`; `currentImportDecisionWording`, `LibraryViewModel+Duplicates.swift:38`; `answerImportDecision(_:with:)`, `:228`.
- Opening what was imported: set `library.readerOpener`, `ViewModels/LibraryViewModel.swift:232`, to the iPhone's own opener.
- Plain types: `ImportDecision`, `ImportDecisionAnswer`, `ImportDecisionWording`, `Models/ImportDecision.swift:50`, `:178`, `:215`; `ImportDecisionQueue`; `ImportProgressWording`, `Models/ImportProgressWording.swift:6`; `ImportStep`, `ImportFailure`, `Services/ImportFailure.swift`; `OriginalFileDeletionWording`.
- What iOS cannot read today: every conversion, through `WatchedProcess+iOS`. A Word 6 or 95 document says "Converting this kind of file is not available on iPhone yet."; Ogg, Opus, AC-3, AMR, and the rest of `ImportAudioConverter.convertedExtensions`, `Services/ImportAudioConverter.swift:41-58`, fail the same way (`.convert` verdict, `Parsers/AudioContentSniffer.swift:110-111`); braille needs the helper, so BRF, BRL, and PEF import fail at translation (`BrailleTranslator`, not run). MP3, ADTS, WAV, AIFF, and FLAC are `.leave` (`:112-113`).

### 2.8 Reader for text

- Make: `BookReaderWindowView.makeReader(book:libraryViewModel:settingsViewModel:showBook:requestedBookID:...)`, `Views/Reader/BookReaderWindowView.swift:54`, is `static` and compiles on iOS; it sets `nextBookWindowSwitcher` and releases a sleep timer held for a book that is gone.
- Play: `togglePlayPause()`, `ReaderViewModel+Playback.swift:366`; `playOrResume()`, `:175`; `pause()`, `:316`; `stop()`, `:482`; `play()`, `:37`.
- State: `isLoading`, `content`, `headings`, `bookmarks`, `errorMessage`, `isCurrentlyPlaying`, `isCurrentlyPaused`, `isWhereAmISpeaking`, `currentWPM`, `hasSavedPosition`, `displayChapterIndex`, `displayCharacterOffset`, `displayVisibleTextWindow`, `readingListPlace`, `goToPageRequests`, `ReaderViewModel.swift:148-223`, `:306`, `:375`.
- Play button rule: playing when `isCurrentlyPlaying && !isCurrentlyPaused` (`Views/Reader/PlaybackControlsView.swift:143-155`), `isPlaybackActivelyAdvancing`, `ReaderViewModel.swift:2032`.
- Status: `displayFormattedPercentComplete:2144`, `displayFormattedTimeRemaining:2140`, `displayTimeRemaining:2132`, `formattedTotalTime:949`, `totalEstimatedTime:929`, `displayHeadingPosition`, `ReaderViewModel+WhereAmI.swift:738`, `locationTitle(for:chapterIndex:)`, `:745`.
- Text shown: `displayVisibleTextWindow`, at most `maxDisplayChars` 20,000, `ReaderViewModel.swift:1852`; `VisibleTextWindowPolicy`, `:14`, is plain.
- Plain types: `ChapterSpeechInputs`, `ChapterSpeech`, `SpeechMarkupGuard`, `ComposedOffsetMap`.

### 2.9 Reader for audio

- The same reader: `isAudioBook`, `ReaderViewModel.swift:332`. Same `togglePlayPause()`, `skipForward`, `skipBackward`.
- Speed: `audioSpeed`, `:363`, `@Published`; `setAudioSpeed(_:)`, `ReaderViewModel+Playback.swift:2517`; `stepSpeed(forward:)`; `AudioSpeed`, `Services/AudioPlaybackService.swift:393`, plain.
- Clock: `placeClock`, `ReaderViewModel+Jump.swift:114`, `timeCount`, `:128`.
- Trap: an audiobook's chapter text is spaces (`Parsers/AudioBookParser.swift:185`, `:199`, `:295`, `:380`). `SkipUnit.sentence` and `.paragraph` find nothing to stop at: `nextSentence()`, `ReaderViewModel+Navigation.swift:356-377`, passes over every chapter whose trimmed text is empty and does nothing and says nothing; `previousSentence()`, `:382-411`, goes to the chapter's start, and at a chapter's start falls through to chapter 0. `navigationUnitChoices(bookHasPages:keeping:)`, `ReaderViewModel+Pages.swift:108`, offers both anyway. The spec should leave them out for audiobooks.

### 2.10 Voices and rate

- Voices: `VoiceCatalog.shared`, `Services/VoiceCatalog.swift:24`; `voices`, `languages`, `isLoaded`, `:28-33`; `loadIfNeeded()`, `:70`; `voices(forLanguage:)`, `:111`; `listNow()`, `:81`. Quality: `qualityLabel`, `Parsers/ParserUtilities.swift:9`.
- This book: `setLocalVoice(_:)`, `ReaderViewModel+VoiceAndSpeed.swift:57`; `adjustSpeed(delta:)`, `:33`; `stepSpeed(forward:)`, `:16`; `adjustPitch(to:)`, `:46`; `saveSettingsToGlobal()`, `:129`; `resetToGlobalSettings()`, `:147`; `hasLocalSettings`, `:173`.
- Read: `speechService.currentVoice`, `.wordsPerMinute`, `.pitchMultiplier`, `Services/SpeechService.swift:658-669`; forwarded `currentWPM`. Limits `minimumWPM` 50, `maximumWPM` 650, `:994-995`; `speechSpeedStep` 25, `ReaderViewModel+VoiceAndSpeed.swift:11`.
- Global: `SettingsViewModel.selectedVoiceID:194`, `wordsPerMinute:367`, `pitchMultiplier:373`, `availableVoices:317`, `availableLanguages:319`, `refreshVoices()`, `selectedVoice`, `voiceQualityLabel(_:)`.
- Plain: `SpeechService.rateForWPM(_:):2311`, `clampedPitch(_:):2202`, `pitchLabel(_:):2207`.
- `BookVoicePickerView.ReaderState`, `Views/Reader/ReaderView.swift:829`, shows how to follow a reader without 8 Hz redraws.

### 2.11 Navigation units

All go through `performSkip(unit:forward:)`, `ReaderViewModel+Navigation.swift:230`, from `skipForward(useShiftUnit:)`, `:130`, and `skipBackward(useShiftUnit:)`, `:145`. The two skip entries debounce 0.4 seconds (`skipDebounceWindow`, `ReaderViewModel.swift:721`; `acquireSkipToken()`, `ReaderViewModel+Navigation.swift:167`): a second quick press is dropped in silence.

- Unit state: `playbackSkipForwardUnit:14`, `playbackSkipBackwardUnit:19`, resolved by `PlaybackSkipUnitPolicy.resolve`, `ViewModels/SettingsViewModel.swift:160`. Change: `setSharedPlaybackSkipUnit(_:):36`, `setPlaybackSkipUnit(_:direction:):43`, `cyclePlaybackSkipUnit(direction:):58`. Choices: `navigationUnitChoices(keeping:)`, `ReaderViewModel+Pages.swift:114`. Plain: `SkipUnit`, `ViewModels/SettingsViewModel.swift:38`, with `iconName(forward:):111`, `playbackMenuAccessibilityLabel(direction:):86`, `nextNavigationUnit:99`.
- Sentence: `nextSentence():356`, `previousSentence():382`. Pure scans: `nextSentenceStart(in:after:):504`, `sentenceStart(in:before:):524`.
- Paragraph: `nextParagraph():418`, `previousParagraph():443`. Pure: `nextParagraphStart(in:after:):543`, `paragraphStart(in:before:):566`.
- Heading: `nextHeading():833`, `previousHeading():852`, `navigateToHeading(_:):869`. Subheading: `nextSubheading():296`, `previousSubheading():314`. Pure: `headingAnnouncement(arrivingAt:in:):336`, `nextHeading(in:chapterIndex:characterOffset:):1112`, `previousHeading(in:chapterIndex:characterOffset:):1125`.
- Page: `nextPage()`, `previousPage()`, `ReaderViewModel+Pages.swift:185`, `:203`. Pure: `nextPage(in:chapterIndex:characterOffset:isPassedOver:):57`, `previousPage(...)`, `:73`, `unit(after:bookHasPages:):94`.
- Bookmark: `goToNextBookmark()`, `goToPreviousBookmark()`, `ReaderViewModel+Bookmarks.swift:237`, `:248`.
- Time: `skipByTime(seconds:)`, `:693` (text), `skipCharacters(count:)`, `:768` (audio, 10 characters a second, `audioCharsPerSecond`, `ReaderViewModel.swift:708`). A skip by time announces nothing.
- Every jump: `navigateTo(chapterIndex:characterOffset:)`, `:893`. Return keeps a place: `navigatePreservingReturnPosition(chapterIndex:characterOffset:)`, `ReaderViewModel+Bookmarks.swift:401`; `returnToSavedPosition()`, `:409`; `goBack()`, `:371`; `autoPlayIfEnabled()`, `:385`.

### 2.12 Go to Page

- `requestGoToPage()`, `ReaderViewModel+Pages.swift:332`; `goToPage(typed:)`, `:255`, jumps and returns nil, or returns the refusal; `goToPageStartingText:225`; `goToPageLabelIsRepeated(_:):237`; `bookPages:13`; `hasPages:18`; `hasSeveralPages:29`; `currentPagePosition:41`; `displayPagePosition:47`.
- Plain: `JumpInputValidator.page(_:in:currentIndex:)`, `Views/Reader/ReaderJumpPanels.swift:38`; `JumpFieldOutcome.taking`, `:143`; `BookPages`, `PageBreak`, `PagePosition`, `Models/BookPages.swift:63`, `:7`, `:130`; `ReaderPageWording`, `Models/ReaderPageWording.swift:9`.

### 2.13 Jump to time and percent

- `goToTime(typed:)`, `goToPercent(typed:)`, `ReaderViewModel+Jump.swift:78`, `:61`; `jumpToTime(seconds:)`, `:44`; `jumpToPercent(_:)`, `:22`; `goToTimeStartingText:146`; `goToPercentStartingText:156`; `namedListeningSpeed:136`.
- Plain: `JumpInputValidator.percent`, `.time`, `Views/Reader/ReaderJumpPanels.swift:70`, `:94`; `TimeEntry`, `Models/TimeEntry.swift`; `PlaceClock`, `Models/PlaceClock.swift`; `ReaderTimeWording`, `Models/ReaderTimeWording.swift:6`; `TimeFormatting`, `Models/DocumentContent.swift:525`.

### 2.14 Bookmarks

- `toggleBookmarkAtCurrentPosition()`, `ReaderViewModel+Bookmarks.swift:69`; `addBookmarkAtCurrentPosition(label:)`, `:149`; `updateBookmarkLabel(_:label:)`, `:218`; `removeBookmark(_:)`, `:258`; `navigateToBookmark(_:)`, `:264`; `hasNearbyBookmark:48`; `headingText(forBookmark:):56`.
- State: `bookmarks`, `ReaderViewModel.swift:202`.
- Plain: `Bookmark`, `Models/Book.swift:1723`, `accessibilityLabel(headingText:):1777`, `dateText:1789`; `BookmarkCommand`, `Views/Reader/BookmarkPanelView.swift:641`; and these `nonisolated static` helpers on the view: `listOrder(of:):539`, `focusTarget(after:in:):559`, `nearestBookmark(toChapter:offset:in:):591`, `neighbor(of:offset:in:):617`, `emptyListHelp(keys:):456`.

### 2.15 Where Am I?

- `whereAmI(_:)`, `ReaderViewModel+WhereAmI.swift:34`, `.brief` or `.full`; `cancelWhereAmIIfActive()`, `:416`; state `isWhereAmISpeaking`, `ReaderViewModel.swift:220`.
- Pure: `briefWhereAmISummary(...)`, `:146`; `fullWhereAmISummary(...)`, `:212`; `whereAmISummary(parts:quoting:)`, `:266`; `whereAmIQuote(of:)`, `:298`; `readingPositionSummary(...)`, `:830`; `SummaryPress`, `SummaryDetail`, `Models/SummaryPress.swift:33`, `:9`; `HeadingPosition`, `Models/DocumentContent.swift:318`.
- It speaks with its own `whereAmISynth`, `ReaderViewModel.swift:389`, in the book's voice and speed, not through VoiceOver.

### 2.16 Sleep timer

- `startSleepTimer(duration:startPlaybackIfNeeded:)`, `ReaderViewModel+Playback.swift:3128`; `cancelSleepTimer()`, `:3248`; `restartSleepTimer(startPlaybackIfNeeded:)`, `:3260`; `restartOrStartLastSleepTimer()`, `:3283`.
- Observe `sleepTimerService`, `ReaderViewModel.swift:234`: `SleepTimerService.shared`, `Services/SleepTimerService.swift:35`; `isActive:37`, `remainingSeconds:38`, `duration:39`, `isFadingOut:40`, `lastUsedDuration:71`, `formattedRemaining:1074`, `spokenStatus:1088`, `spokenLabel:1097`.
- Hand-over: `claimSleepTimerHandOver()`, `ReaderViewModel+SleepTimerHandOver.swift:230`.
- Plain: `SleepTimerDuration`, `Models/DocumentContent.swift:446`; `SleepTimerHandOverWording`; `SleepTimerView`'s `nonisolated static` words (`Views/Reader/SleepTimerView.swift:309-369`); `SettingsPolicy.sleepTimerMinutes`, `Models/SettingsPolicy.swift:564`.

### 2.17 Now Playing and remote commands

- A reader's own: `nowPlayingService`, `ReaderViewModel.swift:244`, `NowPlayingSession`, `Services/NowPlayingService.swift:101`. The reader sets it up (`setupCallbacks()`, `ReaderViewModel.swift:1051-1101`) and updates it as it plays; a view does nothing.
- Coordinator: `NowPlayingService.shared`, `Services/NowPlayingService.swift:239`; `setup:462`, `focus:518`, `prepareForPlayback:552`, `unregister:613`, `setupRemoteCommands:741`, `updateNowPlayingInfo:1167`, `writeMediaPlayerNowPlaying:1223`, `clearNowPlaying:1253`.
- `canReleaseMediaControls`, `ReaderViewModel.swift:2105`; `holdsMediaControls`, `Services/NowPlayingService.swift:180`.
- What the system is told: title, artist, media type, playback rate 1 or 0 (`:1230-1234`), `playbackState` (`:1237`). No duration, no elapsed time, no artwork.
- Commands: play, pause, togglePlayPause, skipForward with `preferredIntervals = [30]`, skipBackward with `[15]`, nextTrack, previousTrack (`:755-785`). Next and previous track are skips by the reader's unit (`:935-946`); so are skipForward and skipBackward (`:923-934`), whatever interval the system displays.
- Plain: `RemoteMediaCommandPolicy`, `Services/NowPlayingService.swift:5`; `MediaGestureDetector`.

### 2.18 End of book

- `handleEndOfBook()`, `ReaderViewModel+Playback.swift:2578`; `playFromTheEnd()`, `:121`; `finishListening(announcing:)`, `:2757`; `finishAtTheEnd(replayingAFinishedEnd:)`, `:2785`; `restAtEnd()`, `:2815`; `handOverToNextBook(to:titled:askingWith:)`, `:2921`; `continueToNextBook(_:under:)`, `:3002`; `claimAutoplayRequest()`, `:3044`; `goOnPastThisBook`, `ReaderViewModel+GoingOn.swift:45`; `showNextBook`, `ReaderViewModel+NextBookWindow.swift:125`.
- Set per book: `setLocalEndOfBookBehavior(_:)`, `ReaderViewModel+Playback.swift:2863`; read `effectiveEndOfBookBehavior:2858`, `endOfBookRule:2848`, `cursorRestsAtEnd:2839`, `hasFinishedBook`, `ReaderViewModel.swift:491`.
- Succession: `succession(after:going:skippingFinished:)`, `LibraryViewModel+Succession.swift:31`.
- Plain: `EndOfBookBehavior`, `ViewModels/SettingsViewModel.swift:18`; `EndOfBookRule`, `Models/EndOfBookRule.swift:25`; `EndOfBookWording`, `Models/EndOfBookWording.swift:9`; `ListeningOptions`, `Models/ListeningOptions.swift:15`; `ReadingList`, `Models/ReadingList.swift`.

### 2.19 Saved positions

- Reader: `savePosition()`, `ReaderViewModel.swift:2151`; `savePositionIfMoved()`, `:2166`; live publish `scheduleLivePositionPublish()`, `:2195`, `publishLivePosition(now:)`, `:2210`, once a second; `PlaybackCheckpointPolicy.persistenceInterval` 30 seconds, `:132`.
- Library: `persistReadingPosition(bookID:position:markingOpened:)`, `LibraryViewModel+BookOperations.swift:689`; `updateLiveReadingPosition(bookID:position:)`, `:666`.
- Flush everything: `PlaybackMemoryGuard.savePendingWrites()`, `Services/PlaybackMemoryGuard.swift:442` or `UnsavedChangesTerminationGuard.flushPendingWrites()`, `App/UnsavedChangesTermination.swift:187`, which both compile on iOS.
- Plain: `ReadingPosition`, `Models/Book.swift:1685`; `TextAnchor`, `PlaceRelocator`.

### 2.20 Reading statistics

- `ReadingStatsService.shared`, `Services/ReadingStatsService.swift:19`; `stats:29`; the reader calls `startSession(bookID:at:):439`, `endSession(bookID:at:):454`, `markBookFinished(bookID:title:):537`. A view reads `ReadingStatsFigures(service:at:)`, `Models/ReadingStatsTile.swift:37`.
- `ReadingStatsView` reuses as it stands (2.22).

### 2.21 Settings

`SettingsViewModel`, `ViewModels/SettingsViewModel.swift:184`, is `@AppStorage`-based and mirrored in config.json through `ConfigService.shared`, `Services/ConfigService.swift:18`. Section 8 lists every key.

### 2.22 Which views can be reused

Reuse as they stand. Each compiles on iOS and holds only plain SwiftUI:

- `ReaderLocationHeader`, `ReaderLoadFailureView`, `ReaderErrorAlert`, `Views/Reader/ReaderView.swift:316`, `:290`, `:416`.
- `BookmarkRow`, `Views/Reader/BookmarkPanelView.swift:689`; `HeadingRow`, `Views/Reader/HeadingNavigatorView.swift:663`.
- `BookRow`, `FolderRow`, `TimeRemainingBar`, `BreadcrumbBar`, `Views/Library/LibrarySubviews.swift`. Their accessibility labels replace their children, so VoiceOver hears the same words; a sighted layout is crowded at phone width, since each sets several labels in one `HStack`.
- `ReadingStatsView` and `ReadingStatsTileRow`, `Views/Settings/ReadingStatsView.swift:21`, `:135`. It reads `Form`, `LabeledContent`, and a timer publisher, nothing of a window.
- `OperationFailureNotice`, `SheetWorkIndicator`, `Views/Library/LibrarySheetViews.swift:260`, `:320`.
- `ProgressOverlay`, `Views/ContentView.swift:515`: fixed width 300 fits, and `.keyboardShortcut` is inert without a keyboard.
- `PersistenceFailureBanner`, `Views/Library/PersistenceFailureBanner.swift:14`; `ProgressObserver`, `Views/ContentView.swift:641`.
- `ReaderSnapshot`, `SheetOverOneReader`, `Views/Reader/ReaderSnapshot.swift:16`, `:51`.
- `ReadOnlyTextArea+iOS`, `Platform/iOS/Views/ReadOnlyTextArea+iOS.swift:12`.

Reuse with little change. For each the change is on one or two lines, wrapped so the Mac compiles what it compiled:

- `PlaybackControlsView`, `Views/Reader/PlaybackControlsView.swift:3`. One `HStack` of up to twelve controls will not fit; its speed buttons use `.font(.caption)`, too small a target. Every action and label is right. It observes the whole reader, so it redraws 8 times a second while playing (`:4`).
- `BookInfoBar`, `Views/Reader/ReaderView.swift:1227`: five labels in one row (`:1296`). Its three-state hints are private (`:1413-1438`) and must move to be shared.
- `JumpFieldPanel`, `Views/Reader/ReaderJumpPanels.swift:269`: needs a decimal or number keyboard, and a Return on the keyboard to reach Jump.
- `HeadingNavigatorView`, `Views/Reader/HeadingNavigatorView.swift:4`: `.frame(width: 550, height: 500)` at `:357`; segmented `Picker` fixed at 280 in a row with "Back to Book" (`:259-270`). Its row-building statics are shared and pure (`:187`, `:427`, `:473`).
- `BookmarkPanelView`, `Views/Reader/BookmarkPanelView.swift:54`: `.frame(width: 380, height: 400)` at `:116`; `.onKeyPress` (`:259`, `:265`) is inert but harmless; its focus requests depend on `InitialVoiceOverFocusModifier`, a stand-in; `addBookmarkKeysInForce()`, `:465`, names a Mac key in the empty state ("Command + B adds a bookmark at the current position."). Call `emptyListHelp(keys: [])` instead.
- `SleepTimerView`, `Views/Reader/SleepTimerView.swift:35`: width 320 fits. `TextField(value:format:)` needs a number pad and a way to submit: Return runs `onSubmit` at `:222`, and the hint says so at `:325`.
- `BookVoicePickerView`, `Views/Reader/ReaderView.swift:822`: `.frame(width: 450, height: 600)` at `:1039`; `.navigationTitle` at `:1040` needs a `NavigationStack` around the sheet. Otherwise a `Form` of pickers and sliders.
- `MetadataEditorView`, `Views/Reader/MetadataEditorView.swift:16`: `.frame(width: 450, height: 550)` at `:140`.
- `LibraryBookInfoSheet`, `Views/Library/LibrarySheetViews.swift:7`: frame at `:152`.
- `ImportDecisionSheet`, `Views/Library/ImportDecisionSheet.swift:18`: `.frame(width: 460)` at `:76`; three buttons in one `HStack` (`:87-93`). Pass `takesFocus: true`.
- `NewFolderSheet`, `MoveFolderSheet`, `RenameFolderSheet`, `MoveFolderToParentSheet`, `DeleteFolderMoveContentsSheet`: frames at `Views/Library/LibrarySheetViews.swift:410`, `:817`, `:941`, `:1020`, `:1101`.
- `EditModeBar`, `Views/Library/LibrarySubviews.swift:13`: too many buttons in one row.
- `LibraryBookListRow`, `Views/Library/LibrarySubviews.swift:794`: right as the row unit (`Equatable`, cached), but its menu (`:913-1021`) offers Mac commands (Export…, Show in Finder through `cloudCommands`), and it has no tap: a book opens by VoiceOver's default action (`:896-902`) or the context menu's Open, and on the Mac by Return, `.openSelectedBook`, `Views/Library/LibraryView.swift:751`. A sighted tap on iOS does nothing.
- `AddToLibrarySheet`, `Views/Library/AddToLibrarySheet.swift:82`: fixed `width`/`height`, and `AddToLibraryHost` makes a `KeyboardShortcutManager` to show keys (`Views/Library/AddToLibraryHost.swift:54`).

Only makes sense on a Mac:

- `LibraryWindowView`, `Views/ContentView.swift:5`: `WindowAccessor`, `openWindow`, router registration, `.handlesExternalEvents`, `bringToFront()`, `.frame(minWidth: 600, minHeight: 400)` at `:166`, and `presentDAISYFolderPanel()`, whose `NSOpenPanel` is behind `#if os(macOS)` (`:478-503`).
- `LibraryView` as a whole, `Views/Library/LibraryView.swift:206`: `List(selection:)` with selection through a key window, 2,354 lines of notification receivers guarded by `takesCommand`, `.focusedSceneValue`, a toolbar of six items, and Mac-only sheets. Call its model functions instead.
- `BookReaderWindowView`, `Views/Reader/BookReaderWindowView.swift:4`: `.onDisappear` closes the reader (`:124-133`); `.focusedValue`, `.focusedSceneValue`, `WindowAccessor`, `.frame(minWidth: 600, minHeight: 400)` at `:134`.
- `ReaderView` as a whole, `Views/Reader/ReaderView.swift:14`: `@Environment(\.dismissWindow)` at `:23`, a toolbar of nine items (`:107-164`), and `.modifier(ReaderBookCommandsSupport(...))`, `:32`, which drags in Export, Transcription, and Move to Library.
- `ReaderBookCommandsSupport`, `Views/Reader/ReaderBookCommands.swift:24`; `ReaderPanelCommands`, `Views/Reader/ReaderView.swift:600`: menu commands by notification, routed by `hostWindow`.
- `SettingsView`, `Views/Settings/SettingsView.swift:6`: `windowSize` 860 by 540 (`:12`), eleven tabs. `VoiceSettingsView` and `PlaybackSettingsView` inside it are ordinary `Form`s and can be reused; `formStyle(.grouped)` comes from `SettingsTabPage` (`:147`).
- `KeyboardShortcutsSettingsView`, `StorageSettingsView`, `LogsSettingsSection`, `MiscellaneousSettingsView`: keys, folder panels, Finder, Bluetooth.
- `App/MenuCommands.swift`'s `Commands`: a phone has no menu bar. `MenuVisibilityManager`, `FrontWindowKind`, `WindowAccessor`, `SwitchedWindowFocus`, `SilentKeyEquivalent`: section 5.

What compile but do nothing on iOS, so a reused view loses them without an error: `VoiceOverFocus`, `StandardVoiceOverFocus`, `InitialVoiceOverFocusModifier`, `SilentKeyEquivalent`, `WindowAccessor`, every `.keyboardShortcut` without a hardware keyboard, `.help`, `.focusedValue`.

## 3. How a reader opens

### 3.1 On the Mac, step by step

1. VoiceOver's default action on a row (`Views/Library/LibrarySubviews.swift:896-902`), the row's Open (`:917`), or Return (`.openSelectedBook`, `Views/Library/LibraryView.swift:751`) calls `LibraryView.openBook(_:)`, `:1437`.
2. That calls `ReadingListOpenRequests.shared.open(_:shownIn:libraryIsMoving:with:)`, `Services/ReadingListOpenRequests.swift:79`, which at the Reading List leaves a request to read from the list, then calls `onOpenBook`.
3. `onOpenBook`, `Views/ContentView.swift:65-69`, refuses while the library moves, or calls `openWindow(id: BookReaderWindowView.windowID, value: book.id)`.
4. SwiftUI's `WindowGroup(for: UUID.self)`, `Platform/macOS/App/TextMouthApp.swift:51-71`, brings forward a window with that value, or makes `BookReaderWindowView(bookID:libraryViewModel:settingsViewModel:showBook:)` with `.id(bookID)`.
5. The view's `init`, `Views/Reader/BookReaderWindowView.swift:18-39`, finds the book or a placeholder "Unknown", and sets `_viewModel = StateObject(wrappedValue: Self.makeReader(...))`.
6. `ReaderViewModel.init`, `ReaderViewModel.swift:752-816`, in order: keeps its services; `libraryViewModel.registerOpenBook(book.id)` (`:785`); restores the position (`:788-791`); `applyLocalSpeechOverrides()` (`:794`); `setupCallbacks()` (`:796`), which registers with Now Playing and so claims remote commands; `setupNotifications()`; `observeSpokenAudioSettings()`; `observeLibraryUpdates()`; `observeReadingList()`; `observeSleepTimerHandOvers()`; `forwardSpeechState()`; `followPlaybackForMemoryGuard()`; `setupAudioCallbacks()` for an audiobook; and `loadContent()` (`:815`). The reader starts loading in its initializer.
7. `loadContent()`, `:1455`, reads on `loadQueue`, a global queue, through `readContent(of:)`, `:1492`. Then `finishLoading`, `:1643`, and `showLoadedContent(_:readFrom:)`, `:1660`, on the main actor: publishes `content` and headings, brings the place into range, sets `hasFinishedBook`, `isLoading = false`, saves, `refreshPlaybackUI()`, `claimSleepTimerHandOver()`, `placeFocusAfterSwitchIfDue()`, `claimAutoplayRequest()`, `prepareOpenedChapterSpeech()`.
8. The view's `body`: `ReaderView(viewModel:)`, with `WindowAccessor` (`:90-105`), whose `onWindowFound` calls `viewModel.attach(to: window)` (`ReaderViewModel+NextBookWindow.swift:96`) and `LibraryWindowRouter.shared.registerReaderWindow`; `onWindowBecameKey` calls `viewModel.windowBecameKey()` (`ReaderViewModel.swift:2116`). `onAppear` calls `libraryViewModel.markBookOpened(bookID)` (`:121`).
9. `ReaderView.onAppear` sets `viewModel.soundEffectService` (`Views/Reader/ReaderView.swift:28-30`). Until then the reader makes no sounds.
10. A press of Play: `togglePlayPause()`, then `play()` (`ReaderViewModel+Playback.swift:37`): claims media controls (`nowPlayingService.activateRemoteCommandsIfNeeded()`, `:76`), plays the sound, `recordPlaybackStarted()`, `readingStatsService.startSession`, `sleepTimerService.resumeCountdown`, then speech or audio (section 6).

### 3.2 What it needs and who owns it

- Needs: a `Book`, `LibraryViewModel`, `SettingsViewModel`. Everything else defaults to a shared store (`ReaderViewModel.swift:756-764`).
- Owner on the Mac: `@StateObject` in `BookReaderWindowView`. SwiftUI keeps a closed window's views for the session, so `close()` must let go of everything by hand (`releaseWhatGrowsWithTheBook()`, `:2307`).
- Window type: `weak var hostWindow: PlatformWindow?`, `:382`. Nil is a supported state: tests run that way, and `WindowCommandRouting.shouldAccept` returns true for a nil host (`Views/Library/LibraryView.swift:30`).

### 3.3 What happens at close

`close()`, `ReaderViewModel.swift:2239-2290`, guarded by `hasClosed`: ends the next-episode wait; `endCloudWorkForClose()`; cancels UI work; `stop()` (`ReaderViewModel+Playback.swift:482`), which stops speech or audio, ends the listening session, clears Now Playing, and saves; `savePosition()`; `stopWhereAmISynthesizer()`; `nowPlayingService.clearNowPlaying()`; `nowPlayingService.close()` (`unregister`); stops a sleep timer it owns unless it is held for the next book; `forgetLastOwner`; `removeWorkingCopy()`; `bookUpdates.unwatch`; `unregisterOpenBook`; `cancelHeld` when no other reader of the book is left; `releaseWhatGrowsWithTheBook()`, which empties `cancellables` and sets `content = nil`. A closed reader is finished: it never plays again, and a new one must be made.

There is no `deinit` cleanup, since `deinit` is not main-actor isolated.

### 3.4 What is saved, and when

- Position, durably: at the end of a load (`:1734`); every pause that paused something (`ReaderViewModel+Playback.swift:3431`); every stop of active playback (`:574`); every jump (`ReaderViewModel+Navigation.swift:941`, `:971`); every 30 seconds of playback (`ReaderViewModel.swift:2218-2225`); at close (`:2254`); as Where Am I? pauses (`ReaderViewModel+WhereAmI.swift:92`).
- Position, live: once a second to `LiveReadingPositions` (`ReaderViewModel.swift:2227`), never to disk.
- Where it goes: `persistReadingPosition`, the book's record at once and library.json within five minutes, or within half a second after a close (`docs/architecture/reading-a-book.md:11`, `:17`).
- Statistics: `startSession` at each play (`ReaderViewModel+Playback.swift:79`), `endSession(bookID:)` at each pause and stop (`:3409`, `:564`) and book end (`:2582`); `checkpointActiveSession` once a minute (`defaultCheckpointInterval`, `Services/ReadingStatsService.swift:23`); `markBookFinished` at an end.
- Per-book settings: at each change, through `saveLocalVoiceSettings()`, `updateLocalSkipUnits`, `updateEndOfBookBehavior`, `updateSkippedHeadings`.

### 3.5 Window seams of the reader, each place

- `ReaderViewModel.swift:382`: `hostWindow`, nil on iOS.
- `ReaderViewModel.swift:1109-1116`: `isTargetedNotification`, true with a nil host.
- `ReaderViewModel.swift:1333-1335`: the restart gesture's fallback, passes with a nil host.
- `ReaderViewModel.swift:553`: `placeFocusAfterSwitch`, a stand-in.
- `ReaderViewModel.swift:2116`: `windowBecameKey()`, which nothing calls on iOS.
- `ReaderViewModel+NextBookWindow.swift:42-60`: `windowStanding`, `.noWindow` on iOS, unless `windowStandingOverride` (`ReaderViewModel.swift:549`) is set.
- `ReaderViewModel+NextBookWindow.swift:79-85`: `switchingTheWindowCouldLoseWork`, always true on iOS with no override, because `.noWindow.isBusy` is true (`Models/NextBookWindow.swift:67-69`).
- `ReaderViewModel+NextBookWindow.swift:96-113`: `attach(to:)`, `placeFocusAfterSwitchIfDue()`. Nothing calls `attach` on iOS, so a `WindowSwitchRequest` is left to lapse (`Services/ReaderRequestStore.swift:56`, 30 seconds).
- `ReaderViewModel+NextBookWindow.swift:194-198`: closes the host window on the Mac alone.
- `ReaderViewModel+SpeechRefusal.swift:14-32`: `speechRefusalWindowStanding`, always `.behind` on iOS, so a refusal says `SpeechRefusalWording.announcement` ("Details are in the book's window.") in place of moving to the sheet.
- `ReaderViewModel+SpeechRefusal.swift:58`, `:64`: announces from `hostWindow`, ignored on iOS.
- `Views/Reader/ReaderView.swift:23`, `:95`: `dismissWindow` for the cloud view's Close.
- `Views/Reader/ReaderView.swift:645-648`, `:657-663`: panel commands by window.
- `Views/Reader/ReaderBookCommands.swift:115`, `:145`, `:162`, `:170`, `:182`, `:193`, `:201`, `:212`, `:223`, `:241-246`.
- `Views/Reader/BookReaderWindowView.swift:90-105`, `:129-131`.

### 3.6 Two readers

- Nothing limits how many readers exist. Windows differ by book ID, and the same ID brings its window forward. A book can have two readers only through tests or a race, which is why `openReaderCounts` counts per book (`ViewModels/LibraryViewModel.swift:182`, `LibraryViewModel+BookOperations.swift:940`, `:954`).
- Only one plays: `NowPlayingService.prepareForPlayback(ownerID:)`, `Services/NowPlayingService.swift:552`, pauses every other reader, reached from every start through `activateRemoteCommandsIfNeeded()`.
- One sleep timer serves all: `SleepTimerService.shared`, each call carrying `readerID`.
- Shared singletons a reader touches: `SleepTimerService.shared`, `ReadingStatsService.shared`, `TextSubstitutionService.shared`, `ReaderAutoplayRequests.shared`, `ReadingListOpenRequests.shared`, `WindowSwitchRequests.shared`, `SpeechRenderCoordinator.shared`, `NowPlayingService.shared`, `PlaybackMemoryGuard.shared`, `CloudServices`, `BookCloudStates.shared`, `ReaderWorkingCopies.shared`, `VoiceCatalog.shared`, `TranscribedBooks.shared`, `ConfigService.shared`.

### 3.7 Next-book window switching

- The Mac: `showNextBook(_:under:openingANewWindowWith:)`, `ReaderViewModel+NextBookWindow.swift:125`, asks `NextBookWindowRule.action(choice:isBusy:canSwitch:nextBookIsOpenElsewhere:)`, `Models/NextBookWindow.swift` (in `NextBookWindowRule`, `:73`). `.switchThisWindow` sets `hasSwitchedWindow`, leaves a window-switch request, and calls `nextBookWindowSwitcher`; the scene sets `$bookID`, and `.id(bookID)` makes a new view and reader; the old view's `onDisappear` closes the old reader.
- Before any of that, every request the new reader claims is made: `autoplayRequests.request(for:from:)` (`ReaderViewModel+Playback.swift:3003`), `readingListRequests`, `sleepTimerService.markAsked`. The new reader claims them as its load ends.

### 3.8 What an iPhone app must do differently

- Own the reader in one app-level object (a coordinator made in the `App`, not in a view), with `@Published var reader: ReaderViewModel?`. The reader screen and the now-playing bar both read it. Popping the screen leaves it playing.
- Yes, `ReaderViewModel` can outlive its view: nothing in it needs a view, and every callback captures it weakly. The owner must hold it strongly.
- Call `markBookOpened(bookID)` as the Mac's `onAppear` does, once per open.
- Set `reader.soundEffectService` right after making it, and not from a view's `onAppear`, or a Play from the AirPods or an autoplay comes first.
- Open: if a reader for that book exists, show it. Otherwise make the new one with `makeReader`, then `close()` the old. Keep `close()` out of every `onDisappear`.
- Go on to the next book, one of two ways:
  - Set `reader.nextBookWindowSwitcher` to the coordinator's "show this book" and `reader.windowStandingOverride = .onScreen`, but compute the override so a sheet or a focused field counts as busy, since `windowStanding` no longer reads them on iOS. `.switchThisWindow` then runs, and the new reader claims the autoplay request. Set `hasSwitchedWindow` needs no handling, since nothing uses it but the Mac's view.
  - Or leave them unset, so `showNextBook` takes `.openANewWindow`, and subscribe to `.continueToNextBook` and `.openBookWindow` in the coordinator (`GlobalAction.routedNotificationNames`, `Services/LibraryWindowRouter.swift:464-471`, `Notification.nextBookID`). The second is simplest: the coordinator is the only "window".
- Announce the screen change: `SwitchedWindowFocus` does nothing on iOS, so VoiceOver must be moved to the new book's screen by new code.
- A bar that outlives the reader's screen must read a `ReaderSnapshot` of what it shows (title, playing, sleep timer), or it redraws at 8 Hz (`playbackUIRefreshInterval` 0.12 seconds, `ReaderViewModel.swift:710`).
- When the app goes to the background, nothing closes the reader, and nothing should: flush instead (section 4.6).
- Do not call `windowBecameKey()`; `setup` gives the first reader the focus (`Services/NowPlayingService.swift:497-499`).

## 4. Launch

### 4.1 Finding the data directory

- `TextMouthPaths.root`, `Services/TextMouthPaths.swift:74`, is `StorageBoundary.shared.current.root`; `StorageBoundary.shared`, `Services/StorageGeneration.swift:155`, starts from `TextMouthPaths.root(for: .current)`, `:40`.
- With no custom path, that is `defaultRoot(in: runtime.homeDirectory)`, `:15-17`: `home/.TextMouth`.
- `TextMouthRuntime.current`, `App/TextMouthRuntime.swift:91`, `detect(...)`, `:117-140`: not under test, `homeDirectory: realHomeDirectory`, `:123`, and `preferences: .standard`.
- `realHomeDirectory`, `:144-149`, is `getpwuid(getuid())`, with `NSHomeDirectory()` only as a fallback. Its comment says why: so no sandbox can redirect it. On iOS the sandbox redirecting it is what is wanted.

What would make it sit in the iOS container:

- In `realHomeDirectory`, under `#if os(iOS)`, return `URL(fileURLWithPath: NSHomeDirectory())`. Then `MachineLocalPaths` (`Models/CloudStorageContract.swift:573-655`) lands correctly, since `Library/Application Support/...`, `Library/Logs/...`, and `Library/Caches/...` all exist in a container.
- `.TextMouth` directly under the container's home is not writable on a device (only `Documents`, `Library`, and `tmp` are; not run). So under `#if os(iOS)` `defaultRoot(in:)` should name a folder inside `Library/Application Support` or `Documents`. The second makes the library visible in Files if the spec wants that.
- Not `Library/Application Support/TextMouth`: `legacyApplicationSupportDirectory(in:)`, `:593`, names exactly that folder, and the legacy migration reads `oldLibraryFile`, `:613`, from it. A library placed there would be read as an old one. Pick another name.
- `isDefaultLocation`, `:455`, then still holds, and `ensureDirectoryStructure()`, `:386`, creates it. `DataDirectoryCheck` treats a missing default as a first launch (`docs/architecture/launch.md:7-8`).

### 4.2 The Mac's launch, in order, and the phone's verdict

1. `TextMouthApp.init`: `CloudServices.installSystemServices()`, `Platform/macOS/App/TextMouthApp.swift:16-18`; `Services/BookCloudStorageService.swift:752`. Phone: skip in the first version. The defaults are `LocalItemStatusProvider` and `LocalBookStorage` (`Models/CloudStorageContract.swift:393-396`), so every book is local and every cloud path is dead.
2. `@StateObject LibraryViewModel()`, `TextMouthApp.swift:6`; `ViewModels/LibraryViewModel.swift:394`. Phone: needed, once.
   - `migrateFromSandboxContainer()`, `LibraryViewModel+Migration.swift:449`: finds no `Library/Containers/...` on iOS, a no-op. Leave.
   - `observeDataDirectoryLoss()`, `ViewModels/LibraryViewModel.swift:732`: volume unmounts are Mac-only, the write-failed notice is shared. Leave.
   - `checkDataDirectory()`, `:569`. Leave.
   - `startLibrary()`, `:419`, which does all of the following, unconditionally:
     - `TextMouthPaths.ensureDirectoryStructure()`, needed.
     - `recordLibraryIdentity()`, `:638`, needed.
     - `removeLeftoverArchiveExtractions()`, `LibraryViewModel+Import.swift:475`, needed.
     - `ReadingTextCache.shared.removeExpiredInBackground()`, needed.
     - `loadLibraryIndex()`, `LibraryViewModel+IndexRecovery.swift:203`, needed, with `migrateOldBooksIfNeeded`, `LibraryViewModel+Migration.swift:32`.
     - `setupDataDirectoryChangeHandler()`, `:483`, harmless.
     - `sweepAudioOriginalsInBackground()`, `LibraryViewModel+AudioEditing.swift:14`, and `removeStaleAudioEditCachesInBackground()`, `:46`, harmless, nothing to find.
     - `observeImportActivity()`, needed for the overlay; `observeImportProgressRequests()`, `observeDownloadProgressRequests()`, harmless.
     - `updateContentCachesAndStatistics`, `LibraryViewModel+Migration.swift:613`, then `moveFinishedBooksToTheirEndsOnce`, `:2129`, needed: it keeps text caches current and shows the `textExtraction` overlay, which the phone must show or say.
     - `refreshOutdatedMetadata`, `LibraryViewModel+MetadataRefresh.swift:106`, `captureMissingTextAnchors`, `LibraryViewModel+TextAnchors.swift:94`, `takeOutsideManifestEdits`, `LibraryViewModel+ManifestEdits.swift:136`, `keepHandEditedTitlesInManifestsOnce`, `:77`, `convertOggBooksOnce`, `LibraryViewModel+OggConversion.swift:102`: all run inside that batch or beside it, all fine on a library of local books; the Ogg pass fails book by book if an Ogg book ever exists.
     - `startFeeds()`, `LibraryViewModel+Feeds.swift:39`, `FeedCenter.start(library:)`, `Services/Feeds/FeedCenter.swift:439`: starts the feed engine and its hourly schedule, with no feeds and so no network. `LibraryFeedFolders.shared.center` needs it. Leave running.
     - `dataDirectoryEnvironment.sessionLease?.begin()`: `.app` gives `.shared` (`:549`), which writes nothing for a local library. Harmless. `presentWarning` answers `.continueHere` on iOS (`Services/LibrarySessionLease.swift:513`); the quit does nothing (`:159-163`).
     - `fetchLaunchFilesInBackground()`, `LibraryViewModel+LaunchFiles.swift:74`, harmless.
3. `@StateObject SettingsViewModel()`, `TextMouthApp.swift:7`; `ViewModels/SettingsViewModel.swift:504`; `startConfigSync()`, `:582` by its doc comment: applies config.json, `voiceCatalog.listNow()` on the first launch, writes the file, starts watching. Phone: needed, as it stands. It calls `KeyboardShortcutManager.moveSavedShortcutsIfNeeded`, harmless.
4. `@StateObject KeyboardShortcutManager()`, `TextMouthApp.swift:8`. Phone: skip unless a view asks for the environment object. No event monitor exists on iOS.
5. `@StateObject SoundEffectService()`, `TextMouthApp.swift:9`; `Services/SoundEffectService.swift:121`. Phone: `ReaderView` asks for it by `@EnvironmentObject`; the phone's reader needs one to set on the model. It plays nothing until sounds are bundled (section 5).
6. `LibraryWindowRouter.shared`, `TextMouthApp.swift:10`. Phone: skip the router, or use only `listen`: `register(_:perform:)` needs a window.
7. `AppDelegate.applicationWillFinishLaunching`, `Platform/macOS/App/AppDelegate.swift:19-23`: Phone: replace with the coordinator's subscriptions.
8. First window's `onAppear`: `VoiceCatalog.shared.loadIfNeeded()`, `TextMouthApp.swift:32`. Phone: needed, in the root view's `onAppear` or `task`. `RecordingWindowController.shared.attach`, `:35`: skip.
9. `AppDelegate.applicationDidFinishLaunching`, `AppDelegate.swift:48-91`:
   - `TextMouthPaths.ensureDirectoryStructure()`, `:54`: needed, already done by `startLibrary`. Keep for the case of an unavailable library.
   - `Self.logBuildIdentity(.current)`, `:55`: the phone calls `DiagnosticLog.event(.app, BuildIdentity.current.diagnosticLine)`, since `AppDelegate` is Mac-only.
   - `PlaybackMemoryGuard.tellOfAQuitToProtectTheMac()`, `:57`: compiles, tells nothing on iOS (`Services/PlaybackMemoryGuard.swift:424-441`). Skip.
   - `PlaybackMemoryGuard.shared.beginWatching()`, `:62`: harmless, reads memory. Its limits are 3 GB and 6 GB, past what an iPhone allows. Keep or skip; see section 10.
   - `OrphanedConversionSweep.sweepInBackground()`, `sweepTextutilInBackground()`, `sweepAfinfoInBackground()`, `:66-73`: no-ops (`Platform/iOS/Services/OrphanedConversionSweep+iOS.swift:13-21`). Skip.
   - `BrailleTableCatalog.loadInBackground()`, `:76`: reads VoiceOver's tables, absent on iOS. Skip until braille.
   - `MigrationStagingLeftovers.sweepInBackground()`, `:82`: nothing to find. Skip.
   - `NSWindow.allowsAutomaticWindowTabbing`, `disableWindowRestoration()`, `menuVisibilityManager.startObserving()`, `:85-90`: Mac-only.
10. Singletons made when first read: `ConfigService.shared`, `TextSubstitutionService.shared`, `ReadingStatsService.shared`, `LibraryViewDefinitionStore.shared`, `RemovalPreferencesModel.shared`, `SleepTimerService.shared`, `NowPlayingService.shared`. All are fine. `ReadingStatsService` gets an unshared center for sleep and wake (`Services/ReadingStatsService.swift:217-223`).

### 4.3 The calls an iOS app makes, in order

1. (Shared code first) `TextMouthRuntime.realHomeDirectory` and `TextMouthPaths.defaultRoot(in:)`, as in 4.1.
2. In the `App`'s stored properties, in this order, as `TextMouthApp` holds them: `LibraryViewModel()`, `SettingsViewModel()`, `SoundEffectService()`, then the coordinator with those three.
3. In the coordinator's `init`: set `library.readerOpener`; subscribe to `.continueToNextBook` and `.openBookWindow` (or set the switcher per reader); subscribe to `.speechSettingsChanged` only if it needs it (readers do already).
4. In the root view's `task`: `VoiceCatalog.shared.loadIfNeeded()`; `DiagnosticLog.event(.app, BuildIdentity.current.diagnosticLine)`.
5. In the root view: present `library.showError`, `library.importDecisions.current`, `library.showRemoveBookDialog`, the delete-folder dialogs, `library.indexRecovery`, `library.dataDirectoryUnavailability`, `library.isImporting`.
6. `onChange(of: scenePhase)`, to `.background`: section 4.6.
7. `.onOpenURL`: `library.importAndOpenFiles(urls: [url], from: nil)`, as `AppDelegate.application(_:open:)` routes to (`AppDelegate.swift:244-246`).

### 4.4 What misbehaves though it compiles

- `App/TextMouthRuntime.swift:144-149`: the real home (0.1).
- `Services/TextMouthPaths.swift:12`: `.TextMouth` at the container's top level.
- `Services/SoundEffectService.swift:194`: `systemSoundsPath = "/System/Library/Sounds"`, `.aiff` files, absent on iOS (not run). `soundFile(named:)` answers nil and `availableSounds()` answers `["None"]`. No earcons, silently. `SettingsPolicy.soundEffectAssignments.parse` (`Models/SettingsPolicy.swift:532-534`) then rejects every assignment a config.json names.
- `Services/LibrarySessionLease.swift:522-524`: `UIDevice.current.name` for "the computer's name"; harmless.
- `Services/FileImportService.swift:2368`, `Services/DuplicateReplacement.swift:181`: `FileManager.trashItem`, the default way to remove a book (`moveToTrashInsteadOfDeleting` true, `Services/ConfigService.swift:264`). On iOS there is no Trash a person can open (not run). The spec should default to deleting and change the words.
- `Services/PlaybackMemoryGuard.swift:47-69`: stops at 3 GB and quits at 6 GB, and says "a fault in macOS's audio".
- `ViewModels/LibraryViewModel+Migration.swift:2498`: `TextMouthRelauncher` throws `IOSUnavailable` on iOS; only "Use This Library" reaches it.
- `Services/KeyboardShortcutManager.swift`: a key-binding preference still exists, so `BookmarkPanelView.addBookmarkKeysInForce()` returns Mac keys.
- `Views/ContentView.swift:51-57`: Quit does nothing on iOS, so the Library Not Available screen's Quit button must go.
- `Services/FileImportService.swift:2874-2886`: `UTType(importedAs:)` with no declaration in the iOS app's generated Info.plist.
- `ViewModels/LibraryViewModel+Duplicates.swift:827`: `deleteOriginalFile` runs outside the security scope the import took, so "Delete After Import" of a file from Files fails (not run).
- `project.yml:281-292`: no `INFOPLIST_KEY_UIBackgroundModes`, no document types, no icon (`Resources/**` is excluded at `:280`, `Assets.xcassets` with it), and the Mac's bundle identifier at `:287`.
- `TextMouth/Resources/transcript-cleanup.json` is excluded too; transcript cleanup needs it (later).

### 4.5 The session lease, config sync, logs, memory guard, voice warm-up, sweeps: short answers

- Session lease: leave as `startLibrary` runs it. On a local library it holds nothing.
- Config sync: leave. `ConfigService` reads and writes config.json in the data directory, and watches it (nothing else writes it on the phone).
- Logs: `LogWriter.shared`, through `DiagnosticLog`. Works once home is right. There is no way to read them on a phone yet; `LogsInFinder` says so.
- Migrations: all run, all find nothing on a new library.
- Memory guard: `beginWatching()` is optional; `ReaderViewModel.followPlaybackForMemoryGuard` reports anyway.
- Voice warm-up: the reader does it itself (`warmUpVoice()`, `ReaderViewModel+VoiceAndSpeed.swift:71`, through `SpeechRenderCoordinator.warmUp`).
- Metadata refresh, launch page re-read: inside `updateContentCachesAndStatistics`, automatic.
- Media keys: the first reader's `setup` installs them (`Services/NowPlayingService.swift:509`, `:668-673`); `installsSystemIntegrations` is true on iOS (`:256-258`).

### 4.6 What the termination path does, and the phone's replacement

The Mac saves in `applicationShouldTerminate` and `applicationWillTerminate` (`AppDelegate.swift:195-236`). iOS sends no such call to a killed app. At `scenePhase == .background` the phone should call:

- `PlaybackMemoryGuard.savePendingWrites()`, `Services/PlaybackMemoryGuard.swift:442`, which is `flushPendingWrites()`: every open reader's place (`saveEveryOpenReaderPosition()`, `:402`), `LibraryPersistenceService.flushPendingSave()`, `ReadingStatsService.shared.flushPendingSaves()`, `ConfigService.shared.flushScheduledSave()`, then `TextMouthPaths.flushLogs()`.
- Not `statsService.endSession()`: a book playing in the background is still being listened to.
- Long imports and other queues get no extra time without a background task: the code begins none.

## 5. The seams

Each entry: where, what iOS gets, and whether the first version must replace it.

- `PlatformWindow`, `PlatformFont`, `PlatformView`: `Platform/PlatformTypes.swift:28-32`, UIKit's. Keep.
- `PlatformApplication`: `Platform/PlatformApplication.swift:17`. `keyWindow` and `mainWindow` are nil (`:20-35`); `isActive` is `applicationState == .active` (`:39-45`); `didBecomeActiveNotification`, `didResignActiveNotification` are UIKit's (`:49-65`, the second being `willResignActive`). Keep, unless a window is really needed.
- `FrontWindowKind`: `Platform/iOS/App/FrontWindowKind+iOS.swift:8`, `kind` nil. Keep; nothing on the phone reads it.
- `VoiceOverFocus`, `StandardVoiceOverFocus`, `InitialVoiceOverFocusModifier`, `StandardVoiceOverFocusTriggerView`: `Platform/iOS/Views/VoiceOverFocus+iOS.swift:47`, `:35`, `:59`, `:79`. Hidden `Color.clear`, or only the identifier `vo-focus-target` (`:14`, `:66-67`). Must be replaced: this is the first version's main accessibility work. The header names `AccessibilityFocusState`. Where it is asked for today: `ReaderDownloadProgressView`, `ReaderCloudMessageView`, `HeadingNavigatorRow:642`, `SleepTimerView:202`, `RequestedVoiceOverFocus:772`, `ImportDecisionSheet:267`, the play button `PlaybackControlsView:34-35`, `continueListeningButton`, `TimeRemainingBar`, `LibraryFocusTargetModifier`.
- `VoiceOverAnnouncer`: `Services/VoiceOverAnnouncer.swift:29`; the iOS branch (`:119-132`) posts `AccessibilityNotification.Announcement` with `.high`, `.default`, or `.low` priority. Real; keep. `from window` is ignored. `afterSheetCloses` waits 0.6 seconds (`:86`, `:91-95`). Nearly every reader announcement is `.high`, which on iOS interrupts what VoiceOver is saying.
- `NSAccessibilityPriorityLevel`: `Platform/iOS/Services/NSAccessibilityPriorityLevel+iOS.swift:10`. Keep.
- `NowPlayingService` on iOS: `Platform/iOS/Services/NowPlayingService+iOS.swift:19-23` gives two typealiases. `startDeviceChangeListener()` is empty on iOS (`Services/NowPlayingService.swift:1333`, `#if os(macOS)` at `:1347`), `currentDefaultOutputDeviceID()` nil (`:1574-1578`), `isBluetoothDevice` false (`:1606-1610`), `allAudioDeviceIDs()` empty (`:1684-1688`). The handler `onAudioRouteChangePause` (`pauseForAudioRouteChange()`, `ReaderViewModel+Playback.swift:324`) therefore never fires. Must be replaced: a route change must pause, as the file's own comment says.
- `WindowAccessor`: `Platform/iOS/Views/Reader/WindowAccessor+iOS.swift:8`, no callbacks. Keep; do not rely on it.
- `SwitchedWindowFocus`: `Platform/iOS/Views/SwitchedWindowFocus+iOS.swift:9`, `place(in:)` empty. Keep; new code does the phone's move of focus.
- `ReadOnlyTextArea`: `Platform/iOS/Views/ReadOnlyTextArea+iOS.swift:12`, a real read-only `UITextView`, with `.screenChanged` for `takesFocus` (`:33-43`). Keep, and consider it for the book's text.
- `SilentKeyEquivalent`: `Platform/iOS/Views/SilentKeyEquivalent+iOS.swift:8`. Keep.
- `PlatformControlStyles`: `Platform/PlatformControlStyles.swift:12`, `:23`. A switch and an inline picker. Keep. Add here any helper a shared sheet needs, such as a Mac-only frame, with its line in `Scripts/ios/mac-projection.py` (`docs/architecture/platforms.md:38`).
- `IOSUnavailable`: `Platform/iOS/IOSUnavailable.swift:8`. `.feature(name)` says "\(name) is not available on iPhone yet." Keep.
- `WatchedProcess`: `Platform/iOS/Services/WatchedProcess+iOS.swift:14`. `run` (`:93-101`) and `runCapturingOutput` (`:106-115`) throw `IOSUnavailable.feature("Converting this kind of file")`. Must change for `runCapturingOutput`: `AudioFileInfo.read` documents "Throws: `CancellationError` only" (`Services/AudioFileInfo.swift:285`) and `needsConversion` rethrows (`Services/ImportAudioConverter.swift:261-283`), so the import stops at `Services/FileImportService+AudioConversion.swift:51`, `:60`. The one-line way out: return `(.couldNotStart, Data())` from the iOS `runCapturingOutput`. `AudioFileInfo.read` then answers nil (`Services/AudioFileInfo.swift:306-307`), `isConvertedByWhatItHolds` false (`Services/ImportAudioConverter.swift:286-289`), and the file is left as it is, to be played by `AVPlayer`. The Mac does not compile this file.
- `OrphanedConversionSweep`: `Platform/iOS/Services/OrphanedConversionSweep+iOS.swift:11`, no-ops. Keep.
- `PackageFileEditing`, `BookTextEditor`, `BookManifestEditor`: `Platform/iOS/Services/PackageFileEditing+iOS.swift:13`, `BookTextEditor+iOS.swift:13`, `BookManifestEditor+iOS.swift:14`. No editing; `canEditText` false. Keep.
- `AudioEditorLauncher`, `AudioEditorWindowController`: `Platform/iOS/Views/AudioEditor/`, `canEdit` false. Keep.
- `RecordingWindowController`: `Platform/iOS/Views/Recording/RecordingWindowController+iOS.swift:13`. Nothing. Keep; `AddToLibraryChoice.newRecording` must not be offered.
- `LogsInFinder`: `Platform/iOS/Views/LogsInFinder+iOS.swift:7`, says it is not available.
- `FunctionKeyConstants`: `Platform/iOS/Models/FunctionKeyConstants+iOS.swift`. Keep.
- `XMLDocument`, `XMLElement`, `XMLNode`: `Platform/iOS/Parsers/XMLTree+iOS.swift`, the portable tree. Keep.
- `UIFontDescriptor.SymbolicTraits`: `Platform/iOS/Parsers/UIFontDescriptorSymbolicTraits+iOS.swift`. Keep.
- `UIWindow.isMainWindow`: `Platform/iOS/Windows/PlatformWindow+iOS.swift:13`. Keep.
- `TextMouthIOSApp`, `IOSPlaceholderView`: `Platform/iOS/App/TextMouthIOSApp.swift:9`, `:19`. Replaced by the first version.

`#else` branches in shared files, with no stand-in file:

- `DataDirectoryEnvironment.app`: default center for volume notices, `ViewModels/LibraryViewModel.swift:543-552`.
- `ReadingStatsService.init`: unshared center, `Services/ReadingStatsService.swift:217-223`.
- `LibrarySessionLease`: quit does nothing, warning answers Continue, name is the device's, `Services/LibrarySessionLease.swift:159-163`, `:513`, `:522-524`.
- `windowStanding`, `speechRefusalWindowStanding`: above.
- `ImportOrigin.init?(window:)`, `ImportDecisionPresenter.userIsIn(_:)`: `Views/Library/ImportDecisionPresenter.swift:15-24`, `:97-105`. Must be replaced by a phone presenter.
- `PlaybackMemoryGuard`: no alert, no quit, `Services/PlaybackMemoryGuard.swift:427-441`, `:457-462`.
- `revealInFinder`: nothing, `ViewModels/LibraryViewModel+Cloud.swift:534-539`. The row still offers it (`:447`).
- `presentDAISYFolderPanel()`, `bringToFront()`, Quit: `Views/ContentView.swift:478-503`, `:440-448`, `:51-57`.
- `WindowCommandRouting.rootWindow(for:)`: the window itself, `Views/Library/LibraryView.swift:44-60`.
- `copyReadingPosition`: `UIPasteboard`, `ReaderViewModel+WhereAmI.swift:776-782`. Real.
- `TextInputView`: `UIPasteboard` real, editor action empty, `Views/Library/TextInputView.swift:279-302`.
- `showNextBook`: closes no window, `ReaderViewModel+NextBookWindow.swift:194-198`.

To replace for the first version, in short: `VoiceOverFocus` and its kin; route-change handling and the audio session (with the audio researcher); `WatchedProcess.runCapturingOutput`; the import-question presenter; `TextMouthRuntime.realHomeDirectory`; the placeholder app.

## 6. The audio path

### 6.1 Text: what selects direct speech or the engine

Nothing selects up front. Every chapter starts in direct mode, and the engine takes over only at a natural break.

- `SpeechService.speak(_:fromCharOffset:)`, `Services/SpeechService.swift:1010`: `stop()`, sets `isSpeaking`, calls `speakDirect(_:fromCharOffset:)`, `:1069`, on `AVSpeechSynthesizer`; then, for a text of at most `maximumTextLength` 100,000 UTF-16 units (`:328`, `:1036`), `SpeechRenderCoordinator.shared.render(...)`, `:1043`, into `AudioEngineService` (`AVSpeechSynthesizer.write`, then `AVAudioEngine` with a time-pitch unit).
- Direct: first chunk `directModeFirstChunkSize` 1,000, later chunks `directModeChunkSize` 5,000 (`docs/architecture/state/media-playback.md:7`).
- The engine is used at: `seek(toCharOffset:)`, `:2151`; `resume()`, `:1958`; either watchdog's recovery; a refusal's recovery; and a pre-rendered next chapter, `usePreRenderedEngine`, `ReaderViewModel+Playback.swift:703`.
- A sleep fade never switches: `setSleepTimerFadeVolume(_:duration:)`, `:1789`.
- Watchdogs tick on `RunLoopWatchdogTimer` on the main run loop, every 0.5 seconds; start stalls after about 5.5 seconds (10.5 cold), `media-playback.md:13`.

### 6.2 How the reader starts and stops them

- Text start: `play()` then `startSpeakingAsNowPlaying(_:)`, `ReaderViewModel+Playback.swift:156`, then `startSpeaking(_:playing:)`, `:687`, then `speechService.speak`, `:705`, then `preRenderNextChapter()`, `:1253`. Speech for a long chapter prepared off the main thread: `waitForChapterSpeech(_:)`, `:1618`.
- Text pause: `pause(playingPauseSound:)`, `:3335`, `speechService.pause()`, `:3392`.
- Text resume: `resumeSpeechPlayback()`, `:247`, with `applyRewindOnResume()`, `:3510`.
- Text stop: `stop()`, `:482`, `speechService.stop()`, `:501`.
- Chapter end: `onUtteranceFinished`, `listenForSpeechEnd(of:)`, `:782`, `speechDidFinish(_:)`, `:811`.
- Audio start: `playAudioChapter()`, `:2109`, `startCurrentChapterAudio()`, `:2173`, `AudioPlaybackService.load(url:)`, `play(fromTime:)`, `playClips(_:fromChapterTime:)`, `Services/AudioPlaybackService.swift:784`, `:932`, `:953`, on `AVQueuePlayer`.
- Audio pause, resume, stop: `audioPlaybackService.pause()`, `resume()`, `stop()`, `:1013`, `:1032`, `:1071`.
- Audio seek: `seek(to:)`, `:1224`; speed `setSpeed(_:)`, `:1435`; volume `setVolume(_:)`, `:1445`.
- Audio chapter end: `onPlaybackFinished`, `listenForAudioEnd(of:)`, `ReaderViewModel+Playback.swift:789`, `audioDidFinish(_:)`, `:839`.
- Failure: `onPlaybackFailed`, `handleAudioPlaybackFailure(_:)`, `:2379`, sets `errorMessage`, `audioPlaybackFailure`, and announces.

### 6.3 How state reaches a view

- Text: `speechService.$isSpeaking`, `$isPaused`, `$wordsPerMinute` are forwarded to `isCurrentlyPlaying`, `isCurrentlyPaused`, `currentWPM` on the main queue by `forwardSpeechState()`, `ReaderViewModel.swift:895-921`. A reader waiting for chapter speech counts as playing (`:899-902`).
- Audio: the reader sets the flags itself (`ReaderViewModel+Playback.swift:2152-2153`, `:3380-3383`, `:537-538`).
- Cursor: `onWordSpoken` (`ReaderViewModel.swift:1015-1025`), or `onPositionUpdate` (`ReaderViewModel+Playback.swift:2037`), sets `currentCharacterOffset`, which is not published; `schedulePlaybackUIRefresh()`, `ReaderViewModel.swift:1880`, updates the published `displayChapterIndex`, `displayCharacterOffset`, `displayVisibleTextWindow` at most every 0.12 seconds (`:710`, `:1927`).
- Everything UI-facing reads the `display*` mirrors; commands read the raw cursor.

### 6.4 Where `AVAudioSession` is or is not touched

- Nowhere. A search of `TextMouth/` and `project.yml` for `AVAudioSession`, `setCategory`, `setActive`, `interruption`, `AVAudioEngineConfigurationChange`, `mediaServicesWereReset`, `beginReceivingRemoteControlEvents`, `usesApplicationAudioSession`, and `UIBackgroundModes` finds nothing.
- `AVSpeechUtterance.prefersAssistiveTechnologySettings = false` at `Services/SpeechService.swift:489`, `:1151`, `Services/AudioEngineService.swift:1182`, `ReaderViewModel+WhereAmI.swift:454`, `ViewModels/LibraryInfoSpeaker.swift:263`.
- Synthesizers in play: the reader's direct one in `SpeechService`; `whereAmISynth`, `ReaderViewModel.swift:389`; `LibraryInfoSpeaker`'s; the render queue's; `VoiceWarmUp`'s; the preview `AVSpeechSynthesizer`s (`Views/Reader/ReaderView.swift:868`, `Views/Settings/SettingsView.swift:159`).
- Sound effects: `SystemSoundEffectPlayer`, `AVAudioPlayer`, `Services/SoundEffectService.swift:32-57`.

## 7. The vocabulary

The two apps share one vocabulary. Interpolations are written as in the source, such as `\(title)`. Each group says whether it is shared or inline.

### 7.1 Playback bar: inline, `Views/Reader/PlaybackControlsView.swift`

- Skip backward label: "Skip backward: \(viewModel.playbackSkipBackwardUnit.rawValue)" (`:23`).
- Play/Pause label: "Pause" (`:152`), "Play" (`:154`). Shown as "pause.fill", "play.fill" (`:145-147`). The Mac's rule: "Pause" only while `isCurrentlyPlaying && !isCurrentlyPaused`.
- Skip forward label: "Skip forward: \(viewModel.playbackSkipForwardUnit.rawValue)" (`:45`).
- Shared unit picker: title and label "Navigation unit" (`:168`, `:182`), value the unit's `rawValue` (`:183`), help "Change this book's forward and backward navigation unit" (`:184`).
- Separate units menu: "Navigation units" (`:210`, `:214`); value "Forward navigation unit: \(forward); backward navigation unit: \(backward)" (`:216-217`); hint "Choose separate forward and backward navigation units for this book" (`:219`); help "Change this book's forward and backward navigation units" (`:220`); pickers "Forward navigation unit" (`:192`), "Backward navigation unit" (`:201`).
- Bookmark button: "Remove bookmark", "Add bookmark" (`:62`).
- Speed for an audiobook: `AudioSpeed.visibleLabel(for:)` such as "1.25x" (`:82`), spoken `AudioSpeed.spokenLabel(for:)` such as "1.25 times speed" (`:85`).
- Speed for a text book: "\(Int(viewModel.currentWPM))" (`:87`), spoken "\(Int(viewModel.currentWPM)) words per minute" (`:90`).
- Save button: `BookSettingsWording.saveAsDefaultsLabel`, help `saveAsDefaultsHint` (`:110`, `:114`).
- Sleep indicator: `formattedRemaining`, spoken `spokenLabel` (`:126`, `:133`).
- Group label: "Playback controls" (`:139`).

Shared speed words:

- `ReaderViewModel.speedStepButtonLabel(forward:)`, `ReaderViewModel+VoiceAndSpeed.swift:23-29`: "\(direction) speed by \(Int(Self.speechSpeedStep)) words per minute", with "Increase" and "Decrease", so "Increase speed by 25 words per minute".
- `AudioSpeed.stepButtonLabel(increasing:by:)`, `Services/AudioPlaybackService.swift:455`: "Increase audio speed by 0.1 times", "Decrease audio speed by 0.1 times".
- `AudioSpeed.visibleLabel(for:)`, `:443`: "1.0x", "1.3x", "1.25x".
- `AudioSpeed.spokenLabel(for:)`, `:449`: "1.25 times speed".
- `AudioSpeed.stepHint(_:)`, `:461-462`: "Changes the speed in steps of \(formattedNumber(step)) times".
- Range 0.25 to 4.0, `:396`; `coarseStep` 0.1, `fineStep` 0.05.

### 7.2 Reader toolbar: inline, `Views/Reader/ReaderView.swift`, unless named

- Return: "Return" (`:111`), label "Return to previous reading position" (`:113`), hint "Go back to where you were before browsing headings or bookmarks" (`:117`).
- Where Am I?: "Where Am I?" (`:259`); label "Where Am I? Announces current position in the book" (`:261`); while speaking "Stop Where Am I announcement" (`:264`); VoiceOver action `ShortcutAction.whereAmIFull.title`, "Where Am I? Full Summary" (`:267`, `Models/KeyboardShortcut.swift:68`).
- Headings: "Headings", label "Show heading navigator" (`:124`).
- Bookmarks: "Bookmarks", label "Show bookmarks" (`:128`).
- Sleep Timer: "Sleep Timer", label "Sleep timer" (`:132`).
- Search: "Search", label "Search in book" (`:137`).
- Book's settings: `BookSettingsWording.buttonTitle(isAudioBook:)`, "Audio Settings" or "Voice" (`:1150-1152`); `buttonLabel(isAudioBook:)`, "Audio Settings" or "Change voice for this book" (`:1155-1157`).
- Book Info: "Book Info" (`:155`), label `FeedItemBookInfoWording.readerButtonLabel(readOnly:)`, "Show book information" or "Edit book metadata" (`Views/Library/FeedItemBookInfoSheet.swift:116-118`).
- Speed caption: audiobook `AudioSpeed` words (`:187`, `:190`); text "\(Int(wpm)) WPM" (`:192`), label "\(Int(wpm)) words per minute" followed by ", book-specific speed" when the book has one (`:195`).

### 7.3 Reader window, its states: inline unless named

- Window title: "\(prefix): \(book.title) by \(book.author)", or "\(prefix): \(book.title)" with no known author, with prefix "Book" (`Views/Reader/BookReaderWindowView.swift:146`, `:154-160`) or `ReadingListReaderWording.windowTitlePrefix`, "Reading List" (`Models/ReadingListReaderWording.swift:18`).
- Loading: "Loading book..." (`Views/Reader/ReaderView.swift:64`), label "Loading \(viewModel.book.title)" (`:65`).
- Load failure: "Failed to load book" (`:300`), then the reason; one combined element.
- Placeholder book: title "Unknown" (`Views/Reader/BookReaderWindowView.swift:27`).
- Book's text: scroll area label "Book content" (`Views/Reader/ReaderView.swift:377`).
- Error alert: titles "Chapter Not Downloaded" (`ReaderViewModel.swift:2067`), "Error", "Playback Problem" (`:2074`); buttons "Retry" (`:2050`), "Try Again" (`:2070`), "Cancel" (`Views/Reader/ReaderView.swift:435`), "OK" (`:437`).
- Header (`ReaderLocationHeader`, `:316-358`): the book's title with the header trait; `ReadingListReaderWording.place`; the location title; `position.label`.

Shared position words:

- `HeadingPosition.label`, `Models/DocumentContent.swift:352-356`: "Heading \(number) of \(count)", "Before heading 1 of \(count)", or empty.
- `PagePosition.label`, `Models/BookPages.swift:158-162`: "Page \(page.label) of \(total)", "Before page \(firstLabel)", or empty.
- `TimeFormatting.format(_:)`, `Models/DocumentContent.swift:527`: "1:03:45", "3:45", or "Unknown".
- `TimeFormatting.spoken(_:)`, `:540`: "1 hour, 3 minutes, 45 seconds", or "Unknown duration".
- `CountWording.hours`, `.minutes`, `.seconds`: "1 hour", "2 minutes", "5 seconds" (`Models/CountWording.swift:48`, `:54`, `:59`).

### 7.4 Status row: `BookInfoBar`, `Views/Reader/ReaderView.swift:1227`

- Percent shown: `displayFormattedPercentComplete`, "%.1f%%" (`ReaderViewModel.swift:2144-2146`), such as "22.9%".
- Percent label: "\(viewModel.displayFormattedPercentComplete) through the book" (`:1311`). Inline.
- Percent hints: "Opens jump to percent controls" (`:1415`), "Hides jump to percent controls" (`:1416`), "Switches to jump to percent controls" (`:1417`). Inline.
- Page: `displayPagePosition.label` shown and spoken (`:1321`, `:1330`); hints `ReaderPageWording.openHint`, `hideHint`, `switchHint` (shared, below).
- Time left: `ReaderTimeWording.timeLeftShown(_:_:)`, `timeLeftSpoken(_:_:)`; hints "Opens jump to time controls" (`:1425`), "Hides jump to time controls" (`:1426`), "Switches to jump to time controls" (`:1427`). Inline.
- Total: `ReaderTimeWording.totalShown(_:_:)`, `totalSpoken(_:_:)`.
- Sleep: `formattedRemaining`, spoken `spokenLabel` (`:1369`, `:1380`).

Shared `ReaderTimeWording`, `Models/ReaderTimeWording.swift`:

- `timeLeftShown`, `:135-137`: "\(formatted) left\(shownSpeed(speed))", such as "3:44:01 left".
- `timeLeftSpoken`, `:142-145`: "\(TimeFormatting.spoken(seconds)) remaining" then " at current speed" when no speed is named, else the named speed.
- `totalShown`, `:149-151`: "Total: \(formatted)\(shownSpeed(speed))".
- `totalSpoken`, `:156-158`: "Total time: \(TimeFormatting.spoken(seconds))\(spokenSpeed(speed))".
- `shownSpeed`, `:108-117`: " at \(AudioSpeed.visibleLabel(for: multiple))", " at \(wordsAMinute(perMinute))", or nothing.
- `spokenSpeed`, `:122-131`: " at \(AudioSpeed.spokenLabel(for: multiple))", " at \(wordsAMinute(perMinute))", or nothing.
- `wordsAMinute`, `:176-178`: "\(wholeWords(wordsPerMinute)) words a minute".

### 7.5 Go to Percent and Go to Time

`JumpFieldPanel`, `Views/Reader/ReaderJumpPanels.swift:269`: buttons "Jump" (`:336`), "Cancel" (`:338`); refusal shown as "Error: \(errorMessage)" (`:346`). Inline.

Shared:

- Percent field: "Percent through the book" (`Models/ReaderTimeWording.swift:80`).
- Percent hint: "Type a percent from 0 to 100, such as 47.5." (`:83`).
- Percent jump: "Jumped to %.1f percent." (`:88`), such as "Jumped to 47.5 percent."
- Percent refusals (`Views/Reader/ReaderJumpPanels.swift:72-75`, `JumpInputValidator`, shared by being a plain enum in a view file): "Enter a percent.", "\"\(trimmed)\" is not a number.", "Percent must be between 0 and 100."
- Time field: "Time in the recording" (`Models/ReaderTimeWording.swift:18`), or "Time at \(wordsAMinute(perMinute))" (`:27`), "Time at 500 words a minute".
- Time hint: `TimeEntry.howToType`, "Type a time, such as 12:04.3, 1:02:03, or 75.5." (`Models/TimeEntry.swift:15`).
- Time refusals: `howToType`; "Seconds must be less than 60." (`:18`); "Minutes must be less than 60." (`:21`); "Time exceeds the recording's length. The recording lasts \(TimeFormatting.spoken(length))." (`Models/ReaderTimeWording.swift:41`); "Time exceeds book length. Maximum is \(TimeFormatting.spoken(length))." (`:43`).
- Time jump: "Jumped to \(TimeFormatting.spoken(time)) in the recording." (`:53`), "Jumped to \(TimeFormatting.spoken(time))." (`:55`).
- Copied place: "at \(format(time)) of \(format(length))" with " in the recording" or " at \(wordsAMinute(perMinute))" (`:66-74`).

### 7.6 Pages: shared, `Models/ReaderPageWording.swift`

- Arrival: "Page \(label)" (`:15`).
- No pages: "This book has no pages." (`:20`).
- One page: "This book has only one page." (`:26`).
- Field: "Page" (`:31`).
- Typing hint: "Type a page as the book numbers it, such as 12 or xii." (`:34`).
- Field hint: "This book's only page is \(first)." or "This book has \(pages.total) \(pages.total == 1 ? "page" : "pages"), from \(first) to \(last)." followed by the typing hint (`:42-50`).
- Empty field: "Type a page number." (`:53`).
- No such page: "There is no page \(typed) in this book." then " Its only page is \(first)." or " Its pages run from \(first) to \(last)." (`:61-64`).
- Jump: "Jumped to \(page(label, occurrence: occurrence))." (`:78`), giving "Jumped to page 12." or "Jumped to page 2, the second page labelled 2."
- With no words: "\(named) has no words, so the cursor is \(cursor)." (`:100-102`, `:136-138`), such as "Page 7 has no words, so the cursor is on page 8."
- Skipped: "\(named) is in a skipped section, so the cursor is \(cursor)." (`:111-113`).
- Cursor: "The cursor is \(cursor)." (`:120`).
- Button hints: "Opens jump to page controls" (`:190`), "Hides jump to page controls" (`:193`), "Switches to jump to page controls" (`:196`).
- Settings: section "Pages" (`:201`); "Show the page on the reader screen" (`:204`); its hint "Shows the page being read, such as Page 12 of 300, beside the percent, for books of more than one page." (`:208`); "Say the page in Where Am I?" (`:211`); its hint "Adds the page, such as Page 12 of 300, to Where Am I?'s summaries, for books of more than one page." (`:215`).

### 7.7 Navigation announcements: spoken from the reader, inline in shared view models

These strings live in `ReaderViewModel` extensions, which iOS compiles, so a phone view gets them by calling the function; it has nothing to copy.

- Next sentence: "Next sentence" (`ReaderViewModel+Navigation.swift:363`).
- Previous sentence: "Previous sentence" (`:394`).
- Next paragraph: "Next paragraph" (`:425`).
- Previous paragraph: "Previous paragraph" (`:455`).
- Crossing a section: the heading's text, or "Next section", "Previous section" (`:499-500`).
- Heading: "Heading: " followed by every heading that begins there joined by ", " (`:338`), such as "Heading: Season Two, Where Is Everybody?".
- Page: `ReaderPageWording.arrived(at:)`.
- Bookmark: "Bookmark \(next.number)", "Bookmark \(previous.number)" (`ReaderViewModel+Bookmarks.swift:243`, `:254`).
- A skip by time: nothing. A next or previous with nothing that way: nothing.
- Unit changed: "Navigation unit: \(rawValue)", "Forward navigation unit: \(rawValue)", "Backward navigation unit: \(rawValue)" (`ViewModels/SettingsViewModel.swift:89-93`).
- Return: "Returned to previous position" (`ReaderViewModel+Bookmarks.swift:413`).
- Nothing to go back to: "No previous position to return to." (`Views/Reader/BookSearchView.swift:69`).
- Section skipped: "Section skipped: \(heading.text)", "Section included: \(heading.text)" (`ReaderViewModel+VoiceAndSpeed.swift:206`, `:202`).
- Copy position: "Reading position copied to clipboard" (`ReaderViewModel+WhereAmI.swift:783`).

Unit names, `SkipUnit`, `ViewModels/SettingsViewModel.swift:39-51`: "10 seconds", "15 seconds", "30 seconds", "60 seconds", "Sentence", "Paragraph", "Page", "Heading", "Subheading", "Bookmark". Order in every picker is this order.

Rewind units, `RewindUnit`, `:7-10`: "None", "Sentence", "Paragraph", "Heading".

### 7.8 Book's voice and speed sheet

Shared by being a plain enum in a view file, `BookSettingsWording`, `Views/Reader/ReaderView.swift:1137`:

- Sheet name: "Audio Settings" (`:1140`), "Voice & Speed" (`:1145`).
- Heading: "\(sheetName) for This Book" (`:1161`).
- Title: "\(sheetName): \(bookTitle)" (`:1166`).
- "Audio speed" (`:1171`).
- "Save to Global Settings" (`:1177`).
- "Save this book's voice, speed, and pitch as the global defaults" (`:1180`).
- "Updates the default voice, speed, and pitch for every book without settings of its own." (`:1183`).
- "Reset to Normal Speed", "Reset to Global Settings" (`:1188`).
- "Reset this book's voice, speed, and pitch to the global defaults" (`:1192`).
- "Removes this book's own voice, speed, and pitch, so it uses the global defaults." (`:1195`).
- "Reset to normal audio speed" (`:1200`).
- "Resets this book to \(AudioSpeed.spokenLabel(for: AudioSpeed.normal))" (`:1207`).
- "Using global voice, speed, and pitch settings" (`:1213`).

Inline in `BookVoicePickerView`:

- "Audio Speed" section (`:889`); "Speed: \(AudioSpeed.visibleLabel(for:))", hidden from VoiceOver (`:1066`).
- Language: "Language" (`:894`), item "All" (`:895`), label "Voice language filter" (`:901`).
- Voice: "Voice" (`:903`), item label "\(voice.name), \(voiceQualityLabel(voice)) quality" (`:918`), shown "(\(quality))" (`:914`), picker label "Select voice for this book" (`:921`).
- Preview: "Preview Voice" (`:923`), label "Preview selected voice" (`:926`), speaks "Hello! This is how I'll read for you." (`:1112`).
- Section "Voice" (`:928`), "Speed" (`:960`), "Pitch" (`:989`), "End of Book" (`:1011`).
- Speed: "Speed: \(Int(wpm)) WPM", hidden (`:935`); slider "Words per minute" (`:952`), label "Speed" (`:956`), value "\(Int(wpm)) words per minute" (`:957`). Range 50 to 650, step 25.
- Pitch: "Pitch: \(SpeechService.pitchLabel(pitch))", hidden (`:967`); slider label "Pitch" (`:985`), value `pitchLabel` (`:986`). `pitchLabel`, `Services/SpeechService.swift:2207-2210`: "Normal (1.0x)", or "%.1fx". Range 0.5 to 2.0, step 0.1.
- End of book: "When this book ends" (`:994`), label "End of book behavior for this book" (`:1002`); "Use Global Default" (`:1005`), label "Reset to global end-of-book setting" (`:1008`).
- "Close" (`:1035`).

Spoken as they change, from the reader:

- "\(Int(speechService.wordsPerMinute)) words per minute" (`ReaderViewModel+VoiceAndSpeed.swift:42`).
- "Pitch \(formatted)" (`:51`).
- "Voice changed to \(voice.name)" (`:63`).
- "Settings applied as global defaults" (`:143`).
- "Audio speed reset to \(AudioSpeed.spokenLabel(for: audioSpeed))" (`:158`).
- An audiobook's speed: `AudioSpeed.spokenLabel(for: newSpeed)` (`ReaderViewModel+Playback.swift:2528`).

Voice quality, `Parsers/ParserUtilities.swift:9-15`: "Standard", "Enhanced", "Premium", "Unknown".

### 7.9 Headings sheet: `Views/Reader/HeadingNavigatorView.swift`

Static, callable from iOS:

- Row label, `accessibilityDescription(text:level:isSkipped:isCurrent:suffix:)`, `:130-141`: "\(skipPrefix)\(text)\(currentSuffix) - level \(level)" with ", \(suffix)", prefix "Skipped, ", current " (current heading)".
- List label: "Headings, \(CountWording.phrase(headingCount, singular: "heading", plural: "headings"))" (`:164`).
- Filter label: "Show levels" (`:169`); hint "Shows only the headings up to the level chosen." (`:171`).
- Filter choices: "All levels", "Level 1", "Levels 1 to \(maximumLevel)" (`:179-180`).
- Row commands: "Go To", "Include Section", "Skip Section" (`:714`).
- Row hint: "Goes to this heading and closes the list." (`:707`).
- Display modes: "Duration", "Time In", "Percentage" (`:230-232`).
- Row suffixes: `TimeFormatting.spoken(seconds)` + `ReaderTimeWording.spokenSpeed`; "\(TimeFormatting.spoken(start)) in" (`:534`); "%.1f percent" (`:542`). Shown "%.1f%%" (`:541`).

Inline:

- Heading "Headings" (`:254`).
- Display picker "Display" (`:259`), label "Heading info display mode" (`:266`).
- "Back to Book" (`:268`), hint "Close the headings screen and return to the book" (`:270`).
- Empty: "No headings found in this document." (`:308`).
- Rotor: "Heading Levels" (`:341`).
- Title: "Headings: \(shown.value.title)" (`:358`).
- Badges: "Skipped" (`:675`), "Currently reading" (`:695`).

### 7.10 Bookmarks: `Views/Reader/BookmarkPanelView.swift`, `Models/Book.swift`

Shared or static:

- Row label, `Bookmark.accessibilityLabel(headingText:)`, `Models/Book.swift:1777-1784`: "Bookmark \(number)", heading text, "Note: \(label)", "added \(dateText)", joined by ", "; such as "Bookmark 3, The Battle, Note: Check this, added October 9, 2026".
- Commands, `BookmarkCommand`, `:651-657`: "Go To", "Edit Note", "Delete".
- Button labels, `:680-686`: "Go to bookmark \(number)", "Edit note for bookmark \(number)", "Delete bookmark \(number)".
- Empty help, `emptyListHelp(keys:)`, `:456-459`: "Add Bookmark adds one at the current position." (with no keys), or "\(keys) adds a bookmark at the current position." The phone should pass no keys.

Inline:

- Heading "Bookmarks" (`:166`).
- "Add Bookmark" (`:175`), label "Add bookmark at current position" (`:177`).
- "Done" (`:186`).
- Empty: "No bookmarks yet." (`:196`).
- Rotor: "Bookmarks" (`:220`).
- Add sheet: "Add Bookmark" (`:359`); field "Note (optional)" (`:363`), label "Bookmark note" (`:365`), hint "Optional note to describe this bookmark" (`:366`); "Cancel" (`:370`); "Add" (`:379`).
- Edit: "Edit Bookmark \(bookmark.number)" (`:398`); field "Note" (`:402`), label "Bookmark note" (`:404`); "Cancel" (`:408`); "Save" (`:416`).
- Row shown: "Bookmark \(bookmark.number)" (`:702`).
- Row hint: "Goes to this bookmark and closes the list." (`:733`).

Spoken, from the reader:

- "Bookmark \(number) added" (`ReaderViewModel+Bookmarks.swift:211`).
- "Bookmark \(number) removed" (`:80`).
- "Could not add the bookmark: \u{201C}\(bookTitle)\u{201D} is no longer in the library." (`:183`).
- "Could not remove the bookmark: \u{201C}\(bookTitle)\u{201D} is no longer in the library." (`:189`).

Menu names, `ShortcutAction`, `Models/KeyboardShortcut.swift:56-59`: "Toggle Bookmark", "Next Bookmark", "Previous Bookmark", "Show Bookmarks".

### 7.11 Where Am I?: shared, `ReaderViewModel+WhereAmI.swift`

- No book: "No book is loaded." (`:101`).
- Brief, `:146-170`: joined by ". " and ended with ".": book title; location title; heading label; page label; then "%.0f percent" (`:160`) and "\(TimeFormatting.spoken(timeRemaining)) remaining\(ReaderTimeWording.spokenSpeed(speed))" (`:161`), or `EndOfBookWording.finishedProgress` "Finished" (`:158`). Example from `:134`: "Dune. The Battle. Heading 26 of 412. Page 112 of 300. 30 percent. 3 hours remaining."
- Full, `:212-247`: the same opening; then "%.0f percent through the book" (`:236`); "\(spoken) remaining\(namedSpeed)" (`:237`); "\(spoken) remaining in this heading" (`:239`); or "Finished" (`:234`); then always "Total book time: \(TimeFormatting.spoken(totalTime))\(namedSpeed)" (`:242`); then `ReadingListReaderWording.place` (`:244`).
- A transcribed audiobook adds the sentence being heard, at most 40 words and "…" (`:277`, `:298-305`).
- The press rules are `SummaryPress.outcome(pressing:while:)`, `Models/SummaryPress.swift`.

Copied reading position: joined by " | ": title; "by \(author)"; location; heading label; "%.1f%% through" (`:844`); place; "\(formatted) remaining\(shownSpeed)" (`:846`); or "Finished". Example at `:821`: "My Book | by An Author | The Battle | Heading 26 of 412 | 30.0% through | 3:00:00 remaining". Unknown author dropped (`:859`).

### 7.12 Sleep timer

Static on the view, callable from iOS, `Views/Reader/SleepTimerView.swift`:

- `presetMinutes`: 10, 15, 30, 45, 60 (`:38`).
- Adjust stepper: "Adjust minutes" (`:313`), step 5 (`:311`).
- Preset and Set label: "Set timer for \(SleepTimerDuration.minutes(minutes).displayName) and start playing" (`:319`).
- Custom hint: "Type the minutes, or change them \(customMinutesStep) at a time with \(adjustMinutesLabel). Return sets the timer and starts playing." (`:325`).
- "Stop At" (`:328`).
- "End of heading" (`:330`); label "Stop at the end of this heading and start playing" (`:332`); hint "Pauses playback where the heading playing now ends: where the next heading begins, or the book ends." (`:336`).
- "End of book" (`:338`); label "Stop at the end of the book and start playing" (`:340`).
- End of book hints, by behavior: "Pauses playback when this book ends, before Continue to Next Book starts the next book." (`:349`); "Pauses playback when this book ends, before Loop to Start plays it again." (`:351`); "This book already stops playing at its end, since Continue to Next Book is off; the timer stops it there too." (`:353`).
- Set: "Timer set for \(duration.displayName)." (`:361`), or "Sleep timer: \(stop)." (`:362`).
- Reset: "Timer reset: \(status)." (`:368`).

Inline in the view:

- "Sleep Timer" (`:75`, title `:102`).
- "Close" (`:81`), hint "Close the sleep timer and return to the book" (`:83`).
- "Current Timer" (`:136`).
- "Reset Timer" (`:151`), hint "Restart the timer with its original duration" (`:159`).
- "Cancel Timer" (`:161`), hint "Stop the timer and discard the remaining time" (`:166`).
- Spoken on cancel: "Sleep timer cancelled." (`:164`).
- "New Timer" (`:182`).
- "Setting a new timer replaces the current one.", "Pause playback after:" (`:188-189`).
- "Custom:" (hidden, `:216`); field "Minutes" (`:218`); label "Custom timer minutes" (`:226`); value `CountWording.minutes(customMinutes)` (`:287`); "min" (hidden, `:235`); "Set" (`:239`).

Shared:

- `SleepTimerDuration.displayName`, `Models/DocumentContent.swift:471-477`: `CountWording.minutes(m)`, "End of heading", "End of book".
- `spokenStop`, `:485-486`: "stops at the end of this heading", "stops at the end of the book".
- `SleepTimerService.formattedRemaining`, `Services/SleepTimerService.swift:1074-1082`: "Fading out", the place's name, or "%d:%02d".
- `spokenStatus`, `:1088-1092`: "fading out", `spokenStop`, or "\(formattedRemaining) remaining".
- `spokenLabel`, `:1097-1099`: "Sleep timer: \(spokenStatus)".
- Milestones at 5 minutes, 1 minute, 30 and 10 seconds, medium priority (`:1056-1068`): "Sleep timer: \(remainingSeconds / 60) minute" or "minutes" " remaining"; "Sleep timer: \(remainingSeconds) seconds remaining".
- `sleepTimerExpiredAnnouncement`: "Sleep timer expired. Playback paused." (`ReaderViewModel+Playback.swift:867`).
- `sleepTimerStoppedAtHeadingEndAnnouncement`: "Sleep timer expired at the end of the heading. Playback paused." (`:879`).
- Restart: "Timer reset." (`:3292`); "Timer restarted: \(last.displayName)." (`:3300`); "No previous sleep timer to restart." (`:3307`).
- `SleepTimerHandOverWording`, `Models/SleepTimerHandOverWording.swift:14`, `:25`: "Sleep timer cancelled, because the next book could not be opened."; "Sleep timer cancelled, because you moved to another book while it faded out."

### 7.13 The end of a book: shared, `Models/EndOfBookWording.swift`

- "Starting: \(title)" (`:16`).
- "Restarting: \(title)" (`:22`).
- "Starting again: \(title)" (`:30`).
- "Still starting: \(title)" (`:38`).
- "Finished: \(title)", with notes joined by ". " and ended with "." (`:57-59`).
- "Sleep timer expired" (`:63`).
- "Next book not started because of the sleep timer" (`:67`).
- "Not restarted because of the sleep timer" (`:71`).
- "No more books in folder" (`:74`).
- "Every book after it in the folder is finished" (`:80`).
- "Every book before it in the folder is finished" (`:89`).
- "Downloading the next \(kind): \(item.title)" (`:99`).
- "The next \(kind) could not be downloaded, so playback stopped. \(reason)" (`:111`).
- "Download cancelled, so playback stopped." (`:117`).
- "TextMouth is not downloading right now." (`:121`).
- "Finished" (`:144`).
- Caption: "With \"Stop\", Play on a finished book says it is finished; with \"Stop, and Play Starts Over\", Play starts it again from the beginning." (`:151-153`).

Choices, `EndOfBookBehavior`, `ViewModels/SettingsViewModel.swift:21-30`: "Stop", "Stop, and Play Starts Over", "Loop to Start", "Continue to Next Book". Stop is the default (`Models/SettingsPolicy.swift:433`).

### 7.14 Next and Previous in Folder, and in Reading List: shared

- Opening: "Opening: \(title)" (`Models/ReadingListReaderWording.swift`, `opening(_:)`).
- Nothing that way: `FolderNavigationWording.nothingThatWay(_:)`, the note and ".", `Models/FolderNavigationWording.swift:15-17`.
- Episode download words: `:22-24`, `:38-39`, `:51`.
- Reading list place: "Reading list, book \(place.position) of \(place.count)" (`Models/ReadingListReaderWording.swift`, `place(_:)`).
- Reading list stop: "The reading list is set to stop when a book ends"; "End of the reading list"; "Start of the reading list"; "Every book \(side(direction)) it in the reading list is finished".
- Not read from the list: "This book was not opened from the reading list."
- No neighbor: "No next book in the reading list", "No previous book in the reading list", then "." or ": every book \(side(direction)) this one is finished."

### 7.15 Media controls: shared, `Services/NowPlayingService.swift`

- "Media controls released" (`:86`).
- "Media controls not released: this book does not hold them." (`:94`).
- Menu: "Release Media Controls" (`App/MenuCommands.swift:231`; `Models/KeyboardShortcut.swift:10`).

### 7.16 Library rows: `Views/Library/LibrarySubviews.swift`

Row label (`BookRow.rowAccessibilityLabel`, `:589-624`), joined by ", ", in this order: "Selected" in edit mode (`:592`); title; "by \(book.author)" (`:595`); `ReadingListWording.inReadingListNote` "In reading list"; "New" (`:602`) or "Now Reading" (`:604`); cloud note; "Kept on this Mac"; transcription note; progress; time left; format.

- Example from `docs/user/library-window.md:17`: "Loose Pages, by Ines Okonkwo-Varga, In reading list, New, Plain Text".
- Hints: "Opens the book." (`:569`); "Deselects this book.", "Selects this book." (`:570`).
- Shown badges: "New" (`:475`), "Now Reading" (`:484`).
- Progress: visible "\(wholePercent)%", spoken "\(wholePercent) percent" (`:642`); "\(progress.spoken) read" beside a download (`:652`); "Finished" for a finished book (`:638`).
- Time left: shown "\(TimeFormatting.format(remaining)) left" (`:669`), spoken `LibraryInfoWording.remaining`, "\(TimeFormatting.spoken(remaining)) remaining" (`Models/LibraryInfoWording.swift:845`).
- Format: `BookFormat.displayName`, `Models/Book.swift:66-83`: "EPUB", "Plain Text", "Markdown", "HTML", "Web Archive", "SSML", "Word Document", "Rich Text", "Rich Text with Attachments", "Word 97-2003 Document", "OpenDocument Text", "Word 2003 XML", "Braille", "DAISY", "PDF", "Audio", "Kindle Book (MOBI)", "Kindle Book (KFX)".
- Unknown author: `Book.unknownAuthor`, "Unknown" (`Models/Book.swift:467`).

Row commands (`LibraryBookListRow.menu`, `:913-1021`):

- "Open" (`:917`), "Book Info" (`:920`), "Select" (`:925`).
- `LibraryTransitionWording.moveToFolderTitle(for:)`: "Move to Folder...", "Move \(movable) Books to Folder..." (`LibraryViewModel+BookOperations.swift:1183`).
- `ReadingListCommand` titles, below.
- `BookExportWording.commandTitle(count:)`: later.
- "Move Up", "Move Down" (`:681`, `:683`), each only where the book can move.
- Remove, `LibraryRemoveCommandWording.menuTitle`, below.

Move words (`LibraryViewModel+SortAndOrder.swift`): "\(title) can't move \(direction < 0 ? "up" : "down")." (`:42`); "Books can be moved only in a folder sorted by Manual Order, and this folder is not. Choose Manual Order in the Sort menu, then try again." (`:55-56`); "Books can't be moved in this view. Go to a folder in Folders, or to the Reading List, then try again." (`:58`); "\(title) is an item of a feed, and a feed's items can't be moved." (`:65`); "No book is selected. Select the book to move, then try again." (`:70`); "Moved \(movedTitle) \(direction < 0 ? "above" : "below") \(adjacentTitle)" (`:23`). A move through VoiceOver's action says `placeAnnouncement`, such as "Dune, 3 of 12".

Empty states:

- A folder with no books has no sentence of its own on the Mac: the list shows the section header `CountWording.booksHeader`, "Books (0)", and `TimeRemainingBar` draws nothing (`:154`). The phone needs a new sentence, which the spec must word.
- A filter view or a listener's view that lists nothing: "Nothing matches this view now." (`Models/LibraryViewPickerWording.swift:18`).
- An empty Reading List: "The reading list is empty. To add a book, choose Add to Reading List from its context menu, its VoiceOver actions, or the Library menu." (`Models/ReadingListWording.swift:57-58`). It names the Library menu, so the phone needs its own.
- Book search with no match: nothing is said on the Mac.

### 7.17 Folder rows, breadcrumbs, summary bar, and the window

Folder row, `Views/Library/LibrarySubviews.swift`:

- Label: "\(name), \(countText)" (`:383`), such as "Fiction, 12 books", "Podcasts, 3 books, 2 feeds".
- Hint: "Opens the folder." (`:365`).
- Count: `CountWording.booksAndFeeds(books:feeds:)` (`Models/CountWording.swift:104`).

Inline in `LibraryView`:

- Section header "Folders" (`Views/Library/LibraryView.swift:1280`); books header `CountWording.booksHeader(of:)` (`:1349`, `Models/CountWording.swift:147-160`): "Books (743)", "Books (2), Episodes (5)".
- Rotors: "Books" (`:504`), "Folders" (`:509`).
- Search prompt: "Search books" (`:503`).

Breadcrumb: "Library" (`LibrarySubviews.swift:294`), label "Navigate to library root" (`:296`), "Navigate to \(part)" (`:309`).

Summary bar, `TimeRemainingBar`:

- Shown: "\(TimeFormatting.format(time)) remaining" (`:158`); "(\(CountWording.books(unknown)) not yet opened)" (`:167`); count `CountWording.listItems`.
- Spoken, joined by ". ": count text; "\(TimeFormatting.spoken(time)) total remaining at current speed" (`:243`); "\(phrase "book has"/"books have") not been opened yet" (`:246`).

Announced on entering a folder: "\(folderName), \(CountWording.booksAndFeeds(books:feeds:))", with "Library" at the top (`Models/FolderNavigationHistory.swift:93-99`).

Window title: "Library: \(name) (\(sort.titleFragment))", or "Library: \(name)" for the Reading List and a feeds-only view (`Models/LibrarySortState.swift:121`); the name "All Folders" at the top of Folders (`:65`).

Continue button (`Views/Library/LibraryView.swift`):

- Shown: "Continue: \(lastBook.title)" (`:1041`) and "\(time) left".
- Label: "Continue listening to \(book.title)", then ", \(remaining spoken)" (`:1077-1079`).
- Hint: "Opens the last book you were reading" (`:1057`).

Toolbar (`Views/Library/LibraryView.swift`):

- "Up One Level" (`:544`), label "Go up one folder level" (`:546`).
- "Done", "Edit" (`:559`), labels "Exit edit mode", "Enter edit mode" (`:561`), hints "Exits edit mode. \(CountWording.books(selectedCount)) selected.", "Enters edit mode, for selecting several books to move or remove." (`:1636-1637`).
- "New Folder" (`:569`), label "Create new folder" (`:571`).
- View pop-up: "View" (`:1861`), label "Library view" (`:223`).
- Sort: "Sort" (`:937`).

### 7.18 Sorting and views: shared

Fields, `LibrarySortField`, `ViewModels/LibraryViewModel.swift:6-11`: "Title", "Author", "Date Added", "Last Opened", "File Size", "Manual Order".

`LibrarySortState`, `Models/LibrarySortState.swift`:

- Direction names: "Ascending", "Descending" (`:253`).
- Title fragment: "Title Ascending", "Manual Order" (`:265-269`).
- Direction command: "Sort Descending", "Sort Ascending" (`:280`).
- Its hint: "Reverses the order of the books" (`:295`); "Manual order has no direction" (`:290`).
- Sort button label: "Sort books by \(spokenSort)" (`:301`), such as "Sort books by Title, ascending".
- On change: "Sorted by \(spokenSort)" (`:307`).
- On applying down: "All subfolders now sorted by \(spokenSort)" (`:313`).

Inline: "Apply Sort to All Subfolders" (`Views/Library/LibraryView.swift:994`).

Reading List's sort, `Models/ReadingListWording.swift`: "Reading List Order" (`:20`); "Sort books by \(orderName)" (`:25`); "Sorted by \(orderName)" (`:29`); "The reading list keeps the order you arrange with Move Book Up, Move Book Down, or dragging" (`:32`).

Feeds view's sort, `Models/LibraryViewPickerWording.swift:29-35`: "Title"; "Sort feeds by Title"; "Feeds are always listed by title"; "Feeds are listed by title".

View names, `LibraryCategory`, `ViewModels/LibraryViewModel.swift:23-34`: "Folders", "All Items", "Unopened", "Recently Opened", "Reading List"; "Feeds" (`Models/LibraryViewDefinition.swift:24`). Deleted view: "The view this window showed was deleted. It now shows \(name)." (`Models/LibraryViewPickerWording.swift:24`).

### 7.19 Reading List: shared, `Models/ReadingListWording.swift`

- "In reading list" (`:13`).
- Options: "When a book ends" (`:39`); hint "For a book opened from the reading list: play the book below it or the book above it when it ends, or stop" (`:43-44`); "Skip finished books" (`:48`); hint "When a book opened from the reading list ends, pass over the books already finished" (`:51`).
- Commands: "Add \(countedBooks(count)) to Reading List" (`:68`); "Remove \(countedBooks(count)) from Reading List" (`:76`); `ShortcutAction` titles "Add to Reading List", "Remove from Reading List".
- Edit bar: "Add \(CountWording.books(count)) to the reading list" (`:105`); "Remove \(CountWording.books(count)) from the reading list" (`:106`); hints "Adds the selected books to the end of the reading list." (`:114`), "Takes the selected books off the reading list. They stay in the library." (`:115`).
- Said: "Added to reading list: \(title)" (`:128`); "Added \(CountWording.books(titles.count)) to the reading list." (`:129`); "\(phrase "book was"/"books were") already in it." (`:131`); "Removed from reading list: \(title)" (`:142`); "Removed \(CountWording.books(titles.count)) from the reading list." (`:143`); "\(phrase) not in it." (`:145`); "\(title) is already in the reading list." (`:167`); "The \(titles.count) selected books are already in the reading list." (`:169`); "\(title) isn't in the reading list." (`:178`); "None of the \(titles.count) selected books is in the reading list." (`:180`).

### 7.20 Folders: inline in `Views/Library/LibrarySheetViews.swift` and `LibraryView.swift`, unless named

Commands (`Views/Library/LibraryView.swift`): "Rename Folder..." (`:1294`), "Move Folder..." (`:1298`), "Delete Folder..." (`:1303`).

New Folder:

- "New Folder" heading and title (`LibrarySheetViews.swift:378`, `:411`).
- "Folder name", label "Folder name" (`:382`, `:384`).
- "Parent folder", label "Parent folder" (`:386`, `:394`), root "Library Root" (`:387`, `:428`).
- "Cancel" (`:399`), "Create" (`:402`).
- Said once closed: "Folder \(name) created in \(place)." (`:373`).

Folder picker in sheets:

- "New Folder..." (`:569`), group "New Folder" (`:586`), "New folder name" (`:591`), "Parent folder for new folder" (`:598`), "Create" (`:619`).
- "Cancel New Folder" (`:500`), hint "Closes the new folder's fields and keeps the folder chosen." (`:503`).
- Said: "New Folder cancelled." or "New Folder cancelled. \(pickerLabel): \(chosen)." (`:511-512`); "Folder \(name) created. \(pickerLabel): \(chosen)." (`:522`).

Move to Folder:

- "Move \"\(book.title)\"" (`:745`), "Move \(books.count) Books" (`:747`).
- "Destination", label "Destination folder" (`:776-777`).
- "Moving \(CountWording.books(books.count))..." (`:787`).
- "Cancel" (`:791`), "Move" (`:803`).

Rename: "Rename Folder" (`:912`, `:942`), "Folder name" (`:916`), label "New folder name" (`:918`), "Renaming the folder..." (`:924`), "Cancel" (`:928`), "Rename" (`:931`).

Move folder: "Move \"\(folder.name)\"" (`:985`), "New parent folder" (`:989`), label "Destination parent folder" (`:994`), "Moving the folder..." (`:1000`), "Cancel" (`:1004`), "Move" (`:1007`), title "Move Folder: \(folder.name)" (`:1021`).

Delete folder:

- "Delete Folder?" (`Views/Library/LibraryView.swift:858`), "Move Contents Out" (`:861`), "Cancel" (`:867`).
- `FolderRemovalWording`, `Models/RemovalWording.swift`: button `mode.buttonTitle("Everything")`, "Move Everything to Trash" or "Delete Everything Permanently" (`:567`).
- Message: "“\(name)” contains \(books) and may have subfolders. With Move Contents Out, they stay in the library and only the folder is deleted. With \(buttonTitle), the folder and everything in it leave the library, and \(filesClause)." (`:593-596`).
- Contents sheet: "Move Contents of \"\(folder.name)\"" (`LibrarySheetViews.swift:1063`); "Choose where to move the books and subfolders before deleting \"\(folder.name)\"." (`:1067`); "Move contents to" (`:1071`), label "Destination for folder contents" (`:1076`); "Moving the folder's contents..." (`:1082`); "Move Contents & Delete Folder" (`:1089`); title "Move Contents: \(folder.name)" (`:1102`).

Failures: `OperationFailureNotice`, "Error: \(message)" (`LibrarySheetViews.swift:278`).

Folder Settings, shared `Models/FolderSettingsWording.swift`: "Folder Settings" (`:14`), "Location" (`:17`), "Books" (`:20`), "Subfolders" (`:23`), "Feeds" (`:26`), "Time remaining" (`:30`), "Listening" (`:33`), "Done" (`:36`), "This folder is no longer in the library." (`:40`). Button: `LibraryFolderSettingsWording`, `Views/Library/LibraryFolderSettingsTarget.swift:13`, `:22`, `:29`: "Folder Settings"; "Folder settings for \(name)"; "Opens the settings of this folder: what it holds, and what happens when one of its books ends".

Listening options, `Models/ListeningOptionsWording.swift:60`, `:73-76`: "When \(article) \(singular) ends"; "Use the global setting (\(global.rawValue))"; "Play the \(singular) below"; "Play the \(singular) above"; "Stop".

### 7.21 Edit mode: `EditModeBar`, `Views/Library/LibrarySubviews.swift`

- "\(selectedCount) of \(totalCount) selected" (`:48`).
- "Deselect All", "Select All" (`:57`).
- "Move" (`:67`), label "Move \(CountWording.books(selectedCount)) to folder" (`:69`).
- Bar label: "Edit mode, \(CountWording.part(selectedCount, of: totalCount, singular: "book", plural: "books")) selected" (`:96`).
- Select label: "Deselect all books" (`:112`); "Select all \(CountWording.books(totalCount))" or "Select all books" (`:114`).
- Remove: `LibraryRemoveCommandWording.shortTitle`, `accessibilityLabel`, `accessibilityHint`, below.

### 7.22 Removing books: shared, `Models/RemovalWording.swift`

- `RemovalMode.buttonTitle`, `:28-34`: "Remove \(spaced)from Library Only", "Move \(spaced)to Trash", "Delete \(spaced)Permanently".
- `spokenAction`, `:39-44`: "Remove \(object) from the library and keep the files", "Move \(object) to the Trash", "Delete \(object) permanently".
- Files clause, `:63-67`: "stay in the TextMouth library folder"; "go to the Trash, where you can recover them until the Trash is emptied"; "are deleted permanently and cannot be recovered".
- Done, `:89-93`: "Removed \(subject) from the library. ", "Moved \(subject) to the Trash.", "Deleted \(subject) permanently."
- Dialog title: "Remove Book?", "Remove \(deletion.count) Books?" (`:237`).
- Message: "Choose how to remove \(deletion.subject) from the library. With \(deleteButtonTitle), \(filesClause). With \(keepButtonTitle), \(filesClause)." (`:266-268`).
- Row: "Remove from Library..." (`:451`), "Remove \(removal.count) Books from Library..." (`:462`).
- Edit bar: "Remove..." (`:487`).
- Label: "Remove \(removal.subject) from the library" (`:497`).
- Hint: "Asks whether to \(preferences.deletingTheFiles) or keep them in the TextMouth library folder." (`:511`).
- Button: "Cancel" (`Views/ContentView.swift:218`).
- Summary: "When a book is deleted, \(filesClause). With \(keepTitle), \(filesClause)." (`:746-750`).

The word Trash has no meaning on a phone. See 7.27.

### 7.23 Add to Library: shared, `Models/AddToLibraryWording.swift`

- "Add to Library" sheet title, button title, button label (`:9`, `:12`, `:15`).
- Hint: "Opens a sheet with the ways to add to the library: open a book, import a folder, make a book from text, record audio, or add a feed" (`:18`).
- "Cancel" (`:21`).
- Choices, `ShortcutAction`, `Models/KeyboardShortcut.swift:137-146`: "Open Book…", "Import Folder…", "New from Text…", "New Recording…", "Add Feed…".
- Open Book summary: "Opens a file picker to import books in any format TextMouth reads." (`Views/Library/LibraryView.swift:1936`).
- Others: "Chooses a folder that holds a DAISY book or audio tracks and imports it as one book." (`:29`), "Makes a new book from text you paste or type." (`:30`), "Records from a microphone into a new audiobook." (`:31`).
- Dimmed: "\(summary) Not available in this window." (`:39`).

### 7.24 Import progress: shared, `Models/ImportProgressWording.swift`

- Title: "Importing Books" (`:8`).
- Count: "3 of 10 books processed", from `CountWording.part` with `itemNoun` "book processed", "books processed" (`:13`, `:23-25`).
- "Extracting archive..." (`:16`).
- Extraction: "Extracting “\(archive)”: \(extracted(progress))..." (`:32`); "\(entriesDone) of \(entries) items", then ", \(size) of \(size)" (`:40-42`).
- A batch's book: "Book \(number) of \(total): “\(name)”, \(step)" (`:62`).
- One book: "“\(name)”, \(step)" (`:71`), then ": \(extracted)" (`:73`).
- Time on a book: "\(TimeFormatting.spoken(stepped)) on this book" (`:92`), after 10 seconds, in steps of 5.
- Tracks: "12 of 176 tracks", noun "track", "tracks" (`:108`).
- Time left: "Less than a minute left" (`:128`); "About \(TimeFormatting.spoken(rounded)) left" (`:129`).
- Cancelling: "Cancelling after this book..." (`:136`); "Cancelling..." (`:143`).
- Waiting: "\(n) more import waiting", "\(n) more imports waiting" (`:150`).
- Spoken status: "\(title): " then each line as a sentence (`:172`).
- Unasked: "Importing “\(subject)”: \(count)\(timeLeft)." (`:189`).
- Batch finished: "Finished importing “\(subject)”: \(counts)." (`:209`), counts "\(books) imported", "skipped as a duplicate" or "skipped as duplicates", "\(failed) failed".
- No new books: "No books were found in “\(subject)”." (`:223`); "No new books in “\(subject)”: its one book was already in your library." (`:225`); "No new books in “\(subject)”: both were already in your library." (`:227`); "No new books in “\(subject)”: all \(duplicates) were already in your library." (`:229`).
- Alerts: "Book Imported" (`:239`), "Nothing Imported" (`:245`).
- Holding others: "\(opening) It holds no files." (`:277`); "\(opening) It holds \(kindsHeld(files)), which TextMouth does not import." (`:278`).
- Book finished: "Finished importing “\(subject)”." (`:311`).
- Failed: "Could not import “\(subject)”." (`:317`).
- On request: "No import is under way." (`:324`).

Steps, `ImportStep.activity`, `Services/ImportFailure.swift:44-57`: "Checking its format", "Reading the file", "Creating its package", "Copying it into the library", "Extracting the archive", "Reading its manifest", "Converting its DAISY audio", "Converting its audio", "Checking the package", "Reading its text", "Reading its audio", "Saving its bookInfo.json file", "Adding it to the library folder", "Returning it to the library".

Failures, `Services/ImportFailure.swift:77`, `:82`: "\(step.activity) failed: \(description)"; "Could not import “\(fileName)”. \(reason)".

Overlay, `ProgressOverlay`, `Views/ContentView.swift:539`, `:544`, `:579`: "Cancel", label "Cancel Import", hint "Stops importing ZIP archives after the current book. Books already imported stay in the library." Text extraction: "Extracting Text" (`:97`).

iOS: `IOSUnavailable.feature`: "Converting this kind of file is not available on iPhone yet." (`Platform/iOS/Services/WatchedProcess+iOS.swift:101`, `Platform/iOS/IOSUnavailable.swift:18`).

### 7.25 Import questions

Shared, `Models/ImportDecision.swift`:

- "Duplicate Book Found" (`:233`).
- "Create Folder for Imported Books?" (`:235`).
- Place: "\(title), \(position) of \(total)" (`:304`).
- Duplicate: "“\(newCopy)” matches “\(matchingTitle)”, which is already in your library. Replace the existing copy, or keep both as separate books?" (`:379-380`).
- Text keep: "Replacing keeps the existing copy's reading position and bookmarks, moved to their words in the new text wherever those are found, and its settings, folder, and place on the reading list. An edit of its text is kept beside the new text as a copy, not applied to it." (`:313-316`).
- Audio keep: "Replacing keeps the existing copy's reading position, bookmarks, settings, folder, and place on the reading list, and its transcript when the audio is the same. Edits of its audio or of its manifest are not kept." (`:323-326`).
- Across kinds: "One copy is played from its recording and the other is read aloud from its text, so replacing keeps only the existing copy's folder and place on the reading list, not its reading position, its bookmarks and their notes, or its settings." (`:337-340`).
- Where the old copy goes: "The existing copy's files go to the Trash, but putting them back won't return that copy to your library." (`:358`).
- Incomplete: "The copy just imported is incomplete. \(warning)" (`:384`).
- ZIP: "\(CountWording.books(batch.books.count)) were imported from “\(archive)”. Would you like to create a new folder to hold them?" (`:281-283`).
- Copy gone, `DuplicateCopyWording`: `:407-408`, `:418-419`, `:427-428`.

Shared in the view file, `ImportDecisionChoiceWording`, `Views/Library/ImportDecisionSheet.swift:184-245`:

- "Keep Both", hint "Adds the new copy to the library as a separate book."
- "Replace Existing", hint "Puts the new copy in place of the one already in the library, keeping the existing copy's reading position, bookmarks, and settings."
- Across kinds, hint "Puts the new copy in place of the one already in the library, keeping only the existing copy's folder and place on the reading list."
- "Cancel", hint "Discards the new copy. The library stays as it was."
- "Keep", hint "Leaves the original file where it is."
- "Create Folder", hint "Moves the imported books into a new folder with this name."
- "No Thanks", hint "Leaves the imported books where they are."
- "Folder name".

Original file, `Models/OriginalFileDeletionWording.swift`: "the original file “\(fileName)”" (`:25`); "\(mode.buttonTitle("Original File"))?" (`:33`); "The book has been imported successfully. \(action)? \(consequence)" (`:46`); "You can recover it from the Trash until the Trash is emptied.", "It cannot be recovered." (`:52-53`).

### 7.26 Stops the listener must hear: shared

- `SpeechService.voiceDidNotStartAnnouncement`, "Speech paused: the voice did not start. Press Play to try again." (`Services/SpeechService.swift:1407`).
- `SpeechService.engineRefusedAnnouncement`, "Speech stopped: the Mac's speech engine refused this text." (`:1455`).
- `SpeechRefusalWording.heading`, "Speech Stopped" (`Models/SpeechRefusalReport.swift:315`).
- `summary`, "The Mac's speech engine refused to speak the text here, twice, so speech stopped. Play tries again from the same place." (`:318-319`).
- `announcement`, "Speech stopped: the speech engine refused this passage. Details are in the book's window." (`:325`).
- `audioStoppedRespondingMessage`, "Playback stopped: the audio stopped responding. Press Play to try again; if it stops again, quit and reopen TextMouth." (`ReaderViewModel+Playback.swift:2412-2413`).
- `memoryRunawayMessage`, "Playback stopped because TextMouth's memory grew to \(gigabytes) GB while the audio played, a fault in macOS's audio." (`:2420-2421`).
- `audioPlaybackFailureMessage`, "Chapter \(chapterNumber) could not be played: \(problem). \(remedy)" (`:2495`), remedies "Re-import the book to restore it." (`:2487`), "Re-import the book to replace it." (`:2489`), "Choose Retry to try again, or re-import the book if it keeps failing." (`:2491`), "Check that the disk holding your library is connected, then choose Retry." (`:2493`).

### 7.27 Words that say Mac, for the spec to decide

Each is shared, so a change must leave the Mac's words as they are, by a platform branch or a wording function:

- `SpeechService.engineRefusedAnnouncement`, `Services/SpeechService.swift:1455`.
- `SpeechRefusalWording.summary`, `Models/SpeechRefusalReport.swift:318`, and the report's "This Mac", "macOS:" lines (`:292-293`).
- `memoryRunawayMessage`, `ReaderViewModel+Playback.swift:2420-2421`; `audioStoppedRespondingMessage`, `:2413` ("quit and reopen").
- `BookmarkPanelView.emptyListHelp(keys:)`, by its keys, `Views/Reader/BookmarkPanelView.swift:456-467`.
- `SleepTimerView.customMinutesHint`, "Return sets the timer", `Views/Reader/SleepTimerView.swift:325`.
- `ReadingListWording.emptyList`, "the Library menu", `Models/ReadingListWording.swift:57-58`.
- `ReadingListWording.orderHint`, "dragging", `:32`.
- `RemovalWording` throughout, "Trash", `Models/RemovalWording.swift:32`, `:42`, `:65`, `:91`.
- `ImportDecisionWording.replacedCopySentence`, "Trash", `Models/ImportDecision.swift:358`.
- `OriginalFileDeletionWording`, "Trash", `Models/OriginalFileDeletionWording.swift:52`.
- `LibraryCloudWording.showInFinderTitle`, "Show in Finder", `Models/LibraryCloudWording.swift:52`.
- `KeptOnThisMacNote.text`, `Views/Library/BookCloudNote.swift:84`; `TimeRemainingBar`, `Views/Library/LibrarySubviews.swift:252`, `:275`.
- `DataDirectoryUnavailableText`, `Views/Library/DataDirectoryUnavailableView.swift`: "Library Not Available" (`:8`), "Getting Your Library" (`:11`), "Try Again" (`:21`), "Checks the library's location again, and opens the library when it is there." (`:23`), "Quit TextMouth" (`:25`), "Quits TextMouth without changing anything in the library's location." (`:27`), "To use another folder, open Settings, Storage, and choose ..." (`:34-36`), "Books can't be added while the library isn't available." (`:49`), "Books can't be opened while the library isn't available." (`:51`). And in the model: "The library is still not available. \(reason.explanation)", "The library is available." (`ViewModels/LibraryViewModel.swift:679`, `:704`). `Services/DataDirectoryAvailability.swift:254`, `:268-270`, `:293`, `:434` say "this Mac".
- `FileCommands`' New Window and the words "this window" in `NextBookWindowWording`, `Models/NextBookWindow.swift:153-185`, and `"This Window"`, `"A New Window"`, `:18`, `:21`.

Failure banner: "Storage problems" (`Views/Library/PersistenceFailureBanner.swift:34`), "Retry" (`:58`), "Dismiss" (`:61`), hint "Hides this notice without saving anything. It appears again if the problem returns after it clears." (`:69-70`).

### 7.28 Book Info

`LibraryBookInfoSheet`, inline, `Views/Library/LibrarySheetViews.swift`:

- "Book Information" (`:57`).
- "Title", label by `MetadataEditorWording.fieldLabel("Book title", ...)` (`:64-65`).
- "Author", "Book author" (`:66-67`).
- "Format" (`:69`), "Added" (`:94`), "Last Opened" (`:98`), "Word Count" (`:103`).
- "Cancel" (`:119`), "Save" (`:129`).
- Title: "Info: \(book.title)" (`:153`).

`MetadataEditorView`, inline, `Views/Reader/MetadataEditorView.swift`:

- "Book Information" (`:102`), "Cancel" (`:131`), "Save" (`:134`), title "Info: \(title)" (`:141`).
- Save label: "Save metadata changes" (`:208`).
- Audio: "Title"/"Book title" (`:228-229`); "Artist"/"Artist or narrator" (`:231-232`); "Album"/"Album name" (`:234-235`); "Genre" (`:237-238`); "Year" (`:240-241`); "Editable" (`:243`); "Duration", "Duration: \(duration)" (`:252`, `:255`); "Format", "File format: \(format)" (`:259`, `:262`); "Read Only" (`:265`).
- EPUB: "Title"/"Book title" (`:276-277`); "Author" (`:279-280`); "Publisher" (`:282-283`); "Publication Date"/"Publication date" (`:285-286`); "Editable" (`:288`); "ISBN", "ISBN: \(isbn)" (`:297`, `:301`); "Language" (`:305`, `:308`); "Identifier" (`:312`, `:316`); "EPUB Version", "EPUB version: \(v)" (`:320`, `:323`); "Read Only" (`:326`).

Shared, `MetadataEditorWording`, `:356`: "edited by hand" (`:360`), "\(label), \(editedByHand)" (`:366`), "Could not save: the book's title is empty. Type a title, then save again." (`:371`), "Could not save metadata: “\(title)” is no longer in the library. Nothing was changed." (`:377`). Reader: "Metadata updated" (`ReaderViewModel+Bookmarks.swift:489`).

Shared, `EPUBMetadataSaveWording`, `Models/EPUBMetadataSave.swift`: "Metadata saved to \(libraryCopy)." (`:113`); "Metadata saved to the library only; the EPUB file is unchanged." (`:135`); "Also write to the library's copy of the EPUB file" (`:143-147`); `saveButtonLabel`, `:161-164`.

Spoken info, shared, `LibraryInfoWording`, `Models/LibraryInfoWording.swift`: "Nothing is selected." (`:619`); "Folder" (`:621`); "Unopened" (`:623`); "Not in a folder" (`:625`); "Open in a reader window" (`:627`); "By \(author)" (`:672`); "In \(folderPath)" (`:699`); "In reading list, \(position) of \(count)" (`:707`); "Added \(moment)" (`:724`); "Last opened \(moment)" (`:726`); "File size \(size)" (`:739`); "\(spoken) remaining" (`:845`). Example at `docs/user/library-window.md:70`: "Middlemarch. By George Eliot. EPUB. In Classics. In reading list, 3 of 12. 42 percent. 2 hours, 5 minutes remaining."

### 7.29 Statistics: shared, `Models/ReadingStatsTile.swift`

- Tiles: "Today", "This Week", "All Time", "Current Streak", "Books Finished This Year", "Books Finished All Time" (`:135-140`).
- Spoken: "Listening time today" (`:155`); "Listening time this week" (`:157`); "Total listening time" (`:159`), each followed by ": \(TimeFormatting.spoken(seconds))" (`:196`); "Current listening streak: \($0)" (`:162`); "\(phrase) finished \(when)" with ": \(breakdown)" (`:223`), when "this year", "all time".
- Kinds: "text book", "audiobook", "podcast episode", "other book" (`:95-98`).
- Inline in `Views/Settings/ReadingStatsView.swift`: "Listening Time" (`:65`), "Progress" (`:72`), "Recently Finished" (`:92`), "\(entry.title), finished \(date)" (`:89`).

## 8. Settings

Every preference below is on `SettingsViewModel`, `ViewModels/SettingsViewModel.swift:184`, an `@AppStorage` in `TextMouthRuntime.current.preferences`, mirrored in config.json by `syncToConfig()` under the same key (`ConfigService.AppConfig`, `Services/ConfigService.swift`). Ranges and defaults are in `Models/SettingsPolicy.swift`. The view lines are in `Views/Settings/SettingsView.swift`.

### 8.1 Worth having in the first version

Voice:

- "Language" (`:163`), label "Voice language" (`:173`), item "All" (`:164`). Key `selectedLanguage`, default "en" (`SettingsViewModel.swift:521`).
- "Voice" (`:175`), label "Select voice" (`:186`), hint "Choose a voice for reading. Change takes effect immediately." (`:187`), item label "\(voice.name), \(quality) quality" (`:183`). Key `selectedVoiceID` (`SettingsViewModel.swift:518`).
- "Quality", "Language" readouts (`:190`, `:193`).
- "Preview Voice" (`:198`), label "Preview selected voice" (`:201`), speaks "Hello! This is TextMouth, ready to read for you." (`:263`).
- "Default Speed" (`:227`); shown "Default Speed: \(Int(wpm)) WPM" (`:207`); slider "Words per minute" (`:215`), label "Default speed" (`:219`), value "\(Int(wpm)) words per minute" (`:220`); caption "Default speed for new books. Each book can override this with its own speed." (`:222`). Key `wordsPerMinute`, 50 to 650, step 25, default 200 (`SettingsPolicy.swift:373`).
- "Default Pitch" (`:252`); shown "Default Pitch: \(pitchLabel)" (`:234`); label "Default pitch" (`:244`), value `pitchLabel` (`:245`); caption "Default pitch for new books. 1.0 is normal. Each book can override this." (`:247`). Key `pitchMultiplier`, 0.5 to 2.0, step 0.1, default 1 (`:377`).

Playback:

- Section "Skip Controls" (`:299`). "Skip Forward" (`:277`), label "Skip forward unit" (`:285`), hint "What happens when you skip forward" (`:286`); key `skipForwardUnit`, default "15 seconds". "Skip Backward" (`:288`), label "Skip backward unit" (`:296`), hint "What happens when you skip backward" (`:297`); key `skipBackwardUnit`, default "15 seconds".
- Section "Rewind on Resume" (`:375`). "Rewind to" (`:333`), label "Rewind on resume unit" (`:341`), hint "When resuming playback, rewind to the start of this unit" (`:342`); key `rewindOnResumeUnit`, default None. "Smart mode" (`:345`), label "Smart rewind mode" (`:346`), hint "Only rewind if the pause was longer than the threshold" (`:347`); key `rewindSmartMode`, default off. "Minimum pause: \(Int) seconds" (`:353`), stepper label "Minimum pause threshold" (`:365`), value "\(Int) seconds" (`:366`), "Don't rewind if paused for less than this." (`:368`); key `rewindSmartThreshold`, 5 to 600, step 5, default 70.
- Section "Punctuation Pauses" (`:402`). "Punctuation pauses: \(levelName)" (`:384`), names "Off", "Subtle", "Moderate", "Heavy" (`:381`); label "Punctuation pause level" (`:394`), value the name (`:395`); caption "0 = Off, 1 = Subtle (periods), 2 = Moderate (+ commas), 3 = Heavy (+ paragraph breaks)" (`:397`); key `punctuationPauseLevel`, 0 to 3, default 0.
- Section "Navigation" (`:417`). "Auto-play after navigation" (`:406-407`), hint "When enabled, playback starts automatically after jumping to a heading, bookmark, or search result" (`:408`), caption "Automatically start playing when you navigate to a heading, bookmark, or search result." (`:412`); key `autoPlayOnNavigate`, default off.
- Section "End of Book" (`:463`). "When book ends" (`:421`), label "End of book behavior" (`:429`), hint "What happens when a book finishes playing" (`:430`), caption "\"Continue to Next Book\" plays the next book in the same folder by sort order." (`:432`), and `EndOfBookWording.playOnAFinishedBookCaption`; key `endOfBookBehavior`, default Stop.
- Section "Sleep Timer" (`:495`). "Fade out: \(text)" (`:471`), text "Off" or `CountWording.seconds` (`:611-613`); stepper label "Fade out duration" (`:483`); caption "Gradually reduce volume before pausing when the sleep timer expires. 0 pauses instantly." (`:486`); key `sleepFadeOutDuration`, 0 to 10, default 0. "Close sheet after setting timer" (`:491`), label "Close sleep timer sheet after setting a timer" (`:492`), hint "When off, the sheet stays open showing the remaining time and a reset button" (`:493`); key `sleepTimerAutoClose`, default on. Sleep timer presets are constants; the last duration is stored under `sleepTimer.lastUsedDuration` (`Services/SleepTimerService.swift:140`).
- Section `ReaderTimeWording.settingSection`, "Times" (`:553`). `settingTitle`, "Include the speed with time left and total time"; `settingHint`, "Adds the speed they count at, such as 2.0x for an audiobook not at 1x, or 500 words a minute for a text book, in the reader, Where Am I?, Copy Reading Position, and the Headings sheet's durations." (`Models/ReaderTimeWording.swift:161`, `:168-170`); key `includeSpeedWithTimes`, default off.
- Section `ReaderPageWording.settingSection`, "Pages" (`:585`): `showsPageInReader`, default on; `saysPageInWhereAmI`, default on. Words in 7.6.

Removal, in `Views/Settings/StorageSettingsView.swift`:

- Section "Removal Behavior" (`:365`). "Confirm before removing a book" (`:346`), key `confirmBeforeDelete`, default on (`Services/ConfigService.swift:237`).
- "Move to Trash instead of deleting" (`:352`), key `moveToTrashInsteadOfDeleting`, default on (`:264`): see below.

Stats: `ReadingStatsView`, no settings.

### 8.2 Should not appear on a phone, and why

- Shift+Skip: "Shift+Skip Forward", "Shift+Skip Backward", keys `shiftSkipForwardUnit`, `shiftSkipBackwardUnit` (`:303`, `:314`). They need a Shift key.
- "Open the next book in", key `nextBookWindow` (`:447`, `Models/SettingsPolicy.swift:437`). A phone has one screen. It also appears in Folder Settings (`Views/NextBookWindowPicker.swift`).
- "Navigation unit controls", key `playbackNavigationUnitControlMode`, and "Show bookmark button", `showBookmarkInPlaybackControls`, "Show speed controls", `showSpeedInPlaybackControls` (`:499`, `:515`, `:522`): these decide what crowds a Mac's bar; the phone's screen has its own layout. The mode still matters: `PlaybackSkipUnitPolicy.resolve` reads it (`ViewModels/SettingsViewModel.swift:161-180`), and at its default `.none` per-book units are ignored. The spec should choose, and iPhone code should set it, not offer it.
- "Show Export in the reader toolbar", `showExportInReaderToolbar`: later.
- Shortcuts tab, all of it, and `shortcutDoublePressSeconds`: hardware keys. A later iPad or keyboard question.
- Storage Directory, Library Maintenance, Logs (`logLocation`), `dataDirectoryPath`: the container is the place. Show Logs in Finder has no Finder.
- "After Importing a Book", `importDeleteBehavior` (`Views/Settings/StorageSettingsView.swift:307`), choices "Keep Original", "Delete After Import", "Ask Each Time" (`Services/ConfigService.swift:1395-1397`). The phone copies a file from Files, and the delete runs outside the file's scope. Keep at Keep Original.
- "Move to Trash instead of deleting": no Trash to open on the phone. Decide one way, and word it.
- "Keep originals of converted audio", `keepsOriginalOfConvertedAudio`: nothing converts on iOS.
- Bluetooth: "Enable Bluetooth monitoring", `bluetoothMonitoringEnabled`, `bluetoothDisconnectDelay` (`Views/Settings/MiscellaneousSettingsView.swift:21`, `:38`). They concern macOS's `rcd`. The phone needs route handling, not a switch.
- Restart gesture: `restartTimerGestureEnabled`, `restartTimerGesturePattern`, `restartTimerGestureWindow`. Works through `MediaGestureDetector` on any platform, so it may come later.
- Sounds tab until sounds are bundled: `soundEffectsEnabled`, `soundEffectsVolume`, `soundEffectAssignments` (`Services/SoundEffectService.swift`). `availableSounds()` would offer only "None".
- Braille, Feeds, Transcription, Audio Editing, Text: later features. Their defaults still act: the shipped substitution rules apply to speech (`TextSubstitutionService.shared`).

## 9. Tests

### 9.1 What pins the shared types

Test classes are in `TextMouthProductionTests/`, one bundle hosted by the Mac app.

- `ReaderPageWording`, `BookPages`, `PagePosition`, `JumpInputValidator`, `JumpFieldOutcome`: `GoToPageTests`, `PageNavigationTests`, `PageModelTests`.
- `ReaderTimeWording`, `TimeEntry`, `PlaceClock`: `JumpToTimeTests`, `SpeedBesideTimesTests`, `CopiedPlaceRecordingTimeTests`, `TimeEntryTests`.
- `EndOfBookWording`, `EndOfBookRule`: `FinishedBookWordingTests`, `FinishedBookModelTests`, `FinishedBookReaderTests`, `EndOfBookRuleTests`, `ContinueToNextBookTests`, `EndBehaviorMatrixTests`.
- `FolderNavigationWording`, `NextBookWindowRule`: `NextBookWindowTests`, `NextBookWindowReaderTests`, `EpisodeDownloadContinuationTests`.
- `SleepTimerService`, `SleepTimerDuration`, `SleepTimerHandOverWording`: `SleepTimerServiceTests`, `IntegrationSleepTimerTests`, `A10AccessibilityTests`.
- `ImportProgressWording`, `ImportDecisionWording`, `ImportDecisionQueue`: `ImportProgressWordingTests`, `ImportProgressTests`, `ProgressOverlayTests`, `ImportDecisionQueueTests`, `ImportDecisionSheetTests`, `ImportDecisionFlowTests`.
- `CountWording`, `TimeFormatting`: `CountWordingTests`.
- `LibraryInfoWording`: `LibraryInfoWordingTests`.
- `LibrarySortState`: `LibrarySortStateTests`, `LibrarySortSavingTests`, `LibraryBookSorterTests`.
- `LibraryViewPickerWording`: `LibraryViewPickerTests`, `LibraryViewGoToTests`, `LibraryViewLocationTests`.
- `RemovalWording`: `RemovalWordingTests`.
- `BookSettingsWording`, `SkipUnit`, `AudioSpeed`: `PlaybackSettingsAuditTests`, `A10AccessibilityTests`, `SettingsPolicyTests`, `LegacyBookStateTests`.
- `HeadingPosition`, navigation: `HeadingVocabularyTests`, `HeadingAnnouncementTests`, `LegacyNavigationAlgorithmTests`, `LegacySentenceParagraphSkipTests`.
- Where Am I?: `WhereAmIPolicyTests`, `WhereAmIAnnouncementEndTests`, `LegacyWhereAmIProductionTests`, `FullSummaryActionTests`, `FullSummaryReaderTests`.
- Now Playing: `NowPlayingOwnershipTests`, `MediaCommandPlaybackTests`, `RemoteMediaCommandPolicyTests`, `AudioRouteMonitoringTests`.
- Statistics: `ReadingStatsServiceTests`, `ReadingStatsViewTests`, `ReadingStatsDayAttributionTests`.
- Reader sheets: `ViewsAndWindowsReaderSheetTests`, `BookmarkKeyboardAccessTests`, `BookmarkPlacementTests`.
- Runtime and paths: `HostedTestIsolationTests`, `DataDirectoryPreferencesTests`.
- Routing: `LibraryWindowRouterTests`, `WindowFocusPolicyTests`.
- Concurrency policy: `UncheckedConcurrencyPolicyTests` counts `@unchecked Sendable` and `nonisolated(unsafe)` across every Swift file, platform folders included (27 and 15, `docs/architecture/parts-of-the-app.md:27`). A new one fails it.

### 9.2 Where iPhone logic should go

- The Mac test target compiles `TextMouth` less `Platform/iOS/**` (`project.yml:109-111`), and `TextMouthProductionTests` is `platform: macOS` with `TEST_HOST` the Mac app (`:418-452`). So nothing under `TextMouth/Platform/iOS/` can be tested tonight, on any machine: the iOS platform is not installed, and the Mac does not compile that folder.
- So a plain iPhone type that needs tests goes in a shared folder, such as `TextMouth/Models/` (values, words, and rules) or `TextMouth/ViewModels/` (a `@MainActor` coordinator with no UIKit). Both targets compile it (`docs/architecture/platforms.md:13`), and `@testable import TextMouth` reaches it.
- It must import only `Foundation`, or `SwiftUI` with no UIKit-only name, or wrap the UIKit part in `#if os(iOS)`. An `#if os(iOS)` block is compiled on iOS alone and is untestable; keep decisions out of it.
- A view with no platform code can go in `Views/iPhone/` or the like, also shared, and so be hosted in a test on the Mac, but a view named by no Mac code is dead code there. The Mac's size limit is 50 MB and its projection reports new shared files as new (`docs/architecture/platforms.md:40` has the precedent: 13 such files in phase 0, read and allowed). A view that can only run on iOS belongs in `Platform/iOS/Views/`.
- A shared type used only by the iPhone is one of the kinds phase 0 allowed ("new shared code that only tests and aliases use"). `make mac-projection BASE=main` will list it; a reviewer reads it. Anything else the Mac compiles must fit one of the five kinds (`docs/architecture/platforms.md:30-36`): a move, a wrapper, an alias, a control-style helper, a split. A new helper in `Platform/` needs its line in `Scripts/ios/mac-projection.py` (`:38`).
- Wording moved out of a view stays pinned by the same tests, and `Views/...` statics are callable where they are: a view file can hold a `nonisolated static` word.

### 9.3 Adding a file

- New test file: put it in `TextMouthProductionTests/`, then `python3 -I Scripts/agents/regenerate-project.py` (`Scripts/agents/regenerate-project.py:1-29`), and commit the changed `TextMouth.xcodeproj/project.pbxproj` with it. `make generate` is the plain form (`docs/developer/building.md:26`), but it changes the copy-phase order.
- New source file, anywhere under `TextMouth/`: the same regeneration, so the Xcode targets know it. `make typecheck-ios` reads the committed tree (`docs/developer/building.md:46-48`) by its own rule (`Scripts/ios/typecheck.py:13-14`, `:147-157`), so commit first.
- Place a new test class in `Scripts/test/areas.conf`: `python3 Scripts/test/run-area.py --unassigned` must end "0 unassigned classes" (`docs/developer/testing.md:60`).
- Run tests only through the build train: `python3 -I Scripts/agents/build-train.py request --agent SLUG --branch BRANCH --classes A,B`, and wait with `python3 -I Scripts/agents/wait-for-result.py --agent SLUG` in the background (`docs/developer/testing.md:53-56`).
- `make lint-tests`, `make lint-a11y`, `make lint-ogg` read only what a branch adds (`docs/developer/testing.md:65-69`).
- A test must not leave a reader open, or it fails (`docs/developer/testing.md:9`): call `close()`.
- Under test, `NowPlayingService` installs no system integrations (`Services/NowPlayingService.swift:256-258`) and `VoiceOverAnnouncer` records (`Services/VoiceOverAnnouncer.swift:45-47`), so `VoiceOverAnnouncer.recordedAnnouncements` is how a test reads a sentence.

### 9.4 How the excludes behave

- `TextMouth` (Mac): `path: TextMouth`, `excludes: "Platform/iOS/**"` (`project.yml:109-111`). Everything else, `Resources/` included through `INFOPLIST_FILE` and the asset catalog.
- `TextMouthiOS`: `path: TextMouth`, `excludes: "Platform/macOS/**"`, `"Resources/**"` (`:277-280`).
- A new file in `Models/`, `ViewModels/`, `Views/`, `Services/`, `App/`, or directly in `Platform/` is in both. A new file in `Platform/iOS/` is in iOS alone. A new file in `Platform/macOS/` is in the Mac alone, and shared code must not name it without a stand-in (`docs/architecture/platforms.md:44`).
- A resource for the phone cannot go in `Resources/`. It needs a folder of its own, listed in the `TextMouthiOS` target, and a `Platform/iOS` path outside `.swift` files needs the same care, since `sources: path: TextMouth` takes non-Swift files as resources too.
- Bundled sounds and `Assets.xcassets` for the iOS icon follow from this.

## 10. The fifteen things most likely to bite

1. The home directory. `App/TextMouthRuntime.swift:144-149` reads `getpwuid`. In the Simulator the data directory would be the user's live `~/.TextMouth`, which no agent may touch (not run). Fix it, and `TextMouthPaths.defaultRoot(in:)` at `Services/TextMouthPaths.swift:15-17`, first. Don't name the new folder `Library/Application Support/TextMouth`: that is the legacy location (`Services/TextMouthPaths.swift:593`).
2. M4B and M4A imports fail. `Parsers/AudioContentSniffer.swift:115-116` asks `afinfo`; `Platform/iOS/Services/WatchedProcess+iOS.swift:106-115` throws; `Services/FileImportService+AudioConversion.swift:60` stops the import at "Converting its audio". Return `.couldNotStart` from the stand-in.
3. Import questions never show. `Views/Library/ImportDecisionPresenter.swift:85-90` needs an `ImportOrigin`, and `:15-24` never gives one on iOS. The phone presents `library.importDecisions.current` itself, with `currentImportDecisionWording` and `answerImportDecision(_:with:)`, or a duplicate's new copy waits for ever.
4. App-wide notifications reach nobody. `Services/LibraryWindowRouter.swift:380` listens only because `Platform/macOS/App/AppDelegate.swift:22` asked, and `openLibraryWindow` answers false by default (`:47`). `.continueToNextBook` and `.openBookWindow` must be heard, or Continue to Next Book says "Starting: Dune" and nothing starts. `windowStanding` is `.noWindow` (`ViewModels/ReaderViewModel+NextBookWindow.swift:53-59`), so `showNextBook` takes that path whatever the switcher.
5. `close()` is final and is on `onDisappear`. `Views/Reader/BookReaderWindowView.swift:124-133` stops the book when its screen goes. Don't reuse that view. `ViewModels/ReaderViewModel.swift:2239`, `:2307`: after `close()`, `content` is nil and every subscription is gone. Own the reader above the navigation.
6. Nothing saves as the app leaves. `Platform/macOS/App/AppDelegate.swift:195-236` is the Mac's whole save path, and iOS gives no last call. Without a `scenePhase` handler calling `PlaybackMemoryGuard.savePendingWrites()` (`Services/PlaybackMemoryGuard.swift:442`), a killed app loses up to 30 seconds of place (`ViewModels/ReaderViewModel.swift:132`) and any library.json waiting on its debounce.
7. VoiceOver focus does nothing. `Platform/iOS/Views/VoiceOverFocus+iOS.swift:35-71` holds hidden views and an identifier. Every reused sheet opens with VoiceOver left where it was, in silence and without an error. The rules to keep are in `Views/Reader/BookmarkPanelView.swift:489-584` (where focus goes after each operation) and `Views/Reader/HeadingNavigatorView.swift:405-410`.
8. Fixed sizes. `Views/Reader/ReaderView.swift:1039`, `Views/Reader/HeadingNavigatorView.swift:357`, `Views/Reader/BookmarkPanelView.swift:116`, `Views/Reader/MetadataEditorView.swift:140`, `Views/Library/ImportDecisionSheet.swift:76`, `Views/Library/LibrarySheetViews.swift:152`, `Views/ContentView.swift:166`, `Views/Reader/BookReaderWindowView.swift:134`, `Views/Settings/SettingsView.swift:12`. Each clips on a phone and pushes controls out of VoiceOver's reach. Removing one directly changes the Mac: add a helper in `Platform/PlatformControlStyles.swift` that applies the frame on the Mac alone, with its line in `Scripts/ios/mac-projection.py`.
9. Screen lock silences it. `project.yml:281-292` declares no background audio, and no code sets an audio session (section 6.4). Route changes never reach `ReaderViewModel+Playback.swift:324`, since the listener is empty on iOS (`Services/NowPlayingService.swift:1347`). The audio researcher has the rules; this code has none of it yet, and the route change must call `pauseForAudioRouteChange()`.
10. The lock screen shows little and says the wrong thing. `Services/NowPlayingService.swift:1230-1234` gives title, artist, and rate alone, with no duration or elapsed time. `:772`, `:776` advertise 30 and 15 seconds, while `:923-946` skip by the reader's unit: a Control Center "back 15" can move a heading.
11. A bar that watches the reader redraws 8 times a second. `ViewModels/ReaderViewModel.swift:710`; `Views/Reader/PlaybackControlsView.swift:4` observes all of it. A now-playing bar must use `ReaderSnapshot`, `Views/Reader/ReaderSnapshot.swift:16`, or VoiceOver's cursor suffers, as `Views/Reader/HeadingNavigatorView.swift:5-9` explains.
12. Sounds are silent twice over. `ViewModels/ReaderViewModel.swift:151` is nil until `Views/Reader/ReaderView.swift:28-30`, and `Services/SoundEffectService.swift:194` names a folder iOS lacks (not run). The phone must set the service as it makes the reader, and bundle sounds. A blind listener uses these sounds to confirm a press.
13. Mac words in shared constants. `Services/SpeechService.swift:1455`, `Models/SpeechRefusalReport.swift:318`, `ViewModels/ReaderViewModel+Playback.swift:2413`, `:2421`, `Views/Reader/BookmarkPanelView.swift:465` ("Command + B"), `Models/RemovalWording.swift:32` ("Trash"). Mac tests pin these, so change them by a platform-aware function, and don't edit the Mac's text. Section 7.27 lists them all.
14. A row has no tap, and its menu is the Mac's. `Views/Library/LibrarySubviews.swift:896-902` opens a book only by VoiceOver's default action or the context menu's Open. `:913-1021` offers Export… and, through `ViewModels/LibraryViewModel+Cloud.swift:447`, Show in Finder, which does nothing on iOS (`:534-539`). Pass an empty `cloudCommands` and build the phone's list of actions.
15. The book's text. `Views/Reader/ReaderView.swift:373-409`: one `Text` of up to 20,000 characters (`ViewModels/ReaderViewModel.swift:1852`), replaced as playback moves, with a scroll-area label whose history on the Mac is the warning at `:363-368` (on the text itself, the label replaced the words). Selection is off during playback (`:383-394`). On iOS VoiceOver reads a `Text` as one element, so line and word reading needs a `UITextView` such as `ReadOnlyTextArea` (`Platform/iOS/Views/ReadOnlyTextArea+iOS.swift:12`), kept from rebuilding under the cursor.

Two more, in case the fifteen are done early:

- Sentence and Paragraph units do nothing useful in an audiobook, whose text is spaces (`ViewModels/ReaderViewModel+Navigation.swift:356-411`, `Parsers/AudioBookParser.swift:185`), and a press of Previous at a chapter's start goes to the first chapter. The pickers offer them (`ViewModels/ReaderViewModel+Pages.swift:108-110`).
- Skips debounce for 0.4 seconds (`ViewModels/ReaderViewModel.swift:721`) to absorb one media key arriving by two paths on a Mac. A quick second flick on the phone is dropped in silence.

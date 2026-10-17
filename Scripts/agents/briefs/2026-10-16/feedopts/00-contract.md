# Team feedopts: the contract every task shares (October 16, 2026)

Written by `feedopts-lead`. Read it with your brief. Tasks are built apart, one after another, so the names below are fixed: use them exactly. If a name cannot work, post to `feedopts-lead` before you change it.

The user's request (FR19), in their words: "have similar options for Feeds as for the reader list view with an option to continue to the next book and to skip finished books and one to delete items as they're finished / download them as you approach the end... maybe actually add an option when in a folder or feed to the toolbar for 'Folder Settings' or 'Feed Settings' that would just be another way to pop up the sheet you get with cmd+i but for the folder/feed you're in." The orchestrator's design decisions follow; the user confirms them in the morning, so each lives in one place, easy to change.

## The rules of the design

1. **Standard means nothing is stored.** A feed or a folder with no choices of its own keeps `listeningOptions == nil`; so does one whose choices are all the defaults (`ListeningOptions.standard`). Every existing library therefore behaves exactly as before, and its files are byte for byte what they were.
2. **Which setting wins at the end of a book**, strongest first:
   1. the reading list, when the book was opened from it (unchanged);
   2. the book's own end behavior (`Book.localEndOfBookBehavior`, set in the reader's settings sheet);
   3. the feed's or the plain folder's "When an episode/book ends" (`ListeningOptions.continuation`), unless it is nil, "Use the global setting";
   4. the global setting (`SettingsViewModel.endOfBookBehavior`, stored under `SettingsPolicy.endOfBookBehavior`).
   The feed's or folder's "Skip finished" and "Download the next episode" apply whenever listening goes on from one of its items to another, whoever sent it there (its own option, the book's own Continue to Next Book, or the global one). Only the reading list uses its own skip option.
3. **Direction.** "Below" is the next item in the order the library lists them: for a plain folder `ManualBookOrder.orderedBooks(in:folderPath:)` (what `laterBooksInFolder` uses today), for a feed `FeedCenter.listedItems(of:)`, newest first. "Above" is the other way. The book's own Continue to Next Book, and the global one, always go below.
4. **Finished.** A book is finished when it rests at its end (`Book.restsAtEnd`), as Continue to Next Book already counts it. A feed item whose file is not here is finished when it was played (`FeedItem.playedDate != nil`).
5. **Where the options live.** A plain folder's options apply to the books directly in it, never to its subfolders, never to a feed's folder (that feed's own options apply there), and the library's top level has none. A feed's options apply to its items.
6. **The delete-when-finished control already exists** ("Delete downloads after playing" in Feed Info's "This Feed's Settings"). Add no second control for it.
7. **The episode that follows may not be downloaded.** When the next item of a feed has no file here, it is downloaded (origin `.listener`) and played once it arrives, and the listener hears what is happening. Today's `nextBookInFolder`/`laterBooksInFolder` pass over such items, and existing tests pin that; they keep doing so. The new search is a separate function (task B3).
8. **Words.** Every control, label, hint, and spoken message is a constant or function in a wording type, pinned by a test with its exact string. The user is a VoiceOver and braille user: every control keyboard-operable, every value spoken, nothing by sight alone. The orchestrator copies the wording from your report into the user's documentation, so use the strings your brief gives, and report any you changed and why.

## Names, by the task that adds them

| Task | Adds |
| --- | --- |
| **A** `model` | `ListeningOptions` (`TextMouth/Models/ListeningOptions.swift`): `continuation: ReadingList.Continuation?`, `skipsFinished: Bool` (true), `predownloadsNext: Bool` (true), `static let standard`, `isStandard`, `goesOn(under: EndOfBookBehavior) -> Bool`. `Feed.listeningOptions: ListeningOptions?` and `BookFolder.listeningOptions: ListeningOptions?`. `FeedCenter.setListeningOptions(_:of:)`. `LibraryViewModel.listeningOptions(of: Book) -> ListeningOptions?`, `.listeningOptions(ofFolder: UUID) -> ListeningOptions?`, `.setListeningOptions(_:ofFolder:)`. `EnumSettingRule.storedValue(in: UserDefaults)`. `ListeningOptionsWording` with `Noun`. |
| **B1** `succession` | `ListNeighbors.beyond(_:going:in:)` and `.neighbor(of:_:in:where:)` (`TextMouth/Models/ListNeighbors.swift`). `LibraryViewModel.booksBeyond(_:going:)` and `.nextBook(after:going:skippingFinished:)`. `BookSuccession` (`.book(Book)`, `.nothing(note: String)`) and `ReaderViewModel.goOnPastThisBook(...)`. |
| **B2** `endrule` | `EndOfBookRule` (`TextMouth/Models/EndOfBookRule.swift`): `behavior`, `direction`, `skipsFinished`, `predownloadsNext`, `static resolve(localRawValue:options:global:)`. `ReaderViewModel.endOfBookRule`; `effectiveEndOfBookBehavior` reads it. `EndOfBookWording.onlyFinishedBooksInFolderNote(going:)`. |
| **B3** `episodedl` | `BookSuccession.episodeToDownload(feedID: UUID, item: FeedItem)`. `LibraryViewModel.succession(after:going:skippingFinished:) -> BookSuccession` (feed items: the item beyond, downloaded or not). The reader's wait for the download, and `EndOfBookWording` for it. |
| **C** `predownload` | `ReaderViewModel` pre-download of the next episode (`ReaderViewModel+Predownload.swift`). |
| **D** `feedsheet` | `FeedInfoModel` listening properties and Feed Info's three controls. |
| **E** `foldersheet` | `FolderSettingsModel`, `FolderSettingsSheet`, `FolderSettingsWording`. |
| **F** `toolbar` | `LibraryFolderSettingsTarget`, the toolbar button, `ShortcutAction.folderOrFeedSettings`, `Notification.Name.showFolderOrFeedSettings`. |
| **G** `addsheet` | `AddToLibraryChoice`, `AddToLibrarySheet`, `AddToLibraryWording` (FR20). |
| **H** `addbutton` | The toolbar's Add to Library button replacing three (FR20). |

## Existing tests

An existing test that fails after your change may be the only sign of a bug in the app. **Stop and ask** (post to `feedopts-lead`, then wait for the answer); never edit, weaken, or work around it. Two exceptions, each only when your brief says so: a test that lists every shortcut action and fails only because of the one action your brief adds, and the tests your brief names as pinning behavior that changes on purpose.

## Files you may not touch

`*.md` files other than your own report; `TextMouth.xcodeproj/project.pbxproj` except by `xcodegen generate` for a new file; any file your brief does not name. Other teams work tonight in `Scripts/test`, `TestData`, the Makefile, and the audio and recording code; a problem there is a finding on the board (`bbs post ... --tag finding --file <path>`), never an edit.

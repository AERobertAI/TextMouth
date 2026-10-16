# Task F, `feedopts-toolbar`: the "Feed Settings" / "Folder Settings" toolbar button

Branch `feedopts/toolbar`. Read `00-contract.md` first. Tasks A, D, and E are on the team branch: Feed Info has its listening controls (D), and `FolderSettingsModel` and `FolderSettingsSheet` exist (E, `TextMouth/Views/Library/FolderSettingsSheet.swift`, `FolderSettingsWording`). **In the library toolbar, while the window shows a folder other than the top level, add a button that opens the sheet for the folder shown**: "Feed Settings" in a feed's folder (the Feed Info sheet, the same way Command-I on the feed's row opens it), "Folder Settings" in a plain folder (the new sheet). Add a keyboard-shortcut action with no default key, "Folder or Feed Settings", so the listener can bind a key.

This is FR19's last piece and shares the toolbar with FR20 (task H, after yours, replaces three buttons in the same region): keep your toolbar hunk small and separate.

## What exists (read by line range)

- `TextMouth/Views/Library/LibraryView.swift:493-555`: the toolbar; New Folder is `:541-549`, shown for `category == .folders`; the Sort menu follows. The window's state: `category`, `currentFolderPath` (`:171`/`:200`, a `@Binding`), `shownFeedID` (`:1301-1307`, the feed whose folder the list shows), `feedFolders` (`LibraryFeedFolders`), `libraryViewModel`, `settingsViewModel` (`:198-199`).
- `showFeedInfo(_ feedID:)` (`:1657`) calls `performFeedAction(FeedAction(command: .feedInfo, feedID:, title: FeedWording.feedInfoTitle))`, which sets `LibraryFeedsPresenter.feedInfo` (`FeedCommandRunner.swift:86-87`); the sheet is presented by `LibraryFeedsWindowSupport` (`LibraryFeedsWindowSupport.swift:217`). **Reuse that path; do not build a second one.**
- Command-I (`:678-695`) opens Feed Info for a feed's row or feed's folder, the Book Info sheet for a book, and **speaks** a plain folder's full information (`LibraryInfoRow.swift:66-77`). Leave all of that.
- A modifier per group of commands keeps `LibraryView.body` quick to type-check (`LibraryOrderCommandsSupport`, `:1952-1988`; the file's comments say the long chain once took the compiler eight seconds): put your sheet and notification handler in **a new `private struct LibraryFolderSettingsSupport: ViewModifier`** in that style.
- Shortcut actions: `TextMouth/Models/KeyboardShortcut.swift`: the enum (`:4-110`), `notificationName` (`:262-300`), `category` (`:320-345`), and `defaultBindings` (`:1453-1610`); "Add to Reading List" (`:88`, `:1594`, `MenuCommands.swift:401`, `LibraryView.swift:1977`) is a Library-menu command with no default key: **copy its way through every one of those places**. `ShortcutPressDispatcher.swift:785` and the shortcut tests list actions; run them (below).
- The toolbar can be inspected in a hosted window: `BookExportSheetTests.swift:298-330` shows a reader's toolbar read as AppKit draws it. `ViewsAndWindowsLibraryListTests.swift:114` constructs a `LibraryView`.

## What to build

1. **New `TextMouth/Views/Library/LibraryFolderSettingsTarget.swift`**, pure:
   ```swift
   enum LibraryFolderSettingsTarget: Equatable {
       case feed(feedID: UUID, title: String)
       case folder(folderID: UUID, name: String)
       static func of(category: LibraryCategory, folderPath: String, folders: [BookFolder], feedID: (UUID) -> UUID?, feedTitle: (UUID) -> String?) -> LibraryFolderSettingsTarget?
   }
   ```
   `nil` unless `category == .folders` and the path names a folder (compare as `shownFeedID` does, `BookFolder.fullPath`); `.feed` when `feedID(folder.id)` names a feed (with its title, or the folder's name when the record is gone); else `.folder`. Wording, exact, as properties of the target and constants of `FolderSettingsWording`'s sibling `LibraryFolderSettingsWording` (a new enum in the same new file or `TextMouth/Models`), each documented:
   | | Feed | Folder |
   | --- | --- | --- |
   | button title | "Feed Settings" | "Folder Settings" |
   | accessibility label | "Feed settings for <feed title>" | "Folder settings for <folder name>" |
   | accessibility hint | "Opens the settings of this feed: where its downloads go, what it lists and downloads, and what happens when an episode ends" | "Opens the settings of this folder: what it holds, and what happens when one of its books ends" |
   | system image | `slider.horizontal.3` | `slider.horizontal.3` |
   Also `LibraryFolderSettingsWording.nothingToOpen` = "Open a folder first to see its settings", said when the shortcut is pressed where no folder is shown.
2. **The toolbar button** in `LibraryView.swift`, after New Folder (`:549`), inside the same `ToolbarItemGroup`: shown only when the target is non-nil; `Label(target.buttonTitle, systemImage:)`, `.accessibilityLabel`, `.accessibilityHint`. Pressing it calls one function, `openFolderSettings(target)`: `.feed` calls `showFeedInfo(feedID)`; `.folder` makes a `FolderSettingsModel(folderID:library:feedFolders:wordsPerMinute:)` (`wordsPerMinute: settingsViewModel.wordsPerMinute`) and presents `FolderSettingsSheet(model:onDone:)` through the new modifier's `.sheet(item:)`.
3. **The shortcut action** `ShortcutAction.folderOrFeedSettings = "Folder or Feed Settings"`: no default key (`[]`, with a comment as `.addToReadingList` has), category "Library", notification `.showFolderOrFeedSettings` (declare it where the other names are, `MenuCommands.swift:~823`), a Library-menu item (`Button(ShortcutAction.folderOrFeedSettings.title)` in `LibraryCommands`, next to the reading-list items) that posts it. The window that takes the command (`takesCommand(notification)`, as the other handlers do) calls `openFolderSettings` for its current target, or, with none, announces `LibraryFolderSettingsWording.nothingToOpen` (`announceToVoiceOver`). Add the doc comment the neighbouring cases have.
4. Nothing else changes: not Command-I, not the Sort or New Folder buttons, not the Feed Info or Folder Settings sheets (read-only for you).

## Existing tests that change on purpose

The shortcut tests that list **every** action and fail **only** because of the one action you add (a count, a snapshot of config.json's action names, a listing of the Library category): extend each by exactly that one entry and list each, with its reason, in your report. Any other failure: stop and ask.

## Tests

- New `TextMouthProductionTests/LibraryFolderSettingsTargetTests.swift` (needs `xcodegen generate`, `project.pbxproj` committed with it): the target for the top level (nil), for a category other than Folders (nil), an unknown path (nil), a plain folder, a nested plain folder, a feed's folder (with the feed's title), a feed's folder whose record is gone; every wording string pinned.
- The toolbar as drawn: host the Library window's view in a window and read its toolbar's items as `BookExportSheetTests.swift:298-330` reads a reader's: no such item at the top level; "Folder Settings" in a plain folder; "Feed Settings" in a feed's folder; none in any category but Folders (All Items, Unopened, Recently Opened, Reading List). If the toolbar cannot be read for the Library view, test the same through the modifier and the target and say so in your report.
- Opening: pressing "Feed Settings" sets `LibraryFeedsPresenter.feedInfo` to a model for that feed (the same model Command-I's path makes); pressing "Folder Settings" presents `FolderSettingsSheet` for that folder (a hosted test, or by the modifier's state); the notification `.showFolderOrFeedSettings` does the same from the window that takes it, and a window that does not take it does nothing; with no folder shown it announces `nothingToOpen`.
- The shortcut: the action's title, category, empty default binding, notification, Library-menu item present, and that the Shortcuts tab lists it (`ShortcutListingTests`, `ShortcutsSettingsTabTests` show how).

## Tests to run

`LibraryFolderSettingsTargetTests`, `FolderSettingsSheetTests`, `FeedListeningOptionsSheetTests`, `ShortcutListingTests`, `ShortcutMigrationTests`, `ShortcutConfigFileTests`, `ShortcutsSettingsTabTests`, `MenuKeyShortcutTests`, `ShortcutPressDispatcherTests`, `ConfigSyncTests`, `SpeakInfoShortcutTests`, `FullSummaryActionTests`, `LibraryInfoSpeakerTests`, `ViewsAndWindowsLibraryListTests`, `WindowFocusPolicyTests`.

## Commits

1. The target and its wording, with tests.
2. The shortcut action through its places, with the listing tests' one-entry changes.
3. The toolbar button, the modifier with its sheet and handler, and their tests.

## Do not touch

The Sort menu, the Import, New from Text, and Add Feed toolbar buttons (task H replaces them), `FeedInfoSheet.swift`, `FolderSettingsSheet.swift`, `LibraryInfoRow.swift`.

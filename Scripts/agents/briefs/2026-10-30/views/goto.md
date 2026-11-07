# Task `goto`: Command-1 to Command-9 and Library > Go to View (team `views`, October 30, 2026)

Slug `views-goto`, branch `views/goto` from `team/views`. Read `Scripts/agents/briefs/2026-10-30/teams-common.md` ("The worker's part", "Rules for everyone", "The board", "Builds", and "Lessons every brief applies": this task adds shortcut actions), then this brief. The design is `LIBRARY-VIEWS-RESEARCH-2026-10-30.md` at the worktree's root: read section 6 ("Keys") and section 9 ("The Library window"). On the team branch: the views model and store, `LibraryViewModel+Views.swift` (`offeredViews(in:current:center:)`, `shownView`), and the window (`LibraryView.swift`, `ContentView.swift`) reading views.

## What you build

Nine shortcut actions, Go to View 1 to Go to View 9, with Command-1 to Command-9 by default, which no default uses now (`KeyboardShortcut.swift:1501-1700` binds no digit); a Go to View submenu in the Library menu listing the views offered, each of the first nine showing its key; and the Library window's handling, which shows the view and announces it. One or two commits.

## 1. The actions (`TextMouth/Models/KeyboardShortcut.swift`)

- Nine cases after `folderOrFeedSettings` (line 107): `goToView1 = "Go to View 1"` … `goToView9 = "Go to View 9"`, each documented once in a block comment (design section 6). A `static let goToViewActions: [ShortcutAction]` in order, and `var goToViewNumber: Int?` (1 to 9, nil for every other action).
- Category "Library" (line 352's case list); default scope Library windows, like `.importDAISYFolder` and `.addFeed` in `defaultScopesOfTheirOwn` (line 248-255) if menu commands need it there, as those two do: follow their pattern exactly.
- Notification: all nine post one name, `.goToLibraryView` (beside `.audioEditorShortcut`, line 531); `KeyboardShortcutManager` already puts the action's raw value in the user info under "action" (`KeyboardShortcutManager.swift:644`).
- Defaults: `KeyBinding(key: "1", command: true)` … `"9"` (line 1501-1700, after `.folderOrFeedSettings: []`). Check `KeyBinding` takes a digit key as written in config.json ("command+1"), and that `canBeKeyEquivalent` holds for it, so the menu shows the key.
- Every list of actions the code keeps by hand that a new action must join (`grep -n "folderOrFeedSettings" TextMouth -r`), and the migration rules for new defaults that collide with a user's own keys (`ShortcutMigrationTests` explains them): a user who gave Command-1 to another action keeps it, and Go to View 1 then has none.

## 2. The menu (`TextMouth/App/MenuCommands.swift`, `LibraryCommands`, line 302-480)

- A focused scene value, `libraryOfferedViewNames: [String]?` (pattern: `LibraryRemovalSelectionKey`, line 71-85), which `LibraryView` publishes: the names of the views its pop-up offers, without a view kept only because the window shows it (`offeredViews(in:current: nil, center:)`).
- A `Menu("Go to View")` after the Folder or Feed Settings item: one `Button` per name, its title the view's name, posting `.goToLibraryView` with the user info `["action": ShortcutAction.goToViewN.rawValue]`; the first nine carry `.menuCommandKey(.goToViewN, shortcuts: shortcuts, frontKind: front.kind)`. With no Library window in front, the submenu holds one dimmed item, "No Library Window".

## 3. The window (`LibraryView.swift`)

`.onReceive(NotificationCenter.default.publisher(for: .goToLibraryView))`, guarded by `takesCommand`: read the number from the user info's action; the views counted are those offered with no current view (as the menu lists them); when there is an Nth, set `shownViewID` to it and announce `LibraryViewPickerWording.wentToView(name:counts:)`, "All Items, 743 books, 2 feeds" (the name, then `CountWording.listItems(of: displayedBooks, feeds: feed rows' count)` of the new location); when there is none, announce `LibraryViewPickerWording.noView(number:offered:)`, "There is no view 7. The View pop-up offers 6 views." (`CountWording.phrase` for "1 view"). Add both to `LibraryViewPickerWording`, pinned by tests.

## Tests

- `KeyboardReachabilityTests`, `ShortcutMigrationTests`, `MenuKeyShortcutTests`, `ShortcutsSettingsTabTests`, `ShortcutConfigFileTests`, `OnDiskContractTests` (its list of `ShortcutAction` raw values gains the nine names, on purpose: say so in the commit message), `DoublePressBindingTests`, `LegacyKeyboardShortcutScenarioTests`, `LegacyMenuVisibilityScenarioTests`, and every class `grep -rln "ShortcutAction.allCases" TextMouthProductionTests` lists. An existing test that fails for any other reason: stop and ask your lead.
- New `TextMouthProductionTests/LibraryViewGoToTests.swift` (`@MainActor` per test): the nine actions, names, numbers, category, defaults, and notification; the wordings; the window's choice of the Nth offered view and its announcement, with a store of the test's own on sandboxed preferences and a model of its own (factor the choice into a function such as `LibraryViewModel.view(numbered:in:center:)` so it is tested without a window).

## Build and test

- `/opt/homebrew/bin/xcodegen generate` for the new test file; commit `project.pbxproj` with it. Add the class to the `[shortcuts]` area of `Scripts/test/areas.conf`, on its own line, moving no other line.
- `make lint-a11y LINT_BASE=team/views` and `make lint-tests LINT_BASE=team/views`; no new Swift warning.
- `BBS_AGENT=views-goto python3 Scripts/test/run-area.py shortcuts LibraryViewGoToTests OnDiskContractTests LibraryViewPickerTests`, in the background, checking no more than every four minutes.
- When done: `BBS_AGENT=views-goto python3 Scripts/test/run-area.py --clean`.

## Do not touch

The settings, the model, the store; anything else; no `*.md` file.

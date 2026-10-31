# Task `settings`: the Library tab of Settings (team `views`, October 30, 2026)

Slug `views-settings`, branch `views/settings` from `team/views`. Read `Scripts/agents/briefs/2026-10-30/teams-common.md` ("The worker's part", "Rules for everyone", "The board", "Builds"), then this brief. The design is `LIBRARY-VIEWS-RESEARCH-2026-10-30.md` at the worktree's root: read sections 5, 7 ("Where", "The list", "The controls for the selected view"), and 9 ("The Library tab"). On the team branch: `LibraryViewDefinition.swift`, `LibraryViewDefinitionList.swift`, `LibraryViewDefinitionStore.swift` (read the list and the store whole).

## What you build

A new Settings tab, Library, listing the views in order, with their visibility, Move Up and Move Down, Duplicate, Delete…, and Restore Default…. New View… and Edit… come in the next task (the editor): leave room for them in the button row, add neither. Two commits: (1) the tab, the list, visibility, and moving; (2) Duplicate, Delete…, and Restore Default…, with the sort kept in library.json.

## 1. The tab (`TextMouth/Views/Settings/SettingsView.swift`)

- `SettingsTab`: `case library` between `stats` and `feeds`, with a doc comment; title "Library" (from the wording enum), symbol `books.vertical`; `SettingsTabContent` shows `LibraryViewsSettingsView()`.
- `scrollsAsAWhole` is false for `.library` too, as for Text: its list fills the room its other controls leave, and a list inside a scrolling form collapses. Update the property's doc comment.
- `SettingsView.windowSize` grows from 780 to 860 points wide, so the eleven tabs fit the toolbar (the comment says each tab added has needed about 80).
- `SettingsTabFitTests` changes on purpose, as it did for Braille (commit 03c9d9bf): `testTheWindowOffersItsTenTabsInTheirOrder` becomes "…ElevenTabs…" with "Library" after "Stats", and its non-scrolling tabs are `[.text, .library]`; add a test like `testTheTextTabLeavesItsRuleListRoom` for the Library tab's list. Say so in the commit message. No other assertion changes.

## 2. Wording: new `TextMouth/Models/LibraryViewsSettingsWording.swift`

Every sentence of design section 9, "The Library tab", as `static let`s and `static func`s with doc comments, each pinned by a test exactly: the tab title, the section header "Views", the two captions, the list's label "Views", `rowLabel(name:isBuiltIn:visibility:number:count:)` ("Reading List, built in, always, 5 of 6"; "custom"; "when applicable"; "hidden"), the visibility items "Always", "When Applicable", "Hidden" and the row's words "always", "when applicable", "hidden" (one function from `LibraryViewVisibility` each), the row hints for Folders and the Reading List, the action names, the Visibility pop-up's label "Visibility of <name>", its hint, and Folders' dimmed hint, the move buttons' spoken labels and hints, the place announcement "<name>, <n> of <count>", Duplicate's hint and announcement, Delete's hint, its built-in hint, its alert's title, message, and buttons, and its announcement, Restore Default's hint, its dimmed hint, its alert, and its announcement, and the unreadable-entries caption (singular and plural). A filter view's row hint (its description) comes with the editor task; until then a filter view's row has no hint.

## 3. The view: new `TextMouth/Views/Settings/LibraryViewsSettingsView.swift`

Pattern: `SubstitutionsSettingsView` (the Text tab, `TextMouth/Views/Settings/SubstitutionsSettingsView.swift`, read its body and how its list and buttons are laid out and labeled). `@EnvironmentObject var libraryViewModel: LibraryViewModel`; `@ObservedObject var store: LibraryViewDefinitionStore = .shared`; `@State private var selection: LibraryViewID?`, set to the first view when the tab appears and to a neighbour when the selected view is deleted.

- Header and the two captions, then the list: `List(selection: $selection)`, one row per readable view (`store.list.views`), each `.tag(view.id)`, drawn as the name with the kind and visibility beside it in secondary text, and read as one element: `.accessibilityElement(children: .ignore)`, `.accessibilityLabel(rowLabel…)`, the hint for Folders and the Reading List. `.accessibilityLabel` of the list: "Views". The list fills the room left (`frame(maxHeight: .infinity)`).
- Each row's VoiceOver actions, only those that apply (`.accessibilityActions { … }`, as `LibraryView.swift:1196` and `LibrarySubviews.swift:542` do): Move Up, Move Down, Show Always, Show When Applicable, Hide (all but the current visibility; none for Folders), Duplicate (filter views), Delete… (custom), Restore Default… (when it applies). The same commands in the list's context menu (`.contextMenu(forSelectionType:)`).
- Under the list, for the selected view: the Visibility pop-up (`Picker` with the three items; visible label "Visibility", `.accessibilityLabel` "Visibility of <name>", hint; disabled for Folders with Folders' hint), Move Up and Move Down buttons (visible "Move Up"/"Move Down"; spoken "Move <name> Up"/"Down"; disabled at the end they cannot pass), then Duplicate, Delete…, Restore Default… (each disabled where it does not apply, with its dimmed hint as `.help` and `.accessibilityHint`).
- The unreadable caption when `store.list.unreadableCount > 0`.
- Every change goes through `store.update { … }`; after a move, VoiceOver hears the place announcement (`VoiceOverAnnouncer.announce`); after a visibility change nothing more (the pop-up says it).

## 4. The second commit: Duplicate, Delete…, Restore Default…

- `TextMouth/ViewModels/LibraryViewModel+SortAndOrder.swift`, after `setFolderSortSetting` (line 233-237): `func removeSortSetting(for key: String)` removing the setting saved under `key`, saving only when one was there.
- **Duplicate** (filter views): a custom view `LibraryViewDefinition(id: .custom(UUID()), name: store.list.copyName(for: view.name), visibility: .always, filter: view.filter)`, added after the original; the original's sort as shown (`libraryViewModel.sortState(at: LibraryLocation(view: original, folderPath: "")).setting`) saved under the copy's `sortSettingsKey` with `setFolderSortSetting`; the copy selected; Duplicate's announcement with its place.
- **Delete…** (custom views): the alert (title, message, Delete destructive, Cancel); on Delete, `store.update { $0.delete(id) }`, then `removeSortSetting(for:)` the view's key, the selection to the next view (or the one before), the announcement after the alert closes (`VoiceOverAnnouncer.announceAfterSheetCloses` or as the codebase announces after an alert).
- **Restore Default…** (built-in filter views, enabled while `view.differsFromShipped` or a sort is saved under its key): the alert; on Restore Default, `store.update { $0.restoreDefault(id) }` and `removeSortSetting(for:)` its key; the announcement.

## Tests

- `SettingsTabFitTests` (changed as above), `SettingsViewTests` or whichever classes host the Settings window (`grep -rln "SettingsTab\b\|SettingsView(" TextMouthProductionTests`), `KeyboardReachabilityTests`.
- New `TextMouthProductionTests/LibraryViewsSettingsTests.swift` (`@MainActor` per test; a `LibraryViewDefinitionStore` on a sandboxed preferences store of its own, and a model of its own, never `.shared`'s preferences): every wording exactly; the row labels for the shipped list; the actions each row offers (factor what decides them into a testable function, such as `LibraryViewsSettingsCommands.available(for:in:sortIsSaved:)`, used by the row, the context menu, and the buttons alike, so the three never disagree); moving and its announcement; Folders' visibility refused; Duplicate's name, place, filter, and copied sort; Delete removing the view and its sort key; Restore Default restoring the view and removing its sort key; the tab hosted at the window's size (as `SettingsTabFitTests` hosts tabs) with every control reachable.

## Build and test

- `/opt/homebrew/bin/xcodegen generate` for the new files; commit `project.pbxproj` with them. Add `LibraryViewsSettingsTests` to the `[settings]` area of `Scripts/test/areas.conf`, on its own line, moving no other line.
- `make lint-a11y LINT_BASE=team/views` and `make lint-tests LINT_BASE=team/views` must pass; no new Swift warning.
- `BBS_AGENT=views-settings python3 Scripts/test/run-area.py settings LibraryViewsSettingsTests LibrarySortSavingTests KeyboardReachabilityTests`, in the background, checking no more than every four minutes.
- When done: `BBS_AGENT=views-settings python3 Scripts/test/run-area.py --clean`.

## Do not touch

The Library window's files, the model, the store; anything else; no `*.md` file.

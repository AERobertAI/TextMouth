# Task `editor`: making and changing a view (team `views`, October 30, 2026)

Slug `views-editor`, branch `views/editor` from `team/views`. Read `Scripts/agents/briefs/2026-10-30/teams-common.md` ("The worker's part", "Rules for everyone", "The board", "Builds"), then this brief. The design is `LIBRARY-VIEWS-RESEARCH-2026-10-30.md` at the worktree's root: read sections 4, 7 ("The editor sheet"), and 9 ("The editor"). On the team branch: the model (`LibraryViewDefinition.swift`, `LibraryViewDefinitionList.swift`), the evaluator, the store, `LibraryLocation(view:folderPath:)`, `LibraryViewModel.books(listedAt:context:)` and `filterContext(for:)`, `LibraryViewPickerWording`, and the Library tab (`LibraryViewsSettingsView.swift`, `LibraryViewsSettingsWording.swift`); read the tab's view and wording whole.

## What you build

The editor sheet, and New View… and Edit… in the Library tab. Two commits: (1) the wording and the editor's model, pure and fully tested; (2) the sheet, its place in the tab, and saving.

## 1. Wording: new `TextMouth/Models/LibraryViewEditorWording.swift`

Every sentence of design section 9, "The editor", as `static let`s and `static func`s with doc comments, each pinned by a test exactly. Names: `newTitle` "New View"; `editTitle(_:)` "Edit <name>"; `nameLabel` "Name"; `listsLabel` "Lists"; `kindName(_ kind: LibraryViewItemKind)` "Books", "Episodes", "Articles", "Feeds"; `listsCaption`; `matchLabel` "Match"; `matchName(_:)` "All Conditions", "Any Condition"; `conditionsHeader` "Conditions"; `noConditions`; `testName(_ kind: LibraryViewCondition.Kind)` ("Format", "Folder", "Reading State", "Reading List", "Date Added", "Date Opened", "Title or Author", "New Items", "Subscription"); `relationName(_ kind:, isNegated:)` (the design's pairs); `stateName(_:)` ("Unopened", "In Progress", "Finished"); the spoken labels `conditionLabel(_ n:)` "Condition <n>", `relationLabel` "Condition <n> relation", `formatLabel` "Condition <n> format", `folderLabel` "Condition <n> folder", `subfoldersLabel` "Condition <n> includes subfolders" (visible `subfoldersTitle` "Including Subfolders"), `readingStateLabel` "Condition <n> reading state", `daysLabel` "Condition <n> days" (visible caption `daysCaption` "days"), `textLabel` "Condition <n> text"; `removeTitle` "Remove", `removeLabel(_:)` "Remove condition <n>"; `addCondition` "Add Condition", `conditionLimitHint`; `onePerFeedTitle`, `onePerFeedHint`; `sortByLabel` "Sort By"; `orderLabel` "Order"; `orderName(ascending:)` "Ascending", "Descending"; `limitTitle` "Show at Most"; `limitFieldLabel` "Most rows shown"; `chosenByLabel` "Chosen By"; `limitOrderName(_:)` "Opened Last", "Added Last", "First in the Sort"; `cancel` "Cancel"; `save` "Save"; the five errors; `saved(_:)` "Saved <name>."; `added(_:number:count:)` "Added <name>, <n> of <count>."; `newViewTitle` "New View…" and `newViewHint`; `editTitle` for the button "Edit…", `editHint`, `editDisabledHint` (design section 9, "The Library tab").

Two composed sentences:
- `count(of rows: [Book], feeds: Int) -> String`: "Lists " + the nonzero counts (books by `CountWording.books`, episodes and articles by `CountWording.phrase`, feeds by `CountWording.feeds`, rows told apart by `Book.listedKind`) joined by `CountWording.list` + "."; "Lists nothing now." when all are zero.
- `description(of filter: LibraryViewFilter, folderName: (UUID?) -> String) -> String`: "Lists " + the kinds in `LibraryViewItemKind.allCases` order, lowercased, joined by `CountWording.list`; then, with conditions, ": " and the conditions' phrases joined as `CountWording.list` joins (with "and" for All, and with "or" for Any: write the "or" joiner beside it, same commas); then "; only the latest from each feed" when on, "; at most <n>, <order lowercased>" with a limit ("at most 10, opened last"); then ".". Phrases: "format is EPUB" / "format is not EPUB" (`displayName`); "folder is <name>" (+ ", including subfolders") / "folder is not <name>"; "reading state is Finished" / "reading state is not Finished"; "in the reading list" / "not in the reading list"; "added today" (1 day) or "added within the last <n> days", negated with "not " before; the same with "opened"; "title or author contains “<text>”" / "title or author does not contain “<text>”"; "has new episodes or articles" / "has none new"; "subscribed" / "unsubscribed". `folderName(nil)` is "Library Root" (`LibraryFolderOption.rootLabel`), a folder's path otherwise, or "a folder no longer in the library".

Also: give `LibrarySortState` (`TextMouth/Models/LibrarySortState.swift`, the direction hint at about line 260) a `static let manualOrderHasNoDirection = "Manual order has no direction"`, which `directionCommandHint` uses, so the editor's Order hint reuses it.

## 2. The model: new `TextMouth/ViewModels/LibraryViewEditorModel.swift`

```swift
/// One condition as the editor shows it: its kind of test, whether negated, and a value for every
/// kind, so switching the test pop-up away and back keeps what was chosen or typed.
struct LibraryViewConditionDraft: Identifiable, Equatable {
    let id: UUID
    var kind: LibraryViewCondition.Kind
    var isNegated: Bool
    var format: BookFormat            // default .epub
    var folderID: UUID?               // nil: Library Root (default)
    var includingSubfolders: Bool     // default true
    var readingState: LibraryReadingState   // default .unopened
    var days: Int                     // default 7
    var text: String                  // default ""
    init(_ condition: LibraryViewCondition)       // its kind and value, defaults for the rest
    static func newCondition() -> LibraryViewConditionDraft   // Format is EPUB
    var condition: LibraryViewCondition           // days clamped to the range, text trimmed and cut to the limit
}

/// What the editor sheet edits: a view's name, what it lists, its conditions, its sort, and its limit.
@MainActor
final class LibraryViewEditorModel: ObservableObject, Identifiable {
    let id: UUID                      // also the new view's identity, when there is no original
    let original: LibraryViewDefinition?
    @Published var name: String
    @Published var lists: Set<LibraryViewItemKind>
    @Published var match: LibraryViewMatch
    @Published var conditions: [LibraryViewConditionDraft]
    @Published var onePerFeed: Bool
    @Published var limitIsOn: Bool
    @Published var limitCount: Int            // default 10, kept in LibraryViewLimit.countRange
    @Published var limitChosenBy: LibraryViewLimit.Order   // default .viewSort
    @Published var sortField: LibrarySortField
    @Published var sortAscending: Bool
    @Published var problem: String?           // what the last Save found
    init()                                    // a new view: Books, All, no conditions, Title Ascending, no limit
    init(editing view: LibraryViewDefinition, sort: FolderSortSetting)   // a filter view, with the sort shown
    var title: String
    var canAddCondition: Bool                 // fewer than LibraryViewFilter.conditionLimit
    func addCondition()
    func removeCondition(_ id: UUID)
    var filter: LibraryViewFilter             // the draft's
    func definition() -> LibraryViewDefinition   // the original with this name and filter (identity, visibility, extra fields kept), or a custom view .custom(id), Always offered
    func sortSetting(from shown: FolderSortSetting) -> FolderSortSetting   // shown with this field and direction, normalized
    func firstProblem(in list: LibraryViewDefinitionList) -> String?       // in the order the sheet shows the controls
}
```

Problems, in order: the trimmed name empty; longer than `LibraryViewDefinition.nameLimit`; taken (`list.isNameTaken(name, except: original?.id)`, the sentence naming the trimmed name); no kind listed; then each "Title or Author" condition, by number from 1, whose trimmed text is empty.

## 3. The sheet: new `TextMouth/Views/Settings/LibraryViewEditorSheet.swift`

A sheet over Settings, `frame(width: 620, height: 520)`: the title as a header (`.accessibilityAddTraits(.isHeader)`); a `ScrollView` holding a `Form` (`.formStyle(.grouped)`, checkboxes `.toggleStyle(.checkbox)`) with, in order: Name; Lists (four checkboxes, under the caption); Match; Conditions (each row: the test pop-up, the relation pop-up with the test's pair, the value control the test needs: a format pop-up of `BookFormat.allCases` by `displayName`, a folder pop-up of "Library Root" and every folder in tree order by path (`library.folders.sortedTreeOrder()`) tagged by ID, with "Including Subfolders", a reading state pop-up, a number field with a stepper and the caption "days", or a text field; and Remove), Add Condition; Only the Latest from Each Feed (enabled while Episodes or Articles is checked); Sort By and Order (disabled in Manual Order with the manual hint; replaced by the Feeds note when only Feeds is checked); Show at Most with its field and stepper and Chosen By (enabled while on); the count. Then, outside the scroll view, the problem (red, and announced when Save finds it) and the buttons Cancel (`.keyboardShortcut(.cancelAction)`) and Save (`.keyboardShortcut(.defaultAction)`). Every control has its spoken label and hint from the wording; every pop-up a bounded width (`frame(maxWidth: 220)`); nothing makes the content wider than the sheet.

The count is given to the sheet as a closure, `count: (LibraryViewDefinition) -> String`, and recomputed as the draft changes: `LibraryViewEditorWording.count(of: libraryViewModel.books(listedAt: location, context: libraryViewModel.filterContext(for: location)), feeds: LibraryFeedsSectionRows.feeds(at: location, center: LibraryFeedFolders.shared.center).count)` with `location = LibraryLocation(view: draft, folderPath: "")`, never through the list cache, so editing never evicts a window's lists.

## 4. In the Library tab (`LibraryViewsSettingsView.swift`)

- New View… (always) and Edit… (filter views; dimmed with `editDisabledHint` otherwise), first in the button row, before Duplicate; Edit… in each filter view's VoiceOver actions and context menu; the list's primary action (Return, double-click) is Edit… where it applies (`contextMenu(forSelectionType:menu:primaryAction:)`).
- A filter view's row hint becomes `LibraryViewEditorWording.description(of:folderName:)`.
- Saving: when `firstProblem(in: store.list)` finds one, set `problem` and announce it, keeping the sheet open. Otherwise add (at the end, for a new view) or replace the view through the store; save the sort under the view's key with `setFolderSortSetting` when it differs from the sort shown (`libraryViewModel.sortState(at: LibraryLocation(view:folderPath: ""))`); close the sheet; select the view; and announce `added` (with its place) or `saved` once the sheet has closed (`VoiceOverAnnouncer.announceAfterSheetCloses`).

## Tests

- New `TextMouthProductionTests/LibraryViewEditorModelTests.swift` (commit 1): every wording exactly, `count` and `description` included (the shipped views' descriptions, a custom view's with each condition, Any's "or"); drafts round-trip every condition; switching a draft's kind keeps the other kinds' values; `definition()` for new and edited views (a built-in keeps its identity and visibility); `sortSetting(from:)` keeps remembered directions; every problem in its order; the condition limit.
- New `TextMouthProductionTests/LibraryViewEditorSheetTests.swift` (commit 2, `@MainActor` per test): the sheet hosted at 620 by 520 with 20 conditions, a folder with a 200-character path, and a 60-character name is no wider than the sheet and every control can be reached (as `SettingsTabFitTests.testEveryControlOfEveryTabCanBeReached` measures); New View… and Edit… save through a store of the test's own (sandboxed preferences) and a model of its own, the sort saved under the view's key, the problems refusing Save.
- `SettingsTabFitTests`, `LibraryViewsSettingsTests`, `KeyboardReachabilityTests`, `LibrarySortStateTests`.

## Build and test

- `/opt/homebrew/bin/xcodegen generate` for the new files; commit `project.pbxproj` with them. Add both classes to the `[settings]` area of `Scripts/test/areas.conf`, each on its own line, moving no other line.
- `make lint-a11y LINT_BASE=team/views` and `make lint-tests LINT_BASE=team/views` must pass; no new Swift warning.
- `BBS_AGENT=views-editor python3 Scripts/test/run-area.py settings LibraryViewEditorModelTests LibraryViewEditorSheetTests LibraryViewsSettingsTests LibrarySortStateTests KeyboardReachabilityTests`, in the background, checking no more than every four minutes.
- When done: `BBS_AGENT=views-editor python3 Scripts/test/run-area.py --clean`.

## Do not touch

The Library window's files, the model, the store, the evaluator; anything else; no `*.md` file.

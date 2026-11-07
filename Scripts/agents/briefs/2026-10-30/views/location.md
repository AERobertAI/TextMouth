# Task `location`: a place in the library becomes a view and a folder (team `views`, October 30, 2026)

Slug `views-location`, branch `views/location` from `team/views`. Read `Scripts/agents/briefs/2026-10-30/teams-common.md` ("The worker's part", "Rules for everyone", "The board", "Builds"), then this brief. The design is `LIBRARY-VIEWS-RESEARCH-2026-10-30.md` at the worktree's root: read sections 1, 2 ("A place in the library"), and 8 ("Sorts"). On the team branch already: `TextMouth/Models/LibraryViewDefinition.swift`, `LibraryViewDefinitionList.swift`, and `LibraryViewFilterEvaluator.swift` (read the evaluator and the definition whole).

## What you build

`LibraryLocation` holds a view (`LibraryViewDefinition`) instead of a category, and every list a location lists comes through the view: Folders and the Reading List as now, filter views through the evaluator. For the five categories' shipped views, every list, sort, key, and title stays exactly what it is: every existing test passes unchanged. Nothing new is shown yet (the window still makes its locations from its category). One or two commits.

## 1. `LibraryLocation` (`TextMouth/Models/LibrarySortState.swift:3-95`)

```swift
struct LibraryLocation: Equatable {
    var view: LibraryViewDefinition          // the view shown
    var folderPath: String                   // as now
    init(view: LibraryViewDefinition, folderPath: String)
    init(category: LibraryCategory, folderPath: String)   // the category's shipped view (LibraryViewDefinition.shipped(_:))
    var category: LibraryCategory            // view.id.category ?? .allItems (doc: below)
    var sortSettingsKey: String              // view.sortSettingsKey ?? folderPath
    var defaultSortSetting: FolderSortSetting // view.defaultSortSetting
    var name: String                         // Folders: as now; otherwise view.name
    var keepsItsOwnOrder: Bool               // view.kind == .readingList
    var listsOnlyFeeds: Bool                 // view.filter?.listsOnlyFeeds ?? false (new)
    var manualOrderFolder: String?           // view.kind == .folders ? folderPath : nil
    func reorderableFolder(sortedBy:) / reorderTarget(sortedBy:)   // unchanged
    func windowTitle(sortedBy sort: LibrarySortState) -> String
        // keepsItsOwnOrder || listsOnlyFeeds ? "Library: \(name)" : "Library: \(name) (\(sort.titleFragment))"
}
```

`category`'s doc comment says: the category whose rules the location follows, its view's own for the five categories' views, and All Items' for the Feeds view and every view the listener makes, which, like All Items, list rows from every folder in an order no one arranges; it serves the callers that take a category (`ReadingListOpenRequests`, `LibraryFolderSettingsTarget`, `LibraryFeedFolders.folderRows`) and tests; new code asks `view.kind` and `view.id`. Update the type's and members' doc comments to speak of views. `Library.sortState(at:)` and `sortSetting(at:)` (lines 296-328) need no change: check that they still read right (the No Folder carry-over applies only to Unopened's view, by `category`).

## 2. The cache key (`TextMouth/ViewModels/LibraryListCache.swift`)

- `Key` (lines 38-69): replace `category` with `view: LibraryViewID`, and add `filter: LibraryViewFilter?` (so a changed filter derives again) and `context: LibraryViewFilterContext?`; `init(location:sort:search:feedID:context:)`, `context` defaulting to nil; `folderPath` and `feedID` only for Folders (`location.view.kind == .folders`), as now.
- `hasSameListFields` (lines 289-297): add `format == other.format` (a format condition reads it, and so does telling episodes from articles), with its doc comment updated.

## 3. The lists (`TextMouth/ViewModels/LibraryViewModel+FolderManagement.swift:380-464`)

- `displayedBooks(at:matching:)`: as now, with `let context = filterContext(for: location)` passed into both keys, and the derive closure calling `books(listedAt: location, context: context)`.
- New `func books(listedAt location: LibraryLocation, context: LibraryViewFilterContext?) -> [Book]`: by `location.view.kind`: `.folders` as `booksForCategory(.folders, …)` does now; `.readingList` the reading list's books; `.filter`, `LibraryViewFilterEvaluator.items(of: filter, in: library.books, context: context ?? LibraryViewFilterContext(), sorted: { sortedBooks($0, by: sortState(at: location)) })` (no filter: none). Its doc comment carries what `booksForCategory`'s says of feed items, and says the shipped presets list exactly what the categories listed (design section 3).
- `booksForCategory(_:folderPath:)` keeps its signature (tests call it): `books(listedAt: LibraryLocation(category: category, folderPath: folderPath), context: filterContext(for: that location))`. Its doc comment says it is the categories' shipped views' list.
- New `func filterContext(for location: LibraryLocation) -> LibraryViewFilterContext?`: nil without a filter; otherwise `LibraryViewFilterContext(for: filter, now: Date(), calendar: .current, finishedIDs: finishedBookIDs, readingListIDs: { Set(self.library.readingList.bookIDs) }, folderPath: { id in self.library.folders.first { $0.id == id }?.fullPath }, feedFolderPaths: feedFolderPathsByFeedID)`.
- New, in `TextMouth/ViewModels/LibraryViewModel+Feeds.swift` after `feedFolderPath(forFolderID:)` (line 48-50): `func feedFolderPathsByFeedID() -> [UUID: String]`: each feed of `feeds.feeds` whose folder is in the library, by feed ID, keeping the first of any duplicate.

## 4. The feeds (`TextMouth/Views/Feeds/FeedLibraryPresentation.swift:160-195`)

`LibraryFeedsSectionRows.feeds(at:center:)` switches on `location.view.kind`: `.folders` as now; `.readingList` none; `.filter`, none unless the filter lists feeds, else `LibraryViewFilterEvaluator.feeds(of: filter, in: center.feeds, context: LibraryViewFilterContext(for: filter, now: Date(), calendar: .current, finishedIDs: { [] }, readingListIDs: { [] }, folderPath: { center.library?.feedFolderPath(forFolderID: $0) }, feedFolderPaths: { [:] }), newItemCount: { center.counts(of: $0).new }, folderPath: { center.folderPath(of: $0) })`. Update the enum's doc comment: what each view lists comes from its filter; the shipped views list what the categories did (quote them as now).

## 5. Folder operations keep the views' sort keys

No code change is expected: `Library`'s folder removal (`Library.swift:600-670`), relocation (`960-990`), and spelling repair (`860-895`) leave keys that are not valid library paths alone. Prove it in tests (below); if one does not, stop and ask your lead.

## Tests

Every existing test passes unchanged: `FolderSortSettingTests` (run as `LegacyFolderSortSettingScenarioTests`), `UnopenedCategoryTests`, `LegacyLibraryModelTests`, `LibrarySortStateTests`, `LibrarySortSavingTests`, `ReadingListViewTests`, `ReadingListReaderTests`, `LibraryFolderSettingsTargetTests`, `FeedUILibraryRowsTests`, `OnDiskContractTests`, `LibraryListCacheTests`, `ViewsAndWindowsLibraryListTests`, `ManualOrderRearrangingTests`, `LibraryInfoSpeakerTests`, `FolderDuplicateRepairTests`.

New `TextMouthProductionTests/LibraryViewLocationTests.swift` (`@MainActor` per test, as `UnopenedCategoryTests` explains; a model of its own: `LibraryViewModel(initializeServices: false)`, `finishedBookIDs` given):
1. The Feeds view's location: key "/views/Feeds", name "Feeds", title "Library: Feeds", no own order, no manual order folder, category All Items.
2. A custom view's location: title "Library: Mine (Title Ascending)" with no saved sort; a sort chosen through `userChangedSort(_:at:)` is saved under "/views/<id>" and shown; a location of another view is not affected.
3. `displayedBooks(at:)` for a custom view listing EPUBs alone, sorted by its sort; for Unopened's view with an edited filter; for a view with a limit; a second read derives nothing (`listCache.derivationCount`), and a location whose filter differs derives again.
4. `LibraryFeedsSectionRows.feeds(at:)` for the Feeds view, a custom view of feeds with new items, a custom view of books alone (no feeds), and each category as before (reuse the feed fixtures of `FeedUILibraryRowsTests` or `UnopenedCategoryTests`).
5. A `"/views/…"` sort key survives deleting a folder (moving its contents and deleting everything), renaming and moving a folder, and the duplicate-spelling repair.
6. A change of a book's format alone makes a list derive again.

## Build and test

- `/opt/homebrew/bin/xcodegen generate` for the new test file; commit `project.pbxproj` with it. Add the class to the `[library]` area of `Scripts/test/areas.conf`, on its own line after `LibraryViewFilterEvaluatorTests`, moving no other line.
- `BBS_AGENT=views-location python3 Scripts/test/run-area.py library LibraryViewLocationTests ReadingListReaderTests FeedUILibraryRowsTests LibraryInfoSpeakerTests LegacyFolderSortSettingScenarioTests reading-list`, in the background, checking no more than every four minutes. Load-sensitive tests are named in teams-common; rerun one alone before reporting it.
- `make lint-tests LINT_BASE=team/views`; no new Swift warning.
- Completion check: `grep -n "location.category\|\.category ==" TextMouth/ViewModels/LibraryListCache.swift TextMouth/ViewModels/LibraryViewModel+FolderManagement.swift TextMouth/Views/Feeds/FeedLibraryPresentation.swift` finds nothing.
- When done: `BBS_AGENT=views-location python3 Scripts/test/run-area.py --clean`.

## Do not touch

`LibraryView.swift`, `ContentView.swift`, the settings, anything else; no `*.md` file.

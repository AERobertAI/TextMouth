# Task `window`: the Library window shows views (team `views`, October 30, 2026)

Slug `views-window`, branch `views/window` from `team/views`. Read `Scripts/agents/briefs/2026-10-30/teams-common.md` ("The worker's part", "Rules for everyone", "The board", "Builds"), then this brief. The design is `LIBRARY-VIEWS-RESEARCH-2026-10-30.md` at the worktree's root: read sections 1 ("The window"), 5, 6 ("The picker"), and 9 ("The Library window"). On the team branch already: the model (`LibraryViewDefinition.swift`, `LibraryViewDefinitionList.swift`), the evaluator, the store (`LibraryViewDefinitionStore.swift`), and `LibraryLocation(view:folderPath:)` (`LibrarySortState.swift`); read the store and `LibraryLocation` whole.

## What you build

The window's state becomes a view's identity; the segmented picker becomes a pop-up of the views offered; every test of the category becomes a test of the view's kind; a deleted view falls back with an announcement; a view listing only feeds shows them alone. Two commits: (1) the state, the picker, and the kind tests, with no other change for the five categories' views; (2) the Feeds-only list, the empty sentence, the feeds sort item, and the fallback.

This deliberately changes what VoiceOver says of the picker: it is a pop-up button, and its spoken label is "Library view" (was "Library category"). Say so in the first commit's message; change the one assertion in `UnopenedCategoryTests.testThePickerSegmentReadsUnopened` (`XCTAssertEqual(LibraryView.categoryPickerLabel, "Library category")`) to "Library view", and its doc comment, and no other existing test.

## 1. Wording: new `TextMouth/Models/LibraryViewPickerWording.swift`

An enum of the window's new sentences, each a `static let` or `static func` with a doc comment, every one pinned by a test:
- `pickerWidthLimit: CGFloat = 320`: the pop-up's widest.
- `emptyView = "Nothing matches this view now."`
- `deletedView(nowShowing name: String) -> String`: "The view this window showed was deleted. It now shows \(name)."
- `feedsOrderName = "Title"`; `feedsSortMenuLabel = "Sort feeds by Title"`; `feedsOrderHint = "Feeds are always listed by title"`; `feedsOrderAnnouncement = "Feeds are listed by title"`.

`LibraryView.categoryPickerLabel` keeps its name (tests use it) and becomes "Library view", with its doc comment saying it names the View pop-up.

## 2. Which views a window offers: new `TextMouth/ViewModels/LibraryViewModel+Views.swift`

```swift
extension LibraryViewModel {
    /// Whether `view` lists something now (design section 5): Folders always; the Reading List
    /// while it holds a row (`readingListBooks`); a filter view while `displayedBooks(at:)` or its
    /// feed rows (`LibraryFeedsSectionRows.feeds(at:center:)`) are not empty, the books asked first.
    func listsSomething(_ view: LibraryViewDefinition, center: FeedCenter) -> Bool

    /// The views the View pop-up offers a window showing `current` (`offeredViews`), with
    /// applicability from `listsSomething(_:center:)`.
    func offeredViews(in list: LibraryViewDefinitionList, current: LibraryViewID?, center: FeedCenter) -> [LibraryViewDefinition]

    /// The view a window showing `id` shows: that view, or, when the list no longer has it, the
    /// first view offered, with `fellBack` true.
    func shownView(_ id: LibraryViewID?, in list: LibraryViewDefinitionList, center: FeedCenter) -> (view: LibraryViewDefinition, fellBack: Bool)
}
```
`listsSomething` makes the location with `folderPath: ""`.

## 3. `ContentView.swift` (the window's root, `LibraryWindowView`)

- Line 12: `@State private var viewID: LibraryViewID?` (nil until the window first appears), and `@ObservedObject private var views = LibraryViewDefinitionStore.shared`.
- The view shown: `libraryViewModel.shownView(viewID, in: views.list, center: LibraryFeedFolders.shared.center).view`.
- Pass `LibraryView` a binding `shownViewID:` whose getter is that view's ID and whose setter sets `viewID`.
- `.onAppear` (line 115-123): when `viewID` is nil, set it to the view shown, so the window keeps its view however the list changes (a new window opens at the first view offered).
- Lines 146 and 389: `addingToReadingList` is the view shown's kind being `.readingList`.
- Line 251: the title's location is `LibraryLocation(view: <view shown>, folderPath: currentFolderPath)`.

## 4. `LibraryView.swift`

- Line 204: `@Binding var shownViewID: LibraryViewID` in place of `category` (same place, so the memberwise initializer still begins `currentFolderPath:` then `shownViewID:`); after `feedFolders` (line 219), `@ObservedObject var views: LibraryViewDefinitionStore = .shared`.
- In an extension: `init(currentFolderPath: Binding<String>, category: Binding<LibraryCategory>, showFileImporter: Binding<Bool>, showTextInput: Binding<Bool>, onOpenBook: @escaping (Book) -> Void, feedFolders: LibraryFeedFolders = .shared)`, which shows the category's view: its binding's getter is `.category(category.wrappedValue)`, and its setter sets the category when given one. Its doc comment says the hosted tests show the five categories' views through it. (An initializer in an extension keeps the memberwise one.)
- `location` (line 1703): `LibraryLocation(view: shownView, folderPath: currentFolderPath)`, where `shownView` is `libraryViewModel.shownView(shownViewID, in: views.list, center: feedFolders.center).view`.
- The picker (lines 366-376): `Picker("View", selection: $shownViewID) { ForEach(offered) { Text($0.name).tag($0.id) } }`, `.pickerStyle(.menu)`, `.frame(maxWidth: LibraryViewPickerWording.pickerWidthLimit, alignment: .leading)`, leading-aligned in its row with the same padding, `.accessibilityLabel(Self.categoryPickerLabel)`; `offered` is `libraryViewModel.offeredViews(in: views.list, current: shownViewID, center: feedFolders.center)`, read once per body like the other lists (PERF28).
- Every `category == .folders` (lines 382, 452, 506, 530, 643, 920, 1301) becomes `location.view.kind == .folders`; every `category == .readingList` and `category != .readingList` (lines 774, 950, 1152, 1271, 1446, 1462) becomes `location.keepsItsOwnOrder` or its negation; keep each comment true.
- Line 498: `.onChange(of: shownViewID)` clears the selections.
- Line 1319 (`openFeed`): `shownViewID = .category(.folders)`.
- Line 1370: `shownIn: location.category`; line 1664: `category: location.category`.

## 5. The second commit

- **The fallback.** `.onChange(of: views.list)`: when the list no longer has `shownViewID` (`shownView(…).fellBack`), set `shownViewID` to the view shown and announce `LibraryViewPickerWording.deletedView(nowShowing:)` with its name, through `announceToVoiceOver`.
- **A view listing only feeds** (`location.listsOnlyFeeds`, and generally a filter view whose filter lists no items, `filter.listsItems == false`): the list has no Books section (`booksSection` is not drawn), so no "Books (0)" header.
- **The empty sentence.** In the Feeds view and custom views (`location.view.id.category == nil`), when nothing is listed (no books before a search and no feed rows): a row `Text(LibraryViewPickerWording.emptyView)`, styled and placed as the Reading List's empty sentence (line 1271-1274); in a view with a Books section, inside it, as the Reading List's is; in a Feeds-only view, in a section of its own. The five categories' views look as they do now.
- **The Sort menu** (lines 876-930): `location.listsOnlyFeeds` shows one item, `Toggle(LibraryViewPickerWording.feedsOrderName, isOn: …)` always on, with `feedsOrderHint` as its help and hint, choosing it announcing `feedsOrderAnnouncement`, as `readingListSortItem` does; the menu's label is `feedsSortMenuLabel`.

## Tests

Every existing test passes unchanged but the one assertion above: the hosted library tests (`grep -rln "LibraryView(" TextMouthProductionTests`), `UnopenedCategoryTests`, `ReadingListViewTests`, `ReadingListReaderTests`, `LibraryFolderSettingsTargetTests`, `FeedUILibraryRowsTests`, `AddToLibraryToolbarTests`, `ViewsAndWindowsClosedWindowTests`, `ViewsAndWindowsLibraryListTests`, `MoveFolderSheetPresentationTests`, `LibraryInfoSpeakerTests`, `KeyboardReachabilityTests`.

New `TextMouthProductionTests/LibraryViewPickerTests.swift` (`@MainActor` per test; a model of its own; a `LibraryViewDefinitionStore` on a sandboxed preferences store of its own, passed to `LibraryView(…, views:)`; never `.shared`'s preferences):
1. Every wording above, exactly.
2. `listsSomething`: the Reading List empty and not, a filter view with books, with feeds only, with nothing; Folders always.
3. `offeredViews` through the model: the shipped list offers the five views, and Feeds once a feed exists; a hidden view the window shows stays offered.
4. `shownView`: a deleted custom view falls back to the first view offered, `fellBack` true.
5. Hosted (as `ReadingListViewTests.hostLibraryWindow` hosts): the picker is a pop-up (find an `NSPopUpButton` in the hosted view) whose items are the offered views' names, and no `NSSegmentedControl` remains; with a custom view named with 60 characters, the hosted content is no wider than its window at 600 points (`fittingSize`); a Feeds-only view with no feeds shows the empty sentence and no "Books (0)" header (read the list's accessibility or the hosted text, as `FeedUILibraryRowsTests` does).

## Build and test

- `/opt/homebrew/bin/xcodegen generate` for the new files; commit `project.pbxproj` with them. Add `LibraryViewPickerTests` to the `[library]` area of `Scripts/test/areas.conf`, on its own line, moving no other line.
- `make lint-a11y LINT_BASE=team/views` and `make lint-tests LINT_BASE=team/views` must pass; no new Swift warning.
- `BBS_AGENT=views-window python3 Scripts/test/run-area.py library reading-list LibraryViewPickerTests FeedUILibraryRowsTests AddToLibraryToolbarTests ViewsAndWindowsClosedWindowTests MoveFolderSheetPresentationTests LibraryInfoSpeakerTests KeyboardReachabilityTests windows accessibility`, in the background, checking no more than every four minutes. A load-sensitive test (teams-common) that fails is rerun alone and reported with both results.
- Completion check: `grep -n "category ==\|category !=\|\$category\|var category" TextMouth/Views/Library/LibraryView.swift TextMouth/Views/ContentView.swift` finds nothing.
- When done: `BBS_AGENT=views-window python3 Scripts/test/run-area.py --clean`.

## Do not touch

The model, evaluator, store, location, and settings files; anything else; no `*.md` file.

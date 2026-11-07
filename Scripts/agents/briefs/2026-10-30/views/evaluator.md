# Task `evaluator`: what a Library view's filter lists (team `views`, October 30, 2026)

Slug `views-evaluator`, branch `views/evaluator` from `team/views`. Read `Scripts/agents/briefs/2026-10-30/teams-common.md` ("The worker's part", "Rules for everyone", "The board", "Builds"), then this brief. The design is `LIBRARY-VIEWS-RESEARCH-2026-10-30.md` at the worktree's root: read sections 3 and 4. The model is on the team branch already: `TextMouth/Models/LibraryViewDefinition.swift` (read it whole; the filter, condition, and limit types) and `TextMouth/Models/LibraryViewDefinitionList.swift` (skim).

## What you build

The pure evaluator of a filter, with no UI and no wiring: nothing in the app calls it yet, so behavior does not change. One commit, plus a second if `CountWording` needs one of its own.

Files:
- New `TextMouth/Models/LibraryViewFilterEvaluator.swift`: `LibraryViewFilterContext`, `LibraryViewFilterEvaluator`, and `extension Book { var listedKind: LibraryViewItemKind }`.
- `TextMouth/Models/LibraryBookSorter.swift:9-34`: `latestOpened(_:limit:onePerFeed:)`, which `recent(_:limit:)` then calls.
- `TextMouth/Models/CountWording.swift:160-185` (`ListCounts.init`): count by `row.listedKind`, so the rule telling books, episodes, and articles apart is in one place.
- New `TextMouthProductionTests/LibraryViewFilterEvaluatorTests.swift`.

Read first: `TextMouth/Models/LibraryBookSorter.swift:1-80`, `TextMouth/Models/CountWording.swift:95-186`, `TextMouth/Models/Library.swift:1020-1060` (`isPath`, `booksInFolder`, `unopenedBooks`), `TextMouth/Models/Book.swift:205-225` and `400-410` (`isUnopened`, `isFeedItem`), `TextMouth/Models/Feed.swift:14-40` and `80-135` (`title`, `author`, `folderID`, `isSubscribed`).

## 1. `Book.listedKind`

`!isFeedItem` is `.books`; a feed item whose `format.isAudio` is `.episodes`; any other feed item `.articles`. `CountWording.ListCounts` switches on it (`.feeds` never comes from a book: `break`). `CountWording`'s existing tests must pass unchanged.

## 2. `LibraryBookSorter.latestOpened`

```swift
/// The rows of `books` opened last first (by last opened, newest first; a row never opened sorts
/// as the distant past), with, when `onePerFeed`, only the first of each feed's items, and at most
/// `limit` (nil: all).
static func latestOpened(_ books: [Book], limit: Int?, onePerFeed: Bool) -> [Book]
```

Its body is `recent`'s loop, unchanged in what it does: the same `sorted` call with the same closure, the same skip of a feed already listed, the same stop at the limit. `recent` becomes `guard limit > 0 else { return [] }` then `latestOpened(books.filter { !$0.isUnopened }, limit: limit, onePerFeed: true)`. `LibraryBookSorterTests` must pass unchanged.

## 3. `LibraryViewFilterContext`

Everything a filter reads beyond the rows, gathered once per list, `Hashable` and `Sendable`, so it can be part of the list cache's key later (task `location`): only what the filter reads is gathered; the rest stays empty or nil, so an unrelated change never makes a new key.

```swift
struct LibraryViewFilterContext: Hashable, Sendable {
    /// For each day count of a "within the last N days" condition, the first instant inside it:
    /// the start of the day N − 1 days before today.
    var dayThresholds: [Int: Date] = [:]
    /// The rows Books Finished counts; nil unless a reading state of In Progress or Finished is tested.
    var finishedIDs: Set<UUID>? = nil
    /// The reading list's rows; nil unless "in the reading list" is tested.
    var readingListIDs: Set<UUID>? = nil
    /// The path of each folder a folder condition names, by folder ID; a folder no longer in the
    /// library is absent.
    var folderPaths: [UUID: String] = [:]
    /// Each feed's folder path, by feed ID; nil unless a folder condition is tested on episodes or articles.
    var feedFolderPaths: [UUID: String]? = nil

    /// What `filter` reads, gathered through the closures, each called only when the filter needs
    /// what it gives, and at most once.
    init(
        for filter: LibraryViewFilter,
        now: Date,
        calendar: Calendar,
        finishedIDs: () -> Set<UUID>,
        readingListIDs: () -> Set<UUID>,
        folderPath: (UUID) -> String?,
        feedFolderPaths: () -> [UUID: String]
    )
}
```

Rules: a day threshold is `calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now))` (skip a nil result). `finishedIDs` is gathered when a condition tests `.readingState(.inProgress)` or `.readingState(.finished)`; `readingListIDs` when one tests `.inReadingList`; `folderPaths` for each `.folder(id:)` with a non-nil ID; `feedFolderPaths` when a folder condition exists and the filter lists episodes or articles. Also give it a plain memberwise use: tests build contexts directly.

## 4. `LibraryViewFilterEvaluator`

```swift
enum LibraryViewFilterEvaluator {
    /// The books, episodes, and articles of `rows` that `filter` lists (design section 4): the rows
    /// of the kinds it lists that match its conditions; then, with `onePerFeed`, of each feed's items
    /// the one opened last; then at most its limit's count, chosen by the limit's order. A limit
    /// chosen by the view's sort keeps the first of `sorted(rows)`. The rows come in no order the
    /// caller may rely on; the caller sorts them by the view's sort. No rows when the filter lists
    /// none of these kinds.
    static func items(of filter: LibraryViewFilter, in rows: [Book], context: LibraryViewFilterContext, sorted: ([Book]) -> [Book]) -> [Book]

    /// The feeds of `feeds` that `filter` lists, in their order: none unless it lists feeds; those
    /// matching its conditions. `newItemCount` gives a feed's new episodes and articles
    /// (`FeedCenter.counts(of:).new`), and `folderPath` its folder's path, nil when the folder is gone.
    static func feeds(of filter: LibraryViewFilter, in feeds: [Feed], context: LibraryViewFilterContext, newItemCount: (UUID) -> Int, folderPath: (Feed) -> String?) -> [Feed]
}
```

Matching (design section 4), for one row of kind `k`: the conditions that test `k` (`LibraryViewCondition.tests(_:)`); none: the row is listed; `.all`: every one holds; `.any`: at least one holds. A condition holds when its test passes, or, negated, when it fails. Tests:

- `format(f)`: `book.format == f`.
- `folder(id, including)`: the row's path is `book.folderPath` for a book, `context.feedFolderPaths?[feedID]` for a feed item (missing: fails), the feed's `folderPath` for a feed (nil: fails). The target is `""` for a nil ID, else `context.folderPaths[id]` (missing: fails). With target `""`: `including` passes any row whose path is known, otherwise only a path of `""`. Otherwise: path equals target, or, `including`, begins with target + "/".
- `readingState`: `.unopened` is `book.lastOpened == nil`; `.finished` is `context.finishedIDs` holding the row's ID (nil set: fails); `.inProgress` is opened and not finished.
- `inReadingList`: `context.readingListIDs` holds the row's ID (nil set: fails).
- `addedWithin(days)`: `dateAdded >= context.dayThresholds[days]` (missing: fails). `openedWithin(days)`: `lastOpened` set and `>=` the threshold.
- `titleOrAuthorContains(text)`: lowercased, as `LibraryViewModel.displayedBooks(at:matching:)` matches its search: `title.lowercased().contains(q) || author.lowercased().contains(q)` with `q = text.lowercased()`; a feed's author is `feed.author ?? ""`.
- `hasNewItems`: `newItemCount(feed.id) > 0`. `subscribed`: `feed.isSubscribed`.

After matching, for items:
1. A limit chosen by `.lastOpened`: `LibraryBookSorter.latestOpened(matched, limit: count, onePerFeed: filter.onePerFeed)`, and done.
2. Otherwise, with `onePerFeed`: `latestOpened(matched, limit: nil, onePerFeed: true)`.
3. A limit chosen by `.dateAdded`: the first `count` of `LibraryBookSorter.sorted(rows, by: .dateAdded, ascending: false)` (the comparator every list uses, so ties fall the same way). By `.viewSort`: the first `count` of `sorted(rows)`.

So the shipped Recently Opened filter over `library.books` gives exactly `LibraryBookSorter.recent(library.books)`, in its order, by construction.

## Tests: `LibraryViewFilterEvaluatorTests` (no test may trap)

Build a library in the test: books in "", "Fiction", "Fiction/Short", "Essays" of several formats; opened and never opened, with two sharing a `lastOpened`; feed items of two feeds (audio episodes and HTML articles, `feedLink` set; see `UnopenedCategoryTests.book` and `FeedUILibraryRowsTests` for how tests make books and feed items); `Feed` values for those feeds and a third with no folder (see how `FeedUILibraryRowsTests` or `UnopenedCategoryTests` make feeds; build `Feed` values directly when the initializer allows). Use a fixed `now` and a Gregorian calendar in UTC.

1. **The presets give today's lists** (the heart of this task): over `library.books`, the shipped All Items filter's items equal `library.libraryBooks`, Unopened's `library.unopenedBooks()`, Recently Opened's `LibraryBookSorter.recent(library.books)`, each in order; Feeds' items are empty. Feeds: All Items and the Feeds view list every feed; Unopened those whose `newItemCount` is above 0; Recently Opened none.
2. Every test kind on every row kind it tests, passing, failing, and negated; a condition never hides a row it does not test; `.all` and `.any`; no conditions.
3. Folder conditions: Library Root with and without subfolders, a folder with and without subfolders, a folder ID not in `folderPaths`, an episode by its feed's folder, a feed with no folder.
4. Day thresholds across midnight: added at 23:59 yesterday is within 2 days, not within 1.
5. `onePerFeed`, and each limit order, including `.viewSort` with a given `sorted`, and a limit larger than the rows.
6. The context gathers only what the filter reads: count each closure's calls (0 or 1).
7. `latestOpened` and `recent` agree with a copy of the old `recent` algorithm written in the test, on rows with ties.
8. `Book.listedKind` for a book, an audio feed item, and an HTML feed item.

## Build and test

- `/opt/homebrew/bin/xcodegen generate` for the new test file; commit the regenerated `project.pbxproj` with it. Add the class to the `[library]` area of `Scripts/test/areas.conf`, on its own line after `LibraryViewDefinitionTests`, moving no other line.
- `BBS_AGENT=views-evaluator python3 Scripts/test/run-area.py LibraryViewFilterEvaluatorTests LibraryBookSorterTests UnopenedCategoryTests ReadingListViewTests FeedUILibraryRowsTests LibraryListCacheTests`, plus every test class that names `CountWording` (`grep -rln CountWording TextMouthProductionTests`), in the background, checking no more than every four minutes.
- `make lint-tests LINT_BASE=team/views`; no new Swift warning.
- When done: `BBS_AGENT=views-evaluator python3 Scripts/test/run-area.py --clean`.

## Do not touch

Anything else; no `*.md` file. Completion check: `grep -n "listedFeeds" TextMouth/Models/LibraryBookSorter.swift` finds the loop once, inside `latestOpened`.

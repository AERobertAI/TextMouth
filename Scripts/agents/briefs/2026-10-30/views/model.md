# Task `model`: the Library views model (team `views`, October 30, 2026)

Slug `views-model`, branch `views/model` from `team/views`. Read `Scripts/agents/briefs/2026-10-30/teams-common.md`, "The worker's part" and "Rules for everyone", then this brief. The design is `LIBRARY-VIEWS-RESEARCH-2026-10-30.md` at the worktree's root: read its sections 2, 3, 4, and 8 ("The JSON" and "Reading it, as untrusted input"); this brief settles everything they leave open.

## What you build

The value types of customizable Library views and their ordered list, pure Swift with no UI and no wiring: nothing in the app uses them yet, so behavior does not change. Two commits:

1. `TextMouth/Models/LibraryViewDefinition.swift`: the types, the shipped built-in views, and reading and writing one entry as config.json holds it. Tests in `TextMouthProductionTests/LibraryViewDefinitionTests.swift`.
2. `TextMouth/Models/LibraryViewDefinitionList.swift`: the ordered list, reading and writing it, and its operations. Tests in `TextMouthProductionTests/LibraryViewDefinitionListTests.swift`.

Also, in commit 1, one change to `TextMouth/ViewModels/LibraryViewModel.swift` (lines 76-95, `LibraryCategory.init(from:)`): move the name rules into `init?(savedName: String)` (the raw value, or "No Folder" for Unopened, or "Recent" for Recently Opened), which the decoder calls, so `LibraryViewID` reads the same names in one place. The decoder's behavior and error stay exactly as they are.

Read first, by line range: `TextMouth/ViewModels/LibraryViewModel.swift:1-95` (`LibrarySortField`, `LibraryCategory`), `TextMouth/Models/Library.swift:1-60` (`FolderSortSetting` and its defaults), `TextMouth/Models/Book.swift:18-70` (`BookFormat`), `TextMouth/Models/JSONValue.swift` (the JSON value kept as read), `TextMouth/Models/LenientFields.swift:325-375` (`StoredValueRepair.log`).

## Commit 1: the types

Write these declarations, each type, property, and function with a doc comment, as the codebase comments (say what it is and why, in plain sentences). All are `Sendable`; value types are `Equatable` (and `Hashable` where shown).

```swift
/// A view's permanent identity.
enum LibraryViewID: Hashable, Sendable {
    case category(LibraryCategory)   // the five views TextMouth has always had
    case feeds                        // the Feeds view
    case custom(UUID)                 // a view the listener made
    var storedValue: String           // category.rawValue, "Feeds", or uuid.uuidString
    init?(storedValue: String)        // LibraryCategory(savedName:), then "Feeds", then UUID(uuidString:); else nil
    var category: LibraryCategory?
    var isBuiltIn: Bool               // every case but .custom
    static let builtIns: [LibraryViewID]  // the five categories in LibraryCategory.allCases order, then .feeds
}

enum LibraryViewVisibility: String, CaseIterable, Sendable { case always, whenApplicable, hidden }
enum LibraryViewItemKind: String, CaseIterable, Sendable { case books, episodes, articles, feeds }
enum LibraryViewMatch: String, CaseIterable, Sendable { case all, any }
enum LibraryReadingState: String, CaseIterable, Sendable { case unopened, inProgress, finished }

struct LibraryViewCondition: Hashable, Sendable {
    enum Test: Hashable, Sendable {
        case format(BookFormat)
        case folder(id: UUID?, includingSubfolders: Bool)   // nil id: Library Root, the top of the library
        case readingState(LibraryReadingState)
        case inReadingList
        case addedWithin(days: Int)
        case openedWithin(days: Int)
        case titleOrAuthorContains(String)
        case hasNewItems
        case subscribed
    }
    var test: Test
    var isNegated: Bool = false
    /// Whether this condition tests rows of `kind` (design section 4): feeds are tested only by
    /// folder, titleOrAuthorContains, hasNewItems, subscribed; books, episodes, and articles by
    /// every test but hasNewItems and subscribed.
    func tests(_ kind: LibraryViewItemKind) -> Bool
    static let dayRange = 1...3650
    static let textLimit = 200
}

struct LibraryViewLimit: Hashable, Sendable {
    enum Order: String, CaseIterable, Sendable { case lastOpened, dateAdded, viewSort }
    var count: Int
    var chosenBy: Order
    static let countRange = 1...9999
}

struct LibraryViewFilter: Hashable, Sendable {
    var lists: Set<LibraryViewItemKind>
    var match: LibraryViewMatch = .all
    var conditions: [LibraryViewCondition] = []
    var onePerFeed: Bool = false
    var limit: LibraryViewLimit? = nil
    static let conditionLimit = 20
    var listsOnlyFeeds: Bool          // lists == [.feeds]
    var listsItems: Bool              // lists holds books, episodes, or articles
}

enum LibraryViewKind: Sendable { case folders, readingList, filter }

struct LibraryViewDefinition: Equatable, Identifiable, Sendable {
    let id: LibraryViewID
    var name: String
    var visibility: LibraryViewVisibility
    var filter: LibraryViewFilter?    // nil exactly for Folders and the Reading List
    var kind: LibraryViewKind         // from the id: .category(.folders) folders, .category(.readingList) readingList, else filter
    var isBuiltIn: Bool               // id.isBuiltIn
    static let nameLimit = 60
    static let sortSettingsKeyPrefix = "/views/"
    /// The key its sort is saved under in Library.folderSortSettings: nil for Folders (a folder's
    /// path is its key); a category's reserved key (LibraryCategory.sortSettingsKey) for the other
    /// four categories; sortSettingsKeyPrefix + id.storedValue for Feeds and custom views.
    var sortSettingsKey: String?
    /// The sort shown until one is chosen: the category's defaultSortSetting for the five;
    /// FolderSortSetting.defaultSort for Feeds and custom views.
    var defaultSortSetting: FolderSortSetting
    /// The shipped view of a built-in id; nil for a custom id.
    static func shipped(_ id: LibraryViewID) -> LibraryViewDefinition?
    /// The shipped view of one of the five categories.
    static func shipped(_ category: LibraryCategory) -> LibraryViewDefinition
    /// Whether a built-in view's name or filter differs from its shipped one; false for custom views.
    var differsFromShipped: Bool
}
```

### The shipped views (design section 3)

- Folders: name "Folders", always, filter nil.
- All Items: "All Items", always, lists [books, feeds], all, no conditions.
- Unopened: "Unopened", always, lists [books, feeds], all, conditions [readingState(.unopened), hasNewItems].
- Recently Opened: "Recently Opened", always, lists [books, episodes, articles], all, conditions [readingState(.unopened) negated], onePerFeed true, limit 10 chosen by lastOpened.
- Reading List: "Reading List", always, filter nil.
- Feeds: "Feeds", whenApplicable, lists [feeds], all, no conditions.

The five categories' names are their `rawValue`s; never repeat the string literals.

### Writing an entry: `var fileEntry: JSONValue` on `LibraryViewDefinition`

An `.object`, keys exactly as the design's section 8 shows:

- Every entry: `"id"` (storedValue) and `"visibility"` (raw value).
- A built-in view: `"name"` only when it differs from the shipped name, `"filter"` only when it differs from the shipped filter.
- A custom view: `"name"` and `"filter"` always.
- `"filter"`: `"lists"` (an array of raw values in `LibraryViewItemKind.allCases` order), `"match"`, `"conditions"` (array, in order), `"onePerFeed": true` only when true, `"limit": {"count", "chosenBy"}` only when set.
- A condition: `"test"` (one of `format`, `folder`, `readingState`, `inReadingList`, `addedWithin`, `openedWithin`, `titleOrAuthorContains`, `hasNewItems`, `subscribed`), then by test `"value"` (the format's or state's raw value), `"folderID"` (the UUID's string, or `.null` for Library Root) with `"includingSubfolders"` (always written for folder), `"days"` (`.integer`), or `"text"`; and `"not": true` only when negated.
- `extraFields` (below) are written back beside these keys.

### Reading an entry: `init?(fileEntry: JSONValue, path: String, logRepairsAs source: String?)`

`path` is the entry's place for log lines, such as `libraryViews[3]`. Returns nil when the entry is unreadable; the list keeps it as it was. With a non-nil `source`, each repair is logged with `StoredValueRepair.log(source:codingPath:detail:)`; build the coding path with a small private `CodingKey` (string or index). Log lines name the key and the kind of repair only, never a name or a text the listener typed (`LogContentPolicyTests`).

Unreadable (nil), so a newer TextMouth's view is never shown wrongly:

- Not an object; no `"id"` string; an id `init?(storedValue:)` does not read.
- A custom view with no `"name"` string, or one that is empty once whitespace is trimmed; with no `"filter"`.
- A `"filter"` that is not an object; `"lists"` missing, empty, or naming an unknown kind; an unknown `"match"`; `"conditions"` not an array, or longer than `conditionLimit`; any key in the filter object other than the five above.
- A condition that is not an object; an unknown `"test"`; a format, state, or folder ID that does not read; `"days"` not a whole number (`.integer`, or `.number` with no fraction); `"text"` not a string; `"not"` or `"includingSubfolders"` present and not a bool; any key other than those its test writes.
- A `"limit"` that is not an object with an integer `"count"` and a known `"chosenBy"`.

Repaired and logged (the entry stays readable):

- A name longer than `nameLimit` characters is cut to it; a name is trimmed of surrounding whitespace.
- A built-in view's `"name"` that is not a string, or empty once trimmed: its shipped name.
- `"visibility"` missing or unknown: the shipped view's visibility, or `.always` for a custom view. Folders is always `.always`, whatever the entry says.
- Folders and the Reading List ignore a `"filter"`; a built-in filter view without one has its shipped filter.
- `"days"` and `"count"` out of range are moved to the nearest bound; a `"text"` longer than `textLimit` is cut to it.
- `"onePerFeed"` missing or not a bool: false.

Kept, not judged: every top-level key of the entry other than `id`, `name`, `visibility`, `filter` goes into `var extraFields: [String: JSONValue]` (default empty, not part of what the listener edits, compared in `==`), and is written back unchanged.

## Commit 2: the list

```swift
struct LibraryViewDefinitionList: Equatable, Sendable {
    enum Entry: Equatable, Sendable { case view(LibraryViewDefinition), unreadable(JSONValue) }
    private(set) var entries: [Entry]
    static let entryLimit = 200
    static let shipped: LibraryViewDefinitionList           // the six shipped views, in LibraryViewID.builtIns order
    init(entries: [Entry])                                   // normalizes (below)
    init(fileEntries: [JSONValue], logRepairsAs source: String? = nil)
    var fileEntries: [JSONValue]                             // each entry: fileEntry, or the kept JSON
    var views: [LibraryViewDefinition]                       // the readable views, in order
    var unreadableCount: Int
    func view(_ id: LibraryViewID) -> LibraryViewDefinition?
    func place(of id: LibraryViewID) -> (number: Int, count: Int)?   // 1-based among `views`
    func offeredViews(current: LibraryViewID?, isApplicable: (LibraryViewDefinition) -> Bool) -> [LibraryViewDefinition]
    func firstOffered(isApplicable: (LibraryViewDefinition) -> Bool) -> LibraryViewDefinition
    func isNameTaken(_ name: String, except id: LibraryViewID?) -> Bool
    func copyName(for name: String) -> String
    @discardableResult mutating func move(_ id: LibraryViewID, by offset: Int) -> Bool
    @discardableResult mutating func setVisibility(_ visibility: LibraryViewVisibility, of id: LibraryViewID) -> Bool
    mutating func add(_ view: LibraryViewDefinition, after id: LibraryViewID?)
    @discardableResult mutating func replace(_ view: LibraryViewDefinition) -> Bool
    @discardableResult mutating func delete(_ id: LibraryViewID) -> Bool
    @discardableResult mutating func restoreDefault(_ id: LibraryViewID) -> Bool
}
```

Rules:

1. **Normalizing** (`init(entries:)`, and after every operation): a readable view whose id an earlier readable view has becomes `.unreadable(view.fileEntry)` (an unreadable entry's id never counts); Folders' visibility is `.always`; each built-in id missing from the readable views is appended with its shipped view, in `builtIns` order.
2. **Reading** (`init(fileEntries:logRepairsAs:)`): the first `entryLimit` entries, each through `LibraryViewDefinition(fileEntry:path:logRepairsAs:)` or kept unreadable; more are dropped, with one logged line. An empty array gives `shipped`.
3. **`offeredViews`**: in the list's order, a view is offered when it is `current`, or `.always`, or `.whenApplicable` and `isApplicable(view)`. `firstOffered` is `offeredViews(current: nil, …)`'s first, or Folders' view (always offered, so the fallback never happens in practice; never trap).
4. **`move`**: offset −1 or +1 among the readable views (`views`): the view trades places with the readable view before or after it; unreadable entries keep their indices among the entries as near as possible (remove the view's entry and insert it at the neighbour's entry index). Returns false, changing nothing, at the end it cannot pass, for an unknown id, or for any other offset.
5. **`setVisibility`**: false for Folders, an unknown id, or the visibility it has.
6. **`add`**: inserts after `id`'s entry, or at the end for nil or an id not in the list. The caller gives a custom view with a fresh UUID.
7. **`replace`**: swaps in the view with the same id; false when absent or equal. Folders' and the Reading List's name and filter cannot change: the replacement keeps their shipped name and nil filter; their visibility and extra fields may change.
8. **`delete`**: custom views only; false for a built-in or unknown id.
9. **`restoreDefault`**: a built-in filter view's name and filter become the shipped ones, keeping its visibility, place, and extra fields; false for Folders, the Reading List, custom views, unknown ids, or a view already as shipped. (Its saved sort is the caller's, in library.json.)
10. **`isNameTaken`**: compares trimmed names without regard to case or diacritics (`compare(_:options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame`), among readable views other than `except`.
11. **`copyName`**: "\(name) Copy", or "\(name) Copy 2", "Copy 3", and on, the first not taken; when that would pass `nameLimit`, the name is cut first so the suffix fits.

## Tests (each one pins a rule above; no test may trap: no force unwraps or unguarded subscripts)

`LibraryViewDefinitionTests`:
- The six shipped views, field by field; `builtIns` order; `storedValue` and `init?(storedValue:)` for every built-in, "No Folder" and "Recent" read as Unopened and Recently Opened, a UUID string, and unknown strings.
- `sortSettingsKey` and `defaultSortSetting` for every built-in and a custom view (`"/views/Feeds"`, `"/views/<UUID>"`, the four reserved keys, nil for Folders), and that no `"/views/"` key is a valid library path (`BookFolder.isValidLibraryPath`).
- `tests(_:)` for every test and kind.
- `fileEntry` of each shipped view is exactly `{"id", "visibility"}`; a renamed or refiltered built-in writes those keys; a custom view with every kind of condition writes the design's shape, and reads back equal (round trip).
- Each unreadable case listed above returns nil; each repair case reads repaired; extra fields round-trip.
- `LibraryCategory(savedName:)` reads the five names and the two former names and nothing else, and the decoder's existing behavior (`UnopenedCategoryTests` covers it; run it).

`LibraryViewDefinitionListTests`:
- `shipped` and an empty file read as the six shipped views; a file missing built-ins gets them appended in order; a duplicate id is kept unreadable and written back; unreadable entries are written back unchanged, in place, and counted; more than 200 entries read only 200.
- Folders cannot be hidden by a file or by `setVisibility`.
- `offeredViews` with each visibility, applicability true and false, and a hidden current view; `firstOffered`.
- Every operation's success, its refusals, and normalizing after it; `move` across an unreadable entry; `place(of:)` before and after moves.
- `isNameTaken` (case, diacritics, `except`), `copyName` (taken copies, the length limit).

## Build and test

- New test files need `/opt/homebrew/bin/xcodegen generate`; commit the regenerated `TextMouth.xcodeproj/project.pbxproj` with them.
- Add both classes to the `[library]` area of `Scripts/test/areas.conf` (sorted in it).
- Run: `BBS_AGENT=views-model python3 Scripts/test/run-area.py LibraryViewDefinitionTests LibraryViewDefinitionListTests UnopenedCategoryTests LegacyLibraryModelTests LogContentPolicyTests`, in the background; check it no more than every four minutes.
- `make lint-tests LINT_BASE=team/views` must pass.
- No new Swift warning.
- When done: `BBS_AGENT=views-model python3 Scripts/test/run-area.py --clean`.

## Do not touch

Anything outside the files named here. In `LibraryViewModel.swift`, only `LibraryCategory`'s decoder and the new `init?(savedName:)`. No `*.md` file.

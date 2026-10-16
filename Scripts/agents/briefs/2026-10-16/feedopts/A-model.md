# Task A, `feedopts-model`: the listening options as data

Branch `feedopts/model`. Read `00-contract.md` first (the rules and the names). This task is the foundation the others stand on: **a value type kept optionally on `Feed` and on `BookFolder`, read leniently, saved by setters, found for a book, and its wording.** No UI, no playback.

## 1. The type: new `TextMouth/Models/ListeningOptions.swift`

```swift
struct ListeningOptions: Codable, Equatable, Hashable, Sendable {
    var continuation: ReadingList.Continuation?   // nil: "Use the global setting"
    var skipsFinished: Bool                        // default true
    var predownloadsNext: Bool                     // default true; a feed's only, a folder's is never read
    init(continuation: ReadingList.Continuation? = nil, skipsFinished: Bool = true, predownloadsNext: Bool = true)
    static let standard = ListeningOptions()
    var isStandard: Bool { self == .standard }
    /// The lead time of the pre-download: ten minutes (600 seconds). Task C reads it; the hint below words it.
    static let predownloadLeadTime: TimeInterval = 10 * 60
    func goesOn(under global: EndOfBookBehavior) -> Bool
}
```

- `goesOn(under:)`: whether listening goes on from one item to another under these options: `.playBookBelow`/`.playBookAbove` yes, `.stop` no, nil follows `global == .continueNext`. (`EndOfBookBehavior` is in `ViewModels/SettingsViewModel.swift:18`.)
- **Coding keys** `continuation`, `skipsFinished`, `predownloadsNext`. **Reading never throws** (a feed whose record fails to decode is a feed the listener loses): `init(from:)` takes `try? decoder.container(keyedBy:)` and uses `.standard` when that fails; each key is `(try? container.decodeIfPresent(T.self, forKey: key)) ?? default`, the way `ReadingList.init(from:)` does it (`ReadingList.swift:217-236`, read it). So an unknown `continuation` string reads as nil, a non-boolean as the default. Writing may be the compiler's synthesized `encode(to:)`.
- Comment every member, the way `ReadingList` does.

## 2. The fields

- `Feed.swift`: after `unsubscribedDate` (line 92) add `var listeningOptions: ListeningOptions?`, documented like its neighbours (nil is standard; `decodeIfPresent` reads a record written before it existed; written only when set). Set `listeningOptions = nil` in `init` (line ~114). `Feed` keeps its synthesized `Codable`; its template test is `FeedRecordTests.testAFeedsSizeRoundTripsAndAnOlderRecordLoadsWithoutIt` (`FeedRecordTests.swift:135`).
- `BookFolder.swift`: after `dateCreated` (line 7) add `var listeningOptions: ListeningOptions?` (nil is standard). `BookFolder` stays `Hashable` and synthesized `Codable`. Folders are renamed and moved by changing `name` and `parentPath` in place (`Library.swift:500` and `:536`), so the options follow them; **pin that with a test.**
- `Library.mergeEquivalentFolders` (`Library.swift:596-690`) removes a duplicate folder row and keeps the first; the duplicate's options must not be lost: the surviving row keeps its own options, else takes the first duplicate's that has some (earlier rows first), as its sort settings do (`:664-686`). Test beside `FolderDuplicateRepairTests`' existing style (new test in your own file).

## 3. Setters, lookups, a settings reader

- `FeedCenter.setListeningOptions(_ options: ListeningOptions?, of feedID: UUID)` beside `setDeleteDownloadsDaysAfterPlayed` (`FeedCenter.swift:1159`): stores nil when `options` is nil or standard, else the options; goes through `store.update(feedID)` (which writes the record when its durable form changed, `FeedStore.swift:346`).
- New file `TextMouth/ViewModels/LibraryViewModel+ListeningOptions.swift`:
  - `listeningOptions(ofFolder folderID: UUID) -> ListeningOptions?`
  - `setListeningOptions(_ options: ListeningOptions?, ofFolder folderID: UUID)`: normalizes as above, changes `library.folders`, and `save()`s once, as `setFolderSortSetting` does (`LibraryViewModel+SortAndOrder.swift:207`); changes nothing and saves nothing for an unknown ID or an unchanged value.
  - `listeningOptions(of book: Book) -> ListeningOptions?`: for a feed's item (`book.feedLink`) the feed's options (`feeds.store.record(of:)?.feed.listeningOptions`); for any other book the options of the folder that holds it directly (`library.existingFolder(equivalentTo: book.folderPath)`, `Library.swift:553`); nil for a book at the top level, in a folder with none, or whose feed's record is gone.
- `SettingsPolicy.swift`, in `EnumSettingRule` (line ~105): add `func storedValue(in defaults: UserDefaults) -> Value { value(fromRaw: defaults.string(forKey: key)) }`, documented like `ThresholdSettingRule.storedValue(in:)` (line 75), which it mirrors; so a sheet reads the global "When book ends" as Settings does. Test beside `SettingsPolicyTests`' style (your own file).

## 4. The wording: new `TextMouth/Models/ListeningOptionsWording.swift`

`enum ListeningOptionsWording`, pure, one place for every string the controls say. A `Noun` enum (`episode`, `article`, `item`, `book`) with `init(_ feedNoun: FeedWording.ItemNoun)` (`FeedWording.swift:143`), `singular`, `plural`, and `article` ("an" for episode, article, item; "a" for book). Exact strings (for the noun episode; the others change the noun only):

| Function | String |
| --- | --- |
| `continuationLabel(noun)` | "When an episode ends" / "When an article ends" / "When an item ends" / "When a book ends" |
| `continuationTitle(nil, noun:, global:)` | "Use the global setting (Continue to Next Book)": the global's `rawValue` in parentheses |
| `continuationTitle(.playBookBelow, ...)` | "Play the episode below" |
| `continuationTitle(.playBookAbove, ...)` | "Play the episode above" |
| `continuationTitle(.stop, ...)` | "Stop" |
| `continuationHint(noun)` | for a feed noun: "What happens when one of this feed's episodes ends: play the episode below it or the one above it in the list, stop, or follow the global setting"; for `book`: "What happens when one of this folder's books ends: play the book below it or the one above it in the folder, stop, or follow the global setting" |
| `skipFinishedLabel(noun)` | "Skip finished episodes" |
| `skipFinishedHint(noun)` | "When listening goes on to another episode, pass over the episodes already finished" |
| `predownloadLabel(noun)` | "Download the next episode before this one ends" |
| `predownloadHint(noun, enabled: true)` | "When 10 minutes or less of the episode playing are left, download the episode that plays next, if it is not on this Mac yet" (the minutes come from `ListeningOptions.predownloadLeadTime` through `CountWording.minutes`, `CountWording.swift`) |
| `predownloadHint(noun, enabled: false)` | "Available only while this feed's episodes go on to another episode when one ends" |

Each function has a doc comment; a test pins every string above for every noun it varies with.

## 5. Tests: new `TextMouthProductionTests/ListeningOptionsTests.swift` (needs `xcodegen generate`, and the regenerated `project.pbxproj` committed with it)

1. `ListeningOptions` defaults, `isStandard`, `goesOn(under:)` for all nine combinations of continuation and global behavior.
2. A `Feed` with options round-trips through `FeedRecordCoding`; a record written before the field (remove the key from the JSON, as `FeedRecordTests.swift:143-150` does) loads with nil; a standard set of options is never written (no `listeningOptions` key) and the record's file is unchanged.
3. Leniency: `{"continuation":"playBookSideways","skipsFinished":"yes","predownloadsNext":false}` reads as continuation nil, skip true, pre-download false; `"listeningOptions": 5` and `"listeningOptions": "x"` do not fail the record's decoding and read as standard (`feed.listeningOptions ?? .standard == .standard`); a whole library.json with such a folder still decodes.
4. A `BookFolder` round-trips inside a `Library`; a library.json without the key loads with nil; the options survive `renameFolder` and `moveFolder`; `mergeEquivalentFolders` keeps the survivor's own, else takes the duplicate's.
5. The setters: `FeedCenter.setListeningOptions` changes the record, writes it (check the way existing tests check a record saved, see `FeedLifecycleTests.swift:182` for the engine setup with `FeedTestWorld`), stores nil for standard, and a second identical call writes nothing; `LibraryViewModel.setListeningOptions(_:ofFolder:)` changes the folder and saves once, ignores an unknown ID.
6. `listeningOptions(of:)`: a feed's item, a book in a plain folder with options, a book in a plain folder with none, a book at the top level, a book in a subfolder of a folder with options (nil: not inherited).
7. `EnumSettingRule.storedValue(in:)`: missing key, a valid raw value, an unknown raw value (default), using a private `UserDefaults(suiteName:)` removed afterwards.
8. All wording strings.

Run: `ListeningOptionsTests`, `FeedRecordTests`, `FolderDuplicateRepairTests`, `LegacyLibraryModelTests`, `FolderSafetyTests`, `FeedLifecycleTests`, `SettingsPolicyTests` (build once with all `-only-testing:` flags; the builds section of `teams-common.md` shows one).

## 6. Commits (small, each green)

1. The type, the two fields, the merge repair, with their tests (items 1-4 of section 5).
2. The setters, the lookups, `storedValue(in:)`, with their tests (5-7).
3. The wording, with its test (8).

## Do not touch

`FeedInfoSheet.swift`, `LibraryView.swift`, anything under `ViewModels/ReaderViewModel*`, `ReadingList.swift` beyond reading it, and every existing test.

# Brief: `stable020-rows` (V03, first half: library.json)

- **Slug:** `stable020-rows`. **Branch:** `stable020/rows`, made with `git checkout -b stable020/rows team/stable020`. **Team:** `stable020`, lead `stable020-lead`.
- **Read first:** `Scripts/agents/briefs/2026-10-19/teams-common.md`, its sections "The worker's part", "Rules for everyone", "The board", "Builds", and "Lessons every brief applies". Nothing else of it. Then `PLAN-0.2.0-2026-10-23.md` §1.1 (lines 23-33) and §2.7 (lines 168-176).
- **Why:** 0.2.0 is the official build the user would go back to. Every format in the queue (FictionBook, PowerPoint, MOBI, email, and more) adds a `BookFormat` case, and today one row of an unknown format, or a sort field 0.2.0 does not know, makes 0.2.0 refuse the whole library. After this, 0.2.0 opens such a library, shows every book it can read, and keeps the rest exactly as written. A second worker will make every walk of the packages leave those rows' packages alone; this brief does not touch them.
- **Register with:** `--files TextMouth/Models/JSONValue.swift,TextMouth/Models/Library.swift,TextMouth/Services/LibraryPersistenceService.swift,TextMouth/Views/Settings/StorageSettingsView.swift,TextMouthProductionTests/NewerLibraryRowsTests.swift,TextMouth.xcodeproj/project.pbxproj,Scripts/test/areas.conf` (and any `Library(` construction site you must change, below).
- **Commits:** (1) `JSONValue` with its tests; (2) library.json's rows and sort fields with their tests; (3) the sentence and the log line with their tests.
- **Disk:** before every build, `df -g /System/Volumes/Data` must show at least 4 GB available; if not, post to `stable020-lead` and wait for an answer (`bbs watch stable020-rows --timeout 240`). Your build folder is `/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-stable020-rows`.
- **New files** need `/opt/homebrew/bin/xcodegen generate`, with the regenerated `TextMouth.xcodeproj/project.pbxproj` committed beside them; the new test class gets one line in `Scripts/test/areas.conf`, in the area that lists `ContentAnalysisMergeTests` (sorted in place), and `python3 Scripts/test/run-area.py --unassigned` must print "0 unassigned".

## What is known (do not re-explore)
- `Library.init(from:)` (`TextMouth/Models/Library.swift:167-174`) decodes `books` as `[Book]` in one piece, so one row that does not decode fails the whole library. `Library.encode(to:)` (:183-189) writes `libraryBooks`.
- `FolderSortSetting.init(from:)` (:67-80) decodes `sortField` as `LibrarySortField`, strictly; `rememberedDirections` already skips a field it does not know.
- library.json is written with `JSONEncoder` whose dates are ISO 8601 strings (`LibraryPersistenceService.swift:503`) and read with the matching decoder (:1363).
- No JSON value type exists in the code.
- In `JSONDecoder`, a failed `UnkeyedDecodingContainer.decode(_:)` does not advance the container, so the same element can be decoded again as another type. Your tests must prove it (the row after an unreadable one is read).

## Commit 1: `JSONValue`
A new file `TextMouth/Models/JSONValue.swift`:
```swift
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}
```
- Decoding tries, in order: `decodeNil()`, `Bool`, `Int64`, `Double`, `String`, `[JSONValue]`, `[String: JSONValue]`; nothing else decodes, and that throws `DecodingError.dataCorrupted`. Integers stay integers, so a row written back says `3`, not `3.0`; dates stay the strings they were.
- **Bound the nesting,** since the file is untrusted: `static let maximumDepth = 64`; a value nested deeper (measured by `decoder.codingPath.count`) throws `DecodingError.dataCorrupted` with a debug description naming the limit. Never recurse without that check.
- Encoding writes each case as its JSON form.
- Convenience, each with a doc comment: `subscript(key: String) -> JSONValue?` (an object's member, nil otherwise) and `var stringValue: String?`.
- Doc comment on the type: a JSON value kept exactly as read, so a row this TextMouth cannot read is written back as it was (V03); `V04` may reuse it for unknown keys.
- **Tests** (in `NewerLibraryRowsTests`, a `// MARK: - JSONValue`): a round trip through `JSONEncoder` and `JSONDecoder` of an object holding every case; `3` decodes as `.integer(3)` and encodes as `3`; `2.5` as `.number(2.5)`; `true` as `.bool(true)`, never `.integer`; an ISO 8601 date string stays `.string`; a value nested 100 arrays deep throws, and one nested 30 deep decodes.

## Commit 2: the rows and sort fields of library.json
1. **The kept row.** In `TextMouth/Models/Library.swift`:
   ```swift
   struct UnreadableLibraryRow: Equatable, Sendable {
       let json: JSONValue
       var id: UUID? { ... }              // json["id"]'s string, when it is a UUID
       var tmbDirectoryName: String? { ... }
       var folderPath: String? { ... }
   }
   ```
   Doc comment: a row of library.json this TextMouth could not read (V03): a book a later TextMouth wrote, in a format or with fields this one does not know, or a row damaged by hand. It is kept exactly as read, written back at every save, and never shown, counted as a book, opened, or searched. Its package is its own, which the walks of the packages respect (the next worker's part).
2. **`Library.unreadableRows: [UnreadableLibraryRow]`**, empty by default (an `init` parameter with default `[]`), with a doc comment.
3. **Decoding,** in `Library.init(from:)`: read `books` through `nestedUnkeyedContainer(forKey: .books)`, one element at a time: a row that decodes as a `Book` is kept as now (`placedInLibraryFolder()`); any other is decoded as a `JSONValue` and kept in `unreadableRows`, in order. If an element cannot be decoded even as a `JSONValue` (deeper than the limit), the library throws, as a library that cannot be read throws today. Put this in one static function, `UnreadableLibraryRow.decodeRows(from:) -> (books: [Book], unreadable: [UnreadableLibraryRow])` taking the unkeyed container `inout`, with a doc comment, so a feed's index can reuse it later.
4. **Encoding,** in `Library.encode(to:)`: the `books` array holds `libraryBooks` as now, then every unreadable row's `json`, in order. A library without unreadable rows encodes exactly as it does today.
5. **Every new `Library` that replaces the loaded one carries the kept rows.** Find each construction: `grep -rn -E "Library\(" TextMouth --include=*.swift | grep -v -E "LibraryViewModel\(|//"`. Where a `Library` is built to replace the model's `library` or to be saved as library.json (Rebuild Library Index, the data-directory move's `library(afterMoving:from:current:)` and its `migrated` library, a cloud merge, a legacy migration), it takes `unreadableRows` from the library it replaces. Where it is a temporary value or a test's, leave it. List every site and your decision in your report.
6. **Sort fields.** In `FolderSortSetting`:
   - keep the raw value of a `sortField` this TextMouth does not know in `private var unknownSortField: String?`;
   - such a setting reads as `FolderSortSetting.defaultSort`'s field, with its `sortAscending` as read;
   - `encode(to:)` writes `unknownSortField ?? sortField.rawValue`;
   - any assignment of `sortField` clears it (`didSet`), and every other initializer leaves it nil;
   - `Equatable` includes it.
   Find any other strict decode of a `LibrarySortField` in what library.json holds (`grep -rn "LibrarySortField.self" TextMouth`) and treat it the same way, or list it in your report if it is outside library.json.
7. **Tests** (`NewerLibraryRowsTests`, a `// MARK: - Rows a newer TextMouth wrote`). Build library.json's text in the test from a real encoded library (two books, A and B, made as other library tests make books) by inserting raw rows into its `books` array with `JSONSerialization`:
   - `testALibraryWithRowsItCannotReadOpensWithTheRest`: the rows are A, a copy of A's JSON with a new `id`, a new `tmbDirectoryName`, and `"format": "fb2"`, a copy of B's JSON with a new `id` and no `title`, then B; and `folderSortSettings[""]` is `{"sortField": "pages", "sortAscending": false}`. It decodes; `books.map(\.id)` is `[A.id, B.id]`; `unreadableRows` holds the two, in order, with their `id` and `tmbDirectoryName` read; the root folder's sort reads as the default field.
   - `testTheRowsItCannotReadAreWrittenBackUnchanged`: encode what was decoded, and compare with `JSONSerialization` objects: the `books` array holds A and B as encoded, then the two raw rows equal (`NSDictionary` equality) to the originals; the root folder's `sortField` is `"pages"`, its `sortAscending` false. A second decode and encode gives the same JSON.
   - `testALibraryOfReadableRowsEncodesAsBefore`: a library with no unreadable row and only known sort fields encodes to exactly the bytes it encodes to on `team/stable020` before your change (record those bytes once, from the team branch, as a literal or by building the same library both ways; say how in the test's doc comment).
   - `testAKnownSortChosenAfterwardReplacesTheUnknownOne`: assign a `sortField` to the setting read as "pages": it encodes the new field.
   - `testARowNestedTooDeeplyRefusesTheLibrary`: a row holding 100 nested arrays: decoding throws, and nothing traps.
   - `testTheRowsKeptAreNotCounted`: `library.libraryBooks.count` and the library's own book count leave them out.

## Commit 3: one sentence, and one log line
1. **The count.** `LibraryViewModel` gains `var booksNeedingNewerTextMouth: Int { library.unreadableRows.count }`, with a doc comment (feed indexes are the next worker's).
2. **The sentence,** in `StorageLocationWording` (`TextMouth/Views/Settings/StorageSettingsView.swift:78`), a static function `booksNeedingNewerTextMouth(_ count: Int) -> String?`: nil for 0; for 1, `"1 book in this library needs a newer version of TextMouth. It is kept as it is, but not shown."`; for any other count n, `"n books in this library need a newer version of TextMouth. They are kept as they are, but not shown."` (with the number). It is shown in Storage settings' first section, the one holding "Location" and "Status" (`StorageSettingsView.swift:198-280`), right after the "Status" row, as a plain `Text`, only when the function gives one. VoiceOver reads it in order with its section; nothing is conveyed by sight alone.
3. **The log line,** once each time library.json is read and holds kept rows, where `LibraryPersistenceService` decodes it: `DiagnosticLog.event(.storage, "LIBRARY_ROWS_KEPT: \(CountWording.phrase(n, singular: "row", plural: "rows")) of library.json need a newer TextMouth; kept as they are and not shown")`. If a new log tag must be registered for `LogContentPolicyTests`, register it as the other `.storage` tags are.
4. **Tests:** the sentence for 0 (nil), 1, and 3, pinned exactly; `booksNeedingNewerTextMouth` for a model whose library holds two kept rows.

## Test classes to run
`NewerLibraryRowsTests`, `ContentAnalysisMergeTests`, `LogContentPolicyTests`, `SettingsTabFitTests`, every class of the area that lists `ContentAnalysisMergeTests` (`python3 Scripts/test/run-area.py -h` lists the areas), `StorageGenerationStaleWriterTests`, `DataDirectoryMoveTests` (its `testAMoveShowsItsProgressWhileItCopies` is load-sensitive: rerun alone on failure, report both), and `python3 Scripts/test/run-area.py --unassigned`. Run `make lint-tests LINT_BASE=team/stable020` and `make lint-a11y` before you report.

## Do not touch
The walks of the packages (orphan adoption, the startup repair, Rebuild Directory's own walk, the removal sweeps), `TextMouth/Services/Feeds/FeedIndex.swift`, any file not named above or found by step 5, `*.md`, and the transcripts team's files. A failing existing test means stop and ask your lead.

## Report
teams-common's form, and the list from step 5.

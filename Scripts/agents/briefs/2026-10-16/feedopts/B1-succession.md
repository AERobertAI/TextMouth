# Task B1, `feedopts-succession`: one neighbor search and one "go on past this book" path

Branch `feedopts/succession`. Read `00-contract.md` first. This is a **refactor**: the reading list, a plain folder, and a feed's folder all search for "the book beside this one" and all hand listening over to it, each with its own copy. Make them share one of each, so the next tasks add feed and folder options in one place. **What the app does must not change**, and every existing test stays green and unedited. The one addition is that the folder and feed searches learn to go *up* (nothing calls that yet except your tests).

## What exists (read these, by line range)

- `TextMouth/Models/ReadingList.swift:192-203`: `neighbor(of:_:where:)`, the reading list's own search over `bookIDs`. `Direction` is at `:58-81`.
- `TextMouth/ViewModels/LibraryViewModel+ReadingList.swift:237-275`: `readingListNeighbor(of:direction:skippingFinished:)` and `readingListContinuation(after:)`, which use it.
- `TextMouth/ViewModels/LibraryViewModel+SortAndOrder.swift:131-177`: `nextBookInFolder(after:)` (first later book that does not rest at its end), `laterBooksInFolder(after:)` (a plain folder's books after this one in `ManualBookOrder.orderedBooks`, or, for a feed's item, `laterFeedItems(after:of:)`: the downloaded items its feed's folder lists after it). Existing tests pin these two names and results (`FeedItemIndexListTests.swift:136-176`, `ManualOrderRearrangingTests`, `BookmarkKeyboardAccessTests`), including that a feed's item that is not downloaded is passed over.
- `TextMouth/ViewModels/ReaderViewModel+ReadingList.swift:106-173`: `followReadingListPastThisBook(...)` and its helpers; `TextMouth/ViewModels/ReaderViewModel+Playback.swift:2574-2619`: `continueToNextBookInFolder(...)`. They do the same four steps: ask what follows; if nothing, say "Finished: <title>" with a note; if this reader's sleep timer is in effect, say "Finished" with `nextBookNotStartedNote` and start nothing; else `handOverToNextBook(to:titled:askingWith:)` (`:2816`), which asks `continueThroughReadingList(to:)` or `continueToNextBook(_:)`.

## What to build

1. **New `TextMouth/Models/ListNeighbors.swift`**, an `enum ListNeighbors`, generic over `ID: Equatable`:
   - `static func beyond<ID>(_ id: ID, going direction: ReadingList.Direction, in ids: [ID]) -> [ID]?`: the elements of `ids` beyond `id` going `direction`, nearest first (after it going down; before it, read backward, going up); nil when `ids` does not hold `id`; the first position of `id` when it appears twice.
   - `static func neighbor<ID>(of id: ID, _ direction: ReadingList.Direction, in ids: [ID], where isEligible: (ID) -> Bool) -> ID?`: the first of those that `isEligible` accepts; nil when `id` is absent or none qualifies.
   - `ReadingList.neighbor(of:_:where:)` keeps its signature and calls `ListNeighbors.neighbor` on `bookIDs`.
2. **In `LibraryViewModel+SortAndOrder.swift`**:
   - `func booksBeyond(_ book: Book, going direction: ReadingList.Direction) -> [Book]`: for a plain folder's book, the books beyond it in `ManualBookOrder.orderedBooks(in: library, folderPath: book.folderPath)`; for a feed's item (`book.feedLink`), the downloaded items beyond it in the feed's `listedItems` (as `laterFeedItems` finds them today, rows looked up in one pass). Empty when the book is not in the sequence. Use `ListNeighbors.beyond`.
   - `func nextBook(after book: Book, going direction: ReadingList.Direction, skippingFinished: Bool) -> Book?`: the first of `booksBeyond` that does not rest at its end (`restsAtEnd`) when skipping, else the first.
   - `laterBooksInFolder(after:)` becomes `booksBeyond(book, going: .down)`, and `nextBookInFolder(after:)` becomes `nextBook(after:going: .down, skippingFinished: true)`. Keep both names, signatures, and doc comments' meaning. Delete `laterFeedItems` if it has become a duplicate of the new feed branch (do not leave two).
   - `LibraryViewModel+ReadingList.swift`: `readingListNeighbor` uses `ReadingList.neighbor` as now (nothing to change unless you find a reason).
3. **Reader: `BookSuccession` and `goOnPastThisBook`**, in a new file `TextMouth/ViewModels/ReaderViewModel+GoingOn.swift`:
   ```swift
   /// What follows a finished book.
   enum BookSuccession: Equatable {
       case book(Book)                 // this book takes listening over
       case nothing(note: String)      // nothing follows; the note says why
   }
   extension ReaderViewModel {
       func goOnPastThisBook(
           to succession: BookSuccession,
           in place: String,                         // "the reading list" or "its folder", for the debug log only
           startingWith start: @escaping (UUID) -> Void,
           sleepTimerEndsListening: Bool,
           sleepTimerStoppedHere: Bool,
           sayingNothingFollows say: (String) -> Void
       )
   }
   ```
   It holds the one copy of: the `.nothing` case (debug trace, then `say(EndOfBookWording.finished(book.title, notes: [note], sleepTimerExpired: sleepTimerStoppedHere))`), the sleep-timer guard (trace, then `say(EndOfBookWording.finished(book.title, notes: [EndOfBookWording.nextBookNotStartedNote]))`), and `handOverToNextBook(to:titled:) { start(next.id) }`. The words spoken are exactly today's.
   - `followReadingListPastThisBook(...)` (same signature) works out its `BookSuccession` (`readingListContinuation(after:)`, else `.nothing(note: readingListEndNote())`) and calls it with `start: continueThroughReadingList(to:)`.
   - `continueToNextBookInFolder(...)` (same signature, still private in `ReaderViewModel+Playback.swift`) works out its `BookSuccession` (`nextBookInFolder(after:)`, else `.nothing` with `noMoreBooksInFolderNote` when `laterBooksInFolder(after:)` is empty, `onlyFinishedBooksInFolderNote` otherwise) and calls it with `start: continueToNextBook(_:)`.
4. **Tests**, new files (each needs `xcodegen generate`, the regenerated `project.pbxproj` committed with it):
   - `ListNeighborsTests`: `beyond` and `neighbor` going down and up, with the id first, last, in the middle, absent, and repeated; eligibility passing over elements; nothing eligible; empty list.
   - `SuccessionSearchTests` (library level, with the fixtures `FeedItemIndexListTests.swift:136-176` and `ManualOrderRearrangingTests` use): `booksBeyond` and `nextBook` going **up** and down in a plain folder (manual order), and in a feed's folder (downloaded items only, an item not downloaded passed over, both ways); `skippingFinished: false` returns a finished book, `true` passes over it; the old names return what they returned.

## Completion check (each must hold when you are done)

- `grep -rn "handOverToNextBook(to:" TextMouth --include="*.swift"` finds exactly two lines: the definition (`ReaderViewModel+Playback.swift`) and the one call in `goOnPastThisBook`.
- `grep -rn "nextBookNotStartedNote" TextMouth --include="*.swift"` finds the definition (`EndOfBookWording.swift`) and one use.
- `grep -rn "position + 1)\.\.\.\|index(after: current)\|currentIndex + 1)\.\.\." TextMouth --include="*.swift"` finds nothing outside `ListNeighbors.swift`.

## Tests to run (all must pass, none edited)

`ListNeighborsTests`, `SuccessionSearchTests`, `ReadingListTests`, `ReadingListReaderTests`, `ContinueToNextBookTests`, `FeedItemIndexListTests`, `ManualOrderRearrangingTests`, `BookmarkKeyboardAccessTests` (load-sensitive: if it fails, rerun it alone and report both results), `ReaderAutoplayRequestsTests`, `FinishedBookReaderTests`.

## Commits

1. `ListNeighbors` with `ReadingList.neighbor` delegating, and its tests.
2. `booksBeyond` and `nextBook` in the library model, the old two names defined through them, and their tests.
3. `BookSuccession` and `goOnPastThisBook`, the two callers moved onto it.

## Do not touch

Any existing test; `EndOfBookWording.swift`'s strings; `handOverToNextBook`; the notification and request code; the reading list's options or storage. Do not add direction or option parameters anywhere else: the next task (B2) does.

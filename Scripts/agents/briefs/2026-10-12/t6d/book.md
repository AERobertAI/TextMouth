# t6d task "book": a book keeps its waiting skips, and takes moved places only where they still are as they were

Slug `t6d-book`, branch `t6d/book`, board task in your launch prompt. Read `worker-common.md` beside this file first. Two commits, in this order.

## Background
When TextMouth rebuilds a book's text, `PlaceRelocator.relocate(_:movedAt:)` moves the book's places (`PlaceRelocator.Places`: a reading position, bookmarks, skipped headings that name a heading, and skipped headings that wait, naming none) and returns where they are in the new text (`Outcome.places`). The team's later tasks write those moved places into the book's library row and its package record (bookInfo.json). This task gives `Book` what they need:

- **Waiting skips are stored apart.** A book keeps two lists in step today: `skippedHeadingIDs`, which the reader matches against headings (`ReaderViewModel.skippedHeadingIDs`, `isHeadingSkipped(_:)`) and which every older build reads, and `skippedHeadings`, the same skips with their words (T06). A skip that waits must name no heading, so it must be in neither list: it goes in a third, `waitingSkippedHeadings`, which no reader reads and older builds ignore (for them its section simply plays, which is safe). A later rebuild may give it a heading again; the relocator decides that.
- **The guarded take.** Moved places are computed from the places as they were when the old text was copied aside (`original`). By the time they are written, the listener may have saved a place again. Each moved place is taken only where the book still holds it exactly as it was, so a place saved meanwhile wins.

## Read (by line range)
- `TextMouth/Models/Book.swift`: `skippedHeadingIDs` and `skippedHeadings`, lines 123-141; the memberwise init's parameters and body around lines 240-300 (find `skippedHeadings:`); `init(from:)` lines 320-350 (the `LenientFields` decoding, line 346); `makeBookInfo()` lines 860-905 and `init(record:filePath:folderPath:tmbDirectoryName:)` lines 907-960; `ReadingPosition` and `Bookmark`, lines 1200-1260; `SkippedHeading`, lines 1310-1395; `setSkippedHeadings(_:)` and `placesWithoutAnchors`, lines 1397-1422.
- `TextMouth/Models/BookInfo.swift`: `BookState`, lines 175-320 (its skip fields 194-202, init 240-290, decoding 295-315).
- `TextMouth/Models/LenientFields.swift`, lines 50-68: `optionalValue`.
- `TextMouth/Models/PlaceRelocator.swift`: `Places` (search `struct Places`).
- Tests: `TextMouthProductionTests/ContentAnalysisMergeTests.swift` lines 210-230 and 800-860 (`bookWithEveryFieldSet`); `PlaceRelocatorTestSupport.swift`'s `NotesBook` (the slide fixture, at the file's end) and `SavedPlace`; `PlaceRelocatorBookTests.swift`'s `testASkipThatWaitsKeepsWaitingWhileTheNextSectionHasItsID` (how a waiting skip comes out of the relocator); `HeadingVocabularyTests.swift` lines 211-221 (`makeReader`).

## Commit 1: "Keep a book's waiting skips apart from the skips that name headings"
1. `Book.waitingSkippedHeadings: [SkippedHeading]?`, declared after `skippedHeadings`, `var`, nil when there are none (never an empty array). Its doc: the headings skipped during playback for which a rebuild of the book's text found no heading (T06's branch D); each waits, naming no heading, so neither this build's reader nor an older build skips anything for it, and it is kept so a later rebuild may find its heading; never in `skippedHeadingIDs`; written with the moved places (`takeMovedPlaces`, commit 2).
2. Give it everything `skippedHeadings` has, except the `inStep` pairing with IDs:
   - the memberwise init's parameter `waitingSkippedHeadings: [SkippedHeading]? = nil`, after `skippedHeadings:`, stored nil when empty;
   - `init(from:)`: `fields.optionalValue(.waitingSkippedHeadings) { $0 }` (a missing or unreadable value is nil), then nil when empty;
   - Book's encoding is synthesized: confirm there is no explicit `CodingKeys` or `encode(to:)` in `Book.swift`, so the new stored property is encoded as written;
   - `BookState` (BookInfo.swift) gains the same field, init parameter, and lenient decoding, after its `skippedHeadings`;
   - `makeBookInfo()` passes it to `BookState`, and `init(record:…)` takes it back.
   Then grep `TextMouth/` for `skippedHeadings:` and `\.skippedHeadings` to make sure no other place copies a book's fields one by one (the reader's toggle, the anchor capture, and `adoptCapturedAnchors` read named skips only and stay as they are).
3. `hasOwnSettings` (`Book+OwnSettings.swift`) does not change: a waiting skip names no heading, so it is no setting the listener can see.
4. Tests:
   - `ContentAnalysisMergeTests.bookWithEveryFieldSet` gains a waiting skip (another level, label, and place than the named one, with an anchor), so `testBookRebuiltFromItsRecordHasEveryField` and the merge tests pin the new field through the record.
   - In a new test class `BookWaitingSkipTests` (new file `TextMouthProductionTests/BookWaitingSkipTests.swift`; run xcodegen and commit the project with it): a row (`JSONEncoder` and `JSONDecoder` of `Book`) and a record (`makeBookInfo()`, encoded and decoded as `BookInfo`, then `Book(record:…)`) keep a waiting skip; a row and a record written without the key, or with an unreadable value under it (a string), decode with nil; the record's JSON `state.skippedHeadingIDs` never holds the waiting skip's ID.

## Commit 2: "Give a book its places as the relocator moves them, taking each only where it is as it was"
5. `var relocatablePlaces: PlaceRelocator.Places` on `Book` (with the other T06 members, near `placesWithoutAnchors`): the reading position, the bookmarks, `skippedHeadings ?? []`, and `waitingSkippedHeadings ?? []`.
6. `var holdsPlacesToMove: Bool`: false for an audiobook (`format.isAudio`, whose places count time, P08); otherwise true when the book has a reading position past the book's start (its chapter index or its offset not 0), a bookmark, a skipped heading, or a waiting one.
7. `@discardableResult mutating func takeMovedPlaces(original: PlaceRelocator.Places, moved: PlaceRelocator.Places) -> Bool`: the moved places, each only where this book still holds it exactly as it was (`original`); returns whether any of the book's places changed (compare `relocatablePlaces` before and after).
   - **The position:** when `readingPosition == original.position`, it becomes `moved.position`.
   - **Each bookmark:** one of this book's bookmarks that `original` holds by its `id`, equal to `original`'s, becomes `moved`'s bookmark with that `id` (when `moved` has one). A bookmark added, changed, or removed meanwhile stays as this book has it, and the book's order is kept.
   - **The skips, as one:** when `(skippedHeadings ?? []) == original.skippedHeadings` and `(waitingSkippedHeadings ?? []) == original.waitingSkippedHeadings`, `setSkippedHeadings(moved.skippedHeadings)` (which writes the IDs from them) and `waitingSkippedHeadings` = `moved.waitingSkippedHeadings`, nil when empty. Otherwise both lists stay: a skip toggled meanwhile keeps the listener's whole choice. (The relocator merges skips that come to name one heading, so its lists do not match the old ones skip for skip.)
   - Nothing else changes: no date, no last-opened time, no other field.
   - Its doc says why each place is guarded, and that the moves are silent.
8. Tests, in `BookWaitingSkipTests`:
   - **The waiting skip, from the relocator to the reader** (the team's charter asks for exactly this). Use the shared fixture `NotesBook` (`both`, `withoutFirst`, `firstHeading`, `slidHeading`; never copy its strings): a book whose only skip is the first "Notes" (`SavedPlace.skip(of:in:)`). Relocate its `relocatablePlaces` from `both` to `withoutFirst` (`PlaceRelocator(oldTexts:newTexts:oldHeadings:newHeadings:)`, as `testASkipThatWaitsKeepsWaitingWhileTheNextSectionHasItsID` does); `takeMovedPlaces(original:moved:)` with the outcome's places; store the book as a row and as a record (encode, decode, as in commit 1); then for each stored book open a reader as `HeadingVocabularyTests.makeReader(book:)` does (copy it; close the reader in a teardown block) and assert `reader.isHeadingSkipped(NotesBook().slidHeading)` is false and `reader.skippedHeadingIDs` is empty, while the stored book's `waitingSkippedHeadings` holds the skip exactly as it was.
   - **The guard:** a position saved meanwhile is kept while a bookmark moves; a bookmark whose label changed meanwhile keeps the change and its old place while another bookmark moves; a bookmark added meanwhile stays, and one removed meanwhile is not brought back; a skip toggled meanwhile keeps both skip lists as they are while the position moves; with nothing changed meanwhile every place moves and the result is true; with every place as `moved` already, the result is false.
   - **`holdsPlacesToMove`:** false for a book with no places, for one whose only place is a position at chapter 0, offset 0, and for an audiobook with a bookmark; true for a bookmark alone, a skip alone, a waiting skip alone, and a position at chapter 1, offset 0.
   - Places for these tests can be made directly (`ReadingPosition`, `Bookmark`, `SkippedHeading`, with or without anchors); only the first test needs the relocator.

## Run
`BookWaitingSkipTests`, `ContentAnalysisMergeTests`, `TextAnchorRecordTests`, `PlaceRelocatorBookTests`.

## Do not touch
`SkippedHeading.inStep`, `setSkippedHeadings(_:)`, `adoptCapturedAnchors`, `placesWithoutAnchors`, `PlaceRelocator.swift`, and any file but `Book.swift`, `BookInfo.swift`, `ContentAnalysisMergeTests.swift`, the new test file, and the project file.

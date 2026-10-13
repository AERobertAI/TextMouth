# t6e-race: a move never wins over a newer write from another Mac

- **Slug** `t6e-race`; **branch** `t6e/race`, from `team/t6e`; **board task** given in your prompt.
- Read `worker-common.md` beside this file first, then "The worker's part" of `../teams-common.md`.
- Line numbers are `team/t6e`'s at 056e8a90 (main).

## The race branch D left
In a library in the cloud, a book's library row (library.json) and its record (bookInfo.json) take moved places separately:
- `LibraryPersistenceService.saveContentAnalysis(…movedPlaces:)` merges the moves into the record's latest durable state, each only where the record still holds the place as it was (`Book.takeMovedPlaces(original:moved:)`, Book.swift 1474-1518).
- The row then takes them through `ContentAnalysisSummary.apply(to:)` (ContentAnalysisSummaryBuffer.swift 28-38), guarded only by the row.
- When another Mac has written a newer position into the record, the record refuses the move, but the row still takes the moved position, which `PlaceRelocator` dates at the move (`lastUpdated` = the move's time).
- The next launch's adoption (`adoptNewerRecordedPositions`, LibraryViewModel+Migration.swift 164-199: the record's position wins only when its `lastUpdated` is newer than the row's) then keeps the row's moved, stale position over the other Mac's newer one. The other Mac's reading is lost.

## The fix (decided; build exactly this)
The row takes only the moves the record took.
1. **`TextMouth/Services/PlaceSnapshots.swift`, `MovedPlaces` (lines 215-235):** add `func taken(by committed: Book) -> MovedPlaces`. It returns the same `bookID`, `original`, and `snapshot`, with `moved` narrowed: each move the committed record did not take is put back to its original, so a row taking the result changes only what the record changed.
   - **The position** stays moved when `Book.isAsStored(committed.readingPosition, moved.position)`; otherwise it is `original.position`.
   - **Each bookmark** of `moved.bookmarks` stays moved when `committed.bookmarks` holds a bookmark of its `id` that `isAsStored` equals it; otherwise it is the original's bookmark of that `id`. The two lists hold the same ids in the same order; a moved bookmark with no original of its id stays as it is (never trap on a lookup).
   - **The skips move as one,** as `takeMovedPlaces` moves them: both moved lists stay when `(committed.skippedHeadings ?? []) == moved.skippedHeadings` and `(committed.waitingSkippedHeadings ?? []) == moved.waitingSkippedHeadings`; otherwise both are the original's.
2. **`TextMouth/Models/Book.swift` line 1527:** `private static func isAsStored` becomes `static func isAsStored` (internal). Add one line to its doc saying `MovedPlaces.taken(by:)` uses it too. Change nothing else in Book.swift.
3. **`TextMouth/ViewModels/ContentAnalysisSummaryBuffer.swift` lines 5-38:**
   - `init(committed:movedPlaces:)` keeps `movedPlaces.map { $0.taken(by: committed) }`.
   - Update the docs of the struct, of `movedPlaces`, of the init, and of `apply(to:)`: the row takes only the moves its record took, so a move never wins over a newer write another Mac left in the record; one sentence says why (a moved position is dated at the move, which would make a stale place look newer).

This covers every caller that builds a summary: the cache batch (LibraryViewModel+Migration.swift about 942), the statistics pass (about 530), and Edit Text (`LibraryViewModel+TextEdits.swift`). Do not change the callers.

**Not this task:** the reader's own load (ReaderViewModel.swift). A reader re-dates its position at every open (`savePosition()`), so narrowing there would protect nothing.

## Tests
**Commit 1:** the fix, with these tests.
- **Unit tests,** in `ContentAnalysisSummaryBufferTests` (TextMouthProductionTests/ContentAnalysisSummaryBufferTests.swift), each building places directly (`ReadingPosition`, `Bookmark`, `SkippedHeading`). See how `BookWaitingSkipTests.swift` (about lines 180-280) makes books and moves, and reuse its helpers where they are reachable rather than copy them. A row holding the original places, with a `ContentAnalysisSummary(committed:movedPlaces:)` applied:
  - a. the record took every move: the row takes them all.
  - b. the record holds another Mac's newer position (another place, dated later) and took the bookmark's and the skips' moves: the row keeps its position, equal to the original, and takes the moved bookmark and skips.
  - c. the record took the moves, but holds them as read back from disk, with dates cut to whole seconds (the moved position's `lastUpdated` rounded down): the row still takes them.
  - d. the record holds a bookmark another Mac changed (the same id, another note): that bookmark stays as the row has it; the others move.
  - e. the record holds skips the listener toggled: the row's skips stay as they were.
- **The race end to end,** in `PlaceRelocationAtRebuildTests` (hosted; it has `runCacheBatch(on:)` and `recordedBook(like:)`): `testAMoveNeverWinsOverANewerPositionFromAnotherMac`.
  - Start from `makeBookInAnOlderText(title:)` (PlaceRelocationTestSupport.swift 43).
  - Write into the book's record only, not the row, a newer position, as another Mac would: another place in the older text, its `lastUpdated` a minute after the fixture's. Write it the way the fixture writes the record (PlaceRelocationTestSupport.swift 60-118).
  - Run the cache batch, then check:
    - the record keeps the other Mac's position, compared as stored;
    - the row's position is the fixture's original, not moved, and its `lastUpdated` is older than the record's;
    - the row's and the record's bookmark and skipped heading are the moved ones (`fixture.bookmark`, `fixture.notes`);
    - no copy is left (`snapshotsHoldACopy(of:)`).

**Commit 2:** the two commits of moved places that have no tests of their own (the charter's item).
- **The statistics pass,** in `PlaceRelocationAtRebuildTests`: `testTheStatisticsPassCommitsTheMovedPlaces`.
  - Use `makeBookInAnOlderText`, a model with it (`makeModel(with:)`), and `model.calculateMissingBookStats(then:)` (LibraryViewModel+Migration.swift 444), waited for with an expectation, as `runCacheBatch` waits.
  - Then `assertPlaces(of:areThoseOf:)` on the row and the record, and no copy left.
  - If the pass does not pick the fixture's book (`needsContentAnalysis`), post a question rather than change the fixture.
- **The legacy migration,** in `LegacyBookMigrationTests`: `LegacyBookMigration.buildTextCache(for:)` (LegacyBookMigration.swift 676-705) takes moved places and saves them with the record.
  - Find the path on which it rebuilds a package that already holds a content.md and places, such as a package reused from an interrupted run (`testIdenticalCopyInTheUsualPackageIsReusedAndTheOriginalRemoved`, LegacyBookMigrationTests.swift 83).
  - Test that the moved places reach the record and the book the migration returns.
  - If no path can give `buildTextCache` an older content.md with places, say so in one line of your report instead of forcing it.

**Run:** `ContentAnalysisSummaryBufferTests`, `PlaceRelocationAtRebuildTests`, `PlaceSnapshotRecoveryTests`, `BookWaitingSkipTests`, `LegacyBookMigrationTests`, `CloudMaintenanceStatisticsTests`.

## Do not touch
`ReaderViewModel*.swift`, `LibraryPersistenceService.swift`, `PlaceRelocator.swift`, the summary's callers, `BookTextEditing.swift`, `PlaceRelocationTestSupport.swift` (another task moves helpers into it later), and everything outside the files above.

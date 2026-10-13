# t6d task "recovery": a launch finishes the moves a stop left undone

Slug `t6d-recovery`, branch `t6d/recovery`, board task in your launch prompt. Read `worker-common.md` beside this file first. Two commits, in this order.

## Background
Since the team's "rebuild" task, every rebuild of a book's text that has places to move copies the old content.md aside with the book's places (`PlaceSnapshot`, in `MachineLocalPaths.placeSnapshots`), writes the new text, moves the places (`PlaceSnapshot.movePlaces(to:at:)` → `MovedPlaces`), and commits them with the analysis (`LibraryPersistenceService.saveContentAnalysis(for:index:cacheFormatVersion:movedPlaces:)`), which deletes the copy once written. A crash or a quit between the write and the commit leaves the copy, and the book's record still holds its places at the old text's numbers while content.md holds the new text. The design (TEXT-ANCHORS-ADDENDUM-2026-10-10.md, section 9, step 6): "the next launch finds the copy before the cache batch, moves the book's places from it against the content.md now there, saves them, and deletes it." It must run before any other launch pass reads a book's places or text: the anchor pass (`captureMissingTextAnchors`) would otherwise give a place without words the words standing at its old numbers in the new text.

## Read (by line range)
- `TextMouth/Services/LibraryPersistenceService.swift`: `saveContentAnalysis(…)` and its doc (lines 558-655 as the "rebuild" task left them), `contentChange(from:to:)`, `logDroppedAnalysis`, and `writeBookInfo(_:contentIndex:stored:)` (lines 815-870: with a nil index the package keeps its content index file).
- `TextMouth/Services/PlaceSnapshots.swift`, all: `PlaceSnapshot` (`leftovers()`, `record`, `movePlaces(to:at:)`, `discard()`, and `inUse` with `forgetCopiesInUse()`) and `MovedPlaces`. `leftovers()` neither lists nor removes a copy this run still uses (a rebuild between its copy and its commit), so the pass never races a rebuild; in tests, a stop between a rebuild and its commit is a rebuild whose copy is then forgotten with `PlaceSnapshot.forgetCopiesInUse()`, as a quit forgets it.
- `TextMouth/Models/Book.swift`: `takeMovedPlaces(original:moved:)`.
- `TextMouth/ViewModels/LibraryViewModel+Migration.swift`, lines 540-575: `updateContentCachesAndStatistics(access:then:)`.
- `TextMouth/ViewModels/LibraryViewModel+TextAnchors.swift`, lines 80-200: `captureMissingTextAnchors`, the pass to copy the shape of (a background pass over the rows, books open in a reader and books being edited left for later, the rows updated on the main actor in one change).
- `TextMouth/ViewModels/ContentAnalysisSummaryBuffer.swift`, lines 115-132: `applyAnalysisSummaries`, one change and one save for many rows.
- `TextMouth/Services/MaintenanceFileAccess.swift`: `read(_:_:)` (line 52), `requireOnThisMac(_:reading:)` (line 155), `MaintainedFiles` (lines 297-311: `.textCache` is content.md, `.record` is bookInfo.json).
- `TextMouth/Services/MarkdownCacheService.swift`: `loadFromCache(for:contentIndex:)`, `cacheURL(for:)`.
- Tests: `TextMouthProductionTests/PlaceRelocationTestSupport.swift` (all: `makeBookInAnOlderText(title:)`, `assertPlaces`, the leftover-copy helper, `holdInAnEditSession(_:)`); `PlaceRelocationAtRebuildTests.swift` (its first tests); `CloudMaintenanceTestSupport.swift` lines 64-162; `TextAnchorCaptureLaunchTests.swift` lines 112-135 (books in the cloud, held by an edit, or open, waiting for a later launch).

## Commit 1: "Save a book's moved places alone, as the analysis saves them"
1. `LibraryPersistenceService.saveMovedPlaces(_ movedPlaces: MovedPlaces, for book: Book) throws -> Book?`: merges the moved places into the book's latest durable state exactly as `saveContentAnalysis` merges an analysis (on `bookInfoSaveQueue`; the debounced snapshot waiting for the book if there is one, otherwise the record on disk, never downloaded), each only where that state still holds it as it was (`takeMovedPlaces`).
   - A record only in the cloud: nil, and the copy stays, for a later launch.
   - A record of another book (its ID is not `book.id`): nil, and the copy is discarded.
   - Nothing to change (`takeMovedPlaces` returned false: every place was saved again meanwhile, or is moved already): nothing written, the copy discarded, and the latest state returned.
   - Otherwise it writes the merged book with `writeBookInfo(merged, contentIndex: nil, stored:)` (the package keeps its content index), forgets the queued write and settles a failure as `saveContentAnalysis` does, discards the copy, and returns the merged book. A write that throws keeps the copy and rethrows.
   The source's hash, format, and path do not matter here: the places move between two texts of content.md, whatever source the new one came from.
2. DRY: `saveContentAnalysis` and `saveMovedPlaces` share the reading of the latest durable state (lines 600-628 now: rebasing, the waiting snapshot or the record, the cloud refusal, the book made from the record) and the write-and-settle steps (the write, `cancelQueuedWrites`, `failureCenter.recordSuccess` when a snapshot waited). Move each into one private helper both call; `saveContentAnalysis`'s behavior, logs, and doc stay as they are.
3. Tests, in a new class `PlaceSnapshotRecoveryTests: CloudMaintenanceTestCase` (new file; run xcodegen and commit the project with it):
   - **Saved alone.** The fixture's book (`makeBookInAnOlderText`); `MarkdownCacheService.generateReportedCacheContent(for:)` rebuilds it and returns its `movedPlaces` uncommitted (a stop); `saveMovedPlaces(moved, for: book)`: the record holds the moved places (`assertPlaces`), its `cacheFormatVersion` and content index are as they were, and the copy is gone.
   - **Saved again meanwhile.** Before `saveMovedPlaces`, save the book with another position in its record (`saveBookInfoThrowing()` on a copy with `ReadingPosition(chapterIndex: 0, characterOffset: 3)`): that position stays, the bookmark and the skip move, and the copy is gone.

## Commit 2: "Finish at launch the moves of places a stop left undone"
4. A new file `TextMouth/ViewModels/LibraryViewModel+PlaceSnapshots.swift`: `func finishLeftoverPlaceMoves(access: MaintenanceFileAccess = .live, then completion: (@MainActor @Sendable () -> Void)? = nil)`, documented with the background above.
   - On the main actor it takes the rows (`library.books`) and the books open in a reader (`openBookIDs`); the work runs on `DispatchQueue.global(qos: .utility)`, with `[weak self]` on the way back.
   - For each copy, oldest first (`PlaceSnapshot.leftovers()`):
     - a book no longer in the library: discard the copy;
     - a book open in a reader, or being edited (`BookTextEditSessions.shared.isEditing`): leave the copy for a later launch;
     - otherwise, with content.md and the record on this Mac (`access.requireOnThisMac(row, reading: [.textCache, .record])`), read the text now there (`access.read(MarkdownCacheService.cacheURL(for: row)) { try MarkdownCacheService.loadFromCache(for: row) }`); a refusal, or a text that cannot be read, leaves the copy for a later launch;
     - move: `copy.movePlaces(to: text, at: Date())` (nil: nothing to write, and the copy is gone);
     - save: `LibraryPersistenceService.saveMovedPlaces(moved, for: row)`; when it returns a book, the row takes the moved places too.
   - Back on the main actor: every row with moved places takes them (`takeMovedPlaces(original:moved:)`, each only where the row still holds it as it was) in one change of `library.books` and one `save()`, only when one changed; then `completion`.
   - One debug-log line when it finished any, counts only: `PLACES_RECOVERED: finished N, left M for a later launch` (`DiagnosticLog.event(.storage, …)`), where a copy discarded for a book no longer in the library counts in neither. No line when there were no copies.
5. `updateContentCachesAndStatistics(access:then:)` (lines 552-574) calls `finishLeftoverPlaceMoves(access:)` first and starts the metadata refresh in its completion, with the same `[weak self]` and `completion?()` pattern as the steps after it. Add to its doc: first the moves a stop left undone, before any pass reads a book's places or text.
6. Tests, in `PlaceSnapshotRecoveryTests`:
   - **Finished at launch.** The fixture's book, rebuilt with `generateReportedCacheContent(for:)` and not committed, then `PlaceSnapshot.forgetCopiesInUse()` (the stop: in every test of this commit that stands for one); a model of that book (`makeModel(with:)`); `finishLeftoverPlaceMoves(access: .live)` until its completion: the row and the record hold the moved places, the copy is gone, and one `PLACES_RECOVERED: finished 1, left 0` line is logged.
   - **Through the launch's passes.** The same, but with `updateContentCachesAndStatistics(access: .live)` until its completion: the row and the record hold the moved places, the record's cache version is now current, and no copy of the book is left.
   - **A book no longer in the library.** A model without the book: the copy is gone, and the package's record still holds the fixture's places.
   - **Left for a later launch.** Three fixture books, each rebuilt and not committed: one open in a reader (`model.openBookIDs.insert`), one held by an edit (`holdInAnEditSession`), one whose content.md is only in the cloud (`cloud.markDataless(cacheURL)`, the pass run with `cloud.access`). After the pass each keeps its copy and its row's places; after the hold ends, the book is closed, and the pass runs again with `.live`, each is finished.

## Run
`PlaceSnapshotRecoveryTests`, `PlaceRelocationAtRebuildTests`, `ContentAnalysisMergeTests`, `CacheUpdateTests`, `TextAnchorCaptureLaunchTests`, `MetadataRefreshTests`, `CloudMaintenanceCacheBatchTests`, `CloudMaintenanceStatisticsTests`.

## Do not touch
The reader (`ReaderViewModel*.swift`, the "reader" task runs beside you), `PlaceRelocationAtRebuildTests.swift` and the support file (the reader task appends to the first; post a finding to `t6d-lead` if the support file needs a change), `PlaceSnapshots.swift`, `Book.swift`, `MarkdownCacheService.swift`. Edit only `LibraryPersistenceService.swift`, `LibraryViewModel+Migration.swift` (`updateContentCachesAndStatistics` alone), the two new files, and the project file.

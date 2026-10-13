# t6e-load: places found at every load of a book

- **Slug** `t6e-load`; **branch** `t6e/load`, from `team/t6e`; **board task** given in your prompt.
- Read `worker-common.md` beside this file first, then "The worker's part" of `../teams-common.md`.
- Line numbers are main's at 056e8a90 for the files below; earlier tasks of this team did not change them, except the test files named.

## What and why
At every load of a text book, each saved place is checked directly. One whose saved words are not at its numbers is found by them, and anything left goes to a silent best guess. Moved places are saved as any change is, and their anchors are captured anew. This is the backstop for every path a rebuild does not take: a feed article downloaded again, another Mac's text, an edit saved while TextMouth was closed, anything a rebuild could not finish, and a reader that kept saving at the old text's numbers while a rebuild moved its book's places.

The finding is `PlaceRelocator.relocate(_:within:movedAt:) -> Outcome?`, already on `team/t6e` (`PlaceRelocator.swift`, after `relocate(_:from:to:movedAt:)`). It returns nil when every place stands, after only direct checks. Read its doc, not its body.

## Changes
**Commit 1,** a pure move of test helpers so this team's later tasks share them: `recordedBook(like:)`, `runCacheBatch(on:access:)`, and `openReader(on:in:)` move out of `PlaceRelocationAtRebuildTests` (private) into `PlaceRelocationTestSupport.swift`, as internal methods of `CloudMaintenanceTestCase`, with their bodies and docs unchanged. `PlaceRelocationAtRebuildTests` then uses the shared ones. Run `PlaceRelocationAtRebuildTests`.

**Commit 2,** the move at load:
1. **`ReaderViewModel.LoadedContent` (ReaderViewModel.swift 1172-1195).** `var movedPlaces: MovedPlaces? = nil` becomes `var movedPlaces: [MovedPlaces] = []`: the moves of the book's places to take as it shows, in order. First comes a rebuild's during this load (T06's branch D), already committed to the record; then the check at load's (branch E), which the reader saves as any change is. It is empty when nothing moved. Update the doc. The two tests that build `LoadedContent` without it (IntegrationSleepTimerTests 849, SpeechPreparationCacheTests 772) must still compile unchanged.
2. **`readContent(of:audioTagsFrom:readingTexts:)` (1242-1323).** The settle at 1250-1267 belongs to another task; leave it exactly as it is.
   - Keep branch D's commit (1275-1288) as it is, and put its `analysis.movedPlaces` first in the list.
   - Then, for a text book only (`!format.isAudio`), let the local `book` copy take D's moves (`book.takeMovedPlaces(original:moved:)`), so the check at load reads the places as they now are.
   - Run `PlaceRelocator.relocate(book.relocatablePlaces, within: analysis.content, movedAt: Date())`.
   - When it returns an outcome:
     - when `outcome.counts.anythingMoved`, log `outcome.counts.logLine(title: book.title)` with `DiagnosticLog.event(.storage, …)`, as `PlaceSnapshot.movePlaces` does (PlaceSnapshots.swift 195-212);
     - when `outcome.places != book.relocatablePlaces`, append `MovedPlaces(bookID: book.id, original: book.relocatablePlaces, moved: outcome.places, snapshot: nil)`.
   - Nothing is committed to the record here: the reader takes the moves into the row, which saves the row and the record (`LibraryViewModel.updateBook`, through `takeMovedPlaces(_:)`).
   - This all runs in `readContent`, off the main thread, as `loadContent` and the cloud path (`ReaderViewModel+CloudDownload.swift`) call it, so a large book's places are found off the main thread.
3. **`showLoadedContent(_:readFrom:)` (1344-1421).**
   - Take each move in order (`for moved in loaded.movedPlaces { takeMovedPlaces(moved) }`) where `takeMovedPlaces(loaded.movedPlaces)` is (1361-1365); update that comment to name both branches.
   - The clamp (1367-1378) stays, for places saved without words, which nothing can find without the old text. Update its comment to say a place with saved words was found by them first.
   - `showEditedText` (ReaderViewModel+EditedText.swift 30-41) builds a `LoadedContent` without `movedPlaces`; leave it, since the default compiles.
4. **`takeMovedPlaces(_:)` (ReaderViewModel+SavedPlaces.swift 105-148).** Its doc only: it takes one move of the book's places made while it loaded, a rebuild's (already in the record) or the check at load's (saved now, as any change is, through the row). The body is unchanged.

## Tests (commit 2)
A new file, `TextMouthProductionTests/PlaceRelocationAtLoadTests.swift`, `final class PlaceRelocationAtLoadTests: CloudMaintenanceTestCase` (`xcodegen generate`, with the project committed with it). Use the shared helpers.
- **A fixture,** added to `PlaceRelocationTestSupport.swift` beside `makeBookInAnOlderText`: `makeBookWhoseTextChangedSinceItsPlaces(title:) throws -> BookInAnOlderText`.
  - It is `makeBookInAnOlderText`'s book, with its content.md replaced by `newBytes` and its record (and the row it returns) describing that content.md as current. Commit an analysis of `newText` with `MarkdownCacheService.currentCacheVersion`, through `LibraryPersistenceService.saveContentAnalysis`, and take `committed.contentAnalysisFields` into the returned book. So no load and no batch rebuilds it, as when another Mac or an editor changed the text.
  - Assert in the fixture that no rebuild will happen: `MarkdownCacheService.isCacheOutdated(stored:)` is false, and whatever the analysis service checks before rebuilding (`BookContentAnalysisService.load`) is satisfied. Find that check. If no fixture can avoid a rebuild, post a question.
- **`testPlacesFollowTheirWordsWhenTheTextChangedBetweenOpens`.** Open a reader on the changed book. Its cursor, its bookmarks, and its skipped heading (`isHeadingSkipped(fixture.notes)`, `skippedHeadingIDs`) are at the fixture's places in the new text, and so are the row's and the record's (`assertPlaces`; the position may carry the load's save, so compare its numbers). Exactly one `PLACES_RELOCATED: <title>:` line is logged (`logLineCount`). No copy is made (`snapshotsHoldACopy`).
- **`testAnUnchangedBookMovesNothingAtLoad`.** After the first open moved the places, close the reader. `ReaderViewModel.readContent(of:)`, given the row's book, returns no moves, and a second reader open leaves the row's bookmarks and skips exactly as they were (anchors and all) and logs no second line.
- **`testALargeBooksPlacesAreFoundOffTheMainThread`.**
  - A book of about a million UTF-16 units of distinct sentences, packaged as the fixtures package one.
  - Its position, bookmark, and skip were saved with their words, and then a paragraph was put in before them, with the record describing the new text (as the fixture does).
  - Call `ReaderViewModel.readContent(of:)` from `DispatchQueue.global()`, checking `Thread.isMainThread` is false there, and wait with an expectation.
  - The returned `movedPlaces` holds the found places.
- **`testAReaderThatSavedAtTheOldNumbersDuringARebuildIsCaughtAtTheNextLoad`** (the charter's second item to settle).
  - A reader opens a book whose text is current and holds places, then stays open.
  - The book's text is rebuilt under a changed extraction while it is open: Redo Text Extraction (see `testRedoTextExtractionCommitsTheMovedPlaces` in `PlaceRelocationAtRebuildTests`) or the cache batch, so that branch D moves the places in the row and the record.
  - The open reader then saves its position at the old text's numbers (`reader.savePosition()`), as it would while playing, and the row holds those old numbers.
  - Close it and open a new reader: its cursor is at the position's words in the new text, and so is the row's position.

  Build this from `makeBookInAnOlderText`, with its record first made to describe the older content.md as current so the first reader does not rebuild it.

**Run:** `PlaceRelocationAtLoadTests`, `PlaceRelocationAtRebuildTests`, `PlaceSnapshotRecoveryTests`, `TextAnchorCaptureTests`, `TextAnchorCaptureLaunchTests`, `FinishedBookReaderTests`, `FinishedBooksAtEndMoveTests`, `BookTextEditTests`.

## Do not touch
- The settle in `readContent` (1250-1267).
- `ReaderViewModel+EditedText.swift`, `BookTextEditing.swift`, `PlaceRelocator.swift`, `PlaceSnapshots.swift`, `LibraryPersistenceService.swift`, `ContentAnalysisSummaryBuffer.swift`.

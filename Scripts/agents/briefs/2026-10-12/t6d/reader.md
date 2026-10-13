# t6d task "reader": a reader's own rebuild moves its book's places, and the reader opens at them

Slug `t6d-reader`, branch `t6d/reader`, board task in your launch prompt. Read `worker-common.md` beside this file first. One commit.

## Background
A reader rebuilds its book's text when it opens a book whose text cache is outdated or changed (`ReaderViewModel.readContent(of:)` → `BookContentAnalysisService.load(book:regenerateTextCache:…)` → `MarkdownCacheService.writeCache(for:)`). Since the team's "rebuild" task, that rebuild copies the old text aside, moves the book's saved places to the new text, and returns them as `BookContentAnalysisService.Result.movedPlaces` (`MovedPlaces`: `original`, the places as they were; `moved`, where they are now; and the copy, `snapshot`, deleted by `discardSnapshot()`). The cache batch commits such places with `LibraryPersistenceService.saveContentAnalysis(for:index:cacheFormatVersion:movedPlaces:)`, which merges them into the book's latest record, each only where it still is as it was, and deletes the copy once written. The reader does not commit them yet, so it opens the book at its old numbers in the new text, and the copy stays until the next launch.

This task: the reader's load commits the moved places to the record in the same way, and the reader takes them into its own copy of the book, its cursor, its bookmarks, and the library's row before anything else reads its places (TEXT-ANCHORS-ADDENDUM-2026-10-10.md, section 9: "A reader's own rebuild applies them in `showLoadedContent`"). Moves are silent: nothing is spoken or shown.

## Read (by line range)
- `TextMouth/ViewModels/ReaderViewModel.swift`: the init's restoring of the position, lines 591-600; `LoadedContent`, lines 1172-1190; `loadContent()` and `readContent(of:audioTagsFrom:readingTexts:)`, lines 1192-1303; `finishLoading`, lines 1305-1315; `showLoadedContent(_:readFrom:)`, lines 1317-1395; `savePosition()`, lines 1781-1800.
- `TextMouth/ViewModels/ReaderViewModel+SavedPlaces.swift`, all (170 lines): `noteLoadedTextForAnchors`, `captureMissingAnchorsAtLoad` (the model for updating the row and the reader's copies together), `openingPlace`, `savedGlobalOffset(of:)`.
- `TextMouth/ViewModels/ReaderViewModel+EditedText.swift`, lines 20-45: another caller that builds a `LoadedContent`, which must keep compiling unchanged.
- `TextMouth/ViewModels/LibraryViewModel.swift`, lines 353-362: `updateBook(id:_:)`; `LibraryViewModel+Bookmarks.swift` line 46: `bookmarksForBook(_:)`.
- `TextMouth/Services/LibraryPersistenceService.swift`: `saveContentAnalysis(for:index:cacheFormatVersion:movedPlaces:)` and its doc.
- `TextMouth/Models/Book.swift`: `takeMovedPlaces(original:moved:)` (search for it). `TextMouth/Services/PlaceSnapshots.swift`: `MovedPlaces`.
- Tests: `TextMouthProductionTests/PlaceRelocationTestSupport.swift` (all: the fixture `makeBookInAnOlderText(title:)`, `assertPlaces`, the leftover-copy helper); `PlaceRelocationAtRebuildTests.swift` (its batch test, as the pattern); `HeadingVocabularyTests.swift` lines 211-221 (`makeReader`); `IntegrationTestSupport.swift` lines 104-129 (`openReader`) and 377-395 (`waitForReaderToLoad`); `PerformanceBaselineFixtures.swift` line 287 (`SilentRenderQueue`).

## What to build
1. `LoadedContent` gains `var movedPlaces: MovedPlaces? = nil` (a `var` with a default, so `ReaderViewModel+EditedText.swift`'s `LoadedContent(…)` compiles unchanged), documented: the book's places a rebuild of its text during this load moved, already committed to the book's record, for the reader to take on the main actor.
2. In `readContent(of:…)`, right after `BookContentAnalysisService.load(…)`: when `analysis.movedPlaces` is not nil, commit them with `_ = try? LibraryPersistenceService.saveContentAnalysis(for: book, index: analysis.index, cacheFormatVersion: analysis.cacheFormatVersion, movedPlaces: moved)`. Comment why: the record takes them with the rebuilt text's analysis, each only where it still holds it as it was, and the copy of the old text goes once they are written; when the write fails or is dropped, the copy stays and the next launch finishes the move. Then pass them in the returned `LoadedContent`. `readContent` stays `nonisolated` and runs where it ran.
3. In `showLoadedContent(_:readFrom:)`, right after `audioMetadata = …` (line ~1341) and before "Bring the saved place into the book as loaded": `takeMovedPlaces(loaded.movedPlaces)`, with a comment that the moved places come first so that the opening place, the opened place's anchor (`noteLoadedTextForAnchors`), the anchor capture, and the position the load saves all read the moved ones.
4. In `ReaderViewModel+SavedPlaces.swift`, a new `func takeMovedPlaces(_ movedPlaces: MovedPlaces?)`, in a `// MARK: Places Moved by a Rebuild of the Text` section, documented:
   - nothing for nil, or for an audiobook;
   - first note whether the cursor is at the place the book was saved at: `TextPlace(chapter: currentChapterIndex, offset: currentCharacterOffset)` equal to `movedPlaces.original.position`'s chapter and offset;
   - the library's row: `libraryViewModel.updateBook(id: book.id) { _ = $0.takeMovedPlaces(original:moved:) }`, but only when the row (`libraryViewModel.bookByID(book.id)`) would change, so an unchanged row is not saved again;
   - the reader's own copy: `book.takeMovedPlaces(original:moved:)`;
   - the reader's bookmark list: `bookmarks = libraryViewModel.bookmarksForBook(book.id)`, as `captureMissingAnchorsAtLoad` does;
   - the cursor: when it was at the saved place and the reader's copy took the moved position (`book.readingPosition == movedPlaces.moved.position`), set `currentChapterIndex` and `currentCharacterOffset` to that position's.
   Each guarded take keeps a place the listener saved meanwhile, as the record's did.
5. Nothing else in `showLoadedContent` changes; the clamp to the text stays, for branch E.

## Tests, appended to `PlaceRelocationAtRebuildTests` (no new file)
- **A reader's rebuild.** The fixture's book (`makeBookInAnOlderText(title:)`) in a library model (`makeModel(with:)`); open a reader on it as `HeadingVocabularyTests.makeReader` does, with that model and `SilentRenderQueue()` as its render scheduler if the initializer takes one (see `openReader`), and close it in a teardown block; `waitForReaderToLoad(reader)`. Then:
  - the cursor (`currentChapterIndex`, `currentCharacterOffset`) is at `fixture.position`;
  - `reader.bookmarks` holds the bookmark at `fixture.bookmark`;
  - `reader.isHeadingSkipped(fixture.notes)` is true and `reader.skippedHeadingIDs == [fixture.notes.id]`;
  - the row (`model.bookByID`) and the record (`BookInfo.load(from:)` → `Book(record:…)`) hold the moved places (`assertPlaces`; the row's and record's position may carry the date and anchor of the save the load makes, so compare chapter and offset, as `assertPlaces` does);
  - no copy of the book is left (the support file's helper).
- **A cursor that was not at the saved place keeps its place.** Not testable at load without a race; do not add it. Instead, a direct test of `takeMovedPlaces(_:)` on a loaded reader: after the load above, call it again with a `MovedPlaces` whose `original.position` is the fixture's old position (no longer the reader's): the cursor and `book.readingPosition` do not change, and the row is not saved again (its `readingPosition` is unchanged).

## Run
`PlaceRelocationAtRebuildTests`, `ReadingTextOpenTests`, `BookTextEditTests`, `HeadingVocabularyTests`, `TextAnchorCaptureTests`.

## Do not touch
`LibraryPersistenceService.swift`, `LibraryViewModel+Migration.swift`, `MarkdownCacheService.swift`, `PlaceSnapshots.swift`, `Book.swift`, and the support file (another task, "recovery", runs beside you and uses it; post a finding to `t6d-lead` if it needs a change). Edit only `ReaderViewModel.swift`, `ReaderViewModel+SavedPlaces.swift`, and `PlaceRelocationAtRebuildTests.swift`.

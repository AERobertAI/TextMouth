# t6e-editreader: an open reader follows an edit's moves, and EditedTextCursor retires

- **Slug** `t6e-editreader`; **branch** `t6e/editreader`, from `team/t6e`; **board task** given in your prompt.
- Read `worker-common.md` beside this file first, then "The worker's part" of `../teams-common.md`.
- Line numbers are `team/t6e`'s at 207d0927.

## What and why
Each edit Edit Text takes now moves the book's places in its record and row, from a copy of the text the edit replaced (`BookTextEditSessions`' static `check`). Its `BookTextEdit.movedPlaces` holds the moves the record took (`MovedPlaces`: `original`, `moved`). With a reader open, the reader's own text is the old text, and three things must follow the edit:
- its cursor;
- its own copy of the book's places (its `book`, which it skips by: `skippedHeadingIDs`);
- its bookmark list.

Today the cursor follows by `EditedTextCursor`'s literal 48-character search, which lost 27% to 31% of a long book's places on rewrapped text. The reader's copies do not follow at all. Moves are silent: nothing is spoken or shown.

The pieces exist on `team/t6e`:
- `PlaceRelocator.relocate(_ place: TextPlace, from old: DocumentContent, to new: DocumentContent) -> TextPlace` carries one place by the diff (`PlaceRelocator.swift`, "Places Checked at Every Load"). Read its doc only.
- `takeMovedPlaces(_:)` (`ReaderViewModel+SavedPlaces.swift` 105-150) takes one `MovedPlaces` into the row, the reader's `book`, its bookmark list, and its cursor when the cursor was at the saved place, each only where it still holds the place as it was.
- `noteLoadedTextForAnchors(cacheFormatVersion:)` (same file, 61-83) notes the text the places take their words from.

## Changes
1. **The readers' event carries the moves.**
   - `LibraryBookEvent.textReplaced` (`LibraryBookUpdates.swift` 18, 28, 181-183) gains `movedPlaces: MovedPlaces?`, and `textReplaced(bookID:with:movedPlaces:)` sends it.
   - `LibraryViewModel+TextEdits.swift` line 21 passes `edit.movedPlaces`; update `commitTextEdit`'s doc.
   - `ReaderViewModel+LibraryUpdates.swift` 39-40 passes it to `showEditedText`.
2. **`showEditedText(_:movedPlaces:)` (`ReaderViewModel+EditedText.swift` 25-85),** with `movedPlaces: MovedPlaces? = nil`, so `MediaCommandPlaybackTests` line 784 compiles unchanged:
   - **A load held by an edit** (27-43): `LoadedContent(…, movedPlaces: movedPlaces.map { [$0] } ?? [])`.
   - **A reader still loading** (44-47) keeps the moves with the text. `editedTextWaitingForLoad` (`ReaderViewModel.swift` 442) becomes a small struct of both, documented. `showEditedTextWaitingForLoad()` (87-93) passes both.
   - **A reader that already shows the edited text** (48): take the moves (`takeMovedPlaces(movedPlaces)`, a guarded no-op when it holds them), then return.
   - **Otherwise:**
     - Before anything changes, carry the cursor with `PlaceRelocator.relocate(TextPlace(chapter: currentChapterIndex, offset: currentCharacterOffset), from: current, to: edited)`, in place of `EditedTextCursor.position` (55-60).
     - Stop speech as now, and set `content = edited`.
     - Take the moves (`takeMovedPlaces(movedPlaces)`), then set the cursor to the carried place: the reader's own cursor wins.
     - Call `noteLoadedTextForAnchors(cacheFormatVersion: MarkdownCacheService.currentCacheVersion)`, so the opened place's words, which were the old text's, are let go, or are the moved position's own when the cursor is there.
     - Then everything as now: the sleep timer, `savePosition()`, the refresh, play or prepare.
   - Update the extension's doc (5-13) and the function's.
   - The relocation runs on the main actor, once an edit is taken. It builds a relocator only when the cursor's words do not stand in the edited text: about 20 ms for a novel and 100 to 130 ms for a long book, in optimized code. Say so in a comment.
3. **The settlement carries the edit.**
   - `BookTextEditSettlement.readTaken(Book)` (`BookTextEditing.swift` 110) becomes `readTaken(BookTextEdit)`, and `settlePendingEdit` (381) returns `.readTaken(edit)`. Update both docs.
   - In `readContent` (`ReaderViewModel.swift` 1262-1270), `case .readTaken(let edit)` keeps `book.contentAnalysisFields = edit.committed.contentAnalysisFields`. It also lets the local `book` take `edit.movedPlaces` (`book.takeMovedPlaces(original:moved:)`), so that a rebuild's move and the check at load start from them.
   - The list of moves (1284, `var movedPlaces: [MovedPlaces] = []`) then begins with the edit's moves, before a rebuild's and the check's. Update `LoadedContent.movedPlaces`' doc (1190-1197) to name the three in order.
4. **`EditedTextCursor` retires.**
   - Delete the enum (`ReaderViewModel+EditedText.swift` 105-225).
   - Delete `BookTextEditTests.testTheCursorFollowsItsWords` (684-721) and its helper `position(_:_:_:_:)` (1319-1323). Their cases live on as `PlaceRelocatorAtLoadTests`' cursor tests (the relocate task re-expressed each).
   - **Completion check:** `grep -rn "EditedTextCursor" TextMouth TextMouthProductionTests TextMouthTests` finds nothing.
5. **One shared helper (DRY).** `waitForReaderToLoadYielding` exists twice: a private copy in `BookTextEditTests` (about 1310) and one in an extension of `PlaceRelocationAtLoadTests`. Make it one internal method in `PlaceRelocationTestSupport.swift`'s "Shared Test Helpers" (`extension XCTestCase`), with the clearer doc of the two, and delete both copies.

## Tests (hosted)
Add them to `BookTextEditTests`, in a new section `// MARK: - An Open Reader Follows an Edit (T06's branch E)` after "Places Moved by Each Edit Taken". Reuse that section's helpers (places saved with their words, sessions) and `openReader`/`waitForReaderToLoad…`.
- **A reader open and paused at its saved place.** The edit puts a paragraph before the cursor, a bookmark, and a skipped heading. Then:
  - the reader's cursor is at its words in the edited text;
  - its `bookmarks` and `skippedHeadingIDs` (`isHeadingSkipped`) follow;
  - the row and the record agree;
  - the position the reader saves next keeps the edited text's words at the cursor (`row.readingPosition?.anchor` equals `edited.anchor(at:measuredIn:)` there).
- **A cursor moved past the saved place without saving,** as while playing (set `currentCharacterOffset`): it follows its own words, and the position saved after the edit is the cursor's.
- **An edit taken while a reader loads,** through the settle: see `testAReaderOpeningBeforeTheEditIsTakenReadsTheEdit` (205). The reader opens on the edited text with its cursor, bookmarks, and skip at their moved places.
- **An edit saved while TextMouth was closed, with no session's copy** (the edittake task's `testAnEditSavedWhileClosedWithNoCopyLeavesThePlaces` shows the setup). After the launch pass, a reader's open moves the places by their saved words, and the row then holds them.

**Run:** `BookTextEditTests`, `MediaCommandPlaybackTests`, `PlaceRelocationAtLoadTests`, `PlaceRelocatorAtLoadTests`, `TranscriptEditTests`, `TextAnchorCaptureTests`.

## Do not touch
- `PlaceRelocator.swift`, `PlaceSnapshots.swift`, `LibraryPersistenceService.swift`.
- The static `check` and `settleEditSavedWhileClosed` in `BookTextEditing.swift`: only the settlement's enum and `settlePendingEdit` are yours there.

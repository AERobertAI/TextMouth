# t6e-edittake: each edit taken moves the book's places

- **Slug** `t6e-edittake`; **branch** `t6e/edittake`, from `team/t6e`; **board task** given in your prompt.
- Read `worker-common.md` beside this file first, then "The worker's part" of `../teams-common.md`.
- Line numbers are `team/t6e`'s at cfd635c2.

## What and why
An Edit Text session now keeps the text its edits replace: `Session.oldText`, a `PlaceSnapshot` in `MachineLocalPaths.editTextSnapshots`. It is kept at the session's start and replaced by exactly the bytes taken at each take (`BookTextEdit.textAside`, `putOldText`). Read `BookTextEditing.swift` 170-350 and 400-440 first.

This task moves the book's places at each edit taken, by branch D's diff, from that copy to the edited text. It does the same for an edit saved while TextMouth was closed, from the copy a quit left. Moves are silent.

## Changes
1. **The static `check(_:against:access:readingTexts:keepingTextAside:)` (696-806)** gains `placesFrom oldText: PlaceSnapshot? = nil`. In the text book's adopt path, after the parse (760) and before the commit (770-780):
   - `let original = book.relocatablePlaces`.
   - The copy is used only when it is the text the places were saved in: its bytes (`oldText.textBytes()`) have the digest of the baseline's cache (`access.hasher.digestOfData(…) == baseline.cache.digest`), the content.md TextMouth last took or wrote. Any other copy, or one that cannot be read, moves nothing, with one debug-log line, `PLACES_NOT_MOVED: <title>: its earlier text was not kept as its places knew it` (title only; never text).
   - Skip the move when `!book.holdsPlacesToMove`.
   - Move with `PlaceRelocator.relocate(original, from: { parsed old text }, to: <the edited text as parsed>, movedAt: Date())`. Parse the copy's bytes as `oldText()` does: add `PlaceSnapshot.oldText(from bytes: Data)` and have `oldText()` call it, so the bytes are read once.
   - When `outcome.counts.anythingMoved`, log `outcome.counts.logLine(title: book.title)` (`DiagnosticLog.event(.storage, …)`). When `outcome.places != original`, make `MovedPlaces(bookID: book.id, original: original, moved: outcome.places, snapshot: nil)`.
   - Commit it with the analysis: `saveContentAnalysis(for:index:cacheFormatVersion:movedPlaces:)`, which takes each place only where the record still holds it as it was.
   - Return `BookTextEdit.movedPlaces = moved?.taken(by: committed)`.
   - Transcript edits move nothing.
   - Update the function's doc.
2. **Instance `check(_:)` (400-440)** passes `placesFrom:` the session's copy as it is then. Read it inside the lock, as the baseline is read at 406.
3. **`settleEditSavedWhileClosed(of:access:)` (549-557)**, inside its storage work:
   - Find the newest leftover copy of the book: `PlaceSnapshot.leftovers(in: MachineLocalPaths.editTextSnapshots)`, filtered to `record.bookID == book.id`, the last of them. A copy is a leftover only when no session of this run uses it.
   - Pass it as `placesFrom:`. The baseline there is the record's fingerprint, the text TextMouth last took or wrote, so the digest rule above holds.
   - After any check that found something other than `.inCloud`, discard every leftover copy of that book: the session it served is over.
   - Update the doc.
4. **`LibraryViewModel+Migration.swift`:**
   - `editSavedWhileClosed(of:access:)` (961-975) passes `edit.movedPlaces` to `ContentAnalysisSummary(committed:movedPlaces:)`.
   - **The sweep.** When the launch's cache batch ends, in `extractMissingContentCaches` (618-640, the `rebuildTextCaches` completion), discard every leftover in `editTextSnapshots` (`PlaceSnapshot.leftovers(in:)`, which skips copies this run's sessions use). Do it on a utility queue, then call `completion` back on the main actor, so a caller that waits for the pass finds them gone. A copy a quit left for a book with nothing saved since is no use once the pass has looked.
   - Say both in the docs.
5. **`LibraryViewModel+TextEdits.swift` line 17:** `ContentAnalysisSummary(committed: edit.committed, movedPlaces: edit.movedPlaces)`, so the row takes the moves the record took. Line 20, the readers' event, belongs to a later task: leave it.

## Tests
Add them to `BookTextEditTests`, in a new section `// MARK: - Places Moved by Each Edit Taken (T06's branch E)`, after the section "The Session's Copy of Its Old Text". Reuse that section's helpers and the file's doubles. Each places a position, a bookmark, and a skipped heading after the text the edit puts in, with their words (as a reader would save them: anchors captured in the text, `DocumentContent.anchor(at:measuredIn:)`).
- **An edit taken with no reader open** puts a paragraph before every place. The row's and the record's position, bookmark, and skipped heading follow their words. One `PLACES_RELOCATED` line is logged.
- **A second edit in the same session** moves them again, from the first edit's text.
- **A copy that is not the text the places were saved in** moves nothing. Overwrite the copy's `content.md` with other bytes before the edit is saved. The places stay as they were, and `PLACES_NOT_MOVED` is logged.
- **An edit saved while TextMouth was closed, with the session's copy.**
  - Stand in for the copy a quit leaves: `PlaceSnapshot.keep(textAt:record:in: MachineLocalPaths.editTextSnapshots)` of the book's content.md, then `PlaceSnapshot.forgetCopiesInUse()`.
  - Save the edit, and run the launch's cache pass, as `testAnEditSavedWhileClosedIsTakenAtLaunch` (512) does.
  - The edit is taken, the places follow their words in the row and the record, and the copy is gone.
- **The same with no copy:** the edit is taken, and the places stay where they were saved. A reader's next load moves them by their saved words; a later task tests that.
- **The sweep:** a leftover copy of a book whose content.md is unchanged is gone after the pass, and the copy of a session begun in this run is kept.

**Run:** `BookTextEditTests`, `TranscriptEditTests`, `PlaceSnapshotTests`, `PlaceSnapshotRecoveryTests`, `PlaceRelocationAtRebuildTests`, `TextAnchorCaptureLaunchTests`.

## Do not touch
- `ReaderViewModel*.swift`, `LibraryBookUpdates.swift`, `PlaceRelocator.swift`.
- The settlement (`BookTextEditSettlement`, `settlePendingEdit`) and line 20 of `LibraryViewModel+TextEdits.swift`: a later task changes them.
- `PlaceRelocationTestSupport.swift`, which another task is changing now.

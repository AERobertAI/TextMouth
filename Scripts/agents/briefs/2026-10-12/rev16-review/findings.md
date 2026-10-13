# REV16: findings of the independent review of T06's branches D and E

On October 13, 2026, a read-only Opus reviewer (`rev16`, brief `../rev16.md`) reviewed the app code of T06's branch D (merge 112bb7b3) and branch E (merge cf542090). It found four problems: one medium-high, one low-to-medium, and two low. The first three were reproduced by hosted tests. Their sources are `probes.swift.txt` and `probes2.swift.txt` beside this file, and their runs are `test1.log` and `test2.log`; a probe goes into a test target to run. The reviewer could not write this file itself, so the orchestrator wrote it from the reviewer's report.

## F1 (medium-high): at load, a removed section's skip moves to another section, which is then skipped and saved
- **Where:**
  - `PlaceRelocator.swift` about lines 1462 to 1475 (`headingResultAtLoad`), called about line 1326.
  - It asks `TextAnchorFinder.findHeading` (about lines 308 to 321) and accepts anything not marked a guess.
- **What goes wrong:** two weak matches are taken as proof: a score made only from the words before the heading, and the only heading with the skip's label, with no matching words at all. This is the risk the TODO recorded after branch C (#2091): "branch E's load path must not use it as it stands". Branch E did not guard it.
- **Reproduced at load, where the rebuild path correctly makes the skip wait in each case:**
  - **Two "Notes" sections, the first removed:** the skip names the second "Notes" (score 17).
  - **"Pump Repairs" removed before "Soup":** the skip moves to "Soup" (score 12, all from the words before the heading).
  - **Chapter I's "Notes" removed:** the skip goes to chapter II's "Notes", by its label alone.
- **End to end:** in a real book, the reader, the library row, and the record all come to skip "Soup", which the listener never skipped.
- **Worse than before:** before branch E, a skip whose ID named no heading skipped nothing, so in three of the four cases branch E makes it worse.
- **When it happens:** whenever the text changed without the rebuild's move:
  - an edit saved with no usable copy;
  - a feed article downloaded again;
  - an older build on another Mac;
  - a rebuild whose old text could not be read;
  - case C5 below.
- **Should:** at load, a skip whose heading does not stand names another heading only on proof: its saved words after the heading agree there. Never on a label alone, nor on a score from the words before it alone. Otherwise it waits, kept in `waitingSkippedHeadings`, as at a rebuild.

## C1 (low to medium): the launch's recovery gives the library row moves its record refused
- **Where:** `LibraryViewModel+PlaceSnapshots.swift` about lines 161 to 168 and 178 to 191. The result of `saveMovedPlaces` (about line 163) is ignored, and the moves are not narrowed with `MovedPlaces.taken(by:)`, as the batch's and Edit Text's paths narrow them.
- **Reproduced:** another Mac's position (0,3) was written to the record only. After `finishLeftoverPlaceMoves`, the record keeps (0,3), but the row takes the moved (0,102), dated at the move.
- **Should:** a row takes only the moves its record took, as branch E states for every other path.

## C5 (low): a stop between the batch's record commit and the row's update loses the moves
- **Where:** `LibraryViewModel+Migration.swift` about lines 916 to 923. The next launch's recovery rebuilds only the analysis fields, not the moved places. `ContentAnalysisSummaryBuffer.swift` about line 61 says a lost summary "is not lost work", which is no longer true.
- **Reproduced:**
  - After the launch passes, the row is at cache version 3.0.7 but holds the old places (0,168), (0,214), and `0-243-2-Notes`, a heading ID the new text does not have.
  - The next write of the row copies those into the record, over the moved (0,102), (0,148), and `0-177-2-Notes`.
- **How likely:** the window is about a second per book, and the next open usually finds the position and bookmark again by their words. F1 then puts the skip at risk.
- **Should:** a lost summary's moved places reach the row, or the row never writes stale places over the record's moved ones.

## S1 (low; plain in the code, not run): the launch's sweep deletes Edit Text copies the in-cloud check said to keep
- **Where:**
  - `BookTextEditing.swift` about lines 583 to 588 keeps a book's copies when its content.md is only in the cloud.
  - `sweepLeftoverEditTexts` (`LibraryViewModel+Migration.swift` about lines 641 and 967) then deletes every unused leftover anyway.
- **Effect:** the later edit is taken with no copy, so its places fall back to the saved-words search, and its skips to F1's risk.
- **Should:** the sweep keeps a copy for a book whose content.md is only in the cloud.

## Checked and found sound
- **The guarded takes** (`takeMovedPlaces`, `isAsStored`, `taken(by:)`): dates rounded to the second, duplicate bookmark IDs, and skips moved as one.
- **The commits:** the batch's, Redo Text Extraction's, and the statistics pass's, where a place saved meanwhile wins.
- **The copies:** the snapshot's order of writing and its crash steps, the in-use guard on leftover listings, recovery oldest first, and copies kept on this Mac only.
- **Edit Text's copy:** its digest check, and its replace and discard rules.
- **Crash safety:** no force unwraps or unguarded subscripts in the new app code.
- **Cost:** launch and open costs are minor, and the load check runs off the main thread.
- **Two windows on one book:** reasoned through, not tested.

## Already recorded, now confirmed
A rebuild during an Edit Text session moves no places. A session lasts until quit, so this covers every book opened in Edit Text during that run.

# Team t6d: T06's branch D, places moved when TextMouth rebuilds a book's text

Team `t6d`; lead `t6d-lead`; team branch `team/t6d`; workers' branches `t6d/<task>`. Read `teams-common.md` beside this file first.

## What it is
T06 makes a book's saved places follow their text when the text is read anew. Branches A, B, and C are merged:
- **Branch A:** text anchors, the saved words around each place, and `TextAnchorFinder`, the saved-words search.
- **Branch B:** the anchors are captured at every save, at load, and at launch.
- **Branch C:** `PlaceRelocator`, the pure diff relocator, fixed by REV15 on October 12 (merge 7f23cc06).

Nothing calls the relocator yet. Branch D wires it into every rebuild of a book's text.

The design is the user's idea, measured and settled in `TEXT-ANCHORS-ADDENDUM-2026-10-10.md`. Read these parts of it in full; they are the specification:
- section 9, "The design, revised" (lines 238 to 290), above all "When TextMouth rebuilds a book's text";
- section 10's branch D (lines 313 to 317).

Its section 11 says the user's answers settle the design. Moves are silent, with no announcement and no list (the user's answer to question 2); best guesses are silent too; and the debug log gets the one `PLACES_RELOCATED` line.

## What branch D adds (the addendum's list)
1. **The copy aside.** Every rebuild goes through `MarkdownCacheService.writeCache(for:)`. When the book holds a place to move (a position past its start, a bookmark, or a skipped heading) and its old content.md is on this Mac, `writeCache` copies the old content.md aside, with the book's places as they are, into `MachineLocalPaths.placeSnapshots`. That folder is new, belongs to this Mac (beside Working Copies), and is never in the package. On the startup disk the copy is a clone.
2. **The move.** After the rebuild, `PlaceRelocator(old:new:)` moves the places from the copy to the new text: `relocate(_:movedAt:)`, with the current date.
3. **The guarded commit.** The moved places are committed with the analysis (`LibraryPersistenceService.saveContentAnalysis`), each only if it is still as it was at step 1, so a place saved meanwhile wins. The row takes them through the batch's summary, and a reader's own rebuild applies them in `showLoadedContent`.
4. **The copy is deleted** once the record holds the moved places.
5. **Recovery.** After a crash or a quit between the rebuild and the commit, the next launch finds the copy before the cache batch, moves the places from it against the content.md now there, saves them, and deletes the copy.
6. **The log.** One `PLACES_RELOCATED` line a book when anything moved (`PlaceRelocator.Counts.logLine(title:)`), counts only.
7. **Left alone:** a book in the cloud that is not downloaded, and a book held by an edit session.

## Fix these first: what REV15 left for branch D
From the TODO's "Still open after T06's branch C merge" and "Still open after the REV15 fixes merge" lines (lines 3118 and 3119; read both):
- **A skip that waits must name no heading.** The relocator leaves a waiting skip exactly as it was, with its saved ID (`SkippedHeading.id`, "<chapter>-<offset>-<level>-<label>"). When the next section of the same label and level slides into a removed section's numbers, the new heading has exactly that ID, and the reader would skip it. Store a waiting skip so that it names no heading, and make it apply again only when a later move finds its heading. Older builds read `skippedHeadingIDs` alone, so a waiting skip must be absent from them; that is safe, because for an older build its section simply plays. Pin it with a test that goes from the relocator's outcome through the stored book to the reader's set of skipped heading IDs.
- **Write by `places`, not counts.** `PlaceRelocator.Counts.anythingMoved` is false when only a position's offset in the whole book, or an anchor, changed, so decide whether to write by comparing `places`.
- **Write moved skips with `Book.setSkippedHeadings(_:)`,** which keeps the two lists in step.
- **Mind the eager work.** The relocator builds both texts' word indexes even when every place stays: check each place's anchor directly first, and build a relocator only for a book whose places do not all stand.

## Where to look
- `MarkdownCacheService.writeCache(for:)` and its callers:
  - the launch's cache batch, `updateContentCachesAndStatistics`;
  - Redo Text Extraction;
  - the reader's rebuild of an outdated or changed cache;
  - the legacy migration;
  - an EPUB whose title was written into its file.
- `LibraryPersistenceService.saveContentAnalysis`, `MachineLocalPaths`, and the reader's `showLoadedContent`.
- `Book.skippedHeadings`, `Book.skippedHeadingIDs`, and `setSkippedHeadings(_:)`.
- `PlaceRelocator.swift`'s `Places`, `Outcome`, and `relocate(_:movedAt:)`.

## Tests (hosted), from the addendum
- A rebuild under a changed extraction moves the position, a bookmark, and a skipped heading, in the row and in the record.
- A place saved meanwhile is kept.
- A copy left by a stop between writing and saving is finished at launch.
- A book in the cloud and a book held by an edit are left alone.
- Redo Text Extraction moves places.
- A book with no place makes no copy, and the copy is deleted.
- The waiting skip, as above.

## How to split it
This is the user's data, so plan the order with care.
- **The waiting-skip storage and its test** are first, and small.
- **The copy aside and `MachineLocalPaths.placeSnapshots`** can go to a worker.
- **The core** is the move, the guarded commit, and the recovery. You may keep a delicate core task for yourself rather than give it to a worker. If you do, say so and why in your report: the user wants to learn where Sonnet needs help.

The addendum puts the size at about 350 lines, with 550 lines of tests.

## Not this team's
- **Branch E:** the move at every load, and Edit Text's moves. `showLoadedContent`'s clamp stays for E, except where D's reader rebuild must apply moved places.
- **The polish team's files:** check `bbs claims` before you plan, and again before each launch.
- **`.claude/skills/agent-bbs/`.**

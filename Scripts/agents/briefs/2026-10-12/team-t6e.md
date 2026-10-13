# Team t6e: T06's branch E, places moved at every load and by Edit Text

Team `t6e`; lead `t6e-lead`; team branch `team/t6e`; workers' branches `t6e/<task>`. Read `teams-common.md` beside this file first.

## What it is
T06 makes a book's saved places (reading position, bookmarks, skipped headings) follow their text when the text is read anew.
- **Merged already:** branches A, B, C (the pure `PlaceRelocator`, fixed by REV15), and D: the move at every rebuild of the text cache, merged early on October 13. The TODO's entry is "T06's branch D: places moved when TextMouth rebuilds a book's text".
- **Branch E,** this team's, is the last: the move at every load, and Edit Text's moves.

The design is the user's, settled in `TEXT-ANCHORS-ADDENDUM-2026-10-10.md`. Read these parts of it in full:
- section 9's "Edit Text", "At every load", "Best guesses, silently", and "Skipped headings" (from line 262);
- section 10's branch E (line 319).

Moves are silent, with no announcement and no list (the user's answer to question 2), and best guesses are silent too.

## What branch E adds (the addendum's list)
1. **At every load,** in place of today's clamp in the reader's `showLoadedContent`: each place is checked directly. One whose saved words are not at its numbers is found by them (`TextAnchorFinder`), and anything left goes to a silent best guess. Moved places are saved as any change is, and their anchors are captured anew. This covers every path the rebuild does not: a feed article downloaded again, another Mac's text, an edit saved while TextMouth was closed with no copy, and anything a rebuild could not finish.
2. **Edit Text:**
   - When an edit session begins (find where `BookTextEditSessions` starts one), keep a copy of content.md aside as the session's old text, the way branch D's `PlaceSnapshot` does.
   - At each edit taken, move the book's places, bookmarks, and skipped headings from that copy to the edited text by the same diff. With a reader open, its own text is the old text, and its cursor moves too (`ReaderViewModel+EditedText.swift`'s `showEditedText`). Then the copy is replaced by the edited text, for the next save.
   - When the session ends with nothing left to take, delete the copy. When TextMouth quits during a session, the copy stays, so an edit saved while TextMouth was closed is moved from it at launch, when the cache pass takes the edit (`settleEditSavedWhileClosed(of:access:)`). With no copy, the move at load (item 1) moves it.
3. **`EditedTextCursor` retires,** its tests moved to the relocator. Its literal 48-character search lost 27% to 31% of pride.txt's places on rewrapped text.

## Settle these first
Branch D left them; they are in the TODO's "Still open after T06's branch D merge" line, which you should read:
- **The cloud race.** In a library in the cloud, the row and the record take moves separately, so a record newer than this Mac's row (another Mac's write) could lose to the row's moved position, dated at the move, when the row is next written (`ContentAnalysisSummaryBuffer.swift`). Find how the row and the record are reconciled today (the S05 merge of analysis with the latest durable state), and make a move never win over a newer write from another Mac. Pin it with a test. If the right answer needs the user, stop and report the question instead.
- **A reader open while a rebuild moves its book's places** goes on saving places at the old numbers. Item 1 is the backstop; make sure it covers this case, and test it.
- **Tests for the statistics pass's and the legacy migration's commits** of moved places (`LibraryViewModel+Migration.swift`'s `commitStatistics`, `LegacyBookMigration.swift`).

## Tests (hosted), from the addendum
- content.md changed between two opens: the position, the bookmarks, and a skipped heading follow;
- an edit taken with a reader open, and without one;
- an edit saved while TextMouth was closed, with the session's copy and without it;
- an unchanged book writes nothing;
- a large book's places found off the main thread;
- the items under "Settle these first".

## How to split it
The user's data again, so plan the order with care, as the t6d lead did. The addendum puts the size at about 400 lines, with 600 lines of tests. Reuse branch D's pieces (`PlaceSnapshot`, `Book.takeMovedPlaces(original:moved:)`, `PlaceRelocator.relocate(_:from:to:movedAt:)`) rather than restating them.

## Not this team's
- **The polish3 team's files:** check `bbs claims` before you plan and before each launch.
- **`.claude/skills/agent-bbs/`.**

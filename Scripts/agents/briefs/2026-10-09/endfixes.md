# Task brief: endfixes — REV14's reader findings: the one-time move's dates, Go to Time's Return, and the book's end

Slug `endfixes`; branch `fix/rev14-reader-findings`, from main. Read `common.md` beside this file first; the normal usage rule applies: read only "5-hour session" and "Weekly (all models)", ignore "Weekly (Fable)", and stop with a report below 10% left. Use main's latest suite count as your baseline. **Item 1 changes the user's data at their next first launch of main; land it first and keep this branch small.**

## Where these come from
A read-only reviewer (REV14's `reviewend`) read P07 (57d04ab9), P08 (50cdd78c), A11, T06's branch A, and the Where Am I? move fixes. Line numbers are main's at 743a34ff. Read the bookends and recordingtime agents' notes in `AGENT-NOTES-2026-10-04.md` first. The user's installed app is the October 7 build, so none of this has reached their library yet.

## Items, one commit each, each with its test
1. **The one-time move of finished books marks every book it moves as just opened** (bug, confirmed). `LibraryViewModel+Migration.swift` about 1649 calls `persistReadingPosition`, which reaches `Library.swift` about 312 (`books[index].lastOpened = Date()`), and the record write (`LibraryViewModel+BookOperations.swift` about 674) carries the new date.
   - On the user's first launch, 26 rows and records would get today as `lastOpened`, overwriting the real dates for good.
   - Recently Opened would then list 10 finished books, the Last Opened sort and Speak Info's "Last opened" would say today for all 26, and the four unfinished books among today's ten would drop out.
   - Give the move a path that saves the place without touching `lastOpened` (for example `markingOpened: false` through `persistReadingPosition` and `Library.updateReadingPosition`), in the row and the record.
   - Give `FinishedBooksAtEndMoveTests`' fixture books a `lastOpened` and assert it is unchanged after the move, row and record. Check every other caller of the move's save path for the same mistake.
2. **If the stats file cannot be read, the move is recorded as made with nothing moved** (risk). `LibraryViewModel+Migration.swift` about 1552-1566 and `ReadingStatsService.swift` about 217-218. When reading_stats.json fails to decode, the service stands in empty statistics without setting either "await" flag, so no book is a candidate and the per-Mac flag is set, and the move never runs once the file is repaired. Record the move only when the statistics were actually read from the file; test it.
3. **Go to Time's Return on its unchanged starting value moves the place** (bug, confirmed). `ReaderViewModel+Jump.swift` about 139-143 drops the fraction of a second from the starting text, and about 44-58 jumps; see also `ReaderJumpPanels.swift` about 109 and 228.
   - With the place at 2:13:05.7 the field starts at "2:13:05", and Return moves an audiobook back 0.7 s, a text book back up to about 8 words, or onto a heading starting in that second.
   - It also records a Return position, says "Jumped to…", restarts a playing text book's speech, and un-finishes a finished book (the field shows "9:41:07" for an end at 9:41:07.4).
   - Go to Percent has done the same since before P08 (up to 0.05% of the book).
   - When a panel's text equals its starting text, Return closes the panel without jumping or announcing a jump, for both panels.
   - Test with places that are not on a whole second or a whole tenth of a percent. `testTheDesignsBookStaysPutAtEverySpeed` passes only because its place sits on a whole second.
4. **The Headings sheet's Duration for the last heading shown is one unit short** (bug, confirmed). `HeadingNavigatorView.swift` about 461: `location(forGlobalOffset: total)` returns the last chapter's length less one (`BookContentIndex.swift` about 85-87), so a last chapter ending on a whole second shows a second less (25:03.0 as 25:02). End at the clock's length when no later heading is shown; add a fixture chapter that ends on a whole second.
5. **Continue to Next Book in a folder passes through finished books one window at a time** (risk). `LibraryViewModel+SortAndOrder.swift` about 136-145, and `playFromTheEnd()`. Finishing book A opens B, and if B is finished its automatic Play goes straight on to C, opening one reader window per finished book; after the first launch 26 more books rest finished. The hand-over passes over finished books (`Book.restsAtEnd`), as the reading list's "Skip finished books" does; say what happens when every later book is finished.

## Not yours
`showLoadedContent`'s clamp of a past-the-end place (REV14 finding 2, board #2028) belongs to `anchorcapture` (T06's branch B), whose brief already moves such a place to its chapter's end, and a finished book to its end. `anchorcapture` also edits `Library.swift` (`addBookmark`, just below `updateReadingPosition`), `LibraryViewModel+BookOperations.swift` (`updateSkippedHeadings`), and the launch pass. Post a notice on the board before you edit those files, keep to your functions, and expect adjacent-line conflicts. `placediff` adds new files only.

## Verify or report as unverified
Say exactly what the user's first launch of main now does to their 26 finished books' rows and records (counts only from `~/.TextMouth`, never content). Live VoiceOver is unverified. Report the README and ARCHITECTURE wording and the TODO sentence.

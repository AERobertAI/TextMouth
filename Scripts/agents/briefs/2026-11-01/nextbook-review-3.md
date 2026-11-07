# Brief `nextbook-review-3` (November 1, 2026): the held sleep timer

You are `nextbook-review-3` (Opus), an independent reviewer. The branch `feature/nextbook-window` has had two outside reviews, and its author has now finished a second fix round. That round replaced the sleep timer's hand-over with a new design: the shared timer service holds the timer for the next book. No reviewer has read this design yet. You check the round's fixes and review the new code for correctness bugs. You change no code: you read, trace, and report.

## Rules

- **Never read, copy, or write anything under `~/.TextMouth`**, the user's live library.
- Do not build or run tests. The Mac has 8 GB, and builds go only through the orchestrator's build train.
- Change and commit nothing in the repository.
- Never push, merge, or install.
- Every `rm` takes literal paths.

## The code

- **The branch:** base main e3cf97a1, tip c113b75f, 29 commits.
- **The fix range:** `git diff 2a7903f1..c113b75f`, 6 commits, about 1,100 lines added in 27 files. Commit 2a7903f1 is review 2's tip 3d574c2f, rebased.
- **Getting it:** your worktree starts on main. Check out the tip detached: `git checkout --detach c113b75f`.
- **The design note:** `NEXTBOOK-WINDOW-RESEARCH-2026-11-01.md`. Its section "The sleep timer goes on with the book" describes the held timer.
- **Earlier reports,** with line numbers at their own tips:
  - `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/nextbook/review-1.md`;
  - `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/nextbook/review-2.md`, findings N1 to N10, which this round fixes.
- The full suite passed at c113b75f: 9265 tests, 75 skipped, 0 failures. Passing tests are not the question. The question is whether the code is right.

## The rule the code must keep

The user's words, November 1: "the sleeping timer in particular I would like to move still running to the new book without a new window opening."

- **What goes on.** When listening goes on from one book to another, a running sleep timer goes on with it, still running, and its countdown is never restarted. The ways listening goes on: a book's end going on, Next and Previous in Reading List, and Next and Previous in Folder. The reader that takes the book adopts the timer before anything plays, in this window or a new one.
- **The hold.** The timer is held for the next book from the moment the move is announced until a reader of that book adopts it. The old reader's `close()` never stops a held timer.
- **Release.** The hold is released, stopping the timer, on every path that knows the book will not open. The release says "Sleep timer cancelled, because the next book could not be opened." after current speech. The twenty-minute deadline is only a last resort.
- **Running out first.** A timer that runs out, or begins to fade out, before the next book takes it ends listening, and the next book does not start.
- **A second move before the first book loads.** It passes the hold on, and counts that book as playing. Next then Previous asks once.
- **Question 13 (built; the user has not answered yet).** Next or Previous during the timer's fade ends the fade and the timer, as the listener's own Pause does. The book moved to starts. "Sleep timer cancelled, because you moved to another book while it faded out." follows "Starting: <title>", after current speech.
- **Question 14 (built; the user has not answered yet).** An End of heading or End of book timer set after a book has ended goes on with the next book. Only a timer that this book's end spends ends listening there.

## What to check

1. **Review 2's findings.** For each of N1 to N10:
   - Is its failure scenario now closed?
   - Did the fix bring a new problem?
2. **The held timer.** The files are:
   - `SleepTimerService.swift`, from "Held for the Next Book" on, and `noteExpiry()`;
   - `ReaderViewModel+SleepTimerHandOver.swift`;
   - `ReaderViewModel+BookMoves.swift`;
   - `showNextBook` in `ReaderViewModel+NextBookWindow.swift`;
   - `close()` and the end of the load in `ReaderViewModel.swift`;
   - the release paths in `ReaderViewModel+CloudDownload.swift`, `ReaderRequestStore.swift` (`ReaderOpenRefusal`), and `BookReaderWindowView.swift`.

   Trace each of these:
   - **Owners.** Exactly one owner at every moment. The timer never pauses, fades, or ends a book it does not belong to. No release, drop, or deadline ever stops a timer other than the one held, such as one the listener started or restarted during the hold.
   - **The hold's whole life.** Every way a hold ends: adopted, released, dropped, run out, stopped, replaced by `start`, passed on, or the deadline. Does any state stay stale and change a later, unrelated open, Play, or move? Check `expiredWhileHeldBookID`, `askedBookID`, `lastExpiry`, `moveAnnouncedAt`, `pendingMovePlays`, `pendingMoveGeneration`, and `windowAwaitingFocusAfterLoad`.
   - **The deadline.** Is it safe against a reader that is merely slow, such as a large book still downloading from iCloud after twenty minutes? What is said then, and does that book later play without a timer?
   - **Each release.** Is "Sleep timer cancelled, because the next book could not be opened." true every time it is said? Look at the listener closing the target's window while it loads, the Library refusing the open, and a deleted book's placeholder. Is it said once, after the reason the book did not open?
   - **The placeholder release.** How often is `BookReaderWindowView.makeReader` evaluated for one window? Can `bookByID` return nil for a book that exists, as at launch, while the library moves, or while it is unavailable?
   - **The order.** The take at the end of a load (`consumeExpiredWhileHeld`, `isAsked`, the fade, `adoptHeld`, then the autoplay claim). The ask in `showNextBook` (the run-out check, the fade, `holdSleepTimer`, `markAsked`, then the window rule). Follow both for a book already open and loaded, one open and still loading, a new window, this window, and the busy fallback.
   - **Running out.** At each moment between the announcement and the take: what plays, and what is said? The "since" checks compare `Date()` values. Can a change of the clock, or two events with the same time, defeat them?
   - **Restart Sleep Timer.** What do the media gesture and `lastOwnerID` do while a timer is held?
3. **Two moves in quick succession** (N2). Check:
   - Next then Next, and Next then Previous;
   - a folder move then a reading-list move;
   - a playing book, and one only opened;
   - a second move made from the target's reader while it loads or downloads from iCloud.

   In each case, which book plays, and who owns the timer at the end?
4. **The fade (question 13).** Is the sentence said only when the move's pause ended a fade, after "Starting:", and never when nothing was cancelled?
5. **Question 14 (N5) and N6.**
   - A heading or book timer set after the end goes on, and stops at the next book's end or heading.
   - A timer this end spends still ends listening.
   - Play on a finished book, from the reading list and from a folder.
   - A finished book that starts over with an End of heading timer.
6. **Focus after a switch (N7), in `SwitchedWindowFocus.swift`.**
   - Two attempts 0.5 seconds apart: can VoiceOver read the play button twice, when the first attempt takes effect late or the button's own trigger runs late?
   - Does focus ever move in a newly opened window, in another window, or in another app?
   - What happens when the switched book fails to load?
7. **The tests.** Do the new tests drive the real paths? Check N1 through a load slower than a request's 30-second lifetime, N3 through the real `close()`, and N2 through two real commands. Does any test trap, play sound, record, decode Ogg, touch `UserDefaults.standard`, or reach the live library? Is any timing-dependent test likely to be flaky?
8. **Repetition.** The user holds strictly to DRY. Flag any logic copied rather than shared, such as `SwitchedWindowFocus`'s attempt beside `postFocusNotifications` in `VoiceOverFocus.swift`.

## Report

Return the report as your final message, at most 90 lines. Also write it to `build/orchestrator/nextbook/review-3.md` inside your own worktree; the orchestrator copies it.

- **Review 2's findings:** one line each, closed or not, with the commit.
- **New findings:** most severe first, numbered V1, V2, and so on. For each:
  - severity;
  - `file:line` at c113b75f;
  - the failure, as concrete steps leading to a wrong result;
  - CONFIRMED or PLAUSIBLE;
  - the fix, and the test that would catch it.
- **Checked and sound:** one line for each item above that you traced and found sound.
- **Questions for the user,** if any.

# Brief `nextbook-verify-5` (November 1, 2026): the fifth fix round of the held sleep timer

You are `nextbook-verify-5` (Sonnet), an independent verifier. The branch `feature/nextbook-window` lets a reader window go on to the next book in place. The shared sleep timer service holds a running timer for the next book until that book's reader takes it. A verifier found five problems in the fourth fix round, X1 to X5, and the branch's author has fixed them. You check that each fix does what was decided, and that the round brought no new problem. You change no code: you read, trace, and report.

## Rules

- **Never read, copy, or write anything under `~/.TextMouth`**, the user's live library.
- Do not build or run tests. The Mac has 8 GB, and builds go only through the orchestrator's build train.
- Change and commit nothing in the repository.
- Never push, merge, or install.
- Every `rm` takes literal paths.

## The code

- **The fix range:** `git diff 1a760bab..362a3217`. That is 3 commits: about 240 lines of code and 180 of tests in 9 files.
- **Getting it:** your worktree starts on main. Check out the tip detached: `git checkout --detach 362a3217`.
- **The design note:** `NEXTBOOK-WINDOW-RESEARCH-2026-11-01.md`, section "The sleep timer goes on with the book".
- **The findings,** with line numbers at 1a760bab: `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/nextbook/verify-4.md`. Read it first. The earlier reports (`review-3.md`, `verify-3.md`) are beside it.
- The full suite runs on the tip in parallel with you. Passing tests are not the question. The question is whether the code is right.

## The rule the code must keep

The user's words, November 1: "the sleeping timer in particular I would like to move still running to the new book without a new window opening."

- When listening goes on to another book, a running sleep timer goes on with it, still running.
- The timer is held for the next book from the move's announcement until that book's reader takes it, before anything plays.
- A timer that runs out, or begins to fade out, before the take ends listening, and the next book does not start. A restart by the listener changes that. So does a move, which ends the fade and the timer (question 13).
- The timer always has exactly one owner. A book that plays after a move has the timer, unless the listener cancelled or replaced it, or a move ended its fade.

## What was decided for each finding

1. **X1, the user's question 17** (built as recommended; the user has not answered yet). The last move wins until its book has started.
   - A move stays this reader's until its book's reader claims the request to play it.
   - A later move from the same reader cancels it within that span:
     - it discards the request, so that book opens without playing;
     - it undoes the move's hold, asked or not, unless that book has taken the timer;
     - it counts the book as playing;
     - it goes on as any move.
   - Once the book has claimed its request, a later move from the old window is an ordinary move from a book that is not playing.
2. **X2.** Undoing a move consumes the cancelled book's run-out mark.
3. **X3.** Undoing a move always restores the state before it, even while the timer fades out: it is a return, not a new carry. A move ends a fade of any timer it carries, its own or one held for its book: the fade and the timer end, the book moved to starts, and "Sleep timer cancelled, because you moved to another book while it faded out." follows. `BookMoveStart.timerFadeEnded` is true exactly when the move ended a fade.
4. **X4.** The missing tests are added, and the test that asserted after the cancel is corrected.
5. **X5.** The four repetitions are shared.

## What to check

1. **Each finding.** Is each of X1 to X5 closed, as decided above? Did the fix bring a new problem?
2. **`askedMove`** (`underWayAskedMove()`, `cancelAskedMoveUnderWay()`).
   - Is it right for every way an asked move ends? Check:
     - the request claimed;
     - the request dropped by a reader that could not load;
     - the request lapsed;
     - the reader closed;
     - the window switched in place;
     - an "Opening" move, which makes no request to play.
   - Check a second move from the old window:
     - with A New Window, and with the busy fallback;
     - with a book that plays and one only opened;
     - with a timer and without;
     - with a target still downloading from iCloud;
     - with a book open in another window and brought forward.
   - The ask also makes other requests for the book, such as the reading list's (`readingListRequests`). When a later move discards the request to play, is anything else left that B's reader acts on as it loads? Is anything said for B?
   - Do the end-of-book hand-over and Play's path to it (`playGoesToTheHandOver()`) agree with `askedMove`?
3. **`passOnHold(returning:)`.** It skips `isCarriable`'s check of the fade, given `isActive && ownerID == owner`. Can a return give a hold back after the listener restarted, cancelled, or replaced the timer, or after it ran out?
4. **The fade at a move.** In `beginMoveToAnotherBook()`, `fadingHeldForThisBook` stops the timer.
   - What is said, and in what order: "Starting: <title>", then the fade sentence?
   - Can the sentence be said when no fade was ended, or be missed when one was?
   - Check a target still loading, and the old reader with a hold it undid.
5. **The expiry, for every timer.** `sleepTimerRanOut(for:)` replaced the reader's `announceToVoiceOver` in the expiry handler of every timer, not only a held one. Check:
   - the same priority;
   - the same `lastAnnouncement`;
   - the same order after the pause;
   - said exactly once, whether the reader is alive or gone.
6. **`endFade()`.** `stop()` and `cancelFadeForRestart()` now share it. Does `stop()` behave exactly as before? Check the order of its state changes against the fade callback, `isCountdownPausedByPlayback`, and `remainingSeconds`.
7. **The tests.**
   - Does each new test drive the real path?
   - Is a timing-dependent test likely to be flaky?
   - Does any test trap, play sound, record, decode Ogg through Apple's frameworks, touch `UserDefaults.standard`, or reach the live library?
8. **Repetition.** The user holds strictly to DRY ("don't repeat yourself"). Flag any logic copied rather than shared.

## Report

Return the report as your final message, at most 45 lines. Also write it to `build/orchestrator/nextbook/verify-5.md` inside your own worktree; the orchestrator copies it.

- **X1 to X5:** one line each, closed or not, with the commit.
- **New findings,** most severe first, numbered Y1, Y2, and so on. For each, give:
  - its severity;
  - `file:line` at 362a3217;
  - the failure, as concrete steps;
  - CONFIRMED or PLAUSIBLE;
  - the fix, and the test that would catch it.
- **Checked and sound:** one line for each item above that you traced and found sound.
- **Questions for the user,** if any.

# Brief `nextbook-verify-3` (November 1, 2026): the third fix round of the held sleep timer

You are `nextbook-verify-3` (Sonnet), an independent verifier. The branch `feature/nextbook-window` lets a reader window go on to the next book in place. The shared sleep timer service holds a running timer for the next book until that book's reader takes it. A third outside review found ten problems in that hold, V1 to V10, and the branch's author has fixed them. You check that each fix does what was decided, and that the round brought no new problem. You change no code: you read, trace, and report.

## Rules

- **Never read, copy, or write anything under `~/.TextMouth`**, the user's live library.
- Do not build or run tests. The Mac has 8 GB, and builds go only through the orchestrator's build train.
- Change and commit nothing in the repository.
- Never push, merge, or install.
- Every `rm` takes literal paths.

## The code

- **The branch:** base main a6085f57, tip d6aa063f, 38 commits.
- **The fix range:** `git diff ddcebc71..d6aa063f`, 8 commits, about 390 lines of code and 410 of tests in 18 files. Commit ddcebc71 is review 3's tip c113b75f, rebased.
- **Getting it:** your worktree starts on main. Check out the tip detached: `git checkout --detach d6aa063f`.
- **The design note:** `NEXTBOOK-WINDOW-RESEARCH-2026-11-01.md`, section "The sleep timer goes on with the book".
- **The third review**, with line numbers at c113b75f: `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/nextbook/review-3.md`. Read it first.
- The full suite passed at d6aa063f: 9278 tests, 75 skipped, 0 failures. Passing tests are not the question. The question is whether the code is right.

## The rule the code must keep

The user's words, November 1: "the sleeping timer in particular I would like to move still running to the new book without a new window opening."

- When listening goes on to another book, a running sleep timer goes on with it, still running, and its countdown is never restarted by the move. The ways listening goes on are a book's end going on, Next and Previous in Reading List, and Next and Previous in Folder.
- The timer is held for the next book from the move's announcement until that book's reader takes it, before anything plays.
- A timer that runs out, or begins to fade out, before the take ends listening, and the next book does not start.
- The timer always has exactly one owner, and never pauses, fades, or ends a book it does not belong to.

## What was decided for each finding

1. **V1.** A reader that exists for the held book is opening it, and keeps the hold alive however long its download takes. The twenty-minute deadline acts only when no reader exists for the book.
2. **V2 and V4.** Every move starts with one shared step, the folder command's download branch included. A later move:
   - cancels an earlier move that has not asked yet, the end-of-book hand-over included;
   - counts the book as playing when the cancelled move, or an episode wait, was to play;
   - ends any episode wait;
   - says the fade sentence when its pause ended a fade.

   The hold made in `showNextBook` never replaces a hold made for another book.
3. **V3.** Restart Sleep Timer during a hold, whichever reader it reaches, restarts a minutes countdown at its full duration, keeps the hold and the owner, and resumes no reader.
4. **V5 and V6.**
   - V5: closing the old reader during a held fade has the same result as not closing it. The fade runs out, the expiry is said once, and the next book does not start.
   - V6: a release and the silent cancel clear the run-out mark for their book.
5. **V7 and the user's question 15** (built as recommended; the user has not answered yet).
   - Closing the next book's window while it loads stops the timer without a word, as closing the window a timer belongs to does.
   - "Sleep timer cancelled, because the next book could not be opened." is said only when that is true, and after the reason the book did not open.
6. **V8.** A counter that only goes up replaces the wall-clock stamps. The run-out check at the ask runs only for a move that carried a timer. The episode wait still catches a timer set during the wait.
7. **V9.** The switched window posts focus only when the play button's own trigger did not, and never after the trigger posted.
8. **V10.**
   - The repeated code from the review is shared, and the four stale comments are fixed.
   - The placeholder test uses its own stores.
9. **Question 16** (built as recommended; the user has not answered yet). A second Next within the half second goes to the same book as the first.

## What to check

1. **Each finding.** Is V1 to V10's failure scenario now closed, as decided above? Did the fix bring a new problem?
2. **A hold left with no ask.** Say a move has announced and holds the timer for book B, then is cancelled before it asks by a folder command that takes the download branch. What becomes of the hold for B:
   - while the episode downloads;
   - if the download fails;
   - if the listener closes the window during the wait;
   - if the listener plays the old book instead;
   - if the timer runs out?

   What is said, and when? Can `showNextBook`'s `!sleepTimerService.isHolding` guard skip holding for a book because a hold for another book is left over?
3. **The deadline and the count of readers.**
   - Is `noteReaderGone(forBook:)` reached for every reader `noteReaderExists(forBook:)` counted? Check a window closed, a window switched in place, a placeholder, and any reader made and never shown. A count that never comes down keeps the deadline from ever acting for that book.
   - Can a reader exist for the held book that will never take the timer, because nothing will ask for that book? Then the hold lasts until the timer itself ends. What happens if the old reader closes, if the listener plays in another window, and when the timer runs out?
   - `readersByBook` sits beside `LibraryViewModel.openBookIDs` (`registerOpenBook`, `unregisterOpenBook`). Is this a second registry of open books? Could one serve both, and do the two ever disagree?
4. **`restartHeld()`.** Does setting `remainingSeconds` restart a minutes countdown correctly? Check:
   - whether it is the countdown's only source of truth;
   - a countdown halted by the old reader's pause;
   - the fade's lead;
   - what the sleep timer sheet shows;
   - anything saved, and the log.

   What does the listener hear from the media gesture and the keyboard shortcut (`restartOrStartLastSleepTimer()`), and from the sheet's Reset Timer? What happens when the restart reaches a third window, which has nothing to do with the move?
5. **A held fade that runs out after the old reader closed (V5).**
   - Who says the expiry once that reader has closed, and is it said exactly once?
   - Is anything left stale afterwards: the owner, the hold, `lastOwnerID`, or the run-out mark?
   - Does any closure keep the closed reader alive?
6. **The delayed sentence.** The timer stops at once, and "could not be opened" comes 3 seconds later.
   - Can something in those 3 seconds make the sentence false or confusing, such as a new timer started, the window closed, or another release?
   - Can it be said twice for one book, for example a cloud failure followed by a load failure, or a failure followed by a close?
7. **The cancel and Play.**
   - `NextBookHandOver.cancel()` makes `hasAskedForNextBook` true though nothing was asked, and `isPendingAsk` is its exact negation. Is every reader of either right after a cancel, such as `playGoesToTheHandOver()` and `isUnderWay`?
   - What plays when Play reaches the old reader in the half second after a command, or after a cancelled hand-over?
   - `handOverToNextBook` also cancels pending moves. If a book reaches its end in the half second after a command, which move wins, and is the listener's command lost?
8. **`episodeWaitPlays`.** Is it right for every way a wait begins and ends: arrival, failure, close, a new wait replacing an old one, and a cancel?
9. **The counter (V8).** `moveExpiryMark` is set only for a move that carries a timer, and the episode wait's mark always. Does any path now pass nil where a mark is needed, or the reverse?
10. **Focus (V9), in `SwitchedWindowFocus.swift` and `VoiceOverFocus.swift`.**
    - Is the count always noted before the play button's trigger can post?
    - Does it go up only when the trigger really posts, and not when it skips because another window is key or no element was found?
    - `focusPosts` is keyed by `ObjectIdentifier(window)` and never pruned. Is that harmless?
11. **The tests.**
    - Does each new test drive the real path? Check V1's shortened deadline with a reader waiting in a fake download, the slow load past a request's 30-second lifetime, each of V4's four cases, and V5 through the real `close()`.
    - Is any timing-dependent test likely to be flaky?
    - Does any test trap, play sound, record, decode Ogg through Apple's frameworks, touch `UserDefaults.standard`, or reach the live library?
12. **Repetition.** The user holds strictly to DRY ("don't repeat yourself"). Flag any logic copied rather than shared. Candidates:
    - `hasAskedForNextBook` and `isPendingAsk`;
    - `releaseHeld` and `cancelHeld`;
    - the two announcement branches in `releaseHeld`.

## Report

Return the report as your final message, at most 60 lines. Also write it to `build/orchestrator/nextbook/verify-3.md` inside your own worktree; the orchestrator copies it.

- **V1 to V10:** one line each: closed or not, with the commit.
- **New findings:** most severe first, numbered W1, W2, and so on. For each, give:
  - severity;
  - `file:line` at d6aa063f;
  - the failure, as concrete steps leading to a wrong result;
  - CONFIRMED or PLAUSIBLE;
  - the fix, and the test that would catch it.
- **Checked and sound:** one line for each item above that you traced and found sound.
- **Questions for the user,** if any.

# Brief `nextbook-verify-4` (November 1, 2026): the fourth fix round of the held sleep timer

You are `nextbook-verify-4` (Sonnet), an independent verifier. The branch `feature/nextbook-window` lets a reader window go on to the next book in place. The shared sleep timer service holds a running timer for the next book until that book's reader takes it. A verifier found eight problems in the third fix round, W1 to W8, and the branch's author has fixed them. You check that each fix does what was decided, and that the round brought no new problem. You change no code: you read, trace, and report.

## Rules

- **Never read, copy, or write anything under `~/.TextMouth`**, the user's live library.
- Do not build or run tests. The Mac has 8 GB, and builds go only through the orchestrator's build train.
- Change and commit nothing in the repository.
- Never push, merge, or install.
- Every `rm` takes literal paths.

## The code

- **The branch:** base main 3c26cdca, tip 1a760bab, 44 commits.
- **The fix range:** `git diff 476fe83f..1a760bab`, 7 commits, about 250 lines of code and 420 of tests in 14 files. Commit 476fe83f is the third round's tip d6aa063f, rebased.
- **Getting it:** your worktree starts on main. Check out the tip detached: `git checkout --detach 1a760bab`.
- **The design note:** `NEXTBOOK-WINDOW-RESEARCH-2026-11-01.md`, section "The sleep timer goes on with the book".
- **The findings,** with line numbers at d6aa063f: `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/nextbook/verify-3.md`. Read it first. The earlier rounds' reports are beside it: `review-3.md` holds V1 to V10.
- The full suite runs on the tip in parallel with you. Passing tests are not the question. The question is whether the code is right.

## The rule the code must keep

The user's words, November 1: "the sleeping timer in particular I would like to move still running to the new book without a new window opening."

- When listening goes on to another book, a running sleep timer goes on with it, still running.
- The timer is held for the next book from the move's announcement until that book's reader takes it, before anything plays.
- A timer that runs out, or begins to fade out, before the take ends listening, and the next book does not start. Only a restart by the listener changes that.
- The timer always has exactly one owner. A book that plays after a move has the timer, unless the listener cancelled or replaced it.

## What was decided for each finding

1. **W1.** A move cancelled before it asks leaves no trace.
   - `cancelPendingMoves()` undoes the hold the cancelled move made, if that hold is still in place.
   - The timer becomes this reader's own again, or held again for this reader's own book, asked as before.
   - The move's notes (`moveCarriesSleepTimer`, `moveExpiryMark`) are forgotten.
   - The cancelling move then holds as any move does.
   - The folder download branch holds nothing, and the wait's own move carries the timer when the episode arrives.
2. **W2.** A Pause reaching the old reader during a held fade leaves the fade to run out, as closing that reader does. The expiry's own pause still stops the timer. A move's own pause still ends a fade (the user's question 13), because W1 undoes the move's hold before that pause.
3. **W3.** Restart Sleep Timer during a held fade is the listener saying they are awake. It cancels the fade and restores the old reader's volume. The countdown starts again at full duration, and the hold and the owner are kept. No reader resumes, and "Timer reset." is said. The next book then takes the timer and plays as its move said.
4. **W4.** The delayed "Sleep timer cancelled, because the next book could not be opened." is said only if no timer has been started or held since the release.
5. **W5.** The expiry sentence is said even when the handler's reader is gone.
6. **W6 and the registry.**
   - There is one registry of open readers, the library's. `registerOpenBook` and `unregisterOpenBook` count readers per book.
   - The hold's deadline asks the registry through a check the reader gives the service. The service does not know `LibraryViewModel`, and nothing is wired globally.
   - Close's silent cancel acts only when no reader of the book is left.
7. **W7.**
   - Only one of `hasAskedForNextBook` and `isPendingAsk` remains.
   - `releaseHeld` and `cancelHeld` share one stop.
   - The pass-through `cancelSleepTimerHeld` is gone.
   - The stale comment is fixed.
8. **W8.** The missing tests are added.

## What to check

1. **Each finding.** Is each of W1 to W8 closed, as decided above? Did the fix bring a new problem?
2. **A second move from the old window.** With A New Window, or the busy fallback, the old window stays open. A first move has asked for its book, and that book is still loading, held and asked. The listener then makes a second move from the old window to a different book. `holdSleepTimer` may hold again for the new book, since the old reader still owns the timer, while the first book keeps its request to play. Check:
   - which book plays;
   - which book has the timer;
   - whether a book ever plays without it.
3. **`pendingMoveHold`.** Is it cleared on every way a move ends:
   - asked;
   - dropped at the run-out check;
   - cancelled;
   - the reader closed;
   - the hold replaced by another reader's move, or ended by a timer the listener started or cancelled?

   A stale note must never undo a later hold. Also check the `.passedOn` undo:
   - `passOnHold` re-arms the deadline and clears `askedBookID` and `expiredWhileHeldBookID`, and then `markAsked` follows. Can the undo lose a run-out mark, or make a reader take a timer it should not?
   - Are the two guards (`isHeld(forBook:)`, `!isAsked(forBook:)`) enough?
4. **The restart during a held fade.** `cancelFadeForRestart()` bumps `generation` and halts the countdown (`isCountdownPausedByPlayback`) until the taker plays.
   - Is the countdown resumed on every way the taker plays: autoplay at its load, and a move that only opened it, followed by Play?
   - If no reader ever takes it (a release, the deadline, a close), is anything left halted, or is the old reader's volume left low?
   - What else reads `generation`: the countdown's tick, the fade's steps, `pendingFadeCompletion`? Does the bump strand any of them?
5. **The Pause during a held fade.** `pause()` now reaches its countdown branch, whose `pauseCountdown` ignores a fade. For an old reader that is paused already, check:
   - speech (`speechService.pause()` against `pauseForSleepTimerFadeCompletion()`);
   - the audio book's volume;
   - Now Playing;
   - the pause sound.

   Then check the expiry's own pause that follows.
6. **The delayed sentence.** Does every start and every hold change `holdGeneration`? Check a timer started and then cancelled within the 3 seconds, and a release with no delay.
7. **The registry.**
   - Does anything other than the two functions write `openBookIDs` or `openReaderCounts`, in the app or in tests? Can the two disagree?
   - Is the close's new order safe: the unregister, then the silent cancel?
8. **The tests.** For each new test:
   - Does it drive the real path?
   - Is a timing-dependent test likely to be flaky?
   - Does any test trap, play sound, record, decode Ogg through Apple's frameworks, touch `UserDefaults.standard`, or reach the live library?
9. **Repetition.** The user holds strictly to DRY ("don't repeat yourself"). Flag any logic copied rather than shared.

## Report

Return the report as your final message, at most 50 lines. Also write it to `build/orchestrator/nextbook/verify-4.md` inside your own worktree; the orchestrator copies it.

- **W1 to W8:** one line each: closed or not, with the commit.
- **New findings,** most severe first, numbered X1, X2, and so on. For each, give:
  - its severity;
  - `file:line` at 1a760bab;
  - the failure, as concrete steps;
  - CONFIRMED or PLAUSIBLE;
  - the fix, and the test that would catch it.
- **Checked and sound:** one line for each item above that you traced and found sound.
- **Questions for the user,** if any.

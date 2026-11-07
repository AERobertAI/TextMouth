# Brief `nextbook-review-2` (November 1, 2026): the fix round and the sleep timer

You are `nextbook-review-2` (Opus), an independent reviewer. The branch `feature/nextbook-window` had an outside review (round 1), and its author then made a fix round. The fix round also built three answers the user gave meanwhile. You check the fixes and review the new code for correctness bugs. You change no code: you read, trace, and report.

## Rules

The rules of the first review hold, as written in the "Rules" section of `Scripts/agents/briefs/2026-11-01/nextbook-review.md`. In short:
- **Never read, copy, or write anything under `~/.TextMouth`**, the user's live library.
- Do not build or run tests.
- Change and commit nothing.
- Never push, merge, or install.
- Every `rm` takes literal paths.

## The code

- **The branch:** base main 3f25633e, tip 3d574c2f. It was rebased since round 1, so round 1's tip 1d1c8790 is now 3f5ca4cb in content.
- **The fix range:** `git diff 3f5ca4cb..3d574c2f`, 15 commits, about 1,950 lines in 31 files.
- **Getting it:** your worktree starts on main. Check out the tip detached: `git checkout --detach 3d574c2f`.
- **The design note:** `NEXTBOOK-WINDOW-RESEARCH-2026-11-01.md`, now 83 lines with the fix round's sections.
- **Round 1's report:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/nextbook/review-1.md`, findings R1 to R10, its line numbers at 1d1c8790.
- The full suite passed at 3d574c2f: 9250 tests, 75 skipped, 0 failures. Passing tests are not the question; whether the code is right is.

## The user's answers that the fix round built

Their words, November 1: "yes for all 3, the sleeping timer in particular I would like to move still running to the new book without a new window opening." They said yes to these:

- **Next in Folder's direction.** "In a feed set to play upward, should Next in Folder go up the list?" Next in Folder now goes the way the end of the book would go on, and Previous in Folder the other way. "Next" and "previous" in what is spoken follow the command, and "after it" and "before it" follow the way looked.
- **The dimmed choice.** "When a feed or folder's own window choice is dimmed, should Next and Previous in Folder still ignore it?" Unchanged.
- **The sleep timer.** "Should a running sleep timer move with the window to the next book?" The rule the author was given:
  - When listening goes on from a book to another (the end of a book going on, Next and Previous in Reading List, Next and Previous in Folder), a sleep timer the old reader owns and is running goes on with it, still running. The countdown is never restarted. The reader that takes over adopts it before anything plays, in this window or a new one.
  - A minutes timer therefore no longer keeps the next book from starting.
  - A timer set for the end of the heading or the book that runs out at the book's end is spent there, and ends listening as before.
  - If the timer runs out before the next book takes it, the next book does not start.
  - If no reader ever takes it, it must not count down toward pausing nothing.

  The author's report adds:
  - a fading timer is not handed over: the command's pause ends the fade as the listener's own Pause does;
  - a timer no reader takes is stopped, and the listener hears "Sleep timer cancelled, because the next book could not be opened."

## What to check

1. **Round 1's findings.** For each of R1 to R10:
   - Is its failure scenario now closed?
   - Did the fix bring a new problem?

   Give R6 particular care. `SwitchedWindowFocus.swift` and `WindowSwitchRequests.swift` must never take focus from another window or app, never move focus in a newly opened window, and never make VoiceOver say anything twice.
2. **The sleep timer hand-over.** The files are:
   - `SleepTimerService.swift`, its new change of owner;
   - `SleepTimerHandOverRequests.swift`;
   - `ReaderViewModel+SleepTimerHandOver.swift`;
   - `ReaderViewModel+BookMoves.swift`;
   - the Playback, EpisodeDownload, and ReaderViewModel changes.

   Trace each of these:
   - **Owners.** Exactly one owner at every moment. Never no owner while a book that should play is playing. The timer never pauses, fades, or ends a book it does not belong to, and never runs twice.
   - **The old reader closing.** The old reader's `close()` leaves a handed-over timer running, and stops one it still owns.
   - **Adopting it.** The new reader adopts the timer before it plays: in this window, in a new window, through the busy fallback, and when the next book is already open in another window that is brought forward.
   - **Running out before the take.** In the half second after "Starting:", during an episode's download, and while a slow book loads, nothing starts, and what is said is right.
   - **No taker.** When no reader ever takes the timer, how is that known? Is the decision safe against a reader that is merely slow? Is "Sleep timer cancelled, because the next book could not be opened." said only when true?
   - **The fade.** A timer fading out at a move, at the end of a book and from a command.
   - **Heading and book timers.** A heading or book timer moved mid-book by a command: does it apply in the new book as the rule says?
   - **Restarting it.** Restart Sleep Timer, its media gesture, `lastOwnerID`, and `forgetLastOwner` after a hand-over.
   - **What the listener sees.** The new reader's timer status and sheet show the running timer and its time left.
   - **Timers started mid-move.** A timer started during an episode's wait, or between the announcement and the ask.
   - **Back and forth.** Two moves in quick succession: Next then Next again, or Next then Previous, before the first move's book has loaded.
3. **Next in Folder's direction.** It is in `114f3f5f`. Does the direction come from this book's own end rule in every case?
   - A book with its own end-of-book choice.
   - A folder or feed playing up or down.
   - Stop, and the global setting.
   - A book read from the reading list, whose folder is used.

   Check the spoken sentences against the rule above.
4. **The shared move.** `6492bf24` is `ReaderViewModel+BookMoves.swift`. Check that it leaves Next and Previous in Reading List's behavior and words exactly as they were, apart from the sleep timer's intended change.
5. **The tests.** Do the new tests exercise the real paths? Does any test trap, play sound, record, decode Ogg, touch `UserDefaults.standard`, or reach the live library? Is any timing-dependent test likely to be flaky?
6. **Repetition.** The user holds strictly to DRY. Flag any logic copied rather than shared.

## Report

Return the report as your final message, at most 90 lines. Also write it to `build/orchestrator/nextbook/review-2.md` inside your own worktree; the orchestrator copies it.

- **Round 1's findings:** one line each, closed or not, with the commit.
- **New findings:** most severe first, numbered N1, N2, and so on, in round 1's form:
  - severity;
  - `file:line` at 3d574c2f;
  - the failure, as concrete steps leading to a wrong result;
  - CONFIRMED or PLAUSIBLE;
  - the fix, and the test that would catch it.
- **Checked and sound:** one line for each item above that you traced and found sound.
- **Questions for the user,** if any.

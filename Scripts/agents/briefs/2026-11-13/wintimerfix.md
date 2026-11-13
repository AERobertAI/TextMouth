# The fix round of `feature/window-sleep-timer` (November 13, 2026)

You are `wintimerfix`, a Sonnet worker. You fix what the Opus review of the per-window sleep timer asked for, on its branch. First read `common.md` beside this brief and follow it, and `wintimer.md` beside it for the user's words.

## Start

- In your worktree: `git switch feature/window-sleep-timer`, check `git log -1 --format=%h` prints `d26c76a5c`, then rebase onto local main (`git rebase main`): main has moved to 0.4.7 and may hold the Leading articles merge. Keep both sides of any adjacent-line conflict (expect `ReaderViewModel.swift`, `LibraryViewModel.swift`, `ReaderOpenRefusal`, the shortcut and config fixtures); settle a `project.pbxproj` conflict with `make generate`. Its lead has finished and its folder is gone.
- Read in the main checkout (`/Users/roberteggleston/programming/ai/claude/swift/TextMouth/`): the review, `build/orchestrator/nov13/wintimer-review.md` (findings 1 to 5, the eight answers, "Not settled"); the report, `build/orchestrator/nov13/wintimer-report.md`; the design, `WINDOW-SLEEP-TIMER-DESIGN-2026-11-13.md` on the branch.

## The work, one commit each, each with a test that fails without it

1. **Finding 1, the registry lets go too early** (`SleepTimerService.swift:1097-1105, 632-639, 853-856`, `SleepTimerRegistry.swift:78-80`, `ReaderViewModel+SleepTimerHandOver.swift:276`). Keep the run-out mark (`expiredWhileHeldBookID`) in the registry, keyed by book, so it outlives the timer; keep retaining a timer while it fades or owes a sentence (release it in `stop()` and when its fade ends, not in `clearHold()`); capture the timer strongly in `stopHeld`'s 3-second closure. Replace `testTheRegistryKeepsAHeldTimerAliveUntilItsHoldEnds`'s release assertion with the new rule, and add the review's test: a timer only the registry references (`weak var` in the test) that runs out or fades while held: `consumeExpiredWhileHeld(forBook:)` is true for the next reader, and the expiry is said once.
2. **Finding 2, the "next book could not be opened" sentence across windows** (`SleepTimerService.swift:866-869`): `announceNoBook` checks a registry-wide count of starts, holds, and takes, so a timer started in another window during the delay (for instance a Restart in the new window) keeps the sentence from being said. Test with the second timer in another window.
3. **Finding 3, the three unpinned routings** (`IntegrationSleepTimerTests.swift:1333-1375`, `WindowSleepTimerTests.swift:541-615`): the fallback with no source window and no Now Playing owner; a gesture with no window focused (readers attached to windows that are not key); and the menu command posted for real (not only `WindowCommandRouting.shouldAccept` and `sheet(for:)` called directly).
4. **Finding 4, false comments** (`SleepTimerService.swift:399-400, 124-125, 529-530`): Cancel stops only its window's timer and the one coming to it; `take` is the take, not `adoptHeld`.
5. **Finding 5, if it stays small** (`BookReaderWindowView.swift:20`): the window's `@StateObject` subscribes `ReaderWindowContent` to its timer, so every tick re-runs the window's body and `BookReaderWindowView.init` (with a linear `library.books.first { $0.id == id }`). Keep the timer in a holder that publishes nothing (the reader and the sheet observe the timer itself), and pin it with `ViewBodyCounter` (the window's body doesn't run on a tick). If it grows past a commit, describe it in the report instead.

Leave "Not settled" for the report.

## Finish

`make typecheck-tests REF=<commit>` before each train (always), then one last train with the areas `playback-end,windows` and every class you touched, plus `WindowSleepTimerTests`, `SleepTimerRegistryTests`, `IntegrationSleepTimerTests`, `NextBookWindowReaderTests`, `EndBehaviorMatrixTests`, `WindowsMatrixTests`, and `ViewsAndWindowsClosedWindowTests`. Report as `common.md` says (if writes outside your worktree are refused, your final message is the report; otherwise save it as `build/orchestrator/nov13/wintimerfix-report.md`), with each finding: what you changed, its test, and whether breaking it fails the test.

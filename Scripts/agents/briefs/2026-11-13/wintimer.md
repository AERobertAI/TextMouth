# The sleep timer, one for each reader window (November 13, 2026)

You are `wintimer`, an Opus lead. Your branch is `feature/window-sleep-timer`, made at local main. First read `common.md` beside this brief and follow it.

## The user's words

On November 13, 2026:

> "I noticed that the sleep timer still appeared when going from book to book but playing had it stuck... maybe this is from moving from a text book to a audio book when I saw it? Anyway I want each sleep timer to be refactored to be per book view window not global if you understand..."

On November 1, 2026, when the next-book window was built:

> "the sleeping timer in particular I would like to move still running to the new book without a new window opening."

Both stand: each reader window has a timer of its own, and a window that goes on to the next book in place keeps its timer running.

## What the user's timer log shows

The orchestrator read the user's `textmouth_timer.log` (the user's installed app is 0.4.2, e0ea3b9d). You may not read the live library or its logs yourself; these are the lines, with times in UTC:

```
2026-11-12 23:56:52: COUNTDOWN_PAUSED caller=A5084DDE remaining=162 countdownPaused=true owner=A5084DDE generation=11
2026-11-13 00:25:10: COUNTDOWN_RESUMED caller=A5084DDE remaining=162 owner=A5084DDE generation=11
2026-11-13 00:25:12: COUNTDOWN_PAUSED caller=A5084DDE remaining=160 countdownPaused=true owner=A5084DDE generation=11
2026-11-13 01:00:05: COUNTDOWN_PAUSE_IGNORED reason=owner-mismatch caller=98722863 remaining=160 countdownPaused=true owner=A5084DDE generation=11
2026-11-13 03:19:53: STOP reason=replaced-before-start wasActive=true wasRemaining=160 ... generation=12
2026-11-13 03:19:53: START kind=minutes requestedMinutes=15 owner=A5084DDE generation=12
```

There is no `HELD` or `TRANSFERRED` line anywhere in the log since October 14. The debug log has nothing between 00:25 and 01:00 but a `MOVE_SHEET_SHOWN` at 01:00:22. So a 15-minute timer owned by reader A5084DDE stood paused at 2:40 from 00:25 to 03:19, while another reader, 98722863, played and paused: every sheet shows the one shared timer, so the window the user listened in showed a timer it could neither run nor stop, since its playback doesn't own it. No hand-over was made, so this was not the next-book move's hand-over failing. Reader A was still alive at 03:19, when the user started a new timer that A owned.

Find the path that produced it before you change anything, and pin it with a test that fails on main: for instance, a book opened from the Library, from the reading list, Next or Previous in Folder, a feed episode, or a second window, while another reader holds a paused timer; and the user's guess, a text book then an audiobook. If it is a reader that outlives its window or its book (A still owning the timer after its window moved on), say so: that is its own bug.

## The goal

- **Each reader window owns its own sleep timer.** Two windows can each run one. A window's timer pauses, resumes, fades, and stops only that window's playback, and only that window's sheet, status, and VoiceOver label show it.
- **A window that goes on to another book in place keeps its timer running** (the next book, Next or Previous in Folder or in a feed, the reading list's next book). Minutes carry on; End of heading waits for the end of the heading in the new book, as it does now; End of book ends where it does now (`sleepTimerEndsListeningHere`).
- **When the next book opens in a new window** (the setting "Open the next book in"), the timer goes with the listening, to the new window, as today.
- **A window that closes stops its own timer**, and nothing else's.
- **Menu commands and media gestures** (Sleep Timer…, Restart Sleep Timer, a remote command) act on the timer of the window they are for: the key reader window for a menu command, and the window that owns Now Playing for a media gesture, as `forgetLastOwner` and the focused reader do today. Say in the design exactly which, and test each.
- The last timer used (`sleepTimer.lastUsedDuration`) stays one preference for the app.
- The iPhone, which shows one reader at a time, keeps working as it does: one timer for its reader. `make typecheck-ios` stays at 0 errors.

## How to go about it

1. **Read first:** the sleep timer's two entries in `docs/architecture/state/timers-and-statistics.md`, the reader windows in `docs/architecture/state/windows.md`, and the next-book window in `docs/architecture/state/reader.md`; then `Services/SleepTimerService.swift` (1,276 lines), `ViewModels/ReaderViewModel+SleepTimerHandOver.swift`, `+BookMoves.swift`, `+NextBookWindow.swift`, the timer calls in `+Playback.swift`, `Views/Reader/SleepTimerView.swift`, and `Views/Reader/BookReaderWindowView.swift`. `NEXTBOOK-WINDOW-RESEARCH-2026-11-01.md` and `humanQuestions/2026-11-01.md` hold the hand-over's design and the user's answers (read them from the main checkout).
2. **Design before code.** Write `WINDOW-SLEEP-TIMER-DESIGN-2026-11-13.md` in the repository root (stage it with `git add -f`; this is the one Markdown file you edit): where each window's timer lives so that it survives `.id(bookID)` making a new reader (for instance an object the window's scene keeps above that identity), how a reader finds its window's timer, what becomes of the hold machinery (`hold`, `passOnHold`, `adoptHeld`, `heldTimerDeadline`, the request store's part), which of it a per-window timer makes unnecessary and which the new-window case still needs, and how each of today's behaviors maps over. The hand-over took six fix rounds on November 1; every case those rounds fixed must still hold, so list them from the design and the tests.
3. **Keep the behaviors.** `EndBehaviorMatrixTests` (100 cells), the sleep-timer integration tests, and the hand-over tests describe the timer's behavior. Adapt their setup to the new owner; change an assertion only where the per-window rule changes the behavior, and say each one in your report.
4. **Build it in small commits:** the per-window owner first, beside the shared one; then readers moved onto it; then the hold machinery cut down; then the sheet and the commands; then the old shared state removed. Each commit compiles and its tests pass.
5. **Workers.** You may launch up to three Sonnet workers at once with the Agent tool (`model: "sonnet"`, `effort: "high"`, `isolation: "worktree"`, `subagent_type: "general-purpose"`), each with a brief of exact files, line ranges, the mechanism, and the tests, and each told to read `common.md` and to branch from your branch by name. Review every diff before you take it.

## Tests that must exist when you finish

- The user's case, failing on main and passing on your branch.
- Two windows, each with its own timer: each counts, pauses with its own playback, and expires only its own window's playback; each sheet shows only its own.
- In place to the next book: text to audiobook, audiobook to text, text to text, audiobook to audiobook, each with minutes (running and paused), End of heading, and End of book.
- The new-window setting: the timer moves to the new window.
- Closing a window stops its timer only.
- The menu command and the media gesture each reach the right window's timer.
- No test plays sound aloud; every wait has a limit; the sleep-timer integration tests are load-sensitive, so make them deterministic rather than slower.

## Your report

Follow `common.md`'s report, and add: the cause of the user's stuck timer, with the test; the design's summary in ten lines; every assertion you changed and why; and the documentation each change needs (the two timer entries in `timers-and-statistics.md`, `windows.md`, `reader.md`, and `docs/user/reader-windows.md`).

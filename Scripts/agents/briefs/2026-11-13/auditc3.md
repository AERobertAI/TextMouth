# The audit's C3: the reader window publishes what it shows (November 13, 2026, night)

You are `auditc3`, a Sonnet worker. First read `common.md` beside this brief and follow it. Its rules bind you: the live library, `rm` with literal paths only, no search from `/` or `~`, builds only through the heavy-work lock, trains on GitHub, no push except through the train tools, no merge into main. One more rule for tonight: **delete nothing at all.** It is a night's run.

## The user's words

On November 13, 2026, the user asked for a Fable audit of size, memory, and CPU, and that evening asked for its fixes to go on.

## Your branch and item

Your branch is `perf/reader-publish`: `git switch -c perf/reader-publish main`. Main is 22320789 or later. **Rebase onto local main before your report:** `perf/audit-small` (C4, C6, C7, C16, C17) is about to merge, and it touches `ReaderViewModel`'s refresh (C6). Read its diff (`git diff main...perf/audit-small`) before you start, and build on it: `git switch -c perf/reader-publish perf/audit-small` is the better start if main has not yet taken it.

The item is C3 in `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/optaudit/audit-report.md`, Part C: its where, mechanism, gain, must-keep, risk, and tests. Take approach (a), the one `Equatable` value of what the window shows, unless the code shows (b) is clearly better; say why.

## Must keep

These are what the user hears:
- **The sleep countdown.** Today the reader's countdown line in `BookInfoBar` and `PlaybackControlsView` moves only because the reader publishes eight times a second. After your change it must still move every second, playing and paused. The views must observe the window's own timer (`WindowSleepTimerHolder`, `SleepTimerRegistry`; the timer is one per window since the sleep timer merge). If observing the timer would bring back the window body's re-run on every tick that `wintimerfix` removed (its finding 5), give the countdown its own small label view that observes the timer.
- **Every accessibility label and value** stays the same string at each step, the countdown's included.
- `canReleaseMediaControls` and `windowBecameKey()`'s `objectWillChange`.
- Where Am I, pages, and the `display…` mirrors exactly as the tests read them.

## Tests

The audit's tests, and a hosted test that the countdown label's value changes from one second to the next while nothing else changes. Prove a break with a scratch copy through `run_locked.py`, or with a GitHub run of your own, never on a shared train, and say how.

## If the usage limit stops you

The weekly limit may run out before you finish, and the orchestrator resumes you after the reset at 07:00 EST. **Commit after every working step**, so nothing is lost. Before each step, add one line to `build/orchestrator/nov13/auditc3-progress.md` in the main checkout (or, if you cannot write there, to `PROGRESS-auditc3.md` at your worktree's root, staged with `git add -f`), saying what is done and what is next.

## Your report

As `common.md` says. Include a hand check for the user: the reader's countdown line, playing and paused, with VoiceOver.

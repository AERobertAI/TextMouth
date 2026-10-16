# Task process (REV17a findings 4 and 5): the watched child dies with TextMouth, the cancel race closes, the clock is monotonic

Slug `oggsafe-process`, branch `oggsafe/process` (made from `team/oggsafe`). Read `Scripts/agents/briefs/2026-10-16/teams-common.md`: "The worker's part", "Rules for everyone", "The board", "Builds", "Usage", "Keeping the cost down". Never open, play, probe, or decode a real Ogg file in a test or an experiment: stand-in children only (`/bin/sleep`, `/bin/sh` loops). Your files: `TextMouth/Services/WatchedProcess.swift` and the new `TextMouthProductionTests/WatchedProcessSafetyTests.swift` (run `/opt/homebrew/bin/xcodegen generate` and commit the regenerated `project.pbxproj` with it). Not yours: `AppDelegate.swift` and `PlaybackMemoryGuard.swift` (the lead calls your `terminateAll()` from `applicationWillTerminate` and from the memory guard's `quitAtOnce`), `OggAudioConverter.swift`, any `*.md`. Team `fixes` edits the two `words` lines of `.tookTooLong` and `.madeNoProgress` in `KillReason.words` (lines 42 and 46): leave those two lines exactly as they are, and put your new case below the existing ones.

## The problem
`WatchedProcess` (165 lines; read it all) runs `afconvert` as a child that a watchdog thread kills. On October 14, 2026 Apple's Vorbis decoder spun and allocated at about 60 MB a second inside TextMouth. Today: (a) only the watching thread kills the child, so when TextMouth quits, is force-quit, or `_exit`s (the memory guard's `quitAtOnce`), the child keeps running, reparented to launchd, until it ends or the Mac restarts; (b) the child has no CPU limit of its own; (c) `onCancel` (:101-103) does nothing when it fires before the pid is published (:133), so `cancelAll` lets a just-started child run on; (d) elapsed and no-growth times use `Date()` (:136-151), the wall clock, while the poll wait uses `DispatchTime`, so after a sleep or a clock change the next poll kills every healthy child.

## Evidence measured on this Mac (October 16), so you need not explore
- `/bin/sh -c 'ulimit -t 2; exec /bin/sh -c "while :; do :; done"'` ends after about 2 CPU seconds with exit status 152, which is 128 + SIGXCPU (24). In Foundation: `terminationReason == .uncaughtSignal`, `terminationStatus == SIGXCPU`.
- The reaper script below, with a fake parent `sleep 2` and a fake tool `sleep 30`, killed the tool (status 137) 2 seconds after the parent ended; with the tool ending first (`sleep 1`) the reaper exited by itself after 1 second and left the parent alone:
```sh
# $1 = the pid whose death kills the tool, $2 = the tool's pid
while kill -0 "$2" 2>/dev/null; do
    if ! kill -0 "$1" 2>/dev/null; then
        kill -9 "$2" 2>/dev/null
        exit 0
    fi
    sleep 1
done
```
- The app is not sandboxed; `/bin/sh` is bash in POSIX mode. Your own Bash tool refuses commands that hand complex text to `sh -c` (the worktree guard), so put any experiment in a script file and run that file.

## Required behavior
1. **The cancel race.** One lock around `{ pid: pid_t?, isCancelled: Bool }` replaces `running`. `run` first does `try Task.checkCancellation()`. `onCancel` sets the flag and kills the pid if there is one. `watch` publishes the pid and reads the flag in the same critical section, and kills the child at once when it is set. Either order kills the child. Put the two operations in a small internal type with the kill injected, so a test can drive both orders without a race.
2. **The monotonic clock.** `Date()` leaves the watchdog. Start time, last growth, and elapsed come from a new `run` parameter `uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }`.
3. **The CPU limit.** `Limits` gains `var maximumCPUSeconds: TimeInterval? = nil`; nil means four times `maximumSeconds` (a few cores' work; document it). Every child starts as `/bin/sh -c 'ulimit -t "$1" || exit 126; shift; exec "$@"' sh <cpu seconds, rounded up> <executable path> <arguments…>`: the shell replaces itself with the tool, so the pid the watchdog sees, kills, and measures is the tool's own. A child that dies of SIGXCPU is reported `.killed(.usedTooMuchProcessorTime(seconds: maximumCPU))`, a new `KillReason` case whose `words` read "it used more than N seconds of processor time" (N rounded up like its neighbours). An `executable` that does not exist or cannot be executed stays `.couldNotStart`: test `FileManager.default.isExecutableFile(atPath:)` first (`testAChildThatEndsReportsItsStatus` pins it with `/nonexistent/tool`).
4. **It dies with TextMouth.** Right after publishing the pid, start a reaper: a `Process` running `/bin/sh -c <script above> sh <getpid()> <child pid>` with all three standard streams on the null device, as `static func startReaper(watching child: pid_t, parent: pid_t = getpid()) -> Process?` (internal, so tests can use a stand-in parent). Failing to start it does not fail the run. When the child has ended, however it ended, `terminate()` the reaper so none lingers.
5. **`terminateAll()`.** `static func terminateAll()` (callable from any thread, only a short lock, never blocks) kills every running child with SIGKILL, checking `isRunning` first. Every child is registered from the moment it is published until it ends. Add an internal `static var runningChildCount: Int` for tests.

## Tests (new class `WatchedProcessSafetyTests`; existing `OggAfconvertTests` watchdog tests must pass unchanged)
- Cancel race, both orders through the internal type; a task cancelled before `run` starts throws `CancellationError` and starts no child (`runningChildCount` stays 0).
- Clock: a frozen `uptime` closure lets a child that runs 2 s real time with `maximumSeconds: 1` end by itself (`.exited`), proving no wall clock is read; an `uptime` that advances 100 s per call kills a healthy writer with `.killed(.tookTooLong)` within a second or two of real time, proving the loop reads the injected clock. Completion check: `grep -n "Date()" TextMouth/Services/WatchedProcess.swift` finds nothing.
- CPU: a shell loop with `maximumCPUSeconds: 1` and generous wall limits ends `.killed(.usedTooMuchProcessorTime(seconds: 1))` within about 5 s; the `words` text; the default of four times `maximumSeconds`; a non-executable path (a text file with the execute bit off) is `.couldNotStart`; the child's pid is the tool's own (a stand-in that prints nothing but is measured by `residentMemory` called with a pid whose `proc_pidpath` is the tool, not `/bin/sh`).
- Reaper (stand-in parent and tool, short): the tool dies within 3 s after a fake parent `sleep 1` ends; with the tool ending first the reaper exits within 3 s and the parent is untouched; a reaper for a child that is already gone exits at once.
- `terminateAll()`: with two running writers, both end within a second of the call and the count returns to 0; with none running it does nothing.
- Clean up every child and reaper in `tearDown`, whatever the test did.

## Run
`WatchedProcessSafetyTests`, `OggAfconvertTests` (all of it). A failing existing test means stop and ask.

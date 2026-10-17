# testkit/test-logs: slowest, changed, and flaky tests from xcodebuild logs

Slug `testkit-test-logs`. Branch `testkit/test-logs`, made from `team/testkit`. Python 3 standard library only. **You build nothing.** Read `teams-common.md`'s worker's part first.

## Why

The full hosted suite is about 6300 tests and takes 4 to 5 minutes; the orchestrator runs it before every merge and every agent runs classes of it. The logs hold more than pass or fail: how long each test took, which tests changed outcome between two runs, which behave differently from run to run (the load-sensitive ones the pattern lists). Nobody reads a 50,000-line log, so those facts are lost. A small tool turns logs into three short answers: which tests are slowest, what changed between the log from before a merge and the log from after, and which tests are flaky across several logs. The orchestrator and the leads use it; so can the user.

## Ground truth

- XCTest prints, per test: `Test Case '-[TextMouthProductionTests.FooTests testBar]' started.` and then `Test Case '-[TextMouthProductionTests.FooTests testBar]' passed (0.123 seconds).`; a failing test prints `... failed (0.5 seconds).`; a skipped test prints `... skipped (0.001 seconds).` (check this in a real log); per suite `Test Suite 'FooTests' passed at ...` and `Executed 12 tests, with 1 test skipped and 0 failures (0 unexpected) in 1.2 (1.3) seconds`.
- Real logs to learn the format from sit in the shared scratchpad folder `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/8d971e15-7103-46cf-b45e-5c4d099f2f74/scratchpad/` (`ls -t` it; names like `feedopts-*-build*.log`, `fixes-*-build*.log`, `testkit-*-build*.log`; they are other agents' working logs, so READ ONLY, and read them with `grep -E "Test Case '.*(passed|failed|skipped)" file | head`, never whole). Copy a few real lines into your selftest as canned text.
- A test may run twice in one log (a retry or a repeated class); keep the last result per test, and count the runs.

## The command

    python3 Scripts/test/test-logs.py slowest LOG [-n N] [--classes]
    python3 Scripts/test/test-logs.py compare OLD NEW [--slower SECONDS]
    python3 Scripts/test/test-logs.py flaky LOG LOG [LOG ...]
    python3 Scripts/test/test-logs.py --selftest
    python3 Scripts/test/test-logs.py -h

Output is plain words for VoiceOver and braille: one fact per line, no tables, no color, no emoji, no box drawing.

- `slowest`: the N slowest test cases (default 20), one per line as `12.4 seconds  FooTests.testBar`, then `N tests, total X seconds` and, with `--classes`, the 10 slowest classes by summed time (`FooTests: 34.5 seconds in 40 tests`). Also prints how many tests the log holds and how many are skipped, failed.
- `compare OLD NEW`: first both logs' final `Executed` lines. Then, each with a count and the names, one per line: `now failing` (passed or skipped before, failed now), `now passing` (failed before, passed now), `new` (in NEW only), `gone` (in OLD only), `now skipped`, `no longer skipped`, and `slower` (NEW more than `--slower` seconds, default 2.0, AND more than 1.5 times OLD) with both times. Last line: `compared A tests: B changed outcome, C new, D gone, E slower`. When nothing differs, say `no test changed outcome`. A gone test is a signal: someone deleted or renamed a test; say so plainly.
- `flaky LOG LOG ...` (two or more logs of the same suite): tests whose outcome is not the same in every log (`passed in 2 of 3 logs, failed in 1`), and tests whose slowest time is more than 3 times their fastest and above 2 seconds (`varies: 0.4 to 3.1 seconds`). Also report the tests the pattern already calls load-sensitive if they appear (their names are in `teams-common.md`'s "Load-sensitive tests": the sleep-timer integration tests `IntegrationSleepTimerTests`, `BookmarkKeyboardAccessTests`, `StorageGenerationMoveTests`, `BookSearchModelTests.testCancelledSearchPublishesNothing`, `DataDirectoryMoveTests.testAMoveShowsItsProgressWhileItCopies`, `ViewsAndWindowsReaderSheetTests`, `FeedDownloadTests.testADownloadThatStopsPartwayGoesOnFromWhereItStopped`, the performance baselines): mark them `(known load-sensitive)`; keep that list in one constant.
- Exit status 0 always for reports, except `compare` exits 1 when a test is `now failing` or `gone` (so a merge script can use it), and 2 for a usage problem (missing file, no test lines found: say `this does not look like an xcodebuild test log`).
- Logs may be large (50 MB): read line by line, never the whole file at once. A log may contain several runs of the same class; handle that.

## Files

- `Scripts/test/test-logs.py` (every function commented; a `parse_log(path)` that returns `{ "Class.test": Result(outcome, seconds, runs) }` plus the Executed line, reused by all three commands).
- Nothing else. (The runner's `testkit.py` may exist on the team branch later; do not depend on it.)

## Selftest

`--selftest`: canned log text covering a pass, a fail, a skip, a repeated test, a class name with digits and underscores, and the `Executed` lines; each command's expected lines; the "not a log" refusal. Print `selftest: N checks, all passed` or one line per failure; exit 0 or 1. Then run all three commands on real logs from the scratchpad (two different `feedopts-*` or `fixes-*` build logs for `compare`) and paste a short excerpt of each output into your report.

## Commits

1. `parse_log` + `slowest` + selftest.
2. `compare` + `flaky` + selftest.

## Do not

Edit any other file. Write into the scratchpad's existing logs. Build or run tests.

## Report (at most 15 lines)

Branch; commits; selftest result; excerpts of real output; how long it takes on a 20 MB log; what you could not verify.

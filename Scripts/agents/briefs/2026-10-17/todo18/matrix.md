# todo18/matrix: make EndBehaviorMatrixTests fast without losing a cell

Slug `todo18-matrix`. Branch `todo18/matrix`, made from `team/todo18`. You build; at most two of the team's workers build at once. Read `Scripts/agents/briefs/2026-10-17/teams-common.md` first, everything except "The lead's part" and "A lead's report": the worker's part, the rules, the board, the builds, the lessons, and the usage note. Your lead is `todo18-lead`.

## Why

`EndBehaviorMatrixTests` takes 153 s of every full run of the suite (about 16% of its test time, the slowest class; the testkit team measured it). Its audio cells play a book out in real time and then wait out fixed clocks. The suite is run before every merge, so this is paid many times a day. Make the class much faster, and keep every cell asserting what it asserts now.

## What the class is (all yours, nothing else)

A grid of 4 end-of-book behaviors x 5 sleep timers, for 5 kinds of content (the inventory is the doc comment at the top of `EndBehaviorMatrixTests.swift`, lines 4-135). Each kind has a test that loops its cells; every cell builds an `IntegrationWorld`, its books, and a reader, plays the book out, and calls `assertEnd` (`EndBehaviorMatrixTests.swift:284-307`), eight assertions about the announcement, whether the book plays again, whether it rests finished, where the cursor rests, the chapter, whether the next book was asked for, and whether the timer is in effect.

Your files:
- `TextMouthProductionTests/EndBehaviorMatrixTests.swift`: the grid types, `assertEnd`, `arm`, `testTextBookEndBehaviorMatrix` (336-376, 12 cells, speech held silent), `testSingleFileAudioEndBehaviorMatrix` (384-440, 19 cells).
- `TextMouthProductionTests/EndBehaviorMatrixAudioSupport.swift`: `assertAudioBookEnd` (31-85), the one function the next three tests share, and `offsetHalfASecondBeforeTheEnd`.
- `EndBehaviorMatrixChapteredTests.swift`, `EndBehaviorMatrixMultiFileTests.swift`, `EndBehaviorMatrixDAISYTests.swift`: the other three columns.
- NOT yours: `EndBehaviorTestSupport.swift` (its helpers are shared with `IntegrationSleepTimerTests`; put anything new in the matrix files), and every file of the app. In particular `ReaderViewModel.continueToNextBookDelay` (`ReaderViewModel+Playback.swift:2786`) is another team's file: you cannot shorten it, and you must not.

## Where a cell's time goes (my reading of the code; MEASURE it first, then decide)

An audio cell: its world, books and reader (`makeIntegrationWorld`, the silent WAV files, `openReader`, `waitForReaderToLoad`); `reader.play()`; the real playback of the half second left in the book (`offsetHalfASecondBeforeTheEnd`); `eventually(within: 10)` for the end announcement; a fixed `spinMainRunLoop(for: 0.3)` "for the player's last tick"; and then `nextBookIsAskedFor(continued)` (`EndBehaviorTestSupport.swift:17-19`), which waits up to `ReaderViewModel.continueToNextBookDelay * 2`, that is 1.0 s, when nothing is asked for. In 71 of the 80 cells nothing is asked for (the ask comes 0.5 s after "Starting: <title>" and only for Continue to Next Book with no timer or an expired one), so each of those cells spends a full second proving a negative; the cells that do ask return as soon as the ask comes, at about 0.5 s.

The seams other playback tests use to wait on events instead of clocks: `AudioPlaybackService._reportHandledForTesting` (`AudioPlaybackService.swift:1469-1472`), which hears every tick and end-of-file report once the service has dealt with it, and the test helper `PlayerReportLog(observing:)` (`CompletionGenerationTests.swift:1049`) that keeps them (`tickCount`, `endOfFileOutcomes`), used in `ReaderNextChapterFileTests.swift:43`; `_endNoticeArrivedForTesting` (1477); `SleepTimerService._expireForTesting()` (which `arm` already uses); `eventually(within:)` and `spinMainRunLoop(for:)` (`AudioTestFixtures.swift:432-446`).

## Required

1. **Baseline first.** `BBS_AGENT=todo18-matrix python3 Scripts/test/run-area.py EndBehaviorMatrixTests`, then from its log (the path it prints): `grep -E "Test Case '-\[TextMouthProductionTests.EndBehaviorMatrix.*(passed|failed)" <log>`, which gives each test's seconds. Record the five tests' seconds and their sum. To prove no cell is lost, add a temporary `print("MATRIX_CELL \(name)")` at the top of `assertEnd` (never committed) and save the sorted list of cell names from this run (`grep -o "MATRIX_CELL .*" <log> | sort > <scratchpad>/todo18-matrix-cells-before.txt`); there should be 12 + 19 + 19 + 11 + 19 = 80 names. If you can, also time the phases of one audio cell with temporary prints, so you change what costs, not what you guess costs.
2. **Make the cells fast.** Likely levers, most saving first; use the numbers to choose and drop any that does not pay:
   - Wait for the next book to be asked for only in a cell that expects it (`cell.outcome(...).nextAsked`). In every other cell no hand-over began, which the cell's own announcement assertion already proves ("Starting: <title>" is spoken the moment a hand-over begins, and only a hand-over asks: confirm it by reading `handOverToNextBook`, `ReaderViewModel+Playback.swift:2834-2853`, and its callers, `ReaderViewModel+GoingOn.swift:63` and `ReaderViewModel+EpisodeDownload.swift:101`), so read what has been asked so far once, after the end has settled, instead of waiting a second. Say in a comment why this proves the same thing. A new helper beside `assertAudioBookEnd` is the place for it.
   - Replace the fixed `spinMainRunLoop(for: 0.3)` by waiting on the audio service's own reports (the end-of-file report, then one tick after it) where that is shorter and as safe; keep a fixed wait wherever you cannot wait on an event.
   - Save the books closer to their end than half a second (`offsetHalfASecondBeforeTheEnd` and the single-file test's `lastHalfSecond`), if the numbers show it pays and every cell still passes. A loop must still play on for longer than the test spends after the end; keep the last chapter long.
   - Anything else the measurement shows (for example work done per cell that one build per column could share).
3. **Nothing weaker.** `Cell.outcome`, `assertEnd`, its eight assertions, and the cell lists (`textCells`, `singleFileAudioCells`, `chapteredAudioCells`, `multiFileAudioCells`, `daisyCells`) keep what they say. If a change to any of them is unavoidable, say so and why in your report. No test plays sound (keep the silent audio); no test may trap (no unguarded subscript, force unwrap, or over-fulfilled expectation); keep every cell's failure message naming the cell. Update the doc comments that describe how long a cell takes or waits ("plays out in real time", "saved half a second from its end") so they stay true, and keep the inventory comment as it is.
4. **After.** Run the class again and compare: the five tests' seconds and their sum; the cell-name list (`diff` of the before and after lists must be empty); the class's result line. Then `BBS_AGENT=todo18-matrix python3 Scripts/test/run-area.py --repeat 3 EndBehaviorMatrixTests` and report all three results: the class is load-sensitive, and a shortened wait must not make it flaky. A failure in one run is rerun alone and reported with both results. Remove the temporary print before you commit.
5. Run once more, as the surrounding net: `IntegrationSleepTimerTests`, `ContinueToNextBookTests`, `FinishedBookReaderTests` (they share the helpers; you changed none of them, so they should be as they were).
6. `LINT_BASE=team/todo18 make lint-tests` on your diff before you report.

## Commits

One or two, each one logical change with the tests passing: for instance (a) the wait only for an expected ask, (b) the events and the closer saved position. Messages in the repository's style, e.g. `Wait for the next book only in the end-behavior cells that expect it`.

## Report (at most 15 lines)

Branch; each commit's hash and subject; the class's seconds before and after (each test and the sum); where the time went; what you changed and what you tried and dropped; the three-run results; the empty `diff` of the cell lists; anything weaker than before (there should be nothing); what you could not verify.

## Do not touch

The app's files, `EndBehaviorTestSupport.swift`, any other test file, `Scripts/test/areas.conf`, and any `*.md` file. Add no Swift warning.

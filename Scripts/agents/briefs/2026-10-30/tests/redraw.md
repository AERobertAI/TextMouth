# Task `redraw`: find why a reader sheet draws again under load, and count only what the publishes cause

Slug `tests-redraw`, branch `tests/redraw` from `team/tests`. Read `_common.md` beside this file first. This task is investigative: step 1 ends with a post to the lead.

## Why
`ViewsAndWindowsReaderSheetTests.testSheetsDoNotDrawAgainForPublishesThatChangeNothingTheyShow` (`TextMouthProductionTests/ViewsAndWindowsReaderSheetTests.swift` 87-122) fails under load: `BookmarkPanelView` drew 6 and then 15 times for 20 publishes (merge suites of October 4 and 10), and tonight, in run 5 of 10 under a load average near 11, `BookVoicePickerView` drew 11 times (line 119). It allows one draw.

The test hosts each sheet in `ReaderSheetHost` (a parent that observes the reader and makes the sheet again on each publish, `ViewsAndWindowsTestSupport.swift` 112 on), settles it with a FIXED 0.4 seconds (`settle(_:seconds:)`, lines 66-72), then counts body runs (`ViewBodyCounter`) over 3 uncounted and 20 counted `reader.objectWillChange.send()` publishes, each followed by `flush` (a 2 ms run-loop turn and a layout, lines 76-104).

Things that can land in the counting window under load (starting points, not conclusions):
- `BookmarkPanelView` (`TextMouth/Views/Reader/BookmarkPanelView.swift`): `onAppear` asks for focus with `openingVoiceOverDelay` = 1.2 s (line 475), and `.task(id: focusRequest)` sleeps `keyboardFocusDelay` = 150 ms (line 485) then sets `focusedControl` and scrolls (lines 118-145). 1.2 seconds is longer than the 0.4-second settle.
- `BookVoicePickerView` (`TextMouth/Views/Reader/ReaderView.swift` 822 on) observes `VoiceCatalog.shared` (line ~862), which lists the installed voices asynchronously once (PERF07) and publishes when it has them.
- `SleepTimerView` drops its first focus request two seconds after it opens (the test's own comment, lines 104-108).
Eleven or fifteen draws is more than one late update explains, so find the real cause before changing anything.

## Step 1: reproduce and diagnose (local, uncommitted instrumentation)
1. `--repeat 10 ViewsAndWindowsReaderSheetTests` (it failed once in ten tonight; repeat if needed).
2. To see what each extra draw comes from, temporarily add `let _ = Self._printChanges()` at the top of the bodies of the four sheets (SwiftUI prints which property or `@self` changed), and print a timestamp with each `publish` in the test; read the failing run's log.
3. Post the cause to `tests-lead` (`bbs post tests-redraw --to tests-lead --topic "redraw: <sheet> draws again because ..."`) with the fix you propose, and wait for the answer (`bbs watch tests-redraw --timeout 600`, repeated). Remove the instrumentation.

## Step 2: the fix (once the lead confirms)
The test counts only draws the publishes cause, by waiting on the condition itself: for example, settle until the sheet's own opening work has happened (a focus request applied, the voice catalog loaded) or until its body has not run over an interval longer than its longest own delay, bounded at 15 seconds, before counting. Or, if a sheet really does draw again for a publish that changes nothing it shows when the Mac is slow, that is a performance bug in the sheet (PERF30): report it with the evidence; the lead decides. Never raise the allowed count. Keep every assertion. Prove it: with the fix, `--repeat 10` passes; and a sheet changed to observe the whole reader again (temporarily, for example `@ObservedObject var viewModel` in `BookVoicePickerView`) still fails the test.

## Files
`TextMouthProductionTests/ViewsAndWindowsReaderSheetTests.swift`, `TextMouthProductionTests/ViewsAndWindowsTestSupport.swift` (if a shared settle helper changes, run every class that calls `settle(_:seconds:)` or `bodyRuns`: `grep -lE "settle\(|bodyRuns\(" TextMouthProductionTests/*.swift`). A test seam in a sheet (a delay a test may set) only with the lead's confirmation, with no change in the app.

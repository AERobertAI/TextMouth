# Task `search`: the cancelled-search tests wait for the cancellation itself

Slug `tests-search`, branch `tests/search` from `team/tests`. Read `_common.md` beside this file first.

## Why
`BookSearchModelTests.testCancelledSearchPublishesNothing` failed once under load (October 21, `main-after-pg16-merge.log`): `XCTAssertEqual failed: ("[false]") is not equal to ("[true]")` at `log.cancellations`. Its sibling `testNewerQueryCancelsTheOlderSearchWhoseLateCompletionNeverPublishes` has the same race, with a wider window.

The race, in `TextMouth/ViewModels/BookSearchModel.swift`: `restartSearch()` (lines 137-167) starts `searchTask`, which after the debounce calls `runDetached` (lines 185-197). `runDetached` creates the detached task FIRST and installs `withTaskCancellationHandler` SECOND. The fake search fulfils `searchStarted` from inside the detached task, so the test can call `model.cancelSearch()` before the outer task has installed its handler. Swift then runs `onCancel` at once when the handler is installed, a moment later, on the outer task's thread. But the test signals the semaphore right after `cancelSearch()`, so the fake search can read `Task.isCancelled` before that late `onCancel` has cancelled the detached task: it records `false`. The app is right (the detached task is told to stop a moment later, and the generation check publishes nothing); the test assumed the cancellation is visible the instant `cancelSearch()` returns.

## The change (test file only: `TextMouthProductionTests/BookSearchModelTests.swift`)
1. Add one private helper beside `SearchLog` (lines 539-586), for use inside a fake search on its background thread:
   `/// Waits, on the calling background thread, until the current task is cancelled or 10 seconds pass; returns whether it was cancelled.`
   `private func waitUntilCancelled(timeout: TimeInterval = 10) -> Bool` — loop: `if Task.isCancelled { return true }`, `guard Date() < deadline`, `Thread.sleep(forTimeInterval: 0.001)`; return `Task.isCancelled` at the deadline. (A 1 ms poll inside a fake is a wait on the condition itself, bounded; it is not a guess about time.)
2. `testCancelledSearchPublishesNothing` (lines 711-737): in the fake, replace `log.recordCancellation(Task.isCancelled)` with `log.recordCancellation(waitUntilCancelled())`, keeping `releaseSearch.wait()` before it. Every assertion stays as it is.
3. `testNewerQueryCancelsTheOlderSearchWhoseLateCompletionNeverPublishes` (lines 669-707): the same change in the `query == "old"` branch, after `releaseOldSearch.wait()`. The old search still finishes after the new one is published, since it waits for the release first; every assertion stays.
4. Update both tests' doc comments in one sentence each: the fake waits until the search's cancellation reaches it, as the cancellation handler delivers it a moment after `cancelSearch()`.

## Proof
- Can fail: in `BookSearchModel.runDetached`, temporarily delete the `onCancel: { task.cancel() }` body (leave `{ }`): both tests must fail at `log.cancellations` after about 10 seconds. Restore it.
- Deterministic: `--repeat 10 BookSearchModelTests` passes in all 10 runs.

## Classes to run
`BookSearchModelTests`. Touch no other file.

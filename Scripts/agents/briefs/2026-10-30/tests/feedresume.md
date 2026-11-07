# Task `feedresume`: the resumed-download test lets the first half land before the connection drops

Slug `tests-feedresume`, branch `tests/feedresume` from `team/tests`. Read `_common.md` beside this file first.

## Why
`FeedDownloadTests.testADownloadThatStopsPartwayGoesOnFromWhereItStopped` (lines 163-192 of `TextMouthProductionTests/FeedDownloadTests.swift`) failed once under load (October 21, `main-after-pages-merge.log`): `XCTAssertEqual failed: ("Optional("bytes=0-")") is not equal to ("Optional("bytes=8228-")")` at line 191.

The cause is in the stub, `FeedStubProtocol` (`TextMouthProductionTests/FeedTestSupport.swift`, lines 212-337). With no `pause`, `startLoading()` (lines 226-254) tells the client the response, the first half of the body, and `networkConnectionLost`, all at once, in one call. A download task writes what it receives to its file asynchronously, so under load the failure can overtake the bytes, and URLSession's resume data then records 0 bytes: the retry asks for `bytes=0-`. The app did nothing wrong; the stub dropped the connection before the bytes had arrived.

## The change (test files only)
In `TextMouthProductionTests/FeedTestSupport.swift`:
1. `StubResponse` (lines 17-45): add `var failureGate: WorkGate?`, documented: the gate a failure after `failAfterBytes` waits at, on a background queue, before it is told to the client, so a test can let the bytes before it land first. `WorkGate` is the existing class at lines 740-774 (`arm()`, `pass()`, `release()`; a held pass gives up after 30 seconds); reuse it, do not write another.
2. `startLoading()`: deliver at once, as now, only when `response.pause <= 0 && response.failureGate == nil`. Otherwise use the background path (lines 241-253), with two changes: sleep `response.pause` only when it is above 0, and before delivering a failure step, call `response.failureGate?.pass()` on that background queue. Give the private `Step` enum (lines 262-271) a computed `isFailure` (true for `.fail` and `.refuse`) for this.
3. `answering(range:with:)` (lines 276-287): the 206 partial response clears `failureGate` too, beside `partial.failAfterBytes = nil`.

In `TextMouthProductionTests/FeedDownloadTests.swift`, `testADownloadThatStopsPartwayGoesOnFromWhereItStopped`:
4. Make a `WorkGate`, `arm()` it, set `broken.failureGate` to it before `world.server.serve`, and `addTeardownBlock { gate.release() }` so no thread waits should the test fail early.
5. After the first `world.center.download(...)`, wait for the condition itself with the file's `waitFor` helper (`FeedTestSupport.swift` lines 714-731): `await waitFor("the first half was written") { (world.center.downloads.progress.state.download?.transfer?.completedBytes ?? 0) >= Int64(audio.count / 2) }`. That number comes from the session delegate's `didWriteData` (`FeedTransfer.swift` lines 150-160, then `FeedDownloadManager.downloaded(_:of:estimate:for:)`, line 932), which reports bytes already written to the task's file. Then `gate.release()`, and go on with the existing wait for the failure.
6. Every existing assertion stays exactly as it is, the `Range` value included. Add one sentence to the test's doc comment: the stub drops the connection only once the first half is written, as a real connection's bytes arrive before it drops.

## Proof
- Can fail: in `TextMouth/Services/Feeds/FeedTransfer.swift` lines 87-88, temporarily replace `resumeData.map { downloadSession.downloadTask(withResumeData: $0) }` with `(nil as URLSessionDownloadTask?)`, so every download starts afresh: the test must fail at the `Range` assertion (nil, not `bytes=8228-`). Restore it.
- Deterministic: `--repeat 10 FeedDownloadTests` passes in all 10 runs.
- Other users of the stub are unchanged: run `FeedDownloadTests FeedUICommandsTests FeedSubscriptionSwitchTests NextEpisodePredownloadTests FeedLifecycleTests LibraryFeedUnsubscribeTests FeedNewestRuleTests` once.

## Do not touch
Production code. Any other test in these two files.

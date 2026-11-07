# Task `recording`: a take that fails keeps what was recorded, and the recording window's last unpinned words

Slug `tests-recording`, branch `tests/recording` from `team/tests`. Read `_common.md` beside this file first. Audit items U05 and U23 (`build/orchestrator/oct30/tests-audit-untested.md` in the main checkout). Tests only (plus the test double), unless a test shows a bug: then stop and post it to `tests-lead` with the evidence. No test records from a real microphone or plays sound: everything goes through `FakeCaptureBackend` (`TextMouthProductionTests/RecordingTestSupport.swift`).

## U05: failures that promise "what was recorded is kept" (the listener's own recordings, on disk)
Read: `TextMouth/Services/RecordingService.swift` 265-285 (`stop()`: when the backend's stop throws, the result is `.couldNotFinish`), 347-372 (`handle(_:)`: a `.failed` capture event gives `.stoppedUnexpectedly`), the sentences at 36-44; `TextMouth/Services/RecordingEncoder.swift` 101-145 (`RecordingEncodingError.encodingFailed`); `TextMouth/Services/RecordingCaptureBackend.swift` 135-151 (`setupFailed`), 196 and 409 (`didNotFinish`). `RecordingServiceTests` covers a lost microphone (226), a full disk (269), and failures at start, not these.
1. Give `FakeCaptureBackend` a way to make its `stop()` throw, and to send a `.failed("...")` event mid-take, if it has neither (test code only; keep its existing behavior the default).
2. More methods in `RecordingServiceTests`: a `.failed` event mid-take leaves the state `.failed(.stoppedUnexpectedly, take)`, the take's file kept with the frames written so far, and the sentence exactly as the listener hears it; a `stop()` that throws leaves `.failed(.couldNotFinish, take)`, the file kept, and the RECORDING_STOP_FAILED line logged (read how other tests capture diagnostic lines); a failure before any frame was written: assert what the code gives (read it first); a take whose title is in another script.
3. In `RecordingSaveTests` (or `RecordingServiceTests`): encoding into a read-only folder gives `encodingFailed`, and the source take is not deleted. Restore permissions in a teardown block; skip under the superuser as `ArchiveExtractionTests` line 435 does.

## U23: the recording window's strings nothing reaches (what a listener hears)
`TextMouth/Views/Recording/RecordingWording.swift` 99 (`openInReaderHint`) and 216 (`announceLevelTitle`): assert both texts exactly in `RecordingWindowTests`, as it asserts the window's other strings, one with a title in another script if the string takes a title. Leave `RecordingWindowModel.openPrivacySettings` untested (it opens System Settings).

## Proof
For each new test, break the branch it pins (for example make `handle(_:)` drop the take on `.failed`, or delete the file on `couldNotFinish`) and see it fail; restore.

## Classes to run
`RecordingServiceTests RecordingSaveTests RecordingWindowTests RecordingEndToEndTests` (the last skips its microphone test, which is right). Files: `RecordingTestSupport.swift`, `RecordingServiceTests.swift`, `RecordingSaveTests.swift`, `RecordingWindowTests.swift`. No production change.

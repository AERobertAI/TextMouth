# Testing library sync
<!-- id: testing-library-sync; keys: FR43, sync area, run-area.py sync, SyncTestDrive, SyncTwoDevices, SYNC_RUN, TEXTMOUTH_SYNC_FOLDER; src: Scripts/test/areas.conf, TextMouthProductionTests/SyncTestDrive.swift, TextMouthProductionTests/SyncTwoDeviceTests.swift -->

Part of [Testing TextMouth](testing.md).

The design is in [Library sync: the folder, the outbox, and the merge](../architecture/state/library-sync.md) and [its second half](../architecture/state/library-sync-store.md); what a person hears is in [Syncing your library between your devices](../user/syncing-your-library.md).
No test touches the user's drive or library: every file is made up, in the test's own sandbox.

## The sync area
<!-- id: sync-test-area; keys: [sync], areas.conf, run-area, test classes, hosted tests; src: Scripts/test/areas.conf, Scripts/test/run-area.py, TextMouthProductionTests/SyncFeedTests.swift, TextMouthProductionTests/SyncFeedHostTests.swift -->

The `[sync]` area of `Scripts/test/areas.conf` holds every class of FR43.
Run it with `python3 Scripts/test/run-area.py sync`, or `make test-area AREAS=sync`; see [Reusable test tools](testing-tools.md).
A new test class goes in the area when its file is made, and `python3 Scripts/test/run-area.py --unassigned` lists one that isn't.

By part, in `TextMouthProductionTests`:
- Stamps, registers, and the merge, which are pure: `SyncStampTests`, `SyncRegistersTests`, `SyncMergePropertyTests` (random orders of merging give one result, and merging twice changes nothing), `SyncProjectionTests`, `SyncApplyTests`, `SyncBaselineTests`, `SyncOrderKeyTests`, `SyncReviewFixTests`.
- The stored formats and the words: `SyncFormatTests`, `OnDiskContractTests` (the names and key sets), `FileDigestTests`, `SyncWordingTests`, `SyncStatusLineTests`.
- The engine and the folder: `SyncEngineTests`, `SyncOutboxTests`, `SyncFolderTests`, `SyncFolderIOTests`, `PlainSyncFolderAccessTests`, `SyncCenterTests`, `SyncSchedulerTests`.
- Books: `StoreBackupTests`, `StoreFetchTests`, `SyncPlaceholderTests`, `SyncOpenAndRemoveTests`, `SyncLibraryHostTests`, `SyncReaderPlaceTests`, `SyncOlderVersionsTests`.
- Feeds: `SyncFeedTests` (keys, projection, merge, duplicates of one address, folds, the launch, an older TextMouth's reading), `SyncFeedTwoDeviceTests` (two real engines over one drive), and `SyncFeedHostTests` (`FeedCenter.applySync` against a real feed store).
- The interface: `SyncSettingsSectionTests` (the Mac), and `PhoneSyncSettingsTests`, `PhoneSyncLifeCycleTests`, and `PhoneReaderCloudPhaseTests` (the phone's decisions, run on the Mac's host).

`SyncSettingsUITests` (`TextMouthiOSUITests`) reads the iPhone's section with sync off: its heading, summary, status, and two buttons, in order, and no Sync Now on the library's summary.
`PhoneSyncFolderAccessTests` (`TextMouthiOSTests`) covers the bookmark, its renewal, and the system's errors on the iPhone; both run on GitHub only.

## The stand-in drive and the two devices
<!-- id: sync-test-two-devices; keys: SyncTestDrive, SyncTwoDevices, SyncInterruptionTests, SyncNetworkCaseTests, SyncStep, stop after each step; src: TextMouthProductionTests/SyncTestDrive.swift, TextMouthProductionTests/SyncTwoDeviceTests.swift, TextMouthProductionTests/SyncTestFixtures.swift, TextMouth/Services/Sync/SyncEngine.swift -->

`SyncTestDrive` is a `SyncFolderAccess` over a folder in the test's sandbox, with the cloud's behaviours in the test's hands:
- `setOffline`, so reads of files not downloaded fail at once;
- `setFolderLost`;
- `setUpload`, for every file or one named file: uploaded, uploading, failed, or not reported;
- `setNotDownloaded`, a file in the cloud only;
- `failCopies(after:)`, a copy that stops;
- `readLimits`, `copiedPaths`, and `copiedNames`, to check that every wait was bounded and no file went twice.

`SyncTwoDevices` makes a Mac and a phone, each a real `SyncEngine` with its own files over one drive, and `restart` starts one again from its own files, as after a quit or a crash.
`SyncTestFixtures` makes books, libraries, and entries.

- `SyncTwoDeviceTests`: files arriving out of order are never skipped and the cursor waits, and a restart between exchanges changes nothing.
- `SyncInterruptionTests`: a copy stopped after its first file is finished by the next exchange, and `testAStopAfterEveryStepLosesNothing` stops the engine after each `SyncStep` (`outboxWrite`, `record`, `copy`, `upload`, `read`, `merge`, `registers`, `clock`, `cursors`, `apply`) and restarts it.
  After each stop every change is in the folder or the outbox, never lost or doubled, and the second device ends with the same state.
- `SyncNetworkCaseTests`: offline reads are refused at once and every wait is at most 30 seconds, and a lost folder keeps the changes for later.

A test that adds a step to the engine adds it to `SyncStep`, so the interruption test covers it.

## TEXTMOUTH_SYNC_FOLDER
<!-- id: sync-test-seam-folder; keys: TEXTMOUTH_SYNC_FOLDER, seamFolder, isSeamFolder, DEBUG, sandbox folder, test seam; src: TextMouth/Services/Sync/SyncCenter.swift, TextMouth/Phone/PhoneSyncSettingsModel.swift, TextMouth/Platform/iOS/Views/Settings/PhoneSyncSettingsSection.swift -->

`TEXTMOUTH_SYNC_FOLDER` names a sandbox folder that a Debug build may sync into, as `TEXTMOUTH_EXPORT_TO` does for export.
It exists in Debug builds alone: `SyncCenter.seamFolder()` is compiled under `#if DEBUG` and returns nil otherwise, so a Release build never reads the variable.

With it set:
- the library counts as local, and the folder, or any path inside it, as iCloud Drive (`seamFolder`, `isSeamFolder`), so R6's refusals let a sandbox pass;
- the iPhone's Set Up and Join take the folder as if it had been picked, since a test can't drive the system's picker.

## The real drive
<!-- id: sync-test-real-drive; keys: SyncRealDriveTests, TEXTMOUTH_CLOUD_TEST_ROOTS, SYNC SPIKE, privacy prompt, TextMouth Cloud Tests, orchestrator; src: TextMouthProductionTests/SyncRealDriveTests.swift, TextMouthProductionTests/CloudDriveTestSupport.swift -->

`SyncRealDriveTests` is the spike of the build plan: what iCloud Drive does with the files sync puts in it.
It is opt-in and skips unless `TEXTMOUTH_CLOUD_TEST_ROOTS` lists a folder named TextMouth Cloud Tests (prefix it `TEST_RUNNER_` for xcodebuild), the rules of [Testing on real cloud drives](testing.md).
Only the orchestrator runs it, with the user present, because touching iCloud Drive can put a privacy prompt on the screen; no other agent runs it or sets the variable.

Its cases, each in a run folder of its own with files of random bytes, removed when the test ends:
1. the upload state of change files;
2. a clone uses no second copy;
3. a read back after eviction;
4. a listing with evicted files;
5. the identity token without the entitlement;
6. fetching the text one at a time or all at once;
7. a download's progress as the file system shows it.

Each prints its answers as `SYNC SPIKE <case> (<drive>): …` lines and keeps them with the results.
`SyncFetchSampleTests` is the sample's shape, about 100 made-up files shaped like a library's text, and runs everywhere.

## Reading a sync run in the log
<!-- id: sync-test-log-lines; keys: SYNC_RUN, SYNC_BACKUP, SYNC_MERGE, textmouth_debug.log, DiagnosticLog.storage, held removals; src: TextMouth/Services/Sync/SyncEngine.swift, TextMouth/Services/Sync/SyncCenter.swift, TextMouth/ViewModels/LibraryViewModel+Sync.swift -->

Sync writes only a few lines, as events in the `storage` category of textmouth_debug.log (see [The diagnostic logs](../user/library-logs.md)), and none holds a title or a path.
- `SYNC_RUN: <n> book removals were held back…`: a recording found more removals than a person would make; Sync Now confirms them.
- `SYNC_RUN: <n> stamps from other devices were more than a day ahead…`: a device's clock is far ahead, and this one's clock did not follow.
- `SYNC_RUN: <n> files of this device in the sync folder have stayed unreadable for three runs`: a file of this device in the folder can't be read, so isn't known to be the outbox's own.
- `SYNC_BACKUP: …`: a book couldn't be backed up and is passed by for this launch, or the backup stopped; the text names only the error's type.
- `SYNC_MERGE: …`: a placeholder couldn't be made for a book (named by the first 8 characters of its ID), a removal didn't happen, or the merge's moves were refused.

A run that works writes nothing: read the status line, and the counts a test reads from `SyncExchangeResult`.
A new log tag in sync code needs `LogContentPolicyTests` named in the train request.

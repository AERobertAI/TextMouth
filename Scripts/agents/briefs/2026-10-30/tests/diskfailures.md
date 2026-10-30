# Task `diskfailures`: the library index's and the data-directory move's safety branches, driven

Slug `tests-diskfailures`, branch `tests/diskfailures` from `team/tests`. Read `_common.md` beside this file first. Audit items U03 and U08 (`build/orchestrator/oct30/tests-audit-untested.md` in the main checkout). Tests only, unless a test shows a bug: then stop and post it to `tests-lead` with the evidence.

## U03: Rebuild Library Index never destroys the only copy of the index
Read: `TextMouth/Services/LibraryPersistenceService.swift` 1434-1461 (`replaceUnreadableIndex(with:)`, which throws at 1450), `TextMouth/Services/LibraryLoadResult.swift` 100-108 (`LibraryIndexRecoveryError.couldNotPreserve` and its sentence), `TextMouth/ViewModels/LibraryViewModel+IndexRecovery.swift` 382-396 (`rebuildLibraryIndex()`, its `.rebuildFailed` declared at 65). Before a rebuilt library.json replaces an unreadable one, the old bytes are preserved (`LibraryIndexQuarantine.preserve`); when that fails, nothing is replaced ("a rebuild can never destroy the only copy of an index"). `LibraryIndexRecoveryTests` and `LibraryIndexQuarantineTests` cover the paths that succeed; nothing drives the failure.

New class `LibraryIndexRebuildFailureTests` (new file, `xcodegen generate`), reusing `LibraryIndexTestSupport` and the way `LibraryIndexRecoveryTests` makes a damaged index in a temporary data directory:
1. Make the data directory unwritable (`0o555`, so neither a copy nor a link can be made beside library.json), and restore `0o755` in a teardown block that runs whatever happens. `replaceUnreadableIndex(with:)` throws `.couldNotPreserve(<index URL>)`; library.json keeps its exact bytes; index writes stay suspended (`areIndexWritesSuspended`).
2. Through the model, `rebuildLibraryIndex()` returns `.rebuildFailed` with the sentence `LibraryIndexRecoveryError.couldNotPreserve` gives (pin it exactly, as the listener hears it), and recovery stays open (`indexRecovery != nil`).
3. When the index file vanished after the failed load: nothing is preserved, the rebuilt index is written, and the result is nil (read the code for the exact outcome before asserting it).
If the test host runs as the superuser, permissions do not stop it: `try XCTSkipIf(getuid() == 0, "the superuser writes where permissions forbid")`, as `ArchiveExtractionTests` line 435 does.

## U08: a data-directory move's integrity checks
Read: `TextMouth/Services/DataDirectoryMigrator.swift` 377-379 (`missingSource`), 508-513 (`missingBook`), 535-548 (`invalidLibrary`), and the sentences at 46-48. `DataDirectoryMigrationTests.testMissingTrackedBookRejectsMigrationWithoutPublishingDestination` (line 158) reaches `missingBook` without asserting its sentence; `missingSource` and `invalidLibrary` are never reached.

More methods in `DataDirectoryMigrationTests`:
4. The current data directory removed (and, in a second test, a FILE put in its place) before the move: `.missingSource` and "The current data directory does not exist." (pin the exact sentence), with the data-directory setting unchanged and nothing at the destination or staged beside it.
5. The `missingBook` sentence names the book: give the book a title in another script (for example "Ἰλιάς") and assert the sentence holds it.
6. `invalidLibrary`: only if the code offers a way to make the staged index fail its check without a production change (read 535-548); if it needs a seam, add none and say so in your report (the lead lists it as a follow-up).

## Proof
Break each guarded path and see its test fail: make `replaceUnreadableIndex` replace without preserving (skip the throw) and the U03 tests fail with the bytes changed; remove the `missingSource` check and the U08 test fails. Restore each.

## Classes to run
`LibraryIndexRebuildFailureTests DataDirectoryMigrationTests LibraryIndexRecoveryTests LibraryIndexQuarantineTests`. Files: the new test file, `TextMouthProductionTests/DataDirectoryMigrationTests.swift`, `project.pbxproj`. No production change. Nothing outside the test's own temporary folders.

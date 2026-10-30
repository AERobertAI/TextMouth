# Task `feeditems`: substitution rule edits, a feed item's package in both places, an article's earlier text, and waiting for a network

Slug `tests-feeditems`, branch `tests/feeditems` from `team/tests`. Read `_common.md` beside this file first. Audit items U07, U09, U10, U24 (`build/orchestrator/oct30/tests-audit-untested.md` in the main checkout). Tests only, unless a test shows a bug: then stop and post it to `tests-lead` with the evidence.

## U07: changing, removing, and switching off a substitution rule (on disk, and what the listener hears)
`TextMouth/Services/TextSubstitutionService.swift` 564-584 (`updateRule`, `removeRule`, `toggleRule`), the save at 704-735, the filter that drops disabled rules at 623; only `SubstitutionsSettingsView` calls the three. New class `SubstitutionRuleEditTests` (new file, `xcodegen generate`), with a temporary data directory set up as `MultiMacCrashSafetyTests.swift` line 537 sets one up:
1. Update a rule's pattern: `apply` uses the new pattern at once (its compiled expression was replaced), and substitutions.json holds it.
2. Toggle a rule off: it is not applied, and the file has `"isEnabled" : false` (read the file's actual key); toggle it on again.
3. Remove a rule: it is gone from the file, and the other rules keep their order.
4. An unknown ID changes nothing: the file's bytes are unchanged.
5. An update while the file waits in the cloud, through the existing `readFile` injection (line 452): the file is not written over, and the change is reported unsaved (read how `DataFileFailureReportingTests` checks a report).
6. Patterns with regular-expression characters, and text in another script.

## U09: moving a feed item when a package of its name is in both places (on disk)
`TextMouth/ViewModels/LibraryViewModel+FeedItemMove.swift` 317-340 (`relocatePackage(of:as:root:)`, throws `FeedItemMoveError.packageInBothPlaces` at 334; the enum at 9). More methods in `FeedItemIndexMoveTests`, with `FeedItemIndexTestSupport`: packages at both source and destination give `packageInBothPlaces` and its sentence, with both packages' bytes and modification dates and the row's record unchanged; only the destination: the move goes on, as after a stopped launch; a package name in another script.

## U10: downloading an article again when its earlier text cannot be kept (the listener's edits)
`TextMouth/Services/Feeds/FeedItemPackage.swift` 462-480 (`keepEarlierText(_:in:)`, throws at 477; the error at 640). More methods in `FeedItemRecordTests`: nil earlier text gives nil; the same bytes give nil and make no copy; different bytes give a copy named as `BookTextEditSessions.keepCopy` names one; a read-only staged folder gives `earlierTextNotKept`, and through the importer the download fails with the kept package and its text unchanged. Restore permissions in a teardown block; skip under the superuser (`ArchiveExtractionTests` line 435).

## U24: whether a download the newest-N rule asked for waits for a network
`TextMouth/Services/Feeds/FeedDownloadManager.swift` 1149-1151 (`waitsForANetwork`), used at 779. In `FeedDownloadTests` (after `tests/feedresume` is on the team branch; rebase if needed): `waitsForANetwork` is true for offline and a constrained network and false for not-found and a server error (read its parameter's type); and through the tests' fake network, an offline download the rule asked for keeps waiting with no failure reason recorded, while one the listener asked for fails with the offline sentence.

## Proof
Break each pinned branch (make `toggleRule` not save; make `relocatePackage` move over an existing package; make `keepEarlierText` swallow its error; make `waitsForANetwork` return false) and see its test fail; restore.

## Classes to run
`SubstitutionRuleEditTests FeedItemIndexMoveTests FeedItemRecordTests FeedDownloadTests SubstitutionKeyboardAccessTests MultiMacCrashSafetyTests`. Files: the new test file, `FeedItemIndexMoveTests.swift`, `FeedItemRecordTests.swift`, `FeedDownloadTests.swift` (only new methods, at the end), `project.pbxproj`. No production change.

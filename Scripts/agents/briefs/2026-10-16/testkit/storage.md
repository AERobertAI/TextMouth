# testkit/storage: a storage-failure drill on a disposable disk image

Slug `testkit-storage`. Branch `testkit/storage`, made from `team/testkit` AFTER `testkit/runner` was integrated (`Scripts/test/run-area.py` exists on your branch; if it does not, build the Swift part first and rebase for the script). You build; at most two builders run at once. Read `teams-common.md`'s worker's part first. **This is the riskiest task of the team: read "Safety" before anything else.**

## Why

The acceptance matrix's last row (TODO-2026-09-04.md line 3645): "Storage failures: work in disposable libraries; disconnect/unmount storage during import/save/move; recover from a corrupt index; confirm original files survive reported failures." Existing tests simulate a vanished library by renaming a folder (`DataDirectoryLaunchTests.swift:188-240`, `LibraryFixture.takeAway()`), and `LibraryIndexRecoveryTests` covers a corrupt index. What no test does is lose a REAL volume part-way through an operation, or fill one. A small disk image makes both safe to do on any Mac, and a checksum comparison afterwards checks the thing the user cares about most: the originals and the previous library survive.

## Safety (non-negotiable)

- Opt-in only: every test skips with `XCTSkip("Set TEXTMOUTH_STORAGE_DRILL=1 ...")` unless `TEXTMOUTH_STORAGE_DRILL` is `1`.
- The drill runs only inside the xcodebuild test host. It never launches the app, never reads or writes `~/.TextMouth`, the user's preferences, or any volume other than its own images. The library under test is made inside the image; the originals (files to import) live in the test's sandbox folder OUTSIDE the image.
- Every image: `hdiutil create -size <N>m -fs HFS+ -volname TMDrill-<uuid prefix> -ov <sandbox>/<name>.dmg`, attached with `hdiutil attach -nobrowse -noverify -noautofsck -mountpoint <sandbox>/mnt-<name> <dmg>`, detached with `hdiutil detach -force <mountpoint>`. The image and mount point live under the test sandbox (`FileManager.default.temporaryDirectory`, which the hosted tests make `$TMPDIR/TextMouthTests-<pid>`).
- Teardown always detaches (force) and deletes the image, in `addTeardownBlock` registered BEFORE the attach, even on failure. At the start of the class, find and detach leftovers of an earlier crashed run: parse `hdiutil info -plist`, and detach ONLY images whose path begins with the sandbox base (`$TMPDIR/TextMouthTests-`) AND whose file name begins with `TMDrill-`. Never anything else.
- Run each hdiutil call through a helper that uses `Process`, a 60-second timeout, and returns status and output; never block the main thread indefinitely.
- `Scripts/test/storage-drill.sh` afterwards runs `hdiutil info` and says plainly whether any `TMDrill-` image is still attached (and prints the exact `hdiutil detach -force` command if one is).

## Ground truth (read by range, nothing more)

- `TextMouth/Services/ImportFailure.swift:100-120` (`ImportStep`, `ImportStepObserver = (ImportStep, URL) throws -> Void`: told as each step begins on the staged package; tests use it to make a step fail), `FileImportService.swift:752-800` (`importFile`, `importFileWithReport(from:toFolder:observer:)`; the package is built hidden and published only after every step succeeded; the source is never touched), `ImportStaging.swift` (the hidden staging area and how leftovers are cleaned).
- `TextMouth/Services/LibraryPersistenceService.swift:201-330` (`save`, `saveAndWait`, `flushPendingSave`) and `PersistenceFailureCenter.swift` (how a failed write is reported: wording the user hears).
- `TextMouth/Services/DataDirectoryMigrator.swift` and `DataDirectoryMoveTests.swift` / `DataDirectoryMoveProgressTests.swift` (a data-directory move copies, verifies, switches, and only then removes the source), `StorageGeneration*.swift` (generation markers).
- `DataDirectoryLaunchTests.swift:188-250` (the fixture that takes a library away and brings it back), `LibraryIndexRecoveryTests.swift`, `MoveRollbackFailureTests.swift`, `StorageStatusHonestyTests.swift`: what is already pinned, so you do not repeat it.

## Scenarios (priority order; each a test method; do as many as you can finish well, and say which)

1. **Import while the volume vanishes.** Library folder on the image. Observer detaches (force) when a given middle step begins, then returns normally so the later steps hit a dead volume. Expect: the import throws an `ImportFailure` naming the file; no book row; the original (outside the image) has the same SHA-256 as before. Re-attach the image: no PUBLISHED package for the failed import exists, and whatever staging leftover remains is what the app's own promise allows (find the promise in `ImportStaging`; assert it, do not invent one).
2. **A full disk during import.** An 3 MB image filled with a ballast file until the write fails (`ENOSPC`), leaving a few KB. Import a small TXT book into a library folder on it. Expect: refused with the app's own words (find them: `ImportScratchSpace` / the free-space reserve / `ImportFailure`), nothing published, the ballast and the previous contents unchanged, the original unchanged. Assert the exact wording the user hears, as the code produces it; if the wording is poor for a screen reader, post a finding, still pin it.
3. **Saving the library while the volume vanishes.** Library with one folder saved on the image. Detach force. `saveAndWait` reports failure and the failure is recorded in `PersistenceFailureCenter`. Re-attach: `library.json` is byte-identical to the previous good one (an atomic write never leaves a half file).
4. **A data-directory move whose destination vanishes.** Move a small library (a few files of known checksums) from the sandbox to the image with `DataDirectoryMigrator`; force-detach the image when the copy is part-way (use the progress callback or the file-copy hook the move tests use). Expect: the move reports failure, the source is complete (every file's checksum unchanged), the preference/config still names the source.

For each scenario, compare by SHA-256 (`CryptoKit`), listing what differs by name; the helper that snapshots a folder to `[relative path: digest]` and compares two snapshots is a small type of its own (`FolderSnapshot`), unit-tested in an always-on class.

## What you build

1. `TextMouthProductionTests/DiskImageDrill.swift`: `DiskImage` (create, attach, detach, delete, size, fill-to-capacity), the `hdiutil` runner with timeout, the leftover sweeper, `FolderSnapshot`.
2. `TextMouthProductionTests/DiskImageDrillTests.swift`: always-on unit tests with no hdiutil: `FolderSnapshot` finds a changed file, a missing file, an extra file, and names them; the command builders produce the exact arguments above; the leftover filter picks `TMDrill-` images under the sandbox base only and ignores everything else (feed it canned `hdiutil info -plist` text including a lookalike outside the sandbox).
3. `TextMouthProductionTests/StorageDrillTests.swift`: `final class StorageDrillTests: XCTestCase`, the opt-in scenarios.
4. `Scripts/test/storage-drill.sh` (bash, header comment doubling as `-h`, style of `Scripts/perf-baselines.sh`): `python3 "$(dirname "$0")/run-area.py" --classes StorageDrillTests --env TEXTMOUTH_STORAGE_DRILL=1`, then the `hdiutil info` check. State in its header what it does to the Mac (creates and removes a few MB of disk images in the temporary folder) and how long it takes.

## Tests to run

`DiskImageDrillTests` and `StorageDrillTests` (skip line shown), then the drill for real through the script, once; run it a second time to prove repeatability and that nothing is left attached. Existing classes to run once at the end: `DataDirectoryLaunchTests`, `LibraryIndexRecoveryTests`.

## Do not

Edit the app or an existing test. Use a volume that is not your own image. Leave an image attached. Let a test trap or hang (timeouts everywhere). Use `diskutil` on anything but your image's device.

## Commits

1. `DiskImageDrill` + `DiskImageDrillTests`.
2. Scenario 1 and 2.
3. Scenarios 3 and 4 (if reached).
4. `Scripts/test/storage-drill.sh`.

## Report (at most 15 lines)

Branch; commits; exact result lines; which scenarios are done; what each found (a finding is a good outcome: the app promised something it did not keep); the script's runtime; anything you could not verify.

# Library sync: books, platforms, moments, and the rules
<!-- id: library-sync-store; keys: FR43, placeholder, blobs, SyncFolderIO, moments, rules R1 to R9, StoreBackup, StoreFetch; src: TextMouth/Services/Sync/StoreBackup.swift, TextMouth/Services/Sync/StoreFetch.swift, TextMouth/Services/Sync/SyncFolderIO.swift -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

The second half of [Library sync: the folder, the outbox, and the merge](library-sync.md): how a book's files travel, how each platform reaches the folder, when sync runs, and the nine rules.

## Placeholders and the pointer
<!-- id: library-sync-placeholders; keys: In Cloud, .storeCopy.json, StorePointer, SyncPlaceholder, StoreBookStorage, orphan adoption; src: TextMouth/Services/SyncPlaceholder.swift, TextMouth/Services/Sync/StoreBookStorage.swift, TextMouth/Models/Sync/SyncInterfaces.swift, TextMouth/Services/MaintenanceFileAccess.swift -->

A book another device added, and this one hasn't fetched, is a placeholder: a package holding only its bookInfo.json, made from the row the merge gave it, and `.storeCopy.json`, its pointer.
The pointer (`StorePointer`) names the store, the book's manifest, the manifest's `uploaded` copy, and each file with its digest, size, modification time, and whether it is `onThisDevice`.
Its dot keeps it out of `isPackageContentName`, export, and an older TextMouth's search.
`SyncPlaceholder.make` writes it, writing the same files again after a crash changes nothing, and `SyncPlaceholder.isPlaceholder` is the question: a pointer, and the book's file not on this device.

So every file-level check reads a placeholder as a book not downloaded, and the cloud machinery is reused:
- `StoreBookStorage` is a `BookCloudStorage` over the live one: it answers `notDownloaded` for a placeholder and fetches it on `download(_:)`, keeping the state of a fetch under way or failed, which the package's own files can't say.
- So the row says In Cloud, Download Now and the reader's download view (with Cancel and Try Again) fetch it, and `MaintenanceFileAccess` leaves it alone.
- `BookCloudStates.showsCloudNotes` holds while sync is on.
- Orphan adoption keeps a placeholder (`orphanedBook`), and the path repair passes it by.

A pointer is read only while sync is on (R1): `SyncActivity.isOn` is readable from any thread.
After each sync the host records its placeholders as In Cloud (`LibraryViewModel.syncDidApply`), since the cloud refresher runs only while a Mac Library window is open.

## Blobs, backup, and fetch
<!-- id: library-sync-blobs; keys: SHA-256, content-addressed, manifest, StoreBackup, StoreFetch, budget, staging, backup order; src: TextMouth/Services/Sync/StoreBackup.swift, TextMouth/Services/Sync/StoreFetch.swift, TextMouth/Services/FileDigest.swift -->

A book's files are copied into `Books/<book id>/` as blobs named by their SHA-256 (`StoreBackup.back(up:)`):
- each file is cloned into the device's `Staging/` first and hashed there, so the digest is of exactly the bytes copied, even if the book changes meanwhile;
- a blob already in the folder isn't copied again, and nothing is written over a file (R4);
- the manifest, named by the SHA-256 of its own bytes, lists every file with its path, digest, blob, size, and role (content, record, other), and is written only when the files' digests differ from the existing one's, ignoring the record;
- the pointer lists every file before the first fetch, and marks one present only by its digest;
- a package holding a symbolic link isn't backed up, and one with `cachedAudio` leaves that out.

Which books go when, in `SyncCenter.backUpBooks`:
- text books first, then smaller first, ties by ID, so the order is the same every run;
- `StoreBackupBudget` limits what is copied but not yet evicted to 2 GB, or the free space less 1 GB when that is smaller; a book over the budget waits unless nothing is held, and then goes alone;
- the book's `content` register is recorded only once its copy has uploaded, so another device never sees a row whose files aren't there;
- a book that can't be backed up is passed by for the launch, with a `SYNC_BACKUP` line.

`StoreFetch.fetch` fills a placeholder:
- each blob goes into `Staging/`, is checked against its SHA-256 and size, and only then moved in, so a package never holds a half file; a blob that doesn't match is `.damaged` and stays in staging;
- a manifest path must be plain names, never `..` or absolute (`StoreFetch.isSafe`), never the pointer's own name, and a blob named `<digest>.<ext>`;
- each blob has 60 seconds, counting only time stalled; a cancelled fetch stops between files and the pointer says what is here, so the next fetch goes on;
- each file is written at its manifest path, and the host sets the row's `filePath` (`syncDidFetch`); the device's own record is kept;
- on the iPhone the package is left out of iCloud Backup.

## SyncFolderIO and each platform's folder access
<!-- id: library-sync-folder-access; keys: SyncFolderAccess, PlainSyncFolderAccess, PhoneSyncFolderAccess, NSFileCoordinator, bookmark, security scope, staged write; src: TextMouth/Services/Sync/SyncFolderIO.swift, TextMouth/Services/Sync/PlainSyncFolderAccess.swift, TextMouth/Platform/iOS/Services/PhoneSyncFolderAccess.swift, TextMouth/Services/Sync/SyncSeams.swift -->

The engine reaches the folder only through the `SyncFolderAccess` protocol (`withFolder`, `list`, `read`, `fetch`, `write`, `copyIn`, `uploadState`, `evictLocalCopy`, `sweepPartialFiles`).
`SyncFolderIO` is the work both platforms share, so the two never differ:
- a staged write: the file is made whole under a hidden `.partial-<uuid>` name and moved in, so a crash never leaves a half file under a final name, and `moveItem` never goes over a file;
- reads and copies through `NSFileCoordinator` on a queue of their own, cancelled at the limit (30 seconds), so a call stuck on iCloud Drive holds neither the engine nor a cooperative thread;
- `waitUntilHere`: it asks iCloud Drive for one file once, answers `.offline` at once when the network is gone, and gives up as `.notDownloaded` after a limit counting only time with no bytes arriving, so a long file that is arriving is never cancelled;
- the upload rule (`uploadState`): a folder with no sync flags reports nothing; where flags exist a missing upload flag means not yet; a quota error is `.failed(.outOfSpace)`; any other error is still uploading, never offline;
- `isDeleted`, which treats a folder in a trash or Recently Deleted as missing, and the sweep of `.partial-` files older than an hour.

The Mac's `PlainSyncFolderAccess` finds the folder from its bookmark (`DataDirectoryPreferences.makeBookmark`) and renews a stale one.
The iPhone's `PhoneSyncFolderAccess` wraps it with the picked folder's bookmark and its security scope, opened around each `withFolder`, and turns the system's errors into `SyncProblem`s; `TextMouthAppDelegate` installs it through `SyncFolderAccessFactory`.
The folder panel and the Files picker are each platform's own interface (`SyncSettingsSection`, `PhoneSyncSettingsSection`), over one `SyncSettingsModel` for the refusals, commands, and words.

## The moments
<!-- id: library-sync-moments; keys: SyncScheduler, SyncReason, launch, hourly, networkBack, afterChange, quit, NWPathMonitor; src: TextMouth/Services/Sync/SyncScheduler.swift, TextMouth/Services/Sync/SyncCenter.swift, TextMouth/Services/NetworkReachability.swift -->

`SyncCenter.moment(_:)` takes a `SyncReason`: `launch`, `active`, `hourly`, `networkBack`, `afterChange`, `syncNow`, `background`, and `quit`.
`SyncScheduler` is a value with no timers: the center feeds it changes and path reports with their times, asks `nextDue`, and sleeps until `nextWake`; `SyncTiming` holds the constants.
- Launch: `LibraryViewModel` installs the center once it has the library (`install(host:dataDirectory:)`); sync turns on only where this data directory's `Sync/` holds this store's files and R6 holds.
- After a change: three minutes after the first change not yet sent, then at most every three minutes.
- Hourly: an hour after the last run ended, or after sync turned on.
- The network back: a satisfied path after one that wasn't, held 30 seconds, at most once in five minutes.
- Sync Now, and on the iPhone each activation after the first (`PhoneSyncLifeCycle`).
- The iPhone to the background, and the Mac quitting: record and copy only, bounded at 20 and 2 seconds, reading nothing and applying nothing.

One run at a time: a moment during a run is folded (`SyncCenter.folded`) into the one run that follows it.
A run records, renews a stale bookmark, opens the folder, reads `store.json` (expecting this store), copies the outbox, reads the upload states, reads other devices' files, merges, applies, saves, and lets the backup go on.

`NetworkReachability` keeps one `NWPathMonitor`, whose reports carry `isExpensive` and `isConstrained`.
An expensive or constrained path changes no write: writes are local and iCloud Drive decides when to upload.
It does stop unasked downloads (`allowsBackgroundDownloads`, below) and adds the cellular hint to a stalled fetch (`SyncActivity.pathIsCostly`).

## The iPhone's background hold
<!-- id: library-sync-iphone-hold; keys: beginHold, HoldEnd, didEnterBackground, background task, 20 seconds, PhoneLifeCycle; src: TextMouth/Phone/PhoneSyncLifeCycle.swift, TextMouth/Platform/iOS/App/TextMouthAppDelegate.swift -->

`PhoneSyncLifeCycle.install` joins the moments to the phone's life cycle.
- On `didBecomeActive` it fires `.active`, except for the first activation of an app launched to the screen, whose launch sync has begun already; an app launched with no screen counts its first.
- On `didEnterBackground` it begins a background hold named sync, fires `.background`, and ends the hold at whichever comes first: the sync going idle (`waitUntilIdle`), or `backgroundHold`, 20 seconds.
  `HoldEnd` makes the end run once however many times it is asked, since the idle wait can't be cancelled.
- With sync off every handler does nothing (R1).

## Keep on All Devices and the downloads after a sync
<!-- id: library-sync-keep-downloads; keys: SyncBookField.keep, KeptBooks, keptBookIDs, setKeep, downloadEvictedKeptBooks, allowsBackgroundDownloads, Low Data Mode; src: TextMouth/Services/KeptBooks.swift, TextMouth/ViewModels/LibraryViewModel+Cloud.swift, TextMouth/ViewModels/LibraryViewModel+Sync.swift, TextMouth/Services/NetworkReachability.swift -->

Keep on All Devices is a register, `SyncBookField.keep`, `true` or `false`, stamped by `SyncCenter.setKeep(_:for:)` when a person chooses.
`SyncProjection.of` never projects it and `SyncMerge.apply` applies it to no row, so it lives only in the registers and the folder, and adds no key to library.json, config.json, or bookInfo.json (R5).
`SyncCenter.keptBookIDs` hands the set to `KeptBooks.setSyncedBooks`, and `KeptBooks.isKept` answers for the person's own keeps, the reading list's, and these.

After each run `LibraryViewModel.syncDidApply(keptBookIDs:mayDownload:)` calls `downloadEvictedKeptBooks(in:afterSync: true)`:
- it downloads kept and listed books that are only in the cloud here, one at a time, as many as fit in the free space less 1 GB (`downloadWhatFits`, sized from the manifests by `StoreBookStorage.bytesToDownload`);
- `mayDownload` is `NetworkPathReport.allowsBackgroundDownloads`: a satisfied path that is neither expensive nor constrained, so it starts on Wi-Fi or Ethernet with Low Data Mode off and waits otherwise; nothing starts before the first path report;
- a library in a cloud folder is left to the cloud refresher, and a synced library to this call alone;
- the reading list's keeping is a choice of each device (`keepsReadingListBooks`), worked out and never written (`observeReadingListKeeping`).

## Freeing a synced book
<!-- id: library-sync-freeing; keys: StoreRemoval, SyncRemovalRefusal, FreeingCheck, removeDownloadAsync, BooksOnThisDevice, SyncDeviceSettings, BooksFreedOnPurpose, sweep; src: TextMouth/Services/Sync/StoreRemoval.swift, TextMouth/Services/Sync/StoreBookStorage.swift, TextMouth/Services/Sync/SyncCenter.swift, TextMouth/Services/Sync/StoreBackup.swift, TextMouth/Models/Sync/SyncDeviceSettings.swift, TextMouth/Services/Sync/SyncSpaceSettings.swift, TextMouth/ViewModels/LibraryViewModel+Cloud.swift -->

`StoreRemoval.removeDownload(of:bookID:mayDownload:)` frees a book's own files (`StoreBackup.role` content) and leaves the record, the text, and every other file.
Never the last copy.
In order, each step before the next:
- the pointer names this store and a manifest; the manifest read from the folder is what its name says;
- every blob and the manifest are listed and `uploadState` is `.uploaded` (not `.uploading`, not `.notReported`), then each file here that would go is the manifest's by size and SHA-256;
- each blob is read back into staging and matches the manifest;
- the files are listed again and compared by size, time, and file number, and `FreeingCheck.current` is asked (the library's protections, row, setting, sync on, `maySyncNow`, on the main actor);
- the pointer is written with the files away, then the entries are removed, then the folder's copies of the blobs are evicted.
A refusal is a `SyncRemovalRefusal`, with the package unchanged; `SyncWording.removalRefusal` says it.
`mayDownload` is false on a costly path, checked before anything is hashed.

`SyncCenter.removeBookDownload` refuses while the backup has the book queued or awaiting its upload record, and unless the registers hold its content (`backupForbidsFreeing`).
`StoreBackup.back(up:)` refuses a package whose pointer says a file is away, and `markUploaded` takes each file's `onThisDevice` from the files found.
`BookCloudStorage.removeDownloadAsync` is the seam; `StoreBookStorage` answers it, refusing a book being fetched, and with sync off in a local library.

The settings are `SyncPreferences.booksOnThisDevice`, `removeAfterDays`, and `removalsBeganAt`, with `freedOnPurpose`: machine-local keys, never in config.json.
`SyncSpacePolicy` counts days in 24-hour units from the latest of the opening, the play, the pointer's last write, and `removalsBeganAt`.
`LibraryCloudCommands.removeUnopenedDownloads` is the sweep after each sync: one at a time, at most 25 removals, one summary.
`downloadMissingBooks` is All books: it checks `pathIsCostly` and the choice before each book, and skips what `BooksFreedOnPurpose` holds.

## The rules R1 to R9
<!-- id: library-sync-rules; keys: R1 to R9, inert, outbox first, one writer, SyncLaunchHold, massRemovalLimit, SyncWording; src: TextMouth/Services/Sync/SyncCenter.swift, TextMouth/Services/Sync/SyncFolderIO.swift, TextMouth/Services/Sync/SyncEngine.swift, TextMouth/Models/Sync/SyncProjection.swift, TextMouth/Models/Sync/SyncWording.swift, TextMouthProductionTests/OnDiskContractTests.swift -->

Each rule has a test in the branch that first needed it.
- R1, inert until set up:
  - `SyncCenter.install` activates only with a stored bookmark and store ID, and `moment`, `libraryDidChange`, and `syncNow` return while `status.isOn` is false;
  - `StoreBookStorage` reads no pointer while `SyncActivity.isOn` is false;
  - the menu items, the Keep commands, and the iPhone's action show only while sync is on.
  Tested by `SyncCenterTests.testInertUntilSetUp`.
- R2, the library never waits: `SyncEngine` is an actor opened off the main actor; every coordinated call has a limit (`SyncFolderIO.coordinationLimit`, the reader's `SyncReadLimits`, `waitUntilHere`); offline is an ordinary state.
- R3, the outbox first: `SyncEngine.append` writes the outbox file before the registers or the baseline, and nothing is copied that isn't in the outbox.
- R4, one writer per file: `stagedPlace` never goes over a file; `store.json` is made only by `SyncFolder.create`; `device.json` alone is written with `replacing: true`; blobs, manifests, change files, and snapshots are written once.
- R5, no new key in library.json, config.json, bookInfo.json, or a feed's record: `OnDiskContractTests` key sets pass unchanged; Keep on All Devices, a book's content, and a feed's synced fields live in the registers.
- R6, a local library and an iCloud Drive folder: `SyncCenter.requireLocalLibrary` and `requireICloudDrive` refuse otherwise, and `SyncSettingsModel.refusal` says so before anything is made.
- R7, a removal crosses only when a person made it in a running TextMouth:
  `SyncLaunchHold` puts back a book, folder, or feed missing at launch unless its package holds a removal marker, and `massRemovalLimit` holds a mass removal until Sync Now confirms it; books and feeds are each counted against their own number.
- R8, iCloud decides: TextMouth never forces an upload, and asks for a download only of the file it is about to read; it reads upload states at moments and during a fetch.
- R9, everything spoken: every state, refusal, and result is a `SyncWording` line, pinned by `SyncWordingTests`, and translated into every interface language before its branch merges.

# Syncing the library between the Mac and the iPhone: the build plan (November 25, 2026)

Designer `syncplan` (Opus), branch `research/cloud-sync-plan`, main e7c6fd20e (0.5.12), for the user's message of 07:05 today and their question about changes made offline.
The design they remember is option C, the cloud store, of `research/LOCAL-FIRST-LIBRARY-RESEARCH-2026-11-13.md` (the research).
As in a version control system, each device keeps the whole library and records its own changes; unlike one, it keeps each value's latest change, not a history.
`research/LOCAL-FIRST-PHASE1-DESIGN-2026-11-15.md` (Phase 1's design) was never built; this plan takes its formats where they fit, and adds the research's Phases 2 and 3.
Nothing of the user's library or drives was read.

## Summary

1. Friday's scope: a TextMouth Sync folder in iCloud Drive; books' files in it by SHA-256; each device's changes in stamped files only it writes; one merge everywhere; books fetched when opened.
2. Every change goes first into an outbox in the device's own library, and leaves it only once iCloud Drive reports its copy uploaded: offline, nothing is lost.
3. Sync runs at launch, hourly, when the network returns, three minutes after a change, and on Sync Now.
4. A recorder compares the library with what it last recorded, so every writer on both platforms is covered.
5. A book not on a device looks like a cloud book, so the cloud's row note, Download Now, and download view are reused.
6. Four branches start at once from one commit of interfaces, and merge Thursday and Friday.
7. The iOS 27.2 phone probably needs Xcode 27 and macOS 26.6, which don't fit in 9 GB; GitHub's simulator checks the iPhone half meanwhile.

## 1. Friday's scope

### What the user can try on Saturday

- On the Mac, a Sync section in Storage settings: Set Up Sync… makes TextMouth Sync in a chosen iCloud Drive folder; Join Sync Folder… uses one another device made.
- On the iPhone, the same in Settings, the folder picked in Files and kept as a bookmark.
- The Mac copies every book into the folder in the background, text books first, smaller first.
- The iPhone's library fills with the Mac's books as they upload, each downloaded when opened.
- Both ways: places, bookmarks, skipped headings, books' details and own voice and speed settings, folders, the reading list, added books, and removals.
- Sync Now: the Mac's Library menu (Command-Option-S proposed); the iPhone's Settings, and a VoiceOver action on the Library's summary.
- Today's library-in-a-cloud-folder stays as it is; sync is refused for it.

### What waits

- Freeing space (Remove from This Mac), and the read-back that proves a copy first.
- Removing a device's downloads of books unopened for some days (section 16).
- Settings, substitutions, feeds, statistics, sorts, views, folders' sort and listening options, and the manual order.
- A text edit reaching a device that has the book already: each backs up its own text, and places follow their words (`PlaceRelocator`).
- Google Drive, Dropbox, CloudKit, and merging the old Google Drive copy.
- Deleting from the folder, and folding duplicates together.

## 2. Rules every branch keeps

Each has a test in the branch that first needs it.
- **R1. Inert until set up:** no new file, task, word, or control before a folder is chosen.
- **R2. The library never waits:** file work off the main thread, every wait bounded, offline an ordinary state.
- **R3. The outbox first:** a change is in the device's own library before any copy exists.
- **R4. One writer per file:** blobs (a book's files, named by SHA-256), manifests, `store.json`, change files, and snapshots are written once; `device.json` alone is replaced.
- **R5. No new key** in library.json, config.json, or bookInfo.json, so `OnDiskContractTests`' key sets pass unchanged.
- **R6. A local library, an iCloud Drive folder:** refused for a data directory in a cloud location or a folder elsewhere (`UbiquitousItemStatusProvider.swift:168`).
- **R7. A removal crosses only when a person made it** in a running TextMouth; a book or folder missing at launch is put back.
- **R8. iCloud decides:** TextMouth never forces an upload or a fresh download, and reads statuses only at moments and during a fetch.
- **R9. Everything spoken:** each state, refusal, and result in `SyncWording`, pinned by a test, in all 24 languages before its branch merges.

## 3. The folder and the device's own files

### The sync folder

```
TextMouth Sync/store.json
TextMouth Sync/Books/<book id>/<sha256>.<ext>, <sha256>.manifest.json
TextMouth Sync/Devices/<device id>/device.json, <seq>.changes.json, <seq>.snapshot.json
```

- sync-store's `SyncNames` and `StorePointer.fileName` hold these names, pinned by `OnDiskContractTests`: lower-case UUIDs and digests, 12-digit `seq`, extensions of 1 to 8 `a-z0-9` or `bin`, plain folders (iCloud Drive syncs a package as one item).
- `store.json` is made `.withoutOverwriting`, as `LibraryIdentity.adopt` does (`LibraryIdentity.swift:74`), only in a folder Set Up Sync just made; Join waits 60 seconds for it and never makes one.
- JSON with sorted keys and dates to the second, `formatVersion` 1; a higher one is left alone, and "a later TextMouth" said.
- A change file that doesn't decode, or holds other than `count` entries, is not here yet.
- A snapshot holds every value its device knows, so any device's newest snapshot rebuilds the shared state.
- A manifest lists a book's files and blobs, without a date; it leaves out the pointer, `.DS_Store`, and `cachedAudio`, and a bookInfo.json change alone makes none.
- A blob already there isn't copied again, a fetch checks each against its name, and a package holding a symbolic link isn't backed up.
- The pointer, `.storeCopy.json` in each package, names its manifest and which files are on this device; its dot keeps it out of `isPackageContentName`, export, and an older TextMouth's search.

### The device's own files

In `Sync/<store id>/` in the data directory, on the device's own disk:
- `device.json` (`deviceID`, `incarnation`, `installID`, `lastSeq`), `clock.json`, and `cursors.json` (each other device's last `seq` merged);
- `registers.json`, every key's winning entry, with `throughSeq`, the last outbox file in it; `baseline.json`, the library's values as last recorded or applied;
- `Outbox/`, with `outbox.json` giving each file's state (written, copied, uploaded); and `Staging/`.

The folder's bookmark, the store's ID, and `installID` are `SyncPreferences`, shaped as `DataDirectoryPreferences` (`DataDirectoryAvailability.swift:14`), their keys in `localStoreKeys` (`ConfigService.swift:781`).
A device's ID is made when its library joins, so two libraries on one Mac are two devices.
A library restored onto another install finds another `installID`, and a copy on the same install a `seq` above its `lastSeq` or another `incarnation`: either takes a new ID and publishes a snapshot.

## 4. The outbox, and changes made offline

The user asked whether a change file stays on the device without Wi-Fi: it does, until iCloud Drive says its copy uploaded.
1. The recorder writes each batch of stamped entries to `Outbox/<seq>.changes.json`, atomically, with `clock.json`; the registers and baseline follow each merge, and at least every five minutes.
2. Each moment that reaches the folder copies every outbox file still written, or copied but now missing, into `Devices/<id>/`: a local copy, needing no network, which iCloud Drive uploads when it can.
3. Each moment reads the copies' upload states (the ubiquitous-item upload keys, through `SyncFlagReporting`, `UbiquitousItemStatusProvider.swift:30`).
4. A file leaves the outbox once it and a later snapshot have uploaded; one that never uploads stays, counted as waiting.
5. A file sent again keeps its name and bytes, and an entry merged twice changes nothing: never lost, never doubled.
6. After a crash, outbox files past `throughSeq` go back into the registers, and a change in library.json but in no outbox file is found by the next recorder.
7. Where no upload state is reported, perhaps on the iPhone, a copy counts as sent, not uploaded.

## 5. The state and the merge

### Stamps

- An entry is a value and its stamp: milliseconds, a counter, and the device ID, in that order (a hybrid logical clock).
- `next(at:)` takes the later of the last stamp and the clock, so a clock set back never dates a change before an earlier one; `observe` raises the clock past each stamp merged.

### Keys and values

- A book:
  - `presence`; `content`, the uploaded manifest with what a device lacking the book makes its row from (only the manifest is compared);
  - the details, each with `byHand` from `HandEdits` (`Book.swift:455`); `folder`, by folder ID;
  - the settings (`localVoiceID` to `localSkipBackwardUnit`, `Book.swift:429-437`); `position`, with date and anchor (`Book.swift:2601`); `skippedHeadings`, three lists as one (`:432-434`); `lastOpened`.
- A bookmark, by book and `id` (`Book.swift:2696`): chapter, offset, label, date, anchor; never `number`, which removals renumber (`Library.swift:585`).
- A folder, by `BookFolder.id` (`BookFolder.swift:4`): `presence`, `name`, and `parent` by ID; paths name folders today, so the projection and the applier translate.
- The reading list (`ReadingList.swift:16`): a key per book, and its three options.
- Left out: feed items and feeds' folders, `Library.unreadableRows`, the manual order, playback times, and what a device keeps for itself.

### How each kind merges

- Each key keeps its highest entry, `byHand` first, then the later stamp: one fixed order, so any order of merging gives one result, merging twice changes nothing, and a re-read of a file never replaces a person's edit.
- A book or folder is removed when its removal mark is later than all its other entries, so a later change elsewhere brings it back (research, section 5).
- Bookmarks merge one by one, keeping both devices' additions, numbered by date, then ID.
- The reading list sorts by key, then ID; `SyncOrderKey` makes keys between neighbours, only for moved books, so an addition on one device and a move on the other both stand.
- Folders: paths walked by parent ID; a removed parent's children go to its nearest live ancestor; a cycle is cut at the latest parent change, to the top; a folder deeper than `BookFolder.maxDepth` (4) rises to it.
- Two live folders of one name under one parent fold into the older, the applier recording the moves and the removal, alike on every device.
- `SyncRegisters.merge` and `SyncMerge.apply` are pure, as `PlaceRelocator` is.

## 6. Recording and applying, on today's code

### Every writer changes `LibraryViewModel.library`

It lives in `LibraryViewModel.library` (`LibraryViewModel.swift:136`), whose `didSet` sees every change; the iPhone makes the same model (`PhoneAppModel.swift:50`), so each writer serves both.
- Details and settings: `updateBook(id:_:)` (`LibraryViewModel.swift:570`), from `updateBookMetadata` and its siblings (`LibraryViewModel+BookOperations.swift:738, 864, 898, 908`), and the metadata refresh (`LibraryViewModel+MetadataRefresh.swift:206`).
- Positions: `persistReadingPosition` (`LibraryViewModel+BookOperations.swift:688`), from `ReaderViewModel.savePosition` (`ReaderViewModel.swift:2401`) every 30 seconds of play and each move; a close saves only a moved place (`:2417`).
- Bookmarks: `addBookmark`, `updateBookmarkLabel`, `removeBookmark` (`LibraryViewModel+Bookmarks.swift:10, 30, 38`), outside `updateBook`.
- Skipped headings: `updateSkippedHeadings` (`LibraryViewModel+BookOperations.swift:877`).
- The reading list: `editReadingList` (`LibraryViewModel+ReadingList.swift:470`), `Library.removeBook`, and `removeFolderAndContents` (`Library.swift:519, 695`).
- Folders: creating, removing, moving, renaming (`LibraryViewModel+FolderManagement.swift:62, 100, 138, 208, 238`).
- Adding: `Library.addBook` (`Library.swift:506`), from imports, Keep Both, and orphan adoption (`FileImportService.swift:3886`).
- Removing: `removeBooksReturningOutcome`, `removeBooksFromLibraryOnly` (`LibraryViewModel+BookOperations.swift:156, 41`).
- Without a person: `takeMovedPlaces` (`Book.swift:3019`), Replace Existing (`DuplicateReplacement.swift:242`), the launch repair (`LibraryViewModel+Migration.swift:40`).

### The recorder

- `SyncRecorder` hears of a change from one line in that `didSet`, and runs 2 seconds after the last change, before each merge, as the iPhone goes to the background, and as the Mac quits.
- It compares the library with `baseline.json`, skipping books equal to their baseline, and stamps each changed key (`SyncMerge.changes`).
- Phase 0 keeps a place saved without moving at its date (`Book+ReadingState.swift`), so reopening a book is no change.
- Its first run after launch stamps what an older TextMouth left in library.json.
- A book or folder missing then is put back (R7), unless its package holds a retirement marker (`RemovedFromLibraryMarker.swift:19`), a person's removal.
- It doesn't run while a merge is applied.

### Applying a merge

`LibraryViewModel` conforms to `SyncLibraryHost`, and applies on the main actor:
1. the recorder stamps this device's changes, and the entries read off the main thread are merged in;
2. `SyncMerge.apply` gives the rows changed, books to add and remove, and whether packages move;
3. rows change in place with `save()`, and records are written by a new `saveBookInfo(for:asMerged:)`, which skips `takeStandingReadingState` (`Book.swift:2100`), so a record's older place can't stand over the merged one;
4. folder changes and moves go through `performLibraryTransition` (`LibraryViewModel+BookOperations.swift:363`), the merged library proposed, which moves packages and keeps changes made meanwhile;
5. a new book gets a placeholder (a package of its record and pointer) and joins by `Library.addBook`, which refuses an `md5Hash` this device has (`Library.swift:507`), so a book imported on both stays one on each;
6. removals take the delete path, with the device's Trash setting (`FileImportService.swift:2712`), unasked;
7. `baseline.json` takes the applied values key by key, so a change made meanwhile is still found.

A merge waits while storage work is held, and nothing syncs while the library is unavailable or recovering.
A reader at rest whose book gets a later place moves there and says so; a playing one plays on, and its next checkpoint wins.
A voice the device lacks isn't applied.

### A book not on this device

- `StoreBookStorage`, a `BookCloudStorage` (`CloudStorageContract.swift:577`) over the live one, answers `notDownloaded` for a placeholder and fetches it on `download(_:)`.
- So it shows In Cloud, Download Now and the reader's download view fetch it with Cancel and Try Again (`ReaderViewModel+CloudDownload.swift:555`), and maintenance leaves it (`MaintenanceFileAccess.swift:93` answers `inCloud`).
- `BookCloudStates.showsCloudNotes` (`CloudStorageContract.swift:689`) holds while sync is on; Keep on This Mac and Remove Download stay for cloud libraries.
- A fetch checks each blob's SHA-256 and size, stages it, and moves it in, keeping the device's own record and clearing a page stamp that noted the missing file.
- Orphan adoption keeps a placeholder (`orphanedBook`, `FileImportService.swift:4060`), and the path repair passes it by (`LibraryViewModel+Migration.swift:283`).
- An older TextMouth reads the library as before (R5) and ignores `Sync/` and the pointer, but can't open a placeholder, may stamp it failed for pages, and leaves it out of a Rebuild Library Index, which the next newer launch undoes (R7).
  Hence version 0.6.0 (question 8); `SyncOlderVersionsTests` pins these points first.

## 7. Sync moments and the network

### The moments

- **Launch,** once `startLibrary` (`LibraryViewModel.swift:486`) has the library; on the iPhone, each activation too (`PhoneLifeCycle.swift:47`).
- **Hourly** while TextMouth runs, on the iPhone in front or playing.
- **The network back** (below).
- **After a change:** three minutes after the first unsent change, then at most every three minutes.
- **Sync Now.**
- **The iPhone to the background:** record and copy the outbox, in a background task of at most 20 seconds, reading nothing.
- **The Mac quitting:** record, and copy for at most 2 seconds.
- **One run at a time:** moments during a run make one run after it; Sync Now then says nothing new, and that run's outcome is announced.

A run opens the folder, records, copies the outbox and reads upload states, reads other devices' new files, merges, applies, saves, and lets the backup go on.

### The network

- `NetworkReachability` (`NetworkReachability.swift:26`) keeps one `NWPathMonitor`; sync-store watches its reports, with `isExpensive` and `isConstrained`.
- Back: a satisfied path after one that wasn't, held 30 seconds; at most one such sync in five minutes.
- An expensive (cellular, hotspot) or constrained (Low Data Mode) path changes nothing: writes are local, iCloud Drive decides when to upload, and change files are read within their limits.
- No blob is read except for a book a person opens or downloads.

### Each case, at each moment

In each case the library stays whole on the device (the research's W1), nothing blocks the interface, and the next moment that works catches up.
- **Offline:** every moment records and copies the outbox; uploads wait; files not downloaded are skipped at once; Sync Now says the changes wait.
- **The folder missing, or its bookmark stale:** a stale bookmark is renewed; a missing folder's work is skipped while the outbox grows, and Sync Now says so; once it is back or joined again, everything goes.
- **iCloud signed out:** its folder goes, as above.
- **Uploads paused or slow:** copies stay uploading and counted; nothing goes twice.
- **Out of space** (`NSUbiquitousFileNotUploadedDueToQuotaError`): the backup stops copying blobs; change files are still copied; the status says iCloud Drive is full.
- **Another device's file not downloaded, or evicted:** 30 seconds a file, two minutes a moment; one not arrived holds that device's cursor, one half there is not here yet, and that device's next snapshot covers one that never reads.
- **The iPhone on cellular, in Low Data Mode, or with iCloud Drive's cellular data off:** as above; a fetch stalled 60 seconds on an expensive path adds "If iCloud Drive can't use cellular data, connect to Wi-Fi."

### What a person hears

The Sync section's status line speaks the first state that holds:
- "Sync is off."
- "Syncing…"
- "Offline. 3 changes wait on this Mac, and will be sent when the network is back."
- "TextMouth can't find the TextMouth Sync folder in iCloud Drive. It may have been moved or deleted, or iCloud Drive signed out. Your library on this Mac is as it was."
- "iCloud Drive is full, so 3 changes and 138 books aren't uploaded. Your library on this Mac is as it was."
- "A later TextMouth made this sync folder. Update TextMouth to use it."
- "3 changes are waiting for iCloud Drive to upload them."
- "Some changes from iPhone haven't downloaded yet. TextMouth will try again."
- "Up to date. Last synced at 9:41 AM."

Then, as they apply, "Last heard from iPhone at 9:40 AM." and "Backing up books: 612 of 750."; the iPhone's lines say "this iPhone".
Sync Now announces "Syncing.", then "Synced. 4 changes from iPhone.", "Synced. Nothing new.", or the status line.
Automatic syncs are silent, but for one notice when sync stops working, until it works again, and "Moved to the place saved on iPhone." for an open reader.
All go through `VoiceOverAnnouncer.announce` (`VoiceOverAnnouncer.swift:75`); the line is announced after a person's command (`StorageSettingsView.swift:75`).

## 8. The branches

### Start and merge

- **Step 0, the orchestrator, first half hour:** `sync/base` from main, with section 9's two files and `SyncWording.swift` (section 10), bodies inert, through `make typecheck-tests`.
- All four branch from it; only each file's owner edits it, and others ask on the board.
- Merge order: sync-core, sync-store, sync-mac, sync-iphone, each rebased on main, with an outside review, a fix round, and a check.
- Tests go in a new `[sync]` area of `Scripts/test/areas.conf`; shared ones join `TextMouthiOSTests`' sources in `project.yml`.

### sync-core

- **Files:** `TextMouth/Models/Sync/` (`SyncStamp`, `SyncKey`, `SyncRegisters`, `SyncProjection`, `SyncMerge`, `SyncOrderKey`, `SyncFormats`), and `TextMouth/Services/FileDigest.swift`, the streaming loop that `md5Hash(of:readingChunksWith:)` (`FileImportService.swift:2834`) then shares.
- **Tests:** `SyncStampTests`, `SyncRegistersTests`, `SyncProjectionTests`, `SyncApplyTests`, `SyncOrderKeyTests`, `SyncMergePropertyTests`, `SyncFormatTests`, `FileDigestTests`, and the formats in `OnDiskContractTests`.
- **Interface lines:** `SyncWording`'s translations.
- **Order:** formats and stamps; registers; projection and changes; applying; order keys; properties.

### sync-store

- **Files:** `TextMouth/Services/Sync/`: `SyncCenter`, the `SyncEngine` actor, `SyncRecorder`, `SyncOutbox`, `SyncFolder`, `SyncReader`, `StoreBackup`, `StoreFetch`, `StoreBookStorage`, `SyncScheduler`, `PlainSyncFolderAccess`, `SyncPreferences`, `SyncLocalFiles`.
- `TextMouthPaths` gains `Sync`, and `localStoreKeys` gains `SyncPreferences.keys`.
- **The backup:** a book at a time, text books first, then smaller first; each file hashed once, cloned into `Staging/` (`FileManager.copyItem`), sized, and moved into `Books/<id>/`, never over a file; then the manifest and the pointer.
- A book's `content` is stamped once the drive reports every blob uploaded, or, where it reports nothing, once copied.
- **Its budget:** 2 GB not yet evicted, or the free space less 1 GB if smaller; uploaded blobs are evicted (`removeLocalCopy`, `UbiquitousItemStatusProvider.swift:375`); the spike may raise it.
- **Tests:** on `SyncTestDrive` and `SyncTwoDevices`, `SyncOutboxTests`, `SyncEngineTests`, `SyncFolderTests`, `SyncReaderTests`, `StoreBackupTests`, `StoreFetchTests`, `SyncSchedulerTests`, and section 11's; opt-in, `SyncRealDriveTests` and `SyncRehearsalTests`.
- **Log tags:** `SYNC_RUN`, `SYNC_OUTBOX`, `SYNC_MERGE`, `SYNC_BACKUP`, `SYNC_FETCH`, for `LogContentPolicyTests`.
- **Order:** local files and outbox; the folder; a run on the test drive; recorder; reading; scheduler; backup; fetch; `SyncCenter`.

### sync-mac

- **Shared code:** section 6's places, with one line each in `library`'s `didSet` and in `startLibrary` (beside `reportConflictCopiesInBackground()`, `LibraryViewModel.swift:547`), and the host in a new `LibraryViewModel+Sync.swift`.
- **Mac code:** a `SyncSettingsSection` after library maintenance (`StorageSettingsView.swift:709`), with `NSOpenPanel`s as Change Location's; `ShortcutAction.syncNow` (`KeyboardShortcut.swift:8`) near New Folder (`MenuCommands.swift:562`).
- `TextMouthApp` installs `StoreBookStorage` beside the cloud services.
- **Tests:** first `SyncOlderVersionsTests` (today's code with a placeholder); then `SyncLibraryHostTests`, `SyncPlaceholderTests`, `SyncReaderPlaceTests`, `SyncSettingsSectionTests`, `KeyboardReachabilityTests`, the legacy shortcut scenarios, `ContentAnalysisMergeTests`.
- **Order:** older versions; applying in place; placeholders; transitions and removals; the reader; settings; the menu.

### sync-iphone

- **Files:** `TextMouth/Platform/iOS/Services/PhoneSyncFolderAccess.swift`: the bookmark of `.fileImporter`'s URL, `startAccessingSecurityScopedResource()`, and reads and writes through `NSFileCoordinator`, cancelled at their limits.
- **Interface:** a `.sync` section (`PhoneSettingsModel.swift:19`) after Share Logs (`PhoneSettingsView.swift:352`); a Sync Now action on the summary (`PhoneLibraryView.swift:160`); the reader's download view (`ReaderCloudPhase`, `ReaderViewModel+CloudDownload.swift:53`); rows' cloud notes.
- **Life cycle:** `onDidBecomeActive` and `onDidEnterBackground` (`PhoneLifeCycle.swift:47, 37`) call the moments; `TextMouthAppDelegate` installs `StoreBookStorage` and sets `SyncFolderAccessFactory.make`.
- **Tests:** `PhoneSyncFolderAccessTests`, `PhoneSyncSettingsTests`, `PhoneSyncLifeCycleTests`, the shared tests in the iPhone bundle, and a GitHub interface test joining a sandbox folder named by a debug-only `TEXTMOUTH_SYNC_FOLDER`.
- **Interface lines:** the iPhone forms of the status line's and the download view's "this Mac" sentences, about ten (`BookCloudWording`, `ReaderCloudWording`).
- **Order:** folder access; settings; the life cycle; the download view and row notes.

## 9. The interfaces

sync-core owns `TextMouth/Models/Sync/SyncInterfaces.swift`, the first three parts; sync-store owns `TextMouth/Services/Sync/SyncSeams.swift`, the last two, with a `PlainSyncFolderAccess` stub.
Section 16 adds `SyncBookField.keep`, two `SyncCenter` members, and one `SyncLibraryHost` method.

### Stamps, keys, and entries

```swift
struct SyncStamp: Comparable, Hashable, Codable, Sendable { var wall: Int64; var counter: UInt32; var device: String }
struct SyncClock: Codable, Sendable {
    private(set) var last: SyncStamp
    mutating func next(at now: Date) -> SyncStamp
    mutating func observe(_ remote: SyncStamp, at now: Date)
}
enum SyncBookField: String, Codable, Sendable, CaseIterable {
    case presence, content, title, author, publisher, publicationDate, album, genre, year
    case folder, voice, rate, pitch, skipForward, skipBackward, endOfBook, position, skippedHeadings, lastOpened
}
enum SyncFolderField: String, Codable, Sendable { case presence, name, parent }
enum SyncListOption: String, Codable, Sendable { case continuation, skipsFinished, removesFinished }
enum SyncKey: Hashable, Codable, Sendable {
    case book(UUID, SyncBookField), bookmark(book: UUID, id: UUID)
    case folder(UUID, SyncFolderField), readingList(book: UUID), readingListOption(SyncListOption)
}
struct SyncEntry: Codable, Equatable, Sendable {  // .null is a removal mark
    var key: SyncKey; var value: JSONValue; var stamp: SyncStamp; var byHand: Bool
    func outranks(_ other: SyncEntry) -> Bool  // byHand, then stamp
}
struct SyncRegisters: Codable, Equatable, Sendable {
    private(set) var entries: [SyncKey: SyncEntry]
    var throughSeq: Int
    @discardableResult mutating func merge(_ incoming: [SyncEntry]) -> Set<SyncKey>  // keys whose winner changed
}
```

### Projection and merge

```swift
struct SyncContent: Codable, Equatable, Sendable {  // only `manifest` is compared
    var manifest: String; var format: BookFormat; var dateAdded: Date
    var md5Hash: String; var totalWordCount: Int?; var audioDuration: TimeInterval?
}
struct SyncProjection: Equatable, Sendable {
    var values: [SyncKey: JSONValue]; var byHand: Set<SyncKey>
    static func of(_ library: Library, contents: [UUID: SyncContent]) -> SyncProjection
}
struct SyncNewBook: Sendable { var book: Book; var content: SyncContent }
struct SyncApplication: Sendable {
    var library: Library; var booksToAdd: [SyncNewBook]; var booksToRemove: [UUID]
    var movesPackages: Bool  // through performLibraryTransition
    var entriesToRecord: [SyncKey: JSONValue]  // same-named folders folded
    var appliedKeys: Set<SyncKey>
}
enum SyncMerge {
    static func changes(from baseline: SyncProjection, to now: SyncProjection, atLaunch: Bool) -> [SyncKey: JSONValue]
    static func apply(_ winners: SyncRegisters, to library: Library, voices: Set<String>?) -> SyncApplication
}
```

### Stored formats

```swift
struct SyncStoreFile: Codable, Equatable, Sendable {
    var formatVersion: Int; var storeID: UUID; var created: Date; var createdBy, createdByVersion: String
}
struct SyncDeviceFile: Codable, Equatable, Sendable {
    var formatVersion: Int; var deviceID, name, platform, appVersion: String; var lastSeq: Int; var updated: Date
}
struct SyncChangeFile: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case changes, snapshot }
    var formatVersion: Int; var deviceID: String; var incarnation: UUID
    var seq: Int; var kind: Kind; var count: Int; var entries: [SyncEntry]
}
struct StoreManifest: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable { var path, sha256, blob, role: String; var size: Int64 }  // content, record, other
    var formatVersion: Int; var bookID: UUID; var files: [File]
}
struct StorePointer: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable { var path, sha256: String; var size, modified: Int64; var onThisDevice: Bool }
    var formatVersion: Int; var storeID, bookID: UUID; var manifest: String; var uploaded: String?; var files: [File]
    static let fileName = ".storeCopy.json"
}
```

### The engine's seams

```swift
protocol SyncFolderAccess: Sendable {
    func withFolder<T: Sendable>(_ body: @Sendable (URL) async throws -> T) async throws -> T
    func list(_ folder: URL) throws -> [SyncFolderItem]  // never downloads
    func read(_ file: URL, within limit: Duration) async throws -> Data  // .offline at once, .notDownloaded at the limit
    func write(_ data: Data, to file: URL, replacing: Bool) throws  // staged, coordinated
    func copyIn(_ local: URL, to file: URL) throws  // a clone where the volume allows
    func uploadState(of file: URL) -> SyncUploadState
    func evictLocalCopy(of file: URL) throws  // a refusal is a wait
}
struct SyncFolderItem: Equatable, Sendable { var name: String; var size: Int64?; var isOnThisDevice: Bool }
enum SyncUploadState: Equatable, Sendable { case uploaded, uploading, failed(SyncProblem), notReported }
enum SyncProblem: Error, Equatable, Sendable {
    case offline, folderMissing, notASyncFolder, anotherStore, laterVersion, outOfSpace
    case notDownloaded(device: String), exists, damaged(file: String)
}
enum SyncReason: String, Sendable { case launch, active, hourly, networkBack, afterChange, syncNow, background, quit }
struct SyncStatus: Equatable, Sendable {
    var isOn = false, isSyncing = false, isOffline = false, pendingChanges = 0
    var lastSynced: Date?, lastHeard: [String: Date] = [:], problem: SyncProblem?
    var booksBackedUp: Int?, booksToBackUp: Int?
}
enum SyncFolderAccessFactory {  // sync-iphone sets the phone's
    @MainActor static var make: (_ bookmark: Data) -> any SyncFolderAccess = { PlainSyncFolderAccess(bookmark: $0) }
}
final class StoreBookStorage: BookCloudStorage { init(wrapping live: any BookCloudStorage) }  // fetches through SyncCenter
```

### The library's side, and the app's one sync

```swift
@MainActor protocol SyncLibraryHost: AnyObject {  // LibraryViewModel conforms (sync-mac)
    var library: Library { get }
    var maySyncNow: Bool { get }  // false while storage work is held, or the library is unavailable or recovering
    func applySync(_ application: SyncApplication) async -> Set<SyncKey>  // the keys applied
}
@MainActor final class SyncCenter: ObservableObject {  // sync-store; the UIs and life cycles call it
    static let shared = SyncCenter()
    @Published private(set) var status = SyncStatus()
    func install(host: any SyncLibraryHost, dataDirectory: URL)
    func setUp(in parent: URL) async throws  // makes TextMouth Sync and store.json, then joins
    func join(_ folder: URL) async throws  // waits 60 seconds for store.json; never makes one
    func syncNow()  // announces "Syncing." and the outcome
    func moment(_ reason: SyncReason)
    func libraryDidChange()  // from LibraryViewModel.library's didSet
    func stop()  // forgets the folder; deletes nothing
}
```

## 10. The words

Step 0 puts these and section 7's lines in `SyncWording`, each an `InterfaceText.line` under a `// Translators:` note.
- "Sync", with "Keeps your books, places, and bookmarks the same on your Mac and iPhone, through iCloud Drive."
- "Set Up Sync…", hinted "Makes a folder named TextMouth Sync in the iCloud Drive folder you choose, and copies your books into it."
- "Join Sync Folder…", hinted "Chooses the TextMouth Sync folder that another device set up."
- "Sync Now"; "Stop Syncing…", asking "Stop syncing this library? Nothing is deleted, on this Mac or in iCloud Drive."
- "That folder isn't in iCloud Drive. Choose a folder in iCloud Drive."
- "Sync is for a library kept on this Mac. Move this one here with Change Location first."
- "A folder named TextMouth Sync is already there. To use it, choose Join Sync Folder."
- "That isn't a TextMouth Sync folder, or its files haven't arrived from iCloud Drive yet."
- "The sync folder now holds another library's sync. Choose Join Sync Folder again."
- "Waiting for the sync folder's files to arrive from iCloud Drive."

## 11. Tests in every branch

No test touches iCloud Drive or the user's library: every folder is in the sandbox (`HostedTestIsolationSupport.swift:167`), and the real-drive tests are opt-in.
- **A stand-in drive,** `SyncTestDrive`: offline; an upload held, failed, or unreported; a download late, never, or half; an eviction; a file deleted "in the cloud"; the folder lost or its bookmark stale.
- **Two devices,** `SyncTwoDevices`: two libraries and engines over one cloud folder, the test choosing when files travel.
  `SyncTwoDeviceTests` takes both offline, changes both, lets them meet, and expects one library.
  The changes: places, bookmarks added on each, one deleted here and relabeled there, the list reordered and added to, a folder renamed as a book moves in, a book removed here and read there.
- **Interruptions,** `SyncInterruptionTests`: a run, a backup, and a fetch stopped after each step, then started afresh: each change in the outbox or the folder, the library opening, no row lost, no blob partial, nothing sent twice.
- **The merge's properties,** `SyncMergePropertyTests`: random changes of two or three devices, delivered in random orders, some twice, give one state everywhere, each value its highest entry's.
  Merging again changes nothing, and no removal takes a change it hadn't seen; 300 seeded cases, the seed printed on failure.
- **The network's cases,** `SyncNetworkCaseTests`: each moment offline, an upload stalled and one refused for room, a download past its limit, a change file half there, the folder missing, a stale bookmark.
  Each checks the status's words, and, on a test clock, that every wait was bounded.
- **The iPhone:** its unit bundle's shared tests and its interface test, on GitHub's simulator.

## 12. The real drive

### The spike

The orchestrator runs it while the user is awake, since touching iCloud Drive can put a privacy prompt on screen.
sync-store writes it first, by Wednesday 14:00: `SyncRealDriveTests`, opt-in like `CloudDriveIntegrationTests`, on made-up files.
It runs through `run_locked.py`, with `TEST_RUNNER_TEXTMOUTH_CLOUD_TEST_ROOTS` naming iCloud Drive's TextMouth Cloud Tests folder.
1. An upload's state: change files moved in from staging and written coordinated, their upload keys read every 2 seconds.
2. The clone: a 16 MB blob's private size and clone identifier at the copy, the upload, five minutes on, and after eviction (Phase 1's design, section 9).
3. A read-back after eviction: evicted, seen dataless, read, its SHA-256 compared, timed.
4. A listing with evicted files: their own names, or `.icloud` stand-ins.
5. `FileManager.ubiquityIdentityToken` without the iCloud entitlement.

The answers set the outbox's "uploaded", the budget, `SyncFolderItem`'s names, and a "signed out" sentence.
The third open point, the iPhone's writes through Files reaching the cloud, needs the phone; "Last heard from iPhone" will tell.

### The rehearsal on the user's library

The store's first backup of the real library into iCloud Drive, which the user allowed today; the orchestrator runs it after sync-store merges, never a builder.
- **Checks first:** iCloud's free space, 12 GB at least, read by the user in System Settings; this Mac's free disk, the budget plus 4 GB (`df -h /`, which walks nothing); the spike's clone answer.
  And a backup of the library first, if the user wants one.
- **How:** `SyncRehearsalTests`, opt-in, given the data directory and the folder by two variables, through `run_locked.py` with `caffeinate`, started while the user is awake, left overnight.
- It only reads the library, its pointers going to a scratch folder, and copies every book's blobs and manifest, text books first, paced by the budget and the uploads.
- It writes no device folder, so on Saturday the Mac joins first, finds every blob there, and uploads nothing twice.
- It reports every 10 minutes, names each book it couldn't copy and why, and stops at 1 GB free or a full iCloud Drive.

## 13. The schedule

Eastern times; each merge waits for its full suite, and a train takes 33 to 50 minutes.
- **Wednesday:** 10:30 `sync/base`; 10:45 the builders and a translator; 14:00 to 18:00 the spike; 21:00 to 23:00 the first trains.
- **Thursday:** 02:00 sync-core's review, 08:00 merged; 12:00 sync-store's review, 16:00 merged; 18:00 the rehearsal; 20:00 sync-mac's review.
- **Friday:** 04:00 sync-mac merged; 08:00 sync-iphone's review, 13:00 merged; 14:00 to 18:00 the docs pass, 0.6.0, the full suite; 19:00 the user installs (section 14).

If a day slips, cut in this order:
1. folder renames and moves crossing devices (new folders and books' folders still cross);
2. an open reader moving to a synced place (reopening does it);
3. Set Up Sync on the iPhone (Join only);
4. the hourly and network-back moments;
5. audiobooks over 500 MB in the backup.

## 14. Saturday and the iPhone

- The phone runs iOS 27.2, and this Mac has Xcode 26.0.1, macOS 26.3.1, and about 9 GB free; nothing here needs an iCloud entitlement, so the free signing stands.
- An iOS 26 app runs on iOS 27, but Xcode 26.0.1 may not install onto iOS 27.2, so `make install-ios` is tried first, Friday evening.
- If it refuses, Xcode 27 needs macOS 26.6, and both very likely don't fit in 9 GB until space is freed (build folders by the orchestrator, more by the user).
- GitHub's simulator checks the iPhone half meanwhile; without the phone, Saturday tries the Mac's half, with a second Mac library as the second device.

## 15. Questions for the user

Each recommendation is what gets built; only the rehearsal and the install wait for an answer.
1. **iCloud Drive alone, Google Drive and Dropbox later?** Yes: each costs about a branch later (a spike, since the iPhone's writes into it are undocumented, tests, words); the design stays.
2. **The iPhone's own books:** a joining phone keeps and sends them, and one also on the Mac stays two books. Recommended: start the phone's library empty.
3. **Removals:** a book deleted on one device is deleted on the other, to the Mac's Trash as its setting says, unasked. Recommended: yes.
4. **A book's voice** follows it where that voice exists; else each device keeps its own. Recommended: yes.
5. **A paused reader** moves to the place saved elsewhere, and says so. Recommended: yes.
6. **Sync Now's key,** Command-Option-S if free. Recommended: yes.
7. **The rehearsal,** Thursday evening, you awake at its start: books copied overnight, the library only read, the folder then your real one. Recommended: yes.
8. **Version 0.6.0,** "update every device first" in the changelog. Recommended: yes.
9. **The iPhone on Saturday:** section 14's steps, on Friday evening. Recommended: yes.
10. **Next week:** Remove from This Mac with its proof, then settings and statistics, then the Google Drive copy. Recommended: that order.
11. **The name** TextMouth Sync, for the research's store. Recommended: yes.
12. **Keep on All Devices,** for the Keep Downloaded you asked for, which every device that syncs follows; Keep on This Mac stays for a library in a cloud folder. Recommended: that name.
13. **Removing books unopened for some days** (next week): 7 days by default on the iPhone, and off on the Mac, which holds the whole library, until you turn it on. Recommended: yes.
14. **What "opened" means:** a reader opening the book on any device, a play on this device, or its files arriving here; not an export or Book Information. Recommended: yes.
15. **Automatic downloads** only on Wi-Fi or Ethernet with Low Data Mode off; a book you open downloads on any network; a cellular setting next week. Recommended: yes.
16. **The iPhone's backup:** books fetched from the sync folder left out of its iCloud Backup, since iCloud Drive holds them. Recommended: yes, built Friday.
17. **The reading list's books** kept on every device that keeps its list, as each Mac does today, on by default. Recommended: yes.

## 16. Addendum: keeping books on a device

For the user's message of about 08:45: books unopened for some days, Keep Downloaded, the reading list, and downloading when a device can.

### Who decides what stays

- With sync, each device's library is on its own disk, outside iCloud Drive: the Mac's data directory, and the iPhone's `Library/Application Support/.TextMouth` in its container (`TextMouthPaths.swift:15-29`).
  So TextMouth alone decides which books' files stay; iCloud Drive manages only its copy of TextMouth Sync, and downloads an evicted file of it again when it is read.
- iOS doesn't purge Application Support: Apple's guide names only Caches, purged "on rare occasions when the system is very low on disk space", and tmp, and says Application Support is backed up; offloading the app keeps its data [A][B].
- A library in a cloud folder is unchanged: there the drive evicts files as it likes, TextMouth can't pin them, Keep on This Mac downloads kept books again, and the rules below don't apply.

### Keep on All Devices (Friday)

- The user's Keep Downloaded, named for what it does: every device that syncs keeps the book's files, and downloads them when it can; Finder's Keep Downloaded and one Mac's Keep on This Mac mean less.
- It syncs, as the user's words ask: a new key, `SyncBookField.keep`, `true` or `false`, stamped by `SyncCenter.setKeep(_:for:)` when a person chooses, never projected from the library.
- So it lives in the registers, here and in the folder, with no new key in library.json, config.json, or bookInfo.json (R5).
- `SyncCenter.keptBookIDs` hands the set to `KeptBooks` (`KeptBooks.swift:37`), whose `isKept(_:)` (`:112`) then answers for it beside the reading list.
- Offered with sync on only: a row's commands and VoiceOver actions (`LibraryCloudCommand.Kind`, `LibraryViewModel+Cloud.swift:375`), the Library menu's keep items, and a checkbox in Book Information (`LibrarySheetViews.swift:230`, `PhoneBookInfoSheet`).

### The reading list (Friday, already built)

- `rlkeep` works the list's keep out and never writes it: `observeReadingListKeeping` (`LibraryViewModel+ReadingList.swift:221`) hands `KeptBooks` the list after each change, and `isKept` answers "kept by the person, or listed".
- So a book that leaves the list returns to its own choice, whatever it was, with nothing to undo.
- Keeping the list's books stays each device's choice (`keepsReadingListBooks`, on until cleared); the Mac's checkbox shows while sync is on, since `showsCloudNotes` holds, and the iPhone's waits, on meanwhile.

### Downloading when a device can (Friday)

- After each sync the host records its placeholders' states in `BookCloudStates` and runs `downloadEvictedKeptBooks` (`LibraryViewModel+Cloud.swift:703`), since the refresher runs only while a Mac Library window is open (`:179`).
- It downloads kept and listed books missing here, one at a time, as many as fit in the free space less 1 GB (`downloadWhatFits`), sized from their manifests (`StoreBookStorage.bytesToDownload`).
- It starts only on Wi-Fi or Ethernet with Low Data Mode off (a satisfied path neither expensive nor constrained); on cellular or a hotspot it waits for a later moment, which also spares iCloud Drive's cellular switch.
- A book a person opens downloads on any network; offline nothing starts; short of room, it says so once, as today.
- VoiceOver hears today's single notice, "Downloading 12 reading list books", and the room notice; kept books download quietly, their rows saying "Downloading 40%".
- The phone's first sync fills its reading list so, and each package fetched onto it is left out of its iCloud Backup (`isExcludedFromBackup`, as `ImportScratchSpace.swift:106` sets).

### Books unopened for some days (next week)

- A setting of each device: Off, or 1 to 30 days; 7 by default on the iPhone, off on the Mac until the user turns it on (question 13).
- It removes only a book's own file or tracks (`isPackageContentName`), as Remove from This Mac will, keeping its record and text: a text book still reads, and an audiobook downloads when opened.
- Only once each such file is proven by the research's read-back (its section 6) at the fingerprint it has now, with the folder reachable.
- Opened is the latest of a reader opening it on any device (`lastOpened`, synced), a play here (`lastPlaybackStopped`, this device's own), and its files arriving here.
- Never a book kept on all devices or on a kept reading list, nor one open, playing, downloading, or being edited, exported, or transcribed.
- It runs after a sync, at most daily, and says once: "Removed the downloads of 3 books unopened for 7 days, freeing 412 megabytes. They stay in iCloud Drive."
- It is this device's own: nothing is stamped, and the book stays in the library everywhere (R7).

### What Friday's branches add

The orchestrator adds these declarations to `sync/base` (step 0b), and each branch merges it again.
- **sync-core:** `SyncBookField.keep`, which `SyncProjection.of` leaves out and `SyncMerge.apply` applies to no row.
- **sync-store:** `SyncCenter.keptBookIDs` and `setKeep(_:for:)`; `SyncLibraryHost.syncDidApply(keptBookIDs:mayDownload:)`; `StoreBookStorage.bytesToDownload(of:)` from manifests; the backup exclusion in `StoreFetch`.
- **sync-mac:** `KeptBooks` taking the synced set; `LibraryCloudCommand.Kind.keepOnAllDevices` and `.stopKeepingOnAllDevices`; the host's `syncDidApply` and its path rule; the Mac's Book Information checkbox.
- **sync-iphone:** the row action, and a switch in `PhoneBookInfoSheet`.
- **Words, in `SyncWording`:** "Keep on All Devices", "Stop Keeping on All Devices", their counted forms ("Keep 3 Books on All Devices"), "Kept on all devices", and "Keeping Moby-Dick on all devices."
  And Book Information's hint: "Every device that syncs keeps this book's files, and downloads them when it can."
- **Tests:** `SyncKeepTests` on two devices (kept on one, downloaded on the other when it may; a book in and out of the list; the path rule), and the commands in `SyncSettingsSectionTests` and `PhoneSyncSettingsTests`.
- **If a day slips,** these go before section 13's cuts: the Book Information checkbox, then Keep on All Devices; the reading list's downloads stay.

```swift
enum SyncBookField { /* …, */ case keep }                                   // sync-core
extension SyncCenter {                                                        // sync-store
    var keptBookIDs: Set<UUID> { get }                                        // @Published
    func setKeep(_ keep: Bool, for bookIDs: [UUID])
}
protocol SyncLibraryHost { func syncDidApply(keptBookIDs: Set<UUID>, mayDownload: Bool) }   // sync-mac
```

Sources: [A] Apple's File System Programming Guide, File System Basics: https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html
[B] Apple's platform support guide, offloading apps: https://support.apple.com/guide/platform-support/supb175ad6a1/web

## What I could not verify

- The spike's five points, and whether an iPhone app's writes into a picked folder reach iCloud with upload states.
- Whether Xcode 26.0.1 installs on iOS 27.2; the room macOS 26.6 and Xcode 27 need; iOS's background time; and what Low Data Mode and iCloud's cellular switch do to uploads.
- The recorder's cost on 750 books, and `performLibraryTransition` taking renames, moves, and new folders at once: read, not run.
- That `isExcludedFromBackup` on a package's folder keeps its files out of iCloud Backup, and how much a phone's backup grows without it.
- Each `file:line` was checked with `git grep` at e7c6fd20e; reading code is not running it.

# The local-first library's Phase 1: a design to build from (November 15, 2026)

Designer `phase1design` (Fable), branch `research/local-first-phase1`, against main 9a456fdb1 (version 0.4.11).
It turns Phase 1 of `LOCAL-FIRST-LIBRARY-RESEARCH-2026-11-13.md` ("the research", option C) into seven branches, and takes in Phase 0's reports in `build/orchestrator/nov14/`.
The user's answer of November 14 (`humanQuestions/2026-11-14.md`, question 4): the store will be on iCloud Drive "eventually", the infrastructure may be built, and "for now I won't move everything".
A `file:line` points into main at that commit.
The user's library and cloud drives were never read; the one experiment ran in a scratch folder (section 9).

## Summary

1. Phase 1 is seven branches: `store-core`, `store-drive`, `store-backup`, `store-proof`, `store-settings`, `store-remove`, and `store-rebuild`.
2. The first four add no control, no word, and no file until a store is chosen, and nothing in them can choose one, so they may be built and merged now.
3. `store-settings` is the first thing the user sees, and `store-remove` the first that takes a file off this Mac; both wait for the user, as does `store-rebuild`.
4. No key is added to library.json, config.json, or bookInfo.json; the new files are a hidden pointer in each package, and the store's own.
5. Reading the code found one thing the research missed: a rebuilt index leaves out a book whose file is gone (`FileImportService.swift:3886`), in 0.4.11 and before it.
   So the pointer's name begins with a dot, and `store-remove` makes version 0.5.0.
6. Of Phase 0's five missed risks, two have a Phase 1 form that must be handled (2 and 4), and three belong to Phase 2.
7. Apple documents the calls the design needs, and promises nothing about what "uploaded" proves; the read-back stays the only proof.
8. Whether a clone into a drive's folder stays a clone changes only a budget and two sentences; the design holds either way.
9. Seven questions end the page.

## 1. Words and fixed rules

### The words

- **Store:** a folder TextMouth makes in a cloud drive, holding `store.json`, `Books/`, `Devices/`, and `Damaged/`.
- **Blob:** one file of a book in the store, named by the SHA-256 of its bytes, never changed once written.
- **Manifest:** a blob that lists a book's files and which blob holds each.
- **Pointer:** `.cloudCopy.json` in a book's package on this Mac: where the book's files are in the store, and what has been proven.
- **Device folder:** `Devices/<Mac ID>/`, which only this Mac writes: its index, its small files, and each book's record.
- **Proof:** the drive sent a blob back after its download was removed, and its SHA-256 and size matched.
- **Content:** the files of a package that may leave this Mac, which are those `FileImportService.isPackageContentName` accepts (`FileImportService+Packages.swift:536`): the book's own file, or its tracks.

### Rules every branch keeps

Each rule has a test, named in the branch that first needs it.

- **R1. Inert without a store.** With no store chosen, TextMouth writes no new file, starts no new task, and shows and speaks nothing new.
- **R2. The library never waits for the store.** Store work runs off the main thread, every wait has a limit, and a store that can't be reached only makes store work wait.
- **R3. Blobs are for good.** Phase 1 never deletes or overwrites a blob whose bytes match its name.
  A blob whose bytes don't match is moved to `Damaged/`, never deleted.
- **R4. Proof before removal.** A content file leaves this Mac only by the user's command, only when every content file of the book is proven at the fingerprint it has now.
- **R5. No new key** in library.json, config.json, or bookInfo.json, so `testALibraryRowHoldsExactlyTheseKeys`, `testAPackageRecordHoldsExactlyTheseKeys`, and `testConfigJSONHoldsExactlyTheseKeys` (`OnDiskContractTests.swift:276`, `:324`, `:238`) pass unchanged.
- **R6. A library on this Mac only.** A store is refused while the data directory is in a cloud location, and a store folder must be in one (`StorageLocation.isCloud`, `CloudStorageContract.swift:40`), outside the data directory.
- **R7. One writer for each file.** This Mac writes only blobs, its own device folder, and `store.json` once.
- **R8. Everything is spoken.** Each state, refusal, and result has words in `StoreWording`, pinned by a test.

## 2. The branches, in order

- **Wave 1, now, side by side:**
  - `feature/store-core` (medium): the formats, the store folder, fingerprints, and a package's inventory.
  - `test/store-drive` (small): the stand-in drive, test support only.
- **Wave 2, now, one after the other:**
  - `feature/store-backup` (large): books copied into the store, the pointer, the device folder.
  - `feature/store-proof` (medium): the read-back, the weekly check.
- **Wave 3, when the user says:**
  - `feature/store-settings` (medium to large): Storage settings' Cloud Store section, row notes, Back Up Now.
  - `feature/store-remove` (large, the riskiest): Remove from This Mac, Download to This Mac, and every reader of a book's file.
  - `feature/store-rebuild` (medium): Rebuild Library from Store.
    It can be built beside `store-remove`.

Each large branch gets an outside review, a fix round, and a check of the fix.
New files go in `TextMouth/Services/Store/` and `TextMouth/Models/Store/`; new tests go in a new `[store]` area of `Scripts/test/areas.conf`.

### What may be merged now

`store-core`, `store-drive`, `store-backup`, and `store-proof` change nothing the user hears or sees.
Only `StorePreferences` can name a store, and only `store-settings` has code that writes it.
`store-backup`'s test `testWithNoStoreChosenNothingIsWrittenOrStarted` holds R1 for all four: it opens a library, and asserts no engine task, no file under the data directory or `MachineLocalPaths.root` beyond today's, and no published state.
`store-settings` can be built on its branch at any time, and waits unmerged.

## 3. Stored formats

Every JSON file is written with sorted keys, indented, with dates in ISO 8601 to the second, as `LibraryIdentity` writes its marker (`LibraryIdentity.swift:74`).
Each has `formatVersion`, an integer, 1 in Phase 1; a TextMouth that reads a higher one leaves the file alone and reports "a later TextMouth".

### store.json

In the store's root, created exclusively (`.withoutOverwriting`, as `LibraryIdentity.swift:88`), never replaced.

- `formatVersion` (integer): 1.
- `storeID` (string, a UUID): which store this is.
- `created` (string, a date): when it was made.
- `libraryID` (string, a UUID): the `LibraryIdentity.id` of the library it was made for; a library with another identity is refused.
- `createdByVersion` (string): the app version that made it, for a report only.

### A blob's name

- `Books/<book ID>/<sha256>.<extension>`: the book ID as a lower-case UUID, the SHA-256 as 64 lower-case hexadecimal digits.
- The extension is the file's own, lower-cased, kept only when it is 1 to 8 characters of `a-z0-9`; otherwise `bin`.
- Two files of one book with the same bytes share one blob.
- A manifest is `Books/<book ID>/<sha256>.manifest.json`, the SHA-256 being that of the manifest's own bytes.
- Plain folders only, never a package: iCloud Drive syncs a `.tmb` package as one item (`docs/developer/testing.md`, "Testing on real cloud drives").

### A manifest's keys

- `formatVersion` (integer) and `bookID` (string); no date, so the same files always give the same manifest, and a step run twice writes it once.
- `files` (array, sorted by `path`), one entry for each regular file of the package, at any depth, hidden ones included.
  Left out: the pointer, `.DS_Store`, and the `cachedAudio` folder (`TextMouthPaths.swift:401`), which TextMouth can make again.
  A symbolic link is never followed; a package holding one is not backed up, and says why.
- Each entry:
  - `path` (string): the file's path inside the package, with `/` between parts;
  - `sha256` (string) and `size` (integer, bytes);
  - `blob` (string): the blob's file name;
  - `role` (string): `content`, `record` (bookInfo.json), or `other`.
- A new manifest is written when any file but bookInfo.json changes.
  The `record` entry is the record as it was then; the newest record is in the device folder.

### The pointer's keys

`.cloudCopy.json` in the package, written whole through `SavedFile` (`SavedFile.swift:17`).
The dot keeps it out of `isPackageContentName`, of an export (`BookExportService.swift:554`), and of an older TextMouth's search for the book's file.

- `formatVersion` (integer), `storeID` (string), `bookID` (string), `manifest` (string: the manifest's SHA-256).
- `files` (array), as a manifest's entries, each with three more keys:
  - `modified` (integer): the local file's modification time in nanoseconds when it was fingerprinted, with `size` a `FileStamp` (`TextCacheFingerprint.swift:20`), so an unchanged file is not hashed again;
  - `proven` (string, a date, optional): when its read-back matched;
  - `onThisMac` (boolean): false once Remove from This Mac took it.
- `uploaded` (string, a date, optional): when the drive first reported every blob uploaded.
- `removing` (string, a date, optional): set before a removal deletes, cleared after, so a launch can finish one a crash cut short.
- `lastFailure` (string, optional): the last failure, in words for Book Information.

### The device folder's files

`Devices/<Mac ID>/`, the ID being `LibrarySessionLease.macID` (`LibrarySessionLease.swift:177`).
Each file is replaced whole, staged on this Mac and moved in.

- `device.json`: `formatVersion`, `deviceID`, `deviceName` (the computer's name), `appVersion`, `libraryID`, `written`.
- `Books/<book ID>.json`: `formatVersion`, `bookID`, `manifest`, `written`, and `record`, the bytes of the package's bookInfo.json as an object.
  Written when the record changes, at most once in five minutes for a book.
- `Library/`: copies, byte for byte, of library.json, library-identity.json, config.json, substitutions.json, reading_stats.json, audio-filters.json, and each feed's record and index.
  Written when a file's stamp changes, at most once an hour, and at quit with a two-second limit.
- No clock is stamped on any value: that is Phase 2.

### How the contract tests pin them

In `OnDiskContractTests`, in the pattern of `testARemovalMarkerHoldsExactlyTheseKeys` (`OnDiskContractTests.swift:413`).
Each encodes a value with every field set, compares `Set(written.keys)` with a literal set, and compares `propertyNames(of:)` (`:692`) with the same set.

- `testTheStoreFileHoldsExactlyTheseKeys`, `testAManifestHoldsExactlyTheseKeys`, `testThePointerHoldsExactlyTheseKeys`, `testADeviceRecordHoldsExactlyTheseKeys`, `testADeviceBookRecordHoldsExactlyTheseKeys`.
- `testTheStoresFilesAndFoldersAreNamed`: the literals `store.json`, `Books`, `Devices`, `Damaged`, `Library`, `device.json`, `.cloudCopy.json`, `.manifest.json`.
- `testABlobIsNamedByItsFingerprint`: literal inputs and names, the `bin` fallback included.
- `testTheStoreFormatVersion`: the literal 1.
- `testTheStorePreferencesAreThisMacsOwn`: the three keys are in `localStoreKeys` (`ConfigService.swift:764`), so config.json never carries them.

## 4. Branch by branch

### 4.1 store-core

- **Adds** (new files):
  - `FileDigest`: one streaming digest over any `HashFunction`, read in 1 MB chunks, each in an autorelease pool.
  - `StoreFormats`: the `Codable` types of section 3.
  - `StoreLayout`: the names and paths.
  - `CloudStore`: `create(in:for:)` and `open(at:)`, with the refusals of section 5.
    It reads `store.json` inside `DatalessFiles.withoutDownloading` (`CloudStorageContract.swift:685`).
  - `StorePreferences`: `textMouthStorePath`, `textMouthStoreBookmark`, `textMouthStoreIdentity`, shaped as `DataDirectoryPreferences` (`DataDirectoryAvailability.swift:14`).
  - `StoreAvailability`: not chosen, available, or unreachable with its reason.
  - `BookFileInventory`: a package's files with their roles and stamps.
  - `StoreDriveAccess`: the seam every store read and request goes through, closures over `SyncFlagReporting` (`UbiquitousItemStatusProvider.swift:30`) and `DatalessFiles.isDataless`, as `MaintenanceFileAccess` is.
- **Touches:** `FileImportService.md5Hash(of:readingChunksWith:)` (`FileImportService.swift:2660`) calls `FileDigest`, so there is one loop; `localStoreKeys` gains the three keys; `areas.conf` gains `[store]`.
- **Leaves as today:** every caller of `md5Hash`, and everything else; nothing in the app makes a `CloudStore`.
- **Tests:**
  - `FileDigestTests`: SHA-256 against published vectors; MD5 equal to today's for the same files; a failing read throws;
  - `StoreFormatTests`: round trips; a higher `formatVersion` refused;
  - `CloudStoreTests`: each refusal; a second `create` never replaces the first;
  - `BookFileInventoryTests`: an EPUB, a folder of tracks, an RTFD, a package with audio edits, a link;
  - the contract tests of section 3.
  Without the branch none compiles; `testCreatingAStoreTwiceKeepsTheFirst` fails if `.withoutOverwriting` is dropped.
- **Also here:** `StorePackageAsOlderVersionsReadItTests`, which feeds today's unchanged code a package with a pointer, and one with its content gone, and pins what 0.4.11 does (section 6).
- **An older TextMouth:** sees nothing; this branch writes nothing.

### 4.2 store-drive

- **Adds**, in `TextMouthProductionTests` only: `StoreTestDrive`, a `StoreDriveAccess` over a sandbox folder with a second folder standing for the server.
  It grows from `FakeCloudItemStatusProvider` (`CloudTestDoubles.swift:21`).
- **It can:**
  - hold a written file as not uploaded until told to upload it, or fail the upload (out of room, offline, paused);
  - evict a file, and report it dataless through the seam;
  - download a file back whole, late, never, or with other bytes;
  - delete a file "on the server", and make each drive's conflict copy (`name 2`, `name (1)`, `conflicted copy`);
  - refuse an eviction as a real drive does: not uploaded, or busy.
- **Tests:** `StoreTestDriveTests`, one for each ability.
- **Leaves as today:** the app, which it doesn't touch.

### 4.3 store-backup

- **Adds:** `StoreBackupEngine` (an actor), `StoreDeviceWriter`, `BookBackupState` and `BookBackupStates` (shaped as `BookCloudStates`, `CloudStorageContract.swift:553`), `StoreWording`, and `MachineLocalPaths.storeStaging` ("Store Staging").
- **Touches:** one line in `LibraryViewModel.startLibrary()` beside `reportConflictCopiesInBackground()` (`LibraryViewModel.swift:511`), which returns at once when no store is chosen.
- **One book at a time,** text books first, then smaller before larger.
  Each step is safe to repeat, and a hook after each lets a test stop there:
  1. inventory the package, and fingerprint each file whose stamp the pointer doesn't already hold;
  2. for each blob not in the store, clone the file into Store Staging with `FileManager.copyItem` (as `ReaderWorkingCopy.swift:118`), check its size, and move it into `Books/<book ID>/`, refusing to replace;
  3. write the manifest the same way, then the pointer, then the device folder's book record;
  4. on later passes, read each blob's status; when none has a doubt (`cloudCopyDoubt`, `CloudStorageContract.swift:139`), set `uploaded` and hand the book to the proof.
- **No task waits on an upload.** A pass runs at launch, when TextMouth becomes active, and every 60 seconds while a book is uploading.
- **A budget** bounds the bytes of blobs copied and not yet evicted: 2 GB, or the free space less `ArchiveLimits.standard.freeSpaceReserve` when that is smaller.
  It counts whole sizes, as if no clone shared anything (section 9).
  Only the proof (4.4) removes a blob's download, so this branch alone stops at the budget.
- **A changed book** is found by its stamps at launch and hourly, and backed up again as new blobs and a new manifest; the old ones stay (R3).
- **Leaves as today:** every file of the package but the pointer; library.json; all windows.
- **Tests** (`StoreBackupEngineTests`, `StoreDeviceWriterTests`, `StoreBackupInterruptionTests`):
  - a text book and an audiobook arrive in the store, and every blob's bytes hash to its name;
  - a stop after each step, then a fresh engine: the same end state, no blob written twice, no partial file under a blob's name;
  - an upload that fails for room says so and leaves the book "Backup Failed"; the budget holds the queue;
  - a changed file gets a new blob and the old one is still there;
  - `testWithNoStoreChosenNothingIsWrittenOrStarted`;
  - a store that vanishes mid-copy leaves the package as it was.
- **Fail without it:** all of them; taking out the staging step fails the partial-file test.
- **New log tags** `STORE_BACKUP` and `STORE_DEVICE`: name `LogContentPolicyTests` in the train.

### 4.4 store-proof

- **Adds:** `StoreProof` and `StoreCheck`, and `MachineLocalPaths.storeCheck` ("Store Check.json": `lastChecked`, a date).
- **The proof of one blob,** only when its status has no doubt:
  1. remove its download (`removeLocalCopy`, `UbiquitousItemStatusProvider.swift:375`), never inside a coordinated write; a busy file is tried again later;
  2. wait, 60 seconds at most, until it is dataless;
  3. ask for it (`requestDownload`, `:366`) and poll every 2 seconds, giving up after 60 seconds without progress (`BookCloudStorageService.swift:100`);
  4. hash it inside `withoutDownloading`, and compare the SHA-256 and size with the pointer's;
  5. on a match, write `proven`, and remove the download again;
  6. on a mismatch, move the blob to `Damaged/<book ID>/`, copy the file again, and say so; a second mismatch is a failure that waits for Check Cloud Copy.
- **It waits** while the network is expensive or constrained, and while a reader has the book open.
- **The weekly check** reads metadata only: each pointer's blobs and manifest exist, with their sizes.
  A dataless file's size is not judged: an evicted iCloud Drive file can report 0 bytes (`docs/architecture/state/text-caches.md`).
- **Leaves as today:** every local file; the proof reads and evicts only blobs.
- **Tests** (`StoreProofTests`, `StoreCheckTests`):
  - a match sets `proven`; a blob returned with other bytes is moved to `Damaged/`, the local file stays, and a second copy is made;
  - a download that never comes ends in the stall limit, with nothing marked;
  - a blob with an upload error, a conflict, or no upload report is never evicted;
  - a blob deleted on the server is reported, once, with the right sentence for a book on this Mac and for one that isn't;
  - a stop after each step leaves either "not proven" or "proven", never between.
- **Fail without it:** all; skipping the hash fails the other-bytes test.

### 4.5 store-settings

- **Adds:** `CloudStoreSettingsSection`, a view of its own placed in `StorageSettingsView` after the location buttons (`StorageSettingsView.swift:532`), and the sheet that sets a store up.
- **Touches:**
  - the row's note (`LibrarySubviews.swift:610`, `LibraryInfoRow.swift:162`, `BookCloudNote.swift:110`);
  - `LibraryCloudCommand.Kind` (`LibraryViewModel+Cloud.swift:367`), which gains Back Up Now and Check Cloud Copy;
  - the Library menu beside Keep on This Mac (`MenuCommands.swift:562`);
  - Book Information, which gains a Cloud Store line.
- **Setting up:** the user picks a folder; TextMouth makes `TextMouth Store` inside it, never using a folder that exists.
  Use an Existing Store waits for `store.json` as Phase 0 waits for an index, and never makes one (section 7, risk 2).
- **No new shortcut action:** the commands are in the menu bar, the row's menu, and its VoiceOver actions, so `KeyboardShortcuts*` stays untouched.
- **Stop Using This Store** forgets the three preferences and deletes nothing; it refuses while any book's content is only in the store.
- **Tests:** `CloudStoreSettingsTests` (each control's label, value, and hint; each refusal's words), `StoreRowNoteTests`, `StoreCommandTests`, and `KeyboardReachabilityTests` for the section.
- **An older TextMouth** ignores the pointers and the preferences, and backs nothing up.

### 4.6 store-remove

- **Adds:** `BookFilePresence`, one answer for a book: on this Mac, in the store, or missing.
- **Remove from This Mac,** for a book or a selection, refuses unless all of these hold, and says which didn't:
  - every content file is proven, and its stamp is the pointer's (a changed stamp is hashed again);
  - the book isn't open, isn't kept, and isn't on a reading list this Mac keeps (`KeptBooks.isKept`, `KeptBooks.swift:112`);
  - the store is reachable now, and each blob is there with no doubt.
- **It then** writes `removing`, deletes the content files for good, writes `onThisMac` false, and removes the blobs' downloads.
- **Download to This Mac** asks for the blobs, hashes each, clones each back to its `path` through Store Staging, and sets `onThisMac`.
  It also clears a page stamp that notes a missing file, which an older TextMouth may have written (section 6), so the next launch reads the pages.
- **Every reader of `bookFileURL`** (`Book.swift:1236`) asks `BookFilePresence` first:
  - the index rebuild and package adoption keep a book whose pointer says its content is in the store (`FileImportService.swift:3886`);
  - the path repair leaves it alone (`LibraryViewModel+Migration.swift:317`);
  - the page re-read skips it without the failed stamp it writes today (`:1254`);
  - a reader opens a text book from content.md, and an audiobook through the download view (`ReaderViewModel+CloudDownload.swift:511`);
  - export of the original, Redo Text Extraction, Replace Existing, the EPUB details write-back, the audio editor, transcription, and a reading in another encoding download first or refuse in words.
- **Keep on This Mac** and the reading list's keep apply when a store is in use, as they do in a cloud library.
- **Tests** (`StoreRemovalTests`, `StoreRemovedBookTests`, `StoreRemovalInterruptionTests`):
  - each refusal, with a file changed one byte after its proof among them;
  - a stop after each step, then a launch: the content is on this Mac or proven in the store, never neither;
  - every launch task run over a library with removed books leaves each content.md and record byte for byte the same;
  - Rebuild Library Index keeps every removed book;
  - Download to This Mac restores bytes that hash to the pointer's.
- **Fail without it:** the rebuild test and the page test fail on main today.

### 4.7 store-rebuild

- **Adds:** Rebuild Library from Store, in the Cloud Store section: it makes a library in a new, empty folder on this Mac from one device folder.
- It downloads each book's manifest and its files that aren't content, checks each against its name, and writes the package with a pointer saying the content is in the store.
- Each book's reading state is the later of the device's index row and its record, by `Book.readingState(standingAgainst:)` (`Book+ReadingState.swift:108`).
- It never touches the library in use, and ends by naming the folder for Use This Library.
- **Tests:** `StoreRebuildTests`: a library backed up, rebuilt, then compared with `LibraryComparison.compare` gives no difference; a missing blob is listed and its book still made; a stop and a second run finish.
- **It is also the rehearsal:** rebuild into a scratch folder, then Compare Libraries against the real one.
  A rehearsal's library is compared and never used: in use, it would write this Mac's device folder.

## 5. Wording

All in `StoreWording`, with "iCloud Drive" from `CloudProvider.displayName`.

### Row notes

Shown and spoken after the New or Now Reading badge, where today's cloud notes are.

- "Not Backed Up".
- "Backing Up 40%", spoken "Backing up, 40 percent": the share of the book's bytes the drive reports uploaded.
- "Checking Backup": uploaded, and being read back.
- "Backed Up": proven.
- "In Cloud": the content is in the store only.
- "Downloading 40%", spoken "Downloading, 40 percent".
- "Backup Failed", with the reason in Book Information.

### Commands

- "Back Up Now", "Check Cloud Copy", "Remove from This Mac", "Download to This Mac"; for a selection, "Back Up 3 Books Now" and so on, as `LibraryCloudWording` counts today.
- In Storage settings: "Set Up Cloud Store…", "Use an Existing Store…", "Check Cloud Store", "Rebuild Library from Store…", "Stop Using This Store…".

### Sentences spoken

- "Moby-Dick is backed up in iCloud Drive, and its copy there was checked."
- "Removed Moby-Dick from this Mac. 412 megabytes freed. Its copy in iCloud Drive was checked today."
- "Moby-Dick stays on this Mac: its copy in iCloud Drive hasn't been checked yet. Choose Check Cloud Copy, or wait for the backup to finish."
- "Moby-Dick has changed since it was backed up, so it stays on this Mac. TextMouth is backing it up again."
- "Moby-Dick is open in a reader, so it stays on this Mac. Close its window and try again."
- "Moby-Dick is kept on this Mac. Choose Stop Keeping on This Mac first."
- "The copy of Moby-Dick that iCloud Drive sent back doesn't match this Mac's. Moby-Dick stays on this Mac, and TextMouth is uploading it again."
- "iCloud Drive is out of room, so 138 books aren't backed up yet. Nothing was removed from this Mac."
- "The cloud store can't be reached, so nothing was removed from this Mac. Your library is as it was."
- "Emma's copy is missing from iCloud Drive. Emma is still on this Mac, and TextMouth is backing it up again."
- "Emma's copy is missing from iCloud Drive, and Emma isn't on this Mac. Look in iCloud Drive's Recently Deleted, which keeps deleted files for 30 days, then choose Check Cloud Store again."
- The status line: "Cloud store: TextMouth Store in iCloud Drive. 612 books backed up, 138 backing up, 4.2 GB can be freed."

### Setting up, and its refusals

- "TextMouth will make a folder named TextMouth Store in the folder you choose, and copy every book into it. Nothing leaves this Mac until you choose Remove from This Mac for a book."
- "That folder isn't in a cloud drive, so a store there would protect nothing. Choose a folder in iCloud Drive."
- "Your library is in iCloud Drive itself. A cloud store is for a library kept on this Mac. Move the library to this Mac first, with Change Location."
- "A folder named TextMouth Store is already there. To use it, choose Use an Existing Store."
- "This folder's store file hasn't arrived from iCloud Drive yet. TextMouth is waiting for it."
- "The store file didn't arrive. Try again when iCloud Drive has finished syncing. TextMouth won't make a new store here."
- "This store belongs to another TextMouth library, so this library can't use it."
- "A later TextMouth made this store. Update TextMouth to use it."

## 6. An older TextMouth

"Older" means 0.4.11 and before, which know nothing of the store and never write in it.

- **After `store-backup`:** each package holds `.cloudCopy.json`.
  An older TextMouth ignores it: the name is hidden, so it is never taken for the book (`isPackageContentName`), never exported, and never counted by `regularFilePaths` (`FileImportService.swift:1243`).
  Without the dot, an older rebuild would take the pointer for the book's own file once the content was gone (`:3886`).
- **After a removal,** an older TextMouth:
  - opens the library, and reads a text book from content.md;
  - can't play such an audiobook (`AudioPlaybackService.swift:908`), export its original, or read it again from its file;
  - stamps its row and record as failed for pages at the launch re-read, and doesn't try again (`LibraryViewModel+Migration.swift:1254`, `unreadableText`);
  - **leaves it out of a rebuilt index:** `orphanedBook(in:libraryDirectory:access:)` returns no book for a package whose content is absent (`FileImportService.swift:3886` and the lines after it).
    Nothing is deleted, and a newer TextMouth adopts the package again, but the book's place on the reading list is lost.
- So `store-remove` is 0.5.0, and its changelog entry says: update every Mac first, and don't rebuild the index in an older TextMouth.
- **Whether an older data-directory move or Replace Existing carries the hidden pointer** is read from the code, not run.
  A pointer left behind or carried to other content does no harm: proof is tied to fingerprints, and R4 checks them again.
- `StorePackageAsOlderVersionsReadItTests` (4.1) pins each line above against today's code before any branch changes it.
- V04, being built today, keeps unknown keys through a save from the version that has it on; 0.4.11 and before still drop them, so the pointer stays a file of its own.

## 7. The five missed risks

From `guards0-report.md`, "Risks the research missed".

1. **A reader left open plays on from its old place, which becomes the later one.**
   Phase 2's: it needs a merge before a book opens.
   Phase 1 shares no state between devices, and copies each record's bytes into the device folder, deriving nothing.
2. **A cloud folder chosen before another Mac's files arrived looks empty.**
   Phase 1 must handle its own form: a store folder that looks empty because `store.json` hasn't come.
   So a store is made only in a folder TextMouth itself just made, exclusively; an existing folder is only ever opened, after a bounded wait for its `store.json`; and no path gives a store a second identity.
   Test: `testAnExistingFolderIsNeverGivenANewStoreFile`.
3. **A stale feed record's item is downloaded again as a second copy.**
   Phase 2's: it is the feeds' merge.
   In Phase 1 a second copy is a second book with its own blobs, which wastes room and loses nothing.
4. **Replace Existing wrote a fresh record without Move to Library's note** (fixed in Phase 0, 7fefe585).
   Phase 1 must handle the same shape: any command that writes a book's content again leaves a pointer describing other bytes.
   R4 answers it for every such command at once: a removal trusts no date, only a stamp equal to the pointer's or a fresh hash.
   Tests: Replace Existing, the EPUB details write-back, and an audio edit, each followed by Remove from This Mac, are refused and backed up again.
5. **A setting or bookmark changed without moving gives way to the other Mac's.**
   Phase 2's: it needs a clock on each value.
   Phase 1 keeps bookmarks whole in each record, with their identifiers, so nothing Phase 2 needs is lost.

## 8. iCloud Drive

### What Apple documents

Read in the macOS 26 SDK's headers and Apple's pages on November 15 (Sources).

- `evictUbiquitousItem(at:)` "removes only the local version", and must not be called inside a coordinated write [1].
- `startDownloadingUbiquitousItem(at:)` starts a download, or "synchronizes the local copy with the version in the cloud", and returns at once [2].
- `ubiquitousItemIsUploaded` is "true if there is data present in the cloud for this item", and no more [3][8].
- `ubiquitousItemDownloadingStatus` `.current` is "the most up-to-date version known to this device" [8].
- `ubiquitousItemUploadingError` carries `NSUbiquitousFileNotUploadedDueToQuotaError` when the account would go over its quota [8].
- `ubiquitousItemIsExcludedFromSync`: an excluded item is "locally on disk but won't be available on the server" [8].
- File Provider's eviction fails for an item with changes not uploaded, with open file descriptors, or with several hard links [8].
- `NSFileCoordinator` coordinates "among multiple processes and objects in the same process" [4].
- `NSMetadataQuery` is "a query that you perform against Spotlight metadata" [5], and its ubiquitous scopes search "the app's iCloud container directories" [6]; TextMouth has no iCloud entitlement, and so no container.
- `FileManager.copyItem` "automatically create[s] a clone for Apple File System volumes" [7]; `clonefile(2)` is "expected to be atomic", and copies extended attributes [9].
- `fileContentIdentifier`: "Only cloned files and their originals can have the same identifier" [8].

### What this Mac showed in October

From `docs/developer/testing.md`, "Testing on real cloud drives", in a throwaway folder with the user's yes.

- The status keys answer for iCloud Drive files to an app with no iCloud entitlement.
- Files written with plain file calls uploaded within 10 seconds, and both calls above worked.
- iCloud Drive syncs a package as one item, and gives a file it downloads again a modification time in whole seconds.

### What is inferred or unknown

- That iCloud Drive's folder is `~/Library/Mobile Documents/com~apple~CloudDocs`: seen, not documented; the code tells iCloud Drive by `Mobile Documents` in the path (`UbiquitousItemStatusProvider.swift:204`).
- Whether a read-back comes from Apple's server or from a cache on this Mac: nothing says.
- Whether a clone into the folder stays a clone: section 9.
- Whether a metadata query over a path in iCloud Drive reports upload percentages to an app without the entitlement: not documented, not tried.
- Whether coordination changes anything for iCloud Drive's own folder: Apple asks for it in an app's container, and says nothing of this folder.

### What the design does

- **Status by polling** the keys TextMouth reads today (`statusKeys`, `UbiquitousItemStatusProvider.swift:97`), from a fresh URL each time (`:144`); no `NSMetadataQuery`.
  So "Backing Up 40%" counts the bytes of blobs reported uploaded, not a file's own progress.
- **No coordination for blobs:** each is moved in complete, has one writer, and never changes.
  A device folder's file is replaced inside a coordinated write (`.forReplacing`) on a background queue with a 30-second limit, since the drive may be reading it.
- **Eviction** is never coordinated, and a busy or not-uploaded refusal is a wait, not an error.
- **Out of room** is told from the quota error, and gets its own sentence.
- **An excluded folder** (a name ending `.nosync`, or the flag) is refused at set-up, since nothing in it would upload.
- **Signed out, or iCloud Drive off:** the bookmark no longer resolves, the store is unreachable, and the library is as it was (R2).
- **macOS 14** is the floor, so macOS 26's sync controls are not used; nothing in the store has two writers.

## 9. The clone measurement

### The instruments, checked in a scratch folder

A 60-line Python script, run once in the session's scratch folder on the startup disk, on a 16 MB file of random bytes.
It needs no compile: it calls `clonefile(2)` and `getattrlist(2)` through `ctypes`.
It read two things for each file, with `FSOPT_ATTR_CMN_EXTENDED`: the private size (`ATTR_CMNEXT_PRIVATESIZE`, the bytes deleting the file would free) and the clone identifier (`ATTR_CMNEXT_CLONEID`).

- The file alone: private size 16,777,216.
- After a clone: the file and its clone each report private size 0, and one clone identifier.
- A plain copy of the same bytes: private size 16,777,216, and another identifier.
- A clone replaced by a new file of the same bytes, as a drive rewriting it would do: private size 16,777,216, and another identifier.

So the two readings tell a clone from a copy, and show the moment a clone stops being one.
The script is in the report's scratch folder; a later agent can write it again from this section.

### The run that needs the user's yes

The same probe, pointed at a throwaway folder in iCloud Drive (as October's tests used `TextMouth Cloud Tests`), with one 16 MB file:

1. clone it into the folder, and read both at once, for the file and for its original;
2. read them again when the drive reports it uploaded, and five minutes later;
3. remove its download, ask for it back, and read them again.

It writes one file, downloads it once, and deletes nothing.
It is not part of any branch, and no agent runs it without the user's yes.

### What the result changes

- **If the clone stays a clone until it is evicted:** backing up costs no room on this Mac, the budget of 4.3 can rise, and the set-up sheet may say "copying takes no extra room on this Mac".
- **If the drive replaces it with a copy of its own:** each book costs its size from copy to proof, the 2 GB budget stands, and the sheet says "TextMouth backs up a few books at a time, so it needs about 2 GB free".
- **Either way,** a read-back is a new download, never a clone, so a proven blob's download is always removed.
- Nothing else in the design depends on it.

## 10. Questions for the user

Each has the answer I recommend, which is what the branches build.

1. **May the four branches that change nothing you hear be built and merged now?**
   Recommended: yes. They add no setting and no command, and a test holds that.
2. **When should the Cloud Store section appear in Storage settings?**
   Recommended: built on its own branch now, merged only when you say. Backing up copies books and removes nothing.
3. **Should every backed-up row say "Backed Up"?** With 1,500 books that is one more phrase on almost every row.
   Recommended: no. A row speaks only the exceptions (Not Backed Up, Backing Up, In Cloud, Backup Failed), and Book Information always says the full state.
4. **The check downloads each book once**, about 11 GB over time, a few books at a time, never on a hotspot or in Low Data Mode.
   Recommended: yes. It is the only proof that goes through the drive.
5. **Phase 1 never deletes from the store**, so a book you replace or delete leaves its old files there until Phase 2 cleans up.
   Recommended: yes. Check Cloud Store says how much room they take.
6. **Feed episodes you haven't moved to the library aren't backed up**, since they can be downloaded again.
   Recommended: yes.
7. **May an agent run the clone measurement** in a throwaway folder in your iCloud Drive: one 16 MB file, a few minutes?
   Recommended: yes, before `store-settings` merges. Nothing waits on it.

## What I could not verify

- Any real drive: nothing here ran against iCloud Drive.
- That a text book opens from content.md with its file gone, and what an older move or Replace Existing does with a hidden file: read, not run; 4.1's tests pin them.
- How VoiceOver reads any new control: none exists yet.
- Whether two Macs can come to share one Mac ID (a Mac set up from another's backup): Phase 2 must guard it before a second device writes.
- How Time Machine treats blobs whose downloads were removed.

## Sources

1. `evictUbiquitousItem(at:)`: https://developer.apple.com/documentation/foundation/filemanager/evictubiquitousitem(at:)
2. `startDownloadingUbiquitousItem(at:)`: https://developer.apple.com/documentation/foundation/filemanager/startdownloadingubiquitousitem(at:)
3. `ubiquitousItemIsUploaded`: https://developer.apple.com/documentation/foundation/urlresourcevalues/ubiquitousitemisuploaded
4. `NSFileCoordinator`: https://developer.apple.com/documentation/foundation/nsfilecoordinator
5. `NSMetadataQuery`: https://developer.apple.com/documentation/foundation/nsmetadataquery
6. `NSMetadataQueryUbiquitousDocumentsScope`: https://developer.apple.com/documentation/foundation/nsmetadataqueryubiquitousdocumentsscope
7. About Apple File System: https://developer.apple.com/documentation/foundation/about-apple-file-system
8. The macOS 26 SDK in this Mac's Xcode: Foundation's `NSURL.h`, `NSFileManager.h`, `NSFileCoordinator.h`, `NSMetadataAttributes.h`, and `FoundationErrors.h`; FileProvider's `NSFileProviderManager.h`.
9. This Mac's manual pages `clonefile(2)` and `copyfile(3)`.

Pages 1 to 7 were read through a fetch tool that extracts each page with a small model, so their quotations are as that tool gave them.
The headers of [8] and the manual pages of [9] I read directly.

# Library sync: the folder, the outbox, and the merge
<!-- id: library-sync; keys: FR43, sync, iCloud Drive, TextMouth Sync, SyncCenter, SyncEngine, registers; src: TextMouth/Services/Sync/SyncCenter.swift, TextMouth/Services/Sync/SyncEngine.swift, TextMouth/Models/Sync/SyncInterfaces.swift -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

FR43 keeps one library the same on the Mac and the iPhone through a TextMouth Sync folder in iCloud Drive.
Each device keeps its whole library on its own disk and records its changes; unlike a version control system, the folder keeps each value's latest change, not a history.
research/CLOUD-SYNC-BUILD-PLAN-2026-11-25.md is the design, and where it and the code differ, the code wins.
This page is the model: files, outbox, clock, merge, and saves.
[Library sync: books, platforms, and the rules](library-sync-store.md) is the rest.
What a person hears is in [Syncing your library between your devices](../../user/syncing-your-library.md), and the tests are in [Testing library sync](../../developer/testing-sync.md).

The parts, all under TextMouth/Services/Sync/ and TextMouth/Models/Sync/:
- `SyncCenter`, on the main actor, is the app's one sync: its status, its timers, and its runs.
- `SyncEngine`, an actor, owns the device's files, the outbox, the registers, and the exchange with the folder; the library never waits on it.
- `SyncMerge`, `SyncRegisters`, `SyncProjection`, and `SyncFolderPlan` are pure: no file, no clock, no randomness.
- `SyncLibraryHost`, which `LibraryViewModel` conforms to on both platforms, is how a merge reaches the library (`LibraryViewModel+Sync.swift`).

## The sync folder
<!-- id: library-sync-folder-layout; keys: store.json, Devices, Books, device.json, SyncNames, formatVersion; src: TextMouth/Services/Sync/SyncNames.swift, TextMouth/Services/Sync/SyncFolder.swift, TextMouth/Models/Sync/SyncFormats.swift -->

```
TextMouth Sync/store.json
TextMouth Sync/Books/<book id>/<sha256>.<ext>, <sha256>.manifest.json
TextMouth Sync/Devices/<device id>/device.json, <seq>.changes.json, <seq>.snapshot.json
```

- `SyncNames` holds the names, pinned by `OnDiskContractTests`: lower-case UUIDs and digests, a 12-digit `seq`, extensions of 1 to 8 of `a-z0-9` or `bin`, and plain folders, since iCloud Drive syncs a package as one item.
- `store.json` names the store (`storeID`, `createdBy`, `createdByVersion`) and is made once, only by `SyncFolder.create`, in a folder Set Up Sync just made.
  Join waits 60 seconds for it (`waitForStore`) and never makes one.
- Every file is JSON with sorted keys and dates to the second, `formatVersion` 1 (`SyncFormats`), so one value is always the same bytes.
  A file of a higher version is left alone, and `SyncProblem.laterVersion` is said as "a later TextMouth".
- A change file that doesn't decode, or holds other than `count` entries, is not here yet.
  An entry whose key a later TextMouth added is left out of `entries` but counts toward `count`.
- A snapshot holds every value its device knows, so any device's newest snapshot rebuilds the shared state.
- `device.json` is the one file replaced in place: the device's name, platform, app version, `lastSeq`, and the time it published.
- A manifest lists a book's files and blobs without a date, and leaves out the pointer, Finder's debris, `cachedAudio`, and the removal marker; a bookInfo.json change alone makes no new manifest.

## The device's own files
<!-- id: library-sync-device-files; keys: Sync folder, device.json, clock.json, cursors.json, registers.json, baseline.json, installID, incarnation; src: TextMouth/Services/Sync/SyncLocalFiles.swift, TextMouth/Services/Sync/SyncPreferences.swift, TextMouth/Services/TextMouthPaths.swift -->

In `Sync/<store id>/` of the data directory (`TextMouthPaths.syncDir`), on the device's own disk and never in iCloud Drive:
- `device.json` (`deviceID`, `incarnation`, `installID`, `lastSeq`, and when the last snapshot was made), `clock.json`, and `cursors.json`, each other device's last `seq` merged;
- `registers.json`, every key's winning entry, with `throughSeq`, the last outbox file in it;
- `baseline.json`, the library's values as last recorded or applied;
- `Outbox/`, with `outbox.json` giving each file's state, and `Staging/`, where files are made whole before they move.

Every write is atomic, and a file that is missing or doesn't decode reads as nothing, so a crash leaves a state the next run repairs.
`SyncPreferences` keeps the folder's bookmark, the store's ID, and the install's ID in the process's preferences, like `DataDirectoryPreferences`.

A device's ID is made when its library joins, so two libraries on one Mac are two devices.
A library restored onto another install (another `installID`), or a copy that finds another writer's file under a `seq` it numbered itself, takes a new identity: the old outbox is set aside, never adopted and never deleted, and a snapshot is published (`SyncEngine.takeNewIdentity`).

## The outbox
<!-- id: library-sync-outbox; keys: Outbox, outbox.json, written, copied, uploaded, retireUploaded, offline, unconfirmedStay; src: TextMouth/Services/Sync/SyncOutbox.swift, TextMouth/Services/Sync/SyncEngine.swift -->

A change leaves its device only through the outbox.
1. The recorder writes each batch of stamped entries to `Outbox/<seq>.changes.json`, atomically, and then saves the clock, the registers, and the baseline.
2. Each run that reaches the folder copies every outbox file still `written`, or `copied` but now missing there, into `Devices/<id>/`.
   The copy is local, needs no network, and iCloud Drive uploads it when it can.
   A file already there with the outbox's bytes is left alone; one with other bytes is another writer's (`SyncOutboxConflict`).
3. The run reads each copy's upload state (`SyncFolderAccess.uploadState`, from the ubiquitous-item upload keys): `uploaded`, `uploading`, `failed`, or `notReported`.
4. A file leaves the outbox once it and a later snapshot have uploaded (`retireUploaded`); a copy the drive never reports on goes a week after it was copied.
5. Where no upload state is reported, a copy counts as sent, not uploaded.
6. `pendingChanges` is the entries of every change file whose copy hasn't uploaded; snapshots hold no new change.

A file sent again keeps its name and bytes, and an entry merged twice changes nothing: nothing is lost or doubled.
After a crash, outbox files past `throughSeq` go back into the registers when the engine opens, and a change in library.json that is in no outbox file is found by the next recording.
A snapshot is due for a new device, after 100 files, or after a day.

## Stamps and the clock
<!-- id: library-sync-stamps-clock; keys: hybrid logical clock, HLC, SyncStamp, SyncClock, maximumAhead, joiningStamp; src: TextMouth/Models/Sync/SyncInterfaces.swift, TextMouth/Services/Sync/SyncEngine.swift -->

An entry is a value and its `SyncStamp`: wall-clock milliseconds, a counter, and the device ID, compared in that order (a hybrid logical clock).
Any two stamps are ordered alike on every device.

`SyncClock.next(at:)` takes the later of the last stamp and the clock, so a clock set back never dates a change before an earlier one.
`observe` moves the clock past each stamp merged, but refuses one more than a day ahead of the clock (`maximumAhead`): it is merged and the clock doesn't follow, so one device with a wrong clock can't freeze the others, and a `SYNC_RUN` line counts the refused.

A device's first record in a store (a joining, restored, or copied library) is stamped with `SyncMerge.joiningStamp`, as old as its values are, so they lose to what the store holds already.

## Keys, registers, and merging
<!-- id: library-sync-registers-merge; keys: SyncKey, SyncRegisters, SyncEntry, byHand, removal mark, SyncOrderKey, SyncFolderPlan, commutative; src: TextMouth/Models/Sync/SyncInterfaces.swift, TextMouth/Models/Sync/SyncProjection.swift, TextMouth/Models/Sync/SyncFolderPlan.swift, TextMouth/Models/Sync/SyncOrderKey.swift, TextMouth/Models/Sync/SyncApplier.swift, TextMouth/Models/Sync/SyncFeedValues.swift, TextMouth/Services/Feeds/FeedCenter+Sync.swift -->

A `SyncKey` is one register of the shared state, written as a line of text: `book/<id>/<field>`, `bookmark/<book id>/<id>`, `folder/<id>/<field>`, `readingList/<book id>`, `readingListOption/<option>`, and `feed/<id>/<field>`.
- A book has `presence`, `content` (the uploaded manifest, with what a device lacking the book makes its row from), its details, `folder`, its settings, `position`, `skippedHeadings`, `lastOpened`, and `keep`.
- A bookmark merges one by one, keeping both devices' additions; its `number` is not synced, since removals renumber.
- A folder has `presence`, `name`, and `parent` by ID, where the library's paths name folders.
- A feed has `presence`, `address`, `subscribed`, `folder` (the library folder's ID), `unsubscribed`, and its own `itemPolicy`, `deleteAfterPlayed`, and `listening` choices (`SyncFeedField`, `SyncFeedValues`).
  A refresh's reading (title, items, fetch state) is no key, so a refresh records nothing.
  Downloads stay on each device, and a device lacking the feed makes its record from `address`, `subscribed`, and `folder`.
- Left out: feed items and their places, the global feed settings, a folder's listening options, `Library.unreadableRows`, the manual order, playback times, and what a device keeps for itself.

`SyncRegisters.merge` keeps each key's highest `SyncEntry`: a `byHand` entry (`HandEdits`) first, then the later stamp, then the values' text, so every device picks the same one.
So any order of merging gives the same registers, merging twice changes nothing, and a re-read of a file never replaces a person's edit.
A null value is a removal mark; a book or folder is removed when its mark is later than all its other entries, so a later change elsewhere brings it back.

A feed merges like a book: `SyncMerge.apply` returns a `SyncFeedApplication` beside the library's changes, and `FeedCenter.applySync` carries it out through the feed store and Delete Feed.
Folders apply first, then books, then feeds, so a new feed's folder is there when it lands; a feed waits, keys unapplied, until its `address`, `subscribed`, and `folder` have arrived and its folder is live.
Two feeds of one address (`FeedAddress.comparisonKey`) subscribed apart stay one on each device: a device adds no feed whose address it holds, and a Delete Feed reaches every copy of the address.
A feed another device deleted is deleted here as Delete Feed does, with this device's Trash setting and `leavingLibraryFolder`, so the library folder follows its own keys.

The reading list sorts by key, then ID.
`SyncOrderKey` makes a key between two neighbours, only for a moved book, so an addition on one device and a move on another both stand.
`SyncFolderPlan` walks the folders by parent ID, the same on every device:
- a removed parent's children go to its nearest live ancestor;
- a cycle is cut at its latest parent change, to the top;
- a folder deeper than `BookFolder.maxDepth` rises to it;
- two live folders of one name under one parent fold into the older, the applier recording the moves and the removal.

## Recording and applying
<!-- id: library-sync-record-apply; keys: SyncRecorder, SyncMerge.changes, baseline, applySync, performLibraryTransition, SyncRowMerge, SyncLibraryHost; src: TextMouth/Services/Sync/SyncRecorder.swift, TextMouth/Services/Sync/SyncEngine.swift, TextMouth/ViewModels/LibraryViewModel+Sync.swift, TextMouth/Models/Sync/SyncProjection.swift, TextMouth/Services/LibraryPersistenceService.swift -->

Every writer changes `LibraryViewModel.library`, whose `didSet` calls `SyncCenter.libraryDidChange`, so no writer is wired by hand and both platforms are covered.
`SyncRecorder` runs `SyncEngine.record` 2 seconds after the last change (a burst of checkpoints is one recording), before each merge, as the iPhone goes to the background, and as the Mac quits.
It does nothing while a merge is applied.

A feed's change reaches the recorder through `LibraryViewModel.followFeedsForSync`: it watches the store's synced values, so a refresh, which changes none, schedules nothing.
Until `FeedStore.hasLoaded`, `syncFeeds` is nil and no feed key is recorded or applied, so a launch never reads as every feed removed.

`record` makes the library's `SyncProjection` and compares it with `baseline.json`, skipping books equal to their baseline, and stamps each changed key.
Its first run after launch stamps what an older TextMouth left in library.json (`SyncLaunchHold`; see R7 in the next page).

Applying a merge, on the main actor:
1. The engine records the library as it is, and `SyncMerge.apply` works the merge out from it: rows changed, books to add and remove, and whether packages move.
2. `LibraryViewModel.applySync` makes a placeholder for each new book, off the main thread, and changes folders and moves packages first, through `performLibraryTransition`.
3. It then sets each field the merge changed onto the library as it is now, only where the person has not changed it since (`SyncRowMerge`); a row with such a field is left alone and offered again at the next sync.
4. Records are written by `LibraryPersistenceService.saveBookInfo(for:asMerged:)`, which skips `takeStandingReadingState`, so a record's older place can't stand over the merged one.
   Then the readers of books whose place changed hear of it (`syncedReadingStates`).
5. Books another device removed are removed by the delete path with this device's Trash setting, unasked, except a book that is busy.
6. The baseline takes the applied values key by key, so a change made meanwhile is still found.

A new book joins by `Library.addBook`, which refuses an `md5Hash` this device has, so a book imported on both stays one on each.
A voice this device lacks isn't applied (`availableVoiceIDs`).
Nothing syncs while `maySyncNow` is false: storage work held, the library unavailable or recovering, or its data directory moving.

## Reading other devices' files
<!-- id: library-sync-reader-cursor; keys: SyncReader, cursor, seq, snapshot, notArrived, 30 seconds, two minutes; src: TextMouth/Services/Sync/SyncReader.swift, TextMouth/Services/Sync/SyncEngine.swift -->

iCloud Drive promises no order, so `SyncReader` never takes a listing to hold every file.
A device's cursor moves only to the next `seq`: a `seq` that is missing or not readable yet holds it, unless a later snapshot that reads covers it, and then the cursor jumps to that snapshot.
The newest `seq` a device expects is the highest it lists or its `device.json` says.
A device read for the first time starts at its newest readable snapshot.

Reading is bounded (R2): 30 seconds a file and two minutes a moment (`SyncReadLimits`).
A device whose newest files hadn't arrived is named in `notArrived`, which says "Some changes from iPhone haven't downloaded yet"; a later TextMouth's file is left alone and said; a read refused at once for want of a network sets `sawOffline`.

## The save order
<!-- id: library-sync-save-order; keys: crash, SyncStep, registers before cursors, clock, throughSeq, atomic; src: TextMouth/Services/Sync/SyncEngine.swift, TextMouth/Services/Sync/SyncLocalFiles.swift -->

The order is chosen so that a crash between two saves re-reads, never loses:
1. Recording: the outbox file is written first.
   The registers and baseline take the entries in memory at once, before any save that can fail, so a snapshot made after a failed save still holds them.
   Then the clock, the registers, and the baseline are saved.
2. An exchange: publish `device.json`, copy the outbox, read the upload states, retire uploaded files, and read other devices' files.
3. The merge into the registers, then the registers, the clock, and last the cursors.
4. Then the apply, and the baseline after it.

`SyncStep` names these steps, and `SyncInterruptionTests` stops the engine after each in turn, restarts it on the same files, and checks that nothing is lost, doubled, or different between devices.

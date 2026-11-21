# A library on each device, with a safer library in the cloud

November 13, 2026. Research and design for your message of about 1:05 a.m.:

> "I am starting to to think if it would be a better idea to refactor the library system so that a full set json and book data would be stored locally always with just pointers to the cloud library like paths or symbolic links (not sure how that sould work on IOS), which would also have the full data on the books to be eventually sinked? My thought being we could have some books perdimently local but maybe build the Cloud libary to be safer so we can delete the local copy to save space eventually."

You are weighing this, not deciding it, so the document ends in a recommendation and questions, and nothing is built until you choose. The agent `localfirst` (Opus) wrote it read-only, against main at 130f6788 (version 0.4.6), the macOS 26 and iOS 26 SDK headers in this Mac's Xcode, and Apple's, Google's, and Dropbox's own pages. Your library was never read: its size here (11 GB in ~/.TextMouth, 750 books with 677 MB of text) is what the orchestrator gave. Bracketed numbers cite the Sources at the end; a file name with a line number points into the repository.

## Summary

1. Today the whole library can live in a cloud drive's folder, and the drive decides what stays on this Mac.
2. That has three weak points. The library can't open while its index is only in the cloud and the Mac is offline. Two devices overwrite each other's changes, a whole file at a time, and nothing merges them or even notices: a device that is behind can put a book's old place back just by opening it, and your own two copies came apart in early November. And Remove Download trusts the drive's word that the cloud has the book.
3. Your idea answers the first and the third: the library's own files always on each device, the books' files in the cloud, and a local copy removed only once the cloud copy is proven.
4. Taken literally, as two complete libraries kept in step, it keeps the second: devices would still write the same files.
5. So I recommend your idea in one shape, which I call the cloud store. Each device keeps its whole library on its own disk, as your library is kept today.
6. The store is a folder in iCloud Drive, Google Drive, or Dropbox. It holds every book's files, each named by a fingerprint of its content and never changed once written, and one file of changes for each device, which only that device writes. Each device merges the others' files by fixed rules, so no two devices ever write the same file.
7. No symbolic links: the iPhone can't follow one out of its sandbox, and the drives sync them differently or not at all. A book points into the store by a path inside the store's folder, and by its fingerprint.
8. A local copy goes only after TextMouth has had the drive send its copy back and found the same fingerprint in it.
9. It needs no paid Apple account, and the iPhone reaches the same store through the Files app. CloudKit would need the paid program, and works with iCloud alone.
10. It comes in phases, each useful alone: a read-only comparison of your two diverged copies, with three small guards for today's cloud library; the store on this Mac, which frees space safely; syncing between devices, the largest and riskiest part; then the iPhone.
11. Twelve questions end the document, each with the answer I recommend.

## 1. What the design has to give

From your message:

- **W1. The library always opens.** Its index, every book's record and text, and your settings are on each device, offline too.
- **W2. A full, safe copy in the cloud.** The cloud holds every book's full data, proven, not only what the drive happened to upload.
- **W3. Local by choice.** Some books stay on this Mac for good. Any other can leave it to save space, but only once its cloud copy is proven.
- **W4. Eventually synced.** A change made on one device reaches the others, and no change is lost because two devices each made one.
- **W5. The iPhone.** The same idea works where an app lives in its own sandbox.

Today's design, for comparison:

- The data directory (library.json, config.json, every book's package under Library, the feeds, the statistics) can be any folder, a cloud drive's included, and the drive fetches and evicts its files as it likes. This Mac keeps only its own choices, such as Kept Books.json, outside it (`MachineLocalPaths`, CloudStorageContract.swift:573-660).
- It meets W3 in part (Keep on This Mac, Remove Download), W1 only while the drive keeps the index downloaded or the Mac is online, W2 only as far as the drive does, W4 by overwriting, and W5 not at all: the iPhone app keeps a library of its own in its container (TextMouthPaths.swift:15-30).

## 2. Today's risks, ranked

Ranked by what each can cost you, then by how likely it is. "Two devices" means two Macs today, or a Mac and the iPhone later, using one data directory in a drive's folder, at the same time or one after the other while the drive catches up. None of these touches a library kept on this Mac alone, as yours is now. A second agent read the code independently for this document and found risks 2, 4, 5, 7, 12, and 13, and parts of others. I checked risks 1 to 7 at the lines given; a line that only that read checked says "by the code read".

1. **Two copies drift apart, and nothing says which is newer. (Reported: it has happened.)**
   - In early November you moved your library to Google Drive and back. A move copies the library and leaves the old folder where it was (where-your-library-lives.md, line 20). Going back with Use This Library switches to the old folder as it is, and its confirmation says only "This folder holds another copy of the library TextMouth is using, which may not have its latest changes." (StorageDestinationAssessment.swift:515).
   - The TODO records that "the two libraries have diverged" (TODO-2026-09-04.md, line 3710). What you did while the library was in Google Drive is only in `TextMouthLibrary` there (humanQuestions/2026-11-06.md, question 4), and what you've done since is only in ~/.TextMouth.
   - Nothing compares two copies or merges them. Test: none; `testAnotherCopyOfTheLibraryInUseIsSaidToBeOne` checks only the warning.
2. **Reopening a book on a device that is behind puts the old place back, newly dated.**
   - The reader starts at the place in the book's row in the library (ReaderViewModel.swift:794-797), and once the text has loaded it saves that place with the time of the save (lines 1757-1758; a new position takes the current time, Book.swift:1703).
   - The book's record is rebuilt from that row, keeping from the record on disk only its content index, transcript note, feed link, braille settings, and encoding (Book.swift:1257-1296). So the newer place, bookmarks, and per-book settings the other device saved in the record give way to this device's older ones.
   - The new date then wins every later "the newer place wins" comparison. The architecture says as much: "A reader re-dates its position at every open" (package-records.md, line 36).
   - Trigger: TextMouth left open on one Mac while you listen on the other, then the book opened there; or a Mac starting from a library.json older than the other's records. With an iPhone, the phone in your pocket is that second device. Test: none for two devices.
3. **Two devices overwrite each other, a whole file at a time, without noticing.**
   - library.json: every save encodes the whole index and replaces the file (LibraryPersistenceService.swift:492-504). It skips a write only when the bytes equal what this process last read or wrote itself (SavedFile.swift:177-179), never looking at what is on disk now, so another Mac's newer index gives way to this Mac's next change. Each feed's own index is written the same way (LibraryPersistenceService.swift:538-561, by the code read).
   - Each feed's record is written whole from memory (FeedStore.swift:448-457), so a Mac holding an old copy also undoes the other's Unsubscribe and Delete Episode (FeedStore.swift:379-396, by the code read).
   - reading_stats.json (ReadingStatsService.swift:743-754 and 796) and substitutions.json (TextSubstitutionService.swift:716-721) are written whole too: one device's listening time or rules go when the other saves.
   - Only config.json is read and merged before each write (ConfigService.swift:887-906).
   - No file presenter, file version, or file coordination is used anywhere in the Mac's library code: a search of the app finds `NSFileCoordinator` only in the iPhone's import copier (PhoneImportCopy.swift:435). The tests say so in their own words: "Merging what two Macs wrote is left for later." (MultiMacCrashSafetyTests.swift:15). The session lease only warns (cloud-library.md, line 36).
4. **An episode moved to the library on one device goes back to its feed, and its audio can be deleted.**
   - Move to Library marks the item as in the library. The other device's record of the feed, written whole from memory, still calls it downloaded.
   - At the next launch, the step that moves older downloads into their feeds takes every book of the library's own whose ID a feed's record names as a download (LibraryViewModel+FeedItemMove.swift:145-157; only the downloaded state names a book there, FeedItem.swift:167-169). The book becomes the feed's again, and the rule that removes played episodes can then delete its file for good (FeedLifecycle.swift:446-462, by the code read).
   - Test: one device only (`FeedMoveToLibraryOperationTests`).
5. **Opening a library before all its small files have arrived replaces or splits them.**
   - With library-identity.json here and library.json not yet, the library opens with no index (DataDirectoryAvailability.swift:584-588; LibraryViewModel+IndexRecovery.swift:207-209). The startup repair adopts whatever packages are here, and its save goes over the real index once that arrives: the reading list, the sorts, the folders' options, and the rows of the books not here yet.
   - With library.json here and the identity file not yet, the library opens as one from before identities (DataDirectoryAvailability.swift:589-593) and is given a new identity (LibraryIdentity.swift:62-79; LibraryViewModel.swift:646-654). Once the drive keeps one of the two identity files, the other Mac says the library isn't available, being a different library.
   - A reading_stats.json not here yet loads as empty statistics, which the first save writes over the real file (ReadingStatsService.swift:324-325 and 395); a config.json not here yet is written from this Mac's settings (SettingsViewModel.swift:592-597, by the code read).
   - Trigger: Use This Library on a second Mac, or any launch, while the drive is still bringing the files down. How long a drive can show one of these files without the other is unmeasured. Tests: the one-Mac cases only (`testMissingIndexIsAFreshInstall` in LibraryIndexPersistenceTests; `testALibraryWithoutAnIdentityIsGivenOneAsItOpens` in DataDirectoryLaunchTests).
6. **Removed books and feeds come back.**
   - Nothing marks a removal. A row whose package is gone is kept as Waiting for Sync, by design, since a package can arrive after its row (`testALibraryIndexListingPackagesNotHereYetKeepsEveryRow`, MultiMacCrashSafetyTests.swift:91-115, and `testAPackageThatDisappearedWaitsForSync`, lines 190-209). So when the other device next writes its index, a removed book's row returns, waiting for a package that never comes.
   - A Mac that is running writes a deleted feed's record again, and makes its folder and index again (FeedStore.swift:448-458; LibraryPersistenceService.swift:545-559, by the code read), so the feed refreshes and downloads once more.
   - A book added on the other device fares better: the startup repair adopts its package from its record, which keeps its reading position, bookmarks, settings, and manual order (Book.swift:1400), in the folder its package lies in. What only the index held is lost: its place in the reading list, and, for a folder made with it, that folder's own sort and listening options.
7. **A folder renamed or moved on one device can leave its books unopenable on the other.**
   - When the other device's index, written last, still puts the books in the old folder, the startup repair looks for each book only there and at the Library's top level (LibraryViewModel+Migration.swift:300-317). The scan for packages that no row lists skips any package whose name a row already holds, wherever it lies (FileImportService.swift:3589 and 3618-3619). So the books stay listed where their packages aren't, and can't be opened, though their files are intact.
   - Books name their folders by path (Book.swift:243), and a folder names its parent by path (BookFolder.swift:6). So a book filed under the old name meanwhile brings back a second folder: the startup repair gives a row to every folder a book lies in (where-your-library-lives.md, line 41). This is also why syncing must name folders by their identifiers. Test: none.
8. **The library can't open while its index is only in the cloud and the Mac is offline.**
   - library.json, library-identity.json, the Feeds folder, and each feed's index must be on this Mac (data-directory.md, "Its availability"; `testALibraryIndexOnlyInTheCloudLeavesTheLibraryUnavailable`, MultiMacCrashSafetyTests.swift:71-86).
   - Since 0.3.2, after your report of November 6, TextMouth fetches them by itself when it can (LibraryViewModel+LibraryFetch; TODO line 3711). Offline, or with the drive paused, signed out, or not running, the library stays unavailable. Nothing can keep these files downloaded: no app may pin another provider's files (section 7).
   - The recovery sheet's Try Again and Rebuild Library Index read library.json with downloading allowed while the main thread waits (LibraryViewModel+IndexRecovery.swift:341-343, by the code read), so an index evicted while the sheet is open hangs TextMouth.
9. **Conflicts are seen and never acted on.**
   - TextMouth reads each file's unresolved-conflict flag (UbiquitousItemStatusProvider.swift:146), and nothing ever uses it. A drive's conflict copy is left alone and never read (`testConflictCopiesBesideTheLibraryIndexAreLeftAlone`, MultiMacCrashSafetyTests.swift:28-43; cloud-library.md, line 39).
   - So the changes the drive set aside sit unseen, and you aren't told. On iCloud Drive the losing versions also go on taking your iCloud storage until an app removes them [7].
10. **Remove Download trusts the drive's word.**
    - It refuses only when the upload flag is false (BookCloudStorageService.swift:384-390), and a file that reports no flag at all counts as uploaded (UbiquitousItemStatusProvider.swift:316).
    - Apple's header defines the flag as "true if there is data present in the cloud for this item", and its documentation promises nothing more [3][21]. A download status of current means "the most up-to-date version known to the device" [4].
    - The drive's own eviction does refuse a file whose changes haven't uploaded (NSFileProviderManager.h, `evictItem`) [14][21], and the October tests saw Dropbox refuse one (CLOUD-STORAGE-MANUAL-TESTS-2026-10-03.md, line 63). But nothing checks the cloud copy's content, and once the download is removed the drive holds the only copy.
11. **Two versions of TextMouth undo each other's newer state.** An older one drops the fields it doesn't know at its next whole write, and offers Rebuild Library Index, which leaves out books in formats it can't read (cloud-library.md, line 38). What goes includes an unsubscribe, Edit Text's record of an edit (so a later re-read for pages replaces the edited text, keeping only a copy), text anchors, and hand edits (library-index.md and feeds.md, by the code read). You run 0.4.2, and main is 0.4.6.
12. **The crash journal is shared.** reading-checkpoints.json, which brings back the last few minutes of places after a crash, is cleared by whichever Mac next writes library.json (LibraryPersistenceService.swift:469-471), so a crash on one Mac can lose up to five minutes of place in each book it was reading. Test: one Mac only (ReadingCheckpointTests).
13. **Moving a library out of a cloud folder waits on the network.** The move refuses only while books are only in the cloud. Everything else only in the cloud, such as an episode's folder, a feed's record, or a log, is copied with downloading allowed, so the move's sheet waits on the network, or the move fails offline (LibraryViewModel+Migration.swift:1841-1851; DataDirectoryMigrator.swift:448-456, by the code read). Nothing is lost.

## 3. The options

### A. Today's design, made safer

- **What it is.** The data directory stays in the drive's folder, and TextMouth:
  - keeps its own small files downloaded: library.json, library-identity.json, config.json, each package's bookInfo.json, contentIndex.json, and content.md, and the feeds' records and indexes. When the drive evicts one, TextMouth asks for it again at once, as Keep on This Mac does for a book;
  - leaves only the big files to the drive: the books' own files and audio, as today;
  - fixes the risks above: it reads library.json again before each write and merges by row, marks removals, reports conflict copies and conflicting versions, and lets Remove Download go ahead only for a file that is uploaded, not uploading, current, and free of conflicts.
- **What it can't do.** No app may pin another provider's files: the "keep downloaded" policy is a property the drive's own extension sets, and exists on the Mac only, not on iOS [14][21]. So TextMouth can fetch its small files back but never stop the drive evicting them, and an offline Mac whose drive evicted library.json still can't open the library.
- **Its merges would be guesses.** Nothing records which device changed what, or when. Positions carry a date (Book.swift:1692), but bookmarks have only a creation date (Book.swift:1730), and settings, the reading list, and folders have none.
- **How it meets the wishes.** W1 only online; W2 only as far as the drive does; W3 yes; W4 by guesswork; W5 only as its worst case, the phone in your pocket writing the same files while the Mac is open (IOS-PORT-RESEARCH-2026-11-03.md, "The cloud library").
- **Cost.** Small to medium, but every fix is to the most critical writers, and little of it carries over to a design that merges properly. Phase 0 (section 8) takes only the parts that do, or that protect today's library-in-the-cloud meanwhile.

### B. Your idea, taken literally

- **What it is.** A complete library on each device, as your local library is today, and a second complete library in the cloud folder, in the same layout. TextMouth copies each changed file across, both ways, and a book left only in the cloud has a pointer in its place locally.
- **What it gives.** W1, W3, and the local half of W5.
- **Its flaw.** The cloud library's files are still written by every device. library.json in the cloud is written by each device's copying, so the overwriting comes back one step removed. Now TextMouth's own copying decides which file is newer, by modification date, which drives move (Dropbox's re-download moved it by 9 to 118 nanoseconds, CLOUD-STORAGE-MANUAL-TESTS-2026-10-03.md, line 59) and devices' clocks disagree on.
- To be safe it would have to merge every shared file, and then it is option C in a layout that makes merging harder: packages whose files change in place, an index every device rewrites, folders renamed on two disks.

### C. Your idea as a cloud store (recommended)

- **Each device's library, on its own disk.**
  - This Mac's stays in ~/.TextMouth in today's layout, so it always opens, offline too, and an older TextMouth still reads it.
  - A book whose files left this Mac keeps its record, content.md, content index, transcript, and places. Only its own file, or its audio tracks, are gone, with a small pointer file in their place.
- **The store, a folder you choose in iCloud Drive, Google Drive, or Dropbox.** It holds three kinds of thing:
  - `store.json`: which store this is, an identifier and a date, written once and never replaced, as library-identity.json is. A store is made only in an empty folder, and a device joins one only once its store.json is there, so a store can never be given a second identity, as a library can today (risk 5). A device's own library never waits for anything in the store to arrive: a state file not here yet is simply news not yet heard.
  - `Books/<book ID>/`: each book's files, each named by its SHA-256 fingerprint, as `Books/5d3a…/9f86d081….epub`, and never changed once written.
    - A file that changes, as an EPUB whose details you edit, or audio the editor saves, becomes a new file with a new name. The old one goes only once the new one is proven.
    - A book's text, content index, transcript, and record go in the same way, so the store holds every book's full data, and the Books folder alone is enough to rebuild every book, as Rebuild Library Index rebuilds them from their packages today; the folders and the reading list come from the devices' states.
    - Plain folders and plain files, never packages, so iCloud Drive syncs each file on its own; it syncs a `.tmb` package as one item (cloud-library.md, line 7).
    - Names hold only lower-case letters, digits, dashes, and the dot before an extension, and none begins with a dot, so no drive's rules on characters or letter case apply (Dropbox's are in [38]), and every path inside the store stays short.
  - `Devices/<device ID>/`: one device's state. It holds every book that device knows, with each change stamped by a clock (section 5): places, bookmarks, the reading list, folders, sorts, views, settings, feeds, the device's own listening statistics, and what it removed. Only that device ever writes in its folder.
    - The state is a snapshot, written now and then, and small files of the changes since, a new one every few minutes while anything changes, so a reading position never uploads the whole state again. Each new snapshot takes in the change files before it, which then go. (Today's library.json goes up whole at each save, at most every five minutes while a book plays: library-index.md.)
- **Merging.** Each device reads the other devices' state files, merges them into its own library by fixed rules, writes its library on its own disk, and then writes its own state file.
  - No conflict copy can arise, because no file in the store has two writers: a book's files never change, and a state file has one writer.
- **Keeping a book on this Mac** means a copy in this Mac's own library. That works the same on the iPhone, where no app can make a drive keep a file downloaded: the iOS 26 SDK marks File Provider's keep-downloaded policy unavailable on iOS [21].
- **How it meets the wishes.** W1 yes. W2 yes, with TextMouth proving each file. W3 yes. W4 yes, by rules that lose nothing a later change didn't replace. W5 yes, through a folder you pick once in Files [15], in iCloud Drive at least (Phase 3).
- **Cost.** The largest of the four, in two halves: the store on one device (Phase 1, which is most of what saves space), and the syncing (Phase 2), which touches every writer of the library.

### D. CloudKit, or an iCloud container of TextMouth's own

- **What it is.** The index and the records in CloudKit's private database, synced with `CKSyncEngine` (macOS 14, iOS 17) [11][21]. The books as CloudKit assets, or as files in an iCloud Drive container that belongs to TextMouth [8][9][19].
- **For.**
  - Apple's servers keep track of changes and push them, so nothing polls a folder.
  - A record's save fails when the server's copy changed since (`serverRecordChanged`), so a conflict is caught one record at a time [11].
  - On the iPhone, no folder needs picking.
- **Against.**
  - It needs the paid Apple Developer Program. Apple's capability tables mark CloudKit, iCloud documents, and iCloud key-value storage for the Program, and not for the free account, on macOS and on iOS alike [10]. TextMouth is built ad hoc (project.yml, lines 162-164) and installed signed with a self-signed identity made on this Mac (Makefile, line 342), with no provisioning profile and no iCloud entitlement (TextMouth/Resources/TextMouth.entitlements).
  - It works with iCloud alone, so Google Drive and Dropbox are out.
  - The merging is still TextMouth's: the sync engine "will not handle errors that require application-specific logic", and a `serverRecordChanged` "you need to handle … yourself" (CKSyncEngine.h) [11][21].
  - A record holds at most 1 MB beside its assets [12], and everything in the private database counts against your iCloud storage [13].
- **So** D could later carry C's merge rules faster, if you join the program and choose iCloud alone. It doesn't replace them.

## 4. Pointers: why not symbolic links, and what instead

### Symbolic links

- **On this Mac alone**, a link from a book's package to its file in the drive's folder would open: TextMouth isn't sandboxed (TextMouth.entitlements), and reading through a link downloads the file. But:
  - The link holds an absolute path, which names the drive's folder. Google Drive's names your account (`GoogleDrive-<account>/My Drive`), so the link breaks when the account changes, when a drive moves its folder, as Dropbox's moved to ~/Library/CloudStorage with File Provider [33], or on another Mac under another user name.
  - TextMouth's own checks look at the link, not at the file. The dataless check uses `lstat` (CloudStorageContract.swift:521-527), so a link to an evicted file looks downloaded, and a read of it on the main thread waits on the network, which Apple warns can make an app unresponsive until the system ends it [17].
  - Copies keep the link and lose the file: a move of the data directory, a backup, an export.
- **In a drive's folder, each drive does something different:**
  - Dropbox syncs a link as a link, without the file it points to when that file is outside Dropbox, and warns that links "may not open on devices that don't have the original file or folder" [30]. Another of its pages lists symbolic links among the things it can't sync [31].
  - Google documents nothing about links you make, though Drive for desktop makes aliases and links of its own when it replaces duplicated folders with shortcuts [45].
  - Nothing on Apple's iCloud Drive support pages that the research found speaks of links at all [23][25][26].
  - File Provider can carry a link as an item with a target path (`symlinkTargetPath`) [14][21], so a drive may sync it as a link whose target means nothing on another device.
- **On the iPhone they can't work.** An app reaches a folder in another provider's storage only through the security-scoped URL the document picker returns, kept across launches as a bookmark [15][16]. Asked how to make a symbolic link to a file from the Files app, Apple's engineer answered with a security-scoped bookmark instead: "If you create a symlink to a file outside of your container, and then your app is terminated and relaunched, you lose access to that file. However, with a security-scoped bookmark you're able to get that back." [20] That is a forum answer; no documentation page speaks of links across containers.

### What instead

- **A root you granted, recognized by its identity.**
  - On the Mac: a bookmark of the store's folder, as the data directory has today (`DataDirectoryPreferences`), checked against store.json's identifier, so a folder that only has the right name is never taken for the store.
  - On the iPhone: the folder you pick in Files, kept as a bookmark, opened with `startAccessingSecurityScopedResource()` and read and written through a file coordinator, as Apple's "Providing access to directories" lays out [15][16]. On iOS a bookmark can't carry the Mac's security-scope option, which the SDK marks unavailable there [21]; the picker's URL is security-scoped itself [15].
- **A path relative to that root.** `Books/<book ID>/<fingerprint>.<extension>` is the same on every device, wherever the drive keeps its folder.
- **A content fingerprint.** The file's SHA-256 and size find it whatever its path, prove that what arrived is what left, and tell apart two different files with one name.
- **Where the pointer lives.** In the package, a small file beside the record, say `cloudCopy.json`: the store's identifier, the path, the size, the fingerprint, when the file was uploaded, and when it was last proven. It is a file of its own, not new fields in bookInfo.json, because an older TextMouth rewrites a record without the fields it doesn't know, but leaves alone a file it doesn't know (package-records.md; where-your-library-lives.md, line 63).

## 5. Syncing

### Which copy is newer

- **Never by a file's date.** Drives move it, and devices' clocks differ.
- **Never by a whole file.** What is compared is each value inside: a book's title, a position, one bookmark.
- **Each change carries a clock.** A hybrid logical clock: the device's time, raised past any later time it has seen from another device, with a counter, and the device's identifier to break ties. So a device whose clock runs slow still orders its changes after those it has seen.
- **The merge is a fixed function of every device's state.** It gives the same result in any order, and merging one state twice changes nothing. Every device that has read the same files shows the same library.

### How each kind of change merges

- **A book's details and settings** (title, author, folder, voice, rate, pitch, skip units, end-of-book choice, hand edits): each value on its own, the later clock winning.
- **A reading position:** the later one, so going back to reread a chapter on the iPhone is kept, rather than the furthest point reached. Positions already carry a date (Book.swift:1692). A place saved without moving keeps the clock it had, so opening a book never makes an old place newer, as today's reader does (risk 2), and a device merges the others' states before it opens a book.
- **Bookmarks:** each by its identifier (Book.swift:1724-1735). Additions on both devices are all kept. A label changed on both takes the later change. A bookmark deleted on one device goes everywhere, unless the other changed it later.
- **Skipped headings:** the book's list as one value, the later winning.
- **The reading list:** each book on it carries a position key, a string that sorts between its neighbours' keys, so a book added on one device and another moved on the other both survive. Taking a book off the list leaves a mark, as deleting a bookmark does.
- **Folders:** each by its identifier, with its name and parent as values. In the store a book names its folder by the folder's identifier, never by its path (risk 7). A book whose folder was deleted goes to that folder's parent.
- **Sorts and views:** each key on its own.
- **Edits of a book's text** (Edit Text, a reading in another encoding, a transcript's cleanup): the text is a file in the store like any other, the book's state names the current one, and the later clock wins. The other text is kept beside it as content.md.edited- and a date, as TextMouth keeps a replaced text today (where-your-library-lives.md, line 60), and places follow their words, as they do now.
- **Feeds:** a feed's address, title, folder, and choices, and each episode's played, deleted, and moved-to-library state, merge as values. Whether an episode is downloaded is each device's own, so one device's downloads never mark another's.
- **Statistics:** each device keeps its own counts, and the Stats tab shows their sum. Books finished are every device's records together.
- **Settings and rules:** each setting on its own; the substitution rules and the audio filter presets each as one value. Settings that belong to one machine (the data directory, the log location, windows, audio devices) never leave it.
- **Each device's own, never shared:** kept books, downloads, working copies, logs, sessions, and the crash journal, which no other device can then clear (risk 12).

### Deletions

- **A removal leaves a mark** (a tombstone): the book's identifier, the clock, and the device. A book whose mark is later than its last change is removed on every device, and its package goes to the Trash if your setting says so. Today nothing marks a removal (risk 6).
- **Marks are kept for good.** Each is about a hundred bytes, and a device away for a year still learns what was removed meanwhile.
- **A removed book's files leave the store** only after 30 days, and only once every device seen in the last 90 days has read the mark, so a removal on one device can be undone on another for a month. The drives then keep deleted files for 30 days more: iCloud Drive and Google Drive for 30 days, Dropbox for 30, 180, or 365 by plan [27][28][35][43].

### An older TextMouth

- **Phase 1 changes nothing in library.json**, and nothing in a package but two things: the book's own file is gone once you remove it from this Mac, and the pointer file is there. An older TextMouth (0.4.6 or before):
  - opens the library;
  - reads such a text book from its content.md, as it reads any book whose file is missing;
  - can't play such an audiobook, export such a book's original file, or read such a book again from its file (conversions in Export work from content.md, so they still do);
  - stamps such a book as failed for pages and doesn't try it again (LibraryViewModel+Migration.swift:1253-1254 and 1382-1385);
  - removes nothing for it, as far as reading the code shows; one test in Phase 1 checks it.
- That makes Phase 1 a minor version, 0.5.0, by your version policy: after it an older TextMouth can't do something with the library (AGENTS.md, "The version").
- **Phase 2 keeps its clocks in files of its own**, not in library.json, so an older TextMouth reads and writes the library as before. A change it makes carries no clock. The next launch of a newer TextMouth finds it by comparing the library with the last merged state this Mac kept, and stamps it then.
- **No older TextMouth knows the store**, so none writes in it.

## 6. "Safer, so we can delete the local copy"

### What proves a cloud copy

Each step must pass, in this order, before a local file goes.

1. **The fingerprint is known before anything is copied.** TextMouth reads the local file once and records its SHA-256 and size, in the pointer and in the device's state. A copy into the store on the same disk should be an APFS clone, taking no more space until one of the two changes, as the working copies are (cloud-library.md, line 30); a clone into a drive's folder is unverified (below).
2. **The drive says it has the file.** Uploaded, not uploading, no upload error, no unresolved conflict, and a download status of current. Where the drive reports no upload state, that counts as not uploaded, the opposite of today's rule (UbiquitousItemStatusProvider.swift:316). Apple promises little here (risk 10), so this step is necessary but proves nothing alone.
3. **The drive gives it back.** TextMouth removes the store copy's download (`evictUbiquitousItem` [2]), downloads it again, reads it, and compares its SHA-256 and size with the recorded ones. This is the only check that goes through the drive, and it costs one download of the book. One limit no API lifts: whether the drive served the file from its server or from a cache of its own, nothing says.
4. **Only then, the local file.** TextMouth removes it, and then removes the store copy's download too, so the space is really freed. The pointer records the date of the check.

Afterwards, a weekly check of the store reads metadata only: every pointer's file must be there, with its size. A missing one is reported at once, while the drive's 30-day trash can still give it back [27][35][43].

Why the drive's own word isn't enough:

- Google: unsynced changes "can be lost if the cache is cleared or corrupted" [41], and "If a streaming account is disconnected, any offline files are removed." [44]
- iCloud Drive keeps one current version of a file, and when two devices saved it, it chooses one and tags the others as conflicts, for an app to find [7]. The dialog in which you choose which to keep appears "When you view the document" [25], which nobody does with library.json.
- No drive documents a way for another app to ask whether the server holds this exact version.

### What you hear

- **A book's row** speaks where the book is after the New or Now Reading badge, where the cloud notes are spoken today (cloud-library.md, line 9), and shows the same words:
  - "Not backed up": on this Mac only;
  - "Backing up, 40 percent";
  - "Backed up": on this Mac, and proven in the store;
  - "In Cloud": in the store only, the word the cloud notes use today;
  - "Downloading 40%" and "Kept on this Mac", as today's notes say them;
  - "Backup failed", with the drive's reason in Book Information.
- **The commands**, in a row's context menu, its VoiceOver actions, and the Library menu: Back Up Now, Remove from This Mac (offered only for a backed-up book), Download to This Mac, Keep on This Mac, and Check Cloud Copy. For the whole store, Check Cloud Store, in Storage settings.
- **Announcements:**
  - "Moby-Dick is backed up in Google Drive, and its copy there was checked."
  - "Removed Moby-Dick from this Mac. 412 megabytes freed. Its copy in Google Drive was checked today."
  - "Moby-Dick stays on this Mac: its copy in Google Drive hasn't been checked yet. Choose Check Cloud Copy, or wait for the backup to finish."
  - "The copy of Moby-Dick that Google Drive sent back doesn't match this Mac's. Moby-Dick stays on this Mac, and TextMouth is uploading it again."
  - From the weekly check: "Emma's copy is missing from Google Drive, and Emma isn't on this Mac. Look in Google Drive's Trash, which keeps deleted files for 30 days, then choose Check Cloud Store again."
- **The summary line**, as today's counts the books in the cloud: "612 books backed up, 138 backing up, 4.2 GB can be freed."
- Every state is spoken and shown in braille; nothing is told by an icon alone.

## 7. Apple's and the drives' APIs: verified and not

How this was checked. I read the macOS 26 and iOS 26 SDK headers in this Mac's Xcode myself [21]. Two research agents read Apple's documentation and the drives' help pages; their fetch tool extracts each page through a small model, so I read the seven pages that carry most weight again myself: Dropbox's pages on links [30] and on File Provider [33], Google's advanced guide [41] and sync status page [44], Apple's page on version conflicts [25], the DTS answer on links [20], and the capability tables, whose marks I read from the pages' own markup [10].

- **Downloading and evicting** (`startDownloadingUbiquitousItem(at:)`, `evictUbiquitousItem(at:)`), macOS 10.7 and iOS 5 [1][2][21].
  - Verified: the first starts a download, or brings a local copy up to date, and returns at once; the second "removes only the local version", and Apple says not to call it inside a coordinated write [2]. Neither page names an entitlement. The October real-drive tests ran both on all three drives (docs/developer/testing.md, "Testing on real cloud drives").
  - Not verified: when a download really ends; TextMouth polls the status, as it does today.
- **The status keys** (`ubiquitousItemIsUploaded`, `IsUploading`, `UploadingError`, `DownloadingStatus`, `HasUnresolvedConflicts`, `IsExcludedFromSync`) [3][4][21].
  - Verified: their definitions, quoted in risk 10. Excluded from sync means "locally on disk but won't be available on the server" (macOS 11.3, iOS 14.5) [21].
  - Not verified: that uploaded means the server holds the version on this Mac. Apple doesn't say so.
- **The sync controls of macOS 26 and iOS 26** (`pauseSyncForUbiquitousItem`, `resumeSyncForUbiquitousItem(at:with:)`, `uploadLocalVersionOfUbiquitousItem(at:withConflictResolutionPolicy:)`, `fetchLatestRemoteVersionOfItem(at:)`) [5][21].
  - Verified: pausing stops a drive changing a file or package while an app works on it; an upload can be made to fail when the server's version is newer, and the app then fetches that version, "rebase[s] local changes on top", and tries again; pausing "fails with … featureUnsupported" for an ordinary folder [21]. On October 3, iCloud Drive reported both controls on this Mac, Google Drive and Dropbox only pausing (CLOUD-STORAGE-RESEARCH-2026-10-03.md, section 2).
  - Use: TextMouth supports macOS 14 (project.yml, line 5), so these would be used only where available. The store doesn't need them, since nothing in it has two writers; they would guard a state file if two Macs ever shared a device identifier.
- **File coordination** (`NSFileCoordinator`, `NSFilePresenter`) [6][18].
  - Verified: coordination is among "multiple processes and objects" on one device; presenters hear "Only changes that go through a file coordinator". Apple's iCloud guide asks for coordination in a container and says changes "can arrive from iCloud at any time" [18].
  - Not verified: whether a presenter hears changes that Google Drive or Dropbox make. The design doesn't rely on it: it reads the other devices' files when the library opens, when TextMouth becomes active, and every minute, as today's cloud refresh does (cloud-state.md).
- **File versions** (`NSFileVersion`) [7].
  - Verified: on iCloud, of two saves at once "one file is chosen as the current version and any other versions are tagged as being in conflict", and versions an app doesn't remove go on syncing and taking iCloud storage. Dropbox makes a "conflicted copy" file instead [32]. Google documents no rule for two computers changing one file (searched, not found [41]); a file that can't upload is copied into a Lost and Found folder on the computer [42].
- **An iCloud container of TextMouth's own** (`url(forUbiquityContainerIdentifier:)`, `NSUbiquitousContainers`) [8][9][19].
  - Verified: it needs the iCloud entitlement, and a container "can be unique to the app or shared by multiple apps" of one developer; the paid program is required [10].
- **CloudKit and its sync engine** [11][12][13][22].
  - Verified: `CKSyncEngine` on macOS 14 and iOS 17, needing "the CloudKit and remote notification capabilities"; conflicts left to the app; at most 250 records in one request; a record's data "must not exceed 1 MB" beside assets; the private database counts against the user's iCloud storage [13]; the paid program [10].
  - Not verified: any size limit on one asset.
- **Keeping files downloaded in another provider's drive** [14][21].
  - Verified, in the headers: the content policy is a property of the provider's own items; "keep downloaded" (`downloadEagerlyAndKeepDownloaded`) is macOS 13 and later only, and marked unavailable on iOS. The File Provider manager's lookups fail "on a file which doesn't reside in your provider/domain".
  - Not verified as a rule: that no other way exists. I found none, as October's research found none.
- **Links in File Provider** [14][21]: verified that an item can be a link with a target path; not verified what iCloud Drive and Google Drive do with links. Dropbox: verified [30], with a contradicting page [31].
- **The iPhone's access to a picked folder** [15][16][21]: verified, as in section 4: picker, security-scoped URL, bookmark, start and stop access, coordinated reads.
- **Dataless files** [17]: verified that reading one, even listing a folder or asking whether a file exists, can download it and freeze an app on the main thread, and that a thread can refuse downloads and get `EDEADLK` instead, which TextMouth already does (`DatalessFiles.withoutDownloading`, CloudStorageContract.swift:535-552).
- **The drives' own behavior:**
  - Keeping files: Finder's Keep Downloaded for iCloud Drive [23], whose Optimize Mac Storage otherwise keeps "only recently opened files on your Mac when space is needed" [24]; Dropbox's Make available offline, which protects a file from being made online-only "automatically" when space is low [33][34]; Google's Available offline, in stream mode only [41], while its mirror mode keeps every file on the computer [39].
  - Upload state: iCloud Drive's "Waiting to Upload" means "not yet stored in iCloud" [26]; Dropbox shows a plain cloud while uploading [36]; Google documents only a Sync status tile [44].
  - Offline and quit: Google contradicts itself, one page saying files downloaded through File Provider stay readable while Drive isn't running [40], another "If the app is closed or you've signed out, you can't access your cached files." [41]
  - Deleted files: iCloud Drive and Google Drive keep them 30 days [27][28][43]; Dropbox 30, 180, or 365 days by plan, and earlier versions as long [35]. iCloud Drive documents no version history for ordinary files.
  - The iPhone: Dropbox and Google Drive appear in Files as locations once their apps are installed [29][37], and iCloud Drive always.

## 8. The cost: a phased plan

Sizes are in this project's terms: a branch is one agent's task with its tests, and every large branch gets an outside review, a fix round, and a check of the fix, which every campaign since October has needed (AGENTS.md, "Lessons of October 24").

### Phase 0: today's design, made honest (small to medium: four or five branches, one wave)

- **Three guards for one Mac at a time,** since risks 2, 4, and 5 bite even when two Macs are used one after the other:
  - a reader that opens a book takes the newer of the row's place and the record's, and a place saved without moving keeps its date (risk 2);
  - the launch's move of older downloads into their feeds no longer takes a book that Move to Library made the library's own, whether by a note in the book's record or by running that move once per library, so no stale record can undo a Move to Library (risk 4);
  - in a cloud location, a library.json missing beside its identity file, or an identity file missing beside library.json where this Mac expects one, is waited for, as a file only in the cloud is, and then put to you as a choice, never taken as a fresh start or a new identity; and a reading_stats.json not there yet is stood in for without being written over, as substitutions.json already is (risk 5).
- **Compare Libraries…**, read-only. Given two folders holding the same library, by identity, it lists what differs: books in one only, the newer of each position, bookmarks in one only, the reading list and folders, and which copy holds the newer of each. It changes nothing. It answers what your Google Drive copy has that ~/.TextMouth lacks, and its comparison is the first piece of Phase 2's merge.
- **Use This Library says which copy is newer**, from the same comparison, in place of "may not have its latest changes".
- **Conflicts reported.** A conflict copy of library.json, a feed's record, or a book's record, and iCloud's conflicting versions, are reported once, saying what each holds, instead of being left unseen.
- **Remove Download** asks for not uploading and current too, and treats an unknown upload state as not uploaded.
- **Tests:** fixtures of two copies of a small library and of each drive's conflict copies; a stale row opened over a newer record; a stale feed record after Move to Library; a library folder holding the identity file without its index, and the reverse. No real drive needed.
- **Alone it gives:** your two copies compared, and today's cloud mode safer for one Mac at a time, telling you when it is about to lose something.

### Phase 1: the store, for this Mac (large: about the size of the October cloud work's first wave, five to seven branches over two waves)

- **The store:** choosing its folder in Storage settings, store.json, the bookmark and identity check, and a state for a store that can't be reached, in which the library still opens and only the store's work waits.
- **Fingerprints:** each book's files read once in the background, never on the main thread, for SHA-256 and size.
- **Backing up:** each book's files copied into the store as clones, one book at a time, in the background, with each book's state, Back Up Now, and the drive's reasons for a failure (out of space, offline, paused). This Mac's state file is written to the store as a plain snapshot, without clocks yet, so the store holds every book's full data.
- **The check and the removal:** the read-back of section 6, Remove from This Mac, Download to This Mac, and opening a book whose file is only in the store (the reader's download view, reused).
- **What is kept carries over:** Keep on This Mac (`KeptBooks`, this Mac's own Kept Books.json) and the reading list's books, which the `rlkeep` work being built today keeps in a cloud library by working them out from the list, come to mean "never removed from this Mac", with no change to how they are chosen.
- **The weekly check**, and **Rebuild Library from Store**, which makes a library from the store alone, as Rebuild Library Index makes one from the packages today.
- **Wording** for every row, command, and announcement, in a wording enum as the code around it does.
- **Alone it gives:** the space you choose to free, every removed file proven in the cloud first, a library that always opens, and a full copy of your library in the cloud.

### Phase 2: syncing between devices (the largest: about twice Phase 1, and the riskiest)

- **Clocks:** every writer of the library stamps its change: the reader's positions and bookmarks, the library's edits, the reading list, folders, feeds, settings, statistics.
- **The merge:** one pure function over states, with section 5's rules, as `PlaceRelocator` is pure today (package-records.md).
- **Marks and clean-up:** tombstones, and the store's clean-up of removed books' files.
- **Another Mac:** Use This Store builds a library on that Mac from the store: records, text, and indexes come down at once, books' files when opened or kept.
- **Changes nothing stamped:** those an older TextMouth or a hand edit made, found by comparison with the last merged state and stamped then.
- **Your diverged copy:** the Google Drive copy merged as another device's state without clocks: positions by their dates, bookmarks by identifier, and the rest listed for you to choose.
- **Alone it gives:** your places, bookmarks, reading list, and books on every device, with nothing overwritten.

### Phase 3: the iPhone (large: about Phase 1 again, on the phone)

- The store picked in Files, kept as a bookmark, read and written through a file coordinator [15][6], with the same merge, which is shared code.
- The phone must write its own state file into the store. Apple's page gives an app a picked folder's URL and a file coordinator to work in it [15], but not what each provider accepts. Neither Google's nor Dropbox's pages say whether another app's writes into their folders reach the cloud, and a Dropbox page seen only in search results suggests that changes made in other apps may not save back. So a spike on each drive comes first, and the phone may need iCloud Drive, Apple's own.
- Books downloaded when opened, and kept by copying them into the phone's own library.
- The phone's copies of books left out of its iCloud backup, since the store holds them, which answers question 6 of humanQuestions/2026-11-07.md.

### Phase 4, optional: CloudKit

- Only with the paid program, and iCloud alone. It would carry the state files' contents as CloudKit records, the merge rules staying as they are.

### The tests, in every phase

- **A stand-in drive.** A fake sync service over sandbox folders, growing from today's `FakeCloudItemStatusProvider` (TextMouthProductionTests/CloudTestDoubles.swift:21): uploads that take time or fail (out of space, offline, paused), evictions, downloads that stall, fail, or come back different, conflict copies under each drive's names (iCloud's "name 2", Google's "name (1)", Dropbox's "conflicted copy"), and files deleted from "the server".
- **Two simulated devices.** Two libraries with two device identifiers in two sandbox folders, and a test service that carries files between their views of the store, in any order, at any moment the test chooses.
- **Interrupted syncs.** A stop after every step of a backup, a check, a removal, and a merge, then a fresh launch, each time checking that every book's file has at least one proven copy, the library opens, and no row is lost.
- **The merge's properties.** Random changes on two or three devices, merged in random orders, must give one library, in which every change survives unless a later one replaced it.
- **Real drives, opt-in.** The October tests (`CloudDriveIntegrationTests`) extended with the read-back on each drive, in a throwaway folder, with your yes, as before.
- **Older versions.** A library with removed files read by the paths an older TextMouth takes, as V03's tests read a later version's rows (library-index.md).

### Moving your library

- **Nothing moves in place.** Your library stays in ~/.TextMouth as it is. The store starts empty in the folder you choose, books are copied into it one at a time, and a local file goes only when you choose Remove from This Mac for a book whose copy was proven.
- **Before the first run on your library:** a backup, by Time Machine or a copy on another disk, and a rehearsal on a copy of the library, with your yes, as the October rehearsal plan had it (humanQuestions/2026-10-23.md).
- **Disk.** Copies into the store are clones on the same disk, so backing up 11 GB should take no more room on this Mac, which has about 14 GB free; measured before anything else in Phase 1.
- **The cloud plan.** It must have room for what you back up. TextMouth can't read a plan's free space (CLOUD-STORAGE-RESEARCH-2026-10-03.md, section 4), so it reports the drive's own error, such as iCloud Drive's Out of Space [26].
- **Your Google Drive copy** stays as it is until Phase 0's comparison has said what it holds.

## 9. Recommendation

- **Build C, in its phases, and stop after any phase that gives you enough.**
- **Start with Phase 0, then Phase 1.** Phase 1 is most of what you asked for: space freed safely, a full and proven copy in the cloud, and a library that always opens.
- **Leave Phase 2 until a second device is really in use:** the iPhone app on your phone, or a second Mac. It is the largest and riskiest step, and pays off only then.
- **Don't build B as written, and put no more into A than Phase 0.** A's merges would be guesses, and its index can still be in the cloud when you're offline.
- **Keep today's library-in-the-cloud for one Mac at a time,** saying so plainly, until the store has replaced it; then decide whether to retire it.
- **Leave CloudKit** unless you join the paid program and choose iCloud alone.
- **No symbolic links,** on either device.

## 10. Questions for you

Each has the answer I recommend. They are also the questions a first brief would build from.

1. **Which drive holds the store first?** All three passed the October tests. Apple documents iCloud Drive's upload states best, and the iPhone reaches it with no other app, while whether the iPhone can write into Google Drive or Dropbox from another app is undocumented (Phase 3). Your earlier copy is in Google Drive, whose help pages say least.
   Recommended: iCloud Drive if your iCloud plan has room for about 11 GB of books, and Google Drive otherwise.
2. **Back up every book, or only the books you remove from this Mac?**
   Recommended: every book, text books first. It makes the store the full copy your idea asks for, and copies on this disk cost no room here.
3. **How is a cloud copy proven?**
   Recommended: the read-back of section 6 for every book, before its local copy goes, in the background. It costs one download of each book.
4. **Does Remove from This Mac free the space at once, or move the file to the Trash?**
   Recommended: at once. The copy was read back and checked, the drive keeps deleted files for 30 days more, and the Trash would free nothing.
5. **What stays on this Mac without asking?**
   Recommended: the books on the reading list (as the `rlkeep` work does for a cloud library today), the books kept on this Mac, and those opened in the last 30 days. Nothing is removed automatically in the first version: every removal is your command.
6. **Text books' originals first?** A text book reads from its content.md, so its EPUB or PDF is needed only to read it again.
   Recommended: yes. A command that removes the proven originals of text books frees space without changing anything you hear.
7. **Your Google Drive copy, `TextMouthLibrary`.**
   Recommended: compare it read-only first (Phase 0), then decide; nothing changes it meanwhile. (Question 4 of humanQuestions/2026-11-06.md, which asked to look at its files' sync flags, is still open.)
8. **Today's library-in-the-cloud.**
   Recommended: keep it for one Mac at a time, with a plainer warning, and decide about retiring it once the store works.
9. **When does syncing between devices (Phase 2) start?**
   Recommended: after Phase 1 is in daily use, and once the iPhone app or a second Mac is in use.
10. **The iPhone's library.** Question 3 of humanQuestions/2026-11-03.md asked whether the phone has a library of its own; the store gives a third answer: its own library, filled from the store.
    Recommended: that, in Phase 3.
11. **The paid Apple Developer Program.**
    Recommended: not for this. Nothing in the recommended design needs it.
12. **The version.** Phase 1 makes 0.5.0, since an older TextMouth can't play an audiobook whose files left this Mac.
    Recommended: yes, updating every Mac that opens the library first.

## What I could not verify

- Whether a clone into a drive's folder stays a clone, taking no more room: the first measurement of Phase 1.
- Whether the read-back after an eviction reaches each drive's server, or a cache of the drive's own.
- What iCloud Drive and Google Drive do with symbolic links.
- What an older TextMouth does with a package whose own file is missing, beyond reading the code: a test in Phase 1. Older builds' code isn't in this tree, so risk 11 rests on today's code and the architecture pages.
- How each drive settles two whole-file writes of one file, which one it keeps current, and how long it can show one of a library's files without another: the real reach of risks 3 and 5.
- Whether a file presenter hears the changes Google Drive and Dropbox make.
- Whether an iPhone app's writes into a Google Drive or Dropbox folder picked in Files reach the cloud.
- CloudKit's size limit for one asset.
- Any version history for ordinary files in iCloud Drive, and Google's rule for two computers changing one file: neither documented.
- How Time Machine treats files a drive has evicted: not researched.
- The research agents' quotes come through their fetch tool's extraction; seven pages were read again by me (section 7).
- Reading code is not running it: each risk in section 2 cites its lines, and those without a test say so.

## Sources

Apple's developer documentation and SDK:

1. `FileManager.startDownloadingUbiquitousItem(at:)`: https://developer.apple.com/documentation/foundation/filemanager/startdownloadingubiquitousitem(at:)
2. `FileManager.evictUbiquitousItem(at:)`: https://developer.apple.com/documentation/foundation/filemanager/evictubiquitousitem(at:)
3. `URLResourceKey.ubiquitousItemIsUploadedKey` and the other ubiquitous item keys: https://developer.apple.com/documentation/foundation/urlresourcekey/ubiquitousitemisuploadedkey
4. `URLUbiquitousItemDownloadingStatus`: https://developer.apple.com/documentation/foundation/urlubiquitousitemdownloadingstatus
5. The sync controls: https://developer.apple.com/documentation/foundation/filemanager/pausesyncforubiquitousitem(at:completionhandler:) , https://developer.apple.com/documentation/foundation/filemanager/uploadlocalversionofubiquitousitem(at:withconflictresolutionpolicy:completionhandler:) , https://developer.apple.com/documentation/foundation/filemanager/fetchlatestremoteversionofitem(at:completionhandler:)
6. `NSFileCoordinator` and `NSFilePresenter`: https://developer.apple.com/documentation/foundation/nsfilecoordinator and https://developer.apple.com/documentation/foundation/nsfilepresenter
7. `NSFileVersion`: https://developer.apple.com/documentation/foundation/nsfileversion
8. `FileManager.url(forUbiquityContainerIdentifier:)`: https://developer.apple.com/documentation/foundation/filemanager/url(forubiquitycontaineridentifier:)
9. Configuring iCloud services: https://developer.apple.com/documentation/xcode/configuring-icloud-services
10. Supported capabilities, macOS and iOS: https://developer.apple.com/help/account/reference/supported-capabilities-macos and https://developer.apple.com/help/account/reference/supported-capabilities-ios
11. `CKSyncEngine`: https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5
12. `CKRecord` and `CKAsset`: https://developer.apple.com/documentation/cloudkit/ckrecord and https://developer.apple.com/documentation/cloudkit/ckasset
13. TN2241 (archived), the private database and iCloud storage: https://developer.apple.com/library/archive/technotes/tn2241/_index.html
14. File Provider: https://developer.apple.com/documentation/fileprovider/nsfileprovidercontentpolicy , https://developer.apple.com/documentation/fileprovider/nsfileprovideritemprotocol/symlinktargetpath , https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/evictitem(identifier:completionhandler:)
15. Providing access to directories: https://developer.apple.com/documentation/uikit/providing-access-to-directories
16. `startAccessingSecurityScopedResource()` and `bookmarkData(options:includingResourceValuesForKeys:relativeTo:)`: https://developer.apple.com/documentation/foundation/nsurl/startaccessingsecurityscopedresource() and https://developer.apple.com/documentation/foundation/url/bookmarkdata(options:includingresourcevaluesforkeys:relativeto:)
17. TN3150, Getting ready for dataless files: https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files
18. Designing for Documents in iCloud (archived): https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html
19. Information Property List keys (archived), `NSUbiquitousContainers`: https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CocoaKeys.html
20. Apple Developer Forums, a DTS engineer on links and the sandbox: https://developer.apple.com/forums/thread/672838
21. The macOS 26 and iOS 26 SDKs in this Mac's Xcode, read directly: Foundation's NSFileManager.h, NSURL.h, and NSFileCoordinator.h; FileProvider's NSFileProviderItem.h, NSFileProviderManager.h, and NSFileProviderDefines.h; CloudKit's CKSyncEngine.h, CKRecord.h, and CKAsset.h.
22. Deciding whether CloudKit is right for your app: https://developer.apple.com/documentation/cloudkit/deciding-whether-cloudkit-is-right-for-your-app

Apple Support:

23. Work with folders and files in iCloud Drive on Mac (Keep Downloaded): https://support.apple.com/guide/mac-help/mchl1a02d711/mac
24. Optimize storage space on your Mac: https://support.apple.com/guide/mac-help/sysp4ee93ca4/mac
25. Resolve document version conflicts in iCloud Drive: https://support.apple.com/guide/mac-help/mh40780/mac
26. Check the status of iCloud Drive files and folders: https://support.apple.com/guide/mac-help/mchlc994344b/mac
27. Recover deleted files on iCloud.com: https://support.apple.com/guide/icloud/recover-deleted-files-mmae56ea1ca5/icloud
28. Recently Deleted on iPhone and iPad: https://support.apple.com/en-us/104953
29. Other services in the Files app: https://support.apple.com/en-us/102238

Dropbox:

30. Symlinks: https://help.dropbox.com/sync/symlinks
31. Files that won't sync: https://help.dropbox.com/sync/files-not-syncing
32. Conflicted copies: https://help.dropbox.com/organize/conflicted-copy
33. Dropbox for macOS on File Provider: https://help.dropbox.com/installs/macos-support-for-expected-changes
34. Make files available offline: https://help.dropbox.com/sync/access-files-offline
35. Deleted files and version history: https://help.dropbox.com/delete-restore/deleted-files and https://help.dropbox.com/delete-restore/version-history-overview
36. Sync icons on macOS: https://help.dropbox.com/sync/macos-sync-icons
37. Dropbox in the Files app on iPhone: https://help.dropbox.com/integrations/ios-files-app
38. File names: https://help.dropbox.com/organize/file-names

Google:

39. Stream and mirror files: https://support.google.com/drive/answer/13401938
40. Use Drive for desktop on macOS: https://support.google.com/drive/answer/12178485
41. Manage Drive for desktop, advanced guide: https://support.google.com/drive/answer/16631477
42. Fix problems in Drive for desktop (Lost and Found): https://support.google.com/drive/answer/2565956
43. Trash and versions: https://support.google.com/drive/answer/2375102 and https://support.google.com/drive/answer/2409045
44. Sync status and disconnecting an account: https://support.google.com/drive/answer/10838124
45. Shortcuts in place of duplicated folders: https://support.google.com/drive/answer/10864219

In the repository: CLOUD-STORAGE-RESEARCH-2026-10-03.md, CLOUD-STORAGE-PLAN-2026-10-03.md, CLOUD-STORAGE-MANUAL-TESTS-2026-10-03.md, IOS-PORT-RESEARCH-2026-11-03.md, TODO-2026-09-04.md, docs/user/cloud-library.md, docs/user/where-your-library-lives.md, docs/architecture/platforms.md, the pages of docs/architecture/state/ named above, and humanQuestions/2026-11-03.md, 2026-11-06.md, 2026-11-07.md, and 2026-11-13.md.

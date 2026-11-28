# The data directory
<!-- id: data-directory; keys: library folder, storage location, move library, cloud library, Storage settings; src:  -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## Its location, and moving it
<!-- id: location-moving-it; keys: Move Library Here, Reset to Default, Change Location, library folder, relocate; src: TextMouth/Services/StorageGeneration.swift, TextMouth/Services/TextMouthPaths.swift, TextMouth/Services/DataDirectoryMigrator.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift -->

Its location, and moving it.

### Owner of the data directory's location
<!-- id: owner-data-directory-location; keys: library root, generation, default location, current location; src: TextMouth/Services/StorageGeneration.swift, TextMouth/Services/TextMouthPaths.swift -->

- Owner: StorageBoundary.shared, which holds the current StorageGeneration, the data directory's root numbered by the moves this process has published, and the earlier ones.
  TextMouthPaths.root is the current generation's root: at launch the folder TextMouthPaths.root(for:) names (~/.TextMouth, or the folder the textMouthDataDirectory preference names, which a test host ignores), and after a move the new location.
  It changes only when a move publishes its copy, never because the preference changed.

### Who may write the location
<!-- id: who-may-write-location; keys: config.json, move refused, open books, cloud-only files, Move Library Here; src: TextMouth/Services/TextMouthPaths.swift, TextMouth/Services/LibraryPersistenceService.swift, TextMouth/Services/MaintenanceFileAccess.swift, TextMouth/Services/ConfigService.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift, TextMouth/ViewModels/LibraryViewModel.swift -->

- Who may write it: a published move, and a check whose bookmark finds the library under another path (its availability, below).
  TextMouthPaths.moveDataDirectory(to:library:) changes the preference, the current generation, and the library only once the copy is published, and publishes the generation between the persistence queues' writes (LibraryPersistenceService.betweenWrites).
  So no write resolves its file under the old root and writes it afterwards.
  Change Location's Move Library Here and Reset to Default in Storage settings, and a changed dataDirectoryPath in config.json, reach the move in LibraryViewModel+Migration, which refuses:
  - while the index cannot be read or the data directory is unavailable,
  - while any book is open (openBooksRefusal, naming the books),
  - and while any book inside the data directory has files only in the cloud, which copying would download (countBooksOnlyInCloud, through MaintenanceFileAccess.itemInCloud).

### Choosing a folder
<!-- id: choosing-folder; keys: folder picker, NSOpenPanel, destination check, hidden folders, confirmation wording; src: TextMouth/Services/StorageDestinationAssessment.swift, TextMouth/Views/Settings/StorageSettingsView.swift -->

- Choosing: a folder chosen in Storage settings (StorageSettingsView.makeLibraryFolderPanel, a chooser that shows hidden folders and can make one) is judged off the main thread, from metadata alone, by StorageDestinationAssessment.
  It answers a move for a missing or empty folder, Use This Library for one holding a library (an identity marker, or library.json beside a Library folder), the library in use, a new library in the default location while the library is unavailable, or a refusal with its reason.
  StorageChoice and StorageWording word the confirmation or the status line.

### Holding storage work
<!-- id: holding-storage-work; keys: storage hold, StorageBusyError, Try again, Rebuild Directory, import blocked, feed items set aside; src: TextMouth/Services/StorageGeneration.swift, TextMouth/Services/StorageDestinationAssessment.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift, TextMouth/ViewModels/LibraryViewModel+BookOperations.swift, TextMouth/Models/Library.swift, TextMouth/Services/ReadingStatsService.swift, TextMouth/Services/TextSubstitutionService.swift -->

- Holding: withStorageWorkHeld(moving:waiting:_:) holds new storage work back (StorageBoundary.holdWork(for:)).
  It waits for the import, text extraction, and book analysis under way (StorageWorkHold.waitForWorkUnderWay), flushes the queued saves and logs, runs the move, and then lets the held work go on under the new generation.
  Work that captured paths before the publication moves them under the new root first (rebasedToCurrent and rebaseToCurrent), so nothing is written under the old one.
  Rebuild Directory holds storage work the same way, with no move, while it relocates and adopts packages, so an import that has published its package but not yet added its book finishes first and is never adopted as an orphan too; Storage settings show what the rebuild waits for.
  It reconciles the library's own books with the Library folder, a feed's items waiting aside meanwhile (Library.withFeedItemsSetAside(_:), FR11).
  So do the folder edits made from the library's sheets (performLibraryTransition: moving books to a folder, and moving, renaming, or deleting a folder while keeping its contents).
  They then move their packages and rewrite their records off the main actor (OffMainWork.runThrowing), VoiceOver hearing what they wait for.
  Each hold says what it is for (StorageHoldReason: moving the data directory, rebuilding it, or moving books between folders), and only one is in place at a time.
  While one is, holdWork(for:) refuses another with a StorageBusyError naming the operation under way, so a refused move, rebuild, or folder edit says what is actually running, as in "TextMouth is moving books between folders.
  Try again when that finishes.
- Saves made meanwhile: the substitution rules, the statistics, and the filter presets (audio-filters.json) are written from outside the storage work, so a save of either during the copy would land in the folder being copied, which the copy may have passed.
  From the end of the move's flushes (StorageBoundary.beginProvisionalSaves()) until the hold is released, such a save is provisional (isProvisionalSave(of:rewrite:)): it is written, but settles no earlier failure, and its rewrite is kept, one for each file's name in the data directory.
  The filter presets' file is looked up at each save, so a pane left open through the move writes the library in use, and its rewrite keeps the bytes, not the pane.
  A save made while the move only waits for other work is final, since the copy takes it, and so is one made during Rebuild Directory or a folder edit, which write in the same directory.
  After the release, however the move ended, rewriteFilesSavedDuringTheMove() saves each such file again once, in the library then in use, and the move waits for the statistics' queue (waitForQueuedStatisticsSaves) when any was saved, so the outcome is judged after the write that settles a failure.

### Copying and publishing
<!-- id: copying-publishing; keys: migration, staging folder, copy library, cancel move, rename into place, rmdir; src: TextMouth/Services/DataDirectoryMigrator.swift, TextMouth/Services/StorageDestinationAssessment.swift, TextMouth/Services/TextMouthPaths.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift -->

- Copying: copyAndPublish runs TextMouthPaths.moveDataDirectory on a background queue (OffMainWork) with the task-local DataDirectoryMigrator.copyObserver bound, which hears each DataDirectoryCopyProgress and answers Cancel.
  DataDirectoryMigrator takes each location as the real folder its links lead to (DataDirectoryLocation): a data directory that is a link is copied from its folder, and a new location that is a link to an empty folder receives the data in that folder, the link staying as it is.
  Before copying, it refuses overlapping real folders, naming both, a link that leads nowhere, a file at the new location, and a folder that is not empty.
  It copies into a hidden staging folder (.TextMouth-migration- followed by a UUID) beside the new location's real folder, one item at a time in the order DataDirectoryCopyPlan gives.
  It copies each package whole, which clones it on one APFS volume, the books first and the small files at the top last, and gives each folder it makes its original's metadata with copyfile.
  Cancel stops the copy between items, or after the last, with DataDirectoryMigrationError.cancelled, and the staged copy is deleted.
  The migrator points the copy's package records, each feed's index (stageFeedIndexes, a feed item's package staged in its feed's folder of the copy, FR11), and library.json at the new location and checks them, then looks again.
  The name must still lead to the same folder, and that folder must still be empty or missing.
  It removes nothing but an empty folder, with rmdir, which the kernel refuses once anything is inside, and publishes the copy with one rename (moveItem, which never replaces an item).
  Anything that arrives meanwhile stops the move: the staged copy is deleted, whatever arrived stays, and the data directory in use and its setting stay as they were.
  The library is taken once the wait is over, and nothing should change it during the copy; a change made anyway is kept, its paths rebased.
  A save's temporary file is no item of the copy (SaveTemporaryNames, in DataDirectoryCopyPlan), since a save made during the copy can rename it away before it is reached, which would stop the move.
  Three forms are left out, each by its exact shape, and a folder is never left out, whatever its name, since a library folder may begin with a dot:
  - Foundation's atomic write's, ".dat.nosync", the writing process's number in hexadecimal, a dot, and six letters or digits (macOS 26.3.1);
  - the other form it makes, the target's name, ".sb-", eight hexadecimal digits, a dash, and six letters or digits (the hosted runner's macOS);
  - and TextMouth's own, ".<target>.<UUID>", in upper case, for the targets named in stagedTargets only (transcript-cleanup.json), which TranscriptCleanupRuleFile stages through stagedName(for:).
  A stale one a crash left stays in the old library, uncopied, and a real file that vanishes during the copy still stops the move, naming it.
  The copy order is no guarantee that a target is copied after its rename (".sb-" sorts after its target); a target copied before a save ended is stale as a save made after its copy is, and the rewrites after the move cover the writers outside the storage work.
  DataDirectoryCopyTests holds a canary that writes 16 MB atomically in its sandbox, lists the folder meanwhile, and fails on a hidden name this does not know, so a macOS whose names differ shows itself.

### Leftovers of a move
<!-- id: leftovers-move; keys: stale staging folder, journal, orphaned copy, launch sweep; src: TextMouth/Services/MigrationStagingLeftovers.swift, TextMouth/Services/DataDirectoryMigrator.swift, TextMouth/Models/CloudStorageContract.swift, TextMouth/Platform/macOS/App/AppDelegate.swift -->

- Leftovers: the hidden staging folder of a move, when the move could not remove it.
  DataDirectoryMigrator.prepareMigration notes the folder in MigrationStagingLeftovers (note) before anything is created, and defers discard(_:fileManager:), which removes the folder however the move ends and forgets the note once it has.
  A removal that fails leaves the note, and logs MIGRATION_STAGING_LEFT only if the folder can still be seen, since a folder on an unplugged volume can be neither seen nor removed and "not there" cannot be told from "gone".
  A published copy is forgotten (forget), since the rename left nothing to remove.
  The journal is Move Leftovers.json at MachineLocalPaths.moveLeftovers, this Mac's own and never in the data directory, which the folders' volume may not be.
  It is a list of Entry values, a folder's path and the date it was noted, the newest journalLimit (20) kept, written atomically and removed when no entry is left, read and written under a lock that also holds the folders this process is using.
  AppDelegate.applicationDidFinishLaunching calls MigrationStagingLeftovers.sweepInBackground(), once on a utility queue and never in a hosted test. sweep(fileManager:now:) takes the entries in order:
  - it drops one whose last component is not exactly stagingNamePrefix and a UUID (isStagingName), so a hand-edited journal can never make it delete another folder;
  - leaves one this process is using;
  - keeps one whose path cannot be seen until it is unseenLifetime (30 days) old, then drops it;
  - drops one that is not a real directory (a file, or a link, which attributesOfItem does not follow);
  - and otherwise removes the folder and logs MIGRATION_STAGING_REMOVED, or keeps the entry and logs MIGRATION_STAGING_LEFT when the removal fails.

### Use This Library
<!-- id: use-this-library; keys: switch library, Choose Another Library, relaunch, open existing library; src: TextMouth/ViewModels/LibraryViewModel+Migration.swift, TextMouth/Services/StorageGeneration.swift, TextMouth/Services/TextMouthPaths.swift -->

- Use This Library (useLibraryReturningOutcome(at:relaunching:)) moves nothing but holds the storage work itself (StorageHoldReason.switchingLibraries, "TextMouth is switching to another library and opening again on it.").
  So a move, a rebuild, or a folder edit under way refuses it with the StorageBusyError naming that operation, and nothing starts one while the switch runs.
  It writes pending saves, refuses while changes can't be saved unless the library is unavailable, records the folder for the next launch with TextMouthPaths.setCustomRoot (nil for the default location), and has TextMouthRelauncher open a new instance of TextMouth and quit this one.
  A process hosting tests never opens again.
  Before the confirmation, Storage settings runs the comparison of Compare Libraries for at most 60 seconds, which Stop Comparing (a cancel flag) ends, and the confirmation says which copy is newer (StorageWording.copyOfCurrentLibrarySentence(_:), LibraryComparisonWording.newerCopySentence).

### How a move is observed
<!-- id: how-move-observed; keys: progress sheet, move progress, Move cancelled, quit during move, status line; src: TextMouth/ViewModels/DataDirectoryMoveProgress.swift, TextMouth/Views/Library/DataDirectoryMoveSheet.swift, TextMouth/Views/Settings/StorageSettingsView.swift, TextMouth/Platform/macOS/App/AppDelegate.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/Services/StorageGeneration.swift, TextMouth/Services/InterfaceTextOverrides.swift -->

- How others observe it: LibraryViewModel.dataDirectoryMove, a DataDirectoryMoveProgress, is set while a move runs.
  Every Library window shows DataDirectoryMoveSheet and refuses to open or add books.
  Storage settings show DataDirectoryMoveProgressView.
  VoiceOver hears what the move waits for, its start, each quarter, and Cancel.
  Once a move or a switch of library makes another folder the data directory, StorageBoundary.publish(root:) posts .dataDirectoryDidMove on the main queue, with the new root's path in its userInfo, outside the write fence of the persistence queues.
  What reads a file there by its path reads it again at the new place: InterfaceTextOverrides moves its watcher to interface_text.json there and reads it.
  And AppDelegate calls DataDirectoryMoveProgress.stopForQuit before quitting. config.json's dataDirectoryPath names the folder in use after every attempt.
  The Storage settings status line, which VoiceOver announces once, or else the library's alert, says "Done.
  Data is now at…", naming the folder a link leads to, "Move cancelled.
  The library is still at…", or why nothing moved, naming what arrived and where.
  The old folder is left where it was.

## Whether the data directory is available
<!-- id: whether-data-directory-available; keys: Library Not Available, Try Again, unmounted volume, cloud sync, iCloud, bookmark, Use Default Location; src: TextMouth/Services/DataDirectoryAvailability.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/ViewModels/LibraryViewModel+IndexRecovery.swift, TextMouth/ViewModels/LibraryViewModel+LibraryFetch.swift, TextMouth/ViewModels/LibraryViewModel+LaunchFiles.swift, TextMouth/Services/LibraryPersistenceService.swift, TextMouth/Services/LibraryFileFetch.swift, TextMouth/Services/BookCloudStorageService.swift, TextMouth/Services/TextMouthPaths.swift, TextMouth/Services/ConfigService.swift, TextMouth/Services/ReadingStatsService.swift, TextMouth/Services/TextSubstitutionService.swift, TextMouth/Services/Feeds/FeedStore.swift, TextMouth/Models/CloudStorageContract.swift, TextMouth/Views/Library/DataDirectoryUnavailableView.swift, TextMouth/Views/Settings/StorageSettingsView.swift, TextMouth/Views/ContentView.swift, TextMouth/Services/InterfaceTextOverrides.swift -->

Its availability: whether the data directory can be used.

- Owner: LibraryViewModel.dataDirectoryUnavailability, the reason it can't (DataDirectoryUnavailability), nil while it can, and DataDirectoryGate, the data directories found unavailable, kept by path, which every writer of the data directory consults.
- Who may write it: only the library model's data-directory functions, in LibraryViewModel.swift.
  checkDataDirectory runs DataDirectoryCheck, which reads metadata only, inside DatalessFiles.withoutDownloading:
  - at launch, before anything is created or loaded;
  - on Try Again (retryDataDirectory);
  - when the volume holding the data directory is unmounted (volumeDidUnmount, from the workspace's notifications);
  - and when a write found a custom data directory's folder missing (dataDirectoryWriteFoundFolderMissing, which LibraryPersistenceService posts through DataDirectoryEvents).

  The default location is always available, and created when missing.
  A custom one must be a readable folder holding this library: an identity marker naming the identity this Mac expects or, for a library given none yet, a library index.
  When its path is missing, its bookmark may find the library under another path, never in a Trash, which then becomes the data directory.
  The library index, the identity marker, the Feeds folder, and each feed's folder and index (DataDirectoryCheck.assessLibrary(in:itemStatus:), through feedIndexFiles(in:), FR11), when only in the cloud, are asked of the sync service.
  And the library stays unavailable (notDownloaded, whose explanation names the library index whichever it was) until a later check finds them on this Mac.
- The fetch from the cloud: when the check, through runNamingPending, names files only in the cloud, LibraryViewModel+LibraryFetch reads them off the main thread with downloads allowed (LibraryFileFetcher, to each file's end, at most eight at once, a folder listed one level).
  It then checks again, up to six passes.
  Meanwhile the reason is .gettingFromCloud, and .cloudFetchFailed when a pass makes no progress after retries at 5, 15, and 30 seconds, or a read gives no answer for BookCloudStorageService.defaultStallLimit (60 s).
  A stuck path stays in libraryFilesBeingRead, so Try Again never reads it twice, and its late return checks again and opens the library, unless another library was chosen.
  LibraryViewModel+LaunchFiles does the same for config.json, reading_stats.json, substitutions.json, interface_text.json, and the feed records once a cloud library opens, without holding it back.
  It also tells the service that owns each (ConfigService.fileMayHaveArrived, ReadingStatsService.fileMayHaveArrived, the substitutions' re-read, InterfaceTextOverrides.fileMayHaveArrived, FeedStore.loadRecordsInCloud).
  Reads go through the library's own files only, never a book or an episode.
- How others observe it: every Library window:
  - shows DataDirectoryUnavailableView in place of the library, with the reason and, read right after it, where to choose another folder (DataDirectoryUnavailableText.anotherFolderPointer, which names Storage settings' two buttons by their titles in StorageLocationWording, so it follows any rename),
  - says so in its title,
  - and refuses the app-wide actions that add or open books (DataDirectoryUnavailableText.refusal(of:)).

  Storage settings show the reason and offer Choose Another Library and Use Default Location.
  Their status line asks whether the data directory exists off the main thread, as the pane appears, after each data-directory operation, and when its path or availability changes (StorageSettingsView.directoryCheck), never while drawing, since a network or unplugged volume can block there.
  Meanwhile TextMouthPaths.ensureDirectoryStructure throws DataDirectoryUnavailableError, and it never creates a custom data directory or any folder above it.
  Library index writes are skipped, not counted as failures.
  Record writes that fail stay listed for a retry.
  ConfigService neither reads, writes, nor watches config.json.
  The log writer writes to ~/Library/Logs/TextMouth instead (see [The diagnostic logs](logs.md)).
  And ReadingStatsService and TextSubstitutionService use stand-ins that they never save over their files, as they do while a file is only in the cloud (files several Macs write, below).
  A check that finds the library again posts dataDirectoryDidBecomeAvailable, and those services read their files.
  After a loss while TextMouth ran, reloadLibraryAfterDataDirectoryReturned reads library.json afresh, carrying the session's newer reading positions and moved packages into it.

### A library's two small files in the cloud
<!-- id: library-two-small-files-cloud; keys: library.json, library-identity.json, awaitedFile, LibraryFileAwaited, identityNotKnown, Open Without the Index, Restore Its Identity, Give It a New Identity; src: TextMouth/Services/DataDirectoryAvailability.swift, TextMouth/ViewModels/LibraryViewModel+LibraryFetch.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/Models/LibraryFileWaitWording.swift, TextMouth/Views/Library/DataDirectoryUnavailableView.swift, TextMouth/Services/LibraryIdentity.swift, TextMouthProductionTests/MultiMacCrashSafetyTests.swift, TextMouthProductionTests/LibraryCloudFetchTests.swift -->

A sync service can bring a cloud library's small files down one at a time, so a folder may hold library.json without library-identity.json, or the reverse, for a while.
Only in a cloud location (`itemStatus.location(of:).isCloud`) the check waits for the missing one as a file that is only in the cloud, whether or not this Mac expects an identity: a Mac given the folder knows none yet, and would otherwise give the library a second one.
`DataDirectoryCheck.awaitedFile(among:in:expectingIdentity:)` names it as the fetch gives up (after its three retries, about 50 seconds): `LibraryFileAwaited.index`, `.identity`, or `.identityNotKnown` (the identity file missing on a Mac that expects none).
The reason is then `DataDirectoryUnavailability.libraryFileNotArrived`, and the Library Not Available screen puts the choice to the listener, which TextMouth never makes alone:
- `.index`: "Open Without the Index…" asks first, then opens the library for the rest of the session (`libraryIndexWaitWaivedFor`), and the startup repair makes a new index from the books here.
- `.identity`: "Restore Its Identity…" asks first, then writes the identity this Mac expects (`LibraryIdentity.adopt`, a marker that arrived meanwhile stands), inside `DatalessFiles.withoutDownloading`, so a marker that arrived as a placeholder goes back to the fetch.
- `.identityNotKnown`: "Give It a New Identity…" asks first, with a warning, then opens the library for the rest of the session (`libraryIdentityWaitWaivedFor`), and it is given a new identity as it starts.

Each button's title, hint, question, and answers are in `LibraryFileWaitWording`, and a test pins each.
A new library, with no index and no identity, saves its empty index with its identity (`saveIndexOfNewLibrary(madeIdentity:hadIndex:)`), so its next launch opens without waiting; an index that existed before identities is left as it was.
That writes an empty library.json for a new local library at its first launch too.

## Which library a data directory holds
<!-- id: which-library-data-directory-holds; keys: identity marker, UUID, wrong folder, another copy of the library; src: TextMouth/Services/LibraryIdentity.swift, TextMouth/Services/DataDirectoryAvailability.swift, TextMouth/Services/StorageDestinationAssessment.swift, TextMouth/Services/TextMouthPaths.swift, TextMouth/ViewModels/LibraryViewModel.swift -->

Its identity: which library a data directory holds.

- Owner: the marker library-identity.json at the data directory's root (LibraryIdentity: a UUID and the date it was given), and DataDirectoryPreferences, this Mac's record of the custom location's path, a bookmark of its folder, and the identity expected there, all machine-local preferences.
- Who may write it: LibraryIdentity.adopt writes a marker only where there is none, creating the file exclusively, so one another Mac wrote a moment earlier stands: when the default location is created, and when a library without one starts (recordLibraryIdentity).
  TextMouthPaths.setCustomRoot records the path, the bookmark, and the identity together; recordLibraryIdentity records the identity again whenever a library starts, and a bookmark for a location chosen before bookmarks; TextMouthPaths.recordRelocation records a folder the bookmark found.
- How others observe it: DataDirectoryCheck compares the marker with the identity expected, so a folder that only has the right name is never taken for the library, and StorageDestinationAssessment recognizes a folder holding another copy of the library in use.

## The session lease
<!-- id: session-lease; keys: TextMouth Is Open on Another Mac, Sessions folder, multiple Macs, lease file, stale lease; src: TextMouth/Services/LibrarySessionLease.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/Platform/macOS/App/AppDelegate.swift -->

The session lease: this Mac's note, in a library another Mac can open, that it has the library open.

- Owner: LibrarySessionLease.shared, which keeps this Mac's file, `Sessions/<Mac ID>.json` (the computer's name, when TextMouth was last active, and the app's version), in a data directory in a cloud location or on another volume, asking the cloud services' provider where the directory is.
  One on the startup disk gets none.
  Its disk work, writing and refreshing the file, reading the other Macs' files, and removing stale ones, runs on its own serial queue (diskQueue) with dataless files left in the cloud, so a Sessions folder that hasn't synced never stalls the main thread.
  Its refresh() is awaited, and ending the lease at quit waits at most two seconds (removalWait) for the file's removal.
- Who may write it: the library model begins the lease when the library starts, and again after Try Again, writing the file and refreshing it every minute, and pauses it when the library is lost; AppDelegate ends it at quit, removing the file.
  A refresh removes leases untouched for 30 days, and the file a move left in the old data directory.
- How others observe it: each Mac's refresh reads the other files with dataless files left in the cloud, judging one only in the cloud by its modification date.
  Another Mac's lease refreshed in the last three minutes brings one warning a session (TextMouth Is Open on Another Mac, with Continue and Quit TextMouth); nothing is locked.
  A file whose name begins with this Mac's ID, as a sync service's conflict copy of this Mac's own lease does (`<Mac ID> 2.json`), never counts as another Mac, and ages out as any lease does.

## Files several Macs write
<!-- id: files-several-macs-write; keys: multi-Mac, conflict copy, stand-in, dataless, unsaved notice, crash safety; src: TextMouth/Services/SavedFile.swift, TextMouth/Services/ReadingStatsService.swift, TextMouth/Services/TextSubstitutionService.swift, TextMouth/Services/LibraryIndexQuarantine.swift, TextMouth/Services/PersistenceFailureCenter.swift, TextMouthProductionTests/MultiMacCrashSafetyTests.swift -->

Files several Macs write: reading_stats.json and substitutions.json, which TextMouth reads whole and replaces whole, and which another Mac sharing a library in the cloud writes too.

- Owner: ReadingStatsService and TextSubstitutionService, each for its own file, which each reads through SavedFile with dataless files left in the cloud, so a read on the main thread never waits on the network.
  SavedFile.read(_:using:) tells a missing file, one only in the cloud, one that can't be read, and its bytes apart.
- Who may write it: each service, never over a file only in the cloud, and over one it can't read or decode only after keeping a copy of it, or logging that none could be made.
  A file found only in the cloud is asked of the sync service (SavedFile.requestDownload(of:)), with one line in the log, and stand-ins are used meanwhile, never saved over it.
  Fresh statistics stand in (statsAwaitFileInCloud), counting this session's listening; each save first reads the file again, and the first that finds it on this Mac adds the stand-ins to what it holds (ReadingStats.adding(_:)) and saves the sum.
  A reading_stats.json that isn't on this Mac at all, in a cloud location, is waited for the same way (SavedFile.mayStillArrive(_:)).
  Only a save with listening to keep writes the stand-ins while it is still missing.
  config.json is not made by a save that only reconciles it or notes a book was opened (ConfigService.scheduleSave(creatingAwaitedFile:)).
  Saves merged into one write may make it if any of them may, so a changed setting's save still writes it.
  In a cloud location the settings stay in the preferences until the file arrives.
  ReadingStatsService.statsReadFromFile says whether the statistics hold what the file held: true once it was read and decoded (at launch, when the library is available again, or once a file only in the cloud was added to the stand-ins), never for stand-ins.
  The standard rules stand in for the substitutions (rulesAwaitFileInCloud).
  The file is read again when the app becomes active and before each save, a save meanwhile is reported to PersistenceFailureCenter as unsaved, with a retry (SavedFile.InCloudError).
  And once the file is on this Mac its rules replace the stand-ins and the notice is withdrawn, dropping the change made to them.
  With no substitutions.json at all, the standard rules stand in without being written, and the file is written only when a rule changes, so one the sync service brings down later is adopted, on activation or before the next save, without a conflict copy.
  A file that can't be read or decoded, as a write cut short on another Mac leaves it, is preserved beside itself before anything replaces it (SavedFile.preserveUnusable, through LibraryIndexQuarantine).
  And fresh statistics or the standard rules stand in until the next save replaces it.
- How others observe it: the Stats tab, the Text tab, and the reader's substitution pass use the stand-ins until the file is read, and READING_STATS_FILE and SUBSTITUTIONS_FILE lines record each wait, arrival, and preserved copy.
  A sync service's conflict copy of library.json, a package record, the identity marker, config.json, or one of these two files is never read in place of the file it copies, nor removed; a package copied under another name is never adopted as a second book; and nothing merges what two Macs wrote.
  MultiMacCrashSafetyTests feeds library.json, the packages and their records, the identity marker, the leases, config.json, these two files, and the checkpoint journal what another Mac can leave:
  - conflict copies,
  - files cut short,
  - files only in the cloud,
  - packages that disappeared,
  - another Mac's lease,
  - an index listing packages not here yet.

  It checks that the code reading each may log a line, warn of another Mac, show the recovery sheet or the Library Not Available screen, or leave a row as it is, but never crashes, hangs the main thread, or deletes anything.

## This Mac's own folders
<!-- id: this-mac-own-folders; keys: Application Support, Caches, machine-local, scratch folders, not synced; src: TextMouth/Models/CloudStorageContract.swift, TextMouth/Services/ImportScratchSpace.swift, TextMouth/Services/ImportStaging.swift, TextMouth/Services/ArchiveExtraction.swift, TextMouth/Services/AudioEditing/AudioEditComposition.swift, TextMouth/Services/AudioEditing/AudioEditCaches.swift, TextMouth/Services/TextMouthPaths.swift, TextMouth/App/TextMouthRuntime.swift, TextMouth/Services/ReaderWorkingCopy.swift, TextMouth/Services/KeptBooks.swift, TextMouth/Services/ReadingTextCache.swift, TextMouth/Services/RecordingService.swift, TextMouth/Services/MigrationStagingLeftovers.swift, TextMouth/Services/Feeds/FeedStore.swift -->

This Mac's own folders.

- Owner: MachineLocalPaths:
  - ~/Library/Logs/TextMouth, where the logs go when Storage settings choose this Mac and while the data directory can't take them (see [The diagnostic logs](logs.md)),
  - and, in ~/Library/Application Support/com.textmouth.TextMouth:
    - Working Copies, Import Staging, Archive Extraction, Recordings (MachineLocalPaths.recordings), and Feed Downloads (MachineLocalPaths.feedDownloads),
    - beside two files, Kept Books.json (MachineLocalPaths.keptBooks) and Move Leftovers.json (MachineLocalPaths.moveLeftovers),
  - and, in ~/Library/Caches/com.textmouth.TextMouth:
    - Reading Text (MachineLocalPaths.readingTextCache),
    - Search Text (MachineLocalPaths.librarySearchText, Search Library's texts; see [Text caches](text-caches-rereads-edits.md)),
    - Feeds (MachineLocalPaths.feedCaches), and BrailleTables (MachineLocalPaths.brailleTables: the tables unpacked from the pack, see [Braille table pack](braille-table-pack.md#the-unpacker)),
    - Audio Edits (AudioEditScratch.root),
    - and Audio Editor Clips (AudioEditCaches.clipsRoot), which macOS may empty.

  They never sync, and stay usable while the data directory is unavailable; under hosted tests they are in the sandbox.
- Who may write it:
  - the log writer (see [The diagnostic logs](logs.md));
  - ReaderWorkingCopies (see [The cloud working copy](reader.md));
  - KeptBooks, Kept Books.json and Keep Reading List Books.json (see [Books kept on this Mac](cloud-state.md) and, for the choice to keep the reading list's books, [Books the reading list keeps](cloud-state.md));
  - MigrationStagingLeftovers, Move Leftovers.json (the leftovers of moves, above);
  - ReadingTextCache (see [Kept reading text](text-caches-rereads-edits.md));
  - RecordingService, whose takes stay in Recordings until they are saved as books, or until a punch-in's edit holds them (see [A take being recorded](recordings.md)), and the Record window, which saves or discards a take left there (see [Takes left behind](recordings.md));
  - the feed engine, whose finished downloads wait in Feed Downloads and whose fetch details, resume data, and list of the downloads TextMouth quit during are in its Caches folder (see [Feeds](feeds.md));
  - audio editing, whose filtered stretches and silence wait in Audio Edits, a folder for each book, until the book's edits are saved or its editing session ends (AudioEditScratch, in [Rendering the edited audio](audio-edits.md));
  - the audio editor window, whose audio kept for Paste waits in Audio Editor Clips, a folder for each window, removed as the window closes (see [The editor window](audio-edits.md)).
    And what a crash, or a quit with editors open, left in either folder is removed at the next launch, off the main thread, never a folder in use (AudioEditCaches.removeStale, from startLibrary, logged as AUDIO_EDIT_CACHES_SWEPT).
    A folder in use is a book's while it is being edited or saved, looked at and set aside under the lock its folder is made under, and a window's while the window is open;
  - and imports, through ImportScratchSpace, which stages packages and extracts archives here while the data directory is on this folder's volume (the startup disk, where iCloud Drive's and File Provider's folders are too).
    Otherwise it stages beside each package's destination and extracts in the data directory's Archive Extraction folder, so publishing stays one rename on one volume.

  ImportScratchSpace never creates a folder inside a data directory that vanished.
- How others observe it: at launch, ArchiveExtractionDirectory.removeLeftovers sweeps both Archive Extraction folders, listing the data directory's with dataless files left in the cloud, and removes the data directory's once it is empty while this Mac's is in use.
  An extraction folder is named for the process that made it (extract- followed by its process number and a UUID).
  The sweep removes one of this process's own that no import of it uses, and one whose maker has ended, by the rule the test sandbox sweep follows (TextMouthRuntime.isFolderMakerRunning, in [Sandboxes left behind](hosted-test-sandbox.md)), so a later process that took the number keeps no leftover.
  Only plain folders go.
  Each import sweeps the folder it stages in, and, when that is this Mac's, the destination folder that earlier versions staged in.
  While an import stages a book, the book's tmbDirectory is the staged package, wherever it is (ImportStaging.directory(ofStagedPackage:)).

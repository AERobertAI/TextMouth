# Keeping the TextMouth data directory in iCloud Drive or Google Drive

Research for the October 3 request, from the code on main (6acb853), the macOS 26 SDK headers, and Apple's and Google's documentation. This Mac was inspected read-only with materialization off, and nothing was downloaded or changed. Bracketed numbers cite the sources.

## Summary

- **Feasible without an Apple Developer account.** With no iCloud entitlement, Foundation's ubiquitous-item keys report each file's cloud state, and on this Mac they behave the same for iCloud Drive, Google Drive and Dropbox.
- **Today's code is unsafe in a cloud folder.** It does disk work on the main thread at launch and during moves, its maintenance can download every book, and it assumes a single Mac.
- **Recommendation: option A, made cloud-aware.** Put the whole directory in the cloud folder, keep machine-local and fast-changing files on the Mac, and support one Mac at a time at first.
- **Progress:** every provider reports per-file state, so an opening book can show "2 of 3 files". Byte progress within a file is unverified.
- **Pinning:** apps have no "Keep Offline" API. iCloud's Keep Downloaded and Google's Available offline stay in Finder.

## 1. What TextMouth does today

- **Location:** `~/.TextMouth`, unless the preference `textMouthDataDirectory` names another folder. It is unset here.
- **Change Location** creates a hidden `.TextMouth` inside the chosen folder; an existing `.TextMouth` there must be empty. `DataDirectoryMigrator` copies to a hidden staging folder beside it, rewrites absolute book paths, validates and renames, all on the main actor (`StorageSettingsView.start`). Editing `dataDirectoryPath` in config.json also triggers a move (`SettingsViewModel.observeExternalEdits`).
- **Launch:** `LibraryViewModel.init` runs on the main actor. It reads library.json and runs `migrateOldBooksIfNeeded`: a `fileExists` call per book, folder scans, and orphan adoption.
- **Watching:** only config.json is watched. A running copy never re-reads library.json.
- **Writes:** library.json (690 KB here) is replaced after every change, including the 30-second playback checkpoint, which also writes the book's bookInfo.json. reading_stats.json is saved every 60 seconds while you listen, and logs are appended line by line.
- **Text caches:** fingerprints compare size and nanosecond modification time, and a redated source is MD5-hashed in full. A cache-format bump or Redo Text Extraction reads every source, and an index-version bump re-reads every book.
- **Source reads:** opening an EPUB or audiobook always reads the book's own file for metadata, on a background queue. Book Info reads an EPUB on the main thread (`LibraryView.showBookInfo`).
- **Temporary folders:** import staging (`.import-<UUID>.tmb`) and `Archive Extraction/extract-<pid>-<UUID>` live inside the data directory. Their leftover sweeps rely on an in-process set and on `kill(pid, 0)`.
- **Build:** no cloud API is used, and `.tmb` is an exported package type. The app is unsandboxed and ad-hoc signed (`CODE_SIGN_IDENTITY: "-"`, no provisioning profile), and `make install` installs it.

## 2. What is on this Mac

- **System:** macOS 26.3.1 on one case-insensitive APFS volume. The library, `~/Library/Caches` and every cloud folder share one device, so renames between them work.
- **iCloud Drive** (`~/Library/Mobile Documents/com~apple~CloudDocs`):
  - 1,164 of the 1,165 top-level files are dataless (`ls -lO`: `compressed,dataless`), with no `.icloud` placeholders, so evicted files keep their real names as APFS dataless files.
  - 1,153 of them report 0 bytes through `stat`, and samples agree in Foundation and Spotlight.
- **Google Drive** streams through File Provider at `~/Library/CloudStorage/GoogleDrive-<your Gmail address>/My Drive`.
  - Its xattrs are `com.apple.file-provider-domain-id` on the domain root and `com.google.drivefs.item-id#S` on files.
  - 389 of the 390 top-level files are dataless, all reporting real sizes.
- **Dropbox** is a File Provider domain too, at `~/Library/CloudStorage/Dropbox`.
- **What an unentitled process sees** (osascript, materialization off): for sampled items in all three drives, `isUbiquitousItem` is true, the status is NotDownloaded or Current, and the upload flags are filled in. `NSMetadataItem(url:)` returns no ubiquitous attributes, and every probed file stayed dataless.
- **macOS 26 sync controls:** iCloud reports pause plus fail-on-conflict uploads (value 3). Google Drive and Dropbox report pause only (value 1).
- **The library:** 5.5 GB in 644 packages, typically 3 files and 1.4 MB each, the largest a 925 MB audiobook. The text caches total 580 MB.

## 3. iCloud Drive

- **Reading state:** `URLResourceValues` gives `isUbiquitousItem`, `ubiquitousItemDownloadingStatus`, `ubiquitousItemIsDownloading`, the uploaded and uploading flags, the download error, and unresolved conflicts [3][25]. `SF_DATALESS` from `stat` is the cheap local check [12].
- **Downloading:**
  - `startDownloadingUbiquitousItem(at:)` has no completion handler [1]. A developer reports it returning success while offline [20].
  - Apple DTS called it a bug (reported on iOS 15 and later) that `coordinate(with:queue:byAccessor:)` doesn't force iCloud downloads; the synchronous `coordinate(readingItemAt:)` does [20].
  - A plain read also downloads; the syscall is paused until the data arrives [19].
- **Evicting:** `evictUbiquitousItem(at:)` removes only the local copy [2], and DTS confirms apps may call it on iCloud Drive files [20].
- **Byte progress:**
  - `NSMetadataUbiquitousItemPercentDownloadedKey` needs `NSMetadataQuery`'s ubiquitous scopes, which search the app's own containers [8], so it needs the entitlement.
  - `Progress.addSubscriber(forFileURL:)` hears progress another process publishes for a URL [9]. Whether iCloud publishes there is unverified.
- **Coordination:** presenters hear only about coordinated changes [6], access inside a package coordinates the whole package [5], and `immediatelyAvailableMetadataOnly` reads metadata without downloading [4].
- **Packages:** only the changed files inside a package upload [15].
- **Conflicts:** when two computers save at once, one version wins and the rest become conflict versions [7]. A losing library.json is silently set aside unless TextMouth checks `unresolvedConflictVersionsOfItem(at:)` [7].
- **Entitlement:** none is needed for files you placed in iCloud Drive. A container (`url(forUbiquityContainerIdentifier:)`, the ubiquitous query scopes, CloudKit) needs the iCloud capability on an App ID [14]. That is a restricted entitlement, which only a provisioning profile can authorize [13], so today's ad-hoc signing rules it out.
- **Newer APIs:** macOS 26's pause and fail-on-conflict uploads would give library.json a compare-and-swap on iCloud [11], but the app targets macOS 14. `ubiquitousItemIsExcludedFromSync` keeps an item out of sync [10].

## 4. Google Drive and other File Provider drives

- **Location:** streaming on macOS 12.1 or later uses File Provider in `~/Library/CloudStorage`, a location you can't change [22]. Mirror mode keeps every file local [23], so there is nothing to download.
- **State:** the same Foundation keys work (observed). `volumeIsLocal` is true, so only the keys and the path identify cloud folders.
- **Reads** of a dataless file block until it is materialized [17][19]. On the main thread that causes hangs, `ETIMEDOUT` errors or watchdog kills, and even `fileExists` or a folder listing can materialize dataless folders [12]. A thread can opt out with `setiopolicy_np` (`IOPOL_MATERIALIZE_DATALESS_FILES_OFF`) and gets `EDEADLK` instead [12][25].
- **When Drive isn't available:** while Drive is paused, nothing can be downloaded. Downloaded files stay readable while Drive isn't running [22].
- **Not available to TextMouth:** `NSFileProviderManager`'s download, evict and progress calls need the caller's own domain, and `getIdentifierForUserVisibleFile` fails for items your extension doesn't manage [18]. FileManager's calls [1][2] are documented generically and untested on Drive.
- **Progress:** the provider reports each download to the system [17], and Finder shows it per file [19], but a client could reach it only through `Progress.addSubscriber` (unverified). Content is cloned into place when complete [17], so file size never shows progress.
- **Pinning:** "Available offline" and Keep Downloaded [21] belong to the provider and Finder. Content policies are set by providers (`NSFileProviderContentPolicy`), and Foundation gives clients no call to read or set pinning [25].
- **Conflicts:** Google makes the original inaccessible and leaves "a copy of the file with your edits" in its folder, or in Lost & Found [24]. Names differing only in case are renamed locally [25].
- **Also impossible for TextMouth:** reading the quota, cancelling a download, or knowing whether Drive is paused.

## 5. Risks

1. **Main-thread hangs** at launch, during Change Location, and in Book Info [12].
2. **Whole-library downloads:** from version bumps, Redo Text Extraction, the statistics pass, and MD5 checks of redated sources. If evicted iCloud files report 0 bytes (as 1,153 do here), they look resized, so their caches would be called stale and rebuilt from downloaded sources.
3. **Two Macs at once:** a running copy's next save overwrites or conflicts with the other Mac's changes, and playback rewrites library.json every 30 seconds (up to about 80 MB of uploads an hour). Another Mac's `dataDirectoryPath` triggers a move attempt here, absolute paths differ when user names differ, and reading_stats.json and the logs conflict.
4. **Sweeps:** another Mac's process IDs mean nothing here, and the staging sweep deletes any `.import-*` this process isn't building, including another Mac's import in progress. Both folders also upload throwaway data.
5. **The migrator** copies on the main thread and hides the folder (dot-folder sync is unverified). Its staging folder uploads mid-copy, and it can't see the quota. Moving back out must download 5.5 GB, and it can't attach a second Mac to an existing cloud library.
6. **Partial sync:** library.json can arrive before the packages it lists.
7. **Lower risk:** the config.json watcher handles rename and delete events, though it is untested against sync. Name lengths already fit APFS. Eviction skips unsynced edits [16] and fails on open files (`EBUSY`) [25], which should protect a playing audiobook (untested).

## 6. Design options

- **A. The whole directory in the cloud folder.** For: what was asked, one root, any provider, and it reuses index recovery and orphan adoption. Against: per-Mac and busy files must move out, and several Macs need merging.
- **B. Books in the cloud; index and caches local.** For: no shared index. Against: two roots, an index per Mac, repair by book ID when packages move, caches extracted on every Mac, and not what was asked.
- **C. A cloud library the app manages over the local one.** For: full control and real pinning. Against: it reimplements sync and stores books twice. Highest risk.

**Recommendation: A, made cloud-aware.** It is the smallest change that meets the request, and one code path serves both providers.

- **Synced:** books, library.json, config.json (portable fields only) and substitutions.json, in a visible "TextMouth" folder.
- **Kept on each Mac:** logs, archive extraction, import staging (packages built locally and renamed in), and one statistics file per Mac.
- **Computed, never saved:** cloud state comes from a `CloudItemStatusProvider` protocol (resource keys plus `SF_DATALESS`) read off the main thread, polled while a download runs.
- **One Mac at a time:** a lease file with a heartbeat for each Mac; TextMouth warns when another Mac is active.

**Book list notes:**

- **Notes,** placed after "New" or "Now Reading": "In Cloud", "Downloading 40%", "Download Failed", "Uploading", and "Waiting for Sync" (the package hasn't arrived).
- **"Downloaded"** is optional; otherwise all 644 rows would say it.
- **Spoken row:** "Moby-Dick, by Herman Melville, Downloading, 40 percent, 42 percent read, 3 hours remaining, EPUB". Reading progress gains "read" so the row never holds two bare percentages.

**Commands:**

- **Where:** the row's context menu, the Library menu (with shortcuts), and VoiceOver custom actions.
- **The commands:** Download Now; Remove Download, disabled while the book is open or has changes not yet uploaded; and Show in Finder, for Keep Downloaded and Available offline.
- **Later:** an experimental "Keep on This Mac" that TextMouth enforces itself.

**Opening a book that isn't downloaded:**

- **The window:** the reader opens at once with a "Downloading Moby-Dick" heading, Cancel, and a progress bar that takes VoiceOver focus. The bar reads "2 of 3 files, 40 percent", or is indeterminate (with size and elapsed time) for one large file.
- **Announcements:** at the start, every 25 percent (or every 30 seconds without a percentage), "Downloaded. Loading.", and on failure, with the reason and Retry.
- **Audiobooks:** the current chapter downloads first.
- **What each provider can report:** per-file state and sizes everywhere, counting files where iCloud reports zero sizes. Within-file progress is available only if `Progress.addSubscriber` works.

## 7. Testing strategy

- **Unit tests with fakes behind protocols:**
  - Combining file states into a package state.
  - Visible and spoken wording.
  - Progress arithmetic, including zero sizes.
  - Opening: time-out, Cancel, Retry, offline.
  - Remove Download rules.
  - Maintenance and fingerprints skipping dataless files.
  - Migrator checks: cloud destination, size, free space.
  - The `dataDirectoryPath` guard, Mac-aware sweeps, leases, and conflict copies.
  - The materialization-off helper, with a fake that throws `EDEADLK`.
- **Opt-in hosted tests** (skipped by default) in a throwaway folder inside each drive:
  - Upload, evict, and the dataless flag and size.
  - Download calls, status changes, and whether `Progress.addSubscriber` reports anything.
  - Whether modification times survive.
  - `EDEADLK`, and renaming a package in.
- **By hand on this Mac, with both drives:**
  - Migrating in and out.
  - Offline, a slow network (Network Link Conditioner), and Drive paused or quit.
  - Conflicts from two Macs, or offline plus the web.
  - Finder's Remove Download on an open text book and audiobook.
  - Optimize Mac Storage on a nearly full disk.
  - A second Mac's first launch.
  - VoiceOver and braille throughout.
- **Experimental settings:** the cloud location until Phase 3, Remove Download, Keep on This Mac, several Macs, and the sync controls.

## 8. Phased plan

- **Phase 0, spike (1–2 days):** the hosted tests above, to settle the unverified points.
- **Phase 1, first safe step (about 1 week):**
  - Detect cloud destinations and warn (size, upload time, one Mac at a time), behind the experimental setting.
  - Move the library off the main actor, with progress and Cancel.
  - Use a visible "TextMouth" folder.
  - Ignore another Mac's `dataDirectoryPath`.
  - Keep logs, extraction and staging local.
- **Phase 2, cloud-aware reads (1–1.5 weeks):**
  - Add the status provider.
  - Move launch loading and repair off the main thread, scanning with materialization off.
  - Make maintenance and fingerprints skip dataless books.
  - Move Book Info off the main thread, and make the reader wait for downloads.
- **Phase 3, interface (1–1.5 weeks):** notes, commands, the reader's download view, announcements, and an "N books in the cloud" summary.
- **Phase 4, several Macs (about 2 weeks):** leases, conflict detection, reconciling rows with package records (newest revision first), per-Mac statistics, relative paths, and "Use Existing Library…" for a second Mac.
- **Phase 5, optional:** Keep on This Mac, and the macOS 26 sync controls.

## Open questions for you

1. One Mac, or several sharing one library?
2. iCloud Drive or Google Drive first?
3. Should every downloaded book say "Downloaded"?
4. Is a visible "TextMouth" folder acceptable instead of ".TextMouth"?
5. Should the text caches (580 MB) sync, or be rebuilt on each Mac?
6. Will Google Drive stay in Stream mode? Mirror mode keeps everything local.

## What I could not verify

(November 6, 2026: the real-drive tests of October 3 did run FileManager's download and removal calls on Google Drive and Dropbox, for book files; see Testing on real cloud drives in docs/developer/testing.md. A library's own files are now fetched by reading them, which TextMouth can wait for, as LibraryViewModel+LibraryFetch does.)

- Downloading or evicting through FileManager on Google Drive and Dropbox.
- `Progress.addSubscriber` progress.
- Whether the zero-byte iCloud files are really empty.
- Whether modification-time precision survives eviction.
- What reading an evicted file does while offline.
- Whether dot-folders sync.
- Google's conflict-copy names.
- Whether renaming a package into the folder is atomic.
- An Apple statement that iCloud Drive uses File Provider. A secondary source agrees [26].

## Sources

1. startDownloadingUbiquitousItem(at:): https://developer.apple.com/documentation/foundation/filemanager/startdownloadingubiquitousitem(at:)
2. evictUbiquitousItem(at:): https://developer.apple.com/documentation/foundation/filemanager/evictubiquitousitem(at:)
3. ubiquitousItemDownloadingStatus: https://developer.apple.com/documentation/foundation/urlresourcevalues/ubiquitousitemdownloadingstatus
4. immediatelyAvailableMetadataOnly: https://developer.apple.com/documentation/foundation/nsfilecoordinator/readingoptions/immediatelyavailablemetadataonly
5. coordinate(with:queue:byAccessor:): https://developer.apple.com/documentation/foundation/nsfilecoordinator/coordinate(with:queue:byaccessor:)
6. NSFilePresenter: https://developer.apple.com/documentation/foundation/nsfilepresenter
7. NSFileVersion: https://developer.apple.com/documentation/foundation/nsfileversion and https://developer.apple.com/documentation/foundation/nsfileversion/unresolvedconflictversionsofitem(at:)
8. NSMetadataQueryUbiquitousDocumentsScope: https://developer.apple.com/documentation/foundation/nsmetadataqueryubiquitousdocumentsscope and https://developer.apple.com/documentation/foundation/nsmetadataubiquitousitempercentdownloadedkey
9. Progress.addSubscriber(forFileURL:withPublishingHandler:): https://developer.apple.com/documentation/foundation/progress/addsubscriber(forfileurl:withpublishinghandler:)
10. ubiquitousItemIsExcludedFromSync: https://developer.apple.com/documentation/foundation/urlresourcevalues/ubiquitousitemisexcludedfromsync
11. Sync controls: https://developer.apple.com/documentation/foundation/filemanager/pausesyncforubiquitousitem(at:completionhandler:) , https://developer.apple.com/documentation/foundation/urlresourcekey/ubiquitousitemsupportedsynccontrolskey , https://developer.apple.com/documentation/foundation/filemanager/uploadlocalversionofubiquitousitem(at:withconflictresolutionpolicy:completionhandler:)
12. TN3150, Getting ready for dataless files: https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files
13. TN3125, Inside Code Signing: Provisioning Profiles: https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles
14. Configuring iCloud services: https://developer.apple.com/documentation/xcode/configuring-icloud-services
15. Designing for Documents in iCloud (archived): https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html
16. Synchronizing the File Provider Extension: https://developer.apple.com/documentation/fileprovider/synchronizing-the-file-provider-extension
17. fetchContents(for:version:request:completionHandler:): https://developer.apple.com/documentation/fileprovider/nsfileproviderreplicatedextension/fetchcontents(for:version:request:completionhandler:)
18. NSFileProviderManager: https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/getidentifierforuservisiblefile(at:completionhandler:) and https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/getdomainswithcompletionhandler(_:)
19. WWDC21, Sync files to the cloud with FileProvider on macOS: https://developer.apple.com/videos/play/wwdc2021/10182/
20. Apple Developer Forums, DTS answers: https://developer.apple.com/forums/thread/764270 and https://developer.apple.com/forums/thread/763378
21. Apple Support, iCloud Drive files on Mac: https://support.apple.com/guide/mac-help/mchl1a02d711/mac
22. Google, Use Drive for desktop on macOS: https://support.google.com/drive/answer/12178485
23. Google, Stream and mirror files: https://support.google.com/drive/answer/13401938
24. Google, Fix problems in Drive for desktop: https://support.google.com/drive/answer/2565956
25. macOS 26 SDK headers (Foundation `NSURL.h`, `NSFileManager.h`; FileProvider `NSFileProviderManager.h`, `NSFileProviderReplicatedExtension.h`, `NSFileProviderItem.h`) and man page `getiopolicy_np(3)`.
26. Secondary: Eclectic Light, How iCloud Drive works in macOS Sonoma: https://eclecticlight.co/2024/03/18/how-icloud-drive-works-in-macos-sonoma/

# Cloud library: answers, revised design, and the working-draft plan (FR02)

October 3, 2026. This follows `CLOUD-STORAGE-RESEARCH-2026-10-03.md` (on main) and the user's answers to its six questions. It was written read-only against main at cfdca33, including the S10 migration guard, the P10 reader refresh, and the I01 import decision queue. Nothing in the repository or any cloud folder was changed. Every check of this Mac ran with dataless-file materialization switched off, so nothing was downloaded. Numbered references point to the sources at the end.

## What the user asked for, in short

- **Main goal:** free space on this Mac by keeping books in the cloud. A cloud library also serves as long-term storage and as a backup that another Mac can restore.
- **Two Macs:** should be possible and safe, but not a priority yet.
- **Providers:** iCloud Drive, Google Drive and Dropbox, together, through one code path.
- **Cloud notes:** "Downloaded", "In Cloud" and similar, shown only when the library is in a detectable cloud location.
- **Location:** the data directory can be any folder, on any drive, hidden or not.
- **Unavailable library:** when the library can't be reached, show an error screen with Retry and Quit.
- **Caches:** sync everything, text caches included.
- **Sync modes:** both mirror and streaming should work.
- **Open books:** an open book must never vanish or stop playing offline.

## 1. How long files stay downloaded, and keeping an open book safe (question 6)

No provider promises a time limit. In every case, a downloaded file stays on the Mac until one of three things happens:
- the system needs disk space,
- you remove the download yourself,
- or, for Dropbox, the app turns unpinned files online-only because the disk is low.

Pinned items are protected from all of this.

**iCloud Drive**
- **With Optimize Mac Storage on:** "older documents are stored in iCloud when space is needed" [1]. macOS keeps "only recently opened files on your Mac when space is needed" [2].
- **With it off:** the full contents of iCloud Drive stay on the Mac [1].
- **Pinning:** Finder's Control-click menu offers Keep Downloaded, which shows a Keep Downloaded icon; Remove Download and Download Now are beside it [3].
- **On this Mac:** 1,164 of the 1,165 files at the top of iCloud Drive are evicted, which suggests Optimize Mac Storage is on.

**Google Drive for desktop**
- **Streaming:**
  - It uses File Provider on macOS 12.1 and later [4].
  - Opened files are cached, and the cache "makes them available offline". On newer macOS, "macOS manages the content cache", and no size limit can be set [5]. Google documents no lifetime.
  - File Provider's default policy is to download a file when it is read and to "allow eviction on low disk pressure and other triggers" [11].
- **Pinning:** Control-click, then Offline Access, then Available offline [6].
- **Offline access:** with File Provider, offline files open even when the Drive app isn't running [6]. While Drive is paused, nothing can be downloaded [4].
- **Mirroring:** every file is stored on the computer and is always available offline [7]. To TextMouth a mirrored folder is an ordinary local folder, so there's nothing to download or show.

**Dropbox (File Provider)**
- **Opening:** opening an online-only file downloads it and makes it available offline [8].
- **Automatic eviction:** "Dropbox files or folders not previously set to Make available offline may be automatically set to online-only when your hard drive is low on disk space" [9].
- **Pinning:** Make available offline pins a file. Only pinned files count as occupying disk space [9].
- **New files:** the default for new files can be set to Online-only [8].

**A file open in another app (TextMouth)**
- The File Provider eviction call fails with `EBUSY` while a file has open descriptors. It also refuses items with edits not yet uploaded [10][12].
- Whether the system's own low-space eviction also skips an open file is not documented.
- AVPlayer holds only the current audio file open. A multi-file audiobook's other chapter files can therefore be evicted, or never downloaded, while the book is open.

**What TextMouth will do so an open book never stops**
1. **Download the whole book before opening it,** in the reader window, with a progress bar, Cancel and Try Again. A Mac that is offline gets an immediate explanation, never a hang: the network's state comes from `NWPathMonitor` [21].
2. **Keep a working copy of an open audiobook:**
   - The package is cloned into `~/Library/Application Support/com.textmouth.TextMouth/Working Copies`.
   - `FileManager.copyItem` makes an APFS clone, which "occupies no additional space on disk" [13]. The cloud folders share the startup volume with that folder (checked: same device).
   - Playback reads the copy, so eviction or a lost network can't interrupt it. The copy is removed when the reader closes.
   - Text books are already read into memory when they open.
3. **Re-check each chapter's file before playing it** when no working copy exists. Online, it downloads the file first; offline, playback stops at the chapter boundary with a clear sentence.
4. **Load books and scan in the background with materialization off:**
   - Scans run under `setiopolicy_np(…MATERIALIZE_DATALESS_FILES_OFF)` [14]. A file that is unexpectedly evicted fails at once with `EDEADLK` and is handled, never waited on.
   - I checked this on this Mac. Reading an evicted iCloud file this way failed immediately, the error was recognized, and the file stayed evicted.
5. **Refuse Remove Download** for an open book, or one whose changes aren't uploaded yet.
6. **Point to pinning:** Show in Finder leads to Keep Downloaded, Available offline and Make available offline for books you want offline. A TextMouth "Keep on This Mac" command comes in the polish phase.

## 2. Hidden folders, and "any path"

My earlier suggestion of a visible "TextMouth" folder had two reasons:
- Finder hides dot-folders by default, which doesn't matter for this user.
- I hadn't verified that the providers sync dot-folders.

I checked the second point on this Mac, read-only:
- **iCloud Drive:** 572 dot-items, 56 of them dot-folders such as `.github` and `node_modules/.bin`. Every sample reported `isUbiquitousItem` true and `ubiquitousItemIsUploaded` true. Several dot-files (`.editorconfig`, `.travis.yml`) were evicted, so they live in the cloud.
- **Dropbox:** the dot-folder `Saves/.d` and dot-files were uploaded, and several were evicted.
- **Google Drive:** has no dot-items locally, and Google's help doesn't say either way. This stays unverified, and the `cloudtests` task checks it with a throwaway `.hidden-test` folder.
- **What providers do ignore:** system files. Dropbox documents ignored files and its own ignore attribute [15], and iCloud reports `.DS_Store` as not synced. TextMouth relies on none of these.

**Design: any folder can be the data directory.**
- **Location:** hidden or visible; on the startup disk, an external or network drive, or a cloud folder.
- **Choosing:** the chooser selects the folder itself rather than a parent with `.TextMouth` appended. It shows hidden files, and the user can create or name the folder, `.TextMouth` included.
- **Empty folder:** Move Library Here.
- **Folder already holding a TextMouth library:** Use This Library. This switches without copying, which is how another Mac restores the library from the cloud.
- **Anything else:** refused, with the reason.
- **Identity:** each library gets an identity marker file holding a UUID. The preferences remember that UUID and a bookmark of the folder [16]. A drive that remounts under a new name is then found again, and a folder that merely has the right name but holds a different library is refused.

## 3. When the data directory is unavailable

**Today:**
- A missing custom location loads as an empty library, because a missing `library.json` counts as a first run.
- If the drive returns while TextMouth runs, the next save can write that empty index over the real one.
- `ensureDirectoryStructure` creates missing parents with `withIntermediateDirectories: true`. `~/Library/CloudStorage` is writable by the user, so a signed-out Google Drive or Dropbox folder would silently get a fresh local library. `/Volumes` isn't writable, so an unplugged drive's path fails quietly instead.

**The design:**
- **Startup check:** before anything is created or loaded, TextMouth checks the library:
  - The default location keeps today's first-run behavior.
  - A custom location must exist and be readable, and it must hold this library: the identity marker, or `library.json` for a library that has no marker yet.
  - Nothing is ever created at a missing custom location or under its parents.
- **The unavailable screen:** if the check fails, every Library window shows a full-window view and nothing is loaded or saved.
  - A heading, "Library Not Available".
  - One sentence giving the reason, for example:
    - "The drive “Backup” isn't connected."
    - "The folder … can't be found. Google Drive may be signed out or not running."
    - "TextMouth can't read the folder …"
    - "The folder is there, but the library isn't in it."
    - "The library index is in iCloud Drive and isn't on this Mac yet."
  - The full path, as selectable text.
  - Try Again, the default button.
  - Quit TextMouth.
- **VoiceOver:** focus lands on the message, using `InitialVoiceOverFocusModifier` as the index-recovery view does. The reason is announced through `VoiceOverAnnouncer`, and every control has a label.
- **Try Again** re-runs the check, then the normal startup.
- **Losing the library while running:** when the volume unmounts (`NSWorkspace.didUnmountNotification` [17]) or a save finds its folder gone:
  - Saving stops.
  - The windows switch to the same screen.
  - Unsaved changes stay listed in `PersistenceFailureCenter`, so they can be retried.
- **Logs** move to `~/Library/Logs/TextMouth`, so logging keeps working and nothing churns in the cloud.

## 4. Revised recommendation

Keep design A: the whole data directory, in today's layout, with the full text cache in each package, in any folder.

- **Providers:** one code path covers iCloud Drive, Google Drive and Dropbox (and any other File Provider drive), through Foundation's ubiquitous-item resource keys. On this Mac those keys behave the same for all three, without any entitlement [18].
- **Mirror and stream:**
  - A mirrored folder is ordinary local storage.
  - A streamed folder gets cloud notes, downloads on open, and Remove Download.
- **Cloud notes:** only when the data directory is in a detectable cloud location: Downloaded, In Cloud, Downloading 40%, Download Failed, Waiting for Sync. A local or external library looks exactly as today.
- **This Mac's own folders:** logs, archive extraction, import staging and working copies live in folders that belong to this Mac, while the data directory is on the startup volume. An external drive keeps extraction and staging on itself, as today, so publishing stays a single rename on one volume.
- **Single Mac first, safe for two:**
  - Each Mac writes a heartbeat file inside the library, and TextMouth warns when another Mac used it in the last few minutes.
  - A `dataDirectoryPath` that arrives from another Mac is ignored.
  - No leftover-folder cleanup can touch another Mac's work.
  - Merging and conflict recovery come in the polish phase.
- **Unchanged pieces:**
  - The S10 migration guard stays in place.
  - Moving out of a cloud folder is refused while some books aren't downloaded; the user downloads them first.
  - On macOS 26, iCloud Drive reports fail-on-conflict uploads (sync controls value 3), and Google Drive and Dropbox report pause only (value 1). Using that for `library.json` is polish, because the app targets macOS 14.

## 5. Working-draft plan: parallel agents, hours not weeks

**Sequencing:**
- **Start after the current wave merges:** Q06 (warnings, which can touch many files), P05 (`completion`, which owns `ReaderViewModel+Playback.swift` and `AudioPlaybackService.swift`), `logtail` (which edits `ArchiveExtraction`'s logging) and `pdftext`.
- **Run S04 first if possible.** Its storage-generation boundary sits under the same executors that `datadir`, `cloudmaint` and `storagemove` touch. If S04 runs later, it rebases on this work.
- **Step 0, the contract (about 45 minutes):**
  - The `cloudcore` agent's first commit adds the shared contract (`briefs/cloud/CloudStorageContract.swift`) and the test doubles (`briefs/cloud/CloudTestDoubles.swift`), verbatim, with a smoke test.
  - The orchestrator merges that commit, then launches wave 1 from the new main.
  - Fallback: a task that starts earlier copies both files verbatim. Identical additions merge cleanly; the pbxproj is regenerated.
  - I type-checked both files against stubs in Swift 5 mode with complete concurrency checking and warnings as errors, and in Swift 6 mode. Both pass, and the dataless helper behaved correctly at run time.
- **Wave 1, five agents (about 4–6 hours of wall-clock time, sharing three build slots):**

  | Slug | Task | Agent effort |
  | --- | --- | --- |
  | `cloudcore` | Status provider, book storage service (state, download stream, remove download), installation at launch | 2–3 h after Step 0 |
  | `datadir` | Identity marker and bookmark, availability gate and unavailable screen, never creating a missing root, unmount handling, logs on this Mac, `dataDirectoryPath` guard, two-Mac warning | 4–5 h |
  | `cloudmaint` | Maintenance, statistics, fingerprints and launch repair never download; extraction and staging on this Mac | 2–3 h |
  | `cloudlist` | List notes, Download Now, Remove Download, Show in Finder, VoiceOver actions, summary count, Book Info off the main thread | 3–4 h |
  | `clouddownload` | Reader download view with progress, Cancel and Retry, offline errors, working copy, chapter checks | 4–5 h |

- **Merging:**
  - Order: `cloudcore` (if Step 0 was skipped), then `datadir`, `cloudmaint`, `cloudlist`, `clouddownload`.
  - Each brief names its regions to avoid. The only expected conflicts are `project.pbxproj` (regenerate it) and neighboring functions in `LibraryViewModel+Migration.swift`: `cloudmaint` owns the maintenance functions, and `storagemove` later owns the move functions.
- **Wave 2, two agents (about 3–4 hours):**
  - `storagemove`, after `datadir`: any-folder chooser, Move Library Here and Use This Library (with relaunch), destination assessment (cloud, external, size), the move off the main actor with progress and Cancel, and refusing to move out of the cloud while books are evicted.
  - `cloudtests`, after `cloudcore`: opt-in hosted tests against throwaway folders on real drives, plus the manual matrix below.
- **Total for a working draft:** about one long day of wall-clock time.
- **The briefs**, in `scratchpad/briefs/cloud/`:
  - `task-cloud-core.md`
  - `task-cloud-datadir.md`
  - `task-cloud-maintenance.md`
  - `task-cloud-list.md`
  - `task-cloud-reader-download.md`
  - `task-cloud-storage-settings.md` (wave 2)
  - `task-cloud-real-drive-tests.md` (wave 2)

  The contract they share is `CloudStorageContract.swift`, with `CloudTestDoubles.swift`. Each brief quotes, verbatim, the declarations it uses.

**Polish phase (about 1–2 days, parallel):**
- **Several Macs:**
  - Detect conflicts: `NSFileVersion` for iCloud, and sibling copies of `library.json` for Google Drive and Dropbox.
  - Reconcile library rows with package records, newest revision first.
  - One statistics file per Mac.
  - Package-relative paths in `library.json`.
- **"Keep on This Mac":** an app-enforced pin that downloads the book again if it is evicted while TextMouth runs.
- **Library menu commands** with shortcuts for Download Now and Remove Download.
- **Download ahead:** fetch the next book in the folder before Continue to Next Book needs it.
- **Byte progress** within one file, if `Progress.addSubscriber(forFileURL:)` turns out to work [19].
- **Migration staging:** build the copy outside the cloud folder and rename it in, or exclude it from sync with `ubiquitousItemIsExcludedFromSync` [20].
- **Working copies for external drives.**
- **macOS 26 sync controls** for `library.json` on iCloud Drive.
- **Docs:** README and ARCHITECTURE, plus a full VoiceOver and braille pass on every drive.

## 6. Manual test matrix (this Mac: iCloud Drive, Google Drive streaming, Dropbox; a small library first)

Run each row on each drive unless it names one. Record what VoiceOver and the braille display say.

1. **Move a small library into the drive's folder, then back.**
   - Expect: the size and destination warning, progress, a working library afterwards, and a refusal to move back while books are evicted.
2. **On a second Mac or user account, choose Use This Library on the cloud folder.**
   - Expect: the library opens, notes read "In Cloud", and books download on open.
3. **Remove Download on several books (a selection), then check free space.**
   - Expect: notes change to "In Cloud" and the Finder status matches.
4. **Open an evicted text book and an evicted audiobook with Wi-Fi on.**
   - Expect: progress, announcements, then playback.
5. **Repeat with Wi-Fi off.**
   - Expect: an immediate offline message with Try Again, no beachball; Try Again works once Wi-Fi is back.
6. **Slow network (Network Link Conditioner) with a large audiobook.**
   - Expect: indeterminate or file-count progress, Cancel works, the UI stays responsive.
7. **While an audiobook plays from the cloud library, use Finder's Remove Download on it, then turn Wi-Fi off.**
   - Expect: playback continues from the working copy to the end.
8. **Quit Google Drive, or pause syncing, then open an evicted book.**
   - Expect: a stall or provider message, no hang.
9. **Unplug an external drive holding the library while TextMouth runs, then launch with it unplugged.**
   - Expect: the unavailable screen, Try Again after replugging works, nothing created in `/Volumes`.
10. **Sign out of Dropbox (or rename the library folder) and launch.**
    - Expect: the unavailable screen; no new library appears in `~/Library/CloudStorage`.
11. **Two Macs or accounts open the same cloud library.**
    - Expect: the warning on the second; nothing deleted on either.
12. **Optimize Mac Storage with a nearly full disk.**
    - Expect: evicted books show "In Cloud"; startup maintenance downloads nothing (no new `MAINTENANCE_SKIPPED_IN_CLOUD` surprises in the log).

## What I could not verify

- **Real-drive behavior** (the `cloudtests` spike settles these):
  - Whether `startDownloadingUbiquitousItem` and `evictUbiquitousItem` work on Google Drive and Dropbox.
  - Whether `Progress.addSubscriber` receives download progress.
  - Whether an APFS clone keeps its data after the original is evicted.
  - Whether renaming a staged package into a File Provider folder publishes it as one item.
  - Whether modification times survive eviction.
  - Whether Google Drive syncs dot-folders.
- **Not documented anywhere I found:** whether the system's low-space eviction skips files that are open, and how long Google Drive keeps streamed files.

## Sources

1. Apple, Store files in iCloud Drive on Mac: https://support.apple.com/guide/mac-help/mchle5a61431/mac
2. Apple, Optimize storage space on your Mac: https://support.apple.com/guide/mac-help/sysp4ee93ca4/mac
3. Apple, Work with folders and files in iCloud Drive: https://support.apple.com/guide/mac-help/mchl1a02d711/mac
4. Google, Use Drive for desktop on macOS: https://support.google.com/drive/answer/12178485
5. Google, Customize Drive for desktop settings: https://support.google.com/drive/answer/13470231
6. Google, Manage Google Drive for desktop: Advanced guide: https://support.google.com/drive/answer/16631477
7. Google, Stream and mirror files with Drive for desktop: https://support.google.com/drive/answer/13401938
8. Dropbox, Free up space with online-only files: https://help.dropbox.com/sync/make-files-online-only
9. Dropbox, Expected changes with Dropbox for macOS on File Provider: https://help.dropbox.com/installs/macos-support-for-expected-changes
10. Apple SDK header `FileProvider/NSFileProviderManager.h`, `evictItemWithIdentifier:completionHandler:` (`EBUSY` with open file descriptors; unsynced edits).
11. Apple SDK header `FileProvider/NSFileProviderItem.h`, `NSFileProviderContentPolicy` (download lazily; eviction on low disk pressure; keep downloaded).
12. Apple, Synchronizing the File Provider Extension: https://developer.apple.com/documentation/fileprovider/synchronizing-the-file-provider-extension
13. Apple, About Apple File System (clones): https://developer.apple.com/documentation/foundation/about-apple-file-system
14. Apple, TN3150: Getting ready for dataless files: https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files
15. Dropbox, How to set a file or folder to be ignored: https://help.dropbox.com/sync/ignored-files
16. Apple, URL.bookmarkData(options:includingResourceValuesForKeys:relativeTo:): https://developer.apple.com/documentation/foundation/url/bookmarkdata(options:includingresourcevaluesforkeys:relativeto:)
17. Apple, NSWorkspace.didUnmountNotification: https://developer.apple.com/documentation/appkit/nsworkspace/didunmountnotification
18. Apple, URLResourceValues.ubiquitousItemDownloadingStatus: https://developer.apple.com/documentation/foundation/urlresourcevalues/ubiquitousitemdownloadingstatus
19. Apple, Progress.addSubscriber(forFileURL:withPublishingHandler:): https://developer.apple.com/documentation/foundation/progress/addsubscriber(forfileurl:withpublishinghandler:)
20. Apple, URLResourceValues.ubiquitousItemIsExcludedFromSync: https://developer.apple.com/documentation/foundation/urlresourcevalues/ubiquitousitemisexcludedfromsync
21. Apple, NWPathMonitor: https://developer.apple.com/documentation/network/nwpathmonitor

# A local-first library with a safer cloud library: research and design (November 13, 2026)

You are `localfirst`, an Opus designer. You write a research and design document; you change no code. First read `common.md` beside this brief and follow its rules (you make no branch and no commits; the orchestrator commits your document).

## The user's words

On November 13, 2026, at about 01:05:

> "I am starting to to think if it would be a better idea to refactor the library system so that a full set json and book data would be stored locally always with just pointers to the cloud library like paths or symbolic links (not sure how that sould work on IOS), which would also have the full data on the books to be eventually sinked? My thought being we could have some books perdimently local but maybe build the Cloud libary to be safer so we can delete the local copy to save space eventually."

In the same message, a smaller wish another agent is building now: "if the main library is in the cloud keep all the reading list books downloaded" (`rlkeep.md` beside this brief).

So the user is weighing, not deciding. Your document is what they decide from: plain, honest about cost and risk, with a recommendation.

## What exists

- **Today's design:** TextMouth's whole data directory (library.json, config.json, the book packages under `Library/`, feeds, statistics) can live in a cloud drive's folder (iCloud Drive, Google Drive, Dropbox), and the drive's File Provider fetches and evicts files; this Mac keeps only its own choices (`Kept Books.json`, through `MachineLocalPaths`). Read, in the main checkout: `CLOUD-STORAGE-RESEARCH-2026-10-03.md`, `CLOUD-STORAGE-PLAN-2026-10-03.md`, `CLOUD-STORAGE-MANUAL-TESTS-2026-10-03.md`, `docs/user/cloud-library.md`, `docs/user/where-your-library-lives.md`, and `docs/architecture/state/cloud-state.md`, `data-directory.md`, `library-index.md`, `package-records.md`, and `saving-failures.md`; then the code they name (`LibrarySessionLease`, `KeptBooks`, `LibraryCloudRefresher`, `CloudStorageContract`, the data directory move).
- **What went wrong before:** in early November the user moved their library to Google Drive and back, and the two copies diverged, with no merge (the orchestrator's memory; say so as "reported"). The triage of November 13 noted that a feed's record is written whole, so two Macs overwrite each other (`FeedStore.writeRecord`). Find any other places where two Macs, or a slow sync, can lose or garble data today.
- **The iPhone** target shares the code (`docs/architecture/platforms.md`, `IOS-PORT-RESEARCH-2026-11-03.md`), and its own library questions are in `humanQuestions/2026-11-03.md` and later files.

## Questions your document answers

1. **Today's risks, ranked:** where the current design can lose data, corrupt the index, or leave the user waiting, with evidence (file and line, or the cloud tests).
2. **The options**, at least:
   - **A.** Today's design, made safer: TextMouth's small files (library.json, each package's records, `content.md`, the indexes, config) always kept downloaded, only big files (audio, original books) offloadable, plus the fixes risk 1 finds.
   - **B.** The user's idea: a full local library on each device, the cloud library as a synced store with every book's full data, pointers from local to cloud, books kept locally by choice, and a local copy deleted only once the cloud copy is proven safe.
   - **C.** Anything better you find, for instance CloudKit or an iCloud ubiquity container for the index and records, with files in the drive.
3. **Pointers:** why symbolic links do or don't work (how iCloud Drive, Google Drive for desktop, and Dropbox each treat a symbolic link; what iOS allows: a sandboxed app can't link into another container), and what to use instead (relative paths from a library root the user granted, security-scoped bookmarks, content fingerprints).
4. **Sync:** what decides which copy is newer, how two devices' changes to places, bookmarks, the reading list, edits, and feeds merge without loss, how deletions travel (tombstones), and what an older TextMouth does with the new layout.
5. **"Safer so we can delete the local copy":** exactly what proves a cloud copy complete before a local copy goes (the provider's upload state, a fingerprint read back, a size and hash in the record), and what the user hears.
6. **Apple's and the drives' APIs** for this, from primary sources only (Apple's documentation for `NSFileCoordinator`, `NSFilePresenter`, `FileManager.startDownloadingUbiquitousItem(at:)`, `evictUbiquitousItem(at:)`, the `ubiquitousItem…` resource keys, File Provider pinning on current macOS and iOS, CloudKit; Google's and Dropbox's own help pages for their desktop apps). Say for each what you verified and what you could not.
7. **The cost:** a phased plan with each phase's size, what it delivers on its own, its tests (a stand-in cloud, two simulated devices, interrupted syncs), and the migration of the user's existing library (never in place without a copy; the user's own library is local at `~/.TextMouth` today, 11 GB).
8. **Your recommendation**, and the questions for the user, each with the answer you recommend.

## Rules

- **The live library:** never read, stat, or copy `~/.TextMouth`, anything under `~/Library/CloudStorage/`, or any data directory the settings name. Never search from `/` or the home folder.
- **Web research:** prefer Apple's documentation and the providers' own help pages. Keep a Sources list with links.
- No `rm`. No builds. No code changes.
- The user said today: "don't worry about the usage limit that much, I want to use it all up". Keep working until you finish, whatever a usage script says.

## Your output

Write `LOCAL-FIRST-LIBRARY-RESEARCH-2026-11-13.md` in the main checkout's root (`/Users/roberteggleston/programming/ai/claude/swift/TextMouth/`), plain Markdown, with a summary of at most 15 lines at the top that a listener can take in by ear. If you can't write there, put the whole document in your final message. Your final message is its summary, at most 40 lines, also saved as `build/orchestrator/nov13/localfirst-report.md`.

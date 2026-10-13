# polish2-datadir: Library Not Available names the library's files, not only its index

- Team `polish2`; lead `polish2-lead`; your task is number 10 on the team's list.
- Your slug is `polish2-datadir`. Your branch is `polish2/datadir`, made with `git checkout -b polish2/datadir team/polish2`. Your worktree may start on an old commit, so branch from `team/polish2` exactly so.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- Register, joining the team, then mark your task started:

      bbs register polish2-datadir --role "Library Not Available names the library's files" --branch polish2/datadir --files TextMouth/Services/DataDirectoryAvailability.swift TextMouthProductionTests/DataDirectoryAvailabilityTests.swift TextMouthProductionTests/LibraryFeedIndexCloudTests.swift --team polish2
      bbs task move polish2-datadir 10 working

- This brief gives you what you need. Read only the line ranges it names, once each.
- It closes two TODO items that are one defect: "the not-downloaded reason says "library index" when it waits for a feed's index" (line 3122) and "Library Not Available always blames "the library index", even when only a feed's index or folder is in the cloud" (line 3126).

## What is wrong
When the data directory is in a cloud drive, the launch waits until everything it reads at once is on this Mac: the identity marker, library.json, the Feeds folder, and each feed's folder and index (`assessLibrary(in:itemStatus:)`, `TextMouth/Services/DataDirectoryAvailability.swift` lines 481 to 506, with `feedIndexFiles(in:)` at lines 558 to 575). Whichever of them is only in the cloud, the screen says the same thing, `DataDirectoryUnavailability.notDownloaded`'s explanation (line 234):

    The library index is in Google Drive and isn't on this Mac yet.

So a listener whose library.json is here, but whose feed's index is not, hears a wrong reason. The debug log's wording (`logDescription`, the `.notDownloaded` case at line 272 to 273) says "the library index" too.

## Do
1. **The explanation** (line 234) becomes, word for word:

       Some of the library's files are in <provider> and aren't on this Mac yet.

   with `<provider>` as today: `provider?.displayName ?? "the cloud"`.
2. **The log's wording** (line 273) becomes:

       some of the library's files in <name> are only in <provider>; asked to download them

3. **The comments** say what is waited for:
   - the `notDownloaded` case's doc comment (lines 198 to 200): the identity marker, library.json, or a feed's folder or index is only in the cloud, and TextMouth asked the sync service for it;
   - `notDownloaded(_:in:itemStatus:)`'s doc comment (lines 544 to 545), which says "the library's index or identity marker": the same list.
4. Nothing else changes: not the enum's cases, not what is checked, not what is asked for.
5. **One commit**, ending with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Tests
- `TextMouthProductionTests/DataDirectoryAvailabilityTests.swift` pins the old explanation at line 232 (in `testAnIndexOnlyInTheCloudIsAskedForAndWaitedFor`) and line 288 (the table of every reason's explanation). Change both to the new wording.
- `TextMouthProductionTests/LibraryFeedIndexCloudTests.swift` holds the class `LibraryFeedIndexCloudCheckTests` (the class name differs from the file's). Its first test, `testAFeedIndexOnlyInTheCloudIsAskedForAndWaitedFor` (from line 17), waits for a feed's index alone. Add to it an assertion on the explanation the listener hears in that case: the reason in its outcome is `.notDownloaded`, so assert `DataDirectoryUnavailability.notDownloaded(.iCloudDrive, folder: library.root.path).explanation` equals the new wording, and that it does not contain "library index". Read lines 17 to 30 first, to fit its style.
- If a test elsewhere pins the log wording, grep once (`grep -rn "library index in" TextMouthProductionTests`) and change it; if none does, add one line to the table test or beside it pinning `logDescription` for `.notDownloaded`.

## Build and test
- Run only `DataDirectoryAvailabilityTests` and `LibraryFeedIndexCloudCheckTests`.
- Start each build in the background, and check on it no more often than every 4 minutes, with one short command.
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish2-datadir-…`.

      BBS_AGENT=polish2-datadir .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath "${TMPDIR}TextMouth-DerivedData-polish2-datadir" -only-testing:TextMouthProductionTests/DataDirectoryAvailabilityTests -only-testing:TextMouthProductionTests/LibraryFeedIndexCloudCheckTests > /private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/polish2-datadir-build-1.log 2>&1

- Read a result with `grep -E "Executed [0-9]+ tests|error:|failed \(" <log> | tail -20`.

## Do not touch
- Any other app file, and any other test file.
- Any `*.md` file. (README.md may quote the old wording; the lead reports that to the orchestrator.)

# polish3-removedue: a feed rule's file removal runs as storage work

- Team `polish3`; lead `polish3-lead`; your task is number 17 on the team's list.
- Your slug is `polish3-removedue`. Your branch is `polish3/removedue`, made with `git checkout -b polish3/removedue team/polish3`. Your worktree may start on an old commit, so branch from `team/polish3` exactly so.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- `bbs` is `python3 .claude/skills/agent-bbs/scripts/bbs.py`, run from your worktree root. Write it out in full: the worktree guard refuses a command kept in a variable. Register, joining the team, then mark your task started:

      python3 .claude/skills/agent-bbs/scripts/bbs.py register polish3-removedue --role "A feed rule's file removal runs as storage work" --branch polish3/removedue --team polish3 --files TextMouth/Services/StorageGeneration.swift TextMouth/Services/Feeds/FeedLifecycle.swift TextMouthProductionTests/FeedTestSupport.swift TextMouthProductionTests/FeedLifecycleTests.swift TextMouthProductionTests/LogContentPolicyTests.swift TextMouthProductionTests/StorageGenerationWorkTests.swift
      python3 .claude/skills/agent-bbs/scripts/bbs.py task move polish3-removedue 17 working

- This brief gives you what you need. Read only the line ranges it names, once each.
- It closes the TODO's "`FeedLifecycle.removeDue` not registered as storage work (`FeedLifecycle.swift:510`)".

## The problem
`FeedCenter.removeDue(_:from:by:at:putOffEvent:)` (`TextMouth/Services/Feeds/FeedLifecycle.swift`, doc comment from about line 478, function lines 510 to 570) is how the engine's rules (delete after played, and keep the newest N) delete feed items' downloaded files. Its step 3 (lines 544 to 556) removes the files on the import queue through `FeedDownloadManager.runBesideImports(_:)` (`FeedDownloadManager.swift` 761 to 774), which is not storage work. So a data-directory move neither waits for a removal under way nor holds a removal off while it copies: files can go from the old data directory in the middle of a move. It also reads `TextMouthPaths.root` (line 545) before it waits for the queue, so a removal queued across a move would use the old root.

Confirm it is still open first: `grep -n "runBesideImports\|let root = TextMouthPaths.root\|perform(" TextMouth/Services/Feeds/FeedLifecycle.swift` shows the first two and no `perform(`.

## What to build
1. **A kind of storage work.** In `TextMouth/Services/StorageGeneration.swift`, `enum StorageWork` (lines 34 to 79), add `case removingFeedDownloads` after `savingFeeds`, with a doc comment in its neighbours' style: the engine's rules deleting feed items' downloaded files (`FeedCenter.removeDue`). Its `waitingMessage` is `"Waiting for feed downloads to be deleted..."`, three periods as the others. A move names the first kind of work under way in `allCases` order, so keep it last.
2. **The removal as that work.** In `removeDue`, inside the closure passed to `downloads.runBesideImports`, run the removal loop inside `boundary.perform(.removingFeedDownloads, whileHeld: { … }) { _ in … }`, returning the failures as now. Take `let boundary = environment.boundary` before the closure, which is `@Sendable` (`environment` is `FeedCenter`'s; its `boundary` is at `FeedCenter.swift` line 39). Read `TextMouthPaths.root` inside the `perform` body instead of at line 545: it is the current generation's root (`TextMouthPaths.swift` 68 to 74), so a removal held across a move removes from where the library is now. Ignore the generation `perform` passes (`{ _ in`), as every other caller does, `importAndCommit` among them (`FeedDownloadManager.swift` 786 to 810).
3. **The wait, logged.** `whileHeld` runs once, before the wait, only when a move holds the work (`StorageBoundary.perform` and `begin`, `StorageGeneration.swift` 304 to 345). Make it write `DiagnosticLog.event(.feeds, "FEED_DOWNLOAD_DELETE_WAITING: storage work is held, so the deletions by \(rule) wait")`.
4. **The tag listed.** `TextMouthProductionTests/LogContentPolicyTests.swift` lists every event tag in `eventTags` (lines 265 to 312). Add `"FEED_DOWNLOAD_DELETE_WAITING"` beside `"FEED_DOWNLOAD_DELETE_REFUSED"` (line 311). Read lines 370 to 400 to see what its tests do with the list.
5. **The doc comment.** In `removeDue`'s doc comment, the paragraph beginning "No rule's removal races" (lines 501 to 507) says the files' removal runs on the import queue. Add that it runs there as storage work (`StorageWork.removingFeedDownloads`): a data-directory move waits for a removal under way, and a removal waits while a move holds the work, then removes from the data directory as the move left it.

## Tests
- **The world's own boundary.** `FeedTestWorld` (`TextMouthProductionTests/FeedTestSupport.swift`; its init's doc comment and parameters are lines 495 to 511) passes `boundary: .shared` to its `FeedEnvironment` (line 564). Add an init parameter `boundary: StorageBoundary = .shared` after `recordsBoundary`, say what it is for in the doc comment beside `recordsBoundary`'s sentence, and pass it at line 564. Never hold `.shared` in a test: every later test would wait on it.
- **New test in `FeedLifecycleTests`** (`TextMouthProductionTests/FeedLifecycleTests.swift`), such as `testARulesRemovalWaitsWhileAMoveHoldsStorageWork`, modelled on `testAPlayedDownloadIsDeletedAfterTheSetDays` (lines 114 to 142) and `testAnItemOpenedDuringARulesRemovalStaysDownloading` (246 to 279):
  1. `let boundary = StorageBoundary(root: try makeSandboxDirectory("FeedRemovalHeld"))`, as `StorageGenerationWorkTests.makeBoundary()` does (line 224), and `FeedTestWorld(self, label: "FeedRemovalHeld", boundary: boundary)`.
  2. A downloaded episode (`downloadedEpisode(in:)`), then `FeedSettings.deleteDownloadsDaysAfterPlayedPreference.write(0, to: world.preferences)` and `world.center.markPlayed("guid:ep-1", of: feed.id)`.
  3. `let hold = try boundary.holdWork(for: .movingDataDirectory)` and `addTeardownBlock { hold.release() }`; a second release does nothing (`StorageWorkHold.release()`, `StorageGeneration.swift` 459 to 468).
  4. Count the waiting lines first, as line 121 counts the deleted ones with `debugLogLines(containing:)`. Then `let sweep = Task { await world.center.sweepPlayedDownloads() }` and `await waitFor("the removal waits for the move") { self.debugLogLines(containing: "FEED_DOWNLOAD_DELETE_WAITING").count > before }`.
  5. While it waits, the package is still there: `FileManager.default.fileExists(atPath: book.tmbDirectory.path)`.
  6. `hold.release()`, then `let report = await sweep.value`: `report.deletedBookIDs == [book.id]`, the package gone, and the item `.notDownloaded`.
- **The wording, pinned** in `StorageGenerationWorkTests` (`TextMouthProductionTests/StorageGenerationWorkTests.swift`): `StorageWork.removingFeedDownloads.waitingMessage` is `"Waiting for feed downloads to be deleted..."`, and `StorageWork.allCases.last` is `.removingFeedDownloads`. If a test there already lists every kind's message (`grep -n "waitingMessage" TextMouthProductionTests/StorageGenerationWorkTests.swift`), add it there instead.

## Commits
One commit, or two: the new kind of work with its wording test, then the removal, its log line, and its test. Each message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Build and test
- Run `FeedLifecycleTests`, `FeedNewestRuleTests` (the newest-N rule removes through `removeDue` too), `StorageGenerationWorkTests`, and `LogContentPolicyTests`, and nothing else.
- Start each build in the background, and check on it no more often than every 4 minutes, with one short command.
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish3-removedue-…`.

      BBS_AGENT=polish3-removedue .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-polish3-removedue -only-testing:TextMouthProductionTests/FeedLifecycleTests -only-testing:TextMouthProductionTests/FeedNewestRuleTests -only-testing:TextMouthProductionTests/StorageGenerationWorkTests -only-testing:TextMouthProductionTests/LogContentPolicyTests > /private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/polish3-removedue-build-1.log 2>&1

- Read a result with `grep -E "Executed [0-9]+ tests|error:|failed \(" <log> | tail -20`.

## Do not touch
- `FeedDownloadManager.swift` and every file not named above; add no new file, so `TextMouth.xcodeproj/project.pbxproj` stays as it is.
- Any `*.md` file.

## Finish
As "The worker's part" says: post `done: polish3/removedue` to `polish3-lead`, move task 17 to `review`, remove your build folder (unregistering its app first), release your claims, and reply with your report of at most 15 lines.

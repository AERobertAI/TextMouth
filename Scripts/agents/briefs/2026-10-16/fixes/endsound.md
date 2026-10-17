# fixes-endsound: a move's end and a chapter download's end wait for Where Am I?'s end sound

- Team `fixes`; lead `fixes-lead`; your task is number 46 on the team's list.
- Your slug is `fixes-endsound`. Your branch is `fixes/endsound`, made with `git checkout -b fixes/endsound team/fixes`. Your worktree may start on an old commit, so branch from `team/fixes` exactly so.
- First read `Scripts/agents/briefs/2026-10-16/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds". **Tonight the usage rule is overridden:** the user said to "max it out" before the weekly reset, so keep working until the API refuses you, whatever the usage reading says. The "Weekly (Fable)" window caps another model and does not apply. Commit each green step at once.
- `bbs` is `python3 .claude/skills/agent-bbs/scripts/bbs.py`, run from your worktree root. Write it out in full: the worktree guard refuses a command kept in a variable. Use `git -C <path>` rather than `cd … &&`. Register, joining the team, then mark your task started:

      python3 .claude/skills/agent-bbs/scripts/bbs.py register fixes-endsound --role "Where Am I?: audio waits out the end sound after a move or a chapter download" --branch fixes/endsound --team fixes --files TextMouth/ViewModels/ReaderViewModel.swift TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift TextMouth/ViewModels/ReaderViewModel+LibraryUpdates.swift TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift TextMouthProductionTests/ReaderCloudDownloadTests.swift TextMouthProductionTests/ReaderRefreshTests.swift
      python3 .claude/skills/agent-bbs/scripts/bbs.py task move fixes-endsound 46 working

- This brief gives you what you need. Read only the line ranges it names, once each, and what its tests lead you to.

## The problem (confirmed on `team/fixes` by the lead)
When a Where Am I? announcement ends by itself, `whereAmIAnnouncementFinished()` (`ReaderViewModel+WhereAmI.swift` about 526) clears `isWhereAmISpeaking`, plays the end sound, and schedules `resumeAfterWhereAmIEndSound()` (about 558) to run `whereAmIEndSoundDelay` (0.3 s, line 379) later. That later run resumes the book the announcement paused and starts the play or the chapter it held (`startPlayHeldByWhereAmI()`, `ReaderViewModel+Playback.swift` about 1646). In those 0.3 seconds nothing says an announcement still has the book, and two places start audio over the end sound because each tests only `isWhereAmISpeaking`:
- `resumeAudioAfterPackageMove()` (`ReaderViewModel+LibraryUpdates.swift` about 161 to 186): `guard !isWhereAmISpeaking` at line 176. A package move that ends in the window goes on to `restartAudioAtCursor(volume:)`.
- `downloadDidFinish(_:)`, the `.chapter` case (`ReaderViewModel+CloudDownload.swift` about 609 to 632): `guard !isWhereAmISpeaking` at line 624. A chapter download that ends in the window goes on to `playAudioChapter()`.

While an announcement SPEAKS both places hold the audio instead: they set `isChapterHeldByWhereAmI` and return, and the end sound's run plays it once. The window should hold it the same way.

`isWhereAmIResumePending` (`ReaderViewModel.swift` 365) does not cover the window: it is set only when the book was playing before the announcement (`wasPlayingBeforeWhereAmI`). A reader waiting for its chapter's download when W was pressed has nothing playing, so nothing pending, and its download is the case that matters most. The TODO says the fix "needs a flag set in `whereAmIAnnouncementFinished()` and cleared in `resumeAfterWhereAmIEndSound()`".

## What to build
1. **The state.** In `ReaderViewModel.swift`, beside `isWhereAmIResumePending` (365) and `isChapterHeldByWhereAmI` (388), add a documented stored property for the end sound still playing (suggested name `isWhereAmIEndSoundPlaying`). `whereAmIAnnouncementFinished()` sets it just before it schedules the end sound's work; `resumeAfterWhereAmIEndSound()` clears it first thing. Nothing else sets or clears it. An announcement the system cancels (`endWhereAmIWithoutResuming()`) plays no end sound and leaves it false.
2. **The test of it.** One computed property in `ReaderViewModel+WhereAmI.swift` (near `isWhereAmIUnderWay`, about 309), documented, true while an announcement speaks or its end sound plays: `isWhereAmISpeaking || isWhereAmIEndSoundPlaying`. Use it in place of `isWhereAmISpeaking` in exactly the two guards above, and nowhere else (the other `isWhereAmISpeaking` tests are about the announcement itself).
3. **The hold in the window.** A chapter download that finishes in the window, and a package move that ends in the window, hold the audio as they do while the announcement speaks (`isChapterHeldByWhereAmI = true`; the move keeps `audioPlaybackService.setVolume(paused.volume)`), and the end sound's run plays it once, after the end sound, with no play sound. Keep the trace lines' meaning, reworded for the window ("while Where Am I speaks or sounds its end").
4. **Comments.** Update the doc comments of `resumeAudioAfterPackageMove()`, `downloadDidFinish(_:)`, `whereAmIAnnouncementFinished()`, and `isWhereAmIUnderWay` where they say only "while it speaks", and the new property's own. Say what the window is and why a flag of its own is needed.
5. **Edge cases to check by reading, and to cover with a test where cheap:**
   - A reader stopped, or paused with Play/Pause, in the window: nothing held plays (`endWhereAmIAsTheBookStops()`, `stopWaitingForChapterDownload(because:)`). The flag stays true until the end sound's work runs and is harmless.
   - A reader closed in the window: the work holds `self` weakly, so nothing runs.
   - A second announcement started in the window: unchanged (it takes the resume over).
   - Where Am I? pressed again in the window with a chapter held: `cancelWhereAmIIfActive()` plays the held chapter at once, as it does while the announcement speaks (`testAChapterDownloadedDuringWhereAmIPlaysAtOnceWhenAPressEndsIt`).

## Tests to add (new methods in existing classes; no new test file)
Model them on the existing tests named here, which show the fixtures. None of the existing tests may change.
- `ReaderCloudDownloadTests`: model `testAChapterDownloadedDuringWhereAmIPlaysAsTheAnnouncementEnds` (about line 903) and its helper `chapterHeldForWhereAmI(in:)`. New: a reader waiting for its chapter's download, W pressed, the announcement ends by itself (`whereAmIDelegate?.speechSynthesizer(_, didFinish:)`), the end sound's clock (`WhereAmIEndSoundClock`, `IntegrationTestSupport.swift` about 438) not yet passed, and only then the download finishes: nothing plays, `isChapterHeldByWhereAmI` is true, the reader still shows Playing; after `passEndSound()` the chapter plays exactly once (`chapterPlaybackGeneration` up by one) and the only sound recorded is `.whereAmIEnd`.
- `ReaderRefreshTests`: model `testWhereAmIPressedDuringAMoveHoldsTheAudioUntilTheAnnouncementEnds` (about 478) and `testAnAudiobookWhoseFilesMoveDuringWhereAmIPlaysOnFromTheMovedPackage` (about 591). New: the announcement ends, the end sound has not passed, and then the move ends: the audio does not start; after `passEndSound()` it plays on from the moved package, once, at the volume it played at.
- A small test of the flag itself in one of those classes: false before; true after `whereAmIAnnouncementFinished()` with the clock held; false after `passEndSound()`; still false after an announcement the system cancels.
- **Prove each new behavior test fails without the fix.** After your commit: revert only the two production guards (`git checkout HEAD~1 -- <the production files>`), run the new tests alone (`-only-testing:TextMouthProductionTests/<Class>/<testName>`), see them fail for the right reason, then `git checkout HEAD -- <the production files>` so the tree is clean again. Report both results.

## Commits
Two commits, in order: (1) the state, the test of it, and the two guards, with the doc comments; (2) the tests. If the tests need a small helper, it goes with the tests. Each message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Build and test
Run these classes once after both commits, in one build: `ReaderCloudDownloadTests`, `ReaderRefreshTests`, `WhereAmIAnnouncementEndTests`, `FullSummaryReaderTests`, `ReaderChapterPauseTests`. Then the revert run described above. Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/8d971e15-7103-46cf-b45e-5c4d099f2f74/scratchpad/`, each named `fixes-endsound-…`. Start each build in the background and check no more often than every 4 minutes with one short command.

    BBS_AGENT=fixes-endsound .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-fixes-endsound -only-testing:TextMouthProductionTests/ReaderCloudDownloadTests -only-testing:TextMouthProductionTests/ReaderRefreshTests -only-testing:TextMouthProductionTests/WhereAmIAnnouncementEndTests -only-testing:TextMouthProductionTests/FullSummaryReaderTests -only-testing:TextMouthProductionTests/ReaderChapterPauseTests > /private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/8d971e15-7103-46cf-b45e-5c4d099f2f74/scratchpad/fixes-endsound-build-1.log 2>&1

Read a result with `grep -E "Executed [0-9]+ tests|error:|failed \(|\.swift:[0-9]+:[0-9]+: warning:" <log> | tail -20`. Your change must add no Swift warning. A failing existing test means stop and ask (`bbs post fixes-endsound --to fixes-lead --tag question --topic "…"`): never edit or work around it.

## Do not touch
- `ReaderViewModel+Playback.swift` and `ReaderViewModel+ReadingList.swift` (team feedopts owns them): if you think they need a change, post a finding with `--file`.
- Any existing test, any `*.md` file, any other test file, and `project.pbxproj` (add no new file).
- The meaning of `isWhereAmIUnderWay` and `whereAmIWillPlayBook`: a Play pressed in the window behaves as it does today.

## Finish
As "The worker's part" says: post `done: fixes/endsound` to `fixes-lead`; move task 46 to `review`; remove your build folder, unregistering its app first; release your claims; reply with your report of at most 15 lines.

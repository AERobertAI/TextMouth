# polish2-secondplay: a second Play while an audiobook waits for its chapter starts nothing anew

- Team `polish2`; lead `polish2-lead`; your task is number 15 on the team's list.
- Your slug is `polish2-secondplay`. Your branch is `polish2/secondplay`, made with `git checkout -b polish2/secondplay team/polish2`. Your worktree may start on an old commit, so branch from `team/polish2` exactly so.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- Register, joining the team, then mark your task started:

      bbs register polish2-secondplay --role "A second Play during a chapter download starts nothing anew" --branch polish2/secondplay --files TextMouth/ViewModels/ReaderViewModel+Playback.swift TextMouthProductionTests/ReaderCloudDownloadTests.swift --team polish2
      bbs task move polish2-secondplay 15 working

- This brief gives you what you need. Read only the line ranges it names, once each.
- It closes "a second AirPods Play on an audiobook waiting for its download makes the play sound again and begins a new chapter play (`playOrResume()`)" (TODO line 3144).

## What is wrong
An audiobook whose next chapter is only in the cloud waits for its files to download: the reader shows Playing, and the chapter plays once they are here (`isWaitingForChapterDownload`, `TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift` lines 541 to 549).

The AirPods' Play, and the media keys' Play, go to `playOrResume()` (`TextMouth/ViewModels/ReaderViewModel+Playback.swift`, about lines 150 to 176). For an audiobook it resumes a paused player, and otherwise calls `play()` whenever the player is not playing:

    if isAudioBook {
        if audioPlaybackService.isPaused {
            resumeAudioPlayback()
        } else if !audioPlaybackService.isPlaying {
            play()
        }
        return
    }

While the chapter downloads, the player is neither playing nor paused, so a second Play calls `play()` again: the listener hears the play sound a second time, and the chapter's play begins anew. The same holds while the library moves the book's package with its audio set aside (`audioPausedForMove`), when `play()` would start the audio from the files being moved.

`isPlaybackUnderWay` (same file, about lines 3071 to 3092; read its doc comment) already counts both waits as playback under way, as `playUnlessUnderWay()` (about lines 178 to 194) uses it. A text book needs nothing: `play()` already ignores a Play while its chapter's speech is prepared (`guard !isWaitingForChapterSpeech`, about line 46).

## Do
1. In `playOrResume()`'s audiobook branch, the `else if` becomes `} else if !isPlaybackUnderWay {`. Since that branch already knows the player is not paused, this still starts a stopped book, and leaves a book playing, waiting for its chapter's files, or waiting for its package's move as it is. Add a comment saying so, and that a second Play once played the play sound again and began the chapter anew (TODO line 3144).
2. Add one sentence to `playOrResume()`'s doc comment: an audiobook whose play is already under way (`isPlaybackUnderWay`) is left as it is.
3. Change nothing else: not `play()`, not the text-book branch, not Where Am I?'s guard at the top.
4. **One commit** with its test, ending with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Tests
In `TextMouthProductionTests/ReaderCloudDownloadTests.swift`, beside `testAutoPlayAfterABookmarkLeavesAChaptersDownloadToPlay` (lines 840 to 866; read it, and use its setup):
- **A second Play while the chapter downloads.** With `readerWaitingForSecondChapter(in:)`, give the reader a `RecordedSoundEffects` as `testAPlayAsWhereAmIEndsLetsAHeldChapterStartOnceAsTheEndSoundPasses` does (about lines 969 to 990), and note `reader.chapterPlaybackGeneration`. Call `reader.playOrResume()`. Then: no `.play` sound was made; `chapterPlaybackGeneration` is unchanged; the reader still waits for the chapter (`isWaitingForChapterDownload`), shows Playing and not paused; and no download was cancelled (`cloud.storage.downloadsCancelled` is empty). Then finish the download as the auto-play test does; the chapter plays, and it is "02.wav". End with `reader.stop()`.
- **A Play during a package move,** only if the file can hold a move partway: one `grep -n "audioPausedForMove" TextMouthProductionTests/ReaderCloudDownloadTests.swift`. If a test there holds the audio aside for a move, add the same check for a second Play during it (no play sound, nothing loaded from the moving files). If none does, add nothing and say so in your report.
- No test may play sound aloud: `RecordedSoundEffects` records instead.

## Build and test
- Run `ReaderCloudDownloadTests` and `MediaCommandPlaybackTests`.
- Start each build in the background, and check on it no more often than every 4 minutes, with one short command.
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish2-secondplay-…`. If the worktree guard refuses `${TMPDIR}`, write the folder's literal path, `/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-polish2-secondplay`.

      BBS_AGENT=polish2-secondplay .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath "${TMPDIR}TextMouth-DerivedData-polish2-secondplay" -only-testing:TextMouthProductionTests/ReaderCloudDownloadTests -only-testing:TextMouthProductionTests/MediaCommandPlaybackTests > /private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/polish2-secondplay-build-1.log 2>&1

- Read a result with `grep -E "Executed [0-9]+ tests|error:|failed \(" <log> | tail -20`.

## Do not touch
- `ReaderViewModel.swift` (another team's work is in it), `ReaderViewModel+WhereAmI.swift`, and any other app file.
- `TextMouth.xcodeproj/project.pbxproj`, which another team claims; add no new file.
- Any `*.md` file.

# Brief: `stable020-playback` (ST03, ST08)

- **Slug:** `stable020-playback`. **Branch:** `stable020/playback`, made with `git checkout -b stable020/playback team/stable020`. **Team:** `stable020`, lead `stable020-lead`.
- **Read first:** `Scripts/agents/briefs/2026-10-19/teams-common.md`, its sections "The worker's part", "Rules for everyone", "The board", "Builds", and "Lessons every brief applies". Nothing else of it.
- **Why:** two ways the user's place or play can go wrong before the official 0.2.0 install (`PLAN-0.2.0-2026-10-23.md` §3.2 items 3 and 8).
- **Register with:** `--files TextMouth/Services/SpeechService.swift,TextMouth/ViewModels/ReaderViewModel+Playback.swift,TextMouthProductionTests/PlaybackLifecyclePolicyTests.swift,TextMouthProductionTests/ReaderRefreshTests.swift`
- **Two commits:** ST03, then ST08, each with its tests.
- **Disk:** before every build, `df -g /System/Volumes/Data` must show at least 4 GB available; if not, post to `stable020-lead` and wait for an answer (`bbs watch stable020-playback --timeout 240`). Your build folder is `/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-stable020-playback`.
- **No test may play a sound.** The integration world's audiobooks are silent and its reader's audio service plays nothing aloud; use only those.

## Commit 1: ST03, Resume after a very quick Pause restarts the chapter
**The bug.** `SpeechService.resume()` (`TextMouth/Services/SpeechService.swift:1933-1940`) resumes from `currentWordRange?.location ?? madeAudioEngine?.currentCharOffset() ?? 0`. When Pause comes within about 0.3 seconds of Play, no word has been reported yet: in direct mode the engine's offset is not the speech being heard (it is 0, or stale), so the resume plays the chapter from its start, and the saved place follows. `speakDirect` (:1068-1086) records where the direct utterance being heard began, `directModeBaseOffset`.

**Do:**
1. Add to `SpeechService` one pure function, and use it in `resume()` for `offset`:
   ```swift
   nonisolated static func resumeOffset(
       reportedWord: NSRange?,
       usingDirectMode: Bool,
       directModeBaseOffset: Int,
       engineOffset: Int?
   ) -> Int
   ```
   It returns the reported word's location when there is one; otherwise, in direct mode, `directModeBaseOffset`; otherwise `engineOffset ?? 0`. Doc comment: what each case is (ST03), and that the direct utterance's start is where the listener pressed Play, snapped to its word, so a quick Play and Pause keeps the place.
2. `resume()` calls it with `currentWordRange`, `usingDirectMode`, `directModeBaseOffset`, and `madeAudioEngine?.currentCharOffset()`. Nothing else in `resume()` changes.

**Tests,** in `TextMouthProductionTests/PlaybackLifecyclePolicyTests.swift` beside its `SpeechResumePolicy` tests, a `// MARK: - The offset a resume starts from (ST03)`:
- `testResumeOffsetIsTheReportedWord`: `NSRange(location: 120, length: 5)`, direct, base 40, engine 900: 120.
- `testResumeOffsetBeforeAnyWordInDirectModeIsWhereTheUtteranceBegan`: nil, direct, base 500, engine 0: 500.
- `testResumeOffsetBeforeAnyWordIgnoresAStaleEngineInDirectMode`: nil, direct, base 500, engine 77: 500.
- `testResumeOffsetBeforeAnyWordInEngineModeIsTheEnginesOffset`: nil, not direct, base 0, engine 750: 750.
- `testResumeOffsetWithNothingKnownIsTheStart`: nil, not direct, base 0, engine nil: 0.

## Commit 2: ST08, Play during a move of the book's package
**The bug.** For an audiobook that was not playing when the library began moving its package, Play reads the moving files, since `pauseAudioForPackageMove()` (`TextMouth/ViewModels/ReaderViewModel+LibraryUpdates.swift:149-159`) sets aside only audio that plays. The result is a "damaged" failure; nothing is lost. The reader already knows a move is under way (`isPackageMoving`, :236-238), and audio set aside for a move (`audioPausedForMove`) plays on from the cursor at the move's end (`resumeAudioAfterPackageMove()`, :176-193), which runs after `LibraryBookUpdates.packagesDidMove(_:)` has closed the move's bracket, so `isPackageMoving` is false by then. A Pause or Stop during a move lets set-aside audio go (`letGoOfAudioSetAsideForMove(because:)`).

**Do:**
1. In `playAudioChapter()` (`TextMouth/ViewModels/ReaderViewModel+Playback.swift:2047-2075`), right after its `guard isAudioBook, let content = content, ... else { return }` and before `listenForAudioEnd(of: beginChapterPlay())`:
   ```swift
   if isPackageMoving, !playsFromWorkingCopy {
       if audioPausedForMove == nil {
           audioPausedForMove = AudioPausedForMove(volume: audioPlaybackService.intendedVolume)
       }
       DiagnosticLog.trace(.playback, "the chapter waits for the book's package to finish moving")
       return
   }
   ```
   with a comment: the book's package is moving (ST08), so its files are read only once the move is over; the play waits as playing audio set aside for the move does; the reader shows Playing, and the move's end plays the chapter from the cursor, from the package's new place; a Pause or Stop meanwhile lets it go.
2. Nothing else changes; nothing new is spoken. Check that `playAudioChapter()`'s doc comment still holds, and add one sentence to it about the wait.

**Tests,** in `TextMouthProductionTests/ReaderRefreshTests.swift`, in its section "Loading During a Package Move", using the class's own helpers (`makeIntegrationWorld`, `world.makeSilentAudioBook(title:trackDurations:)`, `world.openReader(for:)`, `waitForReaderToLoad(_:)`, `row(of:in:)`, `Self.folderPath(of:)`, `Self.standardizedPath(_:)`), as `testABookMovedWhileItLoadsOpensFromWhereItIsNow` uses them:
- `testPlayDuringAMoveWaitsForItsEndAndThenPlays`: load an audiobook of two 2-second tracks; `world.library.bookUpdates.packagesWillMove([book.id])`; `reader.play()`: the audio service has loaded nothing (`loadedURL` is nil) and `reader.isPlaybackUnderWay` is true; then `world.library.bookUpdates.packagesDidMove([book.id])`: the loaded URL's folder is the book's path, as the row has it; `reader.stop()`.
- `testAPauseDuringAMoveLetsAWaitingPlayGo`: the same up to `reader.play()`; then pause the reader (its Pause command, `pause()` or the one `togglePlayPause()` takes when playing); then `packagesDidMove`: nothing is loaded and `isPlaybackUnderWay` is false.

## Test classes to run
`PlaybackLifecyclePolicyTests`, `ReaderRefreshTests`, `MediaCommandPlaybackTests`, and the area holding the speech service tests (`python3 Scripts/test/run-area.py -h` lists the areas; pick the one with `SpeechService` in its description, or `playback`). Run `make lint-tests LINT_BASE=team/stable020` before you report.

## Do not touch
Any file not named above, `*.md`, and the transcripts team's files. A failing existing test means stop and ask your lead.

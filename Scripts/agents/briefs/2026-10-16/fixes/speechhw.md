# fixes-speechhw: the playback watchdog's idle recoveries are capped per place, and the audio engine's node calls and start failures reach the log

- Team `fixes`; lead `fixes-lead`; your task is number 47 on the team's list.
- Your slug is `fixes-speechhw`. Your branch is `fixes/speechhw`, made with `git checkout -b fixes/speechhw team/fixes`. Your worktree may start on an old commit, so branch from `team/fixes` exactly so.
- First read `Scripts/agents/briefs/2026-10-16/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds". **Tonight the usage rule is overridden:** the user said to "max it out" before the weekly reset, so keep working until the API refuses you, whatever the usage reading says. The "Weekly (Fable)" window caps another model and does not apply. Commit each green step at once.
- `bbs` is `python3 .claude/skills/agent-bbs/scripts/bbs.py`, run from your worktree root. Write it out in full: the worktree guard refuses a command kept in a variable. Use `git -C <path>` rather than `cd … &&`. Register, joining the team, then mark your task started:

      python3 .claude/skills/agent-bbs/scripts/bbs.py register fixes-speechhw --role "Direct speech: cap idle recoveries per place; audio engine node calls and start failures logged" --branch fixes/speechhw --team fixes --files TextMouth/Services/SpeechService.swift TextMouth/Services/AudioEngineService.swift TextMouthProductionTests/SpeechDirectChunkingTests.swift TextMouthProductionTests/AudioEngineBehaviorTests.swift
      python3 .claude/skills/agent-bbs/scripts/bbs.py task move fixes-speechhw 47 working

- This brief gives you what you need. Read only the line ranges it names, once each, and what its tests lead you to.
- Two independent parts, in two (or three) commits: Part 1 `SpeechService.swift`, Part 2 `AudioEngineService.swift`. Build once for both.

## Part 1: the playback watchdog's idle recovery has no cap (`SpeechService.swift`)

### The problem (confirmed on `team/fixes` by the lead)
`recoverFromIdleDirectSynthesizer(watchedUtteranceID:)` (about 1250 to 1292) recovers an utterance AVFoundation left idle without a finish: from rendered audio, by continuing at a nearly finished chunk's end, or, in its last branch, by restarting direct speech at the last reported word (`DIRECT_WATCHDOG_RECOVERY: … restarting direct speech at offset=…`). It counts nothing. An utterance that starts but goes idle before its first word is therefore restarted at the same offset again and again, each restart armed afresh by its own start, without end (never seen in a log). The START watchdog already has the cap this lacks: `directStartWatchdogRecoveriesPerPlace = 2` (808), the record `startStallRecoveries` of type `StartStallRecoveries` (821 to 829), `recoverFromUnstartedDirectUtterance()` (about 1307), and `pauseAfterStartStalls(at:)` (about 1345), which stops speech at the place as a pause, the cursor kept, tells the reader once through `onSpeechStalled` (or announces `voiceDidNotStartAnnouncement` itself with no reader), and clears the record.

The other half of the TODO line ("a retry's place record outlives the retry") is already fixed on main (`forgetRetryPlace(passedBy:)`, about 2382); leave it alone.

### What to build
1. **A cap.** `static let directIdleWatchdogRecoveriesPerPlace = 2`, documented beside the start watchdog's. At most that many idle recoveries at one place, which is the `safeOffset` the function already computes (the last reported word's start, else the chunk's base). The third idle at the same place pauses speech there instead of recovering, exactly as `pauseAfterStartStalls(at:)` does: same pause, same cursor, same `onSpeechStalled` call or announcement, same cleanup, so the listener hears the one wording that is pinned today (`voiceDidNotStartAnnouncement`). The count includes whichever branch recovered (all three).
2. **One bookkeeping type, one pause.** Do not copy: generalize `StartStallRecoveries` (a place and a count; give it a name that fits both) and use two instances, one per watchdog. Generalize `pauseAfterStartStalls(at:)` to take what differs: its log tag and wording, and the reason handed to `replaceDirectSynthesizer(after:)`. The start watchdog's existing log line, `DIRECT_START_STALLED: offset=… chunkEnd=… never started after 2 recoveries; speech paused there`, must stay byte for byte (a test pins it). The idle one is `DIRECT_IDLE_STALLED: offset=<n> chunkEnd=<m> went idle after 2 recoveries; speech paused there`, offsets only.
3. **When the idle count goes.**
   - When a word is reported strictly past the place (where `forgetRetryPlace(passedBy:)` is called from the word callback, about 2370): speech has moved on, so a later idle there is a new stall. A word AT the place is not past it (the restart at the last reported word speaks that word again).
   - When speech stops (`stop()`, about 1949 to 1972, where `startStallRecoveries = nil` is), and when the cap pauses speech there.
   - NOT when an utterance starts (`directUtteranceStarted(_:)`, about 1196): a start proves the synthesizer can start, not that it speaks, so it must not clear the idle count (the start watchdog's record does clear there; keep that).
4. **Play after the stall** (`resume()`) speaks from the place afresh (`pendingDirectSeekOffset`, as after a start stall) and the place has its two recoveries again.
5. Leave the three recovery branches' own behavior and their existing log lines as they are (tests pin them with `hasPrefix` and exact matches). You may add a count to a line only if every existing test on it passes unchanged.

### Tests to add (new methods in `SpeechDirectChunkingTests`, "The Watchdogs" section, about line 1170 on)
Model them on `testTheWatchdogSwitchesAnIdleSynthesizerToRenderedAudio` (about 1180) for an idle synthesizer and on `testAnUtteranceThatNeverStartsAfterTwoRecoveriesPausesSpeechThere` (about 1445) and `testWithNoReaderSpeechSaysItselfThatTheVoiceDidNotStart` (about 1493) for the cap. The harness: `ManualWatchdogTimers`, `makeDirectSpeech(watchdogTimers:)`, `report(start:to:)`, `report(word:of:to:)`, `handedOver(_:by:)`, `chunk(at:size:)`, `recordingAnnouncements`.
- Idle at one place twice: each recovery speaks again at the same offset; the third idle pauses speech there (`isSpeaking && isPaused`), `currentWordRange` at the place with length 0, nothing more handed over, no watchdog running, the reader told once (`onSpeechStalled`), speech says nothing over it, and the `DIRECT_IDLE_STALLED` line is logged (offsets only).
- Progress resets the count: recover once at a place; the restarted utterance reports a word past the place; idle again later: a recovery (count 1), not a pause.
- A start alone does not reset it: recover, the new utterance starts and reports no word, idle again, again, the third pauses.
- Play after the stall speaks from the place and the place has its recoveries again; `stop()` forgets the record.
- With no reader, speech announces `voiceDidNotStartAnnouncement` itself, once.
- **Prove the cap test fails without the fix** (see "Prove it" below).

## Part 2: B08's leftovers (`AudioEngineService.swift`)

### The problem (confirmed by the lead)
B08 put an Objective-C exception catcher (`ObjCException.catching`, `TextMouth/Services/ObjCException.swift`) around the player node's `play()` (`playNode()`, 659 to 669, which logs `SPEECH_PLAYER_EXCEPTION` through `DiagnosticLog.event(.playback, …, in: .speechTransitions)`) and around the stop after a failed start (`stopNodeCatchingExceptions()`, 673). The other node calls of `RenderedSpeechFeeder` run bare and could raise in the same glitch (the audio output has stopped cycling), which ends the app:
- `stopNode()` (618): `node.stop()`; `resetNode()` (627): `node.reset()`; `pauseNode()` (635): `node.pause()`.
- `startEngineIfStopped(for:)` (1226 to 1238) reports `engine.start()` failing with `print("AudioEngine could not start for \(purpose): \(error)")`, not the app's log.

### What to build
1. **One catching helper** in `RenderedSpeechFeeder`, used by `playNode()`, `stopNodeCatchingExceptions()`, `stopNode()`, `resetNode()`, and `pauseNode()` (DRY: the existing two keep their behavior and their log line, `SPEECH_PLAYER_EXCEPTION: <name>: <reason>`, exactly, since `AudioEngineBehaviorTests` pins it with `hasSuffix`). A raise in `stopNode()` or `resetNode()` still ends the play being fed first (`endPlay()`), so scheduled reports schedule nothing; a raise in `pauseNode()` changes nothing else. Each raise logs one `SPEECH_PLAYER_EXCEPTION` line. The engine's own state after a raising stop, reset, or pause is the same as after a normal one.
2. **A hosted-test seam** to make the node's stop, reset, and pause raise, beside `_playerStartForTesting` (1712, which stays as it is, since existing tests call it): one closure property or function taking the command and the node, nil as in the app. Comment it as the existing seam is.
3. **The start failure goes to the log.** Replace the `print` with `DiagnosticLog.event(.playback, "AUDIO_ENGINE_START_FAILED: could not start for \(purpose): \(error.localizedDescription)", in: .speechTransitions)` (a system error's words, never book text). If you add this tag, also add it to the `eventTags` list in `LogContentPolicyTests.swift` (about line 265 to 370, the "Every other tag" group): a list entry added, no test changed.

### Tests to add (new methods in `AudioEngineBehaviorTests`, beside `testAPlayerThatRaisesOnPlayLeavesTheEngineStopped`, about line 433)
Model them on that test and `testAPlayerThatRaisesOnResumeLeavesTheEnginePaused`; `logLines(in: .speechTransitions) { … }` reads the log.
- A node that raises as it pauses: no crash; `engine.pause()` leaves the engine paused, and one `SPEECH_PLAYER_EXCEPTION` line is logged.
- A node that raises as it stops: `engine.stop()` ends the engine's play (not playing, not paused), one line.
- A node that raises as it resets: `engine.play()` does not crash, one line, and the engine plays once the node does not raise.
- `_refusesToStartForTesting = true`: `engine.play()` plays nothing and logs `AUDIO_ENGINE_START_FAILED: could not start for a play`; `resume()` of a paused engine returns false and logs it for "a resume".
- **Prove the new tests fail without the fix** (see below).

## Prove it
Before you finish, for each part: after its commit, revert only that part's production file (`git checkout HEAD~1 -- TextMouth/Services/<file>`, with the commit number right for you), run its new tests alone (`-only-testing:TextMouthProductionTests/<Class>/<testName>`), see them fail for the right reason (or not compile, in which case say so), then `git checkout HEAD -- TextMouth/Services/<file>` so the tree is clean again. Report both results.

## Commits
(1) Part 1 with its tests; (2) Part 2's helper, seam, and log, with its tests (split into two commits if you like: the helper and seam; the start failure's log). Each message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. Comment every function and non-obvious block.

## Build and test
Run once after your commits, in one build: `SpeechDirectChunkingTests`, `AudioEngineBehaviorTests`, `PlaybackWatchdogTests`, `ObjCExceptionTests`, `LogContentPolicyTests`. Then the revert runs. Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/8d971e15-7103-46cf-b45e-5c4d099f2f74/scratchpad/`, each named `fixes-speechhw-…`. Start each build in the background and check no more often than every 4 minutes with one short command.

    BBS_AGENT=fixes-speechhw .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-fixes-speechhw -only-testing:TextMouthProductionTests/SpeechDirectChunkingTests -only-testing:TextMouthProductionTests/AudioEngineBehaviorTests -only-testing:TextMouthProductionTests/PlaybackWatchdogTests -only-testing:TextMouthProductionTests/ObjCExceptionTests -only-testing:TextMouthProductionTests/LogContentPolicyTests > /private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/8d971e15-7103-46cf-b45e-5c4d099f2f74/scratchpad/fixes-speechhw-build-1.log 2>&1

Read a result with `grep -E "Executed [0-9]+ tests|error:|failed \(|\.swift:[0-9]+:[0-9]+: warning:" <log> | tail -20`. Your change must add no Swift warning. **No test may play sound aloud**: keep the engine's volume at 0 as the neighbours do. A failing existing test means stop and ask (`bbs post fixes-speechhw --to fixes-lead --tag question --topic "…"`): never edit or work around it.

## Do not touch
- `ReaderViewModel*.swift` (the reader's `onSpeechStalled` handler, `ReaderViewModel+Playback.swift`, belongs to team feedopts): the announcement the reader makes stays as it is.
- Any existing test (except the one added list entry above), any `*.md` file, any other test file, and `project.pbxproj` (add no new file).

## Finish
As "The worker's part" says: post `done: fixes/speechhw` to `fixes-lead`; move task 47 to `review`; remove your build folder, unregistering its app first; release your claims; reply with your report of at most 15 lines.

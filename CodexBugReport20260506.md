# Codex Playback Bug Report - 2026-05-06

## Scope

Read-only investigation of the current `fix/playback-bugs` branch, focused on:

- TTS rewind/skip jumping farther than configured.
- Remote/headphone Play behaving differently from the in-app Play button.
- Audio continuing logically while output appears paused.
- Skipped/repeated words at boundaries.
- Sleep timer restart/start/fade behavior.
- Main-thread hangs while audio is playing, especially with VoiceOver.
- EPUB/DAISY paths that generate or consume `content.md`.

No production playback fixes were implemented in this investigation. The only intended file change is this report.

## Verification

- `make test`: passed, `1151/1151`.
- `make build`: passed, Release app built at `build/TextMouth.app`.
- Existing warnings are test/compiler warnings, not investigation blockers.

## Executive Summary

The strongest common pattern is that playback state is split across several coordinate systems and command paths:

- Direct TTS (`AVSpeechSynthesizer.speak`) and rendered-engine TTS (`AVSpeechSynthesizer.write` + `AVAudioEngine`) use different clocks.
- Remote Play uses a cold-start path while the in-app Play button uses a pause-aware resume path.
- TTS skip-by-time estimates seconds from text length instead of rendered audio time.
- Some DAISY segmented audio is likely treated as multi-file audio, which breaks chapter-relative offsets and clip boundaries.
- High-frequency position updates publish directly into SwiftUI, causing heavy text-window and accessibility tree churn while audio is playing.

There are several clear code bugs that should be fixed first before tuning smaller timing issues.

## Priority 1 - Remote Play Cold-Starts Instead Of Resuming

**Confidence:** High. This is a clear behavior split.

**Evidence:**

- `NowPlayingService.playCommand` calls `onPlay` directly: `TextMouth/Services/NowPlayingService.swift:190-202`.
- `ReaderViewModel.setupCallbacks` wires `onPlay` to `play()`: `TextMouth/ViewModels/ReaderViewModel.swift:343-348`.
- `ReaderViewModel.play()` always cold-starts `speakCurrentChapter()` or `playAudioChapter()`: `TextMouth/ViewModels/ReaderViewModel+Playback.swift:14-31`.
- The in-app button calls `togglePlayPause()`, which resumes paused services and applies TTS rewind-on-resume: `TextMouth/ViewModels/ReaderViewModel+Playback.swift:103-152`.

**Likely user-visible result:**

When AirPods/headphones send Play while the app is paused, the app does not take the same path as clicking Play in the UI. It can restart speech from `currentCharacterOffset` instead of resuming the paused audio service. If the offset has advanced due to a stale callback or direct-mode seek, clicking the in-app button later can appear to jump ahead as if the book was playing during the pause.

**Fix plan:**

1. Add a single directed `playOrResume()` method on `ReaderViewModel`.
2. If paused, use the same resume branch as the in-app Play button:
   - Apply rewind-on-resume for TTS.
   - Resume stats and sleep timer countdown.
   - Call `speechService.resume()` or `audioPlaybackService.resume()`.
   - Update Now Playing.
3. If stopped, cold-start with the existing `play()` logic.
4. Wire `NowPlayingService.onPlay` to `playOrResume()`.
5. Keep `togglePlayPause()` as a toggle, but make its play-side call the same helper.

**Tests to add:**

- Paused TTS + remote Play calls resume path, not `speakCurrentChapter()`.
- Paused audio book + remote Play calls `audioPlaybackService.resume()`, not `playAudioChapter()`.
- Rewind-on-resume is applied once for both in-app and remote Play.

## Priority 2 - Paused Direct TTS Seek Can Start Speaking Again

**Confidence:** High. The code path starts direct speech regardless of paused state.

**Evidence:**

- `SpeechService.seek(toCharOffset:)` falls back to direct mode when rendered audio is not ready: `TextMouth/Services/SpeechService.swift:442-449`.
- That fallback calls `speakDirect(...)`.
- `speakDirect(...)` immediately calls `directSynth.speak(utterance)`: `TextMouth/Services/SpeechService.swift:251-292`.
- `didStart` clears `isPaused`: `TextMouth/Services/SpeechService.swift:613-617`.

**Likely user-visible result:**

If the user seeks, skips, or rewind-on-resume triggers while direct TTS is paused and the rendered engine is not ready, the service can start a new direct utterance immediately. Word callbacks then keep advancing `currentCharacterOffset`, making the app's logical position move while the user thinks playback is paused.

**Fix plan:**

1. Preserve paused state in `SpeechService.seek`.
2. If paused and engine audio is not ready:
   - Stop the current direct synth if needed.
   - Store a pending direct offset.
   - Update `currentWordRange` logically.
   - Do not call `speakDirect` until `resume()`.
3. Make `resume()` consume the pending offset when still in direct mode.

**Tests to add:**

- Paused direct-mode seek does not call `directSynth.speak`.
- `isPaused` remains true after paused seek.
- `resume()` starts at the pending seek offset.

## Priority 3 - TTS Rewind/Skip Is Text-Time, Not Audio-Time

**Confidence:** High for the code behavior; medium for explaining every 60-second jump.

**Evidence:**

- TTS skip-by-time computes `charDelta` from whole-book estimated reading time and total characters: `TextMouth/ViewModels/ReaderViewModel+Navigation.swift:393-474`.
- Actual spoken text is transformed before speech by skipped sections, punctuation pauses, and substitutions: `TextMouth/ViewModels/ReaderViewModel+Playback.swift:213-227`.
- Rendered TTS is produced at a fixed internal rate and then speed-adjusted with `AVAudioUnitTimePitch`: `TextMouth/Services/AudioEngineService.swift:92-109`, `TextMouth/Services/AudioEngineService.swift:317-319`.

**Likely user-visible result:**

A configured 15-second rewind is only an estimate for TTS. It can drift badly when punctuation pauses, skipped sections, substitutions, voice behavior, or speed settings make spoken audio time diverge from raw text length.

**Fix plan:**

1. For rendered-engine TTS, add a seek-by-audio-seconds path based on rendered frames and sample rate.
2. Convert frame targets back to character offsets only after the audio-time seek target is known.
3. For direct TTS before render is ready, keep the current text/WPM estimate as fallback, but log that this path is approximate.
4. Use the transformed speech text's offset map, not raw chapter text, when a TTS skip lands.

**Tests to add:**

- TTS with punctuation pause level 3 rewinds near 15 seconds in rendered-engine mode.
- TTS with substitutions and skipped sections does not overshoot by large multiples.
- Direct-mode fallback is word-boundary safe and marked approximate.

## Priority 4 - AudioEngine Position Rate Correction May Over-Report Progress

**Confidence:** Medium. Needs empirical verification, but it exactly matches the "15 becomes about 60" shape at slow rates.

**Evidence:**

- `AudioEngineService.currentCharOffset()` divides `playerTime.sampleTime` by `timePitch.rate`: `TextMouth/Services/AudioEngineService.swift:359-379`.
- `timePitch.rate` is `wpm / renderWPM`, clamped from `0.25` to `4.0`: `TextMouth/Services/AudioEngineService.swift:317-319`.
- The scheduled segment is already in rendered-buffer frames: `TextMouth/Services/AudioEngineService.swift:238-249`.

**Risk:**

If `AVAudioPlayerNode.playerTime(forNodeTime:)` already reports progress in the scheduled buffer's frame timeline, dividing by a slow `timePitch.rate` over-reports position. At the minimum clamp of `0.25`, that is a 4x error: 15 seconds can become about 60 seconds.

**Fix plan:**

1. Add instrumentation or a small empirical test with a known rendered buffer at rates `0.25`, `0.5`, `1.0`, and `2.0`.
2. Compare:
   - Wall-clock elapsed time.
   - `playerTime.sampleTime`.
   - Expected source-frame progress.
   - Audible position.
3. If `sampleTime` is already source-frame progress, remove the division by `timePitch.rate`.
4. If the division is required on this platform, keep it but document the measured behavior and add regression coverage.

## Priority 5 - Direct TTS Chunk-To-Engine Handoff Can Skip Or Repeat Words

**Confidence:** High as a risk; likely as a direct cause of boundary glitches.

**Evidence:**

- Direct mode chunks at about 5,000 characters: `TextMouth/Services/SpeechService.swift:64-66`, `TextMouth/Services/SpeechService.swift:251-292`.
- Comments say the engine should not switch mid-playback: `TextMouth/Services/SpeechService.swift:172-215`.
- Actual `didFinish` logic switches from direct mode to engine when a direct chunk ends and rendered audio is ready: `TextMouth/Services/SpeechService.swift:638-650`.
- The engine maps characters to frames linearly, with about 200 sample points, not real speech boundary timing: `TextMouth/Services/AudioEngineService.swift:181-188`, `TextMouth/Services/AudioEngineService.swift:402-439`.

**Likely user-visible result:**

At the end of a direct chunk, the app switches to rendered-engine playback at `directModeChunkEnd`. Since direct speech callbacks and rendered speech frames are different clocks, the linear frame guess can land early or late by words. That explains repeated or skipped words at segment/chunk boundaries.

**Fix plan:**

1. Remove automatic `CHUNK_SWITCH` during continuous listening.
2. Keep direct chunking until a natural break:
   - User seek.
   - User pause/resume.
   - Chapter boundary.
3. Use the rendered engine only when the user action naturally accepts a seek/resume boundary.

**Tests to add:**

- A chunked direct utterance with rendered audio ready continues to the next direct chunk instead of switching to engine.
- No `CHUNK_SWITCH` event occurs during uninterrupted playback.

## Priority 6 - DAISY Segmented Audio Is Likely Misclassified

**Confidence:** High for segmented audio books where both `audioChapterFiles` and `audioSegments` are populated.

**Evidence:**

- `audioLayout` checks `audioChapterFiles` before `audioSegments`: `TextMouth/ViewModels/ReaderViewModel+Playback.swift:300-309`.
- `AudioBookParser.parseSegmentedAudio` returns both file paths and segments for segmented audio: `TextMouth/Parsers/AudioBookParser.swift:94-104`, `TextMouth/Parsers/AudioBookParser.swift:130-150`.
- `.segmented` layout is the only path that subtracts segment start time during position updates and sets clip-end boundaries: `TextMouth/ViewModels/ReaderViewModel+Playback.swift:357-368`, `TextMouth/ViewModels/ReaderViewModel+Playback.swift:446-453`.

**Likely user-visible result:**

Segmented DAISY books can be treated as `.multiFile`. That means:

- `chapterStartTime` returns `0` instead of `segment.startTime`.
- Clip end may not be set.
- Position updates store raw player time instead of segment-relative time.
- A chapter can start at the wrong point in a shared audio file, repeat earlier material, or play past its segment.

**Fix plan:**

1. Prefer `audioSegments` over `audioChapterFiles` in `audioLayout`.
2. In `playAudioChapter`, keep using the segment's file path but use segmented timing semantics.
3. Add a production-shaped test where both arrays are non-empty.

**Tests to add:**

- Both `audioSegments` and `audioChapterFiles` non-empty -> `.segmented`.
- `chapterStartTime(index)` returns `audioSegments[index].startTime`.
- `playAudioChapter()` sets `clipEndTime` for segmented audio.
- Position observer stores segment-relative offsets.

## Priority 7 - DAISY Segment Boundaries Can Overlap Or Truncate

**Confidence:** Medium-high.

**Evidence:**

- DAISY segment builders use the next nav/heading clip only if the next clip has the same `lastPathComponent`, otherwise they default to the current SMIL's last clip end: `TextMouth/Parsers/DAISYParser+Audio.swift:238-245`, `TextMouth/Parsers/DAISYParser+Audio.swift:354-360`.

**Likely user-visible result:**

If one SMIL references multiple audio files, or different directories contain files with the same basename, segment end times can be assigned from the wrong clip/file. That can repeat or skip audio around DAISY boundaries.

**Fix plan:**

1. Resolve canonical audio paths for each clip.
2. Compare canonical paths, not `lastPathComponent`.
3. Group clips by resolved audio file.
4. Pick the next clip start within the same resolved file.

**Tests to add:**

- Multiple audio files in one SMIL.
- Same basename in different directories.
- Monotonic, non-overlapping segment ranges per resolved audio file.

## Priority 8 - Sleep Timer Start/Reset/Restart Paths Diverge

**Confidence:** High.

**Evidence:**

- New timer selection auto-starts playback only when no timer was already active: `TextMouth/Views/Reader/SleepTimerView.swift:203-211`.
- Reset Timer only calls `restartSleepTimer()` and does not start playback or dismiss: `TextMouth/Views/Reader/SleepTimerView.swift:115-120`.
- `restartSleepTimer()` only calls `sleepTimerService.restart()`: `TextMouth/ViewModels/ReaderViewModel+Playback.swift:605-609`.
- Headphone/keyboard restart while active only restarts the timer and announces: `TextMouth/ViewModels/ReaderViewModel+Playback.swift:620-640`.

**Likely user-visible result:**

When a timer exists but playback is paused, replacing or resetting the timer can restart the countdown without starting playback. The sheet behavior also differs between choosing a new timer and pressing Reset.

**Fix plan:**

1. Add one view-model method, for example `armSleepTimer(duration:source:)`.
2. Use it for:
   - Preset/custom/end-of-heading/end-of-document buttons.
   - Reset Timer.
   - Keyboard restart.
   - Headphone gesture restart.
3. The method should:
   - Start or restart the service.
   - Recapture current fade settings when appropriate.
   - Ensure playback starts when user intent is "read until timer fires".
   - Honor the same auto-close policy for sheet-driven actions.
4. Make `.showSleepTimer` set `showSleepTimer = true` instead of toggling it, so a "show" command cannot close an already-open sheet: `TextMouth/Views/Reader/ReaderView.swift:243-249`.

**Tests to add:**

- Active timer + paused playback + new duration starts playback.
- Active timer + paused playback + Reset Timer starts playback if that is the chosen behavior.
- Active timer + headphone restart starts playback.
- Auto-close is consistent for new timer and reset.
- `.showSleepTimer` is idempotent.

## Priority 9 - Sleep Timer Fade Is Not Applied To Direct TTS

**Confidence:** High.

**Evidence:**

- Sleep timer fade steps call `speechService.audioEngine.setVolume(volume)` for TTS: `TextMouth/ViewModels/ReaderViewModel+Playback.swift:586-592`.
- TTS starts in direct synthesizer mode first: `TextMouth/Services/SpeechService.swift:176-189`.
- Direct `AVSpeechSynthesizer.speak()` output is not routed through `speechService.audioEngine`.

**Likely user-visible result:**

For common TTS playback, fade can appear to do nothing because the audible audio is coming from direct `AVSpeechSynthesizer`, not the engine mixer whose volume is being faded.

**Fix plan:**

1. Introduce a fade-capable playback abstraction:
   - Audio books -> `AudioPlaybackService`.
   - Engine TTS -> `AudioEngineService`.
   - Direct TTS -> either switch to engine before fade, or use a supported direct TTS volume strategy if available.
2. At sleep timer fade start, if TTS is still in direct mode and rendered audio is available, switch to engine at current offset before fading.
3. If rendered audio is not available, either:
   - Shorten behavior to immediate pause with no fake fade, or
   - Render a short tail before fade if that can be done without delaying expiry.

**Tests to add:**

- Direct TTS timer fade does not call only the engine volume path while direct audio is active.
- Engine-ready TTS fade switches to engine and fades.
- Audio book fade still uses `AudioPlaybackService.setVolume`.

## Priority 10 - Sleep Fade Duration And End Burst Have Multiple Causes

**Confidence:** High for direct causes; medium for exact timing under load.

**Evidence:**

- `SleepTimerService.restart()` preserves the old `fadeOutDuration`: `TextMouth/Services/SleepTimerService.swift:213-227`.
- New timers capture `settingsViewModel.sleepFadeOutDuration`: `TextMouth/ViewModels/ReaderViewModel+Playback.swift:569-595`.
- Fade uses a main-run-loop `Timer`: `TextMouth/Services/SleepTimerService.swift:340-372`.
- Timer expiry calls `pause()`: `TextMouth/ViewModels/ReaderViewModel+Playback.swift:573-584`.
- `pause()` plays the pause sound before pausing audio: `TextMouth/ViewModels/ReaderViewModel+Playback.swift:42-60`.
- Audio `load(url:)` calls `stop()`, and `stop()` resets tracked volume to `1.0`: `TextMouth/Services/AudioPlaybackService.swift:55-75`, `TextMouth/Services/AudioPlaybackService.swift:135-144`.

**Likely user-visible result:**

- Setting fade to 2 seconds may not affect an active timer reset because reset preserves the old fade duration.
- Direct TTS may not fade at all.
- Main-thread hangs can stretch fade timing because the fade timer runs on the main run loop.
- A full-volume sound or short burst can happen at expiry because `pause()` plays a non-faded pause sound and volume restore races with pausing/stopping.

**Fix plan:**

1. Define reset semantics:
   - If reset means "restart with current settings", call the same start path and recapture fade duration.
   - If reset means "preserve original settings", show that clearly in UI.
2. Use a monotonic clock or `DispatchSourceTimer`/async task for fade progress, not a main-run-loop timer.
3. Add `pause(playSound:)` and call `pause(playSound: false)` for sleep timer expiry.
4. Keep fade state true through the expiry callback or pass an explicit expiry reason.
5. Restore volume only after audio is confirmed paused/stopped.
6. Split audio teardown from user stop so internal reloads do not reset `currentVolume` during a fade.

**Tests to add:**

- Reset after changing fade setting uses the expected fade duration.
- Timer expiry suppresses pause sound.
- Volume remains low until audio is stopped.
- Main-thread load does not stretch a 2-second fade into a much longer fade.

## Priority 11 - Main Thread Churn During Playback Can Trigger VoiceOver "Not Responding"

**Confidence:** High.

**Evidence:**

- TTS direct mode posts every spoken word to main: `TextMouth/Services/SpeechService.swift:600-610`.
- TTS engine mode polls every 0.1 seconds and publishes word/offset updates: `TextMouth/Services/SpeechService.swift:486-533`.
- Audio books publish position updates on `.main` every 0.25 seconds: `TextMouth/Services/AudioPlaybackService.swift:290-305`.
- `ReaderViewModel.currentCharacterOffset` is `@Published`: `TextMouth/ViewModels/ReaderViewModel.swift:16`.
- `ReaderView` recomputes `visibleTextWindow` on each invalidation: `TextMouth/Views/Reader/ReaderView.swift:68-78`.
- `visibleTextWindow` builds new string indices from the beginning of the chapter and allocates a fresh substring: `TextMouth/ViewModels/ReaderViewModel.swift:684-710`.
- The info bar also recomputes progress/time/accessibility strings on redraw: `TextMouth/Views/Reader/ReaderView.swift:510-553`.
- Offset-map conversion is linear per callback: `TextMouth/Services/OffsetMap.swift:31-35`, `TextMouth/Services/OffsetMap.swift:93-99`.
- Punctuation pause preprocessing repeatedly indexes from `startIndex`: `TextMouth/ViewModels/ReaderViewModel+Playback.swift:761-825`.

**Likely user-visible result:**

Playback tick -> published offset -> full SwiftUI view invalidation -> text-window recomputation -> accessibility tree churn. VoiceOver then waits on the main thread and reports the app as not responding. Pausing stops the tick source, so the app appears to unfreeze.

**Fix plan:**

1. Split exact playback position from UI position:
   - Keep exact offset private/internal for saving/seeking.
   - Publish UI-facing offset at a coarse cadence, such as 1 Hz, or only when the visible window/heading/progress bucket changes.
2. Cache `visibleTextWindow` by chapter and window range.
3. Add hysteresis so the text window is not rebuilt until playback nears the edge of the current window.
4. Optimize `OffsetMap` lookups with binary search and optional last-index cache for monotonic playback.
5. Move next-chapter preprocessing off main.
6. Rewrite `applyPunctuationPauses` to iterate `String.indices` once.
7. Add `os_signpost` around playback callbacks, offset mapping, visible window generation, and `ReaderView.body`.

**Tests/instrumentation to add:**

- Performance test for 10,000 playback ticks over a 100k-character chapter.
- Assert UI publishes are throttled.
- Main-run-loop watchdog that logs stalls over 100-200 ms during playback.
- Reproduce with VoiceOver running and sample the main thread.

## Priority 12 - Stale Finish Guard In ReaderViewModel Is Ineffective

**Confidence:** High as a code bug; lower confidence that it is a common current symptom because `SpeechService` also filters live utterances.

**Evidence:**

- `onUtteranceFinished` captures `expectedGeneration` inside the finish callback, then compares it to the same current value: `TextMouth/ViewModels/ReaderViewModel.swift:282-292`.

**Risk:**

If any stale finish escapes lower-level filtering after a seek, rewind, stop, or chapter navigation, this guard will not stop a chapter advance. That can look like skipped content or a rewind being immediately undone.

**Fix plan:**

1. Capture playback generation when starting a chapter.
2. Pass or close over that token in the finish callback.
3. Ignore finishes whose token no longer matches `chapterPlaybackGeneration`.

**Tests to add:**

- Start chapter A, navigate/seek to chapter B, then deliver stale A finish. Assert no auto-advance.

## Priority 13 - Remote Skip Events Can Still Multiply

**Confidence:** Medium.

**Evidence:**

- `skipBackwardCommand` and `previousTrackCommand` both call `onSkipBackward`: `TextMouth/Services/NowPlayingService.swift:247-271`.
- Keyboard/menu notifications call separate skip handlers: `TextMouth/ViewModels/ReaderViewModel.swift:396-409`.
- Remote command callbacks are not explicitly hopped to the main actor before calling VM closures.

**Likely user-visible result:**

A single hardware gesture can arrive as multiple command types or arrive close to a keyboard/menu notification. If the debounce misses the burst, 15 seconds can become 30, 45, or 60 seconds.

**Fix plan:**

1. Dispatch every Now Playing callback onto `MainActor`.
2. Add command-layer coalescing by action/source/timestamp.
3. Keep the VM skip debounce as a second layer of defense.

**Tests to add:**

- Burst of `skipBackwardCommand`, `previousTrackCommand`, and `.skipBackward` notification within the debounce window produces one rewind.
- Same burst outside the debounce window produces expected multiple rewinds.

## Priority 14 - `content.md` Can Contain Duplicate Or Over-Broad Text

**Confidence:** Medium-high for duplicated EPUB/DAISY text, separate from audio transport bugs.

**Evidence:**

- Reader loads cached markdown content: `TextMouth/ViewModels/ReaderViewModel.swift:583`.
- EPUB markdown cache uses `HTMLToMarkdownConverter.convert`: `TextMouth/Services/MarkdownCacheService.swift:171-177`.
- `HTMLToMarkdownConverter` recurses through `<nav>` instead of stripping duplicate EPUB nav TOCs: `TextMouth/Parsers/HTMLToMarkdownConverter.swift:147-155`.
- Direct EPUB parser has nav stripping logic that the cache path bypasses: `TextMouth/Parsers/EPUBParser.swift:327-335`.
- DAISY 2.02 production strips SMIL text fragments down to whole files and deduplicates by file: `TextMouth/Parsers/DAISYParser.swift:413-445`.

**Likely user-visible result:**

Some repeated content may be baked into `content.md` before playback starts, especially nav/TOC duplication or DAISY fragment over-inclusion. That can be perceived as playback repeating, even if the audio state is correct.

**Fix plan:**

1. Reuse EPUB nav-stripping behavior in the markdown cache path.
2. Port fragment-aware DAISY text extraction from test helpers into production.
3. Add cache-path tests, not only direct parser tests.

**Tests to add:**

- EPUB cache conversion strips duplicate nav content when body headings exist outside nav.
- DAISY 2.02 content extraction respects SMIL text fragments instead of whole-file over-inclusion.

## Recommended Fix Order

1. Add lightweight instrumentation for remote commands, seek/resume paths, audio engine current offset, direct chunk boundaries, sleep fade callbacks, and UI publish cadence.
2. Fix remote Play parity and paused direct-TTS seek. These are clear state bugs and likely explain the most confusing "paused but advanced" reports.
3. Remove automatic direct chunk -> engine handoff during uninterrupted playback.
4. Fix DAISY segmented layout ordering and add segmented audio tests.
5. Verify and fix `AudioEngineService.currentCharOffset()` rate math.
6. Rework TTS skip-by-time to use rendered audio time when engine audio is available.
7. Unify sleep timer start/reset/restart behavior and suppress expiry sound/pop.
8. Make sleep fade work for the actual active playback path, including direct TTS.
9. Throttle/cached UI position publishing to address VoiceOver responsiveness.
10. Fix `content.md` duplicate/fragment extraction paths.

## Test Strategy For The Implementation Pass

Most existing playback and sleep timer tests are simulations or mirrors of logic rather than production-object tests. They are useful, but they did not catch these integration mismatches.

Add focused tests around production-shaped seams:

- `ReaderViewModel` with fake speech/audio services for remote play, in-app play, sleep timer start/reset, and restart gesture behavior.
- `SpeechService` with injectable/direct-synth facade or a small wrapper so paused seek and direct chunk continuation can be verified without real TTS.
- `AudioEngineService` empirical/integration tests for timePitch position math.
- `ReaderViewModel+Playback` audio layout tests for segmented DAISY with both file paths and segments populated.
- Parser/cache tests that exercise the actual `MarkdownCacheService` EPUB path and production DAISY fragment extraction.
- Performance tests for playback-position publishing and text-window generation.

## Notes On Current Branch State

- `CLAUDE.md` was already modified before this investigation and was not touched.
- `make build` regenerated the Xcode project during verification; that generated UUID churn was removed from the working tree.
- No source-code playback fixes were made in this pass.

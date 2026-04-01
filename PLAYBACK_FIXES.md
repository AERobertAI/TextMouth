# Playback System Fixes — 2026-03-19

This documents the fixes made to the TTS playback system (rewind/fast-forward, play/pause, chapter transitions). Future sessions should understand **why** each fix exists to avoid reverting them.

---

## Architecture Overview

TextMouth uses a **dual-mode TTS system**:

1. **Direct mode** — `AVSpeechSynthesizer.speak()` for instant playback start
2. **Audio engine mode** — `AVSpeechSynthesizer.write()` pre-renders to `AVAudioPCMBuffer`, played through `AVAudioEngine` + `AVAudioUnitTimePitch` for instant seeking and real-time speed control

The key design principle established in this session:

> **Never switch from direct mode to engine mode mid-playback.** The position gap between the last `willSpeakRangeOfSpeechString` callback and actual audio output is unknowable, making seamless handoff impossible. Only switch at natural breaks: user-initiated seeks, pause/resume, or chapter boundaries.

---

## Fix 1: Completion Handler Race Condition (AudioEngineService)

**Problem:** `playerNode.stop()` triggers the completion handler from the previously scheduled buffer. During a seek, this caused `handlePlaybackComplete()` → `onPlaybackFinished` → `onUtteranceFinished` → chapter advance, killing the seek.

**Solution:** Added `playbackGeneration` counter. Each `scheduleAndPlay()` and `stop()` increments it. Completion handlers capture their generation and check it matches before firing.

**Files:** `AudioEngineService.swift`

**What NOT to do:** Do not remove the generation check. Without it, every seek/rewind/fast-forward will trigger a false "chapter finished" signal.

---

## Fix 2: Direct Mode Position Reporting (SpeechService)

**Problem:** `speakDirect()` trims text from a charOffset (e.g., starting at position 10977), but `willSpeakRangeOfSpeechString` reports ranges relative to the trimmed text (0, 5, 10...). The `onWordSpoken` callback overwrote `currentCharacterOffset` with these tiny values, so the next rewind calculated from ~61 instead of ~10977.

**Solution:** Added `directModeBaseOffset` to SpeechService. The delegate callback adds this base to all reported ranges, so positions are always absolute within the chapter.

**Files:** `SpeechService.swift`

**What NOT to do:** Do not report raw `characterRange` from the delegate without adding `directModeBaseOffset`. All callers expect absolute chapter positions.

---

## Fix 3: Stale didFinish Callbacks (SpeechService)

**Problem:** `directSynth.stopSpeaking(.immediate)` queues a `didFinish` callback asynchronously. If a new `speakDirect()` starts before it fires, the stale callback sees `usingDirectMode == true` (from the NEW utterance) and calls `onUtteranceFinished`, which advances to the next chapter — undoing the rewind.

**Solution:** Added `ignoreDirectFinishCount`. Incremented in `stop()`, `seek()`, and the mode-switch code before calling `stopSpeaking`. The `didFinish` delegate decrements it and skips processing.

**Files:** `SpeechService.swift`

**What NOT to do:** Do not call `directSynth.stopSpeaking()` without incrementing `ignoreDirectFinishCount` first (when the synth is active). The Zotero iOS app uses the same pattern for the same reason.

---

## Fix 4: No Mid-Playback Mode Switching

**Problem:** Earlier attempts tried to switch from direct mode to engine mode while audio was playing, to gain seeking/speed benefits. This always caused audible glitches:
- **Repeated words** — `willSpeakRangeOfSpeechString` fires BEFORE a word is spoken and dispatches to main queue async. By the time we read the position, the direct synth's actual audio output is 2-5+ words ahead. Any offset guess (skip N words) is unreliable.
- **Clicks** — `stopSpeaking(.immediate)` cuts audio mid-sample.

**Approaches that were tried and failed:**
1. Skip 1 word past last reported range → still repeated text
2. Skip 3 words past last reported range → sometimes repeated, sometimes skipped text
3. Fade-in on engine start → reduced clicks but didn't fix repeats

**Solution:** Removed mid-playback switching entirely. Direct mode runs until a natural break:
- **Seek/rewind/FF:** If engine is rendered, switch then (user expects audio break)
- **Pause → Resume:** Switch to engine if rendered (natural silence gap)
- **Chapter end:** Next chapter starts with engine (pre-rendered during current chapter)
- **No engine ready:** Stay in direct mode, restart from new position

**Files:** `SpeechService.swift` — `speak()`, `seek()`, `resume()`

**What NOT to do:** Do not add code to switch from direct to engine mode during active playback. It will always produce audible artifacts. The position gap is fundamental to how `AVSpeechSynthesizer` reports word ranges.

---

## Fix 5: Chapter Transition Pre-rendering (ReaderViewModel + AudioEngineService)

**Problem:** Starting a new chapter required rendering the full text before audio played, causing a delay.

**Solution:**
- `speakCurrentChapter()` calls `preRenderNextChapter()` which creates a separate `AudioEngineService` and renders the next chapter's text in background.
- When `onUtteranceFinished` fires, if pre-rendered audio is ready, it's adopted via `audioEngine.adoptRenderedAudio(from:)` and plays immediately — no direct mode fallback needed.
- `AudioEngineService.adoptRenderedAudio()` copies the rendered buffer, format, word-frame map, and total frames from the pre-rendered engine.

**Files:** `ReaderViewModel.swift`, `AudioEngineService.swift`, `SpeechService.swift` (`usePreRenderedEngine()`)

---

## Fix 6: Buffer Completion Timing (AudioEngineService)

**Problem:** `scheduleBuffer` default completion type (`.dataConsumed`) fires when the playerNode consumes the data, before the audio finishes playing through TimePitch and out the speakers. This clipped the last word of chapters (e.g., "else" became "el").

**Solution:** Changed to `.dataPlayedBack` completion type, which fires only when audio has actually been output through the hardware.

**Files:** `AudioEngineService.swift` — `scheduleAndPlay()`

**What NOT to do:** Do not use the default `scheduleBuffer` without specifying `.dataPlayedBack`. Do not use artificial delays as a workaround (unreliable, adds perceptible gaps).

---

## Fix 7: Instant Pause (SpeechService)

**Problem:** `directSynth.pauseSpeaking(at: .word)` waits until the current word finishes before pausing, adding noticeable delay.

**Solution:** Changed to `.immediate` for instant pause response.

**Files:** `SpeechService.swift` — `pause()`

---

## Fix 8: Audio Click Reduction (AudioEngineService)

**Problem:** Starting playback from a mid-buffer position causes an audio pop/click from the abrupt amplitude change.

**Solution:** `applyFadeIn()` applies a 10ms linear amplitude ramp (0→1) to the start of sub-buffers when seeking to a mid-point.

**Files:** `AudioEngineService.swift`

---

## Fix 9: Silence Padding for Chapter-End Clipping (AudioEngineService) — 2026-03-31

**Problem:** `.dataPlayedBack` fires when the `playerNode` finishes consuming data, but the `AVAudioUnitTimePitch` node downstream still has audio in its internal processing buffer. During chapter transitions, `stop()` discards those buffered samples, clipping the last word or syllable. The effect is worse at non-1.0 rates (e.g., 200 WPM = 0.44x rate) where the timePitch buffer is larger.

**Solution:** Append 200ms of silence to the end of every rendered buffer. This gives the timePitch node time to fully process and output the last real audio samples before the completion callback fires and the chapter transition begins. The char-to-frame mapping and `totalFrames` use only the speech portion so position tracking remains accurate.

**Files:** `AudioEngineService.swift` — `render()`, `silencePaddingDuration` constant

**What NOT to do:** Do not remove the silence padding. Do not include padding frames in `totalFrames` or the char-to-frame mapping — characters should only map to real speech audio, not silence.

---

## Fix 10: Sleep Timer Fade-Out Volume Pop (ReaderViewModel) — 2026-03-31

**Problem:** When the sleep timer fade-out completed, `onTimerExpired` called `restoreVolume()` (setting volume to 1.0) *before* calling `pause()`. This created a brief audible pop of full-volume audio in the last ~250ms before the pause took effect. The same bug existed in the manual `pause()` path when the user pressed pause during an active fade-out.

**Solution:** Reordered both paths: pause audio output first (stopping sound immediately), then restore volume (now inaudible since audio is paused). The volume is ready for the next playback session without any audible artifact.

**Files:** `ReaderViewModel.swift` — `setupCallbacks()` (`onTimerExpired`), `ReaderViewModel+Playback.swift` — `pause()`

**What NOT to do:** Do not call `restoreVolume()` or `setVolume(1.0)` while audio is still playing. Always pause first.

---

## Fix 11: Volume Tracking Across Engine Restarts (AudioEngineService) — 2026-03-31

**Problem:** During chapter transitions, `stop()` calls `engine.stop()` and then `play()` disconnects/reconnects nodes and calls `engine.start()`. The `mainMixerNode.outputVolume` can reset to 1.0 during this cycle, discarding any volume set by the sleep timer fade or other callers. This caused unpredictable volume jumps between chapters.

**Solution:** Added a `currentVolume` property that shadows the mixer node's output volume. `setVolume()` and `restoreVolume()` update both the tracked value and the mixer node. `play()` re-applies `currentVolume` after `engine.start()` so volume persists across chapter boundaries regardless of engine restart behavior.

**Files:** `AudioEngineService.swift` — `currentVolume` property, `setVolume()`, `restoreVolume()`, `play()`

**What NOT to do:** Do not set `engine.mainMixerNode.outputVolume` directly — always go through `setVolume()` or `restoreVolume()` so the tracked value stays in sync.

---

## Debugging

Two log files are written to the app's sandbox container:

- `textmouth_debug.log` — Skip/rewind/FF calculations, chapter advances
- `textmouth_transition.log` — Mode switches, engine render readiness, pre-render status

Location: `~/.TextMouth/Logs/`

---

## Research Sources

Patterns were informed by open-source TTS implementations:
- **BlazeBooks** (`iaingblack/blaze-books`) — Sentence chunking, documented AVSpeechSynthesizer pitfalls
- **Zotero iOS** (`zotero/zotero-ios`) — `ignoreFinishCallCount` pattern for suppressing stale callbacks
- **FreeTTS** (`enefry/FreeTTS-Apple`) — Pre-render via `write()` approach
- **Apple Developer Forums** — `AVSpeechSynthesizer` has no native seek; all apps must build workarounds

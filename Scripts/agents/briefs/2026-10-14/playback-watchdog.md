# Task brief: playbackwatch — a playback watchdog, and sound effects that never block (B07)

Slug `playbackwatch`. Branch `fix/playback-watchdog` from local `main`. Read `common.md` beside this brief first, above all its rule on Ogg.

## Why: what happened on October 14, 2026 (from a sample of the frozen app, the system log, and the JetsamEvent report)
1. A few seconds into a new track, Apple's Vorbis decoder locked up inside AudioToolbox, so the audio went silent. The reader went on showing Playing ("Pause" on the button) and noticed nothing.
2. The user pressed Pause with VoiceOver. `pause()` played the pause sound first. `SoundEffectService` → `-[NSSound play]` → `AVAudioPlayer play` → `AudioQueuePrime` → `AudioQueueObject::AcquirePlayResources` → `os_unfair_lock` blocked the main thread for good, behind the stuck decoder. The app froze.
3. The stuck decoder kept allocating memory. TextMouth reached 34 GB on the 8 GB Mac in about nine minutes, WindowServer stopped responding, and the Mac had to be reset.

Agent `oggtoaac` stops Ogg reaching the player. Your task is that **any** such fault in the system's audio, whatever its cause, can never freeze TextMouth's window, never leave it showing Playing over silence, and never take the Mac down. The user agreed to: "a playback watchdog: if the player's time stops advancing while TextMouth thinks it's playing, or its memory climbs past a safe limit, playback stops and VoiceOver says what happened; and play the play and pause sounds off the main thread, so a stuck audio system can never freeze the window."

## Required behavior, one commit each, with tests
1. **Sound effects never block the main thread** (`TextMouth/Services/SoundEffectService.swift`). A sound is handed to a serial queue of its own and played there, and the main thread never waits for it. While a sound's play has not returned, later sounds are dropped rather than queued behind it, with one log line (`SOUND_EFFECT_STUCK`). Every other behavior of the sounds (which play, their volume, the settings) stays as it is and keeps its tests. Use whatever sound API is safe off the main thread, and say which in a comment.
2. **A playback that stops advancing is stopped and said.**
   - **What counts:** while a reader's audio is playing (not paused, not seeking, not waiting out a chapter's pause, a download, or a package move), the player's time must advance. If it hasn't moved for 8 seconds with the rate above zero, playback has stalled.
   - **The machinery:** extend the start-stall check that exists (`AudioPlaybackService.isStalled`, `scheduleProgressCheck`, `checkProgress(of:)`, and the reader's `PLAYBACK_PAUSED_AFTER_START_STALLS`) to the whole play, rather than add a second timer.
   - **Stopping:** stop through the existing failure path (`handleAudioPlaybackFailure`), with a new reason. So Play shows, Now Playing clears, and the sleep timer's countdown halts, as for any failure.
   - **Wording:** "Playback stopped: the audio stopped responding. Press Play to try again; if it stops again, quit and reopen TextMouth." Pin it.
   - **Letting go of the stuck player:** do it off the main thread. Never call into a player that may be stuck (pause, rate, replaceCurrentItem) synchronously on the main thread; a retry gets a fresh player.
   - **Log:** `AUDIO_PLAYBACK_STALLED` with the file (`DiagnosticLog.loggablePath`), media time, seconds without progress, and rate.
3. **A guard on memory while anything plays.**
   - **What it reads:** while audio or speech plays, read TextMouth's physical footprint (`task_vm_info.phys_footprint`) every 5 seconds through an injectable reader. Measure TextMouth's normal footprint (a large library open, a book playing) and set the ceilings well above it, as named constants with comments. 3 GB and 6 GB are the starting proposal.
   - **At the first ceiling:** stop playback as in item 2, log `AUDIO_MEMORY_RUNAWAY` with the footprint, and say: "Playback stopped because TextMouth's memory grew to N GB while the audio played, a fault in macOS's audio."
   - **At the second ceiling,** whether reached afterwards or at once: save the library, every open reader's position, and any pending writes. Write a marker, and quit TextMouth without asking any question. A runaway inside Apple's audio code cannot be stopped from inside the app, and would otherwise take the Mac down. The next launch then says, in an alert: "TextMouth quit on <date> to protect your Mac: its memory grew to N GB while <book> played, because of a fault in macOS's audio. Your place was saved." Pin it.
   - **Tests:** an injected footprint and clock; nothing real runs away.
4. **No false alarms.** Test that none of these trips the watchdog: a pause; a seek; Where Am I?; a chapter's pause (FR15); waiting for a download or a package move; the sleep timer's fade; the slowest speed; the end of a track. Test too that a book playing normally for its whole length (a short silent fixture) never trips it.

## Out of scope
Converting Ogg (agent `oggtoaac`), and text-to-speech's own engine beyond the memory guard.

## Report
As `common.md` says. Include the normal footprint you measured and the ceilings you chose, and the documentation wording, naming the page for each sentence (`docs/user/reader-windows.md`, `docs/user/where-your-library-lives.md` for the log lines, and the architecture pages you touch).

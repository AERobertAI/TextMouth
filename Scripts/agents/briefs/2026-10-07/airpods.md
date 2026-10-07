# Task brief: airpods — rewind from the AirPods after a book has finished

Slug `airpods`; branch `fix/airpods-rewind-after-finish`.

## The user's words (October 7, 2026)
"Oh and another possible bug I noticed after a book "finished" trying to use the rewind track on my Airpods didn't seem to work to hear the last little bit, please look into this..."

## What the orchestrator found (verify as you go)
- `NowPlayingService.performRemoteCommand` sends skip-backward and previous-track commands (the AirPods' rewind is `previousTrack`, mapped to backward navigation, see `setupRemoteCommands`) through `dispatchSkipCommandToActiveOwner`, which needs `activeOwnerID = playingOwnerID ?? focusedOwnerID` and fails the command (`.commandFailed`) when it is nil.
- `ReaderViewModel.handleEndOfBook()` (ReaderViewModel+Playback.swift around line 1986) sets `isCurrentlyPlaying = false` and, for the Stop behavior, calls `finishListening(announcing:)`, which shows Now Playing stopped (`updateNowPlayingInfo(isPlaying: false)`). Find out what the reader's media ownership is after that (does it remain the focused owner? does anything release its controls or unregister it?), what `skipBackward()` → `performSkip` does when the cursor is at the end of the book and nothing plays (an audiobook at its duration; a text book past its last chapter), and whether the gesture detector swallows the command. The open decision P07 in TODO-2026-09-04.md ("the end-of-book position") is related: where does the cursor sit after a finished book?
- The user listens on AirPods; the fix must work for the AirPods' previous-track command and for the keyboard's Skip Backward alike, for a finished audiobook and a finished text book.

## Files you own
TextMouth/Services/NowPlayingService.swift, TextMouth/Services/MediaGestureDetector.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift (the end-of-book region and the Now Playing calls), TextMouth/ViewModels/ReaderViewModel+Navigation.swift (`performSkip` and the skip handlers), and the tests: TextMouthProductionTests/MediaCommandPlaybackTests.swift, ContinueToNextBookTests.swift, and any end-of-book or skip tests you find (name them in your report), plus a new file if needed. Avoid: TextMouth/Services/SpeechService.swift and AudioEngineService.swift (the speechguard agent), the library view models and views, Models/Book.swift and BookInfo.swift (other agents).

## Items, one commit each, each with its tests
1. **Diagnosis pinned by a failing test first**: a reader whose book has just finished (Stop behavior) receives the previous-track and the skip-backward remote commands through `NowPlayingService` and nothing happens today; write the test that shows what is dropped and where (owner missing, or the skip refused at the end), then fix.
2. **The behavior**: after a book has finished, a backward skip or previous-track command (from the AirPods, the media keys, or the keyboard) moves the cursor back by the skip unit from the end of the book and starts playback there, exactly as a skip during playback does, with the skip's sound effect and VoiceOver wording unchanged; the reader stays the media owner after finishing while its window is open, so the AirPods reach it; next-track or skip-forward at the end does nothing harmful (stays at the end, no announcement loop). A finished audiobook and a finished text book both. Continue-to-next-book and Loop behaviors keep their meaning; the sleep timer's end-of-book stop keeps its meaning. Tests in `MediaCommandPlaybackTests` for the remote commands, and reader tests for the keyboard skip after the end.
3. **Comments** at `handleEndOfBook`, `finishListening`, `activeOwnerID`, and `performSkip` say what a finished book owns and why.

## Verify or report as unverified
- Real AirPods are not available to a test: say that the AirPods path was verified only as the `previousTrack` remote command delivered to `NowPlayingService`.
- Whether macOS still delivers `previousTrackCommand` to an app whose Now Playing state is stopped (rather than paused) is unverified; if `updateNowPlayingInfo(isPlaying: false)` reports "stopped" to the system, consider whether a finished book should report "paused" at its end instead, and say what you chose and why.

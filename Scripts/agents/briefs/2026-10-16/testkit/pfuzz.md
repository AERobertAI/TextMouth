# testkit/pfuzz: a seeded playback state-machine fuzzer (TODO P09, the part that needs no hardware)

Slug `testkit-pfuzz`. Branch `testkit/pfuzz`, made from `team/testkit`. You build; at most two builders run at once. Read `teams-common.md`'s worker's part first.

## Why

TODO P09 (TODO-2026-09-04.md line 3483): "Validate direct/rendered speech transitions on supported voices and routes ... Acceptance: repeated pause/resume/seek/voice changes and disconnect/reconnect preserve the cursor, stop old audio, and release render resources." A person cannot do that by hand enough times to find a race. A test can: it applies thousands of random operations, in a seeded order, to a reader that plays silent audio or speaks into a held (never rendered) queue, and after every step checks the invariants a listener depends on. A failing sequence prints its seed and the operations so far, which reproduces it exactly.

## Ground truth (read the neighbours first; they show every fake you need)

- Silent audio and text readers: `IntegrationTestSupport.swift` (`makeIntegrationWorld`, `makeSilentAudioBook`, `makeSilentAudioFileBook`, `makeChapteredAudioBook`, `openReader(for:renderScheduler:nowPlaying:)`, `waitForReaderToLoad`), and `EndBehaviorTestSupport.swift` (`withSpeechReader`: a text reader whose speech is held; `startSpeakingSilentlyUntilItsEnd`, `endSpeechSilently`). Speech never renders (`HeldRenderQueue`) and a test stops its speech before the main run loop turns.
- Route changes: `AudioRouteMonitoringTests.swift` (a `NowPlayingService` with injected device state: `handleDefaultOutputChange()`, `handleDeviceListChange`-style calls; `makeHarness`), `PlaybackWatchdogTests`, `NowPlayingOwnershipTests`, `MediaCommandPlaybackTests` (77 tests: pause/resume/skip commands through the media-command path).
- Render resources and stale callbacks: `PreRenderedSpeechInvalidationTests` (48 tests), `SpeechRenderCoordinatorTests`, `CompletionGenerationReaderTests`/`CompletionGenerationTests` (a generation number stops stale completions), `ReaderLifecycleAuditTests`, `PlaybackMemoryGuardTests`.
- What a reader exposes: `ReaderViewModel` (TextMouth/ViewModels/ReaderViewModel.swift, a large file: read the public/internal members you need by `grep -n "func \|var "` with a pattern, never the whole file): `play()`, `pause()`, `stop()`, `skipForward()`, `skipBackward()`, `navigateTo(chapterIndex:characterOffset:)`, voice and speed setters, `isCurrentlyPlaying`, `currentChapterIndex`, `audioPlaybackService.isPlaying`, `speechService.isSpeaking`, the cursor/global offset, `lastAnnouncement`, `close()`.

## What you build

1. `TextMouthProductionTests/PlaybackFuzzOperations.swift`: a pure, seeded operation generator. A SplitMix64 generator (a seed reproduces a sequence on any Mac). `enum PlaybackOperation: CustomStringConvertible` with the operations you can drive through the reader and its fakes: play, pause, toggle, stop, skip forward, skip backward, seek to a random place (chapter and offset within bounds), next heading, previous heading, change the voice, change the speed, run a short time (spin the run loop 0.05 to 0.3 s), route lost (a default-output change on the injected `NowPlayingService`), route back, a media command (pause or play), a render invalidation (`invalidate pre-rendered speech`), sleep timer set and cancel. List in your report which of the plan's operations you could not drive and why. `func sequence(seed:length:kinds:) -> [PlaybackOperation]`, stable and printable (`seed=17 [play, run 0.1, seek ch1@120, voice, route lost, play, ...]`).
2. `TextMouthProductionTests/PlaybackFuzzOperationsTests.swift`: always-on unit tests: determinism by seed; different seeds differ; every generated seek is within bounds for the stated book shape; a sequence has the requested length; descriptions are stable text.
3. `TextMouthProductionTests/PlaybackFuzzTests.swift`: `final class PlaybackFuzzTests: XCTestCase` (`@MainActor`) with one test per book kind (text, single-file audio, multi-file audio), each running `TEXTMOUTH_PLAYBACK_FUZZ_SEQUENCES` sequences (default 8 always-on, so the always-on part takes under 60 seconds; `TEXTMOUTH_PLAYBACK_FUZZ_SEQUENCES=200` and `TEXTMOUTH_PLAYBACK_FUZZ_SEED` for a long run through `Scripts/test/run-area.py --classes PlaybackFuzzTests --env ...`) of `TEXTMOUTH_PLAYBACK_FUZZ_LENGTH` (default 30) operations. After EVERY operation check the invariants, each failure message starting with the seed, the step number, and the operation list so far:
   - the cursor (chapter and offset) is within the book's bounds and never jumps backward without a seek, skip back, loop, or stop-at-end causing it;
   - at most one source is active: not (audio service playing and speech speaking), and not two audio sources;
   - `isCurrentlyPlaying` agrees with the service that is actually playing, after the run loop has settled for 0.05 s;
   - after `pause` or `stop` nothing is playing or speaking, and stays so after a further 0.1 s (a stale completion must not restart it);
   - after a route loss while playing, the reader is paused (not playing) and keeps its cursor (the app's documented behavior; find it in `AudioRouteMonitoringTests`), and a later play resumes from that cursor;
   - after `close()` or at the end of the sequence the reader holds no render work (find the member that reports pending or held renders in `HeldRenderQueue`/`SpeechRenderCoordinator` and assert it is empty), and no timer is left running.
   An invariant you cannot state from the code or the existing tests is not to be invented: omit it and say so.
4. Run once at 200 sequences per book kind with the fixed default seed and again with one other seed. If an invariant fails, minimise: rerun the printed seed, shorten the sequence by halves while it still fails, and report the shortest failing operation list. Do not fix the app: post a finding (`bbs post testkit-pfuzz --tag finding --file <app file> --topic "<invariant> fails: seed N, ops ..."`), then make the test tolerate it in the narrowest way (a `knownIssues` entry matching the invariant and the exact operation prefix, with a comment pointing at the finding) so the suite stays green and the issue stays visible: a known issue that stops failing fails the test with `remove it from the list`.

## Tests to run

`PlaybackFuzzOperationsTests`, `PlaybackFuzzTests` (default size), then the long run once. At the end also `MediaCommandPlaybackTests` and `AudioRouteMonitoringTests` once. Time every always-on test: the always-on part must stay under 60 seconds in total.

## Do not

Edit the app or an existing test. Play sound (silent files only; speech held and stopped). Use real devices or Core Audio listeners (`AudioRouteMonitoringTests.swift:287` shows monitoring on a test coordinator installs none). Leave readers, timers, or notifications subscribed (tear everything down in `addTeardownBlock`/`defer`). Let a test trap (no `[0]`, no `!`).

## Commits

1. `PlaybackFuzzOperations` + its tests (+ `project.pbxproj` from `xcodegen`).
2. `PlaybackFuzzTests` for text.
3. Audio kinds.
4. Known issues with their findings, if any.

## Report (at most 15 lines)

Branch; commits; exact result lines; the operations driven and not driven; the invariants checked and not checked; the long run's results; every finding with its shortest reproduction.

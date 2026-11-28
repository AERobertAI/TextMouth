# Tests of real speech synthesis: a plan

A plan, November 28, 2026, written after B31 (merged in ceb3882ff).
Where this plan and the code differ, the code wins.

## Why B31 got through

On macOS 27, `AVSpeechSynthesizer.write(_:toBufferCallback:)` sends an empty buffer at the end of each of its segments, and `didFinish` after the last.
The engine's render took the first empty buffer for the end, so each rendered chapter held its first segment, and the reader moved on to the next chapter.
The suite of 14,503 Mac tests stayed green for four reasons:
- every test of the render's end used a fake writer, scripted by hand with one empty buffer at the end, as macOS 26 sends;
- GitHub's runners run macOS 26 (26.7.2, Xcode 26.0.1), where a write sent one empty buffer, so a real write there could not show the change;
- the one test that writes a real voice through the export (`SpeechChapterRendererTests.testTheMacsSynthesizerWritesASentenceIntoAFile`) is opt-in, and writes one sentence, which is one segment, so it passes with the bug;
- the change came with an update of macOS, not with a commit, so no train was asked for.

So the plan's first rule: a test of the end of a write needs either a real synthesizer on the macOS that misbehaves, or a recording of what that macOS really did.

## What the probe measured on this Mac

A probe of this plan (in the agent's scratch folder, not the repository) wrote into memory only, never with `speak()` and never with a Personal Voice, which renders to the speakers.
macOS 27.2.1, 181 voices, 42 of them English and not Personal Voices, one of those enhanced, none premium.
At the render's rate, 0.7:

- **One word** ("Ready.") gives one empty buffer, then `didFinish`, in every voice tried (compact Samantha, Alex, Eloquence Eddy).
- **Five sentences** (60 words, 350 UTF-16 units) give two segments: the first ends after 3 sentences, at 57 to 58% of the audio, and the last empty buffer comes just before `didFinish`.
  Samantha made 8.53 s of audio (422 words a minute), Alex 6.86 s (525), Eddy 8.25 s at 16,000 Hz (436); `AudioEngineService.renderWPM` assumes 457.
- **Forty sentences** (2,807 units) give 14 segments, each ending at a sentence's end, every 199 to 225 units.
  A novel's chapter of 20,000 units would make about 95, so a render that stopped at the first kept about 1% of it.
- **`stopSpeaking(at: .immediate)` during a write** returned false, 5,887 buffers followed it, and the write ended with `didFinish`, not `didCancel`: 68.3 s of audio, all of it.
- **`willSpeakRangeOfSpeechString` is called during a write**, once a word (60 to 65 calls for 60 words), on the main thread, interleaved with the buffers.
  The frames delivered by each call rise with the text, the last word's range ends at the text's end (349 or 350 of 350), and no word was more than 5% of the audio from an even spread over the text.
- Every buffer, the ranges, `didStart`, and `didFinish` came on the main thread, although the write was asked for off it.
- **Cost:** the whole probe, the voice listing, three voices loaded, and 1,000 units written, took 15.8 s and 46 MB; each five-sentence write took 0.09 to 0.63 s.

On GitHub's macOS 26 runner a real write works too: `SpeechMarkupGuardTests` writes compact Samantha offline in every train, and the run of November 28 (`build/orchestrator/nov28b31b-suite.log`) printed "the guarded chunk finished with 75989 frames".
What the runner cannot do is start an `AVAudioEngine` (AudioQueue error -4), so the two `AudioEngineBehaviorTests` that play are in `Scripts/agents/runner-skips.conf`.

## What exists: the fakes

The speech code has three seams, and the tests use each:

- `SpeechBufferSynthesizing`: the speech export's synthesizer; `FakeSpeechBufferSynthesizer` makes a quiet tone in memory for `SpeechChapterRendererTests`, `SpeechExportJobTests`, `SpeechExportServiceTests`, and `SpeechExportDialogTests`.
- `SpeechBufferWriting`: one write of `SystemSpeechBufferSynthesizer`; `SpeechBufferSynthesizerTests` scripts it through a refusal, Stop, the stall limits, the Personal Voice check, and, since B31, empty buffers between segments.
- The engine's render has no writer seam: `AudioEngineService.write` makes its own `AVSpeechSynthesizer`, sharing only `SpeechBufferDelivery` and `SpeechWriteRelay` with the export.
  Its wait is tested apart (`AudioEngineService.waitForWrite`, four tests added by B31 in `AudioEngineBehaviorTests`).
  The other reader tests install audio of a given length (`_installRenderedAudioForTesting`), or take direct speech's utterances (`SpeechService._directUtteranceRecorderForTesting`) and deliver the synthesizer's callbacks by hand.

A third write, `VoiceWarmUp.writeOneWord`, still ends at the first empty buffer; for its one word that is the end on both systems (the probe above), so it is right, but nothing pins it.
The probe `Scripts/agents/probes/speech-render-speed-probe.swift` also stops at the first empty buffer, so its numbers on macOS 27 measure the first segment.

## What exists: real voices

- `SpeechMarkupGuardTests` writes compact Samantha offline through `OfflineRenderProbe`, which ends at `didFinish`, in every run, and skips when the voice is missing; it tests the guard, not the render's end.
- `SpeechChapterRendererTests.testTheMacsSynthesizerWritesASentenceIntoAFile`: one sentence through the export into a CAF, only with `TEXTMOUTH_REAL_SPEECH_EXPORT=1`.
- `AudioEngineBehaviorTests.testRenderedSpeechMemoryBenchmark`: a 40,000-unit render and play at volume 0, only with `TEXTMOUTH_RENDER_BENCHMARK=1`; it starts the audio engine.
- `VoiceSweepTests` (`Scripts/test/voice-sweep.sh`): the fixed sample in every installed voice, offline, reporting audio length, render time, hangs, and refusals; opt-in, and it counts frames to `didFinish`, but asserts nothing about length.
- `ProductionPlaybackProfilingTests` (`Scripts/profile-production-playback.sh`): opt-in, on a copied book.
- `TranscriptionFixtureTests`: `SpeechTranscriber` on two DAISY audio books a checkout may keep; skips without macOS 26, the English model, or the files, and never downloads a model.
- `TranscriptAccuracyMeasurementTests`: opt-in, measured the Mac's voices at 4.9% (Alex) and 3.4% (Daniel) word error rate (research/TRANSCRIPT-CLEANUP-RESEARCH-2026-10-04.md).
- `make release-goldens` (`Scripts/test/release-goldens.sh`) runs the text goldens against a Release build; no golden is audio.
- The iPhone: the unit bundle may name no audio framework (`SOUND_PATTERN` in `Scripts/agents/ios_ui_tests.py`), so no iPhone test writes speech; the interface tests press Play on GitHub with `TEXTMOUTH_UI_SOUND`, and check what VoiceOver would be given, not what was said.

## Where each test can run

- **This Mac:** macOS 27.2.1 and Xcode 27.2, the user's voices, a speech model for transcription; the only macOS 27 until TL26.
  A real write here plays nothing, but shares the speech service with the user's TextMouth, which may be speaking.
- **GitHub's `macos-26` runner:** real writes work with compact Samantha; the audio engine cannot start; `AVSpeechSynthesisVoice.speechVoices()` once hung there with no limit (`VoiceCatalog` now lists on a queue of its own), so a test names its voice by identifier.
- **The `xcode-27` macOS 27 image, after TL26:** expected to behave as this Mac; unverified.
- **The iOS 26.2 simulator on the runner (and iOS 27 after TL26):** unknown whether its voices write; `SpeechTranscriber.isAvailable` is false in the simulator, by Apple's sample notes and a developer forum thread (sources at the end).

## Layer 1: recorded write traces, replayed

The cheapest layer, and the one that would have caught B31 on every runner.

- A trace is what one real write did: the voice, the OS, the text's length, each buffer's frame count (runs collapsed), each empty buffer, each word range with the frames before it, and the delegate calls in order.
  It is JSON of 1 to 3 KB, in `TestData/speech-traces/<os>/<voice>-<text>.json`.
- A scripted writer replays a trace into each write path in the ordinary suite: the export's `SystemSpeechBufferSynthesizer`, the engine's render, and `VoiceWarmUp`.
  Each must keep every frame of the trace and end at its `didFinish`.
- The engine's render must first write through the `SpeechBufferWriting` seam, as the export does (one writer for both, which also removes the copy of the write-and-wait logic in `AudioEngineService.write`).
- The first traces are this probe's, macOS 27.2.1: one word, five sentences, forty sentences, and Stop during forty sentences, for Samantha, Alex, and Eddy; and macOS 26's, recorded on the runner by layer 2.
- **Catches:** any path that ends at an empty buffer, drops a segment, or mishandles a Stop that does not stop, on every OS, every train, with no voice.
- **Cost:** under a second of tests; one branch for the seam and the replay (about a train).
- **Flakiness:** none; a trace is fixed data.
- **Runs:** everywhere, the iPhone unit bundle included, since replaying names no audio framework if the trace reader builds `AVAudioPCMBuffer`s only in the Mac half (or behind the allowance of question 5).

## Layer 2: the write's contract, on each OS

A test that writes the real synthesizer into memory and fails loudly when Apple changes what the app relies on (`SpeechWriteContractTests`).

- **Asserted, on every OS:** `didFinish` (or `didCancel` for a refused text) comes exactly once, after the last buffer, and no buffer after it.
  One word gives at least one empty buffer; every buffer of a write has one format; the last word range ends at the text's end; the audio is within layer 3's length band.
- **Recorded and compared with the OS's trace:** the number of segments and where they end, whether `stopSpeaking` returns true and stops the write, and the threads called on.
  A difference fails with the new trace written to the test's sandbox and the command that records it, so a new macOS is one reviewed commit of JSON.
- An OS with no trace yet fails on the runner image named for it and skips elsewhere with one message.
- Voices: compact Samantha always (on every runner); Alex and an Eloquence voice where installed, since they differ in rate, sample rate, and speed.
- **Catches:** B31 itself on this Mac and on the macOS 27 image, the day the OS changes, and the Stop that does not stop a write, which `checkb31` found.
- **Cost:** 2 to 4 s of tests after the voices load; one branch.
- **Flakiness:** low; a busy Mac slows a write but changes no callback order, and every wait has a limit of 30 s.
- **Runs:** GitHub `macos-26` in every train, the macOS 27 image after TL26, and this Mac at each merge and after each macOS update (question 1).

## Layer 3: render completeness

Real renders through the app's own two paths, checked for length (`SpeechRenderCompletenessTests`).

- The engine's `render` and the export's `SpeechChapterRenderer` each write a fixed 40-sentence text (about 2,800 units, 14 segments on macOS 27).
- **Against a reference:** the same text written by `OfflineRenderProbe` (it ends at `didFinish` and keeps nothing), the same voice and rate; the app's frames must be within 2% of the reference's.
  This needs no guess of a voice's speed, and is the check that would have failed B31 at 7%.
- **Against the text:** speech seconds within 0.5 to 2 times the words at `renderWPM` (457 a minute at rate 0.7; measured 422 to 525), and, for the export, at the words a minute it asked for.
- **Against silence:** at least half of the 50 ms windows above -50 dBFS, so a render of zeros or of one held sample fails.
- The engine is never started (`_engineBuildCountForTesting` stays 0), so the test runs on the runner, where the audio engine cannot start.
- The opt-in export test gains the 40-sentence text and joins this class; `TEXTMOUTH_REAL_SPEECH_EXPORT` is then no longer needed.
- **Catches:** B31 on macOS 27, any early end, a lost segment, a voice that renders silence, and a render installed after a timeout.
- **Cost:** 1 to 3 s of tests (Samantha renders 2,800 units in about 1.6 s here); in the same branch as layer 2.
- **Flakiness:** low; the 2% compares two writes of one voice on one machine, and the band is wide.

## Layer 4: a guard in the app

Not a test, but the same check made in the app, so that a future B31 costs the listener nothing.

- The render keeps the synthesizer's word ranges with the frames delivered before each (the probe shows them during a write).
- It installs audio only when the last range ends within the text's last sentence; otherwise it logs `RENDER_SHORT` with the counts and leaves speech direct, as a refused render does.
- The frame map can then use the real word positions in place of an even spread, so seeking and Where Am I land on the word heard.
- **Catches:** in the field, what layers 2 and 3 catch in tests; a short render becomes direct speech rather than a skipped chapter.
- **Cost:** one branch of app code in `AudioEngineService` and `SpeechChapterRenderer`, with layer 1's traces as its tests.
- **Risk:** a voice that reports no ranges in a write would render nothing; the guard needs a fallback to the length band of layer 3 (question 4).

## Layer 5: the reader, end to end

A hand-made book of four short chapters (a heading and three sentences each), read by the real reader on rendered speech, with no sound.

- **Silence:** the engine renders into `AVAudioEngine`'s manual rendering mode (offline), pulled by the test, in place of the output device; a seam in `AudioEngineService` chooses it.
  That also runs on the runner, where the device cannot start.
- **Steps:** Play from the start; Pause and Play; rewind 30 s; fast forward; Next Heading; let a chapter end and the next begin; then the export of the whole book.
- **Oracle:** for each chapter, every frame of its render is pulled through the player before the reader moves on, and the word ranges of layer 4 reach the chapter's end; for the export, each chapter's audio passes layer 3's reference check.
  The engine's own position is not the oracle: its frame map spreads the text over whatever audio there is, so a short render still reports the whole chapter played.
- **Catches:** B31 as the listener met it (skipping after a rewind, Pause and Play, or a chapter change), and any reader bug that moves on before a chapter's audio ends.
- **Cost:** the seam and the test, one or two branches; 10 to 20 s of tests.
- **Flakiness:** medium, since it drives timers and the render queue; every wait has a limit.

## Layer 6: transcription

The real render transcribed by the Mac's own recognizer and compared with the text (`SpeechTranscriptCheckTests`).

- **API:** `SpeechAnalyzer` with `SpeechTranscriber` (macOS 26 and iOS 26), which the app already uses for transcripts (`SpeechAnalyzerEngine`), from a file the render wrote in the test's sandbox; no microphone.
  The app asks no permission for it, as `SpeechAnalyzerEngine` notes: Apple's permission covers `SFSpeechRecognizer`.
- **Model:** the English model must be installed (`AssetInventory`); on this Mac it is, and the tests never download it here; on a runner a download is possible but unmeasured (question 3).
- **Simulator:** `SpeechTranscriber.isAvailable` is false there, so no iPhone layer; `SFSpeechRecognizer` would need a permission prompt and `import Speech`, which the iPhone sound rule forbids.
- **Check:** words compared as `TranscriptAccuracyMeasurementTests` compares them; pass at a word error rate of 25% or less, and at least 85% of the text's words found in order.
  The Mac's voices measured 3.4 to 4.9%; B31's renders would have scored over 90% deletions.
- **Catches:** what length cannot: a passage left out and another said twice, the wrong voice's language, text the markup guard or the substitution rules silenced.
- **Cost:** about 5 s to load the model and 2 to 5 s for 60 s of audio; one branch.
- **Flakiness:** medium; a model update moves the words, so the text is plain and the tolerance loose.
- **Runs:** this Mac, opt-in (`TEXTMOUTH_REAL_TRANSCRIPTION`), and the runner if the probe of the first issue finds the recognizer there.

## Layer 7: fingerprints of real audio

Short renders kept as fingerprints, not as audio (`SpeechFingerprintTests`).

- **What is kept:** per OS and voice, for three fixed texts, the frame count, the sample rate, the segment count, and the RMS level of each 50 ms window, quantized to whole decibels: about 1 KB a text, in `TestData/speech-fingerprints/<os>/<voice>.json`.
  The audio itself (44 KB a second at 22,050 Hz) never goes in the public repository; a refresh run keeps it as a GitHub Actions artifact for 90 days, should anyone want to listen.
- **Compared:** length within 3%; the envelope correlated at 0.9 or more after the best shift of up to 200 ms.
- **Refresh:** `Scripts/test/speech-fingerprints.sh --record` on this Mac or by a request key on the runner, when an OS or a voice update moves them; one reviewed commit of JSON, as with the document goldens.
- **Catches:** a voice that changes, renders in another voice (Eddy's longest render came back at Samantha's rate and length on November 15), changes sample rate, or garbles audio.
- **Cost:** one branch and a recording script; under 2 s of tests.
- **Flakiness:** high across OS updates, by design; that is what it reports.

## No sound, no trap

- Every layer writes with `write(_:toBufferCallback:)` and never calls `speak`; the engine is never started on a device (layer 5 renders offline), and nothing records.
- A Personal Voice is never handed a synthesizer (`SystemSpeechBufferSynthesizer`'s `usableVoice(identifiedBy:)`), since it renders to the speakers.
- No force unwrap or unguarded subscript; every wait has a limit (30 s for a write, 60 s for a transcription), and a missing voice or model is a skip with one message.
- No layer reads `~/.TextMouth` or the user's books: the texts are fixed in the tests, and layer 5's book is built in the test's sandbox.

## Issues to file, in order

1. **Write traces replayed (layer 1).** The engine's render writes through `SpeechBufferWriting`; a trace reader and scripted writer; this probe's macOS 27 traces; replay tests of the render, the export, and `VoiceWarmUp`. Areas speech, audio, speech-export. Would have caught B31 everywhere.
2. **The write's contract and render completeness (layers 2 and 3).** `SpeechWriteContractTests` and `SpeechRenderCompletenessTests`; record the macOS 26 trace from the runner; fold the opt-in export test in. Areas speech, speech-export.
3. **A speech probe on the runner.** A request key `speech_probe` in `Scripts/agents/run-on-runner.py` (no `.github` change): which voices write, the contract, on `macos-26` and in the iOS simulator; whether `SpeechTranscriber` is available and how long an English model takes to download.
4. **The render's guard (layer 4),** after the user's answer to question 4. Areas speech, audio, reader-text.
5. **The iPhone's half** of layers 1 to 3, after issue 3 and question 5.
6. **The reader end to end (layer 5),** with the offline engine seam.
7. **Transcription (layer 6).**
8. **Fingerprints (layer 7).**

Issues 1 to 3 are each a branch and about one train; 4 and 6 are two.

## Questions for the user

1. May the real-synthesizer tests (layers 2 and 3, about 5 s, silent) run on this Mac in the merge suite and after each macOS update, while your TextMouth may be speaking? Recommended: yes, as the `speech-real` area, and in every GitHub train.
2. May fingerprints of a few KB per voice go in the repository, with no audio? Recommended: yes; the audio only as GitHub artifacts.
3. May a GitHub runner download Apple's English speech model for the transcription tests? Recommended: yes, on runners only, never on this Mac.
4. Should a render that ends short of its text be dropped for direct speech, with a log line? Recommended: yes.
5. May the iPhone unit bundle hold write-only speech tests, a named allowance in the sound rule like `makeReader`, checked to call no `speak` or `play`? Recommended: yes.
6. Should GitHub run the speech tests on a schedule, weekly, so a new runner image is tested without a commit? It needs a `.github` change at a release push. Recommended: yes, with TL26.

## Sources

- [Recognizing speech in live audio](https://developer.apple.com/documentation/speech/recognizing-speech-in-live-audio): the sample does not run in the iOS Simulator; `SpeechAnalyzer`, `DictationTranscriber`, and `AssetInventory` are 26, and `CaptureInputSequenceProvider` 27.
- [SpeechTranscriber on Simulator](https://developer.apple.com/forums/thread/802969): `SpeechTranscriber.isAvailable` is false in the iOS 26 simulator, `supportedLocales` empty.

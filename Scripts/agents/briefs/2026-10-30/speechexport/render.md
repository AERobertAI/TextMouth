# speechexport/render: a chapter spoken into a 16-bit CAF through a synthesizer seam (FMT43, step 2)

Slug `speechexport-render`; branch `speechexport/render`, made with `git checkout -b speechexport/render team/speechexport`. Team `speechexport`, lead `speechexport-lead`. Follow "The worker's part" of `Scripts/agents/briefs/2026-10-30/teams-common.md`, and the build section at the end of this brief, which overrides its build-folder rules.

## Goal

FMT43 exports a text book's speech as audio. This task speaks one chapter of the export (a title and its texts) into a 16-bit linear PCM CAF file, as `AudioEngineService` renders speech (`AVSpeechSynthesizer.write(_:toBufferCallback:)` on a fresh synthesizer, with the markup guard and its one strict retry), but at the export's own rate and pitch, set on the utterance as direct speech sets them, and through a seam so that **no test ever runs a real synthesizer or makes a sound**: tests use a fake that makes a quiet tone in memory. Two commits: the seam, then the renderer.

## Read first (only these, by line range)

- `TextMouth/Services/AudioEngineService.swift` 95-135 (`RenderCancellationObserver`, which you reuse as is), 976-1000 (`RenderGuard`), 1000-1220 (`render` and `write`: the fresh synthesizer, the semaphore, the zero-length last buffer, a refusal being a cancel the engine did not make).
- `TextMouth/Services/SpeechService.swift` 165-205 (`DirectSpeechChunk`), 326-330 (`SpeechRenderCoordinator.maximumTextLength`), 1141-1156 (`makeDirectUtterance`: rate, pitch, `prefersAssistiveTechnologySettings`), 2202-2205 (`clampedPitch`), 2302-2326 (`rateForWPM`).
- `TextMouth/ViewModels/ReaderViewModel+Playback.swift` 1700-1706 (`hasSpeakableText`).
- `TextMouth/Services/BookExportService.swift` 175-200 (`BookExportCancellation`).

## Commit 1: the seam, `TextMouth/Services/SpeechExport/SpeechBufferSynthesizer.swift` (new; create the folder if it is not there yet)

1. `struct SpeechExportUtterance: Equatable, Sendable`: `let text: String` (as the synthesizer is handed it, already guarded), `let voiceIdentifier: String`, `let rate: Float` (`AVSpeechUtterance.rate`), `let pitchMultiplier: Float`.
2. `enum SpeechWriteEnd: Equatable, Sendable { case finished; case refused }`: the synthesizer delivered its last buffer; or it cancelled the utterance on its own, the speech engine refusing the text.
3. `enum SpeechWriteFailure: Error, Equatable { case stalled; case unusableVoice }`.
4. `protocol SpeechBufferSynthesizing: Sendable` with one requirement:
   `func write(_ utterance: SpeechExportUtterance, cancellation: BookExportCancellation, onBuffer: @escaping (AVAudioPCMBuffer) throws -> Void) throws -> SpeechWriteEnd`
   Its contract, in its doc comment: speaks the utterance into buffers, never aloud; hands each buffer to `onBuffer` one at a time, in order; blocks the calling thread until the last buffer or a refusal (call it off the main thread); throws `CancellationError` once `cancellation` is cancelled (noticed within a quarter of a second), `SpeechWriteFailure.stalled` when no buffer came for the stall limit, `.unusableVoice` for a voice it may not use, or what `onBuffer` threw (the write then stops); and **after it returns or throws, `onBuffer` is never running and is never called again**.
5. `struct SystemSpeechBufferSynthesizer: SpeechBufferSynthesizing`, the app's, with `static let stallLimit: TimeInterval = 60`:
   1. Resolve `AVSpeechSynthesisVoice(identifier: utterance.voiceIdentifier)`. Nil, or a voice whose `voiceTraits` contain `.isPersonalVoice`, throws `.unusableVoice` before any synthesizer exists: a Personal Voice renders to the speakers instead of buffers (research 7.5), and a nil voice would be the system's default, which can be one. Never hand a synthesizer a nil voice.
   2. A fresh `AVSpeechSynthesizer` per write; an `AVSpeechUtterance` of `utterance.text` with that voice, `rate`, `pitchMultiplier`, and `prefersAssistiveTechnologySettings = false`; a `RenderCancellationObserver(waking:)` as the delegate (held until the write ends), so a refusal wakes the wait.
   3. In the write's callback, under one lock: ignore anything that is not an `AVAudioPCMBuffer`; a zero-length buffer is the last: signal the wait; otherwise, unless the write has ended, call `onBuffer` (synchronously, as `AudioEngineService` copies its pieces in the callback) and note the time; an error from it is kept, ends the write, and signals the wait.
   4. The calling thread waits on the semaphore in slices of 0.25 s. Between slices: a cancelled `cancellation` ends the write, stops the synthesizer (`stopSpeaking(at: .immediate)`), and throws `CancellationError`; no buffer for `stallLimit` seconds (counted from the write's start until the first) ends it, stops the synthesizer, and throws `.stalled`.
   5. "Ends the write" means setting the ended flag under the same lock the callback holds while it calls `onBuffer`, so the contract's last sentence holds even though the synthesizer may call back after `stopSpeaking`.
   6. Once woken: a kept `onBuffer` error is thrown (after stopping the synthesizer); a cancel that this write did not make (the observer's `wasCancelled`) returns `.refused`; otherwise `.finished`. Clear the delegate before returning.
   7. Avoid `@unchecked Sendable` and `nonisolated(unsafe)`: the struct has no stored state; the lock-protected state can be a small final class with an `NSLock`, captured by the callback, as `AudioEngineService` captures its builder. If you cannot avoid either, say why in a comment and run `UncheckedConcurrencyPolicyTests`.

## Commit 2: the renderer, `TextMouth/Services/SpeechExport/SpeechChapterRenderer.swift` (new)

1. `enum SpeechRenderFailure: LocalizedError, Equatable` with these cases and exactly these `errorDescription`s (curly quotes as shown):
   - `refused(String)`: "The Mac's speech engine refused to speak part of “\(title)”, even with its brackets made silent."
   - `noSound(String)`: "The voice made no sound for “\(title)”. Check that the book's voice speaks the book's language."
   - `stalled(String)`: "The voice stopped partway through “\(title)” and made no sound for a minute."
   - `formatChanged(String)`: "The voice changed its kind of audio partway through “\(title)”."
   - `unusableVoice`: "The book's voice can't be recorded to a file. Choose another voice for this book with the Voice button in its reader, then export again."
2. `struct RenderedSpeechChapter: Equatable, Sendable { let frameCount: Int64; let sampleRate: Double; let channelCount: Int }`.
3. `enum SpeechChapterRenderer` with
   `static func render(title: String, texts: [String], voiceIdentifier: String, wordsPerMinute: Double, pitch: Double, trailingSilence: TimeInterval, to url: URL, synthesizer: any SpeechBufferSynthesizing, maximumUtteranceLength: Int = SpeechRenderCoordinator.maximumTextLength, cancellation: BookExportCancellation, framesWritten: (Int64) -> Void = { _ in }) throws -> RenderedSpeechChapter`
   1. `url` has the extension `caf` (AVAudioFile infers the file type from it) and nothing is there yet.
   2. Each text is cut into utterances with the reader's own chunking, `DirectSpeechChunk.starting(at:in:maximumLength:)` with `maximumUtteranceLength` (the engine renders a whole chapter of up to 100,000 units as one utterance, so most chapters are one utterance and keep their intonation whole), going on from each chunk's `end` while `isPartial`; a chunk with nothing speakable (`ReaderViewModel.hasSpeakableText`) is passed over.
   3. Each utterance: text `AudioEngineService.RenderGuard.markup.apply(to: chunk)`, the voice, `rate: SpeechService.rateForWPM(wordsPerMinute)`, `pitchMultiplier: Float(SpeechService.clampedPitch(pitch))`.
   4. `.refused` before this utterance wrote any frame: write it once more with `RenderGuard.everyBracket.apply(to: chunk)`. Refused again, or refused after it wrote a frame (its audio cannot be taken back): throw `.refused(title)`.
   5. Buffers go into a 16-bit linear PCM CAF made at the first buffer: `AVAudioFile(forWriting: url, settings: [linear PCM, the buffer's sample rate and channel count, 16 bits, integer, little-endian, interleaved], commonFormat: <the buffer's>, interleaved: <the buffer's>)`. A later buffer of another sample rate, channel count, common format, or interleaving throws `.formatChanged(title)`. `framesWritten` hears the chapter's total after each buffer.
   6. `SpeechWriteFailure.stalled` becomes `.stalled(title)`, `.unusableVoice` becomes `.unusableVoice`; other errors pass as they are.
   7. No frame after every utterance: throw `.noSound(title)`.
   8. Then `trailingSilence` seconds of zero frames (rounded to whole frames at the file's rate; zero the buffer's memory yourself).
   9. The file is closed before returning (`close()` where available, macOS 15; on macOS 14 the `AVAudioFile` must be released, so keep it in a scope or an optional you set to nil), so the caller may rename it at once.
   10. Any throw, `CancellationError` included, first removes whatever is at `url`.
   11. Returns the frames written (speech and silence), the sample rate, and the channel count.

Comment every type, property, and function, and each non-obvious block.

## Tests

### `TextMouthProductionTests/FakeSpeechBufferSynthesizer.swift` (new test support; later tasks reuse it, so keep its interface as given)

`final class FakeSpeechBufferSynthesizer: SpeechBufferSynthesizing`, Sendable without `@unchecked` (its configuration in `let`s of Sendable types, its record in an `OSAllocatedUnfairLock`):
- `init(framesPerUnit: Int = 40, pieceFrameCount: Int = 2_205, commonFormat: AVAudioCommonFormat = .pcmFormatFloat32, sampleRate: @escaping @Sendable (SpeechExportUtterance) -> Double = { _ in 22_050 }, refuses: @escaping @Sendable (SpeechExportUtterance) -> Bool = { _ in false }, beforeWrite: @escaping @Sendable (SpeechExportUtterance) -> Void = { _ in })`.
- `write`: records the utterance; calls `beforeWrite`; returns `.refused` with no buffer when `refuses`; otherwise throws `CancellationError` if cancelled, then hands `onBuffer` `utf16 count × framesPerUnit` frames of a quiet 440 Hz tone (amplitude 0.1), mono, in the given common format, in buffers of `pieceFrameCount` frames, on the calling thread, checking the cancellation before each; returns `.finished`.
- `var written: [SpeechExportUtterance]`.

### `TextMouthProductionTests/SpeechChapterRendererTests.swift` (new)

Every file goes in a sandbox folder (`makeSandboxDirectory`). Pin at least:
1. Two texts make one CAF of 16-bit integer linear PCM at 22,050 Hz, one channel (`AVAudioFile(forReading:)`'s `fileFormat`), whose length is the fake's frames plus the silence; the result says so; the utterances' texts are the guarded chunks, with the voice, `rateForWPM(250)`, and `Float(clampedPitch(1.3))`.
2. A text longer than `maximumUtteranceLength` (pass 50) is spoken in the reader's chunks: the utterances are exactly `DirectSpeechChunk`'s, no word cut; a chunk of white space alone is not spoken.
3. A refused utterance is written once more strictly guarded, and the chapter is made; refused twice throws `.refused(title)` and leaves no file.
4. Stop (`beforeWrite` cancelling the token at the second utterance) throws `CancellationError` and leaves no file.
5. A voice that makes no frames (`framesPerUnit: 0`) throws `.noSound(title)`; a second utterance at 24,000 Hz throws `.formatChanged(title)`; 16-bit buffers (`.pcmFormatInt16`) are written too.
6. `framesWritten` rises with each buffer and ends at the speech's frames.
7. Every failure's words, exactly.
8. `SystemSpeechBufferSynthesizer` given an identifier no voice has throws `.unusableVoice` (no synthesizer is made, so nothing speaks).
9. Opt-in, skipped (`XCTSkip`) unless the environment has `TEXTMOUTH_REAL_SPEECH_EXPORT=1`: `SystemSpeechBufferSynthesizer` writes "TextMouth wrote this sentence to a file." in the first installed `en-US` voice (`AVSpeechSynthesisVoice.speechVoices()`) that is neither a Personal Voice nor a novelty voice (skip when there is none; never the default voice) into a CAF through `SpeechChapterRenderer`; frames > 0; it prints how many seconds of audio a second of rendering made. Writing to buffers never sounds aloud; never pick a Personal Voice.

## Run

`SpeechChapterRendererTests export speech`. Report the exact `Executed N tests, with S tests skipped and F failures` line.

## Do not

- Touch `AudioEngineService.swift`, `SpeechService.swift`, or any reader file: reuse `RenderCancellationObserver`, `RenderGuard`, `DirectSpeechChunk`, `rateForWPM`, and `clampedPitch` as they are.
- Use a real `AVSpeechSynthesizer` in any test but the opt-in one; touch Personal Voice anywhere; play a sound.
- Read or write anything under `~/.TextMouth`. Edit any `*.md` file, or any file not named here.

## Build and test (this team's rules; they override teams-common.md's build folder rules)

- The team shares ONE build folder, used by one teammate at a time: `/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-speechexport`. Never make another and never delete it: the lead deletes it at the end.
- Disk: before each build, `df -g /System/Volumes/Data` must show at least 2 GB available when that folder exists, 5 GB when it does not. Otherwise post to `speechexport-lead` and wait (`python3 .claude/skills/agent-bbs/scripts/bbs.py watch <slug> --timeout 600`), then check again.
- Build in the background, through the team's lock, which queues you behind a teammate's build (waiting is normal):
  `BBS_AGENT=<slug> /usr/bin/lockf -k /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-speechexport-build.lock python3 Scripts/test/run-area.py --derived-data /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-speechexport --log <your scratchpad>/<slug>-run.log <names>`
  Check on it no more often than every 4 minutes, with one short command.
- New files need `/opt/homebrew/bin/xcodegen generate`; commit the regenerated `TextMouth.xcodeproj/project.pbxproj` with them.
- Before reporting, `make lint-tests LINT_BASE=team/speechexport` must be clean, and the build must add no Swift warning.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

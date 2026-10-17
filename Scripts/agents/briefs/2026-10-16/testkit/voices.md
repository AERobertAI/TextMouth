# testkit/voices: a voice sweep, every installed voice rendered offline

Slug `testkit-voices`. Branch `testkit/voices`, made from `team/testkit` AFTER `testkit/runner` was integrated (`Scripts/test/run-area.py` exists on your branch; if it does not, build the Swift part first and rebase for the script). You build; at most two builders run at once. Read `teams-common.md`'s worker's part first.

## Why

TODO P09 (TODO-2026-09-04.md line 3483) asks to validate speech on the supported voices and routes. The route part (Bluetooth, disconnects) needs hardware. The scriptable part: for every voice installed on this Mac, does TextMouth's offline render path (`AVSpeechSynthesizer.write`, which never plays aloud) produce audio for a fixed sample, how long is it, and does any voice hang, refuse, or fail? Voices differ by Mac and by what the user downloaded; some novelty and premium voices are known to hang or to produce nothing. The user wants a plain report per voice that he can run on his own Mac after installing voices or updating macOS.

## Ground truth

- `TextMouthProductionTests/SpeechMarkupGuardTests.swift:511-` `OfflineRenderProbe`: a test double that renders one text offline with `synthesizer.write(utterance)`, counts the frames, and hears how the render ended (`End.finished` / `.cancelled`; cancelled with no frames is a refusal), on whatever thread the synthesizer reports. Read its whole body (about 70 lines) and `:480-509` (a helper that waits for a render with a timeout). It counts frames only: for a duration you need the sample rate. You may add, in ONE additive commit of its own, a `sampleRate` property and a `buffers` count to `OfflineRenderProbe` (recorded from the first/each `AVAudioPCMBuffer`: `pcm.format.sampleRate`, under the same lock); nothing existing may change behavior, and `SpeechMarkupGuardTests` must pass unchanged afterwards. Do not copy the class.
- Voices: `AVSpeechSynthesisVoice.speechVoices()` (the app lists them through `VoiceCatalog.installedVoices()`, TextMouth/Services/VoiceCatalog.swift:129). A voice has `identifier`, `name`, `language`, `quality` (`.default`, `.enhanced`, `.premium`), `gender`.
- How the app renders: `TextMouth/Services/AudioEngineService.swift:1139` and `SpeechService.swift:490`. The sweep uses the same call.
- Some voices hang. A hung voice must cost one watchdog interval, not the run, and a speech service wedged by one voice must be noticed.

## What you build

1. `TextMouthProductionTests/VoiceSweepReport.swift`: a pure type, no synthesizer.
   - `VoiceSweepSample.text`: the fixed sample, in one constant, composed of: numbers and a time and date (`"The ferry leaves at 3:45 p.m. on March 14, 2026, from berth 12; call 555-0134 for 2 or 3 spare seats."`), punctuation (`"Wait... what?! He said (quietly) that it cost $4.50 - or was it 4,50 euros?"`), a bracketed aside (`"[An aside, in brackets, that the speech should handle.]"`), and one long sentence of about 60 words with commas. You may improve the wording; keep all four parts, keep it under 700 characters, and keep it the same on every run.
   - `struct VoiceSweepResult`: voice identifier, name, language, quality, outcome (`ok`, `no audio`, `timed out`, `stopped early`), buffers, frames, sample rate, duration seconds (frames / sample rate), wall seconds, and a note.
   - `VoiceSweepReport.markdown(results:macOS:date:sample:)`: Markdown to be read with VoiceOver and a braille display: `# Voice sweep`, the Mac's OS version and date and the sample text, a counts line `N voices: A ok, B no audio, C timed out, D not tried`, then `## Problems` listing every voice that was not `ok` (name, language, quality, identifier, outcome, note), then `## Voices` with one `### <name> (<language>)` per voice and bullet lines (`Identifier:`, `Quality:`, `Outcome:`, `Duration:`, `Buffers:`, `Time taken:`). No tables, no emoji, no color, outcomes in words.
   - the circuit breaker: `VoiceSweepBreaker`, which says `shouldStop` after 3 timeouts IN A ROW (a wedged speech service); the remaining voices are reported `not tried`, and the report says why.
2. `TextMouthProductionTests/VoiceSweepReportTests.swift`: unit tests of the above with synthetic results (no synthesizer, always on): the counts line, the problems section lists exactly the not-ok voices, a name with a quote or a slash, the breaker trips on 3 in a row and resets on a success, the report for zero voices says so, and the sample contains digits, a bracket pair, and more than 50 words.
3. `TextMouthProductionTests/VoiceSweepTests.swift`: `final class VoiceSweepTests: XCTestCase` with `testSweepEveryInstalledVoice`, which throws `XCTSkip("Set TEXTMOUTH_VOICE_SWEEP=1 to render every installed voice offline.")` unless `TEXTMOUTH_VOICE_SWEEP` is `1`. It renders the sample with each voice, one voice at a time, with the probe and a fresh `AVSpeechSynthesizer`, with the watchdog `TEXTMOUTH_VOICE_SWEEP_SECONDS` (default 20) per voice; on a timeout it calls `stop()` and records `timed out`. Filters: `TEXTMOUTH_VOICE_SWEEP_LANGUAGE` (a prefix such as `en`) and `TEXTMOUTH_VOICE_SWEEP_VOICES` (comma-separated identifiers). It writes the report to `TEXTMOUTH_VOICE_SWEEP_REPORT` (default: a file in the test sandbox, and the path printed as `VOICE SWEEP REPORT: <path>`) **after every voice** so a crash or a hang leaves a usable partial report. The test never fails because a voice is bad (the report is the product); it fails only if the sweep itself could not run (no voices at all at the start, the report not writable). No test plays sound: only `write(...)`, never `speak`.
4. `Scripts/test/voice-sweep.sh [report.md]` (bash, header comment doubling as `-h`, style of `Scripts/perf-baselines.sh`): the report path defaults to `${TMPDIR}textmouth-voice-sweep.md`; runs `python3 "$(dirname "$0")/run-area.py" --classes VoiceSweepTests --env TEXTMOUTH_VOICE_SWEEP=1 --env TEXTMOUTH_VOICE_SWEEP_REPORT=<absolute path>`; then prints the report's path and its counts line; exit status is the runner's. Extra environment variables for the filters are passed through by the runner's `--env`: document them in the header (`VOICE_SWEEP_LANGUAGE=en Scripts/test/voice-sweep.sh` style: the script turns each of the three variables, if set in its own environment, into an `--env`).

## Tests to run

`VoiceSweepReportTests`, `VoiceSweepTests` (skip line shown), `SpeechMarkupGuardTests` (if you touched the probe). Then ONE real run: `VoiceSweepTests` with `TEXTMOUTH_VOICE_SWEEP=1` and `TEXTMOUTH_VOICE_SWEEP_LANGUAGE=en` through the script. Read the report; describe which voices were not ok and how long the run took. Do not run the sweep over all languages unless the English run took under 5 minutes.

## Do not

Call `speak`, play a buffer, or open an audio output. Edit any existing test except the additive probe change above. Read the user's library. Let a test trap (the buffer callbacks run on other threads: touch shared state only under the probe's lock; no force unwrap; no `[0]`).

## Commits

1. (optional) the additive probe change.
2. `VoiceSweepReport`, the breaker, and `VoiceSweepReportTests`.
3. `VoiceSweepTests`.
4. `Scripts/test/voice-sweep.sh`.

## Report (at most 15 lines)

Branch; commits; exact result lines; the real English run's counts line, the problem voices, and the time taken; what you could not verify (other languages).

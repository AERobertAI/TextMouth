# speechexport-harness: a scratch harness that runs the speech export for real (FMT43), November 7, 2026

Slug `speechexport-harness`; branch `speechexport/harness`, made with `git switch -c speechexport/harness speechexport/finish` as your very first command (your worktree starts at an old commit). Lead: `speechexport-lead2`. You change no tracked file and commit nothing unless the lead asks. Everything you make goes in your own worktree's gitignored folder, `<your worktree>/build/harness/`.

## Why

TextMouth is a native macOS and iOS text-to-speech and audiobook reader whose user is blind and reads with VoiceOver and braille. FMT43 speaks a text book, or a range of its headings, into one M4B, M4A, or MP3 with a chapter per heading. Every test so far runs a fake synthesizer. Nobody has run the real path with a real voice, or a book with very many headings. Your job is to measure both, with no sound and nothing touching the user's data, and to give the lead numbers. Later the lead will send you a list of deliberate breaks of the code (mutations) to run in the same harness, to prove the tests fail when the code is wrong: that is why the harness runs real test classes and not only a program of its own.

## The rules (the orchestrator's, word for word)

- **Nobody deletes anything tonight.** No `rm` at all, not even with a relative name, and no deleting from scripts. A prompt about an `rm` woke the user and stopped things. Overwrite files in a fixed folder instead, and the orchestrator clears scratch folders at the end. Git branches you made yourself are fine to leave in place.
- **Keep shell commands plain.** Nested `${...}`, a substitution in a redirect, or a long chain can stop at a permission prompt only the user can answer. Use a small Python script run with `python3 -I -B` for anything fancy.
- **Disk is tight.** Keep each agent's scratch under 500 MB.
- **Never read, stat, or copy the user's live library:** `~/.TextMouth`, anything under `~/Library/CloudStorage/`, or any data directory the settings name.
- No test may trap, hang, play sound aloud, or use a microphone. Every wait has a limit. Never play, probe, or decode Ogg through Apple's frameworks in-process.
- Never push, never `make install`, and never merge into main.
- Nobody runs xcodebuild directly: tests go through the build train, and `make typecheck-mac` and `make typecheck-ios` take the machine's lock themselves.
- A new agent's worktree starts at origin/main from October 3: switch onto the branch named above first.

And these, from the briefs of this campaign:
- **Heavy work takes the lock.** Every `swift build`, `swift test`, and run of your harness goes under `python3 -I /Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/followups1105/run_locked.py speechexport-harness <command...>`. It waits its turn; that is normal. The Mac has 8 GB of memory. Run them in the Bash tool's background mode (you are told when each ends), one at a time. Never wrap `make typecheck-*` in it.
- Python tools write no bytecode. Use `-I -B`.
- Use absolute paths and `git -C <path>`, since your shell's working directory resets. `sed` here is GNU sed; use Python for in-place edits.
- Check `df -g /System/Volumes/Data` before a build: below 3 GB free, post to the lead and wait.
- Edit no `*.md` file. Ask nothing of the user. Questions go to `speechexport-lead2` with SendMessage if you have it, else `python3 .claude/skills/agent-bbs/scripts/bbs.py post speechexport-harness --to speechexport-lead2 --tag question --topic "..."`, and you carry on with the safest choice.
- Register on the board: `python3 .claude/skills/agent-bbs/scripts/bbs.py register speechexport-harness --role "Scratch harness for FMT43's real voice and scale" --branch speechexport/harness --files 'build/harness/**'`.

## The harness

Model it on `Scripts/ios/typecheck.py` (read `prepare_sources` and `write_package`). A Python script of yours, kept in `<your worktree>/build/harness/`:

1. Copies the committed sources of a given commit (`git archive <commit> TextMouth Vendor TextMouthBraille TextMouthProductionTests`, by default the tip of `speechexport/finish`) into `build/harness/src`. Overwrite in place: to refresh a file, write it again. Do not delete folders. If a commit's files must replace older ones, extract over them.
2. Copies `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/typecheck/macos/pkgs` (36 MB: ZIPFoundation, SwiftSoup, swift-markdown, cmark) once into `build/harness/pkgs`.
3. Writes `build/harness/src/Package.swift`: `typecheck.py`'s package for macOS (the `LAME` and `ObjCExceptionCatcher` targets, the `TextMouth` executable target, excluding `Resources` and `Platform/iOS`, and the braille `-I` flag), plus one `.testTarget` named `SpeechHarnessTests` depending on `TextMouth`, whose `path` is a folder of yours that holds copies of the test files the lead names and your own tests, or `sources:` naming them.
4. Builds with `swift test --scratch-path build/harness/spm -j 2 -Xswiftc -gnone --filter <classes>`, with the macOS SDK as `typecheck.py` passes it (`--sdk`). `-gnone` drops the debug information, which keeps the folder small; the aim is under 500 MB, and if it cannot stay under 700 MB say so to the lead. `@testable import TextMouth` works on an executable target on macOS.

### The isolation switch comes first (this is what keeps the user's library safe)

The app decides where its data lives in `TextMouthRuntime.current` (`TextMouth/App/TextMouthRuntime.swift`), from the environment variable `XCTestConfigurationFilePath`, which xcodebuild sets for hosted tests and `swift test` does not. Without it, `TextMouthPaths.root`, the debug log, and the preferences are the user's real ones. So your script patches **the copy only** so that it can never be anything but the sandbox:

- In `build/harness/src/TextMouth/App/TextMouthRuntime.swift`, `detect(environment:processIdentifier:temporaryDirectory:)` begins `guard environment[testConfigurationVariable] != nil else {`. Your script replaces that line with `guard true else {`, checks that it found it exactly once, and stops with an error otherwise. The repository's file is never changed. The script does this every time it copies sources.
- The first test you ever run, and the first in every class you write, is a check that `TextMouthRuntime.current.isHostedTest` is true and `TextMouthRuntime.current.homeDirectory.path` is under `FileManager.default.temporaryDirectory.path`; when either is not so it prints why and calls `exit(3)`, doing nothing else. Run that one test alone first and print the home it found.
- Nothing you write reads `~/.TextMouth`. A test process that is not sandboxed must end at once.

The fixtures you will need from `TextMouthProductionTests/`: `FakeSpeechBufferSynthesizer.swift`, `HostedTestIsolationSupport.swift`, `IntegrationTestSupport.swift`, `AccessibilityTestSupport.swift` and whatever they pull in; let the compiler tell you, and keep the set small. Tests that draw windows (`withHostedView`) are left out: only tests of the job, the store, the encoder, the text, the options' state, and the dialog's model run here, since a window in a process with no application could trap, and a trap puts a Problem Report on the user's screen.

## First: run the existing classes

`SpeechExportJobTests`, `SpeechExportEncoderTests`, `SpeechExportTextTests`, `SpeechChapterRendererTests`, `SpeechExportSupportTests` and `SpeechExportServiceTests`, as many as compile without windows. Report the `Executed N tests` line. A class that needs a window stays out, and you say which.

## Then: the measurements (your own tests, in your harness only)

**Sound.** `AVSpeechSynthesizer.write(_:toBufferCallback:)` plays nothing; it is what the reader uses to render chapters. A Personal Voice is the one exception: it can speak aloud. So every test picks voices from `AVSpeechSynthesisVoice.speechVoices()`, refuses any with `.isPersonalVoice` or `.isNoveltyVoice` in `voiceTraits`, and only ever calls `SystemSpeechBufferSynthesizer` or the renderer, never `speak`. Never create an `AVAudioPlayer`, an `AVAudioEngine`, or anything else that plays.

**A. The real voice, end to end.** Run `SpeechExportJob.run` with `SpeechExportEnvironment` holding `SystemSpeechBufferSynthesizer()`, `SpeechExportVoiceInfo.installed`, a power that records (no real assertion), real free space, `ImportScratchSpace.areOnSameVolume`, and a store root in the sandbox, on a small Markdown book (as `SpeechExportJobTests` makes one: a few hundred words over four headings). For the first installed en-US voice that is allowed:
1. M4B, M4A, and MP3: each file's duration, size, and chapters (`AudioPlaybackService.extractChapters(from:)`), each chapter's start against the frames of its CAF. Keep one CAF's format: its sample rate, channel count, and the buffers' common format and interleaving (print them from a small synthesizer wrapper of yours).
2. Rate: the same text at 100, 200, 400, and 650 words a minute: the duration of the speech at each, and words a minute actually heard (words over seconds). Say whether the Rate slider's number is what comes out, and how far off.
3. Pitch: 0.5, 1, and 2 at one speed: durations (should barely change) and an estimate of the pitch, such as counting zero crossings a second over the voiced part.
4. Speed: seconds of audio a second of rendering, for each of up to five different allowed voices, the first of each quality (`.default`, `.enhanced`, `.premium`) if installed. Also each voice's sample rate.
5. Stop: a `BookExportCancellation` cancelled after one second, in the middle of a long chapter: how long until `run` throws, and what it leaves.
6. A text the speech engine refuses, such as one full of angle-bracket tags (`<sm> <foo bar="1"> a < b`): whether it is refused, and what the guard's retry does (`AudioEngineService.RenderGuard`, `SpeechMarkupGuard`).

**B. One long chapter.** A section of 100,000 UTF-16 units (one utterance, the renderer's limit), then 250,000 units (three utterances), of ordinary sentences, at 200 words a minute, on the first allowed voice and on the slowest one found in A4: the time until the first buffer (the synthesizer's stall limit is 60 seconds, `SystemSpeechBufferSynthesizer.stallLimit`, measured from a write's start to its first buffer and from each buffer to the next: **does a real long text stay inside it?**), the longest gap between two buffers, the total time, and the process's peak resident memory. Give each run a limit: cancel it after 15 minutes and report how far it came.

**C. Very many headings.** With the fake synthesizer (no real voice), a Markdown book with 300, then 1,000, then 3,000 headings, each with one short sentence, and a `framesPerUnit` that makes each chapter under a second: M4B and MP3 through `SpeechExportJob.run`. First lower the process's soft limit on open files to 256 with `setrlimit(RLIMIT_NOFILE)`, which is what an app launched from the Finder gets, and print what the limit was before. For each: did it succeed; the time of the speaking and of the encoding; the most file descriptors open (sample `proc_pidinfo` or count `/dev/fd` from a timer every 100 ms, at no cost to the work); peak memory; and whether every chapter is in the result (`extractChapters`' count and first and last titles). If one fails, give its exact error, and find roughly the count where failures begin. **This is the question the lead most needs answered:** `AudioEditComposition.make` keeps one `AVURLAsset` for each chapter file, and a book can have thousands of headings.

Every test has a limit, and every wait inside it too. Every output file stays in the sandbox or `build/harness/`.

## Your report

At most 60 lines, as your final message: the harness's path and how to run a class in it; what compiled and what you left out; the measurements above as plain lines of numbers, each saying which voice and which sizes; everything surprising; the disk the harness takes; and whatever you could not do. Do not fix anything in the app: report it. The lead may then message you with mutations to run, so keep the harness in place.

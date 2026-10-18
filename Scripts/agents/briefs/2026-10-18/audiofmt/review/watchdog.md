# Review fix watchdog: no lying header and no endless output fills the disk (review items 4, 9, 8)

Slug `audiofmt-watchdog`, branch `audiofmt/watchdog` made from `team/audiofmt`. Read `../common.md`, then `common.md` in this folder, then this brief.

## Item 4 (medium): a lying header removes the time limit
A 136 KB CAF whose data chunk claims 2^50 bytes makes afinfo report 25.5 billion seconds. `AudioFileInfo` takes any duration above zero (`TextMouth/Services/AudioFileInfo.swift` about line 129), the converter's `maximumSeconds` (`ImportAudioConverter.swift` about lines 416-426: `60 + duration / 10`) becomes about 2.6e9, and afconvert reserves output in proportion, over 200 MB at once. The review's files: `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/8d971e15-7103-46cf-b45e-5c4d099f2f74/scratchpad/review-audiofmt-c/absurd/` and `bigcaf*.sh` beside it.
1. **Bound the claimed length** in `AudioFileInfo`, with the file's size. A duration is believed only when it is at most one year (as `OggHeaderReader`'s `maximumDuration`) and at most the file's size in bits divided by the codec's lowest plausible bit rate:
   - linear PCM: exactly sample rate × channels × bits a sample (32 for floating point), with 1% and one second of slack;
   - by `formatID` otherwise: `samr` 4,750 b/s; `sawb` 6,600; `opus` 6,000; `aac ` and the other AAC forms 8,000; `.mp3` and `.mp2` 8,000; `.mp1` 32,000; `ac-3` and `ec-3` 32,000; `ima4` 4 bits a sample and channel; `ulaw` and `alaw` 8 bits a sample and channel; `alac`, `flac`, and any other 1,000.
   Beyond the bound `read` returns nil and logs `AUDIO_INFO_IMPLAUSIBLE: <file>: claims <N> seconds in <M> bytes`; the import then refuses the file as any unreadable one ("The audio file X could not be read for converting.").
2. **An output cap in `WatchedProcess`.** `Limits` gains `maximumOutputBytes: Int64?` (nil means no cap). The watchdog kills a child whose watched file has passed it, with a new `KillReason.wroteTooMuch(bytes:)` whose words are "its output passed 120 MB" (whole megabytes, as `usedTooMuchMemory` counts them). A listener then hears "Converting X was stopped because its output passed 120 MB.": pin it.
3. **The converter's cap**, only once task `channels` is on `team/audiofmt`: your lead posts it; then rebase onto `team/audiofmt`, ask for a second turn, and wire it. Each afconvert step's limits cap its output at four times its expected size plus 16 MB: AAC, duration × bit rate ÷ 8 (320,000 b/s where the encoder chooses its own); Apple Lossless and the downmix's PCM, duration × rate × channels × bytes a sample.

## Item 9 (low): captured output
`runCapturingOutput` (`TextMouth/Services/WatchedProcess.swift` about lines 230-275) lets a child write any amount to its stdout file, and that file's growth resets the stall clock.
- **Cap the stdout file itself** at `maximumOutputBytes` (which today only trims what is returned): the child is killed at the cap (`wroteTooMuch`), and the bytes up to the cap are still returned.
- **Output is not progress.** For `runCapturingOutput` the stall clock runs from the child's start, whatever it prints: afinfo prints only at its end, and its stall allowance is its time limit.
- **Each test its own folder.** The stdout file's folder becomes a parameter (`outputFolder`, the temporary directory by default), and `WatchedProcessSafetyTests` (about lines 338 and 356, which count `.watched-output` files in the shared temporary folder, a flake of review item 14) give each test its own.
- **The launch sweep.** At launch, remove `.<UUID>.watched-output` files older than an hour from the temporary directory (a test host and the user's TextMouth share it, so a newer file may be another copy's), and kill an orphaned afinfo: add it to `OrphanedConversionSweep` beside afconvert and textutil, as `/usr/bin/afinfo`, run by the current user, with parent pid 1, whose standard output (descriptor 1, read with `proc_pidfdinfo` and `PROC_PIDFDVNODEPATHINFO`) is a `.watched-output` file. Find where the launch runs the sweeps (`grep -rn "sweepInBackground\|sweepTextutilInBackground" TextMouth`), and add yours there, with its log line.

## Item 8 (low): Cancel cannot stop a running conversion
`TextMouth/Services/FileImportService+AudioConversion.swift` (about line 109) waits with `AsyncBridge.waitForResult` and no cancellation. Pass `cancelledBy: ImportCancellation.current`, read on the import's own thread before the wait, as `TextMouth/Services/TextutilConverter.swift` lines 215-235 do, and turn the resulting `CancellationError` into `ImportCancelled()` the same way.

## Tests
- A CAF whose data chunk claims 2^50 bytes (written in the test; `bigcaf.py` shows how) is refused by `AudioFileInfo.read`, with the log line, and a real short CAF is not. Pure tests of the bound for PCM, for a table codec, and at one year.
- `WatchedProcess.run` kills a stand-in that writes past `maximumOutputBytes` to its watched file (`/bin/sh -c` with a loop of `printf` into it), with `wroteTooMuch`; and the words.
- `runCapturingOutput` kills `/usr/bin/yes` at the cap and returns the first bytes; a child that prints a line a second without end is still killed at its time limit.
- The sweep's afinfo rules (a pure test over `ProcessSnapshot`s, as the existing sweep tests do), and the leftover files' age rule.
- An import of a folder of tracks whose conversion is a stand-in that sleeps ends at once when cancelled, as a cancelled import ends, with nothing left behind (`grep -ln "ImportCancellation" TextMouthProductionTests/*.swift` for the existing way).

## Commits
1. Item 4's bound. 2. Item 4's cap in `WatchedProcess`, with item 9's stdout cap, clock, and folder. 3. Item 9's sweeps. 4. Item 8. 5. Later, item 4's cap of the converter's steps.

## Test classes (one run each, in your turn)
`AudioFileInfoTests`, `WatchedProcessSafetyTests`, `OrphanedConversionSweepTests`, `OggAfconvertTests`, `ImportAudioFormatsTests`, `OggImportConversionTests`, and the import cancellation classes.

## Do not touch
`afconvertArguments`, `target(for:bytes:)`, and `convert(_:naming:using:)` (task `channels`'), the "Which Files" section of `ImportAudioConverter.swift` (task `sniff`'s), `M3UPlaylist.swift`, and any `*.md`.

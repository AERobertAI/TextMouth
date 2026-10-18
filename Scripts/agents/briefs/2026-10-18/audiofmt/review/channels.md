# Review fix channels: every channel count converts (review item 1, high)

Slug `audiofmt-channels`, branch `audiofmt/channels` made from `team/audiofmt`. Read `../common.md`, then `common.md` in this folder, then this brief.

## The bug
`ImportAudioConverter.afconvertArguments(from:to:info:target:)` (`TextMouth/Services/ImportAudioConverter.swift`, about lines 376-401) passes `-c 2` to the AAC encoder for a source of more than two channels. afconvert then exits 1 ("ExtAudioFileSetProperty ('cclo') failed") for 3.0 and 5.1 AC-3, 5.1 E-AC-3, and 5.1 PCM, so most real AC-3 and E-AC-3 files are refused. The Apple Lossless path's `-c 8` fails the same way above eight channels. `--mix`, `-l Stereo`, and `-m 0 2` do not help. The review's samples and scripts: `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/8d971e15-7103-46cf-b45e-5c4d099f2f74/scratchpad/review-audiofmt-c/` (`center.sh`, `center5.sh`, `many.sh`, and the `center/` folder).

## The decision (settled; say it and why in the doc comments)
**TextMouth writes at most two channels.** A source of more than two channels, lossy or lossless, is mixed down to stereo; mono and stereo are written as they are. Why: an audiobook is one listening stream. A film's or a radio drama's dialogue lives in the centre channel, and a stereo mix puts it in both ears on every path (the player, the editor, transcription, MP3 export), so none of them meets more than two channels.

What your lead measured on this Mac (macOS 26.3.1): `afconvert -f caff -d LEI16 -c 2` mixes any layout down to stereo PCM in one step (3.0 and 5.1 AC-3, 5.1 E-AC-3, and a 10-channel Wave64 all work), and AAC from that stereo file works. Apple Lossless with `-c 2` works from 6-channel PCM WAV but fails from AC-3 and above eight channels. So:
- **Two steps for every source of more than two channels.** Step 1: afconvert writes a hidden stereo PCM CAF beside the staged output, named `.<UUID>.audio-downmix.caf` (a suffix of its own, which `isTemporaryName(_:)` must know, so `removeLeftovers(in:)` and the orphan sweep find it): `-f caff -d LEI<bits> -c 2`, with 16 bits for an AAC target and the Apple Lossless depth for a lossless one (24 for a depth of 20). Step 2: the AAC or Apple Lossless arguments of today, reading the stereo file, with no `-c`. The intermediate is removed as soon as step 2 ends, however it ends.
- **One step, as today, for mono and stereo.** `-c` is never passed to the AAC or Apple Lossless encoder any more; `maximumLosslessChannels` and its `-c 8` go.
- **Each step is a watched child** (`WatchedProcess`) under the tool's limits; a kill or a failure of either step is the conversion's `Failure`, as today.
- **Disk space.** Before step 1, when the staged file's volume has less free space (`volumeAvailableCapacityForImportantUsageKey`) than the intermediate's size (duration × output sample rate × 2 channels × bytes a sample) plus 512 MB, refuse with a new failure, `notEnoughSpace(fileName:bytesNeeded:)`, whose words are: "There is not enough free disk space to convert X: it needs 1.4 GB free." (the size by `ImportProgressWording.size(_:)`, as `OggConversionWording.notEnoughSpace` writes it). Make the free-space reader injectable, for the test.
- **Keep the `Tool` seam** (`ImportAudioConverter.Tool`): a test's stand-in must still drive each step, so the hang and failure tests in `OggAfconvertTests` keep working.
- `target(for:bytes:)`: a source of more than two channels gets `channels: 2`, and its AAC bit rate is chosen among stereo's rates. Update the `Target` and `afconvertArguments` doc comments.
- Do not add an output-size cap: task `watchdog` wires one into these steps after you.

## Tests
- **The pinned arguments** in `OggAfconvertTests.swift` (about lines 115-123) and `ImportAudioFormatsTests.swift` (about line 125) change on purpose: update them to the new steps, and name them in your report.
- **Lossy 3.0, 5.1, and 7.1 sources convert to stereo AAC** that passes the probe and keeps its length. Commit two small fixtures to `TestData/audio/`, made with `/opt/homebrew/bin/ffmpeg` (one second each, a 440 Hz tone in the centre channel only, as `center.sh` makes `centre51.ac3`): `tone-centre-5.1.ac3` and `tone-centre-3.0.ac3`; give the commands in the test's doc comment. For 7.1, write a 7.1 PCM CAF in the test with `AVAudioFile(forWriting:)`, make AAC 7.1 in a CAF from it with `/usr/bin/afconvert -f caff -d aac -l <the 7.1 tag the AAC encoder takes: try AAC_7_1, then MPEG_7_1_C>`, and convert that CAF.
- **The dialogue reaches both ears.** For the 5.1 centre-only fixture, decode the converted .m4a to WAV with `/usr/bin/afconvert -f WAVE -d LEI16` in the test and check, from the WAV's bytes, that it has two channels and both carry the tone (RMS well above silence).
- **Every channel count from 1 to 8 converts** on the lossless path: PCM CAF sources of 1 to 8 channels written in the test, each with a standard layout (Mono, Stereo, MPEG_3_0_A, Quadraphonic, MPEG_5_0_A, MPEG_5_1_A, MPEG_6_1_A, MPEG_7_1_C), each converting to Apple Lossless with one channel for mono and two for the rest; and a 10-channel source too (`DiscreteInOrder` with 10, or `many.sh`'s recipe).
- **Nothing is left behind**: no intermediate after a success, a failure of step 1, a failure of step 2, and a kill (with a stand-in tool).
- **Not enough space** is refused with the new words before any child runs, leaving nothing.

## Commits
1. The two-step downmix, with its tests and fixtures (review item 1).
2. The free-space check and its failure, with its test (review item 1).

## Test classes (one run each, in your turn)
`ImportAudioFormatsTests`, `OggAfconvertTests`, `OggAudioConverterTests`, `OggImportConversionTests`, `OggFlacConversionTests`, `ConvertedOriginalTests`, `OrphanedConversionSweepTests`, and any class you add.

## Do not touch
`WatchedProcess.swift`, `AudioFileInfo.swift`, `M3UPlaylist.swift`, the "Which Files" section of `ImportAudioConverter.swift` (from `isOgg` to `tracks(in:where:)`, task `sniff`'s), and any `*.md`.

# Task brief: afconvert — convert Ogg in a separate process that can be killed (B09)

Slug `afconvert`. Branch `fix/ogg-afconvert` from local `main` (at 544fd223 or later: `git merge-base --is-ancestor 544fd223 HEAD`). Read `common.md` beside this brief (ignore its "Who else is working"; no other agent is working), above all its rule: never play Ogg through Apple's players. The budget is nearly spent: work directly, build only targeted classes while iterating, run the full suite once at the end, and keep the report short.

## The bug (October 14, 20:17, the user's first launch of B06)
The library's one-time conversion (`LibraryViewModel+OggConversion.swift`, through `OggAudioConverter`) decodes Ogg with AVAssetReader. All four conversions froze about 30 seconds into their tracks, with TextMouth at 100% CPU. A sample of the user's app shows each thread in `-[AVAssetReaderOutput copyNextSampleBuffer]` → `AudioConverterFillComplexBuffer` → `ACSpanningInputBuffer::checkRelocateClientPacketDescriptions` → caulk's real-time allocator, spinning. That is Apple's Vorbis decoder bug, the one that locked up AVPlayer and took the Mac down that afternoon. It is not ours to fix, and no in-process call can be stopped once it spins.

What worked: `/usr/bin/afconvert -f m4af -d aac -b 64000 in.ogg out.m4a`, Apple's own command-line converter, which reads Ogg through AudioFile and ExtAudioFile. It converted one of the user's 34-minute tracks whole in 9.5 seconds on October 13.

## Required behavior, one commit each, with tests
1. **Decode and encode in a child process, never in TextMouth.**
   - **The swap:** `OggAudioConverter` runs `/usr/bin/afconvert -f m4af -d aac -b <bitrate>` with the bitrate it already chooses, writing to the same hidden temporary name, in place of its AVAssetReader decode and AudioEditRenderer encode. Reuse the project's existing way of running a subprocess (the ffmpeg MP3 route, `MP3Route`) rather than writing another.
   - **The watchdog:** while the child runs, check it every second.
     - Kill it (SIGKILL) and fail that track when it takes longer than 60 seconds plus a tenth of the track's length, when its resident memory passes 1 GB, or when its output file has not grown for 20 seconds.
     - Reading the child's memory: `proc_pid_rusage` or `ps -o rss= -p <pid>`. Make the reader injectable for tests.
   - **Logging and checks:** log the kill as `OGG_CONVERSION_KILLED: <file>: <why>`. Keep the existing check of the result (`AudioMediaProbe` on the .m4a, which decodes AAC, not Ogg).
   - **Nothing in-process touches Ogg's audio:** the source's length must not come from decoding it in TextMouth (AudioFile's estimated duration, or AVURLAsset's duration with no reader, is fine). Read the converter and its callers, including the import's playability check and the editor's preview, and remove or route every other in-process decode of Ogg through this converter.
   - **Tests:** the 2-second synthetic fixtures (`TestData/audio`) convert through the real afconvert. A stand-in child that never ends, or never writes, is killed by each rule (use `/bin/sleep` or a tiny script as the child, with an injected command). No Ogg ever reaches a player.
2. **An interrupted conversion leaves nothing behind.** At the start of a book's conversion, remove the stale temporary files a killed or quit run left in its audio folder (`.<stem>.<UUID>.ogg-conversion.m4a`); the user's book holds four now. A track that fails waits for a later launch as a whole book does: the book stays as it was, and is logged with `OGG_CONVERSION_WAITS`. The pass must never leave the app unusable: the Library window stays usable while a book converts, and a book that keeps failing is tried again only at the next launch, never in a loop.

## Report
As `common.md` says, short: the commits, the suite's exact line, what you could not verify, the measured time to convert a synthetic 20-minute file through afconvert, and documentation wording naming each page (`docs/user/where-your-library-lives.md`, `docs/architecture/state/imports.md`).

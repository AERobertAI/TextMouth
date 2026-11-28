# Imports: audio only FFmpeg reads
<!-- id: imports-audio-ffmpeg; keys: FFmpeg, FMT50, TextMouthFFmpeg, WMA, Matroska, WebM, helper, sandbox; src: -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).
The rest of the audio import is in [Imports: audio](imports-audio.md).

## Which files go to FFmpeg
<!-- id: audio-only-ffmpeg-reads; keys: FFmpegAudioConverter, FFmpegContainer, ASF, copy protection, FMT31, FMT50, extensions; src: TextMouth/Services/FFmpegAudioConverter.swift, TextMouth/Parsers/FFmpegContainer.swift, TextMouth/Services/FileImportService+AudioConversion.swift, TextMouth/Models/FFmpegImportWording.swift; status: incomplete; issues: Q13, B19, FU05 -->

- Which files: FFmpegAudioConverter.converts(_:) is true for a file in either of two cases, whatever its name.
  - Its extension is in FFmpegAudioConverter.extensions (15 of them, joined to ImportAudioConverter.convertedExtensions so the reader guards keep them from Apple's decoders; "mpp" is not one, since Microsoft Project uses it).
  - Its bytes are of a container only ffmpeg reads, as FFmpegContainer.of(fileAt:) tells: ASF, Matroska, FLV, AVI, RealMedia, Musepack 7 and 8, or Speex in Ogg.
  Ogg of any other codec stays with afconvert, and a file of TextMouth's own readers (OwnAudioConverter.format(of:)) is never ffmpeg's.
  No failed Apple open ever chooses the path.
- Dispatch: ImportAudioConverter.convert returns FFmpegAudioConverter.convert first for such a file, before keepChapters, since FFmpegAudioConverter.convert keeps the chapters itself.
  FFmpegContainer reads only the first bytes (AudioContentSniffer.firstBytes).
  ASFHeader.isCopyProtected walks the ASF header for the four protection objects, PlayReady's among them: every object at least 24 bytes and inside its parent, at most 10,000 objects, at most 16 MB (maximumHeaderBytes), one nested level.
  A protected file is refused before the helper is started, or on the iPhone before any file is refused for its kind (`PhoneImportRefusal.refuseConversion`).
  ASF is checked by its header, and Matroska and WebM by their Tracks (`FFmpegContainer`, RFC 9559): a file whose every sound track has a ContentEncryption under ContentEncodingType 1 is told as protected too, on both platforms.
  Still open (B19): RealMedia with DRM, and a file whose Tracks follow its Clusters, end as damaged.
  An encrypted default sound track beside a plain one is decoded (FU05).
  Musepack is in the build and the sniff on both platforms, but no sample has ever been decoded on either (Q13).
- Tracks left out: FFmpegAudioConverter.tracksToLeaveOut(of:located:) names, among a book's several tracks, the files only ffmpeg reads that can't be converted (the helper is missing from the app, or this is the iPhone) and those whose bytes are of no container the helper reads.
  FileImportService.leavingOutWhatOnlyFFmpegReads removes their staged copies and returns the notice (FFmpegImportWording.tracksLeftOutNotice), and the book is refused only when no track is left.
- The iPhone starts no program, so it runs the same session inside the app ([The in-app run](#the-in-app-run)), and its files are converted as the Mac's are; the build is in [Building TextMouth](../../developer/building.md).
  It still refuses Ogg and the audio the Mac converts with afconvert (FMT55), and the files TextMouth's own readers decode.

## The helper and its stream
<!-- id: ffmpeg-helper-and-stream; keys: TextMouthFFmpeg, FFmpegHelperStream, FFmpegReport, protocol, HEAD, INFO, PCM, END; src: TextMouthFFmpeg/main.c, TextMouthFFmpeg/Session/session.c, TextMouthFFmpeg/include/TextMouthFFmpegProtocol.h, TextMouth/Services/FFmpegHelperStream.swift, TextMouth/Services/FFmpegReport.swift -->

- The helper: FFmpeg 9.0.2 is built into TextMouthFFmpeg, a program in the app's Contents/MacOS (FFmpegAudioConverter.locateBundled finds it; none on iOS), and an ffmpeg installed on the Mac is never used for the import (the editor's filters still use one: FFmpeg.locate).
  One run is one file: "probe" says what the file holds, "decode" adds its sound as plain samples, each as a stream of records on the helper's standard output that TextMouthFFmpegProtocol.h defines (HEAD, INFO, TAG, STAG, CHAP, PCM, END).
  FFmpegHelperStream reads them against the protocol's limits, so a helper that writes nonsense costs a failed import: a record over its kind's size, out of order, an empty PCM record, samples that are not whole frames, or an END that counts other frames.
  The file is opened by the session itself (`tmff_open_regular_file`), a regular file only, and FFmpeg reads it through the session's own callbacks, with no FFmpeg protocol built and the demuxer named from FFmpegContainer.demuxer.
  A FIFO is never waited on, and a symbolic link is refused (`O_NOFOLLOW`); `runSession` resolves the path first, on both platforms, so a link to a good file still converts.

## Confining and watching the helper
<!-- id: ffmpeg-helper-confinement-watching; keys: sandbox, sandbox_init, exit status 12, watchdog, grace after END, output cap, AUDIO_DECODER_REFUSED; src: TextMouthFFmpeg/main.c, TextMouth/Services/FFmpegAudioConverter.swift, TextMouth/Platform/macOS/Services/WatchedProcess.swift -->

- Confinement: once the file is open, main.c calls sandbox_init with the profile named "pure-computation", so the helper can compute, read that descriptor, and write its standard output, and no more.
  main.c spells the name, since the macOS 27 SDK no longer declares kSBXProfilePureComputation.
  A refusal ends it with exit status 12 (TMFF_EXIT_NOT_CONFINED), which is FFmpegImportWording.notConfined; it reads nothing.
  The processor's features are asked first (tmff_session_prepare), since the sandbox blocks sysctl and FFmpeg found fewer afterwards.
  Every fatal signal ends the helper with _exit on a stack of its own (status 70, so no crash report), and SIGXCPU with 71.
  The session sets thread_count to 1 before the decoder opens, and av_max_alloc to 256 MB.
  It also sets the decoder's max_samples to 16,777,216 samples over all channels (MAX_DECODED_SAMPLES), kept by the session's own buffer callback.
  A frame past it ends the decode with exit status 13 (TMFF_EXIT_FRAME_TOO_LARGE, `FFmpegImportWording.frameTooLarge`) before any allocation, and is never skipped as damaged; the iPhone has the same bound.
- Watching it: FFmpegAudioConverter.probe and decode run the helper under WatchedProcess.runStreaming, whose watchdog looks every 0.25 s.
  - The decode gets a minute plus a tenth of the length, 1 GB, and a stall of 60 s; the probe 30 s plus the size at 20 MB/s, 512 MB, and a stall as long as that.
  - The decode's output file is the .m4a the app writes, so the helper's pipe is never capped by the kernel: the reader checks the file's size against the cap before each block and once at the end (checkOutputCap, WroteTooMuch), and the watchdog looks too.
  - A reader that returns after END has the helper end by itself within 2 seconds (defaultEndGraceSeconds), else a plain SIGKILL that is no failure; a stream that ends early is told by the exit status (failure(forExitStatus:)), a signal, or "endedEarly".
  - The decoder's refused packets and frames are logged as AUDIO_DECODER_REFUSED, and the file converts all the same.

## The in-app run
<!-- id: ffmpeg-in-app-run; keys: runInProcess, InProcessEngine, SessionStopCheck, RunningClock, Tool.clock, memory floor, FFmpeg_iOS, B18; src: TextMouth/Platform/iOS/Services/FFmpegInProcessRun.swift, TextMouth/Services/FFmpegAudioConverter.swift, TextMouth/Services/InProcessEngine.swift, TextMouth/Services/RunningClock.swift, TextMouth/Models/InProcessEngineWording.swift, TextMouth/Models/FFmpegImportWording.swift, TextMouthFFmpeg/Session/session.c, TextMouthiOSTests/FFmpegInAppTests.swift -->

The iPhone links the Mac's session (FFmpeg_iOS) and runs it in TextMouth's own process.
A decoder's crash would end the app, so the patches, the one decoding thread, and the bounds below matter more than on the Mac.

- **One fork:** `FFmpegAudioConverter.runSession` is where the platforms part: the Mac runs its helper under `WatchedProcess.runStreaming`, and the iPhone `runInProcess` (`#if os(iOS)`).
  Everything else is shared: the plan, the sentences, and `FFmpegHelperStream`, which reads the records and holds every bound.
- **One engine call per record:** The first piece the reader asks for opens the session, and each later one is the session's next record.
  A call takes at most the stall limit, and no more than the run has left.
  The engine is `FFmpegAudioConverter.sessionEngine`, apart from braille's, so a hung call in one never refuses the other.
  `Tool.engine`, `openSession`, `memoryFloor`, and `clock` let a test stand in for each.
- **The stop check** (`SessionStopCheck`): it is asked by FFmpeg's interrupt callback, by the session's reads and seeks of its file (`must_stop` first, AVERROR_EXIT), and at each step.
  It says stop once the engine's call should, or the app has less memory left than the run's floor, and it stays stopped.
- **The memory floor:** Free memory is `os_proc_available_memory()`.
  The floor is 512 MB, twice `av_max_alloc`'s 256 MB, so no allocation between two asks can take the app from above the floor to its limit.
  A run that begins with less than 1 GB free keeps half of what it began with, and FFmpeg's allocation cap is half the floor, at most 256 MB.
  A return of 0 means no limit only in the simulator (`#if targetEnvironment(simulator)`); on a device it means over the limit, and stops the run.
  The stop is a kill for memory, worded by `FFmpegImportWording.memoryGrew` or `beganShortOfMemory`.
- **The clock** (B18): it is `RunningClock`, which counts only the time TextMouth runs, since iOS keeps the system's clocks counting while it holds the app suspended.
  - A reading adds at most 1 s since the one before, and a 0.25 s heartbeat reads it while a call or run holds it (`hold()`, `release()`).
    So running time counts whole, and only a suspension is cut.
  - `Tool.clock` is the clock a run's whole time is counted by: `RunningClock.app` on the iPhone, and the Mac's braille uses `RunningClock.system`, whole steps.
  - The engine's waiter is the one judge of a call's time: it holds the clock, reads it afresh, sets the stop, and abandons the call a grace later.
    `Call.shouldStop` reads no clock, so work resuming first after a suspension never stops on a stale reading.
- **Abandoned and refused:** A call past its time and grace is abandoned, and the engine refuses every conversion until TextMouth is closed and opened again.
  `InProcessEngineWording` has the two sentences, with `FFmpegImportWording.inAppWork`.
  The first names the stall limit, or the run's whole limit when the time left cut the call.
- **The build:** Clang modules are off for the C files (see [The FFmpeg build](../../developer/building.md#the-ffmpeg-build)), and the app installs no signal handler (FU02).
- **The tests** are in [Formats only ffmpeg reads](../../developer/testing-formats.md#formats-only-ffmpeg-reads).
  No test may let a real liblouis call be abandoned (B20).

## What is written
<!-- id: ffmpeg-conversion-plan; keys: plan, Apple Lossless, AAC, writeBlocks, tags, form changed, no length; src: TextMouth/Services/FFmpegAudioConverter.swift, TextMouth/Services/FFmpegReport.swift, TextMouth/Services/OwnAudioConverter.swift -->

- The plan (FFmpegAudioConverter.plan(for:fileName:)): the session chose the first sound stream the build decodes that the file marks as default, else the first.
  A lossless codec (isLossless(codec:)) becomes Apple Lossless at its depth; anything else, AAC included, is decoded and written again as AAC at its own bit rate (OwnAudioConverter.writeBlocks, the writer TextMouth's own readers use), mixed to stereo when it has more channels.
  The book's tags come from FFmpegReport.bookTags: the title, the artist (or author, or album_artist), the album, the genre, and the date, each cut at 4 KB, and a value holding U+FFFD is missing; stream tags count only for Ogg.
- Sound that changes its form partway (joined recordings) is converted: the session sends each later frame of another rate, channel layout, or sample format through libswresample into the first frame's form, so the stream keeps one form and END counts the frames of that form.
  - The first frame after a change of rate takes the decoder's rate, which FFmpeg's MP3 decoder leaves on the frame one step late.
  - The channel layouts are compared, not only the counts, so 6.0 after 5.1 is converted.
  - It is refused with TMFF_EXIT_FORM_CHANGED (exit 7, FFmpegImportWording.formChanged) only for a rate more than 16 times the first one's, or a sixteenth of it (MAX_RATE_RATIO), a form that cannot be converted, or more than 1,000 changes away from the first form (MAX_FORM_CHANGES).
  - A converted frame is at most 16 MiB (MAX_CONVERTED_BYTES): a longer one is fed to the resampler in slices.
  - The Debug helper's `formcheck` mode (TMFF_MODE_FORMCHECK, no file) runs these bounds on frames made up in memory: the ratio at 16 and 17 to 1 each way, a frame whose conversion would be 268 MB, a frame the resampler holds back, and 1,000 and 1,001 changes.
- Packets the decoder refuses are skipped and counted in END (AUDIO_DECODER_REFUSED), however many: the guard on errors in a row, MAX_ERRORS_IN_A_ROW, counts errors with no packet between them, which a damaged packet never makes, so no file reaches it.
  The session keeps the gap as silence, so the book keeps its length and its chapter marks: the gap is the packets' timestamps' when they go forward and within the bound, else the packets' own lengths.
  The silence is bounded by the file's stated length (an hour when it states none, 12 hours at most) and by the file's size at 1 kbit/s (`silence_limit`); past the bound none is owed and the decode goes on.
  A file with no good packet ends with exit 6 and the damaged sentence.
  END carries no silence length, so the import tells only that part was kept: `Conversion.partlyDecoded` and `FFmpegImportWording.partlyDecodedNotice` join the import's notices, for a single file, a folder, or several tracks.
- The edge samples are in TestData/format-samples/ffmpeg-edge (see [Formats only ffmpeg reads](../../developer/testing-formats.md#formats-only-ffmpeg-reads)).
- Limits on a source with no length: assumedDuration at 6 kbit/s, and an output cap of max(64 MB, 50 times the file) (unknownLengthOutputCap), refused before running when the volume lacks that and downmixReserveBytes.
  A stated length the file's size can't hold is taken as unknown (believedDuration, AUDIO_INFO_IMPLAUSIBLE).

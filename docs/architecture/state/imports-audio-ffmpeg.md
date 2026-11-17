# Imports: audio only FFmpeg reads
<!-- id: imports-audio-ffmpeg; keys: FFmpeg, FMT50, TextMouthFFmpeg, WMA, Matroska, WebM, helper, sandbox; src: -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).
The rest of the audio import is in [Imports: audio](imports-audio.md).

## Which files go to FFmpeg
<!-- id: audio-only-ffmpeg-reads; keys: FFmpegAudioConverter, FFmpegContainer, ASF, copy protection, FMT31, FMT50, extensions; src: TextMouth/Services/FFmpegAudioConverter.swift, TextMouth/Parsers/FFmpegContainer.swift, TextMouth/Services/FileImportService+AudioConversion.swift, TextMouth/Models/FFmpegImportWording.swift; status: incomplete; issues: FMT54 -->

- Which files: FFmpegAudioConverter.converts(_:) is true for a file in either of two cases, whatever its name.
  - Its extension is in FFmpegAudioConverter.extensions (15 of them, joined to ImportAudioConverter.convertedExtensions so the reader guards keep them from Apple's decoders; "mpp" is not one, since Microsoft Project uses it).
  - Its bytes are of a container only ffmpeg reads, as FFmpegContainer.of(fileAt:) tells: ASF, Matroska, FLV, AVI, RealMedia, Musepack 7 and 8, or Speex in Ogg.
  Ogg of any other codec stays with afconvert, and a file of TextMouth's own readers (OwnAudioConverter.format(of:)) is never ffmpeg's.
  No failed Apple open ever chooses the path.
- Dispatch: ImportAudioConverter.convert returns FFmpegAudioConverter.convert first for such a file, before keepChapters, since FFmpegAudioConverter.convert keeps the chapters itself.
  FFmpegContainer reads only the first bytes (AudioContentSniffer.firstBytes).
  ASFHeader.isCopyProtected walks the ASF header for the four protection objects, PlayReady's among them: every object at least 24 bytes and inside its parent, at most 10,000 objects, at most 16 MB (maximumHeaderBytes), one nested level.
  A protected file is refused before the helper is started.
- Tracks left out: FFmpegAudioConverter.tracksToLeaveOut(of:located:) names, among a book's several tracks, the files only ffmpeg reads that can't be converted (the helper is missing from the app, or this is the iPhone) and those whose bytes are of no container the helper reads.
  FileImportService.leavingOutWhatOnlyFFmpegReads removes their staged copies and returns the notice (FFmpegImportWording.tracksLeftOutNotice), and the book is refused only when no track is left.
- The iPhone starts no program, so it refuses these formats (FMT54 will run the same session inside the app); the build is in [Building TextMouth](../../developer/building.md).

## The helper and its stream
<!-- id: ffmpeg-helper-and-stream; keys: TextMouthFFmpeg, FFmpegHelperStream, FFmpegReport, protocol, HEAD, INFO, PCM, END; src: TextMouthFFmpeg/main.c, TextMouthFFmpeg/Session/session.c, TextMouthFFmpeg/include/TextMouthFFmpegProtocol.h, TextMouth/Services/FFmpegHelperStream.swift, TextMouth/Services/FFmpegReport.swift -->

- The helper: FFmpeg 9.0.2 is built into TextMouthFFmpeg, a program in the app's Contents/MacOS (FFmpegAudioConverter.locateBundled finds it; none on iOS), and an ffmpeg installed on the Mac is never used for the import (the editor's filters still use one: FFmpeg.locate).
  One run is one file: "probe" says what the file holds, "decode" adds its sound as plain samples, each as a stream of records on the helper's standard output that TextMouthFFmpegProtocol.h defines (HEAD, INFO, TAG, STAG, CHAP, PCM, END).
  FFmpegHelperStream reads them against the protocol's limits, so a helper that writes nonsense costs a failed import: a record over its kind's size, out of order, an empty PCM record, samples that are not whole frames, or an END that counts other frames.
  The file is opened by the helper itself, a regular file only (a FIFO is never waited on), and FFmpeg reads it through the helper's own callbacks, with no FFmpeg protocol built and the demuxer named from FFmpegContainer.demuxer.

## Confining and watching the helper
<!-- id: ffmpeg-helper-confinement-watching; keys: sandbox, sandbox_init, exit status 12, watchdog, grace after END, output cap, AUDIO_DECODER_REFUSED; src: TextMouthFFmpeg/main.c, TextMouth/Services/FFmpegAudioConverter.swift, TextMouth/Platform/macOS/Services/WatchedProcess.swift -->

- Confinement: once the file is open, main.c calls sandbox_init with kSBXProfilePureComputation, so the helper can compute, read that descriptor, and write its standard output, and no more.
  A refusal ends it with exit status 12 (TMFF_EXIT_NOT_CONFINED), which is FFmpegImportWording.notConfined; it reads nothing.
  The processor's features are asked first (tmff_session_prepare), since the sandbox blocks sysctl and FFmpeg found fewer afterwards.
  Every fatal signal ends the helper with _exit on a stack of its own (status 70, so no crash report), and SIGXCPU with 71.
  The session sets thread_count to 1 before the decoder opens, and av_max_alloc to 256 MB.
- Watching it: FFmpegAudioConverter.probe and decode run the helper under WatchedProcess.runStreaming, whose watchdog looks every 0.25 s.
  - The decode gets a minute plus a tenth of the length, 1 GB, and a stall of 60 s; the probe 30 s plus the size at 20 MB/s, 512 MB, and a stall as long as that.
  - The decode's output file is the .m4a the app writes, so the helper's pipe is never capped by the kernel: the reader checks the file's size against the cap before each block and once at the end (checkOutputCap, WroteTooMuch), and the watchdog looks too.
  - A reader that returns after END has the helper end by itself within 2 seconds (defaultEndGraceSeconds), else a plain SIGKILL that is no failure; a stream that ends early is told by the exit status (failure(forExitStatus:)), a signal, or "endedEarly".
  - The decoder's refused packets and frames are logged as AUDIO_DECODER_REFUSED, and the file converts all the same.

## What is written
<!-- id: ffmpeg-conversion-plan; keys: plan, Apple Lossless, AAC, writeBlocks, tags, form changed, no length; src: TextMouth/Services/FFmpegAudioConverter.swift, TextMouth/Services/FFmpegReport.swift, TextMouth/Services/OwnAudioConverter.swift; status: incomplete; issues: FU-FFMPEG2 -->

- The plan (FFmpegAudioConverter.plan(for:fileName:)): the session chose the first sound stream the build decodes that the file marks as default, else the first.
  A lossless codec (isLossless(codec:)) becomes Apple Lossless at its depth; anything else, AAC included, is decoded and written again as AAC at its own bit rate (OwnAudioConverter.writeBlocks, the writer TextMouth's own readers use), mixed to stereo when it has more channels.
  The book's tags come from FFmpegReport.bookTags: the title, the artist (or author, or album_artist), the album, the genre, and the date, each cut at 4 KB, and a value holding U+FFFD is missing; stream tags count only for Ogg.
  A sound that changes its rate or channels partway is refused (TMFF_EXIT_FORM_CHANGED), where the old ffmpeg import converted it (FU-FFMPEG2).
- Limits on a source with no length: assumedDuration at 6 kbit/s, and an output cap of max(64 MB, 50 times the file) (unknownLengthOutputCap), refused before running when the volume lacks that and downmixReserveBytes.
  A stated length the file's size can't hold is taken as unknown (believedDuration, AUDIO_INFO_IMPLAUSIBLE).

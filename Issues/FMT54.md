---
id: FMT54
title: FFmpeg inside the iPhone app (FMT50's iPhone half)
kind: format
status: in-progress
priority: P2
platform: iphone
assignee: phoneffmpeg
created: 2026-11-17
updated: 2026-11-17
found-by: FMT50's merge
branch:
merged:
reason:
related: FMT50, FU-FFMPEG, DR34
docs:
labels:
---

## Description

FMT50's Mac half merged d8ccedb95 on November 17, 2026: FFmpeg 9.0.2 (LGPL 2.1 or later) with five upstream patches, built by Scripts/vendor/ffmpeg/build.py, runs in the sandboxed helper TextMouthFFmpeg. The iPhone can start no helper, so there the same session (TextMouthFFmpeg/Session/session.c) runs inside the app through InProcessEngine, from DR34's liblouis work once that merges: one serial thread with a large stack, time limits, and abandoning a call that hangs, with the session's interrupt callback on Call.stopCheck. Build FFmpeg's libraries for device and simulator as static _iOS targets (the LAME_iOS and liblouis_iOS pattern), and lift PhoneImportRefusal's refusal of the formats only FFmpeg reads. Keep parity: the user's answers of November 16 ask for everything the Mac converts on both, Matroska holding AAC, FLAC, or AC-3 included, now rather than later. A decoder's crash ends TextMouth itself on the iPhone, so the patches, the one decoding thread, and the input and record limits matter more there. From FU-FFMPEG: check copy protection first on the iPhone, before any conversion. Size: the iPhone app was 13.66 MB with liblouis (DR34's measure); the parity set added about 1.8 MB on the Mac (research/FFMPEG-MINIMAL-RESEARCH-2026-11-16.md).

## Comments

### 2026-11-17, phoneffmpeg, 28 lines

Design, before the build (phoneffmpeg, branch phone/ffmpeg-in-app).

How the records reach the import in one process: a pull, one record per engine call, into FFmpegHelperStream unchanged.
- The session's API already gives one record per call (tmff_session_next), and FFmpegHelperStream(reading:) frames pieces of any size. On the iPhone each piece the stream asks for is one call of the engine: the first opens the session, each later one is tmff_session_next, and its record is copied out. So every bound of the stream (a record's length for its kind, the order, the counts of tags and chapters, whole frames, END's count) stays in FFmpegHelperStream, the one place both platforms read it.
- Not a pipe: InProcessEngine.run returns only when its work ends, so one call would hold the engine for the whole decode, its limit would be the whole decode's, and a stall could not be told; a pipe also needs a second thread, two descriptors, and SIGPIPE masked in the app.
- Not a callback that pushes records during one long call: handing each record to the waiting import from the engine's thread is a pipe built by hand.
- The pull also gives back-pressure for nothing: the session decodes only when the import asks.

The run (FFmpegAudioConverter.runSession, shared): on the Mac it is WatchedProcess.runStreaming of the helper, exactly as now; on the iPhone, Located.inProcess, it runs on the tool's engine. Both return the helper's Ending (an exit status of TextMouthFFmpegProtocol.h, or a kill and its reason) and the reader's result, so failure(of:read:...) and every sentence stay one copy. The session returns the helper's exit numbers already.

The session's stop check: session.c gains tmff_session_open_checked and tmff_session_set_stop_check (a check of InProcessEngine.Call.stopCheck's shape, with Call.context). Every place the session asked its stopped flag (FFmpeg's interrupt callback, each step of next_frame, each tmff_session_next) asks the flag or the check, and a check that says stop stops the session for good. The Mac's helper passes none, so it behaves as before. main.c's open_regular_file moves into the library as tmff_open_regular_file, so the iPhone opens its file the same way (regular files only, never waiting on a FIFO).

What replaces each Mac protection in the app:
- The sandbox: iOS's own app sandbox. The session still reads only the descriptor it is given, through its own callbacks, with no FFmpeg protocol or network code built.
- The signal guards: none in the app; a crash ends TextMouth (FU02).
- The watchdog's memory look: av_max_alloc (256 MB for any one allocation) and the session's own bounds (a record at most 1 MiB, a converted frame at most 16 MiB, at most 512 tags of 4 KB and 4,096 chapters). There is no whole-process cap: iOS ends the app past its memory limit.
- The time limits: the engine's. The run's whole time is the Mac's (a minute and a tenth of the length for a decode; 30 seconds and one for each 20 MB for a probe), counted from its start; each call may take at most the stall limit (no record for that long is a stall) and no more than the run has left. A call past its limit is told to stop through the session's interrupt callback and the session's own checks, and ends in the watchdog's own reason (it ran longer than, or its output did not grow for), the Mac's sentence. A call still running its grace later is abandoned, with InProcessEngineWording's sentences. The processor-time limit is implied: one thread can use no more processor time than its time limit.
- The import's Cancel: the task's cancellation reaches the call (a new async entry of InProcessEngine that waits off Swift's cooperative threads and follows its task's cancellation), and the run ends in CancellationError, as on the Mac.
- The output cap: the reader's own check before each block and at the end, already shared; only the watchdog's look four times a second is gone.
- The grace after END: not needed; the session is closed on the engine once the reader is done.

What stays exactly as on the Mac: the sniff and the demuxer named from it, the copy-protection check, the probe then the decode, the plan (Apple Lossless at its depth for a lossless codec, AAC at its own bit rate rounded up for any other, more than two channels mixed to stereo), the stream and its bounds, the writer (OwnAudioConverter.writeBlocks), the output cap and the space check, the length check, the chapters and the tags, the final name, and every sentence.

Matroska, as the Mac does it: AAC is decoded and written again as AAC at its own bit rate rounded up to a standard one (HE-AAC at the rate it decodes to); FLAC becomes Apple Lossless at its own depth; AC-3 becomes AAC, 5.1 mixed to stereo. The iPhone runs the same plan.

The tool (one reach for all limits): FFmpegAudioConverter.Tool keeps the Mac's limits, probe limits, and free space, and gains on iOS the engine, the clock, and what a run opens (the linked session, or a test's stand-in), as BrailleTranslator.tool does.

Copy protection first: on the iPhone, PhoneImportRefusal.refuseConversion tells a copy-protected Windows Media file as such before it refuses any other format, and before any conversion; it refuses no format only FFmpeg reads.

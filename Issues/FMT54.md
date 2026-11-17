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

### 2026-11-17, phoneffmpeg, 12 lines

Built as designed above, on phone/ffmpeg-in-app, rebased onto main cf72969c0 (18 commits; the last code commit is 80ea8e85c, the same tree as d2f89edd5, which the last train tested, but for main's Issues/TL07.md); waiting for the orchestrator's merge.

- The iPhone app links FFmpeg_iOS and runs TextMouth's session in its own process on FFmpegAudioConverter.sessionEngine. FFmpegAudioConverter.runSession is the one place the platforms part: the Mac's helper under WatchedProcess.runStreaming, unchanged, or runInProcess (TextMouth/Platform/iOS/Services/FFmpegInProcessRun.swift), each piece of FFmpegHelperStream one engine call. InProcessEngine gained runForTask(limit:_:): it waits off Swift's cooperative threads and follows the task's cancellation.
- PhoneImportRefusal no longer refuses the formats only FFmpeg reads, and tells a copy-protected Windows Media file first (FU-FFMPEG). sync-info-plist.py no longer refuses "Audio and Video Converted with ffmpeg", so the iPhone offers the Mac's document type and its four com.textmouth types.
- Licenses/FFmpeg ships in the iPhone app, between liblouis and LAME; BundledLicenseIOSTests checks it. The App Store question stays QN01's.
- The FFmpegLibrary template sets CLANG_ENABLE_MODULES to NO for both FFmpeg targets: train 1117-1219's iPhone build failed on a restored runner cache with "module file ..._Builtin_stddef-*.pcm not found" while precompiling this C target's own modules. session.c needs no module.
- Size (make ios-size, Release, device, main b4ca9dd5e to d2f89edd5): app 13,674,901 to 16,078,691 bytes (+2.40 MB), IPA 6,266,651 to 7,561,598, App Store estimate 13,414,827 to 15,792,235; train 1117-1753 measured 16,078,689, 7,561,582, and 15,792,238. Limit 30 MB; nothing cut.
- Parity: seven FFmpeg test classes and their support file now run on the iPhone too (project.yml), with fences only for what the iPhone has no part in (the helper's sandbox and argument errors, the made-up-frame bounds, a helper that kills itself or hangs after END). On the iPhone, as on the Mac, every sample imports to the same book (three WMA files, WMV, AVI, FLV, MKV with FLAC, MKA with AC-3 5.1, AAC, two tracks, a long title, a form change, WebM Opus and Vorbis, Speex in .spx and .ogg, RealAudio), the new TestData/format-samples/mka/tones-aac.mka included, and a cue sheet's FFmpeg file is measured on both. The test reader M4ASampleEntry reads codec, channels, and rate from the .m4a's boxes; on the Mac it must agree with afinfo. Musepack has no sample on either platform.
- Train 1117-1406 at 92d1f63c4 (run 44159764165): the Mac PASSED, "Executed 3146 tests, with 11 tests skipped and 0 failures (0 unexpected) in 526.467 (529.062) seconds"; the iPhone, all its tests in two jobs, 1227 with 1 failure and 1239 with none (FFmpegImportRealTests whole: every sample the same book as on the Mac). The one failure: an open told to stop by its check still succeeded, since FFmpeg can finish a step it was told to stop; 79449989b makes the session ask itself once FFmpeg has found the streams (the Mac gives no check, so its opens are unchanged); train 1117-1509 at the same commit failed the same test alone.
- The last train, 1117-1753 at d2f89edd5 (run 44194376073), PASSED: the Mac "Executed 3146 tests, with 11 tests skipped and 0 failures (0 unexpected) in 511.790 (511.790) seconds"; the iPhone "Executed 2466 tests, with 1 tests skipped and 0 failures (0 unexpected) in 725.274 (725.274) seconds" (2429 unit tests, 37 interface tests).
- Break proofs (scratch commit 1ebe69a26, GitHub hand runs 44145820175 and 44154562017), each removal failing its tests and nothing else: (a) the session ignores its stop check: FFmpegInAppTests.testFFmpegsInterruptCallbackAsksTheStopCheckWhileTheFileOpens and testTheSessionStopsForGoodOnceItsCheckSaysStop (iPhone); (b) copy protection not told first: FFmpegImportConversionTests.testTheIPhoneTellsACopyProtectedFileFirst (Mac and iPhone); (c, g) runForTask waiting on the caller's thread and following no cancellation: three of InProcessEngineTests' runForTask tests (Mac and iPhone) and FFmpegHelperProtocolTests.testStopKillsTheHelperAndLeavesNothingBehind (iPhone, 60.2 s); (d) each call given the run's whole time: FFmpegInAppTests.testTheRunsTimeIsTheMacsCountedFromItsStart ([25, 25, 25]) and testACallThatGivesNoRecordForTheStallIsStopped (iPhone); (f) the ffmpeg document type refused again: five IOSInfoPlistTests (Mac; four on the iPhone) and two FFmpegImportSnifferTests (iPhone); (h) no FFmpeg notice: BundledLicenseIOSTests.testFFmpegLicenseShipsWithTheApp (iPhone) and check-licenses.py (here). The typecheck stand-in's test fails on a header function it lacks (here). The module setting: the iPhone build failed twice on a kept runner cache without it (train 1117-1219, run 44142270349) and passed on a kept cache with it (44154562017).
- Follow-ups suggested: Ogg (Vorbis, Opus, FLAC) and the afconvert formats through the in-app FFmpeg on the iPhone; a Musepack sample; make ios-size with a relative IOS_SIZE_ARGS path (#6513); the Simulator build's retry for "module file not found" (#6515); the train giving up on a run after one failed gh call (#6519).

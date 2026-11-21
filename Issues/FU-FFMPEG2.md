---
id: FU-FFMPEG2
title: The bundled FFmpeg's leftovers
kind: follow-up
status: in-progress
priority: P2
platform: mac
assignee: ffmpegleft
created: 2026-11-16
updated: 2026-11-18
found-by: review-ffmpegbuild
branch: formats/ffmpeg-leftovers
merged:
reason:
related:
docs:
labels:
---

## Description

**FU-FFMPEG2 — The bundled FFmpeg's leftovers.** From `review-ffmpegbuild` (November 16, 2026), left out of `formats/ffmpeg-bundled`: a Debug-only self-test of the helper's signal guard (a segfault, an abort, a stack overflow, a double free: exit 70 and no crash report), on GitHub only; tests of a frame over 1 MB split across records (a FLAC-in-Matroska sample with 65,535-sample blocks, 8 channels, and 24 bits), of a PCM record over 1 MB in the reader, and of the decoder error bound; sound whose rate or channels change partway (joined recordings, HE-AAC whose SBR or PS first appears late) is refused (`TMFF_EXIT_FORM_CHANGED`), where the old ffmpeg import converted it: convert later frames to the first frame's form with libswresample, which is linked; each DerivedData keeps about 125 MB of FFmpeg's tarball and unpacked source, which could be shared in `build/ffmpeg/` as the download is; a workflow cache of FFmpeg's build keyed on `build.py`'s key (a guarded `.github` change, for a release push); and before any binary carrying FFmpeg leaves the project (TestFlight, the App Store, a release download), LGPL 2.1 section 6 wants its source offered from the same place or by a written offer, and the App Store's terms must be weighed against section 10: a question for the user then.

## Comments

### 2026-11-16, issuelib, 1 line

Moved from TODO-2026-09-04.md, line 5441 of the version this import read, where it was an open item; the description is its text as it was.

### 2026-11-17, ffmpegform, 1 line

ffmpegform, branch formats/ffmpeg-form at 4da8ec09f (train 1117-0559 PASSED, Executed 1041 tests, 5 skipped, 0 failures). Done: sound whose rate, channels, or format change partway is converted to the first frame's form with libswresample (mka/mp3-form-changes.mka imports whole at 22,050 Hz mono; only a form that cannot be converted, or over 1,000 changes, still ends with exit 7); tests of a frame over 1 MB split across records (ffmpeg-edge/flac-7.1-24bit-65535.mka) and of a PCM record over 1 MB in the reader; the decoder error bound tried with 900 and 1,200 refused packets (GitHub only): the bound is never reached by a damaged packet, so both import, each counted in END; build.py keeps the release's archive and unpacked source once in build/ffmpeg/ (saves 12.0 MB of archive and 90.4 MB of source for each DerivedData). Still open here: the signal guard self-test, the workflow cache of FFmpeg's build, and the LGPL and App Store question.

### 2026-11-17, ffmpegform, 1 line

ffmpegform, review fixes on formats/ffmpeg-form at 7cae22b57 (train 1117-0750 PASSED, Executed 1044 tests, 5 skipped, 0 failures; Mac type-check and iOS strict 0 errors, lint-tests 0 findings). Fix 1: the first frame after a change of rate takes the decoder's rate (70,272 frames from one resampler, not 70,560). Fix 2: tests assert 70,272 +-2, END's count, and each stretch's place within 6 frames; a new sample ends in a converted stretch (46,656); the import test is +-0.02 s; the no-drain (70,256) and lost-frame (69,696) breaks fail them. Fix 3: a rate ratio past 16 to 1 ends with exit 7, a converted frame is capped at 16 MiB (long frames are fed in slices), tested with made-up frames through a Debug-only helper mode (formcheck), with the held-back frame, the layout, and 1,000 and 1,001 changes. Fix 4: the formChanged sentence now says more than TextMouth can follow. Items 5, 6, 8, 9 taken (all-refused sample ends damaged, layouts compared, two-process lock test, helpers and the download fallback). Still open here: the signal guard self-test, the workflow cache, the LGPL and App Store question; filling a refused stretch with silence is a later issue.

### 2026-11-17, orchestrator, 1 line

Part merged 098398533 (formats/ffmpeg-form, full Mac suite 13313/105/0): sound that changes form is converted, bounded at 16 to 1 and 16 MiB a converted frame; the frame over 1 MB, the record over 1 MB, and the refused-packet tests; one shared FFmpeg source in build/ffmpeg/. Still open here: the signal guard's self-test (GitHub only) and a workflow cache of FFmpeg's build (a .github change, for a release push). The LGPL and App Store question moved to QN01, and a refused stretch closing the timeline is FU03.

### 2026-11-18, ffmpegleft, 1 line

ffmpegleft, branch formats/ffmpeg-leftovers at 342d0fc16 (train 1118-0221 PASSED: Mac 4165 tests, 31 skipped, 0 failures; iPhone 145 tests, 0 failures). Done: a Debug-only signalcheck mode of the helper (main.c, under DEBUG; a Release helper answers the usage error and carries none of its code); FFmpegHelperHostileFileTests.testEachFatalSignalEndsTheHelperWithItsOwnStatus (GitHub only) shows a null write, an abort, a stack overflow, and a double free each end with 70 by the guard's own _exit, not by the signal. Left: the workflow cache of FFmpeg's build keyed on build.py's key, a .github change that waits for the user's next push.

### 2026-11-18, orchestrator, 1 line

Part merged c5e4c226c on November 18, 2026: the helper's signal-guard self-test (a Debug-only signalcheck mode, run on GitHub only). Still open here: a workflow cache of FFmpeg's build, a .github change held for a release push.

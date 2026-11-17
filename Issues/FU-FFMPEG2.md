---
id: FU-FFMPEG2
title: The bundled FFmpeg's leftovers
kind: follow-up
status: in-progress
priority: P2
platform: mac
assignee: ffmpegform
created: 2026-11-16
updated: 2026-11-17
found-by: review-ffmpegbuild
branch:
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

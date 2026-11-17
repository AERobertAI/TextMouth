---
id: FU-FFMPEG2
title: The bundled FFmpeg's leftovers
kind: follow-up
status: open
priority: P2
platform: mac
assignee:
created: 2026-11-16
updated: 2026-11-16
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

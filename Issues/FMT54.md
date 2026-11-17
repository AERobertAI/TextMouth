---
id: FMT54
title: FFmpeg inside the iPhone app (FMT50's iPhone half)
kind: format
status: open
priority: P2
platform: iphone
assignee:
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

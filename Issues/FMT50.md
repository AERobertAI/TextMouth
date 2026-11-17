---
id: FMT50
title: A bundled ffmpeg
kind: format
status: done
priority: P2
platform: both
assignee: ffmpegfix
created: 2026-10-17
updated: 2026-11-17
found-by: the research of 2026-10-17
branch: formats/ffmpeg-bundled
merged: d8ccedb95
reason:
related: FMT31
docs:
labels:
---

## Description

**FMT50 — A bundled ffmpeg.** Difficulty L · Impact 2 · Only if FMT31's formats should work without Homebrew (question 9). Build an ffmpeg executable with only the needed demuxers and decoders, AudioToolbox for AAC, and no GPL or non-free parts; ship it as a separate signed executable in the bundle with its exact source, configure line, and notices (ffmpeg.org's legal checklist), and rebuild it on every ffmpeg security release. About 1.5 to 3 MB, estimated from reports (no build was measured). Measured November 16, 2026 (`research/FFMPEG-MINIMAL-RESEARCH-2026-11-16.md`, FFmpeg 9.0.2): built into the app with --enable-small, WMA only adds 696,304 bytes, WMA and WebM 943,344, and parity with the installed ffmpeg 1,766,688 (over make check's 20 MB); the libraries build for iOS unchanged. Recommended: WMA and WebM from a pinned release built by a script, a helper on the Mac and in the app on the iPhone; the user's questions are in humanQuestions/2026-11-16.md. The user's answers (November 16): build it, with parity on both the Mac and the iPhone, credited; the size limit is 30 MB (make check warns) and 40 MB strict (make check fails). Agent `ffmpegbuild` builds it.

## Comments

### 2026-11-16, issuelib, 1 line

Moved from TODO-2026-09-04.md, line 5883 of the version this import read, where it was an open item; the description is its text as it was.

### 2026-11-17, ffmpegfix, 1 line

Bundled FFmpeg finished for its merge: the helper confines itself with the pure-computation sandbox once its file is open (exit status 12 and its own sentence when it cannot; a Debug-only confinement mode proves input readable, hosts file and network refused, processor features kept); second download source (FFmpeg's GitHub mirror, own SHA-256); an empty audio record is refused and a helper that hangs after END is ended without failing the import; the output cap is counted by the reader; one decoding thread; memory read every 0.25 s; five upstream CVE patches applied and credited (FU01 drops them at 9.0.3); hostile-file tests run on every GitHub train. Report: build/orchestrator/nov17/ffmpegfix-report.md.

### 2026-11-17, orchestrator, 1 line

Closed as done: merged in d8ccedb95.

### 2026-11-17, orchestrator, 1 line

The Mac half merged d8ccedb95. The iPhone half (FFmpeg inside the app through InProcessEngine, parity, the copy-protection check) is FMT54.

---
id: FU-FFMPEG
title: ffmpeg import's leftovers
kind: follow-up
status: done
priority: P2
platform: both
assignee: ffmpegfix
created: 2026-11-15
updated: 2026-11-17
found-by: ffmpegimport
branch: formats/ffmpeg-bundled
merged: d8ccedb95
reason:
related:
docs:
labels:
---

## Description

**FU-FFMPEG — ffmpeg import's leftovers.** From `ffmpegimport`'s report (item 6, November 15, 2026): drop the "mpp" extension; cap each tag passed to ffmpeg at 4 KB; treat a tag holding U+FFFD as missing; check copy protection first on the iPhone; name brew.sh in the install sentence; give a crashed ffprobe its own sentence. Also: a CUE sheet over a WMA or MKV file is taken to fit without a check, because `measuredLengths` uses afinfo; measure those with ffprobe.

## Comments

### 2026-11-16, issuelib, 1 line

Moved from TODO-2026-09-04.md, line 5440 of the version this import read, where it was an open item; the description is its text as it was.

### 2026-11-17, ffmpegfix, 1 line

Nothing of this issue's own list was changed by ffmpegfix; the bundled FFmpeg's work (FMT50) is on the same branch, formats/ffmpeg-bundled; see FMT50's comment.

### 2026-11-17, orchestrator, 1 line

Closed as done: merged in d8ccedb95.

### 2026-11-17, orchestrator, 1 line

Done at d8ccedb95 but for one item: checking copy protection first on the iPhone, which moved to FMT54 (FFmpeg's iPhone half).

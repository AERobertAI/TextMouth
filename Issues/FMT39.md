---
id: FMT39
title: FLAC export with chapters and tags
kind: format
status: open
priority: P2
platform: mac
assignee:
created: 2026-10-17
updated: 2026-11-16
found-by: the research of 2026-10-17
branch:
merged:
reason:
related:
docs:
labels:
---

## Description

**FMT39 — FLAC export with chapters and tags.** Difficulty M · Impact 2 · afconvert writes FLAC (verified) but no tags, so write the Vorbis comment block ourselves (title, artist, and CHAPTERnnn and CHAPTERnnnNAME, the convention ffmpeg reads, verified on the sample) into the file's metadata, and add FLAC to the editor's and Export's formats. About 200 lines in all, half of it the comment block, plus tests. Sample: flac-chapters/three-tones.flac.

## Comments

### 2026-11-16, issuelib, 1 line

Moved from TODO-2026-09-04.md, line 5872 of the version this import read, where it was an open item; the description is its text as it was.

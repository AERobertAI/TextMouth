---
id: FMT30
title: Audiobooks exported in another format, and a book of tracks as one file
kind: format
status: open
priority: P2
platform: mac
assignee:
created: 2026-10-17
updated: 2026-11-16
found-by: the user
branch:
merged:
reason:
related: FMT18
docs:
labels:
---

## Description

**FMT30 — Audiobooks exported in another format, and a book of tracks as one file.** Difficulty M · Impact 3 · The user's wish ("any book (text or audio)"). After FMT18: the Audio kind gains Convert to (M4A, M4B, Apple Lossless, MP3, WAV, AIFF, CAF) through the audio editor's renderer and encoders (Core Audio and the built-in LAME), keeping chapters; a book of tracks exports as one file with a chapter per track (rendered as the editor renders a timeline) or as its tracks, each converted. About 300 lines plus tests. Samples: m4b-chapters/, mp3-chapters/.

## Comments

### 2026-11-16, issuelib, 1 line

Moved from TODO-2026-09-04.md, line 5863 of the version this import read, where it was an open item; the description is its text as it was.

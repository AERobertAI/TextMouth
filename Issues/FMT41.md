---
id: FMT41
title: MIDI files
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

**FMT41 — MIDI files.** Difficulty M · Impact 1 · macOS ships a General MIDI bank (gs_instruments.dls, 2 MB): render a .mid offline to PCM with `AVAudioSequencer` and `AVAudioUnitSampler` in a manual-rendering `AVAudioEngine`, then encode it to AAC; marker events (FF 06) become chapters. About 300 lines plus tests; rendering was not tried. Sample: mid/tones.mid (three notes, two markers).

## Comments

### 2026-11-16, issuelib, 1 line

Moved from TODO-2026-09-04.md, line 5874 of the version this import read, where it was an open item; the description is its text as it was.

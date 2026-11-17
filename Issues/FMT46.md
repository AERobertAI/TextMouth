---
id: FMT46
title: EPUB 3 with Media Overlays (read-along books)
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

**FMT46 — EPUB 3 with Media Overlays (read-along books).** Difficulty L · Impact 3 · Publisher narration synchronized to the text: SMIL par elements, each a text fragment and an audio clip. Import such an EPUB as an audiobook in SMIL order, with headings from nav.xhtml and a transcript built from the pars (each fragment's text and clip times), so it follows the narration as a transcribed audiobook does, on any macOS. The DAISY reader's SMIL code carries over, but its `parseTime` reads SMIL timecounts with h, min, or ms as 0 ("500ms" gives 0; `DAISYParser+Audio.swift`, line 129, verified), a fix this needs and DAISY 3 books may want now. About 500 lines plus tests. Risks: src paths that climb out of the package; Ogg audio inside goes through the converter. Sample: epub3-media-overlays/three-tones-read-along.epub (three pars in three clip-time forms).

## Comments

### 2026-11-16, issuelib, 1 line

Moved from TODO-2026-09-04.md, line 5879 of the version this import read, where it was an open item; the description is its text as it was.

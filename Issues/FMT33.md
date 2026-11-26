---
id: FMT33
title: PowerPoint slides (.pptx, .ppsx)
kind: format
status: open
priority: P2
platform: mac
assignee:
created: 2026-10-17
updated: 2026-11-26
found-by: the research of 2026-10-17
branch:
merged:
reason:
related:
docs:
labels: release-0-7-0
---

## Description

**FMT33 — PowerPoint slides (.pptx, .ppsx).** Difficulty M · Impact 3 · Lecture slides as a book: each slide's title a heading (else "Slide N"), its text in order, tables a row at a time, pictures' alt text, and optional speaker notes; slide order from presentation.xml's sldIdLst through its relationships, not file names; hidden slides skipped. ZIPFoundation and `XMLParser`, as the DOCX reader is. About 350 lines plus tests; legacy .ppt is out. Sample: pptx/tides.pptx (made with pandoc: four slides, notes, a table).

## Comments

### 2026-11-16, issuelib, 1 line

Moved from TODO-2026-09-04.md, line 5866 of the version this import read, where it was an open item; the description is its text as it was.

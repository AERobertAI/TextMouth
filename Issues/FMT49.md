---
id: FMT49
title: Tagged PDF export with an outline
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

**FMT49 — Tagged PDF export with an outline.** Difficulty L · Impact 2 · The user's wish (any supported format). After FMT18. AppKit's PDF has no structure, but Core Graphics' `CGPDFContextBeginTag` writes one (verified: H1 and P tags, MarkInfo marked): lay out pages with Core Text, tag headings and paragraphs, set the language and title, and add an outline of the headings with PDFKit. About 400 lines plus tests; for sighted sharing and printing, since a blind reader prefers EPUB, HTML, or DOCX.

## Comments

### 2026-11-16, issuelib, 1 line

Moved from TODO-2026-09-04.md, line 5882 of the version this import read, where it was an open item; the description is its text as it was.

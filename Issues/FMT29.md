---
id: FMT29
title: DOCX and ODT export with real heading styles
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

**FMT29 — DOCX and ODT export with real heading styles.** Difficulty M · Impact 3 · The user's wish. After FMT18. Apple's writers make documents with no navigable headings (verified: no Heading1 style or outline level in DOCX, no text:h in ODT, no \outlinelevel in RTF), so write both with ZIPFoundation: DOCX with styles.xml defining Heading1 to 6 (w:outlineLvl) and core properties, ODT with the mimetype stored first and text:h with outline levels. The prototypes read back with their headings in pandoc and textutil, and TextMouth's own DOCX reader can read the DOCX back in a round-trip test; neither was opened in Word or LibreOffice. About 300 lines plus tests.

## Comments

### 2026-11-16, issuelib, 1 line

Moved from TODO-2026-09-04.md, line 5862 of the version this import read, where it was an open item; the description is its text as it was.

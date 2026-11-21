---
id: FMT26
title: FictionBook (.fb2, .fb2.zip)
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

**FMT26 — FictionBook (.fb2, .fb2.zip).** Difficulty M · Impact 2 · XML books, common among Russian-language public-domain e-books: a title-info description, nested sections whose titles give the heading levels, epigraphs, poems, notes, and base64 images. Read with `XMLParser`, honouring the prolog's encoding (windows-1251 is common), and .fb2.zip through ZIPFoundation. About 250 lines plus tests; no library. Samples: fb2/ (UTF-8, windows-1251, and a .fb2.zip).

## Comments

### 2026-11-16, issuelib, 1 line

Moved from TODO-2026-09-04.md, line 5859 of the version this import read, where it was an open item; the description is its text as it was.

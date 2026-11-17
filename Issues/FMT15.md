---
id: FMT15
title: CSV and TSV
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

**FMT15 — CSV and TSV.** Difficulty M · Impact 3 · RFC 4180 is only informational: write a small state machine (quoted fields with commas, line breaks, and doubled quotes), sniff the delimiter (comma, semicolon, tab, pipe) from the first lines, decode with `TextFileDecoder`, and stream large files. A row becomes a paragraph, its cells joined by ", " and the header row first (today's HTML tables join cells with a space only, which reads badly), with a setting to say each column's name before its cell (question 15) and a row cap with a notice for huge files. About 250 lines plus tests. Samples: csv/books.csv, tsv/books.tsv.

## Comments

### 2026-11-16, issuelib, 1 line

Moved from TODO-2026-09-04.md, line 5848 of the version this import read, where it was an open item; the description is its text as it was.

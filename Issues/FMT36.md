---
id: FMT36
title: OpenDocument presentations and spreadsheets (.odp, .ods)
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
related: FMT33, FMT35
docs:
labels: release-0-7-0
---

## Description

**FMT36 — OpenDocument presentations and spreadsheets (.odp, .ods).** Difficulty M · Impact 2 · The ODF forms of FMT33 and FMT35: a draw:page per slide, with its title frame and notes, and a table:table per sheet, with repeated rows and columns expanded but capped, since a blank trailing run can claim a million rows. About 250 lines each, sharing their XML walker, plus tests. Samples: odp/tides.odp, ods/inventory.ods (written by script; not opened in an ODF program).

## Comments

### 2026-11-16, issuelib, 1 line

Moved from TODO-2026-09-04.md, line 5869 of the version this import read, where it was an open item; the description is its text as it was.

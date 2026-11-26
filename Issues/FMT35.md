---
id: FMT35
title: Excel workbooks (.xlsx)
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
related: FMT15
docs:
labels: release-0-7-0
---

## Description

**FMT35 — Excel workbooks (.xlsx).** Difficulty M · Impact 2 · After FMT15's way of reading rows: a heading per sheet (hidden sheets skipped), shared strings, booleans, and cached formula values, and dates turned from serial numbers into dates through the styles' number formats and the 1900 or 1904 epoch, or a listener hears "45123"; stream large sheets. About 450 lines plus tests; legacy .xls is set aside. Sample: xlsx/inventory.xlsx.

## Comments

### 2026-11-16, issuelib, 1 line

Moved from TODO-2026-09-04.md, line 5868 of the version this import read, where it was an open item; the description is its text as it was.

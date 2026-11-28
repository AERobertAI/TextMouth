---
id: FMT57
title: PowerPoint, Excel, OpenDocument slides and sheets, CSV, and TSV
kind: format
status: open
priority: P2
platform: both
assignee:
created: 2026-11-24
updated: 2026-11-26
found-by: the user
branch:
merged:
reason:
related: B26, DR35
docs:
labels: release-0-7-0
---

## Description

Read PowerPoint, Excel, OpenDocument presentations and spreadsheets, CSV, and TSV, with TextMouth's own readers. Design: research/SLIDES-AND-SHEETS-2026-11-24.md.

The user's decisions, November 24, 2026: every deck and sheet format the report lists (.pptx, .pptm, .ppsx, .potx, .ppt, .pps, .pot, .xlsx, .xlsm, .xltx, .xls, .odp, .ods) and CSV and TSV; Mac and iPhone parity as much as possible. Keynote and Numbers stay refused with advice to export, as the report recommends, unless the user decides otherwise.

Samples: 25 private exports of the user's own Google Slides and Sheets in HumanFiles/DriveExports (with a manifest), never to be copied into a tracked file; Google pads each sheet to 1,000 rows and exports a notes page for every slide; some decks have alt text on every picture and some on none. Public test files: Apache POI's test-data (Apache License 2.0), LibreOffice's test documents (MPL 2.0), and csv-spectrum (BSD-2-Clause, by its package.json); SheetJS's test_files repository has been disabled by GitHub.

Open: the questions in humanQuestions/2026-11-24.md. Related: B26 (a table's cells joined by one space), DR35 (a picture's description in Word and rich text).

## Comments

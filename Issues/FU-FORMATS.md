---
id: FU-FORMATS
title: Smaller leftovers of the November 15 format branches
kind: follow-up
status: open
priority: P2
platform: both
assignee: phoneformats
created: 2026-11-15
updated: 2026-11-18
found-by: orchestrator
branch: phone/own-lossless
merged:
reason:
related:
docs:
labels:
---

## Description

**FU-FORMATS — Smaller leftovers of the November 15 format branches.** `pageimages`: pictures over 24 megapixels, and WebP and GIF pages, are refused rather than scaled or read; `mp3render`: the edits preview still decodes through the composition, not the per-stretch readers the render now uses; the iPhone refuses TTA, WavPack, and Monkey's Audio at import (`PhoneImportRefusal.refuseConversion`; its Info.plist declares none), though their readers compile into it, so the own readers could let it take them. Each item's report is in `build/orchestrator/nov15/`.

## Comments

### 2026-11-16, issuelib, 1 line

Moved from TODO-2026-09-04.md, line 5442 of the version this import read, where it was an open item; the description is its text as it was.

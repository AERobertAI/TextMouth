---
id: DOC01
title: Pages that mean October's B12 say B12-OCT
kind: docs
status: done
priority: P3
platform: both
assignee: docspass1116
created: 2026-11-16
updated: 2026-11-16
found-by: review-issuelib
branch: docs/pass-1116
merged: 377101c46
reason:
related: B12-OCT
docs:
labels:
---

## Description

The review of tools/issue-library (November 16, 2026, its item 13) found pages that cite B12 for the October bug, an Edit Text change that automatic re-reads keep, which B12 no longer names alone since November's B12 (the 64-bit float render) took the ID too.

- docs/architecture/state/text-caches-rereads-edits.md, "Edited text" and "Who may write edited text";
- docs/architecture/state/text-caches.md, "How the page reader's version is read";
- docs/architecture/state/package-records.md, "Analysis-owned fields";
- docs/agents/history.md, "Where things stood on November 1, 2026", a log, which may keep its words.

`doclib find '\bB12\b'` lists them. The docs pass writes B12-OCT where a page means the October bug.

## Comments

### 2026-11-16, docspass1116, 1 line

Done on docs/pass-1116: B12-OCT now stands in package-records (Analysis-owned fields), text-caches (How the page reader's version is read), and text-caches-rereads-edits (Edited text, Who may write edited text). The log history.md keeps its November 1 words.

### 2026-11-16, orchestrator, 1 line

Closed as done: merged in 377101c46.

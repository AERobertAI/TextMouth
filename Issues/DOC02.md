---
id: DOC02
title: DR35's limitation is also stated in the Word 6 and Word 95 section, which no marker cites
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
related: DR35
docs: what-word-6-word-95
labels:
---

## Description

DR35's own text says "the Word 6 and Word 95 page also lists pictures as not read", and that page's section "What Word 6 and Word 95 reading leaves out" says "Headers, footers, comments, and pictures are not read."
The import marks only the sections that hold an item's quoted sentences, so this section names no issue, as the review of tools/issue-library (November 16, 2026, its item 9) noted.

On main, the docs pass adds DR35 to that section's marker (`status: incomplete; issues: DR35`), and `issuelib set DR35 docs` adds the section to DR35's docs.

## Comments

### 2026-11-16, docspass1116, 1 line

Done on docs/pass-1116: the section what-word-6-word-95 (What Word 6 and Word 95 reading leaves out) now says status: incomplete; issues: DR35. The orchestrator still runs issuelib set DR35 docs on main to add the section to DR35's docs line (a branch may not).

### 2026-11-16, orchestrator, 1 line

Closed as done: merged in 377101c46.

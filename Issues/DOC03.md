---
id: DOC03
title: testing-iphone.md lists PhoneFontPolicyTests in the phone area
kind: docs
status: open
priority: P3
platform: iphone
assignee:
created: 2026-11-16
updated: 2026-11-16
found-by: gotofont
branch:
merged:
reason:
related:
docs:
labels:
---

## Description

docs/developer/testing-iphone.md should name PhoneFontPolicyTests (the scan that refuses fixed-size fonts under Platform/iOS, merged November 16, 2026 with A11Y-GOTO) among the phone area's classes.

## Comments

### 2026-11-16, orchestrator, 1 line

Also for testing-iphone.md, section two-ios-test-targets: one sentence naming the no-sound rule's one exception, ReaderViewModel inside a makeReader() helper, which the scanner still reads for anything that plays, speaks, or resumes (Q11, merged 0f9e29faf).

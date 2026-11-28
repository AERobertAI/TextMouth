---
id: Q-HANG
title: `LegacyDocumentContentModelTests.testSleepTimerDurationNamesAndPresetsComeFromProductionModel` started and never finished in one iPhone run
kind: test
status: open
priority: P2
platform: iphone
assignee:
created: 2026-11-15
updated: 2026-11-16
found-by: train 1115-2347
branch:
merged:
reason:
related:
docs:
labels:
---

## Description

**Q-HANG — `LegacyDocumentContentModelTests.testSleepTimerDurationNamesAndPresetsComeFromProductionModel` started and never finished in one iPhone run.** Train 1115-2347 (November 15, 2026), outside that branch's files; the full run on the 0.5.0 tree passed it. Watch for it again before looking deeper.

## Comments

### 2026-11-16, issuelib, 1 line

Moved from TODO-2026-09-04.md, line 5444 of the version this import read, where it was an open item; the description is its text as it was.

### 2026-11-20, orchestrator, 1 line

**Instrumented, no cause found (flakeq15, November 20, 2026).** Reading found nothing in the test that can wait: it is synchronous and pure, with no expectation, lock, main-thread wait, timer, or speech, so a hang points at the host or the simulator, or something an earlier test left running. Each stage now runs off the test thread with a 60-second limit that fails naming what it waited for. GitHub run 44823357501 ran the class 50 times on the iPhone simulator (17 tests each), 0 failures; the hang never came back. Open until it does, with the stage it names.

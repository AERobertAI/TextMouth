---
id: A11Y-GOTO
title: The iPhone Go To sheet's two text fields don't follow Dynamic Type
kind: bug
status: done
priority: P2
platform: iphone
assignee:
created: 2026-11-15
updated: 2026-11-16
found-by: train 1115-1800
branch:
merged: ff2025a64
reason:
related:
docs:
labels:
---

## Description

**A11Y-GOTO — The iPhone Go To sheet's two text fields don't follow Dynamic Type.** Found November 15, 2026: train 1115-1800's iPhone accessibility audit failed on Dynamic Type for the sheet's two UITextFields, and 1115-1838 passed on the same main, so the audit only sometimes reaches them; the gap is real. Give both fields `adjustsFontForContentSizeCategory` with a text style, and pin it with a test that doesn't depend on the audit's order.

## Comments

### 2026-11-16, issuelib, 1 line

Moved from TODO-2026-09-04.md, line 5439 of the version this import read, where it was an open item; the description is its text as it was.

### 2026-11-16, orchestrator, 1 line

Closed as done: merged in ff2025a64.

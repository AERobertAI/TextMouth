---
id: FMT45
title: Email (.eml, .mbox)
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

**FMT45 — Email (.eml, .mbox).** Difficulty L · Impact 3 · Archived mail, newsletters, and support threads: a heading per message ("Subject, from, date"), then its body. Foundation has no MIME parser: header folding, RFC 2047 encoded words, quoted-printable and base64, charsets, multipart/alternative (the plain part preferred, else the HTML part through the existing converter), format=flowed, attachments listed by name, nested messages, and no remote images; mbox per RFC 4155, which prescribes no escaping, so read mboxrd and mboxo and find the separator by its pattern, streaming line by line. About 850 lines plus tests. Samples: eml/cafe-hours.eml (a quoted-printable ISO-8859-1 plain part and an HTML part), mbox/three.mbox (>From and >>From lines).

## Comments

### 2026-11-16, issuelib, 1 line

Moved from TODO-2026-09-04.md, line 5878 of the version this import read, where it was an open item; the description is its text as it was.

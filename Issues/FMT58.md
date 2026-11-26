---
id: FMT58
title: RAR archives (3, 4, and 5), passwords included, ported from rardecode
kind: format
status: open
priority: P2
platform: both
assignee:
created: 2026-11-26
updated: 2026-11-26
found-by: the user, November 26
branch:
merged:
reason:
related: FR41
docs:
labels: release-0-7-0
---

## Description

research/RARDECODE-2026-11-26.md: rardecode (BSD 2-clause, Go) is the only option that opens encrypted RAR 3/4 and 5; libarchive's RAR readers refuse encryption. Its commit messages cite UnRAR's source, so it was written with UnRAR in view (question 4 of humanQuestions/2026-11-26.md). Recommended: its choice B, RAR 3, 4, and 5 with the standard filters and passwords, about 3,100 lines of Swift and 95 to 185 KB in each app; PPMd and the VM only if real books need them; a corpus from libarchive's and SharpCompress's encrypted samples. The user put RAR in 0.7.0, with the sheets and decks formats.

## Comments

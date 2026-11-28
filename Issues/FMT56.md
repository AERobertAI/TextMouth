---
id: FMT56
title: NLS BARD braille books: a .bopf package and its BRF volumes, read as one book
kind: format
status: done
priority: P2
platform: both
assignee: bardbraille
created: 2026-11-23
updated: 2026-11-23
found-by: the user
branch:
merged: 5938367ae
reason:
related: DR34, FMT22
docs:
labels:
---

## Description

The user, November 23, 2026: support NLS BARD braille packages, and treat .bopf files and zips holding them as DAISY books are treated. A BARD braille download is a zip of BRF volumes (the user's sample: 14 volumes of about 190 KB, 38 cells by 25 lines a page) and one .bopf file. The .bopf is an Open eBook 1.0 package, the form of a DAISY 3 OPF: dc-metadata (title, creator, description, publisher, date, language, subjects, format, identifier), an x-metadata series of brl:* metas (brailleCode EBAE, contractionLevel 2, volumes, pages, lineLength 40, pageLength 26), and a manifest and spine of the volumes. Import it as one book, the volumes in the spine's order, each beginning with a heading, with the metadata from the package and the braille table from brl:brailleCode and contractionLevel. Accept the .bopf, its folder, or a zip, on both apps. Tests: a public fixture made of TextMouth's own text in this form, with nothing of NLS's; and a private test of the user's HumanFiles zip, skipped when it is absent. Brief: Scripts/agents/briefs/2026-11-21/bardbraille.md (local).

## Comments

### 2026-11-23, orchestrator, 1 line

Closed as done: merged in 5938367ae.

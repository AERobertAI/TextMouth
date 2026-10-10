# Task brief: docs9 — README.md and ARCHITECTURE.md for the later October 10 merges

Slug `docs9`; branch `docs/october-10-later`. Markdown only, no build, no suite. Read `common.md` beside this file first; where it says "edit no `*.md`", you are the exception for README.md and ARCHITECTURE.md, and only those two. Its usage override ended at the 8:00 a.m. reset: read only "5-hour session" and "Weekly (all models)", ignore "Weekly (Fable)", and stop with a report below 10% left. `docs8.md` beside this file was the previous pass; follow its rules on where things go and on keeping each document's voice.

## What to document
The branches merged after `docs/october-10` (ada6c7cf), each in its own commit, in merge order:
1. `feature/feed-item-policy` (merge 87d8857c, FR11's branch B: the List and download choice, `feedItems` and `feedNewestCount`, the newest-N rule, waiting downloads)
2. `fix/playback-robustness` (merge 8e2ac3c3)
3. `fix/feed-index-review` (merge cd256562, REV10's fixes to A1: the Unsubscribe stopgap that returns downloads as books, the commands feed items lose, the counts, cloud data directories waiting for feed indexes)
4. `feature/menu-and-window-shortcuts` (merge 2c3b3eac, FR12's branches D and E)
5. `feature/feed-item-policy-ui` (FR11's branch C) and `fix/feed-followups`, only once the orchestrator has posted on the board that each merged; leave out any that has not, and say so.

Each agent's proposed README and ARCHITECTURE wording is in `AGENT-NOTES-2026-10-04.md` under "Agent notes, October 9, 2026" ("From the feeditempolicy agent", "From the playbackfixes agent" (two reports: the first's wording with the second's changes), "From the feedindexfixes agent", "From the menukeys agent"), and each merge's TODO entry summarizes it. **Check every sentence against the merged code before you paste it**; where they differ, the code wins, and you say so.

Stale sentences to find and fix while you are there: everything about `feedKeepEntries`, `feedAutoDownload`, "Keep the newest … entries", and "Download new episodes and articles by themselves" (branch B, and branch C if it merged); the Unsubscribe paragraph docs8 wrote ("listed only by Recently Opened and the Reading List"), which the feed-index-review merge changed; the Shift paragraph, the dialog keys, and Shift-Command-T (FR12's D and E); REV10's inexact claims listed in the TODO ("In the Library and reader windows" is every window but the audio editor's; 64 control characters; a book's end also moves the media focus; the double-press time from the store is corrected silently).

## Commits and report
One commit per documented branch, each ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`, staged with `git add -f README.md ARCHITECTURE.md`. Register on the board as `docs9` with `--files README.md ARCHITECTURE.md`, post `commit` notices, and `done: docs/october-10-later` at the end. Prefix your scratch files with `docs9-`. Report: the commits; each place where the code contradicted the proposed wording; stale sentences fixed; follow-ups.

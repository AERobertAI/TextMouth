# Task brief: docs10 — README.md and ARCHITECTURE.md for the merges after the later October 10 pass

Slug `docs10`; branch `docs/october-10-afternoon`. Markdown only, no build, no suite. Read `common.md` beside this file first; where it says "edit no `*.md`", you are the exception for README.md and ARCHITECTURE.md, and only those two. Its usage override ended at the 8:00 a.m. reset: read only "5-hour session" and "Weekly (all models)", ignore "Weekly (Fable)", and stop with a report below 10% left. `docs9.md` beside this file was the previous pass; follow its rules on where things go and on keeping each document's voice.

## What to document
The branches merged after `docs/october-10-later` (e923e43a), each in its own commit, in merge order:
1. `feature/feed-download-progress` (dde4d957, FR10's feed half)
2. `fix/reading-list-followups` (9bcecf3c)
3. `fix/where-am-i-and-keys` (f9193138)
4. `feature/move-to-library` (30eab7f9, FR11's branch D)
5. `fix/import-and-sheet-followups` (bf6bcf00)
6. `fix/a10-accessibility` (704b1b53)
7. `fix/where-am-i-followups` (c89cd338)
8. `fix/feed-policy-review` (7339bcb7)
Each agent's README and ARCHITECTURE wording is in `AGENT-NOTES-2026-10-04.md` under "Agent notes, October 9, 2026" (their sections are titled by agent and branch), and each merge's TODO entry summarizes it. REV12 in TODO-2026-09-04.md lists claims a reviewer found inexact, for this pass: write the code's version. **Check every sentence against the merged code before you paste it**; where they differ, the code wins, and you say so.

Stale sentences to find and fix: the README's sentence that a Play during Where Am I? over a paused book changes nothing (now held and started as it ends); "Recording Window" (now "New Recording"), and that the Record buttons' hints give default keys (they name the keys in force); ARCHITECTURE's `KeyboardShortcutManager.refusal(ofKeys:for:)`, `ShortcutAction.refusal(ofKeys:)`, `blocksBookPlayback`, `WhereAmIInterruptionPolicy`, and `action(holding:in:)`, which are gone; the Unsubscribe paragraphs (Unsubscribe is a switch since 30eab7f9); `FeedDownloadTimeEstimate` (now `TimeLeftEstimate`); "Speak Download Progress works from any window" (every window but an audio editor's); a feed item's Remove (Delete Download… since 7339bcb7); the search limit (500 since 704b1b53). Do not describe as built what the TODO lists as waiting (Delete Feed…, the book's end as Finished, recording time, text anchors).

## Commits and report
One commit per documented branch, each ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`, staged with `git add -f README.md ARCHITECTURE.md`. Register on the board as `docs10` with `--files README.md ARCHITECTURE.md`, post `commit` notices, and `done: docs/october-10-afternoon` at the end. Prefix your scratch files with `docs10-`. Report: the commits; each place where the code contradicted the proposed wording; stale sentences fixed; follow-ups.

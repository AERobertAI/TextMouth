# Task brief: docs11 — README.md and ARCHITECTURE.md for the October 10 evening merges

Slug `docs11`; branch `docs/october-10-evening`. Markdown only, no build, no suite. Read `common.md` beside this file first; where it says "edit no `*.md`", you are the exception for README.md and ARCHITECTURE.md, and only those two. Its usage override ended at the 8:00 a.m. reset: read only "5-hour session" and "Weekly (all models)", ignore "Weekly (Fable)", and stop with a report below 10% left. `docs10.md` beside this file was the previous pass; follow its rules on where things go and on keeping each document's voice.

## What to document
The branches merged after `docs/october-10-afternoon` (c316c066), each in its own commit, in merge order:
1. `fix/a11-sort-speed-reader-text` (cc2d6c39, A11)
2. `fix/rev13-app-cleanups` (adf3d24a)
3. `feature/delete-feed` (428f4532, FR14)
4. `fix/book-ends-finished` (57d04ab9, P07)
5. `fix/audiobook-recording-time` (50cdd78c, P08)
6. `fix/rev13-feed-followups` (2304010c)
7. `feature/text-anchors` (2597e5c8, T06's branch A: ARCHITECTURE only, since nothing is visible yet)
8. `fix/where-am-i-and-package-moves` (b985d72a)
Each agent's README and ARCHITECTURE wording is in `AGENT-NOTES-2026-10-04.md` under "Agent notes, October 9, 2026" (their sections are titled by agent and branch), and each merge's TODO entry summarizes it. **Check every sentence against the merged code before you paste it**; where they differ, the code wins, and you say so. Later branches change earlier ones' code (the feed follow-ups change FR14's refusals and wording; P08 changes the Where Am I? and Copy Reading Position formatters P07 gave `isFinished`; the Where Am I? move fixes change what a cancel and Play/Pause do): describe main as it stands.

Stale sentences to find and fix: the jump panels' Hours, Minutes, and Seconds fields (one field since P08); "Go to Time" counting listening time; the speed sheet's stepper and its toolbar name (Audio Settings since A11); "the list keeps every row" for Find Duplicate Books (pages since adf3d24a); the offline wait's wording, Unsubscribe's and Delete Episode's announcements as their alert closes, the focus after Cancel, and Unsubscribe's question counting spared packages (all changed by FR14); a feed's folder offering Delete Folder…; "100 percent, 0 seconds remaining" for a finished book; Books Finished counting every finish; Play at a book's end replaying it; `AudioEditorTimeEntry` (now `TimeEntry`); `CountWording.progress` (removed); `feedBooksOpenInReaders` (removed). Do not describe as built what the TODO lists as waiting (T06's branches B to E).

## Commits and report
One commit per documented branch, each ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`, staged with `git add -f README.md ARCHITECTURE.md`. Register on the board as `docs11` with `--files README.md ARCHITECTURE.md`, post `commit` notices, and `done: docs/october-10-evening` at the end. Prefix your scratch files with `docs11-`. Report: the commits; each place where the code contradicted the proposed wording; stale sentences fixed; follow-ups.

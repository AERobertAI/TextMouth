# Task brief: docs7b — README.md and ARCHITECTURE.md for the October 7 evening merges

Slug `docs7b`; branch `docs/october-7-evening`. Markdown only, no build, no suite. Read `common-evening.md` beside this file first; where it says "edit no `*.md`", you are the exception for README.md and ARCHITECTURE.md, and only those two. `docs7.md` beside this file was the afternoon's pass; follow its rules on where things go and on keeping each document's voice.

## What to document
The branches merged on October 7 evening, each in its own commit, in merge order:
1. `fix/feed-folder-counts` (merge 9ae7becc, FR03 follow-ups)
2. `feature/reading-list` (merge 01197eb1, FR09's library part)
3. `fix/october-7-followups` (merge cb134bb1: #1290, #1291, #1308, #1296)
4. `fix/speech-refusal-followups` (merge 6b78bd4c, REV07's speech findings)
5. `feature/import-progress` (merge f2b39d7f, FR10's first half)
6. `feature/reading-list-reader` (merge 9a61278d, FR09's reader part)
7. `fix/text-field-editing-keys` (merge 5b137a63, B03), once the orchestrator posts that it merged with a green suite; if it has not by the time you reach it, leave it out and say so.

Each agent's proposed README and ARCHITECTURE wording is in `AGENT-NOTES-2026-10-04.md` under "Agent notes, October 7, 2026 (evening)", in sections titled "From the <slug> agent (<branch>), Oct 7 evening", and each merge's TODO entry in `TODO-2026-09-04.md` summarizes it (search for the branch name). **Check every sentence against the merged code before you paste it** (`git show <merge>` and the files it names); where the code and the wording differ, the code wins, and you say so in your report. Several of these branches change sentences the afternoon's pass wrote (the hand-edit refresh, the reader's editors, the refusal, the speech guard's shapes, the unchecked pin, which is now 26, a feed's counts, the four Library categories, which are now five): find and fix each one, so nothing stale remains. The FR11 and FR12 design notes (`FEED-ITEMS-RESEARCH-2026-10-07.md`, `KEYBOARD-SHORTCUTS-RESEARCH-2026-10-07.md`) describe work not yet built: mention them only where the README or AGENTS.md-style lists of research documents name such notes, never as features.

## Commits and report
One commit per documented branch, each ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`, staged with `git add -f README.md ARCHITECTURE.md`. Register on the board as `docs7b` with `--files README.md ARCHITECTURE.md`, post `commit` notices, and `done: docs/october-7-evening` at the end. Report: the commits; each place where the code contradicted the proposed wording; stale sentences fixed; follow-ups.

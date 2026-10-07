# Task brief: docs7 — README.md and ARCHITECTURE.md for the five October 7 afternoon merges

Slug `docs7`; branch `docs/october-7`. Markdown only, no build, no suite. Read `common-evening.md` beside this file first; where it says "edit no `*.md`", you are the exception for README.md and ARCHITECTURE.md, and only those two.

## What to document
The five branches merged on October 7 afternoon, each in its own commit, in merge order:
1. `feature/unopened-category` (merge 1790ae21, FR08)
2. `feature/hand-edited-metadata-flags` (merge 065ec6a0, FR06)
3. `fix/speech-markup-guard` (merge aec5c91b, B01)
4. `fix/airpods-rewind-after-finish` (merge f5273ba2, B02)
5. `feature/speak-info` (merge 33219144, FR07)

The wording each agent proposed is in `AGENT-NOTES-2026-10-04.md` under "Agent notes, October 7, 2026" ("README wording" and "ARCHITECTURE wording"), and each merge's TODO entry in `TODO-2026-09-04.md` summarizes it. **Check every sentence against the merged code before you paste it** (`git show <merge>` and the files it names): a reviewer is reading the same merges now and the agents' wording may be inexact; where the code and the wording differ, the code wins, and you say so in your report.

## Where it goes
- README.md describes the app to its user: put each feature where a user looks for it (the Library window's categories, Book Info, the keyboard commands and Settings' key map, playback and the AirPods, what happens when speech fails). Remove what is no longer true: "No Folder" as a category; anything saying Command-I does nothing for feeds or folders. Search for each old term (`No Folder`, `noFolder`, `Book Info`, `Where Am I`, `Release Media Controls`, `Previous Track`) and fix every stale sentence.
- ARCHITECTURE.md explains ownership: add each type to the entry that owns its state (the library index for `LibraryCategory` and `Library.sortSetting(at:)`; package records for `Book.handEdits`; the reader and media playback for `hasFinishedBook`, `SpeechMarkupGuard`, and `SpeechService`'s recovery; windows or the library for `LibraryInfoSpeaker` and `LibraryInfoRow`), the shared helpers list for `SpeechMarkupGuard` and `LibraryInfoWording`, and the concurrency paragraph where a branch changed a thread or a pin (the unchecked-Sendable pin is 27). Change "It describes main as of October 6, 2026" to October 7.
- Keep each document's voice: plain sentences, the names of Swift types in code font, no marketing, no "simply", and nothing conveyed only by a picture or a symbol.

## Commits and report
One commit per documented branch (subject like "Describe the Unopened category in the README and the architecture"), each ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. `*.md` is gitignored: stage with `git add -f README.md ARCHITECTURE.md`. Register on the board as `docs7` with `--files README.md ARCHITECTURE.md`, post `commit` notices, and `done: docs/october-7` at the end. Report: the commits; each place where the code contradicted the proposed wording; any stale sentence you found and fixed outside the five features; follow-ups.

# Task brief: docs7c — README.md and ARCHITECTURE.md for the October 7 late merges

Slug `docs7c`; branch `docs/october-7-late`. Markdown only, no build, no suite. Read `common.md` beside this file first; where it says "edit no `*.md`", you are the exception for README.md and ARCHITECTURE.md, and only those two. `../2026-10-07/docs7.md` and `../2026-10-07/docs7b.md` were the earlier passes; follow their rules on where things go and on keeping each document's voice.

## What to document
The three branches merged late on October 7, each in its own commit, in merge order:
1. `fix/hand-edit-baselines` (merge afde34e4, REV07 library finding 3: editor saves change and mark only what the user changed)
2. `fix/finished-book-followups` (merge 377edc97, REV07 speech findings 4 and 5: a finished book once the next book takes over, and Release Media Controls)
3. `feature/shortcut-edit-record` (merge 094dd885, FR12's branch A: a record of the shortcuts the user edited, config.json's two forms, the Shortcuts tab's words, "Edited", and Reset to Default)

Each agent's proposed README and ARCHITECTURE wording is in `AGENT-NOTES-2026-10-04.md` under "Agent notes, October 7, 2026 (evening)", in the sections "From the editbaselines agent", "From the finishedbook agent", and "From the shortcutsA agent" (all "Oct 7 late"), and each merge's TODO entry in `TODO-2026-09-04.md` summarizes it (search for the branch name). **Check every sentence against the merged code before you paste it** (`git show <merge>` and the files it names); where the code and the wording differ, the code wins, and you say so in your report.

Stale sentences to find and fix while you are there:
- The README's config.json paragraph ("a shortcut given to one action is taken from any other that works in the same windows") and ARCHITECTURE's preferences entry ("a key belonging to at most one action of each scope") overstated how keys were reassigned (#1422). After branch A they are true; check them against the code and make them exact.
- Every sentence that says the whole map of shortcuts is saved once one is customized, or names `customKeyboardBindings` as the live store (it is now read once, at the first launch, and retired).
- The README still promises Shift-Command-T for New from Text…, which does not work while Show Sleep Timer holds that key (#1451). Leave the promise out or say plainly that the key is Show Sleep Timer's until shortcuts scoped to a kind of window are built; do not describe that future work as a feature.
- Do not describe double presses, the full-summary actions, or the editable menu keys as features: they are FR12's branches B to E, not yet merged.

## Commits and report
One commit per documented branch, each ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`, staged with `git add -f README.md ARCHITECTURE.md`. Register on the board as `docs7c` with `--files README.md ARCHITECTURE.md`, post `commit` notices, and `done: docs/october-7-late` at the end. Report: the commits; each place where the code contradicted the proposed wording; stale sentences fixed; follow-ups.

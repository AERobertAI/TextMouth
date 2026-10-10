# Task brief: docs8 — README.md and ARCHITECTURE.md for the October 9 and 10 merges

Slug `docs8`; branch `docs/october-10`. Markdown only, no build, no suite. Read `common.md` beside this file first; where it says "edit no `*.md`", you are the exception for README.md and ARCHITECTURE.md, and only those two. `docs7c.md` beside this file, and `../2026-10-07/docs7.md` and `docs7b.md`, were the earlier passes; follow their rules on where things go and on keeping each document's voice.

## What to document
The branches merged on October 9 and 10, each in its own commit, in merge order:
1. `feature/speech-refusal-alert` (merge 6c5b4d9d, B05: the "Speech Stopped" report)
2. `feature/double-press-shortcuts` (merge ed23f19c, FR12's branch B: double presses, the double-press time, the dispatcher, Shift beyond a binding's own, one table of key names)
3. `feature/feed-item-index` (merge de0839c5, FR11's branch A1: each feed's own index and packages, the library's counts "743 books, 2 feeds", Recent with one item per feed, the first launch's move)
4. `fix/now-playing-followups` (merge 2f74c130: which book the AirPods reach after a pause behind another window, closing a window, Release Media Controls' new sentence, the pause sound, Play during the hand-over, metadata saves, the NUL in speech)
5. `feature/full-summary-actions` (merge 3cf2c820, FR12's branch C: Speak Full Info and Where Am I? Full Summary, the three-second rule retired)
6. `feature/feed-item-records` (FR11's branch A2 and FR13, Recent renamed Recently Opened), only once the orchestrator has posted on the board that it merged; if it has not by the time you reach it, leave it out and say so.

Each agent's proposed README and ARCHITECTURE wording is in `AGENT-NOTES-2026-10-04.md` under "Agent notes, October 9, 2026", in sections titled "From the <slug> agent (<branch>)", and each merge's TODO entry in `TODO-2026-09-04.md` summarizes it (search for the branch name). **Check every sentence against the merged code before you paste it** (`git show <merge>` and the files it names); where the code and the wording differ, the code wins, and you say so in your report.

Stale sentences to find and fix while you are there:
- The README's "A punctuation key keeps its symbol, as in "Go Back: Command + ["" is wrong since branch B; ARCHITECTURE's duplication note about `AudioEditorWording.keyName` (#1508) goes, since branch B shares one table.
- The README's "three quick presses" passage on Speak Info and Where Am I?, and every mention of the three-second rule, are wrong since branch C.
- Every sentence that says episodes appear in All Items, Unopened, or Recent, or that a feed's downloads are books in the feed's library folder, is wrong since A1.
- Unsubscribe: until FR11's branch D, unsubscribing deletes the feed's record while its downloads stay under `Feeds/<feed ID>/`, listed nowhere, though nothing is lost. Say it plainly where the README describes Unsubscribe, so the user is not surprised, without describing branch D as built.
- The unchecked-concurrency pin moved (A1); check the number the documents give against `UncheckedConcurrencyPolicyTests`.

## Commits and report
One commit per documented branch, each ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`, staged with `git add -f README.md ARCHITECTURE.md`. Register on the board as `docs8` with `--files README.md ARCHITECTURE.md`, post `commit` notices, and `done: docs/october-10` at the end. Prefix your scratch files with `docs8-`. Report: the commits; each place where the code contradicted the proposed wording; stale sentences fixed; follow-ups.

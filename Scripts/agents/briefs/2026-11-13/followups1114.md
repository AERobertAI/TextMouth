# Three follow-ups (November 14, 2026, before the weekly reset)

You are one of three Sonnet workers: `brfheads`, `rlcloud`, or `audiolook`. Your launch message says which one. First read `common.md` beside this brief and follow it. Its rules bind you:
- the live library;
- `rm` with literal paths only;
- no search from `/` or `~`;
- builds only through the heavy-work lock;
- trains on GitHub;
- no push except through the train tools;
- no merge into main.

**Delete nothing tonight.** Main is 0.4.8 (be2d2a31 or later). Start your branch there.

## If the usage limit stops you

The weekly limit may run out before you finish. The orchestrator resumes you after the reset at 07:00 EST. **Commit after every item.** Before each item, add one line saying what is done and what is next. Put it in `build/orchestrator/nov13/<your name>-progress.md` in the main checkout. If you can't write there, use `PROGRESS-<your name>.md` at your worktree's root, staged with `git add -f`.

## `brfheads`, branch `fix/brf-heads-followup`

Read `build/orchestrator/nov13/brflayout-report.md` and the TODO entry "BRF running heads, change lines, chapter headings, title page" (in `TODO-2026-09-04.md`).
1. Six running-head blocks remain in the user's BRF. They have the form "life of pi. part2" with a left-hand number such as `a102`. A head whose text differs only by a part or volume number from the repeating one, or whose page carries the number in another place, is still a head. Find the rule that keeps them, fix it, and test with invented braille, never the book's.
2. The English Braille suggestion in Book Information is not announced when it appears. Post a VoiceOver announcement once, when the sheet's load finishes and the suggestion shows, as the app's other late sentences do (find how they do it). It must not repeat on every redraw.

## `rlcloud`, branch `fix/reading-list-cloud-followups`

Read `build/orchestrator/nov13/rlcheck-report.md` (the follow-ups section) and the TODO entry for the Reading List options. Fix these:
1. In a cloud library, a book whose size the cloud doesn't report counts as 0. A first refresh with many such books could then download them all at once. Treat an unknown size as one book at a time: download one, check the free space again, then go on.
2. Log each book left out for lack of room, in TextMouth's own log, never in a dialog.
3. The user's own evicted Kept books are skipped silently too. Log them the same way.
4. The "Remove books when finished" hint is incomplete. A finished book stays on the list while its reader window rests on it, so say so in the hint.
5. The single-book notice should name the list.

Test everything without a real cloud: the code has seams for it, which the check report names.

## `audiolook`, branch `perf/audio-lookahead`

Items C8 and C9 of `build/orchestrator/optaudit/audit-report.md`, Part C. Check each one in the code first.
- **Never switch speech between direct mode and the audio engine during playback.** The position gap between `willSpeakRangeOfSpeechString` and the audio heard is unknowable, and every handoff tried (skipping words, fades) was audible. Switch only at a seek the user makes, at pause and resume, or at a chapter boundary. Nothing you change may alter what is heard at Play, at a seek, or at a chapter change.
- **C8:** the audio engine graph is built lazily, so a look-ahead that only renders never builds one.
- **C9:** Play after Stop on the same text, in the same voice, keeps the chapter's render.
- Include the audit's new tests. The audio-engine tests are skipped on GitHub, so name them in your report: the orchestrator's Mac suite runs them.

## All three

- Make one commit per item, each with its test.
- A test must fail without its fix. Prove that through a scratch copy and `run_locked.py`, or by a GitHub run of your own, never on a shared train.
- Then:
  1. type-check;
  2. run one train naming your classes and areas;
  3. review your diff;
  4. rebase onto local main;
  5. report as `common.md` says, in at most 40 lines.
- Your worktree may refuse writes outside it, so your final message is the record.

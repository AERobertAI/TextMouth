# Task brief: reviewpolicy and reviewshortcuts — read-only review of the October 10 merges

Two reviewers share this brief; each takes its own merges. You are read-only: **edit no file, make no commit, run no build or test, post nothing on the board.** Your report goes to the orchestrator. Read `common.md` beside this file for the user's rules; the usage override it describes ended at the 8:00 a.m. reset, so read only "5-hour session" and "Weekly (all models)", ignore "Weekly (Fable)", and stop with what you have below 10% left. `review10.md` beside this file is the format the night's first review used; it found real bugs, and REV10 in TODO-2026-09-04.md lists them and where they went.

## Your merges
Read each merge's diff against its first parent (`git diff <merge>^1 <merge>`), its commits, and the code it relies on; the agents' notes are in `AGENT-NOTES-2026-10-04.md` under "Agent notes, October 9, 2026".
- **reviewpolicy**: `87d8857c` feature/feed-item-policy (FR11's branch B: the List and download choice, the one-time move of the old settings, the newest-N rule's passes and protections, file removals off the main thread, the commit race) and `cd256562` fix/feed-index-review (REV10's A1 fixes: the move's validation, cloud reads of feed indexes, the Unsubscribe stopgap that returns downloads, the commands feed items lose, the counts). Say exactly what the first launch of main does to the user's two feeds (Finish It!, 381 items, nothing downloaded, its old override -1; The Digital Antiquarian, one downloaded and opened article), and where it could lose or wrongly download or remove anything.
- **reviewshortcuts**: `2c3b3eac` feature/menu-and-window-shortcuts (FR12's branches D and E: menu keys as actions, scopes and the Works in pop-up, config.json's object form, the Shift fallback narrowed, dialog keys left to sheets) and `8e2ac3c3` fix/playback-robustness (the sleep fade without a backend switch, the start watchdog and its cap, the retry's place, refused renders retried, Now Playing, Where Am I's pause kept and Play held back, AsyncBridge's priority). Say exactly what the user's shortcuts and config.json become, and which keys now do something different in which kind of window.

## What to look for, in this order
1. **Correctness**: a concrete input or state that gives a wrong result, a crash, a hang, lost or corrupted user data, a race, a loop, a state flag that can stick, an announcement that repeats or never comes.
2. **Accessibility**: a value VoiceOver cannot reach, wording that reads wrong or twice, a key that fires while typing in a field, focus lost.
3. **Tests**: a test that can trap, play sound, read `~/.TextMouth`, or pass for the wrong reason, and behavior added with no test.
4. **Design and cleanliness**: duplication (DRY is a hard rule), comments that say what the code does not do, dead code, misleading names.
5. **The agents' claims**: which are false or inexact (a documentation agent, `docs9`, is writing from them now).

## How to report
For each finding: a one-line title; the file and line on main; the severity (`bug`, `risk`, `test-gap`, `cleanup`, `doc-mismatch`); the concrete scenario; your confidence (`confirmed` or `plausible`); and the smallest fix. Most severe first. Then what you checked and found sound, briefly.

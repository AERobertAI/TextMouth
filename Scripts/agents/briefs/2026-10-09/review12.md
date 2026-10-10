# Task brief: reviewfeeds2 and reviewreader — read-only review of the October 10 morning merges

Two reviewers share this brief; each takes its own merges. You are read-only: **edit no file, make no commit, run no build or test, post nothing on the board.** Your report goes to the orchestrator. Read `common.md` beside this file for the user's rules; the usage override it describes ended at the 8:00 a.m. reset, so read only "5-hour session" and "Weekly (all models)", ignore "Weekly (Fable)", and stop with what you have below 10% left. `review11.md` beside this file is the format; REV10 and REV11 in TODO-2026-09-04.md list what the earlier reviews found and where each went, so do not report those again unless a merge below reopened one.

## Your merges
Read each merge's diff against its first parent (`git diff <merge>^1 <merge>`), its commits, and the code it relies on; the agents' notes are in `AGENT-NOTES-2026-10-04.md` under "Agent notes, October 9, 2026".
- **reviewfeeds2**: `5686cb2d` feature/feed-item-policy-ui (FR11's branch C: the List and download controls, retired settings, item rows, Unopened's rule, read-only Book Info), `5e3c2018` fix/feed-followups (kept packages that cannot be listed, the swap fallback's recovery, the rules keeping an article's text, the cloud two-launch rule, the feed test world's drain), and `dde4d957` feature/feed-download-progress (FR10's feed half: the downloads section, Speak Download Progress, Cancel, the progress model off the lists). Say what the user sees and hears in the Feeds settings, Feed Info, a feed's folder, and the downloads section at the first launch, when the newest-5 rule downloads about 320 MB.
- **reviewreader**: `9bcecf3c` fix/reading-list-followups (row move actions, the edit-mode bar, retired and replaced books on the list, Rebuild Library Index keeping the list and sorts, imports at the Reading List, Speak Info's place, the request store and its hold) and `f9193138` fix/where-am-i-and-keys (Where Am I? ending with any stop, the pending resume, held Plays and chapters, menu keys claimed in every window their items act in, sheets over sheets, the Record window's hints, the cleanups). The user's rule that speech never switches from the voice to rendered audio while it is heard matters for the Where Am I? changes.

## What to look for, in this order
1. **Correctness**: a concrete input or state that gives a wrong result, a crash, a hang, lost or corrupted user data, a race, a loop, a state flag that can stick, an announcement that repeats or never comes.
2. **Accessibility**: a value VoiceOver cannot reach, wording that reads wrong or twice, focus lost, a duplicate control by the user's rule.
3. **Tests**: a test that can trap, play sound, read `~/.TextMouth`, or pass for the wrong reason, and behavior added with no test.
4. **Design and cleanliness**: duplication (DRY is a hard rule), comments that say what the code does not do, dead code, misleading names.
5. **The agents' claims**: which are false or inexact (the next documentation pass writes from them).

## How to report
For each finding: a one-line title; the file and line on main; the severity (`bug`, `risk`, `test-gap`, `cleanup`, `doc-mismatch`); the concrete scenario; your confidence (`confirmed` or `plausible`); and the smallest fix. Most severe first. Then what you checked and found sound, briefly.

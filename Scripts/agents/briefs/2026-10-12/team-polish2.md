# Team polish2: a second round of polish, from a verified list

Team `polish2`; lead `polish2-lead`; team branch `team/polish2`; workers' branches `polish2/<task>`. Read `teams-common.md` beside this file first.

## What the user asked
On October 12: "I would like some agents to work on the next todos and pollishing".

## What the first round learned
The first polish team (merged October 12; its TODO entry is "The polish team's eight fixes") spent most of its lead's effort checking which open follow-ups were still open: about 30 checked to find 8. The TODO's "Still open after …" lines are not struck when a later merge fixes them.

So this round starts with a verifier: one Sonnet worker whose only task is to check candidates against main's code and write the verified list. You choose from that list.

## Where the work is
In `TODO-2026-09-04.md`, read by line range after finding the lines with `grep -n`:
- **The open follow-ups:** the paragraph beginning `**Open follow-ups noted on October 3 afternoon and evening**`, with its "Still open after …" lines, through the line for the polish-team merge. That line also lists what the first round found already fixed: skip those.
- **The open reviews:** REV10 to REV14 (`- [ ] **REVnn`); REV07 is closed.

## Step 1: the verifier
Brief one worker, slug `polish2-verify`, to read those parts and check each item against main's code. It reads no more of the code than each check needs: one `grep`, or a few lines. It writes `Scripts/agents/briefs/2026-10-12/polish2/candidates.md`, one line per item, in four lists:
- **still open, one right answer:** the item, its files, and a one-line fix;
- **still open, needs the user:** the question, with a recommended answer;
- **already fixed:** the commit or the code that fixed it;
- **too large for one task.**

It commits the file on its branch, and reports the counts of each list. Its task builds nothing.

## Step 2: choose and fix
From the first list, choose 6 to 10 items, with the same preferences as the first round:
- what a listener notices first: what VoiceOver says, keyboard access, a wrong state shown, a control that does nothing, a crash risk;
- then correctness bugs;
- refactors last.

#1857's next slice (`ContentIndexValidationTests`, about 130 subscripts; `BookmarkKeyboardAccessTests`; `LibraryBookUpdatesTests`) is a fine task for a worker. One test file is one task.

Leave alone:
- **The t6d team's files:** `PlaceRelocator`, `TextAnchor*`, `PatienceDiff`, `FineWords`, `SkippedHeading` and the skips in `Book`, `MarkdownCacheService`, `LibraryPersistenceService.saveContentAnalysis`, `MachineLocalPaths`, and the reader's `showLoadedContent`. Check `bbs claims` before you plan and before each launch.
- **The board:** `.claude/skills/agent-bbs/`.
- **The orchestrator's scripts** in `Scripts/agents/`.
- **Manual-only items:** P09, T10, and A01.
- **FR02.**
- **Anything `humanQuestions/2026-10-12.md` asks the user:** the Continue button's "Finished", the Shortcuts Reset alert's wording, Delete Feed…'s in-use refusal, and #2077.

## Your report
Use `teams-common.md`'s report. Also include:
- the verifier's lists, as counts;
- the "already fixed" list, so the orchestrator can strike those items;
- the "needs the user" list, which the orchestrator turns into questions.

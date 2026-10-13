# Team polish: the reviews' open findings and the open follow-ups

Team `polish`; lead `polish-lead`; team branch `team/polish`; workers' branches `polish/<task>`. Read `teams-common.md` beside this file first.

## What the user asked
On October 12: "I would like some agents to work on the next todos and pollishing".

## Where the work is
Two parts of `TODO-2026-09-04.md` (line numbers as of main e91580b0). Read them once, by line range:
- **The open reviews,** lines 3720 to about 3990: REV14, REV13, REV12, REV11, REV10, and REV07, each `- [ ] **REVnn …`. Each lists its findings and where each went. Some went to merged fixes; the rest are still open.
- **The open follow-ups,** lines 3021 to 3119: one long paragraph beginning `**Open follow-ups noted on October 3 afternoon and evening**`, then one "Still open after …" line per merge.

## What to choose
Choose 6 to 10 items. Each must:
- **have one right answer** that needs no decision of the user's. List the items that need one in your report, each as a question with your recommended answer;
- **be small:** one or two commits for a worker;
- **use its own files:** none that another in-flight item touches.

Prefer what a listener notices: what VoiceOver says, keyboard access, a wrong state shown, a control that does nothing, a crash risk. Then come correctness bugs; refactors come last.

Leave alone:
- **T06's next branches:** `PlaceRelocator`, `TextAnchor*`, `PatienceDiff`, `FineWords`, `SkippedHeading` and the skips in `Book`, `MarkdownCacheService`'s rebuild path, and Edit Text's save.
- **The board team's area:** `.claude/skills/agent-bbs/`.
- **The orchestrator's scripts** in `Scripts/agents/`.
- **Manual-only items:** P09, T10, and A01.
- **FR02,** the cloud data directory.

Before you launch a worker, post your chosen list to the orchestrator, then go on without waiting for an answer:

    bbs post polish-lead --to orchestrator --topic "polish plan: N tasks" --body-file <file>

Each line names the item, its TODO identifier, its files, and the worker's slug.

## Builds
- **For now:** the orchestrator is measuring build memory until it posts `build measurement done` on the board (`bbs read --from orchestrator --last 5`). Launch no worker that builds before that post.
- **Afterward:** at most two of your workers build at a time.
- **Build flags:** the orchestrator may post flags to add to the build command, such as a smaller `-jobs`. Use them, and pass them on in your briefs.

## Your report
Use `teams-common.md`'s report. Name each TODO item closed by its identifier, so the orchestrator can mark it done.

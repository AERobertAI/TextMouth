# Team polish3: a third round of polish, from the verified lists

Team `polish3`; lead `polish3-lead`; team branch `team/polish3`; workers' branches `polish3/<task>`. Read `teams-common.md` beside this file first.

## What the user asked
On October 12: "I would like some agents to work on the next todos and pollishing".

## Where the work is
The second polish team's verifiers checked every open follow-up and review finding against main's code. They wrote two lists, each entry with its evidence:
- `Scripts/agents/briefs/2026-10-12/polish2/candidates.md`;
- `Scripts/agents/briefs/2026-10-12/polish2/candidates-2.md`.

Their "still open, one right answer" sections are your candidates. Leave out those the second team took; its TODO entry ("The second polish team's eight fixes") and its "Still open after the second polish team's merge" line say which were taken and which were not. That line also lists the verified items it did not take, with their files. It names #1857's next slices too (about 35 test files with bare subscripts), each a fine task: one test file is one task.

The lists are a few hours old. Have each worker confirm its item is still open before changing anything; a one-line `grep` will do.

## What to choose
Choose 6 to 10 tasks, with these preferences:
1. what a listener notices: what VoiceOver says, keyboard access, a wrong state shown, a crash risk;
2. then correctness;
3. then DRY and dead code;
4. #1857's slices fill the rest.

Leave alone:
- **The t6d team's files:** `PlaceRelocator`, `TextAnchor*`, `PatienceDiff`, `FineWords`, `SkippedHeading` and the skips in `Book`, `MarkdownCacheService`, `LibraryPersistenceService`, `MachineLocalPaths`, and the reader's load path in `ReaderViewModel.swift`. That includes the Where Am I? end-sound flag, which needs `ReaderViewModel.swift`. Check `bbs claims` before you plan and before each launch.
- **The board:** `.claude/skills/agent-bbs/`, which the board2 team works on.
- **The orchestrator's scripts** in `Scripts/agents/`.
- **Manual-only items** and FR02.
- **Anything waiting on the user** in `humanQuestions/2026-10-12.md` or `humanQuestions/2026-10-10-evening.md`.

## Your report
Use `teams-common.md`'s report, naming each TODO item closed by its identifier, or by its file and a few words when it has none.

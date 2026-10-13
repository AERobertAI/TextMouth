# Team polish4: test files that can still trap, and three small moves

Team `polish4`; lead `polish4-lead`; team branch `team/polish4`; workers' branches `polish4/<task>`. Read `teams-common.md` beside this file first.

## What the user asked
On October 12: "I would like some agents to work on the next todos and pollishing". The user also sees a macOS crash dialog for every test host that aborts, so a test that can trap costs them every time it breaks.

## The tasks
1. **#1857, five test files.** Each file is one task, in this order:
   - `LiveReadingPositionsTests` (21 bare subscripts);
   - `LibraryCloudRefreshTests` (21);
   - `LibraryCloudCommandTests` (20);
   - `EPUBHeadingRecoveryTests` (18);
   - `KeepOnThisMacTests` (17).

   The counts come from the third polish team's grep and are not yet judged. For each file, the worker:
   - proves each bare subscript safe, or guards it with the shared `subscript(safe:)` (`TextMouthProductionTests/CollectionTestSupport.swift`) and `XCTUnwrap`;
   - changes no assertion's meaning;
   - runs that class alone.

   The first, second, and third polish teams did this for other files: their commits under `polish/subscripts`, `polish2/cindex`, and `polish2/subscripts2` in the TODO's entries show how.
2. **Three homes.** The second polish team's verifier found three types or helpers living in the wrong file:
   - `FeedReadOnlyText` and `SilentKeyEquivalent`, in `FeedInfoSheet.swift` (about lines 432 and 483);
   - `showLogs`, in `LogsSettingsSection.swift` (about line 137).

   The entries in `Scripts/agents/briefs/2026-10-12/polish2/candidates.md` and `candidates-2.md` say where each belongs. One worker moves all three, with no change of behavior, in one commit per move.

## A cost experiment: reviewers
Every team's lead has been 75 to 87% of its team's cost, mostly from reading every diff in a growing context. For the five test-only tasks, try this instead:
- When a worker reports, launch a fresh reviewer with the Agent tool (`model: "sonnet"`, `effort: "high"`, `subagent_type: "general-purpose"`, no worktree). It reads that one diff (`git diff team/polish4...<branch>`) against the worker's brief and these rules: each subscript proven or guarded, no assertion's meaning changed, no new warning, comments kept.
- The reviewer replies in at most ten lines with "accept" or "fix", and the fixes.
- Read only its verdict. Read the diff yourself only when it says "fix" or you doubt it.

Review the three moves (task 2) yourself, as before. Say in your report what the reviewers cost, from their agent ids, and whether they caught anything.

## Leave alone
- **The t6e team's files:** `ReaderViewModel*.swift`, `PlaceRelocator`, `PlaceSnapshots`, `TextAnchor*`, `Book.swift`'s places, `MarkdownCacheService`, `LibraryPersistenceService`, the Edit Text session files, and their tests. Check `bbs claims` before you plan and before each launch.
- **The board** and `Scripts/agents/`.

## Your report
Use `teams-common.md`'s report, with each reviewer's agent id beside its worker's.

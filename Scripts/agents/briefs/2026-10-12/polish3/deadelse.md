# polish3-deadelse: the legacy scenario files lose their `canImport(TextMouth)` conditionals

- Team `polish3`; lead `polish3-lead`; your task is number 25 on the team's list.
- Your slug is `polish3-deadelse`. Your branch is `polish3/deadelse`, made with `git checkout -b polish3/deadelse team/polish3`. Your worktree may start on an old commit, so branch from `team/polish3` exactly so.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- `bbs` is `python3 .claude/skills/agent-bbs/scripts/bbs.py`, run from your worktree root. Write it out in full: the worktree guard refuses a command kept in a variable. Register, joining the team, then mark your task started:

      python3 .claude/skills/agent-bbs/scripts/bbs.py register polish3-deadelse --role "Legacy scenario files lose dead canImport branches" --branch polish3/deadelse --team polish3 --files "TextMouthTests/Sources/Tests/*.swift"
      python3 .claude/skills/agent-bbs/scripts/bbs.py task move polish3-deadelse 25 working

- This brief gives you what you need. Read only the line ranges it names, once each.
- It closes the TODO's "dead `#else` branches in six legacy test files".

## The problem
The files in `TextMouthTests/Sources/Tests/` build only into `TextMouthProductionTests` (`project.yml` lines 150 to 172), which links TextMouth, so `canImport(TextMouth)` is always true there. Twelve of them still test it:
- `#if canImport(TextMouth)` with an `#else` branch that never compiles: `BugRegressionTests` (8 `#else`), `DOCXEdgeCaseTests` (3), `IntegrationTests` (3), `BookmarkToggleTests` (2), and `MenuVisibilityTests` (1);
- `#if canImport(TextMouth)` around code with no `#else`, which is always kept: those five, and `DAISYEdgeCaseTests`, `DAISYAudioTests`, `EPUBParserTests`, `DOCXParserTests`, `DAISYParserTests`, and `ParserEdgeCaseTests`;
- `#if !canImport(TextMouth)`, the other way round, in `TextSubstitutionTests.swift`: its lines 3 to 139 never compile, and its `#else` branch (lines 139 to 163) is the live code.

Confirm it is still open first: `grep -rln "canImport(TextMouth)" TextMouthTests/Sources/Tests` lists the twelve files.

## What to build
1. Write a small Python script in the scratchpad (named `polish3-deadelse-strip.py`) that, for each file, keeps the branch that compiles and drops the other, with the `#if`, `#else`, and `#endif` lines of those conditionals:
   - for `#if canImport(TextMouth)`: keep the `#if` branch, drop the `#else` branch;
   - for `#if !canImport(TextMouth)`: drop the `#if` branch, keep the `#else` branch;
   - any other `#if` (nested or not) stays exactly as it is: keep a stack, so an `#else` or `#endif` belongs to the `#if` it closes;
   - stop with an error on an `#elseif` inside one of these conditionals, rather than guess.
2. Run it, then read the diff of each file once (`git diff --stat`, then `git diff <file>`). Kept code keeps its indentation. Where a dropped block leaves two blank lines together, leave one.
3. Change nothing else: no reformatting, no renaming, and no scenario added or removed.

**Completion check:** `grep -rn "canImport(TextMouth)" TextMouthTests/Sources/Tests` finds nothing.

## Tests
Each file registers its scenarios with a runner, and a class in `TextMouthProductionTests/LegacyScenarioHarness.swift` counts what registers (lines 104 to 340): the same counts passing after the change prove no live code went. Run the twelve classes: `LegacyBugRegressionScenarioTests`, `LegacyDOCXEdgeCaseScenarioTests`, `LegacyIntegrationScenarioTests`, `LegacyBookmarkToggleScenarioTests`, `LegacyMenuVisibilityScenarioTests`, `LegacyTextSubstitutionScenarioTests`, `LegacyDAISYEdgeCaseScenarioTests`, `LegacyDAISYAudioScenarioTests`, `LegacyEPUBParserScenarioTests`, `LegacyDOCXParserScenarioTests`, `LegacyDAISYParserScenarioTests`, and `LegacyParserEdgeCaseScenarioTests`.

## Commits
Two commits: `TextSubstitutionTests.swift` alone (its dead branch is a whole old copy of the file), then the other eleven. Each message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Build and test
- Run the twelve classes above, and nothing else.
- Start each build in the background, and check on it no more often than every 4 minutes, with one short command.
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish3-deadelse-…`.

      BBS_AGENT=polish3-deadelse .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-polish3-deadelse -only-testing:TextMouthProductionTests/LegacyBugRegressionScenarioTests -only-testing:TextMouthProductionTests/LegacyDOCXEdgeCaseScenarioTests -only-testing:TextMouthProductionTests/LegacyIntegrationScenarioTests -only-testing:TextMouthProductionTests/LegacyBookmarkToggleScenarioTests -only-testing:TextMouthProductionTests/LegacyMenuVisibilityScenarioTests -only-testing:TextMouthProductionTests/LegacyTextSubstitutionScenarioTests -only-testing:TextMouthProductionTests/LegacyDAISYEdgeCaseScenarioTests -only-testing:TextMouthProductionTests/LegacyDAISYAudioScenarioTests -only-testing:TextMouthProductionTests/LegacyEPUBParserScenarioTests -only-testing:TextMouthProductionTests/LegacyDOCXParserScenarioTests -only-testing:TextMouthProductionTests/LegacyDAISYParserScenarioTests -only-testing:TextMouthProductionTests/LegacyParserEdgeCaseScenarioTests > /private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/polish3-deadelse-build-1.log 2>&1

- Read a result with `grep -E "Executed [0-9]+ tests|error:|failed \(" <log> | tail -20`.

## Do not touch
- `LegacyScenarioHarness.swift`, `project.yml`, app code, and every file not named above; add no new file, so `TextMouth.xcodeproj/project.pbxproj` stays as it is.
- Any `*.md` file.

## Finish
As "The worker's part" says: post `done: polish3/deadelse` to `polish3-lead`, move task 25 to `review`, remove your build folder (unregistering its app first), release your claims, and reply with your report of at most 15 lines.

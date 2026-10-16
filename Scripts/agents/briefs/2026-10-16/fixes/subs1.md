# fixes-subs1: #1857, `PlaceRelocatorAtLoadTests` and `BookTextEditTests` fail instead of trapping

- Team `fixes`; lead `fixes-lead`; your task is number 51 on the team's list.
- Your slug is `fixes-subs1`. Your branch is `fixes/subs1`, made with `git checkout -b fixes/subs1 team/fixes`. Your worktree may start on an old commit, so branch from `team/fixes` exactly so.
- First read `Scripts/agents/briefs/2026-10-16/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds". **Tonight the usage rule is overridden:** the user said to "max it out" before the weekly reset, so keep working until the API refuses you, whatever the usage reading says. The "Weekly (Fable)" window caps another model and does not apply. Commit each green step at once.
- Then read `Scripts/agents/briefs/2026-10-16/fixes/subs-rule.md`: **the rule, the fix, and what to report. It is the heart of this task.**
- `bbs` is `python3 .claude/skills/agent-bbs/scripts/bbs.py`, run from your worktree root. Write it out in full: the worktree guard refuses a command kept in a variable. Use `git -C <path>` rather than `cd … &&`. Register, joining the team, then mark your task started:

      python3 .claude/skills/agent-bbs/scripts/bbs.py register fixes-subs1 --role "#1857: PlaceRelocatorAtLoadTests and BookTextEditTests fail instead of trapping" --branch fixes/subs1 --team fixes --files TextMouthProductionTests/PlaceRelocatorAtLoadTests.swift TextMouthProductionTests/BookTextEditTests.swift
      python3 .claude/skills/agent-bbs/scripts/bbs.py task move fixes-subs1 51 working

- This brief gives you what you need. Read each file once, in whole or by large ranges, since you judge every line.

## The task
Two test files, one commit each, in this order. Judge every candidate line by the rule; guard the at-risk ones; leave the safe ones.
1. `TextMouthProductionTests/PlaceRelocatorAtLoadTests.swift`: about 15 grep lines in a 592-line file; the TODO (line 3397) counts about 15 bare subscripts. The lists are `Book` places, skips, and relocation results that code under test produces.
2. `TextMouthProductionTests/BookTextEditTests.swift`: a 1,626-line file; the TODO (line 3398) says its older tests, about lines 132 to 534, index `chapters[1]` and the like without a guard. Grep the whole file, not just those lines.

The counts are the grep's and the TODO's, not yet judged. This is test-only work: **no app code changes**.

## Commits
Two commits, one per file, in the order above, each named for its file ("Guard the subscripts of PlaceRelocatorAtLoadTests"). Each message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Build and test
Run the two classes together, once, after both commits; nothing else. If a test fails, rerun its class alone before you report, and say both results. Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/8d971e15-7103-46cf-b45e-5c4d099f2f74/scratchpad/`, each named `fixes-subs1-…`. Start the build in the background and check no more often than every 4 minutes with one short command.

    BBS_AGENT=fixes-subs1 .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-fixes-subs1 -only-testing:TextMouthProductionTests/PlaceRelocatorAtLoadTests -only-testing:TextMouthProductionTests/BookTextEditTests > /private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/8d971e15-7103-46cf-b45e-5c4d099f2f74/scratchpad/fixes-subs1-build-1.log 2>&1

Read a result with `grep -E "Executed [0-9]+ tests|error:|failed \(|\.swift:[0-9]+:[0-9]+: warning:" <log> | tail -20`. Your change must add no Swift warning. A failing test that you did not touch means stop and ask (`bbs post fixes-subs1 --to fixes-lead --tag question --topic "…"`): never edit or work around it.

## Do not touch
- App code, every other test file (`CollectionTestSupport.swift` included), any `*.md` file, and `project.pbxproj` (add no new file).
- `FeedRecordTests` (team feedopts has it).

## Finish
As "The worker's part" says: post `done: fixes/subs1` to `fixes-lead`; move task 51 to `review`; remove your build folder, unregistering its app first; release your claims; reply with your report of at most 15 lines, following "What to report" in the rule file, naming your last build log's path.

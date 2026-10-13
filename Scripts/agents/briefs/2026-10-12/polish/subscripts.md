# polish-subscripts: #1857, a first slice, so that no test traps on a short list

- Team polish; lead `polish-lead`. Your slug is `polish-subscripts`, and your branch is `polish/subscripts`, made with `git checkout -b polish/subscripts team/polish`.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- This brief gives you what you need. Read only the line ranges it names, once each.
- It closes a first slice of #1857, from "Still open after the where-am-i-followups merge". The rest stays open.

## What is wrong
Take a numeric subscript on a list that the test did not first prove long enough, such as `results[2].title` after `XCTAssertEqual(results.count, 3)`. The assertion does not stop the test, so when the code under test breaks, the subscript traps. The test host then crashes, and the user sees a crash dialog instead of a failed test.

About 600 such subscripts remain, across about 40 test files (#1857). This task takes three of those files, all in `TextMouthProductionTests/`:
- `TranscriptModelTests.swift`;
- `FeedNewestRuleTests.swift`;
- `FeedParserTests.swift`.

## Do
1. **Share the helper.** Move the private `subscript(safe:)` extension on `Array` out of `TextMouthProductionTests/RecordingWindowTests.swift` (about lines 655 to 660), with its comment. Put it, made internal, in a new shared file, `TextMouthProductionTests/CollectionTestSupport.swift`. `RecordingWindowTests` goes on using it. A new file needs `/opt/homebrew/bin/xcodegen generate`, with the regenerated `project.pbxproj` in the same commit.
2. **Guard the three files.** Wherever a numeric subscript is on a collection not proven long enough, make it fail instead of trap:
   - inside an assertion, compare `list[safe: 2]?.title` with the expected value;
   - for a value used further on, write `let item = try XCTUnwrap(list[safe: 2])`, and make the test function `throws` if it is not already.
3. **Leave the safe ones alone.** These are safe:
   - a subscript after a guard that returns;
   - a subscript on a fixed-size literal that the test made itself.
4. **Change nothing the tests assert.**
5. **Commits.** Commit the move first. Then commit the three files, in one commit or one per file.
6. **Report** how many subscripts you changed in each file.

## Build and test
- Run only `TranscriptModelTests`, `FeedNewestRuleTests`, `FeedParserTests`, and `RecordingWindowTests`.
- Start each build in the background and check on it no more often than every 4 minutes.
- `-jobs 4` is required (the orchestrator's #2107).
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish-subscripts-…`.

    BBS_AGENT=polish-subscripts .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath "${TMPDIR}TextMouth-DerivedData-polish-subscripts" -only-testing:TextMouthProductionTests/TranscriptModelTests -only-testing:TextMouthProductionTests/FeedNewestRuleTests -only-testing:TextMouthProductionTests/FeedParserTests -only-testing:TextMouthProductionTests/RecordingWindowTests > <scratchpad>/polish-subscripts-build-1.log 2>&1

## Do not touch
- App code.
- Any other test file.
- Any `*.md` file.

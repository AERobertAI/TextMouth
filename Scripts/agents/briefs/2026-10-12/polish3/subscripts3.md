# polish3-subscripts3: #1857, `FeedNewestRuleTests` fails instead of trapping

- Team `polish3`; lead `polish3-lead`; your task is number 26 on the team's list.
- Your slug is `polish3-subscripts3`. Your branch is `polish3/subscripts3`, made with `git checkout -b polish3/subscripts3 team/polish3`. Your worktree may start on an old commit, so branch from `team/polish3` exactly so.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- `bbs` is `python3 .claude/skills/agent-bbs/scripts/bbs.py`, run from your worktree root. Write it out in full: the worktree guard refuses a command kept in a variable. Register, joining the team, then mark your task started:

      python3 .claude/skills/agent-bbs/scripts/bbs.py register polish3-subscripts3 --role "#1857: FeedNewestRuleTests fails instead of trapping" --branch polish3/subscripts3 --team polish3 --files TextMouthProductionTests/FeedNewestRuleTests.swift
      python3 .claude/skills/agent-bbs/scripts/bbs.py task move polish3-subscripts3 26 working

- This brief gives you what you need. Read only the line ranges it names, once each.
- It is #1857's next slice: one test file.

## The rule
A numeric subscript on a list the test has not proven long enough traps when the list is short, and the trap crashes the test host: the user sees a crash dialog instead of a failed test. An assertion does not stop a test, so it proves nothing.
- **At risk:** a list that code under test made or changed, such as a feed record's `items`, a store's records, the library's `books`, or a report's IDs.
- **Safe; leave it alone:**
  - a list the test wrote itself, as a literal, or with a helper of its own that builds a fixed number of values;
  - a subscript after a guard that stops the test (`try XCTUnwrap(list[safe: n])`, or a `guard … else { XCTFail(…); return }`);
  - text inside a string literal.
- **The fix:** for a value read, `try XCTUnwrap(list[safe: n])`; inside an assertion, compare through `[safe:]`; before a write by position, one guard line, `_ = try XCTUnwrap(list[safe: n], "…")`, after which the test's subscripts stay as they are. Make a test `throws` when it needs `try`.
- `subscript(safe:)` is the shared, read-only helper in `TextMouthProductionTests/CollectionTestSupport.swift`. Use it; do not change it.
- Change nothing a test asserts: no expected value, no message, and no test removed or renamed.

## The file
`TextMouthProductionTests/FeedNewestRuleTests.swift`. `grep -n -E '[A-Za-z)?]\[[0-9]+\]' TextMouthProductionTests/FeedNewestRuleTests.swift` finds 32 numeric subscripts on `team/polish3`. Take them in order: for each, read only the few lines around it, and further up only where the list's source is not plain. Guard each test once, before its first subscript at risk, where one guard covers the rest.

Confirm it is still open first: that `grep` still finds subscripts without a guard before them.

## Commits
One commit. Its message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. Report how many subscripts you guarded, and how many you judged safe and why, in a line or two.

## Build and test
- Run `FeedNewestRuleTests`, and nothing else.
- Start each build in the background, and check on it no more often than every 4 minutes, with one short command.
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish3-subscripts3-…`.

      BBS_AGENT=polish3-subscripts3 .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-polish3-subscripts3 -only-testing:TextMouthProductionTests/FeedNewestRuleTests > /private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/polish3-subscripts3-build-1.log 2>&1

- Read a result with `grep -E "Executed [0-9]+ tests|error:|failed \(" <log> | tail -20`.

## Do not touch
- App code, and every other test file (`CollectionTestSupport.swift` and `FeedTestSupport.swift` included); add no new file, so `TextMouth.xcodeproj/project.pbxproj` stays as it is.
- Any `*.md` file.

## Finish
As "The worker's part" says: post `done: polish3/subscripts3` to `polish3-lead`, move task 26 to `review`, remove your build folder (unregistering its app first), release your claims, and reply with your report of at most 15 lines.

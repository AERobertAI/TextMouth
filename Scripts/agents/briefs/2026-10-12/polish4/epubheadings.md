# polish4-epubheadings: #1857, `EPUBHeadingRecoveryTests` fails instead of trapping

- Team `polish4`; lead `polish4-lead`; your task is number 37 on the team's list.
- Your slug is `polish4-epubheadings`. Your branch is `polish4/epubheadings`, made with `git checkout -b polish4/epubheadings team/polish4`. Your worktree may start on an old commit, so branch from `team/polish4` exactly so.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- `bbs` is `python3 .claude/skills/agent-bbs/scripts/bbs.py`, run from your worktree root. Write it out in full: the worktree guard refuses a command kept in a variable. Register, joining the team, then mark your task started:

      python3 .claude/skills/agent-bbs/scripts/bbs.py register polish4-epubheadings --role "#1857: EPUBHeadingRecoveryTests fails instead of trapping" --branch polish4/epubheadings --team polish4 --files TextMouthProductionTests/EPUBHeadingRecoveryTests.swift
      python3 .claude/skills/agent-bbs/scripts/bbs.py task move polish4-epubheadings 37 working

- This brief gives you what you need. Read only the line ranges it names, once each.
- It is #1857's next slice: one test file, one commit.

## The rule
A numeric subscript on a list the test has not proven long enough traps when the list is short, and the trap crashes the test host: the user sees a crash dialog instead of a failed test. An assertion does not stop a test, so it proves nothing: `XCTAssertEqual(content.chapters.count, 122)` fails and the test goes on to the subscript.
- **At risk:** a list that code under test made, such as the chapters a parser or the cache returns.
- **Safe:** a subscript after a guard that stops the test: `try XCTUnwrap(list[safe: n])`, or a `guard … else { XCTFail(…); return }`.
- **The fix:**
  - **Several subscripts in one test:** one guard line before the first of them, `_ = try XCTUnwrap(list[safe: k], "…")`, where `k` is the highest index the test reads from that list. The test's subscripts then stay as they are. This holds here because every list below is a constant (`let content`, `let current`, a `for content in …` constant), so nothing can shorten it after the guard.
  - **A single subscript inside an `XCTAssertEqual`:** compare through `[safe:]` instead, as in `XCTAssertEqual(content.chapters[safe: 0]?.text, "")`.
  - **A single subscript inside an `XCTAssertTrue`:** a guard line before it, as for several.
- `subscript(safe:)` is the shared, read-only helper in `TextMouthProductionTests/CollectionTestSupport.swift`, on `Array`; `DocumentContent.chapters` is `[Chapter]`. Use it; do not change it.
- Change nothing a test asserts: no expected value, no message, and no test removed or renamed. Every test below already `throws`.
- A guard's message names the chapter the test needs by its number from 1, as the test's words do: index 110 is "chapter 111". For example, `"the book has no chapter 111"`.

## What the lead found
`grep -n -E '[A-Za-z)?]\[[0-9]+\]' TextMouthProductionTests/EPUBHeadingRecoveryTests.swift` finds 18 lines on `team/polish4`, all at risk, in six tests. Confirm it first, then take the tests in order:

1. `testSparseNavigationRecoversAll122ChaptersWithoutChangingSpeech` (lines 11-26). Lines 20-23 read `content.chapters[30]` and `[110]` inside `for content in [cached, direct]` (lines 16-24). One guard inside the loop, before line 20, at index 110.
2. `testUnlistedChaptersUseDistinctDocumentTitlesThenNumberedFallbacks` (lines 99-110). Lines 107-109 read indices 0 and 1. One guard before line 107, at index 1.
3. `testPartialAndBrokenNavigationStillProvideChapterStarts` (lines 154-172). Lines 169-171 read indices 0 and 1. One guard before line 169, at index 1.
4. `testImageOnlyChapterRetainsNavigationWithZeroTextDuration` (lines 193-201 and on). Line 200, a single subscript in an `XCTAssertEqual`: compare through `[safe:]`.
5. `testPageListsLandmarksAndGuideDuplicatesNeverBecomeHeadings` (lines 564-600). Lines 585-597 read indices 0 to 3 inside `for content in [cached, direct]` (from line 573): three assertions, the value read at line 589, the `XCTUnwrap(…range(of:))` at line 594, and the assertion at lines 595-598. One guard inside the loop, before line 585, at index 3.
6. `testCopiedHelliconiaRetainsTextAndRecoversEveryChapter` (lines 803-870). Line 869, `XCTAssertTrue(current.chapters[17].title.contains(…))`. One guard just before line 869, at index 17. This test throws `XCTSkip` without the copied Helliconia package (line 806), so your run will skip it: it must still compile, and your report says it was not exercised.

When you finish, every line the `grep` finds must sit below a guard in its own test at an index at least as high, except line 200's, which reads through `[safe:]`.

## Commits
One commit. Its message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. In your report, say how many guard lines you added and how many subscripts each covers.

## Build and test
- Run `EPUBHeadingRecoveryTests`, and nothing else.
- Start each build in the background, and check on it no more often than every 4 minutes, with one short command.
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish4-epubheadings-…`. Your reviewer reads your last build log, so keep it there.

      BBS_AGENT=polish4-epubheadings .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-polish4-epubheadings -only-testing:TextMouthProductionTests/EPUBHeadingRecoveryTests > /private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/polish4-epubheadings-build-1.log 2>&1

- Read a result with `grep -E "Executed [0-9]+ tests|error:|failed \(|\.swift:[0-9]+:[0-9]+: warning:" <log> | tail -20`. Your change must add no Swift warning.

## Do not touch
- App code (`MarkdownCacheService` and the parsers belong to another team), and every other test file (`CollectionTestSupport.swift` included). Add no new file, so `TextMouth.xcodeproj/project.pbxproj` stays as it is.
- Any `*.md` file.

## Finish
As "The worker's part" says:
- post `done: polish4/epubheadings` to `polish4-lead`;
- move task 37 to `review`;
- remove your build folder, unregistering its app first;
- release your claims;
- reply with your report of at most 15 lines, naming your last build log's path.

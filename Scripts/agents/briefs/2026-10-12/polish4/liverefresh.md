# polish4-liverefresh: #1857, `LiveReadingPositionsTests` and `LibraryCloudRefreshTests` fail instead of trapping

- Team `polish4`; lead `polish4-lead`; your task is number 36 on the team's list.
- Your slug is `polish4-liverefresh`. Your branch is `polish4/liverefresh`, made with `git checkout -b polish4/liverefresh team/polish4`. Your worktree may start on an old commit, so branch from `team/polish4` exactly so.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- `bbs` is `python3 .claude/skills/agent-bbs/scripts/bbs.py`, run from your worktree root. Write it out in full: the worktree guard refuses a command kept in a variable. Register, joining the team, then mark your task started:

      python3 .claude/skills/agent-bbs/scripts/bbs.py register polish4-liverefresh --role "#1857: LiveReadingPositionsTests and LibraryCloudRefreshTests fail instead of trapping" --branch polish4/liverefresh --team polish4 --files TextMouthProductionTests/LiveReadingPositionsTests.swift TextMouthProductionTests/LibraryCloudRefreshTests.swift
      python3 .claude/skills/agent-bbs/scripts/bbs.py task move polish4-liverefresh 36 working

- This brief gives you what you need. Read only the line ranges it names, once each.
- It is #1857's next slice: two test files, one commit each.

## The rule
A numeric subscript on a list the test has not proven long enough traps when the list is short, and the trap crashes the test host: the user sees a crash dialog instead of a failed test. An assertion does not stop a test, so it proves nothing.
- **At risk:** a list that code under test made or changed, such as the library model's `library.books`.
- **Safe; leave it alone:**
  - a list the test wrote itself, as a literal, or with a helper of its own that builds a fixed number of values;
  - a subscript after a guard that stops the test (`try XCTUnwrap(list[safe: n])`, or a `guard … else { XCTFail(…); return }`);
  - text inside a string literal.
- **The fix:**
  - for a value read, `try XCTUnwrap(list[safe: n])`;
  - before a write by position, one guard line, `_ = try XCTUnwrap(list[safe: n], "…")`, after which the test's subscripts stay as they are, so long as nothing between the guard and them can shorten the list.
  - Make a test `throws` (or `async throws`) when it needs `try`, and change nothing else in its signature.
- `subscript(safe:)` is the shared, read-only helper in `TextMouthProductionTests/CollectionTestSupport.swift`, on `Array`; `Library.books` is `[Book]`. Use it; do not change it.
- Change nothing a test asserts: no expected value, no message, and no test removed or renamed. Keep every read at the moment it happens now: a read inside a loop stays inside the loop.
- A guard's message says what is missing, in plain words, such as "the library has no first book".

## What the lead found
The lead judged every line `grep -n -E '[A-Za-z)?]\[[0-9]+\]' <file>` finds in both files on `team/polish4` (21 lines in each). Confirm each judgment as you reach it; if one is wrong, guard it and say so in your report.

### Commit 1: `TextMouthProductionTests/LiveReadingPositionsTests.swift`
- **Safe, 16 lines:** every `books[0]` and `books[1]` (lines 21, 23, 55, 56, 63, 87, 101, 145, 162-166, 171, 175, 177). `books` comes from `makeModel()` (lines 218-227), which returns the fixed pair `[first, second]` it built itself.
- **At risk, 5 lines:** `model.library.books[0]`, the library model's own list.
  - Line 102, inside the `for minute in 1...3` loop of `testARowsTimeLeftFollowsALivePositionWithNoTick` (lines 85-112, not yet `throws`). The loop reads the library's first book afresh on each pass. Keep it so: in the loop, just before line 102, `let libraryBook = try XCTUnwrap(model.library.books[safe: 0], "…")`, and pass `libraryBook` to `BookRow(book:…)`.
  - Lines 149, 150, 153 and 154 in `testALivePositionNeverHidesANewerOrEqualLibraryPosition` (lines 143-155, not yet `throws`): two writes by position and two reads. One guard line before line 149 covers all four; nothing in the test removes a book.

### Commit 2: `TextMouthProductionTests/LibraryCloudRefreshTests.swift`
- **Safe, 18 lines:**
  - `books[0]` and `books[1]` at lines 97, 103, 104, 121, 122, 132, 138, 139, 244, 260, 278, 330 and 353: each test wrote `books` itself as a literal of two or three books (lines 96, 114, 129, 240, 322).
  - `sleeps[0]`, `[1]`, `[2]` at lines 297, 303, 310: `sleeps` is `(1...3).map { … }` (line 290). `sleeps[0]`, `[1]`, `[31]` at lines 340 and 358: `sleeps` is `(1...32).map { … }` (line 331).
  - Out of the grep and also safe: `sleeps[count - 1]` at lines 292 and 333. `SteppedSleep` (`LibraryCloudTestSupport.swift`:188) reports `waits.count` after an append, so `count` is at least 1, and `count <= sleeps.count` bounds it above. Leave both alone.
- **At risk, 3 lines:** `fixture.model.library.books[0]`, each a write by position.
  - Line 160 in `testEveryChangeToWhereBooksAreRefreshes` (lines 146-167, `async`, not yet `throws`): one guard line just before line 160.
  - Lines 178 and 179 in `testChangesThatMoveNoPackageDoNotRefresh` (lines 172-185, `async`, not yet `throws`): one guard line just before line 178.

When you finish, `grep -n -E '[A-Za-z)?]\[[0-9]+\]'` over each file must find only the safe lines above, the guarded ones below their guards, and nothing new.

## Commits
Two commits, one per file, in the order above. Each message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. In your report, say per file how many lines you guarded and how many you left as safe.

## Build and test
- Run `LiveReadingPositionsTests` and `LibraryCloudRefreshTests` together, once, after both commits; nothing else. If a test fails, rerun its class alone before you report.
- Start each build in the background, and check on it no more often than every 4 minutes, with one short command.
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish4-liverefresh-…`. Your reviewer reads your last build log, so keep it there.

      BBS_AGENT=polish4-liverefresh .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-polish4-liverefresh -only-testing:TextMouthProductionTests/LiveReadingPositionsTests -only-testing:TextMouthProductionTests/LibraryCloudRefreshTests > /private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/polish4-liverefresh-build-1.log 2>&1

- Read a result with `grep -E "Executed [0-9]+ tests|error:|failed \(|\.swift:[0-9]+:[0-9]+: warning:" <log> | tail -20`. Your change must add no Swift warning.

## Do not touch
- App code, and every other test file (`CollectionTestSupport.swift` and `LibraryCloudTestSupport.swift` included). Add no new file, so `TextMouth.xcodeproj/project.pbxproj` stays as it is.
- `LibraryCloudCommandTests` and `KeepOnThisMacTests`: the lead judged them safe (task 39).
- Any `*.md` file.

## Finish
As "The worker's part" says:
- post `done: polish4/liverefresh` to `polish4-lead`;
- move task 36 to `review`;
- remove your build folder, unregistering its app first;
- release your claims;
- reply with your report of at most 15 lines, naming your last build log's path.

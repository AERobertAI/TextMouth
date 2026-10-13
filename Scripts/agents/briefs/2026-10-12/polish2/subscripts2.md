# polish2-subscripts2: #1857, three more test files fail instead of trapping

- Team `polish2`; lead `polish2-lead`; your task is number 16 on the team's list.
- Your slug is `polish2-subscripts2`. Your branch is `polish2/subscripts2`, made with `git checkout -b polish2/subscripts2 team/polish2`. Your worktree may start on an old commit, so branch from `team/polish2` exactly so.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- Register, joining the team, then mark your task started:

      bbs register polish2-subscripts2 --role "#1857: three test files fail instead of trapping" --branch polish2/subscripts2 --files TextMouthProductionTests/LibraryBookUpdatesTests.swift TextMouthProductionTests/BookmarkKeyboardAccessTests.swift TextMouthProductionTests/TranscriptModelTests.swift --team polish2
      bbs task move polish2-subscripts2 16 working

- This brief gives you what you need. Read only the line ranges it names, once each.
- It closes the rest of #1857's named slice, "next, `ContentIndexValidationTests` …, `BookmarkKeyboardAccessTests`, and `LibraryBookUpdatesTests`", and "`TranscriptModelTests` still writes into its fixture by index, safe while `TranscriptFixtures.twoFiles` has two files" (TODO line 3152). `ContentIndexValidationTests` is done already, on `team/polish2`.

## The rule
A numeric subscript on a list the test has not proven long enough traps when the list is short, and the trap crashes the test host: the user sees a crash dialog instead of a failed test. An assertion does not stop a test, so it proves nothing.
- **At risk:** a list that code under test made or changed, such as a view model's `library.books`, or a reader's `bookmarks`.
- **Safe; leave it alone:**
  - a list the test wrote itself, as a literal or with a helper of its own that builds a fixed number of values, such as `makeBookmarks(count: 3)`;
  - a subscript after a guard that stops the test (`try XCTUnwrap(list[safe: n])`, or a `guard … else { XCTFail(…); return }`);
  - text inside a string literal.
- **The fix:** for a value read, `try XCTUnwrap(list[safe: n])`; inside an assertion, compare through `[safe:]`; before a write by position, such as `model.library.books[0].title = "…"`, one guard line, `_ = try XCTUnwrap(model.library.books[safe: 0], "…")`, after which the test's subscripts stay as they are. Make a test `throws` when it needs `try`.
- `subscript(safe:)` is the shared, read-only helper in `TextMouthProductionTests/CollectionTestSupport.swift`. Use it; do not change it.
- Change nothing a test asserts: no expected value, no message, and no test removed or renamed.

## The three files
1. **`TextMouthProductionTests/LibraryBookUpdatesTests.swift`** (248 lines). `makeLibrary(count:)` (lines 234 to 247) builds the `books` it returns itself, so `books[0]` and `books[1]` are safe. But it hands them to `Library(books:)` and a `LibraryViewModel`, which are code under test, so `model.library.books[0]` and `[1]` (lines 27 to 29, 50 to 53, 95 to 104, 120 to 123) and `renamed.books[0]` and `[1]` (lines 156 and 157; read lines 150 to 158 for where `renamed` comes from) are at risk. Guard each test once, before its first such subscript.
2. **`TextMouthProductionTests/BookmarkKeyboardAccessTests.swift`** (878 lines). Its lists appear to be the test's own: `makeBookmarks(count:)` (line 703), `outOfBookOrderBookmarks()` (line 711), and literals (lines 62, 113, 133). Check each numeric subscript with one `grep -n -E '[A-Za-z)?]\[[0-9]+\]'` of the file, and look at a few lines around a hit only where the list's source is not plain. Guard any subscript on a list a reader or the panel made; leave the rest. If none is at risk, change nothing in the file and say so in your report, with the count you checked.
3. **`TextMouthProductionTests/TranscriptModelTests.swift`**, `testValidationNamesTheFirstUnusableField` (from line 112). Its cases write into `TranscriptFixtures.twoFiles` by position (`files[1]`, `files[0].sentences[2]`, `files[1].sentences[0]`). That fixture is the tests' own, so it is safe today, but a change to it would trap. At the top of the test, prove the shape the cases rely on with one guard that stops the test with a message: two files, the first with at least three sentences, and the second with at least one. Read the test to its end first, to take every position it uses.

## Commits
One commit per file you change, each ending with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. Report how many subscripts each guards, and which you judged safe.

## Build and test
- Run `LibraryBookUpdatesTests`, `BookmarkKeyboardAccessTests`, and `TranscriptModelTests`.
- `BookmarkKeyboardAccessTests` is load-sensitive: if one of its tests fails, run that class alone once more and report both results.
- Start each build in the background, and check on it no more often than every 4 minutes, with one short command.
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish2-subscripts2-…`. If the worktree guard refuses `${TMPDIR}`, write the folder's literal path, `/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-polish2-subscripts2`.

      BBS_AGENT=polish2-subscripts2 .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath "${TMPDIR}TextMouth-DerivedData-polish2-subscripts2" -only-testing:TextMouthProductionTests/LibraryBookUpdatesTests -only-testing:TextMouthProductionTests/BookmarkKeyboardAccessTests -only-testing:TextMouthProductionTests/TranscriptModelTests > /private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/polish2-subscripts2-build-1.log 2>&1

- Read a result with `grep -E "Executed [0-9]+ tests|error:|failed \(" <log> | tail -20`.

## Do not touch
- App code, and any other test file (`CollectionTestSupport.swift` and `TranscriptFixtures` included).
- `TextMouth.xcodeproj/project.pbxproj`, which another team claims; add no new file.
- Any `*.md` file.

# polish2-cindex: #1857, ContentIndexValidationTests fails instead of trapping

- Team `polish2`; lead `polish2-lead`; your task is number 2 on the team's list.
- Your slug is `polish2-cindex`. Your branch is `polish2/cindex`, made with `git checkout -b polish2/cindex team/polish2`. Your worktree may start on an old commit, so branch from `team/polish2` exactly so.
- First read `Scripts/agents/briefs/2026-10-12/teams-common.md`: "The worker's part", "Rules for everyone", "The board", and "Builds".
- Register, joining the team, then mark your task started:

      bbs register polish2-cindex --role "#1857: ContentIndexValidationTests fails instead of trapping" --branch polish2/cindex --files TextMouthProductionTests/ContentIndexValidationTests.swift --team polish2
      bbs task move polish2-cindex 2 working

- This brief gives you what you need. Read only the line ranges it names, once each.
- It closes the `ContentIndexValidationTests` part of #1857's next slice ("Still open after the polish-team merge"). The rest of #1857 stays open.

## What is wrong
A numeric subscript on a list the test has not proven long enough, such as `index.chapters[1].headings[1].level = 7`, traps when the code under test breaks. An assertion does not stop a test, so it cannot prove anything. The test host then crashes, and the user sees a crash dialog instead of a failed test.

`TextMouthProductionTests/ContentIndexValidationTests.swift` (1,571 lines, 92 tests) has about 130 lines with a numeric subscript. They fall into four kinds:
1. **Fixtures made by the code under test.** The fixture builders in its "Fixtures" section (lines 1262 to 1360) call `BookContentIndex.build`, which is the code under test: `textIndex()` (line 1284), `singleFileIndex()` (1289), `multiFileIndex(in:)` (1303), `segmentedIndex()` (1321), and `severalClipIndex()` (1339, already `throws`). Most tests take one and change it by position, such as `index.chapters[1].headings[1].level = 7` (line 208) or `index.chapters[1].audio?.clips?[2].duration = -1` (line 470). These are at risk.
2. **Indexes read back from a book.** The "Opening a book" tests (lines 939 to 1227) subscript what `savedIndex(of:)`, `BookContentAnalysisService.load`, and `MarkdownCacheService.loadFromCache(for:)` return, such as `damaged.chapters[1].startCharacterOffset` (line 958), `otherChapters[1].text` (987), `result.index.chapters[1]` (966), and `result.audioSegments?[1]` (1114). These are at risk.
3. **Built inline.** Lines 43 to 45 and 935 subscript an index the test built a line or two before with `BookContentIndex.build`. These are at risk.
4. **Safe; leave them alone.**
   - Text inside a string literal, such as `"chapters[1].chapterIndex is 2, expected 1"`, is not a subscript.
   - `textChapters()` (line 1267) is a literal list of two chapters the test wrote itself, so `chapters[1]` on it (lines 830 to 921) is safe.
   - A subscript after a guard that stops the test, such as a `try XCTUnwrap` of that element, is safe.

## Do
1. **One shape check.** Add one private helper to the "Fixtures" section, with a doc comment:

       /// `index` itself, once it proves to hold `headings.count` chapters,
       /// with `headings[n]` headings in chapter n. Throws, failing the test,
       /// when the builder made another shape, so a test that changes the
       /// fixture by position fails instead of trapping the test host.
       private func requiringShape(_ index: BookContentIndex, headings: [Int]) throws -> BookContentIndex {
           let shape = index.chapters.map(\.headings.count)
           return try XCTUnwrap(shape == headings ? index : nil, "chapters with \(shape) headings, expected \(headings)")
       }

2. **Each fixture builder proves its shape.** Make the builders `throws` and return through the helper, and say so in each doc comment:
   - `textIndex()`: `[1, 2]`, as `textChapters()`'s comment describes;
   - `singleFileIndex()`: `[1]`;
   - `multiFileIndex(in:)`: `[1, 1, 1]`;
   - `segmentedIndex()`: `[1, 1]`;
   - `severalClipIndex()`: `[1, 1]`, and also that its second chapter has its three clips. Prove that with `try XCTUnwrap(index.chapters[1].audio?.clips?[safe: 2], "…")`, after the shape check has proven `chapters[1]`.
3. **Callers.** Every call becomes `try textIndex()` and so on. Make each test that calls one `throws` if it is not already. That is about 100 call sites and 45 test signatures: mechanical, and nothing else in those tests changes.
4. **Kinds 2 and 3.** Before the first subscript of such a list in each test, prove the element exists:
   - for a value read, `let chapter = try XCTUnwrap(list[safe: 1])`, then use `chapter`;
   - inside an assertion, compare through `[safe:]`, such as `XCTAssertEqual(result.index.chapters[safe: 1]?.startCharacterOffset, start)`;
   - before a change by position, such as `damaged.chapters[1].startCharacterOffset += 7` or `otherChapters[1].text += addition`, one `_ = try XCTUnwrap(list[safe: 1], "…")` line, which is a guard; then the subscripts after it stay as they are;
   - `clips?[1]` on a read-back index likewise: prove `clips?[safe: 1]` first.
5. **`subscript(safe:)`** is the shared, read-only helper in `TextMouthProductionTests/CollectionTestSupport.swift`, an extension on `Array`. Use it; do not change it, and do not add a setter.
6. **Change nothing a test asserts:** no expected value, no message, and no test removed or renamed. The class still runs 92 tests.
7. **Commits.** One commit for the helper and the fixture builders with their callers (step 1 to 3), and one for kinds 2 and 3 (step 4). Each message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
8. **Report** how many subscripts each commit guards, and any you judged safe besides the kinds above, with their lines.

Edit with Python or `gsed -i`, never two heredocs on one command line. Read the file by line range, in pieces of at most about 250 lines.

## Build and test
- Run only `ContentIndexValidationTests`. It must report 92 tests and 0 failures, as on `team/polish2` before your change. If you want that baseline, take it from a first build before you edit.
- Start each build in the background, and check on it no more often than every 4 minutes, with one short command.
- Scratch files go in `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/`, each named `polish2-cindex-…`.

      BBS_AGENT=polish2-cindex .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath "${TMPDIR}TextMouth-DerivedData-polish2-cindex" -only-testing:TextMouthProductionTests/ContentIndexValidationTests > /private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/d79ccbfe-f907-4768-bef3-66390cef7d23/scratchpad/polish2-cindex-build-1.log 2>&1

- Read a result with `grep -E "Executed [0-9]+ tests|error:|failed \(" <log> | tail -20`.

## Do not touch
- App code, and any test file but this one (`CollectionTestSupport.swift` included).
- Any `*.md` file.

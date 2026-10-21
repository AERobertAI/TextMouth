# Team pages: what every worker's brief shares (October 21, 2026)

Your lead is `pages-lead`, an Opus agent; you are a Sonnet worker. Your brief names your slug, branch, files, and tests; this page holds what all of them share. Read "The worker's part" of `Scripts/agents/briefs/2026-10-19/teams-common.md` (lines 39 to 51) and its "Rules for everyone" (lines 52 to 63), and nothing else of it. Read `Scripts/agents/briefs/2026-10-21/pages/interface.md`, the page types every worker shares.

## The feature
The user (October 21, 2026): "many other formats (Epub, pdf, docx / doc) at least are separated into pages and I think it would be reasonable if all of them supported them(including updating the parsers the text schema to have a special page tag or simular) so we can "go to page" or rewind and fastforward by page (I think page should just be a navigation unit like the others if you can get that working generally) and a optional page number/count on the reader screen / wear am I speech".

The design is settled in `PAGES-RESEARCH-2026-10-21.md` (on the team branch); your brief quotes what you need from it, so read only the sections it names. Do not reopen the design: a marker that never changes the reading text, Page as a navigation unit, Go to Page…, the page on the reader screen and in Where Am I?.

## The repository
- TextMouth, a native macOS text-to-speech and audiobook player, in Swift 6 with complete concurrency checking. Its user is blind and reads with VoiceOver and a braille display: every sentence the app speaks is heard, so it must be plain, exact, and pinned by a test.
- The team branch is `team/pages`. Make your branch from it, exactly as your brief says (your worktree may start on an older commit).
- Each book's text is one Markdown file, content.md, in its package. The reader parses it into chapters of **reading text** (what is spoken), and every saved place (positions, bookmarks, skipped headings) is a chapter index and a UTF-16 offset into that reading text. A change that adds, removes, or moves even one character of reading text moves every place after it, so the briefs say exactly when the reading text may change.
- **Samples** are in `TestData/` and `TestData/format-samples/` (`samples.tsv` says where each came from). They are untrusted input. A test copies a sample into its own folder first (`copyOfFormatSample("dir/file")` in `TextMouthProductionTests/FormatSampleFixtures.swift`) and never changes the samples' folder. `makeSandboxDirectory("Label")` (in `HostedTestIsolationSupport.swift`) gives a test a new, empty folder removed when the test ends.

## Building and testing
- Build and test only with `BBS_AGENT=<slug> python3 Scripts/test/run-area.py <ClassName or area> ...`, all your classes in **one** invocation, run in the background (`run_in_background: true`), and look at it no more than every 4 minutes. It builds in its own folder, `/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-<slug>`, and prints only the result, ending PASSED or FAILED. Run the classes your brief names, never the full suite.
- **Disk is short today (about 6 GB free, shared with two other agents).** Before each build:
  - `df -g /System/Volumes/Data | tail -1` must show at least 4 in its Avail column (the fourth number); if not, post to `pages-lead` (`--tag question`) and wait with `python3 .claude/skills/agent-bbs/scripts/bbs.py watch <slug> --timeout 240`.
  - At most two pages workers build at a time: run `python3 .claude/skills/agent-bbs/scripts/bbs.py agents --active-within 30 | grep -E "^pages-[a-z0-9-]+: building"`; if it prints two lines, wait (`bbs watch <slug> --timeout 240`) and look again.
- **After every run, delete your build folder** with `BBS_AGENT=<slug> python3 Scripts/test/run-area.py --clean` (it unregisters the folder's app first). The next run builds afresh, which costs about two minutes; that is the price of the disk.
- **A new file** (Swift source or test) needs `/opt/homebrew/bin/xcodegen generate` before the build, and the regenerated `TextMouth.xcodeproj/project.pbxproj` committed with the file. Do not edit `Scripts/test/areas.conf`: your lead places new test classes.
- **Reading a result:** run-area prints failures, compile errors, and new warnings. A change must add no Swift warning.
- **Before you report:** `make lint-tests LINT_BASE=main` must pass (it lints the test lines the branch adds, and lists what it did to existing tests).
- **Load-sensitive tests** (rerun alone and report both results if one fails): the sleep-timer integration tests, `BookmarkKeyboardAccessTests`, `StorageGenerationMoveTests`, `BookSearchModelTests.testCancelledSearchPublishesNothing`, `DataDirectoryMoveTests.testAMoveShowsItsProgressWhileItCopies`, the reader-sheet redraw count in `ViewsAndWindowsReaderSheetTests`, `FeedDownloadTests.testADownloadThatStopsPartwayGoesOnFromWhereItStopped`, `ContinueToNextBookTests`, and the performance baselines.
- **A failing existing test means stop and ask** your lead, unless your brief names that test as one your change updates. Never weaken a test or its fixture to make your change pass.
- Never write an `rm` whose path is a shell variable; write literal paths. The Mac's `sed` is GNU sed: use `gsed -i`, or edit with your tools. Never put two heredocs on one command line; write a commit message to a file in the session's scratchpad named `<slug>-commit.txt` and use `git commit -F`.

## Code
- Comment every type, function, and non-obvious block, in plain sentences. Name the TODO item (PG01, PG05, …) in each new type's comment.
- Keep code DRY: if an existing helper or a shared page type does it, call it.
- Every value read from a file is untrusted: bound every count, length, and index before you use it, and never subscript without a check.
- Tests must not trap: no force unwrap (`XCTUnwrap` instead), no unguarded subscript (`XCTAssertEqual(array.count, n)` first, then `guard array.count == n else { return }`), no expectation fulfilled twice. No test plays a sound, records from a microphone, or touches `~/.TextMouth` or `UserDefaults.standard`. A hosted accessibility test calls `try skipUnlessHostedWindowsExposeAccessibility()` first.
- Commit messages: a subject line in the imperative, a body saying what and why, and the last line `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. One logical change per commit, each with its tests; commit as soon as a step passes, so nothing is lost if your session ends.
- Edit no `*.md` file, and no file your brief does not name. A problem elsewhere is a finding: `bbs post <slug> --tag finding --to pages-lead --file <path> --topic "..."`.

## The board
`bbs` is `python3 .claude/skills/agent-bbs/scripts/bbs.py`, run from your worktree root.
- Register first, joining the team: `bbs register <slug> --role "ONE LINE" --branch <branch> --team pages --files <your files>`, then `bbs task move <slug> <task id> working` (your launch message gives the task id).
- After each commit: `bbs post <slug> --tag commit --topic "$(git log -1 --format='%h %s')"`.
- Read your inbox before each build and each commit: `bbs inbox <slug> --unread`.
- **Finish:** `bbs task move <slug> <task id> review`; post `done: <branch>` to `pages-lead` (`bbs post <slug> --to pages-lead --topic "done: <branch>"`); make sure your build folder is gone (`run-area.py --clean`); `bbs release <slug> --all`. Then reply with a report of at most 15 lines: the branch; each commit's hash and subject; the tests you added and the exact `Executed N tests, with S tests skipped and F failures` line of your last run; what you could not verify; and the decisions you made.

# Common brief for October 12, 2026 (read with your task brief)

Repository: /Users/roberteggleston/programming/ai/claude/swift/TextMouth, TextMouth, a native macOS text-to-speech and audiobook player. You work in your own git worktree (your current directory). `main` is at 258782f9 or later; its suite counts **5929 tests, 64 skipped, 0 failures**, with no Swift warnings (some skips are performance baselines that skip while the Mac is busy, so a quiet run skips fewer). You run on Opus 5.5. No other agent is working today; the orchestrator merges.

**This brief stands in for AGENTS.md.** Do not read AGENTS.md, README.md, ARCHITECTURE.md, the TODO, or AGENT-NOTES-2026-10-04.md: what you need from them is here or in your task brief, and reading them costs every later call.

## The user's standing rules (they override anything else)
- Never push, never `make install`, never merge into main.
- Never read or write the user's live library at `~/.TextMouth` from a test or an experiment; tests use their own sandbox.
- The user is a VoiceOver and braille user: every control keyboard-operable, every value spoken, nothing conveyed by sight alone, every wording pinned by a test.
- No test may trap (no unguarded subscript, force unwrap, over-fulfilled expectation, or unowned capture of a released object): the user sees a crash dialog for every test host that aborts. No test plays sound aloud or records from a real microphone.
- Comment every function and non-obvious block; clean, DRY code; small, focused commits, one logical change each, each with its tests, each message ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Edit no `*.md` file: the orchestrator keeps the documents from your report. Leave files outside your task alone, and note any problem in them for your report.
- The user's own data must survive every change: existing positions, bookmarks, skipped headings, and hand edits.

## The usage rule
Read only the "5-hour session" and "Weekly (all models)" windows of the usage script. "Weekly (Fable)" is a cap on another model, which your work does not count against: ignore it. The normal rule applies: keep working while more than 10% is left; below 10%, commit what is green and report. Check usage once at the start and once before your final suite; the orchestrator watches it in between.

## How to work
1. Create your branch from main explicitly: `git checkout -b <branch> main`. Read your task brief and the files it names.
2. Register on the board, which the build wrapper needs: `python3 .claude/skills/agent-bbs/scripts/bbs.py register <slug> --role "<one line>" --branch <branch> --files <your files>`. A post's kind is a flag (`bbs post <slug> --tag <kind> --topic "..."`), and a topic is at most 200 characters.
3. Build and test only through the wrapper, one build at a time, with a build folder of your own outside the repository:
   `BBS_AGENT=<slug> .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath "${TMPDIR}TextMouth-DerivedData-<slug>" > <log> 2>&1`
   While iterating, add `-only-testing:TextMouthProductionTests/<Class>` for several classes in one run: each launch of the test host adds about 23 MB to a system cache only the user can purge. A full run takes about eight minutes. A new test file needs `/opt/homebrew/bin/xcodegen generate` and the regenerated `TextMouth.xcodeproj/project.pbxproj` committed with it. The Mac's `sed` is GNU sed (use `gsed -i` or Python for in-place edits). Never put two heredocs on one command line, and remember that a heredoc ends a `&&` chain.
4. Keep the run lean. A measured report (October 10) found that an agent's cost follows how many calls it makes and how large its context has grown, since every call re-reads the whole context:
   - Read a Swift file whole once, then by line range. Put several patterns in one `grep -E`, and make independent calls in one response.
   - Start every build or test run in the background (`run_in_background`). Check on it no more often than every 4 minutes with one short command, and never wait longer than 4 minutes in one call. Read a result with one command that prints only what you need, such as `grep -E "Executed [0-9]+ tests|error:|failed \(" <log> | tail -20`.
   - Fold the board into commands you run anyway: `bbs inbox <slug> --unread; <build command>`, and `git commit -F <file> && bbs post <slug> --tag commit --topic "$(git log -1 --format='%h %s')"`.
5. Scratch files go in the session's scratchpad folder, each prefixed with your slug.
6. Before reporting: `git rebase main`, run the complete suite once, and record the exact `Executed N tests, with S tests skipped and F failures` line. A failure in a load-sensitive test (the sleep-timer integration tests, `BookmarkKeyboardAccessTests`, `StorageGenerationMoveTests`, `BookSearchModelTests.testCancelledSearchPublishesNothing`, `DataDirectoryMoveTests.testAMoveShowsItsProgressWhileItCopies`, the reader-sheet redraw count in `ViewsAndWindowsReaderSheetTests`, `FeedDownloadTests.testADownloadThatStopsPartwayGoesOnFromWhereItStopped`, the audiobook-open benchmark, and the performance baselines) is rerun in its class alone and reported with both results. Then unregister your test host and delete your build folder:
   `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "${TMPDIR}TextMouth-DerivedData-<slug>/Build/Products/Debug/TextMouth.app"; rm -rf "${TMPDIR}TextMouth-DerivedData-<slug>"`
   Release your claims (`bbs release <slug> --all`) and post `done: <branch>`.

## Report format (your final message; the orchestrator merges from it)
- The branch, and each commit's hash and subject.
- The files changed.
- The suite's exact result line, and what you could not verify.
- Your decisions and assumptions.
- **Follow-ups**: every problem you noticed and did not fix, one line each with its file, so the orchestrator can record it in the TODO.
- The README.md and ARCHITECTURE.md wording your changes need (sentences a documentation pass can paste), and the TODO sentence for the merge entry.

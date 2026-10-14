# Common brief for October 13, 2026 (read with AGENTS.md)

Repository: /Users/roberteggleston/programming/ai/claude/swift/TextMouth, a native macOS TTS and audiobook app, TextMouth. You work in your own git worktree (your current directory). `main` is at 07040da7 (FR15's merge, e2ab40d9, and its documentation) or later; the suite on it counts **6192 tests, 64 skipped, 0 failures**, with no Swift warnings (the performance baselines skip while the Mac is busy, so a quiet run skips fewer). The orchestrator runs on Opus 5.5, and so do you.

**Your worktree starts at origin/main, which is far behind local main.** Make your branch from local main by name (`git checkout -b <branch> main`) and check that `git merge-base --is-ancestor e2ab40d9 HEAD` succeeds before you start.

## Who else is working
No other agent. You may use any of the three build slots the wrapper hands out, one build at a time.

## The user's standing rules (from AGENTS.md; they override anything else)
- Never push, never `make install`, never merge into main. The orchestrator merges.
- Never read or write the user's live library at `~/.TextMouth` from a test or an experiment. Tests use their own sandbox. Reading its logs for a diagnosis is fine.
- The user is a VoiceOver and braille user: every control keyboard-operable, every value spoken, nothing conveyed by sight alone, every wording pinned by a test.
- No test may trap (no unguarded subscript, force unwrap, over-fulfilled expectation, or unowned capture of a released object): the user sees a crash dialog for every test host that aborts. No test plays sound aloud (silent audio fixtures may play) or records from a real microphone. No test writes to the general pasteboard.
- Comment every function and non-obvious block; clean, DRY code; small, focused commits, one logical change each, each with its test, each message ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Edit no `*.md` file: the orchestrator maintains the documents from your report. Leave files outside your task alone; post a finding on the board instead.
- Existing rows, records, positions, bookmarks, shortcuts, and hand edits must survive every change. A book that opens today must still open.

## The usage rule, read correctly for today
Your global instructions say to act on the usage script's binding window. Read only the unscoped windows ("5-hour session" and "Weekly (all models)"); **ignore "Weekly (Fable)"**, a cap on another model. The user accepts agent work running the weekly all-models window down to about 10% left (October 12: "I am fine if the weekly budget hits around 90%"), so a "low" reading is no reason to stop. If "Weekly (all models)" reads 10% left or less, commit what is green, stop, and report what is left. Commit each item as soon as it is green, so a cut-off loses nothing.

## How to work
1. Create your branch from main explicitly, then read AGENTS.md at the repository root, this brief, and your task brief.
2. Register on the board and look for overlaps: `python3 .claude/skills/agent-bbs/scripts/bbs.py register <slug> --role "<one line>" --branch <branch> --files <your files>`, then `bbs claims` and `bbs read --last 10`. Read your inbox (`bbs inbox <slug> --unread`) before every build, every commit, and your report. The post syntax is `bbs post <slug> --tag <kind> --topic "..."`; a topic is at most 200 characters.
3. Build and test only through the wrapper, one build of your own at a time, in a build folder of your own outside the repository:
   `BBS_AGENT=<slug> .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath "${TMPDIR}TextMouth-DerivedData-<slug>" > <log> 2>&1`
   While iterating add `-only-testing:TextMouthProductionTests/<Class>` for several classes per run (each launch of the test host costs about 23 MB of system icon cache, so batch targeted runs). In zsh, pass several `-only-testing` options as an array (`O+=("-only-testing:…")`, then `"${O[@]}"`): an unquoted string is not split. A full run takes about ten minutes. A new test file needs `/opt/homebrew/bin/xcodegen generate` and the regenerated `TextMouth.xcodeproj/project.pbxproj` committed with it. The Mac's `sed` is GNU sed (use `gsed -i` or Python for in-place edits). Never put two heredocs on one command line; a heredoc ends a `&&` chain. Prefix every scratch file you write in the session scratchpad with your slug.
4. Post a `build` notice before a full suite and a `commit` notice after each commit (`bbs post <slug> --tag commit --topic "$(git log -1 --format='%h %s')"`).
5. Before reporting: `git rebase main`, run the complete suite once, and record the exact `Executed N tests, with S tests skipped and F failures` line. A failure in a test AGENTS.md lists as load-sensitive is rerun in its class alone and reported with both results. Then unregister your test host and delete your build folder:
   `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "${TMPDIR}TextMouth-DerivedData-<slug>/Build/Products/Debug/TextMouth.app"; rm -rf "${TMPDIR}TextMouth-DerivedData-<slug>"`
   Release your claims (`bbs release <slug> --all`) and post `done: <branch>`.
6. Two tests pin every field of `Book`: `ContentAnalysisMergeTests.bookWithEveryFieldSet(seed:)` and `testBookRebuiltFromItsRecordHasEveryField`. `UncheckedConcurrencyPolicyTests` pins the count of `@unchecked Sendable` and `nonisolated(unsafe)` declarations. `LogContentPolicyTests` scans log calls: an `event` line may name a book or a file, never an absolute path.

## Report format (your final message; the orchestrator merges from it)
- The branch, and each commit's hash and subject.
- The files changed.
- The suite's exact result line, and what you could not verify.
- Your decisions and assumptions, and findings posted on the board.
- **Follow-ups**: every problem you noticed and did not fix, one line each with its file.
- The README.md and ARCHITECTURE.md wording your changes need (sentences a documentation pass can paste), and one TODO sentence for the merge entry.

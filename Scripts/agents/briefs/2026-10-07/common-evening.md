# Common brief for the October 7, 2026 evening wave (read with AGENTS.md)

Repository: /Users/roberteggleston/programming/ai/claude/swift/TextMouth, a native macOS TTS and audiobook app, TextMouth. You work in your own git worktree (your current directory) unless your brief says you are a read-only reviewer. `main` is at fca0f91d or later; the suite on it counts **4687 tests, 56 skipped, 0 failures**. The orchestrator runs on Opus 5.5, and so do you.

## Who else is working (each owns only the files its brief names)
- `reviewspeech` and `reviewlibrary`: read-only code reviewers of the five October 7 afternoon merges. They edit nothing and build nothing.
- `docs7`: README.md and ARCHITECTURE.md only, for the five October 7 afternoon merges. No build.
- `followups7` (branch `fix/october-7-followups`): the reader's metadata editor flags, the import's hand-edit record, the reader taking `onSpeechRefused`, Where Am I hearing a cancel. Reader files and one line in the file import.
- `readinglist` (branch `feature/reading-list`): FR09's library part: the model, the fifth category, its options bar, its commands.
- `feedfollowups` (branch `fix/feed-folder-counts`): FR03's follow-ups: a feed's folder row and counts, no duplicate row in the Folders list, the open feed's summary, "keeping 10 of 381 episodes".
Three of these build: `followups7`, `readinglist`, `feedfollowups`. The machine has three build slots, so each of you gets one.

## The user's standing rules (from AGENTS.md; they override anything else)
- Never push, never `make install`, never merge into main. The orchestrator merges.
- Never read or write the user's live library at `~/.TextMouth` from a test or an experiment. Tests use their own sandbox. Reading its logs for a diagnosis is fine.
- The user is a VoiceOver and braille user: every control keyboard-operable, every value spoken, nothing conveyed by sight alone, every wording pinned by a test.
- No test may trap (no unguarded subscript, force unwrap, over-fulfilled expectation, or unowned capture of a released object): the user sees a crash dialog for every test host that aborts. No test plays sound aloud or records from a real microphone. (`AVSpeechSynthesizer.write(_:toBufferCallback:)` renders offline and plays nothing; it is allowed.)
- Comment every function and non-obvious block; clean, DRY code; small, focused commits, one logical change each, each with its test, each message ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Edit no `*.md` file (except `docs7`, which edits README.md and ARCHITECTURE.md only): the orchestrator maintains the documents from your report. Leave files outside your task alone; post a finding on the board instead.
- The user said on October 7: "0 other people should have this app aside from me". Take that as freedom from migrations for other users, not as leave to lose this user's own data: existing rows, records, and hand edits must survive every change.

## The usage rule, read correctly for this wave
Your global instructions say to act on the usage script's binding window. On October 7 the script and the session-start line report a **"Weekly (Fable)"** window at a few percent left, marked critical. That window is a separate cap on the Fable model only; you run on Opus 5.5, which it does not count. **Ignore "Weekly (Fable)" entirely.** Act on the two windows that count your work: "5-hour session" and "Weekly (all models)" (`python3 ~/.claude/skills/claude-usage-left/scripts/claude_usage.py --json`, read those two entries of `windows`, not `binding`). Keep working while both are above 10% left. If either falls below 10% left, finish the commit in hand, post a notice on the board saying where your branch stands, and report.

## How to work
1. Create your branch from main explicitly: `git checkout -b <branch> main`. Read AGENTS.md at the repository root, then this brief and your task brief.
2. Register on the board and look for overlaps: `python3 .claude/skills/agent-bbs/scripts/bbs.py register <slug> --role "<one line>" --branch <branch> --files <your files>`, then `bbs claims` and `bbs read --last 10`. `bbs protocol` prints the rules. Read your inbox (`bbs inbox <slug> --unread`) before every build, every commit, and your report. The post syntax is `bbs post <slug> --tag <kind> --topic "..."` (the kind is a flag); a topic is at most 200 characters.
3. Build and test only through the wrapper, one build of your own at a time, in a build folder of your own outside the repository:
   `BBS_AGENT=<slug> .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath "${TMPDIR}TextMouth-DerivedData-<slug>" > <log> 2>&1`
   While iterating add `-only-testing:TextMouthProductionTests/<Class>` for several classes per run (each launch of the test host costs about 23 MB of system icon cache, so batch targeted runs). A full run takes about eight minutes and the wrapper queues you for one of three machine-wide slots (the Mac has 8 GB of memory). A new test file needs `/opt/homebrew/bin/xcodegen generate` and the regenerated `TextMouth.xcodeproj/project.pbxproj` committed with it. The Mac's `sed` is GNU sed (use `gsed -i` or Python for in-place edits). In zsh, `log` is a builtin: call `/usr/bin/log` for the unified log. Never put two heredocs on one command line.
4. Post a `build` notice before a full suite and a `commit` notice after each commit (`bbs post <slug> --tag commit --topic "$(git log -1 --format='%h %s')"`). A problem in a file you do not own: `bbs post <slug> --tag finding --file <path> --topic "..." --body "..."`, never a fix. Note every follow-up you find, fixed or not, for your report: the orchestrator records them in the TODO.
5. Before reporting: `git rebase main` (keep both sides of adjacent-line conflicts, which are common in `MenuCommands`, `KeyboardShortcut`, `LibraryView`, and the config test fixtures), run the complete suite once, and record the exact `Executed N tests, with S tests skipped and F failures` line. Then unregister your test host and delete your build folder:
   `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "${TMPDIR}TextMouth-DerivedData-<slug>/Build/Products/Debug/TextMouth.app"; rm -rf "${TMPDIR}TextMouth-DerivedData-<slug>"`
   Release your claims (`bbs release <slug> --all`) and post `done: <branch>`.
6. Hosted accessibility tests: `withHostedControls` and `accessibleControls(in:)` (TextMouthProductionTests/AccessibilityTestSupport.swift) see the AppKit controls SwiftUI draws (text fields, steppers, sliders, checkboxes, pickers) but on this Mac SwiftUI exposes no buttons to them, even with VoiceOver running; a test that needs buttons skips with `XCTSkip` when none are exposed. Pin wording with static constants and tests that need no window as well.
7. Two tests pin every field of `Book`: `ContentAnalysisMergeTests.bookWithEveryFieldSet(seed:)` must set a new field, and `testBookRebuiltFromItsRecordHasEveryField` requires the package record (`BookMetadata`/`BookState`, `makeBookInfo()`, `Book(record:…)`) to carry it. A new field of a row or record is decoded with `decodeIfPresent` so older files load. `UncheckedConcurrencyPolicyTests` pins the count of `@unchecked Sendable` (27) and `nonisolated(unsafe)` declarations; a new one needs a comment naming its lock, queue, actor, or thread, and the pin moves with it.

## Report format (your final message; the orchestrator merges from it)
- The branch, and each commit's hash and subject.
- The files changed.
- The suite's exact result line, and what you could not verify.
- Your decisions and assumptions, and findings posted on the board.
- **Follow-ups**: every problem you noticed and did not fix, one line each with its file, so the orchestrator can record it in the TODO.
- The README.md and ARCHITECTURE.md wording your changes need (sentences the documentation pass can paste), and the TODO sentence for the merge entry.

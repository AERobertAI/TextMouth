# Common brief for the October 7, 2026 wave (read with AGENTS.md)

Repository: /Users/roberteggleston/programming/ai/claude/swift/TextMouth, a native macOS TTS and audiobook app, TextMouth. You work in your own git worktree (your current directory). `main` is at 74f794f1 or later; the suite on it counts **4596 tests, 53 skipped, 0 failures**. Four task agents run at once; each owns the files its brief names and no others.

## The user's standing rules (from AGENTS.md; they override anything else)
- Never push, never `make install`, never merge into main. The orchestrator merges.
- Never read or write the user's live library at `~/.TextMouth` from a test or an experiment. Tests use their own sandbox. (The orchestrator read it read-only for the diagnoses quoted in the briefs.)
- The user is a VoiceOver and braille user: every control keyboard-operable, every value spoken, nothing conveyed by sight alone, every wording pinned by a test.
- No test may trap (no unguarded subscript, force unwrap, over-fulfilled expectation, or unowned capture of a released object): the user sees a crash dialog for every test host that aborts. No test plays sound aloud or records from a real microphone. (`AVSpeechSynthesizer.write(_:toBufferCallback:)` renders offline and plays nothing; it is allowed.)
- Comment every function and non-obvious block; clean, DRY code; small, focused commits, one logical change each, each with its test, each message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Edit no `*.md` file: the orchestrator maintains the documents from your report. Leave files outside your task alone; post a finding on the board instead.
- Follow the usage rule in your instructions as written: the user has not overridden it today.
- The user said today: "0 other people should have this app aside from me". Take that as freedom from migrations for other users, not as leave to lose this user's own data: existing rows, records, and hand edits must survive every change.

## How to work
1. Create your branch from main explicitly: `git checkout -b <branch> main`. Read AGENTS.md at the repository root, then this brief and your task brief.
2. Register on the board and look for overlaps: `python3 .claude/skills/agent-bbs/scripts/bbs.py register <slug> --role "<one line>" --branch <branch> --files <your files>`, then `bbs claims` and `bbs read --last 10`. `bbs protocol` prints the rules. Read your inbox (`bbs inbox <slug> --unread`) before every build, every commit, and your report.
3. Build and test only through the wrapper, one build of your own at a time, in a build folder of your own outside the repository:
   `BBS_AGENT=<slug> .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath "${TMPDIR}TextMouth-DerivedData-<slug>" > <log> 2>&1`
   While iterating add `-only-testing:TextMouthProductionTests/<Class>` for several classes per run (each launch of the test host costs about 23 MB of system icon cache, so batch targeted runs). A full run takes eight minutes and the wrapper queues you for one of three machine-wide slots (the Mac has 8 GB of memory). A new test file needs `/opt/homebrew/bin/xcodegen generate` and the regenerated `TextMouth.xcodeproj/project.pbxproj` committed with it. The Mac's `sed` is GNU sed (use `gsed -i` or Python for in-place edits). In zsh, `log` is a builtin: call `/usr/bin/log` for the unified log.
4. Post a `build` notice before a full suite and a `commit` notice after each commit (`bbs post <slug> --tag commit --topic "$(git log -1 --format='%h %s')"`). A problem in a file you do not own: `bbs post <slug> --tag finding --file <path> --topic "..." --body "..."`, never a fix.
5. Before reporting: `git rebase main` (keep both sides of adjacent-line conflicts), run the complete suite once, and record the exact `Executed N tests, with S tests skipped and F failures` line. Then unregister your test host and delete your build folder:
   `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "${TMPDIR}TextMouth-DerivedData-<slug>/Build/Products/Debug/TextMouth.app"; rm -rf "${TMPDIR}TextMouth-DerivedData-<slug>"`
   Release your claims (`bbs release <slug> --all`) and post `done: <branch>`.
6. Hosted accessibility tests: `withHostedControls` and `accessibleControls(in:)` (TextMouthProductionTests/AccessibilityTestSupport.swift) see the AppKit controls SwiftUI draws (text fields, steppers, sliders, checkboxes) but on this Mac SwiftUI exposes no buttons to them, even with VoiceOver running; a test that needs buttons skips with `XCTSkip` when none are exposed. Pin wording with static constants and tests that need no window as well.
7. Two tests pin every field of `Book`: `ContentAnalysisMergeTests.bookWithEveryFieldSet(seed:)` must set a new field, and `testBookRebuiltFromItsRecordHasEveryField` requires the package record (`BookMetadata`/`BookState`, `makeBookInfo()`, `Book(record:…)`) to carry it. A row's new field is decoded with `decodeIfPresent` so older rows load.

## Report format (your final message; the orchestrator merges from it)
- The branch, and each commit's hash and subject.
- The files changed.
- The suite's exact result line, and what you could not verify.
- Your decisions and assumptions, and findings posted on the board.
- The README.md and ARCHITECTURE.md wording your changes need (sentences the documentation pass can paste), and the TODO sentence for the merge entry.

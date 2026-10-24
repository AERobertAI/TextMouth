# Common rules for the October 24 agents (before the weekly reset)

The user (October 24, 2026, 02:25 ET): "Are there any more formats or bugs / todos you could work on? there is still around 13 % left resetting in about 5 hours and I want you to use as much as possible".

The user has not yet installed 0.2.1 (main at 96020f1d, release-checked at 8467 tests, 0 failures). Main must stay stable, so:
- **Your branch, not main.** Work on your own branch from main. The orchestrator integrates every branch into one integration branch, reviews it, runs one full suite, and only then moves main.
- **Unfinished is fine.** Anything unfinished when the week's usage runs out stays on your branch, and is resumed after the 08:00 reset. Commit small and often, so nothing is lost.
- **The usage rule does not apply.** The user overrode its "low/critical, wrap up" guidance tonight. Work until the API refuses.

Rules for every agent:
- **The board and builds.** Register on the message board (`python3 -I .claude/skills/agent-bbs/scripts/bbs.py protocol`), claim your files, read the others' claims, and build only through the wrapper (`Scripts/test/run-area.py`).
- **Disk.** Five agents share about 15 GB. Check for at least 5 GB free before each build, wait if it is lower, and delete your build folder as soon as your last run ends, unregistering its app first with `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u <folder>/Build/Products/Debug/TextMouth.app`.
- **Commits.** Small focused commits, each with its tests, and comments in the surrounding style. Each message ends with your model's `Co-Authored-By:` line (`Claude Opus 5.5 <noreply@anthropic.com>` or `Claude Sonnet 5.5 <noreply@anthropic.com>`).
- **Tests:**
  - none may trap, play a sound, record, decode Ogg through Apple's frameworks, or touch `~/.TextMouth` or `UserDefaults.standard`;
  - a hosted accessibility test calls `skipUnlessHostedWindowsExposeAccessibility()` first;
  - adding an `@unchecked Sendable` type or a `nonisolated(unsafe)` variable means updating `UncheckedConcurrencyPolicyTests`' pin in the same commit, and a new log tag means `LogContentPolicyTests`;
  - a change to an on-disk format, a version, or `PageReaderVersions` means updating `OnDiskContractTests`' pins in the same commit, with the reason.
- **Before you change a test that pins old behavior,** grep for every fixture and test that pins it, and change them deliberately, saying so in the commit.
- **At the end,** in one `run-area.py` invocation, run your touched classes and their areas, plus `make lint-tests LINT_BASE=main`. Do not run the full suite.
- **Paths.** Use literal paths in every `rm`.
- **Never** push, merge into main, or touch `~/.TextMouth`.
- **The final message is your report, at most 25 lines:**
  - each commit;
  - the counts and the lint result;
  - every new sentence a listener hears;
  - what is unfinished;
  - follow-ups.

# The fix round of `ci/ios-unit-tests` (November 11, 2026)

You are `iosunitfix`, a Sonnet worker. You fix what the Opus review of branch `ci/ios-unit-tests` asked for, on that branch.

First read `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/Scripts/agents/briefs/2026-11-11/iosunit.md`, the brief of the worker who made the branch. Follow its sections "Runs on GitHub", "Pushing: what you may do, and what you may not", "The rule on sound", and "Checks", with one change: never run `gh run watch` (see "Waiting" below). Through it, also follow `../2026-11-10/common.md`, as that brief says.

## Start

- In your worktree, run `git switch ci/ios-unit-tests`, and check that `git log -1 --format=%h` prints `2b9b371b`. The branch's first worker has finished, and its folder no longer holds the branch.
- Read, in `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/iosunit/`:
  - `iosunit-review.md`, the review, findings 1 to 6 and "Couldn't settle";
  - `iosunit-report.md`, the worker's report.
- Briefs are gitignored, so after the switch they are not in your worktree: read them from the main checkout's paths above.

## The work, in this order

1. **Finding 1: make the Search sheet's growth test prove what it claims** (`TextMouthiOSUITests/LargeTextUITests.swift`, `testTheSearchSheetHoldsAtTheLargestText`).
   - **The goal.** The Search sheet's audit (`SearchUITests.swift`) reports Dynamic Type findings without failing. That is sound only if the growth test fails whenever one of the four parts stops growing before the largest size, and still passes for the sheet as it is. The four parts are the field, the status line, the regular-expression switch, and the "Search results" heading. Today it requires only 1.2 times the default height, and text capped at Extra Extra Extra Large passes that.
   - **Measure first.** Make the test log every part's height at both sizes on every run, not only when it fails. Then send one GitHub run that names `LargeTextUITests`, and read the heights from its log.
   - **Then set the bound from what you measured.** It must fail a part capped at Accessibility 2 (`.accessibility2`) or any smaller size. The review suggests 2.0 times the default height, or a comparison with a text known to grow, such as a result row's text. Choose from the heights.
     - A part whose height can't grow that much, such as the switch's row or the field with its padding, needs its own check, still failing a cap at Accessibility 2.
     - Say in a comment where the bound comes from, with the run.
   - **Name every part that fails.** One failure message must name every part that fell short, not only the first.
   - **Prove it.** Make a proof-only branch from your fixed tree.
     - Cap all four parts at `.accessibility2` in `TextMouth/Platform/iOS/` (for instance `.dynamicTypeSize(...DynamicTypeSize.accessibility2)`).
     - Send one GitHub run of it that names `LargeTextUITests`. The growth test must fail there, naming all four parts.
     - Never merge that branch.
2. **Finding 2: the source counter** (`Scripts/agents/ios_ui_tests.py`). It must count, and credit to the right class:
   - a test whose `func` has attributes or modifiers before it on the same line, such as `@MainActor func testA()`;
   - a class with attributes or modifiers before `class`, such as `@MainActor final class A: XCTestCase`;
   - a test in an `extension` of a test class in another file;
   - a file in a subfolder of either test folder (`project.yml` takes its sources recursively).

   Add a test that fails if a `func test` in either folder is left uncounted. Keep the safe cases safe: anything that now gives a false red may stay a false red.
3. **Finding 3: the guard that no unit test makes sound** (`Scripts/agents/tests/test_run_ios_ui_tests.py`).
   - It must also catch the app's own calls that `@testable import TextMouth` exposes and the review lists: `togglePlay()`, `playOrResume()`, `playSelection()`, `playAudioChapter()`, `startPunchIn()`, `PhoneAudioSession`, `import Speech`, and `.play(at:)` with any arguments. It must also read subfolders.
   - It must still pass on today's 19 tests: check each new name against them before you add it.
   - Prove it by a break in a scratch copy: a unit test file that calls `togglePlay()` fails it.
4. **Finding 4: iPhone and Mac test class names.** Add a Python test that no iPhone test class, unit or interface, has a Mac test class's name. If one does today, rename the iPhone class instead of loosening the test.
5. **Findings 5 and 6: the documentation.**
   - `docs/developer/building.md:130`: only the interface tests skip unless the opt-in variable is 1. The unit tests never skip.
   - `docs/developer/testing.md:198`: `run_suite.py --remote` prints failed unit tests too.
   - Correct any other line your changes make untrue.
6. **If it is small** (a few lines and a test): when the host app crashes in the middle of a test, so that a test has started and has no outcome line, the summary names that test as failed. Otherwise leave it for the report.

## Waiting

- Wait for each GitHub run with one background command, such as your `run_suite.py --remote`. Then end your turn: you are resumed when it ends. Never poll in a loop.
- **Never run `gh run watch`.** `github_run.py` already polls GitHub. On November 11, duplicate watchers used up the account's 5,000 API calls an hour for 20 minutes. A train and other agents share that limit.

## The final run

When everything is done, send one GitHub run of your final tree for the phone area. Its iPhone job must pass all of both bundles' tests, and its log must show the growth test's heights. Don't run a full suite: the orchestrator runs one after the merge.

## Rules (also in the briefs above; follow every one)

- **The live library:** never read, stat, or copy the user's live library: `~/.TextMouth`, anything under `~/Library/CloudStorage/`, or any data directory the settings name.
- **No deleting:** nobody deletes anything during a run. No `rm` at all, not even with a relative path, and no deleting from scripts.
- **This Mac:** build no app, and run no simulator, `simctl`, `xcodebuild test`, or `run-ios-ui-tests.py`. Never set the opt-in sound variable, and don't name it in a new file.
- **Pushing:** push to `TestBuild` only, through `github_run.py` or `run_suite.py --remote`. Never push another branch or a tag, never `make install`, and never merge into main.
- **Downloads** are untrusted: each goes in a new folder of its own, and any Python that reads them runs as `python3 -I -B`.
- **Small commits,** each doing one thing, ending with your model's `Co-Authored-By` line.
- Use they/them for the user.

## Your report

Your final message is the report, at most 40 lines. Also save it as `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/iosunit/iosunit-fix-report.md`. It holds:
- the branch's tip and your commits;
- each finding: what you changed, and the break that fails its test;
- the four parts' heights at both sizes, the bound you chose, and why;
- each GitHub run, with its link, minutes, and result;
- what you couldn't do.

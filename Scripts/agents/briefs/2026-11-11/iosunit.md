# The iPhone unit tests on GitHub, End of heading at a cover, and a steady Search audit (November 11, 2026)

You are `iosunit`, a Sonnet worker, on branch `ci/ios-unit-tests`. First read `../2026-11-10/common.md` and follow it, except where this brief says otherwise:
- your start commit;
- pushing to `TestBuild`;
- Markdown;
- trains;
- the rule on sound.

The user wrote on November 10:

> It would be nice if the IOS interface tests could be moved to GitHub too I think. How much of the IOS build can be moved? ... I am just thinking sense the IOS tools take up so much space on this Mac.

The interface tests now run on GitHub (`ci/ios-ui-tests`, on main). This branch moves the rest of the iPhone testing there, so that this Mac can drop its 7.5 GB simulator runtime.

## Start

- Make your branch at main **52b06e0a**: `git switch -c ci/ios-unit-tests 52b06e0a`. Check that `git log -1 --format=%h` prints `52b06e0a`.
- Read these first:
  - `AGENTS.md`, with its "Where things stood on November 11, 2026";
  - in `docs/developer/testing.md`: "Tests on GitHub Actions", "The two iOS test targets", and "In the simulator, sound tests run on GitHub only";
  - `Scripts/agents/run-ios-ui-tests.py` and `Scripts/agents/ios_ui_tests.py`, with their tests;
  - `TextMouthiOSTests/`;
  - in `TextMouthiOSUITests/`: `PlaybackUITests.swift`, `SearchUITests.swift`, `LargeTextUITests.swift`, and `audit` in `TextMouthUITestCase.swift`.
- Also read the reports of the branch that put the interface tests on GitHub, in the main checkout's `build/orchestrator/iosuitests/`: `iosuitests-report.md`, `iosuitests-fix-report.md`, and `iosuitests-check.md`.

## The work, in this order

1. **Run the 19 unit tests (`TextMouthiOSTests`) on GitHub.**
   - The iPhone job already builds them (`run-ios-build.py`, `build-for-testing`) but runs only `TextMouthiOSUITests`. Run them too, from the same build, in the same simulator: for every full suite, the phone area, and any request that names one of their classes.
   - One `xcodebuild test-without-building` for both bundles saves xcodebuild's start-up, 2 to 2.7 minutes. Use one, as long as the results still name each failed test by its bundle and class.
   - **The verdict.** A failed or missing unit test turns the iPhone job red and never changes the Mac tests' verdict. `judge`'s expected count must include the unit tests. Two of `IOSRuntimeTests`' four tests are inside `#if DEBUG`, so count what the Debug `build-for-testing` holds.
   - **The results.** `ios-ui-summary.txt`, the join, `run_suite.py --remote`, and a train's result each say how many unit tests and how many interface tests ran.
   - **Scripts before workflows.** Prefer changes to the scripts over changes to `.github/workflows/`.
     - The user may push main at any time. That switches on `github_run.py`'s guard, and then a workflow change can't run on TestBuild until it's on GitHub's main.
     - If you must change a workflow, say exactly what in your report.
2. **An End of heading test at the book's cover.**
   - **Why.** The comment on `PlaybackUITests.testAnEndOfBookTimerNamesItsStopAndCancelEndsIt` says End of heading "was tried first and is not used", and that why "is not known".
     - It is known and fixed in 0.4.6 (finding 3 of `iosuitests-review.md`, and the TODO entry "Version 0.4.6").
     - The timer took the heading after the cursor, which was at the image-only cover. Play starts past the cover, at that very heading, so the timer ran out at once.
   - **The test.** At the book's opening, choose "Stop at the end of this heading and start playing". Check that:
     - the book plays;
     - it is still playing a few seconds later (with a limit);
     - the Sleep Timer's value names the end of the heading, not "Off".
   - **The old test.** Keep the End of the book test's Cancel Timer check, and correct its comment.
   - **Proof.** Send a GitHub run of a proof-only branch with 0.4.6's fix taken out. Take out only the merge 5862bce0's changes under `TextMouth/ViewModels/`. The new test must fail there. Never merge that branch.
3. **Steady the Search sheet's audit.**
   - **What happened.** `SearchUITests.testTheSearchSheetPassesTheAudit` failed in run 43032983986 on 4 Dynamic Type findings, "Dynamic Type font sizes are partially unsupported":
     - the match count, "7 matches";
     - the "Search results" heading;
     - the "Use regular expression" switch;
     - the "Search text" field.

     The 3 full runs before it had none.
   - **The other sheets** pass `informing: .dynamicType` to their audits, which reports such findings without failing, because `LargeTextUITests` checks text sizes another way.
   - **First find out whether the findings are true:** does the Search sheet's text grow with Dynamic Type?
     - Read its code: `PhoneSearchSheet.swift` and `PhoneTextStyle`.
     - If `LargeTextUITests` doesn't cover the Search sheet, add it there.
   - **Then decide.** If the text grows, report Dynamic Type on the Search sheet as the other sheets do, with the reason in a comment. If it doesn't, fix the sheet so that it does. Say which in your report.
   - **The run's results.** That run's `ios-ui-result.xcresult` artifact holds the screenshots and trees, if GitHub still keeps it. It is untrusted: download it into a new folder of its own.
4. **Documentation.** This branch may edit Markdown:
   - in `docs/developer/testing.md`: "The two iOS test targets", "Tests on GitHub Actions", and "In the simulator, sound tests run on GitHub only";
   - `docs/developer/building.md`, where it says which iPhone tests run where;
   - the November 11 lines of `AGENTS.md`.
5. **What this Mac still needs (report only).** Once this works, say whether anything on this Mac still needs the iOS simulator runtime. Delete nothing: the orchestrator asks the user.

## Runs on GitHub

- **Send your own runs,** with `run_suite.py --remote` or `github_run.py`, from your worktree. Request no train.
- **One run at a time.** A push holds a lock until GitHub shows its run, and then waits for the run in front of it.
- **Waiting.** Wait for each run with one background `gh run watch <id> -R AERobertAI/TextMouth --exit-status`. Don't poll in a loop.
- **Keep runs short.** A request for the phone area runs faster than a full suite. Use full suites only to measure, and run two of the final tree at the end.
- **Keep a list** of every run: its link, minutes, and result.

## Pushing: what you may do, and what you may not

- **You may push to `TestBuild` only,** through `github_run.py` (which `run_suite.py --remote` uses).
- **Never push** to main or any other branch, never push a tag, and never delete a remote branch. The repository is public:
  - push only commits of tracked files;
  - push nothing from `build/`, `humanQuestions/`, or `humanReports/`;
  - push no secret.
- **Never change** the repository's settings, never start a workflow by hand, and never cancel a run you didn't start.

## The rule on sound

- A test that presses Play or types makes sound. It runs only where `TEXTMOUTH_UI_SOUND` is 1, and only `run-ios-ui-tests.py` sets it, which refuses to run anywhere but on a GitHub runner.
- Never run that script on this Mac, and never set the variable anywhere else. `test_run_ios_ui_tests.py` fails if a tracked file outside its list names the variable, so don't name it in new files.
- The unit tests must make no sound. Check that none of them plays or records anything.

## Checks

- **Python:** `python3 -I -B -m unittest discover -s Scripts/agents/tests` passes and leaves no `__pycache__` folder.
- **Swift:** type-check what you change, as `common.md` says.
  - `make typecheck-ios` covers the app's sources only.
  - For the iPhone test bundles, run `swiftc -typecheck` against the iPhone Simulator SDK, with the command in `testing.md`.
  - If you change a Mac test, run `make typecheck-tests REF=<commit>`.
- **On this Mac:** don't build the app, run a simulator, or run any test. GitHub runs them.
- **The train loop** is a background task of the orchestrator's. Don't stop or restart it, and don't touch its queue, the lock, or `build/orchestrator/train/`.

## Your report

Your final message is the report, 40 lines at most. Also save it as `build/orchestrator/iosunit/iosunit-report.md` in the main checkout. It holds:
- the branch, its tip, and its commits;
- each item above: what changed, and the test or run that proves it; for each new test, whether breaking what it checks fails it;
- the iPhone job's minutes and counts, unit tests and interface tests apart;
- each GitHub run, with its link, minutes, and result;
- what this Mac still needs for iPhone work;
- what you couldn't verify, and any workflow change only the user can push.

# The iPhone interface tests on GitHub, with playback and typing (November 10, 2026)

You are `iosuitests`, a Sonnet worker, on branch `ci/ios-ui-tests`. First read `common.md` beside this file and follow it, except where this brief says otherwise:
- your start commit;
- pushing to `TestBuild`;
- Markdown;
- trains;
- the rule on sound.

The user wrote, on November 10:

> It would be nice if the IOS interface tests could be moved to GitHub too I think. How much of the IOS build can be moved? ... I am just thinking sense the IOS tools take up so much space on this Mac.

And later, about the old rule that the interface tests never press Play or type:

> I don't remember saying the rule regarding no typing or playback on the simulator, I definitely think those should be tested on the IOS.

That rule was the orchestrator's, not the user's, and it is withdrawn.

## Start

- Make your branch at main **d79e7832** (version 0.4.5), not at the commit `common.md` names: `git switch -c ci/ios-ui-tests d79e7832`. Check that `git log -1 --format=%h` prints `d79e7832`.
- Read these first:
  - "Tests on GitHub Actions" and "In the simulator, never press Play and never type" in `docs/developer/testing.md`;
  - `.github/workflows/tests.yml`, its job `build the iPhone app`;
  - `Scripts/agents/run-ios-build.py`, and how `run_suite.py --remote` and `build-train.py` report its results;
  - `TextMouthiOSUITests/`: 26 tests in `LibraryUITests`, `ReaderUITests`, `SearchUITests`, `ScreenOrderUITests`, and `LargeTextUITests`, with `TextMouthUITestCase`;
  - `PhoneLaunchRequest`, with its launch variables;
  - the reports of the branch that built the iPhone job: `build/orchestrator/cisuite/cisuite-report.md`, `cisuite-fix-report.md`, and `cisuite-check.md` in the main checkout.

## Where things stand

- Every GitHub run builds the iPhone app and its UI-test bundle for the Simulator (`build-for-testing`) in the job `build the iPhone app`. The job first downloads the iOS 26.0.1 platform, which includes its simulator, in 3 to 4 minutes. It runs no test.
- The interface tests have run only on this Mac, in its iPhone 17 simulator, by hand. They type nothing and press no Play. Search in Book's tests fill the field through the debug-only `TEXTMOUTH_SEARCH_IN_BOOK` launch variable.
- GitHub's `macos-26` image also has iOS 26.2, 26.4, and 26.5 simulators, with iPhone 17s, for its newer Xcodes. This project builds with Xcode 26.0.1.

## The work, in this order

1. **Run the interface tests on GitHub.**
   - Every full suite runs `TextMouthiOSUITests` on the runner, from the bundle the iPhone job built (`test-without-building`). So does a request that names the phone area or a UI-test class.
   - Pick the simulator: an iPhone 17 on the downloaded iOS 26.0.1 runtime if it works. If it doesn't, say what does.
   - The results name each failed test, as the Mac's runs do. They appear in the run's summary, and in what `run_suite.py --remote` and a train report.
   - A failed interface test fails the iPhone job's verdict, never the Mac tests' verdict.
   - Keep the job within its limits, and report its minutes.
2. **Playback and typing.** The interface tests may now press Play and type. Add tests for:
   - typing a search into Search in Book, as a person types it. Where typing replaces `TEXTMOUTH_SEARCH_IN_BOOK`, remove that variable, unless something else needs it.
   - pressing Play and Pause in the reader: what VoiceOver would read on the button (its label, value, and traits) before and after;
   - the controls that act while a book plays, such as the skips and the sleep timer, where the spec says what they do.
   - Use a public-domain book the tests already send at launch. Never play Ogg through Apple's frameworks.
3. **Quiet on this Mac.** A test that presses Play or types runs only when an opt-in environment variable says it may make sound, as the user's rule on sound asks. Only the runner's script sets that variable. One helper in `TextMouthUITestCase` decides, and a skipped test says why.
4. **Documentation.** This branch may edit Markdown.
   - Rewrite "In the simulator, never press Play and never type" in `docs/developer/testing.md`, and "Never press Play" in `docs/developer/building.md`, to the new rule. Tests on GitHub press Play and type; on this Mac those tests are skipped unless the variable is set.
   - Also update `TextMouthUITestCase`'s comment, "Tests on GitHub Actions" with the new times, and AGENTS.md where it states the old rule.
5. **What this Mac still needs for iPhone work (report only).** Once the interface tests run on GitHub, say what this Mac still needs. In particular, say whether `make typecheck-ios` works without the iOS simulator runtime (read `Scripts/ios/typecheck.py`). Delete nothing: the orchestrator asks the user about the runtime.

## Runs on GitHub

- **Send your own runs,** with `run_suite.py --remote` or `github_run.py`, from your worktree. Request no train.
- **One run at a time.** A push now waits for the run in front of it.
- Wait for each run with one background `gh run watch <id> -R AERobertAI/TextMouth --exit-status`, and don't poll in a loop.
- **Keep runs short.** For the interface tests, a request for the phone area runs faster than a full suite. Use full suites only to measure, and run two of the final tree at the end.
- **Keep a list** of every run: its link, minutes, and result.

## Pushing: what you may do, and what you may not

- **You may push to `TestBuild` only,** through `github_run.py`.
- **Never push** to main or any other branch, never push a tag, and never delete a remote branch. The repository is public:
  - push only commits of tracked files;
  - push nothing from `build/`, `humanQuestions/`, or `humanReports/`;
  - push no secret.
- **Prefer script changes to workflow changes.**
  - The user may push main at any time. That switches on `github_run.py`'s guard, after which a tree whose `.github/workflows` or `.github/actions` differ from GitHub's main can't run on TestBuild.
  - If a push is refused for that reason, finish with the change in place, and say exactly which workflow change the user must push.
- **Never change** the repository's settings, never start a workflow by hand, and never cancel a run you didn't start.

## Checks

- `python3 -I -B -m unittest discover -s Scripts/agents/tests` passes, and leaves no `__pycache__` folder.
- Type-check the Swift you change, as `common.md` says (`make typecheck-ios` covers the UI-test target only if it says so; check).
- Don't build the app, run a simulator, or run any test on this Mac: GitHub runs them.
- The live train loop is a background task of the orchestrator's. Don't stop or restart it, and don't touch its queue, the lock, or `build/orchestrator/train/`.

## Your report

Your final message is the report, 40 lines at most:
- the branch, its tip, and its commits;
- each item above: what changed, and the test or run that proves it; for each new test, whether breaking what it checks fails it;
- the interface tests' minutes and counts on GitHub;
- each GitHub run, with its link, minutes, and result;
- what this Mac still needs for iPhone work;
- what you couldn't verify, and any workflow change only the user can push.

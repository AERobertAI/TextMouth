# The full suite on GitHub: clean, faster, and the iPhone app too (November 10, 2026)

You are `cisuite`, a Sonnet worker, on branch `ci/suite-clean`. First read `common.md` beside this file and follow it, except where this brief says otherwise: pushing to `TestBuild`, Markdown, and trains.

The user wrote, after reading how last night's GitHub runs went:

> Yes do the non hourly plan you described, and try getting the full sweet clean and faster on GitHub. the IOS also be built on GitHub or just the Mac ones?

The plan without the hour is done: trains now leave 5 minutes after a request. The rest is yours.

## Where things stand

- **The workflow.** `.github/workflows/test-build.yml` runs on a push to `TestBuild`. It has a Linux plan job, up to four macOS shards (`macos-26`, Xcode 26.0.1), and a Linux join. Its concurrency group cancels an older run when a newer push comes.
- **The Mac's side.**
  - `Scripts/agents/github_run.py` pushes and fetches.
  - `run_suite.py --remote COMMIT NAME LOG` sends a full suite, and `build-train.py --remote` sends trains.
  - The runner runs `Scripts/agents/run-on-runner.py`, with `test_command.py`, `shard.py`, `plan_shards.py`, `merge_shards.py`, `class_times.py`, `restore_mtimes.py`, and `runner-skips.conf`.
- **Reports** of the branch that built all this, in `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/`: `ci-report.md`, `ci-fix-report.md`, `ci-review.md`, `cicheck-report.md`.
- **Times**, from the 21 runs of November 9 and 10:
  - a machine starts each job within 2 to 5 seconds;
  - setup takes about 30 seconds;
  - the build takes about 1.5 minutes from the saved build, and about 9 from scratch;
  - a full suite's tests take 5.5 to 7 minutes on each of the four machines, and the whole run takes 11 to 16 minutes from the saved build. Hung tests and uneven shards make up the gap.
- **The last full suite**, run 42781458092 (November 10, 03:17), failed on four tests:
  - `OfficeXMLGuardTests.testCancelLandsInTheMiddleOfARead`: 2.21 seconds against its 2.0 limit;
  - `OwnReaderCancellationTests.testCancelPartwayThroughALargeWordDocumentIsHeardAtOnce`: 1.90 against 1.5;
  - `AudioEngineBehaviorTests.testReportWhilePausedShortOfTheEndIsNotFinishedOnResume`: its 5-second wait ran out;
  - `EpisodeDownloadContinuationTests.testACancelAfterTheListenerPlayedAgainSaysNothing`: it ran past its 2-minute allowance.
- **Train 1110-0219** (run 42774453623) failed with no failed assertion: `ReadingListReaderTests.testABookOffTheListByItsClaimIsNotReadFromIt` ran past its 2-minute allowance.
- **On this Mac all of these pass.** 0.4.4's full suite ran 11,962 tests, with 0 failures.
- **Skips.** `runner-skips.conf` leaves out about 145 tests on the runner, each with its reason, and this Mac still runs them.
- **Check on main.** The older workflow `.github/workflows/check.yml` is the reproducibility gate (`make check`, `Scripts/check.sh`), run on each push to main. It runs the whole suite on one machine, and run 42765562754 was cancelled at its 60-minute limit.
- **No iPhone check on GitHub.** A train on this Mac runs the iOS census (`ios_census` in `build-train.py`). A remote train doesn't, so today no train checks the iPhone app.

## The work, in this order

1. **One run never cancels another.**
   - Trains now leave 5 minutes after a request, so one could cut off a full suite sent by hand.
   - Before it pushes, `github_run.py` waits, up to a limit, while a TestBuild run is queued or in progress.
   - The Mac's own senders take turns, so two can't push at once. They are the train loop, `run_suite.py --remote`, and you.
   - A wait that reaches its limit fails as a failed push does: with a sentence that says why, and nothing left half done.
   - Tests go in `Scripts/agents/tests`, with the fake `gh` they already use.
2. **Clean.** Find what causes each failure above, and fix it at its cause.
   - **Timing.** A limit that holds on this Mac fails on the runner, which is slower. The test must check the same promise on both machines.
     - Prefer a measure relative to the machine over a looser number: for instance, the same work uncancelled, on the same machine.
     - If a scale factor is the only way, one helper that every timing test shares reads it. Only the runner's script sets it, and the docs say what it changes.
     - Never loosen a limit on this Mac.
   - **Hangs.** A test past its allowance waits on something with no limit.
     - Xcode captures a spindump of a test that runs past its allowance and keeps it in the result bundle, which the workflow uploads for a failed run. Read the stacks with `xcrun xcresulttool`, and find what blocks.
     - If what blocks is in the app, not the test, a listener could hang too. Report it with its stack. Fix it only if the fix is small and plainly safe.
   - **Audio.** The runner's audio service is restarted on every run. A test that can't work on the runner goes in `runner-skips.conf`, with its reason, and still runs on this Mac.
   - **Proof.**
     - For each fix, show that breaking it fails the test, in one of the ways `common.md` gives.
     - Run each fixed class on GitHub at least three times.
   - **No retry hides a flake.**
     - Retry a test only when its cause is fixed and it still fails now and then, on the runner alone.
     - The report names every retried test and its first failure.
     - This Mac never retries.
   - **At the end,** three full suites in a row must be clean on GitHub.
3. **Faster.** Aim for a clean full suite in about 10 minutes from the push, with the saved build. First measure where the time goes. Then try, for example:
   - balancing the shards by the recorded class times (`class_times.py`);
   - a fifth shard: GitHub runs 5 macOS jobs at once for this account, so a train or a Check run would then wait for a free machine;
   - building once and sharing the products, if fetching them beats building on each machine.

   Keep each test's 2-minute allowance until the hangs are gone. Report the minutes each change saves.
4. **The iPhone app on GitHub.** Every train and full suite also builds the iPhone app (`TextMouthiOS`) and its UI-test bundle (`TextMouthiOSUITests`) for the iOS Simulator.
   - There's no signing, and the UI tests aren't run.
   - The results of a train and of `run_suite.py --remote` show its errors by file, as a Mac train's census does.
   - Keep it off the longest path where you can, and report what it adds to a train and to a full suite.
   - If the runner image lacks what the build needs, say so.
   - Prove the train's side with the train's tests on a downloaded result. The orchestrator's first train after the merge proves it end to end.
5. **Check on main.** `check.yml` must finish within its limit, and keep every check it makes:
   - the project regenerated;
   - the package pins;
   - the Release build, with no Swift warning, and the app's size;
   - the suite, with no Swift warning and strict performance baselines.

   Run its suite through the same shards and skips as TestBuild, for instance with a reusable workflow that both call, so the suite has one way to run. You can't push to main, so prove the shared part through TestBuild, and say in your report what only a push to main will show.
6. **Documentation.** Say what changed, the new times, and that trains leave on request. This branch may edit Markdown.
   - "Tests on GitHub Actions" in `docs/developer/testing.md`;
   - `docs/developer/building.md`;
   - `AGENTS.md`;
   - "Making each train count" in `docs/agents/working-with-agents.md`.

## Runs on GitHub

- **Send your own runs,** with `run_suite.py --remote` or `github_run.py`, from your worktree. Request no train: the loop's trains merge other branches with yours.
- **One run at a time.**
  - Until item 1 is in your tree, check that no TestBuild run is going before you push: `gh run list -R AERobertAI/TextMouth --branch TestBuild --limit 3`.
  - Wait for each run with one background `gh run watch <id> -R AERobertAI/TextMouth --exit-status`, or with the wait in `github_run.py`. Don't poll in a loop.
- **Keep runs short.** Use class and area runs for quick checks. Save full suites for measuring and for the last three.
- **Keep a list** of every run: its link, minutes, and result.

## Pushing: what you may do, and what you may not

- **You may push to `TestBuild` only,** through `github_run.py`, or as `git push --force --no-follow-tags origin <commit>:refs/heads/TestBuild`.
- **Never push** to main or any other branch, never push a tag, and never delete a remote branch.
- **The repository is public:** everything you push is published.
  - Push only commits of tracked files, as git makes them.
  - Never push a file from `build/`, `humanQuestions/`, `humanReports/`, or anything else the user keeps private.
  - Never push a secret.
- **Workflow changes.**
  - Once `test-build.yml` is on GitHub's main, `github_run.py` refuses a tree whose `.github/workflows` differs from origin's main.
  - It isn't there yet, and the user has been asked to hold their push of main until your branch merges.
  - If a push is refused for this reason, stop changing workflows, and say so in your report.
- **Never change** the repository's settings, its Actions permissions, or its secrets.
  - Never start a workflow by hand (`gh workflow run`), and never cancel a run you didn't start.
  - If something only the user can change is needed, say so in your report.

## Checks

- `python3 -I -B -m unittest discover -s Scripts/agents/tests` passes, and leaves no `__pycache__` folder.
- Don't build the app or run the hosted suite on this Mac: GitHub runs them. Type-check the Swift you change, as `common.md` says.
- The live train loop is a background task of the orchestrator's. Don't stop or restart it, and don't touch its queue, the lock, or `build/orchestrator/train/`. The orchestrator restarts it after merging your branch.

## Your report

Your final message is the report, 40 lines at most:
- the branch, its tip, and its commits;
- each item above: what changed, and the test or run that proves it; for each fix, whether breaking it fails a test;
- the time of each part, before and after;
- each GitHub run, with its link, minutes, and counts, including the three last full suites;
- what you couldn't verify, and anything only the user can do.

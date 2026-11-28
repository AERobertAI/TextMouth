# Builds and tests on GitHub Actions (November 9, 2026)

You are `ci`, a Sonnet worker, on branch `ci/github-actions`. First read `common.md` beside this file and follow it, except where this brief says otherwise: your start commit, and pushing to `TestBuild`.

The user, finding the builds hard on their Mac's CPU, wrote:

> I had the idea to take the build preassure off my Mac using GitHub Actions (maybe in a special "TestBuild" branch that you could commit and push too. I made the repo public and transferred it to a organization for my AI assisted projects ... please try having some agents ... try to move the testing and compiling to a GH actions workflow and test it out... not sure if your a able to download the resultant ardifacts but lets try, we can start with keeping to hour builds but can decrease that or meven make it no schedule based if we can get it easily.

- **The repository** is public at `github.com/AERobertAI/TextMouth`. `origin` is `git@github.com:AERobertAI/TextMouth.git`.
- **`gh`** is signed in, with admin rights, and Actions is enabled.
- **This Mac** has Xcode 26.0.1 on macOS 26.3.1. The Mac app's deployment target is macOS 14.0, and the iPhone app's is iOS 26.0.

## Start

- Make your branch at main: `git switch -c ci/github-actions 94b80209`, and check that `git log -1 --format=%h` prints `94b80209`.
- Read these first:
  - `Scripts/agents/build-train.py`: how a train merges requests, regenerates the project, builds and runs the tests (`run_tests`), reads a log (`summarize`), and reports.
  - `Scripts/agents/run_suite.py`, the orchestrator's full suite before a merge.
  - The Makefile's `test` target and the runner it calls.
  - `docs/developer/testing.md` (the areas, the hosted suite) and `docs/developer/building.md`.
  - `project.yml`.

## The goal

The hourly train, and the orchestrator's full suite, build and test on GitHub's macOS runners instead of this Mac. The Mac only merges, pushes, waits, and reads the results.

## The work, in this order

1. **A workflow**, `.github/workflows/test-build.yml`.
   - **Triggers:** a push to the branch `TestBuild` only. Nothing from pull requests or forks, and never `pull_request_target`.
   - **Permissions and actions:** `permissions: contents: read`, and no secrets. Use only GitHub's own actions (`actions/checkout`, `actions/cache`, `actions/upload-artifact`), pinned.
   - **The runner:** a free macOS runner with Xcode 26. Check GitHub's runner-images documentation for what each image holds. If no free runner has an Xcode that builds this project, say so, and stop after this step.
   - **What it runs:**
     - It installs xcodegen and generates the project as `make generate` does.
     - It builds once, then runs the tests that a request file in the pushed tree names: a train's classes and areas, or the whole suite.
     - Use the same test command the train and `run_suite.py` use, from one place all three call, not a copy.
     - Ad-hoc signing, since there is no identity on the runner.
   - **Artifacts:** it uploads the test log and a short summary, kept a few days. Upload the result bundle too, but only on failure or if it is small.
   - **Limits:** a time limit on the job. One run at a time on `TestBuild`; a newer push cancels an older run.
2. **Prove it by hand.**
   - Push a commit of your branch to `TestBuild` with a request for two or three small areas. Wait for the run, download its artifacts with `gh run download`, and check that `summarize` reads its log.
   - Then run the whole suite, and compare its counts with the last local full suite: 11,853 tests, 81 skipped, 0 failures, on main e0ea3b9d.
   - Name every test that fails on GitHub but passes here, with the cause: no voice, a missing tool, a permission, timing.
   - Report each run's minutes, from the push to the downloaded artifacts.
3. **The train on GitHub.** In `build-train.py`, a way to run a train remotely: an option of `run` and `loop`.
   - **What it does:**
     - it merges the requests as now, and commits the request file;
     - it pushes the merged commit to `TestBuild` with `--force`;
     - it waits for that commit's run, found by its SHA, with a limit;
     - it downloads the artifacts into the train's folder, and reports from the log as a local train does.
   - **The lock:** the remote part takes no heavy-work lock, since it doesn't load the Mac.
   - **When something fails:** if the push or the run fails, the train tells each agent so and leaves nothing half done. Its requests wait for the next train.
   - **Tests** in `Scripts/agents/tests`, with a fake `git push` and a fake `gh`, on the throwaway repository the train's tests already use.
4. **The orchestrator's full suite on GitHub:** a way to send a branch's tree for a full run and read its verdict as `run_suite.py` does, as an option of `run_suite.py` or a small script beside it.
5. **Without the schedule, as an option.** Since a remote train costs the Mac nothing, the loop may send one a few minutes after a request comes, instead of on the hour. Add it as an option and leave the loop's default hourly. The orchestrator turns it on once the remote trains are proved.
6. **Documentation:** update `docs/developer/testing.md`, `building.md`, `AGENTS.md`, and "Making each train count" in `docs/agents/working-with-agents.md`, so they say what runs where and how to read a remote run. This branch may edit Markdown.

## Pushing: what you may do, and what you may not

- **You may push to `TestBuild` only:** `git push --force origin <commit>:refs/heads/TestBuild`.
- **Never push** to main or to any other branch, never push a tag, and never delete a remote branch.
- **The repository is public:** everything you push is published.
  - Push only commits of tracked files, as git makes them.
  - Never push a file from `build/`, `humanQuestions/`, `humanReports/`, or anything else the user keeps private.
  - Never push a secret.
- **Never change** the repository's settings, its Actions permissions, or its secrets. If something only the user can change is needed, say so in your report.

## Checks

- `python3 -I -B -m unittest discover -s Scripts/agents/tests` passes, and leaves no `__pycache__` folder.
- Don't build the app or run the hosted suite on this Mac: GitHub runs them. A type-check is fine if you change Swift, but this work should change none.
- The live train loop is a background task of the orchestrator's. Don't stop or restart it, and don't touch its queue, the lock, or `build/orchestrator/train/`. The orchestrator switches it to remote trains after merging your branch.

## Your report

Your final message is the report, 40 lines at most:
- the branch, its tip, and its commits;
- each GitHub run: its link, minutes, and counts;
- what fails on GitHub that passes here, and why;
- what you couldn't verify;
- anything only the user can do, such as a setting.

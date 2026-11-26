# Orchestrating TextMouth's agents
<!-- id: orchestrating-textmouth-agents; keys: no-ff, merge train, handoff, sub-orchestrator, set-version; src: Scripts/agents/merge-chain.sh, Scripts/agents/build-train.py, Scripts/agents/record-merge.py -->

Part of [working on TextMouth with coding agents](../../AGENTS.md).

## Every launch names its model
<!-- id: every-launch-names-model; keys: model override, Sonnet, Opus, Fable, effort high, weekly window, launch message, worktree isolation; src: Scripts/agents/usage-watch-unscoped.py -->

**Every launch names its model, Sonnet by default.**
Workers, verifiers, documentation passes, and narrow fixes run on Sonnet at high effort (`model: "sonnet"`, `effort: "high"`), and Opus (`model: "opus"`) is kept for the lead of a large design and the first outside review of a big or risky branch.
Every launch also passes `subagent_type: "general-purpose"` and `isolation: "worktree"`; an agent launched without a model override inherits the orchestrator's model and spends that model's weekly window.
The orchestrator, on Fable, writes the briefs, reads each report and diff, decides, merges, and records; it uses a Fable agent only when the user asks for one.
Briefs are kept in `Scripts/agents/briefs/<date>/` (stage with `git add -f`), never only in the session's scratch folder, so the next session can launch from them.
The orchestrator itself may run on Opus too; the launches still name the model.
The usage script's `binding` window can then be a weekly cap scoped to one model, such as "Weekly (Fable)", which Opus work does not count.
Read only the unscoped windows ("5-hour session", "Weekly (all models)"), watch them with `Scripts/agents/usage-watch-unscoped.py <left%>` as a background task, and say in every launch message that the scoped window does not apply, or an agent following the usage rule stops at once.

## One brief per task
<!-- id: one-brief-per-task; keys: brief, wave, launch message, origin/main, shared contract, core branch, issuelib assign; src: .claude/skills/issue-library/scripts/issuestore.py -->

- One brief per task, written to `Scripts/agents/briefs/<date>/` and pointed at from the launch message;
- it names the branch the agent makes its own from (local main or the team branch, by name), since a worktree starts at origin/main, which can be far behind local main;
- the user's decisions quoted in the brief in their own words;
- the issue the agent works on, named in the brief, assigned to it on main and committed before the launch (`issuelib assign ID AGENT --branch BRANCH --as orchestrator`), since a branch made before the assignment may not touch the issue until it rebases;
- waves of three to five agents whose file regions do not overlap, with a shared contract or a first "core" branch when they must share types.

## After an agent reports
<!-- id: after-agent-reports; keys: merge message, worktree remove, unregister, DerivedData-main, flaky test, rerun, AGENT-NOTES; src: Scripts/agents/merge-chain.sh, Scripts/agents/record-merge.py, TextMouthProductionTests/BookmarkKeyboardAccessTests.swift, TextMouthProductionTests/StorageGenerationMoveTests.swift, TextMouthProductionTests/BookSearchModelTests.swift, TextMouthProductionTests/DataDirectoryMoveTests.swift, TextMouthProductionTests/ViewsAndWindowsReaderSheetTests.swift, TextMouthProductionTests/FeedDownloadTests.swift, TextMouthProductionTests/MacBrailleTableCheckTests.swift -->

After an agent reports:
- write the merge message to a file;
- note the agent's unverified items and its documentation wording where the next documentation pass will find them (`AGENT-NOTES-2026-10-04.md` is the current such file);
- then run `Scripts/agents/merge-chain.sh <branch>:<message-file>` in the background;
- on a green suite, record the merge in the TODO with `Scripts/agents/record-merge.py`:
  - it puts the merge's `- [x]` entry before the paragraph that begins `**Open follow-ups noted by the September 28 agents**`;
  - it appends a sentence with the suite's exact counts to the long verification paragraph, after the latest "After the … merge: **N tests, S skipped, 0 failures**";
  - it appends open items to the paragraph that begins `**Open follow-ups noted on October 3 afternoon and evening**`;
  - `--note` in place of `--counts` is for a merge that ran no suite, and `--tick FR09 --hash <merge>` ticks an entry still in the TODO;
  - `--close B16 --hash <merge>` closes the issue B16, its file in `Issues/`, at the merge and ticks its pointer line in the TODO;
- commit the TODO, with the issue files `--close` changed in `Issues/`;
- remove the agent's worktree (`git worktree remove --force --force` and `git worktree prune`);
- unregister and delete `build/DerivedData-main` when the disk is tight;
- and post `merged: <branch>` on the board with the new counts so the other agents rebase.

A suite that fails only in a load-sensitive test is rerun on that class alone before the merge stands.
The load-sensitive tests are:
- the sleep-timer integration tests;
- `BookmarkKeyboardAccessTests`;
- `StorageGenerationMoveTests`;
- `BookSearchModelTests.testCancelledSearchPublishesNothing`;
- `DataDirectoryMoveTests.testAMoveShowsItsProgressWhileItCopies`;
- the reader-sheet redraw count in `ViewsAndWindowsReaderSheetTests`;
- the resume-data test `FeedDownloadTests.testADownloadThatStopsPartwayGoesOnFromWhereItStopped`;
- the audiobook-open benchmark;
- `MacBrailleTableCheckTests.testFrenchGermanAndSpanishPassAndRoundTrip` (its reading of the braille helper's memory can miss three short runs);
- and the performance baselines, which skip while the Mac is busy.


## When an issue file stops a merge
<!-- id: issue-file-stops-merge; keys: ISSUES_CHECK_FAILED, merge driver, conflict markers, issues-merge-driver, issuelib check; src: Scripts/agents/merge-chain.sh, .claude/skills/issue-library/scripts/issuemerge.py, Makefile -->

`make issues-merge-driver`, run once in the main checkout, defines the merge driver that every worktree and the train's use for `Issues/*.md`; without it an issue file merges as text.
Two things can still stop a merge at an issue file:
- A conflict: one header field, one description line, or one older comment changed both ways.
  The chain aborts it as it aborts any conflict (`UNMERGED` in its log), so merge that branch by hand with `git merge --no-ff --no-commit <branch>`.
  Between git's markers `current` is main and `other` the branch: keep the right line, delete the markers, and run `issuelib check`, which also names a comment whose line count no longer matches its text.
  Then commit, and start the chain again with the branches after it.
- `ISSUES_CHECK_FAILED`: `issuelib check` found a problem on the merged tree that main did not have, in a file the merge changed, and the chain prints each.
  A problem main already had, or one in a file the merge left alone (an issue citing a doc section the branch renamed), does not stop it, and the next `issuelib check` on main names it.
  Fix it on the branch and merge again, or fix it in the merge commit by hand.

## Questions for the user
<!-- id: questions-user; keys: humanQuestions, Answer line, recommended answer, numbered questions; src: -->

Questions for the user go into a new file in `humanQuestions/` for each session or batch, so the user can answer while away and the answers are kept:
- each question numbered, with its context in a sentence or two, a recommended answer, and an `Answer:` line for the user;
- an optional "Answer for the whole section:" line;
- and an "Answered this session" section quoting the answers already given in chat.

Say in chat which file holds new questions.
When acting on an answer, record the decision in the TODO with the user's words, as before.

## A documentation pass
<!-- id: documentation-pass; keys: docs agent, Markdown-only merge, no build, doc-library; src: -->

A documentation pass is its own agent (no build) that edits only the documentation (README.md, ARCHITECTURE.md, and the pages under docs/) from the merged code and the agents' wording, one commit per documented branch.
It runs `doclib check`, which names each section whose marker still cites an issue that has closed, and updates those sections.
It is merged without a suite as a Markdown-only merge and recorded in the TODO with a sentence.

## The docs' checks
<!-- id: docs-checks; keys: make lint-docs, lint baseline, rebuild-baseline, ratchet, doclib; src: Makefile, Scripts/agents/merge-chain.sh, .claude/skills/doc-library/scripts/doclib.py -->

**The docs' checks:** before each fast-forward of main, run `make lint-docs` on the merged tree.
After each docs merge, run `python3 -I .claude/skills/doc-library/scripts/doclib.py lint --update-baseline`.
When main's docs changed under a branch, run it with `--rebuild-baseline` instead, which only the orchestrator runs because it can raise a count.
`Scripts/agents/merge-chain.sh` also runs the issue tracker's check on each merged tree before it commits, as a ratchet by file: it fails only on a problem that is new and in a file the merge changed ([When an issue file stops a merge](#when-an-issue-file-stops-a-merge)).
It runs the interface-text lint (`scan.py lint --base HEAD`) too, aborting the merge on `L10N_LINT_FAILED`, and on success lowers `Scripts/l10n/scan-baseline.json` into the merge itself ([The scanner's lint](../developer/localization.md#the-scanners-lint)).

## The end of a campaign
<!-- id: end-campaign; keys: Where things stand, hand-over, campaign, history.md; src: AGENTS.md, docs/agents/history.md -->

**The end of a campaign:** move `AGENTS.md`'s `Where things stand` to the top of `docs/agents/history.md` as `## Where things stood on <date>`.
Then write a new `Where things stand` of at most 1,400 bytes, without dates.

## Reading an agent's report
<!-- id: reading-agent-report; keys: transcript, subagent, last message, extract-report; src: Scripts/agents/extract-report.py -->

**Reading an agent's report:** `Scripts/agents/extract-report.py <transcript> [max_chars]` prints a subagent transcript's last message.

## The version
<!-- id: orchestrator-version; keys: bump-patch, bump-minor, set-version, changelog, annotated tag, MAJOR MINOR PATCH; src: Scripts/set-version.sh, Makefile, docs/user/changelog.md -->

**The version.**
The user's rule is one bump for each day on which main gains bug fixes or small backward-compatible features.
After the day's last merge, and before the user's next install, run `make bump-patch`.
Run `make bump-minor` instead when that day holds a change that is not backward compatible (an older TextMouth cannot open the library, every book is read again, a stored format changes, or a setting, shortcut, or file is removed or renamed).
- Commit the bump on its own;
- add the day's dated section to the top of `docs/user/changelog.md` with one plain sentence per change (a MINOR section first says what an older TextMouth can no longer do with the library);
- tag the commit the user is to install as `vX.Y.Z` with an annotated tag (the orchestrator pushes tags only at a stable release, with main, as AGENTS.md says);
- run `make release-goldens` before the user installs, and after a change to the Release build settings (`Scripts/size_settings.py`), through `Scripts/agents/run_locked.py` while other agents work ([The Release golden tests](../developer/building-release.md#the-release-golden-tests)).
  On a Mac it tests the light profile; the full build's golden tests wait for a GitHub job (TL22);
- never build the full profile on the Mac (`make install`, `make release`, `SIZE_PROFILE=full`): its link takes several GB of memory and once froze the user's Mac, and installing is the user's;
- never run `make install-ios` or its script without `--dry-run`: it signs with the user's Apple ID and installs on their iPhone, and is the user's;
- and record the bump in the TODO.

MAJOR stays 0 until the user calls TextMouth released.
Versions in `docs/developer/building.md` has the rules and the cases they leave open.

## Builds go through the build train
<!-- id: builds-go-through-build-train; keys: freeze, 8 GB, hourly build, pooled builds, CPU; src: Scripts/agents/build-train.py -->

**Builds go through the build train.**
The Mac has 8 GB of memory and froze under the agents' own builds, so agents do not build on their own: builds go one at a time, on a schedule, with the agents' work pooled into each.

### Start the train
<!-- id: start-train; keys: loop, release flag, hold slots, --remote, --soon, heavy-work lock; src: Scripts/agents/hold-build-slots.sh, Scripts/agents/build-train.py, Scripts/agents/heavy_lock.py, Scripts/agents/run_locked.py, Scripts/agents/run_suite.py -->

**Start it.**
While agents work, the orchestrator runs two background tasks.
`Scripts/agents/hold-build-slots.sh <release flag>` holds every build slot, so no agent builds on its own.
`python3 -I Scripts/agents/build-train.py loop --hours <N>` runs a train every hour, on the hour; with `--remote` the trains build and test on GitHub Actions instead of this Mac (see **Builds on GitHub** below), and `--remote --soon <minutes>` sends one that many minutes after a request comes.
Run it with `--base main`, so each train tests a branch merged onto main's tip, as its merge will be: the default base, `train/base`, can be an old commit, which tests each branch without main's newer commits.
Every heavy job takes the heavy-work lock (`Scripts/agents/heavy_lock.py`), so one runs at a time: the trains, the type-checks, `run_suite.py`, and anything run through `run_locked.py`, simulator runs included.
The jobs that wait go first come, first served: a waiting job takes a ticket in `heavy-lock-line/` beside the lock, and takes the lock only when no live older ticket remains; the train's first-in-line mark still goes ahead of every ticket.

### The helper scripts
<!-- id: helper-scripts; keys: heavy lock, exit status, xcodebuild, pbxproj, make generate; src: Scripts/agents/run_locked.py, Scripts/agents/run_suite.py, Scripts/agents/copy_phases.py, Scripts/agents/regenerate-project.py -->

**The helpers** are in `Scripts/agents/`, each found from its own location, so they work from any checkout.
`python3 -I Scripts/agents/run_locked.py NAME COMMAND...` runs one command under the lock and exits with its status.
`python3 -I Scripts/agents/run_suite.py NAME LOG` runs the full hosted suite under the lock from the checkout to test (as a background task), ends an xcodebuild that outlives its tests, prints the log's Executed line, and exits 0 only when every test passed.
`run_suite.py --remote COMMIT NAME LOG` runs the same suite on GitHub for COMMIT's tree, takes no heavy-work lock, writes the run's log to LOG, and judges it the same way (exit 4: the push or the run failed, not the tests; exit 3: a train held TestBuild throughout).
It also measures the iPhone app's size, as the release check; `--no-ios-size` after COMMIT leaves that out for a merge's gate, whose branches each measured it on their last train, and ends about 14 minutes sooner.
`python3 -I Scripts/agents/copy_phases.py A.pbxproj B.pbxproj` says whether two projects copy the same files to the same places.
`Scripts/agents/regenerate-project.py` is what `make generate` runs.
Their tests are in `Scripts/agents/tests`.

### An agent's part in a train
<!-- id: agent-part-train; keys: request, classes, areas, results file, wait-for-result; src: Scripts/agents/build-train.py, Scripts/agents/wait-for-result.py -->

**An agent's part.**
It commits, then queues `build-train.py request --agent <name> --branch <branch> --classes <A,B> --areas <x,y>`.
It waits for its board message or for `build/orchestrator/train/results/<name>.md`.
The train tests the commit the branch was at when the agent asked, so an agent that commits a fix before the train leaves asks again; the newest request for a branch wins.
Every brief points the agent at Making each train count, in `docs/agents/working-with-agents.md`.

### What each train does
<!-- id: what-each-train-does; keys: train/base, lock queue, conflict, summary.md, free disk, run-area; src: Scripts/agents/build-train.py, Scripts/agents/heavy_lock.py, Scripts/test/run-area.py -->

**Each train:**
- it waits for the heavy-work lock first in line, ahead of every ticket, so no other job takes the lock before it, for up to 50 minutes, and never runs without it; a train that waited in vain leaves its requests queued for the next one and tells the orchestrator who held the lock;
- it then takes every waiting request, those made while it waited included, and merges the commit each one names onto `train/base` in `.claude/worktrees/train`, leaving out a branch that conflicts anywhere but project.pbxproj and telling its agent;
- it builds once, with two jobs.
  If the build fails to compile only in files some merged branches change, it builds again without those branches, and merges again, in the order of the requests, every branch it had left out for a conflict: one that now merges cleanly is taken back, and the summary says so;
- it runs the union of the tests asked for, dropping and reporting any name `Scripts/test/run-area.py` does not know;
- it writes `build/orchestrator/train/trains/<id>/summary.md`;
- it waits for the next hour while under 3 GB is free.

### An integration's full suite
<!-- id: integration-full-suite; keys: integration branch, train/base, --areas all, summary file; src: Scripts/agents/build-train.py -->

**An integration's full suite.**
Point `train/base` at the integration branch, then queue `--agent orchestrator --branch <integration> --areas all`.
The loop does not exit when a train ends, so wait for that summary with a background task that exits when the file appears.

### Look at the train and finish
<!-- id: look-at-train-finish; keys: status, release flag, stop the loop, queue, heavy_lock status; src: Scripts/agents/build-train.py, Scripts/agents/hold-build-slots.sh, Scripts/agents/heavy_lock.py -->

**Look and finish.**
`build-train.py status` shows the next train, what a running train is doing (waiting for the lock and for whom, or which branches it builds), and the queue.
`python3 -I -B Scripts/agents/heavy_lock.py status` prints the lock's holder and how long it has held it, the first-in-line mark, and the line of waiting jobs in order; it changes nothing.
When the agents are done, stop the loop and `touch` the release flag.

### Builds on GitHub
<!-- id: builds-github; keys: TestBuild, GitHub Actions, runner, shard, force push, runner skips, workflow guard; src: .github/workflows/test-build.yml, .github/workflows/tests.yml, .github/workflows/check.yml, Scripts/agents/build-train.py, Scripts/agents/run_suite.py, Scripts/agents/github_run.py, Scripts/agents/test_command.py, Scripts/agents/run-on-runner.py, Scripts/agents/shard.py, Scripts/agents/merge_shards.py, Scripts/agents/restore_mtimes.py, Scripts/agents/runner-skips.conf, Scripts/agents/run-ios-build.py -->

**Builds on GitHub.**
The testing and compiling can run on GitHub Actions instead of this Mac's CPU.
`.github/workflows/test-build.yml` runs only for a push to the branch `TestBuild` of the public repository (`AERobertAI/TextMouth`), with a read-only token, no secrets, and GitHub's own pinned actions.
A remote train (`build-train.py run --remote`, or `loop --remote`) merges the requests here as always, then pushes the merged tree plus `.github/test-request.json` to `TestBuild` with `--force`.
Nothing else is ever pushed (`Scripts/agents/github_run.py` builds the refspec itself and refuses a tree holding a path under `build/`, `humanQuestions/`, or `humanReports/`).
It waits for that commit's run, found by its SHA, for up to 125 minutes, downloads the run's artifact into the train's folder (`run.log`, `run-summary.txt`, `remote-N/`), and reports from it exactly as a local train does.
The test command is made in one place, `Scripts/agents/test_command.py`, which the local train, `run_suite.py`, and the runner script (`Scripts/agents/run-on-runner.py`) all call.
A remote train takes no heavy-work lock, skips the disk check and the iOS census, and shares the train's own lock with a remote suite, since a newer push to `TestBuild` cancels the older run.
If its push or run fails, it puts every request back in the queue, tells each agent and the orchestrator, and the loop waits 15 minutes before the next try.
A lost connection is only a missed poll, and the next train collects a run this one could not (see [A remote train and a lost connection](../developer/testing-tools.md#a-remote-train-and-a-lost-connection)).
Restart the loop between trains (`status` says "running now: no"): killed while a train is on GitHub, its requests are stranded in its folder with no record.
A long request runs as up to four parallel jobs (`Scripts/agents/shard.py` deals the classes out; `merge_shards.py` joins the results into the one artifact the Mac reads), and build products are cached between runs (`restore_mtimes.py`).
A cache made on another runner image is emptied by a toolchain stamp, and its build is tried once more ([A cache made on another runner image](../developer/building-ios.md#a-cache-made-on-another-runner-image)).
When the only errors of a train's iPhone build are cache failures, "has been modified since the module file" or "module file ... not found" (retried from an empty folder), its summary says the module cache failed the build, not the branch's code, so nobody chases a file for it.
The full suite takes about 26 minutes, the iPhone job being the longest part (80 without finishing before the tuning).
The runner cannot start the audio engine and has other limits, so `Scripts/agents/runner-skips.conf` lists the 14 entries (of about 12,470 tests) it does not run, each with its reason.
Each remote result says which of an agent's requested tests were among them ("Not run on GitHub, no verdict").
A remote suite is therefore not the last check before a release: run those on this Mac too, with a local `build-train.py run`, which takes the heavy-work lock.
A push to `TestBuild` also refuses a tree whose `.github/workflows/` or `.github/actions/` differs from origin's main, once origin's main holds `test-build.yml`.
Origin's main has held it since 0.4.10 (a1214dc0): **the guard is on**, so a workflow or action change runs on `TestBuild` only after it is on GitHub's main.
A push waits, up to 125 minutes, while another run is queued or going on `TestBuild` (a newer push cancels the older run), and fails, pushing nothing, if the branch stays busy; so a train, a remote suite, and a hand-sent run take turns, and a train leaves 5 minutes after a request.
The jobs are in `.github/workflows/tests.yml`, which `test-build.yml` (a push to `TestBuild`) and `check.yml` (main and pull requests) both call, and each run also builds the iPhone app and its UI-test bundle for the iOS Simulator (`Scripts/agents/run-ios-build.py`).
A train's result and `run_suite.py --remote` list its errors by file, and the iPhone build's errors never change the tests' verdict.
The train's verdict does count the iPhone tests ("FAILED (iPhone tests)"), and the board post counts the agent's Mac and iPhone failures apart.
A test that fails on the runner with a timing, and passes here, is flaky there, not a reason to raise its limit or add it to the list.
Testing TextMouth (Tests on GitHub Actions) has how to read a run, what differs from the Mac, and the flaky tests.

### Type-checks between trains
<!-- id: type-checks-between-trains; keys: typecheck-mac, typecheck-ios, typecheck-tests, SwiftPM, CENSUS, iOS errors; src: Makefile, Scripts/agents/heavy_lock.py, Scripts/agents/wait-for-result.py -->

**Type-checks between trains.**
`make typecheck-mac` compiles and links the committed Mac app with SwiftPM in about 96 seconds, without xcodebuild, and `make typecheck-ios` does the same for the iOS target (`CENSUS=1` counts every AppKit use left).
`make typecheck-tests [REF=<commit>]` adds the Mac's hosted test target (`TextMouthProductionTests`), so a test file that does not compile is found before a train does; an agent runs it before every train request.
All take `Scripts/agents/heavy_lock.py`'s lock, as each train does around its build and tests, so no two heavy jobs run at once on the 8 GB Mac.
Each train result also counts the iOS errors in the agent's own files.
For a train that carries a change to interface text, `python3 -I -B Scripts/l10n/l10n.py reach --base main` names the Mac test classes to request; `l10n.py sync` reads the code in about two seconds and takes no lock.
An agent waits for its result with `Scripts/agents/wait-for-result.py --agent <slug>` in the background.


## Two branches can fail together
<!-- id: two-branches-can-fail-together; keys: rebase, merged tree, final suite, combined failure; src: -->

Two branches that each pass can fail together; the suite after each merge on the merged tree is what counts.
A branch started before another merged must rebase before its final suite.

## Intermittent failures are bugs
<!-- id: intermittent-failures-are-bugs; keys: flaky test, retry, test_iterations, indeterminate; src: Scripts/agents/test_command.py -->

The user's rule: always spend time tracking down and fixing intermittently failing tests.
A test that passes on a retry is a bug to hunt, not a pass: find the cause, fix it, and prove the fix with many runs (`test_iterations`, see [Tests on GitHub Actions](../developer/testing-github.md)).

## The orchestrator's own memory
<!-- id: orchestrator-own-memory; keys: memory directory, report to the user, decisions, unverified; src: -->

The orchestrator keeps its own memory of the campaign (the harness's memory directory) and tells the user, in plain words, what landed, what is unverified, and what decisions are theirs.

## Team leads and their workers
<!-- id: orchestrator-teams; keys: sub-orchestrator, delegation, hierarchy, team lead; src: Scripts/agents/agent-cost.py, Scripts/agents/briefs/2026-10-12/teams-common.md, .claude/skills/agent-bbs/SKILL.md -->

For a wave of small tasks, the orchestrator can launch team leads in place of task agents.
- **How a team works.**
  A lead (Sonnet for a wave of small tasks, Opus for a large design) owns a team branch `team/<team>`.
  It breaks its charter into tasks of one or two commits, writes a brief for each, and launches a worker per task with the Agent tool (`model: "sonnet"`, `effort: "high"`, `isolation: "worktree"`): agents can launch agents.
  It reviews every diff, integrates the accepted work in a straight line, runs the full suite once, and reports.
  The orchestrator merges the team branch like any other.
- **The briefs.**
  The pattern, the rules, and the report format are in `Scripts/agents/briefs/2026-10-12/teams-common.md`; each team has a charter beside it (`team-board.md`, `team-polish.md`, `team-t6d.md`).
- **The board.**
  It has teams, channels addressed `team:NAME`, and task lists (`SKILL.md`).
- **What it cost** on the first day of teams, by `Scripts/agents/agent-cost.py`, which prices each call by its model (Sonnet 5.5 at half Opus 5.5's prices):
  - The board team (24 commits) and the polish team (eight fixes) cost about 0.7 and 0.6 weekly points.
  - Each lead cost about 0.5; each Sonnet worker cost 0.01 to 0.03, its context staying under 100,000 tokens.
  - A single Opus fix agent that day cost 1.56.
  - Workers were accepted as written 15 times in 16, when their briefs gave exact line ranges, the mechanism, and the tests.
  - A lead's growing context is the team's largest cost.

## Lessons
<!-- id: orchestrator-lessons; keys: disk, icon cache, lsregister, usage override, weekly reset, stall-watch, exit status; src: Scripts/agents/stall-watch.py, Scripts/agents/wait-for-usage-reset.py, Scripts/agents/usage-watch-unscoped.py, Scripts/agents/run_suite.py -->

### Briefs and launches
<!-- id: lessons-briefs-and-launches; keys: brief, launch, SendMessage, subagent limit, recommended answer, extract-report; src: Scripts/agents/extract-report.py -->

- Save a subagent's report from its final message (`Scripts/agents/extract-report.py` prints it): a subagent often cannot write outside its worktree.
- Keep the user's rules apart from yours: never pass off a rule of the orchestrator's as the user's.
- When an agent's task is to search for inputs that defeat a security check, the model's safeguards can stop it, on Sonnet and Opus alike.
  Don't do its work yourself and don't hand the case to another agent: make the defence not depend on the search.
- When the user has not answered a question, build the recommended answer and record that choice.
- Put the rule against reading or copying the user's live library (`AGENTS.md`, The user's standing rules) in every prompt, a reviewer's included: a reviewer copied two books to `/tmp` when its prompt lacked it.
- A message sent with SendMessage reaches an agent at its next tool call, and a question on the board can go unseen, so send a message for anything urgent.
- **The Agent tool runs at most 20 subagents at once** in a session ("Concurrent subagent limit reached (20)"), so count the leads, reviewers, and workers before a launch.
  A finished agent keeps its slot until it is stopped, so stop it, and launch the rest as slots free.
  Stopping it also ends its leftover background checks and timers.
- An agent in an isolated worktree cannot write the main checkout, so scratch folders and reports go elsewhere, and the report is the agent's final message.
- A translator must not run `check`: `apply` checks every string it writes, and the orchestrator runs `check` on the merged catalog (see [Translating TextMouth](../developer/translation.md#translating-at-scale)).

### Trains and builds
<!-- id: lessons-trains-and-builds; keys: train base, zsh status, build-train, shared base; src: Scripts/agents/build-train.py -->

- When branches conflict, make one shared base early (`build-train.py loop --base <branch>`) and have each agent request its real branch: a private train copy of a branch tangles with other agents' commits.
- An agent that writes that it is waiting on a train, and has no background `wait-for-result.py` running, has ended its turn and is never woken: message it to start one (`AGENTS.md`, How a task agent works), or read `build/orchestrator/train/results/<agent>.md` yourself when it appears.
- When a sender of a remote run dies on the API's 403, the run goes on: its results are still there to download afterward (`gh run download <run id> -R AERobertAI/TextMouth -n test-build-results`, as `download` in `Scripts/agents/github_run.py` does).
- Never assign `status` in a zsh script that waits on a suite: it is read-only there, so the script dies after the suite and reports a failure; use another name.

### Reviews and merges
<!-- id: lessons-reviews-and-merges; keys: review, fix round, verifier, integration branch, merge-tree, regenerate-project, merge-chain, exit status; src: Scripts/agents/merge-chain.sh, Scripts/agents/regenerate-project.py, Scripts/agents/run_suite.py -->

- Take every branch through a review, a fix round, a narrow check, the Mac's full suite on an integration branch, and a fast-forward of main: every review finds real problems, so keep review, fix, and verify as separate steps.
- Review a large or data-touching branch whole, first with Opus, and a small batch with Sonnet: the review of a whole branch is worth its cost for anything that rewrites the live library.
- Give the narrow check to a fresh Sonnet verifier with the review report, the fix range, and one shared brief: it takes 2 to 18 minutes and costs less than resuming the reviewer.
- Give each fix round its own review, right after it or after the merge, and have it measure on real samples: one braille fix split 98 of 233 titles of a real book.
- Integrate on a fresh branch from main that merges only verified branches, so main stays installable; a branch that fails verification is left out.
  Merge two conflicting team branches there, in a scratch worktree, and fast-forward main once the suite is green.
- Scout conflicts before merging with `git merge-tree --write-tree --name-only main <branch>`, or with a trial merge made with `git commit-tree` while the reviews run: neither touches the working tree.
- Run `Scripts/agents/regenerate-project.py` after every merge, clean or not: a clean textual merge of `project.pbxproj` can leave out a branch's new file when the branch never listed it.
- Run a full suite in the lead's worktree while the review runs, to find full-suite-only failures early; three `TranscriptionFixtureTests` skip there, since their TestData zips are untracked.
- Start `Scripts/agents/merge-chain.sh` with the Bash tool's background mode: a shell `&` gives no notice when the merge ends.
- **The Mac suite's exit status is the gate.**
  Read `Scripts/agents/run_suite.py`'s exit status, not the Executed line: "1 failure (0 unexpected)" is a real failure.

### Usage, disk, and the Mac
<!-- id: lessons-usage-disk-and-the-mac; keys: disk, icon cache, usage override, weekly reset, stall-watch, login expiry, scratchpad, 403; src: Scripts/agents/stall-watch.py, Scripts/agents/wait-for-usage-reset.py, Scripts/agents/usage-watch-unscoped.py -->

- **Deleting to free disk:** the user allows the orchestrator, when the disk runs low or whenever it helps, to delete build folders that can be rebuilt.
  That means DerivedData, release and scratch builds, and finished agents' worktrees, each folder's apps unregistered first (the icon-cache lesson).
  When the disk falls under 8 GB, clear finished worktrees and scratch at once, with literal paths.
  Keep two gigabytes free before a merge suite: the archive-import tests refuse to run under the app's one-gigabyte reserve.
- **The system icon cache** (`/Library/Caches/com.apple.iconservices.store`, root-only, invisible to `du`) grows about 23 MB with every build-and-launch of the test host, and only the user can purge it.
  At each merge check `stat -f %l /Library/Caches/com.apple.iconservices.store` (entries plus two), and tell the user when it passes 10,000.
  Before deleting any build folder run `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u <folder>/Build/Products/Debug/TextMouth.app`.
  Batch targeted test runs into fewer launches.
- Under 10 GB free, run one heavy job at a time and delete `build/DerivedData-main` right after each merge suite: an idle one blocked a team for 45 minutes.
- Keep your scripts and working files in `build/orchestrator/`, never in the session's scratch folder: a restart of the Mac or of the session empties it, and the old session's agents cannot be resumed ("No transcript found").
  Agents commit small and often, and a fresh agent finishes from the branches.
- **The usage override before the weekly reset** (Saturdays at 8:00 a.m. Eastern).
  On a Friday night or Saturday morning, keep a full set of agents going until the limit runs out, and tell every agent so in its launch message.
  An agent that follows the usage rule stops itself at a "critical" reading, so say in the launch message whenever the user has overridden it.
  Keep a background task that exits after the reset, so you are re-invoked to resume agents that were cut off.
- Agent work may run the weekly window down to about 10% left.
- **A spent usage window:** nothing re-invokes you when it comes back, and once the limit is reached you cannot start a watcher.
  At the start of any long unattended run, start `Scripts/agents/wait-for-usage-reset.py` as a background task: it exits, re-invoking you, when a window it saw spent has headroom again.
- A login expiry or an API 403 ("Please run /login") stops every agent and watcher silently, and the usage monitor exits with "AUTH PROBLEM".
  After the user logs in, a SendMessage to each agent's id resumes it with its uncommitted work; a 403 that passes by itself needs only that resume.
  Take over the last steps of a lead near a million tokens instead of resuming it: it met the 403 again on resume.
- After a weekly reset, resume few agents at first: a resumed long-context agent is costly (3% of a week in 10 minutes).
- **Stalled agents:** an agent can stall with "no progress for 600s": a message to its id resumes it with its context intact, and its branch keeps its commits.
  A background suite stopped at its time limit must be rerun.
  While agents work, run `python3 -I Scripts/agents/stall-watch.py --subagents ~/.claude/projects/<project folder>/<session id>/subagents` as a background task.
  It exits naming any agent whose tool call has waited fifteen minutes for its result, usually at a permission prompt.

### Teams
<!-- id: lessons-teams; keys: team lead, outside review, signature, Sonnet lead; src: .claude/skills/agent-bbs/SKILL.md -->

- A team lead may run on Sonnet: Sonnet leads matched Opus leads on waves of small tasks with exact line ranges; keep Opus for a large design and the first outside review.
- Give a team branch an in-team reviewer and then an outside review before the merge; the outside review's fixes are small enough for one agent each.
- When one team declares a signature that another calls, pick that single commit onto the integration branch at once, so the other team can rebase.

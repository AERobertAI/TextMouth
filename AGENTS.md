# Working on TextMouth with coding agents

This file is for a coding-agent session that starts cold: an orchestrator that runs several task agents at once, and the task agents themselves. It says where the project's state lives, what the user has standing rules about, how a task agent must work, and how the orchestrator merges and records. README.md is the index of the documentation, whose pages are in docs/: docs/user explains the app to its user, docs/developer how to build and test it, and ARCHITECTURE.md, the index of docs/architecture, explains the code. None repeats what is here.

## Start here

- `README.md`: the index of the documentation in `docs/`. `docs/user/` holds a page for each part of the app, for the person using it. `docs/developer/building.md` holds what you need, the make targets, and the make check gate; `docs/developer/testing.md` the hosted suite, the performance baselines, and the cloud-drive tests. `docs/agents/working-with-agents.md` introduces the message board, and `docs/agents/history.md` keeps the status of earlier campaigns.
- `ARCHITECTURE.md`: the index of `docs/architecture/`: the parts of the app, launch, who owns each kind of state (a page for each, in `docs/architecture/state/`), the reading walkthrough, the shared helpers, and the duplication left in place. Read only the pages your task touches, and keep them true after every merge.
- `TODO-2026-09-04.md`: the record. Every merge gets a `- [x]` entry before the paragraph that begins `**Open follow-ups noted by the September 28 agents**`, a sentence with the suite's exact counts appended to the long verification paragraph (search for the latest "After the … merge: **N tests, S skipped, 0 failures**"), and open items go into the paragraph that begins `**Open follow-ups noted on October 3 afternoon and evening**`. Its "Feature requests (October 3)" section holds FR01 to FR05; its "Performance review (October 3)" section holds PERF01 to PERF33.
- The research documents, each written before a feature was built and ending in the user's answered questions: `CLOUD-STORAGE-RESEARCH-2026-10-03.md` with `CLOUD-STORAGE-PLAN-2026-10-03.md` and `CLOUD-STORAGE-MANUAL-TESTS-2026-10-03.md`, `RSS-READER-RESEARCH-2026-10-03.md`, `AUDIO-RECORDING-EDITOR-RESEARCH-2026-10-03.md`, `TRANSCRIPTION-RESEARCH-2026-10-03.md`, `TRANSCRIPT-CLEANUP-RESEARCH-2026-10-04.md`, `FEED-ITEMS-RESEARCH-2026-10-07.md` with `FEED-ITEMS-ADDENDUM-2026-10-07.md` (FR11), `KEYBOARD-SHORTCUTS-RESEARCH-2026-10-07.md` (FR12), `TEXT-ANCHORS-RESEARCH-2026-10-10.md` (T06), and `END-AND-JUMP-RESEARCH-2026-10-10.md` (P07 and P08). Older notes: `CACHE-UPDATES-2026-09-09.md`, `EPUB-HEADINGS-FIX-2026-09-08.md`, `FEATURE_IDEAS0509.md`, `TODO-2026-07-12.md`.
- `AGENT-NOTES-2026-10-04.md`: what each agent of the September 28 to October 4 campaign left unverified or undone, in its own words, with the documentation wording that was still to be applied. Read it before a documentation pass.
- `.claude/skills/agent-bbs/`: the message board the agents coordinate through (`SKILL.md` is the reference; `scripts/bbs.py` is the command; `scripts/build-slot-with-bbs.sh` is the build wrapper). It was used for every task since October 2: well over a thousand messages by October 4.
- `Scripts/agents/`: `merge-chain.sh` (merge a branch into main and run the suite) and `extract-report.py` (print a subagent transcript's final report).
- `*.md` is gitignored except README.md, AGENTS.md, ARCHITECTURE.md, CLAUDE.md, and the pages under `docs/`: stage any other Markdown file (the TODO, AGENT-NOTES, the research documents, the briefs) with `git add -f`.
- `humanQuestions/` (gitignored, in the main checkout only, so agents' worktrees do not have it): the questions put to the user and their answers, one Markdown file per session or batch, named by date and part (`2026-10-07-evening.md`). Read the newest files before asking the user anything; an answer there is the user's answer.

## The user's standing rules

- Never push, and never install: the user pushes main and runs `make install` themselves when told main is ready.
- Never read or write the user's live library at `~/.TextMouth` from a test or an experiment; copy what a test needs into its own sandbox. Reading its logs for a diagnosis is fine.
- Merges into `main` happen only after the full hosted suite is green on the merged tree, as non-squash merges (`git merge --no-ff`), which the user authorized for the orchestrator; the project `CLAUDE.md` otherwise forbids merging. Every merge is recorded in the TODO and described in the documentation (the pages under docs/, indexed by README.md and ARCHITECTURE.md) by a documentation pass.
- Small, focused commits, each with a test; comments on every function and non-obvious block; Markdown for every document; a VoiceOver and braille user first: every control keyboard-operable, every value spoken, nothing conveyed by sight alone.
- The user sees a macOS crash dialog for every test host that aborts, so no test may trap (no unguarded subscript, force unwrap, over-fulfilled expectation, or unowned capture of a released object), and no test may play sound aloud or record from a real microphone without an opt-in environment variable.
- Only TextMouth's own caches may be cleared; other apps' caches and the user's Trash are theirs.
- The system icon cache (`/Library/Caches/com.apple.iconservices.store`, root-only, invisible to `du`) grows about 23 MB with every build-and-launch of the test host and only the user can purge it: check `stat -f %l /Library/Caches/com.apple.iconservices.store` (entries plus two) at each merge and tell the user when it passes 10,000; before deleting any build folder run `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u <folder>/Build/Products/Debug/TextMouth.app`; batch targeted test runs into fewer launches.
- The usage rule in the user's global instructions (wrap up when a limit is nearly spent) can be overridden by the user for a day; when it is, agents keep working until the API refuses them, and unmerged branches wait on their worktrees for the reset. The user set that override as standing for the night before the weekly reset (Saturdays at 8:00 a.m. Eastern; October 10, 2026: "please don't warry about the weekly reset and have a full set of agents going and work until the limit runs out, everything can just be resumed without issue in the new week... and remember this for Friday nights / Saturday mornings before the usage resets"): on a Friday night or Saturday morning keep three builders and the non-building agents going until the limit runs out, tell every agent so in its launch message, and keep a background task that exits after the reset so the orchestrator is re-invoked to resume agents that were cut off.

## How a task agent works

The orchestrator launches each agent in its own git worktree under `.claude/worktrees/` with a brief: the branch name, a task slug, the regions to avoid because other agents are editing them, the required behavior as numbered items with one commit each, the tests each item needs, the baseline test count on main, and the report format. The agent:

1. Creates its branch from `main` (a worktree can start on an older commit; branch from `main` explicitly), reads this file, its brief, and the documents the brief names, and registers on the board as its slug: `python3 .claude/skills/agent-bbs/scripts/bbs.py register <slug> --role "<one line>" --branch <branch> --files <paths or 'quoted globs'>`, then `bbs claims` and `bbs read --last 10` for overlaps. `bbs protocol` prints the full rules.
2. Reads its inbox before every build, every commit, and its report (`bbs inbox <slug> --unread`); posts a `build` notice before a full suite, a `commit` notice after each commit (`--topic "$(git log -1 --format='%h %s')"`), a `finding` with `--file <path>` for a problem in files it does not own (never fixing them), a `question` to another agent when a decision touches that agent's work, and `done: <branch>` with `bbs release <slug> --all` at the end. Posts are short; the board's topic limit is 200 characters.
3. Builds and tests only through the wrapper, one build of its own at a time, with a build folder of its own outside the repository: `BBS_AGENT=<slug> .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath "${TMPDIR}TextMouth-DerivedData-<slug>" > log 2>&1`. `-jobs 4` holds a clean build's peak memory to about 1.9 GB, against 2.6 GB at Xcode's default of eight jobs, for 13 seconds more (69 to 82 seconds, measured October 12, 2026; compiling is about a minute of a full run, the tests about eleven). The wrapper holds one of three machine-wide slots (the Mac has 8 GB of memory) under `/tmp/textmouth-build-slots` (or `BUILD_SLOT_ROOT`). While iterating it adds `-only-testing:TextMouthProductionTests/<Class>`, several classes per run. A full run compiles the app and takes seven to eight minutes; a new test file needs `make generate` and the committed `project.pbxproj`. Hosted tests run inside the real app against a sandbox under the temporary directory and never join the system's media session.
4. Commits one logical change at a time, each message ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` (or the attribution the session's own instructions give), edits no `*.md` file (the orchestrator maintains the docs from the agent's report), and leaves files outside its task alone except for a hook its brief names.
5. Before reporting: rebases onto `main` (keeping both sides of adjacent-line conflicts, which are common in `ConfigService`, `SettingsViewModel`, `MenuCommands`, `AppDelegate.applicationShouldTerminate`, and the config test fixtures), runs the complete suite once and records the exact `Executed N tests, with S tests skipped and F failures` line, keeps `make check` in mind when the Release build or the app's size changes, deletes its build folder after unregistering its app, and releases its claims.
6. Reports: the branch; the commits with hashes and subjects; the files changed; the suite's exact result; what it could not verify; its decisions and assumptions; findings posted on the board; and the documentation wording its changes need, naming the page under docs/ each sentence belongs on, which the orchestrator or a documentation agent applies.

## How the orchestrator works

- **Every launch names its model, Sonnet by default.** Since October 31, 2026, workers, verifiers, documentation passes, and narrow fixes run on Sonnet at high effort (`model: "sonnet"`, `effort: "high"`), and Opus (`model: "opus"`) is kept for the lead of a large design and the first outside review of a big or risky branch. After a night of 76 Opus agents the user asked: "Are the subagents teams running as sonnet agents? just checking given how fast they used usage last night." Every launch also passes `subagent_type: "general-purpose"` and `isolation: "worktree"`; an agent launched without a model override inherits the orchestrator's model, which on October 6 and 7, 2026 put thirteen task agents on Fable and spent the weekly Fable window (only the four read-only sheet sweeps of October 6 ran on Opus). The orchestrator, on Fable, writes the briefs, reads each report and diff, decides, merges, and records; it uses a Fable agent only when the user asks for one. Briefs are kept in `Scripts/agents/briefs/<date>/` (stage with `git add -f`), never only in the session's scratch folder, so the next session can launch from them. The orchestrator itself may run on Opus too (it did on the evening of October 7, 2026); the launches still name the model. The usage script's `binding` window can then be a weekly cap scoped to one model, such as "Weekly (Fable)", which Opus work does not count: read only the unscoped windows ("5-hour session", "Weekly (all models)"), watch them with `Scripts/agents/usage-watch-unscoped.py <left%>` as a background task, and say in every launch message that the scoped window does not apply, or an agent following the usage rule stops at once.
- One brief per task, written to `Scripts/agents/briefs/<date>/` and pointed at from the launch message; the user's decisions quoted in the brief in their own words; waves of three to five agents whose file regions do not overlap, with a shared contract or a first "core" branch when they must share types.
- After an agent reports: write the merge message to a file, note the agent's unverified items and its documentation wording where the next documentation pass will find them (`AGENT-NOTES-2026-10-04.md` is the current such file), then `Scripts/agents/merge-chain.sh <branch>:<message-file>` in the background; on a green suite, record the merge in the TODO with `Scripts/agents/record-merge.py` (the three edits named under "Start here"; `--note` in place of `--counts` for a merge that ran no suite, `--tick FR09 --hash <merge>` to tick an entry), commit the TODO, remove the agent's worktree (`git worktree remove --force --force` and `git worktree prune`), unregister and delete `build/DerivedData-main` when the disk is tight, and post `merged: <branch>` on the board with the new counts so the other agents rebase. A suite that fails only in a load-sensitive test (the sleep-timer integration tests, `BookmarkKeyboardAccessTests`, `StorageGenerationMoveTests`, `BookSearchModelTests.testCancelledSearchPublishesNothing`, `DataDirectoryMoveTests.testAMoveShowsItsProgressWhileItCopies`, the reader-sheet redraw count in `ViewsAndWindowsReaderSheetTests`, the resume-data test `FeedDownloadTests.testADownloadThatStopsPartwayGoesOnFromWhereItStopped`, the audiobook-open benchmark, `MacBrailleTableCheckTests.testFrenchGermanAndSpanishPassAndRoundTrip` (its reading of the braille helper's memory can miss three short runs), and the performance baselines, which skip while the Mac is busy) is rerun on that class alone before the merge stands.
- Questions for the user go into a new file in `humanQuestions/` for each session or batch, so the user can answer while away and the answers are kept: each question numbered, with its context in a sentence or two, a recommended answer, and an `Answer:` line for the user; an optional "Answer for the whole section:" line; and an "Answered this session" section quoting the answers already given in chat. Say in chat which file holds new questions. When acting on an answer, record the decision in the TODO with the user's words, as before.
- A documentation pass is its own agent (no build) that edits only the documentation (README.md, ARCHITECTURE.md, and the pages under docs/) from the merged code and the agents' wording, one commit per documented branch; it is merged without a suite as a Markdown-only merge and recorded in the TODO with a sentence.
- **The version.** The user's rule (October 23, 2026) is one bump for each day on which main gains bug fixes or small backward-compatible features. After the day's last merge, and before the user's next install, run `make bump-patch`; run `make bump-minor` instead when that day holds a change that is not backward compatible (an older TextMouth cannot open the library, every book is read again, a stored format changes, or a setting, shortcut, or file is removed or renamed). Commit the bump on its own, add the day's dated section to the top of `docs/user/changelog.md` with one plain sentence per change (a MINOR section first says what an older TextMouth can no longer do with the library), tag the commit the user is to install as `vX.Y.Z` with an annotated tag (pushing tags is the user's), and record the bump in the TODO. MAJOR stays 0 until the user calls TextMouth released. Versions in `docs/developer/building.md` has the rules and the cases they leave open.
- **Builds go through the build train** (since October 31, 2026). That day the Mac, with 8 GB of memory, froze under the agents' builds and was force-restarted, and the user asked for "1 build at a time maybe on a schedule or something every 30 minutes and have the agents pool there work into each build". On November 8, 2026, finding that the builds took a lot of CPU, they asked for "the builds every hour and putting them one after the other", and for the agents "to use the wait time to review there patches and fix any obvius issues so its less likely a hour cycle would be waisted, or to improve tests so each indiviusal build would give more information".
  - **Start it.** While agents work, the orchestrator runs two background tasks. `Scripts/agents/hold-build-slots.sh <release flag>` holds every build slot, so no agent builds on its own. `python3 -I Scripts/agents/build-train.py loop --hours <N>` runs a train every hour, on the hour; with `--remote` the trains build and test on GitHub Actions instead of this Mac (see **Builds on GitHub** below), and `--remote --soon <minutes>` sends one that many minutes after a request comes. Every heavy job takes the heavy-work lock (`Scripts/agents/heavy_lock.py`), so one runs at a time: the trains, the type-checks, `run_suite.py`, and anything run through `run_locked.py`, simulator runs included.
  - **The helpers** are in `Scripts/agents/`, each found from its own location, so they work from any checkout. `python3 -I Scripts/agents/run_locked.py NAME COMMAND...` runs one command under the lock and exits with its status. `python3 -I Scripts/agents/run_suite.py NAME LOG` runs the full hosted suite under the lock from the checkout to test (as a background task), ends an xcodebuild that outlives its tests, prints the log's Executed line, and exits 0 only when every test passed; `run_suite.py --remote COMMIT NAME LOG` runs the same suite on GitHub for COMMIT's tree, takes no heavy-work lock, writes the run's log to LOG, and judges it the same way (exit 4: the push or the run failed, not the tests; exit 3: a train held TestBuild throughout). `python3 -I Scripts/agents/copy_phases.py A.pbxproj B.pbxproj` says whether two projects copy the same files to the same places. `Scripts/agents/regenerate-project.py` is what `make generate` runs. Their tests are in `Scripts/agents/tests`.
  - **An agent's part.** It commits, then queues `build-train.py request --agent <name> --branch <branch> --classes <A,B> --areas <x,y>`. It waits for its board message or for `build/orchestrator/train/results/<name>.md`. The train tests the commit the branch was at when the agent asked, so an agent that commits a fix before the train leaves asks again; the newest request for a branch wins. Every brief points the agent at Making each train count, in `docs/agents/working-with-agents.md`.
  - **Each train:**
    - it waits for the heavy-work lock first in line, so no other job takes the lock before it, for up to 50 minutes, and never runs without it; a train that waited in vain leaves its requests queued for the next one and tells the orchestrator who held the lock;
    - it then takes every waiting request, those made while it waited included, and merges the commit each one names onto `train/base` in `.claude/worktrees/train`, leaving out a branch that conflicts anywhere but project.pbxproj and telling its agent;
    - it builds once, with two jobs. If the build fails to compile only in files some merged branches change, it builds again without those branches, and merges again, in the order of the requests, every branch it had left out for a conflict: one that now merges cleanly is taken back, and the summary says so;
    - it runs the union of the tests asked for, dropping and reporting any name `Scripts/test/run-area.py` does not know;
    - it writes `build/orchestrator/train/trains/<id>/summary.md`;
    - it waits for the next hour while under 3 GB is free.
  - **An integration's full suite.** Point `train/base` at the integration branch, then queue `--agent orchestrator --branch <integration> --areas all`. The loop does not exit when a train ends, so wait for that summary with a background task that exits when the file appears.
  - **Look and finish.** `build-train.py status` shows the next train, what a running train is doing (waiting for the lock and for whom, or which branches it builds), and the queue. When the agents are done, stop the loop and `touch` the release flag.
  - **Builds on GitHub** (since November 9, 2026). The user, finding the builds hard on this Mac's CPU, asked to move the testing and compiling to GitHub Actions. `.github/workflows/test-build.yml` runs only for a push to the branch `TestBuild` of the public repository (`AERobertAI/TextMouth`), with a read-only token, no secrets, and GitHub's own pinned actions. A remote train (`build-train.py run --remote`, or `loop --remote`) merges the requests here as always, then pushes the merged tree plus `.github/test-request.json` to `TestBuild` with `--force`, and nothing else is ever pushed (`Scripts/agents/github_run.py` builds the refspec itself and refuses a tree holding a path under `build/`, `humanQuestions/`, or `humanReports/`). It waits for that commit's run, found by its SHA, for up to 110 minutes, downloads the run's artifact into the train's folder (`run.log`, `run-summary.txt`, `remote-N/`), and reports from it exactly as a local train does. The test command is made in one place, `Scripts/agents/test_command.py`, which the local train, `run_suite.py`, and the runner script (`Scripts/agents/run-on-runner.py`) all call. A remote train takes no heavy-work lock, skips the disk check and the iOS census, and shares the train's own lock with a remote suite, since a newer push to `TestBuild` cancels the older run. If its push or run fails, it puts every request back in the queue, tells each agent and the orchestrator, and the loop waits 15 minutes before the next try. A long request runs as up to four parallel jobs (`Scripts/agents/shard.py` deals the classes out; `merge_shards.py` joins the results into the one artifact the Mac reads), build products are cached between runs (`restore_mtimes.py`), and the full suite took 14.5 minutes on November 10, 2026 against 80 without finishing before the tuning. The runner cannot play or read audio, so `Scripts/agents/runner-skips.conf` lists the 76 entries (about 311 of 11,854 tests) it does not run, each with its reason; a remote suite is therefore not the last check before a release: run those classes on this Mac too. A test that fails on the runner with a timing, and passes here, is flaky there, not a reason to raise its limit or add it to the list. Testing TextMouth (Tests on GitHub Actions) has how to read a run, what differs from the Mac, and the flaky tests.
  - **Type-checks between trains** (since November 3, 2026). `make typecheck-mac` compiles and links the committed Mac app with SwiftPM in about 96 seconds, without xcodebuild, and `make typecheck-ios` does the same for the iOS target (`CENSUS=1` counts every AppKit use left). `make typecheck-tests [REF=<commit>]` adds the Mac's hosted test target (`TextMouthProductionTests`), so a test file that does not compile is found before a train does; an agent runs it before every train request. All take `Scripts/agents/heavy_lock.py`'s lock, as each train does around its build and tests, so no two heavy jobs run at once on the 8 GB Mac. Each train result also counts the iOS errors in the agent's own files. An agent waits for its result with `Scripts/agents/wait-for-result.py --agent <slug>` in the background.
- Two branches that each pass can fail together; the suite after each merge on the merged tree is what counts. A branch started before another merged must rebase before its final suite.
- The orchestrator keeps its own memory of the campaign (the harness's memory directory) and tells the user, in plain words, what landed, what is unverified, and what decisions are theirs.

## Teams (since October 12, 2026)

For a wave of small tasks, the orchestrator can launch team leads in place of task agents. The user asked for it on October 12 ("a sub sub orcistrater pattern where tasks are broken down even smaller... the subsubagents could be high Sonnet agents to see if that can save some cost").
- **How a team works.** A lead (Opus) owns a team branch `team/<team>`. It breaks its charter into tasks of one or two commits, writes a brief for each, and launches a worker per task with the Agent tool (`model: "sonnet"`, `effort: "high"`, `isolation: "worktree"`): agents can launch agents. It reviews every diff, integrates the accepted work in a straight line, runs the full suite once, and reports. The orchestrator merges the team branch like any other.
- **The briefs.** The pattern, the rules, and the report format are in `Scripts/agents/briefs/2026-10-12/teams-common.md`; each team has a charter beside it (`team-board.md`, `team-polish.md`, `team-t6d.md`).
- **The board.** It has teams, channels addressed `team:NAME`, and task lists (`SKILL.md`).
- **What it cost** on October 12, by `Scripts/agents/agent-cost.py`, which prices each call by its model (Sonnet 5.5 at half Opus 5.5's prices):
  - The board team (24 commits) and the polish team (eight fixes) cost about 0.7 and 0.6 weekly points.
  - Each lead cost about 0.5; each Sonnet worker cost 0.01 to 0.03, its context staying under 100,000 tokens.
  - A single Opus fix agent that day cost 1.56.
  - Workers were accepted as written 15 times in 16, when their briefs gave exact line ranges, the mechanism, and the tests.
  - A lead's growing context is the team's largest cost.

## Lessons that cost time

- `git merge -F -` does not read standard input; write merge messages to files. Two heredocs on one command line swallow the second; write helper scripts to files first.
- Every agent of one session shares the session's scratchpad folder: on October 9, 2026 one agent's commit-message files were overwritten by another's after use. Each agent prefixes its scratch files with its slug (or keeps a subfolder named for it), and the orchestrator's own start with `orchestrator-`.
- Agents can stall with "no progress for 600s"; a message to the agent's id resumes it with its context intact, and its branch keeps its commits. A background suite stopped at its time limit must be rerun.
- An agent that follows the usage rule stops itself at a "critical" reading; say in the launch message when the user has overridden it.
- Keep two gigabytes free before a merge suite: the archive-import tests refuse to run under the app's one-gigabyte reserve.
- A hosted SwiftUI view whose width outgrows the width offered (a macOS form in the columns style did) makes its window chase it until AppKit raises "more Update Constraints in Window passes than there are views in the window" and the test host ends with a crash dialog the user sees (twice on October 10, 2026). Host such views inside a fixed frame, or measure them with `NSHostingController.sizeThatFits(in:)` and no window.
- An agent's worktree (`isolation: "worktree"`) starts at origin/main, which can be far behind local main (1,081 commits on October 12, 2026): every brief has its agent make its branch from local main or a team branch, by name.
- A changed copy of `bbs.py` must never run against the live board: one worker did on October 12, which created the new tables early (harmlessly). Point `TEXTMOUTH_BBS_DIR` at a scratch folder first.
- A test host that joins the system's media session takes the user's AirPods; it never does now, but a branch older than that fix still can until it rebases.
- A tool call that waits on a permission prompt stops its agent until the user answers, and the user may be away. Claude Code asks before an `rm` through a shell variable: on October 18, 2026 a team lead's `rm -f "$D/$out"` in a throwaway test loop waited five hours while its team stood still. Every `rm`, in a brief or the orchestrator's own commands, takes literal paths. While agents work, the orchestrator runs `python3 -I Scripts/agents/stall-watch.py --subagents ~/.claude/projects/<project folder>/<session id>/subagents` as a background task; it exits naming any agent whose tool call has waited fifteen minutes for its result.
- The Agent tool runs at most 20 subagents at once in a session ("Concurrent subagent limit reached (20)"). Count the leads, reviewers, and workers before a launch: on October 30, 2026 two leads built most of their tasks themselves because they could not launch workers.
- Nothing re-invokes the orchestrator when a spent usage window comes back, and once the limit is reached the orchestrator cannot start a watcher either. At the start of any long unattended run, start `Scripts/agents/wait-for-usage-reset.py` as a background task: it exits, re-invoking the orchestrator, when a window it saw spent has headroom again. On October 31, 2026 the 5-hour window reset at 03:20 and every agent stood still until 12:06.
- A revert must keep what other code uses. Reverting a commit also takes away the helpers it added: on October 31, 2026 a revert removed the test helper `onWorkerSizedStack`, which other tests used, and the next build failed. Before a revert, grep for each symbol the commit added.

## Where things stood on November 9, 2026

- Main is version 0.4.3, tagged `v0.4.3`:
  - the KF8 follow-ups (`.mobi` at 1.1.0);
  - unmarked UTF-16 and UTF-32, and linked book folders (plain text at 1.0.1, HTML at 1.0.4);
  - the transcripts' follow-ups;
  - the iPhone's audit findings (unshipped).
  Full suite 11,905 tests: 11,818 passed, 81 skipped, 5 expected failures, and 1 interrupted when the user's own TextMouth started beside the host. That class passed alone 3 times. `make build` (Release) succeeded.
- Every version from v0.2.0 is tagged (Versions in `docs/developer/building.md`); pushing tags is the user's.
- The repository is public at `github.com/AERobertAI/TextMouth`, with `origin` at `git@github.com:AERobertAI/TextMouth.git`. The orchestrator, its train, and the `ci` agent may push to the `TestBuild` branch only, for GitHub Actions; every other push stays the user's.
- The tools gained four things:
  - `run_locked.py`, `run_suite.py`, and `copy_phases.py` in `Scripts/agents/`;
  - `make generate` through `regenerate-project.py`, so `make install` leaves no noise;
  - trains that take back a branch left out only for a conflict;
  - `make typecheck-tests`, the step before every train request.
- Then main went to version 0.4.4, tagged `v0.4.4`, after midnight. It holds the quit fix (`fix/quit-while-held`: a quit asked again never hangs, a second Command-Q never cuts held work off, a log out still waits) and the iPhone's Search in Book (`ios/search-1109`, unshipped). Full suite 11,962 tests, 93 skipped, 0 failures; the Release build compiled, and only its signing failed, with the login keychain locked after midnight.
- Under way: `ci/github-actions`.
- The user's line for the day is 45% of the week left; nothing new starts until the work under way is done.
- Lessons of that day, which hold for any campaign:
  - Never put a deliberate break on the build train: it tests every request in one tree, and two scratch branches with fixes broken on purpose failed other agents' classes. Prove a break with a harness through `run_locked.py`.
  - A hosted test failing with "The test runner exited with code 0" may be the user's own TextMouth starting beside the host, which shares its bundle identifier. Read the system log for `terminate:`, and run the class alone before calling it a fault.
  - Outside reviews found three faults no train could. A decoder rule that would have turned valid text into garbage on the launch re-read. A chapter rule that could cut a chapter in two. A quit-reason keyword that would have cancelled log outs. Every test and probe of the last had pinned the same wrong keyword: a test should take an outside constant from the SDK, not from the code it tests.
  - Test files that don't compile cost an hourly train each: `make typecheck-tests REF=<commit>` finds them first.

## Where things stood on November 8, 2026

- Main is version 0.4.2: spoken-audio export (M4B, M4A, or MP3 in a chosen voice, a chapter at each heading), transcripts that come with podcasts and audiobooks, symbols in `.docx` and Word 2003 XML documents, the markup guard's large stack, so a book nested however deeply can't crash TextMouth, and KF8 Kindle books (`.azw3`, and the KF8 half of a `.mobi`). Full suite 11,853 tests, 81 skipped, 0 failures, the iPhone interface's included; `make typecheck-ios` 0 errors, 0 warnings. At the first launch, `.docx` and `.wordml` books are read again once (1.3.0), and `.mobi` books once (1.0.0).
- The iPhone interface (`ios/lead-1108`) is on main too, unshipped: it ran in the simulator for the first time that morning, its Mac tests pass, and after its fix round (`ios/fix-c-1108`: one placement for every sheet's buttons, after the title, and full-contrast text) 17 of its 22 XCUITests pass; the five left are audit findings, three with no known cause. Since 07:20, at the user's word, a train leaves every hour and heavy jobs run one after the other (see Builds go through the build train). The hand checks and the one question 0.4.2 leaves, listening while a spoken-audio export runs, are in `humanQuestions/2026-11-08.md`.
- Lessons of that day, which hold for any campaign:
  - `make typecheck-mac`, `make typecheck-ios`, and `make typecheck-tests` check HEAD's commit as it was when they started (`git archive`), not the working tree. Commit first, and start them again after later commits.
  - A clean textual merge of `project.pbxproj` can still leave out a branch's new file when the branch never listed it and relied on the train's regeneration. Run `Scripts/agents/regenerate-project.py` after every merge, clean or not.
  - `git merge-tree --write-tree` and `git commit-tree` scout a chain of merges for conflicts without touching the working tree.
  - Told to use a train's wait for reviewing their own diff, agents found before the train what it would have cost an hour to learn from it: two near-identical scans to share and tests that could trap the host (KF8), and a backup file compiled into the test bundle (iPhone).
  - A narrow check of each branch on Sonnet, from one shared brief (`Scripts/agents/briefs/2026-11-08/verify-common.md`), took 2 to 18 minutes and found what the fix rounds had missed: two guards no test pinned, a policy test too loose to fail, and a measurement that settled less than its report said.

## Where things stood on November 7, 2026

- Main is version 0.4.1: the follow-up sweep, the reader follow-ups, EPUB 3 export, Word 6 and Word 95 documents with symbols read by their font, and the markup guard, which closes three ways a damaged or crafted book, web page, or feed could crash TextMouth. Full suite 10,631 tests, 78 skipped, 0 failures; `make typecheck-ios` 0 errors, 0 warnings. At the first launch, `.doc` books are read again once (1.3.0), and `.docx` and `.wordml` books once (1.2.0).
- Not on main yet, each with a review and a fix round behind it: speech export (`speechexport/finish`), podcast transcripts and chapters (`podcast/finish`, which merges after speech export), DOCX symbols (`readers/docx-symbols`), KF8 Kindle books (`readers/azw3`, which merges main and routes KF8 through the guard next), and the guard's large-stack parse (`fix/markup-guard-stack`). The iPhone interface (`ios/interface`) has its spec and nine slices; the iOS 26.0.1 simulator is now installed, so it can run for the first time. The running log is `build/orchestrator/followups1105/agents.md`; the questions left with the user are in `humanQuestions/2026-11-06.md` and `2026-11-07.md`.
- Lessons of that day, which hold for any campaign:
  - The model's safeguards can stop an agent that searches for inputs that defeat a security check, on Sonnet and on Opus alike. When that happens, don't do the agent's work yourself, and don't hand the case to another agent: make the defence not depend on the search (here, a stack big enough for any tree the size limit allows).
  - A branch under every reader trains the import and feeds areas, not only its own classes: the guard's trains passed while a MOBI test it changed never ran, and only the full suite caught it.
  - `make bump-patch` and `make set-version` regenerate the project through `Scripts/agents/regenerate-project.py`, which keeps the copy-files phases in their old order. Check with `git diff --stat` that only `project.yml` and the `MARKETING_VERSION` lines of the project changed.
  - Stamp the running log from the clock (`build/orchestrator/followups1105/logline.py`), never from an estimate.

## Where things stood on November 6, 2026

- Main is version 0.4.0: the one policy for every document reader, OpenDocument and Word 2003 XML, and DRM-free KFX, after 0.3.2's removal of the page commands and a library in the cloud that fetches its files and opens by itself. Full suite 10243 tests, 78 skipped, 0 failures.
- The record is in the TODO, under "One policy for every document reader". The questions left with the user are in `humanQuestions/2026-11-06.md`.
- Lessons of that night, which hold for any campaign:
  - Every first review found blockers, and every fix round's verification found something. Keep review, fix, and verify as separate steps.
  - Private train copies of a branch tangle with other agents' commits. When branches conflict, make one shared base early (`--base`), and have agents request their real branches.
  - A hang in a test holds every agent, as a trap does: the train now kills a host that writes nothing for 15 minutes, and every wait in a test takes a limit.
  - Never wrap `make typecheck-*` in another hold of the heavy lock: they take it themselves.
  - Every `rm` uses a literal or relative path, never a variable, substitution, glob, or built path: the user's rule, and it goes in every agent's prompt.
  - A subagent may be refused writes outside its worktree. Let its final message be its report, and save it from there.

## Where things stood on November 4, 2026

**November 3 and 4: iOS phase 0.**

- **The request.** On the morning of November 3 the user asked how hard an iOS port would be. The answer is `IOS-PORT-RESEARCH-2026-11-03.md`: one repository, a second app target compiled from the same sources, with eleven questions in `humanQuestions/2026-11-03.md`. That evening they asked: "please try spending the night with well reviewed sonnet agent teams and the pooled contribution scheduled builds to try conducting the first phase and fixing all IOS errors without changing MacOS behavior if possible."
- **How it ran.**
  - The orchestrator (Opus) laid a foundation on `integrate/ios-phase0`: the `TextMouthiOS` target, `TextMouth/Platform/{macOS,iOS}/`, the platform aliases, `make typecheck-ios` and `typecheck-mac` (SwiftPM, so no 10 GB iOS platform download), `make mac-projection`, and the heavy-work lock.
  - Five Sonnet teams split the census's 817 errors by file: shell, a11y, engine, media, and xml (briefs `Scripts/agents/briefs/2026-11-03/`, reports in `build/orchestrator/ios0/`). Every worker's work was accepted as written.
  - A Sonnet outside review read each team branch. The xml review found a real iOS hang (fixed).
  - An Opus review read every Mac change against main and found none that changes what the Mac does.
- **Merged into main** (fast-forward to cb7cc4c6): the iOS target compiles and links (strict check BUILD SUCCEEDED, 0 errors) and the Mac compiles what it did. Suite: 9322 tests, 75 skipped, 1 failure (the braille memory reading, which passed alone). No version bump, since nothing changed for the Mac's user. Docs: `docs/ios-phase0`.
- **Next:** phase 1, the first iPhone reader, after the user's answers to questions 1 to 4 and 6 and the iOS platform download. The phase 1 follow-ups are in the TODO.

**Lessons of November 3 and 4:**
- **The compiler is the census.** A search for `import AppKit` missed half the work, since SwiftUI brings AppKit's names in. Files that import AppKit without using it show no census error, and two were left unwrapped. Check strict mode, or list the bare imports, before the end.
- **Shared signatures cross teams.** Most messages between teams were one signature (`NSWindow` to `PlatformWindow`) that one team's file declared and another's called. The orchestrator picked those single commits onto the integration branch at once, so the other team could rebase.
- **A trial merge before the reviews finish** found the last two errors while the reviews ran.
- **The projection tool** turned "no Mac behavior change" into a mechanical check. Its global pool of moved lines could hide a deletion: match whole blocks (a follow-up).

## Where things stood on November 1, 2026

**November 1, version 0.2.5.** On the morning of November 1 the user asked that a reader window go on to the next book in place instead of opening a new window, with Next and Previous for a folder's or feed's items and "a global setting for the behavior of moving from book to book for windows and a local one for feeds and folders". At about 09:50 they added: "the sleeping timer in particular I would like to move still running to the new book without a new window opening."
- **How it ran.**
  - One Sonnet agent, `nextbook`, built it (design `NEXTBOOK-WINDOW-RESEARCH-2026-11-01.md`, briefs `Scripts/agents/briefs/2026-11-01/`).
  - Three Opus reviews and three Sonnet verifications each found real problems, mostly in the sleep timer's hand-over, and six fix rounds closed them. The orchestrator read the last round itself (reports in `build/orchestrator/nextbook/`, gitignored).
  - The user's questions 1 to 18 are in `humanQuestions/2026-11-01.md`.
- **Merged into main:**
  - **`feature/nextbook-window` (aad1fab9).**
    - A reader window shows the next book in place: the scene's `$bookID` changes, and `.id(bookID)` gives the same window a new reader.
    - The Playback tab's "Open the next book in" (`nextBookWindow`), and a feed's or folder's own choice in Feed Info and Folder Settings.
    - Next in Folder and Previous in Folder, in the Navigate menu.
    - A running sleep timer goes on with listening: the shared service holds it for the next book until that book's reader takes it.
  - **`docs/nextbook` (ff328b9a)** and **version 0.2.5** (4d72a43c).

**October 30 to November 1.** On Friday evening, October 30, before the Saturday 08:00 reset, the user lifted the usage limit for the night ("treat it as no limit") and asked: "Please try working through any remaining todos and unfinished work that doesn't require me, improve the tests and look for bugs", with a new feature, customizable Library views.
- **How it ran.**
  - Four teams worked through the night, every agent on Opus (`Scripts/agents/briefs/2026-10-30/`).
  - A triage agent read the TODO and the code for open items (`build/orchestrator/oct30/triage-report.md`, gitignored).
  - Outside Opus reviews read the views, braille, and bug hunt branches, and each found real problems. Every one was fixed and checked by a Sonnet verifier.
  - The branches were merged on `integrate/oct30`, and one full suite ran there through the build train (train 1031-1800). Main was fast-forwarded to it on November 1 (3769130e).
- **Merged into main:**
  - **`team/views` (71f22891).** Customizable Library views.
    - The categories became views of one system, in a View pop-up ("Library view"), with a new Feeds view.
    - A Library tab in Settings orders the views and shows each Always, When Applicable, or Hidden.
    - The user can make views of their own, each a filter and a sort.
    - Go to View reaches the first nine views (Command-1 to Command-9).
    - An Opus review's 15 findings were fixed.
    - The design is `LIBRARY-VIEWS-RESEARCH-2026-10-30.md`. Its 16 questions to the user are in `humanQuestions/2026-10-30.md`; the build follows their recommended answers.
  - **`team/braillecodes` (0b523829).** Braille file characters, chosen in the Braille tab, Export, and Book Information: North American Braille ASCII, Eurobraille six-dot, and Unicode braille patterns. Nine review findings were fixed.
  - **`team/bughunt` (d1a1a602).**
    - About 40 bugs found by five Opus reviews and the triage were fixed.
    - Its outside review found seven data problems, fixed in `bughunt/datafix`.
    - Its HTML depth guard changed the words of deeply nested books, so it was reverted (`bughunt/revert-htmldepth`). Redoing it is a follow-up.
  - **`team/tests` (090bce28).** Eleven load-sensitive tests made deterministic, vacuous tests made to fail, and new tests for risky code. These tests found four app bugs, which were fixed.
  - **`docs/oct31` (6fabf93f)** and **version 0.2.4** (6116fbb5).
- **Paused and not merged.** These teams started before the integration and must rebase onto main:
  - `team/podcastext`: FMT23 and FMT25, SRT and WebVTT transcripts and a podcast's own transcript and chapters;
  - `team/speechexport`: FMT43, speech to audio.

  `team/fixes30` was never launched: the triage's batches A to C, charter `Scripts/agents/briefs/2026-10-30/team-fixes.md`.

**October 25 (after midnight).** On the evening of October 24 the user asked for FMT16's follow-up: "Go ahead and do the reopening with a different encoding … can it be set in the info screen for a book with the current one seleted in the popup?" One Opus agent built it (`Scripts/agents/briefs/2026-10-24/encodingchoice.md`). One Opus reviewer found a wrong-text bug and four risks, then verified the first fix round and found four more gaps; both rounds were fixed. It was merged on `integrate/encoding-choice` after a green full suite, and main was fast-forwarded (b835fa79). Merged into main:
- **`formats/encoding-choice` (7b5375b9 and 0b1bf8dd).**
  - Book Information's Text Encoding row is a pop-up, with the encoding the book is read in selected and how it was decided.
  - Choosing another reads the file again in it, strictly. Places move with their words, an edit is kept as a copy, and the book stays busy throughout (a quit waits through the shared quit hold).
  - A failure puts the old text back. `textEncodingSource` records a choice.
- **`docs/encoding-choice` (c4d8ae8e)** and **version 0.2.3** (b835fa79).

**October 24.** At 02:25 ET on Saturday, with 13% of the week left before the 08:00 reset, the user asked: "Are there any more formats or bugs / todos you could work on? ... I want you to use as much as possible". Five agents worked on branches (`Scripts/agents/briefs/2026-10-24/`). The week ran out at 04:43, and they resumed after the reset. An independent Opus reviewer read each branch, and every one had real bugs, which its author fixed and a verifier checked. The branches were merged on `integrate/oct24`, one full suite ran there, and main was fast-forwarded to it (c7958b3c). Merged into main:
- **`pages/polish` (cedc79ef).** The pages follow-ups:
  - Go to Page's words, and Return on a repeated label;
  - heading labels without page-break numbers, so the EPUB and HTML page readers are at 1.0.1;
  - PDF grouped labels;
  - Page left out of the bar's pickers for a book without pages.
- **`pages/braille` (bd9bc748).** PG12 (braille pages) and PG13 (plain text form feeds), each with its own page-reader line (V07).
- **`braille/reading` (d8d2a3d7).**
  - EBAE emphasis is read where it is certain, with a safety net that keeps liblouis's words.
  - EBAE export stays plain.
  - Contracted UEB reads "people", not "p", before a terminator.
- **`fix/replace-existing` (7a2e503e).** ST04's carry-over: Replace Existing keeps the old copy's ID, places, bookmarks, settings, folder, reading-list place, and transcript. The new copy is committed before the old one goes.
- **`fix/pages-oct24` (2370465e).** Go to Page takes its reasons from the pages, and a BRF whose only form feeds are at its edges counts as having none.
- **`docs/oct24b` (723052e4)** and **version 0.2.2** (c7958b3c).
- **`formats/encodings` (1cf19935, with docs `docs/fmt16`, 7335f088): FMT16.**
  - At import, TextMouth guesses the encoding of a text file that names none, only when the Windows-1252 reading proves wrong. The guess is recorded with the book and named in Book Information.
  - It was held back from the first integration after one fix round still turned some Western text into other encodings.
  - The user then asked for its check ("Just do the check now"). After a second fix round and a one-line book-ID check, it merged on `integrate/fmt16`, after its own full suite.

**October 23.** The user asked for four things before installing: transcript work, a review of transcription for bugs, a plan of the breaking changes to make before the official install, and a changelog with a daily version policy ("I want to install the new version with it as stable as you can make it"). Friday's line was 95% of the week used, before Saturday's 08:00 reset. Merged into main:
- **`team/transcripts` (fec4de73).**
  - A feed episode's transcript can be edited and cleaned up.
  - Search in Book (Command-F) searches a transcript by time, with Go Back (Command-[).
  - Markdown exports escape only what Markdown needs, and a transcript's content.md is at layer 1.1.0.
  - Retranscribe Audio… names the command once a book has a transcript.
  - Two reviews' fifteen findings were fixed.
- **`release/changelog` (447a8c01).** `docs/user/changelog.md`, and the daily version policy ("Versions" in building.md; `make bump-patch` and `make bump-minor`).
- **`research/plan020` (737e641f).** `PLAN-0.2.0-2026-10-23.md`, and the TODO's section "Before the official 0.2.0 install" (ST01 to ST10, V01 to V07).
- **`team/stable020` (8aa0c690).** ST01 to ST10, V02 (`OnDiskContractTests`), and V03 (a library a later version wrote opens).
- **`fix/polish020` (cf7862f6).** Narrower page-label rule, Delete Folder keeping a newer version's books, precise chapter timing, and V05.
- **`docs/oct23` (712f5507), with V01.**
- **The version is 0.2.1** (5485d559): the daily bump.

**October 21.** The user asked for three things: fix the failing test ("send a team to see if its a real problem"), carry text formatting through braille, and pages across formats as a navigation unit, "the feature set implemented first today". Today's line was 30% of the week left. Merged into main:
- **`fix/reader-load-race` (825a3f23).** The race was real: a book moved while a reader opened it was called damaged. A moving package is now noted, and the reader waits and reloads, in cloud libraries too.
- **`braille/emphasis` (b4ca969e).** Helper protocol 2 carries emphasis both ways where liblouis reads it back: UEB, but not EBAE or most of this Mac's tables.
- **`team/pages` (77e798a0).**
  - A `<!-- page: LABEL -->` marker in content.md.
  - Page as a navigation unit, with Go to Page…, and the page on the reader screen and in Where Am I?.
  - Pages for EPUB, PDF, DOCX, DAISY text, and textutil's formats.
  - B12 (a finished Edit Text change is kept by automatic re-reads) and B13 (textutil's joined words).
  - **PG09's launch re-read of existing books** was merged switched off, since its Opus review found it unsafe for the live library.
- **`pages/pg16` (5f38016b).** It is now safe and on: a byte-for-byte compare, a stopped batch recognised, and a differing book with no edit on record copied (`content.md.edited-<UTC>`) before it gains pages. Two Opus reviews.
- **`release/version` (0587b7c4).** Version 0.2.0, `Scripts/set-version.sh` and `make set-version`, the beta procedure ("Versions" in building.md), and the user's What's new page (renamed the changelog, `docs/user/changelog.md`, on October 23).
- **Research and documentation:** `research/pages` (3c7d43b1), and the documentation pass `docs/oct21` (5c8a2a07).

**October 19 and 20.** On October 19 the user asked: "Go ahead and try working on the braille reading features tonight. and the export feature, for the braille I want it possible to have multiple braille tables and contracted and uncontracted settings and use the library. (see how much it increases app size)". Two teams worked on it, each an Opus lead with Sonnet workers (`Scripts/agents/briefs/2026-10-19/`), and fresh Opus reviewers read every branch before its merge. Merged into main:
- `team/export` (0db62a38): FMT18 and FMT19. The Export dialog's Convert to picker offers Markdown, HTML, RTF, and Word 97-2003. One swift-markdown walker of content.md feeds every writer. Every exported file is made in a scratch folder and moved in with an exclusive rename. 12 review findings were dealt with.
- `team/braille` (3996434d): FMT20, FMT21, and FMT22.
  - liblouis 3.39.0 runs in the TextMouthBraille helper, with four English tables and a Braille tab.
  - TextMouth reads BRF, BRL, and PEF, and writes BRF and PEF from Export.
  - 26 review findings over two rounds were fixed. The app grew about 0.6 MB, to about 19.75 MB.
- `team/mactables` (b5fffa42, then e7461fe1). A Language pop-up offers this Mac's VoiceOver liblouis tables (3.34.0, read in place), each measured and checked before first use, beside the built-in English ones. 16 findings over two reviews were dealt with.
- Documentation passes: `docs/oct19` (c77c9cf4), `docs/oct19b` (bc5ef365), and `docs/oct20` (077b4e1e).

**State at the end:**
- **Main's suite:** **9301 tests, 75 skipped, 0 failures**, on `feature/nextbook-window` merged with main's code in train 1101-1800, the same tree as main's merge (aad1fab9). Only the documentation merge and the 0.2.5 bump followed.
- **Not installed yet:** the user's installed build is still 0.1.1 (fb46ea6e). The first launch of 0.2.x reads every text book again for pages, safely (PG16), braille and plain text books included (V07).
- **Questions:**
  - `humanQuestions/2026-11-01.md` holds 18, on the next-book window. The user said yes to 9 to 11. 1 to 8 and 13 to 18 are built as recommended and unanswered. 12, whether Next in Reading List should follow the list's direction, is open, and nothing was built for it.
  - `humanQuestions/2026-10-30.md` holds 21. Questions 1 to 20 (views and braille) were built with their recommended answers. Question 21, whether Delete After Import may delete a ZIP holding files that were not imported, is open, and nothing was built for it.
  - That file also lists 20 older questions still open in `2026-10-10-evening.md` and `2026-10-12.md`.
  - `humanQuestions/2026-10-23.md` holds four: the escaping (V06) comes after the install; V03 is built and V04 is not; the rehearsal on a copy of the library needs the user's yes; the install's version follows the policy.
- **Pending with the user:** the push and install, now of 0.2.5, with the hand checks of the next-book window (the timer through a slow iCloud download, Command-W just after "Starting", focus in a switched window); the rm-hook offer; and whether and when to resume the paused teams.
- **The next candidates:**
  - the next-book window's follow-ups in the TODO (questions 12 and 18);
  - the October 30 follow-ups in the TODO, the HTML depth guard first;
  - the paused teams and `team/fixes30`;
  - the tests team's five unrun briefs (`Scripts/agents/briefs/2026-10-30/tests/`);
  - reading the first launch's `PAGES_UPGRADE_SUMMARY` once the user installs;
  - V06 in the first update after the install.

**Lessons of November 1:**
- **An agent that says it is waiting has stopped.** At 15:34 the `nextbook` agent wrote that it was waiting on two trains and ended its turn. Both results sat unread until 17:47. When an agent's work goes to the train, the orchestrator starts a background waiter on `build/orchestrator/train/results/<agent>.md`, which exits when the result is written.
- **A delayed closure can carry a test's fixtures past its teardown.** A move asks for its book half a second after saying so, and holds its reader, with the test's settings, until then. A test that ended within the config's 250 ms save delay left a save that ran after its sandbox was removed. The failure sentence then landed in the next test, which records every announcement. A fixture that removes a folder at teardown writes any waiting save first, in a teardown block added after the folder's (2f3674d2).
- **Every review round found something.** Each of the six rounds was answered by a fix and a check. The sleep timer's hand-over was where most of the problems lay.

**Lessons of October 30 to November 1:**
- **Opus everywhere spent the week.**
  - All 76 agents ran on Opus, and the 5-hour limit stopped them at about 20:45 and 02:20.
  - The window came back at 03:20, but nothing ran until 12:06, nearly nine hours lost; see "Lessons that cost time".
  - The user then asked for Sonnet.
- **The machine.**
  - **Memory.** Eight gigabytes cannot take the agents' builds beside the user's own apps. At 12:41 on October 31 a build of about 2.5 GB left 64 MB free and the Mac froze. The forced restart killed every agent and background task and emptied the session's scratch folder. Keep the orchestrator's scripts in `build/orchestrator/` or in the repository.
  - **The build train fixed it.** The trains that followed ran one build at a time, with two jobs, and the Mac did not freeze again.
- **The disk** fell from 12 GB to 1 GB several times, taken by the teams' build folders (3 to 4 GB each), swap, and the system icon cache (3,517 entries by 01:51 on October 31). By November 1 the icon cache was down to 174 entries.
- **Every outside review found real problems again:**
  - 15 in views and 9 in braille;
  - in the bug hunt, seven data problems and a depth guard that changed a book's words.

  The 17:30 train on October 31 failed four tests, for two causes:
  - the removal marker's key list, pinned by the bug hunt, lacked the braille branch's new key, which only the merged tree could show;
  - `train/base` held an older commit of views than the integration branch, one without its fix of the editor's fit test. Once an integration branch exists, point `train/base` at it.
- **An unnoticed result.** The final suite passed at 18:17 on October 31. Nothing woke the orchestrator, since the board watcher wakes it only for questions, and the result sat unread until 01:50 on November 1.

**Lessons of October 24:**
- **Every branch needed a fix round.** All five reviews found real bugs, two of them data loss or changed words, and the verifications after the fixes found new bugs in three branches. Plan review, fix, and verify for each branch.
- **Integrate on a branch.** A fresh integration branch from main, merging only verified branches, keeps main installable throughout, and a branch that fails verification (FMT16) is simply left out.
- **A guarantee by construction beats fuzz and patch.** Braille's safety net uses liblouis's reading whenever the pass's words differ from it.
- **Narrow verifiers.** A fresh Opus verifier, given the review report and the fix range, cost less than resuming a large reviewer.
- **After the weekly reset,** a SendMessage to each stopped agent resumed it with its uncommitted work intact. Resumed long-context agents are costly: 3% of the new week went in 10 minutes.
- **Every prompt needs the live-library rule.** The pages reviewer copied two of the user's books to /tmp because its prompt lacked it.
- **zsh's `status` is read-only.** A background script that assigns `status=$?` dies after the suite and reports a failure; use another name.

**Lessons of October 23:**
- **Two teams in parallel.** Two teams, each with an in-team Opus reviewer and then an outside Opus review of its branch, found real bugs both times. The outside reviews' fixes were small enough for one Sonnet or Opus agent each.
- **Trial merges.** `git merge-tree --write-tree --name-only main <branch>` shows whether two teams' overlapping branches conflict, before merge-chain commits anything.
- **Disk.** Two teams building at once on about 11 GB free fell to 3 GB. A shared disk budget across teams, at most two builds in all, would have been better than two builds per team.
- **The version policy:** bump once at the day's end with `make bump-patch`, and complete the changelog's section yourself. XcodeGen may need several runs before only the version lines change.

**Lessons of October 21:**
- **A review of the whole branch is worth its cost for anything that rewrites the live library.** The pages review found the launch re-read unsafe (heading-only edits invisible to its check, kept books unprotected afterwards, an interrupted batch turned into false edits), and switching it off let the rest ship.
- **A fix to a shared writer needs the golden and heading-annotation classes in its targeted run.** pagesfix's marker change passed 388 tests and failed three others at the merge, and merge-chain had already committed the merge. main was reset to its parent (local and unpushed), and the branch was fixed and merged again.
- **Disk.** It hit 0 GB at 04:44, with six workers and two other agents building on about 6 GB, and every shell call failed. Run one build at a time when under 10 GB free, and delete build/DerivedData-main right after each merge suite: an idle one blocked the pages team for 45 minutes.
- **Untracked fixtures.** TestData zips that only the main checkout has (the DAISY audio books, the transcription fixtures) are missing from worktrees, so goldens that read them are first checked at the merge.
- **merge-chain** must be started with the Bash tool's background mode. A shell `&` worked once, but gave no notice when it ended.

**Lessons of October 19 and 20:**
- **A login expiry** stops every agent and watcher silently; the usage monitor exits with "AUTH PROBLEM". After the user logs in, a SendMessage to each agent id resumes it, and workers came back with their uncommitted work intact.
- **A restart of the user's Claude Code session** makes the old session's agents unresumable ("No transcript found"), and the session's scratchpad goes with it. Agents should therefore commit small and often. The orchestrator keeps its working files in the repository's gitignored `build/orchestrator/`, and a fresh agent finishes from the branches.
- **Review fix rounds earned their own reviews:**
  - the braille round's heading fix split multi-line titles on real books (98 of 233 Pride and Prejudice titles);
  - one mactables fix failed English exports of text holding braille characters;
  - another dropped five languages.

  Have fix rounds measure on real samples, and review them before or right after the merge.
- **Libraries' success codes are not proof.** liblouis reports success when its output fills on an escape, so check the room left. A check run shorter than the watchdog's poll proves nothing about a table's memory.
- **Strictness has a cost.** A strict up-front check can cost more than it saves: refusing every table that writes @ in eight dots would have cost 19 languages, while refusing each book by name loses nothing silently.
- **A pre-merge full suite** in the lead's worktree, run while the review runs, finds full-suite-only failures early. Run in a worktree, it skips three TranscriptionFixtureTests, whose TestData zips are untracked.
- **XcodeGen 2.45.3** orders copy-files phases differently on each run. merge-chain then regenerates and commits the project, which is harmless.
- **Pacing.** On October 20 the user, seeing their usage page on track, approved of the pacing and raised the day's line to 55% used.

**Lessons of October 18:**
- **The Opus review of a whole team branch paid for itself:** in each branch it found serious bugs that the team's own tests had passed.
- **Measure on real samples** where a fix changes what a listener hears.
- **Disk:** each team builds one worker at a time, a worker deletes its build folder after its last build, and a merge suite starts only with 3 GB free.
- **Messages:** a message sent with SendMessage reaches an agent at its next tool call; a question on the board can go unseen.

**Lessons of the October 16 and 17 Sonnet teams:**
- Sonnet leads did as well as Opus ones at these brief sizes.
- **Name the policy tests in a brief:**
  - a brief that adds an `@unchecked Sendable` type, a `nonisolated(unsafe)` variable, or a log tag names `UncheckedConcurrencyPolicyTests` and `LogContentPolicyTests`;
  - one that adds a shortcut action names the legacy scenarios and `KeyboardReachabilityTests`;
  - one that adds a field to `Book` names `ContentAnalysisMergeTests`.
- Workers build with `python3 Scripts/test/run-area.py`. A rebase conflict in `project.pbxproj` is settled by `make generate`, and new classes are placed in `Scripts/test/areas.conf` (`--unassigned`).
- Two conflicting team branches are merged in a scratch worktree, and main is fast-forwarded once green.
- Three teams that build, plus agents that do not, is the ceiling for the build slots.

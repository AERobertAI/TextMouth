# Working on TextMouth with coding agents
<!-- id: working-textmouth-coding-agents; keys: agent-bbs, worktree, orchestrating session, briefs, speech probes; src: .claude/skills/agent-bbs/SKILL.md, AGENTS.md -->

Part of [TextMouth's documentation](../../README.md).

Task agents run in git worktrees of their own, each launched with an explicit model: Sonnet by default, Opus for a large design (see "Every launch names its model" in [Orchestrating TextMouth's agents](orchestrator.md)).
The orchestrating session, which may run on a larger model, writes their briefs, reviews their reports and diffs, merges after a green suite, and records the merge.
The briefs of each day's wave are kept under `Scripts/agents/briefs/`, and `Scripts/agents/probes/` holds the offline speech-engine probes behind the speech guard and the refusal fixes that followed it, and the probe of control characters, which found the null character's dropped words.

Several coding agents can work on TextMouth at once, each in its own git worktree on its own branch, coordinated through a shared message board: the agent-bbs skill, in .claude/skills/agent-bbs/.
Its SKILL.md is the full reference.
AGENTS.md, in the repository root, is the protocol those agents and their orchestrator follow:
- the user's standing rules;
- the build wrapper and the crash-proof tests rule;
- the board routine;
- the report format;
- and how a branch is merged with Scripts/agents/merge-chain.sh and recorded in TODO-2026-09-04.md.

AGENT-NOTES-2026-10-04.md lists what past agents left unverified.

## The board is one SQLite file
<!-- id: board-one-sqlite-file; keys: board.sqlite, bbs.py, message board, no server; src: .claude/skills/agent-bbs/scripts/bbs.py -->

The board is one SQLite file, .claude/agent-bbs/board.sqlite in the repository's main working tree, which git ignores.
A standard-library Python script drives it, with no server: `python3 .claude/skills/agent-bbs/scripts/bbs.py`.

## Registering and claiming files
<!-- id: registering-claiming-files; keys: register, claim, claims overlap, bbs claims; src: .claude/skills/agent-bbs/scripts/bbs.py -->

Each agent registers its role, branch, and the files it expects to edit, claims files as it takes them on, and sees any overlap with another agent's claims.

## Posting messages
<!-- id: posting-messages; keys: post, tag, inbox, message tied to a file; src: .claude/skills/agent-bbs/scripts/bbs.py -->

Agents post short messages about builds, commits, findings, and questions.
A message tied to a file reaches whoever has claimed it.

## Teams on the board
<!-- id: teams-board; keys: team create, team:NAME, task list, lead, layout version, did you mean; src: .claude/skills/agent-bbs/scripts/bbs.py, .claude/skills/agent-bbs/SKILL.md -->

The board has teams: a lead, members, a channel addressed `team:NAME`, and a task list (`team create`, `team add`, `team remove`, `teams`, `task add`, `task assign`, `task move`, `tasks`, and `--team` on `register`, `read`, `inbox`, and `watch`).
The tables for teams are additions to the board's file that leave its layout version at 1, so copies of the script from before teams keep working on the shared board.
A lead can add a worker to its team before the worker registers; the worker joins when it does, and a mistyped name waits with a "did you mean" hint.

## Issues beside the board
<!-- id: issues-beside-board; keys: issue tracker, issuelib, TODO lib, merge driver, record-merge --close; src: .claude/skills/issue-library/SKILL.md, .claude/skills/issue-library/scripts/issuestore.py, .claude/skills/issue-library/scripts/issuemerge.py, .gitattributes, Issues/README.md, Scripts/agents/record-merge.py, Scripts/agents/merge-chain.sh -->

The board is for live talk while agents work: claims, commits, findings, and questions, and it is purged.
What must last is an issue: open work with its decisions and history, one file in `Issues/`, kept in git and read with the issue-library skill (`issuelib list`, `show`, `search`).
The orchestrator files, assigns, and closes issues on main, closing each at its merge with `record-merge.py --close`; an agent, on its own branch, only comments on the issue assigned to it and sets it in-progress or blocked, and the script refuses the rest there, so two branches never take one ID.
A finding an agent posts on the board becomes an issue when the orchestrator files it.
Two branches' changes to one issue merge part by part, through the merge driver `.gitattributes` names for `Issues/*.md` and `make issues-merge-driver` defines in the repository's config: the header field by field, the description as git would, and each comment whole, in date order.
One field changed both ways stops the merge with markers in the header.
`merge-chain.sh` runs `issuelib check` on each merged tree, beside the docs lint, and fails only a problem that main did not have and that sits in a file the merge changed (`check --new-since`).

## The board refuses an unmerged script
<!-- id: board-refuses-unmerged-script; keys: TEXTMOUTH_BBS_DIR, TEXTMOUTH_BBS_ALLOW_UNMERGED, scratch board, changed script; src: .claude/skills/agent-bbs/scripts/bbs.py -->

The board refuses an unmerged copy of its script on the shared board: a copy opens it only when it matches the script at some commit main has had, so a worker tries a changed script on a scratch board, in a folder named by TEXTMOUTH_BBS_DIR, instead.
When git cannot tell, the script goes ahead, and TEXTMOUTH_BBS_ALLOW_UNMERGED=1 overrides the check.

## The protocol for an agent's brief
<!-- id: protocol-agent-brief; keys: protocol, brief rules, release claims, bbs.py protocol; src: .claude/skills/agent-bbs/scripts/bbs.py -->

`bbs.py protocol` prints the rules for an agent's brief: register on start, read the inbox before each build and commit, post each commit, and release claims when done.

## Build slots
<!-- id: working-with-agents-build-slots; keys: build slot, TEXTMOUTH_BUILD_SLOT, make check, three builds at once; src: .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh, Scripts/check.sh -->

`.claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh` runs a build while holding one of three machine-wide build slots, so that at most three wrapped builds share the development Mac's memory at once, and shows the agent as building meanwhile.
`make check` uses such a wrapper when the TEXTMOUTH_BUILD_SLOT variable names one.

## How an agent checks its code
<!-- id: how-agent-checks-code; keys: typecheck-ios, typecheck-mac, typecheck-tests, mac-projection, heavy-work lock, train request; src: Makefile, Scripts/ios/mac-projection.py, Scripts/agents/heavy_lock.py, Scripts/agents/wait-for-result.py -->

An agent checks its code in three ways, none of which builds with Xcode.
It type-checks for iOS with `make typecheck-ios` (`CENSUS=1` while it still has AppKit uses to count) and for the Mac with `make typecheck-mac`, and the Mac's tests with `make typecheck-tests`.
All run under the machine-wide heavy-work lock, which the build train shares, so each waits first come, first served and says its place in line and whom it waits for ("third in line, behind holder, typecheck-a and run-suite").
A change to interface text runs `make l10n-sync`, which reads the code's `InterfaceText.line` calls in about two seconds, with no build and no lock (see [Localizing TextMouth's code](../developer/localization.md)).
And, when its change must leave the Mac as it was, it runs `make mac-projection BASE=main`.
It tests through the build train (see [The build train](../developer/testing-tools.md#the-build-train)), and waits for the train's result in the background with `python3 -I Scripts/agents/wait-for-result.py --agent SLUG`, which exits when the result is written.
What the commands do is in [Building TextMouth](../developer/building.md), under The iOS app.

## Finding and checking doc sections
<!-- id: finding-checking-doc-sections; keys: doclib, find, lint, outline; src: .claude/skills/doc-library/SKILL.md -->

An agent finds, checks, and lints doc sections with the doc-library skill (`.claude/skills/doc-library/SKILL.md`).

## Making each train count
<!-- id: making-each-train-count; keys: hourly train, wasted train, request, wait time; src: Scripts/agents/build-train.py -->

**Making each train count.**
A train leaves once an hour, and heavy jobs run one after the other, so a train that is missed, or spent on a mistake a careful reading would have caught, costs an hour.
So an agent:

### Review before asking
<!-- id: review-before-asking; keys: git diff main...HEAD, typecheck-tests, outside reviewer, compile error; src: Makefile -->

**Reviews before it asks.**
It reads its whole diff against its base (`git diff main...HEAD`) as an outside reviewer would, for a bug in plain sight, a missed edge case, a test that would still pass with the change undone, a comment that no longer says what the code does, or a repeated block, and fixes what it finds.
It then commits and runs `make typecheck-tests` (the app and the Mac's hosted tests; `REF=<commit>` names another commit), and `make typecheck-ios` when the change reaches code the iPhone app shares, once for the whole batch rather than after each edit, so no train is spent on a compile error.
A change to a test file the iPhone's unit bundle shares also needs `make typecheck-ios-tests` (see [Testing the iPhone app](../developer/testing-iphone.md)).
It makes this its last step before the train request: a test file that does not compile costs the whole train, and the type-checks without `--tests` compile no test file.

### Ask once, for everything
<!-- id: ask-once-everything; keys: classes, areas, full suite, policy tests, golden classes, TestBuild lane; src: Scripts/agents/build-train.py, TextMouthProductionTests/UncheckedConcurrencyPolicyTests.swift, TextMouthProductionTests/LogContentPolicyTests.swift, TextMouthProductionTests/KeyboardReachabilityTests.swift, TextMouthProductionTests/ContentAnalysisMergeTests.swift, TextMouthProductionTests/BookBoxTests.swift -->

**Asks once, for everything.**
It sends one request for a batch of work, not one per commit, naming every class and area the change could break, not only those it edited: a class left out costs a second train.
Ask for a train naming your classes and areas, not for a full suite: each full suite on GitHub holds the one `TestBuild` lane about 26 minutes (the iPhone job is the longest) and every train waits behind it; a train of 3 classes takes about 9.
The orchestrator's Mac suite at the merge is the full check.
A fix to a shared writer needs the golden and heading-annotation classes in its request: one marker change passed 388 tests and failed three at the merge.
Name the policy tests your change calls for.
A change that localizes text names the classes `python3 -I -B Scripts/l10n/l10n.py reach` prints, and `phone` when the iPhone's files changed.
A new `@unchecked Sendable` type or `nonisolated(unsafe)` variable needs `UncheckedConcurrencyPolicyTests`, and a new log tag `LogContentPolicyTests`.
A new shortcut action needs `KeyboardReachabilityTests` and the legacy shortcut scenarios, and a new field on `Book` needs `ContentAnalysisMergeTests`, `BookBoxTests`, and `OnDiskContractTests`.

### Make each test informative
<!-- id: make-each-test-informative; keys: assertion message, table test, failure message, two explanations; src: -->

**Makes each test tell as much as it can.**
An assertion's message gives what was expected and what came instead (the values, the list of chapters, the words around a mismatch), so one failure shows the fix.
A test of a table checks every row and reports each mismatch, rather than stopping at the first.
When it is torn between two explanations, it adds a test for each, so one train settles both.

### Work while waiting
<!-- id: work-while-waiting; keys: polling, gh run watch, API rate limit, background wait, newest request wins; src: Scripts/agents/wait-for-result.py, Scripts/agents/github_run.py -->

**Works while it waits.**
It waits with one background `wait-for-result.py` and no polling, since each wake costs usage, and meanwhile reviews the patch again, writes the next step's tests, checks its list of documentation, and drafts its report.
A fix committed meanwhile goes with the train only if the agent asks again before the train leaves, since the train tests the commit each request names, and the newest request for a branch wins.
A train whose Mac loses GitHub keeps watching its run, and the next train collects a run this one could not (see [A remote train and a lost connection](../developer/testing-tools.md#a-remote-train-and-a-lost-connection)).
Never run `gh run watch` beside a train or a remote suite: `github_run.py` already polls the run, and the API allows 5,000 calls an hour for the whole account, shared by every agent and tool, so a second watcher only costs calls; wait with a local check.

### Retry one failing test
<!-- id: retry-one-failing-test; keys: --now, Class/testMethod, retry, one test, last train; src: Scripts/agents/build-train.py, Scripts/test/run-area.py -->

**Retries one failing test cheaply.**
To retry one failing test, request a train naming only its class or method (`--classes Class/testMethod`), with `--now` and no `--areas`: the train leaves at once, and runs only that test.
`--now` with `--areas` still goes ahead, and prints a line that the batching was skipped.
The last train names every class and area the change touches.

### Read the whole result first
<!-- id: read-whole-result-first; keys: result file, one round, fix every failure; src: -->

**Reads the whole result before changing anything.**
It fixes every failure in one round, reviews that round's diff, and asks once.

### Where the train runs
<!-- id: where-train-runs; keys: remote train, TestBuild, run.log, run-summary.txt, not run on GitHub, --soon; src: Scripts/agents/wait-for-result.py, Scripts/agents/build-train.py, Scripts/agents/github_run.py, Scripts/agents/runner-skips.conf -->

**Knows where its train runs.**
When the orchestrator starts the loop with `--remote`, the train merges on the Mac but builds and tests on GitHub's macOS runners, so the Mac stays free and a train costs the Mac no heavy-work lock.
The agent's part is the same: one request, one background `wait-for-result.py`.
What differs is the result.
Its file in `build/orchestrator/train/results/` carries a line "Run on GitHub" with the run's link, and the log is in the train's folder as `run.log` (the whole `xcodebuild` output) beside `run-summary.txt` (what `summarize` reads).
The train does not run the iOS census on this Mac: the run builds the iPhone app and its UI tests for the iOS Simulator on GitHub instead.
Your result lists "iOS errors in files your branch changes" from that build, with the errors themselves (a failed iPhone build is information; it does not change the train's verdict on the tests).
The train's "Verdict" counts the iPhone tests too, when the run was asked for them: it is PASSED only when the Mac suite and the iPhone tests both passed, and otherwise it begins with FAILED and names the part, as "FAILED (iPhone tests)" or "FAILED (Mac suite and iPhone tests)".
The Mac suite's own verdict has its own line, "Mac suite verdict", beside the Executed line.
The board post says "yours: 0 Mac failures, 1 iPhone failure, 0 compile errors" for a run with iPhone tests, counting the iPhone failures in the classes you asked for.
A train leaves 5 minutes after the first waiting request, and a push waits for any run already on `TestBuild`, so a train's run is never cut off by another sender's.
If the push or the run fails, the board says "the run on GitHub failed, so your request waits for the next train": the request is already back in the queue, so the agent does not ask again.
A remote train's tests skip the 14 entries of `Scripts/agents/runner-skips.conf` (the audio engine's and the Ogg decoders' tests among them; the other audio tests run), and your result has a "Not run on GitHub, no verdict: X (reason)" line for each one you asked for.
They have no verdict, so say so in your report and ask the orchestrator to run them in a local train.
A timing failure on the runner that passes on the Mac is flaky there; do not raise the test's limit.
A remote loop started with `--soon N` leaves N minutes after a request instead of on the hour, so a fix may get its result sooner; the rules above hold either way.
How to read a run: see Reading a run in [Tests on GitHub Actions](../developer/testing-github.md).

### Batch heavy jobs
<!-- id: batch-heavy-jobs; keys: simulator run, scratch copy, heavy-work lock, run_locked; src: Scripts/agents/run_locked.py -->

**Batches its own heavy jobs.**
A simulator run, or a deliberate break proven on a scratch copy, takes the same lock through `Scripts/agents/run_locked.py` and waits its turn behind the train, so the agent gathers them into as few runs as it can.

## The tests of the board and the build train
<!-- id: tests-board-build-train; keys: unittest, discover, board tests, train tests; src: Scripts/agents/run_locked.py, Scripts/agents/run_suite.py, Scripts/agents/copy_phases.py, Scripts/agents/regenerate-project.py, .claude/skills/agent-bbs/tests/test_bbs.py, Scripts/agents/tests/test_build_train.py, Scripts/agents/tests/test_heavy_lock.py, Scripts/agents/tests/test_run_locked.py, Scripts/agents/tests/test_copy_phases.py, Scripts/agents/tests/test_regenerate_project.py, Scripts/agents/tests/test_run_suite_remote.py -->

The board's tests run with `python3 -m unittest discover -s .claude/skills/agent-bbs/tests`, and those of the build train, the heavy-work lock, `run_locked.py`, `run_suite.py`, `copy_phases.py`, and `regenerate-project.py` with `python3 -I -B -m unittest discover -s Scripts/agents/tests`.
The issue tracker's run with `python3 -I -B -m unittest discover -s .claude/skills/issue-library/tests`, which `make check-selftest` runs.

## No path of one Mac in a tracked file
<!-- id: no-mac-paths; keys: main checkout, repo_paths, scrub-mac-paths, home folder, $TMPDIR, session folder, policy test; src: Scripts/agents/repo_paths.py, Scripts/agents/scrub-mac-paths.py, Scripts/agents/tests/test_repo_paths.py, Scripts/agents/tests/test_scrub_mac_paths.py, Scripts/agents/tests/test_no_mac_paths.py, Makefile -->

The repository is public, so no tracked file names the home folder, the repository's location, Claude's session or project folders, or `$TMPDIR`'s folder, in code, tests, docs, briefs, or commit messages.
Test fixtures use made-up paths such as `/Users/reader`.
A tool finds the main checkout through `Scripts/agents/repo_paths.py` (it asks git for the common directory), so it reaches the shared lock and results from any worktree; the same module computes Claude's project folder.
`python3 -I -B Scripts/agents/scrub-mac-paths.py` rewrites a tracked file's paths to `<main checkout>`, `<session folder>`, `<project folder>`, `$TMPDIR`, or `~/…`, and `--check` only counts them.
`test_no_mac_paths.py` fails when a tracked file holds one, and `make check-selftest` runs it, so the Check workflow does.

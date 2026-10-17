# testkit/runner2: `run-area.py --changed` and `--repeat`

Slug `testkit-runner2`. Branch `testkit/runner2`, made from `team/testkit` (it has `Scripts/test/run-area.py`, `testkit.py`, `test-logs.py`, `difflint.py`). Python 3 standard library only. One small smoke build at the end (your only build). Read `teams-common.md`'s worker's part first.

## Why

Two questions come up all night and nobody can answer them cheaply:

1. "I changed these files: which tests should I run?" Agents run the classes they remember; the user, who works without a screen, cannot skim a project tree for the tests that matter. The sources and tests are connected by the names of types: a test class that mentions `LibraryFeedShelf` exercises it. A script can follow those names.
2. "Is this failure flaky?" The pattern lists load-sensitive tests an agent must rerun alone; today that means launching xcodebuild again and again by hand, each launch costing build time and about 23 MB of a system cache only the user can purge. One build and several test runs, then a report of what differed, answers it.

## Ground truth

- `Scripts/test/run-area.py` and `Scripts/test/testkit.py` (read their header comments, then the functions you extend: `hosted_test_classes`, `resolve_names`, `build_command`, `summarize_log`, `run_child`). Keep their behavior and selftest passing; extend them. Two other workers are not editing them now.
- `Scripts/test/test-logs.py flaky LOG LOG ...` already reports tests whose outcome or time differs among logs; call it (as a subprocess, `python3 Scripts/test/test-logs.py flaky ...`) rather than copying its logic.
- `Scripts/test/difflint.py` has `run_git`, `repo_root`, `GitError`, `added_lines`; use `run_git(["merge-base", base, "HEAD"])` and `git diff --name-only`/`git ls-files --others --exclude-standard` for the changed files, as `added_lines` does.
- The build wrapper holds a build slot while it runs ONE command; for `--repeat` run the whole sequence (build once, test N times) inside ONE wrapper call so the slot is held throughout and no other agent's build is starved between phases: `<wrapper> /bin/sh -c '<xcodebuild build-for-testing ...> && for i in ...; do <xcodebuild test-without-building ...> > <log i> 2>&1; done'`, or run a hidden internal mode of `run-area.py` under the wrapper; your choice, but quote every argument safely (`shlex.quote`).
- `xcodebuild build-for-testing` and `test-without-building` take the same `-project/-scheme/-destination/-derivedDataPath/-only-testing:` arguments as `test`. `TEST_RUNNER_` variables apply to `test-without-building` (the test run), not to the build.

## `--changed`

    run-area.py --changed [--base REF] [--explain] [--limit N] [--list] [other options]

- Changed files: since the merge-base of REF (default `main`) and HEAD: tracked changes (staged and unstaged) and untracked files, under `TextMouth/` (the app), `TextMouthProductionTests/`, and `TestData/`.
- For each changed app file, its **declared type names**: top-level and one-level-nested `class`, `struct`, `enum`, `protocol`, `actor`, and the named type of an `extension`. Ignore declarations inside comments and strings (reuse the lexer in `difflint.mask_swift`). Ignore extensions of Swift, Foundation, AppKit, SwiftUI, and AVFoundation types (keep a constant list: `String`, `Array`, `Dictionary`, `Data`, `URL`, `Date`, `Int`, `Double`, `Bool`, `Optional`, `Set`, `Collection`, `Sequence`, `View`, `Notification`, `NSView`, `NSWindow`, `FileManager`, `UserDefaults`, `AVAudioPCMBuffer`, and so on: tune it by listing the extension names in `TextMouth/` with `grep` and choosing). Also add the file's base name without extension when it is not already a declared type (`ReaderViewModel+WhereAmI.swift` declares `extension ReaderViewModel`, which covers it).
- For each hosted test class, **score** = the number of distinct declared type names (of all changed app files) that appear as whole words (`\b…\b`, case-sensitive) in the test class's file text. A class declared in a changed test file scores 1000. The selected classes are those with score > 0, highest first; `--limit N` keeps the first N.
- Print the classes, one per line, `score  ClassName`, then a line `N classes; areas: a, b, c` (areas from `areas.conf`; a class in no area counts as `unassigned`), then `Heuristic: a test that mentions no changed type is not listed; run the area or "all" before a merge.` With `--explain`, under each class the matching type names (at most 5).
- Without `--list`, `--changed` RUNS those classes like any NAMEs (one xcodebuild; `--dry-run` shows the command). When nothing is selected, say `no hosted test class mentions the changed code` and exit 0 without building.
- A test class that mentions types of many changed files is not special; a very common type (mentioned by more than 150 classes) carries no information: drop names mentioned by more than 150 test files from the scoring and say how many names were dropped.

## `--repeat N`

    run-area.py --repeat N NAME ...      (N from 2 to 20)

Builds once for testing, then runs the selected classes N times with `test-without-building`, each run to its own log (`<log>.1`, `<log>.2`, ...). Prints each run's `Executed` line and verdict, then the flaky report from `test-logs.py flaky` over the N logs (`no test changed outcome in N runs` when nothing varied), then `PASSED in all N runs` or `FAILED in K of N runs`. Exit status: 0 only when every run passed. `--clean` and `--env` keep working. Reject N outside 2..20 with exit status 2. Remind in `-h` that each run launches the test host (about 23 MB of a system cache per launch).

## Selftest and checks

Extend `--selftest` (no build): type-name extraction on canned Swift (comments and strings ignored, nested types, extension of a standard type ignored, `+` file names); scoring and ordering; dropping common names; the `--repeat` command line (`--dry-run --repeat 3` prints the build step and the three test steps); the argument check. Then on the real repository run `run-area.py --changed --base main --list` (it should say there are no changes yet, or list sensibly) and, in a scratch copy of the sources with one app file touched (do this WITHOUT editing the shared repository: touch a file in your own worktree, run, then `git checkout` that file), show the output for a file such as `TextMouth/Models/CountWording.swift` and for `TextMouth/Services/SleepTimerService.swift`; report whether the classes it picks are the ones a person would pick.

## The smoke run (your only build)

Register on the board first. `BBS_AGENT=testkit-runner2 python3 Scripts/test/run-area.py --repeat 2 --classes CountWordingTests,TimeEntryTests` in the background; read the summary (check no more often than every 4 minutes). Then `--clean`.

## Commits

1. `--changed` with selftest.
2. `--repeat` with selftest.
3. Whatever the smoke run teaches you.

## Do not

Edit another file than `run-area.py` and `testkit.py`. Run the full suite. Leave a `__pycache__` in a commit (`sys.dont_write_bytecode = True` is set before the import already).

## Report (at most 15 lines)

Branch; commits; selftest result; the `--changed` output for the two sample files; the smoke run's result lines; what you could not verify.

# testkit/runner: the area runner, `Scripts/test/run-area.py`

Slug `testkit-runner`. Branch `testkit/runner`, made from `team/testkit`. Python 3 standard library only. You make exactly one build, a smoke run at the end. Read `teams-common.md`'s worker's part first.

## Why

The user is blind and works in a terminal. They want to run only the hosted tests of one area ("feeds", "bookmarks") with one command and read a short result, not xcodebuild's thousands of lines. Every later script of this team (golden update, corpus report, voice sweep, storage drill) will be a few lines that call your runner with `--classes` and `--env`, so **your command line is the team's shared interface**: keep it small and exact. It must work for the user at a terminal with no board registration, and for agents.

## Ground truth (read these and nothing more)

- `Scripts/perf-baselines.sh`: the model for a script that runs test classes, and for the header-comment style (the header doubles as the `-h` text).
- `.claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh`: holds one of three machine-wide build slots. With `BBS_AGENT` unset it skips every board hook silently, so a user needs no registration; with `BBS_AGENT=<name>` it reports to the board. Your runner always goes through it and passes the environment through untouched. It prints "[build-slot] acquired slotN" and unread board messages on stderr: send that to the log, not the terminal.
- The hosted tests are the classes in `TextMouthProductionTests/*.swift` (about 460 files, about 470 classes; some are helpers with no tests, and some tests live in `extension SomeTests { ... }` blocks in other files). Each test-host launch adds about 23 MB to a system cache only the user can purge, so a run of several areas MUST be ONE xcodebuild invocation with several `-only-testing:` arguments.
- `.gitignore` ignores `*.txt` and `*.md`. Name the area list `Scripts/test/areas.conf`, not areas.txt.
- The exact command, run from the repository root (keep every flag):

      <wrapper> xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath <folder> -only-testing:TextMouthProductionTests/<Class> [more -only-testing: arguments]

- An environment variable reaches the test host only with the prefix `TEST_RUNNER_` (`TEST_RUNNER_FOO=1` arrives as `FOO`).
- A passing run ends with a line like `Executed 6310 tests, with 67 tests skipped and 0 failures (0 unexpected) in 312.1 (312.5) seconds` (several such lines print, per suite; the last is the total), then `** TEST SUCCEEDED **`. A failing test prints `/path/File.swift:123: error: -[TextMouthProductionTests.FooTests testBar] : XCTAssertEqual failed: ...` and `Test Case '-[TextMouthProductionTests.FooTests testBar]' failed (0.1 seconds).` A compile error prints `/path/File.swift:12:5: error: ...` then `** TEST FAILED **` or `** BUILD FAILED **`. A crashed host prints lines containing `crashed` or `Restarting after unexpected exit, crash, or test timeout`. A warning prints `/path/File.swift:12:5: warning: ...`. Main has no Swift warnings, so any warning inside the repository is new.

## Files you create

1. `Scripts/test/testkit.py`, the shared module (a script in the same folder does `import testkit`). It holds, each function commented:
   - `repo_root()`: the folder above `Scripts/`, from `__file__`.
   - the class inventory: `hosted_test_classes(root)` returns `{class name: HostedClass(name, path, line, test_count)}` from `TextMouthProductionTests/*.swift`. A top-level declaration starts at column 0 (`final class X: Y {`, `@MainActor` on the line before, `extension X {`); the tests of a class are the `func test...(` lines indented inside it, including those in `extension X` blocks anywhere in the folder. A class with `test_count == 0` is a helper and is not "runnable". Keep it a line scanner (no Swift parser); document its limits in a comment. Sanity check by hand once: the sum of `test_count` should be close to 6310 plus 67 (report both numbers in your commit message).
   - `parse_areas(path)`: reads areas.conf (format below) into an ordered list of `Area(name, description, classes)`; a malformed line is an error that names the line number.
   - `summarize_log(text, root)` returns a `Summary` and `format_summary(summary)` returns the lines to print.
   - `build_command(...)`: the argv above.
2. `Scripts/test/run-area.py`, the command line (below).
3. `Scripts/test/areas.conf`: the format is documented in its header comment, and it holds THREE sample areas (`feeds`, `bookmarks`, `speech`) of 3 to 6 real classes each, so your selftest and smoke run have something to read. The next task (`testkit-areas`) fills it. Format: `#` starts a comment; `[name] one-line description` starts an area (name: lowercase letters, digits, hyphens); every other non-blank line is one test class name belonging to the last area; a class may be listed in two areas; a class twice in one area is an error.
4. `Makefile`: a target `test-area` (and its name in the `.PHONY` line, line 84):
   `test-area:` runs `python3 Scripts/test/run-area.py $(AREAS) $(AREA_ARGS)`, with a `##` comment above it in the style of the neighbours, showing `make test-area AREAS="feeds bookmarks"`. And add `@python3 Scripts/test/run-area.py --selftest` to the existing `check-selftest` target (its `##` comment says "no building": the selftest builds nothing).

## The command line (`run-area.py -h` prints the header comment)

    run-area.py [options] NAME [NAME ...]

A NAME is an area or a test class. `all` is a built-in area: every class listed in any area. Order is kept, duplicates are dropped, and one xcodebuild runs them all.

- `--list`: with no NAME, one line per area: name, class count, description. With NAMEs, each one's classes, one per line.
- `--classes A,B`: more classes (comma separated, repeatable).
- `--dry-run`: print the command (the wrapper and the xcodebuild argv, one shell-quoted line) and exit 0 without building.
- `--unassigned`: print the runnable classes that no area lists, one per line, then a count line; exit 0. (A new test class should not go unnoticed.)
- `--selftest`: no build. Checks: areas.conf parses; every listed class exists in the sources and is runnable; no area is empty; `build_command` gives the documented argv for a sample; `summarize_log` on canned logs gives the expected lines for a pass, a test failure (names the file and line), a compile error, a warning, a crash with no "Executed" line, and a log with two "Executed" lines (it takes the last). Prints `selftest: N checks, all passed` or one line per failure, and exits 0 or 1. Put the canned logs in the script as strings.
- `--summarize LOG`: print the summary of an existing xcodebuild log (from `make test`, from a worker's `> log 2>&1` run) and exit with its verdict. The same code the real run uses.
- `--env NAME=VALUE` (repeatable): passes `TEST_RUNNER_NAME=VALUE` to the test host. A value is never printed except in `--dry-run`.
- `--derived-data FOLDER`: default `<tempdir>/TextMouth-DerivedData-<suffix>`, `--log FILE`: default `<tempdir>/TextMouth-area-<suffix>.log`, where `<tempdir>` is `tempfile.gettempdir()` and `<suffix>` is `$BBS_AGENT` when set, else `area`.
- `--jobs N` (default 4), `--no-slot` (skip the wrapper: for a Mac with no agents running).
- `--clean`: unregister the area build's app with `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "<folder>/Build/Products/Debug/TextMouth.app"` and then delete the folder. Refuse to delete a folder whose name does not contain `TextMouth-DerivedData`. A missing folder is not an error.

A real run: resolve and check every NAME (an unknown one: print `no area or class named 'feed'; closest: feeds, ...` with `difflib.get_close_matches`, exit 2; no NAME at all: usage, exit 2), print one line saying what will run (`running 3 areas, 41 classes; build folder ...; log ...`), run the command with its whole output going to the log file (no output on the terminal while it runs), then print the summary and exit.

The summary prints, in this order, one fact per line, plain words (the reader uses VoiceOver and a braille display: no box drawing, no emoji, no colors, no progress bars, no carriage returns):
1. the last `Executed N tests, ...` line exactly as xcodebuild printed it (or `no tests ran` when there is none);
2. each failed test: `FAILED FooTests.testBar at File.swift:123: first line of the message`;
3. each compile error: `ERROR File.swift:12: message`, at most 20, then `and N more`;
4. each distinct Swift warning inside the repository: `WARNING File.swift:12: message` (ignore warnings from packages and DerivedData);
5. a crash note when the log shows one;
6. the log's path;
7. the last line: `PASSED` or `FAILED`, then the elapsed time. PASSED needs `** TEST SUCCEEDED **`, an Executed line, and no failures. Exit status 0 for PASSED, 1 for FAILED, 2 for a usage or setup error (no xcodebuild, areas.conf unreadable).

Ctrl-C: stop the child, keep the log, print where it is, exit 130.

## Commits (small, each with its checks)

1. `testkit.py` + `areas.conf` + `run-area.py` with `--selftest` passing, `--list`, `--dry-run`, `--unassigned`, `--summarize`.
2. `--clean` and the Makefile targets.
3. Anything the smoke run teaches you.

## The smoke run (your only build)

Register on the board first. Then run, in the background, `BBS_AGENT=testkit-runner python3 Scripts/test/run-area.py --classes CountWordingTests,TimeEntryTests` and read its summary (check no more often than every 4 minutes). It must print an Executed line with 0 failures and PASSED. Then run `python3 Scripts/test/run-area.py --clean` with `BBS_AGENT=testkit-runner` set and confirm the folder is gone. Also run `--summarize` on that run's log, and `make test-area AREAS=feeds --dry-run`-style (`make test-area AREAS=feeds AREA_ARGS=--dry-run`).

## Do not

- Do not edit any other file, `*.md` file, or any Swift file. Do not run the full suite.
- No third-party Python packages; no network. Nothing may launch the app outside xcodebuild's test host.
- Do not run a build command other than the smoke run, and never `make test`.

## Report

The branch; the commits; the exact Executed line of the smoke run; the sum of `test_count` against 6310+67; the runner's `-h` text; what you could not verify.

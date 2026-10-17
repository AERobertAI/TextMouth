# The testkit lead's section for docs/developer/testing.md (October 17, 2026)

Pasted by the orchestrator from the testkit lead's report, for the documentation pass. Check each claim against the merged code before placing it. "Build adds" means the time excludes the xcodebuild build: about 5 minutes cold, and up to 30 more waiting for a slot on a busy Mac.

## Reusable test tools (Scripts/test/)

They need only the Mac's own tools and Python 3, print their usage with `-h`, and never launch the app outside xcodebuild's test host. `make check-selftest` runs every Python tool's selftest in about 30 seconds without building.

- **Run only some tests:** `python3 Scripts/test/run-area.py feeds bookmarks`, or `make test-area AREAS="feeds bookmarks"`.
  - Names are areas from `Scripts/test/areas.conf` (29 areas, all 497 hosted classes placed) or test class names; `all` is every runnable class.
  - One xcodebuild runs them all, through the build-slot wrapper, with no board registration. It prints the Executed line, each failure with file and line, compile errors, warnings, the log path, and PASSED or FAILED.
  - Options: `--list`, `--classes A,B`, `--dry-run`, `--unassigned`, `--env NAME=VALUE`, `--summarize LOG`, `--changed [--base REF] [--explain] [--limit N] [--list]` (the classes that mention the types of the changed files), `--repeat N` (one build, N runs, then a flaky report), `--clean`, `--selftest`.
  - Time: a few seconds of tests for a small area (build adds); the whole suite is about 16 minutes of test time.
- **Check the lines a branch adds** (no building, 1 to 9 seconds; `LINT_BASE=REF` sets the base, default main):
  - `make lint-tests`: `trap-lint.py` flags test lines that can crash the host, play sound, record, or touch the real library; `test-diff.py` lists what the branch removed, changed, skipped, or loosened in existing tests.
  - `make lint-a11y`: SwiftUI lines with no VoiceOver label or action, tap-only controls, drag without a keyboard alternative.
  - `make lint-ogg`: new calls that open audio with an Apple reader, each of which must refuse Ogg first.
  - `--all [--counts]` audits the whole tree. A reviewed line is excused with `// lint-ok: reason`.
- **Read logs:** `python3 Scripts/test/test-logs.py slowest|compare|flaky LOG...` (0.7 s for a 22 MB log).
- **Document goldens:** `DocumentGoldenTests` compares every TestData document with `TestData/golden/<file>.golden` (title, author, headings with levels, text length and checksum, first and last 300 characters, audio tracks) and names every difference. About 1 second of test time.
  - `Scripts/test/update-goldens.sh` records new goldens after a deliberate change.
  - A PDF golden notes the macOS version and is skipped on another major version.
- **Documents to try:**
  - `python3 Scripts/test/make-corpus.py [--out DIR] [--seed N] [--large]` writes 24 deterministic nasty-but-valid documents (65 KB), in seconds.
  - `Scripts/test/corpus-report.sh <folder> [report.md]` imports a copy of every file in a folder (Ogg is skipped) and writes a Markdown report of format, title, author, headings, text length, first lines, warnings, refusals, and a checksum. About 7 s of test time on TestData and 2 minutes on the generated corpus (build adds).
- **Matrices** (always on): `EndBehaviorMatrixTests` pins all 100 cells of 4 end-of-book behaviors by 5 kinds of content by 5 sleep-timer states, about 2.5 minutes. `WindowsMatrixTests` pins 120 cells of what Book A keeps doing while Book B is edited, moved, closed, or timed, about 8 seconds. Each file's header comment has the table.
- **Keyboard:** `KeyboardReachabilityTests` (under 1 second) checks that every action has a default key or a menu item or sits on `unboundActions` with a reason, that no defaults collide, and that every menu command and key can be spoken.
- **Playback fuzz:** `PlaybackFuzzTests` applies seeded random operations to silent readers and checks the invariants of P09. Always-on size is 37 seconds. A long run: `python3 Scripts/test/run-area.py --classes PlaybackFuzzTests --env TEXTMOUTH_PLAYBACK_FUZZ_SEQUENCES=200 --env TEXTMOUTH_PLAYBACK_FUZZ_SEED=N` (about 26 minutes).
- **Opt-in sweeps** (each skips unless its script sets a variable):
  - `Scripts/test/voice-sweep.sh [report.md]` renders every installed voice offline and writes a report per voice (181 voices in 73 s of tests, English only 25 s).
  - `Scripts/test/import-fuzz.sh [--seed N] [--docs a,b] [--pdf]` damages each small TestData document in seeded ways and imports every copy (103 cases, 3 s of tests).
  - `Scripts/test/storage-drill.sh` runs import, full disk, save, and move against a disposable disk image and checks none is left attached (about 20 s of tests). It makes and removes a few MB of images in the temporary folder.

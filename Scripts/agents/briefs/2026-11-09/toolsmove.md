# The orchestrator's build helpers, in the repository (November 9, 2026)

You are `toolsmove`, a Sonnet worker, on branch `tools/scripts-tracked`. First read `common.md` beside this file and follow it exactly: it says how to start, check, and report.

The orchestrator's full-suite runner, the heavy-lock wrapper, and its copy-phase check live untracked in `build/orchestrator/followups1105/` of the main checkout, so a fresh clone lacks them. And `make install` leaves the Xcode project modified: `make generate` runs xcodegen directly, which deals out the copy-files phases in a different order each run. `Scripts/agents/regenerate-project.py` already puts that noise back. This branch fixes both. It changes only tools and Markdown, so no hosted suite and no train.

## Read first

- These files in the main checkout's `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/followups1105/`:
  - `run_locked.py`;
  - `run_suite.py`;
  - `copy_phases.py`.
- In `Scripts/agents/`:
  - `heavy_lock.py`;
  - `build-train.py`, which `run_suite.py` imports;
  - `regenerate-project.py`;
  - `tests/test_heavy_lock.py` and `tests/test_build_train.py`, whose temporary paths and guards your tests copy.
- The `Makefile`'s `generate`, `build`, `install`, `set-version`, `bump-patch`, and `bump-minor` targets.

## The work

1. **Track the three scripts in `Scripts/agents/`.**
   - Copy `run_locked.py`, `run_suite.py`, and `copy_phases.py` there.
   - Make each find its siblings from its own location instead of an absolute path. `run_suite.py` names the main checkout's `Scripts/agents` outright.
   - Keep their command lines and their output the same.
   - The originals stay where they are, since running agents and old briefs name their paths. The orchestrator retires them later.
2. **Tests** in `Scripts/agents/tests/`, on a temporary lock and temporary folders, with the same guards that every path is under the temporary folder.
   - `run_locked.py`:
     - takes the lock, runs the command, and passes on its exit status;
     - releases the lock when the command fails;
     - waits while the lock is held, and gives up at its limit.
   - `run_suite.py`:
     - prints the log's Executed line;
     - exits 0 only when the log says every test passed;
     - ends a command that outlives its tests. Use a fake command, a small Python child that prints the end of a test run and then sleeps, with a short limit.
     - No test runs xcodebuild.
   - `copy_phases.py`:
     - two projects that differ only in phase order and identifiers are the same;
     - a phase whose files or destination changed is not.
   - Each deliberate break of a script should fail one test. Say in your report which breaks you tried.
3. **`make generate` through `regenerate-project.py`.** Then `make install`, `make build`, `make set-version`, and the bumps leave no copy-phase noise.
   - Where git or the index's copy isn't there, as in a source archive, fall back to xcodegen's whole project, and say so on the console.
   - Prove it in a scratch clone under `build/orchestrator/toolsmove/`: `make generate` twice leaves `git status` clean, and `make set-version VERSION=9.9.9` leaves only the version's lines changed. Don't build the app.
4. **The living documentation.** Update every page that names the old paths or describes `make generate`: `AGENTS.md`, `docs/developer/testing.md`, `docs/developer/building.md`, `docs/agents/working-with-agents.md`, and any other page under `docs/`. This branch may edit Markdown.
   - Write in plain words and short sentences, saying what is true now, without dates of change or the branch's story.
   - Leave old briefs as they are: they are a record.

## Checks

- `python3 -I -B -m unittest discover -s Scripts/agents/tests` passes, and leaves no `__pycache__` folder.
- Run the new `run_suite.py` once, with its help or a dry option only. The orchestrator runs it for real at the next merge.

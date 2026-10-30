# Team `tests`: what every worker's brief shares (October 30, 2026)

Read this, then your own brief. "The worker's part" of `../teams-common.md` applies too; where this file is more specific, this file wins.

## The team's one build folder
The team keeps ONE build folder, used by one worker at a time. Never pass another `--derived-data`, and never delete or clean this folder: the lead does that at the end.

- Folder: `/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-tests`
- Every build and test run goes through `lockf` on the team's lock file, so a second worker waits for the first; waiting there is normal. Start it in the background (Bash `run_in_background: true`), from your worktree's root, and check on it no more often than every 4 minutes, with one short command:

      BBS_AGENT=<slug> /usr/bin/lockf -k /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-tests-build.lock python3 Scripts/test/run-area.py --derived-data /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-tests --log <your scratchpad>/<slug>-run<N>.log <ClassName> [<ClassName> ...]

  `run-area.py` prints only the result: the `Executed ...` line, each failure, each compile error, each Swift warning, and PASSED or FAILED. `--repeat N` (2 to 20) builds once and runs the classes N times, with a flaky report; use it where your brief says.
- Disk: before each build, `df -g /System/Volumes/Data` must show at least 5 GB available if the folder above does not exist yet, at least 2 GB if it does. If not, post to `tests-lead` and wait with `python3 .claude/skills/agent-bbs/scripts/bbs.py watch <slug> --timeout 600`, then check again.
- A new test file needs `/opt/homebrew/bin/xcodegen generate` and the regenerated `TextMouth.xcodeproj/project.pbxproj` committed with it.
- Run only the classes your brief names, never the full suite.

## Rules that decide whether your work is taken
- Never weaken an existing test to make it pass. A changed assertion needs a reason, in the commit message, that a reviewer can check.
- A test that you make deterministic keeps checking everything it checked. Replace a guess about time with a wait on the condition itself, a barrier, or a gate the code under test opens; a fixed sleep is never the answer, and neither is a longer one.
- Prove every test you add or change can fail: break the code under test in your worktree (never committed), run the class, see the test fail with a clear message, restore the code, and run again. Say in your report what you broke and the failure line you saw.
- No test may trap (no unguarded subscript, no force unwrap, no over-fulfilled expectation, no unowned capture of a released object), play sound, record from a microphone, or decode Ogg through Apple's frameworks.
- Never read, copy, or write anything under `~/.TextMouth`, the user's live library. Tests make what they need in their own sandbox.
- Comment every function and non-obvious block. Keep it DRY: reuse the helpers your brief names before writing new ones.
- Edit only the files your brief names; claim them on the board first (`bbs claim <slug> <paths>`), and read the claims of the other teams (`bbs claims`). For a problem elsewhere, post a finding with `--file <path>`.
- Commits: one logical change each, message ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` (or the model you run on).
- Before you report: `make lint-tests LINT_BASE=team/tests` must pass (trap-lint and test-diff against the team branch).

## Your report (at most 15 lines)
The branch; each commit's hash and subject; the tests added or changed and the exact `Executed ...` line of your last run; the proof that each can fail (what you broke, what failed); what you could not verify; the decisions you made.

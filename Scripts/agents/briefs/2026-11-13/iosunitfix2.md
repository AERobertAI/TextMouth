# The fix round of `ci/ios-unit-tests`, finished (November 13, 2026)

You are `iosunitfix2`, a Sonnet worker. You finish the fix round another worker began on November 11 and couldn't end, on the branch `ci/ios-unit-tests`.

First read `common.md` beside this brief. Then read `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/Scripts/agents/briefs/2026-11-11/iosunitfix.md`, the fix round's brief, and do what it says, with these changes:

## Start

- In your worktree, run `git switch ci/ios-unit-tests`, and check that `git log -1 --format=%h` prints `4eeb40f8`. The branch is not in another worktree's hands any more; if git says it is checked out elsewhere, report that and stop.
- The first worker made two commits after the review's tip (`2b9b371b`):
  - `1f6d658d` Log the Search sheet's part heights and name every part that falls short (finding 1's measuring and naming);
  - `4eeb40f8` Count iPhone tests written with attributes, in extensions, and in subfolders (finding 2).
  Read both diffs first, and check them against the review: fix what falls short.
- The first worker also left finding 3's guard uncommitted (the sound check in `Scripts/agents/tests/test_run_ios_ui_tests.py`). The orchestrator saved it as `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/iosunit/iosunitfix-uncommitted.patch` and removed the old worktree. Apply it with `git apply`, check it against finding 3 and against today's 19 unit tests (run the Python tests with `python3 -I -B`), fix what falls short, and commit it.
- It then sent a GitHub run of `LargeTextUITests` to read the heights: run 43066870675, pushed as 90e2bf61. Its watcher lost its connection (`build/orchestrator/iosunit/fix-run1.out`), but the run may have finished on GitHub. Look at it once with `gh run view 43066870675 --repo AERobertAI/TextMouth`; if it finished, download its artifact into a new folder of its own (`gh run download`), and read the heights from it. Send a new run only if it has no heights.

## What is left

From `iosunitfix.md`'s list: finding 1's bound, from the heights, and its proof on a throwaway branch (`.accessibility2` caps in `TextMouth/Platform/iOS/`, never merged); findings 3, 4, 5, and 6; item 6 if small; then the final phone-area run. The docs edits of finding 5 and 6 are in `docs/developer/`, the Markdown your brief allows.

## Report

Follow `iosunitfix.md`'s report, saved as `build/orchestrator/iosunit/iosunit-fix-report.md`, and also as `build/orchestrator/nov13/iosunitfix2-report.md`.

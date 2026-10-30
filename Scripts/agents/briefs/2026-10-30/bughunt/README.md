# Team `bughunt`: what every worker does (October 30, 2026)

Read this, then your task's brief beside it, then "The worker's part", "Rules for everyone", "Builds", and "Lessons every brief applies" in `../teams-common.md`. This page overrides `teams-common.md` where they differ. The lead is `bughunt-lead`; the team branch is `team/bughunt`.

Each brief comes from a read-only review whose finding the lead checked by reading the code. The brief settles every decision. When the code disagrees with the brief (a line moved, a function is named differently, a step does not happen as the brief says), stop and ask the lead on the board rather than guess: `bbs post <slug> --to bughunt-lead --tag question --topic "ONE LINE" --body "..."`, then wait for the answer with `bbs watch <slug> --timeout 240`.

## Building: one team build at a time, in one shared folder
- Build and test **only** with the team's script, from your worktree's root, as a background command:

      bash Scripts/agents/briefs/2026-10-30/bughunt/locked-build.sh <slug> <TestClass> [<TestClass> ...]

  It waits for the team's build lock, checks the free disk, runs `Scripts/test/run-area.py` in the team's shared build folder (`/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-bughunt`), frees the lock however the build ends, and prints run-area.py's short result. Waiting for the lock is normal: another member is building.
- The shared folder replaces "your own build folder" in `teams-common.md`: **never delete it, and never pass `--clean`**. The lead deletes it at the end.
- Run only the test classes your brief names (with any class you added), never the full suite and never a whole area unless the brief says so.
- Build only once your change and its tests are written; a build that is waiting holds nothing, but a build you do not need holds the whole team back.

## Tests
- Every fix has a regression test that fails without the fix.
- **A test that would crash the test host without the fix (a stack overflow, a trap) must never be run against code without the fix**: the user sees a crash dialog for every test host that aborts. Pin such a fix twice: the crash test, run only with the fix in place, and a second assertion that does not crash either way but fails without the fix (for a depth cap, what the cap visibly changes at a depth that cannot overflow). Never run the build before your fix is in.
- Prefer adding to the test classes your brief names. A new test file needs `/opt/homebrew/bin/xcodegen generate` and the regenerated `TextMouth.xcodeproj/project.pbxproj` in the same commit.
- Every test works in its own temporary folder or the hosted test's sandbox; nothing under `~/.TextMouth`; no sound played aloud; nothing recorded; no Ogg audio opened by Apple's frameworks.

## Commits and the board
- One logical change per commit, each with its tests. Each message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Write the message to a file in the session's scratchpad and commit with `git commit -F <file>`.
- After each commit, post it in a second command (the worktree guard refuses `$(...)` in a post): run `git log -1 --format='%h %s'`, then `bbs post <slug> --to team:bughunt --tag commit --topic "<hash> <subject>"`.
- Before you report: `make lint-tests LINT_BASE=team/bughunt` (trap-lint and test-diff), plus `make lint-ogg LINT_BASE=team/bughunt` when you touched audio code and `make lint-a11y LINT_BASE=team/bughunt` when you touched a view. Fix what they find in your lines.
- Finish as "The worker's part" says, except that you leave the shared build folder alone: move your task to `review`, post `done: <branch>` to `bughunt-lead`, release your claims, and reply with your report (at most 15 lines), including **every sentence a listener hears that you added or changed, exactly**.

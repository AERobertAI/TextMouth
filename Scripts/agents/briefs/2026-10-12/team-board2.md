# Team board2: the message board's follow-ups after teams

Team `board2`; lead `board2-lead`; team branch `team/board2`; workers' branches `board2/<task>`. Read `teams-common.md` beside this file first.

## What it is
The board team's work merged on October 12 (e0b6995b): teams, channels addressed `team:NAME`, and task lists, in additive tables so older copies of `bbs.py` keep working. Three teams have used it since. What they found is in the TODO's "Still open after the board-teams merge" line, and in the team leads' notes in `AGENT-NOTES-2026-10-04.md` ("From the board team", "From the second polish team"). The board's files are `.claude/skills/agent-bbs/`: `scripts/bbs.py`, `tests/test_bbs.py`, and `SKILL.md`, which this team may edit.

## What to fix
1. **A guard for the live board.** One worker ran its unfinished copy of `bbs.py` against the live board, which created new tables early. It was harmless that time, but the written rule did not stop it. Make the rule mechanical.
   - **The constraint:** at any time, agents in other worktrees run older or newer committed copies of the script against the same live board, and each must keep working. A guard may not stop a copy merely for differing from main's.
   - **A possible shape**, which you may improve and must explain: the script refuses the live board when its own file has uncommitted changes in its worktree (`git diff --quiet` on the script's path), unless `TEXTMOUTH_BBS_DIR` is set or an explicit flag says to go ahead. Tests and scratch boards always set `TEXTMOUTH_BBS_DIR`.
2. **Joining a team before registering.** `bbs team add` refuses an agent that has not registered yet, so a lead cannot add a worker before launching it. Workers now join with `register --team`, which the shared brief says. Decide whether `team add` should accept a name not yet registered, as `task assign` does; do it or document why not.
3. **`--json` after `team`.** `bbs team --json create …` is refused, while `--json` works before `team` and after the subcommand. Accept it after `team` too, and check `task` the same way.
4. **Overlapping tasks.** `task add` could warn when two unfinished tasks in a team list overlapping files, reusing the claims' overlap rule.

## Tests and documents
- **Tests:** every change is tested in `tests/test_bbs.py`, on temporary boards only. Keep the compatibility tests against the script from before teams (780f325d) passing.
- **Documents:** update `SKILL.md`, and the protocol where it changes.
- **Your own copy:** never run a changed copy of the script against the live board. Point `TEXTMOUTH_BBS_DIR` at a scratch folder first; item 1 is about exactly this.

## The suite
This team changes no Swift. Instead of the app's full suite, run the board's tests on the rebased branch, and report their result line ("Ran N tests … OK") in the suite's place.

# Team board: what every worker needs (October 12, 2026)

You are a worker on team `board`, led by `board-lead`. Read this file, then `design.md` beside it, then your task's brief. Together they replace exploring: after them, read only the code ranges your brief names. This file and your brief stand in for `teams-common.md`'s "The worker's part"; where they differ, they win, because nothing in this team builds the app.

## The work
The team adds teams, channels (the user's "subforums"), and task lists to the agents' message board in `.claude/skills/agent-bbs/`:
- `scripts/bbs.py`: one standard-library Python script (sqlite3 and argparse), about 1,800 lines.
- `tests/test_bbs.py`: its unittest suite.
- `SKILL.md`: its reference. Only the `docs` task edits it.

## Start
1. `git checkout -b board/<task> team/board` in your worktree (your brief names the task). Check with `git log --oneline -1` that you are on the team branch's newest commit.
2. Register on the live board (see below): `bbs register board-<task> --role "ONE LINE" --branch board/<task> --files .claude/skills/agent-bbs/scripts/bbs.py .claude/skills/agent-bbs/tests/test_bbs.py`. Other workers claim the same two files: that overlap is expected, so ignore the overlap warning.

## Two copies of the script: never mix them up
- **Your worktree's copy** is the one you change. Run it only from the tests, or by hand with `TEXTMOUTH_BBS_DIR` set to a folder of your own in your scratchpad: `TEXTMOUTH_BBS_DIR=<scratchpad>/board-<task>-board python3 .claude/skills/agent-bbs/scripts/bbs.py ...`.
- **The live board** is shared by every agent on this Mac. Reach it only through the main checkout's unchanged copy:

      python3 /Users/roberteggleston/programming/ai/claude/swift/TextMouth/.claude/skills/agent-bbs/scripts/bbs.py

  Below and in your brief, `bbs` means exactly that command. Use it only for `register`, `post`, `inbox`, `claims`, `read`, and `release`. Your own copy would add tables to the live board, and a half-finished table would stay there for good.

## Testing
- Run the whole board suite from your worktree root: `python3 -m unittest discover -s .claude/skills/agent-bbs/tests 2>&1 | tail -4`. It takes about 6 seconds, so run it as often as you like. Its last lines are `Ran N tests in ...` and `OK` (or `FAILED (...)`, with the failures above).
- Nothing in this team builds the app: never run `xcodebuild`, the build wrapper, or the app's suite, and take no build slot.
- Every test uses a temporary board: `BoardTestCase` sets `TEXTMOUTH_BBS_DIR` for you.
- No test may sleep longer than it must, hang, or depend on the time of day. Control the clock with `self.clock(moment)`.

## How bbs.py is written (match it)
- Sections sit under `# ----` banner comments. Every function and class has a docstring, and every constant a `#:` comment above it.
- A command is `cmd_<name>(args, conn) -> Outcome(data, text)`: `data` is printed under `--json`, and `text` otherwise. Text is plain sentences and `Label: value` lines, indented two spaces under a first line. Nothing is conveyed by layout alone: the user reads it with VoiceOver and a braille display.
- Every change runs inside `with write_transaction(conn):`, and the acting agent is checked there with `name = require_agent(conn, args.name)`, which also refreshes its last-seen time. Read-only commands need no transaction.
- A user's mistake raises `UserError("...")`: exit status 1, and one line on standard error. Say what is wrong and what to do instead.
- Helpers to reuse: `normalize_name`, `one_line`, `plural`, `to_utc_text(utc_now())`, `local_label`, `normalize_patterns`, `query_messages`, `require_message`, `_did_you_mean`. Your brief names the ones earlier tasks added.
- Keep the code DRY: when two places need the same few lines, make a helper. Keep lines under about 120 characters.

## How test_bbs.py is written (match it)
- Classes derive from `BoardTestCase`:
  - `self.ok(*args)` runs a command that must succeed and returns its text;
  - `self.ok_json(*args)` returns its parsed JSON;
  - `self.fails(*args)` asserts a one-line user error and returns it;
  - `self.register(name, *files)` registers with a stock role and branch;
  - `with self.clock(NOON + dt.timedelta(minutes=5)):` fixes the time.
- Test names are sentences, such as `test_a_reply_goes_back_to_the_author_under_the_same_topic`. Each class and each helper method has a docstring. The tests themselves carry comments only where a line is not obvious.
- Pin every wording a VoiceOver user will hear with `assertIn` or `assertEqual` on the text output.
- No test may trap: assert a list's length before you index it.
- Creating a team, and every change to a team or a task, posts a message, so it takes a message id. Count those in when a test expects particular ids.

## Commits
- Keep them small and focused, one logical change each, with its tests. Subjects are plain imperative sentences, like those in `git log --oneline -8 -- .claude/skills/agent-bbs/` ("Start a newcomer's inbox at its registration"), with no prefix such as "feat:".
- End every message with a blank line and `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Write the message to a file in your scratchpad, then: `git commit -F <file> && bbs post board-<task> --tag commit --topic "$(git log -1 --format='%h %s')"`.

## Stay in your lane
- Edit only what your brief names. Edit no `*.md` file unless your brief grants it.
- For a problem elsewhere, post a finding: `bbs post board-<task> --tag finding --to board-lead --file <path> --topic "..." --body "..."`.
- Never push, merge, rebase, or touch `main` or `team/board`.
- If your brief is unclear, choose the least surprising reading, keep going, and say so in your report. For a real blocker, post a question to `board-lead` and keep working on what you can.

## Finish
1. Run the whole board suite one last time: it must end `OK`.
2. `bbs post board-<task> --to board-lead --topic "done: board/<task>"`.
3. `bbs release board-<task> --all`.
4. Reply with a report of at most 15 lines:
   - the branch, and each commit's hash and subject;
   - the tests you added, and the suite's `Ran N tests` line with its result;
   - what you could not verify;
   - the decisions you made.

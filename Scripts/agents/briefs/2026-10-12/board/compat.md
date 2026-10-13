# Task `compat`: the pre-teams script on boards that hold teams

Worker `board-compat`, on branch `board/compat` from `team/board`. Read `common.md` and `design.md` beside this file first. You change only `tests/test_bbs.py`. `board-task-states` works at the same time, in bbs.py and at the end of `TaskTests`. Put your tests at the end of `SchemaTests`, which comes before `TaskTests`, so the two branches never touch the same lines.

## Why
Agents in older worktrees keep running the pre-teams copy of bbs.py against the one shared board, long after this team merges. The board's worktrees are made from an older commit, so those copies will be around for a while. `SchemaTests` already proves that the old script works on a board that the new one has migrated while it is empty. Your tests prove that it keeps working once the board holds what the new commands write:
- teams, with members and leads;
- tasks, with their files;
- posts to `team:<name>` channels.

Some of what the old script does to such a board must not fail, and must not break the new script afterwards:
- deleting agents in `purge` and `reset`, with foreign keys on;
- replying to channel posts;
- reading them.

## What is there
- **`SchemaTests`** (find it with `grep -n "class SchemaTests\|PRE_TEAMS_COMMIT\|def run_old\|def old_ok\|def board_objects\|class TaskTests" .claude/skills/agent-bbs/tests/test_bbs.py`):
  - `run_old(*args)` runs the pre-teams script against the test's temporary board;
  - `old_ok(*args)` asserts that it succeeded, and returns its output;
  - the class skips itself when git history is missing.
- **The new commands** (run them with `self.ok` and `self.ok_json`):
  - `team create NAME TEAM --purpose P [--lead AGENT]`;
  - `team add NAME TEAM AGENT ...`;
  - `team remove ...`;
  - `register NAME ... --team TEAM`;
  - `teams [TEAM]`;
  - `post NAME --to team:TEAM ...`;
  - `read --team TEAM`;
  - `inbox NAME --team TEAM`;
  - `task add NAME TEAM --title T [--brief P] [--files P ...] [--assign A]`;
  - `tasks [...]`.
- **What the commands store.** A channel post is stored with recipient `team:<name>`. Member rows cascade with their agent. `teams.lead` and `tasks.assignee` are plain names.
- **The old script** knows only `register`, `heartbeat`, `agents`, `activity`, `claim`, `release`, `claims`, `post`, `read`, `thread`, `inbox`, `watch`, `purge`, `reset`, and `protocol`. Its `post --reply-to` with no `--to` goes to the parent's author, or, when the sender wrote the parent, to the parent's recipient. Its `inbox` shows posts to the agent, to `all`, and about claimed files, so it never shows channel posts.

## Tests
Write a helper that fills a board with the new script, and use it in each test that needs it.

`populate()` builds this:
- `lead`, `alpha`, `beta`, and `gamma`, with `alpha` claiming `TextMouth/Views/`;
- team `board`, led by `lead`;
- `alpha` added with `team add`, and `beta` joining with `register beta --team board`;
- a post from `lead` to `team:board`, and a channel post from `beta` with `--file TextMouth/Views/A.swift`;
- a task with `--brief`, two `--files`, and `--assign alpha`.

It returns the ids you need.

1. **The old script reads a populated board.**
   - Its `read` shows the channel posts, as `to team:board` in the text.
   - Its `read --json` equals the new script's `read` JSON for every message.
   - Its `thread` on a channel post works, and so do `agents` and `claims`.
2. **The old script's inbox.**
   - Its `inbox alpha` succeeds, and holds beta's channel post (tied to alpha's claimed file) but not lead's.
   - The new script's `inbox alpha --peek` holds both.
   - The two scripts share read marks. Afterwards, the new `inbox alpha --unread` holds lead's post but not beta's, because the old inbox marked beta's read. Check each by its id.
3. **The old script replies into a channel.**
   - The old `post alpha --reply-to <lead's channel post>` goes to `lead` (its old rule).
   - The old `post lead --reply-to <lead's own channel post>` goes to `team:board`.
   - The new script's `read --team board` then holds that second reply, and its `inbox beta` holds it as well.
4. **The old script cannot address a team.** The old `post alpha --to team:board --topic x` fails with exit status 1, as an invalid agent name, and stores nothing.
5. **The old `purge` deletes a member's agent and its member row, and keeps the team and its tasks.**
   - Set `alpha`'s `last_seen` to `2026-01-01T00:00:00Z` with plain SQL.
   - The old `purge --older-than 1` succeeds.
   - Then, with the new script, `teams board` lists `beta` as the only member, still led by `lead`, and `tasks` still lists the task, assigned to `alpha`: a plain name outlives its agent.
6. **The old `reset` and the new board.**
   - The old `reset --yes` succeeds and empties agents, claims, and messages. The member rows go with the agents.
   - The teams and tasks, which the old script does not know, are still there: the new `teams` lists `board` with no members, and the new `tasks` lists the task.
   - The new `reset --yes` then clears them: `"teams": 1, "tasks": 1` in its JSON.
7. **The new script on a board that the old one filled.**
   - The old script registers `lead` and `alpha`, claims, and posts.
   - The new script creates a team with them as lead and member, posts to its channel, and adds a task. All of it succeeds, and the old posts are unchanged in the new `read`.
   - The old `read` then shows the new channel post.
8. **Foreign keys hold.** After tests 5 and 6, `PRAGMA foreign_key_check` on the board returns no rows. Make it a small assertion helper, and call it in both.

## Not yours
bbs.py: if a test finds a fault there, do not fix it. Post a finding to `board-lead` with the failing test's name, mark the test with `@unittest.expectedFailure` and a comment naming the finding, and report it.

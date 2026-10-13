# Task `housekeeping`: `register --team`, `team remove`, `purge`, and `reset`

Worker `board-housekeeping`, on branch `board/housekeeping` from `team/board`. Read `common.md` and `design.md` beside this file first. Two other workers change bbs.py at the same time, `board-channels` and `board-tasks`, in other functions. Stay inside what is named here, so that the three branches fit together.

## What earlier tasks added
These are already on `team/board`:
- **Tables.** `teams`, `team_members` (its member rows cascade with their agent and their team), `tasks`, and `task_files`, which cascade with their team. See `SCHEMA_ADDITIONS`.
- **In the Teams section:**
  - `TEAM_PREFIX`, `team_address`, and `require_team(conn, raw)`;
  - `load_teams` and `describe_team`;
  - `add_member(conn, team, agent) -> bool`, which adds a member unless the agent leads the team or is already in it;
  - `post_to_team(conn, sender, team, topic, *, tag="notice", body="")`;
  - `cmd_team_create`, `cmd_team_add`, and `cmd_teams`.
- **The parser.** The `team` group, made with `command_group`, holds `create` and `add`.

Get the current lines with:

    grep -nE "^def (cmd_register|add_member|post_to_team|cmd_team_add|cmd_teams|cmd_purge|cmd_reset)|register = command|team_add|purge = command|reset = command|class (RegistrationTests|TeamTests|HousekeepingTests)" .claude/skills/agent-bbs/scripts/bbs.py .claude/skills/agent-bbs/tests/test_bbs.py

Read `cmd_register`, `cmd_team_add` (your model for `team remove`), `cmd_purge`, `cmd_reset`, and their parser blocks once. Then read the tests in `HousekeepingTests`, two of which you will update.

## Behavior
1. **`register NAME ... --team TEAM ...`** joins teams while registering.
   - The parser gets `--team`, with `nargs="+"`, `action="extend"`, `default=[]`, metavar TEAM, and the help "teams to join (TEAM or team:TEAM; the team must exist)". It may be repeated, like `--files`.
   - In `cmd_register`, after `add_claims`, for each team (through `require_team`, repeats dropped in order): when `add_member(conn, team, name)` adds the agent, post `Joined team {team}` from the agent to that channel.
   - An unknown team raises, and the whole registration rolls back: a first registration then leaves no agent behind.
   - A team the agent already leads or belongs to changes nothing, and posts nothing.
   - **Text:** one line per team joined, `Joined team {team}.`, placed after the claims' overlap line and before the unread reminder.
   - **JSON:** `data["joined"]`, the list of teams joined.
   - Update the docstring.
2. **`cmd_team_remove`**, for `team remove NAME TEAM AGENT ...`. Put it right after `cmd_team_add`.
   - Normalize the agents with `normalize_name`, dropping repeats in order. They need not be registered.
   - Inside the transaction: check the actor with `require_agent`; `team = require_team(conn, args.team)`; delete each one's member row.
   - When any were removed, post `Removed {a, b} from team {team}` to the channel.
   - **Text:** `Removed a, b from team board.` when any were removed; then, for each agent not removed, `{agent} is not a member of team {team}.` (this covers the lead, who is not a member row); then `describe_team`.
   - **JSON:** `{"team": <dict>, "removed": [...], "not_members": [...]}`.
   - **The parser:** `team remove`, right after `team add`, with the summary "remove members from a team": `name`, `team`, and `agents` (`nargs="+"`, metavar AGENT, "members to remove").
   - Change the `team` group's summary to "create a team or change its members", if it does not say that already.
3. **`cmd_reset`** also empties teams and tasks.
   - It counts `agents`, `claims`, `messages`, `teams`, and `tasks`.
   - It deletes messages, agents, and teams; the cascades take claims, read marks, members, tasks, and task files.
   - **Text:** `Reset the board: removed 1 agent, 1 claim, 1 message, 1 team, and 1 task.`
   - **The refusal without `--yes`:** `reset deletes every agent, claim, message, team, and task on the board; add --yes to confirm`.
   - **The parser's summary:** "delete every agent, claim, message, team, and task".
   - **JSON:** the five counts.
   - Update the docstring.
4. **`cmd_purge`** also deletes idle teams.
   - **The rule.** After deleting the old messages and agents (in the same transaction), delete every team created before the cutoff whose channel no longer holds any message:

         DELETE FROM teams WHERE created_at < ? AND NOT EXISTS
             (SELECT 1 FROM messages m WHERE m.recipient = ? || teams.name)

     Bind the cutoff and `TEAM_PREFIX`.
   - **Why it is right** (say so in the docstring): every change to a team or its tasks posts to its channel, so a channel with nothing newer than the cutoff means a team idle that long. Members, tasks, and task files go with it.
   - **Text:** `Purged 3 messages, 0 agents, and 0 teams older than 1 day.`
   - **JSON:** adds `"teams"`.
   - **The parser.** The summary becomes "delete old messages, and agents and teams idle for a while". The `--older-than` help becomes "delete messages posted, agents last seen, and teams last active more than DAYS days ago (fractions allowed)".

## Tests
- **Update `HousekeepingTests`.**
  - The reset test's exact dict gains `"teams": 0, "tasks": 0`.
  - The purge text becomes `Purged 3 messages, 0 agents, and 0 teams older than 1 day.`
  - Keep everything else those tests check.
- **Add to `HousekeepingTests`:**
  1. Reset clears teams, members, tasks, and task files.
     - Insert one task and one task file with plain SQL, since `task add` comes from a parallel task, and say so in a comment.
     - The JSON counts them, the text pins the sentence, and `count_rows` is 0 for `teams`, `team_members`, `tasks`, and `task_files`.
  2. Purge deletes a team created five days ago whose channel holds nothing newer than the cutoff, with its members and tasks. It keeps a team created five days ago that has a recent post in its channel, and a team created an hour ago. Use `self.clock`.
  3. Purging an agent takes its member rows, but not a team it leads.
     - Five days ago, register `stale` and `gone`.
     - An hour ago, `fresh` creates `board` with `--lead stale`, and adds `gone`. Neither command refreshes `stale` or `gone`.
     - After `purge --older-than 2`, `stale` and `gone` are deleted, and `board` stays, still led by `stale`, with no members.
- **Add to `TeamTests`, at its end:**
  4. `register` with `--team board` joins, says `Joined team board.`, gives `"joined": ["board"]`, and posts `Joined team board` from the agent to `team:board`.
  5. `--team` on a later registration joins too. Joining a team the agent already leads, or already belongs to, posts nothing.
  6. `register newbie ... --team nope` fails with "there is no team 'nope'", and leaves no agent `newbie` and no post.
  7. `team remove`:
     - removes members, and posts one line;
     - reports `{agent} is not a member of team board.` for strangers and for the lead;
     - posts nothing when nobody was removed;
     - fails for an unknown team.
     - `teams board` no longer lists the removed members.

## Not yours
- `post`, `read`, `inbox`, `watch`, `collect_inbox`, and anything about tasks besides the counts and deletes in `reset` and `purge`.
- TAGS.

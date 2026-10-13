# Task `teams`: team names, addresses, `team create`, `team add`, and `teams`

Worker `board-teams`, on branch `board/teams` from `team/board`. Read `common.md` and `design.md` beside this file first.

The `schema` task has already added the `teams`, `team_members`, `tasks`, and `task_files` tables (see `SCHEMA_ADDITIONS`). Line numbers below are from before that task, so get today's with:

    grep -nE "^EVERYONE|^def (normalize_name|one_line|_did_you_mean|cmd_post|cmd_watch|build_parser)|^# (Inbox|Housekeeping)|    def command|watch = command|purge = command" .claude/skills/agent-bbs/scripts/bbs.py

## What is there now
Read these once:
- **`normalize_name(raw)`** (about lines 226-240). Its errors are "'all' addresses every agent and cannot be an agent name" and "invalid agent name {raw!r}: use 1 to 40 letters, ...". Tests pin both.
- **`one_line(value, field)`** (243-250) and `MAX_LINE_LENGTH = 200` (line 73).
- **`_did_you_mean(conn, name)`** (809-813). It suggests the closest name from `SELECT name FROM agents`.
- **`cmd_post`** (1245-1279). Its `INSERT INTO messages` and `INSERT INTO message_files` (1258-1266) store a post.
- **`build_parser`** (1576-1726). Its `command(...)` helper (1595-1601) adds one top-level command with `--json`. The watch command's block ends at 1711, and `purge` follows.

## Behavior
### Helpers
1. **`normalize_name(raw, kind="agent")`.** It names agents and teams, and its errors name the kind: "an agent name" or "a team name", and "invalid agent name" or "invalid team name". An agent's errors stay word for word as they are. Update the docstring.
2. **`_did_you_mean(conn, name, table="agents")`.** It suggests from `SELECT name FROM {table}`. The docstring says that `table` is always a constant from the code, never the user's text.
3. **`TEAM_PREFIX = "team:"`.** Add it in the constants, after `EVERYONE`, with a `#:` comment: the prefix that turns a team's name into the address of its channel, as in "team:board".
4. **`clip_line(text) -> str`.** Put it after `one_line`. It returns `text` when it fits `MAX_LINE_LENGTH`, and otherwise its first `MAX_LINE_LENGTH - 1` characters followed by "…". The docstring says it is for topics that the board writes itself, which can outgrow the limit when they quote a title or list names.
5. **`insert_message(conn, sender, recipient, tag, topic, body="", *, reply_to=None, files=()) -> int`.**
   - Put it in the Messages section, before `cmd_post`. It holds `cmd_post`'s two inserts, and `cmd_post` calls it.
   - It runs inside the caller's write transaction, and returns the new message's id.
   - Every existing test must still pass unchanged.

### A new `# Teams` section
Put it after the Inbox section, just before `# Housekeeping`, in this order:

6. **`team_address(team) -> str`** returns `TEAM_PREFIX + team`.
7. **`normalize_team(raw) -> str`** returns a team's canonical name, whether the user typed the plain name or the address. It drops a leading `team:`, in any letter case, then calls `normalize_name(..., "team")`.
   **`require_team(conn, raw) -> str`** returns `normalize_team(raw)` when that team exists. An unknown team raises `there is no team '{name}'{_did_you_mean(conn, name, "teams")}; list the teams with: bbs.py teams`. Build it from `PROG`.
8. **`load_teams(conn, *, name=None) -> List[dict]`.**
   - It returns JSON-ready dicts ordered by name: `{"name", "lead", "purpose", "created", "channel", "members"}`.
   - `channel` is the team's address.
   - `members` lists member names in the order they joined (`ORDER BY joined_at, rowid`), without the lead.
   - `name` selects one team.
9. **`describe_team(team) -> str`** gives these lines:

       board: led by board-lead, created 20:39
         Purpose: Teams, channels, and task lists on the board
         Channel: team:board
         Members: board-schema, board-teams

   The time comes from `local_label`. With no members, the last line reads `  Members: none`.
10. **`add_member(conn, team, agent) -> bool`.** It adds a member row (`joined_at` now) unless the agent leads the team or is already a member, and returns whether it added one. The `housekeeping` task reuses it for `register --team`.
11. **`post_to_team(conn, sender, team, topic, *, tag="notice", body="") -> int`** posts one line to a team's channel, with `insert_message(conn, sender, team_address(team), tag, clip_line(topic), body)`.

### Commands
12. **`cmd_team_create`**, for `team create NAME TEAM --purpose "ONE LINE" [--lead AGENT]`.
    - The purpose goes through `one_line(..., "purpose")`, and the team name through `normalize_team`, so `team create lead team:board` also makes `board`.
    - Inside the transaction:
      - `actor = require_agent(conn, args.name)`;
      - the lead is the actor, or `require_agent(conn, args.lead, touch=False)`;
      - a team that already exists raises `team {name} exists already; see it with: bbs.py teams {name}`;
      - insert the row, `created_at` now;
      - post to its channel from the actor, with the topic `Created team {name}, led by {lead}` and the purpose as the body.
    - Text: `Created team {name}.`, then `describe_team`. JSON: the team's dict.
13. **`cmd_team_add`**, for `team add NAME TEAM AGENT ...`.
    - Normalize the agents, dropping repeats in order (`dict.fromkeys`).
    - Inside the transaction:
      - check the actor with `require_agent`;
      - `team = require_team(conn, args.team)`;
      - check every agent with `require_agent(conn, agent, touch=False)` before adding any, so an unknown agent fails the whole command;
      - call `add_member` for each;
      - when any were added, post `Added {a, b} to team {team}` to the channel (agents joined with ", ").
    - Text, in this order:
      - `Added a, b to team board.` when any were added;
      - a line for each one skipped: `{agent} already leads team {team}.` or `{agent} is already a member of team {team}.`;
      - then `describe_team`.
    - JSON: `{"team": <dict>, "added": [...], "already": [...]}`.
14. **`cmd_teams`**, for `teams [TEAM]`.
    - Without TEAM, the text is `No teams yet.`, or `{plural(n, 'team')}:` followed by each team's description, separated by blank lines, as `cmd_agents` does.
    - With TEAM (through `require_team`), the text is that team's description alone.
    - JSON: always a list.

### The parser
15. **The helpers.**
    - Give `command(...)` a keyword `group=None`. It adds the command to `commands` when `group is None`, and otherwise to `group`.
    - Add `command_group(name, summary)`. It adds a top-level parser that has no handler (same `help`, `description`, and `allow_abbrev=False`), and returns `parser.add_subparsers(dest=f"{name}_command", metavar="SUBCOMMAND", required=True)`.
    - Give each helper a docstring. Leaf commands keep `parents=[json_flag]`, so `--json` works before or after.
16. **The commands.** After the watch block and before `purge`, add:
    - `team`, a group with the summary "create a team or change its members";
    - `team create`, with the summary "create a team with its lead and purpose": `name` ("your agent name"), `team` (metavar TEAM, "the new team's name, such as board"), `--purpose` (required, "one line saying what the team is for"), and `--lead` (metavar AGENT, "the agent who leads the team (default: you)");
    - `team add`, with the summary "add members to a team": `name`, `team`, and `agents` (`nargs="+"`, metavar AGENT, "registered agents to add");
    - `teams`, with the summary "list teams with their lead and members, or show one": `team` (`nargs="?"`, metavar TEAM, "only this team").

## Tests
Add a new class, `TeamTests(BoardTestCase)`, placed right after `WatchTests` and before `HousekeepingTests`. Its docstring reads: team create, team add, teams, and team names. Register a few agents in `setUp`.
1. `team create`:
   - its JSON has every field, and the lead defaults to the actor;
   - `--lead` names another registered agent;
   - `team create lead team:Polish ...` makes the team `polish`;
   - the text has `Created team board.` and each line of the description, pinned;
   - its channel holds one notice from the actor to `team:board`, with the topic and the purpose as the body. Check with `self.ok_json("read")`.
2. `team create` refuses:
   - an unknown actor or lead;
   - an existing team ("exists already");
   - the names `all`, `ALL`, `two words`, and 41 characters, with "a team name" or "invalid team name";
   - a missing `--purpose`, a blank one, and a purpose of 201 characters.
3. `team add`:
   - adds in order and drops repeats;
   - skips the lead and existing members, with the exact lines;
   - an unknown agent adds nobody;
   - posts one line, and none when nobody was added.
4. A long `team add` list is clipped: add enough agents with 40-character names that the line passes 200 characters. The stored topic is then exactly 200 characters long and ends with "…".
5. `teams`:
   - shows `No teams yet.` and `2 teams:`;
   - a team, by its name or by `team:NAME` in any letter case;
   - an unknown team fails with "did you mean";
   - its JSON is a list.
6. `team` without a subcommand fails with one line; `--json` works before and after `teams` and `team create`.
7. A team and an agent may share a name.
8. `clip_line` leaves 200 characters alone, and clips 201 to 200 ending with "…". Call `bbs.clip_line` directly.

## Not yours
- Membership through `register`, `team remove`, `purge`, `reset`, inbox routing, `post --to team:`, and tasks: later tasks do those.
- Leave TAGS alone.

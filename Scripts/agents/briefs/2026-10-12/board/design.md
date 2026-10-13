# Team board: the design

This is the whole feature, so that each task fits the others. Your brief says which part is yours. The user asked on October 12 to "build out the bbs so if its not already allows for agent teams / subforums basically for them to communicate".

## The data
All of it is additive, and `PRAGMA user_version` stays 1.
- **Why.** Older copies of bbs.py are still run from older worktrees. They refuse any board whose `user_version` is above 1. So the new script never raises the version. Instead, each time it opens a board, it creates whatever is missing of the tables below (task `schema`).
- **The tables.** Arrows are foreign keys:

      teams        (name PRIMARY KEY, lead, purpose, created_at)
      team_members (team -> teams ON DELETE CASCADE, agent -> agents ON DELETE CASCADE, joined_at;
                    PRIMARY KEY (team, agent))
      tasks        (id INTEGER PRIMARY KEY AUTOINCREMENT, team -> teams ON DELETE CASCADE, title,
                    brief (NULL when none), state DEFAULT 'open', assignee (NULL when none), note DEFAULT '',
                    created_at, created_by, updated_at, updated_by)
      task_files   (task_id -> tasks ON DELETE CASCADE, path; PRIMARY KEY (task_id, path))

- **Plain names, not references.** `teams.lead`, `tasks.assignee`, `tasks.created_by`, and `tasks.updated_by` hold plain agent names. Older scripts delete agents (`purge`, `reset`) with foreign keys on and know nothing of these tables, so a plain reference there would make those deletes fail. A team therefore keeps its lead's name, and a task its assignee's, after the agent is purged.
- **What cascades.** A member row goes with its agent. Members, tasks, and task files go with their team.
- **The lead.** The lead is not a member row. "In a team" means leading it or being a member of it.

## Addresses and channels
- **The address.** A team's channel is addressed `team:<name>` wherever a message names its reader, as in `post --to team:board`. Team names follow the agent-name rule: lower case, at most 40 characters, with `all` reserved. Wherever a command takes a TEAM, it accepts the plain name or the address.
- **Why `team:`.**
  - A team may share a name with an agent, and neither can be taken for the other, or for `all`.
  - Older scripts refuse `team:board` as an agent name rather than misread it.
  - A stored recipient says plainly that a message went to a team.
- **Storage.** A channel post keeps `team:<name>` in the messages table's recipient column; there is no new column. A team's channel is every message whose recipient is its address.
- **Who it reaches.** A post to a team reaches the inbox of its lead and of every member: a member's from when it joined, and the lead's from its registration, like a post to `all`. Messages tied to files still reach whoever claims those files.
- **Replies** stay in the channel of the message they answer.
- **History.** Each change to a team (created, members added or removed, joined) posts one `notice` line to its channel. Each change to a task posts one `task` line. So the channel is the team's history. These lines are sentences whose subject is the sender, such as "Added task 3: Channels". A line longer than the 200-character topic limit is clipped, ending in "…".

## Commands (the finished set)
NAME is always the agent running the command, and it comes first, as in every existing command. Every command takes `--json`.

| Command | What it does | Task |
| --- | --- | --- |
| `bbs team create NAME TEAM --purpose "ONE LINE" [--lead AGENT]` | creates a team; the lead defaults to NAME | `teams` |
| `bbs team add NAME TEAM AGENT ...` | adds registered agents as members | `teams` |
| `bbs teams [TEAM]` | lists every team, or shows one | `teams` (`tasks` adds task counts) |
| `bbs register NAME ... [--team TEAM ...]` | joins teams while registering | `housekeeping` |
| `bbs team remove NAME TEAM AGENT ...` | removes members | `housekeeping` |
| `bbs purge ...`, `bbs reset --yes` | also clear idle teams, or all teams and tasks | `housekeeping` |
| `bbs post NAME --to team:TEAM ...` | posts to a team's channel | `channels` |
| `bbs read --team TEAM`, `bbs inbox NAME --team TEAM`, `bbs watch NAME --team TEAM` | limit to one team's channel | `channels` |
| `bbs task add NAME TEAM --title "ONE LINE" [--brief PATH] [--files PATH ...] [--assign AGENT]` | adds a task | `tasks` |
| `bbs tasks [--team TEAM] [--state STATE] [--agent AGENT]` | lists tasks | `tasks` |
| `bbs task assign NAME ID AGENT [--note "ONE LINE"]` | assigns a task | `task-states` |
| `bbs task move NAME ID STATE [--note "ONE LINE"]` | moves a task to another state | `task-states` |

Task states: `open`, `assigned`, `working`, `review`, `done`, `dropped`.

## The tasks, in order
1. `schema`: the tables, their migration, and a harness that runs the pre-teams script in the tests.
2. `teams`: team names and addresses, `team create`, `team add`, and `teams`.
3. In parallel:
   - `channels`: posting to teams, replies, the inbox, and `--team` on `read`, `inbox`, and `watch`;
   - `tasks`: `task add`, `tasks`, and the task counts in `teams`;
   - `housekeeping`: `register --team`, `team remove`, `purge`, and `reset`.
4. In parallel: `task-states` (`task assign`, `task move`) and `compat` (the old script on boards that hold teams).
5. `docs`: SKILL.md and the protocol's team etiquette.

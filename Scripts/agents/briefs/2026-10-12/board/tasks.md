# Task `tasks`: `task add`, `tasks`, and task counts in `teams`

Worker `board-tasks`, on branch `board/tasks` from `team/board`. Read `common.md` and `design.md` beside this file first. Two other workers change bbs.py at the same time, `board-channels` and `board-housekeeping`, in other functions. Stay inside what is named here, so that the three branches fit together.

## What earlier tasks added
These are already on `team/board`:
- **Tables.** `tasks` and `task_files` (see `SCHEMA_ADDITIONS` for their columns), alongside `teams` and `team_members`.
- **In the Teams section:**
  - `team_address`;
  - `require_team(conn, raw)`, which takes `board` or `team:board`;
  - `load_teams(conn, *, name=None)`, which returns dicts with `name`, `lead`, `purpose`, `created`, `channel`, and `members`;
  - `describe_team(team)`;
  - `post_to_team(conn, sender, team, topic, *, tag="notice", body="")`, which clips the topic to 200 characters with `clip_line`.
- **The parser.** `command(..., group=...)` and `command_group(name, summary)` make subcommands, as `team create` shows.

Get the current lines with:

    grep -nE "^TAGS|^ACTIVITIES|^def (load_teams|describe_team|post_to_team|cmd_teams|normalize_patterns|query_messages)|^# (Teams|Housekeeping)|teams = command|team = command_group|purge = command" .claude/skills/agent-bbs/scripts/bbs.py

`query_messages` shows how to gather a row's files from a join.

## Behavior
### Constants
1. **TAGS** gains `"task"` at its end. Its comment says that `task` marks the lines the board posts when a task changes.
2. **`TASK_STATES`.** After `ACTIVITIES`, add `TASK_STATES = ("open", "assigned", "working", "review", "done", "dropped")`. Its `#:` comment gives the order of a task's life: `open` (no one has it yet), then `assigned`, `working`, and `review`, ending `done` or `dropped`.

### A new `# Tasks` section
Put it right after the Teams section, before `# Housekeeping`, in this order:

3. **`load_tasks(conn, *, task_id=None, team=None, state=None, assignee=None) -> List[dict]`.**
   - It returns JSON-ready dicts ordered by id: `{"id", "team", "title", "state", "assignee", "brief", "files", "note", "created", "created_by", "updated", "updated_by"}`.
   - `assignee` and `brief` are None when the task has none.
   - `files` comes in the order the files were stored.
   - Each argument that is given adds one condition.
   - Use one `LEFT JOIN task_files`, gathered as `query_messages` does.
4. **`describe_task(task) -> str`.** Its first line, then only the detail lines that have something to say:

       Task 3 in board, working, assigned to board-teams: Schema and teams
         Brief: Scripts/agents/briefs/2026-10-12/board/schema.md
         Files: .claude/skills/agent-bbs/scripts/bbs.py, .claude/skills/agent-bbs/tests/test_bbs.py
         Note: tests pass
         Changed: 20:39 by board-teams

   A task with no assignee leaves out ", assigned to ...": `Task 4 in board, open: Channels`. The `Changed:` line is always there. Its time comes from `local_label`.
5. **`assignee_reminder(conn, task) -> str`.** It returns `{assignee} has not registered yet.` when the task has an assignee whom no agent row names, and "" otherwise. The `task-states` task reuses it.
6. **`cmd_task_add`**, for `task add NAME TEAM --title "ONE LINE" [--brief PATH] [--files PATH ...] [--assign AGENT]`.
   - **Inputs:**
     - the title goes through `one_line(..., "title")`;
     - the brief, when given, through `normalize_patterns([args.brief])[0]`;
     - the files through `normalize_patterns(args.files)`;
     - `--assign` through `normalize_name`. The assignee need not be registered yet: a lead plans tasks before its workers start.
   - **Inside the transaction:**
     - check the actor with `require_agent`;
     - `team = require_team(conn, args.team)`;
     - insert the task, with state `assigned` when there is an assignee and `open` otherwise, both times now, and both "by" columns the actor;
     - insert its files;
     - post to the channel with `tag="task"`: `Added task {id}: {title}`, or `Added task {id} for {assignee}: {title}`.
   - **Text:** `Added task {id} to team {team}.`, then `describe_task`, then the reminder's line, when there is one.
   - **JSON:** the task's dict.
7. **`cmd_tasks`**, for `tasks [--team TEAM] [--state STATE] [--agent AGENT]`.
   - `--team` goes through `require_team`, and `--agent` through `normalize_name`.
   - The text is one of:
     - `No tasks yet.` when no filter was given;
     - `No tasks match.` when one was;
     - `{plural(n, 'task')}:` followed by each task's description, separated by blank lines.
   - **JSON:** a list.

### Teams show their tasks
8. **`load_teams`** adds `"tasks": load_tasks(conn, team=<name>)` to each team.
9. **`describe_team`** adds a last line counting the tasks in each state, in `TASK_STATES` order, leaving out states with none. `review` reads "in review":

       Tasks: 1 open, 2 working, 1 in review, 3 done

   With no tasks, the line reads `  Tasks: none`. Any test in `TeamTests` that compares a whole team dict, or the whole text, needs the new key or line: update those.

### The parser
10. **The commands.** After the `teams` command and before `purge`, add:
    - `task`, a group made with `command_group`, with the summary "add tasks to a team's list and move them through their states";
    - `task add`, with the summary "add a task to a team's list":
      - `name` ("your agent name");
      - `team` (metavar TEAM, "the team whose list gets the task");
      - `--title` (required, "one line saying what the task is");
      - `--brief` (metavar PATH, "the task's brief, relative to the repository root");
      - `--files` (`nargs="+"`, `action="extend"`, `default=[]`, metavar PATH, "paths or globs the task will touch");
      - `--assign` (metavar AGENT, "the agent who takes the task; it may register later");
    - `tasks`, with the summary "list tasks by team, state, or agent":
      - `--team` (metavar TEAM, "only this team's tasks");
      - `--state` (`choices=TASK_STATES`, "only tasks in this state");
      - `--agent` (metavar AGENT, "only tasks assigned to this agent").

## Tests
Add a new class, `TaskTests(BoardTestCase)`, at the very end of the file, after `SchemaTests`. Its docstring reads: task lists, task add, tasks, and the task counts in teams.

In `setUp`, register `lead`, `alpha`, and `beta`; create team `board` led by `lead`; and create team `polish` led by `beta`. Those two creations take message ids 1 and 2.
1. **`task add`, with everything given.**
   - Its JSON has every field.
   - The brief and files are normalized: `./x/../Scripts/a.md` is stored as `Scripts/a.md`.
   - The state is `open`, and the assignee None.
   - The times and both "by" columns are set.
   - Its text pins each line of the description.
2. **`--assign`.**
   - It sets `assigned` and the assignee.
   - An unregistered assignee adds `nobody-yet has not registered yet.`, and a registered one adds no such line.
3. **The channel.**
   - `read --team board --tag task` holds `Added task 1: ...` and `Added task 2 for alpha: ...`, from the actor, to `team:board`.
   - A 200-character title is kept whole on the task, while the channel's topic is clipped to 200 characters ending with "…".
4. **Refusals.**
   - An unknown team, with "did you mean".
   - An unknown actor.
   - A missing, blank, or 201-character title.
   - A brief outside the repository (`../x.md`).
5. **Ids** count up across teams: a task in `polish` after one in `board` gets id 2.
6. **`tasks`.**
   - It lists every task.
   - It filters by `--team` (also as `team:board`), by `--state`, and by `--agent`, and by any two together.
   - It shows `No tasks yet.` and `No tasks match.`.
   - `--state nonsense` fails.
   - Its JSON is a list.
7. **`teams` with tasks.**
   - `teams board` shows `Tasks: none`, then `Tasks: 1 open, 1 assigned` after two adds.
   - `ok_json("teams")[0]["tasks"]` lists them.
   - Use direct SQL in the test to set one task's state to `review`, to pin "1 in review", since `task move` comes from a later task. Say so in a comment.
8. **`--json`** works on `task add` and on `tasks`.

## Not yours
- `task assign` and `task move` belong to the next task, `task-states`.
- Inbox routing, `post`, `read`, `register`, `team remove`, `purge`, and `reset`.

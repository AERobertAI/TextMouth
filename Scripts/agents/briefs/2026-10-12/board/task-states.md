# Task `task-states`: `task assign` and `task move`

Worker `board-task-states`, on branch `board/task-states` from `team/board`. Read `common.md` and `design.md` beside this file first. `board-compat` works at the same time, in the tests only.

## What earlier tasks added
These are already on `team/board`:
- **Constants.** `TASK_STATES = ("open", "assigned", "working", "review", "done", "dropped")`, and the `task` tag.
- **In the Tasks section:**
  - `load_tasks(conn, *, task_id=None, team=None, state=None, assignee=None)`;
  - `describe_task(task)`;
  - `assignee_reminder(conn, task)`;
  - `cmd_task_add`, which shows how a task is stored and announced;
  - `cmd_tasks`.
- **In the Teams section:** `post_to_team(conn, sender, team, topic, *, tag="notice", body="")`, which clips the topic.
- **The parser.** The `task` group, with `add`, and the `tasks` command.

Get the current lines with:

    grep -nE "^TASK_STATES|^def (load_tasks|describe_task|assignee_reminder|cmd_task_add|cmd_tasks|positive_int)|task_add|tasks = command|class TaskTests" .claude/skills/agent-bbs/scripts/bbs.py .claude/skills/agent-bbs/tests/test_bbs.py

Read `cmd_task_add` and the task parser block once, and skim `TaskTests` for its `setUp`.

## Behavior
Put the new functions in the Tasks section, right after `cmd_task_add`.
1. **`require_task(conn, task_id) -> dict`** returns one task's dict, or raises `there is no task {id}; list the tasks with: bbs.py tasks`. Build it from `PROG`.
2. **`cmd_task_assign`**, for `task assign NAME ID AGENT [--note "ONE LINE"]`.
   - The agent goes through `normalize_name` (it may register later), and the note through `one_line(..., "note", allow_empty=True)`, or "" when it is left out.
   - Inside the transaction:
     - check the actor with `require_agent`;
     - `task = require_task(...)`;
     - set the assignee, state `assigned`, the note, `updated_at` to now, and `updated_by` to the actor;
     - post `Assigned task {id} to {agent}: {title}` to the task's team with `tag="task"` and the note as the body.
   - Assigning works from any state; a `done` or `dropped` task assigned again comes back to life as `assigned`.
   - **Text:** `Assigned task {id} to {agent}.`, then `describe_task`, then the reminder's line, when there is one.
   - **JSON:** the task's dict.
3. **`cmd_task_move`**, for `task move NAME ID STATE [--note "ONE LINE"]`. STATE is one of `TASK_STATES`.
   - **`open`** clears the assignee: an open task is one that no one has.
   - **`assigned`, `working`, and `review`** need an assignee. Without one, raise:

         task {id} has no assignee; assign it with: bbs.py task assign {actor} {id} AGENT

   - **`done` and `dropped`** keep whatever assignee the task has.
   - **The same state again** is allowed: a way to post a progress note.
   - Set the state, the assignee as above, the note (a move without `--note` clears it), `updated_at`, and `updated_by`.
   - Post `Moved task {id} to {state}: {title}` with `tag="task"` and the note as the body.
   - **Text:** `Moved task {id} to {state}.`, then `describe_task`.
   - **JSON:** the task's dict.
   - Factor the update shared with `cmd_task_assign` (the columns, the times, and the post) into one helper, `change_task(conn, actor, task, *, state, assignee, note, topic)`, to keep it DRY.
4. **The parser.** Right after `task add`, add:
   - `task assign`, with the summary "give a task to an agent": `name`, `id` (`type=positive_int`, metavar ID, "the task's number"), `agent` (metavar AGENT, "the agent who takes the task; it may register later"), and `--note` ("one line to go with the change");
   - `task move`, with the summary "move a task to another state": `name`, `id`, `state` (`choices=TASK_STATES`, "the task's new state"), and `--note`.

## Tests
Append these to `TaskTests`, at the end of the file:
1. **`task assign`.**
   - It sets the assignee, state `assigned`, and the note.
   - The channel line is `Assigned task 1 to alpha: ...`, with the note as its body.
   - The text pins `Assigned task 1 to alpha.`.
   - An unregistered agent gets the reminder line.
   - Assigning again to another agent replaces the first.
   - A `done` task assigned again is `assigned`.
2. **`task move`.**
   - `working`, `review`, and `done` keep the assignee.
   - `open` clears it.
   - `assigned`, `working`, and `review` on a task with no assignee fail with the exact hint, naming the actor and the id.
   - `dropped` works with or without an assignee.
   - The channel line is `Moved task 1 to review: ...`, with the note as its body.
   - A move without `--note` clears the note.
   - The same state again posts a second line.
3. **Every change** moves `updated` and `updated_by` (use `self.clock`), and never `created` or `created_by`.
4. **Refusals.**
   - An unknown task fails with "there is no task 9".
   - An id of 0 or `x` fails.
   - An unknown state fails with "invalid choice".
   - An unknown actor fails.
   - A 201-character note fails.
5. **The lists follow along.** After moves, `tasks --state working` and `teams board` (`Tasks: 1 working, 1 done`) reflect them. If `TaskTests` set a state with SQL only because `task move` did not exist yet, replace that with `task move`.
6. **A worker's day, end to end.** The lead adds a task for `alpha`; `alpha` moves it to `working`, then to `review` with a note; the lead moves it to `done`. `read --team board --tag task` then holds the four lines in order.

## Not yours
Everything outside the Tasks section, the task parser block, and `TaskTests`.

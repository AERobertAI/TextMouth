# board2 task: warn when a new task's files overlap (task 30)

Slug `board2-overlap`, branch `board2/overlap`, board task **30**. Read `common.md` beside this file first.

## Why
A team's tasks should touch separate files, since the team pattern runs them side by side. `task add` should warn when the new task's files overlap those of another **unfinished** task in the **same team**, by the claims' overlap rule. The task is added all the same: this is a warning, not a refusal.

## bbs.py (line numbers are for `team/board2` as you branch from it)
1. **A constant,** right after `TASK_STATES` (line 91), with a `#:`-style comment: `FINISHED_TASK_STATES = ("done", "dropped")`, the states in which a task no longer touches its files.
2. **`task_overlaps(conn, task: dict) -> List[dict]`,** right after `assignee_reminder` (lines 1951-1960). It returns the overlapping pairs between `task`'s files and those of every other task in the same team whose state is not in `FINISHED_TASK_STATES`.
   - Get the tasks with `load_tasks(conn, team=task["team"])`, and decide overlap with `patterns_overlap` (line 357), the claims' rule.
   - Order the pairs by the other task's id, then by the new task's file order, then by the other task's file order.
   - Each pair is `{"first": {"task": <new id>, "path": <its path>}, "second": {"task": <other id>, "path": <its path>}}`, mirroring the claims' `{"first", "second"}` pairs.
3. **`describe_task_overlaps(team: str, overlaps: List[dict]) -> str`,** next to it, in the style of `describe_overlaps` (lines 1125-1135). It returns `""` when there are none. Otherwise:
   - a heading, `f"Warning: {plural(len(overlaps), 'overlap')} with unfinished tasks in team {team}:"`;
   - then one line per pair, `f"  task {a} lists {p} and task {b} lists {q}"`.
4. **`cmd_task_add`** (lines 1963-1988): compute `overlaps = task_overlaps(conn, task)` inside the transaction.
   - The text is: the "Added task" line, `describe_task`, the assignee reminder when there is one, then the warning when there is one.
   - The JSON is the task's dict plus `"overlaps"`, always present (an empty list when none): `Outcome(dict(task, overlaps=overlaps), ...)`. Say so in the docstring.
   - Nothing new is posted to the channel.

Touch nothing else: `task assign` and `task move` do not warn, since a task's files never change after it is added.

## Tests (test_bbs.py)
`TaskTests` (line 2027 to the end of the file) registers lead, alpha, and beta, and creates teams `board` (led by lead) and `polish` (led by beta). It has `add(title, team, *extra, actor=...)`, which returns the JSON, and `channel()`.
- **Update** `test_task_add_reports_every_field_of_the_task` (lines ~2048-2075) to expect `"overlaps": []`, and fix any other test that compares `task add`'s whole JSON.
- **New, at the end of `TaskTests`** (the end of the file, before `if __name__`):
  1. `test_task_add_warns_when_files_overlap_an_unfinished_task_in_the_team`:
     - Task 1 has `--files src/a.py docs/`, and task 2 has `--files 'src/*.py' README`.
     - Task 2's text ends with exactly two lines: `Warning: 1 overlap with unfinished tasks in team board:` and `  task 2 lists src/*.py and task 1 lists src/a.py`.
     - Its JSON `overlaps` is `[{"first": {"task": 2, "path": "src/*.py"}, "second": {"task": 1, "path": "src/a.py"}}]`.
     - The task is added all the same, and the channel gets only its usual "Added task" line.
  2. `test_no_warning_without_an_overlap`: disjoint files, and a task with no files, give no line starting `Warning:` and `overlaps == []`.
  3. `test_finished_tasks_and_other_teams_do_not_count`. Task 1 (`src/a.py`) is moved to `done`, a task in `polish` (actor beta) lists `src/a.py`, and a task 3 in board lists `src/a.py`; it gets no warning. Also check `dropped`.
  4. `test_each_overlapping_pair_gets_a_line_in_order`: two unfinished tasks overlap a new task with two files. That gives `Warning: 2 overlaps with unfinished tasks in team board:` and the pairs in the order item 2 above gives.
  5. `test_overlaps_ignore_letter_case_like_claims`: `SRC/A.py` against `src/a.py` warns.

## SKILL.md
At the end of line 82 (the `task add` item), add: "When the new task's files overlap those of an unfinished task in the same team, by the rule for overlapping claims, `task add` warns, naming each pair; the task is added all the same." Change nothing else.

## Commit
One commit: "Warn when a new task's files overlap an unfinished task's".

## Not yours
- Everything in bbs.py but the constant, the two new functions, and `cmd_task_add`.
- Every test class but the end of `TaskTests` and the one test updated above.
- SKILL.md beyond line 82.

# board2 task: `--json` after `team` and `task` (task 29)

Slug `board2-jsonflag`, branch `board2/jsonflag`, board task **29**. Read `common.md` beside this file first.

## Why
`bbs team --json create …` is refused, while `--json` works before `team` (`bbs --json team create …`) and after the subcommand (`bbs team create … --json`). The same holds for `task`.

## The cause and the change
In `build_parser()` (bbs.py lines 2233-2268), `command()` gives every command's parser `parents=[json_flag]`, whose `--json` defaults to `argparse.SUPPRESS`, so that leaving it out never overwrites a `--json` given earlier. `command_group()` (lines 2264-2267), which makes the `team` and `task` parsers, does not.
1. Give `command_group()`'s `add_parser` call `parents=[json_flag]` too. The SUPPRESS default keeps the three positions independent.
2. In `build_parser`'s docstring (lines 2234-2238), "`--json` is accepted before or after the command name" becomes "`--json` is accepted before the command name, after it, or between a command group (`team`, `task`) and its subcommand".

Touch nothing else in bbs.py.

## Tests (test_bbs.py)
Add one method at the end of `RegistrationTests`, right after `test_usage_errors_exit_with_status_1_and_one_line` (line ~272-277): `test_json_flag_is_accepted_after_a_command_group`. Register `chief` and `alpha` with `self.register`, then check each of these with `json.loads(self.ok(...))`:
1. `team --json create chief board --purpose "Build it"` gives a dict whose `name` is `board`.
2. `team --json add chief board alpha` gives `added == ["alpha"]`.
3. `task --json add chief board --title "First"` gives `id == 1`.
4. `task --json assign chief 1 alpha` gives state `assigned`.
5. `task --json move chief 1 working` gives state `working`.
6. `team --json remove chief board alpha` gives `removed == ["alpha"]`.
7. After `alpha` is added again, the three positions give equal JSON:
   - `--json team add chief board alpha`
   - `team --json add chief board alpha`
   - `team add --json chief board alpha`
8. Without `--json` anywhere, the same command prints text that starts with `alpha is already a member of team board.`.
9. `self.fails("team", "--json")` (a group with no subcommand) is still a one-line usage error.

## SKILL.md
Line 18: "Every command prints readable text, or the same data as JSON with `--json`." becomes "Every command prints readable text, or the same data as JSON with `--json`, given before the command, after it, or between `team` or `task` and its subcommand." Change nothing else.

## Commit
One commit: "Accept --json between team or task and its subcommand".

## Not yours
- Everything in bbs.py but `command_group` and `build_parser`'s docstring.
- Every test class but the end of `RegistrationTests`.
- SKILL.md beyond line 18.

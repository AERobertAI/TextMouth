---
name: issue-library
description: TextMouth's issue tracker, one Markdown file per issue in Issues/ (the "TODO lib"). Use it to list, show, search, or count the open work by status, priority, kind, platform, assignee, or label; to see which doc sections cite an issue; as the orchestrator on main, to file an issue with the next free ID, assign it, close it at its merge, or reopen it; as an agent on its branch, to comment on the issue assigned to it and set it in-progress or blocked; and to check every issue file and the TODO's IDs.
---

# issue-library

`issuelib` below is `python3 -I -B .claude/skills/issue-library/scripts/issuelib.py`, run from anywhere in the repository or a worktree.
`Issues/README.md` describes the format; `template.md` beside this file is the file a new issue starts from.

- Output: one line per issue or problem, plain words, no tables; `list` cuts each line to 80 characters (`--width 40`, or `--width 0` for no cut); `--json` prints JSON lines.
- Options follow the command: `--root DIR`, `--todo PATH`, `--json`.
- Exit 0: done; 1: a check found problems, a search found nothing, or a change was refused, said in one line; 2: a command line that names nothing or gives a bad value.

## Reading

- `issuelib list [--status S,S|all] [--priority P] [--kind K] [--platform X] [--assignee NAME|none] [--label L]`: one issue per line by priority, `ID P1 status platform [assignee]: title`; open, in-progress, and blocked unless `--status` says otherwise. `--platform iphone` (or `mac`) includes the issues filed for both; `--platform both`, only those.
- `issuelib show ID`: the file as written, then the doc sections whose marker cites it; for an ID only the TODO has, or an alias, its TODO lines.
- `issuelib search REGEX [--status ...]`: every matching line, `ID:LINE: text`, ignoring case.
- `issuelib summary`: each status's count, split by priority.
- `issuelib check [--new-since FILE]`: every file's header, values, comments, and status rules; that `related` and `docs` name something; that no ID is given twice, in `Issues/` or in the TODO; that the TODO's pointers lead to files whose status their box agrees with; and that no open item is left in the TODO. With `--new-since`, only problems not in FILE (an earlier `check --json`) and in files changed against HEAD, as `merge-chain.sh` runs it.

## Writing

Options and positionals may come in any order (`comment ID --as NAME "text"` works), and a `--` before the first positional parses as it always did.
Each command changes one file, prints one line saying what it did, and takes `--as NAME`, the name it acts and comments under; `close` and `reopen` also tick and untick the issue's pointer line in the TODO.

- `issuelib new --kind K --title T --platform X (--description TEXT | --file F) [--priority P] [--found-by WHO] [--related IDS] [--docs IDS] [--labels L] [--family F | --id ID]`: files the next free ID of the kind's family (bug B, feature FR, format FMT, follow-up FU, test Q, tooling TL, docs DOC, question QN). On a branch it is refused, unless the orchestrator asked for it there: then `--on-branch`, and the ID said on the board, since another branch could take it too.
- `issuelib set ID FIELD VALUE...`: one field, and `updated`; status only to open, in-progress, or blocked.
- `issuelib assign ID AGENT|none [--branch B]`.
- `issuelib comment ID TEXT` (or `--file F`): a dated comment at the file's end; the header is left alone.
- `issuelib close ID (--merged HASH | --reason TEXT) [--status done|wontfix|duplicate] [--date YYYY-MM-DD]`, and `issuelib reopen ID --reason TEXT`.
- `issuelib import-todo [--dry-run]`: moves the TODO's open items into issue files, once; it writes nothing unless every item's words arrive.

## Who changes what

- The orchestrator, on main, files, assigns, closes, and reopens issues, and changes any field; `record-merge.py --close ID --hash HASH` closes an issue at its merge and ticks its pointer line in the TODO.
- An agent, on its own branch, only comments on the issue assigned to it and sets it in-progress or blocked; the script refuses the rest there, so two branches never take one ID.
- Two branches' changes to one issue merge part by part, through the merge driver `.gitattributes` names for `Issues/*.md` (`issuelib merge-driver`, defined once in the repository's config by `make issues-merge-driver`): the header field by field, the description as git would, and each comment whole, in date order. One field changed both ways stops the merge with git's markers in the header; where the driver is not defined, git merges the file as text.
- The message board (agent-bbs) is for live talk, and an issue for what must last: a finding posted on the board becomes an issue when the orchestrator files it.
- A doc section that describes a gap names its issues in its marker (`status: incomplete; issues: ID`), and doc-library's `incomplete` and `check` read them.

The tests: `python3 -I -B -m unittest discover -s .claude/skills/issue-library/tests`, which `make check-selftest` runs.

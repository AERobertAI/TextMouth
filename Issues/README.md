# Issues

Each file here is one of TextMouth's issues: `B16.md` holds B16.
The issue-library skill reads and changes them with `issuelib.py` (`list`, `show`, `new`, `comment`, `close`, and the rest); its `SKILL.md` in `.claude/skills/issue-library/` has the commands.
The folder is public, as the whole repository is.

## The format

A file has three parts: a header between two lines of three hyphens, then `## Description`, then `## Comments`.
The header has one `name: value` line for each field, in this order, with nothing after the colon when the field is empty:

- `id`: the ID, which is also the file's name, and is never changed or given twice.
- `title`: one line.
- `kind`: bug, feature, format, follow-up, test, tooling, docs, or question.
- `status`: open, in-progress, blocked, done, wontfix, or duplicate.
- `priority`: P1, P2, or P3.
- `platform`: mac, iphone, or both.
- `assignee`: the agent working on it, or nothing.
- `created` and `updated`: dates written as 2026-11-16; `updated` is the header's last change, since each comment has its own date.
- `found-by`: who found it.
- `branch`: the branch it is worked on.
- `merged`: the merge commit that closed it.
- `reason`: why it closed, when no merge closed it.
- `related`: other IDs, separated by commas.
- `docs`: the ids of the doc sections it concerns, separated by commas.
- `labels`: lowercase words, separated by commas.

Each comment is a heading with its date, author, and line count, `### 2026-11-16, author, 3 lines`, and its text below it; `issuelib check` fails a comment with no text, and a count its text does not have.
A done issue names its merge or a reason, and a wontfix or duplicate one a reason.
`.claude/skills/issue-library/template.md` is the file a new issue starts from.

## IDs

A new issue takes the next number in its kind's family: B for a bug, FR a feature, FMT a format, FU a follow-up, Q a test, TL tooling, DOC docs, and QN a question.
A number counts as used once it appears anywhere in the TODO or in its history, so none is given twice.
An item whose ID was given twice by mistake keeps an alias in its TODO entry: B12-OCT and B13-OCT are the October B12 and B13.

## Who changes what

- The orchestrator files, assigns, closes, and reopens issues, on main.
- An agent, on its own branch, comments on the issue assigned to it and sets it in-progress or blocked.
- Two branches' changes to one issue merge part by part, through the merge driver `.gitattributes` names (`make issues-merge-driver` defines it once): the header field by field, the description as git would, and each comment whole; one field changed both ways is a conflict, with git's markers.
- The message board is for live talk, and an issue for what must last.

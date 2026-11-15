# doclib task `paths`: `where` and `affected`

You are `doclib-paths`, a worker of team `doclib` (lead `doclib-lead`). Branch `doclib/paths`, made from `team/doclib`.
The team builds the `doc-library` skill (`.claude/skills/doc-library/`): a standard-library Python tool for finding the section of TextMouth's docs to read or update. `team/doclib` already holds the Markdown model (`docmodel.py`: pages, sections, markers, `units`, `prose_blocks`), the section targets (`targets.py`), the repository's file list (`repofiles.py`), and what a section cites (`citations.py`). Read them first; build on them, never around them.
You add two commands that go from code to docs: `where NAME` (which sections cite this path or name) and `affected [REF]` (which sections a branch's changes touch).

## Rules (every one is a hard rule)

- No `rm` at all, and no deleting from scripts (a test's own `tempfile.TemporaryDirectory` is fine).
- Never search from `/` or `~`; search only this worktree.
- Never read, list, stat, copy, or open anything under `~/.TextMouth` or `~/Library/CloudStorage`. The code reads only files inside the repository folder it is given.
- Never push, never merge into `main`, never `make install`. Nothing here builds the app or needs a train.
- Keep shell commands plain; put anything fancy in a small script run with `python3 -I -B`.
- Edit no Markdown file. Tests never read the real docs; they build their own repositories.

## Start

1. `git switch -c doclib/paths team/doclib`. This brief is then at `Scripts/agents/briefs/2026-11-14/doclib/paths.md`.
2. Read `docs/agents/writing-docs.md` (Section markers), then `.claude/skills/doc-library/scripts/`: `doclib.py`, `output.py`, `docmodel.py`, `targets.py`, `repofiles.py`, `citations.py`, `cmd_find.py` (a command to copy the shape of), and `tests/doclib_case.py`.
3. Register: `python3 .claude/skills/agent-bbs/scripts/bbs.py register doclib-paths --role "doclib: where and affected" --branch doclib/paths --files .claude/skills/doc-library/scripts/cmd_where.py .claude/skills/doc-library/scripts/cmd_affected.py .claude/skills/doc-library/scripts/tests/test_where.py .claude/skills/doc-library/scripts/tests/test_affected.py --team doclib`. Read `bbs inbox doclib-paths --unread` before each commit and before your report.
4. Everything under `.claude/` is gitignored: stage each new file with `git add -f`.

Style: Python 3.11 standard library; a comment or docstring on every function and non-obvious block; type hints; one helper, never two copies (if `where` and `affected` share matching logic, it lives once, in `citations.py` if it is about citations). Load `RepoFiles` once per run.

## 1. `where NAME` (commit 1, `cmd_where.py`, `tests/test_where.py`)

NAME is one of three things, decided in this order:
1. A path: it holds `/`. Its targets are `repo.resolve(NAME)` (a folder stands for every file in it). A path that resolves to nothing still matches citations written the same way, so `where TextMouth/Removed.swift` finds the docs that still cite a removed file.
2. A file name: no `/`, and a `.` followed by letters at its end. Its targets are `repo.by_name(NAME)`, and it also matches citations whose last component is NAME.
3. A Swift name: it matches `citations.IDENTIFIER`.
Anything else is a usage error: `where takes a path, a file name, or a Swift name; find searches words`.

A section matches:
- for a path or file name: when one of its citations (`citations.citations(prose_blocks(...), marker src, marker line, repo)`) names a target. A citation names a target T when T is among its `paths`, or one of its paths is a folder holding T, or T is a folder holding one of its paths, or (for a citation that resolves to nothing) its token, or `TextMouth/` plus its token, equals T or NAME. Put this test in `citations.py` as `def names_path(citation: Citation, target: str, written: str) -> bool`, so `affected` uses the same rule.
- for a Swift name: when one of its `units` contains NAME as a whole name, case-sensitively: not preceded or followed by a letter, digit, or `_` (so `Book` matches `Book.Storage`, `` `Book` `` and `Models/Book.swift`, but not `BookBox`).

One hit per matching section, at its first matching place, preferring the marker, then a Files: line, then the rest in line order: the place's line range, the section's heading, the place's text (the citing line, or the unit), and `focus` on the token or name. `extra`: `kind` (`src`, `files`, `text`, or `name`), `token`, `id`, `section_start`, `section_end`. Pages in scope order. `default_max = 20`; exit 0 with hits, 1 without.

Tests: each kind of NAME; a folder target (`where TextMouth/Parsers/` finds a section citing `Parsers/EPUBParser.swift` through a Files: line); a section citing a folder found by a file inside it; a removed file still found; a file name found through a Files: line written relative to `TextMouth/`; `Book` against `BookBox`; one hit per section though it cites the name three times, at the marker; `--scope memory`; the usage error; JSON fields.

## 2. `affected [REF] [--base BASE]` (commit 2, `cmd_affected.py`, `tests/test_affected.py`)

The sections a branch's changes touch, and the changed Swift files no section cites.

- The changes: `git -C ROOT diff --name-status -z -M BASE...REF` (REF defaults to `HEAD`, BASE to `main`; the three dots mean "since the two met", so a branch's own changes). For the merge commit M of an old branch, `affected M --base M^1` gives what the merge brought. An unknown ref is a usage error carrying git's message; a root that is not a git repository is a usage error.
- Each change is a status (`A`, `M`, `D`, `T`, or `R` with both its old and new paths) and the files it touches. Markdown files (`*.md`) are skipped: they are the docs themselves.
- For each changed file F, in path order, each section of the scope with a citation that names F (`names_path`, written form F) gives one hit, at the citing line: the text is `{status} {F}: {the citing line}` with `focus` on the token, and `extra` holds `changed`, `status`, `kind`, `token`, `id`, `section_start`, `section_end`. A section is listed once per changed file.
- After the hits, one line per changed Swift file (`*.swift`, not deleted) that no section cites: `uncited: F`; under `--json`, `{"uncited": F}`. These lines are never capped.
- Always, on standard error: `doclib: N files changed; S Swift, C of them cited (P%); U uncited`, with P rounded to a whole percent (`-` when S is 0).
- The docs read are the working tree's, whatever REF is (it measures today's docs against an old change).
- `default_max = 20` for the hits; exit 0 when there is at least one hit, 1 when there is none.

Tests: a repository with a `main` and a branch that changes a cited Swift file, an uncited one, a Markdown page, a renamed cited file (found under its old name), and a deleted cited file; the summary line's numbers; `--base` with a merge commit (`M^1`); a folder citation covering a changed file; an unknown ref (exit 2); JSON lines, uncited included.

## 3. Measure (no commit)

From your worktree's root, time `where TextMouth/Models/Book.swift`, `where Book`, `where EPUBParser.swift`, and `affected HEAD --base HEAD~5` with `/usr/bin/time -p python3 -I .claude/skills/doc-library/scripts/doclib.py ...`; each must take under a second. Then, for each of the last ten merges on main (`git log --merges -10 --format=%h main`), run `affected M --base M^1 --max 0` and record its standard-error summary line. Give the times and the ten lines in your report.

## Report

Rebase onto `team/doclib` if it moved, run `python3 -m unittest discover -s .claude/skills/doc-library/scripts/tests` (all green; give the count), post `done: doclib/paths` to `team:doclib`, and `bbs release doclib-paths --all`.

Your final message, at most 40 lines: branch and tip; each commit (hash, subject); the test count; the times and the ten summary lines; every rule above you changed or could not meet, and why. Commit messages end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

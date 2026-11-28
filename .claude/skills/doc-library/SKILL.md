---
name: doc-library
description: Find, show, and check the sections of TextMouth's docs and memory files by keyword, code path, or Swift name; list the sections a branch's changes touch; check the writing rules with a ratchet that gates merges; and reflow or mark a page without retyping it. Use it before reading or editing a page under docs/, README.md, ARCHITECTURE.md, AGENTS.md, or CLAUDE.md, and to go from a section to its code.
---

# doc-library

`doclib` below is `python3 -I .claude/skills/doc-library/scripts/doclib.py`, run from anywhere in the repository or a worktree.

- Output: one hit per line, `path:start-end  heading path  text`, the text cut to 200 characters; `--json` prints JSON lines. `show path:start` prints a hit's whole section.
- Options follow the command: `--scope docs|memory|all`, `--max N` (default 20; 0 for all), `--json`, `--root DIR`.
- Scopes: `docs` (the default) is README.md, ARCHITECTURE.md, and docs/; `memory` is AGENTS.md, CLAUDE.md, the TODO, AGENT-NOTES, research/, the briefs, and humanQuestions/.
- A TARGET is a marker id, `PAGE#HEADING`, or `PAGE:LINE`; a PAGE may be the unique end of its path (`feeds`, `user/feeds`).
- Exit 0: found, or passed; 1: nothing found, or a check failed; 2: a usage error.
- Only `reflow`, `mark`, and the `--update-baseline` and `--rebuild-baseline` options write.

## Commands

- `doclib find PATTERN [--fixed] [--area user|architecture|developer|agents]`: sentences, headings, code lines, and marker lines matching a regex, ignoring case.
- `doclib where NAME`: the sections citing a path, a file name, or a Swift name.
- `doclib affected [REF] [--base BASE]`: the sections citing the files changed between BASE (main) and REF (HEAD), and the changed Swift files no section cites.
- `doclib show TARGET [--numbers] [--all]`: one section as written, with its marker's paths.
- `doclib outline PAGE`: each section's lines, id, size, and number of cited paths.
- `doclib code TARGET`: the files and Swift declarations a section names, each with its line.
- `doclib stale [--logs]`: cited paths and backticked Swift names that no longer exist (the logs only with `--logs`); `stale-allowlist.txt` lists framework names.
- `doclib suggest-src TARGET [--strings]`: the paths a section's marker `src` should hold; with `--strings`, the Swift files whose string literals hold the section's heading and quoted or bold names (a `…Wording` file first, then its users), for a user page.
- `doclib lint [--report] [--rule R,..] [--skip R,..] [--page PAGE] [--against REF]`: the docs, AGENTS.md, and CLAUDE.md against docs/agents/writing-docs.md; it fails only when a page has more violations than `lint-baseline.json` records.
- `doclib lint --update-baseline`: lowers the baseline after a fix, and never raises it.
- `doclib split-check OLD NEW... [--files-to-src] [--loose] [--update-baseline]`: whether the NEW pages hold OLD's words in order (OLD may be `REF:PATH`, or several joined by commas); `--loose` compares words without their case and end punctuation, outside code; the last option hands the OLD pages' counts to the new ones.
- `doclib reflow PAGE [--check]` (writes): one sentence per line, word for word.
- `doclib mark PAGE [--dry-run]` (writes): a marker under each heading without one: a suggested id and src, and empty keys.
- `doclib incomplete [--issue ID] [--status incomplete|planned]`: the sections whose marker gives a `status` and the `issues` that track it.
- `doclib check`: fails a section's status that names no issue, or names one that has no file in `Issues/` or is closed.

A docs pass that describes a limitation, a planned feature, or a known bug adds `status: incomplete` (or `planned`) and `issues: ID, ID` to that section's marker, so `incomplete` finds it later.

`make lint-docs` runs the lint against main, and `Scripts/agents/merge-chain.sh` runs it before every merge.
The tests: `python3 -m unittest discover -s .claude/skills/doc-library/scripts/tests`.

## Adding a command

An agent may add a subcommand when it has done the same lookup of several steps twice, on five conditions:

1. it is a subcommand of `doclib.py` (a module `scripts/cmd_NAME.py`, which `doclib.py` finds by itself), not a new script;
2. it uses the standard library only;
3. it is read-only unless its name says it writes;
4. it caps its output and has a test;
5. its commit adds one line to the Commands above, the one Markdown edit a task agent may make.

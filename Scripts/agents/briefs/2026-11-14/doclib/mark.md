# doclib task `mark`: a marker under every heading, for an agent to fill in

You are `doclib-mark`, a worker of team `doclib` (lead `doclib-lead`). Branch `doclib/mark`, made from `team/doclib`.
The team builds the `doc-library` skill (`.claude/skills/doc-library/`). A second team will use it to give every section of TextMouth's docs a marker (`docs/agents/writing-docs.md`, Section markers): `<!-- id: epub-headings; keys: EPUB, nav document, NCX; src: TextMouth/Parsers/EPUBParser.swift -->`. `mark` saves that team from typing them: it gives each heading without a marker one, with a suggested `id` and `src` and empty `keys`, and changes nothing else.
`team/doclib` holds the Markdown model (`docmodel.py`, with `parse_marker` and `ID_SHAPE`), `targets.py` (`strip_markup`), `repofiles.py`, `swiftindex.py`, `cmd_suggest_src.py` (with `suggest_paths`, which suggests a section's `src`), `splitcheck.py`, and `pagewrite.py`, the one way a command writes a page. Read them first; build on them, never around them.

## Rules (every one is a hard rule)

- No `rm` at all, and no deleting from scripts (a test's own `tempfile.TemporaryDirectory` is fine).
- Never search from `/` or `~`; search only this worktree.
- Never read, list, stat, copy, or open anything under `~/.TextMouth` or `~/Library/CloudStorage`.
- Never push, never merge into `main`, never `make install`. Nothing here builds the app or needs a train.
- Never run `mark` on a page of a checkout, yours included: only on pages in a test's temporary folder, or in a scratch copy under `build/` (see Measure).
- Keep shell commands plain; put anything fancy in a small script run with `python3 -I -B`.
- Edit no Markdown file. Tests never read the real docs.

## Start

1. `git switch -c doclib/mark team/doclib`. This brief is then at `Scripts/agents/briefs/2026-11-14/doclib/mark.md`.
2. Read `docs/agents/writing-docs.md`, then `.claude/skills/doc-library/scripts/`: `doclib.py`, `output.py`, `docmodel.py`, `targets.py`, `repofiles.py`, `swiftindex.py`, `cmd_suggest_src.py`, `splitcheck.py`, `pagewrite.py`, and `tests/doclib_case.py`.
3. Register: `python3 .claude/skills/agent-bbs/scripts/bbs.py register doclib-mark --role "doclib: mark" --branch doclib/mark --files .claude/skills/doc-library/scripts/cmd_mark.py .claude/skills/doc-library/scripts/tests/test_mark.py --team doclib`. Read `bbs inbox doclib-mark --unread` before each commit and before your report.
4. Everything under `.claude/` is gitignored: stage each new file with `git add -f`.

Style: Python 3.11 standard library; a comment or docstring on every function and non-obvious block; type hints; one helper, never two copies.

## `mark PAGE [--dry-run]` (commits 1 and 2: `cmd_mark.py`, `tests/test_mark.py`)

Commit 1 is the id and marker functions with their tests; commit 2 the command.

### Ids

```python
STOP_WORDS = frozenset({"a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "with", "by", "its", "is"})
ID_WORDS = 5
ID_LENGTH = 40
def suggest_id(title: str, page_stem: str, taken: set[str]) -> str
```

- The base is the heading's words: `targets.strip_markup`, lowercased, `&` read as `and`, the runs of letters and digits (`[a-z0-9]+`), stop words dropped while other words remain, the first `ID_WORDS` kept, joined with `-`, and cut at a hyphen to at most `ID_LENGTH` characters. A title with no letters or digits gives `section`.
- The first of these not in `taken` is the id: the base; `{page_stem}-{base}`; then `{page_stem}-{base}-2`, `-3`, and so on. `page_stem` is the page's file name without `.md`, made into the same shape (`what-textmouth-reads`).
- `taken` holds every id of the lint pages' markers (`docmodel.lint_pages`), plus the ids this run has given. Every id matches `docmodel.ID_SHAPE`.

### Markers

```python
def marker_line(ident: str, src: list[str]) -> str
```

`<!-- id: ID; keys: ; src: A, B -->`, or `<!-- id: ID; keys: ; src: -->` with no paths: `keys` is left empty for the agent to fill in. `docmodel.parse_marker` must read every line it makes back to the same id, no keys, the same src, and no errors (a test checks it).

The `src` is `suggest_paths(page, section, repo, index)`: every suggestion whose reason is a Files: line, then at most five others, in its order.

### The command

- PAGE is named as every command names a page, through `targets.resolve_page` (its path, or the unique end of it), and read with `pagewrite.read_page_text`; `cmd_reflow.py` does the same, and is the other writing command to copy the shape of.
- For each section of the page at level 1 or deeper whose `marker` is None, the marker line goes on the line straight after its heading. A section that has a marker, a stray one included, is left alone; so is text before the first heading.
- The page's other lines are not touched: removing the added lines gives back the old text exactly, which `mark` checks before writing, besides `pagewrite`'s own checks; it also checks that parsing the new text gives every section that lacked a marker the id it was given, and no stray markers. Any failed check writes nothing, prints what failed, and exits 1.
- A page holding `\r` is refused (as `reflow` does, through `pagewrite`).
- Output: one hit per added marker (`PAGE:LINE`, the section's heading, the marker line) and `mark: PAGE: N markers added` on standard error; exit 0. With nothing to add: `mark: PAGE: every section has a marker`, exit 0. `--dry-run` prints the same and writes nothing. `default_max = 0`.

Tests, each on pages written in the test's temporary folder (some with Swift files, so `src` has something to find):
- ids: stop words dropped, a title of only stop words kept, digits kept, the 40-character cut at a hyphen, markup and `&`, a title of punctuation (`section`);
- a collision with another page's marker id gives the page-stem form; two headings with the same title on one page give the base and the page-stem form; a third gives `-2`;
- `src` from a Files: line written relative to `TextMouth/`, and from an unbackticked type the Swift index knows;
- a section that already has a marker, and one with a stray marker, untouched;
- the page byte-identical apart from the added lines; a page without a last line end stays without one;
- running it twice adds nothing the second time;
- `--dry-run` writes nothing;
- every added line parses back with `parse_marker` to the same fields and no errors.

## Measure (no commit)

Make a scratch copy of two real pages, `docs/architecture/state/saving-failures.md` and `docs/architecture/platforms.md`, in a plain folder `build/doclib-mark/scratch/` of your worktree (`build/` is gitignored), at their docs paths, with a second copy of each under `orig/`; copy the Swift sources too (`TextMouth/`, so `suggest_paths` has what it needs; `cp -R` of that folder is fine, read only). A plain folder has no `.git`, so pass it as `--root`. Run `mark` on each page, then `split-check orig/PAGE PAGE` for each (markers are ignored, so it must pass), and give: the markers added, ten of their lines, how many got a `src`, the times (`/usr/bin/time -p`), and any id you would not keep.

## Report

Rebase onto `team/doclib` if it moved, run `python3 -m unittest discover -s .claude/skills/doc-library/scripts/tests` (all green; give the count), post `done: doclib/mark` to `team:doclib`, and `bbs release doclib-mark --all`.

Your final message, at most 40 lines: branch and tip; each commit (hash, subject); the test count; the measurements; every rule above you changed or could not meet, and why. Commit messages end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

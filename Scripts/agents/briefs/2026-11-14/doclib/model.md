# doclib task `model`: the Markdown model, `outline`, `show`, then `find`

You are `doclib-model`, a worker of team `doclib` (lead `doclib-lead`). Branch `doclib/model`, made from `team/doclib`.
The team builds the `doc-library` skill: a standard-library Python tool that lets agents find a section of TextMouth's docs by keyword, path, or Swift name, and checks the docs' rules (`docs/agents/writing-docs.md`).
You write the model every command stands on: a Markdown page split into blocks and sections, with section markers. Part 1 is the model and two commands. Part 2, `find`, waits for another worker's modules (`sentences.py`, `repofiles.py`, `citations.py`, from `doclib-text`): the lead will message you when they are on `team/doclib`.

## Rules (every one is a hard rule)

- No `rm` at all, and no deleting from scripts (a test's own `tempfile.TemporaryDirectory` is fine).
- Never search from `/` or `~` (`find`, `mdfind`, `du`, `ls -R`): search only this worktree.
- Never read, list, stat, copy, or open anything under `~/.TextMouth` or `~/Library/CloudStorage`. The code reads only files inside the repository folder it is given, and never follows a symlink out of it.
- Never push, never merge into `main`, never `make install`. Nothing here builds the app or needs a train.
- Keep shell commands plain (no nested `${...}`, no long chains); put anything fancy in a small script run with `python3 -I -B`.
- Edit no Markdown file. Tests never read the real docs; they build their own pages.

## Start

1. `git switch -c doclib/model team/doclib` (branch from `team/doclib` by name). This brief is then in your worktree at `Scripts/agents/briefs/2026-11-14/doclib/model.md`.
2. Read `docs/agents/writing-docs.md`, then the contract already on the branch: `.claude/skills/doc-library/scripts/doclib.py` (how a `cmd_*.py` module registers a command), `output.py` (`Hit`, `emit`, `UsageError`, the exit statuses), `tests/doclib_case.py` (`write_tree`, `git_repo`, `run_cli`).
3. Register: `python3 .claude/skills/agent-bbs/scripts/bbs.py register doclib-model --role "doclib: Markdown model, outline, show, find" --branch doclib/model --files .claude/skills/doc-library/scripts/docmodel.py .claude/skills/doc-library/scripts/targets.py .claude/skills/doc-library/scripts/cmd_outline.py .claude/skills/doc-library/scripts/cmd_show.py .claude/skills/doc-library/scripts/cmd_find.py '.claude/skills/doc-library/scripts/tests/test_docmodel.py' '.claude/skills/doc-library/scripts/tests/test_outline.py' '.claude/skills/doc-library/scripts/tests/test_show.py' '.claude/skills/doc-library/scripts/tests/test_find.py' --team doclib`.
   Then `bbs inbox doclib-model --unread` before each commit and before your report.
4. Everything under `.claude/` is gitignored: stage each new file with `git add -f`.

## Style

Python 3.11 standard library only. Every function and every non-obvious block has a comment or docstring. Type hints and dataclasses. One helper, never two copies. Follow `output.py`'s style. No module may share a name with a standard-library module. If the contract files need a change, make it in its own commit and say why in the report.

## Part 1, commit 1: `scripts/docmodel.py` and `tests/test_docmodel.py`

### Scopes

```python
SCOPES = {
    "docs": ("README.md", "ARCHITECTURE.md", "docs/**/*.md"),
    "memory": ("AGENTS.md", "CLAUDE.md", "TODO-*.md", "AGENT-NOTES-*.md", "research/**/*.md",
               "Scripts/agents/briefs/**/*.md", "humanQuestions/**/*.md"),
}
LOG_PAGES = frozenset({"docs/user/changelog.md", "docs/agents/history.md"})
INDEX_PAGES = ("README.md", "ARCHITECTURE.md")

def scope_pages(root: Path, scope: str) -> list[str]
def lint_pages(root: Path) -> list[str]
```

- `scope_pages` lists a scope's Markdown files, repository-relative and POSIX, in the order of the entries above, each glob's matches sorted; `all` is `docs` then `memory`, without repeats. It walks only those folders, never follows a symlink, and skips an entry that does not exist (a worktree has no `humanQuestions/`). It lists files from the disk, not from git, because briefs and `humanQuestions/` are untracked.
- `lint_pages` is the `docs` scope plus `AGENTS.md` and `CLAUDE.md`: the pages the lint covers, and where an id is looked up.

### Blocks

```python
@dataclass
class Block:
    kind: str           # heading, paragraph, list-item, list-para, quote, code, table, html, marker, rule, front-matter
    start: int          # first line, 1-based
    end: int            # last line, inclusive
    level: int = 0      # heading: 1 to 6
    title: str = ""     # heading: its text, closing #s removed
    indent: int = 0     # list-item: the marker's column; list-para: its item's content column
    content_col: int = 0  # list-item: the column its text starts at
    marker: "Marker | None" = None  # marker: the parsed marker
```

`parse(path, text) -> Page` splits `text` into lines (`\r\n` and `\n` both end a line; a final line end adds no empty line) and into blocks, by these rules, tried in this order on each line outside a fenced block:

1. Front matter: when line 1 is `---` and a later line is `---` or `...`, lines 1 to that one are one `front-matter` block. Nothing in it is a heading.
2. A blank line ends the open paragraph, list item, list paragraph, quote, or table. It does not end the list (see 9).
3. A fence, a line of any indentation starting with three or more backticks (with no backtick in the rest of the line) or tildes, opens a `code` block that ends at a line holding only a fence of the same character at least as long. An unclosed fence runs to the last line.
4. An HTML comment: a line starting, after at most 3 spaces, with `<!--` opens an `html` block that ends at the first line holding `-->` (possibly the same line). A one-line comment whose content has an `id:` field is a `marker` block, parsed into `Block.marker` (see Markers).
5. A heading: `^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$`. It ends the list.
6. A thematic break, `^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$`: a `rule` block (tried before list items).
7. A table: consecutive lines starting, after at most 3 spaces, with `|`.
8. A quote: consecutive lines starting, after at most 3 spaces, with `>`.
9. A list item: `^( *)([-*+]|\d{1,9}[.)])([ \t]+|$)`. Its content column is the marker's end plus the spaces after it (one space when there are more than four). Keep a stack of the open items' content columns: a new item first pops every item whose marker column is at or beyond its own. A non-blank line right after an item's line (no blank between) that starts none of the blocks above continues the item, at any indentation. After a blank line, a line indented at least as far as an open item's content column (pop the items deeper than the line first) is a `list-para` of that item, or a `code` block inside it when indented four or more beyond that column; a line indented less than every open item ends the list.
10. Indented code: outside a list, a line indented four or more spaces (or a tab) after a blank line, the page's start, or another such line, is a `code` block; it runs while lines stay indented that far or are blank (trailing blank lines are not part of it).
11. Anything else is a `paragraph` line: it continues the open paragraph, list item, list paragraph, or quote, or starts a paragraph. A line that starts a heading, fence, comment, rule, table, quote, or list item interrupts a paragraph.

The page `docs/agents/writing-docs.md` shows why rule 10 matters: under its "Section markers" heading, a paragraph, a blank line, and then a marker indented four spaces, which is an example in an indented code block, not a marker.

### Markers

```python
@dataclass
class Marker:
    line: int
    raw: str
    id: str | None
    keys: list[str]
    src: list[str]
    errors: list[str]

ID_SHAPE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
def parse_marker(line_number: int, text: str) -> Marker | None
```

A marker is one whole line, `<!-- id: epub-headings; keys: EPUB, nav document, NCX; src: TextMouth/Parsers/EPUBParser.swift -->`. Fields are split at `;`, each `name: value`; `keys` and `src` split at `,`, trimmed, empties dropped (so `keys: ;` is no keys). `parse_marker` returns `None` for a line that is not a one-line comment with an `id:` field. Its `errors` name each problem in a short phrase: no id; an id not matching `ID_SHAPE`; an unknown field; a field given twice; a part without a colon.

### Sections and pages

```python
@dataclass
class Section:
    page: str                 # the page's path
    index: int                # its place in the page, from 0
    level: int                # 1 to 6; 0 for text before the first heading
    title: str
    path: tuple[str, ...]     # the titles from the top heading down to this one
    start: int                # the heading's line (1 for text before any heading)
    end: int                  # the last non-blank line before the next heading (start when there is none)
    span_end: int             # the line before the next heading, or the page's last line
    blocks: list[Block]       # the blocks after the heading line, up to span_end
    marker: Marker | None     # the marker that is the first block under the heading
    stray_markers: list[Marker]  # any other marker block in the section
    heading: str              # property: the heading path to print (see below)

@dataclass
class Page:
    path: str
    lines: list[str]
    blocks: list[Block]
    sections: list[Section]
    size: int                 # UTF-8 bytes of the file
    def section_at(self, line: int) -> Section     # the section whose start..span_end holds the line
    def text(self, start: int, end: int) -> str    # those lines joined with "\n"

def parse(path: str, text: str) -> Page
def load_page(root: Path, path: str) -> Page      # UTF-8, errors="replace"; refuses a path outside root
def load_pages(root: Path, paths: Iterable[str]) -> list[Page]
def prose_blocks(page: Page, section: Section) -> list[tuple[int, str]]
```

- A section starts at each heading block, and text before the first heading (other than front matter) is a level-0 section with the title `""`.
- `heading`, the path printed in hits: the titles of `path` joined with ` > `, leaving out the page's top heading when the page has exactly one level-1 heading and the section is below it (a hit's file path already names the page). The level-1 section itself prints its own title; a level-0 section prints `""`.
- `prose_blocks` gives `doclib-text`'s `citations()` its input: for the section's heading and each of its blocks except `code`, `front-matter`, `marker`, `rule`, and `html`, the pair `(first line, raw lines joined with "\n")`.

### Tests (`tests/test_docmodel.py`)

Each rule above, and these cases: section ranges with blank lines between sections (`end` against `span_end`); the heading path with and without a single top heading; text before the first heading; `#` inside a fence is not a heading; an unclosed fence; the writing-docs.md example (an indented marker in a code block is not a marker); a list item's indented paragraph after a blank line is a `list-para`, and four more spaces make it `code`; nested list items; a marker under a heading with and without a blank line between; a second marker in a section is stray; a comment naming `<!-- page: 12 -->` inside a sentence is not a block; marker errors; front matter; CRLF; `section_at` on a blank line between sections; `scope_pages` order, a missing `humanQuestions/`, `all` without repeats, and a symlink pointing outside the root left out.

## Part 1, commit 2: `scripts/targets.py`, `cmd_outline.py`, `cmd_show.py`, and their tests

### `targets.py`

```python
def github_slug(title: str) -> str
def page_slugs(page: Page) -> dict[str, Section]
def resolve_page(root: Path, name: str) -> str
def resolve_target(root: Path, target: str) -> tuple[Page, Section]
```

- `github_slug`: GitHub's anchor for a heading: backticks and `*`/`_` emphasis removed, lowercased, every character that is not a letter, digit, space, hyphen, or underscore dropped, spaces made hyphens. `page_slugs` adds GitHub's `-1`, `-2` for a repeated heading.
- `resolve_page(name)`: a Markdown file at `root/name` (or with `.md` added) inside the root; else the one page of the `all` scope whose path is `name` or ends with `/name` (with or without `.md`), so `feeds` finds `docs/user/feeds.md` while `docs/architecture/state/feeds.md` also exists only when written `user/feeds`. Several matches or none: `UsageError`, listing up to ten candidates.
- `resolve_target(target)`, tried in this order:
  - `PAGE:LINE` (the text after the last `:` is digits): the section holding that line;
  - `PAGE#HEADING`: the section whose title equals HEADING ignoring case and inline markup; else whose slug equals HEADING's slug; else the only title HEADING starts; else the only title containing it. A HEADING holding ` > ` matches the end of the printed heading path instead;
  - otherwise an id: the section whose marker id is the target, among `lint_pages`.
  Each failure is a `UsageError` saying what was not found, with up to five close matches (`difflib.get_close_matches`) and, for a bare page name, the hint `name a section: PAGE#HEADING, PAGE:LINE, or an id (outline PAGE lists them)`.

### `outline PAGE`

One hit per section, every section (`default_max = 0`): path, the section's `start-end`, as heading `"#" * level + " " + title` (`(top)` for level 0), and as text `{id}  {n} lines  {b} bytes`, with `-` for no id, `n` the lines `start..end`, `b` their UTF-8 bytes. `--json` adds `id`, `level`, `title`, `lines`, `bytes`, and the heading path as `path_titles`. Exit 0.

### `show TARGET [--numbers] [--all]`

- First line: a hit line for the section, the text `id: ID` or `no marker`.
- Then the section's lines `start..end` exactly as written; with `--numbers` each line starts with its number and a tab.
- Unless `--all`, stop before the line that would take the printed lines past 12,000 characters, and end with the line `… lines N-M not shown; --all shows them`.
- `--json`: one object with `path`, `start`, `end`, `span_end`, `heading`, `title`, `level`, `id`, `keys`, `src`, `lines`, `truncated`.
- Exit 0; a target that names nothing is a usage error (exit 2).

### Tests

`tests/test_outline.py` and `tests/test_show.py`: run the commands through `run_cli` on pages written with `write_tree`. Cover each target form, a page named by its unique end, an ambiguous name (both candidates listed), an unknown id with a close match, a bare page given to `show`, `--numbers`, the 12,000-character cap and `--all`, `--json`, and outline's sizes and levels on a page of 30 headings (all printed).

Then post `part 1 done: doclib/model` to `team:doclib`, and stop: give your part 1 report (the Report section below) as your final message. Do not wait or poll for part 2. The lead reviews part 1 and resumes you with a message when the other worker's modules are on `team/doclib`.

## Part 2 (when the lead resumes you): `find`, and the paths in `outline` and `show`

Rebase onto `team/doclib` first: it will hold `sentences.py`, `repofiles.py`, and `citations.py`.

### commit 3: `cmd_find.py`, `docmodel.units()`, `tests/test_find.py`

```python
@dataclass
class Unit:
    kind: str     # heading, marker, sentence, code, table, html
    start: int
    end: int
    text: str
def units(page: Page, section: Section) -> list[Unit]
```

`units` gives, in line order: the section's heading (its title); its marker line (the raw line, so `id`, `keys`, and `src` are all searched); each sentence of each paragraph, list item, list paragraph, and quote, found by `sentences.split_sentences` on the block's lines with list markers, `>` and indentation removed and joined with `\n` (a unit's lines are those of its first and last character); and each line of every code, table, html, and stray marker block.

`find PATTERN [--fixed] [--area user|architecture|developer|agents]`:
- PATTERN is a Python regular expression matched ignoring case (`--fixed`: plain text); a bad pattern is a usage error.
- `--area` keeps the pages under `docs/<area>/`; with `--scope memory` it is a usage error.
- A unit matches when the pattern is found in its text with white space collapsed (`output.collapse`), so a phrase broken over two lines matches. One hit per unit: its `start-end`, the section's heading, the collapsed text, `focus` on the match, and in `extra`: `kind`, `id` (the section's marker id or null), `section_start`, `section_end`.
- Pages in scope order, units in line order; `default_max = 20`; exit 0 with hits, 1 without.

Tests: one sentence of two on a long line found and printed alone; a phrase across a line break; `--fixed` with `.` and `(`; `--area`; a match in marker keys; a match in a code line; a heading match; `--max 1` and the count on standard error; exit 1; a bad pattern (exit 2); JSON fields.

### commit 4: paths in `outline` and `show`

- `outline` appends `  {p} paths` to its text, `p` the number of distinct tokens of the section's `citations()` (built with one `RepoFiles.load` for the run), and `--json` adds `paths`.
- `show` ends with one line per marker `src` entry, `src: PATH`, with ` (missing)` when it resolves to nothing, and `--json`'s `src` becomes a list of `{"path", "exists"}`.
- Update their tests.

### Measure

Time `find seamless`, `find "Files:" --max 0`, `outline docs/architecture/state/imports.md`, and `show` of one section, each with `/usr/bin/time -p python3 -I .claude/skills/doc-library/scripts/doclib.py ...` from your worktree's root; each must take under a second. Give the times in your report.

## Report

Before reporting, rebase onto `team/doclib`, and run `python3 -m unittest discover -s .claude/skills/doc-library/scripts/tests` (all green; give the count). Post `done: doclib/model` to `team:doclib` and release your claims (`bbs release doclib-model --all`).

Your final message, at most 40 lines: the branch and tip; each commit (hash, subject); the test count; the times; every rule above you changed or could not meet, and why; anything in the contract files that should change. Each commit message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

# doclib task `text`: sentences, the repository's files, and citations

You are `doclib-text`, a worker of team `doclib` (lead `doclib-lead`). Branch `doclib/text`, made from `team/doclib`.
The team builds the `doc-library` skill: a standard-library Python tool that lets agents find a section of TextMouth's docs by keyword, path, or Swift name, and checks the docs' rules.
You write three modules of pure functions and their tests. Another worker (`doclib-model`) writes the Markdown model and the commands at the same time; your modules must not import theirs.

## Rules (every one is a hard rule)

- No `rm` at all, and no deleting from scripts (a test's own `tempfile.TemporaryDirectory` is fine).
- Never search from `/` or `~` (`find`, `mdfind`, `du`, `ls -R`): search only this worktree.
- Never read, list, stat, copy, or open anything under `~/.TextMouth` or `~/Library/CloudStorage`. Your code must never touch a path outside the repository folder it is given: see "Safety" below.
- Never push, never merge into `main`, never `make install`. Nothing here builds the app or needs a train.
- Keep shell commands plain (no nested `${...}`, no long chains); put anything fancy in a small script run with `python3 -I -B`.
- Edit no Markdown file.

## Start

1. `git switch -c doclib/text team/doclib` (your worktree may start elsewhere; branch from `team/doclib` by name). This brief is then in your worktree at `Scripts/agents/briefs/2026-11-14/doclib/text.md`.
2. Read `docs/agents/writing-docs.md` (the rules the tool serves), `.claude/skills/doc-library/scripts/doclib.py`, `output.py` and `tests/doclib_case.py` (the contract already on the branch).
3. Register: `python3 .claude/skills/agent-bbs/scripts/bbs.py register doclib-text --role "doclib: sentences, repo files, citations" --branch doclib/text --files .claude/skills/doc-library/scripts/sentences.py .claude/skills/doc-library/scripts/repofiles.py .claude/skills/doc-library/scripts/citations.py .claude/skills/doc-library/scripts/tests/test_sentences.py .claude/skills/doc-library/scripts/tests/test_repofiles.py .claude/skills/doc-library/scripts/tests/test_citations.py --team doclib`.
   Then `bbs inbox doclib-text --unread` before each commit and before your report.
4. Everything under `.claude/` is gitignored: stage each new file with `git add -f`.

## Style

Python 3.11 standard library only. Every function and every non-obvious block has a comment or docstring. Type hints. One helper, never two copies. Follow `output.py`'s style. No module may share a name with a standard-library module.

## 1. `scripts/sentences.py` (commit 1, with `tests/test_sentences.py`)

```python
def protected_spans(text: str) -> list[tuple[int, int]]
def split_sentences(text: str) -> list[tuple[int, int]]
```

`split_sentences` returns the sentences of `text` (a paragraph or list item, possibly spread over several lines joined with `\n`) as `[start, end)` spans in order.
Invariants, which a test checks on many generated texts: spans are increasing and never overlap; each starts and ends on a non-space character; every non-space character of `text` is inside exactly one span.

`protected_spans` returns the spans no sentence may end inside:
- an inline code span: a run of N backticks up to the next run of exactly N backticks (an unclosed run protects nothing);
- a link or image destination: from `](` to its closing `)`, counting nested parentheses;
- an autolink `<scheme:...>` and an HTML comment `<!-- ... -->`;
- a bare URL, `https?://` up to white space, but not its last character when that is one of `.,;:!?)]'"` (so a URL ending a sentence still ends it).

A sentence ends after a terminator when all of these hold:
1. The terminator is `.`, `!`, or `?`, outside every protected span, and not part of a run of two or more periods (`...` is an ellipsis).
2. It is followed by any run of the closers `)`, `]`, `"`, `'`, `”`, `’`, `*`, `_`, then by at least one white-space character (a newline counts).
3. The first character after that white space is an uppercase letter (`str.isupper()`), a digit, or one of `` ` `` `"` `'` `“` `‘` `(` `[` `*` `_`.
4. For a `.`: the word it ends is not an abbreviation. The word is the run of letters and periods before it (`e.g` for `e.g.`, `a.m` for `a.m.`). `ABBREVIATIONS` is a module-level frozenset compared case-insensitively: `e.g`, `i.e`, `etc`, `vs`, `cf`, `a.m`, `p.m`, `mr`, `mrs`, `ms`, `dr`, `st`, `jr`, `sr`, `fig`, `vol`, `approx`, `incl`, `esp`, `u.s`, `u.k`, `inc`, `ltd`, `ch`, `sec`, `pp`.
5. For a `.`: the word is not a single uppercase letter preceded by a space, the start of the text, or another such initial (`J. R. Tolkien` stays one sentence). A single letter after a hyphen ends a sentence (`press Command-F. Then` is two).

The sentence's span runs from its first non-space character to the end of its closers.
When in doubt, don't split: a missed split only leaves two sentences on one line, but a wrong split breaks a sentence in two.

`tests/test_sentences.py` checks at least these, each input against its sentences as strings:

- `One. Two.` gives `One.` and `Two.`
- `It works? Yes! Fine.` gives three.
- `Use e.g. this one. Next.` gives `Use e.g. this one.` and `Next.`
- `At 8:00 a.m. Eastern it resets. Then.` gives `At 8:00 a.m. Eastern it resets.` and `Then.`
- `Version 0.4.10. The next.` gives `Version 0.4.10.` and `The next.`
- `Edit imports.md. Then build.` gives `Edit imports.md.` and `Then build.`
- `macOS 26. 12 books.` gives `macOS 26.` and `12 books.`
- `**Bold one.** Plain two.` gives `**Bold one.**` and `Plain two.`
- `(See X.) Next.` gives `(See X.)` and `Next.`
- `He said "go." Then left.` gives `He said "go."` and `Then left.`
- `` Run `make check. Now` first. Done. `` gives `` Run `make check. Now` first. `` and `Done.`
- `See [x](a. B.md) now. Next.` gives `See [x](a. B.md) now.` and `Next.` (a link destination is protected; link text is not).
- `See https://example.com/a.b. Next.` gives `See https://example.com/a.b.` and `Next.`
- `Wait... What now.` is one sentence.
- `J. R. Tolkien wrote it. Next.` gives `J. R. Tolkien wrote it.` and `Next.`
- `Press Command-F. Type a word.` gives `Press Command-F.` and `Type a word.`
- `Where Am I? opens it.` is one sentence (lowercase after the `?`).
- `Ends with no space.Next` is one sentence.
- `One.\nTwo on a new line.` gives `One.` and `Two on a new line.`
- `` One. `code` starts two. `` gives `One.` and `` `code` starts two. ``
- `<!-- a. B --> text. Next.` gives `<!-- a. B --> text.` and `Next.`
- `  Leading and trailing.  ` gives `Leading and trailing.`
- the empty string gives no sentences.

## 2. `scripts/repofiles.py` (commit 2, with `tests/test_repofiles.py`)

The repository's files, as git sees them, and how a path written in a doc resolves.

```python
SOURCE_EXTENSIONS = frozenset({"swift", "py", "sh", "h", "c", "m", "mm", "js"})

class RepoFiles:
    def __init__(self, root: Path, files: Iterable[str]) -> None
    @classmethod
    def load(cls, root: Path) -> "RepoFiles"
    root: Path
    files: frozenset[str]        # repository-relative POSIX paths of files
    dirs: frozenset[str]         # every folder holding one of them, without a trailing slash
    tops: frozenset[str]         # the first component of every file at the root and under TextMouth/
    def is_file(self, path: str) -> bool
    def is_dir(self, path: str) -> bool
    def by_name(self, name: str) -> list[str]
    def under(self, folder: str) -> list[str]
    def is_repo_path(self, token: str) -> bool
    def resolve(self, token: str) -> list[str]
    def covers(self, cited: str, path: str) -> bool
```

- `load`: when `root/.git` exists (a folder, or a worktree's file), the files are `git -C root ls-files -z --cached --others --exclude-standard` minus `git -C root ls-files -z --deleted`. Otherwise (the tests' plain folders) a walk of `root` that skips hidden folders, `build/`, and `DerivedData/`, never following a symlink. Two subprocesses at most, and no `stat` of any listed path. Load it once per run; the commands share one instance.
- `tops`: the names at the root (`TextMouth`, `Scripts`, `docs`, `.claude`, `README.md`, ...) together with the names directly under `TextMouth/` (`Models`, `Services`, `Parsers`, `Views`, ...).
- `by_name(name)`: the files whose last component is `name`, sorted.
- `under(folder)`: the files inside `folder` (with or without a trailing `/`), sorted.
- `is_repo_path(token)` is the syntactic test of whether a token written in a doc is meant as a repository path. True when all hold:
  - the token has no white space and none of `<>*?$[]{}|\` (a glob or a placeholder such as `<name>` is not a path);
  - it does not start with `/`, `~`, or `../`, and contains no `//`, no `://`, and no `..` component;
  - either it contains `/` and its first component is in `tops` (so `Services/Old.swift` is a candidate but `Logs/textmouth.log`, a data-directory path, is not), or it has no `/` and ends in `.<ext>` with `ext` in `SOURCE_EXTENSIONS` (a bare file name such as `DOCXParser+Numbering.swift`).
- `resolve(token)` returns the existing paths a token names, as a sorted list:
  - not `is_repo_path(token)`: `[]`;
  - the token from the root, else under `TextMouth/` (a path naming a folder, with or without a trailing `/`, resolves to that folder with a trailing `/`: `Vendor/lame` gives `["Vendor/lame/"]`, `Services/SpeechExport/` gives `["TextMouth/Services/SpeechExport/"]`);
  - a bare file name: `by_name(token)`;
  - otherwise `[]`.
- `covers(cited, path)`: True when `cited` is `path`, or is a folder (ending in `/`) that holds `path`.

### Safety

`RepoFiles` decides existence only from the list `load` made, so it never touches a path outside `root`; keep it that way. `is_repo_path` refuses absolute and home paths before anything else, so `~/.TextMouth/library.json` and `/Library/Caches/x` are never resolved. A test proves it: `resolve("~/.TextMouth/library.json") == []` and `is_repo_path(...) is False`, with `os.stat`, `os.lstat` and `Path.exists` patched to fail the test if called.

### Tests

Build plain folders with `DocLibCase.write_tree`, and one git repository with `DocLibCase.git_repo` (an untracked file is listed, an ignored one is not, a deleted one is not). Cover each rule above, the two resolution roots, the trailing `/`, the bare-name lookup, and `covers`.

## 3. `scripts/citations.py` (commit 3, with `tests/test_citations.py`)

What a section cites. The model passes the section's prose blocks: each block is `(first_line, text)`, the block's raw lines joined with `\n` (list markers and indentation included), with code blocks, front matter, and the marker line left out.

```python
FILES_LINE: re.Pattern
IDENTIFIER: re.Pattern

@dataclass(frozen=True)
class Citation:
    token: str                 # the path as written
    kind: str                  # "src", "files", or "text"
    line: int                  # the line it is written on
    paths: tuple[str, ...]     # what RepoFiles.resolve gives; () when it names nothing that exists

def code_spans(text: str) -> list[tuple[int, int, str]]
def path_tokens(text: str) -> list[tuple[int, str]]
def files_block_paths(text: str) -> Optional[list[tuple[int, str]]]
def citations(blocks: Iterable[tuple[int, str]], marker_src: Sequence[str], marker_line: Optional[int], repo: RepoFiles) -> list[Citation]
def identifier_spans(blocks: Iterable[tuple[int, str]]) -> list[tuple[int, str]]
```

- `code_spans(text)`: each inline code span as `(start, end, content)`: a run of N backticks to the next run of exactly N (CommonMark's rule; spans may cross a line break), the content with one leading and one trailing space removed when both are there. Share the backtick scanning with `sentences.protected_spans` (one helper, in whichever module you judge right; no copy).
- `path_tokens(text)`: the tokens of `text` that might be paths, with their offsets: split at white space and commas, with the wrappers `([{"'` stripped from the front and `.,;:)]}"'` from the end. It does not judge them; `RepoFiles.is_repo_path` does.
- `FILES_LINE` matches a block that starts, after optional indentation and an optional list marker (`-`, `*`, `+`), with `Files:` (optionally in `**`). The architecture pages have 155 such lines, each like `  - Files: Models/AudioEdit.swift, Services/X.swift, Vendor/lame, project.yml.`; the list can run on over continuation lines, and some entries carry notes, as in `Services/BookExportService.swift (BookExportConversion)` or `ViewModels/LibraryViewModel.swift and its extensions`. `files_block_paths(text)` returns `None` for a block that is not a Files: block; otherwise the path tokens (with offsets) of everything after `Files:`.
- `citations(...)` returns, in this order:
  1. the marker's `src` entries, kind `"src"`, on `marker_line` (every entry, whether `is_repo_path` accepts it or not, so a bad src entry is reported later);
  2. for each Files: block, its tokens that `repo.is_repo_path` accepts, kind `"files"`;
  3. for every other block, the tokens inside its code spans that `repo.is_repo_path` accepts, kind `"text"` (a span such as `` `python3 -I Scripts/agents/run_locked.py NAME` `` gives `Scripts/agents/run_locked.py`).
  A token appears once per kind (its first place). Each Citation's `line` is the line its token is on.
- `IDENTIFIER` is the shape of a backticked Swift name: an optional leading `.`, dotted words `[A-Za-z_]\w*`, and an optional call `(...)` holding no white space and no parentheses: `Book`, `Book.Storage`, `startLibrary()`, `NSHostingController.sizeThatFits(in:)`, `.terminateCancel`. `identifier_spans(blocks)` returns `(line, content)` for each code span whose whole content matches `IDENTIFIER`, outside Files: blocks, in order. Whether a name is defined is a later task's business.

Tests: a Files: block with notes and a continuation line; the three kinds in order; a token cited twice in the text listed once; a data-directory path in backticks (`` `Logs/textmouth.log` ``) not cited; `` `~/.TextMouth` `` not cited; a code span across a line break; identifiers in and out of code spans.

## Report

Before reporting, rebase onto `team/doclib` if it moved, and run `python3 -m unittest discover -s .claude/skills/doc-library/scripts/tests` (all green; give the count). Post `done: doclib/text` to `team:doclib` and release your claims (`bbs release doclib-text --all`).

Your final message, at most 40 lines: the branch and tip; each commit (hash, subject); the test count; every rule above you changed or could not meet, and why; anything in the contract files (`doclib.py`, `output.py`, `doclib_case.py`) that should change. Each commit message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

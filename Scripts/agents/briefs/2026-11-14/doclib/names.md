# doclib task `names`: the Swift index, `code`, `stale`, and `suggest-src`

You are `doclib-names`, a worker of team `doclib` (lead `doclib-lead`). Branch `doclib/names`, made from `team/doclib`.
The team builds the `doc-library` skill (`.claude/skills/doc-library/`): a standard-library Python tool for finding the section of TextMouth's docs to read or update. `team/doclib` already holds the Markdown model (`docmodel.py`), section targets (`targets.py`), the repository's file list (`repofiles.py`), and what a section cites (`citations.py`, with `IDENTIFIER` and `identifier_spans`). Read them first; build on them, never around them.
You add an index of the Swift declarations and three commands that use it: `code ID` (from a section straight to its code), `stale` (citations and names that no longer exist), and `suggest-src TARGET` (the paths a section's marker should cite). A later task's `mark` command calls your suggestion function, and the lint calls your stale function, so give both a clean API.

## Rules (every one is a hard rule)

- No `rm` at all, and no deleting from scripts (a test's own `tempfile.TemporaryDirectory` is fine).
- Never search from `/` or `~`; search only this worktree.
- Never read, list, stat, copy, or open anything under `~/.TextMouth` or `~/Library/CloudStorage`. The code reads only files inside the repository folder it is given.
- Never push, never merge into `main`, never `make install`. Nothing here builds the app or needs a train.
- Keep shell commands plain; put anything fancy in a small script run with `python3 -I -B`.
- Edit no Markdown file. Tests never read the real docs or Swift sources; they build their own repositories.

## Start

1. `git switch -c doclib/names team/doclib`. This brief is then at `Scripts/agents/briefs/2026-11-14/doclib/names.md`.
2. Read `docs/agents/writing-docs.md`, then `.claude/skills/doc-library/scripts/`: `doclib.py`, `output.py`, `docmodel.py`, `targets.py`, `repofiles.py`, `citations.py`, `cmd_outline.py` and `cmd_show.py` (commands to copy the shape of), and `tests/doclib_case.py`.
3. Register: `python3 .claude/skills/agent-bbs/scripts/bbs.py register doclib-names --role "doclib: Swift index, code, stale, suggest-src" --branch doclib/names --files .claude/skills/doc-library/scripts/swiftindex.py .claude/skills/doc-library/scripts/cmd_code.py .claude/skills/doc-library/scripts/cmd_stale.py .claude/skills/doc-library/scripts/cmd_suggest_src.py .claude/skills/doc-library/stale-allowlist.txt '.claude/skills/doc-library/scripts/tests/test_swiftindex.py' '.claude/skills/doc-library/scripts/tests/test_code.py' '.claude/skills/doc-library/scripts/tests/test_stale.py' '.claude/skills/doc-library/scripts/tests/test_suggest_src.py' --team doclib`. Read `bbs inbox doclib-names --unread` before each commit and before your report.
4. Everything under `.claude/` is gitignored, and so is `*.txt`: stage each new file with `git add -f`.

Style: Python 3.11 standard library; a comment or docstring on every function and non-obvious block; type hints; one helper, never two copies. Load `RepoFiles` and the index once per run.

## 1. `scripts/swiftindex.py` (commit 1, with `tests/test_swiftindex.py`)

```python
TYPE_KINDS = frozenset({"class", "struct", "enum", "protocol", "actor", "typealias"})

@dataclass(frozen=True)
class Declaration:
    name: str
    kind: str          # one of TYPE_KINDS, "func", or "extension"
    path: str
    line: int
    text: str          # the declaration's line, stripped

@dataclass(frozen=True)
class Mention:
    name: str          # as written: "Book.Storage", "startLibrary()", "ReaderViewModel"
    line: int
    backticked: bool

class SwiftIndex:
    @classmethod
    def load(cls, repo: RepoFiles) -> "SwiftIndex"
    def declarations(self, name: str) -> list[Declaration]
    def is_type(self, name: str) -> bool        # declared with a TYPE_KIND, or extended
    def is_func(self, name: str) -> bool
    def type_files(self, name: str) -> list[str]  # files with a TYPE_KIND declaration (extensions left out)

def mentions(blocks: Iterable[tuple[int, str]], index: SwiftIndex | None = None) -> list[Mention]
```

- `load` reads every `*.swift` file in `repo.files` except those under `Vendor/`, and finds declarations with one regular expression of the shape `\b(class|struct|enum|protocol|actor|typealias|func|extension)\s+([A-Za-z_]\w*)`, dropping names that are Swift keywords (`class func`, `class var`). It matches in comments too; that is accepted, since the index only says whether a name exists. Count lines as you go rather than once per match.
- Speed matters: the real repository has about 1,700 Swift files, 30 MB. On it, `load` must take under 0.5 seconds; measure it (`time.perf_counter` in a scratch script) and tune the pattern if it does not. Report the time.
- `mentions(blocks, index)` lists, in order, every name a section's prose blocks name: each `citations.identifier_spans` entry (backticked), and, when an index is given, each unbackticked word in the prose that is shaped like a Swift type (it starts with an uppercase letter, has a lowercase letter, has a second uppercase letter, and is made of letters, digits and `_`: `ReaderViewModel`, `KF8Layout`, `MOBIBook`, not `VoiceOver` unless the index declares it) and that the index declares as a type. Words inside code spans and link destinations are not prose. The architecture pages write names unbackticked (`Owner: PersistenceFailureCenter.shared`), so this second kind is what makes `code` and `suggest-src` useful on today's pages.

## 2. `code ID` and `stale` (commit 2, `cmd_code.py`, `cmd_stale.py`, `stale-allowlist.txt`, `tests/test_code.py`, `tests/test_stale.py`)

### `code TARGET`

TARGET as `show` takes it (`targets.resolve_target`). Hits, in this order:
1. Each distinct path the section cites (its citations, in order): a file prints `path:1-N` (N its line count), the heading column `cited (src)`, `cited (files)`, or `cited (text)`, and the text `file`; a folder prints `path:1-1` and `folder of K files`; a citation that resolves to nothing prints `TOKEN:0-0` and `missing`.
2. Each distinct name of `mentions(blocks, index)`, in order of first mention: its declarations, types first (primary declarations before extensions), then functions, at most three per name, as `path:L-L`, the heading column the name as written, and the text the declaration's line; when there are more, the third hit's text ends with `(+K more)`. A dotted name (`Book.Storage`) is looked up by its last part, then its first; a call (`startLibrary()`) by the name before the parenthesis.
`extra`: `kind` (`path` or `declaration`), `name`, `decl_kind`. `default_max = 20`; exit 0 with hits, 1 without.

### `stale`

Over the scope's sections, two kinds of stale reference:
1. A citation (`citations.citations`) that resolves to nothing, except:
   - a token whose last component has no `.` and that does not end in `/` (it may be a branch name, such as `docs/oct19`, or a folder: too doubtful to report), unless its kind is `src` (a marker's src entry is always meant as a path);
   - a token that starts with a path prefix in the allowlist;
   - a bare file name (no `/`) that the allowlist names exactly: an SDK header such as `UIAccessibilityConstants.h`, or a third-party file such as `mobi.js`. Any other bare source-file name that resolves to nothing is stale, since a removed `OldParser.swift` is written that way in a Files: line.
2. A backticked name (`Mention.backticked`) that the index does not know:
   - skip it when its last dotted part is a file extension (`Info.plist`, `content.md`, `library.json`: file names, not names); keep the extension list as one module constant;
   - each dotted part that starts with an uppercase letter and holds a lowercase letter must be a type (`is_type`) or allowlisted;
   - a call's name (the part before `(`) must be a function, a type (an initializer), or allowlisted;
   - other lowercase parts are not checked.

Each stale reference is one hit at its line: the text `missing path: TOKEN` or `unknown name: NAME` (naming the part that is unknown when the name is dotted), and `extra` with `kind` (`path` or `name`), `token`, `citation_kind`, `id`. Always, on standard error: `doclib: N stale references (P paths, M names)`. `default_max = 20`; exit 0 when there are none, 1 when there are some.

Put the work in `def stale_items(pages, repo, index, allow) -> list[StaleItem]` (a frozen dataclass with `page`, `line`, `heading`, `kind`, `token`, `citation_kind`, `detail`), and the allowlist in `def load_allowlist(root) -> Allowlist`. The lint (another task) will count `stale_items` per page.

### The allowlist

`.claude/skills/doc-library/stale-allowlist.txt`: one entry per line; `#` starts a comment; blank lines are ignored. An entry holding `/` is a path prefix (`.claude/worktrees/`); an entry ending in `*` is a name prefix (`NS*`); any other entry is an exact name. Start the file with a comment saying what may go in it.

Build it from today's docs: run `stale` on the real repository (`--scope docs` and then `--scope all`; both read only), and allowlist only names that are not TextMouth's own: Apple's SDK names and prefixes (`NS*`, `UI*`, `AV*`, `XC*`, `CF*`, `LS*`, `INFOPLIST_KEY_*`, SwiftUI's views and modifiers, Swift's standard library), the vendored packages' names (look under `Vendor/` and `build/DerivedData/SourcePackages/checkouts/` if it exists), Info.plist keys and build settings, the targets and schemes in `project.yml`, the branch `TestBuild`, and the runtime folders `.claude/worktrees/`, `.claude/agent-bbs/`, and `.github/test-request.json`. Never allowlist a name TextMouth itself once declared or a path it once had: those are what `stale` exists to report. When unsure, leave it out. The lead's census found 78 distinct undeclared type-shaped names (158 uses) and 17 call names in the lint pages, most of them targets, Info.plist keys, or Apple's; `TextMouth/Services/WatchedProcess.swift` (in `docs/architecture/platforms.md`) looked like a real stale path. Report which entries you added by category, and list every remaining stale reference in today's docs scope (it is the number the lead reports).

Tests: each exception above; a path prefix, a name prefix, and an exact entry; a dotted name with one unknown part; a call to an initializer; a file name in backticks skipped; the summary line; JSON fields; `code` on a section with a Files: line, a backticked call, an unbackticked type, a name with five declarations (three printed, `(+2 more)`), and a missing citation.

## 3. `suggest-src TARGET` (commit 3, `cmd_suggest_src.py`, `tests/test_suggest_src.py`)

The paths a section's marker `src` should hold, for an agent (or the later `mark` command) to copy.

```python
@dataclass(frozen=True)
class Suggestion:
    path: str       # repository-relative; a folder ends in /
    line: int       # the declaration's line, or 1
    reason: str     # "Files: line", "declares ReaderViewModel (named 4 times)", "file name EPUBParser.swift"
def suggest_paths(page: Page, section: Section, repo: RepoFiles, index: SwiftIndex) -> list[Suggestion]
```

Candidates, leaving out every path the marker's `src` already resolves to:
1. each path the section's Files: blocks resolve to, in order;
2. for each name of `mentions(blocks, index)`: the files of `type_files` when there are one or two; for a call, the files declaring the function when there are one or two;
3. each backticked bare file name (`` `EPUBParser.swift` ``) that resolves.
Each path once, at its first reason. Order: Files: paths first, then the rest by how often the section names them (most first), then by first mention.

`suggest-src TARGET` prints one hit per suggestion: `path:L-L`, the section's heading, and the reason. `default_max = 20`; exit 0 with suggestions, 1 without.

Tests: a section with a Files: line, a type named three times unbackticked and once backticked, a function declared in one file, a function declared in four files (not suggested), a bare file name, and a marker whose src already holds one of the paths.

## 4. Measure (no commit)

From your worktree's root, time `stale`, `stale --scope all`, `code` on a section of `docs/architecture/state/saving-failures.md` (use `PAGE:LINE`), and `suggest-src` on the same section, with `/usr/bin/time -p python3 -I .claude/skills/doc-library/scripts/doclib.py ...`; each must take under a second. Report the times and `SwiftIndex.load`'s.

## Report

Rebase onto `team/doclib` if it moved, run `python3 -m unittest discover -s .claude/skills/doc-library/scripts/tests` (all green; give the count), post `done: doclib/names` to `team:doclib`, and `bbs release doclib-names --all`.

Your final message, at most 50 lines: branch and tip; each commit (hash, subject); the test count; the times; the allowlist's entries by category; today's stale references (count, and the list when under 30); every rule above you changed or could not meet, and why. Commit messages end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

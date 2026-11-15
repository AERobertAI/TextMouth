# doclib task `lint`: the rules, the ratchet, and `lint`

You are `doclib-lint`, a worker of team `doclib` (lead `doclib-lead`). Branch `doclib/lint`, made from `team/doclib`.
The team builds the `doc-library` skill (`.claude/skills/doc-library/`): a standard-library Python tool that finds sections of TextMouth's docs and checks them against `docs/agents/writing-docs.md`. `team/doclib` already holds the Markdown model (`docmodel.py`, with `lint_pages`, `LOG_PAGES`, `INDEX_PAGES`), `targets.py` (with `github_slug`), `repofiles.py`, `citations.py`, and `sentences.py`. Read them first; build on them, never around them.
You write the lint: the rules, a baseline file that lets it gate merges from today (a page may not get worse), and the `lint` command. Another worker (`doclib-gate`) writes `split-check`, `make lint-docs`, and the merge hook at the same time, and will later call your baseline module; a third (`doclib-names`) writes `stale`, which the lead will wire in as one more rule.

## Rules (every one is a hard rule)

- No `rm` at all, and no deleting from scripts (a test's own `tempfile.TemporaryDirectory` is fine).
- Never search from `/` or `~`; search only this worktree.
- Never read, list, stat, copy, or open anything under `~/.TextMouth` or `~/Library/CloudStorage`. The code reads only files inside the repository folder it is given.
- Never push, never merge into `main`, never `make install`. Nothing here builds the app or needs a train.
- Keep shell commands plain; put anything fancy in a small script run with `python3 -I -B`.
- Edit no Markdown file. Tests never read the real docs; they build their own repositories.

## Start

1. `git switch -c doclib/lint team/doclib`. This brief is then at `Scripts/agents/briefs/2026-11-14/doclib/lint.md`.
2. Read `docs/agents/writing-docs.md` closely (every rule below comes from it), then `.claude/skills/doc-library/scripts/`: `doclib.py`, `output.py`, `docmodel.py`, `targets.py`, `repofiles.py`, `citations.py`, `sentences.py`, `cmd_outline.py`, `cmd_show.py`, and `tests/doclib_case.py`.
3. Register: `python3 .claude/skills/agent-bbs/scripts/bbs.py register doclib-lint --role "doclib: lint rules, baseline, lint" --branch doclib/lint --files .claude/skills/doc-library/scripts/lintrules.py .claude/skills/doc-library/scripts/baseline.py .claude/skills/doc-library/scripts/cmd_lint.py .claude/skills/doc-library/sales-words.txt .claude/skills/doc-library/lint-baseline.json '.claude/skills/doc-library/scripts/tests/test_lint*.py' '.claude/skills/doc-library/scripts/tests/test_baseline.py' --team doclib`. Read `bbs inbox doclib-lint --unread` before each commit and before your report.
4. Everything under `.claude/` is gitignored, and so is `*.txt`: stage each new file with `git add -f`.

Style: Python 3.11 standard library; a comment or docstring on every function and non-obvious block; type hints; one helper, never two copies. Every limit is one module constant. Load `RepoFiles` once per run.

## 1. `scripts/lintrules.py` and `sales-words.txt` (commit 1, with `tests/test_lintrules.py`)

```python
LINE_LIMIT = 300            # characters
SECTION_LIMIT = 40          # lines, a section's start..end
PAGE_LIMIT = 40_000         # bytes; a kB is 1,000 bytes, as the Finder counts
PAGE_LIMITS = {"AGENTS.md": 12_000, "CLAUDE.md": 3_000}
KEYS_LIMIT = 8
INDEX_LINE_WORDS = 12
QUOTE_WORDS = 6

@dataclass(frozen=True)
class Violation:
    page: str
    rule: str
    start: int
    end: int
    heading: str
    detail: str

RULES: list[tuple[str, Callable[[LintContext], Iterable[Violation]]]]
def lint(root: Path, rules: Iterable[str] | None = None) -> list[Violation]
```

`LintContext` carries what every rule needs, built once: the root, the parsed lint pages (`docmodel.lint_pages`), the `RepoFiles`, and the sales words. `RULES` is the one list of rules, in the order below; a rule is a function from the context to its violations, so adding one (the lead will add `stale`) is one function and one line.

Page kinds: the *lint pages* are `docmodel.lint_pages(root)`; the *log pages* are `docmodel.LOG_PAGES`; the *index pages* are `docmodel.INDEX_PAGES`; the *reference pages* are the pages under `docs/user/`, `docs/developer/`, `docs/architecture/`, and `docs/agents/`, less the log pages. "Prose" means every block but code, front matter, markers, rules, and HTML comments; inline code spans, link destinations, and URLs inside prose are not prose either.

| Rule | Counts | On |
| --- | --- | --- |
| `line-length` | lines over `LINE_LIMIT` characters, outside code blocks and front matter, marker lines excepted (a marker's `src` can be long) | lint pages |
| `section-length` | sections over `SECTION_LIMIT` lines | lint pages but logs |
| `page-size` | 1 when the page's bytes pass its limit (`PAGE_LIMITS`, else `PAGE_LIMIT`) | lint pages but logs |
| `date` | dates in prose: ISO dates (`2026-10-12`), and month-name dates with a day or a year (`October 12`, `Oct. 12, 2026`, `12 October 2026`, `October 2026`), month names capitalized; a date inside a path-like token (`TODO-2026-09-04.md`, `briefs/2026-11-14/`) is not counted | lint pages but logs |
| `user-quote` | double-quoted spans (`"…"` or `“…”`) of `QUOTE_WORDS` or more words, on a line whose prose holds the word `user` (any case) | lint pages but logs |
| `sales-word` | words and phrases of `sales-words.txt`, matched ignoring case at word boundaries, in prose | lint pages |
| `broken-link` | links and images (`[t](dest)`, `![a](dest)`, and reference definitions `[ref]: dest`) in prose whose destination does not resolve: a destination with a scheme (`https:`, `mailto:`) is not checked; `#anchor` alone must be a heading of the page (`targets.page_slugs`); a relative path must name a file or folder in `RepoFiles` from the page's folder, and an `#anchor` after a Markdown page must be one of its headings | lint pages |
| `index-link` | 1 for each Markdown page under `docs/` that the index pages link to other than exactly once | that page |
| `index-line` | list items of an index page that do not start with a link, or have more than `INDEX_LINE_WORDS` words in their visible text (a link counts its text's words; Markdown syntax is not a word) | index pages |
| `marker-missing` | sections (level 1 and deeper) without a marker | reference pages |
| `marker-invalid` | markers with errors, markers with more than `KEYS_LIMIT` keys, and stray markers | lint pages |
| `marker-duplicate-id` | sections whose marker id another section of the lint pages also has | lint pages |
| `marker-src` | marker `src` entries that resolve to nothing | lint pages |
| `duplicate-heading` | headings whose title, ignoring case and inline markup, repeats an earlier heading of the page | lint pages but logs |
| `sentences-per-line` | prose lines of paragraphs, list items, list paragraphs, and quotes that hold more than one sentence by `sentences.split_sentences` (on the line's text after its list marker or `>`) | lint pages but logs |
| `emoji` | characters in U+1F000 to U+1FAFF, U+2600 to U+27BF, U+2B05 to U+2B07, U+2B1B, U+2B1C, U+2B50, U+2B55, and U+FE0F, outside code | lint pages |

A violation's lines are the line (or the section, for `section-length`; the page's first line for `page-size` and `index-link`) where it is; its detail says what is wrong in a few words, with the numbers (`1,204 characters, limit 300`). Braille cells (U+2800 to U+28FF) and arrows are not emoji: the docs are about braille.

`sales-words.txt` starts with a comment line, then one word or phrase per line: seamless, seamlessly, powerful, robust, comprehensive, effortless, effortlessly, cutting-edge, state-of-the-art, world-class, best-in-class, blazing, blazingly, game-changing, revolutionary, next-generation, stunning, delightful.

Tests: one or more cases for each rule, a page where it does not apply (a log page, an index page, a page outside the reference areas), and the exceptions in the table (a code block's long line, a marker's long line, a date in a file name, a braille cell, a link with a scheme, a heading anchor).

## 2. `scripts/baseline.py` and `cmd_lint.py` (commit 2, with `tests/test_baseline.py` and `tests/test_lint.py`)

### The ratchet

`.claude/skills/doc-library/lint-baseline.json` records each page's count of each rule's violations. The lint fails only when a page has more violations of a rule than the baseline records (a page or rule missing from it counts 0), so it can gate merges while the docs are still being fixed.

```python
BASELINE = ".claude/skills/doc-library/lint-baseline.json"
Counts = dict[str, dict[str, int]]      # page -> rule -> count, zero counts left out
def counts(violations: Iterable[Violation]) -> Counts
def read_baseline(text: str) -> Counts
def load_baseline(root: Path) -> Counts | None              # None when the file is not there
def baseline_at(root: Path, ref: str) -> Counts | None      # git show REF:BASELINE; None when absent
def write_baseline(root: Path, data: Counts) -> None
def lowered(old: Counts, now: Counts, pages_present: set[str]) -> Counts
def regressions(base: Counts, now: Counts) -> list[tuple[str, str, int, int]]   # (page, rule, now, base)
def totals(data: Counts) -> dict[str, int]
```

The file is written one page per line, pages and rules sorted, so two branches that lower different pages merge without a conflict:

```
{
  "version": 1,
  "pages": {
    "AGENTS.md": {"date": 61, "line-length": 69},
    "README.md": {"index-line": 20}
  }
}
```

`write_baseline` writes through a temporary file in the same folder and `os.replace`, so a failed write never leaves half a file.

### `lint` and its options

- `lint`: prints, for each regression, a line `PAGE:1-1  -  RULE: N now, baseline B`, then that page's violations of that rule as hits (all of them, within `--max`, default 20 in all); then on standard error `doclib lint: R regressions on P pages` or `doclib lint: no page got worse (V violations, all within the baseline)`. Exit 1 on a regression, else 0. With no baseline file, every violation is a regression.
- `--report`: every violation as a hit (capped by `--max`), then the totals on standard output, one line per rule in `RULES` order, `total RULE: N on P pages`, and a last line `total: N violations on P pages`. Exit 0. Under `--json` the hits are JSON lines and the totals one last object `{"totals": {...}, "violations": N, "pages": P}`.
- `--update-baseline`: lowers the baseline to today's counts and never raises one (`lowered`: each count becomes the smaller of the two; pages that no longer exist are dropped), creating the file from today's counts when there is none; prints each change (`lowered PAGE RULE B -> N`), then runs as `lint` does.
- `--rebuild-baseline`: writes today's counts, raising them where they rose. Its help says it is for the orchestrator alone, after it accepts a regression.
- `--against REF`: also fails when, for any rule, the baseline's total over all pages is higher than the total in the baseline at `git merge-base REF HEAD` (a missing baseline there skips this check): `baseline raised: RULE total N, B at BASE`. A page split moves counts between pages without raising a total, which this allows; a count raised by hand fails. `make lint-docs` passes `--against main` and the merge hook `--against HEAD`.
- `--rule R[,R]` keeps only those rules, and `--skip R[,R]` leaves them out (an unknown rule is a usage error naming the rules); `--page PAGE` keeps one page (`targets.resolve_page`). The baseline comparison covers only what is kept.

Tests: each option; the file's exact format; `lowered` never raising; a page that vanished dropped; `--against` in a git repository (a raised total fails, a moved count passes, no baseline at the base passes); a regression's lines; `--report` totals and JSON.

## 3. The baseline itself (commit 3)

On your branch, run `lint --report --max 0` against the real repository (read only), check a sample of each rule's violations by reading the lines (say in the report which rules you checked and how), fix any rule that gives a false hit, then `lint --update-baseline` to create `lint-baseline.json`, and commit it with `git add -f`. The lead rebuilds it when the team's branches are joined; yours shows it works. Then time `lint` and `lint --report` with `/usr/bin/time -p` (each under a second without the `stale` rule; say if not).

## Report

Rebase onto `team/doclib` if it moved, run `python3 -m unittest discover -s .claude/skills/doc-library/scripts/tests` (all green; give the count), post `done: doclib/lint` to `team:doclib`, and `bbs release doclib-lint --all`.

Your final message, at most 50 lines: branch and tip; each commit (hash, subject); the test count; the times; `lint --report`'s totals by rule; each false hit you found and how you fixed it; every rule above you changed or could not meet, and why. Commit messages end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

# doclib task `gate`: `split-check`, `make lint-docs`, and the merge hook

You are `doclib-gate`, a worker of team `doclib` (lead `doclib-lead`). Branch `doclib/gate`, made from `team/doclib`.
The team builds the `doc-library` skill (`.claude/skills/doc-library/`): a standard-library Python tool that finds sections of TextMouth's docs and checks them against `docs/agents/writing-docs.md`. `team/doclib` already holds the Markdown model (`docmodel.py`), `targets.py`, `repofiles.py`, and `citations.py` (with `FILES_LINE` and `files_block_paths`). Read them first; build on them, never around them.
You write `split-check`, which proves a reworked page holds the same words in the same order, so a page split needs no human review; and you wire the lint into `make lint-docs` and into `Scripts/agents/merge-chain.sh`. Another worker (`doclib-lint`) writes the lint and its baseline (`lintrules.py`, `baseline.py`, `cmd_lint.py`) at the same time: your hook calls `doclib.py lint --against HEAD`, whose interface is fixed below, and the lead resumes you once the lint is on `team/doclib` for the last part.

## Rules (every one is a hard rule)

- No `rm` at all, and no deleting from scripts (a test's own `tempfile.TemporaryDirectory` is fine).
- Never search from `/` or `~`; search only this worktree.
- Never read, list, stat, copy, or open anything under `~/.TextMouth` or `~/Library/CloudStorage`.
- Never push, never merge into `main`, never `make install`. Nothing here builds the app or needs a train; never run `merge-chain.sh` against this repository (its tests run copies in throwaway repositories).
- Keep shell commands plain; put anything fancy in a small script run with `python3 -I -B`.
- Edit no Markdown file. Tests never read the real docs.
- `Scripts/agents/` belongs to the agent `ghci` today. The lead has posted a notice that this team changes `Scripts/agents/merge-chain.sh` and adds `Scripts/agents/tests/test_merge_chain.py`; change nothing else under `Scripts/agents/`, and read `bbs inbox doclib-gate --unread` for word from `ghci` before you commit there.

## Start

1. `git switch -c doclib/gate team/doclib`. This brief is then at `Scripts/agents/briefs/2026-11-14/doclib/gate.md`.
2. Read `docs/agents/writing-docs.md`, then `.claude/skills/doc-library/scripts/` (`doclib.py`, `output.py`, `docmodel.py`, `targets.py`, `repofiles.py`, `citations.py`, `cmd_outline.py`, `cmd_show.py`, `tests/doclib_case.py`), `Scripts/agents/merge-chain.sh`, the Makefile's lint targets (`lint-tests`, `lint-a11y`, `lint-ogg`, and `LINT_BASE`), and two tests in `Scripts/agents/tests/` for their style (`test_run_locked.py`, `test_typecheck.py`).
3. Register: `python3 .claude/skills/agent-bbs/scripts/bbs.py register doclib-gate --role "doclib: split-check, make lint-docs, merge hook" --branch doclib/gate --files .claude/skills/doc-library/scripts/splitcheck.py .claude/skills/doc-library/scripts/cmd_split_check.py .claude/skills/doc-library/scripts/tests/test_split_check.py Makefile Scripts/agents/merge-chain.sh Scripts/agents/tests/test_merge_chain.py --team doclib`. Read `bbs inbox doclib-gate --unread` before each commit and before your report.
4. Everything under `.claude/` is gitignored: stage each new file there with `git add -f`.

Style: Python 3.11 standard library; a comment or docstring on every function and non-obvious block; type hints; one helper, never two copies. In the shell script, the same comment style as the file has, and plain constructs.

## 1. `split-check OLD NEW [NEW ...]` (commit 1, `splitcheck.py`, `cmd_split_check.py`, `tests/test_split_check.py`)

Whether two versions of a page hold the same words in the same order, ignoring headings, list markers, markers, and white space.

```python
@dataclass(frozen=True)
class Word:
    text: str
    source: str      # the file (or REF:PATH) it came from
    line: int
def words(text: str, source: str, files_to_src: bool = False) -> list[Word]
def read_version(root: Path, spec: str) -> tuple[str, str]   # (source label, text): a path inside the root, or REF:PATH through git show
def compare(old: list[Word], new: list[Word]) -> Difference | None
```

- `words`: parse with `docmodel.parse`; leave out front matter, heading lines, marker lines, and blank lines; from each other line strip the leading list marker (`-`, `*`, `+`, `1.`, `1)`) and quote markers (`>`), then split at white space. Code blocks and tables keep their words. The NEW files' words follow one another in the order given, so one page split into three is `split-check OLD NEW1 NEW2 NEW3`.
- `OLD` (and any NEW) may be `REF:PATH`, read with `git -C ROOT show REF:PATH`; otherwise a path in the working tree inside the root. A path outside the root, or a ref git does not know, is a usage error.
- `--files-to-src`: for converting `Files:` lines into markers. Leave every Files: block (`citations.FILES_LINE`, continuation lines included) out of both sides' words, and check that each path an OLD Files: block names (its tokens that `RepoFiles.is_repo_path` accepts, compared after `RepoFiles.resolve` when they resolve, else as written) is named by a NEW marker's `src` or a NEW Files: block; each one missing is a failure, listed by token.
- Output: `split-check: same words (N words)` and exit 0; or the first difference, as `OLD-SOURCE:LINE` and `NEW-SOURCE:LINE` with up to eight words of context on each side, each side's word count, and exit 1.
- Find the first difference with one linear walk; pages run to 35,000 words, and the whole check must take well under a second.

Tests: identical text reflowed (one sentence per line) passes; a heading added and a marker added pass; a bullet turned into a paragraph passes; one word changed fails, naming both lines; a word moved fails; one page split into two files passes in the right order and fails in the wrong one; `REF:PATH` from a git repository; `--files-to-src` passing when the paths moved into a marker and failing, naming the token, when one was dropped; a path outside the root refused.

## 2. `make lint-docs` and the merge hook (commit 2: `Makefile`, `Scripts/agents/merge-chain.sh`; commit 3: `Scripts/agents/tests/test_merge_chain.py`)

The lint's interface, which `doclib-lint` builds: `python3 -I .claude/skills/doc-library/scripts/doclib.py lint --against REF` exits 0 when no page has more violations than `.claude/skills/doc-library/lint-baseline.json` records and the baseline's totals are not above those at `git merge-base REF HEAD`, and 1 otherwise, printing what got worse.

### The Makefile

Add `lint-docs` beside `lint-tests`, `lint-a11y`, and `lint-ogg`, in their style (a `##` comment above saying what it checks, in their words' manner; the `.PHONY` line; a `help` line):

```make
lint-docs:
	@python3 -I .claude/skills/doc-library/scripts/doclib.py lint --against $(LINT_BASE)
```

### `Scripts/agents/merge-chain.sh`

Today it runs `git merge --no-ff "$branch" -q -F "$message"`, which commits at once, then resolves a conflict in `project.pbxproj` alone with xcodegen and commits, checks the committed project against a fresh generation, and runs the full suite. Change it so that:
1. the merge stops before committing (`git merge --no-ff --no-commit`), keeping the existing check that aborts on any conflict but `TextMouth.xcodeproj/project.pbxproj`, and the regeneration of a conflicted project (staged, not yet committed; keep its log line);
2. on the merged tree, before anything is committed, it runs the docs lint when the tree has the skill: `python3 -I .claude/skills/doc-library/scripts/doclib.py lint --against HEAD`, its output into the merge's log. On a failure it logs `DOCS_LINT_FAILED`, aborts the merge (`git merge --abort`, leaving the branch where it was), and stops the chain; on a pass it logs `DOCS_LINT_OK`; without the skill it logs `DOCS_LINT_SKIPPED`;
3. it then commits the merge with the message file (`git commit -q -F "$message"`);
4. when every file the merge changes (`git diff --cached --name-only HEAD` before that commit) ends in `.md`, it logs `MARKDOWN_ONLY_NO_SUITE`, skips the project check and the suite, and goes on to the next branch: AGENTS.md has a documentation-only branch merged without a suite, and the lint is now its check;
5. the summary it prints for each merge also shows the `DOCS_LINT_` and `MARKDOWN_ONLY_` lines;
6. its header comment says all of this in a few lines, in the file's style.

Run `bash -n` on it, and `shellcheck` if it is installed (say which).

### `Scripts/agents/tests/test_merge_chain.py`

In the style of the other tests there (a module docstring saying how to run them, `unittest`, `tempfile`, a throwaway repository per test). Each test makes a git repository in a temporary folder with a fixed identity (`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`, author and committer variables), a `main` branch, and these stand-ins:
- a copy of the real `merge-chain.sh` at `Scripts/agents/merge-chain.sh` in the throwaway repository, run from there (the script changes to `git rev-parse --show-toplevel`, so it works on the throwaway repository and never this one);
- an executable `.claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh` that appends a line to a record file and prints `Executed 1 tests, with 0 tests skipped and 0 failures` and `** TEST SUCCEEDED **`;
- an `xcodegen` on `PATH` (a folder of the test's own put first) that does nothing and exits 0;
- a `.claude/skills/doc-library/scripts/doclib.py` that appends its arguments, and whether `.git/MERGE_HEAD` exists, to a record file, and exits 1 when a file named `LINT-FAILS` is in the tree, else 0;
- `MERGE_LOG_DIR` pointing into the temporary folder.

Cases:
1. a branch changing a code file: merged (main's tip is a merge commit with the message file's subject), the stand-in lint ran with `lint --against HEAD` while `MERGE_HEAD` existed, the suite ran, `CHAIN_COMPLETE`;
2. a branch adding `LINT-FAILS`: `CHAIN_STOPPED`, main's tip unchanged, no `MERGE_HEAD`, a clean `git status`, the suite not run, `DOCS_LINT_FAILED` in the log;
3. a branch changing only a Markdown page: the lint ran, merged, the suite not run, `MARKDOWN_ONLY_NO_SUITE` in the log;
4. a tree without the skill's `doclib.py`: merged, `DOCS_LINT_SKIPPED`, the suite ran;
5. two branches where the first fails the lint: the chain stops before the second.
Each test must take a few seconds at most. Run the folder's whole suite (`python3 -I -B -m unittest discover -s Scripts/agents/tests`) and give its count.

Then post `part 1 done: doclib/gate` to `team:doclib`, and stop: give your report (below) as your final message. Do not wait or poll. The lead resumes you with a message once `doclib-lint`'s work is on `team/doclib`.

## Part 2 (when the lead resumes you)

Rebase onto `team/doclib`. Then:
0. Several OLD versions (commit 4a, before the hand-off): OLD may be several versions joined by commas, read in the order given, so a move of sections from one page into another existing page is checked in one step, as in `split-check REF:AGENTS.md,REF:docs/agents/history.md AGENTS.md docs/agents/orchestrator.md docs/agents/history.md` (paths hold no commas). The hand-off below then pools the counts of every OLD page. Tests: a section moved from one page to the top of another passes in the matching order and fails in another.
1. `split-check ... --update-baseline` (commit 4): when the check passes and the OLD page (the PATH of `REF:PATH`) has entries in the baseline, hand its counts to the NEW pages: lint the NEW pages; for each rule, the pool is OLD's count plus the counts the baseline already holds for NEW pages other than OLD's path; refuse, writing nothing and naming the rule, when the NEW pages' counts for a rule pass its pool; otherwise set each NEW page's entry to its counts, and drop OLD's entry when OLD's path is not a NEW page and no longer exists. Use `baseline.py`'s functions; add none of your own for reading or writing the file. Tests: a split that keeps the counts within the pool; one that raises a rule (refused, file unchanged); a split that keeps the old page as one of the new ones.
2. `test_merge_chain.py` case 6 (commit 5): the real skill copied into the throwaway repository (`.claude/skills/doc-library/` from this worktree) with a docs page and a baseline made by `lint --update-baseline`; a branch adding the word "seamless" to the page is stopped by the real lint, and a branch changing a code file is merged.

## Report

Rebase onto `team/doclib` if it moved, run `python3 -m unittest discover -s .claude/skills/doc-library/scripts/tests` and `python3 -I -B -m unittest discover -s Scripts/agents/tests` (all green; give both counts), post `done: doclib/gate` to `team:doclib`, and `bbs release doclib-gate --all` at the very end.

Your final message, at most 40 lines: branch and tip; each commit (hash, subject); both test counts; `split-check`'s time on `docs/architecture/state/imports.md` against itself (`/usr/bin/time -p`); `bash -n` and `shellcheck` results; every rule above you changed or could not meet, and why. Commit messages end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

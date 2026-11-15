# doclib task `reflow`: one sentence per line, word for word

You are `doclib-reflow`, a worker of team `doclib` (lead `doclib-lead`). Branch `doclib/reflow`, made from `team/doclib`.
The team builds the `doc-library` skill (`.claude/skills/doc-library/`). A second team will use it to rework every page of TextMouth's docs, and `reflow` is the command that saves it from retyping them: it puts each sentence of a page on its own line (`docs/agents/writing-docs.md`: "One sentence per line") without changing a word, so the change needs no review.
`team/doclib` holds the Markdown model (`docmodel.py`), the sentence splitter (`sentences.py`), `split-check` (`splitcheck.py`), and `pagewrite.py`, the one way a command writes a page (it re-checks the words and writes atomically). Read them first; build on them, never around them.

## Rules (every one is a hard rule)

- No `rm` at all, and no deleting from scripts (a test's own `tempfile.TemporaryDirectory` is fine).
- Never search from `/` or `~`; search only this worktree.
- Never read, list, stat, copy, or open anything under `~/.TextMouth` or `~/Library/CloudStorage`.
- Never push, never merge into `main`, never `make install`. Nothing here builds the app or needs a train.
- Never run `reflow` on a page of a checkout, yours included: only on pages in a test's temporary folder, or in a scratch copy under `build/` (see Measure).
- Keep shell commands plain; put anything fancy in a small script run with `python3 -I -B`.
- Edit no Markdown file. Tests never read the real docs.

## Start

1. `git switch -c doclib/reflow team/doclib`. This brief is then at `Scripts/agents/briefs/2026-11-14/doclib/reflow.md`.
2. Read `docs/agents/writing-docs.md`, then `.claude/skills/doc-library/scripts/`: `doclib.py`, `output.py`, `docmodel.py` (how blocks are found, and `list-item`'s `content_col`), `sentences.py`, `splitcheck.py`, `pagewrite.py`, `cmd_show.py`, and `tests/doclib_case.py`.
3. Register: `python3 .claude/skills/agent-bbs/scripts/bbs.py register doclib-reflow --role "doclib: reflow" --branch doclib/reflow --files .claude/skills/doc-library/scripts/cmd_reflow.py .claude/skills/doc-library/scripts/tests/test_reflow.py --team doclib`. Read `bbs inbox doclib-reflow --unread` before each commit and before your report.
4. Everything under `.claude/` is gitignored: stage each new file with `git add -f`.

Style: Python 3.11 standard library; a comment or docstring on every function and non-obvious block; type hints; one helper, never two copies.

## `reflow PAGE [--check]` (commits 1 and 2: `cmd_reflow.py`, `tests/test_reflow.py`)

Commit 1 is the pure function, `def reflow_text(text: str) -> str`, with its tests; commit 2 the command.

Which blocks change: `paragraph`, `list-item`, and `list-para` blocks (`docmodel.parse`). Every other block (headings, code, tables, quotes, HTML comments, markers, rules, front matter) and every blank line is kept byte for byte. A prose block is also kept as it is when any of its lines ends in a hard line break (two or more spaces, or a backslash) or starts, after its indentation, with `<`.

How a block changes:
- Its text is its lines with the list marker (for an item) and each line's leading indentation set aside, joined with `\n`; `sentences.split_sentences` splits it.
- Each sentence becomes one line: inside a sentence, a line break and the indentation after it become one space; other white space is kept as it is.
- The first sentence keeps the block's first line's own start (its indentation, and an item's marker with the spaces after it). Each later sentence starts a new line, indented as the block's first line is (a paragraph, a list paragraph), or to the item's `content_col` (a list item, so a later sentence is the item's continuation, not a new paragraph).
- A split is refused, and the sentence stays on the line of the one before it, when the sentence would begin a block at the start of its new line: a list marker followed by a space or the line's end (`- `, `* `, `+ `, `1. `, `1) `), `#`, `>`, `|`, `<`, a fence (three backticks or tildes), a thematic break, or a line of only `=` or `-`. Put this test in one function, `starts_a_block(text: str) -> bool`.

The page around the blocks: line ends are `\n` (`pagewrite.read_page_text` refuses a page holding `\r` or bytes that are not UTF-8: a word-for-word change must not touch bytes it cannot see), and the file's last line end is kept as it was. Read with `pagewrite.read_page_text` and write with `pagewrite.rewrite(root, path, old, new)`, which refuses (returning split-check's lines, writing nothing) a text that loses, adds, or reorders a word.

Before calling `rewrite`, `reflow` makes two stricter checks of its own: every non-space character of the page is the same, in the same order (`"".join(old.split()) == "".join(new.split())`); and parsing the new text gives the same blocks, kind for kind and in order, with the same headings, so a split that turned a sentence into a list item or a heading fails here even if the refusal above missed it. Any failed check writes nothing, prints what failed, and exits 1.

Output: `reflow: PAGE: N lines became M` and exit 0; `reflow: PAGE: already one sentence per line` and exit 0 when nothing changes. `--check` writes nothing: it prints the same line and exits 1 when the page would change, 0 when it would not. `default_max = 0`.

Tests, each on a page written in the test's temporary folder:
- a paragraph of three sentences on one line becomes three lines;
- a sentence wrapped over two lines becomes one line;
- a list item of two sentences: the second on a continuation line indented to the item's text, for `- `, `1. `, and a nested item;
- a list paragraph after a blank line keeps its indentation;
- a sentence that starts with `2. ` or `- ` is not moved to a line of its own;
- a code block, a table, a quote, a heading, front matter, a marker, an HTML comment, and a block with a hard line break are byte-identical afterwards;
- a page without a last line end stays without one;
- running it twice changes nothing the second time;
- `--check`'s exit statuses, and the page unchanged by it;
- a page holding `\r` refused;
- a reflow that the block check would catch (force one by patching `starts_a_block` to say False, with a sentence beginning `1. `): nothing written, exit 1;
- non-ASCII text (`é`, a braille cell `⠁`) kept.

## Measure (no commit)

Make a scratch copy of two real pages, `docs/architecture/state/saving-failures.md` and `docs/user/search-library.md`, in a plain folder `build/doclib-reflow/scratch/` of your worktree (`build/` is gitignored), at their docs paths, with a second copy of each under `orig/`. A plain folder has no `.git`, so pass it as `--root` (the tool then walks it for its file list). Run `reflow` on each page there, then `split-check orig/PAGE PAGE` for each, and `lint --report --rule line-length,sentences-per-line --page PAGE` before and after if the lint is on `team/doclib`. Give the lines-became numbers, split-check's lines, the times (`/usr/bin/time -p`), and three reflowed lines you checked by eye.

## Report

Rebase onto `team/doclib` if it moved, run `python3 -m unittest discover -s .claude/skills/doc-library/scripts/tests` (all green; give the count), post `done: doclib/reflow` to `team:doclib`, and `bbs release doclib-reflow --all`.

Your final message, at most 40 lines: branch and tip; each commit (hash, subject); the test count; the measurements; every rule above you changed or could not meet, and why. Commit messages end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

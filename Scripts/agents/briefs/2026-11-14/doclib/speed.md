# doclib task `speed`: `lint` and `stale` under a second, with no change in what they say

You are `doclib-speed`, a worker of team `doclib` (lead `doclib-lead`). Branch `doclib/speed`, made from `team/doclib`.
The `doc-library` skill (`.claude/skills/doc-library/`) must answer in under a second for the whole repository (it parses everything each run; there is no index on disk). `lint` now takes about 1.3 s of wall time and 0.95 s of processor time, and `stale --scope all` about 1.4 s. Make them fast without changing one byte of what they print.

## Rules (every one is a hard rule)

- No `rm` at all, and no deleting from scripts (a test's own `tempfile.TemporaryDirectory` is fine).
- Never search from `/` or `~`; search only this worktree.
- Never read, list, stat, copy, or open anything under `~/.TextMouth` or `~/Library/CloudStorage`.
- Never push, never merge into `main`, never `make install`. Nothing here builds the app or needs a train.
- Keep shell commands plain; put anything fancy in a small script run with `python3 -I -B`.
- Edit no Markdown file. Change only `lintrules.py`, `swiftindex.py`, `cmd_stale.py`, and `sentences.py` under `.claude/skills/doc-library/scripts/`, and add tests beside theirs; another worker adds `cmd_mark.py` at the same time.

## Start

1. `git switch -c doclib/speed team/doclib`. This brief is then at `Scripts/agents/briefs/2026-11-14/doclib/speed.md`.
2. Register: `python3 .claude/skills/agent-bbs/scripts/bbs.py register doclib-speed --role "doclib: lint and stale speed" --branch doclib/speed --files .claude/skills/doc-library/scripts/lintrules.py .claude/skills/doc-library/scripts/swiftindex.py .claude/skills/doc-library/scripts/cmd_stale.py .claude/skills/doc-library/scripts/sentences.py --team doclib`. Read `bbs inbox doclib-speed --unread` before each commit and before your report.
3. Everything under `.claude/` is gitignored: stage files with `git add -f`.
4. Before changing anything, record the references the change must reproduce, from your worktree's root (all read only), into `build/doclib-speed/` (gitignored):
   - `python3 -I .claude/skills/doc-library/scripts/doclib.py lint --report --max 0 > build/doclib-speed/lint-before.txt`
   - the same with `--json` into `lint-before.json`;
   - `stale --scope all --max 0 --json` into `stale-all-before.json`, and `stale --max 0` into `stale-before.txt`.
   After each commit, make the same files as `-after` and `cmp` each pair: every one must be identical.

## What the lead's profile found (cProfile of `lint`, 1.54 s under the profiler)

- `SwiftIndex.load`: 0.65 s, of which reading the 1,708 Swift files (30 MB) is 0.25 s and the eight keyword scans 0.26 s.
- `rule_date` 0.20 s (0.11 s of it the loop itself), `rule_sentences_per_line` 0.16 s, `rule_sales_word` 0.14 s (0.125 s in one alternation regex run on every line), `rule_emoji` 0.07 s: each walks the prose a line at a time and calls a regex on every line.
- Building the context (pages and the file list) 0.11 s; `stale_items` 0.09 s.

## What to do (one commit each, the suite green and the references identical after each)

1. The per-line rules: run each regex once per prose block (`ProseBlock.plain` is already the block's text with code spans, link destinations, and URLs blanked, newlines kept) and map each match's offset to its line with one `bisect` over the block's line starts. For the sales words, a regex alternation tried at every position is the cost: find each word with `str.find` on the block's lowercased text and check its word boundaries yourself, or prefilter blocks with one cheap test; keep the same matches. For the emoji, skip a block that one search finds nothing in. For `sentences-per-line`, skip a line that holds no `.`, `!`, or `?` followed by white space before calling the splitter.
2. The Swift index: measure first (`time.perf_counter` around `SwiftIndex.load` in a scratch script, best of five). Try reading each file with one `os.open`/`os.read` pair, and a scan that finds all eight keywords in one pass over the bytes if that is faster than eight literal-prefix passes (the earlier worker found one alternation twice as slow; a single pass over candidate positions found by `bytes.find` for each keyword's first letters may still win). Keep what is fastest; report each variant's time.
3. Only if `lint` is still over 0.9 s of wall time (best of three `/usr/bin/time -p` runs, on a machine that may be loaded) after items 1 and 2: a cache of the Swift index under `build/doc-library/swift-index.json` in the repository's own folder, holding each file's declarations keyed by its path, size, and modification time in nanoseconds; a file whose size or time differs is scanned again; the cache is read only when its own format version matches, ignored (never fatal) when it cannot be read or parsed, and written through a temporary file in the same folder and `os.replace` only when something changed. Test it: a changed file is rescanned, a removed one is dropped, a corrupt cache is ignored, nothing is written when nothing changed. If you add it, say so in the report: the lead names it in SKILL.md.
4. `stale --scope all`: profile it the same way; fix what is cheap (a second parse of the same page, a citation scan done twice) and report what is left.

## Measure and report

Rebase onto `team/doclib` if it moved, run `python3 -m unittest discover -s .claude/skills/doc-library/scripts/tests` (all green; give the count), post `done: doclib/speed` to `team:doclib`, and `bbs release doclib-speed --all`.

Your final message, at most 40 lines: branch and tip; each commit (hash, subject); the test count; `cmp` of every reference pair after the last commit; for `lint`, `lint --report`, `stale`, `stale --scope all`, and `find seamless`, the best of three wall times (`/usr/bin/time -p`) before and after, and the machine's load average when you measured (`uptime`); each variant you tried for the index and its time. Commit messages end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

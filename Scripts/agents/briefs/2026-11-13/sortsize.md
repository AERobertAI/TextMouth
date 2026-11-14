# The audit's C10 and C18 (November 14, 2026, night)

You are `sortsize`, a Sonnet worker. Read `common.md` beside this brief first and follow it. Its rules bind you:
- the live library;
- `rm` with literal paths only;
- no search from `/` or `~`;
- builds only through the heavy-work lock;
- trains on GitHub;
- no push except through the train tools;
- no merge into main.

Also: **delete nothing tonight.**

Your branch is `perf/sort-helper`, made at local main: `git switch -c perf/sort-helper main`.

## Items

Both items are in `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/optaudit/audit-report.md`, Part C.

1. **C10. One sort helper.**
   - First, build the helper and convert a handful of call sites in a scratch copy. Then read the Release link map, as the audit says (`tools/patterns.py`; find it in the repo and in the audit report's method notes). Measure the size gain with `make check CHECK_ARGS=--without-tests` through `run_locked.py`.
   - If the gain is under 100 KB, stop, and report the measurement instead of converting.
   - Leave `LibraryBookSorter`'s whole-library sorts as they are.
   - Keep every result's order exactly: stable where the old sort was stable, and the same comparator.
   - Two files are being changed by other agents tonight: `BraillePageAnalyzer.swift` and `LibraryViewModel+Cloud.swift`. Don't touch them; list their sorts in your report for later.
2. **C18. The library's `didSet` without the old copy.** Measure first, as the audit says. If the copy costs under 1 ms for 1,500 books, report that and change nothing.

## Work

- Make one commit for each group of call sites, by area. Each must keep the existing order tests green.
- Then:
  1. type-check;
  2. run one train naming the order tests and `PerformanceBaselineTests`;
  3. review your diff;
  4. rebase onto local main;
  5. report as `common.md` says, in at most 40 lines, with the measured sizes before and after.

## If the usage limit stops you

The weekly limit may stop you before you finish; the orchestrator resumes you after the reset, at 07:00 EST. **Commit after every step.** Keep `PROGRESS-sortsize.md` at your worktree's root, staged with `git add -f`, saying what is done and what is next.

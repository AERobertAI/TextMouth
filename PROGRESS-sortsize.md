# sortsize progress

- Baseline Release executable at 6a436b14f: 18,847,264 bytes (make check --without-tests; the build succeeded, signing failed afterwards, as on any agent Mac without the identity).
- Scratch branch perf/sort-helper-scratch: StableSort.swift (a883db048) and four area commits converting every sort except LibraryBookSorter (BraillePageAnalyzer and LibraryViewModel+Cloud hold no sorts at this base).
- Next: converted Release build (build/orchestrator/sortsize/converted.log), compare the executable size. If the gain is under 100 KB: report, make no perf/sort-helper commits. Otherwise: typecheck-tests, one train (order tests + PerformanceBaselineTests), rebase, report.
- C18: measure the copy of 1,500 books (not started).

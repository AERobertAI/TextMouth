# testkit/test-diff: what did this branch do to the EXISTING tests?

Slug `testkit-test-diff`. Branch `testkit/test-diff`, made from `team/testkit` (it has `Scripts/test/difflint.py` and `trap-lint.py`). Python 3 standard library only. **You build nothing.** Read `teams-common.md`'s worker's part first.

## Why

The rule for every worker tonight: "A failing existing test means stop and ask. Never edit, weaken, or work around an existing test, or its fixture, to make your change pass; a test that fails may be the only sign of a bug in the app." The lead's review step says: "any existing test the worker changed, and why." Today that means reading the whole diff. A script can list, in a page, exactly what a branch did to tests that already existed: tests removed or renamed, assertions removed or changed (before and after side by side), skips and expected failures added, timeouts raised, test code commented out. It is the check an orchestrator runs at every merge, and a lead at every review. It complements `trap-lint.py`, which looks at lines a branch ADDS; this looks at what the branch CHANGED OR REMOVED.

## The command

    python3 Scripts/test/test-diff.py [--base REF] [--paths P ...] [--strict] [--selftest] [-h]

- `--base REF` (default `main`): the merge-base of REF and HEAD is the "before" state; the "after" state is the working tree (staged and unstaged edits count, as in `difflint.added_lines`).
- `--paths` default `TextMouthProductionTests` (the hosted tests), which a caller may widen with `TextMouthTests`.
- Exit status: 0 normally; with `--strict`, 1 when there is any finding of the kinds below; 2 for a usage or git problem.

## What it reports (plain words for VoiceOver and braille: no color, no emoji, no box drawing)

First a line per changed file under the paths: `modified TextMouthProductionTests/Foo.swift: 3 added, 5 removed`, `added Bar.swift: 12 tests`, `deleted Baz.swift: 7 tests`, `renamed A.swift to B.swift`. New files get only their test count: their content is for `trap-lint` and for review. A DELETED file is a finding for every test in it.

Then findings, for files that existed before (modified, renamed, deleted), each as `path:line: KIND: text` followed by indented before/after lines:
- `REMOVED-TEST`: a removed `func test…(` line whose name is not added anywhere else in the diff (the same name added in another file is a move, reported once as `MOVED-TEST old to new`).
- `RENAMED-TEST`: a removed and an added `func test…(` in the same hunk with different names.
- `REMOVED-ASSERTION`: a removed line containing `XCTAssert`, `XCTFail`, `XCTUnwrap`, `XCTExpect`, `fulfill(`, `expectation(`, or `await fulfillment`, with no identical line (whitespace-normalized) added in the same file.
- `CHANGED-ASSERTION`: a hunk replacing one or more such lines by others: print each before/after pair. Mark `WEAKER?` when the replacement is plainly weaker: `XCTAssertEqual` replaced by `XCTAssertNotNil`/`XCTAssertTrue`/`XCTAssertFalse` on the same expression, a literal expected value removed, an `XCTAssert` replaced by a comment, `==` replaced by `>=`/`!=`, a message argument removed. Do not guess beyond that: list the rest as plain CHANGED.
- `SKIP-ADDED`: an added `XCTSkip`, `XCTSkipIf`, `XCTSkipUnless`, `XCTExpectFailure`, `XCTExpectedFailure`, `continueAfterFailure`, `#if` or `#else`, or a rename that disables a test (`func disabled_test`, `func xtest`), with the name of the enclosing test (search upward in the new file for the nearest `func `).
- `TIMEOUT-RAISED`: a changed line where a number after `timeout:`, `within:`, `seconds:` or `+ ` (a deadline) is larger than before.
- `COMMENTED-OUT`: an added comment line that contains `XCTAssert`, `XCTFail`, `func test`, or `try `.
- `SETUP-CHANGED`: any change inside `setUp`, `tearDown`, `setUpWithError`, `tearDownWithError`, or `addTeardownBlock` of an existing class (a fixture change that can hide a failure): report the hunk's lines.
The last line: `N files changed, M findings: A removed, B changed, C skips, D timeouts, E commented out`. If there are no findings, say `no existing test was weakened or removed`.

## Build on the engine (DRY)

`Scripts/test/difflint.py` has `run_git`, `repo_root`, `GitError`, and `parse_added_lines`. Add to it, additively, a function `parse_hunks(diff_text)` returning, per file, its status and rename source and a list of hunks with the removed lines and the added lines and their numbers in the old and new file (reuse the hunk-header regex there). `trap-lint.py` and the other linters must keep working unchanged (`python3 Scripts/test/difflint.py --selftest` and `python3 Scripts/test/trap-lint.py --selftest` pass after your change). Use `git diff -U0 --no-color -M --raw`-style information (or `--name-status -M`) for file status. Keep the classification rules in `test-diff.py`, each as a small commented function.

## Selftest and checks

`python3 Scripts/test/test-diff.py --selftest`: canned unified diffs, one per kind (including a clean diff that must report no findings, a pure addition, and a moved test), each with the exact expected output lines. Then prove it on a real change without touching the shared repository: in the scratchpad, copy one small existing test file into a new folder, run `git init` there, commit the original, edit the copy (remove an assertion, add an `XCTSkip`, raise a timeout, rename a test), and run `python3 <your worktree>/Scripts/test/test-diff.py --paths . --base HEAD` from inside that folder. The script finds its repository from the current directory (`difflint.repo_root()` runs `git rev-parse --show-toplevel` there), not from its own location; make sure that holds. Show the output in your report.

## Commits

1. `parse_hunks` in `difflint.py` plus its selftest case.
2. `test-diff.py` with its selftest.

## Do not

Change a rule of `trap-lint.py`. Touch any Swift file or any `*.md`. Create branches or commits in the shared repository other than your own two. Use packages outside the standard library.

## Report (at most 15 lines)

Branch; commits; both selftest results; the sample output on the throwaway repository; what you could not verify.

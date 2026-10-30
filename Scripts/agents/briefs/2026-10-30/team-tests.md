# Team `tests`: make the suite more trustworthy (October 30, 2026)

Read `teams-common.md` beside this file first: it is the pattern, the rules, and the report format, and it stands in for AGENTS.md. You are the lead, `tests-lead`, on branch `team/tests`, made from local `main` by name (`git checkout -b team/tests main`; your worktree may start on an older commit).

The user asked tonight to "improve the tests". The suite has 8777 tests, 78 skipped, and no failures on main, run by `python3 Scripts/test/run-area.py all` (about 20 minutes of tests; `Scripts/test/areas.conf` groups the classes into areas). Its known weaknesses:
- **Load-sensitive tests,** each listed in `teams-common.md` under "Load-sensitive tests": every orchestrator merge that hits one reruns its class alone, which costs time and hides real failures behind "it's just load".
- **78 skipped tests.** Some skip for good reason (opt-in fixtures, macOS versions, network), some perhaps always: on October 6 the hosted button tests were found to skip even with VoiceOver on.
- **Tests that cannot fail:** assertions that run only in a callback that may never be called, expectations never waited for, a comparison of a value with itself, a test whose setup already guarantees its assertion, or an early `return` that always happens.
- **Untested code:** production types that no test names.

## Phase A: find (no build)
Do it yourself, or with up to two read-only reviewers (`model: "opus"`, no worktree, `description: "tests audit <part>"`) if the reading is large; their prompts must say that they change nothing, never read, copy, or write anything under `~/.TextMouth`, and write their report to `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/oct30/tests-audit-<part>.md`.
1. **The load-sensitive tests:** for each, why it is sensitive (a fixed sleep, a wall-clock deadline, a real timer, a race with a background queue, the machine's load in a performance test), and the deterministic form (an injected clock, waiting on the condition itself, an expectation fulfilled by the code under test, a test seam already in the code).
2. **The skips:** list every `XCTSkip`/`throw XCTSkip`/skip helper with its condition, and which of the 78 are skipped on this Mac in a normal run (the last full suite's log is `build/merge-logs/main-after-encoding-choice-merge.log` in the main checkout; read it by grep). For each always-skipped test, say whether it can run, and how.
3. **Vacuous tests:** a scan for the patterns above (`grep -E` over `TextMouthProductionTests` and `TextMouthTests`), each hit checked by reading it.
4. **Untested production code:** types and functions in `TextMouth/` that no test file names, ranked by risk (data written to disk, untrusted input parsed, what a listener hears).
Write the findings to `build/orchestrator/oct30/tests-findings.md` (the absolute path above), and post `findings ready` to `orchestrator`.

## Phase B: fix
With workers, as `teams-common.md` says, one build at a time:
1. Make the load-sensitive tests deterministic, without weakening what they check. A test whose check is about time (a performance baseline) stays as it is.
2. Make always-skipped tests run where they can, or delete a test that can never run and pins nothing, saying why in the commit.
3. Fix vacuous tests so each can fail, and prove it: break the code under test locally (never committed) and see the test fail, then restore it; say so in the worker's report.
4. Add tests for the riskiest untested code. Where a new test shows a real bug, report it on the board to `bughunt-lead` with the evidence, and pin the right behavior with a test that is marked as an expected failure only if the fix is not yours to make (prefer fixing it if the file is unclaimed).

**Never weaken an existing test to make it pass.** A changed assertion needs a reason in the commit that a reviewer can check.

## Files
Test files, test helpers, test seams in production code (an injected clock or queue, with no change in the app's behavior), and `Scripts/test/areas.conf`. The `views`, `braillecodes`, and `bughunt` teams work in production code tonight: claim each file before a worker edits it, read the claims, and agree on the board before touching a file another team claims.

## When you are done
Follow "Finish" in `teams-common.md`: rebase on main, one full suite, report, with the before and after counts (tests, skipped) and the list of load-sensitive tests that are no longer so.

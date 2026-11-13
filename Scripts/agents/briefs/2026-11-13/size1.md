# The app under 20 MB with build settings (November 13, 2026)

You are `size1`, a Sonnet worker. Your branch is `build/size-osize`, made at local main. First read `common.md` beside this brief and follow it.

## The user's words

On November 13, 2026: "I would like it if we could get it under 20 mb again or even 15 mb without loosing anything."

## What the audit found

The Fable audit (`/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/optaudit/audit-report.md`) measured Release builds of main. Read its Part A, and its fixes C1, C2, C5, and C15 in Part C, before you start: they give the lines, the mechanism, the measured bytes, and the tests.

- C1: `SWIFT_OPTIMIZATION_LEVEL: -Osize` in `project.yml`'s TextMouth target, Release only (lines 176 to 195): the app's own code 2.36 MB smaller.
- C2: `SWIFT_OPTIMIZATION_LEVEL=-Osize` on the Makefile's `build` rule (lines 181 to 196, beside `$(NO_COVERAGE)`), which reaches the three packages that `project.yml` can't: 2.08 MB smaller. Don't add `SWIFT_COMPILATION_MODE=wholemodule`: the audit measured it 1.15 MB larger.
- C5: `OTHER_LDFLAGS: -Wl,-no_exported_symbols` in the TextMouth target's Release block: 176 KB. Debug keeps its exports: the test bundle loads against the app.
- Together: executable 18,258,016 bytes, bundle 18.98 MB, against 22,820,048 and 23.55 MB today.
- The cost, measured: the app's own code 1% to 11% slower on ten benchmarks, a millisecond or less each, with identical output; HTML parsing at import 43% slower, about 4 ms more per megabyte of EPUB. The orchestrator takes the audit's recommended answer to its question, yes, and puts the question to the user.

## The work, one commit each

1. C1, then `make generate`, committing `project.yml` and `project.pbxproj`. Check with `python3 -I Scripts/agents/copy_phases.py` and `git diff --stat` that only the setting's lines changed.
2. C2, in the Makefile, with a comment saying why the command line is the only way to reach the packages (as `NO_COVERAGE`'s comment does). Check that `Scripts/check.sh` and `make install` build through that rule; if either doesn't, make it, and say so.
3. C5.
4. The gate: lower `APP_SIZE_LIMIT_MB` in `Scripts/check.sh` (about line 121) to 20, so growth past it fails `make check`.
5. **Proof that nothing changed but the size** (the audit's Part A, "How each would be proved to change nothing"):
   - one `make check` through the lock, `python3 -I /Users/roberteggleston/programming/ai/claude/swift/TextMouth/Scripts/agents/run_locked.py size1 make check`, and its size line in your report (it builds Release from scratch: expect 10 minutes or more); unregister the app it builds afterwards, as the audit's brief says (`lsregister -u <path>`);
   - the audit's benchmark harnesses' checksums for a `-O` and an `-Osize` build, if its tools in `build/orchestrator/optaudit/tools/` run as they are (read them first; run them through the lock); otherwise say why not;
   - a train naming `TextPipelineGoldenTests`, `DocumentGoldenTests`, `MarkupGuardTests`, `BundledLicenseTests`, and any test that reads the build settings or the check script (search the tests for `check.sh`, `APP_SIZE_LIMIT`, and `SWIFT_OPTIMIZATION_LEVEL`).
6. **If it's small** (one script and a make target): a once-per-release check that runs the golden test classes against a Release build made with testability on, as the audit suggests, so a miscompile can't hide behind a Debug suite. Otherwise describe it in the report.

Leave C15 (mergeable traps) and C19 (no function starts) out: each trades crash-report detail, which needs the user's yes. Say what each would save, from the audit.

## Your report

Follow `common.md`'s report, and add: the executable's and the bundle's sizes before and after, from your own `make check`; the benchmark checksums; and the documentation each change needs (`docs/developer/building.md`'s `make build` paragraph and size target).

# Team `fixes`: the TODO's open follow-ups, by batch (October 30, 2026)

Read `teams-common.md` beside this file first: it is the pattern, the rules, and the report format, and it stands in for AGENTS.md. You are the lead, `fixes-lead`, on branch `team/fixes30`, made from local `main` by name (`git checkout -b team/fixes30 main`; your worktree may start on an older commit, and an older branch called `team/fixes` exists, so use the new name).

## What
The user asked tonight to work through "any remaining todos and unfinished work that doesn't require me". A read-only triage agent checked every open item of the TODO against tonight's `main` and grouped the buildable ones into batches of disjoint files: `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/oct30/triage-report.md` (358 KB: read only the line ranges below). Section 2.2 starts at line 643 with a paragraph every batch shares; read it first.

Work these batches, in this order, one task (one worker) per batch, as far as the night allows:
1. **Batch A** (lines 647-693): manifest edits keep the listener's titles and places.
2. **Batch B** (lines 694-735): places that follow their words (T06's follow-ups). Places are the listener's data: run the `places` area and `PlaceRelocationAtRebuildTests`.
3. **Batch C** (lines 736-752): undo for a deleted substitution rule, then FMT08 (pronunciation lexicons as substitution rules).
4. Then, if time remains, in the report's order, skipping D and W (they wait for the `views` and `braillecodes` teams to merge) and any batch whose files another team has claimed on the board: E (775), F (802), G (849), O (1050), R (1173), T (1211), X (1324), Z (1383). Before any batch that changes how a format is read (H, I, J, K, M, N), the report's note at lines 486-494 asks for one commit that gives each format its own line in `PageReaderVersions`; leave those batches to a later night unless everything above is done.

## How
- **Verify first.** The triage read the code tonight, but a worker re-reads each item's lines and `git log` of its files since October 25 before changing anything; an item that no longer holds is dropped and named in the report.
- **One worker per batch,** each item a commit with a regression test that fails without the fix. Settle every decision in the worker's brief from the item's own words in the report (its "fix" and "tests" lines), and say where you chose differently and why.
- **The listener's data:** a fix that touches places, titles, rules, or a manifest must keep every hand edit; say in the commit how the test proves it.
- **Wording:** every new sentence a listener hears is pinned by a test and listed in your report.

## Files
Each batch's files are listed in the report. Six other teams work tonight: `views` (the Library window's categories and views, `ConfigService.swift`, `SettingsViewModel.swift`), `braillecodes` (braille parsers and writers, Book Information's rows), `bughunt` (fixes anywhere in playback, feeds, the library's data, the parsers' traps, and imports), `tests` (test files and test seams), `podcastext` (transcripts and feed downloads), and `speechexport` (export). Claim each file before a worker edits it, read the claims, and leave a batch whose files another team holds for later.

## When you are done
Follow "Finish" in `teams-common.md`: rebase on main, one full suite, report, with each closed item's TODO line number so the orchestrator can strike it.

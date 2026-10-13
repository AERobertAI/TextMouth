# Task brief: rev16, an independent review of T06's branches D and E

Slug `rev16`. You are a read-only reviewer on Opus. You change no file of the app and make no commit; you write your findings into your scratch folder, and the orchestrator files them. Read `common.md` beside this file for the rules everyone follows; skip its build and commit steps, except that you may build and run tests in your own build folder to reproduce a finding.

## Why
T06 makes a book's saved places (the listener's reading position, bookmarks, and skipped headings) follow their words when the book's text is read anew. It is the user's own data. Two branches merged on October 13, 2026:
- **Branch D** (`team/t6d`, merge 112bb7b3): the move at every rebuild of the text cache, with a copy of the old text kept aside, a guarded commit, and recovery at launch.
- **Branch E** (`team/t6e`, merged after it): the move at every load, and Edit Text's moves.

Each team's lead and the orchestrator reviewed them. The last independent review, REV15 of branch C, still found 15 real bugs after the same kind of review. Its findings, each with a reproduction, are in `Scripts/agents/briefs/2026-10-12/rev15-review/`: use them as the model for yours.

## What to review
The app code of both merges: `git diff 112bb7b3^1 <branch E's merge> -- TextMouth`, where `git log --merges --oneline -3` names branch E's merge. The design is `TEXT-ANCHORS-ADDENDUM-2026-10-10.md`, sections 9 and 10, and each merge's TODO entry says what it claims.

Look hardest at what could lose or corrupt the user's places, or hide text they meant to hear:
1. **A place overwritten wrongly:** the guarded takes (`Book.takeMovedPlaces(original:moved:)`, `isAsStored`, `MovedPlaces.taken(by:)`), and every path that writes places: the batch, Redo Text Extraction, the reader's rebuild, the statistics pass, the legacy migration, Edit Text's takes, edits saved while closed, and the move at load.
2. **Skipped headings:** a skip that names the wrong heading, a waiting skip that is lost, or one that names a heading again on too little proof.
3. **Races:** recovery against a reader's rebuild, an edit session against a rebuild, two windows on one book, and a library in the cloud written by two Macs.
4. **The copies aside:** left behind or deleted too early, used for the wrong text, a copy of the book's text that reaches a folder a cloud library uploads, and a crash at each step.
5. **Crash safety:** anything that can trap (subscripts, force unwraps), at launch above all.
6. **Cost at launch and at open,** in a large library: what runs on the main thread, and what runs for every book.

## How (as REV15 did)
- **Gather candidates,** then try to break each one on a concrete case: a hosted test in your own build folder, or a small program compiled against the engine files, as REV15's `build-probe.sh` did.
- **Keep a finding only when it reproduces,** or when the code plainly shows it; rank the confirmed findings most severe first.
- **Never touch** the live library at `~/.TextMouth`, the live board's files, or any branch.

## Report
Write `findings.md` in your scratch folder (`rev16-review/` in the session's scratchpad): one entry per confirmed finding, giving
- its file and line;
- the failure scenario, with concrete inputs;
- what happens and what should;
- its reproduction.

Then reply with at most 40 lines: the count of confirmed findings by severity, the top ones in a sentence each, what you checked and found sound, and the path of `findings.md`.

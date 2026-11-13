# The fix round of `fix/batch-c-replace-encodings` (November 13, 2026)

You are `batchCfix`, a Sonnet worker. You fix what the Opus review of batch C asked for, on that branch. First read `common.md` beside this brief and follow it.

## Start

- In your worktree: `git switch fix/batch-c-replace-encodings`, and check that `git log -1 --format=%h` prints `107971cc`. Its first worker has finished and its folder is gone.
- Read, in the main checkout (`/Users/roberteggleston/programming/ai/claude/swift/TextMouth/`):
  - the review, `build/orchestrator/nov13/batchC-review.md`: findings 1 to 10, "Settled by reading", and "Not settled";
  - the worker's report, `build/orchestrator/nov13/batchC-report.md`;
  - the batch's brief, `Scripts/agents/briefs/2026-11-13/batch-common.md`, and its items 2, 3, 27, and 28 in section 1 of `build/orchestrator/nov13/triage-report.md`.
- Then `git diff main...HEAD` and the code around each finding.

## The work, one commit each, each with a test that fails without it

1. **Finding 1** (`DuplicateReplacement.swift:1163, 1179, 1236`): for a new copy with different bytes, carry the old copy's chosen encoding only when the copy is valid in that encoding and its own encoding was only guessed (not declared, not recognised by its structure, as well-formed ISO-2022-JP is); otherwise keep the import's reading, and Replace Existing goes ahead. Replace `testACopyNotValidInTheChoiceIsRefusedAndLeftAsImported`'s refusal with that rule, and add a structural case.
2. **Finding 2** (`DuplicateReplacement.swift:1094-1098, 228`): Replace Existing keeps a Braille Code the listener chose with the new pop-up, for the same bytes, in the same re-read as the file characters.
3. **Finding 3** (`LibrarySheetViews.swift:125`): each re-read pop-up's error line shows its own message only, and a new re-read of either clears the other's stale message.
4. **Finding 4, the tests the fixes lack:** two held-preparer tests (a data-directory move set, and a reader opened on the book, while the preparation waits), each showing the re-check refuses and puts everything back; a test that each sheet takes the answer off the main actor (switching back to the synchronous answer fails it); a re-read from one of this Mac's tables to a bundled one through `takingDecisions`.
5. **Findings 6, 7, and 10, small:** the busy sentence names the work actually under way (a replacement, a braille-code re-read), with the comment that claims braille books are re-read only for their file characters corrected (find every test pinning the old sentence first; change them with the wording, and say so); `Book.LibraryFields` carries `brailleTable` and its version, so an open reader follows a Braille Code re-read; the false test comment at `BrailleCodeBookInfoTests.swift:20`.

Leave findings 5, 8, and 9 and "Not settled" for the report, each with what a fix would take.

## Finish

Type-check the tests (`make typecheck-tests REF=<commit>`) before each train, end with one train naming the areas `library,reader-text,braille` and every class you touched, and report as `common.md` says, saved as `build/orchestrator/nov13/batchCfix-report.md`, with each finding: what you changed, its test, and whether breaking it fails the test.

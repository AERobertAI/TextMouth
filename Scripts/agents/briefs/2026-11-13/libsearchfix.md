# The fix round of `feature/library-search` (November 13, 2026)

You are `libsearchfix`, an Opus worker. You fix what the Opus review of Search Library asked for, on its branch, and add the background preparation the review recommends. First read `common.md` beside this brief and follow it, and `libsearch.md` beside it, the branch's own brief (its section "What the permission allows, exactly" binds you if you measure the user's library).

## The user's words

On November 13, 2026: "I want ful and effeicent and fast library text search to find strings in books (with options for case insynth and regex) the regex time I understand won't be super fast, but I do want the straight string ignore case or not to take 5 seconds or less on my whole library, you have my permission to test non changing code on my actual library when building."

## Start

- In your worktree: `git switch feature/library-search`, and check that `git log -1 --format=%h` prints `c025f2519`. Its lead stopped on an API error and its folder is gone; its branch holds its workers' work.
- Read, in the main checkout (`/Users/roberteggleston/programming/ai/claude/swift/TextMouth/`): the review, `build/orchestrator/nov13/libsearch-review.md` (findings 1 to 11, the suspicions, and "Question 6"); the report, `build/orchestrator/nov13/libsearch-report.md`; and the design on the branch, `LIBRARY-SEARCH-RESEARCH-2026-11-13.md`. Then `git diff main...HEAD` where each finding points.

## The work, one commit each, each with a test that fails without it

1. **Finding 1:** opening a regular-expression match checks the match at its place (an anchored match there, `[.anchored, .withTransparentBounds, .withoutAnchoringBounds]`) instead of running the expression from the chapter's start on the main actor; any longer search moves off the main actor and can be cancelled. Correct the two comments the review quotes.
2. **Finding 2 and the background preparation (the review's "Question 6" recommendation):** key the store on the build's identity, as `ReadingTextCache.currentProducer` does, so no parser change can serve stale text, and prepare the store at launch when idle so the first search meets the user's 5 seconds:
   - after startup maintenance ends, at background priority, with a smaller memory gate (8 to 16 MB, so the peak stays near 200 to 300 MB), books one at a time or a few at a time, never downloading a book;
   - skipped in Low Power Mode and while the data directory moves; paused, yielding at once, for a real search, which takes full priority (the window opening raises it);
   - on an unchanged library it costs a stat and a header read per book: measure that on a synthetic library of the user's size;
   - the status says when a search waits for preparation ("Preparing 120 of 737 books…"), spoken only when the search ends, as now.
   - Say in the design document what this costs after an install (about 51 seconds of processor time, 650 MB written) and that macOS may empty Caches.
3. **Finding 3:** a new query or Cancel stops the old search at once: check for cancellation after entering the gate and in `prepare`, let the gate's wait end on a cancel, and fix `testNewQueryCancelsTheOldSearchWhoseLateResultsNeverPublish` so it signals the gate before awaiting, and finishes in well under a second.
4. **Finding 4:** for a book with 501 to 1,000 matches, the row and the heading say true numbers ("Show the first 500 of 700 matches"); Show All keeps the book's own count and flag. Test that case.
5. **Finding 5:** the sweep (`removeFiles(notFor:)`) runs after each search that finishes (and after a background preparation), so removed books' and other data directories' texts and partial files leave Caches.
6. **Finding 6:** Search in Book's Match Case checkbox has a model test (it restarts the search with Match Case on) and an engine test with literal expected results.
7. **Finding 7 (a crash, so treat it as should-fix):** every length in a store file is checked against the file's size when it is opened, a bad file is discarded and remade, never trapped on; write with an fsync before the rename.
8. **Findings 8, 9, and 10:** the reader's search for a moved match honors cancellation; a refused open drops its jump request; storing keeps the app's free-space reserve (`ArchiveLimits`'s), and a store that can't be written leaves the search working from the parse, saying nothing new.
9. **Finding 11, if it stays small:** remove the leftover code the review names, with its tests.
10. **The review's suspicion about the announcement:** if "Moved to the match…" can be cut off by the window change, post it after the reader window is in front (the app's `afterSheetDelay` pattern, REV11 F6).

## Measuring

You may measure the user's library exactly as `libsearch.md`'s permission section says (read-only, through the lock, the store under `build/orchestrator/libsearchfix/`, counts and timings only), to report the first search's time with the background preparation done and not done, and the preparation's cost on an unchanged library.

## Finish

`make typecheck-tests REF=<commit>` before each train (always), one last train with the areas `reader-text,shortcuts,windows,library` and every class you touched, update the design document's sections the fixes change (the one Markdown file you edit), and report as `common.md` says, saved as `build/orchestrator/nov13/libsearchfix-report.md` (if writes outside your worktree are refused, your final message is the report), with each finding: what you changed, its test, and whether breaking it fails the test.

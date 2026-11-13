# The fix round of `feature/reading-list-remove-finished` (November 13, 2026)

You are `rlfix`, a Sonnet worker. You fix what the Opus review of the Reading List branch asked for, on that branch. First read `common.md` beside this brief and follow it.

## Start

- In your worktree: `git switch feature/reading-list-remove-finished`, and check that `git log -1 --format=%h` prints `33e959ef`. Its first worker has finished and its folder is gone.
- Read, in the main checkout (`/Users/roberteggleston/programming/ai/claude/swift/TextMouth/`):
  - the review, `build/orchestrator/nov13/rlfinished-review.md`: findings 1 to 9 and "Not settled";
  - the worker's report, `build/orchestrator/nov13/rlfinished-report.md`;
  - the two briefs it worked from, `Scripts/agents/briefs/2026-11-13/rlfinished.md` and `rlkeep.md` (the user's words are there).
- Then `git diff main...HEAD` for the whole branch, and the code around each finding.

## The work, one commit each, each with a test that fails without it

1. **Finding 1: a finished book stays the list's while its reader still rests on it.** Today the book leaves the list one main-queue turn after its end, and from then on its reader treats it as a book not opened from the list (Rewind after the end, Play at the end, and Next in Reading List all go wrong, against the user's October 7 rule that the list's continuation overrides the book's own). Take the review's first way: the finished book leaves the list when its reader moves on to another book or closes, not at its end; with the reader gone, or with no reader (finished elsewhere, such as a feed item marked played), it leaves at once. Pin each of the three cases the review names, and that the book does leave once the reader moves on and once it closes.
2. **Finding 2: the keep's first downloads.** Before the keep starts downloads for the list's books (the first refresh after the update, a checkbox turned on, books added), check free space with the existing `ArchiveLimits.volumeFreeSpace` and its reserve; start only what fits, and say once, at medium priority, how many books it is downloading and, if any didn't fit, that space ran short. An evicted book downloaded again still waits the five-minute retry after a failure. No real drive in the tests: use the cloud tests' stand-ins.
3. **Finding 3: the keep commands' words for books the list keeps.** Stop Keeping on a book only the list keeps says it's kept for the reading list and how to let it go; on a book kept for both reasons, it says the reading list still keeps it; Remove Download's advice never leads to a second refusal. Test the words themselves, not only the count of announcements.
4. **Finding 4: one announcement for Add to Reading List in a cloud library**: one sentence for both the addition and the downloads it starts, as Keep on This Mac does (`keepStarted`), or the download start at medium priority after it; say which, and pin the words and priority.
5. **Finding 5: the observers are tested where the app installs them.** A test that starts the library as the app does (`startLibrary()`) and then finishes a book and changes the list, so deleting either observer's line fails it.
6. **Minor findings 6 to 8:** checking "Keep these books on this Mac" says what it starts (as finding 2's sentence); the log line for an unreadable settings file says what really happens; `OnDiskContractTests` pins the reading list's new key and the new file's shape.
7. **Finding 9, the documentation:** correct the five false or incomplete sentences the review lists, and add `Keep Reading List Books.json` beside `Kept Books.json` in `docs/user/where-your-library-lives.md`, `docs/architecture/state/data-directory.md`, and `docs/architecture/state/logs.md`. This brief allows those Markdown edits.

Leave the review's "Not settled" items for the report, except the narrow options bar: if the bar can't fit its four controls at the window's minimum width, let it wrap onto a second line rather than truncate, and keep the controls' order for VoiceOver.

## Finish

Type-check the tests (`make typecheck-tests REF=<commit>`) before each train, end with one train naming the areas `reading-list,cloud,library` and every class you touched, and report as `common.md` says, saved as `build/orchestrator/nov13/rlfix-report.md`, with each finding: what you changed, its test, and whether breaking it fails the test.

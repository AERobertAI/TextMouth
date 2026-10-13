# Team rev16fix: REV16's four findings in T06's branches D and E

Team `rev16fix`; lead `rev16fix-lead`; team branch `team/rev16fix`; workers' branches `rev16fix/<task>`. Read `teams-common.md` beside this file first.

## What it is
REV16, an independent review on October 13, 2026, confirmed four problems in T06's branches D (112bb7b3) and E (cf542090): the code that moves the user's reading positions, bookmarks, and skipped headings when a book's text is rebuilt, loaded, or edited. Read the findings in full: `Scripts/agents/briefs/2026-10-12/rev16-review/findings.md`. Each finding gives its file and lines, the failure, and what should happen. The reviewer's tests that reproduced them are `probes.swift.txt` and `probes2.swift.txt` beside it, with their runs. Turn each reproduction into a test that pins the right answer, and see it fail before the fix.

The user must not install a build with branches D and E until these are fixed.

## The fixes
1. **F1, first and most carefully.** At load (`PlaceRelocator.headingResultAtLoad`, which asks `TextAnchorFinder.findHeading`), a skip whose heading does not stand names another heading only on proof: the skip's saved words after the heading agree at that heading's start.
   - Never on a label alone, and never on a score made only from the words before the heading.
   - Otherwise the skip waits, kept in `waitingSkippedHeadings`, as a rebuild makes it wait (branch D's rule, and REV15's rule for the rebuild path: "a guess never moves a skip onto a heading").
   - A skip that names its heading, whose saved words stand, is unchanged as before.
   - Every case in the findings must wait, and a heading that only moved (text added before it, its words after it unchanged) must still keep its skip; test both.
   - Check whether anything else in the app still calls `findHeading`'s weak paths for a skip. If nothing does, say so, and consider narrowing `findHeading` itself so no later caller can take them.
2. **C1.** The launch's recovery narrows its moves with `MovedPlaces.taken(by:)`, using the book `saveMovedPlaces` returns, before the library row takes them, as the batch's and Edit Text's paths do.
3. **C5.** A stop between the batch's record commit and the row's update must not lose the moves, and the row's stale places must never overwrite the record's moved ones. Decide how, and say why in your report: for example, the next launch's recovery of a lost summary also brings the record's places to the row where the row still holds the places the move started from. Correct `ContentAnalysisSummaryBuffer.swift`'s comment that a lost summary "is not lost work".
4. **S1.** The launch's sweep of leftover Edit Text copies keeps a book's copy while that book's content.md is only in the cloud, as the in-cloud check intends.

## How to split it
- **F1 is the core:** brief it with the reviewer's three cases and the "heading only moved" case spelled out. You may keep it for yourself if a worker should not take it, and say why.
- **C1 and S1 are small,** and may share a worker.
- **C5 needs a design decision first:** make it yours, then brief it.

## Not this team's
- **Nothing else is in flight.** Still check `bbs claims` before each launch.
- **Leave alone:** `.claude/skills/agent-bbs/` and `Scripts/agents/`.

## Your report
Use `teams-common.md`'s report, naming each finding closed (F1, C1, C5, S1) and the test that pins it.

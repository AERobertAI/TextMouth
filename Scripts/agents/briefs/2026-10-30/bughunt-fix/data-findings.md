# bughunt fix B: the data review's seven findings (October 31, 2026)

You are `bughunt-datafix` (Sonnet). Read `../teams-common.md` ("The worker's part", "Rules for everyone", "Builds") first; it stands in for AGENTS.md. Work on branch `bughunt/datafix`, made from `team/bughunt` (at 2fd75730) by name: `git checkout -b bughunt/datafix team/bughunt`.

An outside review of the bug hunt's fixes outside the parsers is at `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/oct30/review-bughunt-data.md`. Read it whole: each finding gives the files and lines, the scenario, the fix, and the test. Fix all seven, one commit each, each with the test the review names, which must fail without your fix. Read the code it names before changing it.

## Decisions, where the review leaves a choice
1. **Quit saves only readers whose place moved** since their last durable save: keep the last saved chapter and offset beside `lastPersistedCheckpoint`, and add `savePositionIfMoved()`, which `saveEveryOpenReaderPosition()` calls. A reader that played since its last checkpoint counts as moved. `testTheFlushSavesEveryOpenReadersPlaceFirst` must stay green.
2. **Adding back a book whose marker predates the fix:** in `reinstate`, when the book records no fingerprint and content.md's bytes differ from the text about to be written, keep content.md as a `content.md.edited-` copy (`BookTextEditSessions.keepCopy`), logged as TEXT_EDIT_KEPT, and say where it is.
3. **The launch's unanswered duplicate copy:**
   - It goes to the Trash whatever the Trash setting, since no one chose to delete it.
   - Once after the launch, TextMouth says which titles went there and why.
   - A copy whose marker is less than a day old is left alone, so another Mac's waiting question keeps its copy.
4. **A deleted episode:** use the review's smaller fix. When a read lists none of the record's items, every deleted record is kept. Leave the `lastListed` date, which changes the feed index's format, as a follow-up in your report. Correct the commit's and the changelog's promise to match.
5. **The DAISY archive sentence:**
   - `tookOnlyPartOfOriginal` is set only when the archive holds text the package leaves out (a DTBook, or the text documents the SMIL files point to).
   - The sentence names the book and the archive.
   - When the archive also holds other books' files outside the DAISY folder, it says how many were not imported and that unzipping the archive lets them be imported.
6. **The duplicate refusals:**
   - Check whether the data directory is unavailable first, and if so say the library can't be reached and to answer once it is back.
   - Name the book in each sentence.
   - When the marker won't come off, say TextMouth could not keep the copy and that Cancel discards it.
7. **A package chosen in Open Book…** for a book the library does not list takes the folder and the reading-list request, as a ZIP batch does. When several packages are chosen at once, only the first opens a reader.

Every new or changed sentence a listener hears is pinned by a test, and listed in your report exactly.

## Test
One run, through the build wrapper as `teams-common.md` says, of:
- the classes the review names: `UnsavedChangesTerminationTests`, `RetainedPackageImportTests`, `ImportDecisionFlowTests`, `FeedRefresherTests`, `DAISYPackageImportTests`, `TMBPackageImportTests`;
- `LogContentPolicyTests` if you add a log tag;
- the `import`, `feeds` and `library` areas.

Only one build runs on the whole Mac at a time, so wait your turn. `df -g /System/Volumes/Data` must show at least 4 GB free before you make a build folder. Delete the folder after the run (lsregister -u first, literal paths).

## Report (at most 25 lines)
Your branch, each commit with its finding, the exact `Executed` line, every new sentence a listener hears, and the follow-ups.

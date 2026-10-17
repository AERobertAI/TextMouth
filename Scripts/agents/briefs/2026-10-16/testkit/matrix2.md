# testkit/matrix2: the end-behavior matrix, part 2 (multi-file, chaptered, and DAISY columns)

Slug `testkit-matrix2`. Branch `testkit/matrix2`, made from `team/testkit` (it has part 1: `EndBehaviorMatrixTests.swift` and `EndBehaviorTestSupport.swift`). You build; at most two builders run at once. Read `teams-common.md`'s worker's part first, then `Scripts/agents/briefs/2026-10-16/testkit/matrix.md` for the why (team `feedopts` is adding per-folder and per-feed end-of-book options tonight, and this matrix is the safety net that proves the global default is unchanged).

## What part 1 left

Part 1 (`TextMouthProductionTests/EndBehaviorMatrixTests.swift`) holds the 100-cell inventory in its header comment and the tests for the **text** and **single-file audio** columns. Read the whole file first (440 lines): its grid types (`TimerCase`, `Cell`, `Outcome`, `Observed`), `Cell.outcome(title:next:)` (the outcome is the same for every kind of content), `cells(except:)`, `assertEnd(_:is:title:next:lastChapter:content:)`, `arm(_:in:)`, and its two tests are the pattern you follow. They are internal (not private) so that your tests can live in `extension EndBehaviorMatrixTests { ... }` blocks in files of your own.

Your three columns, their uncovered cells (behavior | timer), as the inventory in the header says:
- **multi-file audio** (a package of several tracks, like a ZIP of MP3s; 11 cells): stop | endOfHeading, minutes(running), minutes(expired); stopAndPlayStartsOver | endOfBook, endOfHeading, minutes(running), minutes(expired); loop | endOfHeading, minutes(running), minutes(expired); continueNext | minutes(expired). (The other 9 cells are covered by `FinishedBookReaderTests.testEveryAudiobookLayoutRestsExactlyAtItsEnd` (filePerChapter), `FinishedBookReaderTests.testWithStopAndPlayStartsOverPlayStartsAFinishedBookOver`, `ContinueToNextBookTests` and `IntegrationSleepTimerTests`: see the header.)
- **chaptered audio** (one m4b with chapter markers; 19 cells): every cell except stop | none.
- **DAISY** (segmented audio with clips; 19 cells): every cell except stop | none. (`loop | none` is only partly covered today: the first chapter plays again, no wording pinned: cover it fully.)

## What to do

Work in this order, one commit and one build-and-test round per column, smallest first:

1. **Multi-file audio.** New file `TextMouthProductionTests/EndBehaviorMatrixMultiFileTests.swift`: `extension EndBehaviorMatrixTests { func testMultiFileAudioEndBehaviorMatrix() throws { ... } }`, table-driven over `Self.multiFileAudioCells` (a `static let` in the extension's file: `cells(except: [the nine covered cells])`), following `testSingleFileAudioEndBehaviorMatrix`. Build the book with `IntegrationWorld.makeSilentAudioBook(title:trackDurations:endOfBook:)` (IntegrationTestSupport.swift:141; `IntegrationSleepTimerTests.testEndOfBookTimerPlaysAnAudiobookToItsEndAndStartsNothingAfter`, lines 341-390 there, uses it with `trackDurations: [0.5, 0.5]`), saved near its end like part 1 does, `lastChapter` the last track's index.
2. **Chaptered audio.** `EndBehaviorMatrixChapteredTests.swift`, `testChapteredAudioEndBehaviorMatrix`. Build with `makeChapteredAudioBook(title:in:duration:markers:savedPosition:endOfBook:)` (IntegrationTestSupport.swift:341; markers are `AudioTestFixtures.ChapterMarker`); `FinishedBookReaderTests.swift:15-80` shows how `makeAudioBook(.chapterMarks, ...)` builds one. Writing an m4b encodes AAC and takes a moment: build ONE m4b file per test run if you can and give each cell its own library row pointing at a copy, or accept the cost, but keep the whole test under 90 seconds.
3. **DAISY.** `EndBehaviorMatrixDAISYTests.swift`, `testDAISYEndBehaviorMatrix`. Build with `makeSegmentedAudioBook(title:files:sections:savedPosition:endOfBook:)` (IntegrationTestSupport.swift:178; `FinishedBookReaderTests`' `.clips` layout builds sections with several clips).

In each: the saved position is a moment before the book's end so the book plays out silently in real time; `reader.audioLayout` is asserted to be the layout under test (`.multiFile`, `.chaptersInOneFile`, `.segmented`) so a fixture that opens in the wrong layout fails loudly; sleep timers go through `arm(_:in:)`; the shared timer is protected with `preserveSharedSleepTimer()` and cancelled in a `defer`; every failure message names its cell via `Cell.name(of:)`.

After each column, update that column's lines in the header inventory of `EndBehaviorMatrixTests.swift` from `UNCOVERED` to `covered by EndBehaviorMatrixTests.<test name>` (a single-line edit per cell; do it with a small Python script and check the diff only touches those lines).

## If a cell's outcome is not what `Cell.outcome` says

Part 1 found the same outcome for text and single-file audio in every cell. If chaptered, multi-file, or DAISY books differ in a cell (the announcement, where the cursor rests, whether the next book is asked for), do NOT change the app and do NOT bend the shared `Cell.outcome`: give your column its own expected outcome for that cell (a small per-column override table with a comment saying why), post a finding (`bbs post testkit-matrix2 --tag finding --file TextMouth/ViewModels/ReaderViewModel.swift --topic "<column> <behavior> <timer>: <what differs>"`), and carry on. The finding matters: it is a place where per-folder options could change behavior unnoticed.

## Tests to run

Your new tests with `EndBehaviorMatrixTests` (one xcodebuild: `-only-testing:TextMouthProductionTests/EndBehaviorMatrixTests`, since your tests are in that class's extensions). The sleep-timer integration tests are load-sensitive: if one fails, rerun its class alone and report both results. At the end also run `IntegrationSleepTimerTests`, `ContinueToNextBookTests`, and `FinishedBookReaderTests` once.

## Do not

Change the app, an existing test, or the shared fixtures. Play sound. Leave a timer running. Add an unguarded subscript or a force unwrap. Use the per-folder or per-feed end-of-book options (feedopts' work).

## Commits

One per column (the test file and its header-inventory update), plus one for any per-column override table.

## Report (at most 15 lines)

Branch; commits; exact result lines; cells now covered per column and any still uncovered with the reason; findings posted; how long the new tests take.

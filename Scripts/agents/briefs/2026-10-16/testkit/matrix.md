# testkit/matrix: the end-behavior matrix, part 1 (inventory, text and single-file audio)

Slug `testkit-matrix`. Branch `testkit/matrix`, made from `team/testkit`. You build; at most two builders run at once. Read `teams-common.md`'s worker's part first.

## Why

The acceptance matrix's "End behavior" row (TODO-2026-09-04.md line 3640) says: "stop, loop, and continue-next for text, single-file audio, embedded audio chapters, multi-file ZIPs, and DAISY segments; combine with each sleep-timer mode." Nobody has checked that every cell has a test. Team `feedopts` is adding per-folder and per-feed end-of-book options tonight whose default must leave today's behavior unchanged: **the matrix is their safety net**, and it must exist as tests before their branch merges. This task is part 1: find which cells are covered, write a table-driven class for the uncovered cells of the text and single-file-audio columns, and report the rest so the lead can brief part 2 (m4b chapters, multi-file, DAISY).

Use the **global** end-of-book setting only (a book's own `localEndOfBookBehavior`, which the fixtures set, is the same code path; do not use the new per-folder or per-feed options). No test plays sound (fixtures write silence), none records, none touches `~/.TextMouth`.

## The grid

- Behavior (`EndOfBookBehavior`, TextMouth/ViewModels/SettingsViewModel.swift:18-32): `stop`, `stopAndPlayStartsOver`, `loop`, `continueNext`.
- Content: text; single-file audio; chaptered audio (one m4b with chapter markers); multi-file audio (a package of several tracks, like a ZIP of MP3s); DAISY (segmented audio with a manifest).
- Sleep timer (`SleepTimerDuration`, TextMouth/Models/DocumentContent.swift:323-): none; `.endOfBook`; `.endOfHeading` (set in the last heading, so the book's end ends it); `.minutes(n)` still running at the end; `.minutes(n)` already expired.
That is 4 x 5 x 5 = 100 cells. For each cell the question is: when the book's last audio or speech finishes, what is observable? (a) playing or not, (b) finished or not, and where the position rests, (c) which announcement is made (VoiceOver users hear it: exact wording is pinned), (d) whether the next book was asked for (autoplay request), (e) whether the timer is still active. The source of truth for the behavior is `ReaderViewModel.handleEndOfBook()` and `playFromTheEnd()` (grep for them in TextMouth/ViewModels/) and the existing tests; your tests pin what the code does TODAY. If a cell's current behavior looks wrong, do not change it: post a finding (`bbs post ... --tag finding --file <path>`) and pin the behavior with a comment saying it is under question.

## Step 1: the inventory (this is most of the work; do it first and carefully)

Find the existing test for every cell. Start from these (read their doc comments and bodies by line range, not whole files):
- `IntegrationSleepTimerTests.swift`: `:341` audio x endOfBook timer x {continueNext, stop}; `:391` text x endOfBook x {stop, loop, continueNext}; `:106-340` and `:442-840` end-of-heading cases.
- `ContinueToNextBookTests.swift`: `:263-470` continuing, `:479` `testWhereAFinishedBookRestsFollowsItsEndOfBookBehavior`, `:579-670` timers at the book's end.
- `FinishedBookReaderTests.swift`, `FinishedBookModelTests.swift`, `ReaderLifecycleAuditTests.swift`, `SpeakableChapterAdvanceTests.swift`, `MediaCommandPlaybackTests.swift`, `ReaderAutoplayRequestsTests.swift`, `AudioDirectoryImportTests.swift`, `SegmentedAudioBookFixture.swift`.
- `grep -n -E "EndOfBookBehavior|endOfBook|\.loop\b|\.continueNext|\.stopAndPlayStartsOver|handleEndOfBook|playFromTheEnd" TextMouthProductionTests/*.swift` finds the rest.
Write the result as a table in the header comment of your new file (`EndBehaviorMatrixTests.swift`): one line per cell, `behavior | content | timer | covered by FileName.testName` or `UNCOVERED` or `NOT APPLICABLE (reason)`. Be honest: a test covers a cell only if it checks the observable outcome of THAT combination, not merely runs near it.

## Step 2: the tests

In `TextMouthProductionTests/EndBehaviorMatrixTests.swift` (`final class EndBehaviorMatrixTests: XCTestCase`, `@MainActor` as the neighbours are) add table-driven tests for every UNCOVERED cell of the **text** and **single-file audio** columns: a table of cells (a small struct: behavior, timer, expected outcome), one loop per content type, each failure message naming its cell (`"text / loop / endOfBook: the book started again"`). Reuse the neighbours' helpers rather than copying them. The helpers you need exist:
- `IntegrationTestSupport.swift`: `makeIntegrationWorld(_:)` (:296), `IntegrationWorld.openReader(for:)` (:102), `makeSilentAudioBook(title:trackDurations:endOfBook:)` (:141, silent WAV tracks), `makeChapteredAudioBook` (:341, an m4b with markers), `makeSegmentedAudioBook` (:178, DAISY-like sections), `waitForReaderToLoad`, `preserveSharedSleepTimer()` (:407).
- `IntegrationSleepTimerTests.swift` has the private helpers `withSpeechReader` (:1081), `startSpeakingSilently` (:1151), `endSpeechSilently` (:1163), `recordContinueRequests` (:1043), `nextBookIsAskedFor` (:1036), `harbourChapter` (:1103); `AccessibilityTestSupport.swift:437` `recordingAnnouncements`. They are `private` in that class. If you need them, make ONE mechanical commit that moves them unchanged into a new support file `EndBehaviorTestSupport.swift` as an `extension XCTestCase` (`private` becomes internal, nothing else changes) and deletes the originals; `IntegrationSleepTimerTests` must pass unchanged afterwards. If you can avoid the move, do.
The shared sleep timer is global: always call `preserveSharedSleepTimer()` and cancel what you start. Waits are `eventually(within:)` with a generous timeout and a message; no unguarded subscripts; no force unwrap; no `Thread.sleep`.

## Step 3: report the rest

For the chaptered, multi-file, and DAISY columns, do not write tests. Instead your report lists every UNCOVERED cell of those columns, one per line as `behavior | content | timer`, so the lead can split them into briefs for part 2. Also post the table to the lead on the board when you finish Step 1 (`bbs post testkit-matrix --to testkit-lead --topic "inventory ready: N covered, M uncovered"`), before you write the tests, so part 2 can start in parallel.

## Tests to run

`EndBehaviorMatrixTests`, plus (if you moved helpers) `IntegrationSleepTimerTests`; plus `ContinueToNextBookTests` once at the end. The sleep-timer integration tests are load-sensitive: if one fails, rerun its class alone and report both results.

## Do not

Change any existing test's expectations, or the app. A failing existing test means stop and ask. Use the per-folder or per-feed end-of-book options. Play sound. Leave a timer running.

## Commits

1. (optional) the mechanical helper move.
2. `EndBehaviorMatrixTests` with the inventory comment and the tests for the uncovered text cells.
3. The uncovered single-file-audio cells.

## Report (at most 15 lines)

Branch; commits; exact result lines; counts: cells covered before, covered by your tests, not applicable, still uncovered (with the list for the other columns); any finding posted.

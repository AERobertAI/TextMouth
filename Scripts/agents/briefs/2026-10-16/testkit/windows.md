# testkit/windows: the multiple-windows matrix, part 1 (inventory and first tests)

Slug `testkit-windows`. Branch `testkit/windows`, made from `team/testkit`. You build; at most two builders run at once. Read `teams-common.md`'s worker's part first. Read `Scripts/agents/briefs/2026-10-16/testkit/matrix.md` as well: it is the same kind of task, done for the end-of-book behaviors, and `TextMouthProductionTests/EndBehaviorMatrixTests.swift` (on your branch) is the model of how to structure the result: an inventory in the header comment, a small grid of types, table-driven tests whose failures name their cell.

## Why

The acceptance matrix's "Multiple windows" row (TODO-2026-09-04.md line 3638): "keep Book A playing while editing/closing Book B; change folders/metadata; expire/cancel/restart a timer; close all Library windows and use Finder open." The user listens to one book while managing others, with several windows open and a screen reader on, and cannot see which window did what. A change to one book's window must not disturb the book playing in another. Only a person tries these by hand today; the model layer behind each operation can be driven by tests.

## The grid (you refine it from the code and the existing tests)

State of Book A, the book that is playing (rows): audio playing; speech playing (a text book); paused (audio); paused (speech); a sleep timer running on A (minutes, End of book).
Operation on Book B or on the library (columns), each through the same entry point the UI uses (the library model, the router, the reader's own methods; never a view):
1. open a reader for B (a second reader window) without playing it;
2. edit B's title and author;
3. move B to another folder;
4. rename or move B's folder;
5. remove B from the library; delete B's files;
6. close B's reader window;
7. start, cancel, and restart a sleep timer in B's reader (the timer is global with book ownership: say what happens to A's timer);
8. change a library sort or a folder's contents;
9. close every Library window while A's reader stays open, then open a book from Finder (the router: `LibraryWindowRouter`);
10. start playing B (what happens to A is a design decision: find it in the code and the existing tests (`NowPlayingOwnershipTests`, `MediaCommandPlaybackTests`) and pin it).
For each cell the observable outcome is: A's playing state; whether A's position advanced and was not reset; whether A's timer is still in effect and still A's; the announcement, if any, VoiceOver users hear; B's own state.

## Step 1: the inventory (most of the work; do it first and carefully)

Find which cells existing tests pin. Start from: `ReaderRefreshTests` (P10: readers refresh after shared edits and moves), `IntegrationWindowRoutingTests`, `LibraryWindowRouterTests`, `ViewsAndWindowsClosedWindowTests`, `WindowFocusPolicyTests`, `NowPlayingOwnershipTests`, `MediaCommandPlaybackTests`, `ReaderLifecycleAuditTests`, `IntegrationSleepTimerTests` (`:47 testExpiringTimerPausesItsOwnBookOnceWhileAnotherBooksWindowCloses`, `:898 testTheTimerBelongsToTheReaderThatSetItNotToItsBook`), `LibraryFeedMoveToFolderTests`, `FolderOperationOutcomeTests`, and `grep -n "func test" ` for the rest. A test covers a cell only if it checks that combination's outcome for A. Write the result as a table in the header comment of your new file `WindowsMatrixTests.swift` (`cell | covered by File.testName | UNCOVERED | NOT APPLICABLE (reason)`), and post a summary line to the lead on the board when it is ready: `bbs post testkit-windows --to testkit-lead --topic "inventory ready: N covered, M uncovered"`.

## Step 2: tests for the uncovered cells you can drive

Add `final class WindowsMatrixTests: XCTestCase` (`@MainActor`) with table-driven tests (loops over the cells; failure messages name the cell). Use the integration helpers the neighbours use: `IntegrationTestSupport.swift` (`makeIntegrationWorld`, `makeSilentAudioBook`, `openReader(for:)`, `waitForReaderToLoad`, `preserveSharedSleepTimer`), and the text-reader helpers in `EndBehaviorTestSupport.swift` (`withSpeechReader`, `startSpeakingSilentlyUntilItsEnd`). Play is always silent (silent WAV tracks; speech stopped before the run loop turns). Do not duplicate a covered cell. If you cannot drive a cell without a view, say so in the table (`UNCOVERED (needs a view)`), do not invent a way.

If a cell shows an outcome that looks wrong (A stops when B is renamed; A's timer is cancelled by B's close), do not change the app: pin what happens today with a comment saying it is under question, and post a finding (`bbs post testkit-windows --tag finding --file <app file> --topic "..."`).

## Tests to run

`WindowsMatrixTests` and, once at the end, `ReaderRefreshTests`, `LibraryWindowRouterTests`, `NowPlayingOwnershipTests`. The sleep-timer integration tests are load-sensitive: rerun a failing one alone and report both results.

## Do not

Change the app or an existing test (a failing existing test means stop and ask). Play sound. Leave a timer or a reader running (`reader.stop()` and `cancelSleepTimer()` in `defer`). Open a real window (no views). Let a test trap.

## Commits

1. The file with the inventory comment and the grid types.
2. The tests, in groups of related columns (each commit green).

## Report (at most 15 lines)

Branch; commits; exact result lines; counts: cells covered before, covered by your tests, uncovered with the reason; findings posted.

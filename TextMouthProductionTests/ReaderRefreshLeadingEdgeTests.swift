import Combine
import XCTest
@testable import TextMouth

/// The reader refreshes its display of the cursor on the leading edge (the
/// audit's C6, November 13, 2026): a change that comes a whole refresh
/// interval or more after the last refresh is shown on the main queue's next
/// turn, with no delayed work item, where it waited an interval for nothing;
/// a change inside the interval waits out what is left of it. Refreshes still
/// come at most once an interval, and never later than an interval after
/// their change. The time is the test's own, so ten seconds of an
/// audiobook's quarter-second cursor take a moment.
@MainActor
final class ReaderRefreshLeadingEdgeTests: XCTestCase {

    /// The time the reader counts its refresh intervals by, which a test
    /// moves by hand.
    private final class TestClock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    // MARK: - The Leading Edge

    /// An audiobook's cursor moves every quarter second for ten seconds: each
    /// of the 40 changes is shown by the next turn of the main queue, 40
    /// refreshes, and none waited on a delayed work item (40 did before).
    func testACursorMovingEveryQuarterSecondIsShownAtOnce() {
        let (reader, clock) = makeReader()
        defer { reader.close() }

        for step in 1...40 {
            clock.now.addTimeInterval(0.25)
            reader.currentCharacterOffset = step * 10
            // Far less than the 0.12 s interval the change used to wait.
            spinMainRunLoop(for: 0.01)
            XCTAssertEqual(reader.displayCharacterOffset, step * 10, "step \(step) was not shown at once")
        }

        XCTAssertEqual(reader.delayedPlaybackUIRefreshCount, 0)
    }

    /// A chapter index and an offset set together are shown together: the
    /// refresh comes on the next turn, after both are set, never between.
    func testAChapterAndOffsetSetTogetherAreShownTogether() {
        let (reader, clock) = makeReader()
        defer { reader.close() }
        var shown: [String] = []
        clock.now.addTimeInterval(1)

        reader.currentChapterIndex = 1
        reader.currentCharacterOffset = 40
        shown.append("\(reader.displayChapterIndex):\(reader.displayCharacterOffset)")
        spinMainRunLoop(for: 0.01)
        shown.append("\(reader.displayChapterIndex):\(reader.displayCharacterOffset)")

        XCTAssertEqual(shown, ["0:0", "1:40"], "the refresh did not wait for the end of the turn, or did not come")
    }

    // MARK: - Inside the Interval

    /// Changes inside the interval, as direct speech's words make them, wait
    /// out what is left of it, all in one refresh that shows the last.
    func testChangesInsideTheIntervalWaitOutTheRestOfIt() {
        let (reader, clock) = makeReader()
        defer { reader.close() }
        // The display mirrors are plain properties, which the refresh sets:
        // what the window shows at each step is read from them.

        clock.now.addTimeInterval(1)
        reader.currentCharacterOffset = 5
        spinMainRunLoop(for: 0.01)
        XCTAssertEqual(reader.displayCharacterOffset, 5, "the first change, a whole interval after the last, was not shown at once")

        // Two changes, 0.05 s after the refresh.
        clock.now.addTimeInterval(0.05)
        reader.currentCharacterOffset = 6
        reader.currentCharacterOffset = 7
        spinMainRunLoop(for: 0.01)
        XCTAssertEqual(reader.displayCharacterOffset, 5, "a change inside the interval was shown before the interval ended")
        XCTAssertEqual(reader.delayedPlaybackUIRefreshCount, 1)

        // The rest of the interval, 0.07 s, passes; the refresh shows the last.
        spinMainRunLoop(for: ReaderViewModel.playbackUIRefreshInterval + 0.1)
        XCTAssertEqual(reader.displayCharacterOffset, 7)
    }

    /// A clock set back, so that no interval seems to have passed, still
    /// refreshes within one interval.
    func testAClockSetBackStillRefreshesWithinOneInterval() {
        let (reader, clock) = makeReader()
        defer { reader.close() }
        clock.now.addTimeInterval(1)
        reader.currentCharacterOffset = 5
        spinMainRunLoop(for: 0.01)
        XCTAssertEqual(reader.displayCharacterOffset, 5)

        clock.now.addTimeInterval(-3600)
        reader.currentCharacterOffset = 9
        spinMainRunLoop(for: ReaderViewModel.playbackUIRefreshInterval + 0.15)

        XCTAssertEqual(reader.displayCharacterOffset, 9)
    }

    // MARK: - Fixtures

    /// A stopped reader of a one-chapter-pair book read from memory, as the
    /// heading tests make one, with the clock this test moves.
    private func makeReader() -> (ReaderViewModel, TestClock) {
        let book = Book(
            title: "Leading Edge",
            format: .txt,
            filePath: "/tmp/\(UUID().uuidString)-leading-edge.txt",
            md5Hash: UUID().uuidString
        )
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library(books: [book])
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: library,
            settingsViewModel: SettingsViewModel(initializeServices: false)
        )
        let clock = TestClock()
        reader.playbackUIRefreshNow = { clock.now }
        let chapters = (0..<2).map { index in
            Chapter(title: "Part \(index + 1)", text: String(repeating: "x", count: 1_000), headings: [])
        }
        reader.content = DocumentContent(title: book.title, author: book.author, chapters: chapters)
        reader.isLoading = false
        return (reader, clock)
    }
}

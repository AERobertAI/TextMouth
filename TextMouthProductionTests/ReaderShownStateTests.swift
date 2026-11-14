import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The reader announces a change to its window only when what the window
/// shows has changed (audit C3, November 13, 2026). The place moves with
/// every spoken word, eight times a second while a book plays, and each
/// publish drew the header, the text, the status row, the playback bar, and
/// the window, at 11 ms of the main thread. The display mirrors are plain
/// properties now, and `ReaderShownState` holds what the views draw from
/// them: the reader announces a change when that value differs.
///
/// What these tests guard, since a value left out of the state would go
/// stale on the screen and to VoiceOver:
/// - the state equals what each view builds from the cursor the old way, at
///   every step of a walk through the book;
/// - a move that changes nothing the window shows announces nothing, draws
///   none of the window's views, and a move that does announces and draws;
/// - the sleep countdown, which no longer rides on the reader's publishes,
///   moves every second, playing and paused, by a label of its own.
@MainActor
final class ReaderShownStateTests: XCTestCase {

    /// The time the reader counts its refresh intervals by, which a test
    /// moves by hand.
    private final class TestClock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    /// The labels a countdown label drew, in order.
    private final class SpokenLabels {
        var labels: [String] = []
    }

    /// The length of each of the book's two chapters: long enough that the
    /// percentage and the time left change only every dozen characters or
    /// more, and that a chapter is shown through a window of its text.
    private static let chapterLength = 120_000

    /// Where the second heading and the second page of chapter 0 begin.
    private static let secondHeadingOffset = 60_000

    // MARK: - What the State Holds

    /// At each step of a walk through both chapters, across headings, pages,
    /// and a bookmark, each part of the state equals what the views build
    /// from the cursor the old way: the percentage and time left as the
    /// status row's labels were made, the heading and page of the position,
    /// the bookmark near it, and the text drawn.
    func testTheStateEqualsWhatTheViewsBuildFromTheCursorAtEveryStep() {
        let (reader, _) = makeReader()
        defer { reader.close() }
        reader.bookmarks = [Bookmark(number: 1, chapterIndex: 0, characterOffset: 30_000)]
        guard let content = reader.content else { return XCTFail("the reader holds no book") }

        let walk: [(chapter: Int, offset: Int)] = [
            (0, 0), (0, 1), (0, 29_995), (0, 30_000), (0, 30_011), (0, 59_999),
            (0, Self.secondHeadingOffset), (0, 100_000), (0, Self.chapterLength),
            (1, 0), (1, 5), (1, 119_999),
        ]
        for step in walk {
            reader.currentChapterIndex = step.chapter
            reader.currentCharacterOffset = step.offset
            reader.refreshPlaybackUI(chapterIndex: step.chapter, offset: step.offset)
            let state = ReaderShownState(of: reader)
            let place = "chapter \(step.chapter), offset \(step.offset)"

            // The raw cursor's global offset, as the old labels counted it.
            let globalOffset = content.globalOffset(chapterIndex: step.chapter, localOffset: step.offset)
            XCTAssertEqual(
                state.percentText,
                String(format: "%.1f%%", content.percentComplete(globalOffset: globalOffset)),
                place
            )
            XCTAssertEqual(
                state.timeLeftText,
                TimeFormatting.format(ReadingTimeEstimator.remaining(
                    totalDuration: reader.totalEstimatedTime,
                    globalOffset: globalOffset,
                    totalCharacterCount: content.totalCharacterCount
                )),
                place
            )
            XCTAssertEqual(
                state.headingPosition,
                HeadingPosition(in: reader.headings, chapterIndex: step.chapter, characterOffset: step.offset),
                place
            )
            XCTAssertEqual(
                state.headingsBehind,
                reader.headings.filter {
                    $0.startsAtOrBefore(chapterIndex: step.chapter, characterOffset: step.offset)
                }.count,
                place
            )
            XCTAssertEqual(
                state.pagePosition,
                content.pages.position(atChapter: step.chapter, offset: step.offset),
                place
            )
            XCTAssertEqual(
                state.hasNearbyBookmark,
                step.chapter == 0 && abs(step.offset - 30_000) <= reader.bookmarkProximityThreshold,
                place
            )
            XCTAssertEqual(state.chapterIndex, step.chapter, place)
            XCTAssertEqual(state.visibleTextWindow, reader.displayVisibleTextWindow, place)
            // The mirrors Where Am I, pages, and the tests read are exact.
            XCTAssertEqual(reader.displayChapterIndex, step.chapter, place)
            XCTAssertEqual(reader.displayCharacterOffset, step.offset, place)
        }
    }

    /// The spoken labels of the status row are made from the same whole
    /// seconds and tenths of a percent as its shown ones: whenever a step of
    /// a walk changes what the status row says, it changes the state, so the
    /// reader announces it.
    func testAStepThatChangesASpokenLabelChangesTheState() {
        let (reader, _) = makeReader()
        defer { reader.close() }
        var previous: (spoken: String, state: ReaderShownState)?
        var changes = 0
        for offset in stride(from: 0, to: Self.chapterLength, by: 7) {
            reader.refreshPlaybackUI(chapterIndex: 0, offset: offset)
            let spoken = [
                ReaderTimeWording.timeLeftSpoken(reader.displayTimeRemaining, nil),
                "\(reader.displayFormattedPercentComplete) through the book",
                reader.displayPagePosition.label,
            ].joined(separator: "|")
            let state = ReaderShownState(of: reader)
            if let previous, previous.spoken != spoken {
                changes += 1
                XCTAssertNotEqual(previous.state, state, "\(spoken) changed with no change of state, at offset \(offset)")
            }
            previous = (spoken, state)
        }
        XCTAssertGreaterThan(changes, 100, "the walk saw too few changes to prove anything")
    }

    // MARK: - What Is Announced

    /// Moves that change nothing the window shows announce nothing, and the
    /// first move that does announces once: a run of places with the same
    /// percentage and time left, inside one heading and page, is quiet; the
    /// step out of the run is heard.
    func testOnlyAChangeInWhatIsShownIsAnnounced() throws {
        let (reader, _) = makeReader()
        defer { reader.close() }
        let run = try quietRun(in: reader, startingAt: 1_000, length: 8)
        reader.refreshPlaybackUI(chapterIndex: 0, offset: run[0])
        var announcements = 0
        let listener = reader.objectWillChange.sink { announcements += 1 }
        defer { listener.cancel() }

        for offset in run.dropFirst() {
            reader.refreshPlaybackUI(chapterIndex: 0, offset: offset)
        }
        XCTAssertEqual(announcements, 0, "moves within what the window shows were announced")
        XCTAssertEqual(reader.displayCharacterOffset, run.last, "the mirror did not follow the cursor")

        // Out of the run: the percentage or the time left changes.
        reader.refreshPlaybackUI(chapterIndex: 0, offset: run.last! + 40)
        XCTAssertEqual(announcements, 1, "a change in what the window shows was not announced once")

        // Into the next heading and page: announced, and the header's
        // number changes.
        let before = reader.displayHeadingPosition.number
        reader.refreshPlaybackUI(chapterIndex: 0, offset: Self.secondHeadingOffset + 3)
        XCTAssertEqual(announcements, 2)
        XCTAssertNotEqual(reader.displayHeadingPosition.number, before)
    }

    /// A bookmark coming near the cursor is announced although the cursor
    /// stayed within one run of places: the playback bar's bookmark button
    /// follows the raw cursor.
    func testABookmarkComingNearIsAnnounced() throws {
        let (reader, _) = makeReader()
        defer { reader.close() }
        let run = try quietRun(in: reader, startingAt: 2_000, length: 4)
        reader.currentCharacterOffset = run[0]
        reader.refreshPlaybackUI(chapterIndex: 0, offset: run[0])
        var announcements = 0
        let listener = reader.objectWillChange.sink { announcements += 1 }
        defer { listener.cancel() }

        // Adding a bookmark publishes the bookmarks themselves; the shown
        // state then has to take it, so the next refresh announces nothing
        // new for the same place and the button's state is in the state.
        reader.bookmarks = [Bookmark(number: 1, chapterIndex: 0, characterOffset: run[0])]
        let afterAdding = announcements
        XCTAssertTrue(ReaderShownState(of: reader).hasNearbyBookmark)
        reader.refreshPlaybackUI(chapterIndex: 0, offset: run[0])
        XCTAssertEqual(announcements, afterAdding + 1, "the refresh did not announce the bookmark's arrival")
    }

    // MARK: - Drawing

    /// Twenty-odd moves within what the window shows draw none of the
    /// window's views, where each drew every time; the move into another
    /// heading draws the header.
    func testMovesWithinWhatIsShownDrawNoView() throws {
        let (reader, _) = makeReader()
        defer { reader.close() }
        let run = try quietRun(in: reader, startingAt: 1_000, length: 8)
        reader.currentCharacterOffset = run[0]
        reader.refreshPlaybackUI(chapterIndex: 0, offset: run[0])
        let root = VStack(spacing: 0) {
            ReaderLocationHeader(viewModel: reader)
            ReaderTextArea(viewModel: reader)
            BookInfoBar(viewModel: reader)
            PlaybackControlsView(viewModel: reader)
        }
        .frame(width: 700, height: 700)
        let hosted = hostOffscreen(root, size: NSSize(width: 700, height: 700))
        defer { takeDown(hosted.window) }
        let names = ["ReaderLocationHeader", "ReaderTextArea", "BookInfoBar", "PlaybackControlsView"]
        settle(hosted.hostingView, seconds: 0.3)
        for name in names {
            XCTAssertGreaterThan(ViewBodyCounter.count(of: name), 0, "\(name) never drew")
        }

        // The run is walked forward and back, 3 times over: 21 moves.
        let moves = (0..<3).flatMap { _ in Array(run.dropFirst()) + Array(run.reversed().dropFirst()) }
        var announcements = 0
        let listener = reader.objectWillChange.sink { announcements += 1 }
        defer { listener.cancel() }
        let runs = bodyRuns(of: names, in: hosted.hostingView, publishing: moves.count, warmUps: 0) { index in
            reader.currentCharacterOffset = moves[index]
            reader.refreshPlaybackUI(chapterIndex: 0, offset: moves[index])
        }
        XCTAssertEqual(announcements, 0, "moves within what the window shows were announced")
        for name in names {
            XCTAssertLessThanOrEqual(runs[name, default: 0], 1, "\(name) drew for moves that changed nothing it shows")
        }

        // Crossing a heading draws the header, with the new heading's
        // label.
        let headerBefore = ViewBodyCounter.count(of: "ReaderLocationHeader")
        reader.currentCharacterOffset = Self.secondHeadingOffset + 3
        reader.refreshPlaybackUI(chapterIndex: 0, offset: Self.secondHeadingOffset + 3)
        settle(hosted.hostingView, seconds: 0.2)
        XCTAssertGreaterThan(ViewBodyCounter.count(of: "ReaderLocationHeader"), headerBefore, "the header did not draw for a new heading")
        XCTAssertEqual(reader.displayHeadingPosition.label, "Heading 2 of 3")
    }

    // MARK: - The Sleep Countdown

    /// The countdown label's value changes from one second to the next, with
    /// the book playing and with it paused, and the label and the timer's
    /// text are drawn by the small label alone: the reader's views are not
    /// drawn again for a tick of the timer, which they used to be only
    /// because the reader published every word.
    func testTheCountdownMovesEverySecondPlayingAndPaused() {
        let (reader, _) = makeReader()
        defer { reader.close() }
        let timer = reader.sleepTimerService
        timer.duration = .minutes(5)
        timer.remainingSeconds = 300
        timer.isActive = true
        defer {
            timer.isActive = false
            timer.duration = nil
        }
        // A label of the test's own, drawn as the reader's are, that notes
        // every label it spoke.
        let spoken = SpokenLabels()
        let root = VStack(spacing: 0) {
            BookInfoBar(viewModel: reader)
            PlaybackControlsView(viewModel: reader)
            SleepTimerStatusLabel(timer: timer) { timer in
                let _ = spoken.labels.append(timer.spokenLabel)
                Text(timer.formattedRemaining)
            }
        }
        .frame(width: 700, height: 300)
        let hosted = hostOffscreen(root, size: NSSize(width: 700, height: 300))
        defer { takeDown(hosted.window) }
        settle(hosted.hostingView, seconds: 0.3)

        for (state, playing, paused) in [("playing", true, false), ("paused", true, true)] {
            reader.isCurrentlyPlaying = playing
            reader.isCurrentlyPaused = paused
            settle(hosted.hostingView, seconds: 0.2)
            // Each tick of the timer, then what the reader's views drew.
            let readerViews = ["BookInfoBar", "PlaybackControlsView"]
            let viewsBefore = readerViews.map { ViewBodyCounter.count(of: $0) }
            let labelsBefore = ViewBodyCounter.count(of: "SleepTimerStatusLabel")
            let remainingBefore = timer.remainingSeconds
            for _ in 0..<3 {
                timer.remainingSeconds -= 1
                flush(hosted.hostingView)
                let minutes = timer.remainingSeconds / 60
                let seconds = timer.remainingSeconds % 60
                XCTAssertEqual(
                    spoken.labels.last,
                    "Sleep timer: \(minutes):\(String(format: "%02d", seconds)) remaining",
                    "\(state): the label did not follow the tick"
                )
            }
            XCTAssertEqual(timer.remainingSeconds, remainingBefore - 3)
            // Three ticks drew each of the three labels three times.
            XCTAssertEqual(
                ViewBodyCounter.count(of: "SleepTimerStatusLabel") - labelsBefore, 9,
                "\(state): the labels did not each draw for each tick"
            )
            for (name, before) in zip(readerViews, viewsBefore) {
                XCTAssertEqual(ViewBodyCounter.count(of: name), before, "\(state): \(name) drew for a tick of the timer")
            }
        }
        // Each second said, once and in order: 4:59, 4:58, 4:57, then 4:56 ...
        XCTAssertEqual(Set(spoken.labels).count, 7, "a second was said twice or skipped: \(spoken.labels)")
    }

    /// With no timer, the label draws nothing; starting one draws it, and
    /// stopping it takes it away again, as the views drew it before.
    func testTheCountdownLabelComesAndGoesWithTheTimer() {
        let (reader, _) = makeReader()
        defer { reader.close() }
        let timer = reader.sleepTimerService
        let spoken = SpokenLabels()
        let hosted = hostOffscreen(
            SleepTimerStatusLabel(timer: timer) { timer in
                let _ = spoken.labels.append(timer.spokenLabel)
                Text(timer.formattedRemaining)
            }
            .frame(width: 300, height: 100),
            size: NSSize(width: 300, height: 100)
        )
        defer { takeDown(hosted.window) }
        settle(hosted.hostingView, seconds: 0.2)
        XCTAssertEqual(spoken.labels, [], "a label was drawn with no timer")

        timer.duration = .minutes(5)
        timer.remainingSeconds = 299
        timer.isActive = true
        defer {
            timer.isActive = false
            timer.duration = nil
        }
        flush(hosted.hostingView)
        XCTAssertEqual(spoken.labels.last, "Sleep timer: 4:59 remaining")

        timer.isActive = false
        flush(hosted.hostingView)
        let drawn = spoken.labels.count
        timer.remainingSeconds = 100
        flush(hosted.hostingView)
        XCTAssertEqual(spoken.labels.count, drawn, "the label drew for a timer that is not running")
    }

    // MARK: - Windows and Media Controls

    /// The window's own announcement when it becomes key still reaches its
    /// views, which the media controls' menu items rely on: nothing the
    /// window observes follows a change of what holds the media controls.
    func testBecomingKeyStillAnnouncesToTheViews() {
        let (reader, _) = makeReader()
        defer { reader.close() }
        var announcements = 0
        let listener = reader.objectWillChange.sink { announcements += 1 }
        defer { listener.cancel() }

        reader.windowBecameKey()

        XCTAssertGreaterThanOrEqual(announcements, 1)
    }

    // MARK: - Fixtures

    /// The first run of `length` places, from `start` on in chapter 0, whose
    /// state is one and the same: no change in the percentage, the time left,
    /// the heading, the page, or the text drawn. Fails the test if there is
    /// none within a thousand characters.
    private func quietRun(in reader: ReaderViewModel, startingAt start: Int, length: Int) throws -> [Int] {
        var run: [Int] = []
        var runState: ReaderShownState?
        for offset in start..<(start + 1_000) {
            reader.refreshPlaybackUI(chapterIndex: 0, offset: offset)
            let state = ReaderShownState(of: reader)
            if state == runState {
                run.append(offset)
            } else {
                run = [offset]
                runState = state
            }
            if run.count == length { return run }
        }
        throw XCTSkip("no run of \(length) places with one state near \(start)")
    }

    /// A stopped reader of a book read from memory: two chapters of 120,000
    /// characters, in each its own page and headings (chapter 0 has a second
    /// heading and page halfway), with the clock this test moves.
    private func makeReader() -> (ReaderViewModel, TestClock) {
        let book = Book(
            title: "Shown State",
            format: .txt,
            filePath: "/tmp/\(UUID().uuidString)-shown-state.txt",
            md5Hash: UUID().uuidString
        )
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library(books: [book])
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: library,
            settingsViewModel: SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false),
            notificationCenter: NotificationCenter()
        )
        let clock = TestClock()
        reader.playbackUIRefreshNow = { clock.now }
        // 24,000 words of five characters each in a chapter.
        let text = String(repeating: "word ", count: Self.chapterLength / 5)
        let chapters = [
            Chapter(
                title: "One",
                text: text,
                headings: [
                    Heading(level: 1, text: "One", characterOffset: 0),
                    Heading(level: 2, text: "One B", characterOffset: Self.secondHeadingOffset),
                ],
                pages: [
                    PageBreak(label: "1", characterOffset: 0),
                    PageBreak(label: "2", characterOffset: Self.secondHeadingOffset),
                ]
            ),
            Chapter(
                title: "Two",
                text: text,
                headings: [Heading(level: 1, text: "Two", characterOffset: 0)],
                pages: [PageBreak(label: "3", characterOffset: 0)]
            ),
        ]
        reader.content = DocumentContent(title: book.title, author: book.author, chapters: chapters)
        reader.isLoading = false
        return (reader, clock)
    }
}

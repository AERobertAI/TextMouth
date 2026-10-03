import AppKit
import Combine
import SwiftUI
import XCTest
@testable import TextMouth

/// A reader publishes eight times a second while it plays, and each of its
/// sheets used to observe the whole reader, so every publish rebuilt them:
/// the headings sheet every row, the voice sheet its voice lists. The sheets
/// now follow snapshots of what they show and draw again only when that
/// changes; the headings sheet's rows are equatable, so the playback cursor
/// crossing into another heading redraws two rows (PERF30).
///
/// Sheets are presented as ReaderView presents them, by a parent that
/// observes the reader and makes the sheet again each time it draws, in
/// offscreen windows that never come forward.
@MainActor
final class ViewsAndWindowsReaderSheetTests: XCTestCase {

    // MARK: - The Snapshot

    /// A snapshot republishes only a change in what it reads, read once the
    /// change is stored, however often the reader publishes.
    func testSnapshotRepublishesOnlyAChangeInWhatItReads() {
        let reader = makeReader()
        defer { reader.close() }
        let snapshot = ReaderSnapshot(of: reader) { $0.bookmarks.count }
        var publishes = 0
        let counter = snapshot.objectWillChange.sink { publishes += 1 }
        defer { counter.cancel() }

        for _ in 0..<5 {
            reader.objectWillChange.send()
        }
        spinMainRunLoop(for: 0.1)
        XCTAssertEqual(publishes, 0, "A publish that changed nothing it reads was republished")
        XCTAssertEqual(snapshot.value, 0)

        reader.bookmarks.append(Bookmark(number: 1, chapterIndex: 0, characterOffset: 4))
        spinMainRunLoop(for: 0.1)
        XCTAssertEqual(publishes, 1)
        XCTAssertEqual(snapshot.value, 1, "The snapshot read the reader before its change was stored")
    }

    // MARK: - The Current Heading

    /// Under each level filter, the current heading is the last heading in
    /// reading order at or above that level that starts at or before the
    /// position, as the sheet decided it for one filter, also for headings
    /// out of order, sharing a place, or at levels outside 1 to 6.
    func testCurrentHeadingUnderEachFilterMatchesTheFilteredList() {
        var generator = SeededGenerator(state: 0x4EAD_1265)
        for round in 0..<200 {
            let headings = (0..<Int.random(in: 0...25, using: &generator)).map { number in
                Heading(
                    level: Int.random(in: 0...7, using: &generator),
                    text: "Heading \(number)",
                    chapterIndex: Int.random(in: 0...3, using: &generator),
                    characterOffset: Int.random(in: 0...100, using: &generator)
                )
            }
            let chapter = Int.random(in: 0...3, using: &generator)
            let offset = Int.random(in: 0...100, using: &generator)
            let currentByFilter = HeadingNavigatorView.currentHeadingIDs(
                in: headings,
                chapterIndex: chapter,
                characterOffset: offset
            )
            for maximumLevel in 1...HeadingNavigatorView.deepestFilterLevel {
                let expected = HeadingNavigatorView.filteredHeadings(headings, maximumLevel: maximumLevel)
                    .last { $0.startsAtOrBefore(chapterIndex: chapter, characterOffset: offset) }?
                    .id
                XCTAssertEqual(
                    HeadingNavigatorView.currentHeadingID(forMaximumLevel: maximumLevel, in: currentByFilter),
                    expected,
                    "round \(round), levels up to \(maximumLevel)"
                )
            }
        }
    }

    // MARK: - Drawing Again

    /// No sheet draws again for a publish of the reader that changes nothing
    /// it shows, as the playback cursor's publishes are within a heading.
    func testSheetsDoNotDrawAgainForPublishesThatChangeNothingTheyShow() throws {
        let reader = try makeLoadedReader()
        defer { reader.close() }
        let sheets: [(String, AnyView)] = [
            ("HeadingNavigatorView", AnyView(ReaderSheetHost(reader: reader) { HeadingNavigatorView(viewModel: $0) })),
            ("BookVoicePickerView", AnyView(ReaderSheetHost(reader: reader) { BookVoicePickerView(viewModel: $0) })),
            ("BookmarkPanelView", AnyView(ReaderSheetHost(reader: reader) { BookmarkPanelView(viewModel: $0) })),
            ("SleepTimerView", AnyView(ReaderSheetHost(reader: reader) {
                SleepTimerView(
                    viewModel: $0,
                    sleepTimerService: $0.sleepTimerService,
                    onStartPlayback: {},
                    onClose: {},
                    autoClose: false
                )
            })),
        ]
        for (name, sheet) in sheets {
            let hosted = hostOffscreen(sheet, size: NSSize(width: 600, height: 700))
            settle(hosted.hostingView, seconds: 0.4)
            XCTAssertGreaterThan(ViewBodyCounter.count(of: name), 0, "\(name) never drew")

            let runs = bodyRuns(of: [name, "HeadingNavigatorRow"], in: hosted.hostingView) { _ in
                reader.objectWillChange.send()
            }

            XCTAssertEqual(runs[name], 0, "\(name) drew again for publishes that changed nothing it shows")
            XCTAssertEqual(runs["HeadingNavigatorRow"], 0, "\(name): heading rows drew again")
            takeDown(hosted.window)
        }
    }

    /// The headings sheet draws again when the playback cursor crosses into
    /// another heading, and then redraws only the two rows whose speaker
    /// badge moves; moving within a heading redraws nothing.
    func testHeadingsSheetRedrawsTwoRowsWhenTheCursorCrossesAHeading() throws {
        let reader = try makeLoadedReader()
        defer { reader.close() }
        let sections = reader.headings.filter { $0.chapterIndex == 0 }
        XCTAssertGreaterThanOrEqual(sections.count, 2, "The fixture's first chapter has too few headings")
        guard sections.count >= 2 else { return }
        let hosted = hostOffscreen(
            ReaderSheetHost(reader: reader) { HeadingNavigatorView(viewModel: $0) },
            size: NSSize(width: 600, height: 700)
        )
        defer { takeDown(hosted.window) }
        // Moves the cursor as playback does, and waits until the reader
        // shows the move and the sheet has caught up with it.
        func moveCursor(to offset: Int) {
            reader.currentCharacterOffset = offset
            XCTAssertTrue(waitUntil(timeout: 5) { reader.displayCharacterOffset == offset }, "The cursor never moved")
            settle(hosted.hostingView, seconds: 0.2)
        }
        moveCursor(to: sections[0].characterOffset)
        // The first time the presenting parent draws again after the sheet
        // appears, SwiftUI draws the sheet once more, whatever changed; one
        // publish that changes nothing takes that draw out of the counts.
        reader.objectWillChange.send()
        settle(hosted.hostingView, seconds: 0.3)

        let watched = ["HeadingNavigatorView", "HeadingNavigatorRow"]
        let withinTheHeading = bodyRuns(of: watched, in: hosted.hostingView, publishing: 1, warmUps: 0) { _ in
            moveCursor(to: sections[0].characterOffset + 1)
        }
        XCTAssertEqual(withinTheHeading["HeadingNavigatorView"], 0, "Moving within a heading drew the sheet again")
        XCTAssertEqual(withinTheHeading["HeadingNavigatorRow"], 0, "Moving within a heading redrew rows")

        let intoTheNext = bodyRuns(of: watched, in: hosted.hostingView, publishing: 1, warmUps: 0) { _ in
            moveCursor(to: sections[1].characterOffset + 1)
        }
        XCTAssertGreaterThanOrEqual(intoTheNext["HeadingNavigatorView", default: 0], 1, "Crossing a heading did not draw the sheet")
        XCTAssertEqual(intoTheNext["HeadingNavigatorRow"], 2, "Crossing a heading redrew other than the two rows whose badge moved")
    }

    /// The voice sheet draws again when a setting it shows changes, so its
    /// labels and controls follow it.
    func testVoiceSheetDrawsAgainWhenItsSpeedChanges() throws {
        let reader = makeReader()
        defer { reader.close() }
        let hosted = hostOffscreen(
            ReaderSheetHost(reader: reader) { BookVoicePickerView(viewModel: $0) },
            size: NSSize(width: 600, height: 700)
        )
        defer { takeDown(hosted.window) }
        settle(hosted.hostingView, seconds: 0.4)

        let runs = bodyRuns(of: ["BookVoicePickerView"], in: hosted.hostingView, publishing: 1, warmUps: 0) { _ in
            reader.adjustSpeed(delta: 25)
            self.settle(hosted.hostingView, seconds: 0.2)
        }

        XCTAssertGreaterThanOrEqual(runs["BookVoicePickerView", default: 0], 1, "The sheet did not draw the new speed")
    }

    // MARK: - Readers

    /// A reader of a book whose file does not exist, so its load fails
    /// harmlessly and nothing plays, with an inert library and settings and
    /// a notification center of its own. Callers close it.
    private func makeReader() -> ReaderViewModel {
        let book = Book(
            title: "Sheet Snapshots",
            format: .txt,
            filePath: "/nonexistent/\(UUID().uuidString).txt",
            md5Hash: UUID().uuidString
        )
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])
        return ReaderViewModel(
            book: book,
            libraryViewModel: model,
            settingsViewModel: SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false),
            notificationCenter: NotificationCenter()
        )
    }

    /// A reader with a small Markdown book loaded: three chapters, each a
    /// level-1 heading and two level-2 ones. Callers close it.
    private func makeLoadedReader() throws -> ReaderViewModel {
        let book = try makeMarkdownBook(chapters: 3, charactersPerChapter: 3_000, sectionsPerChapter: 2)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: model,
            settingsViewModel: SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false),
            notificationCenter: NotificationCenter()
        )
        XCTAssertTrue(waitUntil(timeout: 30) { !reader.isLoading }, "The book never loaded")
        XCTAssertFalse(reader.headings.isEmpty, "The book has no headings")
        return reader
    }
}

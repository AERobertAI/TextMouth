import AppKit
import XCTest
@testable import TextMouth

/// Speak Info and Speak Full Info in a reader window (October 17, 2026):
/// Shift-Command-I speaks the reader's own book's brief information, and
/// Shift-Command-I twice its full information, in the words the Library
/// window speaks for that book's row, announced as the reader's other
/// spoken commands announce. Where Am I? keeps W. Nothing is spoken aloud:
/// announcements are captured (`AnnouncementCapture`).
@MainActor
final class ReaderSpeakInfoTests: XCTestCase {

    // MARK: - The Words

    /// The brief information is the Library's brief summary of the book's
    /// row, word for word: the title first, the format, and the progress as
    /// the row says it (the reader has opened the book, so it is not
    /// "Unopened").
    func testBriefInfoIsTheWordsTheLibrarySpeaksForTheBooksRow() throws {
        let fixture = try makeFixture("Reader Info Brief")

        let spoken = fixture.reader.speakInfo(.brief, now: Self.now)

        XCTAssertEqual(spoken, libraryWords(for: fixture.book, in: fixture.world, detail: .brief))
        XCTAssertTrue(spoken.hasPrefix("\(fixture.book.title). "), spoken)
        XCTAssertTrue(spoken.contains(fixture.book.format.displayName), spoken)
        XCTAssertTrue(spoken.contains("0 percent"), spoken)
        XCTAssertFalse(spoken.contains("Added"), "the brief summary says no more than the Library's does")
    }

    /// The full information is the Library's full summary of the book's
    /// row: the brief words, then when it was added, its bookmarks, its
    /// file size, and that a reader window has it open (this one).
    func testFullInfoIsTheWordsTheLibrarySpeaksForTheBooksFullSummary() throws {
        let fixture = try makeFixture("Reader Info Full")
        let brief = libraryWords(for: fixture.book, in: fixture.world, detail: .brief)

        let spoken = fixture.reader.speakInfo(.full, now: Self.now)

        XCTAssertEqual(spoken, libraryWords(for: fixture.book, in: fixture.world, detail: .full))
        XCTAssertTrue(spoken.hasPrefix(String(brief.dropLast())), "the full summary begins with the brief one: \(spoken)")
        XCTAssertTrue(spoken.contains("Added "), spoken)
        XCTAssertTrue(spoken.contains("File size "), spoken)
        XCTAssertTrue(spoken.contains(LibraryInfoWording.openInWindowNote), spoken)
    }

    /// The words go to VoiceOver as the reader's other spoken commands go,
    /// once each, and the reader remembers them as its last announcement.
    func testTheWordsAreAnnouncedOnce() throws {
        let fixture = try makeFixture("Reader Info Announced")
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        let spoken = fixture.reader.speakInfo(.brief, now: Self.now)

        XCTAssertEqual(announcements.messages, [spoken])
        XCTAssertEqual(fixture.reader.lastAnnouncement, spoken)
    }

    // MARK: - The Keys

    /// Pressed in a reader, Shift-Command-I speaks the brief information
    /// once; pressed twice within the double-press time, it speaks the brief
    /// information at once and then the full one, through the real shortcut
    /// manager, which posts the book's window with each. Where Am I? is not
    /// involved.
    func testShiftCommandIAndShiftCommandITwiceSpeakTheBriefThenTheFullInfoInTheReader() throws {
        let fixture = try makeFixture("Reader Info Keys")
        let manager = makeManager(on: fixture.world.notifications)
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        XCTAssertTrue(manager.handleKeyEvent(try shiftCommandI(at: 10), keyWindow: fixture.window, firstResponder: nil))
        XCTAssertEqual(announcements.messages, [libraryWords(for: fixture.book, in: fixture.world, detail: .brief)], "once is the brief information")

        XCTAssertTrue(manager.handleKeyEvent(try shiftCommandI(at: 10.2), keyWindow: fixture.window, firstResponder: nil))
        XCTAssertEqual(announcements.messages.count, 2, "twice speaks one more")
        // The full words say dates relative to the moment of the press, so
        // they are held to their beginning, which is the brief words, and to
        // what only the full summary says.
        let brief = libraryWords(for: fixture.book, in: fixture.world, detail: .brief)
        let full = try XCTUnwrap(announcements.messages.last)
        XCTAssertTrue(full.hasPrefix(String(brief.dropLast())), full)
        XCTAssertTrue(full.contains("Added "), full)
        XCTAssertTrue(full.contains(LibraryInfoWording.openInWindowNote), full)
    }

    /// A press in one reader reaches that reader alone: another reader,
    /// open on another book, says nothing, and a press in a window that is
    /// no reader's reaches neither.
    func testNothingReachesAnotherWindow() throws {
        let first = try makeFixture("Reader Info First")
        let second = try addReader(to: first.world, named: "Second Book")
        let stranger = makeShortcutWindow(.library)
        let manager = makeManager(on: first.world.notifications)

        XCTAssertTrue(manager.handleKeyEvent(try shiftCommandI(at: 10), keyWindow: first.window, firstResponder: nil))
        XCTAssertNotNil(first.reader.lastAnnouncement, "the reader pressed in was silent")
        XCTAssertNil(second.reader.lastAnnouncement, "the other reader spoke")

        first.reader.lastAnnouncement = nil
        XCTAssertTrue(manager.handleKeyEvent(try shiftCommandI(at: 20), keyWindow: second.window, firstResponder: nil))
        XCTAssertNil(first.reader.lastAnnouncement, "the first reader spoke for a press in the second")
        XCTAssertEqual(second.reader.lastAnnouncement, libraryWords(for: second.book, in: second.world, detail: .brief))

        // A Library window's press speaks in the Library, not in a reader.
        second.reader.lastAnnouncement = nil
        XCTAssertTrue(manager.handleKeyEvent(try shiftCommandI(at: 30), keyWindow: stranger, firstResponder: nil))
        XCTAssertNil(first.reader.lastAnnouncement)
        XCTAssertNil(second.reader.lastAnnouncement)
    }

    /// A command with no window, as a menu item posts, speaks only in the
    /// reader whose window is key; with no reader's window key, in none.
    func testAMenuCommandSpeaksInNoReaderWhoseWindowIsNotKey() throws {
        let fixture = try makeFixture("Reader Info Menu")

        fixture.world.notifications.post(name: .speakInfo, object: nil)
        fixture.world.notifications.post(name: .speakFullInfo, object: nil)

        XCTAssertNil(fixture.reader.lastAnnouncement)
    }

    // MARK: - Fixtures

    /// The moment the words are worded as of, fixed so that a date the
    /// summary says reads the same in the reader's words and the Library's.
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A reader open on a book of its own in a new world, with the window
    /// the reader belongs to, a stand-in for a reader's window.
    private struct Fixture {
        let world: IntegrationWorld
        let book: Book
        let reader: ReaderViewModel
        let window: NSWindow
    }

    /// A world with one Markdown book and a loaded reader on it, hosted in a
    /// reader-kind window.
    private func makeFixture(_ label: String) throws -> Fixture {
        let world = try makeIntegrationWorld(label)
        return try addReader(to: world, named: "Harbour Pilots")
    }

    /// Imports a book titled `name` into `world`, opens a loaded reader on
    /// it, and gives the reader a reader-kind window as its host.
    private func addReader(to world: IntegrationWorld, named name: String) throws -> Fixture {
        let source = try makeSandboxDirectory("Reader Info Source \(name)").appendingPathComponent("\(name).md")
        try Data("# \(name)\n\nOne two three four five.\n".utf8).write(to: source)
        let book = try world.importBook(from: source)
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        let window = makeShortcutWindow(.reader)
        reader.hostWindow = window
        return Fixture(world: world, book: book, reader: reader, window: window)
    }

    /// What a Library window speaks for `book`'s row (the `detail` summary),
    /// gathered and worded as `LibraryView.speakSelectedInfo` does.
    private func libraryWords(for book: Book, in world: IntegrationWorld, detail: SummaryDetail) -> String {
        let subject = LibraryInfoSubject(
            LibraryInfoRow.book(world.library.bookByID(book.id) ?? book),
            library: world.library,
            feedFolders: .shared,
            wordsPerMinute: world.settings.wordsPerMinute,
            cloudStates: .shared,
            keptBooks: .shared,
            measuresFileSize: detail == .full,
            now: Self.now
        )
        return LibraryInfoSpeaker.text(for: subject, detail: detail, now: Self.now)
    }

    /// A shortcut manager that posts on `center`, with no event monitor.
    private func makeManager(on center: NotificationCenter) -> KeyboardShortcutManager {
        KeyboardShortcutManager(
            userDefaults: makeSandboxedPreferences("reader-speak-info"),
            installsEventMonitor: false,
            notificationCenter: center,
            clock: { 10 },
            startTimer: { delay, fire in HandFiredTimer(delay: delay, fire: fire) }
        )
    }

    /// A press of Shift-Command-I at `time` on the events' time line.
    private func shiftCommandI(at time: TimeInterval) throws -> NSEvent {
        try ShortcutKeyPresses.keyPress(of: KeyBinding(key: "i", command: true, shift: true), at: time)
    }
}

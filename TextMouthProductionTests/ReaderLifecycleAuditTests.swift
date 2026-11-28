import Combine
import XCTest
@testable import TextMouth

/// Exercise reader-window transitions against their shared production services.
@MainActor
final class ReaderLifecycleAuditTests: XCTestCase {
    /// Closing an inactive window cannot truncate the active book's listening
    /// time. The owning reader can still finalize exactly the intended span.
    func testClosingInactiveReaderPreservesOtherBooksStatisticsSession() {
        let service = ReadingStatsService.shared
        let saved = service.stats
        service.endSession()
        service.stats = ReadingStats()
        defer {
            service.endSession()
            service.stats = saved
            service.save()
        }
        let activeBookID = UUID()
        let start = Date()
        let reader = makeReader()
        service.startSession(bookID: activeBookID, at: start)

        reader.close()

        XCTAssertTrue(service.hasActiveSession)
        service.endSession(bookID: activeBookID, at: start.addingTimeInterval(10))
        XCTAssertEqual(service.stats.bookListeningSeconds[activeBookID.uuidString], 10)
    }

    /// A window's timer is owner-scoped even during its fade phase: a reader
    /// that is not the timer's owner, such as the old reader of a window that
    /// switched books in place, cannot cancel the owner's fade.
    func testInactiveReaderCannotCancelAnotherBooksFade() {
        // Stops every window's timer when the test ends, and puts back the
        // duration last used, the one preference every window's timer shares.
        preserveSleepTimers()
        let reader = makeReader()
        // The reader's window's timer, owned by a reader that is not this one.
        let service = reader.sleepTimerService
        let owner = UUID()
        service.start(duration: .minutes(1), ownerID: owner, onExpire: {}, fadeOutDuration: 10)
        service._expireForTesting()
        XCTAssertTrue(service.isFadingOut)

        reader.pause()
        reader.close()

        XCTAssertTrue(service.isFadingOut)
        XCTAssertEqual(service.ownerID, owner)
    }

    /// Starting an unloaded reader must not claim playback or statistics.
    func testPlayWhileLoadingDoesNotStartAStatisticsSession() {
        let service = ReadingStatsService.shared
        service.endSession()
        let reader = makeReader()
        defer { reader.close() }

        reader.play()

        XCTAssertFalse(service.hasActiveSession)
        XCTAssertFalse(reader.isCurrentlyPlaying)
    }

    /// Restore corrupt lower bounds through the real asynchronous loader.
    /// Valid upper-bound behavior remains covered by navigation tests.
    func testNegativeSavedReadingPositionIsClampedWhenContentLoads() async throws {
        let packageName = "\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: "", tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        let source = package.appendingPathComponent("book.txt")
        try Data("Readable content.".utf8).write(to: source)
        let book = Book(
            title: "Restored Position", format: .txt, filePath: source.path,
            md5Hash: UUID().uuidString,
            readingPosition: ReadingPosition(chapterIndex: -1, characterOffset: -20),
            tmbDirectoryName: packageName
        )
        let reader = makeReader(book: book)
        defer { reader.close() }
        let loaded = expectation(description: "Content loaded")
        let subscription = reader.$isLoading.filter { !$0 }.prefix(1).sink { _ in loaded.fulfill() }
        defer { subscription.cancel() }

        await fulfillment(of: [loaded], timeout: 10)

        XCTAssertNil(reader.errorMessage)
        XCTAssertNotNil(reader.content)
        XCTAssertEqual(reader.currentChapterIndex, 0)
        XCTAssertEqual(reader.currentCharacterOffset, 0)
    }

    /// Audio completion must stop the reader's play/pause button state, which
    /// is independent of the speech service's observable state.
    func testAudioBookCompletionClearsPlayingState() {
        var book = Book(title: "Audio", format: .audio, filePath: "/tmp/missing-\(UUID()).wav", md5Hash: "audio")
        book.localEndOfBookBehavior = EndOfBookBehavior.stop.rawValue
        let reader = makeReader(book: book)
        let stats = reader.readingStatsService.stats
        defer {
            reader.close()
            reader.readingStatsService.stats = stats
            reader.readingStatsService.save()
        }
        reader.isCurrentlyPlaying = true

        reader.handleEndOfBook()

        XCTAssertFalse(reader.isCurrentlyPlaying)
        XCTAssertFalse(reader.isCurrentlyPaused)
    }

    /// Missing sources keep default fixtures inactive; the position test
    /// supplies a disposable managed package for the actual load path.
    private func makeReader(book: Book? = nil) -> ReaderViewModel {
        let book = book ?? Book(
            title: "Inactive Reader", format: .txt,
            filePath: "/tmp/missing-\(UUID()).txt", md5Hash: UUID().uuidString
        )
        let library = LibraryViewModel()
        library.library = Library(books: [book])
        return ReaderViewModel(
            book: book, libraryViewModel: library,
            settingsViewModel: SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        )
    }
}

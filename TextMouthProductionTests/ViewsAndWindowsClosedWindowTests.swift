import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// SwiftUI keeps a closed window, its views, and the reader it shows for the
/// rest of the session (an AppKit notification observer holds the window),
/// so closing has to make what stays behind cheap (PERF27): a closed reader
/// lets go of everything that grows with its book, and a closed Library
/// window stops rebuilding its list.
///
/// Readers are hosted as their windows host them, in offscreen windows that
/// never come forward, and held by the test after closing, as SwiftUI holds
/// them.
@MainActor
final class ViewsAndWindowsClosedWindowTests: XCTestCase {

    // MARK: - Closed Readers

    /// A closed reader keeps nothing of what it showed: no text or headings,
    /// no rendered speech, no offset maps or look-ahead, and no text window,
    /// though SwiftUI keeps it, as here, after its window closes.
    func testClosingAReaderLetsGoOfWhatItShowed() throws {
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        let book = try makeMarkdownBook(chapters: 8, charactersPerChapter: 30_000, sectionsPerChapter: 3)
        let reader = try openReader(of: book, settings: settings, renderedSeconds: 10, showingIt: true)

        reader.close()
        settle(nil, seconds: 0.5)

        assertKeepsNothingOfItsBook(reader)
    }

    /// What a closed reader keeps does not grow with its book: one closed on
    /// a two-million-character book with half a minute of rendered speech
    /// keeps within a megabyte of what one closed on a tiny book with a
    /// second of it keeps. Both made a speech engine, so the difference is
    /// only the book. No view shows them: what drawing leaves belongs to the
    /// view system, not the reader.
    func testAClosedReaderKeepsNothingThatGrowsWithItsBook() throws {
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        let tinyBook = try makeMarkdownBook(chapters: 1, charactersPerChapter: 400, sectionsPerChapter: 1)
        let bigBook = try makeMarkdownBook(chapters: 40, charactersPerChapter: 50_000, sectionsPerChapter: 4)
        // A first reader pays the one-time costs: frameworks, voices, and the
        // audio system's first engine.
        _ = try closedReaderGrowth(of: tinyBook, settings: settings, renderedSeconds: 1)

        let tinyGrowth = try closedReaderGrowth(of: tinyBook, settings: settings, renderedSeconds: 1)
        let bigGrowth = try closedReaderGrowth(of: bigBook, settings: settings, renderedSeconds: 30)

        let growthWithTheBook = bigGrowth - tinyGrowth
        XCTAssertLessThan(
            growthWithTheBook,
            1_048_576,
            "A closed reader of the big book keeps \(growthWithTheBook / 1_024) KB more than one of a tiny book"
        )
    }

    /// The malloc growth a closed reader of `book` leaves while it is held,
    /// as SwiftUI holds a closed window's reader, after `renderedSeconds` of
    /// rendered speech; it also checks that the reader kept nothing of the
    /// book.
    private func closedReaderGrowth(
        of book: Book,
        settings: SettingsViewModel,
        renderedSeconds: TimeInterval
    ) throws -> Int {
        settle(nil, seconds: 0.3)
        let before = mallocBytesInUse()
        let reader = try openReader(of: book, settings: settings, renderedSeconds: renderedSeconds, showingIt: false)
        reader.close()
        settle(nil, seconds: 1)
        assertKeepsNothingOfItsBook(reader)
        let growth = mallocBytesInUse() - before
        // Held to here, as SwiftUI holds a closed window's reader.
        withExtendedLifetime(reader) {}
        return growth
    }

    /// A reader of `book`, loaded, with `renderedSeconds` of rendered speech,
    /// which makes its speech engine. With `showingIt`, a ReaderView shows it
    /// until the reader closes, in a window taken down afterwards, as its
    /// window shows it. Its library and settings are the test's own.
    private func openReader(
        of book: Book,
        settings: SettingsViewModel,
        renderedSeconds: TimeInterval,
        showingIt: Bool
    ) throws -> ReaderViewModel {
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: model,
            settingsViewModel: settings,
            notificationCenter: NotificationCenter()
        )
        let hosted = showingIt ? hostOffscreen(
            ReaderView(viewModel: reader)
                .environmentObject(SoundEffectService())
                .environmentObject(settings)
        ) : nil
        if let hosted {
            addTeardownBlock { self.takeDown(hosted.window) }
        }
        XCTAssertTrue(waitUntil(timeout: 60) {
            hosted?.hostingView.layoutSubtreeIfNeeded()
            return !reader.isLoading
        }, "The book never loaded")
        XCTAssertNotNil(reader.content, "The book did not load")
        reader.speechService.audioEngine._installRenderedAudioForTesting(lasting: renderedSeconds)
        XCTAssertTrue(reader.holdsRenderedSpeech)
        if let hosted {
            settle(hosted.hostingView, seconds: 0.5)
            XCTAssertFalse(reader.displayVisibleTextWindow.isEmpty, "The reader showed no text")
        }
        return reader
    }

    /// Fails unless `reader`, closed, holds nothing of its book.
    private func assertKeepsNothingOfItsBook(_ reader: ReaderViewModel, line: UInt = #line) {
        XCTAssertNil(reader.content, "The closed reader kept the book's text", line: line)
        XCTAssertTrue(reader.headings.isEmpty, "The closed reader kept \(reader.headings.count) headings", line: line)
        XCTAssertFalse(reader.holdsRenderedSpeech, "The closed reader kept rendered speech", line: line)
        XCTAssertNil(reader.currentOffsetMap, line: line)
        XCTAssertNil(reader.currentTransformation, line: line)
        XCTAssertNil(reader.lookAhead, line: line)
        XCTAssertTrue(reader.displayVisibleTextWindow.isEmpty, "The closed reader kept its text window", line: line)
    }

    /// A closed audiobook reader keeps no player and no player item, which
    /// hold the audio file open and its buffers, and closing it makes no
    /// speech engine, which an audiobook never needs.
    func testClosingAnAudiobookReaderLetsGoOfItsPlayer() throws {
        let folder = try makeSandboxDirectory("closed-audiobook")
        let file = folder.appendingPathComponent("chapter.wav")
        try AudioTestFixtures.writeSilence(to: file, duration: 2)
        let book = Book(title: "Closed Audiobook", format: .audio, filePath: file.path, md5Hash: UUID().uuidString)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: model,
            settingsViewModel: SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false),
            notificationCenter: NotificationCenter()
        )
        XCTAssertTrue(waitUntil(timeout: 30) { !reader.isLoading }, "The audiobook never loaded")
        // Loaded but never played: nothing is heard.
        XCTAssertTrue(reader.audioPlaybackService.load(url: file))
        XCTAssertNotNil(reader.audioPlaybackService._playerItemForTesting)

        reader.close()

        XCTAssertNil(reader.audioPlaybackService._playerItemForTesting, "The closed reader kept its player item")
        XCTAssertFalse(reader.speechService.hasAudioEngine, "Closing a reader that never spoke made a speech engine")
        XCTAssertTrue(reader.audioChapterFiles.isEmpty)
        XCTAssertTrue(reader.audioSegments.isEmpty)
        XCTAssertNil(reader.content)
    }

    // MARK: - Closed Library Windows

    /// Once its window closes, a Library window stops rebuilding its list
    /// for each change to the library, and shows the list again as soon as
    /// SwiftUI brings the window back (here, as it becomes key).
    func testClosedLibraryWindowStopsRebuildingItsList() throws {
        let model = LibraryViewModel(initializeServices: false)
        model.library = ViewsAndWindowsFixtures.shapedLibrary(bookCount: 40, manualCount: 20)
        let changing = try XCTUnwrap(model.library.books.first?.id)
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        let hosted = hostOffscreen(
            LibraryView(
                currentFolderPath: .constant(""),
                category: .constant(.allItems),
                showFileImporter: .constant(false),
                showTextInput: .constant(false),
                onOpenBook: { _ in }
            )
            .environmentObject(model)
            .environmentObject(settings)
        )
        defer { takeDown(hosted.window) }
        settle(hosted.hostingView, seconds: 0.5)
        var offset = 1_000
        let changeOneBook: (Int) -> Void = { _ in
            offset += 1
            ViewsAndWindowsFixtures.move(changing, to: offset, in: model)
        }

        let whileOpen = bodyRuns(of: ["LibraryView.list"], in: hosted.hostingView, changeOneBook)
        XCTAssertGreaterThan(whileOpen["LibraryView.list", default: 0], 0, "The open window never rebuilt its list")

        hosted.window.close()
        settle(hosted.hostingView, seconds: 0.3)
        let whileClosed = bodyRuns(of: ["LibraryView.list"], in: hosted.hostingView, changeOneBook)
        XCTAssertEqual(whileClosed["LibraryView.list"], 0, "The closed window rebuilt its list")

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: hosted.window)
        settle(hosted.hostingView, seconds: 0.3)
        let afterReturning = bodyRuns(of: ["LibraryView.list"], in: hosted.hostingView, changeOneBook)
        XCTAssertGreaterThan(afterReturning["LibraryView.list", default: 0], 0, "The window brought back never showed its list")
    }
}

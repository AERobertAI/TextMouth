import Combine
import XCTest
@testable import TextMouth

/// A segmented audiobook written for one test, with the readers the test
/// opens on it.
///
/// The book is a package of silent tracks with a manifest of its sections,
/// indexed and saved as an import leaves it, in a library of its own, so a
/// reader opens it from its saved index. `withSegmentedAudioBook` makes it,
/// and closes every reader opened on it once the test's body returns.
@MainActor
final class SegmentedAudioBook {
    /// The book, as its readers open it.
    let book: Book
    /// The book's audio folder, holding its tracks and its manifest.
    let folder: URL
    /// The library the book is in, which its readers report to.
    private let library: LibraryViewModel
    /// The settings its readers follow, kept in a private preferences suite.
    private let settings: SettingsViewModel
    /// The test, which waits for each reader to load.
    private let test: XCTestCase
    /// Every reader opened on the book, closed when the test is done.
    private var readers: [ReaderViewModel] = []

    fileprivate init(
        book: Book,
        folder: URL,
        library: LibraryViewModel,
        settings: SettingsViewModel,
        test: XCTestCase
    ) {
        self.book = book
        self.folder = folder
        self.library = library
        self.settings = settings
        self.test = test
    }

    /// Open a reader on the book, as its window does, and wait until it has
    /// loaded. The book may be open in other readers too.
    func openReader(file: StaticString = #filePath, line: UInt = #line) -> ReaderViewModel {
        let reader = ReaderViewModel(book: book, libraryViewModel: library, settingsViewModel: settings)
        readers.append(reader)
        test.waitUntilReaderLoaded(reader)
        XCTAssertNil(reader.errorMessage, "The book did not load", file: file, line: line)
        return reader
    }

    /// Close every reader opened on the book.
    fileprivate func closeReaders() {
        readers.forEach { $0.close() }
    }
}

extension XCTestCase {
    /// Run `body` with a segmented audiobook made of `files`, each a silent
    /// track lasting the given number of seconds, played in `sections`.
    ///
    /// The book opens at `position` and does `endOfBook` when its last
    /// section ends. It is indexed and saved as an import leaves it before
    /// `damage` changes its files, so its readers open a saved index that
    /// still lists every clip. Settings live in a private preferences suite,
    /// and the shared listening statistics start empty with no open session
    /// and are put back afterwards, when the book's readers are also closed
    /// and its package removed.
    @MainActor
    func withSegmentedAudioBook(
        title: String,
        files: [String: TimeInterval],
        sections: [AudioSegment],
        at position: ReadingPosition,
        endOfBook: EndOfBookBehavior = .stop,
        damage: (URL) throws -> Void = { _ in },
        _ body: (SegmentedAudioBook) throws -> Void
    ) throws {
        let packageName = "\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: "", tmbName: packageName)
        defer { try? FileManager.default.removeItem(at: package) }
        let folder = package.appendingPathComponent("audio", isDirectory: true)
        for (file, duration) in files {
            try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent(file), duration: duration)
        }
        try JSONEncoder().encode(AudioManifest(title: title, segments: sections))
            .write(to: folder.appendingPathComponent("manifest.json"))
        var book = Book(
            title: title,
            format: .audio,
            filePath: folder.path,
            md5Hash: UUID().uuidString,
            readingPosition: position,
            tmbDirectoryName: packageName
        )
        book.localEndOfBookBehavior = endOfBook.rawValue
        let analysis = try BookContentAnalysisService.load(book: book)
        try book.saveBookInfoThrowing(contentIndex: analysis.index)
        try damage(folder)

        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: makeSandboxedPreferences("segmented-audio-book")
        )
        let library = LibraryViewModel()
        library.library = Library(books: [book])

        try withIsolatedListeningStatistics {
            let audiobook = SegmentedAudioBook(book: book, folder: folder, library: library, settings: settings, test: self)
            defer { audiobook.closeReaders() }
            try body(audiobook)
        }
    }

    /// Run `body` with the shared listening statistics empty and no
    /// listening session open, and put them back as they were afterwards,
    /// so readers that play in a test leave no listening time behind.
    @MainActor
    func withIsolatedListeningStatistics(_ body: () throws -> Void) rethrows {
        let statistics = ReadingStatsService.shared
        let savedStatistics = statistics.stats
        statistics.endSession()
        statistics.stats = ReadingStats()
        defer {
            statistics.endSession()
            statistics.stats = savedStatistics
            statistics.save()
        }
        try body()
    }

    /// Wait until `reader` has finished loading its book, successfully or
    /// not.
    @MainActor
    func waitUntilReaderLoaded(_ reader: ReaderViewModel) {
        let loaded = expectation(description: "Loading ended")
        let subscription = reader.$isLoading
            .filter { !$0 }
            .prefix(1)
            .sink { _ in loaded.fulfill() }
        wait(for: [loaded], timeout: 10)
        subscription.cancel()
    }

    /// Run the main run loop until `condition` holds or `timeout` passes,
    /// recording a sample of `reader`'s audiobook playback each time one
    /// changes.
    @MainActor
    func trackPlayback(
        of reader: ReaderViewModel,
        within timeout: TimeInterval,
        until condition: () -> Bool
    ) -> [ReaderPlaybackSample] {
        var samples: [ReaderPlaybackSample] = []
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let sample = ReaderPlaybackSample(
                chapter: reader.currentChapterIndex,
                offset: reader.currentCharacterOffset,
                file: reader.audioPlaybackService.loadedURL?.lastPathComponent
            )
            if samples.last != sample { samples.append(sample) }
            spinMainRunLoop(for: 0.01)
        } while !condition() && Date() < deadline
        return samples
    }
}

/// One moment of a reader's audiobook playback: its chapter and cursor,
/// and the file its audio service has loaded.
struct ReaderPlaybackSample: Equatable {
    /// The reader's chapter.
    let chapter: Int
    /// The reader's cursor in that chapter, in characters (ten a second).
    let offset: Int
    /// The name of the file the reader's audio service has loaded, if any.
    let file: String?
}

extension Array where Element: Equatable {
    /// The elements with each run of equal neighbors named once:
    /// [a, a, b, a] becomes [a, b, a].
    var runs: [Element] {
        reduce(into: []) { runs, element in
            if runs.last != element { runs.append(element) }
        }
    }
}

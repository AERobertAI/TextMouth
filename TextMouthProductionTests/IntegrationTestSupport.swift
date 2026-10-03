import XCTest
@testable import TextMouth

// Shared fixtures for the integration tests (TODO Q04). Each of those tests
// enters a repaired workflow at its real boundary (a menu command's import,
// a library save, a notification the router hears, a running sleep timer,
// a reader's chapter end, a reader's load) and checks what the user would
// notice, rather than calling the helper the repair introduced.

// MARK: - A Library Folder of the Test's Own

/// A folder of one test's own inside the hosted tests' isolated library.
///
/// Work done in it leaves its traces where nothing else writes, so the
/// folder's complete listing, hidden names included, shows exactly what the
/// work left behind: a published package, or the hidden package an import
/// stages before publishing.
struct IntegrationLibraryFolder {
    /// The folder's path inside the library, as books and folders name it.
    let path: String

    /// The folder on disk.
    var url: URL {
        TextMouthPaths.libraryDir.appendingPathComponent(path, isDirectory: true)
    }

    /// Every name in the folder, hidden ones included, or none when the
    /// folder does not exist.
    func entries() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: url.path))
    }

    /// Removes the folder and everything in it. Queued package writes are
    /// made first, so none can land in a package after it is gone, and write
    /// permission is given back to every directory first, since a test may
    /// have made one read-only.
    func remove() {
        LibraryPersistenceService.flushPendingSave()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if let enumerator = FileManager.default.enumerator(atPath: url.path) {
            for case let relative as String in enumerator {
                chmod(url.appendingPathComponent(relative).path, 0o755)
            }
        }
        chmod(url.path, 0o755)
        try? FileManager.default.removeItem(at: url)
    }
}

extension XCTestCase {
    /// A new library folder of this test's own, named after `label`, that is
    /// removed with everything in it when the test ends. The folder is not
    /// created here: the work under test creates it as it would any folder.
    func makeIntegrationLibraryFolder(_ label: String) -> IntegrationLibraryFolder {
        let folder = IntegrationLibraryFolder(path: "\(label) \(UUID().uuidString.prefix(8))")
        addTeardownBlock { folder.remove() }
        return folder
    }
}

// MARK: - A World of Readers

/// The private surroundings of an integration test that opens real readers
/// on books in real packages.
///
/// Everything a reader reaches beyond its book is the test's own: an inert
/// library model (it starts no disk maintenance, observers, or background
/// analysis), settings in a sandboxed preferences store mirrored to a config
/// file of the test's own, an empty set of substitution rules, a private
/// notification center, so the running app's windows never hear what the
/// readers post, and a private autoplay request store. Packages live in a
/// library folder of the test's own. The shared library index and listening
/// statistics, which readers write as they save positions and sessions,
/// are put back when the test ends, after every reader is closed.
@MainActor
final class IntegrationWorld {
    /// The library folder holding the world's packages.
    let folder: IntegrationLibraryFolder
    /// The library model the readers save through.
    let library: LibraryViewModel
    /// The settings the readers follow.
    let settings: SettingsViewModel
    /// Where the readers post and listen.
    let notifications: NotificationCenter
    /// The requests a finished book leaves for the next book's reader.
    let autoplayRequests: ReaderAutoplayRequests
    /// Every reader opened in this world, closed when the test ends.
    private(set) var readers: [ReaderViewModel] = []

    fileprivate init(folder: IntegrationLibraryFolder, settings: SettingsViewModel, notifications: NotificationCenter) {
        self.folder = folder
        self.settings = settings
        self.notifications = notifications
        autoplayRequests = ReaderAutoplayRequests()
        library = LibraryViewModel(initializeServices: false)
        library.library = Library()
    }

    /// Opens a reader for `book`, which starts loading its content at once,
    /// as a reader window's model does.
    ///
    /// - Parameter renderScheduler: Renders the reader's look-ahead; nil uses
    ///   the app's shared render queue.
    func openReader(
        for book: Book,
        renderScheduler: (any SpeechRenderScheduling)? = nil
    ) -> ReaderViewModel {
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: library,
            settingsViewModel: settings,
            substitutionService: TextSubstitutionService(rules: []),
            autoplayRequests: autoplayRequests,
            notificationCenter: notifications,
            renderScheduler: renderScheduler
        )
        readers.append(reader)
        return reader
    }

    /// An audio book of silent WAV tracks, one per entry of `trackDurations`
    /// (seconds), in a package of its own in the world's folder, indexed as
    /// an import indexes it and listed in the library. A reader playing it
    /// is never heard.
    ///
    /// - Parameters:
    ///   - title: The book's title, which also orders it in its folder.
    ///   - savedPosition: Where the book was last read, if anywhere.
    ///   - endOfBook: The book's own end-of-book behavior.
    func makeSilentAudioBook(
        title: String,
        trackDurations: [TimeInterval],
        savedPosition: ReadingPosition? = nil,
        endOfBook: EndOfBookBehavior = .stop
    ) throws -> Book {
        let packageName = "\(UUID().uuidString).tmb"
        let tracks = TextMouthPaths.tmbPath(folderPath: folder.path, tmbName: packageName)
            .appendingPathComponent("Tracks", isDirectory: true)
        for (number, duration) in trackDurations.enumerated() {
            let name = String(format: "%02d.wav", number + 1)
            try AudioTestFixtures.writeSilence(to: tracks.appendingPathComponent(name), duration: duration)
        }
        let book = Book(
            title: title,
            format: .audio,
            filePath: tracks.path,
            md5Hash: UUID().uuidString,
            folderPath: folder.path,
            readingPosition: savedPosition,
            tmbDirectoryName: packageName,
            localEndOfBookBehavior: endOfBook.rawValue
        )
        let analysis = try BookContentAnalysisService.load(book: book)
        try book.saveBookInfoThrowing(contentIndex: analysis.index)
        library.library.addBook(book)
        return book
    }

    /// Imports `source` into the world's folder as the library imports a
    /// chosen file, and lists the book.
    func importBook(from source: URL) throws -> Book {
        let book = try FileImportService.importFileWithReport(from: source, toFolder: folder.path).book
        library.library.addBook(book)
        return book
    }

    /// Closes every reader opened in the world.
    fileprivate func closeReaders() {
        for reader in readers {
            reader.close()
        }
    }
}

extension XCTestCase {
    /// A new world of readers for this test, named after `label`, taken
    /// apart when the test ends: every reader is closed, the shared
    /// listening statistics and library index are put back, and the
    /// world's folder, config file, and preferences are removed.
    @MainActor
    func makeIntegrationWorld(_ label: String) throws -> IntegrationWorld {
        // Tear-down blocks run last registered first, so these are
        // registered in the reverse of the order they must run in.
        let folder = makeIntegrationLibraryFolder(label)
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }

        let statistics = ReadingStatsService.shared
        let savedStatistics = statistics.stats
        statistics.endSession()
        statistics.stats = ReadingStats()
        addTeardownBlock {
            statistics.endSession()
            statistics.stats = savedStatistics
            statistics.save()
        }

        let notifications = NotificationCenter()
        let configFile = try makeSandboxDirectory("\(label) Config").appendingPathComponent("config.json")
        let settings = SettingsViewModel(
            notificationCenter: notifications,
            initializeServices: false,
            userDefaults: makeSandboxedPreferences(label),
            configService: ConfigService(fileURL: configFile)
        )
        let world = IntegrationWorld(folder: folder, settings: settings, notifications: notifications)
        addTeardownBlock { world.closeReaders() }
        return world
    }

    /// Waits until `reader` has finished loading its book, successfully or
    /// not, including what it does as loading ends, and fails the test when
    /// it never does.
    @MainActor
    func waitForReaderToLoad(
        _ reader: ReaderViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            waitUntil(timeout: 10) { !reader.isLoading },
            "\(reader.book.title) never finished loading",
            file: file,
            line: line
        )
    }
}

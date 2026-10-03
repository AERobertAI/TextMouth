import XCTest
@testable import TextMouth

// MARK: - A Scripted Cloud

/// A cloud library scripted by a test (FR02): the items it pretends are
/// dataless, and the items whose reads it refuses with `EDEADLK`, as the
/// system refuses the read of a dataless file while downloads are off.
///
/// Real dataless files cannot be made in a hosted test, since only a sync
/// service makes them, so the maintenance passes take this cloud's
/// `access` in place of the live one. Items are matched by path, with
/// `/private/var` and `/var` taken as one folder, as the system has them.
final class FakeCloudFiles: @unchecked Sendable {
    /// Guards every stored property: the passes ask from background threads.
    private let lock = NSLock()
    /// The paths of the items pretended dataless.
    private var datalessPaths: Set<String> = []
    /// The paths whose reads are refused.
    private var refusedPaths: Set<String> = []
    /// The paths of the reads refused so far, in order.
    private var refusals: [String] = []

    /// Pretends the items at `urls` are dataless.
    func markDataless(_ urls: URL...) {
        lock.withLock { datalessPaths.formUnion(urls.map(Self.key)) }
    }

    /// Refuses every read of the items at `urls`.
    func refuseReads(of urls: URL...) {
        lock.withLock { refusedPaths.formUnion(urls.map(Self.key)) }
    }

    /// The paths whose reads were refused so far, in order.
    var refusedReads: [String] {
        lock.withLock { refusals }
    }

    /// The access the maintenance passes take: this cloud's answers.
    var access: MaintenanceFileAccess {
        MaintenanceFileAccess(
            isDataless: { [self] url in
                lock.withLock { datalessPaths.contains(Self.key(url)) }
            },
            refusesRead: { [self] url in
                lock.withLock {
                    let key = Self.key(url)
                    guard refusedPaths.contains(key) else { return false }
                    refusals.append(key)
                    return true
                }
            }
        )
    }

    /// The path an item is matched by: standardized, with a leading
    /// `/private` removed, since `/var` and `/tmp` lead there.
    static func key(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }
}

// MARK: - Fixtures

/// The test cases of the FR02 maintenance work: each test's books are
/// packages in a library folder of its own in the hosted test root, which is
/// removed when the test ends, and the library index is put back as it was.
class CloudMaintenanceTestCase: XCTestCase {
    /// The library folder this test's packages are in.
    private(set) var folderPath = ""
    /// The cloud this test scripts.
    private(set) var cloud = FakeCloudFiles()
    /// The library index as it was before the test, put back afterwards.
    private var indexSandbox: LibraryIndexSandbox?

    override func setUpWithError() throws {
        try super.setUpWithError()
        indexSandbox = try LibraryIndexSandbox.capture()
        cloud = FakeCloudFiles()
        folderPath = "Cloud Maintenance \(UUID().uuidString.prefix(8))"
        try TextMouthPaths.ensureLibrarySubfolder(folderPath)
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed partway.
        indexSandbox?.restore()
        if !folderPath.isEmpty {
            try? FileManager.default.removeItem(at: folderURL)
        }
        try super.tearDownWithError()
    }

    /// This test's library folder on disk.
    var folderURL: URL {
        TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
    }

    /// A Markdown book in a package of its own in this test's folder,
    /// holding only its source, `source.md`, and recorded with a text cache
    /// format older than the current one, as a library is after a cache
    /// format change.
    func makePackagedBook(
        title: String = "Field Notes",
        text: String = "# Opening\n\nSome words.",
        cacheFormatVersion: String? = "3.0.3"
    ) throws -> Book {
        let packageName = "\(title)-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let source = package.appendingPathComponent("source.md")
        try text.write(to: source, atomically: true, encoding: .utf8)
        return Book(
            title: title,
            format: .markdown,
            filePath: source.path,
            md5Hash: UUID().uuidString,
            folderPath: folderPath,
            tmbDirectoryName: packageName,
            cacheFormatVersion: cacheFormatVersion
        )
    }

    /// Writes `book`'s text cache, index, and fingerprints as the cache
    /// batch does, and returns the book as its package now records it:
    /// current, fingerprinted, and analyzed.
    func commitCache(of book: Book) throws -> Book {
        var cached = book
        let index = try XCTUnwrap(MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &cached))
        return try XCTUnwrap(LibraryPersistenceService.saveContentAnalysis(
            for: cached,
            index: index,
            cacheFormatVersion: cached.cacheFormatVersion
        ))
    }

    /// A library model listing `books`, without the app's services.
    @MainActor
    func makeModel(with books: [Book]) -> LibraryViewModel {
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: books)
        return model
    }

    /// The bytes of the file at `url`, or nil when there is none.
    func contents(of url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    /// The `MAINTENANCE_SKIPPED_IN_CLOUD` line `pass` writes when it skipped
    /// `count` books, up to the words after the count, so a search finds
    /// exactly that count.
    func skipLine(_ pass: MaintenancePass, count: Int) -> String {
        let books = count == 1 ? "book whose" : "books whose"
        return "MAINTENANCE_SKIPPED_IN_CLOUD: \(pass.rawValue): skipped \(count) \(books) "
    }

    /// How many lines of the debug log hold `text`, read after every queued
    /// log write.
    func logLineCount(_ text: String) -> Int {
        debugLogLines(containing: text).count
    }
}

/// The IDs of the books a cache generation was told about
/// (`MarkdownCacheService.extractionObserver`), recorded from whichever
/// thread generates.
final class BookIDRecorder: @unchecked Sendable {
    /// Guards `ids`.
    private let lock = NSLock()
    /// The IDs recorded so far.
    private var ids: Set<UUID> = []

    /// Records `id`.
    func record(_ id: UUID) {
        lock.withLock { _ = ids.insert(id) }
    }

    /// Whether `id` was recorded.
    func contains(_ id: UUID) -> Bool {
        lock.withLock { ids.contains(id) }
    }
}

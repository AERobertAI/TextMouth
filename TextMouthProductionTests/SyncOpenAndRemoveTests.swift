import XCTest
@testable import TextMouth

/// What a sync does with a book another device has, and a book another
/// device removed, where the library's own parts meet it (FR43): opening a
/// placeholder in a local library, a feed item the sync removes, and the
/// books a removal leaves because they are busy. Each test names the
/// behavior it pins, and fails when that behavior is taken out.
@MainActor
final class SyncOpenAndRemoveTests: XCTestCase {
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox!
    /// Packages and folders a test made in the hosted library, removed after it.
    private var made: [URL] = []

    override func setUp() async throws {
        sandbox = try LibraryIndexSandbox.capture()
    }

    override func tearDown() async throws {
        sandbox?.restore()
        for url in made { try? FileManager.default.removeItem(at: url) }
        made = []
    }

    // MARK: - Fixtures

    /// A placeholder package in the hosted library for a book another device has.
    private func makePlaceholder(_ title: String) throws -> Book {
        let book = Book(id: UUID(), title: title, author: "Test Fixture", format: .txt, filePath: "", md5Hash: "", folderPath: "")
        let content = SyncContent(
            manifest: "m.manifest.json", format: .txt, dateAdded: Date(timeIntervalSince1970: 1_790_000_000),
            md5Hash: "open-\(UUID().uuidString)", totalWordCount: nil, audioDuration: nil
        )
        let made = try SyncPlaceholder.makePackage(for: SyncNewBook(book: book, content: content), storeID: UUID())
        self.made.append(made.tmbDirectory)
        return made
    }

    /// An application that removes `ids` and gives `keys` as applied.
    private func removal(of ids: [UUID], keys: Set<SyncKey>) -> SyncApplication {
        SyncApplication(
            library: Library(), booksToAdd: [], booksToRemove: ids, movesPackages: false,
            entriesToRecord: [:], appliedKeys: keys
        )
    }

    // MARK: - Opening a placeholder

    /// A reader of a placeholder in a library that is not in a cloud folder,
    /// the fetches `StoreBookStorage` was asked for, and when each was ended.
    private final class Fetches: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [UUID] = []
        private var ended = 0

        /// Notes that a fetch of `bookID` began.
        func began(_ bookID: UUID) {
            lock.lock(); defer { lock.unlock() }
            asked.append(bookID)
        }

        /// Notes that a fetch's stream was ended: cancelled by its reader or finished.
        func endedOne() {
            lock.lock(); defer { lock.unlock() }
            ended += 1
        }

        var askedBooks: [UUID] {
            lock.lock(); defer { lock.unlock() }
            return asked
        }

        var endedCount: Int {
            lock.lock(); defer { lock.unlock() }
            return ended
        }
    }

    /// Opens `book`, a placeholder, in a reader over a `StoreBookStorage`
    /// whose fetches never finish by themselves, as a fetch from iCloud Drive
    /// takes its time, and are recorded in `fetches`; each fulfils
    /// `started` as it begins. The reader's own loading asks (it starts in
    /// its initializer): no test asks again unless it says so.
    private func openPlaceholder(
        _ book: Book, fetches: Fetches, started: XCTestExpectation
    ) -> ReaderViewModel {
        let storage = StoreBookStorage(
            wrapping: LocalBookStorage(),
            isSyncOn: { true },
            fetcher: { package in
                fetches.began(package.bookID)
                started.fulfill()
                return AsyncThrowingStream { continuation in
                    continuation.onTermination = { _ in fetches.endedOne() }
                }
            }
        )
        let states = BookCloudStates()
        states.setSyncIsOn(true)
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library(books: [book])
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: library,
            settingsViewModel: SettingsViewModel(initializeServices: false),
            cloud: ReaderCloudServices(storage: storage, states: states, isDataless: { _ in false })
        )
        addTeardownBlock { @MainActor in reader.close() }
        return reader
    }

    /// A placeholder opened in a library that is not in a cloud folder takes
    /// the reader's download path, through `StoreBookStorage`, as a cloud
    /// book does, and one open fetches the book once. Without the reader's
    /// check for missing files while sync is on, the reader reads the absent
    /// file and no fetch is asked for; were one open to ask twice, two
    /// fetches of one book's files would be asked for, and this fails.
    func testAPlaceholderOpenedInALocalLibraryIsFetchedOnce() throws {
        let book = try makePlaceholder("Opened Away")
        let fetches = Fetches()
        let started = expectation(description: "the fetch of the placeholder starts")
        started.assertForOverFulfill = true
        let reader = openPlaceholder(book, fetches: fetches, started: started)
        wait(for: [started], timeout: 20)
        XCTAssertEqual(fetches.askedBooks, [book.id], "one open asks for one fetch of the one book")
        XCTAssertNotNil(reader.cloudPhase, "the reader shows the download")
    }

    /// Were the reader asked to load again while its fetch runs (a retry, a
    /// library change), the first fetch is ended before the second begins:
    /// two fetches of one book never run at once.
    func testASecondRequestEndsTheFirstFetchOfTheBook() throws {
        let book = try makePlaceholder("Asked Twice")
        let fetches = Fetches()
        let started = expectation(description: "both fetches start")
        started.expectedFulfillmentCount = 2
        let reader = openPlaceholder(book, fetches: fetches, started: started)
        // The opening's own fetch is under way once the reader shows it.
        let showing = expectation(description: "the reader shows the first download")
        let watch = reader.$cloudPhase.sink { if $0 != nil { showing.fulfill() } }
        wait(for: [showing], timeout: 20)
        watch.cancel()
        reader.loadContent()
        wait(for: [started], timeout: 20)
        XCTAssertEqual(fetches.askedBooks, [book.id, book.id])
        XCTAssertGreaterThanOrEqual(fetches.endedCount, 1, "the first fetch was ended when the second was asked for")
    }

    // MARK: - A feed item removed by sync

    /// A feed item another device removed is removed the way a person's
    /// removal does it, Delete Download: the item becomes not downloaded and
    /// its package stays while it holds the listener's bookmark. The plain
    /// package deletion that was used before takes the package whole.
    func testAFeedItemRemovedBySyncIsDeletedDownloadKeepingItsPackage() async throws {
        let world = try FeedTestWorld(self, label: "SyncFeedRemoval")
        await world.start()
        world.server.serve("/audio/1.m4a", FeedMediaFixtures.file(try FeedMediaFixtures.silentAAC(), mimeType: "audio/mp4"))
        let item = FeedXML.Item(
            guid: "ep-1", title: "Episode One", published: world.day(-1),
            enclosure: world.server.url("/audio/1.m4a").absoluteString, enclosureType: "audio/mp4"
        )
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: [item])))
        let feed = try await world.subscribe("/feed.xml")
        world.center.download("guid:ep-1", of: feed.id)
        let book = try await downloadedBook(world, feed: feed, item: "guid:ep-1")
        // The listener's own bookmark keeps the package past the file.
        world.library.updateBook(id: book.id) {
            $0.bookmarks = [Bookmark(number: 1, chapterIndex: 0, characterOffset: 5, label: "mine")]
        }
        let kept = try XCTUnwrap(world.library.bookByID(book.id))

        let key = SyncKey.book(book.id, .presence)
        let applied = await world.library.applySync(removal(of: [book.id], keys: [key]))

        XCTAssertTrue(applied.contains(key))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: kept.tmbDirectory.path),
            "the package, which holds the listener's bookmark, is kept"
        )
        let state = world.center.store.record(of: feed.id)?.item("guid:ep-1")?.state
        XCTAssertNil(state?.bookID, "the item is not downloaded now")
    }

    // MARK: - Busy books

    /// A book being transcribed is not removed, and its key is not applied.
    func testABookBeingTranscribedIsNotRemoved() async throws {
        keepDeletionsOutOfTheTrash()
        let book = try makePlaceholder("Transcribing")
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library(books: [book])
        let transcriptions = TranscribedBooks.shared
        let before = transcriptions.transcribingBookID
        addTeardownBlock { @MainActor in transcriptions.setTranscribing(before) }
        transcriptions.setTranscribing(book.id)
        let key = SyncKey.book(book.id, .presence)

        let applied = await library.applySync(removal(of: [book.id], keys: [key]))

        XCTAssertNotNil(library.bookByID(book.id))
        XCTAssertFalse(applied.contains(key))
    }

    /// A book being edited with Edit Text is not removed, and its key is not applied.
    func testABookBeingTextEditedIsNotRemoved() async throws {
        keepDeletionsOutOfTheTrash()
        let book = try makePlaceholder("Text Editing")
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library(books: [book])
        let sessions = BookTextEditSessions()
        library.textEditSessions = sessions
        let fingerprint = FileFingerprint(stamp: FileStamp(byteCount: 0, modificationTimeNanoseconds: 0), digest: "")
        sessions.begin(book.id, BookTextEditSessions.Session(
            baseline: BookTextBaseline(source: nil, cache: fingerprint), report: { _, _ in }
        ))
        addTeardownBlock { sessions.end(book.id) }
        let key = SyncKey.book(book.id, .presence)

        let applied = await library.applySync(removal(of: [book.id], keys: [key]))

        XCTAssertNotNil(library.bookByID(book.id))
        XCTAssertFalse(applied.contains(key))
    }
}

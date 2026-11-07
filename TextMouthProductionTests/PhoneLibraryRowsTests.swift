import Combine
import XCTest
@testable import TextMouth

/// Small libraries for the iPhone Library's tests, held in memory: nothing is
/// read from or written to a disk, and no book is ever opened.
@MainActor
enum PhoneLibraryFixture {
    /// A book of `title` in `folder`, with `percent` of its text read when
    /// given, so its row says progress and time left.
    static func book(
        _ title: String,
        by author: String = "Odile Halvorsen",
        in folder: String = "",
        percent: Int? = nil,
        opened: Bool = true,
        order: Int? = nil
    ) -> Book {
        Book(
            title: title,
            author: author,
            format: .txt,
            filePath: "/nonexistent/\(title).txt",
            md5Hash: "hash-\(title)",
            folderPath: folder,
            lastOpened: opened ? Date(timeIntervalSince1970: 50_000) : nil,
            readingPosition: percent.map { ReadingPosition(characterOffset: $0 * 100, globalCharacterOffset: $0 * 100) },
            totalWordCount: 2_000,
            totalCharacterCount: 10_000,
            manualSortOrder: order
        )
    }

    /// A library model of `books` and `folders`, with no services running.
    static func model(books: [Book], folders: [BookFolder] = [], readingList: [UUID] = []) -> LibraryViewModel {
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: books, folders: folders, readingList: ReadingList(bookIDs: readingList))
        return model
    }

    /// The removal preferences of a phone: ask first, and delete for good.
    static let phoneRemoval = RemovalPreferences(confirmsFirst: true, movesToTrash: false)

    /// The rows of `model` at `location`, with the open book told by
    /// `listening`, and `reach` the book in reach.
    static func rows(
        of model: LibraryViewModel,
        at location: LibraryLocation = LibraryLocation(category: .folders, folderPath: ""),
        listening: CurrentValueSubject<PhoneLibraryListening, Never> = CurrentValueSubject(.nothingOpen),
        reach: @escaping () -> Book? = { nil }
    ) -> PhoneLibraryRows {
        PhoneLibraryRows(
            library: model,
            location: location,
            wordsPerMinute: { 200 },
            removalPreferences: { phoneRemoval },
            bookInReach: reach,
            listening: listening.eraseToAnyPublisher()
        )
    }
}

/// `PhoneLibraryRows`: the iPhone Library's list as values, whose words never
/// change under a listener while a book plays (the engineering review's F11).
@MainActor
final class PhoneLibraryRowsTests: XCTestCase {
    // MARK: - A Book's Row

    /// A book's row says exactly what the Mac's row says, title first.
    func testABookRowSaysExactlyTheMacsLabel() throws {
        let book = PhoneLibraryFixture.book("Middlemarch", by: "George Eliot", percent: 42)
        let model = PhoneLibraryFixture.model(books: [book], readingList: [book.id])
        let rows = PhoneLibraryFixture.rows(of: model)

        let row = try XCTUnwrap(rows.sections.flatMap(\.rows).first { $0.id == .book(book.id) })
        let mac = BookRow(book: book, isOpenInWindow: false, wpm: 200, isInReadingList: true).rowAccessibilityLabel
        XCTAssertEqual(row.label, mac)
        XCTAssertTrue(row.label.hasPrefix("Middlemarch, by George Eliot, In reading list, 42 percent"), row.label)
        XCTAssertEqual(row.title, "Middlemarch")
        XCTAssertEqual(row.detail, "George Eliot, 42%")
        XCTAssertEqual(row.kind, .book)
    }

    /// In the Reading List, where every book is in it, a row doesn't say so,
    /// as on the Mac.
    func testAReadingListRowLeavesOutInReadingList() throws {
        let book = PhoneLibraryFixture.book("Middlemarch")
        let model = PhoneLibraryFixture.model(books: [book], readingList: [book.id])
        let rows = PhoneLibraryFixture.rows(of: model, at: LibraryLocation(category: .readingList, folderPath: ""))

        let row = try XCTUnwrap(rows.sections.flatMap(\.rows).first)
        XCTAssertFalse(row.label.contains(ReadingListWording.inReadingListNote), row.label)
        XCTAssertEqual(row.commands.map(\.action), [.bookInfo, .removeFromReadingList, .moveToFolder, .remove])
    }

    // MARK: - What Republishes

    /// A checkpoint, which moves a reading position alone, publishes nothing:
    /// the row keeps the words it had.
    func testACheckpointLeavesTheRowsAsTheyWere() throws {
        let book = PhoneLibraryFixture.book("Middlemarch", percent: 10)
        let model = PhoneLibraryFixture.model(books: [book])
        let rows = PhoneLibraryFixture.rows(of: model)
        let before = rows.sections
        let builds = rows.buildCount
        var published = 0
        let subscription = rows.$sections.dropFirst().sink { _ in published += 1 }

        model.library.updateReadingPosition(bookID: book.id, position: ReadingPosition(characterOffset: 9_000))
        drainMainQueue()

        XCTAssertEqual(rows.buildCount, builds, "A checkpoint built the rows again")
        XCTAssertEqual(published, 0)
        XCTAssertEqual(rows.sections, before)
        subscription.cancel()
    }

    /// A title changed is a change of the list, and its row says it.
    func testARenamedBookRepublishes() throws {
        let book = PhoneLibraryFixture.book("Middlemarch")
        let model = PhoneLibraryFixture.model(books: [book])
        let rows = PhoneLibraryFixture.rows(of: model)
        let builds = rows.buildCount

        let index = try XCTUnwrap(model.library.books.firstIndex { $0.id == book.id })
        model.library.books[index].title = "Daniel Deronda"
        drainMainQueue()

        XCTAssertEqual(rows.buildCount, builds + 1)
        XCTAssertEqual(rows.sections.flatMap(\.rows).first?.title, "Daniel Deronda")
    }

    /// A book added is a change of the list.
    func testAnAddedBookRepublishes() {
        let model = PhoneLibraryFixture.model(books: [PhoneLibraryFixture.book("Middlemarch")])
        let rows = PhoneLibraryFixture.rows(of: model)

        model.library.books.append(PhoneLibraryFixture.book("Adam Bede"))
        drainMainQueue()

        XCTAssertEqual(rows.sections.flatMap(\.rows).map(\.title), ["Adam Bede", "Middlemarch"])
        XCTAssertEqual(rows.sections.last?.header, "Books (2)")
    }

    /// When a book stops playing, the rows are built afresh with the place it
    /// reached; starting to play builds nothing.
    func testStoppingPlaybackBuildsTheRowsAfresh() throws {
        let book = PhoneLibraryFixture.book("Middlemarch", percent: 10)
        let model = PhoneLibraryFixture.model(books: [book])
        let listening = CurrentValueSubject<PhoneLibraryListening, Never>(PhoneLibraryListening(bookID: book.id, isPlaying: false))
        let rows = PhoneLibraryFixture.rows(of: model, listening: listening)
        drainMainQueue()
        let builds = rows.buildCount

        listening.send(PhoneLibraryListening(bookID: book.id, isPlaying: true))
        drainMainQueue()
        XCTAssertEqual(rows.buildCount, builds, "Starting to play built the rows")

        model.library.updateReadingPosition(bookID: book.id, position: ReadingPosition(characterOffset: 5_000, globalCharacterOffset: 5_000))
        drainMainQueue()
        XCTAssertEqual(rows.buildCount, builds, "A checkpoint built the rows")

        listening.send(PhoneLibraryListening(bookID: book.id, isPlaying: false))
        drainMainQueue()
        XCTAssertEqual(rows.buildCount, builds + 1)
        let row = try XCTUnwrap(rows.sections.flatMap(\.rows).first)
        XCTAssertTrue(row.label.contains("50 percent"), row.label)
    }

    // MARK: - Folders

    /// At the top of Folders, the folders come first under "Folders", each
    /// with the Mac's label and commands, then the books at the top.
    func testTheTopListsFoldersThenBooks() throws {
        let fiction = BookFolder(name: "Fiction")
        let books = [
            PhoneLibraryFixture.book("Kiln Atlas", in: "Fiction"),
            PhoneLibraryFixture.book("Weir", in: "Fiction"),
            PhoneLibraryFixture.book("Orchard"),
        ]
        let model = PhoneLibraryFixture.model(books: books, folders: [fiction])
        let rows = PhoneLibraryFixture.rows(of: model)

        XCTAssertEqual(rows.sections.map(\.header), ["Folders", "Books (1)"])
        let folderRow = try XCTUnwrap(rows.sections.first?.rows.first)
        XCTAssertEqual(folderRow.id, .folder("Fiction"))
        XCTAssertEqual(folderRow.label, "Fiction, 2 books")
        XCTAssertEqual(folderRow.label, FolderRow.accessibilityLabel(name: "Fiction", bookCount: 2, feedCounts: nil))
        XCTAssertEqual(folderRow.detail, "2 books")
        XCTAssertEqual(folderRow.commands.map(\.title), ["Rename Folder...", "Move Folder...", "Delete Folder..."])
        XCTAssertEqual(rows.sections.last?.rows.map(\.title), ["Orchard"])
    }

    /// A folder's count changing is a change of the list.
    func testAFolderCountChangeRepublishes() throws {
        let model = PhoneLibraryFixture.model(
            books: [PhoneLibraryFixture.book("Weir", in: "Fiction"), PhoneLibraryFixture.book("Orchard")],
            folders: [BookFolder(name: "Fiction")]
        )
        let rows = PhoneLibraryFixture.rows(of: model)
        XCTAssertEqual(rows.sections.first?.rows.first?.label, "Fiction, 1 book")

        let index = try XCTUnwrap(model.library.books.firstIndex { $0.title == "Orchard" })
        model.library.books[index].folderPath = "Fiction"
        drainMainQueue()

        XCTAssertEqual(rows.sections.first?.rows.first?.label, "Fiction, 2 books")
    }

    // MARK: - Empty States

    /// A library with nothing in it shows its one sentence, and nothing else.
    func testAnEmptyLibrarySaysSo() {
        let rows = PhoneLibraryFixture.rows(of: PhoneLibraryFixture.model(books: []))

        XCTAssertEqual(rows.sections.count, 1)
        XCTAssertNil(rows.sections.first?.header)
        XCTAssertEqual(rows.rowIDs, [.note(.emptyLibrary)])
        XCTAssertEqual(rows.sections.first?.rows.first?.label, "Your library is empty. Add to Library adds a book.")
        XCTAssertNil(rows.summary)
    }

    /// An empty folder has "Books (0)", then its sentence.
    func testAnEmptyFolderSaysSo() {
        let model = PhoneLibraryFixture.model(
            books: [PhoneLibraryFixture.book("Orchard")],
            folders: [BookFolder(name: "Fiction")]
        )
        let rows = PhoneLibraryFixture.rows(of: model, at: LibraryLocation(category: .folders, folderPath: "Fiction"))

        XCTAssertEqual(rows.sections.map(\.header), ["Books (0)"])
        XCTAssertEqual(rows.rowIDs, [.note(.emptyFolder)])
        XCTAssertEqual(rows.sections.first?.rows.first?.label, "This folder is empty.")
    }

    /// An empty Reading List, and a view that lists nothing, say their own
    /// sentences.
    func testEmptyViewsSayTheirSentences() {
        let model = PhoneLibraryFixture.model(books: [PhoneLibraryFixture.book("Orchard", opened: true)])

        let list = PhoneLibraryFixture.rows(of: model, at: LibraryLocation(category: .readingList, folderPath: ""))
        XCTAssertEqual(list.rowIDs, [.note(.emptyReadingList)])
        XCTAssertEqual(
            list.sections.first?.rows.first?.label,
            "The reading list is empty. To add a book, choose Add to Reading List from its actions."
        )

        let unopened = PhoneLibraryFixture.rows(of: model, at: LibraryLocation(category: .unopened, folderPath: ""))
        XCTAssertEqual(unopened.rowIDs, [.note(.emptyView)])
        XCTAssertEqual(unopened.sections.first?.rows.first?.label, "Nothing matches this view now.")
    }

    // MARK: - Searching

    /// A search at the top of a library kept in folders finds the books in
    /// its folders, and the folders whose names hold the text, and the
    /// summary steps aside.
    func testSearchCoversTheWholeLibrary() {
        let model = PhoneLibraryFixture.model(
            books: [
                PhoneLibraryFixture.book("Dune", in: "Sea Stories"),
                PhoneLibraryFixture.book("Sea Room", in: "Fiction/Old"),
                PhoneLibraryFixture.book("Orchard"),
            ],
            folders: [BookFolder(name: "Fiction"), BookFolder(name: "Old", parentPath: "Fiction"), BookFolder(name: "Sea Stories")]
        )
        let rows = PhoneLibraryFixture.rows(of: model)
        XCTAssertNotNil(rows.summary)

        rows.search(for: "sea")

        XCTAssertTrue(rows.isSearching)
        XCTAssertEqual(rows.rowIDs.first, .folder("Sea Stories"))
        XCTAssertEqual(rows.sections.flatMap(\.rows).filter { $0.kind == .book }.map(\.title), ["Sea Room"])
        XCTAssertEqual(rows.searchCounts.books, 1)
        XCTAssertEqual(rows.searchCounts.folders, 1)
        XCTAssertNil(rows.summary)

        rows.search(for: "dune")
        XCTAssertEqual(rows.sections.flatMap(\.rows).map(\.title), ["Dune"])

        rows.search(for: "")
        XCTAssertFalse(rows.isSearching)
        XCTAssertEqual(rows.sections.map(\.header), ["Folders", "Books (1)"])
    }

    /// A search that matches nothing has its one sentence.
    func testASearchThatFindsNothingSaysSo() {
        let rows = PhoneLibraryFixture.rows(of: PhoneLibraryFixture.model(books: [PhoneLibraryFixture.book("Orchard")]))

        rows.search(for: "zebra")

        XCTAssertEqual(rows.rowIDs, [.note(.noMatches)])
        XCTAssertEqual(rows.sections.first?.rows.first?.label, "No books match.")
    }

    // MARK: - Letters

    /// More than 30 books sorted by title have the books' heading, then a
    /// heading for each letter, the books in their order.
    func testManyBooksByTitleHaveLetterSections() {
        let titles = (0..<31).map { "\(["Almanac", "Bestiary", "Codex"][$0 % 3]) \($0)" }
        let model = PhoneLibraryFixture.model(books: titles.map { PhoneLibraryFixture.book($0) })
        let rows = PhoneLibraryFixture.rows(of: model)

        XCTAssertEqual(rows.sections.map(\.header), ["Books (31)", "A", "B", "C"])
        XCTAssertEqual(rows.sections.map(\.indexLabel), [nil, "A", "B", "C"])
        XCTAssertEqual(rows.sections.first?.rows, [])
        XCTAssertEqual(rows.sections.dropFirst().map(\.rows.count), [11, 10, 10])
        XCTAssertEqual(Set(rows.sections.map(\.id)).count, rows.sections.count, "Two sections share an identity")
    }

    /// Thirty books, or a sort by date, have no letter sections.
    func testFewBooksOrAnotherSortHaveNone() {
        let model = PhoneLibraryFixture.model(books: (0..<30).map { PhoneLibraryFixture.book("Almanac \($0)") })
        XCTAssertEqual(PhoneLibraryFixture.rows(of: model).sections.map(\.header), ["Books (30)"])

        model.library.books.append(PhoneLibraryFixture.book("Bestiary"))
        model.library.folderSortSettings[""] = FolderSortSetting(sortField: .dateAdded, sortAscending: true)
        XCTAssertEqual(PhoneLibraryFixture.rows(of: model).sections.map(\.header), ["Books (31)"])
    }

    // MARK: - Moves and Removal

    /// In a folder in manual order, rows offer Move Up and Move Down where
    /// the book can move.
    func testManualOrderOffersMoves() throws {
        let books = [
            PhoneLibraryFixture.book("Kiln Atlas", order: 0),
            PhoneLibraryFixture.book("Granary", order: 1),
        ]
        let model = PhoneLibraryFixture.model(books: books)
        model.library.folderSortSettings[""] = FolderSortSetting(sortField: .manual, sortAscending: true)
        let rows = PhoneLibraryFixture.rows(of: model)

        let listed = rows.sections.flatMap(\.rows)
        XCTAssertEqual(listed.map(\.title), ["Kiln Atlas", "Granary"])
        XCTAssertEqual(listed.first?.commands.map(\.action), [.bookInfo, .addToReadingList, .moveToFolder, .moveDown, .remove])
        XCTAssertEqual(listed.last?.commands.map(\.action), [.bookInfo, .addToReadingList, .moveToFolder, .moveUp, .remove])
    }

    /// Once a row leaves, focus goes to the row after it, or the one before
    /// it when it was the last.
    func testTheNeighborOfARemovedRow() {
        let books = ["Almanac", "Bestiary", "Codex"].map { PhoneLibraryFixture.book($0) }
        let rows = PhoneLibraryFixture.rows(of: PhoneLibraryFixture.model(books: books))

        XCTAssertEqual(rows.neighbor(of: .book(books[0].id)), .book(books[1].id))
        XCTAssertEqual(rows.neighbor(of: .book(books[2].id)), .book(books[1].id))
        XCTAssertNil(rows.neighbor(of: .book(UUID())))
    }

    /// The summary is the Mac's spoken summary of the books listed.
    func testTheSummaryIsTheMacs() {
        let books = [PhoneLibraryFixture.book("Almanac", percent: 50), PhoneLibraryFixture.book("Bestiary", opened: false)]
        let rows = PhoneLibraryFixture.rows(of: PhoneLibraryFixture.model(books: books))

        let mac = TimeRemainingBar(books: books, wpm: 200)
        XCTAssertEqual(rows.summary, mac.summaryAccessibilityLabel)
        XCTAssertTrue(rows.summary?.hasPrefix("2 books. ") == true, rows.summary ?? "nil")
    }

    // MARK: - The Continue Row

    /// Not playing, the Continue row says the Mac's words with the time left;
    /// playing, "Now Playing:" and the title, and a checkpoint changes neither.
    func testTheContinueRowFollowsPlayingAlone() throws {
        let book = PhoneLibraryFixture.book("Emma", percent: 50)
        let model = PhoneLibraryFixture.model(books: [book])
        let listening = CurrentValueSubject<PhoneLibraryListening, Never>(.nothingOpen)
        let rows = PhoneLibraryFixture.rows(of: model, listening: listening, reach: { model.bookByID(book.id) })

        let resting = try XCTUnwrap(rows.continueRow)
        XCTAssertEqual(resting.label, LibraryView.continueAccessibilityLabel(for: book, wpm: 200))
        XCTAssertEqual(resting.visibleTitle, "Continue: Emma")
        XCTAssertFalse(resting.isPlaying)

        listening.send(PhoneLibraryListening(bookID: book.id, isPlaying: true))
        drainMainQueue()
        XCTAssertEqual(rows.continueRow?.label, "Now Playing: Emma")
        XCTAssertNil(rows.continueRow?.timeText)

        model.library.updateReadingPosition(bookID: book.id, position: ReadingPosition(characterOffset: 8_000, globalCharacterOffset: 8_000))
        drainMainQueue()
        XCTAssertEqual(rows.continueRow?.label, "Now Playing: Emma", "A checkpoint changed the row")
    }

    /// The book in reach leaving the library takes the row with it.
    func testTheContinueRowLeavesWithItsBook() {
        let book = PhoneLibraryFixture.book("Emma")
        let model = PhoneLibraryFixture.model(books: [book, PhoneLibraryFixture.book("Dune")])
        let rows = PhoneLibraryFixture.rows(of: model, reach: { model.bookByID(book.id) })
        XCTAssertEqual(rows.continueRow?.bookID, book.id)

        model.library.removeBook(id: book.id)
        drainMainQueue()

        XCTAssertNil(rows.continueRow)
    }

    // MARK: - Helpers

    /// Lets the main queue run what was put on it before now, as the rows'
    /// subscriptions put the library's changes there.
    private func drainMainQueue(file: StaticString = #filePath, line: UInt = #line) {
        let drained = expectation(description: "the main queue ran")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }
}

import XCTest
@testable import TextMouth

/// The one-time move of the books Books Finished counts to their ends
/// (TODO P07; the user, October 10, 2026, question 16: "yes"): each counted
/// book whose row reads 100 percent is put exactly at its end once, so it
/// reads as finished, as every book that plays to its end now rests.
///
/// The books are shaped like the user's, as the design note counted them:
/// counted books at their last word, at 99.5 percent, past the end of a
/// text extracted again since, and exactly at the end; the one counted
/// book at 99 percent; a book at 100 percent that Books Finished does not
/// count; a counted book whose files are only in the cloud; and one open in
/// a reader window. Each lives in a package of its own, with a record and a
/// content index, in a library folder of the test's own; nothing is read
/// from or written to the user's library.
@MainActor
final class FinishedBooksAtEndMoveTests: XCTestCase {

    // MARK: - Which Books Move

    /// The move is for the books Books Finished counts whose row reads 100
    /// percent, as the row rounds it (`BookRow.progressText(for:)`): 99.5
    /// percent and above. The one at 99 percent stays, and so does a book
    /// at 100 percent that Books Finished does not count.
    func testOnlyCountedBooksWhoseRowReadsAHundredPercentAreConsidered() {
        let counted = Self.book(at: 1_990)
        let ninetyNine = Self.book(at: 1_980)
        let uncounted = Self.book(at: 1_995)
        let past = Self.book(at: 2_300)

        XCTAssertEqual(BookRow.progressText(for: counted)?.visible, "100%", "99.5 percent does not read 100 in its row")
        XCTAssertEqual(BookRow.progressText(for: ninetyNine)?.visible, "99%")
        XCTAssertEqual(
            LibraryViewModel.finishedBooksShortOfTheirEnds(
                [counted, ninetyNine, uncounted, past],
                counted: [counted.id, ninetyNine.id, past.id]
            ).map(\.id),
            [counted.id, past.id]
        )
    }

    /// A book moves to its last chapter at the length its content index
    /// records, whose global offset is the book's total; a book exactly
    /// there already does not move.
    func testABookMovesToItsLastChapterAtItsFullLength() {
        let index = Self.index()
        XCTAssertEqual(
            LibraryViewModel.finishedBookEnd(of: Self.book(at: 1_993), index: index).map(Self.place),
            Self.place(Self.end)
        )
        XCTAssertNil(LibraryViewModel.finishedBookEnd(of: Self.book(at: 2_000), index: index), "A book at its end moved")
    }

    // MARK: - The Move

    /// Shaped like the user's library: the counted books at 100 percent
    /// move to their ends, saved in their rows and records, their places
    /// dated now and their last-opened dates kept, and read as finished; the
    /// one at 99 percent, the one not counted, and the one exactly at its
    /// end already stay as they were, unwritten; the one in the cloud and
    /// the one open in a reader window wait for a later move, which moves
    /// them once they are here and closed.
    func testTheCountedBooksAtAHundredPercentArePutAtTheirEnds() throws {
        let world = try makeIntegrationWorld("Finished Books At End")
        let lastWord = try makeBook("Last Word", at: 1_993, in: world)
        let halfway = try makeBook("Rounded Up", at: 1_990, in: world)
        let pastTheEnd = try makeBook("Extracted Again", at: 2_300, in: world)
        let atTheEnd = try makeBook("At Its End", at: 2_000, in: world)
        let ninetyNine = try makeBook("Ninety-Nine", at: 1_980, in: world)
        let notCounted = try makeBook("Not Counted", at: 1_995, in: world)
        let inCloud = try makeBook("In the Cloud", at: 1_995, in: world)
        let open = try makeBook("Open Now", at: 1_995, in: world)
        let counted = Set([lastWord, halfway, pastTheEnd, atTheEnd, ninetyNine, inCloud, open].map(\.id))
        world.library.registerOpenBook(open.id)
        let cloudIndex = TextMouthPaths.contentIndexPath(in: inCloud.tmbDirectory)
        let cloud = MaintenanceFileAccess(isDataless: { _ in false }, refusesRead: { $0 == cloudIndex })

        let first = try move(counted: counted, in: world, access: cloud)

        XCTAssertEqual(first, LibraryViewModel.FinishedBooksAtEndOutcome(moved: 3, waiting: 2, unplaced: 0))
        for book in [lastWord, halfway, pastTheEnd] {
            try assertAtItsEnd(book, in: world)
        }
        for book in [atTheEnd, ninetyNine, notCounted, inCloud, open] {
            XCTAssertEqual(row(of: book, in: world)?.readingPosition, book.readingPosition, "\(book.title) was moved")
            XCTAssertEqual(row(of: book, in: world)?.lastOpened, Self.lastOpened, "\(book.title) was dated opened")
        }
        XCTAssertTrue(row(of: atTheEnd, in: world)?.restsAtEnd ?? false, "The book at its end does not read as finished")
        XCTAssertFalse(row(of: ninetyNine, in: world)?.restsAtEnd ?? true, "The book at 99 percent reads as finished")
        XCTAssertEqual(
            first.logLine,
            "FINISHED_BOOKS_AT_END: moved 3 of the books Books Finished counts to their ends; "
                + "2 wait for a later launch; 0 without a content index to place them by"
        )

        world.library.unregisterOpenBook(open.id)
        let second = try move(counted: counted, in: world, access: .live)

        XCTAssertEqual(second, LibraryViewModel.FinishedBooksAtEndOutcome(moved: 2, waiting: 0, unplaced: 0))
        try assertAtItsEnd(inCloud, in: world)
        try assertAtItsEnd(open, in: world)
    }

    /// The move is made once on this Mac: it is recorded as made only once
    /// no book waits for it, and from then on it moves nothing, not even a
    /// counted book read again to 100 percent since. Books Finished is read
    /// from the statistics given, as the launch reads the app's.
    func testTheMoveIsMadeOnceEveryBookWasHere() throws {
        let world = try makeIntegrationWorld("Finished Books At End Once")
        let preferences = makeSandboxedPreferences("Finished Books At End Once")
        let statistics = makeStatistics()
        let lastWord = try makeBook("Last Word", at: 1_993, in: world)
        let inCloud = try makeBook("In the Cloud", at: 1_995, in: world)
        for book in [lastWord, inCloud] {
            statistics.markBookFinished(bookID: book.id, title: book.title)
        }
        let cloudIndex = TextMouthPaths.contentIndexPath(in: inCloud.tmbDirectory)
        let cloud = MaintenanceFileAccess(isDataless: { _ in false }, refusesRead: { $0 == cloudIndex })

        try moveOnce(in: world, statistics: statistics, preferences: preferences, access: cloud)
        try assertAtItsEnd(lastWord, in: world)
        XCTAssertEqual(row(of: inCloud, in: world)?.readingPosition, inCloud.readingPosition)
        XCTAssertEqual(preferences.integer(forKey: LibraryViewModel.finishedBooksAtEndKey), 0, "Recorded as made while a book waits")

        try moveOnce(in: world, statistics: statistics, preferences: preferences, access: .live)
        try assertAtItsEnd(inCloud, in: world)
        XCTAssertEqual(
            preferences.integer(forKey: LibraryViewModel.finishedBooksAtEndKey),
            LibraryViewModel.finishedBooksAtEndVersion,
            "Not recorded as made"
        )

        // Read again to 100 percent, short of its end, it stays there.
        let readAgain = ReadingPosition(chapterIndex: 2, characterOffset: 996, globalCharacterOffset: 1_996)
        world.library.persistReadingPosition(bookID: lastWord.id, position: readAgain)
        try moveOnce(in: world, statistics: statistics, preferences: preferences, access: .live)
        XCTAssertEqual(row(of: lastWord, in: world)?.readingPosition, readAgain, "The move was made again")
    }

    // MARK: - The Last-Opened Date

    /// A reader's save dates its book's opening now, as it always has, in
    /// the row and so in the record; a place moved for a book nobody
    /// opened, as the one-time move moves one, keeps the date (REV14).
    func testOnlyAReadersSaveDatesTheBooksOpening() throws {
        let book = Self.book(at: 1_000)
        var library = Library(books: [book])
        let place = ReadingPosition(chapterIndex: 2, characterOffset: 500, globalCharacterOffset: 1_500)

        library.updateReadingPosition(bookID: book.id, position: place, markingOpened: false)
        let moved = try XCTUnwrap(library.books.first)
        XCTAssertEqual(moved.readingPosition, place)
        XCTAssertEqual(moved.lastOpened, Self.lastOpened, "A moved place dated the book opened")

        let beforeTheSave = Date()
        library.updateReadingPosition(bookID: book.id, position: place)
        let saved = try XCTUnwrap(library.books.first?.lastOpened, "A reader's save left the book unopened")
        XCTAssertGreaterThanOrEqual(saved, beforeTheSave, "A reader's save did not date the book opened now")
    }

    // MARK: - Fixtures

    /// When every fixture book was last opened, in whole seconds, as the
    /// record's dates are written: long before any test runs.
    private static let lastOpened = Date(timeIntervalSince1970: 1_767_225_600)

    /// The chapters' lengths of every fixture book, in UTF-16 code units:
    /// 2,000 in all, so a tenth of a percent is two units.
    private static let chapterLengths = [500, 500, 1_000]

    /// Where every fixture book ends: its last chapter, at its full length.
    private static let end = ReadingPosition(chapterIndex: 2, characterOffset: 1_000, globalCharacterOffset: 2_000)

    /// A place's chapter, offset, and global offset, which a comparison
    /// takes without its date.
    private static func place(_ position: ReadingPosition) -> [Int?] {
        [position.chapterIndex, position.characterOffset, position.globalCharacterOffset]
    }

    /// The content index of every fixture book: its three chapters of words.
    private static func index() -> BookContentIndex {
        let chapters = chapterLengths.enumerated().map { number, length in
            Chapter(title: "Part \(number + 1)", text: String(repeating: "tide ", count: length / 5))
        }
        return BookContentIndex.build(fromChapters: chapters, format: .txt)
    }

    /// A text book, measured as the library measures it, last opened at
    /// `lastOpened`, whose row is saved `globalOffset` into it, in its last
    /// chapter.
    private static func book(at globalOffset: Int, title: String = "Breakwater Survey", folder: String = "") -> Book {
        let index = index()
        let lastChapterStart = index.totalCharacterCount - (chapterLengths.last ?? 0)
        return Book(
            title: title,
            format: .txt,
            filePath: "/nowhere/\(title).txt",
            md5Hash: UUID().uuidString,
            folderPath: folder,
            lastOpened: lastOpened,
            readingPosition: ReadingPosition(
                chapterIndex: 2,
                characterOffset: globalOffset - lastChapterStart,
                globalCharacterOffset: globalOffset
            ),
            totalWordCount: index.totalWordCount,
            totalCharacterCount: index.totalCharacterCount,
            tmbDirectoryName: "\(UUID().uuidString).tmb"
        )
    }

    /// A fixture book titled `title`, saved `globalOffset` into it, in a
    /// package of its own in `world`'s folder holding its record and content
    /// index, and listed in `world`'s library.
    private func makeBook(_ title: String, at globalOffset: Int, in world: IntegrationWorld) throws -> Book {
        let book = Self.book(at: globalOffset, title: title, folder: world.folder.path)
        try FileManager.default.createDirectory(at: book.tmbDirectory, withIntermediateDirectories: true)
        try book.saveBookInfoThrowing(contentIndex: Self.index())
        world.library.library.addBook(book)
        return book
    }

    /// Statistics of the test's own, over a file in a folder of its own,
    /// removed when the test ends.
    private func makeStatistics() -> ReadingStatsService {
        let folder = TextMouthPaths.root.appendingPathComponent(
            "FinishedBooksAtEndMoveTests-\(UUID().uuidString)", isDirectory: true
        )
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let statistics = ReadingStatsService(fileURL: folder.appendingPathComponent("reading_stats.json"))
        addTeardownBlock { @MainActor in
            statistics.shutdown()
            ReadingStatsService.waitForQueuedSaves()
            try? FileManager.default.removeItem(at: folder)
        }
        return statistics
    }

    /// Moves the books `counted` names in `world`'s library through
    /// `access`, waits for the move, and returns what it did.
    private func move(
        counted: Set<UUID>,
        in world: IntegrationWorld,
        access: MaintenanceFileAccess
    ) throws -> LibraryViewModel.FinishedBooksAtEndOutcome {
        var outcome: LibraryViewModel.FinishedBooksAtEndOutcome?
        world.library.moveFinishedBooksToTheirEnds(counted: counted, access: access) { outcome = $0 }
        XCTAssertTrue(eventually(within: 10) { outcome != nil }, "The move never ended")
        return try XCTUnwrap(outcome)
    }

    /// Makes the move once, as the launch does, with `statistics`,
    /// `preferences`, and `access`, and waits for it.
    private func moveOnce(
        in world: IntegrationWorld,
        statistics: ReadingStatsService,
        preferences: UserDefaults,
        access: MaintenanceFileAccess
    ) throws {
        var ended = false
        world.library.moveFinishedBooksToTheirEndsOnce(statistics: statistics, preferences: preferences, access: access) {
            ended = true
        }
        XCTAssertTrue(eventually(within: 10) { ended }, "The move never ended")
    }

    /// The library's row of `book` in `world`.
    private func row(of book: Book, in world: IntegrationWorld) -> Book? {
        world.library.bookByID(book.id)
    }

    /// Check that `book` was put at its end: its row there, the place dated
    /// after it was saved, the book's last-opened date kept, and reading as
    /// finished, and its record there too, with the same last-opened date
    /// (REV14: the move once dated every book it moved as opened now).
    private func assertAtItsEnd(
        _ book: Book,
        in world: IntegrationWorld,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let saved = try XCTUnwrap(row(of: book, in: world)?.readingPosition, "\(book.title) has no place", file: file, line: line)
        XCTAssertEqual(Self.place(saved), Self.place(Self.end), "\(book.title) is not at its end", file: file, line: line)
        XCTAssertGreaterThan(
            saved.lastUpdated,
            book.readingPosition?.lastUpdated ?? .distantPast,
            "\(book.title)'s move is not dated now",
            file: file,
            line: line
        )
        XCTAssertEqual(row(of: book, in: world)?.lastOpened, Self.lastOpened, "\(book.title) was dated opened", file: file, line: line)
        XCTAssertTrue(row(of: book, in: world)?.restsAtEnd ?? false, "\(book.title) does not read as finished", file: file, line: line)
        LibraryPersistenceService.flushPendingSave()
        let record = try StoredBookRecord.read(from: book.tmbDirectory).info
        let recorded = try XCTUnwrap(record.state.readingPosition, "\(book.title)'s record has no place", file: file, line: line)
        XCTAssertEqual(Self.place(recorded), Self.place(Self.end), "\(book.title)'s record is not at its end", file: file, line: line)
        XCTAssertEqual(record.metadata.lastOpened, Self.lastOpened, "\(book.title)'s record was dated opened", file: file, line: line)
        XCTAssertFalse(record.state.isNew, "\(book.title)'s record reads as never opened", file: file, line: line)
    }
}

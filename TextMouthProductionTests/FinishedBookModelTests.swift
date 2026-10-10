import XCTest
@testable import TextMouth

/// What a finished book is, apart from any window (TODO P07): where it
/// rests, and how Books Finished counts it.
///
/// The user decided on October 10, 2026 that a book that plays to its end
/// is saved exactly at its end and stays finished after TextMouth quits
/// ("yes", question 11), with no field of its own: the place says it
/// (`Book.restsAtEnd`).
final class FinishedBookModelTests: XCTestCase {

    // MARK: - Resting at the End

    /// The book's measured text: 1,000 UTF-16 units over its chapters.
    private static let total = 1_000

    /// A book `total` units long whose saved place is `place`, given by its
    /// global offset, or none.
    private func book(at globalOffset: Int?, chapter: Int = 2, offset: Int = 0, total: Int? = total) -> Book {
        Book(
            title: "Breakwater Survey",
            format: .epub,
            filePath: "/nowhere/breakwater.epub",
            md5Hash: "breakwater",
            readingPosition: ReadingPosition(chapterIndex: chapter, characterOffset: offset, globalCharacterOffset: globalOffset),
            totalCharacterCount: total
        )
    }

    /// A place at the end of the text, or past it, as a place saved before
    /// the text was extracted again can be, rests at the end; a place short
    /// of it, however near, does not: speech saved there stopped before the
    /// book did.
    func testABookRestsAtItsEndOnlyAtOrPastTheEndOfItsText() {
        XCTAssertTrue(book(at: Self.total).restsAtEnd, "The end itself")
        XCTAssertTrue(book(at: Self.total + 40).restsAtEnd, "Past the end")
        XCTAssertFalse(book(at: Self.total - 1).restsAtEnd, "One unit short")
        XCTAssertFalse(book(at: Self.total - 7).restsAtEnd, "The last word, where speech left it")
        XCTAssertFalse(book(at: 0).restsAtEnd, "The beginning")
    }

    /// A book at its end reads 100 percent, as the row's percent and its
    /// end agree.
    func testABookAtItsEndReadsAHundredPercent() {
        XCTAssertEqual(book(at: Self.total).percentComplete, 100)
        XCTAssertEqual(book(at: Self.total + 40).percentComplete, 100)
    }

    /// A book with no saved place, or not measured yet, is not at its end:
    /// nothing says where it is.
    func testABookWithNoPlaceOrNoMeasureIsNotAtItsEnd() {
        var unplaced = book(at: Self.total)
        unplaced.readingPosition = nil
        XCTAssertFalse(unplaced.restsAtEnd, "No saved place")
        XCTAssertFalse(book(at: Self.total, total: nil).restsAtEnd, "Not measured")
        XCTAssertFalse(book(at: 0, total: 0).restsAtEnd, "Measured empty")
    }

    /// A place saved before global offsets were kept is read as the row's
    /// percent reads it: by its offset in its chapter.
    func testAPlaceWithoutAGlobalOffsetIsReadByItsOffset() {
        XCTAssertTrue(book(at: nil, chapter: 0, offset: Self.total).restsAtEnd)
        XCTAssertFalse(book(at: nil, chapter: 0, offset: Self.total - 1).restsAtEnd)
    }

    // MARK: - The Choice That Starts a Finished Book Over

    /// The end-of-book choice the user asked for on October 10, 2026, "not
    /// by default", beside Stop, Loop, and Continue to Next Book (TODO P07,
    /// question 13): its name, which both pickers list and config.json and a
    /// book's record keep, read back from either; what VoiceOver hears as
    /// Play starts a finished book over; what the Playback tab says of it;
    /// and the sleep timer's End of book hint, which says the book stops at
    /// its end anyway, as for Stop.
    func testTheChoiceThatStartsAFinishedBookOverIsNamedAndKept() {
        let name = "Stop, and Play Starts Over"
        XCTAssertEqual(EndOfBookBehavior.stopAndPlayStartsOver.rawValue, name)
        XCTAssertEqual(SettingsPolicy.endOfBookBehavior.value(fromRaw: name), .stopAndPlayStartsOver)
        XCTAssertEqual(SettingsPolicy.endOfBookBehavior.validatedConfigRawValue(name), name, "config.json refuses it")
        XCTAssertEqual(EndOfBookBehavior.effective(localRawValue: name, global: .stop), .stopAndPlayStartsOver)
        XCTAssertEqual(EndOfBookWording.startingAgain("Breakwater Survey"), "Starting again: Breakwater Survey")
        XCTAssertEqual(
            EndOfBookWording.playOnAFinishedBookCaption,
            "With \"Stop\", Play on a finished book says it is finished; "
                + "with \"Stop, and Play Starts Over\", Play starts it again from the beginning."
        )
        XCTAssertEqual(
            SleepTimerView.endOfBookHint(for: .stopAndPlayStartsOver),
            "This book already stops playing at its end, since Continue to Next Book is off; the timer stops it there too."
        )
    }

    // MARK: - Counting Books Finished

    /// Books Finished counts each book once (TODO P07; the user, October
    /// 10, 2026: "yes, only one finish per book for now"): a book counted
    /// already is not counted again, whatever ends it how many times, so
    /// the file keeps one entry for it, its first finish, with its title
    /// then, which the next launch reads back. Every end is still told
    /// (`.bookDidFinish`), as a feed item heard to its end again is marked
    /// played again.
    @MainActor
    func testBooksFinishedCountsEachBookOnce() throws {
        let file = try makeStatisticsFile()
        let service = makeStatsService(over: file)
        let (dune, emma) = (UUID(), UUID())
        var told: [UUID] = []
        let telling = NotificationCenter.default.publisher(for: .bookDidFinish, object: service).sink { notification in
            if let bookID = notification.userInfo?[ReadingStatsService.finishedBookIDKey] as? UUID {
                told.append(bookID)
            }
        }
        defer { telling.cancel() }

        XCTAssertTrue(service.markBookFinished(bookID: dune, title: "Dune"), "The first finish was not counted")
        let firstFinish = try XCTUnwrap(service.stats.finishedBooks.first?.dateFinished)
        XCTAssertFalse(service.markBookFinished(bookID: dune, title: "Dune"), "A second finish was counted")
        XCTAssertTrue(service.markBookFinished(bookID: emma, title: "Emma"), "Another book's finish was not counted")
        XCTAssertFalse(service.markBookFinished(bookID: dune, title: "Dune, Renamed"), "A finish after another book's was counted")

        XCTAssertEqual(service.stats.finishedBooks.map(\.bookID), [dune.uuidString, emma.uuidString])
        XCTAssertEqual(service.stats.finishedBooks.first?.dateFinished, firstFinish, "The first finish's date was replaced")
        XCTAssertEqual(service.stats.finishedBooks.first?.title, "Dune", "The first finish's title was replaced")
        XCTAssertEqual(told, [dune, dune, emma, dune], "Not every end was told")

        ReadingStatsService.waitForQueuedSaves()
        XCTAssertEqual(
            makeStatsService(over: file).stats.finishedBooks.map(\.bookID),
            [dune.uuidString, emma.uuidString],
            "The next launch reads another count"
        )
    }

    /// Statistics shaped like the user's, as the design note counted them on
    /// October 10, 2026, with no title or ID of theirs: 67 entries for 28
    /// books, all of 2026; 12 books counted more than once, 39 extra entries
    /// in all; the last 10 entries 2 books, one of them 9 times. The file
    /// keeps all 67 (TODO P07: "only one finish per book for now"); Books
    /// Finished All Time and This Year say 28, and by kind each book counts
    /// once; Recently Finished lists the ten books finished last, each once,
    /// newest first, each row keyed by an entry of its own, where it once
    /// listed one book nine times.
    @MainActor
    func testStatsCountTheUsersRepeatedFinishesOnce() throws {
        let service = makeStatsService(over: try makeStatisticsFile())
        let (entries, books) = try Self.usersFinishes()
        service.stats.finishedBooks = entries
        service.finishedBookKind = { _ in .text }
        let now = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 2, day: 15, hour: 12)))

        XCTAssertEqual(entries.count, 67, "The fixture is not the user's shape")
        XCTAssertEqual(Set(entries.suffix(10).map(\.bookID)).count, 2, "The fixture's last ten entries are not two books")
        XCTAssertEqual(service.stats.finishedBooks.count, 67, "The repeats were not kept in the file")

        let figures = ReadingStatsFigures(service: service, at: now)
        XCTAssertEqual(figures.booksFinishedAllTime, 28)
        XCTAssertEqual(figures.booksFinishedThisYear, 28)
        XCTAssertEqual(figures.booksFinishedAllTimeByKind, FinishedBookCounts(textBooks: 28))
        XCTAssertEqual(figures.booksFinishedThisYearByKind, FinishedBookCounts(textBooks: 28))

        let recent = service.stats.recentlyFinished()
        XCTAssertEqual(recent.map(\.bookID), books.suffix(10).reversed().map(\.uuidString), "Recently Finished lists other books")
        XCTAssertEqual(Set(recent.map(\.id)).count, recent.count, "Two rows share an identity")
        XCTAssertEqual(recent.first?.dateFinished, entries.first { $0.bookID == books[27].uuidString }?.dateFinished,
                       "The newest book is not listed by the finish counted")
    }

    // MARK: - Fixtures

    /// Finishes shaped like the user's (`testStatsCountTheUsersRepeatedFinishesOnce`):
    /// 28 books finished a day apart through January 2026; the first ten
    /// heard to their end three more times, a second apart, and the
    /// eleventh once more, as Play on a finished book replayed its end; and
    /// the newest finished nine times within nine seconds, as one book was
    /// on October 7.
    ///
    /// - Returns: The entries, oldest first, and the books in the order of
    ///   their first finishes.
    private static func usersFinishes() throws -> (entries: [FinishedBookEntry], books: [UUID]) {
        let books = (0..<28).map { _ in UUID() }
        let start = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12)))
        var entries: [FinishedBookEntry] = []
        func finish(_ book: Int, day: Int, second: Int) {
            entries.append(FinishedBookEntry(
                bookID: books[book].uuidString,
                title: "Book \(book + 1)",
                dateFinished: start.addingTimeInterval(TimeInterval(day * 86_400 + second))
            ))
        }
        for book in 0..<27 {
            finish(book, day: book, second: 0)
            let repeats = book < 10 ? 3 : (book == 10 ? 1 : 0)
            for again in 0..<repeats {
                finish(book, day: book, second: 1 + again)
            }
        }
        for second in 0..<9 {
            finish(27, day: 27, second: second)
        }
        return (entries, books)
    }

    /// A statistics file of this test's own, in a folder of its own under
    /// the hosted tests' data root, removed with everything in it when the
    /// test ends, once every queued write has landed.
    private func makeStatisticsFile() throws -> URL {
        let folder = TextMouthPaths.root.appendingPathComponent(
            "FinishedBookModelTests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock {
            ReadingStatsService.waitForQueuedSaves()
            try? FileManager.default.removeItem(at: folder)
        }
        return folder.appendingPathComponent("reading_stats.json")
    }

    /// A statistics service over `file`, as a launch makes one, whose
    /// checkpoint timer stops when the test ends.
    @MainActor
    private func makeStatsService(over file: URL) -> ReadingStatsService {
        let service = ReadingStatsService(fileURL: file)
        addTeardownBlock { @MainActor in service.shutdown() }
        return service
    }
}

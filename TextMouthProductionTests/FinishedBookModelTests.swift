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

    // MARK: - Fixtures

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

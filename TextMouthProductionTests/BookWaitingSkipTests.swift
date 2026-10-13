import XCTest
@testable import TextMouth

/// A book keeps the skipped headings that wait apart from the ones that name
/// headings (T06's branch D), and takes the places a rebuild of its text
/// moved only where it still holds them as they were.
final class BookWaitingSkipTests: XCTestCase {

    // MARK: - Fixtures

    /// A skip that waits, with words at its start, as the relocator leaves
    /// one when a rebuild found no heading for it.
    private static let waiting = SkippedHeading(
        level: 3, label: "Appendix", chapterIndex: 4, characterOffset: 120,
        anchor: TextAnchor(before: "the end of the", after: "appendix begins here", fraction: 0.5, measuredIn: "measure", version: 1)
    )

    /// A skip that names a heading, other than `waiting` in every value.
    private static let named = SkippedHeading(level: 2, label: "Notes", chapterIndex: 1, characterOffset: 40)

    /// A plain-text book holding the given skips and nothing else.
    private static func book(skipped: [SkippedHeading]? = nil, waiting: [SkippedHeading]? = nil) -> Book {
        var book = Book(
            title: "Waiting Skips", format: .txt,
            filePath: "/tmp/\(UUID().uuidString)-waiting-skips.txt", md5Hash: UUID().uuidString,
            waitingSkippedHeadings: waiting
        )
        book.setSkippedHeadings(skipped)
        return book
    }

    /// An encoder and decoder that write and read dates as the library and
    /// the package records do.
    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// `book` as a library row: written as JSON and read back.
    private static func storedAsRow(_ book: Book) throws -> Book {
        try decoder().decode(Book.self, from: encoder().encode(book))
    }

    /// `book` as a package record: its `bookInfo.json` written and read back,
    /// and the book made from the record.
    private static func storedAsRecord(_ book: Book) throws -> Book {
        let record = try decoder().decode(BookInfo.self, from: encoder().encode(book.makeBookInfo()))
        return Book(record: record, filePath: book.filePath, folderPath: book.folderPath, tmbDirectoryName: book.tmbDirectoryName)
    }

    /// The JSON object of `book` as a row, for a test to change before it is
    /// read back.
    private static func rowObject(of book: Book) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: encoder().encode(book)) as? [String: Any])
    }

    /// The JSON object of `book`'s record, with its `state` object.
    private static func recordObject(of book: Book) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: encoder().encode(book.makeBookInfo())) as? [String: Any])
    }

    // MARK: - Commit 1: Waiting Skips Stored Apart

    /// A waiting skip survives a library row, with its anchor, and stays out
    /// of the skipped IDs the reader matches.
    func testARowKeepsAWaitingSkip() throws {
        let book = Self.book(skipped: [Self.named], waiting: [Self.waiting])
        let stored = try Self.storedAsRow(book)
        XCTAssertEqual(stored.waitingSkippedHeadings, [Self.waiting])
        XCTAssertEqual(stored.skippedHeadings, [Self.named])
        XCTAssertEqual(stored.skippedHeadingIDs, [Self.named.id])
    }

    /// A waiting skip survives a package record, with its anchor, and stays
    /// out of the skipped IDs.
    func testARecordKeepsAWaitingSkip() throws {
        let book = Self.book(skipped: [Self.named], waiting: [Self.waiting])
        let stored = try Self.storedAsRecord(book)
        XCTAssertEqual(stored.waitingSkippedHeadings, [Self.waiting])
        XCTAssertEqual(stored.skippedHeadings, [Self.named])
        XCTAssertEqual(stored.skippedHeadingIDs, [Self.named.id])
    }

    /// The record's JSON, which an older build reads, never holds a waiting
    /// skip's ID among its skipped IDs, whether the book has named skips or
    /// none.
    func testTheRecordsSkippedIDsNeverHoldAWaitingSkip() throws {
        for named in [[Self.named], nil] as [[SkippedHeading]?] {
            let object = try Self.recordObject(of: Self.book(skipped: named, waiting: [Self.waiting]))
            let state = try XCTUnwrap(object["state"] as? [String: Any])
            XCTAssertEqual(state["skippedHeadingIDs"] as? [String], named.map { $0.map(\.id) })
            XCTAssertNotNil(state["waitingSkippedHeadings"], "the waiting skip itself is written")
            let ids = state["skippedHeadingIDs"] as? [String] ?? []
            XCTAssertFalse(ids.contains(Self.waiting.id))
        }
    }

    /// A row or record written without the key, or with a value under it
    /// that cannot be read, has no waiting skips, and keeps every other
    /// field.
    func testARowAndARecordWithoutReadableWaitingSkipsDecodeWithNone() throws {
        let book = Self.book(skipped: [Self.named], waiting: [Self.waiting])
        for value in [nil, "garbage", 17] as [Any?] {
            // The row.
            var row = try Self.rowObject(of: book)
            // A nil value removes the key, which is the row written without it.
            row["waitingSkippedHeadings"] = value
            let decodedRow = try Self.decoder().decode(Book.self, from: JSONSerialization.data(withJSONObject: row))
            XCTAssertNil(decodedRow.waitingSkippedHeadings, "row, \(String(describing: value))")
            XCTAssertEqual(decodedRow.skippedHeadings, [Self.named])
            XCTAssertEqual(decodedRow.title, book.title)

            // The record.
            var record = try Self.recordObject(of: book)
            var state = try XCTUnwrap(record["state"] as? [String: Any])
            state["waitingSkippedHeadings"] = value
            record["state"] = state
            let decodedRecord = try Self.decoder().decode(BookInfo.self, from: JSONSerialization.data(withJSONObject: record))
            XCTAssertNil(decodedRecord.state.waitingSkippedHeadings, "record, \(String(describing: value))")
            XCTAssertEqual(decodedRecord.state.skippedHeadings, [Self.named])
        }
    }

    /// An empty list is stored as none, never as an empty array: in the
    /// initializer, and when a row or record holding one is read.
    func testAnEmptyListIsNone() throws {
        XCTAssertNil(Self.book(waiting: []).waitingSkippedHeadings)

        var row = try Self.rowObject(of: Self.book(waiting: [Self.waiting]))
        row["waitingSkippedHeadings"] = [Any]()
        XCTAssertNil(try Self.decoder().decode(Book.self, from: JSONSerialization.data(withJSONObject: row)).waitingSkippedHeadings)

        var record = try Self.recordObject(of: Self.book(waiting: [Self.waiting]))
        var state = try XCTUnwrap(record["state"] as? [String: Any])
        state["waitingSkippedHeadings"] = [Any]()
        record["state"] = state
        XCTAssertNil(try Self.decoder().decode(BookInfo.self, from: JSONSerialization.data(withJSONObject: record)).state.waitingSkippedHeadings)
    }
}

import XCTest
@testable import TextMouth

/// `Book` holds its fields in one shared box, copied when a shared one is
/// written (audit C13). These tests pin what a plain struct promises and the
/// box must keep: copies behave as values, equality and hashing read the
/// fields, the stored JSON is exactly the fields', and a write to a book
/// nobody shares never copies its box.
final class BookBoxTests: XCTestCase {
    // MARK: - Fixtures

    /// A fixed id and date, so two books built apart can be alike.
    private static let id = UUID(uuidString: "6F0C2B1E-3D4A-4B5C-8E7F-0A1B2C3D4E5F")!
    private static let added = Date(timeIntervalSince1970: 1_700_000_000)

    /// A fixed bookmark id, so books built apart are alike.
    private static let bookmarkID = UUID(uuidString: "1A2B3C4D-0000-4000-8000-000000000001")!

    /// The IDs of two skipped headings, in the form a book keeps (`Heading.id`).
    private static let skipOne = SkippedHeading(level: 1, label: "One", chapterIndex: 0, characterOffset: 5).id
    private static let skipTwo = SkippedHeading(level: 2, label: "Two", chapterIndex: 1, characterOffset: 9).id

    /// A book with a spread of fields set (strings, optionals, an array, an
    /// enum, a nested value), built the same way every time it is called.
    private static func makeBook(title: String = "A Title") -> Book {
        var book = Book(
            id: id, title: title, author: "An Author", format: .epub, filePath: "Fiction/a.epub",
            md5Hash: String(repeating: "a", count: 32), folderPath: "Fiction", dateAdded: added,
            tmbDirectoryName: "A-Title-1.tmb"
        )
        book.bookmarks = [Bookmark(id: bookmarkID, number: 1, chapterIndex: 2, characterOffset: 30, label: "Here", dateCreated: added)]
        book.totalWordCount = 90_000
        book.epubPublisher = "A Publisher"
        book.skippedHeadingIDs = [skipOne]
        book.brailleTable = "en-ueb-g2.ctb"
        book.brailleTableOrigin = .guessed
        return book
    }

    // MARK: - Equality and Hashing

    /// Two books built apart from the same fields are equal and hash alike,
    /// so a `Set` or a dictionary keyed by a book finds one by its fields,
    /// never by which box it holds.
    func testBooksBuiltApartWithTheSameFieldsAreEqualAndHashAlike() {
        let first = Self.makeBook()
        let second = Self.makeBook()
        XCTAssertFalse(first.sharesFields(with: second), "the fixtures must hold two boxes, or this proves nothing")

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.hashValue, second.hashValue)
        XCTAssertEqual(Set([first, second]).count, 1)
    }

    /// A difference in any one field, the braille table's origin among them,
    /// makes two books unequal.
    func testBooksThatDifferInOneFieldAreNotEqual() {
        let base = Self.makeBook()
        var other = Self.makeBook()
        XCTAssertEqual(base, other)

        other.brailleTableOrigin = nil
        XCTAssertNotEqual(base, other, "the origin of the braille table is a field")

        other = Self.makeBook(title: "Another Title")
        XCTAssertNotEqual(base, other)

        other = Self.makeBook()
        other.bookmarks.removeAll()
        XCTAssertNotEqual(base, other)
    }

    // MARK: - Value Semantics

    /// Changing a copy leaves the original as it was, for a plain field, an
    /// optional, an array grown in place, and the skipped headings (whose
    /// writer also moves another field).
    func testChangingACopyLeavesTheOriginalAsItWas() {
        let original = Self.makeBook()
        let snapshot = Self.makeBook()
        var copy = original
        XCTAssertTrue(copy.sharesFields(with: original), "a copy shares its box until it is written")

        copy.title = "Changed"
        copy.lastOpened = Self.added
        copy.bookmarks.append(Bookmark(number: 2, chapterIndex: 0, characterOffset: 0, label: "Two", dateCreated: Self.added))
        copy.skippedHeadingIDs = [Self.skipOne, Self.skipTwo]
        copy.brailleTableOrigin = nil

        XCTAssertFalse(copy.sharesFields(with: original), "the write gave the copy its own box")
        XCTAssertEqual(original, snapshot, "the original is exactly what it was")
        XCTAssertEqual(original.title, "A Title")
        XCTAssertNil(original.lastOpened)
        XCTAssertEqual(original.bookmarks.count, 1)
        XCTAssertEqual(original.skippedHeadingIDs, [Self.skipOne])
        XCTAssertEqual(original.brailleTableOrigin, .guessed)

        XCTAssertEqual(copy.title, "Changed")
        XCTAssertEqual(copy.bookmarks.count, 2)
        XCTAssertEqual(copy.skippedHeadingIDs, [Self.skipOne, Self.skipTwo])
        XCTAssertNil(copy.brailleTableOrigin)
    }

    /// Writing the original after a copy was made leaves the copy as it was:
    /// the rule holds from either side.
    func testChangingTheOriginalLeavesItsCopyAsItWas() {
        var original = Self.makeBook()
        let copy = original
        original.author = "Someone Else"
        XCTAssertEqual(copy.author, "An Author")
        XCTAssertEqual(original.author, "Someone Else")
    }

    /// A write to a book whose box nothing else holds changes that box in
    /// place: copy on write costs a copy only when the box is shared.
    func testAWriteToAnUnsharedBookKeepsItsBox() {
        var book = Self.makeBook()
        let before = book.fieldsBoxIdentity
        book.title = "Written"
        book.bookmarks.removeAll()
        XCTAssertEqual(book.fieldsBoxIdentity, before)
    }

    /// Setting the skipped heading IDs keeps the headings in step with them,
    /// as the stored property's `didSet` did before the box.
    func testSettingSkippedHeadingIDsKeepsTheHeadingsInStep() {
        var book = Self.makeBook()
        XCTAssertEqual(book.skippedHeadings?.map(\.id), [Self.skipOne])
        book.skippedHeadingIDs = nil
        XCTAssertNil(book.skippedHeadings)
    }

    // MARK: - Stored Form

    /// A book survives a JSON round trip with every field, the braille
    /// table's origin included, and writes the keys a struct of these
    /// fields did (`OnDiskContractTests` pins them all).
    func testABookRoundTripsThroughJSON() throws {
        let book = Self.makeBook()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(book)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Book.self, from: data)
        XCTAssertEqual(decoded, book)

        // Every key of a plain struct of these fields is written (the bytes
        // and key set are pinned by `OnDiskContractTests`).
        let text = String(decoding: data, as: UTF8.self)
        for key in ["title", "folderPath", "brailleTable", "brailleTableOrigin", "skippedHeadingIDs"] {
            XCTAssertTrue(text.contains("\"\(key)\""), key)
        }
    }

    // MARK: - What Copying Costs

    /// Measures what the audit asked about (C13) and prints it: copying a
    /// 1,500-book array (one retain a book), and writing every book of a copy
    /// (each write copies one box). It asserts only that the work ran, since
    /// timings on a busy Mac prove nothing.
    func testCopyTimingsOf1500Books() {
        let books = (0..<1500).map { index -> Book in
            var book = Self.makeBook(title: "Title \(index) with a longer name")
            book.manualSortOrder = index
            return book
        }
        var sink = 0
        let rounds = 200

        let copyStart = DispatchTime.now().uptimeNanoseconds
        for round in 0..<rounds {
            var copy = books
            // Writing one book makes the array's own copy real.
            copy[round % 1500].title = "changed"
            sink &+= copy[(round + 1) % 1500].title.count
        }
        let copyEnd = DispatchTime.now().uptimeNanoseconds

        let writeStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<rounds {
            var copy = books
            for index in copy.indices { copy[index].manualSortOrder = -index }
            sink &+= copy.count
        }
        let writeEnd = DispatchTime.now().uptimeNanoseconds

        print("BOOKBOX copy of 1500 books: \(Double(copyEnd - copyStart) / Double(rounds) / 1000) us")
        print("BOOKBOX write to every book of a copy: \(Double(writeEnd - writeStart) / Double(rounds) / 1000) us")
        XCTAssertGreaterThan(sink, 0)
        XCTAssertEqual(books[0].manualSortOrder, 0, "writing the copies never touched the originals")
    }
}

// MARK: - Looking Inside the Box

extension Book {
    /// A mirror of the fields a book holds: a book has one stored property,
    /// its box, so reflecting the book finds the box and reflecting the box
    /// finds the fields (in the order they are declared). The tests that
    /// name every field of a book (`OnDiskContractTests`,
    /// `ContentAnalysisMergeTests`) read them through this.
    var reflectedFields: Mirror {
        let box = Mirror(reflecting: self).children.first
        precondition(box?.label == "storage", "Book's one stored property is its box")
        return Mirror(reflecting: box!.value)
    }

    /// Which box this book holds, to tell whether a write copied it.
    fileprivate var fieldsBoxIdentity: ObjectIdentifier {
        ObjectIdentifier(Mirror(reflecting: self).children.first!.value as AnyObject)
    }

    /// Whether this book and `other` hold the very same box: true for a
    /// copy that nothing has written since.
    fileprivate func sharesFields(with other: Book) -> Bool {
        fieldsBoxIdentity == other.fieldsBoxIdentity
    }
}

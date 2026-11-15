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

    // MARK: - Guards: Every Field Is Compared and Copied

    /// One edit for each stored field of a book: sets that field of the first
    /// book to the second's value and nothing else. `id` is a `let`, so its
    /// edit is made through the stored form. A new field of `Book` must be
    /// added here: `testTheEditsNameEveryField` fails until it is.
    private static var fieldEdits: [(name: String, apply: (inout Book, Book) -> Void)] { [
        ("id", { book, other in book = bookWithID(of: other, in: book) }),
            ("title", { $0.title = $1.title }),
            ("author", { $0.author = $1.author }),
            ("format", { $0.format = $1.format }),
            ("filePath", { $0.filePath = $1.filePath }),
            ("md5Hash", { $0.md5Hash = $1.md5Hash }),
            ("folderPath", { $0.folderPath = $1.folderPath }),
            ("dateAdded", { $0.dateAdded = $1.dateAdded }),
            ("lastOpened", { $0.lastOpened = $1.lastOpened }),
            ("readingPosition", { $0.readingPosition = $1.readingPosition }),
            ("bookmarks", { $0.bookmarks = $1.bookmarks }),
            ("totalWordCount", { $0.totalWordCount = $1.totalWordCount }),
            ("totalCharacterCount", { $0.totalCharacterCount = $1.totalCharacterCount }),
            ("tmbDirectoryName", { $0.tmbDirectoryName = $1.tmbDirectoryName }),
            ("sourceFilePath", { $0.sourceFilePath = $1.sourceFilePath }),
            ("lastPlaybackStarted", { $0.lastPlaybackStarted = $1.lastPlaybackStarted }),
            ("lastPlaybackStopped", { $0.lastPlaybackStopped = $1.lastPlaybackStopped }),
            ("localVoiceID", { $0.localVoiceID = $1.localVoiceID }),
            ("localWPM", { $0.localWPM = $1.localWPM }),
            ("localPitch", { $0.localPitch = $1.localPitch }),
            ("skippedHeadingIDs", { $0.skippedHeadingIDs = $1.skippedHeadingIDs }),
            ("skippedHeadings", { $0.setSkippedHeadings($1.skippedHeadings) }),
            ("waitingSkippedHeadings", { $0.waitingSkippedHeadings = $1.waitingSkippedHeadings }),
            ("localEndOfBookBehavior", { $0.localEndOfBookBehavior = $1.localEndOfBookBehavior }),
            ("localSkipForwardUnit", { $0.localSkipForwardUnit = $1.localSkipForwardUnit }),
            ("localSkipBackwardUnit", { $0.localSkipBackwardUnit = $1.localSkipBackwardUnit }),
            ("manualSortOrder", { $0.manualSortOrder = $1.manualSortOrder }),
            ("audioDuration", { $0.audioDuration = $1.audioDuration }),
            ("audioAlbum", { $0.audioAlbum = $1.audioAlbum }),
            ("audioGenre", { $0.audioGenre = $1.audioGenre }),
            ("audioYear", { $0.audioYear = $1.audioYear }),
            ("epubPublisher", { $0.epubPublisher = $1.epubPublisher }),
            ("epubPublicationDate", { $0.epubPublicationDate = $1.epubPublicationDate }),
            ("epubISBN", { $0.epubISBN = $1.epubISBN }),
            ("epubLanguage", { $0.epubLanguage = $1.epubLanguage }),
            ("epubIdentifier", { $0.epubIdentifier = $1.epubIdentifier }),
            ("epubVersion", { $0.epubVersion = $1.epubVersion }),
            ("cacheFormatVersion", { $0.cacheFormatVersion = $1.cacheFormatVersion }),
            ("contentIndexVersion", { $0.contentIndexVersion = $1.contentIndexVersion }),
            ("textCacheFingerprint", { $0.textCacheFingerprint = $1.textCacheFingerprint }),
            ("editedText", { $0.editedText = $1.editedText }),
            ("pageReaderVersion", { $0.pageReaderVersion = $1.pageReaderVersion }),
            ("metadataReaderVersion", { $0.metadataReaderVersion = $1.metadataReaderVersion }),
            ("handEdits", { $0.handEdits = $1.handEdits }),
            ("feedLink", { $0.feedLink = $1.feedLink }),
            ("brailleTable", { $0.brailleTable = $1.brailleTable }),
            ("brailleTableVersion", { $0.brailleTableVersion = $1.brailleTableVersion }),
            ("brailleTableOrigin", { $0.brailleTableOrigin = $1.brailleTableOrigin }),
            ("brailleFileCode", { $0.brailleFileCode = $1.brailleFileCode }),
            ("textEncoding", { $0.textEncoding = $1.textEncoding }),
            ("textEncodingSource", { $0.textEncodingSource = $1.textEncodingSource }),
            // The keys a later TextMouth added to the row (V04).
            ("unknownKeys", { $0.unknownKeys = $1.unknownKeys }),
    ] }

    /// `book` with `other`'s id, made through its JSON (the id is a `let`).
    private static func bookWithID(of other: Book, in book: Book) -> Book {
        do {
            let data = try JSONEncoder().encode(book)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object["id"] = other.id.uuidString
            return try JSONDecoder().decode(Book.self, from: JSONSerialization.data(withJSONObject: object))
        } catch {
            XCTFail("could not change a book's id: \(error)")
            return book
        }
    }

    /// The edits cover exactly the fields the box holds, so a field added to
    /// `Book` is added to the two guards below too.
    func testTheEditsNameEveryField() {
        let edited = Self.fieldEdits.map(\.name)
        let held = ContentAnalysisMergeTests.bookWithEveryFieldSet(seed: 1).reflectedFields.children.compactMap(\.label)
        XCTAssertEqual(edited.count, held.count)
        XCTAssertEqual(Set(edited), Set(held))
    }

    /// `==` compares every field: change any one field of a book to another
    /// value and the two are no longer equal. A comparison that forgot a
    /// field would call the pair equal.
    func testEqualityComparesEveryField() {
        let base = ContentAnalysisMergeTests.bookWithEveryFieldSet(seed: 1)
        let other = ContentAnalysisMergeTests.bookWithEveryFieldSet(seed: 2)
        XCTAssertEqual(base, base)
        for (name, apply) in Self.fieldEdits {
            var changed = base
            apply(&changed, other)
            XCTAssertNotEqual(changed, base, "== ignores \(name)")
            XCTAssertNotEqual(base, changed, "== ignores \(name)")
        }
    }

    /// Copying the box keeps every field: write one unrelated field of a
    /// copy that shares its box, and every other field, the eight an
    /// analysis owns among them, is what the original holds.
    func testCopyOnWriteKeepsEveryOtherField() {
        let original = ContentAnalysisMergeTests.bookWithEveryFieldSet(seed: 1)
        var copy = original
        XCTAssertTrue(copy.sharesFields(with: original))
        copy.title = "Written after the copy"
        XCTAssertFalse(copy.sharesFields(with: original), "the write must have copied the box")

        let differing = Set(ContentAnalysisMergeTests.fieldsThatDiffer(original, copy))
        XCTAssertEqual(differing, ["title"])
        // The analysis fields were compared, and found as they were.
        let compared = Set(original.reflectedFields.children.compactMap(\.label))
        XCTAssertTrue(ContentAnalysisMergeTests.analysisFieldNames.isSubset(of: compared))
        XCTAssertTrue(differing.isDisjoint(with: ContentAnalysisMergeTests.analysisFieldNames))
        XCTAssertEqual(original.title, "Title 1")
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

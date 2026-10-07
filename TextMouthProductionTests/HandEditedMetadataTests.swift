import XCTest
@testable import TextMouth

/// The record of which metadata fields the user edited by hand
/// (`Book.handEdits`): the fields it names, how a row and a package record
/// keep and code it, and how a save records what it changed.
final class HandEditedMetadataTests: XCTestCase {

    // MARK: - The Fields

    /// The fields of a record are listed in the order the editors show
    /// them, each once, whatever order they were marked in.
    func testFieldsAreListedAsTheEditorsShowThem() {
        XCTAssertEqual(Book.MetadataField.ordered([.audioYear, .title, .publisher]), [.title, .publisher, .audioYear])
        XCTAssertEqual(Book.MetadataField.ordered([]), [])
        XCTAssertEqual(Book.MetadataField.ordered(Set(Book.MetadataField.allCases)), Book.MetadataField.allCases)
        XCTAssertEqual(Book.MetadataField.refreshable, [.title, .author, .publisher, .publicationDate])
    }

    /// Each field reads its own value of a book, a field the book keeps
    /// none of reading as none, and sets its own value and nothing else.
    func testEachFieldReadsAndSetsItsOwnValue() {
        var book = Self.makeBook()
        XCTAssertEqual(
            Book.MetadataField.values(in: book.editableMetadata),
            [.title: "Tide Tables", .author: "Port Authority"],
            "an EPUB with no publisher, date, album, genre, or year kept has values for its names alone"
        )

        for (number, field) in Book.MetadataField.allCases.enumerated() {
            field.set("Value \(number)", in: &book)
        }

        XCTAssertEqual(book.title, "Value 0")
        XCTAssertEqual(book.author, "Value 1")
        XCTAssertEqual(book.epubPublisher, "Value 2")
        XCTAssertEqual(book.epubPublicationDate, "Value 3")
        XCTAssertEqual(book.audioAlbum, "Value 4")
        XCTAssertEqual(book.audioGenre, "Value 5")
        XCTAssertEqual(book.audioYear, "Value 6")
        for (number, field) in Book.MetadataField.allCases.enumerated() {
            XCTAssertEqual(field.value(in: book.editableMetadata), "Value \(number)", "\(field)")
        }
        XCTAssertEqual(book.md5Hash, "hash", "only the fields change")
    }

    /// The values an EPUB editor and an audio editor open with or save, by
    /// field: the EPUB editor's four, and the audio editor's five with its
    /// artist as the author.
    func testTheEditorsValuesByField() {
        let epub = EPUBMetadata(
            title: "Tide Tables", author: "Port Authority", publisher: "Tollgate Press", publicationDate: "2026",
            isbn: "isbn", language: "en", identifier: "id", epubVersion: "3.0"
        )
        XCTAssertEqual(
            Book.MetadataField.values(in: epub),
            [.title: "Tide Tables", .author: "Port Authority", .publisher: "Tollgate Press", .publicationDate: "2026"]
        )

        let audio = AudioMetadata(
            title: "Soundings", artist: "Harbour Survey", album: "Coastal Series", genre: "Field Recording", year: "2024",
            duration: "1:00", fileFormat: "WAV"
        )
        XCTAssertEqual(
            Book.MetadataField.values(in: audio),
            [.title: "Soundings", .author: "Harbour Survey", .audioAlbum: "Coastal Series", .audioGenre: "Field Recording", .audioYear: "2024"]
        )
    }

    /// The fields that differ between what an editor opened with and what
    /// it saved: a changed value, and a value only one side has; not a
    /// value both sides share, nor a field neither has.
    func testTheFieldsThatDifferAreTheOnesASaveChanged() {
        let opened: Book.MetadataValues = [.title: "Tide Tables", .author: "Port Authority", .publisher: "Tollgate Press"]
        let saved: Book.MetadataValues = [.title: "Tide Tables", .author: "Harbour Survey", .publicationDate: "2026"]

        XCTAssertEqual(Book.MetadataField.fieldsThatDiffer(between: opened, and: saved), [.author, .publisher, .publicationDate])
        XCTAssertEqual(Book.MetadataField.fieldsThatDiffer(between: opened, and: opened), [])
        XCTAssertEqual(Book.MetadataField.fieldsThatDiffer(between: [:], and: [:]), [])
    }

    // MARK: - The Record

    /// A new book has no record. Marking a field begins one, kept from
    /// that edit on; marking more adds to it and never removes a field;
    /// marking nothing changes nothing; and a record kept since the import
    /// stays one.
    func testMarkingBeginsAndGrowsTheRecord() {
        var book = Self.makeBook()
        XCTAssertNil(book.handEdits, "nothing has recorded a new book's edits")

        book.markEditedByHand([])
        XCTAssertNil(book.handEdits, "a save that changed nothing records nothing")

        book.markEditedByHand([.author])
        XCTAssertEqual(book.handEdits, Book.HandEdits(fields: [.author], sinceImport: false))

        book.markEditedByHand([.title, .author])
        XCTAssertEqual(book.handEdits?.fields, [.title, .author])
        XCTAssertEqual(book.handEdits?.sinceImport, false, "a record begun by an edit stays one begun by an edit")
        XCTAssertTrue(book.handEdits?.contains(.title) == true)
        XCTAssertFalse(book.handEdits?.contains(.publisher) == true)

        var imported = Self.makeBook()
        imported.handEdits = .noneSinceImport
        imported.markEditedByHand([.publicationDate])
        XCTAssertEqual(imported.handEdits, Book.HandEdits(fields: [.publicationDate], sinceImport: true))
    }

    /// A record is written as the same bytes whatever order its fields
    /// were marked in, and reads back equal to what was written.
    func testARecordIsWrittenAsTheSameBytesWhateverTheOrderOfItsEdits() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var markedLate = Book.HandEdits(fields: [.audioYear], sinceImport: true)
        markedLate.mark([.title, .publisher])
        let markedAtOnce = Book.HandEdits(fields: [.publisher, .title, .audioYear], sinceImport: true)

        let bytes = try encoder.encode(markedLate)

        XCTAssertEqual(bytes, try encoder.encode(markedAtOnce))
        XCTAssertEqual(
            String(decoding: bytes, as: UTF8.self),
            #"{"fields":["title","publisher","audioYear"],"sinceImport":true}"#
        )
        XCTAssertEqual(try JSONDecoder().decode(Book.HandEdits.self, from: bytes), markedAtOnce)
    }

    /// A record that names a field this version cannot edit, as a newer
    /// version of TextMouth may write, decodes without that field rather
    /// than failing; a record without `sinceImport` counts as begun by an
    /// edit.
    func testARecordWithAnUnknownFieldDecodesWithoutIt() throws {
        let newer = Data(#"{"fields":["narrator","title"],"sinceImport":true}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(Book.HandEdits.self, from: newer),
            Book.HandEdits(fields: [.title], sinceImport: true)
        )

        let bare = Data(#"{"fields":["author"]}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(Book.HandEdits.self, from: bare),
            Book.HandEdits(fields: [.author], sinceImport: false)
        )
    }

    // MARK: - The Row

    /// A row keeps its record through library.json; a row saved before
    /// edits were recorded loads with none; and a row whose record cannot
    /// be read loads with none instead of failing the library.
    func testARowKeepsItsRecordThroughTheLibraryIndex() throws {
        var book = Self.makeBook()
        book.markEditedByHand([.title, .publisher])

        let row = try Self.jsonObject(of: book)
        XCTAssertEqual(
            row["handEdits"] as? NSDictionary,
            ["fields": ["title", "publisher"], "sinceImport": false]
        )
        XCTAssertEqual(try Self.decode(Book.self, from: row), book)

        var older = row
        older.removeValue(forKey: "handEdits")
        XCTAssertNil(try Self.decode(Book.self, from: older).handEdits)

        var damaged = row
        damaged["handEdits"] = "edited"
        XCTAssertNil(try Self.decode(Book.self, from: damaged).handEdits)
    }

    /// The editable metadata carries the record, so a reader's copy that
    /// takes a row's editable metadata, or its library fields, takes the
    /// record with it.
    func testTheEditableMetadataCarriesTheRecord() {
        var row = Self.makeBook()
        row.markEditedByHand([.author])
        var copy = Self.makeBook()
        XCTAssertNil(copy.handEdits)

        copy.applyEditableMetadata(from: row)
        XCTAssertEqual(copy.handEdits, row.handEdits)

        var another = Self.makeBook()
        another.libraryFields = row.libraryFields
        XCTAssertEqual(another.handEdits, row.handEdits)
    }

    // MARK: - The Package Record

    /// The record goes into bookInfo.json's metadata and comes back on a
    /// book rebuilt from it; a record written before edits were recorded
    /// gives none.
    func testThePackageRecordKeepsIt() throws {
        var book = Self.makeBook()
        book.markEditedByHand([.publicationDate])

        let info = book.makeBookInfo()
        XCTAssertEqual(info.metadata.handEdits, book.handEdits)
        let rebuilt = Book(record: info, filePath: book.filePath, folderPath: book.folderPath, tmbDirectoryName: book.tmbDirectoryName)
        XCTAssertEqual(rebuilt.handEdits, book.handEdits)

        var older = try Self.jsonObject(of: info.metadata)
        older.removeValue(forKey: "handEdits")
        XCTAssertNil(try Self.decode(BookMetadata.self, from: older).handEdits)
    }

    // MARK: - Fixtures

    /// An EPUB row as an import lists one: named, with nothing else kept.
    static func makeBook() -> Book {
        Book(
            title: "Tide Tables",
            author: "Port Authority",
            format: .epub,
            filePath: "/nowhere/Tide Tables.tmb/tide.epub",
            md5Hash: "hash",
            tmbDirectoryName: "Tide Tables.tmb"
        )
    }

    /// `value` as JSON, as an object.
    static func jsonObject(of value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// `object` decoded as a `T`.
    static func decode<T: Decodable>(_ type: T.Type, from object: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: try JSONSerialization.data(withJSONObject: object))
    }
}

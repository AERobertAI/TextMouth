import XCTest
@testable import TextMouth

/// library.json keeps what a newer TextMouth wrote (V03): a row it cannot
/// read stays in the file, exactly as it was, and a sort field it does not
/// know is written back as it was, so going back to this version never
/// loses a library.
final class NewerLibraryRowsTests: XCTestCase {

    // MARK: - JSONValue

    /// Decodes `json` (a complete JSON text) as a `JSONValue`.
    private func decodeValue(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    /// Encodes `value` as the text it is written as, with sorted keys so the
    /// text is the same every time.
    private func encodedText(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    /// A value holding every case survives encoding and decoding unchanged.
    /// The top level is an array, which every JSON reader accepts.
    func testAValueHoldingEveryCaseRoundTrips() throws {
        let value = JSONValue.array([
            .object([
                "nothing": .null,
                "flag": .bool(false),
                "whole": .integer(-7),
                "fraction": .number(2.5),
                "text": .string("héllo \"quoted\""),
                "list": .array([.integer(1), .string("two"), .null]),
                "inner": .object(["deep": .array([])]),
            ]),
        ])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
    }

    /// A whole number stays an integer: it is read as one and written back
    /// as `3`, never `3.0`.
    func testAWholeNumberStaysAnInteger() throws {
        XCTAssertEqual(try decodeValue("3"), .integer(3))
        XCTAssertEqual(try encodedText(.integer(3)), "3")
    }

    /// A number with a fraction is a number, written back with its fraction.
    func testANumberWithAFractionStaysANumber() throws {
        XCTAssertEqual(try decodeValue("2.5"), .number(2.5))
        XCTAssertEqual(try encodedText(.number(2.5)), "2.5")
    }

    /// `1` and `0` are integers, never bools: a row's counts must not come
    /// back as `true` and `false`.
    func testOneAndZeroAreIntegersNotBools() throws {
        XCTAssertEqual(try decodeValue("1"), .integer(1))
        XCTAssertEqual(try decodeValue("0"), .integer(0))
        XCTAssertEqual(try encodedText(.integer(1)), "1")
        XCTAssertEqual(try encodedText(.integer(0)), "0")
    }

    /// `true` is a bool, never an integer, and `false` likewise.
    func testABoolIsNeverAnInteger() throws {
        XCTAssertEqual(try decodeValue("true"), .bool(true))
        XCTAssertEqual(try decodeValue("false"), .bool(false))
        XCTAssertEqual(try encodedText(.bool(true)), "true")
    }

    /// An ISO 8601 date is only text here, and stays the string it was.
    func testADateStaysTheStringItWas() throws {
        let value = try decodeValue("\"2026-10-23T04:20:00Z\"")
        XCTAssertEqual(value, .string("2026-10-23T04:20:00Z"))
        XCTAssertEqual(value.stringValue, "2026-10-23T04:20:00Z")
    }

    /// The convenience members read an object's member and a string, and
    /// give nil for anything else.
    func testTheConvenienceMembersGiveNilForTheWrongKind() throws {
        let object = try decodeValue("{\"id\": \"abc\", \"count\": 2}")
        XCTAssertEqual(object["id"], .string("abc"))
        XCTAssertNil(object["missing"])
        XCTAssertNil(object["count"]?.stringValue)
        XCTAssertNil(JSONValue.array([])["id"])
        XCTAssertNil(JSONValue.null.stringValue)
    }

    /// A value nested 100 arrays deep is refused with an error, not decoded
    /// and not trapped on.
    func testAValueNestedTooDeeplyThrows() {
        let json = String(repeating: "[", count: 100) + String(repeating: "]", count: 100)
        XCTAssertThrowsError(try decodeValue(json)) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                return XCTFail("expected dataCorrupted, got \(error)")
            }
            XCTAssertTrue(context.debugDescription.contains("\(JSONValue.maximumDepth)"))
        }
    }

    /// Objects nested too deeply are refused the same way.
    func testObjectsNestedTooDeeplyThrow() {
        let json = String(repeating: "{\"a\":", count: 100) + "1" + String(repeating: "}", count: 100)
        XCTAssertThrowsError(try decodeValue(json))
    }

    /// A value nested 30 arrays deep is within the limit and decodes.
    func testAValueNestedThirtyDeepDecodes() throws {
        let json = String(repeating: "[", count: 30) + String(repeating: "]", count: 30)
        var value = try decodeValue(json)
        var depth = 0
        while case .array(let items) = value, let first = items.first {
            value = first
            depth += 1
        }
        XCTAssertEqual(depth, 29)
    }

    // MARK: - Rows a newer TextMouth wrote

    /// A book with a fixed date, so what is written and read back compares
    /// equal (library.json keeps dates to the second).
    private func makeBook(_ title: String) -> Book {
        Book(
            title: title,
            format: .txt,
            filePath: "/tmp/\(title).txt",
            md5Hash: "hash-\(title)",
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
            tmbDirectoryName: "\(title).tmb"
        )
    }

    /// Decodes library.json's text the way the service reads it.
    private func decodeLibrary(_ data: Data) throws -> Library {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Library.self, from: data)
    }

    /// The JSON object (as `JSONSerialization` reads it) of library.json's
    /// text, so a test compares what was written without caring for spacing.
    private func jsonObject(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    /// A library.json holding books A and B, with raw rows between and
    /// around them, and the root folder sorted by a field this version
    /// does not know, built from a real encoded library.
    private struct RowsFixture {
        let bookA: Book
        let bookB: Book
        /// The text of the file: A, `futureFormat`, `noTitle`, then B.
        let data: Data
        /// A's row with a new id, a new package name, and format `fb2`.
        let futureFormat: [String: Any]
        /// B's row with a new id and no title.
        let noTitle: [String: Any]
        /// A's and B's rows as the encoded library wrote them.
        let rowA: [String: Any]
        let rowB: [String: Any]
    }

    /// Builds the fixture: a real encoded library of A and B, with the raw
    /// rows inserted into its `books` array with `JSONSerialization`.
    private func makeRowsFixture() throws -> RowsFixture {
        let bookA = makeBook("A")
        let bookB = makeBook("B")
        let encoded = try LibraryPersistenceService.encodedIndex(Library(books: [bookA, bookB]))
        var root = try jsonObject(encoded)
        let rows = try XCTUnwrap(root["books"] as? [[String: Any]])
        // No subscript: a library that wrote another number of rows fails
        // here, not by trapping.
        XCTAssertEqual(rows.count, 2)
        let rowA = try XCTUnwrap(rows.first)
        let rowB = try XCTUnwrap(rows.last)

        var futureFormat = rowA
        futureFormat["id"] = UUID().uuidString
        futureFormat["tmbDirectoryName"] = "Future.tmb"
        futureFormat["format"] = "fb2"
        var noTitle = rowB
        noTitle["id"] = UUID().uuidString
        noTitle.removeValue(forKey: "title")

        root["books"] = [rowA, futureFormat, noTitle, rowB]
        root["folderSortSettings"] = ["": ["sortField": "pages", "sortAscending": false]]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return RowsFixture(
            bookA: bookA, bookB: bookB, data: data,
            futureFormat: futureFormat, noTitle: noTitle, rowA: rowA, rowB: rowB
        )
    }

    /// A library with rows it cannot read opens with the rest: the books it
    /// can read are all there, in order, the other rows are kept in order
    /// with their ids and package names readable, and the sort field it does
    /// not know reads as the default. The row after an unreadable one is
    /// read, which proves a failed decode leaves the container on its row.
    func testALibraryWithRowsItCannotReadOpensWithTheRest() throws {
        let fixture = try makeRowsFixture()

        let library = try decodeLibrary(fixture.data)

        XCTAssertEqual(library.books.map(\.id), [fixture.bookA.id, fixture.bookB.id])
        XCTAssertEqual(library.unreadableRows.count, 2)
        XCTAssertEqual(library.unreadableRows.map(\.id), [
            UUID(uuidString: fixture.futureFormat["id"] as? String ?? ""),
            UUID(uuidString: fixture.noTitle["id"] as? String ?? ""),
        ])
        XCTAssertEqual(library.unreadableRows.map(\.tmbDirectoryName), ["Future.tmb", "B.tmb"])
        XCTAssertEqual(library.unreadableRows.map(\.folderPath), ["", ""])
        XCTAssertEqual(library.folderSortSettings[""]?.sortField, FolderSortSetting.defaultSort.sortField)
        XCTAssertEqual(library.folderSortSettings[""]?.sortAscending, false)
    }

    /// What was decoded is written back as it was: the books as encoded,
    /// then the raw rows, equal to the originals, and the unknown sort field
    /// with its direction. Reading that and writing it again changes nothing.
    func testTheRowsItCannotReadAreWrittenBackUnchanged() throws {
        let fixture = try makeRowsFixture()

        let written = try LibraryPersistenceService.encodedIndex(decodeLibrary(fixture.data))
        let root = try jsonObject(written)

        let rows = try XCTUnwrap(root["books"] as? [NSDictionary])
        // Whole arrays are compared, so no row is indexed: A and B as
        // encoded, then the two raw rows as they were.
        XCTAssertEqual(rows, [
            fixture.rowA as NSDictionary,
            fixture.rowB as NSDictionary,
            fixture.futureFormat as NSDictionary,
            fixture.noTitle as NSDictionary,
        ])
        let folderSorts = try XCTUnwrap(root["folderSortSettings"] as? [String: [String: Any]])
        XCTAssertEqual(folderSorts[""]?["sortField"] as? String, "pages")
        XCTAssertEqual(folderSorts[""]?["sortAscending"] as? Bool, false)

        let writtenAgain = try LibraryPersistenceService.encodedIndex(decodeLibrary(written))
        XCTAssertEqual(try jsonObject(writtenAgain) as NSDictionary, root as NSDictionary)
    }

    /// The shape library.json had before rows could be kept: its four keys,
    /// with the books as one array. A test builds the same library through
    /// this and through `Library`, to prove the bytes did not change.
    private struct EncodingBeforeKeptRows: Encodable {
        let books: [Book]
        let folders: [BookFolder]
        let folderSortSettings: [String: FolderSortSetting]
        let readingList: ReadingList
    }

    /// A library with no row it cannot read, and only sort fields it knows,
    /// is written byte for byte as it was before rows could be kept. The
    /// bytes it was written as are made here from the same library through
    /// the old shape (`EncodingBeforeKeptRows`: the books as one array),
    /// with the same encoder settings the service uses.
    func testALibraryOfReadableRowsEncodesAsBefore() throws {
        let sorts: [String: FolderSortSetting] = [
            "": FolderSortSetting(sortField: .author, sortAscending: false, rememberedDirections: [.title: true]),
            "Novels": FolderSortSetting(sortField: .manual, sortAscending: true),
        ]
        let library = Library(
            books: [makeBook("A"), makeBook("B")],
            folderSortSettings: sorts
        )
        XCTAssertTrue(library.unreadableRows.isEmpty)

        let before = EncodingBeforeKeptRows(
            books: library.libraryBooks,
            folders: library.folders,
            folderSortSettings: library.folderSortSettings,
            readingList: library.readingList
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601

        XCTAssertEqual(try LibraryPersistenceService.encodedIndex(library), try encoder.encode(before))
    }

    /// A sort field chosen after one a newer TextMouth saved replaces it:
    /// the unknown name is no longer written.
    func testAKnownSortChosenAfterwardReplacesTheUnknownOne() throws {
        let saved = Data("{\"sortField\":\"pages\",\"sortAscending\":false}".utf8)
        var setting = try JSONDecoder().decode(FolderSortSetting.self, from: saved)
        XCTAssertEqual(setting.sortField, FolderSortSetting.defaultSort.sortField)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(setting)) as? NSDictionary,
                       ["sortField": "pages", "sortAscending": false] as NSDictionary)

        setting.sortField = .author

        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(setting)) as? NSDictionary
        XCTAssertEqual(written, ["sortField": "Author", "sortAscending": false] as NSDictionary)
        XCTAssertEqual(setting, FolderSortSetting(sortField: .author, sortAscending: false))
    }

    /// A setting read as an unknown field is not equal to the default one:
    /// they are written differently.
    func testASettingWithAnUnknownFieldDiffersFromTheDefault() throws {
        let saved = Data("{\"sortField\":\"pages\",\"sortAscending\":true}".utf8)
        let setting = try JSONDecoder().decode(FolderSortSetting.self, from: saved)
        XCTAssertNotEqual(setting, FolderSortSetting.defaultSort)
    }

    /// A row nested 100 arrays deep refuses the library: decoding throws and
    /// nothing traps.
    func testARowNestedTooDeeplyRefusesTheLibrary() throws {
        let fixture = try makeRowsFixture()
        var root = try jsonObject(fixture.data)
        // 100 arrays inside one another, built from the inside out.
        var deep: Any = [Any]()
        for _ in 1..<100 {
            deep = [deep]
        }
        root["books"] = [fixture.rowA, deep]
        let data = try JSONSerialization.data(withJSONObject: root)

        XCTAssertThrowsError(try decodeLibrary(data))
    }

    /// The rows kept are not books: the library's list of its own books and
    /// its count leave them out, and so does `books`.
    func testTheRowsKeptAreNotCounted() throws {
        let library = try decodeLibrary(makeRowsFixture().data)

        XCTAssertEqual(library.unreadableRows.count, 2)
        XCTAssertEqual(library.libraryBooks.count, 2)
        XCTAssertEqual(library.libraryBookCount, 2)
        XCTAssertEqual(library.books.count, 2)
    }

    // MARK: - What the user is told

    /// The sentence Storage settings show: nothing for none, the singular
    /// for one, and the plural with the number for any other count. Each is
    /// pinned exactly, since a VoiceOver user hears it.
    func testTheSentenceForTheBooksNeedingANewerTextMouth() {
        XCTAssertNil(StorageLocationWording.booksNeedingNewerTextMouth(0))
        XCTAssertEqual(
            StorageLocationWording.booksNeedingNewerTextMouth(1),
            "1 book in this library needs a newer version of TextMouth. It is kept as it is, but not shown."
        )
        XCTAssertEqual(
            StorageLocationWording.booksNeedingNewerTextMouth(3),
            "3 books in this library need a newer version of TextMouth. They are kept as they are, but not shown."
        )
    }

    /// The model counts the rows its library keeps, and none when it keeps none.
    @MainActor
    func testTheModelCountsTheRowsItKeeps() throws {
        let model = LibraryViewModel()
        model.library = Library()
        XCTAssertEqual(model.booksNeedingNewerTextMouth, 0)

        model.library = try decodeLibrary(makeRowsFixture().data)

        XCTAssertEqual(model.booksNeedingNewerTextMouth, 2)
    }
}

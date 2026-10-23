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

    // MARK: - Walks of the packages

    /// A scratch folder for one test, removed after it with everything in it.
    private func makeScratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("NewerLibraryRows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// Captures the hosted test root's library index and puts it back after
    /// the test, for a test that saves or recovers the index there.
    private func captureLibraryIndex() throws -> LibraryIndexSandbox {
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        return sandbox
    }

    /// Where the package of `book` is in the library folder
    /// `libraryDirectory`.
    private func packageURL(of book: Book, in libraryDirectory: URL) -> URL {
        let folder = book.folderPath.isEmpty
            ? libraryDirectory
            : libraryDirectory.appendingPathComponent(book.folderPath, isDirectory: true)
        return folder.appendingPathComponent(book.tmbDirectoryName, isDirectory: true)
    }

    /// Writes a real package, as an import leaves one, into the library
    /// folder `folder` ("" for the top) of `libraryDirectory`: a book file, a
    /// content.md, and a readable bookInfo.json. Returns the book it holds.
    /// The package is removed after the test, which matters for one in the
    /// hosted test root's library.
    private func writePackage(title: String, folder: String = "", in libraryDirectory: URL) throws -> Book {
        let name = "NewerRows-\(UUID().uuidString).tmb"
        let folderURL = folder.isEmpty
            ? libraryDirectory
            : libraryDirectory.appendingPathComponent(folder, isDirectory: true)
        let package = folderURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: package) }
        let content = package.appendingPathComponent("book.txt")
        try Data("Words of \(title), \(UUID().uuidString).".utf8).write(to: content)
        try Data("# \(title)\n".utf8).write(to: package.appendingPathComponent("content.md"))
        let book = Book(
            title: title,
            author: "Test Fixture",
            format: .txt,
            filePath: content.path,
            md5Hash: "hash-\(UUID().uuidString)",
            folderPath: folder,
            tmbDirectoryName: name
        )
        try book.makeBookInfo().save(to: package)
        return book
    }

    /// Every file and folder in `package` by its path inside it, each file
    /// with its bytes. Equal snapshots show nothing was added, removed, or
    /// changed.
    private func snapshot(of package: URL) throws -> [String: Data] {
        var entries: [String: Data] = [:]
        let walk = FileManager.default.enumerator(atPath: package.path)
        while let path = walk?.nextObject() as? String {
            if (walk?.fileAttributes?[.type] as? FileAttributeType) == .typeDirectory {
                entries[path + "/"] = Data()
            } else {
                entries[path] = try Data(contentsOf: package.appendingPathComponent(path))
            }
        }
        return entries
    }

    /// A package on disk whose row library.json keeps unshown.
    private struct KeptPackage {
        /// The book that wrote the package, as this version reads it.
        let book: Book
        /// The package's folder.
        let package: URL
        /// The row library.json holds for it: that book's, in a format this
        /// version does not know (`fb2`), so it is kept, not read.
        let row: UnreadableLibraryRow
        /// The package's files before any walk.
        let before: [String: Data]
    }

    /// Writes a package into the library folder `folder` of `libraryDirectory`
    /// and the row that keeps it: the book's own row with its format changed,
    /// read back through the library so it really is a kept row.
    private func makeKeptPackage(folder: String = "", in libraryDirectory: URL) throws -> KeptPackage {
        let book = try writePackage(title: "Kept Book", folder: folder, in: libraryDirectory)
        var root = try jsonObject(LibraryPersistenceService.encodedIndex(Library(books: [book])))
        var rows = try XCTUnwrap(root["books"] as? [[String: Any]])
        // No subscript: another number of rows fails here, not by trapping.
        XCTAssertEqual(rows.count, 1)
        guard rows.count == 1 else { throw CocoaError(.fileReadCorruptFile) }
        rows[0]["format"] = "fb2"
        root["books"] = rows
        let read = try decodeLibrary(JSONSerialization.data(withJSONObject: root))
        XCTAssertEqual(read.unreadableRows.count, 1)
        XCTAssertTrue(read.books.isEmpty)
        let kept = try XCTUnwrap(read.unreadableRows.first)
        let package = packageURL(of: book, in: libraryDirectory)
        return KeptPackage(book: book, package: package, row: kept, before: try snapshot(of: package))
    }

    /// A kept row made of `members`.
    private func keptRow(_ members: [String: JSONValue]) -> UnreadableLibraryRow {
        UnreadableLibraryRow(json: .object(members))
    }

    /// `KeptRowPackages` owns the package a row names by its folder and
    /// name, by its name in any folder when it names no readable folder, and
    /// nothing for a row naming no package.
    func testKeptRowPackagesOwnWhatTheRowsNameAndNothingElse() {
        let both = keptRow(["tmbDirectoryName": .string("A.tmb"), "folderPath": .string("Shelf")])
        let top = keptRow(["tmbDirectoryName": .string("T.tmb"), "folderPath": .string("")])
        let nameOnly = keptRow(["tmbDirectoryName": .string("N.tmb")])
        let folderNotText = keptRow(["tmbDirectoryName": .string("F.tmb"), "folderPath": .integer(3)])
        let nameless = keptRow(["folderPath": .string("Shelf")])
        let emptyName = keptRow(["tmbDirectoryName": .string(""), "folderPath": .string("Shelf")])
        let nameNotText = keptRow(["tmbDirectoryName": .integer(7)])

        let packages = KeptRowPackages([both, top, nameOnly, folderNotText, nameless, emptyName, nameNotText])

        XCTAssertTrue(packages.owns(folderPath: "Shelf", tmbDirectoryName: "A.tmb"))
        XCTAssertFalse(packages.owns(folderPath: "Other", tmbDirectoryName: "A.tmb"), "a readable folder decides")
        XCTAssertFalse(packages.owns(folderPath: "", tmbDirectoryName: "A.tmb"))
        XCTAssertTrue(packages.owns(folderPath: "", tmbDirectoryName: "T.tmb"))
        XCTAssertFalse(packages.owns(folderPath: "Shelf", tmbDirectoryName: "T.tmb"), "the top of the library is a folder too")
        XCTAssertTrue(packages.owns(folderPath: "", tmbDirectoryName: "N.tmb"))
        XCTAssertTrue(packages.owns(folderPath: "Any/Where", tmbDirectoryName: "N.tmb"))
        XCTAssertTrue(packages.owns(folderPath: "Any/Where", tmbDirectoryName: "F.tmb"), "a folder that is not text names none")
        XCTAssertFalse(packages.owns(folderPath: "Shelf", tmbDirectoryName: ""))
        XCTAssertFalse(packages.owns(folderPath: "Shelf", tmbDirectoryName: "7"))
        XCTAssertFalse(packages.owns(folderPath: "Shelf", tmbDirectoryName: "Unrelated.tmb"))
        XCTAssertFalse(packages.isEmpty)
        XCTAssertTrue(KeptRowPackages([nameless, emptyName, nameNotText]).isEmpty)
        XCTAssertTrue(KeptRowPackages([]).isEmpty)
    }

    /// Names and folders match without regard to case, and in precomposed
    /// form, as the library compares folders: a directory listing may spell
    /// them as the volume does, not as the row does.
    func testKeptRowPackagesCompareLikeTheLibraryComparesFolders() {
        let row = keptRow(["tmbDirectoryName": .string("Caf\u{E9}.tmb"), "folderPath": .string("Shelf/Caf\u{E9}")])

        let packages = KeptRowPackages([row])

        XCTAssertTrue(packages.owns(folderPath: "shelf/cafe\u{301}", tmbDirectoryName: "CAFE\u{301}.TMB"))
    }

    /// Orphan adoption adds no book for a package a kept row owns, at the top
    /// of the library and in a folder, and leaves the package as it was,
    /// byte for byte; the package it adopts is another, which no row keeps.
    func testOrphanAdoptionLeavesAKeptRowsPackage() throws {
        for folder in ["", "Shelf"] {
            let libraryDirectory = try makeScratchFolder()
            let kept = try makeKeptPackage(folder: folder, in: libraryDirectory)
            let loose = try writePackage(title: "Loose Book", folder: folder, in: libraryDirectory)
            var library = Library(unreadableRows: [kept.row])

            let adopted = FileImportService.adoptOrphanedTMBPackages(library: &library, libraryDirectory: libraryDirectory)

            XCTAssertEqual(adopted, 1, "folder '\(folder)'")
            XCTAssertEqual(library.books.map(\.id), [loose.id], "folder '\(folder)'")
            XCTAssertEqual(library.unreadableRows, [kept.row])
            XCTAssertEqual(try snapshot(of: kept.package), kept.before, "folder '\(folder)'")
        }
    }

    /// The package of the test above is a book orphan adoption would take
    /// but for the row that keeps it, which proves the guard is what holds
    /// it back.
    func testTheSamePackageIsAdoptedWhenNoRowKeepsIt() throws {
        let libraryDirectory = try makeScratchFolder()
        let kept = try makeKeptPackage(in: libraryDirectory)
        var library = Library()

        let adopted = FileImportService.adoptOrphanedTMBPackages(library: &library, libraryDirectory: libraryDirectory)

        XCTAssertEqual(adopted, 1)
        XCTAssertEqual(library.books.map(\.id), [kept.book.id])
    }

    /// The startup repair leaves a kept row's package alone and the row in
    /// library.json: the shown book stays, no book is made of the package,
    /// and what is saved afterward holds the row as it was.
    @MainActor
    func testTheStartupRepairLeavesAKeptRowsPackage() throws {
        _ = try captureLibraryIndex()
        let kept = try makeKeptPackage(in: TextMouthPaths.libraryDir)
        let shown = try writePackage(title: "Shown Book", in: TextMouthPaths.libraryDir)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [shown], unreadableRows: [kept.row])

        model.migrateOldBooksIfNeeded()
        model.save()
        LibraryPersistenceService.flushPendingSave()

        XCTAssertTrue(model.library.books.contains { $0.id == shown.id })
        XCTAssertFalse(model.library.books.contains { $0.tmbDirectoryName == kept.book.tmbDirectoryName })
        XCTAssertEqual(model.library.unreadableRows, [kept.row])
        XCTAssertEqual(try snapshot(of: kept.package), kept.before)
        let written = try XCTUnwrap(LibraryPersistenceService.load().library)
        XCTAssertEqual(written.unreadableRows, [kept.row])
        XCTAssertFalse(written.books.contains { $0.tmbDirectoryName == kept.book.tmbDirectoryName })
        XCTAssertTrue(written.books.contains { $0.id == shown.id })
    }

    /// Rebuild Directory (and Reset to Default, which runs the same
    /// rebuild) makes no book of a kept row's package, leaves its files as
    /// they were, and keeps the row.
    func testRebuildDirectoryLeavesAKeptRowsPackage() throws {
        let kept = try makeKeptPackage(in: TextMouthPaths.libraryDir)
        let shown = try writePackage(title: "Shown Book", in: TextMouthPaths.libraryDir)
        var library = Library(books: [shown], unreadableRows: [kept.row])

        try FileImportService.rebuildDirectoryStructure(library: &library)

        XCTAssertTrue(library.books.contains { $0.id == shown.id })
        XCTAssertFalse(library.books.contains { $0.tmbDirectoryName == kept.book.tmbDirectoryName })
        XCTAssertEqual(library.unreadableRows, [kept.row])
        XCTAssertEqual(try snapshot(of: kept.package), kept.before)
    }

    /// Rebuild Library Index, after the index became unreadable while
    /// TextMouth ran: the provisional library holds the books read from their
    /// packages and none made of a kept row's, and the index it writes holds
    /// the kept row once, as it was.
    @MainActor
    func testRebuildLibraryIndexKeepsTheKeptRowOnceAndMakesNoRowOfItsPackage() throws {
        let sandbox = try captureLibraryIndex()
        let kept = try makeKeptPackage(in: TextMouthPaths.libraryDir)
        let shown = try writePackage(title: "Shown Book", in: TextMouthPaths.libraryDir)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [shown], unreadableRows: [kept.row])
        try sandbox.stage(.truncated, of: Library(books: [shown]), at: sandbox.indexURL)

        model.reloadLibraryAfterDataDirectoryReturned()

        XCTAssertNotNil(model.indexRecovery)
        XCTAssertTrue(model.library.books.contains { $0.id == shown.id }, "read from its package")
        XCTAssertFalse(model.library.books.contains { $0.tmbDirectoryName == kept.book.tmbDirectoryName })
        let outcome = model.rebuildLibraryIndex()
        guard case .rebuilt = outcome else { return XCTFail("\(outcome)") }
        let written = try XCTUnwrap(LibraryPersistenceService.load().library)
        XCTAssertEqual(written.unreadableRows, [kept.row], "the kept row, once")
        XCTAssertTrue(written.books.contains { $0.id == shown.id })
        XCTAssertFalse(written.books.contains { $0.tmbDirectoryName == kept.book.tmbDirectoryName })
        XCTAssertEqual(try snapshot(of: kept.package), kept.before)
    }

    /// The sweep of empty folders leaves the folder of a kept row's package
    /// (which no folder row of the library names) and the package, and takes
    /// the empty folder beside it, as it always did.
    func testTheEmptyFolderSweepLeavesAKeptRowsPackage() throws {
        let libraryDirectory = try makeScratchFolder()
        let kept = try makeKeptPackage(folder: "Shelf", in: libraryDirectory)
        let empty = libraryDirectory.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        FileImportService.removeEmptyLibrarySubdirectories(
            library: Library(unreadableRows: [kept.row]),
            libraryDirectory: libraryDirectory
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path), "the sweep still sweeps")
        XCTAssertEqual(try snapshot(of: kept.package), kept.before)
    }

    /// The data-directory move copies a kept row's package with the rest,
    /// byte for byte, and writes the row, as it was, into the new
    /// library.json.
    func testTheDataDirectoryMoveCopiesAKeptRowsPackage() throws {
        let base = try makeScratchFolder()
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let destination = base.appendingPathComponent("Destination", isDirectory: true)
        let libraryDirectory = source.appendingPathComponent(TextMouthPaths.libraryFolderName, isDirectory: true)
        let kept = try makeKeptPackage(folder: "Shelf", in: libraryDirectory)
        let shown = try writePackage(title: "Shown Book", in: libraryDirectory)
        let library = Library(books: [shown], unreadableRows: [kept.row])

        let migrated = try DataDirectoryMigrator.prepareMigration(from: source, to: destination, library: library)

        let copy = destination
            .appendingPathComponent(TextMouthPaths.libraryFolderName, isDirectory: true)
            .appendingPathComponent("Shelf", isDirectory: true)
            .appendingPathComponent(kept.book.tmbDirectoryName, isDirectory: true)
        XCTAssertEqual(try snapshot(of: copy), kept.before)
        XCTAssertEqual(migrated.unreadableRows, [kept.row])
        let written = try decodeLibrary(Data(contentsOf: destination.appendingPathComponent("library.json")))
        XCTAssertEqual(written.unreadableRows, [kept.row])
        XCTAssertEqual(written.books.map(\.id), [shown.id])
    }

    // MARK: - A feed's index keeps the rows it cannot read

    /// A data directory of a feed's index holding a readable row and a row
    /// of an unknown format, both with packages on disk.
    private struct FeedRowsFixture {
        /// The data directory the feed lives in.
        let root: URL
        /// The feed.
        let feedID: UUID
        /// The row this version reads.
        let readable: Book
        /// The item whose row is of an unknown format in the index.
        let unreadable: Book
        /// That row as the index file holds it.
        let rawUnreadable: [String: Any]
        /// The feed's index file.
        var indexURL: URL { FeedPaths.indexFile(of: feedID, in: root) }
    }

    /// A downloaded article of `feedID` in the data directory `root`: a
    /// package in the feed's folder holding its HTML and its record, and the
    /// row for it.
    private func makeFeedItem(title: String, feedID: UUID, in root: URL) throws -> Book {
        let bookID = UUID()
        let dateAdded = Date(timeIntervalSince1970: 1_790_000_000)
        let name = TextMouthPaths.tmbName(title: title, author: "Antiquarian", dateAdded: dateAdded, bookID: bookID)
        let package = FeedPaths.packageDirectory(named: name, of: feedID, in: root)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let file = package.appendingPathComponent("\(title).html")
        try "<html><body><h1>\(title)</h1><p>Words.</p></body></html>".write(to: file, atomically: true, encoding: .utf8)
        let book = Book(
            id: bookID,
            title: title,
            author: "Antiquarian",
            format: .html,
            filePath: file.path,
            md5Hash: UUID().uuidString,
            folderPath: "",
            dateAdded: dateAdded,
            tmbDirectoryName: name,
            feedLink: FeedBookLink(feedID: feedID, itemID: UUID().uuidString)
        )
        try book.makeBookInfo().save(to: package)
        return book
    }

    /// Builds the fixture: two feed items with packages, and the feed's index
    /// written from both, with the second item's row then changed to an
    /// unknown format (`fb2`), as a later TextMouth could have written it.
    private func makeFeedRowsFixture() throws -> FeedRowsFixture {
        let root = try makeScratchFolder()
        let feedID = UUID()
        let readable = try makeFeedItem(title: "Readable", feedID: feedID, in: root)
        let unreadable = try makeFeedItem(title: "Future", feedID: feedID, in: root)
        let written = try FeedIndexFiles.encoded(FeedIndex(feedID: feedID, books: [readable, unreadable]))
        var object = try jsonObject(written)
        var rows = try XCTUnwrap(object["books"] as? [[String: Any]])
        let index = rows.firstIndex { ($0["id"] as? String) == unreadable.id.uuidString }
        let position = try XCTUnwrap(index)
        rows[position]["format"] = "fb2"
        object["books"] = rows
        try FileManager.default.createDirectory(
            at: FeedPaths.itemsFolder(of: feedID, in: root), withIntermediateDirectories: true
        )
        let fixture = FeedRowsFixture(
            root: root, feedID: feedID, readable: readable, unreadable: unreadable,
            rawUnreadable: rows[position]
        )
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: fixture.indexURL)
        return fixture
    }

    /// The shelf a library holds after reading `contents` of the feed
    /// `feedID`, as loading the feeds' indexes makes it.
    private func shelf(reading contents: FeedIndexFiles.Contents, of feedID: UUID) -> FeedShelf {
        FeedShelf(
            rows: contents.rows,
            indexedFeedIDs: [feedID],
            unreadableRows: [feedID: contents.unreadableRows]
        )
    }

    /// A feed's index holding a readable row and one of an unknown format
    /// reads the one and keeps the other, is not preserved aside as unusable,
    /// and does not read the kept row's package again as a row of the
    /// folder.
    func testAFeedIndexReadsTheRowItCanAndKeepsTheOther() throws {
        let fixture = try makeFeedRowsFixture()

        let contents = FeedIndexFiles.read(feedID: fixture.feedID, in: fixture.root)

        XCTAssertEqual(contents.rows.map(\.id), [fixture.readable.id])
        XCTAssertEqual(contents.unreadableRows.map(\.id), [Optional(fixture.unreadable.id)])
        XCTAssertEqual(contents.unreadableRows.map(\.tmbDirectoryName), [Optional(fixture.unreadable.tmbDirectoryName)])
        XCTAssertNotNil(contents.indexBytes, "the index was usable")
        XCTAssertFalse(contents.isLeftAlone)
        XCTAssertTrue(LibraryIndexQuarantine.existingCopies(of: fixture.indexURL).isEmpty, "not preserved aside")
    }

    /// The kept row is written back, equal to the original, at the next
    /// save of the feed's index, after the rows it reads and counted as a
    /// row; reading what was written again changes nothing.
    func testAFeedIndexWritesTheKeptRowBackUnchanged() throws {
        let fixture = try makeFeedRowsFixture()
        let contents = FeedIndexFiles.read(feedID: fixture.feedID, in: fixture.root)
        let library = Library(feedShelf: shelf(reading: contents, of: fixture.feedID))

        let indexes = try FeedIndexFiles.encodedIndexes(of: library, placedIn: fixture.root)

        XCTAssertEqual(indexes.map(\.feedID), [fixture.feedID])
        XCTAssertEqual(indexes.map(\.rowCount), [2])
        let written = try XCTUnwrap(indexes.first)
        let rows = try XCTUnwrap(jsonObject(written.data)["books"] as? [NSDictionary])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.last, fixture.rawUnreadable as NSDictionary)
        XCTAssertEqual(rows.compactMap { $0["id"] as? String }.first, fixture.readable.id.uuidString)

        try FeedIndexFiles.write(written, in: fixture.root)
        let again = FeedIndexFiles.read(feedID: fixture.feedID, in: fixture.root)
        XCTAssertEqual(again.rows.map(\.id), [fixture.readable.id])
        XCTAssertEqual(again.unreadableRows, contents.unreadableRows)
    }

    /// A feed whose index holds only rows this version cannot read still has
    /// an index to write: its rows are not an empty list.
    func testAFeedOfOnlyKeptRowsIsNotEmpty() throws {
        let feedID = UUID()
        let row = keptRow(["id": .string(UUID().uuidString), "format": .string("fb2")])
        let library = Library(feedShelf: FeedShelf(unreadableRows: [feedID: [row]]))

        let indexes = try FeedIndexFiles.encodedIndexes(of: library, placedIn: FileManager.default.temporaryDirectory)

        XCTAssertEqual(indexes.map(\.feedID), [feedID])
        XCTAssertEqual(indexes.map(\.rowCount), [1])
    }

    /// An index without kept rows is written exactly as it was before they
    /// could be kept.
    func testAFeedIndexWithoutKeptRowsEncodesAsBefore() throws {
        let fixture = try makeFeedRowsFixture()

        let written = try FeedIndexFiles.encoded(FeedIndex(feedID: fixture.feedID, books: [fixture.readable]))

        let object = try jsonObject(written)
        XCTAssertEqual(Set(object.keys), ["formatVersion", "feedID", "books"])
        let rows = try XCTUnwrap(object["books"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["id"] as? String }, [fixture.readable.id.uuidString])
    }

    /// The shelf keeps the index of a feed it holds kept rows of, counts the
    /// rows, and forgets them with the feed's index.
    func testTheShelfKeepsAndForgetsAFeedsKeptRows() {
        let feedID = UUID()
        let row = keptRow(["tmbDirectoryName": .string("Future.tmb")])
        var shelf = FeedShelf()

        shelf.keepUnreadableRows([row], of: feedID)

        XCTAssertEqual(shelf.unreadableRows[feedID], [row])
        XCTAssertEqual(shelf.unreadableRowCount, 1)
        XCTAssertTrue(shelf.indexedFeedIDs.contains(feedID))

        shelf.keepUnreadableRows([], of: feedID)
        XCTAssertEqual(shelf.unreadableRowCount, 0)

        shelf.keepUnreadableRows([row], of: feedID)
        shelf.forgetIndex(of: feedID)
        XCTAssertEqual(shelf.unreadableRowCount, 0)
        XCTAssertFalse(shelf.indexedFeedIDs.contains(feedID))
    }

    /// A library merged from a session into the index read again keeps the
    /// kept rows: the session's own for a feed it read some of, and else
    /// those the index read.
    func testMergingASessionIntoALoadedLibraryKeepsAFeedsKeptRows() {
        let sessionFeed = UUID()
        let loadedOnlyFeed = UUID()
        let fromSession = keptRow(["tmbDirectoryName": .string("Session.tmb")])
        let fromLoaded = keptRow(["tmbDirectoryName": .string("Loaded.tmb")])
        let session = Library(feedShelf: FeedShelf(unreadableRows: [sessionFeed: [fromSession]]))
        var loadedShelf = FeedShelf(unreadableRows: [loadedOnlyFeed: [fromLoaded]])
        loadedShelf.keepUnreadableRows([fromLoaded], of: sessionFeed)
        let loaded = Library(feedShelf: loadedShelf)

        let merged = LibraryViewModel.feedItems(of: session, over: loaded)

        XCTAssertEqual(merged.unreadableRows[sessionFeed], [fromSession])
        XCTAssertEqual(merged.unreadableRows[loadedOnlyFeed], [fromLoaded])
    }

    /// The model counts the kept rows of the feeds' indexes with those of
    /// library.json.
    @MainActor
    func testTheModelCountsAFeedsKeptRowsToo() throws {
        let model = LibraryViewModel()
        var library = try decodeLibrary(makeRowsFixture().data)
        XCTAssertEqual(library.unreadableRows.count, 2)
        library.feedShelf.keepUnreadableRows([keptRow(["format": .string("fb2")])], of: UUID())
        model.library = library

        XCTAssertEqual(model.booksNeedingNewerTextMouth, 3)
        XCTAssertEqual(library.libraryBookCount, 2, "the kept rows are not books")
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

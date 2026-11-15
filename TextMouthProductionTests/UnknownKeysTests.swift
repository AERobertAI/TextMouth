import XCTest
@testable import TextMouth

/// A library row, a package record, config.json, and every object inside
/// them keep the keys this TextMouth does not know (V04, `UnknownKeys`): a
/// later TextMouth's keys are read with their object and written back as
/// they were, through a load and a save and through every merge, and a file
/// without any is written byte for byte as before.
final class UnknownKeysTests: XCTestCase {

    // MARK: - Fixtures

    /// A fixed date on a whole second, as the files keep dates.
    private static let date = Date(timeIntervalSince1970: 1_800_000_000)

    /// An encoder that writes dates as library.json and bookInfo.json do,
    /// with sorted keys, so one value is always the same bytes.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// The decoder to match `encoder`.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// A book with every field set and no unknown keys, as this TextMouth
    /// makes one, with dates on whole seconds so it reads back equal.
    private static func plainBook(seed: Int = 3) -> Book {
        var book = ContentAnalysisMergeTests.bookWithEveryFieldSet(seed: seed)
        book.unknownKeys = UnknownKeys()
        // A position made now is stamped with now, fractions of a second
        // included, which the files do not keep.
        book.readingPosition?.lastUpdated = date
        return book
    }

    /// A reading position with none of its optional fields, saved at a
    /// whole second.
    private static func barePosition() -> ReadingPosition {
        var position = ReadingPosition(chapterIndex: 2, characterOffset: 9)
        position.lastUpdated = date
        return position
    }

    /// A package record with every section's every field set, the
    /// transcript note and its source included, and no unknown keys.
    private static func plainRecord(seed: Int = 3) -> BookInfo {
        var info = plainBook(seed: seed).bookInfo(replacing: nil, contentIndex: nil, notingMoveToLibraryAt: date)
        info.state.transcript = TranscriptNote(
            version: 1, locale: "en-US", createdAt: date,
            source: TranscriptSource(origin: .attached, format: .webVTT, fileName: "talk.vtt", otherFormats: [.subRip])
        )
        return info
    }

    /// A library of `books` with two folders, one inside the other, a sort
    /// setting for one of them, and a reading list of the first book.
    private static func library(of books: [Book]) -> Library {
        Library(
            books: books,
            folders: [
                BookFolder(name: "Fiction", dateCreated: date),
                BookFolder(name: "Short", parentPath: "Fiction", dateCreated: date),
            ],
            folderSortSettings: ["Fiction": FolderSortSetting(sortField: .author, sortAscending: false)],
            readingList: ReadingList(bookIDs: books.prefix(1).map(\.id), removesFinished: true)
        )
    }

    /// Statistics with listening on two days by two books.
    private static func statistics() -> ReadingStats {
        var stats = ReadingStats()
        stats.addListening(90, bookID: UUID(), dayKey: "2026-11-14")
        stats.addListening(45.5, bookID: UUID(), dayKey: "2026-11-15")
        return stats
    }

    /// A member of every JSON kind, as a later TextMouth might add one: a
    /// null, a bool, a whole number, one above `Int64.max`, a fraction, a
    /// string, an array in an order that is not sorted, and nested objects.
    private static let everyKind: [String: Any] = [
        "nothing": NSNull(),
        "flag": true,
        "whole": -7,
        "large": UInt64.max,
        "fraction": 2.5,
        "text": "héllo \"quoted\"",
        "list": [3, "two", [1.5, NSNull()], ["inner": false]] as [Any],
        "object": ["deeper": ["deepest": [] as [Any]]],
    ]

    /// The name the tests give the unknown member they add to an object.
    private static let addedKey = "addedByALaterTextMouth"

    /// `tree`, a JSON value as `JSONSerialization` reads one, with an
    /// unknown member added to every object in it, at every depth: the
    /// member holds every JSON kind and names the place it was added at, so
    /// no two are alike.
    private static func addingUnknownMembers(to tree: Any, at path: String = "top") -> Any {
        if let object = tree as? [String: Any] {
            var changed: [String: Any] = [:]
            for (key, value) in object {
                changed[key] = addingUnknownMembers(to: value, at: "\(path).\(key)")
            }
            var member = everyKind
            member["place"] = path
            changed[addedKey] = member
            return changed
        }
        if let array = tree as? [Any] {
            return array.enumerated().map { addingUnknownMembers(to: $1, at: "\(path)[\($0)]") }
        }
        return tree
    }

    /// How many objects `tree` holds that have the tests' unknown member.
    private static func countOfAddedMembers(in tree: Any) -> Int {
        if let object = tree as? [String: Any] {
            // The member's own contents are not searched.
            let inside = object.filter { $0.key != addedKey }.values.map(countOfAddedMembers(in:)).reduce(0, +)
            return inside + (object[addedKey] == nil ? 0 : 1)
        }
        if let array = tree as? [Any] {
            return array.map(countOfAddedMembers(in:)).reduce(0, +)
        }
        return 0
    }

    /// `data` as the JSON value it holds.
    private static func tree(_ data: Data) throws -> NSObject {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? NSObject)
    }

    /// `tree` as JSON bytes.
    private static func data(_ tree: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: tree, options: [.sortedKeys])
    }

    /// The object at `path` (member names) inside the JSON object `tree`.
    private static func object(in tree: Any, at path: [String]) throws -> [String: Any] {
        var current = try XCTUnwrap(tree as? [String: Any])
        for name in path {
            current = try XCTUnwrap(current[name] as? [String: Any], "no object at \(name)")
        }
        return current
    }

    /// Decodes `Value` from `value`'s JSON with an unknown member added to
    /// every object in it, encodes the result, and asserts that the JSON
    /// written is the JSON read: every unknown member, at every depth, with
    /// every kind of value, came back as it was. `objects` is how many
    /// objects the value's JSON holds, so a fixture that lost a nested
    /// record would be noticed.
    private func assertKeepsUnknownMembersAtEveryLevel<Value: Codable>(
        _ value: Value,
        objects: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let read = Self.addingUnknownMembers(to: try Self.tree(Self.encoder.encode(value)))
        XCTAssertEqual(Self.countOfAddedMembers(in: read), objects, "the fixture's objects", file: file, line: line)
        let decoded = try Self.decoder.decode(Value.self, from: Self.data(read))
        let written = try Self.tree(Self.encoder.encode(decoded))
        XCTAssertEqual(written, try XCTUnwrap(read as? NSObject), file: file, line: line)
    }

    // MARK: - JSONValue

    /// A whole number above `Int64.max` stays exact, where a `Double` would
    /// round it; one an `Int64` holds is still an integer.
    func testAWholeNumberAboveInt64StaysExact() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data("18446744073709551615".utf8))
        XCTAssertEqual(value, .unsigned(UInt64.max))
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(value), as: UTF8.self), "18446744073709551615")
        XCTAssertEqual(
            try JSONDecoder().decode(JSONValue.self, from: Data("9223372036854775807".utf8)),
            .integer(Int64.max)
        )
    }

    // MARK: - Round Trips With Unknown Keys

    /// A library row keeps the unknown members of the row and of every
    /// object in it: its reading position, bookmarks, skipped and waiting
    /// headings, each one's anchor, its fingerprints, the record of its
    /// edit, its hand edits, and its feed link.
    func testALibraryRowKeepsUnknownKeysAtEveryLevel() throws {
        // The row; position and its anchor; a bookmark and its anchor; a
        // skipped and a waiting heading and their anchors; the fingerprints
        // and their two files; the edit; the hand edits; the feed link.
        try assertKeepsUnknownMembersAtEveryLevel(Self.plainBook(), objects: 15)
    }

    /// A package record keeps the unknown members of bookInfo.json's top
    /// level, of its metadata and its state, and of every object in them,
    /// the transcript note and its source included.
    func testAPackageRecordKeepsUnknownKeysAtEveryLevel() throws {
        // The record, its metadata (with hand edits and feed link) and state
        // (position and anchor, two headings and their anchors, the
        // fingerprints and their two files, the edit, the transcript note
        // and its source), and a bookmark and its anchor.
        try assertKeepsUnknownMembersAtEveryLevel(Self.plainRecord(), objects: 19)
    }

    /// A package record's unknown members survive the files themselves: a
    /// record read from a package and saved again holds them all.
    func testAPackageRecordKeepsUnknownKeysThroughItsFile() throws {
        let package = try makeSandboxDirectory("Unknown Keys Record")
        let file = TextMouthPaths.bookInfoPath(in: package)
        let read = Self.addingUnknownMembers(to: try Self.tree(Self.encoder.encode(Self.plainRecord())))
        try Self.data(read).write(to: file)

        try BookInfo.load(from: package).saveRecord(to: package)

        XCTAssertEqual(try Self.tree(Data(contentsOf: file)), try XCTUnwrap(read as? NSObject))
    }

    /// config.json keeps its unknown top-level members through a decode and
    /// an encode, sorted among its own keys.
    func testConfigJSONKeepsUnknownKeys() throws {
        var read = try XCTUnwrap(
            try Self.tree(ConfigService.fileData(for: .everyFieldCustomized)) as? [String: Any]
        )
        read[Self.addedKey] = Self.everyKind
        read["aNoteKeptByHand"] = "leave this here"

        let config = try ConfigService.decode(Self.data(read))
        XCTAssertEqual(Set(config.unknownKeys.members.keys), [Self.addedKey, "aNoteKeptByHand"])
        let written = try ConfigService.fileData(for: config)

        XCTAssertEqual(try Self.tree(written), read as NSDictionary)
        // An unknown key is written where it sorts among the file's own
        // keys, never after them all.
        let text = String(decoding: written, as: UTF8.self)
        let added = try XCTUnwrap(text.range(of: "\"\(Self.addedKey)\""))
        let last = try XCTUnwrap(text.range(of: "\"wordsPerMinute\""))
        XCTAssertLessThan(added.lowerBound, last.lowerBound)
    }

    /// library.json keeps the unknown members of its rows, of its folders,
    /// and of its reading list, and the top-level sections it does not
    /// know, through the index's own decoder and encoder.
    func testLibraryJSONKeepsItsRowsAndItsOwnUnknownKeys() throws {
        var book = Self.plainBook()
        // A feed item's row is never library.json's.
        book.feedLink = nil
        let read = try XCTUnwrap(try Self.tree(LibraryPersistenceService.encodedIndex(Self.library(of: [book]))) as? [String: Any])
        var changed = read
        // Every object of the rows, of the two folders, and of the reading
        // list. (A folder's sort setting keeps none, so none is added there.)
        for section in ["books", "folders", "readingList"] {
            changed[section] = Self.addingUnknownMembers(to: try XCTUnwrap(read[section]), at: section)
        }
        changed[Self.addedKey] = Self.everyKind
        XCTAssertEqual(Self.countOfAddedMembers(in: changed), 14 + 2 + 1 + 1, "the fixture's objects")

        let library = try LibraryPersistenceService.decodeIndex(from: Self.data(changed))
        XCTAssertEqual(library.books.count, 1)
        XCTAssertEqual(library.folders.count, 2)
        XCTAssertEqual(library.readingList.bookIDs, [book.id])
        XCTAssertEqual(Set(library.unknownKeys.members.keys), [Self.addedKey])
        XCTAssertTrue(library.unreadableRows.isEmpty, "a row with unknown keys is still a book")
        let written = try Self.tree(LibraryPersistenceService.encodedIndex(library))

        XCTAssertEqual(written, changed as NSDictionary)
    }

    /// reading_stats.json keeps its unknown top-level members through a
    /// load and a save, and through the two ways the statistics change:
    /// listening added in place, and this Mac's listening added to a file
    /// that arrives from the cloud.
    func testTheStatisticsFileKeepsUnknownKeys() throws {
        var read = try XCTUnwrap(try Self.tree(Self.statistics().fileData()) as? [String: Any])
        read[Self.addedKey] = Self.everyKind

        var stats = try ReadingStats.decodeFile(Self.data(read))
        XCTAssertEqual(try Self.tree(stats.fileData()), read as NSDictionary)

        let kept = stats.unknownKeys
        XCTAssertEqual(Set(kept.members.keys), [Self.addedKey])
        stats.addListening(30, bookID: UUID(), dayKey: "2026-11-16")
        XCTAssertEqual(stats.unknownKeys, kept)
        // The file's statistics, with this Mac's added: the file's keys.
        XCTAssertEqual(stats.adding(Self.statistics()).unknownKeys, kept)
    }

    /// A folder renamed or moved, and a reading list changed, keep their
    /// unknown keys: each is changed in place.
    func testAFolderAndTheReadingListChangedInPlaceKeepTheirUnknownKeys() {
        var library = Self.library(of: [Self.plainBook()])
        XCTAssertEqual(library.folders.count, 2)
        guard library.folders.count == 2 else { return }
        library.folders[0].unknownKeys = UnknownKeys(["colour": .string("amber")])
        library.readingList.unknownKeys = UnknownKeys(["shuffles": .bool(true)])

        library.folders[0].name = "Novels"
        library.readingList.skipsFinished = false

        XCTAssertEqual(library.folders[0].unknownKeys, UnknownKeys(["colour": .string("amber")]))
        XCTAssertEqual(library.readingList.unknownKeys, UnknownKeys(["shuffles": .bool(true)]))
        XCTAssertNotEqual(library, Self.library(of: library.books))
    }

    // MARK: - A Known Key Always Wins

    /// An unknown member named as a field never stands over the field: the
    /// field is written, whatever the member holds.
    func testAKnownKeyAlwaysWins() throws {
        var book = Self.plainBook()
        book.unknownKeys = UnknownKeys(["title": .string("not the title"), "addedLater": .integer(1)])
        let row = try XCTUnwrap(try Self.tree(Self.encoder.encode(book)) as? [String: Any])
        XCTAssertEqual(row["title"] as? String, book.title)
        XCTAssertEqual(row["addedLater"] as? Int, 1)

        var config = ConfigService.AppConfig.everyFieldCustomized
        config.unknownKeys = UnknownKeys(["wordsPerMinute": .integer(1), "addedLater": .integer(1)])
        let file = try XCTUnwrap(try Self.tree(ConfigService.fileData(for: config)) as? [String: Any])
        XCTAssertEqual(file["wordsPerMinute"] as? Double, config.wordsPerMinute)
        XCTAssertEqual(file["addedLater"] as? Int, 1)
    }

    /// A member that is one of a type's keys is never read as unknown, even
    /// when its value cannot be read as the field: it is repaired or
    /// dropped as before, not kept beside the field.
    func testAKnownKeyIsNeverReadAsUnknown() throws {
        var row = try XCTUnwrap(try Self.tree(Self.encoder.encode(Self.plainBook())) as? [String: Any])
        row["totalWordCount"] = "many"
        let book = try Self.decoder.decode(Book.self, from: Self.data(row))
        XCTAssertNil(book.totalWordCount)
        XCTAssertTrue(book.unknownKeys.isEmpty)
    }

    /// Nothing is ever written under the name of the property the unknown
    /// keys are held in, and a member of that name in a file is kept like
    /// any other unknown member.
    func testNothingIsWrittenUnderThePropertysOwnName() throws {
        let record = String(decoding: try Self.encoder.encode(Self.plainRecord()), as: UTF8.self)
        XCTAssertFalse(record.contains("unknownKeys"))
        let file = String(decoding: try ConfigService.fileData(for: .everyFieldCustomized), as: UTF8.self)
        XCTAssertFalse(file.contains("unknownKeys"))
        XCTAssertFalse(String(decoding: try Self.encoder.encode(Self.plainBook()), as: UTF8.self).contains("unknownKeys"))

        var read = try XCTUnwrap(try Self.tree(ConfigService.fileData(for: .everyFieldCustomized)) as? [String: Any])
        read["unknownKeys"] = ["a": 1]
        let config = try ConfigService.decode(Self.data(read))
        XCTAssertEqual(try Self.tree(ConfigService.fileData(for: config)), read as NSDictionary)
    }

    /// A member nested deeper than a `JSONValue` may be is left out, as
    /// every unknown member was before they were kept; the row still loads,
    /// with its other unknown members.
    func testAMemberTooDeepToKeepIsLeftOutAndTheRowStillLoads() throws {
        var deep: Any = 1
        for _ in 0..<(JSONValue.maximumDepth + 4) {
            deep = [deep]
        }
        var row = try XCTUnwrap(try Self.tree(Self.encoder.encode(Self.plainBook())) as? [String: Any])
        row["tooDeep"] = deep
        row["addedLater"] = "kept"

        let book = try Self.decoder.decode(Book.self, from: Self.data(row))

        XCTAssertEqual(book.unknownKeys, UnknownKeys(["addedLater": .string("kept")]))
        XCTAssertEqual(book.title, Self.plainBook().title)
    }

    // MARK: - Files Without Unknown Keys Are Written as Before

    /// A library index without unknown keys is the same bytes after a load
    /// and a save.
    func testALibraryIndexWithoutUnknownKeysIsWrittenByteForByteAsItWas() throws {
        var books = (1...4).map { Self.plainBook(seed: $0) }
        for index in books.indices {
            books[index].feedLink = nil
        }
        // A row with almost nothing set, too, as an old row is.
        books.append(Book(
            id: UUID(), title: "Bare", format: .txt, filePath: "/library/bare.txt", md5Hash: "bare",
            dateAdded: Self.date
        ))
        let before = try LibraryPersistenceService.encodedIndex(Self.library(of: books))

        let loaded = try LibraryPersistenceService.decodeIndex(from: before)

        XCTAssertTrue(loaded.books.allSatisfy(\.unknownKeys.isEmpty))
        XCTAssertTrue(loaded.folders.allSatisfy(\.unknownKeys.isEmpty))
        XCTAssertTrue(loaded.readingList.unknownKeys.isEmpty && loaded.unknownKeys.isEmpty)
        XCTAssertEqual(try LibraryPersistenceService.encodedIndex(loaded), before)
    }

    /// reading_stats.json without unknown keys is the same bytes after a
    /// load and a save, and holds no key for the property they are kept in.
    func testTheStatisticsFileWithoutUnknownKeysIsWrittenByteForByteAsItWas() throws {
        let before = try Self.statistics().fileData()
        let loaded = try ReadingStats.decodeFile(before)
        XCTAssertTrue(loaded.unknownKeys.isEmpty)
        XCTAssertEqual(try loaded.fileData(), before)
        XCTAssertFalse(String(decoding: before, as: UTF8.self).contains("unknownKeys"))
    }

    /// A package record without unknown keys is the same bytes after a load
    /// and a save, in its file.
    func testAPackageRecordWithoutUnknownKeysIsWrittenByteForByteAsItWas() throws {
        let package = try makeSandboxDirectory("Unknown Keys Plain Record")
        let file = TextMouthPaths.bookInfoPath(in: package)
        try Self.plainRecord().saveRecord(to: package)
        let before = try Data(contentsOf: file)

        try BookInfo.load(from: package).saveRecord(to: package)

        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    /// config.json without unknown keys is the same bytes after a load and
    /// a save.
    func testConfigJSONWithoutUnknownKeysIsWrittenByteForByteAsItWas() throws {
        for config in [ConfigService.AppConfig(), .everyFieldCustomized] {
            let before = try ConfigService.fileData(for: config)
            let loaded = try ConfigService.decode(before)
            XCTAssertTrue(loaded.unknownKeys.isEmpty)
            XCTAssertEqual(try ConfigService.fileData(for: loaded), before)
        }
    }

    // MARK: - The Hand-Written Encoders Write What the Synthesized Ones Wrote

    /// Each record that now writes itself by hand, to put its unknown keys
    /// beside its fields, writes the very bytes Swift's synthesized encoder
    /// wrote for a plain struct of the same fields (the `Plain…` twins
    /// below), with every optional set and with every optional nil; reads
    /// what such a struct wrote; and has the twin's fields, so a field
    /// added to one and forgotten in its encoder fails here.
    func testEachHandWrittenEncoderWritesWhatThePlainStructWrote() throws {
        let book = Self.plainBook()
        let anchor = try XCTUnwrap(book.readingPosition?.anchor)
        let note = try XCTUnwrap(Self.plainRecord().state.transcript)
        let fingerprints = try XCTUnwrap(book.textCacheFingerprint)

        try assertWritesAsPlainStruct(anchor, PlainTextAnchor.self)
        try assertWritesAsPlainStruct(TextAnchor(before: "b", after: "a", fraction: 0.25), PlainTextAnchor.self)
        try assertWritesAsPlainStruct(try XCTUnwrap(book.readingPosition), PlainReadingPosition.self)
        try assertWritesAsPlainStruct(Self.barePosition(), PlainReadingPosition.self)
        try assertWritesAsPlainStruct(try XCTUnwrap(book.bookmarks.first), PlainBookmark.self)
        try assertWritesAsPlainStruct(
            Bookmark(number: 2, chapterIndex: 1, characterOffset: 4, dateCreated: Self.date), PlainBookmark.self
        )
        try assertWritesAsPlainStruct(try XCTUnwrap(book.skippedHeadings?.first), PlainSkippedHeading.self)
        try assertWritesAsPlainStruct(
            SkippedHeading(level: 2, label: "Bare", chapterIndex: 1, characterOffset: 3), PlainSkippedHeading.self
        )
        try assertWritesAsPlainStruct(try XCTUnwrap(book.editedText), PlainEditedText.self)
        try assertWritesAsPlainStruct(try XCTUnwrap(book.handEdits), PlainHandEdits.self)
        try assertWritesAsPlainStruct(try XCTUnwrap(book.feedLink), PlainFeedBookLink.self)
        try assertWritesAsPlainStruct(fingerprints.source, PlainFileFingerprint.self)
        try assertWritesAsPlainStruct(fingerprints, PlainTextCacheFingerprint.self)
        try assertWritesAsPlainStruct(note, PlainTranscriptNote.self)
        try assertWritesAsPlainStruct(
            TranscriptNote(version: 1, locale: "en-GB", createdAt: Self.date), PlainTranscriptNote.self
        )
        try assertWritesAsPlainStruct(try XCTUnwrap(note.source), PlainTranscriptSource.self)
        try assertWritesAsPlainStruct(
            TranscriptSource(origin: .podcast, format: .subRip), PlainTranscriptSource.self
        )
    }

    /// Asserts that `value` is written as the bytes the synthesized encoder
    /// of `Plain`, a struct of the same fields, writes for it; that `value`
    /// reads back from them equal; and that the two have the same fields.
    private func assertWritesAsPlainStruct<Value: Codable & Equatable, Plain: Codable>(
        _ value: Value,
        _ plain: Plain.Type,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let written = try Self.encoder.encode(value)
        let twin = try Self.decoder.decode(Plain.self, from: written)
        let asPlain = try Self.encoder.encode(twin)
        XCTAssertEqual(
            String(decoding: written, as: UTF8.self), String(decoding: asPlain, as: UTF8.self),
            "\(Value.self)", file: file, line: line
        )
        XCTAssertEqual(try Self.decoder.decode(Value.self, from: asPlain), value, "\(Value.self)", file: file, line: line)
        XCTAssertEqual(
            Self.fieldNames(of: value).subtracting(["unknownKeys"]), Self.fieldNames(of: twin),
            "\(Value.self) and \(Plain.self) must have the same fields", file: file, line: line
        )
    }

    /// The names of `value`'s stored properties.
    private static func fieldNames(of value: Any) -> Set<String> {
        Set(Mirror(reflecting: value).children.compactMap(\.label))
    }

    /// A row's encoder writes exactly the keys its decoder knows, when every
    /// field is set; the row reads back equal; and the box holds a field
    /// for each key and nothing else but the unknown keys. So the encoder,
    /// the decoder, and the fields cannot drift apart by a name.
    func testARowsEncoderWritesExactlyTheKeysItsDecoderKnows() throws {
        let book = Self.plainBook()
        let written = try Self.encoder.encode(book)
        let row = try XCTUnwrap(try Self.tree(written) as? [String: Any])

        XCTAssertEqual(Set(row.keys), Book.knownKeyNames)
        XCTAssertEqual(try Self.decoder.decode(Book.self, from: written), book)
        XCTAssertEqual(
            Set(book.reflectedFields.children.compactMap(\.label)).subtracting(["unknownKeys"]),
            Book.knownKeyNames
        )
    }

    // MARK: - Merges Keep Them

    /// Taking an analysis changes the analysis fields and leaves the row's
    /// unknown keys alone, whether the fields are set or an index applied.
    func testAnAnalysisKeepsTheRowsUnknownKeys() {
        let kept = UnknownKeys(["addedLater": .array([.integer(2), .integer(1)])])
        var book = Self.plainBook(seed: 1)
        book.unknownKeys = kept

        book.contentAnalysisFields = Self.plainBook(seed: 2).contentAnalysisFields
        XCTAssertEqual(book.unknownKeys, kept)

        let index = BookContentIndex.build(fromChapters: [Chapter(title: "One", text: "one two three")], format: .txt)
        book.applyContentAnalysis(index, cacheFormatVersion: "9.9.9")
        XCTAssertEqual(book.unknownKeys, kept)
        XCTAssertEqual(book.totalWordCount, 3)
    }

    /// The fields a reader takes from its book's row, the metadata an
    /// editor saves, and a book's own place in the library change their
    /// fields and leave the row's unknown keys alone.
    func testFieldGroupsKeepTheRowsUnknownKeys() {
        let kept = UnknownKeys(["addedLater": .string("stays")])
        let other = Self.plainBook(seed: 2)
        var book = Self.plainBook(seed: 1)
        book.unknownKeys = kept

        book.libraryFields = other.libraryFields
        book.readingState = other.readingState
        book.applyEditableMetadata(from: other)

        XCTAssertEqual(book.unknownKeys, kept)
        XCTAssertEqual(book.title, other.title)
        XCTAssertEqual(book.placedInLibraryFolder().unknownKeys, kept)
    }

    /// A save of a book's state writes a new record from the row and keeps
    /// what the stored record holds that this TextMouth does not know: at
    /// its top level, in its metadata, and in its state. The row's own
    /// unknown keys are never written into the record.
    func testASaveOfABooksStateKeepsTheStoredRecordsUnknownKeys() throws {
        var book = Self.plainBook()
        book.unknownKeys = UnknownKeys(["rowOnly": .bool(true)])
        var stored = book.makeBookInfo()
        stored.unknownKeys = UnknownKeys(["recordLevel": .integer(1)])
        stored.metadata.unknownKeys = UnknownKeys(["metadataLevel": .string("m")])
        stored.state.unknownKeys = UnknownKeys(["stateLevel": .array([.null])])
        stored.state.revision = 4

        book.title = "Changed Since"
        let written = book.bookInfo(
            replacing: StoredBookRecord(info: stored, keepsContentIndex: false), contentIndex: nil
        )

        XCTAssertEqual(written.unknownKeys, stored.unknownKeys)
        XCTAssertEqual(written.metadata.unknownKeys, stored.metadata.unknownKeys)
        XCTAssertEqual(written.state.unknownKeys, stored.state.unknownKeys)
        XCTAssertEqual(written.metadata.title, "Changed Since")
        XCTAssertEqual(written.state.revision, 5)
        // A record with nothing to replace has none.
        let first = book.bookInfo(replacing: nil, contentIndex: nil)
        XCTAssertTrue(first.unknownKeys.isEmpty && first.metadata.unknownKeys.isEmpty && first.state.unknownKeys.isEmpty)
    }

    /// The same through the files: a package whose record holds unknown
    /// keys at every level still holds them all after the book's state is
    /// saved over it, with the book's new state, and after Move to
    /// Library's note is written into it.
    func testSavingOverAPackagesRecordKeepsItsUnknownKeysInTheFile() throws {
        let package = try makeSandboxDirectory("Unknown Keys Save")
        let file = TextMouthPaths.bookInfoPath(in: package)
        var book = Self.plainBook()
        let read = Self.addingUnknownMembers(to: try Self.tree(Self.encoder.encode(book.makeBookInfo())))
        try Self.data(read).write(to: file)
        // The row as the library holds it: read from the same record, so
        // its places carry the keys the record's places hold.
        let record = try BookInfo.load(from: package)
        book = Book(record: record, filePath: book.filePath, folderPath: book.folderPath, tmbDirectoryName: book.tmbDirectoryName)

        book.localVoiceID = "voice.changed"
        try book.saveBookInfoThrowing(inPackageAt: package)

        var expected = try XCTUnwrap(read as? [String: Any])
        var state = try Self.object(in: expected, at: ["state"])
        state["localVoiceID"] = "voice.changed"
        state["revision"] = 1
        expected["state"] = state
        XCTAssertEqual(try Self.tree(Data(contentsOf: file)), expected as NSDictionary)

        // Move to Library's note is one more field; nothing else changes.
        try book.saveBookInfoThrowing(inPackageAt: package, notingMoveToLibraryAt: Self.date)
        var metadata = try Self.object(in: expected, at: ["metadata"])
        metadata["movedToLibrary"] = "2027-01-15T08:00:00Z"
        expected["metadata"] = metadata
        state["revision"] = 2
        expected["state"] = state
        XCTAssertEqual(try Self.tree(Data(contentsOf: file)), expected as NSDictionary)
    }

    /// The reading state that stands between a row and its record: when the
    /// record holds the later place, the row takes the record's places with
    /// the unknown keys those places hold, and keeps its own row's keys.
    func testTheStandingReadingStateBringsItsPlacesKeysAndKeepsTheRows() throws {
        var row = Self.plainBook()
        row.unknownKeys = UnknownKeys(["rowOnly": .integer(9)])
        var later = try XCTUnwrap(row.readingPosition)
        later.characterOffset += 100
        later.lastUpdated = later.lastUpdated.addingTimeInterval(3_600)
        later.unknownKeys = UnknownKeys(["page": .integer(41)])
        var record = row.makeBookInfo()
        record.state.readingPosition = later
        XCTAssertEqual(record.bookmarks.count, 1)
        guard record.bookmarks.count == 1 else { return }
        record.bookmarks[0].unknownKeys = UnknownKeys(["colour": .string("amber")])

        XCTAssertTrue(row.takeStandingReadingState(of: record))

        XCTAssertEqual(row.readingPosition, later)
        XCTAssertEqual(row.readingPosition?.unknownKeys, later.unknownKeys)
        XCTAssertEqual(row.bookmarks.first?.unknownKeys, UnknownKeys(["colour": .string("amber")]))
        XCTAssertEqual(row.unknownKeys, UnknownKeys(["rowOnly": .integer(9)]))

        // The other way: a row with the later place keeps its own.
        var newer = Self.plainBook()
        newer.unknownKeys = UnknownKeys(["rowOnly": .integer(9)])
        var older = newer.makeBookInfo()
        older.state.readingPosition?.lastUpdated = Self.date.addingTimeInterval(-86_400 * 4_000)
        let before = newer
        XCTAssertFalse(newer.takeStandingReadingState(of: older))
        XCTAssertEqual(newer, before)
    }

    /// Replace Existing: the row the new copy becomes keeps the old row's
    /// unknown keys, as it keeps the old row's ID and place in the library.
    func testReplaceExistingKeepsTheOldRowsUnknownKeys() {
        var existing = Self.plainBook(seed: 1)
        existing.unknownKeys = UnknownKeys(["rating": .integer(5)])
        let copy = Self.plainBook(seed: 2)
        let location = Book.FileLocation(folderPath: "Fiction", filePath: "/library/new.txt", tmbDirectoryName: "New.tmb")

        let carried = DuplicateReplacement.carriedBook(
            replacing: existing, with: copy, places: existing.relocatablePlaces, location: location
        )

        XCTAssertEqual(carried.id, existing.id)
        XCTAssertEqual(carried.unknownKeys, existing.unknownKeys)
        XCTAssertEqual(carried.filePath, location.filePath)
    }

    /// A place changed in place keeps its unknown keys (a bookmark renamed,
    /// a place given its words); a place made anew has none.
    func testAPlaceChangedInPlaceKeepsItsKeysAndANewPlaceHasNone() throws {
        var book = Self.plainBook()
        XCTAssertEqual(book.bookmarks.count, 1)
        guard book.bookmarks.count == 1 else { return }
        book.bookmarks[0].unknownKeys = UnknownKeys(["colour": .string("amber")])
        book.readingPosition?.unknownKeys = UnknownKeys(["page": .integer(41)])

        book.bookmarks[0].label = "Renamed"
        book.readingPosition?.characterOffset += 1

        XCTAssertEqual(book.bookmarks[0].unknownKeys, UnknownKeys(["colour": .string("amber")]))
        XCTAssertEqual(book.readingPosition?.unknownKeys, UnknownKeys(["page": .integer(41)]))

        book.readingPosition = ReadingPosition(chapterIndex: 4, characterOffset: 0)
        XCTAssertEqual(book.readingPosition?.unknownKeys, UnknownKeys())
    }

    // MARK: - config.json's Saves and Merges

    /// A setting changed and saved keeps config.json's unknown keys, and
    /// the file holds the new setting.
    @MainActor
    func testASettingChangedAndSavedKeepsConfigJSONsUnknownKeys() throws {
        let url = try makeSandboxDirectory("Unknown Keys Config").appendingPathComponent("config.json")
        var read = try XCTUnwrap(
            try Self.tree(ConfigService.fileData(for: .everyFieldCustomized)) as? [String: Any]
        )
        read[Self.addedKey] = Self.everyKind
        try Self.data(read).write(to: url)
        let service = ConfigService(fileURL: url)
        XCTAssertEqual(service.config.wordsPerMinute, 425)

        service.config.wordsPerMinute = 310
        service.saveToDisk()

        read["wordsPerMinute"] = 310
        XCTAssertEqual(try Self.tree(Data(contentsOf: url)), read as NSDictionary)

        // A second service, as the next launch, reads them and writes
        // nothing: the file already holds exactly what it would write.
        let saved = try Data(contentsOf: url)
        let next = ConfigService(fileURL: url)
        next.saveToDisk()
        XCTAssertEqual(try Data(contentsOf: url), saved)
        XCTAssertEqual(Set(next.config.unknownKeys.members.keys), [Self.addedKey])
    }

    /// The merge of an edit found on disk with a change made here keeps the
    /// change and takes the file's unknown keys, which nothing here changes.
    func testMergingAnEditFoundOnDiskTakesItsUnknownKeys() {
        var base = ConfigService.AppConfig.everyFieldCustomized
        base.unknownKeys = UnknownKeys(["addedLater": .integer(1)])
        var ours = base
        ours.wordsPerMinute = 310
        var theirs = base
        theirs.pitchMultiplier = 1.1
        theirs.unknownKeys = UnknownKeys(["addedLater": .integer(2), "another": .string("new")])

        let merged = ConfigService.merging(ours: ours, theirs: theirs, base: base)

        XCTAssertEqual(merged.wordsPerMinute, 310)
        XCTAssertEqual(merged.pitchMultiplier, 1.1)
        XCTAssertEqual(merged.unknownKeys, theirs.unknownKeys)
    }

    /// A file's unknown keys are no repair: decoding a file that holds some
    /// does not ask for the file to be written again.
    func testUnknownKeysAreNoRepair() throws {
        var read = try XCTUnwrap(
            try Self.tree(ConfigService.fileData(for: .everyFieldCustomized)) as? [String: Any]
        )
        read[Self.addedKey] = Self.everyKind
        let contents = try Self.data(read)
        XCTAssertFalse(ConfigService.decodingRepairedValues(in: contents, decoded: try ConfigService.decode(contents)))
    }

    // MARK: - Equality, Hashing, and Copies

    /// Unknown keys take part in `==`, so a change to one is noticed by
    /// whatever asks whether a row or the settings changed, and not in a
    /// hash, which stays as cheap as it was.
    func testUnknownKeysArePartOfEqualityAndNotOfAHash() {
        let book = Self.plainBook()
        var changed = book
        changed.unknownKeys = UnknownKeys(["addedLater": .integer(1)])
        XCTAssertNotEqual(changed, book)
        XCTAssertEqual(changed.hashValue, book.hashValue)
        XCTAssertNotEqual(Library(books: [changed]), Library(books: [book]))

        var position = Self.barePosition()
        let same = position
        position.unknownKeys = UnknownKeys(["page": .integer(3)])
        XCTAssertNotEqual(position, same)
        XCTAssertEqual(position.hashValue, same.hashValue)

        var config = ConfigService.AppConfig()
        config.unknownKeys = UnknownKeys(["addedLater": .integer(1)])
        XCTAssertNotEqual(config, ConfigService.AppConfig())
    }

    /// A feed link is an identity: a stored link that holds a later
    /// TextMouth's key still equals the link made here for the same item,
    /// and hashes alike, so its book is still found by its item.
    func testAFeedLinkWithUnknownKeysIsStillTheSameLink() throws {
        let feedID = UUID()
        let made = FeedBookLink(feedID: feedID, itemID: "item-1")
        var stored = made
        stored.unknownKeys = UnknownKeys(["enclosure": .integer(2)])

        XCTAssertEqual(stored, made)
        XCTAssertEqual(stored.hashValue, made.hashValue)
        XCTAssertNotEqual(stored, FeedBookLink(feedID: feedID, itemID: "item-2"))
        XCTAssertTrue(Set([made]).contains(stored))
        // And the key is written back all the same.
        let written = try XCTUnwrap(try Self.tree(Self.encoder.encode(stored)) as? [String: Any])
        XCTAssertEqual(written["enclosure"] as? Int, 2)
    }

    /// A feed's index places each of its rows at every save and every
    /// load. A row that already names the feed keeps its link as it is,
    /// unknown keys included; a row that named another feed gets a link
    /// made anew, which has none.
    func testPlacingAFeedsRowKeepsItsLinksUnknownKeys() {
        let feedID = UUID()
        var link = FeedBookLink(feedID: feedID, itemID: "item-1")
        link.unknownKeys = UnknownKeys(["enclosure": .integer(2)])
        var row = Self.plainBook()
        row.feedLink = link
        let root = URL(fileURLWithPath: "/data", isDirectory: true)

        let placed = FeedIndexFiles.placed(row, in: root, of: feedID)
        XCTAssertEqual(placed.feedLink, link)
        XCTAssertEqual(placed.feedLink?.unknownKeys, link.unknownKeys)

        let otherFeed = UUID()
        let moved = FeedIndexFiles.placed(row, in: root, of: otherFeed)
        XCTAssertEqual(moved.feedLink, FeedBookLink(feedID: otherFeed, itemID: "item-1"))
        XCTAssertEqual(moved.feedLink?.unknownKeys, UnknownKeys())
    }

    /// A book's unknown keys are in its box: a copy shares them, and
    /// writing a copy's leaves the original's as they were.
    func testACopysUnknownKeysAreItsOwn() {
        var original = Self.plainBook()
        original.unknownKeys = UnknownKeys(["addedLater": .integer(1)])
        var copy = original
        copy.unknownKeys = UnknownKeys(["addedLater": .integer(2)])
        XCTAssertEqual(original.unknownKeys, UnknownKeys(["addedLater": .integer(1)]))
        copy.title = "Another"
        XCTAssertEqual(copy.unknownKeys, UnknownKeys(["addedLater": .integer(2)]))
    }

    // MARK: - What Keeping Them Costs

    /// Measures loading and saving a library index of 1,500 rows, without
    /// unknown keys and with one in every row, and prints the medians. It
    /// asserts only that the work ran, since timings on a busy Mac prove
    /// nothing; the numbers are compared between a build with V04 and one
    /// without.
    func testTimingsOfLoadingAndSaving1500Rows() throws {
        let plain = (0..<1500).map { index -> Book in
            var book = Self.plainBook(seed: 1 + index % 7)
            book.feedLink = nil
            book.manualSortOrder = index
            return book
        }
        let data = try LibraryPersistenceService.encodedIndex(Library(books: plain))
        var withKeys = plain
        for index in withKeys.indices {
            withKeys[index].unknownKeys = UnknownKeys(["addedLater": .integer(Int64(index)), "also": .string("text")])
        }
        let dataWithKeys = try LibraryPersistenceService.encodedIndex(Library(books: withKeys))

        /// The median of nine runs of `work`, in milliseconds.
        func median(_ work: () throws -> Void) rethrows -> Double {
            var times: [Double] = []
            for _ in 0..<9 {
                let start = DispatchTime.now().uptimeNanoseconds
                try work()
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            return times.sorted().dropFirst(times.count / 2).first ?? 0
        }

        var rows = 0
        let load = try median { rows &+= try LibraryPersistenceService.decodeIndex(from: data).books.count }
        let loaded = try LibraryPersistenceService.decodeIndex(from: data)
        let save = try median { rows &+= try LibraryPersistenceService.encodedIndex(loaded).count }
        let loadWithKeys = try median { rows &+= try LibraryPersistenceService.decodeIndex(from: dataWithKeys).books.count }
        let loadedWithKeys = try LibraryPersistenceService.decodeIndex(from: dataWithKeys)
        let saveWithKeys = try median { rows &+= try LibraryPersistenceService.encodedIndex(loadedWithKeys).count }

        print("UNKNOWNKEYS library.json of 1500 rows: \(data.count) bytes")
        print("UNKNOWNKEYS load \(load) ms, save \(save) ms (no unknown keys)")
        print("UNKNOWNKEYS load \(loadWithKeys) ms, save \(saveWithKeys) ms (two unknown keys in every row)")
        XCTAssertGreaterThan(rows, 0)
        XCTAssertEqual(loadedWithKeys.books.count, 1500)
    }
}

// MARK: - Plain Structs of the Same Fields

// Each is the record as it was before V04: a struct whose coding Swift
// synthesizes. `testEachHandWrittenEncoderWritesWhatThePlainStructWrote`
// holds the hand-written coding of the real record to it.

private struct PlainTextAnchor: Codable {
    var before: String
    var after: String
    var fraction: Double
    var measuredIn: String?
    var version: Int
}

private struct PlainReadingPosition: Codable {
    var chapterIndex: Int
    var headingIndex: Int?
    var characterOffset: Int
    var globalCharacterOffset: Int?
    var lastUpdated: Date
    var anchor: PlainTextAnchor?
}

private struct PlainBookmark: Codable {
    let id: UUID
    var number: Int
    var chapterIndex: Int
    var characterOffset: Int
    var label: String
    var dateCreated: Date
    var anchor: PlainTextAnchor?
}

private struct PlainSkippedHeading: Codable {
    var level: Int
    var label: String
    var chapterIndex: Int
    var characterOffset: Int
    var anchor: PlainTextAnchor?
}

private struct PlainEditedText: Codable {
    var cacheDigest: String
    var takenAt: Date
}

private struct PlainHandEdits: Codable {
    var fields: [String]
    var sinceImport: Bool
}

private struct PlainFeedBookLink: Codable {
    let feedID: UUID
    let itemID: String
}

private struct PlainFileFingerprint: Codable {
    var byteCount: Int64
    var modificationTimeNanoseconds: Int64
    var digest: String
}

private struct PlainTextCacheFingerprint: Codable {
    var source: PlainFileFingerprint
    var cache: PlainFileFingerprint
}

private struct PlainTranscriptSource: Codable {
    var origin: String
    var format: String
    var fileName: String?
    var formats: [String]?
}

private struct PlainTranscriptNote: Codable {
    var version: Int
    var locale: String
    var createdAt: Date
    var source: PlainTranscriptSource?
}

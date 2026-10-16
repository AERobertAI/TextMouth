import XCTest
@testable import TextMouth

/// The listening options of a feed or a plain folder as data (FR19, task A):
/// the type, where a feed and a folder keep it, how it reads and saves, the
/// setters and lookups, the global setting's reader, and the words of its
/// controls.
@MainActor
final class ListeningOptionsTests: XCTestCase {

    // MARK: - The Type

    /// The standard options follow the global setting, skip finished items,
    /// and download the next one; they are the only options that are
    /// standard.
    func testTheDefaultsAreTheStandardOptions() {
        let options = ListeningOptions()
        XCTAssertNil(options.continuation)
        XCTAssertTrue(options.skipsFinished)
        XCTAssertTrue(options.predownloadsNext)
        XCTAssertEqual(options, .standard)
        XCTAssertTrue(options.isStandard)

        XCTAssertFalse(ListeningOptions(continuation: .stop).isStandard)
        XCTAssertFalse(ListeningOptions(skipsFinished: false).isStandard)
        XCTAssertFalse(ListeningOptions(predownloadsNext: false).isStandard)
    }

    /// The pre-download begins ten minutes before the end.
    func testThePredownloadLeadTimeIsTenMinutes() {
        XCTAssertEqual(ListeningOptions.predownloadLeadTime, 600)
    }

    /// Whether listening goes on, for every continuation under every global
    /// behavior: the choice of its own decides, and "Use the global setting"
    /// follows Continue to Next Book alone.
    func testGoesOnForEveryContinuationUnderEveryGlobalBehavior() {
        let continuations: [ReadingList.Continuation?] = [nil, .playBookBelow, .playBookAbove, .stop]
        for continuation in continuations {
            for global in EndOfBookBehavior.allCases {
                let expected: Bool
                switch continuation {
                case .playBookBelow, .playBookAbove: expected = true
                case .stop: expected = false
                case nil: expected = global == .continueNext
                }
                XCTAssertEqual(
                    ListeningOptions(continuation: continuation).goesOn(under: global),
                    expected,
                    "\(String(describing: continuation)) under \(global.rawValue)"
                )
            }
        }
    }

    /// Options round-trip through the coding every record uses.
    func testOptionsRoundTrip() throws {
        let options = ListeningOptions(continuation: .playBookAbove, skipsFinished: false, predownloadsNext: false)
        let data = try JSONEncoder().encode(options)
        XCTAssertEqual(try JSONDecoder().decode(ListeningOptions.self, from: data), options)
    }

    // MARK: - A Feed's Options

    /// A feed's options round-trip through its record; a feed with none
    /// writes no key for them, so its record file is exactly what it was; a
    /// record written before the field loads with nil.
    func testAFeedsOptionsRoundTripAndAnOlderRecordLoadsWithoutThem() throws {
        var record = FeedRecordTests.record(itemCount: 2)
        XCTAssertNil(record.feed.listeningOptions, "a new subscription has no options of its own")
        XCTAssertNil(try Self.feedObject(of: record)["listeningOptions"], "nothing is written for none")

        record.feed.listeningOptions = ListeningOptions(continuation: .playBookAbove, skipsFinished: false)
        let data = try FeedRecordCoding.encoder().encode(record)
        XCTAssertEqual(try FeedRecordCoding.decoder().decode(FeedRecord.self, from: data), record)

        // The same file as a TextMouth that knew no options wrote it.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var feed = try XCTUnwrap(object["feed"] as? [String: Any])
        XCTAssertNotNil(feed.removeValue(forKey: "listeningOptions"), "the record wrote the options")
        object["feed"] = feed
        let older = try FeedRecordCoding.decoder().decode(
            FeedRecord.self, from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(older.feed.listeningOptions)
        record.feed.listeningOptions = nil
        XCTAssertEqual(older, record)
    }

    // MARK: - Reading Leniently

    /// An unknown continuation reads as none, a value of the wrong type as
    /// the default, and a key that is right is kept.
    func testUnreadableChoicesReadAsTheirDefaults() throws {
        let json = #"{"continuation":"playBookSideways","skipsFinished":"yes","predownloadsNext":false}"#
        let options = try JSONDecoder().decode(ListeningOptions.self, from: Data(json.utf8))
        XCTAssertNil(options.continuation)
        XCTAssertTrue(options.skipsFinished)
        XCTAssertFalse(options.predownloadsNext)

        let empty = try JSONDecoder().decode(ListeningOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, .standard, "missing keys read as the defaults")
    }

    /// A feed record whose options are not an object still decodes, and the
    /// options read as standard: a feed the listener loses over a damaged
    /// field would be worse than a lost choice.
    func testAFeedWhoseOptionsAreNotAnObjectStillLoads() throws {
        let record = FeedRecordTests.record(itemCount: 1)
        for damaged in [5, "x", [1, 2], true] as [Any] {
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: FeedRecordCoding.encoder().encode(record)) as? [String: Any]
            )
            var feed = try XCTUnwrap(object["feed"] as? [String: Any])
            feed["listeningOptions"] = damaged
            object["feed"] = feed
            let data = try JSONSerialization.data(withJSONObject: object)
            let loaded = try FeedRecordCoding.decoder().decode(FeedRecord.self, from: data)
            XCTAssertEqual(loaded.feed.listeningOptions ?? .standard, .standard, "\(damaged)")
            XCTAssertEqual(loaded.feed.title, record.feed.title, "the rest of the feed is kept")
        }
    }

    // MARK: - A Folder's Options

    /// A folder's options round-trip inside the library index; an index
    /// written before the field loads with nil; a folder with none writes
    /// no key; and a folder whose options are damaged still loads, as
    /// standard, with the rest of the index.
    func testAFoldersOptionsRoundTripInTheLibraryIndex() throws {
        var folder = BookFolder(name: "Dramas")
        let plain = BookFolder(name: "Plain")
        folder.listeningOptions = ListeningOptions(continuation: .stop, skipsFinished: false)
        let library = Library(folders: [folder, plain])

        let data = try LibraryIndexSandbox.encoded(library)
        let rows = try Self.folderRows(in: data)
        XCTAssertNotNil(rows[0]["listeningOptions"])
        XCTAssertNil(rows[1]["listeningOptions"], "a folder with none writes no key")
        let loaded = try Self.decodeIndex(data)
        XCTAssertEqual(loaded.folders.map(\.listeningOptions), [folder.listeningOptions, nil])

        // An index written before the field.
        let older = try Self.editedIndex(data) { rows in
            for index in rows.indices { rows[index].removeValue(forKey: "listeningOptions") }
        }
        XCTAssertEqual(try Self.decodeIndex(older).folders.map(\.listeningOptions), [nil, nil])

        // Damaged options read as standard and cost the library nothing.
        let damaged = try Self.editedIndex(data) { rows in rows[0]["listeningOptions"] = 5 }
        let survivor = try Self.decodeIndex(damaged)
        XCTAssertEqual(survivor.folders.count, 2)
        XCTAssertEqual(survivor.folders[0].listeningOptions ?? .standard, .standard)
    }

    /// Renaming or moving a folder changes its name and parent in place, so
    /// its options go with it.
    func testTheOptionsSurviveRenamingAndMovingTheFolder() throws {
        var folder = BookFolder(name: "Dramas")
        let options = ListeningOptions(continuation: .playBookAbove)
        folder.listeningOptions = options
        let destination = BookFolder(name: "Archive")
        var library = Library(folders: [folder, destination])

        XCTAssertTrue(library.renameFolder(id: folder.id, to: "Radio Dramas"))
        XCTAssertEqual(library.folders.first { $0.id == folder.id }?.listeningOptions, options)
        XCTAssertTrue(library.moveFolder(id: folder.id, toParentPath: "Archive"))
        let moved = try XCTUnwrap(library.folders.first { $0.id == folder.id })
        XCTAssertEqual(moved.fullPath, "Archive/Radio Dramas")
        XCTAssertEqual(moved.listeningOptions, options)
    }

    /// The repair of duplicate folder rows keeps the survivor's own options,
    /// else takes the first duplicate's that has some, and loses none.
    func testMergingDuplicateFoldersKeepsTheirOptions() {
        let own = ListeningOptions(continuation: .stop)
        let firstDuplicate = ListeningOptions(continuation: .playBookAbove)
        let secondDuplicate = ListeningOptions(skipsFinished: false)

        // The survivor's own options win.
        var withOwn = Self.duplicateRows(options: [own, firstDuplicate, secondDuplicate])
        _ = withOwn.mergeEquivalentFolders(equivalence: .caseInsensitive)
        XCTAssertEqual(withOwn.folders.map(\.listeningOptions), [own])

        // With none of its own, the survivor takes the first that has some.
        var withoutOwn = Self.duplicateRows(options: [nil, nil, secondDuplicate])
        _ = withoutOwn.mergeEquivalentFolders(equivalence: .caseInsensitive)
        XCTAssertEqual(withoutOwn.folders.map(\.listeningOptions), [secondDuplicate])

        var earlierFirst = Self.duplicateRows(options: [nil, firstDuplicate, secondDuplicate])
        _ = earlierFirst.mergeEquivalentFolders(equivalence: .caseInsensitive)
        XCTAssertEqual(earlierFirst.folders.map(\.listeningOptions), [firstDuplicate])

        // None anywhere stays none.
        var neither = Self.duplicateRows(options: [nil, nil, nil])
        _ = neither.mergeEquivalentFolders(equivalence: .caseInsensitive)
        XCTAssertEqual(neither.folders.map(\.listeningOptions), [nil])
    }

    // MARK: - Fixtures

    /// A library of three rows for one directory spelled "Reports",
    /// "reports", and "REPORTS", holding `options` in that order.
    private static func duplicateRows(options: [ListeningOptions?]) -> Library {
        let names = ["Reports", "reports", "REPORTS"]
        let folders = zip(names, options).map { name, options -> BookFolder in
            var folder = BookFolder(name: name)
            folder.listeningOptions = options
            return folder
        }
        return Library(folders: folders)
    }

    /// The feed object of a record as its file writes it.
    private static func feedObject(of record: FeedRecord) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: FeedRecordCoding.encoder().encode(record)) as? [String: Any]
        return try XCTUnwrap(object?["feed"] as? [String: Any])
    }

    /// The folder rows of an index as JSON objects.
    private static func folderRows(in data: Data) throws -> [[String: Any]] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["folders"] as? [[String: Any]])
    }

    /// An index whose folder rows `edit` has changed.
    private static func editedIndex(_ data: Data, _ edit: (inout [[String: Any]]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var rows = try folderRows(in: data)
        edit(&rows)
        object["folders"] = rows
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// An index read the way every index read reads it.
    private static func decodeIndex(_ data: Data) throws -> Library {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Library.self, from: data)
    }
}

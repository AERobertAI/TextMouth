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

    // MARK: - The Setters

    /// Setting a feed's options changes its record and writes it; standard
    /// options, and none, are stored as nil and leave the record file
    /// exactly as it was; the same options again write nothing.
    func testSettingAFeedsOptionsChangesAndWritesItsRecord() async throws {
        let world = try FeedTestWorld(self, label: "ListeningOptionsFeedSet")
        let record = FeedRecordTests.record(itemCount: 1, folderID: world.bookFolder.id)
        let feedID = record.feed.id
        let store = world.center.store
        let file = FeedPaths.recordFile(of: feedID, in: world.recordsFolder)
        store.add(record)
        await store.flush()
        let original = try Data(contentsOf: file)

        let options = ListeningOptions(continuation: .stop, predownloadsNext: false)
        world.center.setListeningOptions(options, of: feedID)
        await store.flush()
        XCTAssertEqual(store.record(of: feedID)?.feed.listeningOptions, options)
        let written = try FeedRecordCoding.decoder().decode(FeedRecord.self, from: Data(contentsOf: file))
        XCTAssertEqual(written.feed.listeningOptions, options, "the record on disk holds them")

        // The same options again write nothing: a file removed stays removed.
        try FileManager.default.removeItem(at: file)
        world.center.setListeningOptions(options, of: feedID)
        await store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "an unchanged value was written")

        // Standard options are stored as none: the file is what it was.
        world.center.setListeningOptions(.standard, of: feedID)
        await store.flush()
        XCTAssertNil(store.record(of: feedID)?.feed.listeningOptions)
        XCTAssertEqual(try Data(contentsOf: file), original, "the record file is byte for byte what it was")

        // None, when there are none, writes nothing either.
        try FileManager.default.removeItem(at: file)
        world.center.setListeningOptions(nil, of: feedID)
        await store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        // A feed that is not here changes nothing.
        world.center.setListeningOptions(options, of: UUID())
        await store.flush()
        XCTAssertNil(store.record(of: feedID)?.feed.listeningOptions)
    }

    /// Setting a folder's options changes the folder and saves the index
    /// once; standard options, none, a value the folder already has, and a
    /// folder that is not here change and save nothing.
    func testSettingAFoldersOptionsChangesTheFolderAndSavesOnce() throws {
        // The index the save writes is the test's own, put back at the end.
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        let folder = BookFolder(name: "Dramas")
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(folders: [folder])
        let changes = LibraryChangeCounter(model)
        let options = ListeningOptions(continuation: .playBookAbove, skipsFinished: false)

        model.setListeningOptions(options, ofFolder: folder.id)
        XCTAssertEqual(model.listeningOptions(ofFolder: folder.id), options)
        XCTAssertEqual(changes.count, 1)
        model.setListeningOptions(options, ofFolder: folder.id)
        model.setListeningOptions(options, ofFolder: UUID())
        XCTAssertEqual(changes.count, 1, "an unchanged value or an unknown folder changed the library")
        XCTAssertNil(model.listeningOptions(ofFolder: UUID()))

        LibraryPersistenceService.flushPendingSave()
        let saved = try Self.decodeIndex(Data(contentsOf: sandbox.indexURL))
        XCTAssertEqual(saved.folders.first?.listeningOptions, options)

        // Standard options are stored as none.
        model.setListeningOptions(.standard, ofFolder: folder.id)
        XCTAssertNil(model.listeningOptions(ofFolder: folder.id))
        XCTAssertNil(model.library.folders.first?.listeningOptions, "standard options were stored")
        XCTAssertEqual(changes.count, 2)
        model.setListeningOptions(nil, ofFolder: folder.id)
        XCTAssertEqual(changes.count, 2, "none, when there are none, changed the library")
    }

    // MARK: - The Options That Govern a Book

    /// A feed's item is governed by its feed's options; a book in a plain
    /// folder by that folder's, not those of a folder above it; and a book
    /// at the top level, in a folder with none, or whose feed's record is
    /// gone, by none.
    func testTheOptionsThatGovernABook() throws {
        let world = try FeedTestWorld(self, label: "ListeningOptionsGovern")
        let options = ListeningOptions(continuation: .playBookAbove)
        let folderOptions = ListeningOptions(continuation: .stop, skipsFinished: false)
        var record = FeedRecordTests.record(itemCount: 1, folderID: world.bookFolder.id)
        record.feed.listeningOptions = options
        world.center.store.add(record)

        var dramas = BookFolder(name: "Dramas")
        dramas.listeningOptions = folderOptions
        let sub = BookFolder(name: "Season One", parentPath: "Dramas")
        let plain = BookFolder(name: "Plain")
        world.library.library = Library(folders: [world.bookFolder, dramas, sub, plain])

        func book(in folder: String) -> Book {
            Book(title: "Book", format: .txt, filePath: "/tmp/Book.txt", md5Hash: "Book", folderPath: folder)
        }
        var feedItem = book(in: world.bookFolder.fullPath)
        feedItem.feedLink = FeedBookLink(feedID: record.feed.id, itemID: "guid:ep-1")
        XCTAssertEqual(world.library.listeningOptions(of: feedItem), options)

        var orphan = book(in: world.bookFolder.fullPath)
        orphan.feedLink = FeedBookLink(feedID: UUID(), itemID: "guid:ep-1")
        XCTAssertNil(world.library.listeningOptions(of: orphan), "a feed whose record is gone")

        XCTAssertEqual(world.library.listeningOptions(of: book(in: "Dramas")), folderOptions)
        XCTAssertNil(world.library.listeningOptions(of: book(in: "Dramas/Season One")), "a subfolder inherits nothing")
        XCTAssertNil(world.library.listeningOptions(of: book(in: "Plain")), "a folder with none")
        XCTAssertNil(world.library.listeningOptions(of: book(in: "")), "the top level has none")
        XCTAssertNil(world.library.listeningOptions(of: book(in: "Missing")), "a folder that is not here")
    }

    // MARK: - The Global Setting's Reader

    /// An enum setting is read from a store as Settings reads it: a missing
    /// key and an unknown raw value read as the rule's default, and a known
    /// raw value as its case.
    func testAnEnumRuleReadsItsStoredValue() throws {
        let suite = "ListeningOptionsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let rule = SettingsPolicy.endOfBookBehavior

        XCTAssertEqual(rule.storedValue(in: defaults), rule.defaultValue, "no key")
        defaults.set(EndOfBookBehavior.loop.rawValue, forKey: rule.key)
        XCTAssertEqual(rule.storedValue(in: defaults), .loop)
        defaults.set(EndOfBookBehavior.continueNext.rawValue, forKey: rule.key)
        XCTAssertEqual(rule.storedValue(in: defaults), .continueNext)
        defaults.set("Play Something Else", forKey: rule.key)
        XCTAssertEqual(rule.storedValue(in: defaults), rule.defaultValue, "an unknown raw value")
        defaults.set(5, forKey: rule.key)
        XCTAssertEqual(rule.storedValue(in: defaults), rule.defaultValue, "a value of the wrong type")
    }

    // MARK: - The Wording

    /// The nouns, and the one a feed's noun becomes.
    func testTheNounsAndTheArticleBeforeEach() {
        typealias Noun = ListeningOptionsWording.Noun
        XCTAssertEqual(Noun(.episode), .episode)
        XCTAssertEqual(Noun(.article), .article)
        XCTAssertEqual(Noun(.item), .item)
        let expected: [(Noun, String, String, String)] = [
            (.episode, "episode", "episodes", "an"),
            (.article, "article", "articles", "an"),
            (.item, "item", "items", "an"),
            (.book, "book", "books", "a"),
        ]
        for (noun, singular, plural, article) in expected {
            XCTAssertEqual(noun.singular, singular)
            XCTAssertEqual(noun.plural, plural)
            XCTAssertEqual(noun.article, article)
        }
    }

    /// The label of the choice of what happens when an item ends.
    func testTheContinuationLabelForEveryNoun() {
        XCTAssertEqual(ListeningOptionsWording.continuationLabel(.episode), "When an episode ends")
        XCTAssertEqual(ListeningOptionsWording.continuationLabel(.article), "When an article ends")
        XCTAssertEqual(ListeningOptionsWording.continuationLabel(.item), "When an item ends")
        XCTAssertEqual(ListeningOptionsWording.continuationLabel(.book), "When a book ends")
    }

    /// The names of the four choices, the first naming the global setting's
    /// own value, whatever that is.
    func testTheContinuationChoicesForEveryNoun() {
        for noun in [ListeningOptionsWording.Noun.episode, .article, .item, .book] {
            XCTAssertEqual(
                ListeningOptionsWording.continuationTitle(.playBookBelow, noun: noun, global: .stop),
                "Play the \(noun.singular) below"
            )
            XCTAssertEqual(
                ListeningOptionsWording.continuationTitle(.playBookAbove, noun: noun, global: .stop),
                "Play the \(noun.singular) above"
            )
            XCTAssertEqual(ListeningOptionsWording.continuationTitle(.stop, noun: noun, global: .continueNext), "Stop")
            XCTAssertEqual(
                ListeningOptionsWording.continuationTitle(nil, noun: noun, global: .continueNext),
                "Use the global setting (Continue to Next Book)"
            )
        }
        XCTAssertEqual(
            ListeningOptionsWording.continuationTitle(.playBookBelow, noun: .episode, global: .stop),
            "Play the episode below"
        )
        XCTAssertEqual(
            ListeningOptionsWording.continuationTitle(.playBookAbove, noun: .book, global: .stop),
            "Play the book above"
        )
        for global in EndOfBookBehavior.allCases {
            XCTAssertEqual(
                ListeningOptionsWording.continuationTitle(nil, noun: .episode, global: global),
                "Use the global setting (\(global.rawValue))"
            )
        }
        XCTAssertEqual(
            ListeningOptionsWording.continuationTitle(nil, noun: .book, global: .stopAndPlayStartsOver),
            "Use the global setting (Stop, and Play Starts Over)"
        )
    }

    /// The hint of the choice, for a feed's nouns and for a folder's books.
    func testTheContinuationHintForEveryNoun() {
        XCTAssertEqual(
            ListeningOptionsWording.continuationHint(.episode),
            "What happens when one of this feed's episodes ends: play the episode below it or the one above it in the list, stop, or follow the global setting"
        )
        XCTAssertEqual(
            ListeningOptionsWording.continuationHint(.article),
            "What happens when one of this feed's articles ends: play the article below it or the one above it in the list, stop, or follow the global setting"
        )
        XCTAssertEqual(
            ListeningOptionsWording.continuationHint(.item),
            "What happens when one of this feed's items ends: play the item below it or the one above it in the list, stop, or follow the global setting"
        )
        XCTAssertEqual(
            ListeningOptionsWording.continuationHint(.book),
            "What happens when one of this folder's books ends: play the book below it or the one above it in the folder, stop, or follow the global setting"
        )
    }

    /// The label and hint of the switch that passes over finished items.
    func testTheSkipFinishedWordingForEveryNoun() {
        XCTAssertEqual(ListeningOptionsWording.skipFinishedLabel(.episode), "Skip finished episodes")
        XCTAssertEqual(ListeningOptionsWording.skipFinishedLabel(.article), "Skip finished articles")
        XCTAssertEqual(ListeningOptionsWording.skipFinishedLabel(.item), "Skip finished items")
        XCTAssertEqual(ListeningOptionsWording.skipFinishedLabel(.book), "Skip finished books")
        XCTAssertEqual(
            ListeningOptionsWording.skipFinishedHint(.episode),
            "When listening goes on to another episode, pass over the episodes already finished"
        )
        XCTAssertEqual(
            ListeningOptionsWording.skipFinishedHint(.article),
            "When listening goes on to another article, pass over the articles already finished"
        )
        XCTAssertEqual(
            ListeningOptionsWording.skipFinishedHint(.item),
            "When listening goes on to another item, pass over the items already finished"
        )
        XCTAssertEqual(
            ListeningOptionsWording.skipFinishedHint(.book),
            "When listening goes on to another book, pass over the books already finished"
        )
    }

    /// The label and both hints of the switch that downloads the next item;
    /// the minutes are the lead time's.
    func testTheDownloadNextWordingForEveryNoun() {
        XCTAssertEqual(ListeningOptionsWording.predownloadLabel(.episode), "Download the next episode before this one ends")
        XCTAssertEqual(ListeningOptionsWording.predownloadLabel(.article), "Download the next article before this one ends")
        XCTAssertEqual(ListeningOptionsWording.predownloadLabel(.item), "Download the next item before this one ends")
        XCTAssertEqual(
            ListeningOptionsWording.predownloadHint(.episode, enabled: true),
            "When 10 minutes or less of the episode playing are left, download the episode that plays next, if it is not on this Mac yet"
        )
        XCTAssertEqual(
            ListeningOptionsWording.predownloadHint(.article, enabled: true),
            "When 10 minutes or less of the article playing are left, download the article that plays next, if it is not on this Mac yet"
        )
        XCTAssertEqual(
            ListeningOptionsWording.predownloadHint(.item, enabled: true),
            "When 10 minutes or less of the item playing are left, download the item that plays next, if it is not on this Mac yet"
        )
        XCTAssertEqual(
            ListeningOptionsWording.predownloadHint(.episode, enabled: false),
            "Available only while this feed's episodes go on to another episode when one ends"
        )
        XCTAssertEqual(
            ListeningOptionsWording.predownloadHint(.article, enabled: false),
            "Available only while this feed's articles go on to another article when one ends"
        )
        XCTAssertEqual(
            ListeningOptionsWording.predownloadHint(.item, enabled: false),
            "Available only while this feed's items go on to another item when one ends"
        )
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

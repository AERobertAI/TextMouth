import XCTest
@testable import TextMouth

/// The Library views' value types (the design of October 30, 2026,
/// LIBRARY-VIEWS-RESEARCH-2026-10-30.md, sections 2, 3, 4, and 8): the
/// identities and the names they are stored by, the views TextMouth ships,
/// the keys their sorts are saved under, which rows each condition tests,
/// and one view's entry in config.json, written and read back, with every
/// entry that cannot be read refused and every value out of range repaired.
final class LibraryViewDefinitionTests: XCTestCase {

    // MARK: - Identities

    /// The built-in views come in the order TextMouth ships them, the five
    /// categories first, in their picker's old order, then Feeds.
    func testTheBuiltInViewsComeInTheirShippedOrder() {
        XCTAssertEqual(
            LibraryViewID.builtIns,
            [.category(.folders), .category(.allItems), .category(.unopened), .category(.recent), .category(.readingList), .feeds]
        )
        XCTAssertTrue(LibraryViewID.builtIns.allSatisfy(\.isBuiltIn))
        XCTAssertFalse(LibraryViewID.custom(UUID()).isBuiltIn)
    }

    /// Every identity is stored as text and read back the same; a category
    /// saved under a former name reads as the category it became; anything
    /// else is no identity.
    func testIdentitiesAreStoredAsTextAndReadBack() throws {
        let uuid = UUID()
        let stored: [LibraryViewID: String] = [
            .category(.folders): "Folders",
            .category(.allItems): "All Items",
            .category(.unopened): "Unopened",
            .category(.recent): "Recently Opened",
            .category(.readingList): "Reading List",
            .feeds: "Feeds",
            .custom(uuid): uuid.uuidString,
        ]
        for (id, text) in stored {
            XCTAssertEqual(id.storedValue, text)
            XCTAssertEqual(LibraryViewID(storedValue: text), id, text)
        }
        XCTAssertEqual(LibraryViewID(storedValue: "No Folder"), .category(.unopened))
        XCTAssertEqual(LibraryViewID(storedValue: "Recent"), .category(.recent))
        XCTAssertEqual(LibraryViewID(storedValue: uuid.uuidString.lowercased()), .custom(uuid))
        for unknown in ["", "feeds", "folders", "Audiobooks", "6F9619FF-8B86"] {
            XCTAssertNil(LibraryViewID(storedValue: unknown), unknown)
        }
        XCTAssertEqual(LibraryViewID.category(.unopened).category, .unopened)
        XCTAssertNil(LibraryViewID.feeds.category)
    }

    /// A category is read by its own name or a former one, and by nothing
    /// else, the one rule the decoder and the views' identities share.
    func testACategoryIsReadByItsNameOrAFormerOne() {
        for category in LibraryCategory.allCases {
            XCTAssertEqual(LibraryCategory(savedName: category.rawValue), category)
        }
        XCTAssertEqual(LibraryCategory(savedName: "No Folder"), .unopened)
        XCTAssertEqual(LibraryCategory(savedName: "Recent"), .recent)
        XCTAssertNil(LibraryCategory(savedName: "Feeds"))
        XCTAssertNil(LibraryCategory(savedName: "unopened"))
    }

    // MARK: - The Shipped Views

    /// The views TextMouth ships, each named as before, with the filters
    /// that list what the five categories always listed, and Feeds offered
    /// when applicable.
    func testTheShippedViews() throws {
        let folders = LibraryViewDefinition.shipped(.folders)
        XCTAssertEqual(folders.name, "Folders")
        XCTAssertEqual(folders.kind, .folders)
        XCTAssertNil(folders.filter)

        let readingList = LibraryViewDefinition.shipped(.readingList)
        XCTAssertEqual(readingList.name, "Reading List")
        XCTAssertEqual(readingList.kind, .readingList)
        XCTAssertNil(readingList.filter)

        let allItems = try XCTUnwrap(LibraryViewDefinition.shipped(.allItems).filter)
        XCTAssertEqual(allItems, LibraryViewFilter(lists: [.books, .feeds]))

        let unopened = try XCTUnwrap(LibraryViewDefinition.shipped(.unopened).filter)
        XCTAssertEqual(unopened.lists, [.books, .feeds])
        XCTAssertEqual(unopened.match, .all)
        XCTAssertEqual(unopened.conditions, [
            LibraryViewCondition(test: .readingState(.unopened)),
            LibraryViewCondition(test: .hasNewItems),
        ])
        XCTAssertFalse(unopened.onePerFeed)
        XCTAssertNil(unopened.limit)

        let recent = try XCTUnwrap(LibraryViewDefinition.shipped(.recent).filter)
        XCTAssertEqual(recent.lists, [.books, .episodes, .articles])
        XCTAssertEqual(recent.conditions, [LibraryViewCondition(test: .readingState(.unopened), isNegated: true)])
        XCTAssertTrue(recent.onePerFeed)
        XCTAssertEqual(recent.limit, LibraryViewLimit(count: 10, chosenBy: .lastOpened))
        XCTAssertEqual(LibraryBookSorter.recentlyOpenedCount, 10)

        let feeds = try XCTUnwrap(LibraryViewDefinition.shipped(.feeds))
        XCTAssertEqual(feeds.name, "Feeds")
        XCTAssertEqual(feeds.visibility, .whenApplicable)
        XCTAssertEqual(feeds.filter, LibraryViewFilter(lists: [.feeds]))
        XCTAssertEqual(feeds.kind, .filter)
        XCTAssertTrue(feeds.filter?.listsOnlyFeeds ?? false)
        XCTAssertFalse(feeds.filter?.listsItems ?? true)

        for category in LibraryCategory.allCases {
            let view = LibraryViewDefinition.shipped(category)
            XCTAssertEqual(view.name, category.rawValue)
            XCTAssertEqual(view.visibility, .always)
            XCTAssertEqual(LibraryViewDefinition.shipped(LibraryViewID.category(category)), view)
            XCTAssertFalse(view.differsFromShipped)
        }
        XCTAssertNil(LibraryViewDefinition.shipped(LibraryViewID.custom(UUID())))
    }

    /// Only a built-in view's name or filter makes it differ from the one
    /// TextMouth ships; a custom view never does.
    func testABuiltInViewDiffersFromShippedByItsNameOrFilter() throws {
        var unopened = LibraryViewDefinition.shipped(.unopened)
        unopened.visibility = .hidden
        XCTAssertFalse(unopened.differsFromShipped)
        unopened.name = "New"
        XCTAssertTrue(unopened.differsFromShipped)
        unopened.name = "Unopened"
        unopened.filter?.match = .any
        XCTAssertTrue(unopened.differsFromShipped)
        XCTAssertFalse(Self.custom("Mine").differsFromShipped)
    }

    // MARK: - Sorts

    /// Folders keeps each folder's sort under its path, the other four
    /// categories under their reserved keys, as before, and Feeds and custom
    /// views under a key that begins with "/", which no folder path can, so
    /// no folder name needs reserving.
    func testEachViewHasTheKeyItsSortIsSavedUnder() {
        XCTAssertNil(LibraryViewDefinition.shipped(.folders).sortSettingsKey)
        XCTAssertEqual(LibraryViewDefinition.shipped(.allItems).sortSettingsKey, "__allItems__")
        XCTAssertEqual(LibraryViewDefinition.shipped(.unopened).sortSettingsKey, "__unopened__")
        XCTAssertEqual(LibraryViewDefinition.shipped(.recent).sortSettingsKey, "__recent__")
        XCTAssertEqual(LibraryViewDefinition.shipped(.readingList).sortSettingsKey, "__readingList__")
        XCTAssertEqual(LibraryViewDefinition.shipped(LibraryViewID.feeds)?.sortSettingsKey, "/views/Feeds")
        let custom = Self.custom("Mine")
        XCTAssertEqual(custom.sortSettingsKey, "/views/" + custom.id.storedValue)

        for key in ["/views/Feeds", custom.sortSettingsKey ?? ""] {
            XCTAssertFalse(BookFolder.isValidLibraryPath(key), key)
        }
        XCTAssertEqual(BookFolder.reservedNames, ["__allItems__", "__unopened__", "__recent__", "__readingList__", "__noFolder__"])
    }

    /// Each view shows its category's default sort until one is chosen, and
    /// Feeds and custom views title ascending.
    func testEachViewHasItsDefaultSort() {
        for category in LibraryCategory.allCases {
            XCTAssertEqual(LibraryViewDefinition.shipped(category).defaultSortSetting, category.defaultSortSetting)
        }
        XCTAssertEqual(LibraryViewDefinition.shipped(LibraryViewID.feeds)?.defaultSortSetting, .defaultSort)
        XCTAssertEqual(Self.custom("Mine").defaultSortSetting, .defaultSort)
    }

    // MARK: - What a Condition Tests

    /// Conditions about books test books, episodes, and articles; those
    /// about feeds test feeds; the folder and the title or author test every
    /// row.
    func testWhichRowsEachConditionTests() {
        let items: Set<LibraryViewItemKind> = [.books, .episodes, .articles]
        let expected: [(LibraryViewCondition.Test, Set<LibraryViewItemKind>)] = [
            (.format(.epub), items),
            (.folder(id: nil, includingSubfolders: true), Set(LibraryViewItemKind.allCases)),
            (.readingState(.finished), items),
            (.inReadingList, items),
            (.addedWithin(days: 7), items),
            (.openedWithin(days: 7), items),
            (.titleOrAuthorContains("Austen"), Set(LibraryViewItemKind.allCases)),
            (.hasNewItems, [.feeds]),
            (.subscribed, [.feeds]),
        ]
        XCTAssertEqual(Set(expected.map(\.0.kind)), Set(LibraryViewCondition.Kind.allCases))
        for (test, kinds) in expected {
            let condition = LibraryViewCondition(test: test)
            XCTAssertEqual(Set(LibraryViewItemKind.allCases.filter(condition.tests)), kinds, "\(test)")
        }
    }

    // MARK: - Writing an Entry

    /// A shipped view's entry holds only its identity and visibility, so a
    /// later TextMouth can improve the shipped views.
    func testAShippedViewWritesOnlyItsIdentityAndVisibility() {
        for id in LibraryViewID.builtIns {
            guard let view = LibraryViewDefinition.shipped(id) else {
                XCTFail("\(id) has no shipped view")
                continue
            }
            XCTAssertEqual(view.fileEntry, .object([
                "id": .string(id.storedValue),
                "visibility": .string(view.visibility.rawValue),
            ]))
        }
    }

    /// A built-in view the listener renamed or refiltered writes the name
    /// or filter it has.
    func testAChangedBuiltInViewWritesItsChanges() throws {
        var unopened = LibraryViewDefinition.shipped(.unopened)
        unopened.name = "Not Yet"
        XCTAssertEqual(unopened.fileEntry["name"], .string("Not Yet"))
        XCTAssertNil(unopened.fileEntry["filter"])
        unopened.name = "Unopened"
        unopened.filter = LibraryViewFilter(lists: [.books])
        XCTAssertNil(unopened.fileEntry["name"])
        XCTAssertEqual(unopened.fileEntry["filter"], try Self.json(#"{"lists": ["books"], "match": "all", "conditions": []}"#))
    }

    /// A custom view writes every part, in the shape the design gives, and
    /// reads back the same, with every kind of condition.
    func testACustomViewIsWrittenAsTheDesignShowsAndReadBack() throws {
        let folder = UUID()
        let view = LibraryViewDefinition(
            id: .custom(UUID()),
            name: "Unread EPUBs",
            visibility: .whenApplicable,
            filter: LibraryViewFilter(
                lists: [.feeds, .books, .episodes],
                match: .any,
                conditions: [
                    LibraryViewCondition(test: .format(.epub)),
                    LibraryViewCondition(test: .folder(id: folder, includingSubfolders: true)),
                    LibraryViewCondition(test: .folder(id: nil, includingSubfolders: false), isNegated: true),
                    LibraryViewCondition(test: .readingState(.inProgress)),
                    LibraryViewCondition(test: .inReadingList, isNegated: true),
                    LibraryViewCondition(test: .addedWithin(days: 7)),
                    LibraryViewCondition(test: .openedWithin(days: 30), isNegated: true),
                    LibraryViewCondition(test: .titleOrAuthorContains("Austen")),
                    LibraryViewCondition(test: .hasNewItems),
                    LibraryViewCondition(test: .subscribed, isNegated: true),
                ],
                onePerFeed: true,
                limit: LibraryViewLimit(count: 20, chosenBy: .dateAdded)
            )
        )
        let expected = try Self.json("""
            {
              "id": "\(view.id.storedValue)",
              "name": "Unread EPUBs",
              "visibility": "whenApplicable",
              "filter": {
                "lists": ["books", "episodes", "feeds"],
                "match": "any",
                "conditions": [
                  {"test": "format", "value": "epub"},
                  {"test": "folder", "folderID": "\(folder.uuidString)", "includingSubfolders": true},
                  {"test": "folder", "folderID": null, "includingSubfolders": false, "not": true},
                  {"test": "readingState", "value": "inProgress"},
                  {"test": "inReadingList", "not": true},
                  {"test": "addedWithin", "days": 7},
                  {"test": "openedWithin", "days": 30, "not": true},
                  {"test": "titleOrAuthorContains", "text": "Austen"},
                  {"test": "hasNewItems"},
                  {"test": "subscribed", "not": true}
                ],
                "onePerFeed": true,
                "limit": {"count": 20, "chosenBy": "dateAdded"}
              }
            }
            """)
        XCTAssertEqual(view.fileEntry, expected)
        XCTAssertEqual(Self.read(view.fileEntry), view)
    }

    // MARK: - Reading an Entry

    /// Each shipped view reads back from its short entry as shipped, and a
    /// built-in filter view without a filter has its shipped one.
    func testShippedEntriesReadBackAsShipped() {
        for id in LibraryViewID.builtIns {
            let shipped = LibraryViewDefinition.shipped(id)
            XCTAssertEqual(shipped.flatMap { Self.read($0.fileEntry) }, shipped, "\(id)")
        }
    }

    /// An entry that cannot be read faithfully is refused, so a view a later
    /// TextMouth wrote is never offered wrongly; the list keeps it as it was.
    func testEntriesThatCannotBeReadAreRefused() throws {
        let custom = UUID().uuidString
        let unreadable = [
            #""Unopened""#,
            #"{"visibility": "always"}"#,
            #"{"id": "Audiobooks", "visibility": "always"}"#,
            #"{"id": 3}"#,
            #"{"id": "\#(custom)", "filter": {"lists": ["books"]}}"#,
            #"{"id": "\#(custom)", "name": "   ", "filter": {"lists": ["books"]}}"#,
            #"{"id": "\#(custom)", "name": "Mine"}"#,
            #"{"id": "\#(custom)", "name": "Mine", "filter": "books"}"#,
            #"{"id": "\#(custom)", "name": "Mine", "filter": {"lists": []}}"#,
            #"{"id": "\#(custom)", "name": "Mine", "filter": {"lists": ["podcasts"]}}"#,
            #"{"id": "\#(custom)", "name": "Mine", "filter": {"lists": ["books"], "match": "none"}}"#,
            #"{"id": "\#(custom)", "name": "Mine", "filter": {"lists": ["books"], "sort": "title"}}"#,
            #"{"id": "\#(custom)", "name": "Mine", "filter": {"lists": ["books"], "conditions": {}}}"#,
            #"{"id": "\#(custom)", "name": "Mine", "filter": {"lists": ["books"], "conditions": [{"test": "duration", "value": 3}]}}"#,
            #"{"id": "\#(custom)", "name": "Mine", "filter": {"lists": ["books"], "conditions": [{"test": "format", "value": "mobi"}]}}"#,
            #"{"id": "\#(custom)", "name": "Mine", "filter": {"lists": ["books"], "conditions": [{"test": "format"}]}}"#,
            #"{"id": "\#(custom)", "name": "Mine", "filter": {"lists": ["books"], "conditions": [{"test": "readingState", "value": "abandoned"}]}}"#,
            #"{"id": "\#(custom)", "name": "Mine", "filter": {"lists": ["books"], "conditions": [{"test": "folder", "folderID": "Fiction"}]}}"#,
            #"{"id": "\#(custom)", "name": "Mine", "filter": {"lists": ["books"], "conditions": [{"test": "folder", "folderID": null, "includingSubfolders": "yes"}]}}"#,
            #"{"id": "\#(custom)", "name": "Mine", "filter": {"lists": ["books"], "conditions": [{"test": "addedWithin", "days": 2.5}]}}"#,
            #"{"id": "\#(custom)", "name": "Mine", "filter": {"lists": ["books"], "conditions": [{"test": "addedWithin", "days": "7"}]}}"#,
            #"{"id": "\#(custom)", "name": "Mine", "filter": {"lists": ["books"], "conditions": [{"test": "titleOrAuthorContains", "text": 7}]}}"#,
            #"{"id": "\#(custom)", "name": "Mine", "filter": {"lists": ["books"], "conditions": [{"test": "subscribed", "not": "true"}]}}"#,
            #"{"id": "\#(custom)", "name": "Mine", "filter": {"lists": ["books"], "conditions": [{"test": "subscribed", "value": "yes"}]}}"#,
            #"{"id": "\#(custom)", "name": "Mine", "filter": {"lists": ["books"], "limit": 10}}"#,
            #"{"id": "\#(custom)", "name": "Mine", "filter": {"lists": ["books"], "limit": {"count": 10, "chosenBy": "title"}}}"#,
            #"{"id": "\#(custom)", "name": "Mine", "filter": {"lists": ["books"], "limit": {"count": 10}}}"#,
            #"{"id": "Unopened", "filter": {"lists": ["books"], "conditions": [{"test": "rating"}]}}"#,
        ]
        for text in unreadable {
            XCTAssertNil(Self.read(try Self.json(text)), text)
        }
        let twentyOne = Array(repeating: #"{"test": "inReadingList"}"#, count: 21).joined(separator: ", ")
        let tooMany = try Self.json(#"{"id": "\#(custom)", "name": "Mine", "filter": {"lists": ["books"], "conditions": [\#(twentyOne)]}}"#)
        XCTAssertNil(Self.read(tooMany))
    }

    /// Values out of range are moved into it, texts too long are cut, and a
    /// missing or unknown name or visibility takes the shipped one; Folders
    /// is always offered, and Folders and the Reading List keep their own
    /// names and ignore a filter.
    func testEntriesWithValuesOutOfRangeAreRepaired() throws {
        let custom = UUID().uuidString
        let long = String(repeating: "N", count: 70)
        let longText = String(repeating: "t", count: 250)
        let repaired = try XCTUnwrap(Self.read(try Self.json("""
            {"id": "\(custom)", "name": "  \(long)  ", "visibility": "sometimes",
             "filter": {"lists": ["books"], "onePerFeed": "yes",
                        "conditions": [{"test": "addedWithin", "days": 0}, {"test": "openedWithin", "days": 99999},
                                       {"test": "titleOrAuthorContains", "text": "\(longText)"},
                                       {"test": "openedWithin", "days": 4.0}],
                        "limit": {"count": 1e30, "chosenBy": "viewSort"}}}
            """)))
        XCTAssertEqual(repaired.name, String(repeating: "N", count: 60))
        XCTAssertEqual(repaired.visibility, .always)
        XCTAssertEqual(repaired.filter?.onePerFeed, false)
        XCTAssertEqual(repaired.filter?.conditions.map(\.test), [
            .addedWithin(days: 1),
            .openedWithin(days: 3_650),
            .titleOrAuthorContains(String(repeating: "t", count: 200)),
            .openedWithin(days: 4),
        ])
        XCTAssertEqual(repaired.filter?.limit, LibraryViewLimit(count: 9_999, chosenBy: .viewSort))

        let feeds = try XCTUnwrap(Self.read(try Self.json(#"{"id": "Feeds", "name": "", "visibility": 3}"#)))
        XCTAssertEqual(feeds, LibraryViewDefinition.shipped(LibraryViewID.feeds))

        let folders = try XCTUnwrap(Self.read(try Self.json(
            #"{"id": "Folders", "name": "Shelves", "visibility": "hidden", "filter": {"lists": ["books"]}}"#
        )))
        XCTAssertEqual(folders, LibraryViewDefinition.shipped(.folders))

        let readingList = try XCTUnwrap(Self.read(try Self.json(
            #"{"id": "Reading List", "name": "Up Next", "visibility": "whenApplicable", "filter": {"lists": ["books"]}}"#
        )))
        XCTAssertEqual(readingList.name, "Reading List")
        XCTAssertNil(readingList.filter)
        XCTAssertEqual(readingList.visibility, .whenApplicable)

        let renamed = try XCTUnwrap(Self.read(try Self.json(#"{"id": "No Folder", "name": " Not Yet ", "visibility": "hidden"}"#)))
        XCTAssertEqual(renamed.id, .category(.unopened))
        XCTAssertEqual(renamed.name, "Not Yet")
        XCTAssertEqual(renamed.visibility, .hidden)
        XCTAssertEqual(renamed.filter, LibraryViewDefinition.shipped(.unopened).filter)

        let noLimit = try XCTUnwrap(Self.read(try Self.json(#"{"id": "\#(custom)", "name": "Mine", "filter": {"lists": ["feeds"], "limit": null}}"#)))
        XCTAssertNil(noLimit.filter?.limit)
    }

    /// Keys of an entry this TextMouth does not know are kept and written
    /// back, so a later TextMouth's harmless additions survive this one.
    func testKeysThisTextMouthDoesNotKnowAreKept() throws {
        let entry = try Self.json(#"{"id": "All Items", "visibility": "always", "icon": "books", "pinned": {"since": 3}}"#)
        let view = try XCTUnwrap(Self.read(entry))
        XCTAssertEqual(view.extraFields, ["icon": .string("books"), "pinned": .object(["since": .integer(3)])])
        XCTAssertEqual(view.fileEntry, entry)
    }

    // MARK: - Fixtures

    /// A custom view named `name` listing books.
    static func custom(_ name: String, visibility: LibraryViewVisibility = .always) -> LibraryViewDefinition {
        LibraryViewDefinition(id: .custom(UUID()), name: name, visibility: visibility, filter: LibraryViewFilter(lists: [.books]))
    }

    /// The JSON value `text` holds.
    static func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// The view `entry` reads as, without logging, or nil when unreadable.
    static func read(_ entry: JSONValue) -> LibraryViewDefinition? {
        LibraryViewDefinition(fileEntry: entry, reading: LibraryViewEntryReading(source: nil, path: []))
    }
}

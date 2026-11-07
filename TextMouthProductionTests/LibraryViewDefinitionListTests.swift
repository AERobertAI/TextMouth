import XCTest
@testable import TextMouth

/// The ordered list of Library views (design section 2): what it reads from
/// config.json, the entries it keeps unread, the built-in views it never
/// loses, which views a window's View pop-up offers, and each operation the
/// Library settings tab makes, with the cases each refuses.
final class LibraryViewDefinitionListTests: XCTestCase {

    // MARK: - Reading

    /// The shipped list, and a list read from nothing, are the six built-in
    /// views in their order, Feeds offered when applicable.
    func testTheShippedListAndAnEmptyFile() {
        XCTAssertEqual(LibraryViewDefinitionList.shipped.views.map(\.id), LibraryViewID.builtIns)
        XCTAssertEqual(LibraryViewDefinitionList.shipped.views.map(\.visibility), [.always, .always, .always, .always, .always, .whenApplicable])
        XCTAssertEqual(LibraryViewDefinitionList(fileEntries: []), .shipped)
        XCTAssertEqual(LibraryViewDefinitionList(fileEntries: LibraryViewDefinitionList.shipped.fileEntries), .shipped)
        XCTAssertEqual(LibraryViewDefinitionList.shipped.unreadableCount, 0)
        XCTAssertEqual(LibraryViewDefinitionList.fileKey, "libraryViews")
    }

    /// Built-in views missing from what was read are added at the end, in
    /// their order, so no hand edit loses one.
    func testMissingBuiltInViewsAreAddedAtTheEnd() throws {
        let list = LibraryViewDefinitionList(fileEntries: [
            try LibraryViewDefinitionTests.json(#"{"id": "Reading List", "visibility": "hidden"}"#),
            try LibraryViewDefinitionTests.json(#"{"id": "Feeds", "visibility": "always"}"#),
        ])
        XCTAssertEqual(list.views.map(\.id), [
            .category(.readingList), .feeds, .category(.folders), .category(.allItems), .category(.unopened), .category(.recent),
        ])
        XCTAssertEqual(list.view(.category(.readingList))?.visibility, .hidden)
        XCTAssertEqual(list.view(.feeds)?.visibility, .always)
    }

    /// Entries that cannot be read, and a second view with one identity,
    /// are kept in their places, counted, never listed among the views, and
    /// written back exactly as they were.
    func testUnreadableEntriesAreKeptInPlace() throws {
        let unknown = try LibraryViewDefinitionTests.json(#"{"id": "Audiobooks", "visibility": "always", "filter": {"lists": ["audiobooks"]}}"#)
        let second = try LibraryViewDefinitionTests.json(#"{"id": "Unopened", "visibility": "hidden"}"#)
        let entries = LibraryViewDefinitionList.shipped.fileEntries
        let file = Array(entries.prefix(2)) + [unknown] + Array(entries.dropFirst(2)) + [second]
        let list = LibraryViewDefinitionList(fileEntries: file)
        XCTAssertEqual(list.views.map(\.id), LibraryViewID.builtIns)
        // The second, plain Unopened entry adds nothing and is dropped
        // (review of October 31, 2026, finding 3); the unknown one is kept.
        XCTAssertEqual(list.unreadableCount, 1)
        XCTAssertEqual(list.view(.category(.unopened))?.visibility, .always)
        XCTAssertEqual(list.fileEntries, Array(file.dropLast()))
    }

    /// At most 206 entries are read from a file, which is untrusted: the
    /// limit of 200 and room for the built-in views, so a list this
    /// TextMouth writes reads back whole; `add` refuses a view past 200
    /// (review of October 31, 2026, finding 1).
    func testTheListsLimits() {
        XCTAssertEqual(LibraryViewDefinitionList.readLimit, 206)
        let customs = (0..<250).map { LibraryViewDefinitionTests.custom("View \($0)").fileEntry }
        let list = LibraryViewDefinitionList(fileEntries: customs)
        XCTAssertEqual(list.views.count, 206 + LibraryViewID.builtIns.count)
        XCTAssertEqual(list.views.last?.id, .feeds)
        XCTAssertFalse(list.canAdd)
        var full = list
        XCTAssertFalse(full.add(LibraryViewDefinitionTests.custom("One Too Many"), after: nil))
        XCTAssertEqual(full, list)
        XCTAssertEqual(LibraryViewDefinitionList(fileEntries: list.fileEntries), list)
    }

    /// Folders is always offered: a file cannot hide it, nor can the list,
    /// and it keeps its own name.
    func testFoldersIsAlwaysOffered() throws {
        var list = LibraryViewDefinitionList(fileEntries: [
            try LibraryViewDefinitionTests.json(#"{"id": "Folders", "visibility": "hidden"}"#),
        ])
        XCTAssertEqual(list.view(.category(.folders))?.visibility, .always)
        for visibility in LibraryViewVisibility.allCases {
            XCTAssertFalse(list.setVisibility(visibility, of: .category(.folders)))
        }
        var renamed = LibraryViewDefinition.shipped(.folders)
        renamed.name = "Shelves"
        renamed.visibility = .hidden
        XCTAssertFalse(list.replace(renamed))
        XCTAssertEqual(list.view(.category(.folders))?.name, "Folders")
        XCTAssertEqual(list.view(.category(.folders))?.visibility, .always)
        // The visibility read is written back as it was (review finding 2).
        XCTAssertEqual(list.fileEntries.first, try LibraryViewDefinitionTests.json(#"{"id": "Folders", "visibility": "hidden"}"#))
    }

    // MARK: - The Views Offered

    /// A window's pop-up offers, in order, the views always offered, those
    /// offered when applicable while they list something, and the view it
    /// shows, however hidden; a new window opens at the first.
    func testWhichViewsThePopUpOffers() {
        var list = LibraryViewDefinitionList.shipped
        let none: (LibraryViewDefinition) -> Bool = { _ in false }
        let all: (LibraryViewDefinition) -> Bool = { _ in true }
        XCTAssertEqual(list.offeredViews(current: nil, isApplicable: none).map(\.id), Array(LibraryViewID.builtIns.prefix(5)))
        XCTAssertEqual(list.offeredViews(current: nil, isApplicable: all).map(\.id), LibraryViewID.builtIns)

        list.setVisibility(.hidden, of: .category(.readingList))
        list.setVisibility(.whenApplicable, of: .category(.unopened))
        XCTAssertEqual(
            list.offeredViews(current: nil, isApplicable: { $0.id == .category(.unopened) }).map(\.id),
            [.category(.folders), .category(.allItems), .category(.unopened), .category(.recent)]
        )
        XCTAssertEqual(
            list.offeredViews(current: .category(.readingList), isApplicable: none).map(\.id),
            [.category(.folders), .category(.allItems), .category(.recent), .category(.readingList)]
        )

        XCTAssertEqual(list.firstOffered(isApplicable: none).id, .category(.folders))
        list.move(.category(.recent), by: -1)
        list.move(.category(.recent), by: -1)
        list.move(.category(.recent), by: -1)
        XCTAssertEqual(list.firstOffered(isApplicable: none).id, .category(.recent))
    }

    // MARK: - Moving

    /// A view moves one place up or down among the views, saying where it
    /// stands, and not past either end.
    func testAViewMovesOnePlaceAtATime() {
        var list = LibraryViewDefinitionList.shipped
        XCTAssertFalse(list.move(.category(.folders), by: -1))
        XCTAssertFalse(list.move(.feeds, by: 1))
        XCTAssertFalse(list.move(.category(.unopened), by: 2))
        XCTAssertFalse(list.move(.custom(UUID()), by: 1))
        XCTAssertEqual(list, .shipped)

        XCTAssertTrue(list.move(.category(.readingList), by: -1))
        XCTAssertEqual(list.views.map(\.id), [
            .category(.folders), .category(.allItems), .category(.unopened), .category(.readingList), .category(.recent), .feeds,
        ])
        XCTAssertTrue(list.place(of: .category(.readingList)).map { $0 == (4, 6) } ?? false)
        XCTAssertTrue(list.move(.category(.folders), by: 1))
        XCTAssertTrue(list.place(of: .category(.folders)).map { $0 == (2, 6) } ?? false)
        XCTAssertNil(list.place(of: .custom(UUID())))
    }

    /// Moving passes an entry this TextMouth cannot read without moving it
    /// among the entries' other views.
    func testMovingPassesAnUnreadableEntry() throws {
        let unknown = try LibraryViewDefinitionTests.json(#"{"id": "Audiobooks", "visibility": "always"}"#)
        let entries = LibraryViewDefinitionList.shipped.fileEntries
        var list = LibraryViewDefinitionList(fileEntries: Array(entries.prefix(1)) + [unknown] + Array(entries.dropFirst(1)))
        XCTAssertTrue(list.move(.category(.allItems), by: -1))
        XCTAssertEqual(list.views.map(\.id).prefix(2), [.category(.allItems), .category(.folders)])
        XCTAssertEqual(list.unreadableCount, 1)
        XCTAssertEqual(list.fileEntries.count, entries.count + 1)
        XCTAssertTrue(list.move(.category(.allItems), by: 1))
        XCTAssertEqual(list.views.map(\.id), LibraryViewID.builtIns)
    }

    // MARK: - Visibility, Adding, Replacing, Deleting

    /// A visibility is set once; setting the one a view has, or one for a
    /// view not in the list, changes nothing.
    func testSettingAVisibility() {
        var list = LibraryViewDefinitionList.shipped
        XCTAssertTrue(list.setVisibility(.hidden, of: .feeds))
        XCTAssertFalse(list.setVisibility(.hidden, of: .feeds))
        XCTAssertFalse(list.setVisibility(.hidden, of: .custom(UUID())))
        XCTAssertEqual(list.view(.feeds)?.visibility, .hidden)
    }

    /// A view is added after the one named, or at the end, and never twice.
    func testAddingAView() {
        var list = LibraryViewDefinitionList.shipped
        let first = LibraryViewDefinitionTests.custom("First")
        let second = LibraryViewDefinitionTests.custom("Second")
        XCTAssertTrue(list.add(first, after: nil))
        XCTAssertTrue(list.add(second, after: .category(.folders)))
        XCTAssertFalse(list.add(first, after: nil))
        XCTAssertFalse(list.add(LibraryViewDefinition.shipped(.unopened), after: nil))
        XCTAssertEqual(list.views.map(\.id), [.category(.folders), second.id] + LibraryViewID.builtIns.dropFirst() + [first.id])
        XCTAssertTrue(list.place(of: first.id).map { $0 == (8, 8) } ?? false)
    }

    /// A view is replaced by one with its identity; the Reading List keeps
    /// its name and no filter, a filter view keeps a filter, and a
    /// replacement that changes nothing reports so.
    func testReplacingAView() {
        var list = LibraryViewDefinitionList.shipped
        var unopened = LibraryViewDefinition.shipped(.unopened)
        unopened.name = "Not Yet"
        XCTAssertTrue(list.replace(unopened))
        XCTAssertFalse(list.replace(unopened))
        XCTAssertEqual(list.view(.category(.unopened))?.name, "Not Yet")

        var noFilter = unopened
        noFilter.filter = nil
        XCTAssertFalse(list.replace(noFilter))

        var readingList = LibraryViewDefinition.shipped(.readingList)
        readingList.name = "Up Next"
        readingList.filter = LibraryViewFilter(lists: [.books])
        readingList.visibility = .whenApplicable
        XCTAssertTrue(list.replace(readingList))
        XCTAssertEqual(list.view(.category(.readingList))?.name, "Reading List")
        XCTAssertNil(list.view(.category(.readingList))?.filter)
        XCTAssertEqual(list.view(.category(.readingList))?.visibility, .whenApplicable)

        XCTAssertFalse(list.replace(LibraryViewDefinitionTests.custom("Absent")))
    }

    /// Only a custom view can be deleted; a built-in one can be hidden.
    func testDeletingAView() {
        var list = LibraryViewDefinitionList.shipped
        let mine = LibraryViewDefinitionTests.custom("Mine")
        list.add(mine, after: nil)
        for id in LibraryViewID.builtIns {
            XCTAssertFalse(list.delete(id), "\(id)")
        }
        XCTAssertTrue(list.delete(mine.id))
        XCTAssertFalse(list.delete(mine.id))
        XCTAssertEqual(list, .shipped)
    }

    /// Restore Default gives a built-in filter view its shipped name and
    /// filter, keeping its place and visibility; it refuses Folders, the
    /// Reading List, custom views, and a view already as shipped.
    func testRestoringABuiltInView() {
        var list = LibraryViewDefinitionList.shipped
        XCTAssertFalse(list.restoreDefault(.category(.unopened)))
        var unopened = LibraryViewDefinition.shipped(.unopened)
        unopened.name = "Not Yet"
        unopened.filter = LibraryViewFilter(lists: [.books])
        list.replace(unopened)
        list.setVisibility(.hidden, of: .category(.unopened))
        list.move(.category(.unopened), by: -1)
        XCTAssertTrue(list.restoreDefault(.category(.unopened)))
        var expected = LibraryViewDefinition.shipped(.unopened)
        expected.visibility = .hidden
        XCTAssertEqual(list.view(.category(.unopened)), expected)
        XCTAssertTrue(list.place(of: .category(.unopened)).map { $0 == (2, 6) } ?? false)

        let mine = LibraryViewDefinitionTests.custom("Mine")
        list.add(mine, after: nil)
        for id in [LibraryViewID.category(.folders), .category(.readingList), mine.id, .custom(UUID())] {
            XCTAssertFalse(list.restoreDefault(id), "\(id)")
        }
    }

    // MARK: - Names

    /// A name is taken by another view whatever its case, accents, or
    /// surrounding spaces, but not by the view being renamed.
    func testANameIsTakenWithoutRegardToCaseOrAccents() {
        var list = LibraryViewDefinitionList.shipped
        let cafe = LibraryViewDefinitionTests.custom("Café Reads")
        list.add(cafe, after: nil)
        XCTAssertTrue(list.isNameTaken("unopened", except: nil))
        XCTAssertTrue(list.isNameTaken("  CAFE reads ", except: nil))
        XCTAssertFalse(list.isNameTaken("Café Reads", except: cafe.id))
        XCTAssertFalse(list.isNameTaken("Unread", except: nil))
    }

    /// A copy's name is the first of "<name> Copy", "<name> Copy 2", and on
    /// that no view has, cut where it would pass the limit.
    func testACopyIsNamedAfterItsOriginal() {
        var list = LibraryViewDefinitionList.shipped
        XCTAssertEqual(list.copyName(for: "Unopened"), "Unopened Copy")
        list.add(LibraryViewDefinitionTests.custom("Unopened Copy"), after: nil)
        list.add(LibraryViewDefinitionTests.custom("Unopened copy 2"), after: nil)
        XCTAssertEqual(list.copyName(for: "Unopened"), "Unopened Copy 3")

        let long = String(repeating: "x", count: 60)
        let copy = list.copyName(for: long)
        XCTAssertEqual(copy.count, 60)
        XCTAssertTrue(copy.hasSuffix(" Copy"))
    }
}

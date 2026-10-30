import XCTest
@testable import TextMouth

/// A place in the library as a view and a folder (the design of October 30,
/// 2026, LIBRARY-VIEWS-RESEARCH-2026-10-30.md, sections 2 and 8): the
/// Feeds view's and a custom view's key, name, title, and sort; the lists a
/// filter view shows through its filter, kept by the list cache until its
/// filter or a field it reads changes; the feeds a filter view lists; and
/// the views' sort keys, which folder operations never touch.
///
/// Each test runs on the main actor, not the class as a whole, as
/// `UnopenedCategoryTests` explains.
final class LibraryViewLocationTests: XCTestCase {
    /// The isolated data root's index, put back after a test that saves.
    private var sandbox: LibraryIndexSandbox!

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
    }

    override func tearDownWithError() throws {
        // Tear-down also runs when capturing failed in set-up.
        sandbox?.restore()
    }

    // MARK: - The Place

    /// The Feeds view saves its sort under a key no folder can have, is
    /// named "Feeds" alone in the title, since feeds are always listed by
    /// title, keeps no order of its own, and follows All Items' rules where
    /// a caller asks for a category.
    @MainActor
    func testTheFeedsViewsPlace() throws {
        let feeds = LibraryLocation(view: try XCTUnwrap(LibraryViewDefinition.shipped(.feeds)), folderPath: "Essays")
        XCTAssertEqual(feeds.sortSettingsKey, "/views/Feeds")
        XCTAssertEqual(feeds.name, "Feeds")
        XCTAssertTrue(feeds.listsOnlyFeeds)
        XCTAssertEqual(feeds.windowTitle(sortedBy: Library().sortState(at: feeds)), "Library: Feeds")
        XCTAssertFalse(feeds.keepsItsOwnOrder)
        XCTAssertNil(feeds.manualOrderFolder)
        XCTAssertEqual(feeds.category, .allItems)
        XCTAssertEqual(feeds.defaultSortSetting, .defaultSort)
        XCTAssertFalse(LibraryLocation(category: .unopened, folderPath: "").listsOnlyFeeds)
    }

    /// A custom view's title names its sort, title ascending until one is
    /// chosen; a sort chosen there is saved under its own key, and shown,
    /// and no other view's changes.
    @MainActor
    func testACustomViewsSortIsItsOwn() throws {
        let model = LibraryViewModel(initializeServices: false)
        let mine = LibraryViewDefinitionTests.custom("Mine")
        let location = LibraryLocation(view: mine, folderPath: "")
        XCTAssertEqual(location.windowTitle(sortedBy: model.sortState(at: location)), "Library: Mine (Title Ascending)")
        XCTAssertEqual(location.category, .allItems)

        model.userChangedSort(.choose(.author), at: location)
        model.userChangedSort(.reverseDirection, at: location)
        let key = try XCTUnwrap(mine.sortSettingsKey)
        XCTAssertEqual(model.library.folderSortSettings[key]?.sortField, .author)
        XCTAssertEqual(location.windowTitle(sortedBy: model.sortState(at: location)), "Library: Mine (Author Descending)")
        XCTAssertNil(model.library.folderSortSettings["__allItems__"])
        let allItems = LibraryLocation(category: .allItems, folderPath: "")
        XCTAssertEqual(model.sortState(at: allItems).field, .title)
    }

    // MARK: - The Lists

    /// A filter view lists what its filter finds, in its sort, and so does a
    /// built-in view whose filter the listener changed; a limit keeps the
    /// rows it chooses.
    @MainActor
    func testAFilterViewListsWhatItsFilterFinds() throws {
        let model = Self.model()
        let epubs = LibraryViewDefinition(
            id: .custom(UUID()),
            name: "EPUBs",
            visibility: .always,
            filter: LibraryViewFilter(lists: [.books], conditions: [LibraryViewCondition(test: .format(.epub))])
        )
        XCTAssertEqual(model.displayedBooks(at: LibraryLocation(view: epubs, folderPath: "")).map(\.title), ["Atlas", "Cartography"])

        var unopened = LibraryViewDefinition.shipped(.unopened)
        unopened.filter?.conditions.append(LibraryViewCondition(test: .format(.txt)))
        let edited = LibraryLocation(view: unopened, folderPath: "")
        XCTAssertEqual(model.displayedBooks(at: edited).map(\.title), ["Drafts"])
        XCTAssertEqual(
            Set(model.displayedBooks(at: LibraryLocation(category: .unopened, folderPath: "")).map(\.title)),
            ["Cartography", "Drafts"]
        )

        var newest = epubs
        newest.filter?.conditions = []
        newest.filter?.limit = LibraryViewLimit(count: 2, chosenBy: .dateAdded)
        XCTAssertEqual(model.displayedBooks(at: LibraryLocation(view: newest, folderPath: "")).map(\.title), ["Cartography", "Drafts"])
    }

    /// A filter view's list is derived once and kept; a location whose
    /// filter differs is derived again, and so is every list once a book's
    /// format changes, which a format condition reads.
    @MainActor
    func testAFilterViewsListIsKeptUntilItsFilterOrAFieldItReadsChanges() throws {
        let model = Self.model()
        let epubs = LibraryViewDefinition(
            id: .custom(UUID()),
            name: "EPUBs",
            visibility: .always,
            filter: LibraryViewFilter(lists: [.books], conditions: [LibraryViewCondition(test: .format(.epub))])
        )
        let location = LibraryLocation(view: epubs, folderPath: "")
        _ = model.displayedBooks(at: location)
        let derivations = model.listCache.derivationCount
        _ = model.displayedBooks(at: location)
        XCTAssertEqual(model.listCache.derivationCount, derivations)

        var plain = epubs
        plain.filter?.conditions = [LibraryViewCondition(test: .format(.txt))]
        XCTAssertEqual(model.displayedBooks(at: LibraryLocation(view: plain, folderPath: "")).map(\.title), ["Drafts"])
        XCTAssertEqual(model.listCache.derivationCount, derivations + 1)

        let index = try XCTUnwrap(model.library.books.firstIndex { $0.title == "Drafts" })
        model.library.books[index].format = .epub
        XCTAssertEqual(model.displayedBooks(at: location).map(\.title), ["Atlas", "Cartography", "Drafts"])
        XCTAssertEqual(model.listCache.derivationCount, derivations + 2)
    }

    /// The categories' lists, through their shipped views, are the lists
    /// they always were.
    @MainActor
    func testTheCategoriesListWhatTheyAlwaysListed() {
        let model = Self.model()
        XCTAssertEqual(model.booksForCategory(.allItems, folderPath: "Essays").map(\.title), model.library.libraryBooks.map(\.title))
        XCTAssertEqual(model.booksForCategory(.unopened, folderPath: "").map(\.title), model.library.unopenedBooks().map(\.title))
        XCTAssertEqual(model.booksForCategory(.recent, folderPath: "").map(\.title), LibraryBookSorter.recent(model.library.books).map(\.title))
        XCTAssertEqual(model.booksForCategory(.folders, folderPath: "Essays").map(\.title), ["Atlas", "Bestiary"])
        XCTAssertNil(model.filterContext(for: LibraryLocation(category: .folders, folderPath: "")))
        XCTAssertNotNil(model.filterContext(for: LibraryLocation(category: .allItems, folderPath: "")))
    }

    // MARK: - Feeds

    /// The Feeds view lists every feed, a custom view of feeds with new
    /// items those with one, and a view of books alone no feed.
    @MainActor
    func testTheFeedsAFilterViewLists() async throws {
        let world = try FeedTestWorld(self, label: "ViewLocationFeeds")
        _ = try await subscribe(world, title: "Harbour Notes", path: "/notes.xml", items: [
            FeedXML.Item(guid: "old-1", title: "Older", published: world.day(-30)),
        ])
        let atlas = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml", items: [
            FeedXML.Item(guid: "ep-1", title: "First", published: world.day(0.5)),
        ])
        let feedsView = try XCTUnwrap(LibraryViewDefinition.shipped(.feeds))
        XCTAssertEqual(
            LibraryFeedsSectionRows.feeds(at: LibraryLocation(view: feedsView, folderPath: ""), center: world.center).map(\.title),
            ["Harbour Notes", "The Tactile Atlas"]
        )
        let withNew = LibraryViewDefinition(
            id: .custom(UUID()),
            name: "New Episodes",
            visibility: .always,
            filter: LibraryViewFilter(lists: [.feeds], conditions: [LibraryViewCondition(test: .hasNewItems)])
        )
        XCTAssertEqual(
            LibraryFeedsSectionRows.feeds(at: LibraryLocation(view: withNew, folderPath: ""), center: world.center).map(\.id),
            [atlas.id]
        )
        let booksAlone = LibraryViewDefinitionTests.custom("Books")
        XCTAssertEqual(LibraryFeedsSectionRows.feeds(at: LibraryLocation(view: booksAlone, folderPath: ""), center: world.center), [])
        XCTAssertEqual(
            LibraryFeedsSectionRows.feeds(at: LibraryLocation(category: .allItems, folderPath: ""), center: world.center).count,
            2
        )
        XCTAssertEqual(LibraryFeedsSectionRows.feeds(at: LibraryLocation(category: .recent, folderPath: ""), center: world.center), [])
    }

    // MARK: - Sort Keys and Folder Operations

    /// A view's sort key, beginning with "/", survives deleting a folder,
    /// moving its contents out or deleting everything, renaming and moving a
    /// folder, and merging folders whose names differ only in spelling.
    @MainActor
    func testFolderOperationsLeaveTheViewsSortKeysAlone() throws {
        let key = "/views/\(UUID().uuidString)"
        let setting = FolderSortSetting(sortField: .author, sortAscending: false)
        var library = Library(folderSortSettings: [key: setting, "/views/Feeds": setting])
        let essays = try XCTUnwrap(library.createFolder(name: "Essays"))
        let travel = try XCTUnwrap(library.createFolder(name: "Travel", parentPath: "Essays"))
        let maps = try XCTUnwrap(library.createFolder(name: "Maps"))
        library.setSortSetting(setting, for: "Essays")

        XCTAssertTrue(library.renameFolder(id: maps.id, to: "Charts"))
        XCTAssertTrue(library.moveFolder(id: travel.id, toParentPath: ""))
        XCTAssertTrue(library.removeFolder(id: essays.id))
        _ = library.removeFolderAndContents(id: travel.id)
        _ = library.mergeEquivalentFolders()
        XCTAssertEqual(library.folderSortSettings[key], setting)
        XCTAssertEqual(library.folderSortSettings["/views/Feeds"], setting)
    }

    // MARK: - Fixtures

    /// A model holding four books: Atlas (EPUB, Essays, opened), Bestiary
    /// (text, Essays, opened), Cartography (EPUB, root, never opened, added
    /// last), and Drafts (text, root, never opened, added second last).
    @MainActor
    private static func model() -> LibraryViewModel {
        let model = LibraryViewModel(initializeServices: false)
        model.finishedBookIDs = { [] }
        let start = Date(timeIntervalSince1970: 1_791_000_000)
        model.library = Library(
            books: [
                book("Atlas", .epub, in: "Essays", added: start, opened: start.addingTimeInterval(500)),
                book("Bestiary", .txt, in: "Essays", added: start.addingTimeInterval(100), opened: start.addingTimeInterval(400)),
                book("Cartography", .epub, in: "", added: start.addingTimeInterval(300), opened: nil),
                book("Drafts", .txt, in: "", added: start.addingTimeInterval(200), opened: nil),
            ],
            folders: [BookFolder(name: "Essays")]
        )
        return model
    }

    /// A book titled `title` of `format` in the folder `folder`, added at
    /// `added`, last opened at `opened`, or never when nil.
    private static func book(_ title: String, _ format: BookFormat, in folder: String, added: Date, opened: Date?) -> Book {
        var book = Book(
            title: title,
            format: format,
            filePath: "/\(title).\(format.rawValue)",
            md5Hash: title,
            tmbDirectoryName: "\(title).tmb"
        )
        book.folderPath = folder
        book.dateAdded = added
        book.lastOpened = opened
        return book
    }

    /// Subscribes `world` to a podcast titled `title` served at `path` with
    /// `items`, each given an audio enclosure, in a new folder of its own,
    /// as `UnopenedCategoryTests` subscribes.
    @MainActor
    private func subscribe(_ world: FeedTestWorld, title: String, path: String, items: [FeedXML.Item]) async throws -> Feed {
        let episodes = items.map { item -> FeedXML.Item in
            var episode = item
            episode.enclosure = "https://views.example/audio/\(item.guid ?? UUID().uuidString).mp3"
            return episode
        }
        world.server.serve(path, .feed(FeedXML.rss(title: title, items: episodes)))
        if !world.center.hasStarted {
            await world.start()
        }
        let outcome = try await world.center.subscribe(
            to: world.server.url(path).absoluteString,
            into: .newFolder(inParentPath: world.folder.path)
        )
        guard case .subscribed(let feed) = outcome else {
            throw NSError(domain: "LibraryViewLocationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(outcome)"])
        }
        return feed
    }
}

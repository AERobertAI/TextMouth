import XCTest
@testable import TextMouth

/// The Unopened category of the Library window, which replaced No Folder:
/// every book never opened, from every folder, and the feeds with items not
/// yet played. These tests pin its name, its sort key and the sort carried
/// over from No Folder, its default sort, and what it lists: the books,
/// which leave it when opened, and the feeds, which leave it when played.
@MainActor
final class UnopenedCategoryTests: XCTestCase {
    /// The isolated data root's index, put back after a test that saves.
    private var sandbox: LibraryIndexSandbox!

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
    }

    override func tearDownWithError() throws {
        // Tear-down also runs when capturing failed in set-up.
        sandbox?.restore()
    }

    // MARK: - The Category

    /// The View picker's segments, in order, with Unopened where No Folder
    /// was and the Reading List (FR09) last; nothing is called No Folder
    /// any more.
    func testTheCategoriesAreNamedInOrder() {
        XCTAssertEqual(LibraryCategory.allCases.map(\.rawValue), ["Folders", "All Items", "Unopened", "Recent", "Reading List"])
        XCTAssertEqual(LibraryCategory.unopened.rawValue, "Unopened")
        XCTAssertEqual(LibraryCategory.formerNoFolderName, "No Folder")
        XCTAssertNil(LibraryCategory(rawValue: "No Folder"))
    }

    /// A category is saved by its name and read back by it; a category
    /// saved as "No Folder" reads as Unopened; a name no category has fails
    /// to read rather than becoming one.
    func testACategorySavedAsNoFolderReadsAsUnopened() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for category in LibraryCategory.allCases {
            let data = try encoder.encode([category])
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "[\"\(category.rawValue)\"]")
            XCTAssertEqual(try decoder.decode([LibraryCategory].self, from: data), [category])
        }
        let formerly = Data("[\"No Folder\"]".utf8)
        XCTAssertEqual(try decoder.decode([LibraryCategory].self, from: formerly), [.unopened])
        let unknown = Data("[\"Shelf\"]".utf8)
        XCTAssertThrowsError(try decoder.decode([LibraryCategory].self, from: unknown))
    }

    // MARK: - The Sort Key and the Sort Carried Over

    /// Unopened saves its sort under its own reserved key, which no folder
    /// path can match, as No Folder did under its key; neither can be a
    /// folder's name, since the old key is still read.
    func testTheSortKeyIsReservedAlongWithNoFoldersKey() {
        XCTAssertEqual(LibraryCategory.unopened.sortSettingsKey, "__unopened__")
        XCTAssertEqual(LibraryLocation(category: .unopened, folderPath: "Essays").sortSettingsKey, "__unopened__")
        XCTAssertEqual(LibraryCategory.formerNoFolderSortSettingsKey, "__noFolder__")
        XCTAssertEqual(BookFolder.reservedNames, ["__allItems__", "__unopened__", "__recent__", "__readingList__", "__noFolder__"])
        for reserved in BookFolder.reservedNames {
            XCTAssertNil(BookFolder.normalizedName(reserved), reserved)
            XCTAssertFalse(BookFolder.isValidLibraryPath(reserved), reserved)
        }
        XCTAssertEqual(BookFolder.normalizedName("Unopened"), "Unopened")
    }

    /// Without a saved sort, Unopened shows its books newest first by the
    /// date they were added: no unopened book has a last-opened date to
    /// sort by, so Recent's default would leave them in title order.
    func testWithoutASavedSortUnopenedShowsNewestAddedFirst() {
        let unopened = LibraryLocation(category: .unopened, folderPath: "Essays")
        let sort = Library().sortState(at: unopened)

        XCTAssertEqual(LibraryCategory.unopened.defaultSortSetting, .unopenedDefault)
        XCTAssertEqual(FolderSortSetting.unopenedDefault, FolderSortSetting(sortField: .dateAdded, sortAscending: false))
        XCTAssertEqual(sort.field, .dateAdded)
        XCTAssertFalse(sort.isAscending)
        XCTAssertEqual(unopened.windowTitle(sortedBy: sort), "Library: Unopened (Date Added Descending)")
        XCTAssertEqual(sort.menuAccessibilityLabel, "Sort books by Date Added, descending")
    }

    /// A sort saved for No Folder shows at Unopened until one is chosen
    /// there: the old key is read, never written, and a sort chosen at
    /// Unopened shadows it. Manual order is not carried over, since it was
    /// the root's arrangement, which books from many folders do not share.
    func testASortSavedForNoFolderIsCarriedOverUntilOneIsChosenAtUnopened() {
        let unopened = LibraryLocation(category: .unopened, folderPath: "")
        let authorDescending = FolderSortSetting(sortField: .author, sortAscending: false)
        let fileSizeAscending = FolderSortSetting(sortField: .fileSize, sortAscending: true)

        // Only the old key saved: its sort shows.
        let carried = Library(folderSortSettings: ["__noFolder__": authorDescending])
        XCTAssertEqual(carried.sortState(at: unopened), LibrarySortState(restoring: authorDescending))
        XCTAssertEqual(unopened.windowTitle(sortedBy: carried.sortState(at: unopened)), "Library: Unopened (Author Descending)")

        // Both keys saved: Unopened's own wins.
        let chosen = Library(folderSortSettings: ["__noFolder__": authorDescending, "__unopened__": fileSizeAscending])
        XCTAssertEqual(chosen.sortState(at: unopened), LibrarySortState(restoring: fileSizeAscending))

        // The old key's manual order is not carried over: the default shows.
        let manual = Library(folderSortSettings: ["__noFolder__": FolderSortSetting(sortField: .manual, sortAscending: true)])
        XCTAssertEqual(manual.sortState(at: unopened), LibrarySortState(restoring: .unopenedDefault))

        // No other category reads the old key.
        for category in LibraryCategory.allCases where category != .unopened {
            let location = LibraryLocation(category: category, folderPath: "")
            XCTAssertEqual(carried.sortState(at: location), LibrarySortState(restoring: location.defaultSortSetting), "\(category)")
        }
    }

    /// Showing the carried-over sort saves nothing; choosing a sort at
    /// Unopened saves it under Unopened's key and leaves the old key as it
    /// was, and from then on the old key is not read.
    func testChoosingASortAtUnopenedSavesUnderItsOwnKey() {
        let model = LibraryViewModel(initializeServices: false)
        let authorDescending = FolderSortSetting(sortField: .author, sortAscending: false)
        model.library = Library(folderSortSettings: ["__noFolder__": authorDescending])
        let unopened = LibraryLocation(category: .unopened, folderPath: "")

        XCTAssertEqual(model.sortState(at: unopened).field, .author)
        XCTAssertEqual(model.library.folderSortSettings, ["__noFolder__": authorDescending])

        // Choosing Title leaves Author's direction remembered, as choosing
        // a field at any location does, and saves under Unopened's key.
        let shown = model.userChangedSort(.choose(.title), at: unopened)
        XCTAssertEqual(shown.field, .title)
        XCTAssertTrue(shown.isAscending)
        XCTAssertEqual(model.library.folderSortSettings["__noFolder__"], authorDescending)
        XCTAssertEqual(model.library.folderSortSettings["__unopened__"], shown.setting)
        XCTAssertEqual(model.sortState(at: unopened), shown)
    }

    // MARK: - What It Lists

    /// Unopened lists every book never opened, from the root and every
    /// folder at any depth, newest added first, and no book opened, whatever
    /// folder Folders showed last; a search narrows it as it does any list.
    /// The root's books, which No Folder listed, are still exactly what
    /// Folders lists at the root, so nothing is lost by the change.
    func testUnopenedListsTheBooksNeverOpenedFromEveryFolder() {
        let model = LibraryViewModel(initializeServices: false)
        let start = Date(timeIntervalSince1970: 1_791_000_000)
        let loose = Self.book("Loose Pages", in: "", added: start, opened: nil)
        let filed = Self.book("Filed Pages", in: "Essays", added: start.addingTimeInterval(60), opened: nil)
        let deep = Self.book("Travel Notes", in: "Essays/Travel", added: start.addingTimeInterval(120), opened: nil)
        let read = Self.book("Read Pages", in: "", added: start.addingTimeInterval(180), opened: start.addingTimeInterval(200))
        let readFiled = Self.book("Read Essay", in: "Essays", added: start.addingTimeInterval(240), opened: start.addingTimeInterval(300))
        model.library = Library(
            books: [read, loose, readFiled, filed, deep],
            folders: [BookFolder(name: "Essays"), BookFolder(name: "Travel", parentPath: "Essays")]
        )
        let unopened = LibraryLocation(category: .unopened, folderPath: "Essays")

        XCTAssertEqual(model.library.unopenedBooks().map(\.title), ["Loose Pages", "Filed Pages", "Travel Notes"])
        XCTAssertEqual(model.displayedBooks(at: unopened).map(\.title), ["Travel Notes", "Filed Pages", "Loose Pages"])
        XCTAssertEqual(model.displayedBooks(at: unopened, matching: "pages").map(\.title), ["Filed Pages", "Loose Pages"])
        // The root's books are what Folders lists at the root.
        let root = LibraryLocation(category: .folders, folderPath: "")
        XCTAssertEqual(Set(model.displayedBooks(at: root).map(\.title)), ["Loose Pages", "Read Pages"])
        XCTAssertEqual(model.library.booksWithNoFolder().map(\.id), model.library.booksInFolder("").map(\.id))
    }

    /// Opening a book takes it off the Unopened list the next time the list
    /// is read, and off no other list: a book's last-opened date is a field
    /// every kept list depends on, so the list is derived again, while
    /// reading it again unchanged derives nothing.
    func testOpeningABookTakesItOffTheListAtTheNextRead() throws {
        let model = LibraryViewModel(initializeServices: false)
        let start = Date(timeIntervalSince1970: 1_791_000_000)
        let first = Self.book("First", in: "Essays", added: start, opened: nil)
        let second = Self.book("Second", in: "", added: start.addingTimeInterval(60), opened: nil)
        model.library = Library(books: [first, second], folders: [BookFolder(name: "Essays")])
        let unopened = LibraryLocation(category: .unopened, folderPath: "")
        let allItems = LibraryLocation(category: .allItems, folderPath: "")
        XCTAssertEqual(model.displayedBooks(at: unopened).map(\.title), ["Second", "First"])
        let derivations = model.listCache.derivationCount

        XCTAssertEqual(model.displayedBooks(at: unopened).map(\.title), ["Second", "First"])
        XCTAssertEqual(model.listCache.derivationCount, derivations, "reading the list again derived it again")
        let index = try XCTUnwrap(model.library.books.firstIndex { $0.id == second.id })
        model.library.books[index].lastOpened = start.addingTimeInterval(120)

        XCTAssertEqual(model.displayedBooks(at: unopened).map(\.title), ["First"])
        XCTAssertEqual(model.listCache.derivationCount, derivations + 1)
        XCTAssertEqual(Set(model.displayedBooks(at: allItems).map(\.title)), ["First", "Second"])
    }

    /// The Feeds section at Unopened lists every feed with an item not yet
    /// played, each row as it reads in All Items, and no feed whose items
    /// are all played or that has none; a feed leaves the section when its
    /// last unplayed item is played, and returns when one is unplayed again.
    func testTheFeedsSectionAtUnopenedListsTheFeedsWithUnplayedItems() async throws {
        let world = try FeedTestWorld(self, label: "UnopenedFeeds")
        let atlas = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml", items: [
            FeedXML.Item(guid: "ep-2", title: "Second", published: world.day(1)),
            FeedXML.Item(guid: "ep-1", title: "First", published: world.day(0.5)),
        ])
        let notes = try await subscribe(world, title: "Harbour Notes", path: "/notes.xml", items: [
            FeedXML.Item(guid: "note-1", title: "Tides", published: world.day(0.5)),
        ])
        let silent = try await subscribe(world, title: "Silent Signal", path: "/silent.xml", items: [])
        world.center.markPlayed("guid:note-1", of: notes.id)
        let now = Date()
        let unopened = LibraryLocation(category: .unopened, folderPath: "")
        let allItems = LibraryLocation(category: .allItems, folderPath: "")
        func titlesAtUnopened() -> [String] {
            LibraryFeedsSectionRows.rows(at: unopened, center: world.center, now: now).map(\.title)
        }

        XCTAssertEqual(titlesAtUnopened(), ["The Tactile Atlas"])
        // The Reading List (FR09) holds books only, and lists no feed.
        let readingList = LibraryLocation(category: .readingList, folderPath: "")
        XCTAssertEqual(LibraryFeedsSectionRows.rows(at: readingList, center: world.center, now: now), [])
        let everywhere = LibraryFeedsSectionRows.rows(at: allItems, center: world.center, now: now)
        XCTAssertEqual(everywhere.map(\.title), ["Harbour Notes", "Silent Signal", "The Tactile Atlas"])
        XCTAssertEqual(world.center.counts(of: silent.id).unplayed, 0)
        XCTAssertEqual(world.center.counts(of: notes.id).unplayed, 0)
        // The feed's row reads exactly as it does in All Items.
        let atlasRow = try XCTUnwrap(LibraryFeedsSectionRows.rows(at: unopened, center: world.center, now: now).first)
        XCTAssertEqual(atlasRow, try XCTUnwrap(everywhere.first { $0.id == atlas.id }))
        XCTAssertEqual(atlasRow.counts.unplayed, 2)
        XCTAssertEqual(atlasRow.countsText, "2 episodes, 2 new, 2 unplayed")
        XCTAssertTrue(atlasRow.label.hasPrefix("The Tactile Atlas, Feed, 2 episodes, 2 new, 2 unplayed, "), atlasRow.label)

        // Playing one of the two episodes keeps the feed listed; playing the
        // other takes it off, and marking an item unplayed brings its feed back.
        world.center.markPlayed("guid:ep-2", of: atlas.id)
        XCTAssertEqual(titlesAtUnopened(), ["The Tactile Atlas"])
        world.center.markPlayed("guid:ep-1", of: atlas.id)
        XCTAssertEqual(titlesAtUnopened(), [])
        world.center.markUnplayed("guid:note-1", of: notes.id)
        XCTAssertEqual(titlesAtUnopened(), ["Harbour Notes"])
    }

    // MARK: - VoiceOver

    /// The View picker's third segment reads "Unopened", under the picker's
    /// own label, and the window title names the category the same way.
    func testThePickerSegmentReadsUnopened() {
        XCTAssertEqual(LibraryView.categoryPickerLabel, "Library category")
        XCTAssertEqual(LibraryCategory.allCases.firstIndex(of: .unopened), 2)
        XCTAssertEqual(LibraryCategory.unopened.rawValue, "Unopened")
        XCTAssertEqual(LibraryLocation(category: .unopened, folderPath: "Essays").name, "Unopened")
    }

    // MARK: - No Manual Order

    /// Unopened offers no manual order, as All Items offers none: books
    /// from many folders share no one order, so dragging and Move Book Up
    /// and Move Book Down rearrange nothing there, whatever sort is saved,
    /// while the same books can be rearranged in their own folder. A manual
    /// sort saved for Unopened still lists every unopened book, in the
    /// books' positions in their folders' orders and then by title, as All
    /// Items shows that sort.
    func testUnopenedOffersNoManualOrderAsAllItemsOffersNone() {
        let manual = FolderSortSetting(sortField: .manual, sortAscending: true)
        let manualSort = LibrarySortState(restoring: manual)
        let unopened = LibraryLocation(category: .unopened, folderPath: "Essays")
        let allItems = LibraryLocation(category: .allItems, folderPath: "Essays")
        XCTAssertNil(unopened.manualOrderFolder)
        XCTAssertNil(allItems.manualOrderFolder)
        XCTAssertEqual(LibraryLocation(category: .folders, folderPath: "Essays").reorderableFolder(sortedBy: manualSort), "Essays")
        for field in LibrarySortField.allCases {
            let sort = LibrarySortState(restoring: FolderSortSetting(sortField: field, sortAscending: true))
            XCTAssertNil(unopened.reorderableFolder(sortedBy: sort), field.rawValue)
        }

        let model = LibraryViewModel(initializeServices: false)
        let start = Date(timeIntervalSince1970: 1_791_000_000)
        model.library = Library(
            books: [
                Self.book("Second in Essays", in: "Essays", added: start, opened: nil, manualOrder: 1),
                Self.book("First at the root", in: "", added: start, opened: nil, manualOrder: 0),
                Self.book("Read first in Essays", in: "Essays", added: start, opened: start, manualOrder: 0),
                Self.book("Unplaced", in: "", added: start, opened: nil, manualOrder: nil)
            ],
            folders: [BookFolder(name: "Essays")],
            folderSortSettings: ["__unopened__": manual, "__allItems__": manual]
        )

        XCTAssertEqual(model.sortState(at: unopened), manualSort)
        XCTAssertEqual(model.displayedBooks(at: unopened).map(\.title), ["First at the root", "Second in Essays", "Unplaced"])
        XCTAssertEqual(model.displayedBooks(at: allItems).map(\.title), ["First at the root", "Read first in Essays", "Second in Essays", "Unplaced"])
    }

    // MARK: - Fixtures

    /// A book titled `title` in the folder `folder`, added at `added`, last
    /// opened at `opened`, or never when nil, at `manualOrder` in its
    /// folder's manual order, or unplaced when nil.
    private static func book(_ title: String, in folder: String, added: Date, opened: Date?, manualOrder: Int? = nil) -> Book {
        let id = UUID()
        return Book(
            id: id,
            title: title,
            format: .txt,
            filePath: "/nonexistent/unopened/\(id.uuidString).txt",
            md5Hash: "unopened-\(id.uuidString)",
            folderPath: folder,
            dateAdded: added,
            lastOpened: opened,
            manualSortOrder: manualOrder
        )
    }

    /// Subscribes `world` to a feed titled `title` served at `path`, listing
    /// `items`, each given audio so it is an episode, into a new folder
    /// inside the world's folder.
    private func subscribe(_ world: FeedTestWorld, title: String, path: String, items: [FeedXML.Item]) async throws -> Feed {
        let episodes = items.map { item -> FeedXML.Item in
            var episode = item
            episode.enclosure = "https://atlas.example/audio/\(item.guid ?? UUID().uuidString).mp3"
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
            throw NSError(domain: "UnopenedCategoryTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(outcome)"])
        }
        return feed
    }
}

import XCTest
@testable import TextMouth

/// The Unopened category of the Library window, which replaced No Folder:
/// every book never opened, from every folder, and the feeds with items not
/// yet played. These tests pin its name, its sort key and the sort carried
/// over from No Folder, and its default sort.
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
    /// was; nothing is called No Folder any more.
    func testTheCategoriesAreNamedInOrder() {
        XCTAssertEqual(LibraryCategory.allCases.map(\.rawValue), ["Folders", "All Items", "Unopened", "Recent"])
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
        XCTAssertEqual(BookFolder.reservedNames, ["__allItems__", "__unopened__", "__recent__", "__noFolder__"])
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
}

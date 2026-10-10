import XCTest
@testable import TextMouth

/// Only a change the user makes saves a sort (TODO A06). Showing a
/// location's sort, whether on a window's first frame, after navigating, or
/// after the library is replaced, reads the saved setting and writes
/// nothing, and a change is saved under the location it was made in.
///
/// The tests use inert library models and put the test root's library index
/// back as they found it.
final class LibrarySortSavingTests: XCTestCase {
    private var sandbox: LibraryIndexSandbox!

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when capturing failed in set-up.
        sandbox?.restore()
    }

    // MARK: - Showing a Sort

    /// Showing the sort of every category and of several folders, as each
    /// window does on every frame, saves no setting for any of them.
    @MainActor
    func testShowingASortNeverSavesIt() {
        let model = makeModel(Library(folders: [BookFolder(name: "Essays")]))

        for category in LibraryCategory.allCases {
            for folder in ["", "Essays", "Essays/Travel"] {
                _ = model.sortState(at: LibraryLocation(category: category, folderPath: folder))
            }
        }

        XCTAssertTrue(model.library.folderSortSettings.isEmpty)
    }

    /// A library replaced by Try Again shows the sorts its index saved,
    /// through the same function that showed the provisional library's
    /// defaults while the index could not be read.
    @MainActor
    func testALibraryRestoredByTryAgainShowsTheSortsItsIndexSaved() throws {
        let shelf = "Sorted Shelf \(UUID().uuidString.prefix(8))"
        let index = Library(
            folders: [BookFolder(name: shelf)],
            folderSortSettings: [
                shelf: FolderSortSetting(sortField: .author, sortAscending: false),
                "__recent__": FolderSortSetting(sortField: .title, sortAscending: true)
            ]
        )
        try sandbox.stage(.unreadable, of: index, at: sandbox.indexURL)
        let model = LibraryViewModel(initializeServices: false)
        model.loadLibraryIndex()
        let shelfLocation = LibraryLocation(category: .folders, folderPath: shelf)
        let recent = LibraryLocation(category: .recent, folderPath: shelf)
        XCTAssertNotNil(model.indexRecovery)
        XCTAssertEqual(model.sortState(at: shelfLocation).titleFragment, "Title Ascending")
        XCTAssertEqual(model.sortState(at: recent).titleFragment, "Last Opened Descending")

        LibraryIndexSandbox.makeReadable(sandbox.indexURL)
        XCTAssertEqual(model.retryLibraryIndex(), .restored(bookCount: model.library.books.count))

        XCTAssertEqual(model.sortState(at: shelfLocation).titleFragment, "Author Descending")
        XCTAssertEqual(model.sortState(at: recent).titleFragment, "Title Ascending")
    }

    // MARK: - Saving a User's Change

    /// Reversing the direction just after a window opens reverses the sort
    /// saved for its location. A window that showed the Title Ascending
    /// default instead used to save Title Descending over the saved sort.
    @MainActor
    func testReversingRightAfterOpeningReversesTheSavedSort() {
        let model = makeModel(Library(folderSortSettings: [
            "": FolderSortSetting(sortField: .author, sortAscending: false)
        ]))
        let root = LibraryLocation(category: .folders, folderPath: "")

        let shown = model.userChangedSort(.reverseDirection, at: root)

        XCTAssertEqual(shown.titleFragment, "Author Ascending")
        XCTAssertEqual(model.library.folderSortSettings, [
            "": FolderSortSetting(sortField: .author, sortAscending: true)
        ])
    }

    /// After a window moves quickly through folders and categories, a change
    /// is saved only under the location shown when the user made it; the
    /// locations passed through keep no setting of their own.
    @MainActor
    func testAChangeAfterFastNavigationIsSavedOnlyWhereItWasMade() {
        let model = makeModel(Library(folders: [
            BookFolder(name: "Essays"),
            BookFolder(name: "Travel", parentPath: "Essays")
        ]))
        let route = [
            LibraryLocation(category: .folders, folderPath: ""),
            LibraryLocation(category: .folders, folderPath: "Essays"),
            LibraryLocation(category: .recent, folderPath: "Essays"),
            LibraryLocation(category: .allItems, folderPath: "Essays"),
            LibraryLocation(category: .folders, folderPath: "Essays/Travel")
        ]
        // The window shows each location in turn, as it draws after each move.
        for location in route {
            _ = model.sortState(at: location)
        }

        let travel = LibraryLocation(category: .folders, folderPath: "Essays/Travel")
        model.userChangedSort(.choose(.dateAdded), at: travel)

        XCTAssertEqual(Array(model.library.folderSortSettings.keys), ["Essays/Travel"])
        XCTAssertEqual(model.sortState(at: travel).titleFragment, "Date Added Ascending")
        XCTAssertEqual(model.sortState(at: route[1]).titleFragment, "Title Ascending", "Essays keeps its default")

        model.userChangedSort(.reverseDirection, at: route[2])

        XCTAssertEqual(Set(model.library.folderSortSettings.keys), ["Essays/Travel", "__recent__"])
        XCTAssertEqual(model.sortState(at: route[2]).titleFragment, "Last Opened Ascending")
        XCTAssertEqual(model.sortState(at: travel).titleFragment, "Date Added Ascending")
    }

    /// A change that leaves the sort as it was saves nothing: a manual
    /// setting saved by an earlier version stays exactly as it was saved.
    @MainActor
    func testAChangeThatChangesNothingSavesNothing() {
        let earlierManual = FolderSortSetting(sortField: .manual, sortAscending: false)
        let model = makeModel(Library(folderSortSettings: ["Shelf": earlierManual]))
        let shelf = LibraryLocation(category: .folders, folderPath: "Shelf")

        XCTAssertEqual(model.userChangedSort(.reverseDirection, at: shelf).titleFragment, "Manual Order")
        XCTAssertEqual(model.userChangedSort(.choose(.manual), at: shelf).titleFragment, "Manual Order")

        XCTAssertEqual(model.library.folderSortSettings, ["Shelf": earlierManual])
    }

    /// Choosing the field a location already shows, the Sort menu's checked
    /// item, keeps the sort and saves nothing (TODO A11): a saved descending
    /// sort stays descending, and a location still showing its category's
    /// default gains no setting.
    @MainActor
    func testChoosingTheCheckedFieldKeepsTheSortAndSavesNothing() {
        let authorDescending = FolderSortSetting(sortField: .author, sortAscending: false)
        let model = makeModel(Library(folderSortSettings: ["Shelf": authorDescending]))
        let shelf = LibraryLocation(category: .folders, folderPath: "Shelf")
        let recent = LibraryLocation(category: .recent, folderPath: "Shelf")

        XCTAssertEqual(model.userChangedSort(.choose(.author), at: shelf).titleFragment, "Author Descending")
        XCTAssertEqual(model.userChangedSort(.choose(.lastOpened), at: recent).titleFragment, "Last Opened Descending")

        XCTAssertEqual(model.library.folderSortSettings, ["Shelf": authorDescending])
    }

    /// A change is saved with the directions the location remembers, so
    /// leaving manual order restores the field's direction even after the
    /// library is loaded again.
    @MainActor
    func testRememberedDirectionsAreSavedWithTheChange() throws {
        let model = makeModel(Library())
        let shelf = LibraryLocation(category: .folders, folderPath: "Shelf")

        model.userChangedSort(.choose(.author), at: shelf)
        model.userChangedSort(.reverseDirection, at: shelf)
        model.userChangedSort(.choose(.manual), at: shelf)

        let reloaded = try LibrarySortStateTests.reread(model.library)
        XCTAssertEqual(reloaded.sortState(at: shelf).titleFragment, "Manual Order")
        XCTAssertEqual(reloaded.sortState(at: shelf).applying(.choose(.author)).titleFragment, "Author Descending")
        XCTAssertEqual(reloaded.sortState(at: shelf).applying(.choose(.title)).titleFragment, "Title Ascending")
    }

    // MARK: - Fixtures

    /// An inert library model holding `library`.
    @MainActor
    private func makeModel(_ library: Library) -> LibraryViewModel {
        let model = LibraryViewModel(initializeServices: false)
        model.library = library
        return model
    }
}

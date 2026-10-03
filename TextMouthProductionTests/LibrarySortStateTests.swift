import XCTest
@testable import TextMouth

/// The sort a library location shows (TODO A06): restored from the setting
/// saved for the location by one function, with one rule for manual order,
/// and shown by the window title, the Sort menu, and the comparator, which
/// all derive from the same `LibrarySortState` and so cannot disagree.
final class LibrarySortStateTests: XCTestCase {

    // MARK: - Restoring a Location's Sort

    /// A window that opens on the root of Folders shows the sort saved for
    /// the root, not the Title Ascending default, from its first frame.
    func testOpeningOnTheRootShowsTheSortSavedForIt() {
        let library = Library(folderSortSettings: [
            "": FolderSortSetting(sortField: .author, sortAscending: false)
        ])
        let root = LibraryLocation(category: .folders, folderPath: "")

        let sort = library.sortState(at: root)

        XCTAssertEqual(sort.field, .author)
        XCTAssertFalse(sort.isAscending)
        XCTAssertEqual(root.windowTitle(sortedBy: sort), "Library: All Folders (Author Descending)")
        XCTAssertEqual(sort.menuAccessibilityLabel, "Sort books by Author, descending")
    }

    /// Every category, and a folder inside Folders, restores the sort saved
    /// under its own key, whatever folder Folders showed last.
    func testEveryCategoryAndFolderRestoresItsOwnSavedSort() {
        let library = Library(folderSortSettings: [
            "__allItems__": FolderSortSetting(sortField: .dateAdded, sortAscending: false),
            "__noFolder__": FolderSortSetting(sortField: .fileSize, sortAscending: true),
            "__recent__": FolderSortSetting(sortField: .title, sortAscending: true),
            "Essays/Travel": FolderSortSetting(sortField: .author, sortAscending: false)
        ])
        let expectedTitles: [(LibraryLocation, String)] = [
            (LibraryLocation(category: .allItems, folderPath: "Essays/Travel"), "Library: All Items (Date Added Descending)"),
            (LibraryLocation(category: .noFolder, folderPath: "Essays/Travel"), "Library: No Folder (File Size Ascending)"),
            (LibraryLocation(category: .recent, folderPath: "Essays/Travel"), "Library: Recent (Title Ascending)"),
            (LibraryLocation(category: .folders, folderPath: "Essays/Travel"), "Library: Travel (Author Descending)")
        ]

        for (location, title) in expectedTitles {
            XCTAssertEqual(location.windowTitle(sortedBy: library.sortState(at: location)), title)
        }
    }

    /// A location with no saved sort shows its category's default: Last
    /// Opened Descending (newest first) for Recent, Title Ascending elsewhere.
    func testALocationWithoutASavedSortShowsItsCategoryDefault() {
        let library = Library()

        for category in LibraryCategory.allCases {
            let location = LibraryLocation(category: category, folderPath: "Unsorted Shelf")
            let expected = category == .recent ? "Last Opened Descending" : "Title Ascending"
            XCTAssertEqual(library.sortState(at: location).titleFragment, expected, "\(category)")
        }
    }

    /// Folders saves a sort under the folder's path; every other category
    /// saves under its reserved key, which no folder path can match.
    func testSortSettingsKeysFollowTheCategory() {
        XCTAssertEqual(LibraryLocation(category: .folders, folderPath: "").sortSettingsKey, "")
        XCTAssertEqual(LibraryLocation(category: .folders, folderPath: "Essays/Travel").sortSettingsKey, "Essays/Travel")
        XCTAssertEqual(LibraryLocation(category: .allItems, folderPath: "Essays").sortSettingsKey, "__allItems__")
        XCTAssertEqual(LibraryLocation(category: .noFolder, folderPath: "Essays").sortSettingsKey, "__noFolder__")
        XCTAssertEqual(LibraryLocation(category: .recent, folderPath: "Essays").sortSettingsKey, "__recent__")
    }

    // MARK: - Manual Order

    /// A saved manual setting is shown without a direction, whatever its
    /// `sortAscending` says: the books keep the order the user arranged, the
    /// direction command is off and says why, and nothing names a direction.
    func testManualOrderIgnoresTheSavedDirection() {
        let shelf = LibraryLocation(category: .folders, folderPath: "Shelf")
        let library = Library(folderSortSettings: [
            "Shelf": FolderSortSetting(sortField: .manual, sortAscending: false)
        ])
        let fixture = Self.distinctBooks()

        let sort = library.sortState(at: shelf)

        XCTAssertEqual(sort.field, .manual)
        XCTAssertFalse(sort.hasDirection)
        XCTAssertTrue(sort.isAscending, "manual order is held ascending, never reversed")
        XCTAssertEqual(shelf.windowTitle(sortedBy: sort), "Library: Shelf (Manual Order)")
        XCTAssertEqual(sort.menuAccessibilityLabel, "Sort books by Manual Order")
        XCTAssertEqual(sort.changeAnnouncement, "Sorted by Manual Order")
        XCTAssertFalse(sort.isDirectionCommandEnabled)
        XCTAssertEqual(sort.directionCommandHint, "Manual order has no direction")
        XCTAssertEqual(
            sort.sorted(fixture.books, fileSizes: fixture.fileSizes).map(\.title),
            Self.ascendingTitles[.manual]
        )
    }

    /// Reversing manual order, or choosing it again, changes nothing, so
    /// nothing needs saving.
    func testReversingOrChoosingManualOrderAgainChangesNothing() {
        let manual = LibrarySortState(restoring: FolderSortSetting(sortField: .manual, sortAscending: true))

        XCTAssertEqual(manual.applying(.reverseDirection), manual)
        XCTAssertEqual(manual.applying(.choose(.manual)), manual)
    }

    /// Leaving manual order shows the chosen field in the direction this
    /// location last showed it, or ascending when it has not shown it.
    func testLeavingManualOrderRestoresTheChosenFieldsLastDirection() {
        var sort = LibrarySortState(restoring: .defaultSort)

        sort = sort.applying(.reverseDirection)
        XCTAssertEqual(sort.titleFragment, "Title Descending")
        sort = sort.applying(.choose(.manual)).applying(.choose(.title))
        XCTAssertEqual(sort.titleFragment, "Title Descending", "Title comes back the way it was shown")

        sort = sort.applying(.choose(.manual)).applying(.choose(.author))
        XCTAssertEqual(sort.titleFragment, "Author Ascending", "a field not shown here starts ascending")

        sort = sort.applying(.reverseDirection).applying(.choose(.manual)).applying(.choose(.author))
        XCTAssertEqual(sort.titleFragment, "Author Descending")
        XCTAssertEqual(sort.applying(.choose(.title)).titleFragment, "Title Descending")
    }

    /// Choosing the field already shown reverses it, as the Sort menu always
    /// has; Sort Ascending and Sort Descending reverse it too.
    func testChoosingTheFieldShownReversesIt() {
        let titleAscending = LibrarySortState(restoring: .defaultSort)

        XCTAssertEqual(titleAscending.applying(.choose(.title)).titleFragment, "Title Descending")
        XCTAssertEqual(titleAscending.applying(.reverseDirection).titleFragment, "Title Descending")
        XCTAssertEqual(
            titleAscending.applying(.reverseDirection).applying(.reverseDirection),
            titleAscending
        )
    }

    /// Restoring forgets what a sort never remembers: the direction of the
    /// field shown, which `sortAscending` holds, and of manual order.
    func testRestoringKeepsOnlyTheOtherFieldsDirections() {
        let saved = FolderSortSetting(
            sortField: .title,
            sortAscending: true,
            rememberedDirections: [.title: false, .manual: false, .author: false]
        )

        let sort = LibrarySortState(restoring: saved)

        XCTAssertEqual(sort.rememberedDirections, [.author: false])
        XCTAssertEqual(sort.setting, FolderSortSetting(
            sortField: .title,
            sortAscending: true,
            rememberedDirections: [.author: false]
        ))
    }

    // MARK: - Saved Settings

    /// Remembered directions are saved with the setting, so after the
    /// library index is written and read again, leaving manual order still
    /// restores the chosen field's last direction.
    func testRememberedDirectionsSurviveTheLibraryIndex() throws {
        let sort = LibrarySortState(restoring: .defaultSort)
            .applying(.reverseDirection)
            .applying(.choose(.manual))
        let library = Library(folderSortSettings: ["Shelf": sort.setting])

        let reread = try Self.reread(library)

        let shelf = LibraryLocation(category: .folders, folderPath: "Shelf")
        XCTAssertEqual(reread.sortState(at: shelf), sort)
        XCTAssertEqual(reread.sortState(at: shelf).applying(.choose(.title)).titleFragment, "Title Descending")
    }

    /// A setting with nothing remembered is written exactly as before
    /// TODO A06, and a setting written before then reads with nothing
    /// remembered, so older and newer indexes read each other's settings.
    func testSettingsWithoutRememberedDirectionsKeepTheEarlierFormat() throws {
        let written = try JSONEncoder().encode(FolderSortSetting(sortField: .author, sortAscending: false))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: written) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["sortField", "sortAscending"])

        let earlier = Data(#"{"sortField": "Author", "sortAscending": false}"#.utf8)
        let read = try JSONDecoder().decode(FolderSortSetting.self, from: earlier)
        XCTAssertEqual(read, FolderSortSetting(sortField: .author, sortAscending: false))
        XCTAssertTrue(read.rememberedDirections.isEmpty)
    }

    /// Remembered directions never cost the library index: a field this
    /// version does not know is skipped, and a value it cannot read is
    /// dropped while the rest of the setting still reads.
    func testUnreadableRememberedDirectionsAreSkipped() throws {
        let unknownField = Data(#"""
        {"sortField": "Title", "sortAscending": true,
         "rememberedDirections": {"Author": false, "Shelf Mark": true}}
        """#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(FolderSortSetting.self, from: unknownField).rememberedDirections,
            [.author: false]
        )

        let malformed = Data(#"{"sortField": "Date Added", "sortAscending": false, "rememberedDirections": "descending"}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(FolderSortSetting.self, from: malformed),
            FolderSortSetting(sortField: .dateAdded, sortAscending: false)
        )
    }

    // MARK: - Applying a Sort to Subfolders

    /// Applying manual order to subfolders gives each the choice of manual
    /// order, without a direction, and the folder's remembered directions;
    /// it never copies the order of the books, which differ in each folder.
    func testApplyingManualOrderToSubfoldersCopiesTheChoiceNotTheOrder() {
        var library = Library(
            books: [
                Self.shelvedBook("Parent Opener", in: "Parent", manualOrder: 1),
                Self.shelvedBook("Parent Closer", in: "Parent", manualOrder: 0),
                Self.shelvedBook("Child Opener", in: "Parent/Child", manualOrder: 2),
                Self.shelvedBook("Child Middle", in: "Parent/Child", manualOrder: 0),
                Self.shelvedBook("Child Closer", in: "Parent/Child", manualOrder: 1)
            ],
            folders: [
                BookFolder(name: "Parent"),
                BookFolder(name: "Child", parentPath: "Parent"),
                BookFolder(name: "Grandchild", parentPath: "Parent/Child"),
                BookFolder(name: "Elsewhere")
            ],
            folderSortSettings: ["Elsewhere": FolderSortSetting(sortField: .author, sortAscending: false)]
        )
        let orderBefore = library.books.map(\.manualSortOrder)

        library.applySortToSubfolders(
            FolderSortSetting(sortField: .manual, sortAscending: false, rememberedDirections: [.title: false, .manual: true]),
            from: "Parent"
        )

        let applied = FolderSortSetting(sortField: .manual, sortAscending: true, rememberedDirections: [.title: false])
        for path in ["Parent", "Parent/Child", "Parent/Child/Grandchild"] {
            XCTAssertEqual(library.folderSortSettings[path], applied, path)
        }
        XCTAssertEqual(library.sortSetting(for: "Elsewhere"), FolderSortSetting(sortField: .author, sortAscending: false))
        XCTAssertEqual(library.books.map(\.manualSortOrder), orderBefore, "no book's manual position changes")

        let child = LibraryLocation(category: .folders, folderPath: "Parent/Child")
        XCTAssertEqual(child.windowTitle(sortedBy: library.sortState(at: child)), "Library: Child (Manual Order)")
        XCTAssertEqual(
            library.sortState(at: child).applying(.choose(.title)).titleFragment,
            "Title Descending",
            "a subfolder switches fields as the folder it copied does"
        )
    }

    /// Applying any other field gives every folder that field and direction.
    func testApplyingAFieldToSubfoldersCopiesItsDirection() {
        var library = Library(folders: [
            BookFolder(name: "Parent"),
            BookFolder(name: "Child", parentPath: "Parent")
        ])
        let parent = LibraryLocation(category: .folders, folderPath: "Parent")
        let dateDescending = library.sortState(at: parent)
            .applying(.choose(.dateAdded))
            .applying(.reverseDirection)

        library.applySortToSubfolders(dateDescending.setting, from: "Parent")

        for path in ["Parent", "Parent/Child"] {
            let location = LibraryLocation(category: .folders, folderPath: path)
            XCTAssertEqual(library.sortState(at: location), dateDescending, path)
        }
    }

    // MARK: - Where Books Can Be Rearranged

    /// Books can be rearranged only where the list shows one folder's
    /// manual order: a folder in Folders, and the root's books in No Folder.
    /// All Items and Recent mix folders, and other sorts have no manual
    /// order to change.
    func testRearrangingIsOfferedOnlyWhereOneFoldersManualOrderIsShown() {
        let manual = LibrarySortState(restoring: FolderSortSetting(sortField: .manual, sortAscending: true))
        let expected: [(LibraryLocation, String?)] = [
            (LibraryLocation(category: .folders, folderPath: "Essays/Travel"), "Essays/Travel"),
            (LibraryLocation(category: .folders, folderPath: ""), ""),
            (LibraryLocation(category: .noFolder, folderPath: "Essays/Travel"), ""),
            (LibraryLocation(category: .allItems, folderPath: "Essays/Travel"), nil),
            (LibraryLocation(category: .recent, folderPath: "Essays/Travel"), nil)
        ]

        for (location, folder) in expected {
            XCTAssertEqual(location.reorderableFolder(sortedBy: manual), folder, "\(location.category)")
            for field in LibrarySortField.allCases where field.hasDirection {
                let sorted = LibrarySortState(restoring: FolderSortSetting(sortField: field, sortAscending: true))
                XCTAssertNil(location.reorderableFolder(sortedBy: sorted), "\(location.category), \(field.rawValue)")
            }
        }

        // No Folder lists exactly the root's books, so its order is the root's.
        let library = Library(books: [
            Self.shelvedBook("Loose Pages", in: "", manualOrder: 0),
            Self.shelvedBook("Filed Pages", in: "Essays", manualOrder: 0)
        ])
        XCTAssertEqual(library.booksWithNoFolder().map(\.id), library.booksInFolder("").map(\.id))
    }

    // MARK: - One Value, Shown Consistently

    /// For every field and saved direction, the window title, the Sort
    /// menu's checked field and direction command, the Sort button's label,
    /// and the order of the books all agree, because each derives from the
    /// one restored sort. Manual order has no direction in any of them.
    func testTitleMenuAndOrderAgreeForEveryFieldAndDirection() {
        XCTAssertEqual(Set(Self.ascendingTitles.keys), Set(LibrarySortField.allCases), "every field needs an expected order")
        let fixture = Self.distinctBooks()
        let shelf = LibraryLocation(category: .folders, folderPath: "Shelf")

        for field in LibrarySortField.allCases {
            for savedAscending in [true, false] {
                let sort = LibrarySortState(restoring: FolderSortSetting(sortField: field, sortAscending: savedAscending))
                let context = "\(field.rawValue), saved ascending: \(savedAscending)"
                // Manual order ignores a saved direction; every other field shows it.
                let shownAscending = field.hasDirection ? savedAscending : true
                let directionWord = shownAscending ? "Ascending" : "Descending"

                XCTAssertEqual(LibrarySortField.allCases.filter(sort.isChecked), [field], context)
                XCTAssertEqual(sort.isDirectionCommandEnabled, field.hasDirection, context)
                XCTAssertEqual(sort.directionCommandTitle, shownAscending ? "Sort Descending" : "Sort Ascending", context)
                if field.hasDirection {
                    XCTAssertEqual(shelf.windowTitle(sortedBy: sort), "Library: Shelf (\(field.rawValue) \(directionWord))", context)
                    XCTAssertEqual(sort.menuAccessibilityLabel, "Sort books by \(field.rawValue), \(directionWord.lowercased())", context)
                    XCTAssertEqual(sort.directionCommandHint, "Reverses the order of the books", context)
                } else {
                    XCTAssertEqual(shelf.windowTitle(sortedBy: sort), "Library: Shelf (Manual Order)", context)
                    XCTAssertEqual(sort.menuAccessibilityLabel, "Sort books by Manual Order", context)
                    XCTAssertEqual(sort.directionCommandHint, "Manual order has no direction", context)
                }

                let ascending = Self.ascendingTitles[field] ?? []
                XCTAssertEqual(
                    sort.sorted(fixture.books, fileSizes: fixture.fileSizes).map(\.title),
                    shownAscending ? ascending : Array(ascending.reversed()),
                    context
                )
            }
        }
    }

    /// The announcements name the sort the same way the Sort button does.
    func testAnnouncementsNameTheSortShown() {
        let sort = LibrarySortState(restoring: FolderSortSetting(sortField: .lastOpened, sortAscending: false))

        XCTAssertEqual(sort.changeAnnouncement, "Sorted by Last Opened, descending")
        XCTAssertEqual(sort.subfolderAnnouncement, "All subfolders now sorted by Last Opened, descending")
    }

    // MARK: - Fixtures

    /// Each field's ascending order of `distinctBooks()`, by title. Every
    /// field orders the books differently, so a comparator that sorts by
    /// the wrong field, or in the wrong direction, cannot pass.
    static let ascendingTitles: [LibrarySortField: [String]] = [
        .title: ["Abacus Lessons", "Bellfounder's Year", "Cartography Notes", "Dockside Ledger"],
        .author: ["Cartography Notes", "Bellfounder's Year", "Dockside Ledger", "Abacus Lessons"],
        .dateAdded: ["Bellfounder's Year", "Dockside Ledger", "Abacus Lessons", "Cartography Notes"],
        .lastOpened: ["Cartography Notes", "Abacus Lessons", "Dockside Ledger", "Bellfounder's Year"],
        .fileSize: ["Abacus Lessons", "Cartography Notes", "Dockside Ledger", "Bellfounder's Year"],
        .manual: ["Dockside Ledger", "Cartography Notes", "Abacus Lessons", "Bellfounder's Year"]
    ]

    /// Four books whose every sortable value differs, listed in no field's
    /// order, with the file size of each.
    static func distinctBooks() -> (books: [Book], fileSizes: [UUID: Int]) {
        typealias Spec = (title: String, author: String, added: TimeInterval, opened: TimeInterval, size: Int, manual: Int)
        let specs: [Spec] = [
            ("Cartography Notes", "Abara", 400, 10, 500, 1),
            ("Abacus Lessons", "Okafor", 300, 20, 100, 2),
            ("Dockside Ledger", "Mwangi", 200, 30, 700, 0),
            ("Bellfounder's Year", "Lindqvist", 100, 40, 900, 3)
        ]
        var fileSizes: [UUID: Int] = [:]
        let books = specs.map { spec -> Book in
            let id = UUID()
            fileSizes[id] = spec.size
            return Book(
                id: id,
                title: spec.title,
                author: spec.author,
                format: .txt,
                filePath: "/nonexistent/sort-state/\(id.uuidString).txt",
                md5Hash: "sort-state-\(id.uuidString)",
                dateAdded: Date(timeIntervalSince1970: spec.added),
                lastOpened: Date(timeIntervalSince1970: spec.opened),
                manualSortOrder: spec.manual
            )
        }
        return (books, fileSizes)
    }

    /// A book in `folder` at `manualOrder` in the folder's manual order.
    static func shelvedBook(_ title: String, in folder: String, manualOrder: Int) -> Book {
        let id = UUID()
        return Book(
            id: id,
            title: title,
            format: .txt,
            filePath: "/nonexistent/sort-state/\(id.uuidString).txt",
            md5Hash: "sort-state-\(id.uuidString)",
            folderPath: folder,
            manualSortOrder: manualOrder
        )
    }

    /// `library` written as `LibraryPersistenceService` writes the index,
    /// then read back.
    static func reread(_ library: Library) throws -> Library {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Library.self, from: LibraryIndexSandbox.encoded(library))
    }
}

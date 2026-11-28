import XCTest
@testable import TextMouth

/// `PhoneLibraryChoices`: what the Library view and Sort sheets offer, which
/// is current, and the Mac's words for each.
@MainActor
final class PhoneLibraryChoicesTests: XCTestCase {
    /// In a folder with subfolders, Sort offers the six fields, the direction,
    /// and Apply Sort to All Subfolders, with the shown field current.
    func testSortInAFolderWithSubfolders() {
        let location = LibraryLocation(category: .folders, folderPath: "Fiction")
        let sort = LibrarySortState(restoring: FolderSortSetting(sortField: .author, sortAscending: true))

        let choices = PhoneLibraryChoices.sortChoices(at: location, sort: sort, hasSubfolders: true)

        XCTAssertEqual(
            choices.map(\.label),
            ["Title", "Author", "Date Added", "Last Opened", "File Size", "Manual Order", "Sort Descending", "Apply Sort to All Subfolders"]
        )
        XCTAssertTrue(choices.allSatisfy(\.isEnabled))
        XCTAssertEqual(PhoneLibraryChoices.currentSortChoice(at: location, sort: sort), .field(.author))
        XCTAssertEqual(PhoneLibraryChoices.sortLabel(at: location, sort: sort), "Sort books by Author, ascending")
    }

    /// In Manual Order the direction is dimmed, with the Mac's hint; a view
    /// other than Folders never offers Apply Sort to All Subfolders.
    func testManualOrderDimsTheDirection() throws {
        let location = LibraryLocation(category: .allItems, folderPath: "")
        let sort = LibrarySortState(restoring: FolderSortSetting(sortField: .manual, sortAscending: true))

        let choices = PhoneLibraryChoices.sortChoices(at: location, sort: sort, hasSubfolders: true)

        let direction = try XCTUnwrap(choices.first { $0.id == .reverseDirection })
        XCTAssertFalse(direction.isEnabled)
        XCTAssertEqual(direction.hint, "Manual order has no direction")
        XCTAssertFalse(choices.contains { $0.id == .applyToSubfolders })
    }

    /// The Reading List offers its one order, current, under the Mac's words.
    func testTheReadingListsOneOrder() {
        let location = LibraryLocation(category: .readingList, folderPath: "")
        let sort = LibrarySortState(restoring: location.defaultSortSetting)

        let choices = PhoneLibraryChoices.sortChoices(at: location, sort: sort, hasSubfolders: false)

        XCTAssertEqual(choices.map(\.label), ["Reading List Order"])
        XCTAssertEqual(PhoneLibraryChoices.currentSortChoice(at: location, sort: sort), .readingListOrder)
        XCTAssertEqual(PhoneLibraryChoices.sortLabel(at: location, sort: sort), "Sort books by Reading List Order")
        XCTAssertEqual(
            PhoneLibraryChoices.choose(.readingListOrder, at: location, in: PhoneLibraryFixture.model(books: [])),
            "Sorted by Reading List Order"
        )
    }

    /// The sheet offers the views the Mac's pop-up offers: with no feed, no
    /// Feeds view, since a view shown when applicable lists something; the
    /// phone filters none of them out any more (FR53).
    func testWithNoFeedTheSheetOffersWhatTheMacOffers() {
        let model = PhoneLibraryFixture.model(books: [PhoneLibraryFixture.book("Emma")])
        let list = LibraryViewDefinitionList.shipped
        // The library's own engine, which was never started and so holds no feed.
        let center = model.feeds

        let offered = PhoneLibraryChoices.views(in: model, list: list, current: .category(.folders), center: center)

        XCTAssertEqual(offered.map(\.id), model.offeredViews(in: list, current: .category(.folders), center: center).map(\.id))
        XCTAssertFalse(offered.contains { $0.id == .feeds }, "a Feeds view with no feed to list was offered")
        XCTAssertTrue(offered.contains { $0.id == .category(.allItems) })
    }
}

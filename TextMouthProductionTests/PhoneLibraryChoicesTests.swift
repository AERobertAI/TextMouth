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

    /// Feeds, and a view of feeds alone, aren't offered on the phone.
    func testFeedsArentOffered() throws {
        let feeds = try XCTUnwrap(LibraryViewDefinition.shipped(LibraryViewID.feeds))
        XCTAssertFalse(PhoneLibraryChoices.isOfferedOnPhone(feeds))
        XCTAssertTrue(PhoneLibraryChoices.isOfferedOnPhone(LibraryViewDefinition.shipped(.allItems)))
        XCTAssertTrue(PhoneLibraryChoices.isOfferedOnPhone(LibraryViewDefinition.shipped(.folders)))
    }
}

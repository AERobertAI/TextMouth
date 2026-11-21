import XCTest
@testable import TextMouth

/// `PhoneEscapePolicy`: what the two-finger scrub does on a Library screen.
final class PhoneEscapePolicyTests: XCTestCase {
    /// A search in progress is cleared first, at the top and in a folder.
    func testASearchIsClearedFirst() {
        XCTAssertEqual(PhoneEscapePolicy.libraryOutcome(isSearching: true, isFolderScreen: false), .clearSearch)
        XCTAssertEqual(PhoneEscapePolicy.libraryOutcome(isSearching: true, isFolderScreen: true), .clearSearch)
    }

    /// With no search, a folder goes back to its parent.
    func testAFolderGoesBack() {
        XCTAssertEqual(PhoneEscapePolicy.libraryOutcome(isSearching: false, isFolderScreen: true), .goBack)
    }

    /// With no search, the top of the Library has nowhere to go.
    func testTheTopOfTheLibraryDoesNothing() {
        XCTAssertEqual(PhoneEscapePolicy.libraryOutcome(isSearching: false, isFolderScreen: false), .nothing)
    }
}

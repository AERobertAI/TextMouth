import XCTest
@testable import TextMouth

/// `PhoneRoute`: the reader's screen is on the navigation stack at most once,
/// so that Back never lands on the screen it left.
final class PhoneRouteTests: XCTestCase {
    /// From the Library or a folder, the reader's screen is pushed.
    func testTheReadersScreenIsPushed() {
        XCTAssertEqual(PhoneRoute.showingReader(on: []), [.reader])
        XCTAssertEqual(PhoneRoute.showingReader(on: [.folder(path: "Novels")]), [.folder(path: "Novels"), .reader])
    }

    /// A book opened while its screen shows pushes nothing, and whatever was
    /// above the reader's screen goes.
    func testTheReadersScreenIsNeverPushedTwice() {
        XCTAssertEqual(PhoneRoute.showingReader(on: [.reader]), [.reader])
        XCTAssertEqual(
            PhoneRoute.showingReader(on: [.folder(path: "Novels"), .reader, .settings]),
            [.folder(path: "Novels"), .reader]
        )
    }

    /// Whether a path shows the reader's screen, on top or under another.
    func testWhetherAPathShowsTheReader() {
        XCTAssertFalse(PhoneRoute.showsReader([]))
        XCTAssertFalse(PhoneRoute.showsReader([.folder(path: "Novels"), .settings]))
        XCTAssertTrue(PhoneRoute.showsReader([.reader, .settings]))
    }
}

import XCTest
@testable import TextMouth

/// `PhoneRoute`: the reader's screen is on the navigation stack at most once,
/// so that Back never lands on the screen it left.
final class PhoneRouteTests: XCTestCase {
    /// From the Library, the reader's screen is pushed.
    func testTheReadersScreenIsPushedOntoAnEmptyStack() {
        XCTAssertEqual(PhoneRoute.showingReader(on: []), [.reader])
    }

    /// A book opened while its screen shows pushes nothing: an import opening
    /// its book, or a row's tap arriving as the first is pushed.
    func testTheReadersScreenIsNeverPushedTwice() {
        XCTAssertEqual(PhoneRoute.showingReader(on: [.reader]), [.reader])
    }
}

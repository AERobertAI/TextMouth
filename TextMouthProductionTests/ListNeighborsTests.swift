import XCTest
@testable import TextMouth

/// `ListNeighbors`, the one search for the element beside another in an
/// ordered list, shared by the reading list, a plain folder, and a feed's
/// items (FR19, B1).
final class ListNeighborsTests: XCTestCase {

    // MARK: - beyond

    /// Going down, the elements after the id come nearest first; going up,
    /// the elements before it, read backward, also nearest first.
    func testBeyondInTheMiddleGoesBothWays() {
        let ids = [1, 2, 3, 4, 5]
        XCTAssertEqual(ListNeighbors.beyond(3, going: .down, in: ids), [4, 5])
        XCTAssertEqual(ListNeighbors.beyond(3, going: .up, in: ids), [2, 1])
    }

    /// At the ends there is nothing beyond: the last going down, the first
    /// going up. The other way still holds the rest.
    func testBeyondAtTheEndsIsEmptyThatWay() {
        let ids = [1, 2, 3]
        XCTAssertEqual(ListNeighbors.beyond(3, going: .down, in: ids), [])
        XCTAssertEqual(ListNeighbors.beyond(3, going: .up, in: ids), [2, 1])
        XCTAssertEqual(ListNeighbors.beyond(1, going: .up, in: ids), [])
        XCTAssertEqual(ListNeighbors.beyond(1, going: .down, in: ids), [2, 3])
    }

    /// An id the list does not hold has no elements beyond it, which is nil
    /// (and so differs from the empty list that the last element has).
    func testBeyondAnAbsentIdIsNil() {
        XCTAssertNil(ListNeighbors.beyond(9, going: .down, in: [1, 2, 3]))
        XCTAssertNil(ListNeighbors.beyond(9, going: .up, in: [1, 2, 3]))
        XCTAssertNil(ListNeighbors.beyond(1, going: .down, in: [Int]()))
        XCTAssertNil(ListNeighbors.beyond(1, going: .up, in: [Int]()))
    }

    /// An id that appears twice counts at its first position.
    func testBeyondARepeatedIdCountsFromItsFirstPosition() {
        let ids = [1, 2, 1, 3]
        XCTAssertEqual(ListNeighbors.beyond(1, going: .down, in: ids), [2, 1, 3])
        XCTAssertEqual(ListNeighbors.beyond(1, going: .up, in: ids), [])
    }

    /// A list of one has nothing beyond its element either way.
    func testBeyondTheOnlyElementIsEmpty() {
        XCTAssertEqual(ListNeighbors.beyond(7, going: .down, in: [7]), [])
        XCTAssertEqual(ListNeighbors.beyond(7, going: .up, in: [7]), [])
    }

    // MARK: - neighbor

    /// With everything eligible the neighbor is the adjacent element.
    func testNeighborIsTheAdjacentElementWhenAllQualify() {
        let ids = [1, 2, 3, 4]
        XCTAssertEqual(ListNeighbors.neighbor(of: 2, .down, in: ids) { _ in true }, 3)
        XCTAssertEqual(ListNeighbors.neighbor(of: 2, .up, in: ids) { _ in true }, 1)
    }

    /// Ineligible elements are passed over, nearest eligible first, both ways.
    func testNeighborPassesOverIneligibleElements() {
        let ids = [1, 2, 3, 4, 5, 6]
        XCTAssertEqual(ListNeighbors.neighbor(of: 3, .down, in: ids) { $0 % 2 == 0 && $0 > 3 }, 4)
        XCTAssertEqual(ListNeighbors.neighbor(of: 5, .up, in: ids) { $0 < 3 }, 2)
        XCTAssertEqual(ListNeighbors.neighbor(of: 1, .down, in: ids) { $0 == 6 }, 6)
    }

    /// The id itself is never its own neighbor, even when it is eligible.
    func testNeighborNeverReturnsTheIdItself() {
        XCTAssertNil(ListNeighbors.neighbor(of: 3, .down, in: [1, 2, 3]) { _ in true })
        XCTAssertNil(ListNeighbors.neighbor(of: 1, .up, in: [1, 2, 3]) { _ in true })
    }

    /// No eligible element that way, an absent id, and an empty list all give nil.
    func testNeighborIsNilWhenNothingQualifiesOrTheIdIsAbsent() {
        XCTAssertNil(ListNeighbors.neighbor(of: 2, .down, in: [1, 2, 3]) { _ in false })
        XCTAssertNil(ListNeighbors.neighbor(of: 2, .down, in: [1, 2, 3]) { $0 < 2 })
        XCTAssertNil(ListNeighbors.neighbor(of: 2, .up, in: [1, 2, 3]) { $0 > 2 })
        XCTAssertNil(ListNeighbors.neighbor(of: 9, .down, in: [1, 2, 3]) { _ in true })
        XCTAssertNil(ListNeighbors.neighbor(of: 1, .down, in: [Int]()) { _ in true })
    }

    /// A repeated id searches from its first position.
    func testNeighborOfARepeatedIdSearchesFromItsFirstPosition() {
        XCTAssertEqual(ListNeighbors.neighbor(of: 1, .down, in: [1, 2, 1, 3]) { _ in true }, 2)
    }

    // MARK: - The reading list

    /// `ReadingList.neighbor` still answers as it did, through the shared search.
    func testTheReadingListDelegatesToTheSharedSearch() {
        let ids = (0..<4).map { _ in UUID() }
        let list = ReadingList(bookIDs: ids)
        XCTAssertEqual(list.neighbor(of: ids[1], .down) { _ in true }, ids[2])
        XCTAssertEqual(list.neighbor(of: ids[1], .up) { _ in true }, ids[0])
        XCTAssertEqual(list.neighbor(of: ids[1], .down) { $0 == ids[3] }, ids[3])
        XCTAssertNil(list.neighbor(of: UUID(), .down) { _ in true })
        XCTAssertNil(list.neighbor(of: ids[3], .down) { _ in true })
    }
}

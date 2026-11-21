import XCTest
@testable import TextMouth

/// `PhoneScreenHolds`: the one keeper of the screen's sleep, which keeps the
/// screen awake while anyone holds it, so two owners never switch each other
/// off.
@MainActor
final class PhoneScreenHoldsTests: XCTestCase {
    /// What the keeper told its owner, oldest first.
    private var told: [Bool] = []

    private func makeHolds() -> PhoneScreenHolds {
        told = []
        return PhoneScreenHolds { [weak self] in self?.told.append($0) }
    }

    /// The first hold turns the screen's sleep off; the last let go turns it
    /// back on; and the owner is told only of those two changes.
    func testTheScreenStaysAwakeWhileAnyoneHolds() {
        let holds = makeHolds()
        XCTAssertFalse(holds.keepsScreenAwake)

        let importHold = holds.begin()
        let textHold = holds.begin()
        XCTAssertEqual(holds.holdCount, 2)
        XCTAssertEqual(told, [true], "The second hold changes nothing")

        // The import ends first: Book content still holds, so the screen
        // must not be let lock under a braille reader.
        importHold()
        XCTAssertTrue(holds.keepsScreenAwake)
        XCTAssertEqual(told, [true])

        textHold()
        XCTAssertFalse(holds.keepsScreenAwake)
        XCTAssertEqual(told, [true, false])
    }

    /// Letting go twice lets go once: a second call can't take another
    /// owner's hold away.
    func testLettingGoTwiceDoesNothing() {
        let holds = makeHolds()
        let first = holds.begin()
        let second = holds.begin()
        first()
        first()
        XCTAssertEqual(holds.holdCount, 1)
        XCTAssertTrue(holds.keepsScreenAwake, "The other owner's hold is still in force")
        second()
        XCTAssertEqual(told, [true, false])
    }

    /// A hold taken again after all were let go turns the sleep off again.
    func testAHoldAfterAllWereLetGoTurnsSleepOffAgain() {
        let holds = makeHolds()
        holds.begin()()
        let again = holds.begin()
        XCTAssertEqual(told, [true, false, true])
        again()
        XCTAssertEqual(told, [true, false, true, false])
    }
}

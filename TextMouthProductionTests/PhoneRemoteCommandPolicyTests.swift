import XCTest
@testable import TextMouth

/// Which system media commands the iPhone offers for each navigation unit, so
/// that the lock screen never promises seconds it won't skip.
final class PhoneRemoteCommandPolicyTests: XCTestCase {
    /// The commands every book has, whatever its unit.
    private let alwaysOn: [PhoneRemoteCommandPolicy.Command] = [.play, .pause, .togglePlayPause, .nextTrack, .previousTrack]

    func testAUnitOfSecondsEnablesBothSkipsWithItsSeconds() {
        let expected: [SkipUnit: Double] = [.seconds10: 10, .seconds15: 15, .seconds30: 30, .seconds60: 60]
        for (unit, seconds) in expected {
            let policy = PhoneRemoteCommandPolicy(unit: unit)
            XCTAssertTrue(policy.isEnabled(.skipForward), unit.rawValue)
            XCTAssertTrue(policy.isEnabled(.skipBackward), unit.rawValue)
            XCTAssertEqual(policy.preferredIntervals(for: .skipForward), [seconds], unit.rawValue)
            XCTAssertEqual(policy.preferredIntervals(for: .skipBackward), [seconds], unit.rawValue)
        }
    }

    func testEveryOtherUnitDisablesTheSkipsSoNothingPromisesSeconds() {
        let structural = SkipUnit.allCases.filter { !$0.isTimeBased }
        XCTAssertEqual(structural.count, 6, "sentence, paragraph, page, heading, subheading, bookmark")
        for unit in structural {
            let policy = PhoneRemoteCommandPolicy(unit: unit)
            XCTAssertFalse(policy.isEnabled(.skipForward), unit.rawValue)
            XCTAssertFalse(policy.isEnabled(.skipBackward), unit.rawValue)
            XCTAssertEqual(policy.preferredIntervals(for: .skipForward), [], unit.rawValue)
            XCTAssertEqual(policy.preferredIntervals(for: .skipBackward), [], unit.rawValue)
        }
    }

    func testNextAndPreviousTrackAndPlayPauseAreAlwaysOn() {
        for unit in SkipUnit.allCases {
            let policy = PhoneRemoteCommandPolicy(unit: unit)
            for command in alwaysOn {
                XCTAssertTrue(policy.isEnabled(command), "\(command) for \(unit.rawValue)")
            }
        }
        for command in alwaysOn {
            XCTAssertTrue(PhoneRemoteCommandPolicy.noBook.isEnabled(command), "\(command) before any book")
        }
    }

    func testEveryOtherCommandStaysDisabled() {
        let others = PhoneRemoteCommandPolicy.Command.allCases.filter {
            !alwaysOn.contains($0) && $0 != .skipForward && $0 != .skipBackward
        }
        XCTAssertEqual(others.count, 13, "every command MPRemoteCommandCenter has is named")
        for unit in SkipUnit.allCases {
            for command in others {
                XCTAssertFalse(PhoneRemoteCommandPolicy(unit: unit).isEnabled(command), "\(command) for \(unit.rawValue)")
            }
        }
    }

    func testTwoUnitsAreJudgedEachOnItsOwn() {
        let policy = PhoneRemoteCommandPolicy(forward: .seconds30, backward: .sentence)
        XCTAssertTrue(policy.isEnabled(.skipForward))
        XCTAssertEqual(policy.preferredIntervals(for: .skipForward), [30])
        XCTAssertFalse(policy.isEnabled(.skipBackward))
        XCTAssertEqual(policy.preferredIntervals(for: .skipBackward), [])
    }

    func testBeforeAnyBookTheSkipsAreOff() {
        XCTAssertFalse(PhoneRemoteCommandPolicy.noBook.isEnabled(.skipForward))
        XCTAssertFalse(PhoneRemoteCommandPolicy.noBook.isEnabled(.skipBackward))
    }

    func testOnlyTheSkipsHaveIntervals() {
        let policy = PhoneRemoteCommandPolicy(unit: .seconds15)
        for command in PhoneRemoteCommandPolicy.Command.allCases where command != .skipForward && command != .skipBackward {
            XCTAssertEqual(policy.preferredIntervals(for: command), [], "\(command)")
        }
    }

    // MARK: - With no reader open

    func testAPlayOrAPressWithNoReaderOpensTheLastBook() {
        XCTAssertEqual(PhoneRemoteCommandPolicy.noReaderOutcome(for: .play, canOpenLastBook: true), .opensLastBook)
        XCTAssertEqual(PhoneRemoteCommandPolicy.noReaderOutcome(for: .togglePlayPause, canOpenLastBook: true), .opensLastBook)
    }

    func testWithNoWayToOpenABookAPlayHasNothingToActOn() {
        XCTAssertEqual(PhoneRemoteCommandPolicy.noReaderOutcome(for: .play, canOpenLastBook: false), .noActionableItem)
        XCTAssertEqual(PhoneRemoteCommandPolicy.noReaderOutcome(for: .togglePlayPause, canOpenLastBook: false), .noActionableItem)
    }

    func testEveryOtherCommandWithNoReaderHasNothingToActOn() {
        let others: [RemoteMediaCommandRequest] = [.pause, .skipForward, .skipBackward, .nextTrack, .previousTrack]
        for request in others {
            XCTAssertEqual(PhoneRemoteCommandPolicy.noReaderOutcome(for: request, canOpenLastBook: true), .noActionableItem, request.rawValue)
        }
    }
}

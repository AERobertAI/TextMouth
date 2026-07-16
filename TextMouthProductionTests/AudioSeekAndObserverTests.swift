import XCTest
@testable import TextMouth

final class AudioSeekAndObserverTests: XCTestCase {
    func testObserverPublishesOrdinaryPosition() {
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 12, isSeeking: false, clipEndTime: nil),
            .publish(12)
        )
    }

    func testObserverSuppressesPositionWhileSeekIsPending() {
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 12, isSeeking: true, clipEndTime: nil),
            .ignore
        )
    }

    func testObserverSuppressesClipEndWhileSeekIsPending() {
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 30, isSeeking: true, clipEndTime: 20),
            .ignore
        )
    }

    func testObserverFinishesAtSegmentClipBoundary() {
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 20, isSeeking: false, clipEndTime: 20),
            .finishClip
        )
    }

    func testObserverPublishesBeforeSegmentClipBoundary() {
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 19.999, isSeeking: false, clipEndTime: 20),
            .publish(19.999)
        )
    }

    func testObserverIgnoresNonFinitePlayerTime() {
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: .nan, isSeeking: false, clipEndTime: nil),
            .ignore
        )
    }

    func testStaleSeekCompletionCannotReleaseNewerSeek() {
        let gate = AudioSeekGate()
        let first = gate.begin()
        _ = gate.begin()

        gate.complete(first)

        XCTAssertTrue(gate.isSeeking)
    }

    func testLatestSeekCompletionReleasesObserverGate() {
        let gate = AudioSeekGate()
        _ = gate.begin()
        let latest = gate.begin()

        gate.complete(latest)

        XCTAssertFalse(gate.isSeeking)
    }

    func testCancelInvalidatesEveryOutstandingSeek() {
        let gate = AudioSeekGate()
        let pending = gate.begin()

        gate.cancelAll()
        gate.complete(pending)

        XCTAssertFalse(gate.isSeeking)
    }

    func testConsecutiveSharedFileSegmentsRemainGatedUntilLatestSeekLands() {
        let gate = AudioSeekGate()
        let firstSegmentSeek = gate.begin()
        let secondSegmentSeek = gate.begin()

        gate.complete(firstSegmentSeek)
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 30, isSeeking: gate.isSeeking, clipEndTime: 30),
            .ignore
        )

        gate.complete(secondSegmentSeek)
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 30, isSeeking: gate.isSeeking, clipEndTime: 30),
            .finishClip
        )
    }
}

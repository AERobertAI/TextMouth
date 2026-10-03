import XCTest
@testable import TextMouth

/// The audio service's position observer and its seek gate: which ticks of
/// the player's clock publish a position, which finish the clip being
/// played, and which are ignored.
final class AudioSeekAndObserverTests: XCTestCase {
    func testObserverPublishesOrdinaryPosition() {
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 12, isSeeking: false, isPlaying: true, clipEndTime: nil),
            .publish(12)
        )
    }

    func testObserverSuppressesPositionWhileSeekIsPending() {
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 12, isSeeking: true, isPlaying: true, clipEndTime: nil),
            .ignore
        )
    }

    func testObserverSuppressesClipEndWhileSeekIsPending() {
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 30, isSeeking: true, isPlaying: true, clipEndTime: 20),
            .ignore
        )
    }

    func testObserverFinishesAtSegmentClipBoundary() {
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 20, isSeeking: false, isPlaying: true, clipEndTime: 20),
            .finishClip
        )
    }

    func testObserverPublishesBeforeSegmentClipBoundary() {
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 19.999, isSeeking: false, isPlaying: true, clipEndTime: 20),
            .publish(19.999)
        )
    }

    func testObserverIgnoresNonFinitePlayerTime() {
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: .nan, isSeeking: false, isPlaying: true, clipEndTime: nil),
            .ignore
        )
    }

    /// Paused playback that stands at or past its clip's end neither
    /// finishes the clip, which would move on while the listener has paused,
    /// nor reports a time that belongs to whatever follows the clip.
    func testPausedPlaybackPastItsClipEndIsIgnored() {
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 20, isSeeking: false, isPlaying: false, clipEndTime: 20),
            .ignore
        )
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 25, isSeeking: false, isPlaying: false, clipEndTime: 20),
            .ignore
        )
    }

    /// Paused playback within its clip still reports where it is, as after
    /// a seek made while paused.
    func testPausedPlaybackWithinItsClipPublishesItsPosition() {
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 12, isSeeking: false, isPlaying: false, clipEndTime: 20),
            .publish(12)
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
            AudioPositionObserverPolicy.action(seconds: 30, isSeeking: gate.isSeeking, isPlaying: true, clipEndTime: 30),
            .ignore
        )

        gate.complete(secondSegmentSeek)
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 30, isSeeking: gate.isSeeking, isPlaying: true, clipEndTime: 30),
            .finishClip
        )
    }
}

import XCTest
@testable import TextMouth

/// The audio service's position observer and its seek gate: which ticks of
/// the player's clock publish a position, which finish the clip being
/// played, and which are ignored.
final class AudioSeekAndObserverTests: XCTestCase {
    func testObserverPublishesOrdinaryPosition() {
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 12, isSeeking: false, isPlaying: true, hasFinished: false, clipEndTime: nil),
            .publish(12)
        )
    }

    func testObserverSuppressesPositionWhileSeekIsPending() {
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 12, isSeeking: true, isPlaying: true, hasFinished: false, clipEndTime: nil),
            .ignore
        )
    }

    func testObserverSuppressesClipEndWhileSeekIsPending() {
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 30, isSeeking: true, isPlaying: true, hasFinished: false, clipEndTime: 20),
            .ignore
        )
    }

    func testObserverFinishesAtSegmentClipBoundary() {
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 20, isSeeking: false, isPlaying: true, hasFinished: false, clipEndTime: 20),
            .finishClip
        )
    }

    func testObserverPublishesBeforeSegmentClipBoundary() {
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 19.999, isSeeking: false, isPlaying: true, hasFinished: false, clipEndTime: 20),
            .publish(19.999)
        )
    }

    func testObserverIgnoresNonFinitePlayerTime() {
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: .nan, isSeeking: false, isPlaying: true, hasFinished: false, clipEndTime: nil),
            .ignore
        )
    }

    /// Paused playback that stands at or past its clip's end neither
    /// finishes the clip, which would move on while the listener has paused,
    /// nor reports a time that belongs to whatever follows the clip.
    func testPausedPlaybackPastItsClipEndIsIgnored() {
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 20, isSeeking: false, isPlaying: false, hasFinished: false, clipEndTime: 20),
            .ignore
        )
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 25, isSeeking: false, isPlaying: false, hasFinished: false, clipEndTime: 20),
            .ignore
        )
    }

    /// Paused playback within its clip still reports where it is, as after
    /// a seek made while paused.
    func testPausedPlaybackWithinItsClipPublishesItsPosition() {
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 12, isSeeking: false, isPlaying: false, hasFinished: false, clipEndTime: 20),
            .publish(12)
        )
    }

    /// A play that has finished reports nothing, with a clip end or
    /// without (TODO P07): the player's stop at the end ticks once more,
    /// and the reader has by then put the finished book at its exact end,
    /// which that tick, a moment off the end, would move. Before, a file
    /// with no clip end published it.
    func testAFinishedPlayReportsNothing() {
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 29.98, isSeeking: false, isPlaying: false, hasFinished: true, clipEndTime: nil),
            .ignore,
            "A file played to its end, before its end"
        )
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 30.02, isSeeking: false, isPlaying: false, hasFinished: true, clipEndTime: nil),
            .ignore,
            "A file played to its end, past its measured end"
        )
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 12, isSeeking: false, isPlaying: false, hasFinished: true, clipEndTime: 20),
            .ignore,
            "A clip played to its end, within the clip"
        )
    }

    /// Stopped playback that has not finished, as after a seek made while
    /// stopped, still reports where it is: only a finished play is silent.
    func testStoppedPlaybackThatHasNotFinishedPublishesItsPosition() {
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 12, isSeeking: false, isPlaying: false, hasFinished: false, clipEndTime: nil),
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
            AudioPositionObserverPolicy.action(seconds: 30, isSeeking: gate.isSeeking, isPlaying: true, hasFinished: false, clipEndTime: 30),
            .ignore
        )

        gate.complete(secondSegmentSeek)
        XCTAssertEqual(
            AudioPositionObserverPolicy.action(seconds: 30, isSeeking: gate.isSeeking, isPlaying: true, hasFinished: false, clipEndTime: 30),
            .finishClip
        )
    }
}

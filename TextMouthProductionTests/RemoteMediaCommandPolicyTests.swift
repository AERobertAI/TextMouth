import CoreAudio
import XCTest
@testable import TextMouth

final class RemoteMediaCommandPolicyTests: XCTestCase {
    func testPlayCommandForwardsOutsideSuppressWindow() {
        XCTAssertEqual(RemoteMediaCommandPolicy.play(isSuppressed: false), .play)
    }

    func testPlayCommandIsConsumedInsideSuppressWindow() {
        XCTAssertEqual(RemoteMediaCommandPolicy.play(isSuppressed: true), .consume)
    }

    func testPauseCommandAlwaysForwardsNormally() {
        XCTAssertEqual(RemoteMediaCommandPolicy.pause(isSuppressed: false, isPlaying: true), .pause)
    }

    func testSuppressedPauseWhilePlayingUsesRouteChangePause() {
        XCTAssertEqual(
            RemoteMediaCommandPolicy.pause(isSuppressed: true, isPlaying: true),
            .routeChangePause
        )
    }

    func testSuppressedPauseWhileAlreadyPausedRemainsPause() {
        XCTAssertEqual(RemoteMediaCommandPolicy.pause(isSuppressed: true, isPlaying: false), .pause)
    }

    func testToggleCommandForwardsOutsideSuppressWindow() {
        XCTAssertEqual(RemoteMediaCommandPolicy.toggle(isSuppressed: false, isPlaying: false), .toggle)
        XCTAssertEqual(RemoteMediaCommandPolicy.toggle(isSuppressed: false, isPlaying: true), .toggle)
    }

    func testSuppressedToggleWhilePlayingUsesRouteChangePause() {
        XCTAssertEqual(
            RemoteMediaCommandPolicy.toggle(isSuppressed: true, isPlaying: true),
            .routeChangePause
        )
    }

    func testSuppressedToggleWhilePausedIsConsumed() {
        XCTAssertEqual(RemoteMediaCommandPolicy.toggle(isSuppressed: true, isPlaying: false), .consume)
    }

    func testSuppressionIsActiveBeforeDeadline() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(RemoteMediaCommandPolicy.isSuppressed(
            now: now, until: now.addingTimeInterval(0.001)
        ))
    }

    func testSuppressionExpiresAtDeadlineBoundary() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(RemoteMediaCommandPolicy.isSuppressed(now: now, until: now))
    }

    func testConfiguredDelayProducesMatchingDeadline() {
        let now = Date(timeIntervalSince1970: 1_000)
        for delay in [1.0, 2.0, 5.0, 10.0] {
            XCTAssertEqual(
                RemoteMediaCommandPolicy.suppressDeadline(now: now, delay: delay),
                now.addingTimeInterval(delay)
            )
        }
    }

    func testNegativeSuppressDelayCannotCreateBackwardWindow() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(RemoteMediaCommandPolicy.suppressDeadline(now: now, delay: -2), now)
    }

    func testBluetoothClassicAndLETransportsAreRecognized() {
        XCTAssertTrue(RemoteMediaCommandPolicy.isBluetoothTransport(kAudioDeviceTransportTypeBluetooth))
        XCTAssertTrue(RemoteMediaCommandPolicy.isBluetoothTransport(kAudioDeviceTransportTypeBluetoothLE))
    }

    func testNonBluetoothTransportDoesNotQualify() {
        XCTAssertFalse(RemoteMediaCommandPolicy.isBluetoothTransport(kAudioDeviceTransportTypeBuiltIn))
    }
}

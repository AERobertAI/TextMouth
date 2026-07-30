import XCTest
@testable import TextMouth

@MainActor
final class NowPlayingOwnershipTests: XCTestCase {
    func testInactiveOwnerCannotClearActiveSession() {
        let coordinator = NowPlayingService(installsSystemIntegrations: false)
        let first = makeSession(coordinator: coordinator)
        let second = makeSession(coordinator: coordinator)

        first.activateRemoteCommandsIfNeeded()
        XCTAssertEqual(coordinator.activeOwnerID, first.ownerID)

        second.clearNowPlaying()
        XCTAssertEqual(coordinator.activeOwnerID, first.ownerID)
    }

    func testLatestActivatedSessionReceivesOwnership() {
        let coordinator = NowPlayingService(installsSystemIntegrations: false)
        let first = makeSession(coordinator: coordinator)
        let second = makeSession(coordinator: coordinator)

        first.updateNowPlayingInfo(title: "First", author: "Author", isPlaying: true)
        second.updateNowPlayingInfo(title: "Second", author: "Author", isPlaying: true)

        XCTAssertEqual(coordinator.activeOwnerID, second.ownerID)
    }

    func testPausedMetadataFromInactiveReaderCannotStealPlayingOwner() {
        let coordinator = NowPlayingService(installsSystemIntegrations: false)
        let first = makeSession(coordinator: coordinator)
        let second = makeSession(coordinator: coordinator)

        first.updateNowPlayingInfo(title: "First", author: "Author", isPlaying: true)
        second.updateNowPlayingInfo(title: "Second", author: "Author", isPlaying: false)

        XCTAssertEqual(coordinator.playingOwnerID, first.ownerID)
        XCTAssertEqual(coordinator.activeOwnerID, first.ownerID)
    }

    func testFocusingSecondReaderDoesNotInterruptFirstReader() {
        let coordinator = NowPlayingService(installsSystemIntegrations: false)
        let first = makeSession(coordinator: coordinator)
        let second = makeSession(coordinator: coordinator)
        first.updateNowPlayingInfo(title: "First", author: "Author", isPlaying: true)

        second.focus()

        XCTAssertEqual(coordinator.focusedOwnerID, second.ownerID)
        XCTAssertEqual(coordinator.playingOwnerID, first.ownerID)
        XCTAssertEqual(coordinator.activeOwnerID, first.ownerID)
    }

    func testStartingFocusedReaderPausesPreviousReaderBeforePlaying() {
        let coordinator = NowPlayingService(installsSystemIntegrations: false)
        var events: [String] = []
        var firstIsPlaying = true
        var secondIsPlaying = false

        let first = makeSession(
            coordinator: coordinator,
            onPause: {
                events.append("pause first")
                firstIsPlaying = false
            },
            isCurrentlyPlaying: { firstIsPlaying }
        )
        let second = makeSession(
            coordinator: coordinator,
            onPlay: {
                events.append("play second")
                secondIsPlaying = true
            },
            isCurrentlyPlaying: { secondIsPlaying }
        )
        first.updateNowPlayingInfo(title: "First", author: "Author", isPlaying: true)
        second.focus()

        XCTAssertEqual(coordinator.dispatchPlayCommand(isSuppressed: false), .success)

        XCTAssertEqual(events, ["pause first", "play second"])
        XCTAssertFalse(firstIsPlaying)
        XCTAssertTrue(secondIsPlaying)
        XCTAssertEqual(coordinator.playingOwnerID, second.ownerID)
    }

    func testPauseTargetsAudibleReaderEvenWhenAnotherReaderHasFocus() {
        let coordinator = NowPlayingService(installsSystemIntegrations: false)
        var firstPauseCount = 0
        var secondPauseCount = 0
        var firstIsPlaying = true
        let first = makeSession(
            coordinator: coordinator,
            onPause: {
                firstPauseCount += 1
                firstIsPlaying = false
            },
            isCurrentlyPlaying: { firstIsPlaying }
        )
        let second = makeSession(
            coordinator: coordinator,
            onPause: { secondPauseCount += 1 }
        )
        first.updateNowPlayingInfo(title: "First", author: "Author", isPlaying: true)
        second.focus()

        XCTAssertEqual(coordinator.dispatchPauseCommand(isSuppressed: false), .success)

        XCTAssertEqual(firstPauseCount, 1)
        XCTAssertEqual(secondPauseCount, 0)
        XCTAssertNil(coordinator.playingOwnerID)
    }

    func testFirstRegisteredReaderAcceptsPlayBeforeFocusNotification() {
        let coordinator = NowPlayingService(installsSystemIntegrations: false)
        var isPlaying = false
        let session = makeSession(
            coordinator: coordinator,
            onPlay: { isPlaying = true },
            isCurrentlyPlaying: { isPlaying }
        )

        XCTAssertEqual(coordinator.dispatchPlayCommand(isSuppressed: false), .success)
        XCTAssertTrue(isPlaying)
        XCTAssertEqual(coordinator.playingOwnerID, session.ownerID)
    }

    func testCommandFailsWhenNoReaderOwnsMediaControls() {
        let coordinator = NowPlayingService(installsSystemIntegrations: false)

        XCTAssertEqual(coordinator.dispatchPlayCommand(isSuppressed: false), .commandFailed)
        XCTAssertEqual(coordinator.dispatchPauseCommand(isSuppressed: false), .commandFailed)
        XCTAssertEqual(coordinator.dispatchToggleCommand(isSuppressed: false), .commandFailed)
    }

    func testClosingFocusedReaderFallsBackToPreviousReader() {
        let coordinator = NowPlayingService(installsSystemIntegrations: false)
        let first = makeSession(coordinator: coordinator)
        let second = makeSession(coordinator: coordinator)
        second.focus()

        second.close()

        XCTAssertEqual(coordinator.focusedOwnerID, first.ownerID)
        XCTAssertEqual(coordinator.activeOwnerID, first.ownerID)
    }

    func testDeallocatingInactiveSessionPreservesActiveOwner() {
        let coordinator = NowPlayingService(installsSystemIntegrations: false)
        let active = makeSession(coordinator: coordinator)
        active.activateRemoteCommandsIfNeeded()

        autoreleasepool {
            let inactive = makeSession(coordinator: coordinator)
            XCTAssertNotEqual(inactive.ownerID, active.ownerID)
            inactive.close()
        }

        XCTAssertEqual(coordinator.activeOwnerID, active.ownerID)
    }

    private func makeSession(
        coordinator: NowPlayingService,
        onPlay: @escaping () -> Void = {},
        onPause: @escaping () -> Void = {},
        isCurrentlyPlaying: @escaping () -> Bool = { false }
    ) -> NowPlayingSession {
        let session = NowPlayingSession(ownerID: UUID(), coordinator: coordinator)
        session.setup(
            onPlay: onPlay,
            onPause: onPause,
            onAudioRouteChangePause: {},
            onTogglePlayPause: {},
            onSkipForward: {},
            onSkipBackward: {},
            isCurrentlyPlaying: isCurrentlyPlaying,
            bluetoothMonitoring: false
        )
        return session
    }
}

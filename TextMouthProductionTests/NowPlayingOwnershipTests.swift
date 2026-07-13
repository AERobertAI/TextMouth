import XCTest
@testable import TextMouth

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

    func testDeallocatingInactiveSessionPreservesActiveOwner() {
        let coordinator = NowPlayingService(installsSystemIntegrations: false)
        let active = makeSession(coordinator: coordinator)
        active.activateRemoteCommandsIfNeeded()

        autoreleasepool {
            let inactive = makeSession(coordinator: coordinator)
            XCTAssertNotEqual(inactive.ownerID, active.ownerID)
        }

        XCTAssertEqual(coordinator.activeOwnerID, active.ownerID)
    }

    private func makeSession(coordinator: NowPlayingService) -> NowPlayingSession {
        let session = NowPlayingSession(ownerID: UUID(), coordinator: coordinator)
        session.setup(
            onPlay: {},
            onPause: {},
            onAudioRouteChangePause: {},
            onTogglePlayPause: {},
            onSkipForward: {},
            onSkipBackward: {},
            isCurrentlyPlaying: { false },
            bluetoothMonitoring: false
        )
        return session
    }
}

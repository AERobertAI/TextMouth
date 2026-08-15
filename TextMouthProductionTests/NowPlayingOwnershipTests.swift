import XCTest
@testable import TextMouth

@MainActor
final class NowPlayingOwnershipTests: XCTestCase {
    /// Mutable clock used to separate command receipt from deferred execution
    /// without making timing-sensitive tests wait in real time.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000)
    }

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

    func testRemoteCommandsAcknowledgeBeforeDeferredPlaybackWorkRuns() {
        var scheduledActions: [@MainActor () -> Void] = []
        var playbackEvents: [String] = []
        var isPlaying = false
        let coordinator = NowPlayingService(
            installsSystemIntegrations: false,
            diagnosticSink: { _ in },
            scheduleRemoteCommandAction: { action in
                scheduledActions.append(action)
            }
        )
        _ = makeSession(
            coordinator: coordinator,
            onPlay: {
                playbackEvents.append("play")
                isPlaying = true
            },
            onPause: {
                playbackEvents.append("pause")
                isPlaying = false
            },
            onTogglePlayPause: {
                playbackEvents.append("toggle")
                isPlaying.toggle()
            },
            onSkipForward: { playbackEvents.append("forward") },
            onSkipBackward: { playbackEvents.append("backward") },
            isCurrentlyPlaying: { isPlaying }
        )

        let requests: [RemoteMediaCommandRequest] = [
            .play,
            .pause,
            .togglePlayPause,
            .skipForward,
            .skipBackward,
            .nextTrack,
            .previousTrack
        ]
        for request in requests {
            XCTAssertEqual(coordinator.acceptRemoteCommand(request), .success)
        }

        // MediaPlayer receives an acknowledgement without reentrant playback,
        // Now Playing, speech, or gesture work inside its callback.
        XCTAssertTrue(playbackEvents.isEmpty)
        XCTAssertEqual(scheduledActions.count, requests.count)

        for action in scheduledActions {
            action()
        }

        XCTAssertEqual(
            playbackEvents,
            ["play", "pause", "toggle", "forward", "backward", "forward", "backward"]
        )
    }

    func testRemoteCommandWithoutOwnerFailsWithoutSchedulingWork() {
        var scheduledActions: [@MainActor () -> Void] = []
        let coordinator = NowPlayingService(
            installsSystemIntegrations: false,
            diagnosticSink: { _ in },
            scheduleRemoteCommandAction: { action in
                scheduledActions.append(action)
            }
        )

        XCTAssertEqual(coordinator.acceptRemoteCommand(.play), .commandFailed)
        XCTAssertTrue(scheduledActions.isEmpty)
    }

    func testNewerFocusInvalidatesDeferredPlay() {
        var scheduledActions: [@MainActor () -> Void] = []
        var firstPlayCount = 0
        var secondPlayCount = 0
        var firstIsPlaying = false
        var secondIsPlaying = false
        let coordinator = NowPlayingService(
            installsSystemIntegrations: false,
            diagnosticSink: { _ in },
            scheduleRemoteCommandAction: { scheduledActions.append($0) }
        )
        _ = makeSession(
            coordinator: coordinator,
            onPlay: {
                firstPlayCount += 1
                firstIsPlaying = true
            },
            isCurrentlyPlaying: { firstIsPlaying }
        )
        let second = makeSession(
            coordinator: coordinator,
            onPlay: {
                secondPlayCount += 1
                secondIsPlaying = true
            },
            isCurrentlyPlaying: { secondIsPlaying }
        )

        XCTAssertEqual(coordinator.acceptRemoteCommand(.play), .success)
        second.focus()
        scheduledActions[0]()

        // A newer user focus action wins over the older queued command. The
        // command must neither start the former owner nor redirect to focus.
        XCTAssertEqual(firstPlayCount, 0)
        XCTAssertEqual(secondPlayCount, 0)
        XCTAssertEqual(coordinator.focusedOwnerID, second.ownerID)
    }

    func testDeferredCommandDoesNotRedirectAfterAcceptedOwnerCloses() {
        var scheduledActions: [@MainActor () -> Void] = []
        var firstSkipCount = 0
        var fallbackSkipCount = 0
        let coordinator = NowPlayingService(
            installsSystemIntegrations: false,
            diagnosticSink: { _ in },
            scheduleRemoteCommandAction: { scheduledActions.append($0) }
        )
        let first = makeSession(
            coordinator: coordinator,
            onSkipForward: { firstSkipCount += 1 }
        )
        _ = makeSession(
            coordinator: coordinator,
            onSkipForward: { fallbackSkipCount += 1 }
        )

        XCTAssertEqual(coordinator.acceptRemoteCommand(.skipForward), .success)
        first.close()
        scheduledActions[0]()

        XCTAssertEqual(firstSkipCount, 0)
        XCTAssertEqual(fallbackSkipCount, 0)
    }

    func testOpeningAndClosingInactiveReaderDoesNotDropQueuedSkip() {
        var scheduledActions: [@MainActor () -> Void] = []
        var activeSkipCount = 0
        let coordinator = NowPlayingService(
            installsSystemIntegrations: false,
            diagnosticSink: { _ in },
            scheduleRemoteCommandAction: { scheduledActions.append($0) }
        )
        _ = makeSession(
            coordinator: coordinator,
            onSkipForward: { activeSkipCount += 1 }
        )

        XCTAssertEqual(coordinator.acceptRemoteCommand(.skipForward), .success)
        let inactive = makeSession(coordinator: coordinator)
        inactive.close()
        scheduledActions[0]()

        XCTAssertEqual(activeSkipCount, 1)
    }

    func testReleasingPausedMediaControlsInvalidatesQueuedPlay() {
        var scheduledActions: [@MainActor () -> Void] = []
        var playCount = 0
        var isPlaying = false
        let coordinator = NowPlayingService(
            installsSystemIntegrations: false,
            diagnosticSink: { _ in },
            scheduleRemoteCommandAction: { scheduledActions.append($0) }
        )
        let session = makeSession(
            coordinator: coordinator,
            onPlay: {
                playCount += 1
                isPlaying = true
            },
            isCurrentlyPlaying: { isPlaying }
        )

        XCTAssertEqual(coordinator.acceptRemoteCommand(.play), .success)
        session.clearNowPlaying()
        scheduledActions[0]()

        XCTAssertEqual(playCount, 0)
        XCTAssertFalse(isPlaying)
    }

    func testRapidPlayThenPauseRoutesPauseToNewPlayingOwner() {
        var scheduledActions: [@MainActor () -> Void] = []
        var events: [String] = []
        var firstIsPlaying = true
        var secondIsPlaying = false
        let coordinator = NowPlayingService(
            installsSystemIntegrations: false,
            diagnosticSink: { _ in },
            scheduleRemoteCommandAction: { scheduledActions.append($0) }
        )
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
            onPause: {
                events.append("pause second")
                secondIsPlaying = false
            },
            isCurrentlyPlaying: { secondIsPlaying }
        )
        first.updateNowPlayingInfo(title: "First", author: "Author", isPlaying: true)
        second.focus()

        XCTAssertEqual(coordinator.acceptRemoteCommand(.play), .success)
        XCTAssertEqual(coordinator.acceptRemoteCommand(.pause), .success)
        scheduledActions.forEach { $0() }

        XCTAssertEqual(events, ["pause first", "play second", "pause second"])
        XCTAssertFalse(firstIsPlaying)
        XCTAssertFalse(secondIsPlaying)
        XCTAssertNil(coordinator.playingOwnerID)
    }

    func testRapidPauseThenToggleRoutesToggleToFocusedOwner() {
        var scheduledActions: [@MainActor () -> Void] = []
        var events: [String] = []
        var firstIsPlaying = true
        var secondIsPlaying = false
        let coordinator = NowPlayingService(
            installsSystemIntegrations: false,
            diagnosticSink: { _ in },
            scheduleRemoteCommandAction: { scheduledActions.append($0) }
        )
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
            onTogglePlayPause: {
                events.append("toggle second")
                secondIsPlaying.toggle()
            },
            isCurrentlyPlaying: { secondIsPlaying }
        )
        first.updateNowPlayingInfo(title: "First", author: "Author", isPlaying: true)
        second.focus()

        XCTAssertEqual(coordinator.acceptRemoteCommand(.pause), .success)
        XCTAssertEqual(coordinator.acceptRemoteCommand(.togglePlayPause), .success)
        scheduledActions.forEach { $0() }

        XCTAssertEqual(events, ["pause first", "toggle second"])
        XCTAssertFalse(firstIsPlaying)
        XCTAssertTrue(secondIsPlaying)
        XCTAssertEqual(coordinator.playingOwnerID, second.ownerID)
    }

    func testRapidPlayThenSkipRoutesSkipToNewPlayingOwner() {
        var scheduledActions: [@MainActor () -> Void] = []
        var firstIsPlaying = true
        var secondIsPlaying = false
        var firstSkipCount = 0
        var secondSkipCount = 0
        let coordinator = NowPlayingService(
            installsSystemIntegrations: false,
            diagnosticSink: { _ in },
            scheduleRemoteCommandAction: { scheduledActions.append($0) }
        )
        let first = makeSession(
            coordinator: coordinator,
            onPause: { firstIsPlaying = false },
            onSkipForward: { firstSkipCount += 1 },
            isCurrentlyPlaying: { firstIsPlaying }
        )
        let second = makeSession(
            coordinator: coordinator,
            onPlay: { secondIsPlaying = true },
            onSkipForward: { secondSkipCount += 1 },
            isCurrentlyPlaying: { secondIsPlaying }
        )
        first.updateNowPlayingInfo(title: "First", author: "Author", isPlaying: true)
        second.focus()

        XCTAssertEqual(coordinator.acceptRemoteCommand(.play), .success)
        XCTAssertEqual(coordinator.acceptRemoteCommand(.skipForward), .success)
        scheduledActions.forEach { $0() }

        XCTAssertEqual(firstSkipCount, 0)
        XCTAssertEqual(secondSkipCount, 1)
        XCTAssertEqual(coordinator.playingOwnerID, second.ownerID)
    }

    func testDeferredTogglePreservesSuppressionDecisionFromReceipt() {
        let clock = Clock()
        var defaultDeviceID: UInt32? = 42
        var deviceIDs: [UInt32] = [42, 99]
        var scheduledActions: [@MainActor () -> Void] = []
        var toggleCount = 0
        var isPlaying = false
        let coordinator = NowPlayingService(
            installsSystemIntegrations: false,
            diagnosticSink: { _ in },
            now: { clock.now },
            defaultOutputDevice: { defaultDeviceID },
            audioDeviceIDs: { deviceIDs },
            isBluetoothDevice: { $0 == 42 },
            scheduleRemoteCommandAction: { scheduledActions.append($0) }
        )
        _ = makeSession(
            coordinator: coordinator,
            onTogglePlayPause: {
                toggleCount += 1
                isPlaying.toggle()
            },
            isCurrentlyPlaying: { isPlaying },
            bluetoothMonitoring: true,
            bluetoothDelay: 2
        )
        coordinator.refreshPreviousDeviceInfo()

        // Leaving the Bluetooth device arms suppression while this reader is
        // paused, matching the rcd auto-play failure mode.
        defaultDeviceID = 99
        deviceIDs = [99]
        coordinator.handleDefaultOutputChange()
        XCTAssertTrue(coordinator.isRouteCommandSuppressed)
        XCTAssertEqual(coordinator.acceptRemoteCommand(.togglePlayPause), .success)

        // Execution after the deadline must still consume the event because
        // it physically arrived inside the suppression window.
        clock.now = clock.now.addingTimeInterval(3)
        XCTAssertFalse(coordinator.isRouteCommandSuppressed)
        scheduledActions[0]()

        XCTAssertEqual(toggleCount, 0)
        XCTAssertFalse(isPlaying)
    }

    func testBluetoothRouteChangeInvalidatesPlayAcceptedForOldRoute() {
        let clock = Clock()
        var defaultDeviceID: UInt32? = 42
        var deviceIDs: [UInt32] = [42, 99]
        var scheduledActions: [@MainActor () -> Void] = []
        var playCount = 0
        var isPlaying = false
        let coordinator = NowPlayingService(
            installsSystemIntegrations: false,
            diagnosticSink: { _ in },
            now: { clock.now },
            defaultOutputDevice: { defaultDeviceID },
            audioDeviceIDs: { deviceIDs },
            isBluetoothDevice: { $0 == 42 },
            scheduleRemoteCommandAction: { scheduledActions.append($0) }
        )
        _ = makeSession(
            coordinator: coordinator,
            onPlay: {
                playCount += 1
                isPlaying = true
            },
            isCurrentlyPlaying: { isPlaying },
            bluetoothMonitoring: true,
            bluetoothDelay: 2
        )
        coordinator.refreshPreviousDeviceInfo()

        XCTAssertEqual(coordinator.acceptRemoteCommand(.play), .success)
        defaultDeviceID = 99
        deviceIDs = [99]
        coordinator.handleDefaultOutputChange()
        scheduledActions[0]()

        XCTAssertTrue(coordinator.isRouteCommandSuppressed)
        XCTAssertEqual(playCount, 0)
        XCTAssertFalse(isPlaying)
    }

    func testDefaultRemoteCommandSchedulerRunsAfterCurrentMainActorTurn() async {
        let playbackStarted = expectation(description: "Deferred playback action ran")
        var didPlay = false
        var isPlaying = false
        let coordinator = NowPlayingService(
            installsSystemIntegrations: false,
            diagnosticSink: { _ in }
        )
        _ = makeSession(
            coordinator: coordinator,
            onPlay: {
                didPlay = true
                isPlaying = true
                playbackStarted.fulfill()
            },
            isCurrentlyPlaying: { isPlaying }
        )

        XCTAssertEqual(coordinator.acceptRemoteCommand(.play), .success)
        XCTAssertFalse(didPlay)

        await fulfillment(of: [playbackStarted], timeout: 1.0)
        XCTAssertTrue(didPlay)
    }

    func testDeferredRemoteCommandsPreserveSleepTimerRestartGesture() async {
        var scheduledActions: [@MainActor () -> Void] = []
        var backwardSkips = 0
        let restartPosted = expectation(description: "Sleep timer restart notification posted")
        let observer = NotificationCenter.default.addObserver(
            forName: .restartSleepTimer,
            object: nil,
            queue: .main
        ) { _ in
            restartPosted.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let coordinator = NowPlayingService(
            installsSystemIntegrations: false,
            diagnosticSink: { _ in },
            scheduleRemoteCommandAction: { action in
                scheduledActions.append(action)
            }
        )
        _ = makeSession(
            coordinator: coordinator,
            onSkipBackward: { backwardSkips += 1 }
        )
        coordinator.updateGestureSettings(
            enabled: true,
            pattern: "previousTrack,previousTrack",
            window: 2.0
        )

        XCTAssertEqual(coordinator.acceptRemoteCommand(.previousTrack), .success)
        XCTAssertEqual(coordinator.acceptRemoteCommand(.previousTrack), .success)
        XCTAssertEqual(scheduledActions.count, 2)

        scheduledActions[0]()
        scheduledActions[1]()

        // The first step keeps its ordinary navigation behavior. The matching
        // final step is consumed so it restarts the timer without another skip.
        XCTAssertEqual(backwardSkips, 1)
        await fulfillment(of: [restartPosted], timeout: 1.0)
    }

    func testDeferredGestureUsesReceiptTimeInsteadOfExecutionTime() async {
        let clock = Clock()
        var scheduledActions: [@MainActor () -> Void] = []
        var backwardSkips = 0
        let restartPosted = expectation(description: "Out-of-window gesture must not restart timer")
        restartPosted.isInverted = true
        let observer = NotificationCenter.default.addObserver(
            forName: .restartSleepTimer,
            object: nil,
            queue: .main
        ) { _ in
            restartPosted.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let coordinator = NowPlayingService(
            installsSystemIntegrations: false,
            diagnosticSink: { _ in },
            now: { clock.now },
            scheduleRemoteCommandAction: { scheduledActions.append($0) }
        )
        _ = makeSession(
            coordinator: coordinator,
            onSkipBackward: { backwardSkips += 1 }
        )
        coordinator.updateGestureSettings(
            enabled: true,
            pattern: "previousTrack,previousTrack",
            window: 2.0
        )

        XCTAssertEqual(coordinator.acceptRemoteCommand(.previousTrack), .success)
        clock.now = clock.now.addingTimeInterval(3)
        XCTAssertEqual(coordinator.acceptRemoteCommand(.previousTrack), .success)

        // Even though both closures execute back-to-back, their original
        // three-second separation remains authoritative for gesture matching.
        scheduledActions[0]()
        scheduledActions[1]()
        XCTAssertEqual(backwardSkips, 2)
        await fulfillment(of: [restartPosted], timeout: 0.1)
    }

    private func makeSession(
        coordinator: NowPlayingService,
        onPlay: @escaping () -> Void = {},
        onPause: @escaping () -> Void = {},
        onTogglePlayPause: @escaping () -> Void = {},
        onSkipForward: @escaping () -> Void = {},
        onSkipBackward: @escaping () -> Void = {},
        isCurrentlyPlaying: @escaping () -> Bool = { false },
        bluetoothMonitoring: Bool = false,
        bluetoothDelay: TimeInterval = 2
    ) -> NowPlayingSession {
        let session = NowPlayingSession(ownerID: UUID(), coordinator: coordinator)
        session.setup(
            onPlay: onPlay,
            onPause: onPause,
            onAudioRouteInvalidated: {},
            onAudioRouteChangePause: {},
            onTogglePlayPause: onTogglePlayPause,
            onSkipForward: onSkipForward,
            onSkipBackward: onSkipBackward,
            isCurrentlyPlaying: isCurrentlyPlaying,
            bluetoothMonitoring: bluetoothMonitoring,
            bluetoothDelay: bluetoothDelay
        )
        return session
    }
}

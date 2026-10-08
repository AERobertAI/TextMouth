import MediaPlayer
import os
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

    // MARK: - What the System's Now Playing Center Is Told

    /// The system's Now Playing center, which decides where macOS sends the
    /// AirPods, is told each item the active reader shows, playing and then
    /// paused, and is cleared only when that reader releases media controls.
    /// An inactive reader's paused state is kept for later, not shown.
    func testSystemNowPlayingCenterIsToldTheActiveReadersItems() {
        var told: [NowPlayingItem?] = []
        let coordinator = NowPlayingService(
            installsSystemIntegrations: false,
            diagnosticSink: { _ in },
            systemNowPlaying: { told.append($0) }
        )
        let first = makeSession(coordinator: coordinator)
        let second = makeSession(coordinator: coordinator)

        first.updateNowPlayingInfo(title: "Tide Tables", author: "Harbour Office", isPlaying: true)
        second.updateNowPlayingInfo(title: "Ferry Log", author: "Purser", isPlaying: false)
        first.updateNowPlayingInfo(title: "Tide Tables", author: "Harbour Office", isPlaying: false)
        first.releaseMediaControls()

        XCTAssertEqual(told, [
            NowPlayingItem(title: "Tide Tables", author: "Harbour Office", isPlaying: true),
            NowPlayingItem(title: "Tide Tables", author: "Harbour Office", isPlaying: false),
            nil,
        ])
    }

    /// Only the reader whose item the system shows takes it down. A window
    /// that never played, focused and then closed while another book waits
    /// paused, clears nothing: the system goes on showing the paused book,
    /// never told that TextMouth stopped, so macOS keeps sending the AirPods
    /// to TextMouth, and the paused book's reader owns the commands again.
    /// Stopping the shown reader and releasing its media controls then
    /// clears the center once.
    ///
    /// Before the repair, closing the idle window told the system three
    /// times that TextMouth stopped before showing the paused book again,
    /// and Release Media Controls cleared the center twice.
    func testOnlyTheReaderShownTakesDownTheSystemNowPlayingItem() {
        var told: [NowPlayingItem?] = []
        let coordinator = NowPlayingService(
            installsSystemIntegrations: false,
            diagnosticSink: { _ in },
            systemNowPlaying: { told.append($0) }
        )
        let listened = makeSession(coordinator: coordinator)
        let idle = makeSession(coordinator: coordinator)
        let paused = NowPlayingItem(title: "Tide Tables", author: "Harbour Office", isPlaying: false)
        listened.updateNowPlayingInfo(title: "Tide Tables", author: "Harbour Office", isPlaying: true)
        listened.updateNowPlayingInfo(title: "Tide Tables", author: "Harbour Office", isPlaying: false)

        // The idle window becomes key, then closes: its reader stops, which
        // clears its Now Playing, twice as a reader's close does, and leaves.
        idle.focus()
        idle.clearNowPlaying()
        idle.clearNowPlaying()
        idle.close()

        XCTAssertEqual(told.last, .some(paused))
        XCTAssertFalse(told.contains(nil), "Closing a window that never played told the system TextMouth stopped")
        XCTAssertEqual(coordinator.activeOwnerID, listened.ownerID)

        // Release Media Controls stops the reader, which clears its Now
        // Playing, then releases the controls.
        listened.clearNowPlaying()
        listened.releaseMediaControls()
        XCTAssertEqual(told.last, .some(nil))
        XCTAssertEqual(told.filter { $0 == nil }.count, 1, "The system was told more than once that TextMouth stopped")
    }

    /// A reader holds TextMouth's media controls, the ones Release Media
    /// Controls hands back, while it is the active reader and the system
    /// shows its item: not before it shows one; not once another reader's
    /// window is focused, though the system still shows its paused book;
    /// not once another reader's playing book replaces its own, whichever
    /// window is focused; and not once it has released them. A finished
    /// book whose controls the next book took holds nothing for the same
    /// reason (REV07, speech finding 5).
    func testOnlyTheActiveReaderWhoseItemIsShownHoldsTheMediaControls() {
        let coordinator = NowPlayingService(installsSystemIntegrations: false, diagnosticSink: { _ in })
        let first = makeSession(coordinator: coordinator)
        let second = makeSession(coordinator: coordinator)
        XCTAssertFalse(first.holdsMediaControls, "A reader that showed nothing holds the controls")

        first.updateNowPlayingInfo(title: "Tide Tables", author: "Harbour Office", isPlaying: true)
        XCTAssertTrue(first.holdsMediaControls, "The playing reader does not hold the controls")
        first.updateNowPlayingInfo(title: "Tide Tables", author: "Harbour Office", isPlaying: false)
        XCTAssertTrue(first.holdsMediaControls, "The paused reader the system shows does not hold the controls")

        // Another reader's window becomes key: the system still shows the
        // first reader's book, but the first is no longer the active one.
        second.focus()
        XCTAssertFalse(first.holdsMediaControls, "A reader no longer active holds the controls")
        XCTAssertFalse(second.holdsMediaControls, "A focused reader whose book is not shown holds the controls")

        // The second reader plays: its book replaces the first's.
        second.updateNowPlayingInfo(title: "Ferry Log", author: "Purser", isPlaying: true)
        XCTAssertTrue(second.holdsMediaControls, "The playing reader does not hold the controls")
        first.focus()
        XCTAssertFalse(first.holdsMediaControls, "A reader whose book another replaced holds the controls")
        XCTAssertTrue(second.holdsMediaControls, "Focusing another window took the controls from the playing reader")

        // The second reader's window becomes key, and releases them.
        second.focus()
        second.releaseMediaControls()
        XCTAssertFalse(second.holdsMediaControls, "A reader holds the controls it released")
        XCTAssertFalse(first.holdsMediaControls, "Releasing the controls handed them to another reader")
    }

    // MARK: - Commands Received on Any Thread

    /// MediaPlayer does not say which thread it calls a command's handler
    /// on, and in the Swift 6 language mode a handler isolated to the main
    /// actor stops the app on any other. Received on the main thread, where
    /// MediaPlayer has delivered every command so far, a command is accepted
    /// at once and MediaPlayer hears whether a reader owns media controls.
    /// Received on another thread, nothing stops: MediaPlayer hears success
    /// at once, and the command is accepted on the main queue, reaching the
    /// reader after the commands received before it.
    func testCommandsAreReceivedOnWhicheverThreadMediaPlayerChooses() {
        var scheduledActions: [@MainActor () -> Void] = []
        var events: [String] = []
        let coordinator = NowPlayingService(
            installsSystemIntegrations: false,
            diagnosticSink: { _ in },
            scheduleRemoteCommandAction: { scheduledActions.append($0) }
        )

        // On the main thread, with no reader owning media controls, the
        // command is refused at once; and with no service, always.
        XCTAssertEqual(NowPlayingService.receiveRemoteCommand(.play, by: coordinator), .commandFailed)
        XCTAssertEqual(NowPlayingService.receiveRemoteCommand(.play, by: nil), .commandFailed)
        _ = makeSession(
            coordinator: coordinator,
            onPlay: { events.append("play") },
            onPause: { events.append("pause") }
        )
        XCTAssertEqual(NowPlayingService.receiveRemoteCommand(.pause, by: coordinator), .success)
        XCTAssertEqual(scheduledActions.count, 1, "The main thread's command was not accepted at once")

        // On another thread. A semaphore, unlike an expectation, lets the
        // main thread wait without running the main queue, so the command
        // can only have been accepted after the handler returned.
        let status = OSAllocatedUnfairLock<MPRemoteCommandHandlerStatus?>(initialState: nil)
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let heard = NowPlayingService.receiveRemoteCommand(.play, by: coordinator)
            status.withLock { $0 = heard }
            returned.signal()
        }
        XCTAssertEqual(returned.wait(timeout: .now() + 5), .success, "The handler never returned")
        XCTAssertEqual(status.withLock { $0 }, .success)
        XCTAssertEqual(scheduledActions.count, 1, "The command was accepted off the main thread")

        XCTAssertTrue(waitUntil { scheduledActions.count == 2 }, "The command was never accepted on the main queue")
        scheduledActions.forEach { $0() }
        XCTAssertEqual(events, ["pause", "play"])
    }

    // MARK: - The Test Host Stays Out of the System's Media Session

    /// Board #958: only the app takes part in the system's media session. A
    /// process hosting the tests is TextMouth.app with the bundle identifier
    /// of the developer's own copy, so its shared coordinator must never
    /// register MediaPlayer command targets, listen to CoreAudio, or tell the
    /// system's Now Playing center that TextMouth plays, even once a reader
    /// has joined it: macOS would then send the developer's AirPods presses
    /// to the test host instead of to the copy being listened to.
    ///
    /// Before the repair the shared coordinator took part in every process:
    /// a reader joining it registered MediaPlayer command targets in the
    /// test host, and a reader playing published "playing" as TextMouth.
    func testOnlyTheAppTakesPartInTheSystemMediaSession() {
        let home = FileManager.default.temporaryDirectory
        let preferences = makeSandboxedPreferences("media-session-runtime")
        let app = TextMouthRuntime(isHostedTest: false, homeDirectory: home, preferences: preferences)
        let testHost = TextMouthRuntime(isHostedTest: true, homeDirectory: home, preferences: preferences)
        XCTAssertTrue(NowPlayingService.installsSystemIntegrations(in: app))
        XCTAssertFalse(NowPlayingService.installsSystemIntegrations(in: testHost))

        // This process hosts the tests, so the shared coordinator stays out
        // of the system's session even once a reader that monitors Bluetooth
        // joins it, which is when the app registers its command targets.
        XCTAssertTrue(TextMouthRuntime.current.isHostedTest)
        let shared = NowPlayingService.shared
        let session = makeSession(coordinator: shared, bluetoothMonitoring: true)
        defer { session.close() }

        XCTAssertFalse(shared.installsSystemIntegrations, "The test host joined the system's media session")
        XCTAssertFalse(shared.remoteCommandsActive, "The test host registered MediaPlayer command targets")
        XCTAssertFalse(shared.isListeningForDeviceChanges, "The test host listens to CoreAudio")
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

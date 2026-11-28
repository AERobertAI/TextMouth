import XCTest
@testable import TextMouth

/// What the iPhone does for each thing the system does to its audio, and that
/// each answer holds however the events of one disconnect are ordered.
final class PhoneAudioEventPolicyTests: XCTestCase {
    // MARK: - Interruptions

    func testAnInterruptionOfAPlayingBookPausesAndSaves() {
        var policy = PhoneAudioEventPolicy()
        XCTAssertEqual(policy.respond(to: .interruptionBegan(becauseRouteDisconnected: false), bookCountsAsPlaying: true), .pauseAndSave)
        XCTAssertTrue(policy.wasPlayingWhenInterrupted)
        XCTAssertTrue(policy.isInterrupted)
    }

    func testAnInterruptionOfAPausedBookDoesNothing() {
        var policy = PhoneAudioEventPolicy()
        XCTAssertEqual(policy.respond(to: .interruptionBegan(becauseRouteDisconnected: false), bookCountsAsPlaying: false), .nothing)
        XCTAssertFalse(policy.wasPlayingWhenInterrupted)
        XCTAssertTrue(policy.isInterrupted, "a cancel during it is still the interruption's")
    }

    func testTheEndWithShouldResumePlaysOnTheBookTheInterruptionPaused() {
        var policy = PhoneAudioEventPolicy()
        _ = policy.respond(to: .interruptionBegan(becauseRouteDisconnected: false), bookCountsAsPlaying: true)
        XCTAssertEqual(policy.respond(to: .interruptionEnded(shouldResume: true), bookCountsAsPlaying: false), .resume)
        XCTAssertFalse(policy.isInterrupted)
        XCTAssertFalse(policy.wasPlayingWhenInterrupted)
    }

    func testTheEndWithoutShouldResumeLeavesTheBookPausedUntilPlay() {
        var policy = PhoneAudioEventPolicy()
        _ = policy.respond(to: .interruptionBegan(becauseRouteDisconnected: false), bookCountsAsPlaying: true)
        XCTAssertEqual(policy.respond(to: .interruptionEnded(shouldResume: false), bookCountsAsPlaying: false), .nothing)
        XCTAssertFalse(policy.isInterrupted)
        XCTAssertEqual(
            policy.respond(to: .interruptionEnded(shouldResume: true), bookCountsAsPlaying: false), .nothing,
            "a later end of the same interruption plays nothing"
        )
    }

    /// F24: a book the listener paused before a call never starts as it ends.
    func testABookPausedBeforeTheCallStaysPausedAfterIt() {
        var policy = PhoneAudioEventPolicy()
        _ = policy.respond(to: .interruptionBegan(becauseRouteDisconnected: false), bookCountsAsPlaying: false)
        XCTAssertEqual(policy.respond(to: .interruptionEnded(shouldResume: true), bookCountsAsPlaying: false), .nothing)
    }

    func testAnEndWithNoBeginningPlaysNothing() {
        var policy = PhoneAudioEventPolicy()
        XCTAssertEqual(policy.respond(to: .interruptionEnded(shouldResume: true), bookCountsAsPlaying: false), .nothing)
    }

    func testABookPlayingAgainByTheEndIsLeftAsItIs() {
        var policy = PhoneAudioEventPolicy()
        _ = policy.respond(to: .interruptionBegan(becauseRouteDisconnected: false), bookCountsAsPlaying: true)
        XCTAssertEqual(policy.respond(to: .interruptionEnded(shouldResume: true), bookCountsAsPlaying: true), .nothing)
    }

    func testASecondBeginningOfTheSameInterruptionChangesNothing() {
        var policy = PhoneAudioEventPolicy()
        _ = policy.respond(to: .interruptionBegan(becauseRouteDisconnected: false), bookCountsAsPlaying: true)
        XCTAssertEqual(policy.respond(to: .interruptionBegan(becauseRouteDisconnected: false), bookCountsAsPlaying: false), .nothing)
        XCTAssertTrue(policy.wasPlayingWhenInterrupted, "the first beginning paused the book, so its end still plays it on")
        XCTAssertEqual(policy.respond(to: .interruptionEnded(shouldResume: true), bookCountsAsPlaying: false), .resume)
    }

    /// Siri's Pause during the interruption: Apple's guide says to honor it.
    func testAPauseFromTheListenerDuringTheInterruptionKeepsTheBookPaused() {
        var policy = PhoneAudioEventPolicy()
        _ = policy.respond(to: .interruptionBegan(becauseRouteDisconnected: false), bookCountsAsPlaying: true)
        policy.listenerPaused()
        XCTAssertEqual(policy.respond(to: .interruptionEnded(shouldResume: true), bookCountsAsPlaying: false), .nothing)
    }

    /// An end isn't guaranteed: a Play that activates the session takes the
    /// audio back, and a late end then plays nothing.
    func testAnActivationEndsTheInterruptionAndALateEndChangesNothing() {
        var policy = PhoneAudioEventPolicy()
        _ = policy.respond(to: .interruptionBegan(becauseRouteDisconnected: false), bookCountsAsPlaying: true)
        policy.activationSucceeded()
        XCTAssertFalse(policy.isInterrupted)
        XCTAssertEqual(policy.respond(to: .interruptionEnded(shouldResume: true), bookCountsAsPlaying: false), .nothing)
    }

    // MARK: - One disconnect, two events, either order

    func testRouteLossThenItsInterruption() {
        var policy = PhoneAudioEventPolicy()
        XCTAssertEqual(policy.respond(to: .routeChanged(.oldDeviceUnavailable), bookCountsAsPlaying: true), .pauseForLostRoute)
        XCTAssertEqual(policy.respond(to: .interruptionBegan(becauseRouteDisconnected: false), bookCountsAsPlaying: false), .nothing)
        XCTAssertEqual(
            policy.respond(to: .interruptionEnded(shouldResume: true), bookCountsAsPlaying: false), .nothing,
            "the book must not play on through the speaker"
        )
    }

    func testInterruptionThenItsRouteLoss() {
        var policy = PhoneAudioEventPolicy()
        XCTAssertEqual(policy.respond(to: .interruptionBegan(becauseRouteDisconnected: false), bookCountsAsPlaying: true), .pauseAndSave)
        XCTAssertEqual(policy.respond(to: .routeChanged(.oldDeviceUnavailable), bookCountsAsPlaying: false), .noteLostRoute)
        XCTAssertEqual(
            policy.respond(to: .interruptionEnded(shouldResume: true), bookCountsAsPlaying: false), .nothing,
            "the book must not play on through the speaker"
        )
    }

    func testAnInterruptionForADisconnectedRouteIsARouteLoss() {
        var policy = PhoneAudioEventPolicy()
        XCTAssertEqual(policy.respond(to: .interruptionBegan(becauseRouteDisconnected: true), bookCountsAsPlaying: true), .pauseForLostRoute)
        XCTAssertTrue(policy.isInterrupted)
        XCTAssertEqual(policy.respond(to: .routeChanged(.oldDeviceUnavailable), bookCountsAsPlaying: false), .noteLostRoute)
        XCTAssertEqual(policy.respond(to: .interruptionEnded(shouldResume: true), bookCountsAsPlaying: false), .nothing)
    }

    func testARouteLossOfAPausedBookOnlyNotesIt() {
        var policy = PhoneAudioEventPolicy()
        XCTAssertEqual(policy.respond(to: .routeChanged(.oldDeviceUnavailable), bookCountsAsPlaying: false), .noteLostRoute)
    }

    // MARK: - Route changes by reason

    func testEveryRouteChangeReasonHasItsResponse() {
        let expected: [PhoneAudioRouteChangeReason: (playing: PhoneAudioResponse, paused: PhoneAudioResponse)] = [
            .unknown: (.nothing, .nothing),
            .newDeviceAvailable: (.invalidateBackend, .invalidateBackend),
            .oldDeviceUnavailable: (.pauseForLostRoute, .noteLostRoute),
            .categoryChange: (.nothing, .nothing),
            .override: (.nothing, .nothing),
            .wakeFromSleep: (.invalidateBackend, .invalidateBackend),
            .noSuitableRouteForCategory: (.pauseForLostRoute, .noteLostRoute),
            .routeConfigurationChange: (.invalidateBackend, .invalidateBackend),
        ]
        XCTAssertEqual(Set(expected.keys), Set(PhoneAudioRouteChangeReason.allCases), "every reason is pinned")
        for (reason, responses) in expected {
            var playing = PhoneAudioEventPolicy()
            XCTAssertEqual(playing.respond(to: .routeChanged(reason), bookCountsAsPlaying: true), responses.playing, "\(reason) playing")
            var paused = PhoneAudioEventPolicy()
            XCTAssertEqual(paused.respond(to: .routeChanged(reason), bookCountsAsPlaying: false), responses.paused, "\(reason) paused")
        }
    }

    /// Apple: a media app "should not" pause for an override.
    func testAnOverrideDoesNothingEvenDuringAnInterruption() {
        var policy = PhoneAudioEventPolicy()
        _ = policy.respond(to: .interruptionBegan(becauseRouteDisconnected: false), bookCountsAsPlaying: true)
        XCTAssertEqual(policy.respond(to: .routeChanged(.override), bookCountsAsPlaying: false), .nothing)
        XCTAssertEqual(
            policy.respond(to: .interruptionEnded(shouldResume: true), bookCountsAsPlaying: false), .resume,
            "an override takes nothing away from the interruption's end"
        )
    }

    func testANewDeviceDuringAnInterruptionLeavesItsEndAlone() {
        var policy = PhoneAudioEventPolicy()
        _ = policy.respond(to: .interruptionBegan(becauseRouteDisconnected: false), bookCountsAsPlaying: true)
        XCTAssertEqual(policy.respond(to: .routeChanged(.newDeviceAvailable), bookCountsAsPlaying: false), .invalidateBackend)
        XCTAssertEqual(policy.respond(to: .interruptionEnded(shouldResume: true), bookCountsAsPlaying: false), .resume)
    }

    // MARK: - The engine and media services

    func testTheEnginesConfigurationChangeIsANaturalBreakWhilePlaying() {
        var policy = PhoneAudioEventPolicy()
        XCTAssertEqual(policy.respond(to: .engineConfigurationChanged, bookCountsAsPlaying: true), .restartFromPlace)
        XCTAssertEqual(policy.respond(to: .engineConfigurationChanged, bookCountsAsPlaying: false), .invalidateBackend)
        XCTAssertFalse(policy.isInterrupted)
    }

    func testAMediaResetRebuildsAndNeverResumesByItself() {
        var policy = PhoneAudioEventPolicy()
        _ = policy.respond(to: .interruptionBegan(becauseRouteDisconnected: false), bookCountsAsPlaying: true)
        XCTAssertEqual(policy.respond(to: .mediaServicesReset, bookCountsAsPlaying: false), .rebuildAudioObjects)
        XCTAssertTrue(policy.isInterrupted, "a cancel from the reset is no refusal")
        XCTAssertEqual(
            policy.respond(to: .interruptionEnded(shouldResume: true), bookCountsAsPlaying: false), .nothing,
            "Apple: don't restart playback until the user initiates it"
        )
    }

    func testAMediaResetWhilePlayingRebuildsToo() {
        var policy = PhoneAudioEventPolicy()
        XCTAssertEqual(policy.respond(to: .mediaServicesReset, bookCountsAsPlaying: true), .rebuildAudioObjects)
        policy.activationSucceeded()
        XCTAssertFalse(policy.isInterrupted)
    }

    func testTheEngineRestartWaitsAMomentForTheRouteChange() {
        XCTAssertGreaterThan(PhoneAudioEventPolicy.engineRestartDelay, 0)
        XCTAssertLessThanOrEqual(PhoneAudioEventPolicy.engineRestartDelay, 0.5, "short enough not to be heard as a gap")
    }
}

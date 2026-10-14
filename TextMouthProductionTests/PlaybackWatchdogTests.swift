import AVFoundation
import os
import XCTest
@testable import TextMouth

/// The playback watchdog (B07): the audio service's start check, extended
/// to the whole play. While audio plays, not paused, the player's time must
/// move; when it has not moved for `stallLimit` with the rate above zero,
/// playback stops as `.stoppedResponding`, through the failure path every
/// failure takes, and the player, which may be stuck, is let go of off the
/// main thread. On October 14, 2026 Apple's Vorbis decoder locked up a few
/// seconds into a track and the reader went on showing Playing over silence.
///
/// No real player is ever stuck here: a test stops the player's clock by
/// having the service read a frozen time (`_frozenPlayerTimeForTesting`).
/// Everything else plays real, short, silent WAV files, never Ogg, and with
/// its limits shortened (`shorten(_:)`), so each case runs in a second or
/// two. The false-alarm cases (item 4) play long enough for several checks
/// to judge them.
@MainActor
final class PlaybackWatchdogTests: XCTestCase {
    /// When the start check runs in these tests: late enough that a slow
    /// start on a busy Mac is never taken for a stall.
    private static let startCheck: TimeInterval = 1
    /// How long the time may stand still with the rate above zero.
    private static let limit: TimeInterval = 0.5
    /// How often the time is checked after the start check.
    private static let interval: TimeInterval = 0.1
    /// Long enough for the start check and several checks after it to run.
    private static let pastSeveralChecks: TimeInterval = startCheck + limit + 4 * interval

    /// The wording the listener hears when the audio stopped responding.
    private static let stoppedRespondingWording = "Playback stopped: the audio stopped responding. "
        + "Press Play to try again; if it stops again, quit and reopen TextMouth."

    // MARK: - A Play That Stops Moving

    /// A player whose time stops moving while its rate is above zero is
    /// stopped as `.stoppedResponding`, once, its stop logged with the file,
    /// the media time, the seconds without progress, and the rate.
    func testPlaybackWhoseTimeStopsMovingStopsAsStoppedResponding() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        try withPlayingService(seconds: 10) { playback, events, url in
            let failed = expectation(description: "Stop reported")
            events.failureExpectation = failed

            let lines = logLines(in: .debug) {
                playback._frozenPlayerTimeForTesting = 1
                wait(for: [failed], timeout: 5)
            }

            XCTAssertEqual(events.failures, [AudioPlaybackFailure(reason: .stoppedResponding, url: url.standardizedFileURL)])
            XCTAssertFalse(playback.isPlaying)
            XCTAssertFalse(playback.isPaused)
            XCTAssertEqual(events.finishedCount, 0)
            let stalled = lines.filter { $0.contains("AUDIO_PLAYBACK_STALLED: ") }
            XCTAssertEqual(stalled.count, 1, "\(lines)")
            let line = stalled.first ?? ""
            for part in ["file=\(url.lastPathComponent) ", "time=1.00 ", "secondsWithoutProgress=", "rate=1.0"] {
                XCTAssertTrue(line.contains(part), "\(part) missing from \(line)")
            }
            spinMainRunLoop(for: Self.limit * 2)
            XCTAssertEqual(events.failures.count, 1, "The stop was reported again")
        }
    }

    /// The player that may be stuck is let go of on a queue of its own,
    /// never the main thread, and playing again builds a fresh player,
    /// which plays on.
    func testTheStuckPlayerIsLetGoOfOffTheMainThreadAndARetryGetsAFreshOne() throws {
        try withPlayingService(seconds: 10) { playback, events, url in
            let letGoOnMainThread = OSAllocatedUnfairLock<Bool?>(initialState: nil)
            playback._stuckPlayerLetGoForTesting = { onMainThread in
                letGoOnMainThread.withLock { $0 = onMainThread }
            }
            let stuck = try XCTUnwrap(playback._playerForTesting)
            let failed = expectation(description: "Stop reported")
            events.failureExpectation = failed

            playback._frozenPlayerTimeForTesting = 1
            wait(for: [failed], timeout: 5)

            XCTAssertNil(playback._playerForTesting, "The service kept the stuck player")
            XCTAssertTrue(eventually { letGoOnMainThread.withLock { $0 } != nil }, "The stuck player was never let go of")
            XCTAssertEqual(letGoOnMainThread.withLock { $0 }, false, "The stuck player was let go of on the main thread")

            playback._frozenPlayerTimeForTesting = nil
            XCTAssertTrue(playback.load(url: url))
            XCTAssertTrue(playback.play(fromTime: 1))
            XCTAssertFalse(playback._playerForTesting === stuck, "The retry reused the stuck player")
            spinMainRunLoop(for: Self.pastSeveralChecks)
            XCTAssertTrue(playback.isPlaying)
            XCTAssertGreaterThan(playback.currentTime, 1.2, "The fresh player did not play on")
            XCTAssertEqual(events.failures.count, 1)
        }
    }

    /// The rule itself: only playback meant to be playing, its rate above
    /// zero and short of its file's end, whose time has stood still for the
    /// whole limit, has stopped advancing.
    func testOnlyAPlayMeantToPlayWhoseTimeStandsStillHasStoppedAdvancing() {
        func stopped(
            playing: Bool = true,
            paused: Bool = false,
            rate: Float = 1,
            still: TimeInterval = 8,
            atEnd: Bool = false
        ) -> Bool {
            AudioStallPolicy.hasStoppedAdvancing(
                isPlaying: playing,
                isPaused: paused,
                rate: rate,
                secondsWithoutProgress: still,
                limit: 8,
                reachedEndOfFile: atEnd
            )
        }

        XCTAssertTrue(stopped())
        XCTAssertTrue(stopped(rate: 0.25, still: 30))
        XCTAssertFalse(stopped(still: 7.9), "Stopped before the limit")
        XCTAssertFalse(stopped(playing: false), "Stopped playback counted")
        XCTAssertFalse(stopped(paused: true), "A pause counted")
        XCTAssertFalse(stopped(rate: 0), "A player not trying to play counted")
        XCTAssertFalse(stopped(atEnd: true), "The end of the file counted")
    }

    // MARK: - No False Alarms: the Service

    /// A pause far longer than the limit, and the resume after it, are no
    /// stall.
    func testAPauseLongerThanTheLimitIsNoStall() throws {
        try withPlayingService(seconds: 10) { playback, events, _ in
            spinMainRunLoop(for: Self.startCheck)
            playback.pause()
            spinMainRunLoop(for: Self.pastSeveralChecks)
            XCTAssertTrue(playback.resume())
            spinMainRunLoop(for: Self.pastSeveralChecks)

            XCTAssertTrue(playback.isPlaying)
            XCTAssertEqual(events.failures, [])
        }
    }

    /// Seeks while playing and while paused are no stall.
    func testSeeksAreNoStall() throws {
        try withPlayingService(seconds: 10) { playback, events, _ in
            spinMainRunLoop(for: Self.startCheck)
            playback.seek(to: 6)
            spinMainRunLoop(for: Self.interval * 3)
            playback.seek(to: 2)
            playback.pause()
            playback.seek(to: 4)
            spinMainRunLoop(for: Self.pastSeveralChecks)
            XCTAssertTrue(playback.resume())
            spinMainRunLoop(for: Self.pastSeveralChecks)

            XCTAssertTrue(playback.isPlaying)
            XCTAssertEqual(events.failures, [])
        }
    }

    /// The slowest speed moves the time a quarter of a second each second,
    /// which is progress.
    func testTheSlowestSpeedIsNoStall() throws {
        try withPlayingService(seconds: 10, speed: AudioSpeed.range.lowerBound) { playback, events, _ in
            spinMainRunLoop(for: Self.pastSeveralChecks)

            XCTAssertTrue(playback.isPlaying)
            XCTAssertGreaterThan(playback.currentTime, 0.1)
            XCTAssertEqual(events.failures, [])
        }
    }

    /// The end of a track, where the player stops and its time stands still
    /// until the end is acted on, is no stall: the play finishes once.
    func testTheEndOfATrackIsNoStall() throws {
        try withPlayingService(seconds: Self.startCheck + 0.6) { playback, events, _ in
            XCTAssertTrue(eventually(within: 10) { events.finishedCount == 1 }, "The track never finished")
            spinMainRunLoop(for: Self.pastSeveralChecks)

            XCTAssertEqual(events.finishedCount, 1)
            XCTAssertEqual(events.failures, [])
        }
    }

    /// A sleep timer's fade, the volume lowered step by step as the audio
    /// plays, is no stall.
    func testAFadeIsNoStall() throws {
        try withPlayingService(seconds: 10) { playback, events, _ in
            spinMainRunLoop(for: Self.startCheck)
            for step in stride(from: Float(1), through: 0, by: -0.1) {
                playback.setVolume(step)
                spinMainRunLoop(for: Self.interval)
            }
            spinMainRunLoop(for: Self.limit)

            XCTAssertTrue(playback.isPlaying)
            XCTAssertEqual(events.failures, [])
        }
    }

    // MARK: - The Reader

    /// A reader whose audio stops responding stops as for any failure, Play
    /// showing, Now Playing given up, and shows and says what happened, in
    /// these words.
    func testAReaderWhoseAudioStopsRespondingStopsAndSaysSo() throws {
        XCTAssertEqual(ReaderViewModel.audioStoppedRespondingMessage, Self.stoppedRespondingWording)
        let failure = AudioPlaybackFailure(reason: .stoppedResponding, url: URL(fileURLWithPath: "/tmp/03.mp3"))
        XCTAssertEqual(
            ReaderViewModel.audioPlaybackFailureMessage(for: failure, chapterNumber: 3, bookHasPackage: true),
            Self.stoppedRespondingWording
        )

        let world = try makeIntegrationWorld("Watchdog Reader Stop")
        let reader = try openSilentBook(in: world, trackDurations: [10])
        let service = reader.audioPlaybackService
        defer { reader.stop() }

        let recorder = try recordingAnnouncements {
            reader.play()
            waitUntilReady(try XCTUnwrap(service._playerItemForTesting))
            service._frozenPlayerTimeForTesting = 1
            XCTAssertTrue(eventually(within: 5) { reader.errorMessage != nil }, "The reader never stopped")
        }

        XCTAssertEqual(reader.errorMessage, Self.stoppedRespondingWording)
        XCTAssertEqual(recorder.announcements.map(\.message), [Self.stoppedRespondingWording])
        XCTAssertEqual(reader.audioPlaybackFailure?.reason, .stoppedResponding)
        XCTAssertFalse(reader.isCurrentlyPlaying)
        XCTAssertFalse(reader.isCurrentlyPaused)
        XCTAssertFalse(service.isPlaying)
        XCTAssertNotEqual(NowPlayingService.shared.playingOwnerID, reader.nowPlayingService.ownerID)
    }

    // MARK: - No False Alarms: the Reader

    /// A book played through to its end, each track rolling straight on into
    /// the next, never trips the watchdog.
    func testABookPlayedToItsEndNeverTripsIt() throws {
        let world = try makeIntegrationWorld("Watchdog Whole Book")
        let reader = try openSilentBook(in: world, trackDurations: [1.6, 1.6, 1.6])
        defer { reader.stop() }

        reader.play()

        XCTAssertTrue(
            eventually(within: 20) { reader.currentChapterIndex == 2 && !reader.isCurrentlyPlaying },
            "The book never played to its end"
        )
        XCTAssertNil(reader.errorMessage)
        XCTAssertNil(reader.audioPlaybackFailure)
    }

    /// The pause a manifest puts between tracks, longer than the limit,
    /// never trips the watchdog: nothing plays while it is waited out.
    func testAPauseBetweenTracksNeverTripsIt() throws {
        let world = try makeIntegrationWorld("Watchdog Chapter Pause")
        let reader = try openSilentBook(
            in: world,
            trackDurations: [1.6, 1.6],
            manifest: #"{"pauseBetweenTracksMs": 1500}"#
        )
        defer { reader.stop() }

        reader.play()

        XCTAssertTrue(eventually(within: 10) { reader.isWaitingOutChapterPause }, "The pause never began")
        XCTAssertTrue(
            eventually(within: 20) { reader.currentChapterIndex == 1 && !reader.isCurrentlyPlaying },
            "The book never played to its end"
        )
        XCTAssertNil(reader.errorMessage)
        XCTAssertNil(reader.audioPlaybackFailure)
    }

    /// Where Am I?, holding the book paused for longer than the limit while
    /// it speaks, never trips the watchdog, and the book plays on after it.
    func testWhereAmINeverTripsIt() throws {
        let world = try makeIntegrationWorld("Watchdog Where Am I")
        let reader = try openSilentBook(in: world, trackDurations: [10])
        let service = reader.audioPlaybackService
        reader._whereAmIUtteranceRecorderForTesting = { _ in }
        let endSound = WhereAmIEndSoundClock(holdingFor: reader)
        defer { reader.stop() }
        reader.play()
        waitUntilReady(try XCTUnwrap(service._playerItemForTesting))
        spinMainRunLoop(for: Self.startCheck)

        reader.whereAmI()
        spinMainRunLoop(for: Self.pastSeveralChecks)
        reader.whereAmIAnnouncementFinished()
        endSound.passEndSound()
        spinMainRunLoop(for: Self.pastSeveralChecks)

        XCTAssertTrue(service.isPlaying, "The book did not play on after Where Am I?")
        XCTAssertNil(reader.errorMessage)
        XCTAssertNil(reader.audioPlaybackFailure)
    }

    /// The reader paused for longer than the limit, and played again, never
    /// trips the watchdog.
    func testAReaderPausedPastTheLimitNeverTripsIt() throws {
        let world = try makeIntegrationWorld("Watchdog Reader Pause")
        let reader = try openSilentBook(in: world, trackDurations: [10])
        let service = reader.audioPlaybackService
        defer { reader.stop() }
        reader.play()
        waitUntilReady(try XCTUnwrap(service._playerItemForTesting))
        spinMainRunLoop(for: Self.startCheck)

        reader.pause()
        spinMainRunLoop(for: Self.pastSeveralChecks)
        reader.playOrResume()
        spinMainRunLoop(for: Self.pastSeveralChecks)

        XCTAssertTrue(service.isPlaying, "The book did not play on")
        XCTAssertNil(reader.errorMessage)
        XCTAssertNil(reader.audioPlaybackFailure)
    }

    // MARK: - Helpers

    /// Shorten `service`'s watchdog to the limits these tests use.
    private func shorten(_ service: AudioPlaybackService) {
        service.stallRecoveryTimeout = Self.startCheck
        service.stallLimit = Self.limit
        service.progressCheckInterval = Self.interval
    }

    /// Run `body` with a shortened service playing a silent WAV file of
    /// `seconds` at `speed`, ready to play, given the service, what it
    /// reported, and the file. The service stops and the file is removed
    /// afterwards.
    private func withPlayingService(
        seconds: TimeInterval,
        speed: Double = 1,
        _ body: (AudioPlaybackService, PlaybackEvents, URL) throws -> Void
    ) throws {
        let directory = try AudioTestFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("watched.wav")
        try AudioTestFixtures.writeSilence(to: url, duration: seconds)
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        shorten(playback)
        let events = PlaybackEvents(observing: playback)
        playback.setSpeed(speed)
        XCTAssertTrue(playback.load(url: url))
        XCTAssertTrue(playback.play())
        waitUntilReady(try XCTUnwrap(playback._playerItemForTesting))
        try body(playback, events, url)
        withExtendedLifetime(events) {}
    }

    /// A reader of a new book of silent tracks lasting `trackDurations`
    /// seconds, with `manifest` beside them, loaded, its sound effects
    /// recorded rather than played, and its watchdog shortened.
    private func openSilentBook(
        in world: IntegrationWorld,
        trackDurations: [TimeInterval],
        manifest: String? = nil
    ) throws -> ReaderViewModel {
        let book = try world.makeSilentAudioBook(
            title: "Ferry Timetables",
            trackDurations: trackDurations,
            manifest: manifest
        )
        let reader = world.openReader(for: book)
        reader.soundEffectService = RecordedSoundEffects()
        shorten(reader.audioPlaybackService)
        waitForReaderToLoad(reader)
        return reader
    }
}

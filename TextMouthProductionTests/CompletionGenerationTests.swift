import AVFoundation
import XCTest
@testable import TextMouth

/// The audio service reports the end of what it plays once for each play,
/// and nothing a released player or an earlier play reports can reach the
/// play under way (TODO P05).
///
/// Every test plays silent WAV files, written for it into a folder of its
/// own, with the real service and AVFoundation's real callbacks. Tests wait
/// for the event that could do harm, such as a released player's tick or
/// an end-of-file notice, rather than for a fixed time, and then check that
/// it did none.
@MainActor
final class CompletionGenerationTests: XCTestCase {

    // MARK: - The Position Observer

    /// Paused playback that a seek leaves past its clip's end does not
    /// finish the clip, which would move on while the listener has paused,
    /// and reports no time past that end; resuming finishes it once.
    func testPausedPlaybackPastItsClipEndFinishesOnlyOnceResumed() throws {
        let file = try writeSilentFile(duration: 1)
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        let events = PlaybackEvents(observing: playback)
        let reports = PlayerReportLog(observing: playback)
        var positions: [TimeInterval] = []
        playback.onPositionUpdate = { positions.append($0) }
        XCTAssertTrue(playback.load(url: file))
        playback.setClipEndTime(0.3)
        XCTAssertTrue(playback.play())
        let item = try XCTUnwrap(playback._playerItemForTesting)
        XCTAssertTrue(eventually { item.status == .readyToPlay }, "The file never became ready")
        playback.pause()

        playback.seek(to: 0.5)
        XCTAssertTrue(
            eventually { reports.handledTick(atOrAfter: 0.5) },
            "The player never reported landing past the clip's end"
        )

        XCTAssertEqual(events.finishedCount, 0, "Paused playback finished its clip")
        XCTAssertTrue(playback.isPaused)
        XCTAssertTrue(playback.resume())
        XCTAssertTrue(eventually { events.finishedCount == 1 }, "Resumed playback never finished its clip")
        XCTAssertFalse(positions.contains { $0 >= 0.3 }, "A time past the clip's end was reported: \(positions)")
    }

    /// A chapter reload replaces the player. The released player, played
    /// on to its end, neither ticks into its successor nor finishes it: its
    /// observers went with it.
    func testAReloadedPlayersObserversNeverReachTheNextFile() throws {
        let first = try writeSilentFile(named: "first.wav", duration: 0.5)
        let second = try writeSilentFile(named: "second.wav", duration: 3)
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        let events = PlaybackEvents(observing: playback)
        let reports = PlayerReportLog(observing: playback)
        XCTAssertTrue(playback.load(url: first))
        XCTAssertTrue(playback.play())
        let firstPlayer = try XCTUnwrap(playback._playerForTesting)
        let firstItem = try XCTUnwrap(playback._playerItemForTesting)
        XCTAssertTrue(eventually { firstItem.status == .readyToPlay }, "The first file never became ready")

        XCTAssertTrue(playback.load(url: second))
        XCTAssertTrue(playback.play())
        playReleasedPlayerToItsEnd(firstPlayer, item: firstItem)

        XCTAssertEqual(reports.ticksFromReleasedPlayers, 0, "The released player's position observer was still installed")
        XCTAssertEqual(events.finishedCount, 0, "The released player's end finished the next file")
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(playback.loadedURL?.lastPathComponent, "second.wav")
    }

    /// Stop releases the player. Played on to its end, it reports nothing
    /// to the stopped service: no tick, and no finish.
    func testAStoppedPlayersObserversNeverReachTheService() throws {
        let file = try writeSilentFile(duration: 0.5)
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        let events = PlaybackEvents(observing: playback)
        let reports = PlayerReportLog(observing: playback)
        XCTAssertTrue(playback.load(url: file))
        XCTAssertTrue(playback.play())
        let player = try XCTUnwrap(playback._playerForTesting)
        let item = try XCTUnwrap(playback._playerItemForTesting)
        XCTAssertTrue(eventually { item.status == .readyToPlay }, "The file never became ready")

        playback.stop()
        let reportsAtStop = reports.reports.count
        playReleasedPlayerToItsEnd(player, item: item)

        XCTAssertEqual(reports.reports.count, reportsAtStop, "The stopped player reported \(reports.reports.dropFirst(reportsAtStop))")
        XCTAssertEqual(events.finishedCount, 0, "The stopped player's end finished playback")
        XCTAssertFalse(playback.isPlaying)
    }

    // MARK: - End-of-File Notices

    /// A file played to its end finishes once, ended by AVFoundation's
    /// notice.
    func testNaturalEndFinishesOnce() throws {
        let file = try writeSilentFile(duration: 0.4)
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        let events = PlaybackEvents(observing: playback)
        let reports = PlayerReportLog(observing: playback)
        XCTAssertTrue(playback.load(url: file))
        XCTAssertTrue(playback.play())

        XCTAssertTrue(eventually { !reports.endOfFileOutcomes.isEmpty }, "The file's end was never reported")

        XCTAssertEqual(reports.endOfFileOutcomes, [.endedPlay])
        XCTAssertEqual(events.finishedCount, 1)
        XCTAssertEqual(events.failures, [])
        XCTAssertFalse(playback.isPlaying)
    }

    /// A clip that ends where its file does is reported ended twice: first
    /// by the position observer, at the clip's end, then about 35
    /// milliseconds later by AVFoundation's notice of the file's end. The
    /// first finishes playback; the second, posted after it, ends nothing.
    func testClipEndingWhereItsFileEndsFinishesOnceThoughReportedTwice() throws {
        let file = try writeSilentFile(duration: 0.4)
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        let events = PlaybackEvents(observing: playback)
        let reports = PlayerReportLog(observing: playback)
        XCTAssertTrue(playback.load(url: file))
        playback.setClipEndTime(0.4)
        XCTAssertTrue(playback.play())

        XCTAssertTrue(eventually { !reports.endOfFileOutcomes.isEmpty }, "The file's end was never reported")

        XCTAssertTrue(reports.finishedAClipOnATick, "The position observer never reached the clip's end: \(reports.reports)")
        XCTAssertEqual(reports.endOfFileOutcomes, [.nothingPlaying])
        XCTAssertEqual(events.finishedCount, 1)
    }

    /// A seek past the end of the file, while playing, finishes once.
    func testSeekPastTheEndFinishesOnce() throws {
        let file = try writeSilentFile(duration: 2)
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        let events = PlaybackEvents(observing: playback)
        let reports = PlayerReportLog(observing: playback)
        XCTAssertTrue(playback.load(url: file))
        XCTAssertTrue(playback.play())
        let item = try XCTUnwrap(playback._playerItemForTesting)
        XCTAssertTrue(eventually { item.status == .readyToPlay }, "The file never became ready")

        playback.seek(to: 10)

        XCTAssertTrue(eventually { !reports.endOfFileOutcomes.isEmpty }, "The file's end was never reported")
        XCTAssertEqual(reports.endOfFileOutcomes, [.endedPlay])
        XCTAssertEqual(events.finishedCount, 1)
    }

    /// Stop between AVFoundation posting the file's end and the service
    /// acting on it leaves the notice nothing to end: it was posted during
    /// the play that Stop ended.
    func testEndOvertakenByStopEndsNothing() throws {
        let file = try writeSilentFile(duration: 0.4)
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        let events = PlaybackEvents(observing: playback)
        let reports = PlayerReportLog(observing: playback)
        XCTAssertTrue(playback.load(url: file))
        XCTAssertTrue(playback.play())
        playback._endNoticeArrivedForTesting = { [unowned playback] in playback.stop() }

        XCTAssertTrue(eventually { !reports.endOfFileOutcomes.isEmpty }, "The file's end was never reported")

        XCTAssertEqual(reports.endOfFileOutcomes, [.postedDuringEarlierPlay])
        XCTAssertEqual(events.finishedCount, 0)
        XCTAssertFalse(playback.isPlaying)
    }

    /// A seek back between AVFoundation posting the file's end and the
    /// service acting on it wins: the notice ends nothing, playback plays on
    /// from the new place, which AVFoundation had stopped at the end, and
    /// finishes once when it reaches the end again.
    func testEndOvertakenBySeekEndsNothingAndPlaybackPlaysOn() throws {
        let file = try writeSilentFile(duration: 0.4)
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        let events = PlaybackEvents(observing: playback)
        let reports = PlayerReportLog(observing: playback)
        XCTAssertTrue(playback.load(url: file))
        XCTAssertTrue(playback.play())
        var hasSought = false
        playback._endNoticeArrivedForTesting = { [unowned playback] in
            guard !hasSought else { return }
            hasSought = true
            playback.seek(to: 0.1)
        }

        XCTAssertTrue(eventually { reports.endOfFileOutcomes.count == 2 }, "Playback never reached the end again")

        XCTAssertEqual(reports.endOfFileOutcomes, [.postedDuringEarlierPlay, .endedPlay])
        XCTAssertEqual(events.finishedCount, 1)
        XCTAssertEqual(events.failures, [])
    }

    /// The same file loaded and played again between AVFoundation posting
    /// its end and the service acting on it, as a chapter reload does,
    /// begins a play that notice cannot end; the new play finishes once.
    func testEndOvertakenByAReloadOfTheSameFileEndsNothing() throws {
        let file = try writeSilentFile(duration: 0.4)
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        let events = PlaybackEvents(observing: playback)
        let reports = PlayerReportLog(observing: playback)
        XCTAssertTrue(playback.load(url: file))
        XCTAssertTrue(playback.play())
        var hasReloaded = false
        playback._endNoticeArrivedForTesting = { [unowned playback] in
            guard !hasReloaded else { return }
            hasReloaded = true
            XCTAssertTrue(playback.load(url: file))
            XCTAssertTrue(playback.play(fromTime: 0))
        }

        XCTAssertTrue(eventually { reports.endOfFileOutcomes.count == 2 }, "The reloaded file never reached its end")

        XCTAssertEqual(reports.endOfFileOutcomes, [.postedDuringEarlierPlay, .endedPlay])
        XCTAssertEqual(events.finishedCount, 1)
    }

    /// A seek back in the moment between the playhead reaching the file's
    /// end and AVFoundation posting that end: the late notice arrives as the
    /// seek lands, with the playhead where the seek put it, and ends
    /// nothing. AVFoundation leaves that player stopped, so the play goes on
    /// from there on a new player, and finishes once at the end.
    func testSeekBackJustAfterTheEndIsReachedPlaysOnAndFinishesOnce() throws {
        let file = try writeSilentFile(duration: 0.4)
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        let events = PlaybackEvents(observing: playback)
        let reports = PlayerReportLog(observing: playback)
        XCTAssertTrue(playback.load(url: file))
        let firstPlayer = try XCTUnwrap(playback._playerForTesting)
        var positionsAfterSeeking: [TimeInterval] = []
        var hasSought = false
        playback.onPositionUpdate = { [unowned playback] time in
            if hasSought {
                positionsAfterSeeking.append(time)
            } else if time >= 0.4 - 0.001 {
                // The tick that finds the playhead at the end comes before
                // AVFoundation posts the end.
                hasSought = true
                playback.seek(to: 0.1)
            }
        }
        XCTAssertTrue(playback.play())

        XCTAssertTrue(eventually { events.finishedCount == 1 }, "Playback never finished after the seek")

        XCTAssertTrue(hasSought, "The playhead was never reported at the end")
        XCTAssertEqual(reports.endOfFileOutcomes, [.lateForEarlierPlaythrough, .endedPlay])
        XCTAssertFalse(playback._playerForTesting === firstPlayer, "The stopped player was kept")
        XCTAssertTrue(
            positionsAfterSeeking.contains { $0 > 0.1 && $0 < 0.4 },
            "Playback did not play on from where it was sought: \(positionsAfterSeeking)"
        )
        XCTAssertEqual(events.failures, [])
    }

    /// A play that finishes at its clip's end, at the file's end, and is at
    /// once played again on the same player, as a loop does, receives the
    /// late end of the earlier playthrough as it begins. That end is ignored,
    /// the play starts again on a new player, and plays through to finish
    /// once more.
    func testReplayingAFileJustAfterItsClipEndsPlaysItThroughAgain() throws {
        let file = try writeSilentFile(duration: 0.4)
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        let reports = PlayerReportLog(observing: playback)
        XCTAssertTrue(playback.load(url: file))
        playback.setClipEndTime(0.4)
        let firstPlayer = try XCTUnwrap(playback._playerForTesting)
        var finishedCount = 0
        playback.onPlaybackFinished = { [unowned playback] in
            finishedCount += 1
            if finishedCount == 1 {
                XCTAssertTrue(playback.play(fromTime: 0))
            }
        }
        XCTAssertTrue(playback.play())

        XCTAssertTrue(eventually { finishedCount == 2 }, "The replay never played through")

        XCTAssertEqual(reports.endOfFileOutcomes.first, .lateForEarlierPlaythrough)
        XCTAssertFalse(reports.endOfFileOutcomes.contains(.endedPlay), "An end of file ended a play: \(reports.endOfFileOutcomes)")
        XCTAssertFalse(playback._playerForTesting === firstPlayer, "The stopped player was kept")
        XCTAssertEqual(finishedCount, 2)
    }

    // MARK: - Pausing as the End Comes

    /// A pause in the moment between the playhead reaching the file's end
    /// and AVFoundation posting that end holds the end: nothing finishes
    /// while paused, and resuming finishes the play once, though
    /// AVFoundation reports nothing more for a player resumed at its end.
    func testPauseJustAsTheEndIsReachedHoldsTheEndUntilResume() throws {
        let file = try writeSilentFile(duration: 0.4)
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        let events = PlaybackEvents(observing: playback)
        let reports = PlayerReportLog(observing: playback)
        XCTAssertTrue(playback.load(url: file))
        playback.onPositionUpdate = { [unowned playback] time in
            if time >= 0.4 - 0.001 { playback.pause() }
        }
        XCTAssertTrue(playback.play())

        XCTAssertTrue(eventually { !reports.endOfFileOutcomes.isEmpty }, "The file's end was never reported")
        XCTAssertEqual(reports.endOfFileOutcomes, [.heldUntilResume])
        XCTAssertEqual(events.finishedCount, 0, "Paused playback finished")
        XCTAssertTrue(playback.isPaused)

        XCTAssertTrue(playback.resume())
        XCTAssertEqual(events.finishedCount, 0, "Resuming finished before it returned")
        XCTAssertTrue(eventually { events.finishedCount == 1 }, "Resuming never finished the play")
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(reports.endOfFileOutcomes, [.heldUntilResume])
    }

    /// A pause between AVFoundation posting the file's end and the service
    /// acting on it holds the end as well, and resuming finishes the play
    /// once.
    func testPauseBetweenTheEndAndItsHandlingHoldsTheEnd() throws {
        let file = try writeSilentFile(duration: 0.4)
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        let events = PlaybackEvents(observing: playback)
        let reports = PlayerReportLog(observing: playback)
        XCTAssertTrue(playback.load(url: file))
        XCTAssertTrue(playback.play())
        playback._endNoticeArrivedForTesting = { [unowned playback] in playback.pause() }

        XCTAssertTrue(eventually { !reports.endOfFileOutcomes.isEmpty }, "The file's end was never reported")
        XCTAssertEqual(reports.endOfFileOutcomes, [.heldUntilResume])
        XCTAssertEqual(events.finishedCount, 0, "Paused playback finished")

        XCTAssertTrue(playback.resume())
        XCTAssertTrue(eventually { events.finishedCount == 1 }, "Resuming never finished the play")
    }

    /// An end held while paused ends nothing once a seek moves playback
    /// away from it: resuming plays on from there, and the play finishes
    /// once, at the end it reaches next.
    func testHeldEndGivesWayToASeekMadeWhilePaused() throws {
        let file = try writeSilentFile(duration: 0.4)
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        let events = PlaybackEvents(observing: playback)
        let reports = PlayerReportLog(observing: playback)
        XCTAssertTrue(playback.load(url: file))
        XCTAssertTrue(playback.play())
        var hasPaused = false
        playback._endNoticeArrivedForTesting = { [unowned playback] in
            guard !hasPaused else { return }
            hasPaused = true
            playback.pause()
        }
        XCTAssertTrue(eventually { reports.endOfFileOutcomes == [.heldUntilResume] }, "The file's end was never held")

        playback.seek(to: 0.1)
        XCTAssertTrue(playback.resume())

        XCTAssertTrue(eventually { reports.endOfFileOutcomes.count == 2 }, "Playback never reached the end again")
        XCTAssertEqual(reports.endOfFileOutcomes, [.heldUntilResume, .endedPlay])
        XCTAssertEqual(events.finishedCount, 1)
    }

    // MARK: - The Speech Service's Finished Utterances

    /// A finished utterance held for the main queue keeps its identity its
    /// own: however many utterances are made and released meanwhile, none
    /// takes its identifier, and it is released only with its holder.
    func testAHeldFinishedUtteranceKeepsItsIdentityItsOwn() {
        var finished: FinishedUtterance?
        weak var heldUtterance: AVSpeechUtterance?
        autoreleasepool {
            finished = FinishedUtterance(utterance: AVSpeechUtterance(string: "Mooring lines are fast."))
            heldUtterance = finished?.utterance
        }
        let finishedID = try? XCTUnwrap(finished?.id)

        let laterIDs = autoreleasepool {
            (0..<500).map { _ in ObjectIdentifier(AVSpeechUtterance(string: "Cast off.")) }
        }

        XCTAssertNotNil(heldUtterance, "The held utterance was released")
        XCTAssertFalse(laterIDs.contains { $0 == finishedID }, "A later utterance took the held one's identity")
        autoreleasepool { finished = nil }
        XCTAssertNil(heldUtterance, "The utterance outlived its holder")
    }

    /// A finish reported for an utterance that is not the one speaking, such
    /// as one stopped by a seek, moves nothing.
    func testFinishOfAnUtteranceNoLongerSpeakingIsIgnored() {
        let speech = SpeechService(userDefaults: makeSandboxedPreferences("finished-utterances"))
        var finishedCount = 0
        speech.onUtteranceFinished = { finishedCount += 1 }

        speech.speechSynthesizer(AVSpeechSynthesizer(), didFinish: AVSpeechUtterance(string: "Already stopped."))
        // The finish is handled on the main queue; a block queued after it
        // runs only once it has been.
        var handled = false
        DispatchQueue.main.async { handled = true }
        XCTAssertTrue(eventually { handled }, "The finish was never handled")

        XCTAssertEqual(finishedCount, 0)
    }

    // MARK: - End Notice Policy

    /// A notice posted during an earlier play ends nothing, wherever the
    /// playhead stood.
    func testPolicyIgnoresANoticePostedDuringAnEarlierPlay() {
        XCTAssertEqual(
            AudioEndNoticePolicy.outcome(
                postedGeneration: 3, currentGeneration: 4, isPlaying: true, isPaused: false,
                playhead: 10, playStart: 0, fileDuration: 10, restartedFrom: nil
            ),
            .postedDuringEarlierPlay
        )
    }

    /// With nothing playing, a notice ends nothing.
    func testPolicyIgnoresANoticeWhenNothingPlays() {
        XCTAssertEqual(
            AudioEndNoticePolicy.outcome(
                postedGeneration: 4, currentGeneration: 4, isPlaying: false, isPaused: false,
                playhead: 10, playStart: 0, fileDuration: 10, restartedFrom: nil
            ),
            .nothingPlaying
        )
    }

    /// A playhead at the file's end, or past where its play began, has
    /// played to the end; so has one whose position is unknown.
    func testPolicyEndsThePlayThatReachedTheEnd() {
        func outcome(playhead: TimeInterval?, playStart: TimeInterval, fileDuration: TimeInterval?) -> AudioEndNoticeOutcome {
            AudioEndNoticePolicy.outcome(
                postedGeneration: 1, currentGeneration: 1, isPlaying: true, isPaused: false,
                playhead: playhead, playStart: playStart, fileDuration: fileDuration, restartedFrom: nil
            )
        }
        XCTAssertEqual(outcome(playhead: 10, playStart: 2, fileDuration: 10), .endedPlay)
        // A file whose length was overestimated ends short of it.
        XCTAssertEqual(outcome(playhead: 9.4, playStart: 2, fileDuration: 10), .endedPlay)
        // A play that began at the end ends there.
        XCTAssertEqual(outcome(playhead: 10, playStart: 10, fileDuration: 10), .endedPlay)
        XCTAssertEqual(outcome(playhead: nil, playStart: 2, fileDuration: 10), .endedPlay)
    }

    /// A playhead still where the play began, short of the file's end, is
    /// the late end of an earlier playthrough, within the tolerance of a
    /// seek's landing, and also while the file's length is unknown.
    func testPolicyRecognizesTheLateEndOfAnEarlierPlaythrough() {
        func outcome(playhead: TimeInterval, fileDuration: TimeInterval?) -> AudioEndNoticeOutcome {
            AudioEndNoticePolicy.outcome(
                postedGeneration: 1, currentGeneration: 1, isPlaying: true, isPaused: false,
                playhead: playhead, playStart: 3, fileDuration: fileDuration, restartedFrom: nil
            )
        }
        let tolerance = AudioEndNoticePolicy.playStartTolerance
        XCTAssertEqual(outcome(playhead: 3, fileDuration: 10), .lateForEarlierPlaythrough)
        XCTAssertEqual(outcome(playhead: 3 + tolerance, fileDuration: 10), .lateForEarlierPlaythrough)
        XCTAssertEqual(outcome(playhead: 3, fileDuration: nil), .lateForEarlierPlaythrough)
        XCTAssertEqual(outcome(playhead: 3 + 2 * tolerance, fileDuration: 10), .endedPlay)
    }

    /// The end of a paused play is held until it resumes; the late end of
    /// an earlier playthrough is told apart while paused too.
    func testPolicyHoldsTheEndOfAPausedPlay() {
        func outcome(playhead: TimeInterval) -> AudioEndNoticeOutcome {
            AudioEndNoticePolicy.outcome(
                postedGeneration: 1, currentGeneration: 1, isPlaying: true, isPaused: true,
                playhead: playhead, playStart: 3, fileDuration: 10, restartedFrom: nil
            )
        }
        XCTAssertEqual(outcome(playhead: 10), .heldUntilResume)
        XCTAssertEqual(outcome(playhead: 3), .lateForEarlierPlaythrough)
    }

    /// A play already started again on a new player after a late notice is
    /// not started again: another notice with the playhead at its start is
    /// a real end, as at the true end of a file whose length was
    /// overestimated, and never starts a loop of restarts.
    func testPolicyNeverRestartsAPlayTwice() {
        XCTAssertEqual(
            AudioEndNoticePolicy.outcome(
                postedGeneration: 2, currentGeneration: 2, isPlaying: true, isPaused: false,
                playhead: 3, playStart: 3, fileDuration: 10, restartedFrom: 3
            ),
            .endedPlay
        )
    }

    // MARK: - Fixtures

    /// A silent WAV file lasting `duration` seconds, in a folder of its own
    /// that is removed when the test ends.
    private func writeSilentFile(named name: String = "chapter.wav", duration: TimeInterval) throws -> URL {
        let folder = try AudioTestFixtures.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(name)
        try AudioTestFixtures.writeSilence(to: file, duration: duration)
        return file
    }

    /// Play `player`, which the service has released, on from where it
    /// stopped until AVFoundation posts the end of `item`, its item, so that
    /// any observer of it still installed has had every chance to report.
    private func playReleasedPlayerToItsEnd(_ player: AVPlayer, item: AVPlayerItem) {
        let ended = expectation(forNotification: .AVPlayerItemDidPlayToEndTime, object: item)
        player.rate = 1
        wait(for: [ended], timeout: 10)
    }
}

/// Every report from AVFoundation that an audio service dealt with, in
/// order, kept for a test. Written and read on the main queue, where the
/// service deals with them.
@MainActor
final class PlayerReportLog {
    /// The reports, in the order the service dealt with them.
    private(set) var reports: [AudioPlayerReport] = []

    /// Start keeping `playback`'s reports, replacing its report hook.
    init(observing playback: AudioPlaybackService) {
        playback._reportHandledForTesting = { [unowned self] report in
            self.reports.append(report)
        }
    }

    /// How many ticks came from the position observer of a released player.
    var ticksFromReleasedPlayers: Int {
        reports.filter { $0 == .tickFromReleasedPlayer }.count
    }

    /// What the service made of each end-of-file notice, in order.
    var endOfFileOutcomes: [AudioEndNoticeOutcome] {
        reports.compactMap { report in
            guard case .endOfFile(let outcome) = report else { return nil }
            return outcome
        }
    }

    /// Whether a tick of the position observer found the clip at its end
    /// and finished it.
    var finishedAClipOnATick: Bool {
        reports.contains { report in
            guard case .tick(_, .finishClip) = report else { return false }
            return true
        }
    }

    /// Whether a tick of the current player found it at least `seconds`
    /// into its file, give or take a millisecond.
    func handledTick(atOrAfter seconds: TimeInterval) -> Bool {
        reports.contains { report in
            guard case .tick(let tickSeconds, _) = report else { return false }
            return tickSeconds >= seconds - 0.001
        }
    }
}

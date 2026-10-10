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

    /// A file played to its end, with no clip end, reports no position once
    /// it has finished (TODO P07): its player's clock still ticks after the
    /// finish, as the stop at the end makes it, and here as a jump of the
    /// player's own makes it, and the service ignores each such tick, so a
    /// finished book's place stays at the exact end the reader saved it at.
    /// A new play from there reports positions again.
    func testAFinishedPlayReportsNoPositionUntilItPlaysAgain() throws {
        let file = try writeSilentFile(duration: 0.4)
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        let events = PlaybackEvents(observing: playback)
        let reports = PlayerReportLog(observing: playback)
        var positions: [TimeInterval] = []
        playback.onPositionUpdate = { positions.append($0) }
        XCTAssertTrue(playback.load(url: file))
        XCTAssertTrue(playback.play())
        XCTAssertTrue(eventually { events.finishedCount == 1 }, "The file never finished")
        let reportsAtFinish = reports.reports.count
        let positionsAtFinish = positions.count

        // The player's clock jumps, behind the service's back, as the stop
        // at the end makes it tick.
        let player = try XCTUnwrap(playback._playerForTesting)
        player.seek(to: CMTime(seconds: 0.1, preferredTimescale: 600))
        let ticksAfterTheFinish = { () -> [AudioPositionObserverPolicy.Action] in
            reports.reports.dropFirst(reportsAtFinish).compactMap { report in
                guard case .tick(_, let action) = report else { return nil }
                return action
            }
        }
        XCTAssertTrue(eventually { !ticksAfterTheFinish().isEmpty }, "The player's clock never ticked after the finish")
        XCTAssertTrue(
            ticksAfterTheFinish().allSatisfy { $0 == .ignore },
            "A tick after the finish was acted on: \(ticksAfterTheFinish())"
        )
        XCTAssertEqual(positions.count, positionsAtFinish, "The finished play reported a position: \(positions)")

        XCTAssertTrue(playback.play(fromTime: 0))
        XCTAssertTrue(eventually { positions.count > positionsAtFinish }, "A new play reported no position")
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

    // MARK: - The File That Follows

    /// A file named to follow the loaded one is the loaded file, playing on
    /// the same player, when the loaded one's end is reported (TODO PERF09).
    /// Loading it then and playing it from its start, as the reader starts
    /// the next chapter, plays on with no new player, which then stops at
    /// that file's end. Each file's end is reported once, and the position
    /// never jumps back to the next file's start before the first file's end
    /// is reported.
    func testANamedFileFollowsOnTheSamePlayer() throws {
        let first = try writeSilentFile(named: "first.wav", duration: 0.5)
        let second = try writeSilentFile(named: "second.wav", duration: 0.5)
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        let events = PlaybackEvents(observing: playback)
        var finishedCount = 0
        var followingWasPlayingAtTheFirstEnd = false
        playback.onPlaybackFinished = { [unowned playback] in
            finishedCount += 1
            guard finishedCount == 1 else { return }
            followingWasPlayingAtTheFirstEnd = playback.isPlaying
                && playback.loadedURL?.lastPathComponent == "second.wav"
            XCTAssertTrue(playback.load(url: second))
            XCTAssertTrue(playback.play(fromTime: 0))
        }
        var positionsBeforeTheFirstEnd: [TimeInterval] = []
        playback.onPositionUpdate = { time in
            if finishedCount == 0 {
                positionsBeforeTheFirstEnd.append(time)
            }
        }
        XCTAssertTrue(playback.load(url: first))
        XCTAssertTrue(playback.play())
        playback.setFileAfterCurrent(second)
        let player = try XCTUnwrap(playback._playerForTesting as? AVQueuePlayer)
        XCTAssertEqual(player.items().count, 2, "The named file was not queued")

        XCTAssertTrue(eventually { finishedCount == 1 }, "The first file never finished")
        XCTAssertTrue(followingWasPlayingAtTheFirstEnd, "The named file was not playing when the first file's end came")
        XCTAssertTrue(playback._playerForTesting === player, "A new player was made for the file that followed")
        XCTAssertEqual(playback.loadedURL?.lastPathComponent, "second.wav")
        XCTAssertTrue(playback.isPlaying)
        XCTAssertTrue(
            eventually { player.currentItem === playback._playerItemForTesting && player.actionAtItemEnd == .pause },
            "The player never settled on the file that followed, to stop at its end"
        )
        XCTAssertTrue(eventually { finishedCount == 2 }, "The file that followed never finished")
        XCTAssertEqual(events.failures, [])
        XCTAssertEqual(positionsBeforeTheFirstEnd, positionsBeforeTheFirstEnd.sorted(), "The position jumped back")
    }

    /// Without a file named to follow, the loaded file stops at its end and
    /// stays the player's item, as with a plain player.
    func testWithoutANamedFileTheLoadedFileStopsAtItsEnd() throws {
        let file = try writeSilentFile(duration: 0.3)
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        let events = PlaybackEvents(observing: playback)
        XCTAssertTrue(playback.load(url: file))
        XCTAssertTrue(playback.play())

        XCTAssertTrue(eventually { events.finishedCount == 1 }, "The file never finished")
        XCTAssertFalse(playback.isPlaying)
        XCTAssertTrue(playback._playerForTesting?.currentItem === playback._playerItemForTesting)
    }

    /// A file named to follow that cannot be read is not queued: the loaded
    /// file stops at its end, and the named file's own load will report it.
    func testANamedFileThatCannotBeReadIsNotQueued() throws {
        let file = try writeSilentFile(duration: 0.3)
        let missing = file.deletingLastPathComponent().appendingPathComponent("missing.wav")
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        let events = PlaybackEvents(observing: playback)
        XCTAssertTrue(playback.load(url: file))
        XCTAssertTrue(playback.play())

        playback.setFileAfterCurrent(missing)

        XCTAssertEqual((playback._playerForTesting as? AVQueuePlayer)?.items().count, 1)
        XCTAssertTrue(eventually { events.finishedCount == 1 }, "The file never finished")
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(playback.loadedURL?.lastPathComponent, "chapter.wav")
        XCTAssertEqual(events.failures, [])
    }

    /// Loading another file forgets the file named to follow the one before.
    func testLoadingAnotherFileForgetsTheNamedOne() throws {
        let first = try writeSilentFile(named: "first.wav", duration: 0.3)
        let second = try writeSilentFile(named: "second.wav", duration: 0.3)
        let third = try writeSilentFile(named: "third.wav", duration: 0.3)
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        let events = PlaybackEvents(observing: playback)
        XCTAssertTrue(playback.load(url: first))
        XCTAssertTrue(playback.play())
        playback.setFileAfterCurrent(second)

        XCTAssertTrue(playback.load(url: third))
        XCTAssertTrue(playback.play())

        XCTAssertEqual((playback._playerForTesting as? AVQueuePlayer)?.items().count, 1)
        XCTAssertTrue(eventually { events.finishedCount == 1 }, "The third file never finished")
        XCTAssertEqual(playback.loadedURL?.lastPathComponent, "third.wav")
        XCTAssertTrue(playback._playerForTesting?.currentItem === playback._playerItemForTesting)
    }

    /// Loading the loaded file again, which keeps its player, as the next
    /// chapter of a file with chapter marks does, forgets the file named to
    /// follow it too, and so does a clip end.
    func testReloadingTheFileOrSettingAClipEndForgetsTheNamedOne() throws {
        let first = try writeSilentFile(named: "first.wav", duration: 0.6)
        let second = try writeSilentFile(named: "second.wav", duration: 0.3)
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        XCTAssertTrue(playback.load(url: first))
        XCTAssertTrue(playback.play())
        let player = try XCTUnwrap(playback._playerForTesting as? AVQueuePlayer)

        playback.setFileAfterCurrent(second)
        XCTAssertTrue(playback.load(url: first))
        XCTAssertTrue(playback._playerForTesting === player)
        XCTAssertEqual(player.items().count, 1, "Reloading the file kept the named one")

        playback.setFileAfterCurrent(second)
        playback.setClipEndTime(0.2)
        XCTAssertEqual(player.items().count, 1, "A clip end kept the named file")
        XCTAssertEqual(player.actionAtItemEnd, .pause)
    }

    /// A seek in the loaded file made once it has played to its end and the
    /// player is moving on into the named file, before that end is acted on,
    /// starts the loaded file again on a new player, rather than trust the
    /// moving queue: that end then ends nothing, the named file is
    /// forgotten, and the loaded file plays on from the seek and finishes
    /// once.
    func testASeekAsTheFileRollsOnStartsTheLoadedFileAgain() throws {
        let first = try writeSilentFile(named: "first.wav", duration: 0.4)
        let second = try writeSilentFile(named: "second.wav", duration: 2)
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        let events = PlaybackEvents(observing: playback)
        let reports = PlayerReportLog(observing: playback)
        XCTAssertTrue(playback.load(url: first))
        XCTAssertTrue(playback.play())
        playback.setFileAfterCurrent(second)
        var hasSought = false
        playback._endNoticeArrivedForTesting = { [unowned playback] in
            guard !hasSought else { return }
            hasSought = true
            playback.seek(to: 0.1)
        }

        XCTAssertTrue(eventually { reports.endOfFileOutcomes.count == 2 }, "The loaded file never reached its end again")
        XCTAssertEqual(reports.endOfFileOutcomes, [.postedDuringEarlierPlay, .endedPlay])
        XCTAssertEqual(events.finishedCount, 1)
        XCTAssertEqual(playback.loadedURL?.lastPathComponent, "first.wav")
        XCTAssertTrue(playback._playerForTesting?.currentItem === playback._playerItemForTesting)
    }

    /// A pause made as the loaded file's end is acted on, with the player
    /// moving on into the named file, holds that end until playback resumes.
    /// Resuming reports the end once, and the named file, loaded then and
    /// played from its start, plays on, on the same player, to an end of its
    /// own.
    func testAPauseAsTheFileRollsOnHoldsTheEndUntilResume() throws {
        let first = try writeSilentFile(named: "first.wav", duration: 0.4)
        let second = try writeSilentFile(named: "second.wav", duration: 0.4)
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        let reports = PlayerReportLog(observing: playback)
        var finishedCount = 0
        playback.onPlaybackFinished = { [unowned playback] in
            finishedCount += 1
            guard finishedCount == 1 else { return }
            XCTAssertTrue(playback.load(url: second))
            XCTAssertTrue(playback.play(fromTime: 0))
        }
        XCTAssertTrue(playback.load(url: first))
        XCTAssertTrue(playback.play())
        playback.setFileAfterCurrent(second)
        let player = try XCTUnwrap(playback._playerForTesting)
        var hasPaused = false
        playback._endNoticeArrivedForTesting = { [unowned playback] in
            guard !hasPaused else { return }
            hasPaused = true
            playback.pause()
        }

        XCTAssertTrue(eventually { reports.endOfFileOutcomes == [.heldUntilResume] }, "The first file's end was never held")
        XCTAssertEqual(finishedCount, 0, "Paused playback finished")
        XCTAssertTrue(playback.isPaused)

        XCTAssertTrue(playback.resume())
        XCTAssertTrue(eventually { finishedCount == 1 }, "Resuming never finished the first file's play")
        XCTAssertEqual(playback.loadedURL?.lastPathComponent, "second.wav")
        XCTAssertTrue(playback.isPlaying)
        XCTAssertFalse(playback.isPaused)
        XCTAssertTrue(playback._playerForTesting === player)
        XCTAssertTrue(eventually { finishedCount == 2 }, "The file that followed never finished")
    }

    /// How long the next file's clock takes to move once the loaded file's
    /// end is reported and the next file is loaded and played, as the reader
    /// starts the next chapter: on a new player, as without a named file,
    /// and rolling on, with one (TODO PERF09). One line beginning
    /// `PERF09_BENCHMARK` carries the milliseconds of five changes each as
    /// JSON. Opt-in, since it times real playback: set
    /// TEXTMOUTH_TRACK_CHANGE_BENCHMARK=1, or for xcodebuild
    /// TEST_RUNNER_TEXTMOUTH_TRACK_CHANGE_BENCHMARK=1. The files are silent,
    /// and the callbacks only record what the test polls for.
    func testTrackChangeBenchmark() throws {
        let variable = "TEXTMOUTH_TRACK_CHANGE_BENCHMARK"
        guard ProcessInfo.processInfo.environment[variable] == "1" else {
            throw XCTSkip("Set \(variable)=1 (for xcodebuild, TEST_RUNNER_\(variable)=1) to time track changes")
        }
        var report: [String: [Double]] = [:]
        for namesTheNextFile in [false, true] {
            var gaps: [Double] = []
            for change in 0..<5 {
                let first = try writeSilentFile(named: "first-\(change).wav", duration: 0.4)
                let second = try writeSilentFile(named: "second-\(change).wav", duration: 1)
                let playback = AudioPlaybackService()
                defer { playback.stop() }
                var endReportedAt: ContinuousClock.Instant?
                var nextFileTimeThen: TimeInterval = 0
                playback.onPlaybackFinished = { [unowned playback] in
                    guard endReportedAt == nil else { return }
                    endReportedAt = .now
                    _ = playback.load(url: second)
                    nextFileTimeThen = playback._playerItemForTesting.map { CMTimeGetSeconds($0.currentTime()) } ?? 0
                    _ = playback.play(fromTime: 0)
                }
                XCTAssertTrue(playback.load(url: first))
                XCTAssertTrue(playback.play())
                if namesTheNextFile {
                    playback.setFileAfterCurrent(second)
                }
                XCTAssertTrue(eventually { endReportedAt != nil }, "The first file never finished")
                // The next file's clock moves once its time passes where it stood.
                let moved = eventually(within: 2) {
                    (playback._playerItemForTesting.map { CMTimeGetSeconds($0.currentTime()) } ?? 0) > nextFileTimeThen + 0.001
                }
                XCTAssertTrue(moved, "The next file's clock never moved")
                if let endReportedAt {
                    let elapsed = endReportedAt.duration(to: .now)
                    gaps.append((Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15).rounded())
                }
            }
            report[namesTheNextFile ? "rollingOnMilliseconds" : "newPlayerMilliseconds"] = gaps
        }
        let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("PERF09_BENCHMARK \(String(decoding: json, as: UTF8.self))")
    }

    /// Stop releases the player, the loaded file's item, and the file named
    /// to follow, which the reader's close relies on.
    func testStopReleasesThePlayerAndTheNamedFile() throws {
        let first = try writeSilentFile(named: "first.wav", duration: 0.5)
        let second = try writeSilentFile(named: "second.wav", duration: 0.5)
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        XCTAssertTrue(playback.load(url: first))
        XCTAssertTrue(playback.play())
        playback.setFileAfterCurrent(second)
        XCTAssertEqual((playback._playerForTesting as? AVQueuePlayer)?.items().count, 2)

        playback.stop()

        XCTAssertNil(playback._playerForTesting)
        XCTAssertNil(playback._playerItemForTesting)
        XCTAssertNil(playback.loadedURL)
    }

    // MARK: - The Speech Service's Synthesizer Callbacks

    /// An utterance a synthesizer callback holds for the main queue keeps its
    /// identity its own: however many utterances are made and released
    /// meanwhile, none takes its identifier, and it is released only with
    /// its holder.
    func testAHeldReportedUtteranceKeepsItsIdentityItsOwn() {
        var reported: ReportedUtterance?
        weak var heldUtterance: AVSpeechUtterance?
        autoreleasepool {
            reported = ReportedUtterance(utterance: AVSpeechUtterance(string: "Mooring lines are fast."))
            heldUtterance = reported?.utterance
        }
        let reportedID = try? XCTUnwrap(reported?.id)

        let laterIDs = autoreleasepool {
            (0..<500).map { _ in ObjectIdentifier(AVSpeechUtterance(string: "Cast off.")) }
        }

        XCTAssertNotNil(heldUtterance, "The held utterance was released")
        XCTAssertFalse(laterIDs.contains { $0 == reportedID }, "A later utterance took the held one's identity")
        autoreleasepool { reported = nil }
        XCTAssertNil(heldUtterance, "The utterance outlived its holder")
    }

    /// A finish reported for an utterance that is not the one speaking, such
    /// as one stopped by a seek, moves nothing.
    func testFinishOfAnUtteranceNoLongerSpeakingIsIgnored() {
        let speech = SpeechService(userDefaults: makeSandboxedPreferences("finished-utterances"))
        var finishedCount = 0
        speech.onUtteranceFinished = { finishedCount += 1 }

        speech.speechSynthesizer(AVSpeechSynthesizer(), didFinish: AVSpeechUtterance(string: "Already stopped."))
        handleQueuedCallbacks()

        XCTAssertEqual(finishedCount, 0)
    }

    /// A word reported for the utterance speaking moves the cursor to the
    /// word's place in the whole text, counted from where that utterance
    /// starts. A word reported for another utterance, such as one a seek
    /// stopped, moves nothing, and neither does a word of the utterance
    /// speaking when a seek replaces it before the word is handled.
    func testAWordMovesTheCursorOnlyForTheUtteranceSpeaking() {
        let live = AVSpeechUtterance(string: "Mooring lines are fast.")
        let speech = makeDirectSpeech(speaking: live, from: 100)
        defer { speech.stop() }
        var words: [String] = []
        speech.onWordSpoken = { _, word in words.append(word) }

        speech.speechSynthesizer(
            AVSpeechSynthesizer(),
            willSpeakRangeOfSpeechString: NSRange(location: 0, length: 4),
            utterance: AVSpeechUtterance(string: "Cast off.")
        )
        handleQueuedCallbacks()
        XCTAssertEqual(words, [])
        XCTAssertNil(speech.currentWordRange)

        speech.speechSynthesizer(
            AVSpeechSynthesizer(),
            willSpeakRangeOfSpeechString: NSRange(location: 8, length: 5),
            utterance: live
        )
        handleQueuedCallbacks()
        XCTAssertEqual(words, ["lines"])
        XCTAssertEqual(speech.currentWordRange, NSRange(location: 108, length: 5))

        speech.speechSynthesizer(
            AVSpeechSynthesizer(),
            willSpeakRangeOfSpeechString: NSRange(location: 18, length: 4),
            utterance: live
        )
        speech._adoptLiveDirectUtteranceForTesting(AVSpeechUtterance(string: "Fenders out."), baseOffset: 300)
        handleQueuedCallbacks()
        XCTAssertEqual(words, ["lines"])
        XCTAssertEqual(speech.currentWordRange, NSRange(location: 108, length: 5))
    }

    /// The synthesizer may call back on a thread of its own while the main
    /// queue changes which utterance is speaking, so nothing about a word is
    /// decided where it is reported: the main queue places it by what it
    /// knows when it handles the report. A word reported before its
    /// utterance was the one speaking, and handled once it was, moves the
    /// cursor from where that utterance starts; a word of the utterance
    /// speaking, handled once a seek replaced it, moves nothing.
    func testAWordReportedOffTheMainThreadIsPlacedWhenTheMainQueueHandlesIt() {
        let speech = SpeechService(userDefaults: makeSandboxedPreferences("synthesizer-thread"))
        defer { speech.stop() }
        var words: [String] = []
        speech.onWordSpoken = { _, word in words.append(word) }
        let spoken = ReportedUtterance(utterance: AVSpeechUtterance(string: "Mooring lines are fast."))

        reportWordOffTheMainThread(NSRange(location: 8, length: 5), of: spoken, to: speech)
        speech._adoptLiveDirectUtteranceForTesting(spoken.utterance, baseOffset: 100)
        handleQueuedCallbacks()
        XCTAssertEqual(words, ["lines"])
        XCTAssertEqual(speech.currentWordRange, NSRange(location: 108, length: 5))

        reportWordOffTheMainThread(NSRange(location: 18, length: 4), of: spoken, to: speech)
        speech._adoptLiveDirectUtteranceForTesting(AVSpeechUtterance(string: "Fenders out."), baseOffset: 300)
        handleQueuedCallbacks()
        XCTAssertEqual(words, ["lines"])
        XCTAssertEqual(speech.currentWordRange, NSRange(location: 108, length: 5))
    }

    /// The start of the utterance speaking marks speech as playing and not
    /// paused; the start of another utterance changes nothing.
    func testAStartCountsOnlyForTheUtteranceSpeaking() {
        let live = AVSpeechUtterance(string: "Mooring lines are fast.")
        let speech = makeDirectSpeech(speaking: live)
        // Stopped at once: a started utterance arms the direct-speech
        // watchdog, which would look at the idle synthesizer in a second.
        defer { speech.stop() }
        speech.isSpeaking = false
        speech.isPaused = true

        speech.speechSynthesizer(AVSpeechSynthesizer(), didStart: AVSpeechUtterance(string: "Cast off."))
        handleQueuedCallbacks()
        XCTAssertFalse(speech.isSpeaking)
        XCTAssertTrue(speech.isPaused)

        speech.speechSynthesizer(AVSpeechSynthesizer(), didStart: live)
        handleQueuedCallbacks()
        XCTAssertTrue(speech.isSpeaking)
        XCTAssertFalse(speech.isPaused)
    }

    /// A pause of the utterance speaking marks speech as paused; a pause of
    /// another utterance changes nothing.
    func testAPauseCountsOnlyForTheUtteranceSpeaking() {
        let live = AVSpeechUtterance(string: "Mooring lines are fast.")
        let speech = makeDirectSpeech(speaking: live)
        defer { speech.stop() }
        speech.isSpeaking = true
        speech.isPaused = false

        speech.speechSynthesizer(AVSpeechSynthesizer(), didPause: AVSpeechUtterance(string: "Cast off."))
        handleQueuedCallbacks()
        XCTAssertFalse(speech.isPaused)

        speech.speechSynthesizer(AVSpeechSynthesizer(), didPause: live)
        handleQueuedCallbacks()
        XCTAssertTrue(speech.isPaused)
        XCTAssertTrue(speech.isSpeaking)
    }

    /// The utterance speaking, continued after a pause, marks speech as no
    /// longer paused; another utterance continuing changes nothing.
    func testAContinueCountsOnlyForTheUtteranceSpeaking() {
        let live = AVSpeechUtterance(string: "Mooring lines are fast.")
        let speech = makeDirectSpeech(speaking: live)
        defer { speech.stop() }
        speech.isSpeaking = true
        speech.isPaused = true

        speech.speechSynthesizer(AVSpeechSynthesizer(), didContinue: AVSpeechUtterance(string: "Cast off."))
        handleQueuedCallbacks()
        XCTAssertTrue(speech.isPaused)

        speech.speechSynthesizer(AVSpeechSynthesizer(), didContinue: live)
        handleQueuedCallbacks()
        XCTAssertFalse(speech.isPaused)
        XCTAssertTrue(speech.isSpeaking)
    }

    /// The utterance speaking, cancelled while speech should be playing, is
    /// logged as an unexpected cancel, after which speech speaks again on a
    /// fresh synthesizer (`SpeechDirectChunkingTests`), or, with no text to
    /// speak again as here, ends where it was without ending the chapter;
    /// another utterance's cancel, such as one a seek stopped, is expected
    /// and changes nothing.
    func testACancelIsUnexpectedOnlyForTheUtteranceSpeaking() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        // The expected cancel is a trace line.
        setAppTracing(true)
        let live = AVSpeechUtterance(string: "Mooring lines are fast.")
        let speech = makeDirectSpeech(speaking: live)
        defer { speech.stop() }
        var finishedCount = 0
        speech.onUtteranceFinished = { finishedCount += 1 }
        speech.isSpeaking = true
        speech.isPaused = false

        let staleLines = logLines(in: .speechTransitions) {
            speech.speechSynthesizer(AVSpeechSynthesizer(), didCancel: AVSpeechUtterance(string: "Cast off."))
            handleQueuedCallbacks()
        }
        let liveLines = logLines(in: .speechTransitions) {
            speech.speechSynthesizer(AVSpeechSynthesizer(), didCancel: live)
            handleQueuedCallbacks()
        }

        XCTAssertTrue(
            staleLines.contains { $0.contains("DIRECT_CANCEL_EXPECTED:") && $0.contains("current=false") },
            "\(staleLines)"
        )
        XCTAssertFalse(staleLines.contains { $0.contains("DIRECT_CANCEL_UNEXPECTED") }, "\(staleLines)")
        XCTAssertTrue(liveLines.contains { $0.contains("DIRECT_CANCEL_UNEXPECTED:") }, "\(liveLines)")
        XCTAssertTrue(liveLines.contains { $0.contains("DIRECT_RETRY_FAILED:") }, "\(liveLines)")
        XCTAssertEqual(finishedCount, 0)
        XCTAssertFalse(speech.isSpeaking, "with no text to speak again, speech ends")
        XCTAssertFalse(speech.isPaused)
    }

    /// A speech service with preferences of its own, speaking `live` directly
    /// from `baseOffset` of its text as far as its callbacks can tell, though
    /// nothing is heard (`_adoptLiveDirectUtteranceForTesting`).
    private func makeDirectSpeech(speaking live: AVSpeechUtterance, from baseOffset: Int = 0) -> SpeechService {
        let speech = SpeechService(userDefaults: makeSandboxedPreferences("synthesizer-callbacks"))
        speech._adoptLiveDirectUtteranceForTesting(live, baseOffset: baseOffset)
        return speech
    }

    /// Returns once the main queue has run every block queued on it so far:
    /// the speech service handles each of the synthesizer's callbacks there,
    /// and a block queued after a callback runs only once it has been.
    private func handleQueuedCallbacks(file: StaticString = #filePath, line: UInt = #line) {
        var handled = false
        DispatchQueue.main.async { handled = true }
        XCTAssertTrue(eventually { handled }, "The callbacks were never handled", file: file, line: line)
    }

    /// Tell `speech`, on a thread other than the main thread, as the
    /// synthesizer may, that it will speak `range` of `spoken`'s utterance.
    /// Returns once the report is made but before the main queue has handled
    /// what the report queued there: a semaphore, unlike an expectation,
    /// never runs the main queue while the main thread waits on it.
    private func reportWordOffTheMainThread(
        _ range: NSRange,
        of spoken: ReportedUtterance,
        to speech: SpeechService,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reported = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            speech.speechSynthesizer(
                AVSpeechSynthesizer(),
                willSpeakRangeOfSpeechString: range,
                utterance: spoken.utterance
            )
            reported.signal()
        }
        XCTAssertEqual(
            reported.wait(timeout: .now() + 5),
            .success,
            "The synthesizer's report never returned",
            file: file,
            line: line
        )
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

    /// How many ticks of the loaded player's position observer the service
    /// has dealt with.
    var tickCount: Int {
        reports.filter { report in
            guard case .tick = report else { return false }
            return true
        }.count
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

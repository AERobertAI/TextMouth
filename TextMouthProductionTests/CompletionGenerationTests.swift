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

    /// Whether a tick of the current player found it at least `seconds`
    /// into its file, give or take a millisecond.
    func handledTick(atOrAfter seconds: TimeInterval) -> Bool {
        reports.contains { report in
            guard case .tick(let tickSeconds, _) = report else { return false }
            return tickSeconds >= seconds - 0.001
        }
    }
}

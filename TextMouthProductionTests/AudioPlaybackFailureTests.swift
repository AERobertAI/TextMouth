import AVFoundation
import XCTest
@testable import TextMouth

/// How `AudioPlaybackService` reports files it cannot play: through
/// `failure` and `onPlaybackFailed`, never by claiming to play, and never
/// through `onPlaybackFinished`. Every file is written into a folder of the
/// test's own under the temporary directory.
@MainActor
final class AudioPlaybackFailureTests: XCTestCase {
    // MARK: - Checking the file before playing

    /// A missing track is reported before `load` returns, and Play never
    /// claims to play it.
    func testMissingFileIsReportedBeforeLoadReturns() throws {
        try withFixtureDirectory { directory in
            let playback = AudioPlaybackService()
            let events = PlaybackEvents(observing: playback)
            let url = directory.appendingPathComponent("03.mp3")

            XCTAssertFalse(playback.load(url: url))

            // The service names the file as it loads it: standardized.
            XCTAssertEqual(events.failures, [
                AudioPlaybackFailure(reason: .fileMissing, url: url.standardizedFileURL)
            ])
            XCTAssertEqual(playback.failure, events.failures.first)
            XCTAssertFalse(playback.play(fromTime: 0))
            XCTAssertFalse(playback.resume())
            XCTAssertFalse(playback.isPlaying)
            XCTAssertFalse(playback.isPaused)
            // Nothing more arrives later: no duplicate report, no finish.
            spinMainRunLoop(for: 0.2)
            XCTAssertEqual(events.failures.count, 1)
            XCTAssertEqual(events.finishedCount, 0)
        }
    }

    /// A folder is not a track, whatever its name says.
    func testFolderWithAnAudioNameIsReportedUnreadable() throws {
        try withFixtureDirectory { directory in
            let playback = AudioPlaybackService()
            let events = PlaybackEvents(observing: playback)
            let url = directory.appendingPathComponent("04.mp3", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

            XCTAssertFalse(playback.load(url: url))

            XCTAssertEqual(events.failures.map(\.reason), [.fileUnreadable])
            XCTAssertEqual(events.failures.first?.fileName, "04.mp3")
            XCTAssertFalse(playback.play())
            XCTAssertFalse(playback.isPlaying)
        }
    }

    /// A track TextMouth may not read is reported at once, not left for
    /// AVFoundation to fail on later.
    func testFileWithoutReadPermissionIsReportedUnreadable() throws {
        try withFixtureDirectory { directory in
            let url = directory.appendingPathComponent("05.wav")
            try AudioTestFixtures.writeSilence(to: url)
            let fileManager = FileManager.default
            try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
            // Give the permission back so the folder can be removed.
            defer { try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
            let playback = AudioPlaybackService()
            let events = PlaybackEvents(observing: playback)

            XCTAssertFalse(playback.load(url: url))

            XCTAssertEqual(events.failures.map(\.reason), [.fileUnreadable])
            XCTAssertFalse(playback.isPlaying)
        }
    }

    /// A symbolic link is judged by what it leads to: a link to a real track
    /// plays, and a link whose track is gone is a missing file.
    func testSymbolicLinksAreJudgedByTheirTarget() throws {
        try withFixtureDirectory { directory in
            let track = directory.appendingPathComponent("06.wav")
            try AudioTestFixtures.writeSilence(to: track)
            let link = directory.appendingPathComponent("link.wav")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: track)

            XCTAssertNil(AudioPlaybackService.fileProblem(at: link))

            try FileManager.default.removeItem(at: track)
            XCTAssertEqual(AudioPlaybackService.fileProblem(at: link), .fileMissing)
        }
    }

    /// Loading a playable file clears the failure an earlier file left.
    func testSuccessfulLoadClearsTheEarlierFailure() throws {
        try withFixtureDirectory { directory in
            let playback = AudioPlaybackService()
            defer { playback.stop() }
            let track = directory.appendingPathComponent("07.wav")
            try AudioTestFixtures.writeSilence(to: track)

            playback.load(url: directory.appendingPathComponent("missing.wav"))
            XCTAssertNotNil(playback.failure)

            XCTAssertTrue(playback.load(url: track))

            XCTAssertNil(playback.failure)
        }
    }

    // MARK: - Failures AVFoundation reports

    /// A file that passes the check but holds no audio fails once
    /// AVFoundation tries to open it: reported asynchronously as unreadable,
    /// once, with AVFoundation's error, leaving nothing playing.
    func testNonAudioFileWithAnAudioNameFailsAsynchronously() throws {
        try withFixtureDirectory { directory in
            let playback = AudioPlaybackService()
            defer { playback.stop() }
            let events = PlaybackEvents(observing: playback)
            let url = directory.appendingPathComponent("05.mp3")
            try AudioTestFixtures.writeNonAudioBytes(to: url)
            let failed = expectation(description: "Failure reported")
            events.failureExpectation = failed

            XCTAssertTrue(playback.load(url: url))
            // Play may already find the item failed and report it at once;
            // either way the failure comes through the same channel.
            playback.play()
            wait(for: [failed], timeout: 10)

            let failure = try XCTUnwrap(events.failures.first)
            XCTAssertEqual(failure.reason, .fileUnreadable)
            XCTAssertEqual(failure.url, url.standardizedFileURL)
            XCTAssertNotNil(failure.underlyingError)
            XCTAssertEqual(playback.failure, failure)
            XCTAssertFalse(playback.isPlaying)
            XCTAssertFalse(playback.isPaused)
            XCTAssertFalse(playback.resume())
            // The item's other failure signals, if any, are not reported again.
            spinMainRunLoop(for: 0.3)
            XCTAssertEqual(events.failures.count, 1)
            XCTAssertEqual(events.finishedCount, 0)
        }
    }

    /// Play pressed after the item failed, but before the service's own
    /// observation of the failure reached the main queue, does not play:
    /// Play reports the failure itself, and it is reported once.
    func testPlayReportsAnItemThatHasAlreadyFailed() throws {
        try withFixtureDirectory { directory in
            let playback = AudioPlaybackService()
            defer { playback.stop() }
            let events = PlaybackEvents(observing: playback)
            let url = directory.appendingPathComponent("05.mp3")
            try AudioTestFixtures.writeNonAudioBytes(to: url)
            XCTAssertTrue(playback.load(url: url))
            let item = try XCTUnwrap(playback._playerItemForTesting)
            // AVFoundation changes the status on the main thread and tells
            // observers at once; the service's observer only queues its
            // handling. Pressing Play from this observer lands in between.
            let playResult = PlayResult()
            let pressPlayWhenFailed = item.observe(\.status) { item, _ in
                guard item.status == .failed, Thread.isMainThread, playResult.started == nil else { return }
                playResult.started = playback.play()
                playResult.failuresReportedByPlay = MainActor.assumeIsolated { events.failures.count }
            }
            defer { pressPlayWhenFailed.invalidate() }

            XCTAssertTrue(eventually { playResult.started != nil }, "Item never failed on the main thread")

            XCTAssertEqual(playResult.started, false)
            XCTAssertEqual(playResult.failuresReportedByPlay, 1)
            XCTAssertEqual(events.failures.map(\.reason), [.fileUnreadable])
            XCTAssertFalse(playback.isPlaying)
            // The service's own observation, arriving afterwards, finds the
            // failed item already released.
            spinMainRunLoop(for: 0.3)
            XCTAssertEqual(events.failures.count, 1)
        }
    }

    /// A playable file still plays: its item becomes ready, nothing fails,
    /// and it plays until stopped.
    func testPlayableFileBecomesReadyAndPlaysUntilStopped() throws {
        try withFixtureDirectory { directory in
            let playback = AudioPlaybackService()
            let events = PlaybackEvents(observing: playback)
            let url = directory.appendingPathComponent("06.wav")
            try AudioTestFixtures.writeSilence(to: url, duration: 3)

            XCTAssertTrue(playback.load(url: url))
            XCTAssertTrue(playback.play())
            XCTAssertTrue(playback.isPlaying)
            XCTAssertTrue(eventually { playback._playerItemForTesting?.status == .readyToPlay })
            XCTAssertTrue(playback.isPlaying)

            playback.stop()

            XCTAssertFalse(playback.isPlaying)
            spinMainRunLoop(for: 0.3)
            XCTAssertNil(playback.failure)
            XCTAssertEqual(events.failures, [])
            XCTAssertEqual(events.finishedCount, 0)
        }
    }

    /// A file that fails partway through is reported with AVFoundation's
    /// error. Playback halts where it was, without finishing the file.
    func testFailureToPlayToTheEndKeepsThePositionAndNeverFinishes() throws {
        try withFixtureDirectory { directory in
            let playback = AudioPlaybackService()
            defer { playback.stop() }
            let events = PlaybackEvents(observing: playback)
            let url = directory.appendingPathComponent("07.wav")
            try AudioTestFixtures.writeSilence(to: url, duration: 3)
            XCTAssertTrue(playback.load(url: url))
            XCTAssertTrue(playback.play(fromTime: 0.5))
            let item = try XCTUnwrap(playback._playerItemForTesting)
            waitUntilReady(item)
            let readError = NSError(domain: NSOSStatusErrorDomain, code: -12_345)

            NotificationCenter.default.post(
                name: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                userInfo: [AVPlayerItemFailedToPlayToEndTimeErrorKey: readError]
            )
            XCTAssertTrue(eventually { !events.failures.isEmpty })

            let failure = try XCTUnwrap(events.failures.first)
            XCTAssertEqual(failure.reason, .failedDuringPlayback)
            XCTAssertEqual(failure.underlyingError, readError)
            XCTAssertFalse(playback.isPlaying)
            XCTAssertFalse(playback.isPaused)
            // Halting kept the position the file failed at, near where it
            // started, and nothing moves it or finishes the file afterwards.
            let positionAtFailure = try XCTUnwrap(events.currentTimesAtFailures.first)
            XCTAssertGreaterThanOrEqual(positionAtFailure, 0.5)
            spinMainRunLoop(for: 0.5)
            XCTAssertEqual(playback.currentTime, positionAtFailure)
            XCTAssertEqual(events.failures.count, 1)
            XCTAssertEqual(events.finishedCount, 0)
        }
    }

    /// A track deleted while it plays is reported as missing, whatever
    /// error AVFoundation gives, because the file is checked again.
    func testTrackDeletedDuringPlaybackIsReportedMissing() throws {
        try withFixtureDirectory { directory in
            let playback = AudioPlaybackService()
            defer { playback.stop() }
            let events = PlaybackEvents(observing: playback)
            let url = directory.appendingPathComponent("08.wav")
            try AudioTestFixtures.writeSilence(to: url, duration: 3)
            XCTAssertTrue(playback.load(url: url))
            XCTAssertTrue(playback.play())
            let item = try XCTUnwrap(playback._playerItemForTesting)
            waitUntilReady(item)

            try FileManager.default.removeItem(at: url)
            NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: item)
            XCTAssertTrue(eventually { !events.failures.isEmpty })

            XCTAssertEqual(events.failures.map(\.reason), [.fileMissing])
            XCTAssertFalse(playback.isPlaying)
        }
    }

    /// An item that `load` has replaced can no longer report anything.
    func testReplacedItemCannotReportAFailure() throws {
        try withFixtureDirectory { directory in
            let playback = AudioPlaybackService()
            defer { playback.stop() }
            let events = PlaybackEvents(observing: playback)
            let first = directory.appendingPathComponent("09.wav")
            let second = directory.appendingPathComponent("10.wav")
            try AudioTestFixtures.writeSilence(to: first)
            try AudioTestFixtures.writeSilence(to: second)
            XCTAssertTrue(playback.load(url: first))
            let replacedItem = try XCTUnwrap(playback._playerItemForTesting)
            XCTAssertTrue(playback.load(url: second))

            NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: replacedItem)
            spinMainRunLoop(for: 0.3)

            XCTAssertEqual(events.failures, [])
            XCTAssertNil(playback.failure)
            XCTAssertEqual(playback.loadedURL, second.standardizedFileURL)
        }
    }

    /// An AVFoundation error is classified by the file first, then by
    /// whether the item ever became ready to play.
    func testPlaybackErrorsAreClassifiedByTheFileThenByReadiness() {
        let reason = AudioPlaybackFailure.reasonForPlaybackError
        XCTAssertEqual(reason(.fileMissing, true), .fileMissing)
        XCTAssertEqual(reason(.fileMissing, false), .fileMissing)
        XCTAssertEqual(reason(.fileUnreadable, true), .fileUnreadable)
        XCTAssertEqual(reason(nil, false), .fileUnreadable)
        XCTAssertEqual(reason(nil, true), .failedDuringPlayback)
    }

    // MARK: - Wording

    /// Every failure names its file, by name alone, in a sentence fit to be
    /// spoken.
    func testFailureMessagesNameTheFileByItsName() {
        let url = URL(fileURLWithPath: "/Library/Book.tmb/Tracks/03.mp3")
        let expected: [(reason: AudioPlaybackFailure.Reason, problem: String, message: String)] = [
            (.fileMissing,
             "the file 03.mp3 is missing",
             "The file 03.mp3 is missing."),
            (.fileUnreadable,
             "the file 03.mp3 is damaged, unreadable, or not an audio file",
             "The file 03.mp3 is damaged, unreadable, or not an audio file."),
            (.failedDuringPlayback,
             "the file 03.mp3 failed partway through",
             "The file 03.mp3 failed partway through."),
            (.stalled,
             "the file 03.mp3 could not be read quickly enough",
             "The file 03.mp3 could not be read quickly enough."),
        ]
        for (reason, problem, message) in expected {
            let failure = AudioPlaybackFailure(reason: reason, url: url)
            XCTAssertEqual(failure.fileName, "03.mp3")
            XCTAssertEqual(failure.problem, problem)
            XCTAssertEqual(failure.message, message)
        }
    }

    // MARK: - Helpers

    /// Run `body` with a new, empty folder that is removed afterwards.
    private func withFixtureDirectory(_ body: (URL) throws -> Void) throws {
        let directory = try AudioTestFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    /// Let queued main-queue work, such as AVFoundation observations, run.
    private func spinMainRunLoop(for interval: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    /// Run the main run loop until `condition` holds or `timeout` passes.
    ///
    /// - Returns: Whether `condition` came to hold.
    private func eventually(within timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            spinMainRunLoop(for: 0.01)
        }
        return condition()
    }

    /// Wait until `item` is ready to play and the service has seen it
    /// become ready: its status observation reaches the main queue just
    /// after the status itself changes.
    private func waitUntilReady(_ item: AVPlayerItem) {
        XCTAssertTrue(eventually { item.status == .readyToPlay }, "Item never became ready")
        spinMainRunLoop(for: 0.1)
    }
}

/// What pressing Play from a key-value observer found. Written and read on
/// the main thread only; the observer's closure must be `Sendable`.
private final class PlayResult: @unchecked Sendable {
    /// What `play()` returned, or nil before Play was pressed.
    var started: Bool?
    /// How many failures had been reported when `play()` returned.
    var failuresReportedByPlay: Int?
}

/// Everything a playback service reported through its callbacks, in order.
@MainActor
final class PlaybackEvents {
    /// Every failure `onPlaybackFailed` delivered.
    private(set) var failures: [AudioPlaybackFailure] = []
    /// The service's `currentTime` as each failure arrived.
    private(set) var currentTimesAtFailures: [TimeInterval] = []
    /// How many times `onPlaybackFinished` was called.
    private(set) var finishedCount = 0
    /// Fulfilled by the next failure, when a test is waiting for one, and
    /// then forgotten; tests count any later failures in `failures`.
    var failureExpectation: XCTestExpectation?

    /// Start recording `playback`'s failures and completions, replacing its
    /// callbacks.
    init(observing playback: AudioPlaybackService) {
        playback.onPlaybackFailed = { [unowned self, weak playback] failure in
            self.failures.append(failure)
            self.currentTimesAtFailures.append(playback?.currentTime ?? .nan)
            self.failureExpectation?.fulfill()
            self.failureExpectation = nil
        }
        playback.onPlaybackFinished = { [unowned self] in
            self.finishedCount += 1
        }
    }
}

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
}

/// Everything a playback service reported through its callbacks, in order.
@MainActor
final class PlaybackEvents {
    /// Every failure `onPlaybackFailed` delivered.
    private(set) var failures: [AudioPlaybackFailure] = []
    /// How many times `onPlaybackFinished` was called.
    private(set) var finishedCount = 0

    /// Start recording `playback`'s failures and completions, replacing its
    /// callbacks.
    init(observing playback: AudioPlaybackService) {
        playback.onPlaybackFailed = { [unowned self] failure in
            self.failures.append(failure)
        }
        playback.onPlaybackFinished = { [unowned self] in
            self.finishedCount += 1
        }
    }
}

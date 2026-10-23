import XCTest
import os
@testable import TextMouth

/// The bridge that lets synchronous parsing and analysis wait for async work
/// (TODO Q08). It replaced private copies in `BookParser` and
/// `BookContentAnalysisService`, so these tests pin what every copy did: the
/// work's own value or error comes back, only once the work has finished,
/// from a task that does not run on the waiting thread; and what the bridge
/// adds: the task runs at no lower priority than the thread waiting on it.
final class AsyncBridgeTests: XCTestCase {
    /// The folder of audio files one test writes, removed when it ends.
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try AudioTestFixtures.makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed.
        if let folder {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: - The Bridge

    /// An error equal only to itself, to show that the work's own error
    /// arrives unchanged rather than wrapped or replaced.
    private struct Refusal: Error, Equatable {
        let reason: String
    }

    /// The work's value comes back only once the work, which suspends
    /// before it returns, has finished.
    func testReturnsTheWorksValueOnceItHasFinished() throws {
        let value = try AsyncBridge.waitForResult {
            try await Task.sleep(for: .milliseconds(50))
            return "Tide tables for the outer harbour"
        }

        XCTAssertEqual(value, "Tide tables for the outer harbour")
    }

    /// The work's own error is thrown, neither wrapped nor replaced.
    func testThrowsTheWorksOwnError() {
        XCTAssertThrowsError(
            try AsyncBridge.waitForResult { () async throws -> Int in
                throw Refusal(reason: "the ferry has left")
            }
        ) { error in
            XCTAssertEqual(error as? Refusal, Refusal(reason: "the ferry has left"))
        }
    }

    /// The work runs in a detached task rather than on the waiting thread,
    /// so waiting on the main thread does not stop work that needs no actor.
    func testRunsTheWorkOffTheWaitingThread() throws {
        XCTAssertTrue(Thread.isMainThread, "Synchronous tests wait on the main thread")

        let ranOnMainThread = try AsyncBridge.waitForResult { pthread_main_np() != 0 }

        XCTAssertFalse(ranOnMainThread)
    }

    /// The work runs at the waiting thread's priority, never below the
    /// default it ran at before, so the main thread, waiting, never waits on
    /// lower-priority work, which the Thread Performance Checker reported
    /// as a priority inversion for every silent audiobook a test made
    /// (board #1581); work waited for from a background queue runs no
    /// lower than it did.
    func testTheWorkRunsNoLowerThanItsWaiter() throws {
        XCTAssertTrue(Thread.isMainThread, "Synchronous tests wait on the main thread")
        let waiting = Task.currentPriority

        let ranAt = try AsyncBridge.waitForResult { Task.currentPriority }

        XCTAssertGreaterThanOrEqual(ranAt, waiting, "the main thread waited on lower-priority work")
        XCTAssertGreaterThanOrEqual(ranAt, .medium)
        XCTAssertEqual(AsyncBridge.waitPriority(for: .high), .high)
        XCTAssertEqual(AsyncBridge.waitPriority(for: TaskPriority(rawValue: 33)), TaskPriority(rawValue: 33))
        XCTAssertEqual(AsyncBridge.waitPriority(for: .medium), .medium)
        XCTAssertEqual(AsyncBridge.waitPriority(for: .low), .medium)
        XCTAssertEqual(AsyncBridge.waitPriority(for: .background), .medium)
    }

    /// Threads that wait at the same time each get their own work's result,
    /// as the analysis queue's workers do.
    func testSimultaneousWaitsEachGetTheirOwnResult() {
        let squares = SquaresByNumber()

        DispatchQueue.concurrentPerform(iterations: 8) { number in
            let square = try? AsyncBridge.waitForResult {
                try await Task.sleep(for: .milliseconds(10))
                return number * number
            }
            // -1 marks a wait that threw, which the comparison below reports.
            squares.record(square ?? -1, for: number)
        }

        XCTAssertEqual(squares.recorded, Dictionary(uniqueKeysWithValues: (0..<8).map { ($0, $0 * $0) }))
    }

    // MARK: - The Time Limit (ST07)

    /// Work that sleeps for a minute, given a limit of a fifth of a second,
    /// ends the wait with `TimeLimitExceeded` within two seconds, and its
    /// task is cancelled: the sleep sees the cancellation.
    func testWorkThatPassesItsLimitIsAbandonedAndCancelled() throws {
        let sawCancellation = OSAllocatedUnfairLock(initialState: false)
        let started = Date()

        XCTAssertThrowsError(
            try AsyncBridge.waitForResult(timeLimit: .milliseconds(200)) { () async throws -> Int in
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    sawCancellation.withLock { $0 = true }
                    throw error
                }
                return 1
            }
        ) { error in
            XCTAssertEqual(error as? AsyncBridge.TimeLimitExceeded, AsyncBridge.TimeLimitExceeded(limit: .milliseconds(200)))
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "the wait did not end at its limit")
        // The task sees the cancellation a moment after the wait ends.
        let deadline = Date().addingTimeInterval(2)
        while !sawCancellation.withLock({ $0 }) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(sawCancellation.withLock { $0 }, "the abandoned task was not cancelled")
    }

    /// Work that returns at once gives its value under a limit, and its own
    /// error comes back unchanged.
    func testWorkInsideItsLimitGivesItsValueOrItsOwnError() {
        XCTAssertEqual(try AsyncBridge.waitForResult(timeLimit: .seconds(30)) { "Slack water" }, "Slack water")
        XCTAssertThrowsError(
            try AsyncBridge.waitForResult(timeLimit: .seconds(30)) { () async throws -> Int in
                throw Refusal(reason: "the ferry has left")
            }
        ) { error in
            XCTAssertEqual(error as? Refusal, Refusal(reason: "the ferry has left"))
        }
    }

    /// A limit and a cancellation together: the work's value comes back when
    /// neither passes, and cancelling ends the work before the limit.
    func testALimitAndACancellationTogether() throws {
        let cancellation = ImportCancellation()
        XCTAssertEqual(
            try AsyncBridge.waitForResult(timeLimit: .seconds(30), cancelledBy: cancellation) { 7 },
            7
        )

        cancellation.cancel()
        XCTAssertThrowsError(
            try AsyncBridge.waitForResult(timeLimit: .seconds(30), cancelledBy: cancellation) { () async throws -> Int in
                try await Task.sleep(for: .seconds(60))
                return 1
            }
        ) { error in
            XCTAssertTrue(error is CancellationError, "cancelling should end the work, not the limit: \(error)")
        }
    }

    /// The sentence a passed limit gives, word for word: whole minutes when
    /// the limit is a whole number of them, else seconds, and "1 minute"
    /// in the singular.
    func testTheSentenceNamesTheLimitInWords() {
        func sentence(_ limit: Duration) -> String? {
            AsyncBridge.TimeLimitExceeded(limit: limit).errorDescription
        }

        XCTAssertEqual(sentence(.seconds(30)), "Reading the audio took longer than 30 seconds, so TextMouth stopped waiting for it.")
        XCTAssertEqual(sentence(.seconds(300)), "Reading the audio took longer than 5 minutes, so TextMouth stopped waiting for it.")
        XCTAssertEqual(sentence(.seconds(60)), "Reading the audio took longer than 1 minute, so TextMouth stopped waiting for it.")
        XCTAssertEqual(sentence(.seconds(90)), "Reading the audio took longer than 90 seconds, so TextMouth stopped waiting for it.")
        XCTAssertEqual(sentence(.seconds(1)), "Reading the audio took longer than 1 second, so TextMouth stopped waiting for it.")
    }

    /// The limits the callers use.
    func testTheCallersLimits() {
        XCTAssertEqual(AsyncBridge.audioTagsTimeLimit, .seconds(30))
        XCTAssertEqual(AsyncBridge.audioAnalysisTimeLimit, .seconds(300))
    }

    // MARK: - Its Callers

    /// `BookParser` reads an audio file through the bridge, giving what the
    /// async audio parser gives (see `AudioMediaValidationTests`).
    func testBookParserReadsAnAudioFile() throws {
        let file = folder.appendingPathComponent("Harbour Notices.wav")
        try AudioTestFixtures.writeSilence(to: file, duration: 2)

        let content = try BookParser.parse(url: file, format: .audio)

        XCTAssertEqual(content.title, "Harbour Notices")
        XCTAssertEqual(content.author, "Unknown")
        XCTAssertEqual(content.chapters.map(\.title), ["Harbour Notices"])
        XCTAssertEqual(content.chapters.map(\.text.count), [20])
    }

    /// `BookParser` throws the audio parser's own error for a file that
    /// cannot be played.
    func testBookParserThrowsTheAudioParsersOwnError() throws {
        let file = folder.appendingPathComponent("Lecture.mp3")
        try AudioTestFixtures.writePlainText(to: file)

        XCTAssertThrowsError(try BookParser.parse(url: file, format: .audio)) { error in
            XCTAssertEqual(error as? AudioParseError, .unplayableFile(file: "Lecture.mp3", problem: .cannotOpen))
        }
    }

    /// Analysis reads a single-file audio book through the bridge. Books
    /// kept as a folder of tracks take the bridge's other route, which
    /// `ContinueToNextBookTests` exercises.
    func testAnalysisReadsASingleFileAudioBook() throws {
        let file = folder.appendingPathComponent("Harbour Notices.wav")
        try AudioTestFixtures.writeSilence(to: file, duration: 2)
        // The package is never created, so analysis finds no saved index.
        let book = Book(
            title: "Harbour Notices",
            format: .audio,
            filePath: file.path,
            md5Hash: UUID().uuidString,
            tmbDirectoryName: "AsyncBridgeTests-\(UUID().uuidString).tmb"
        )

        let result = try BookContentAnalysisService.load(book: book)

        XCTAssertEqual(result.content.chapters.map(\.title), ["Harbour Notices"])
        XCTAssertNil(result.audioFilePaths)
        XCTAssertFalse(result.usedPersistedIndex)
    }
}

/// Squares recorded by several threads at once, under a lock.
private final class SquaresByNumber: @unchecked Sendable {
    private let lock = NSLock()
    private var squares: [Int: Int] = [:]

    /// Every square recorded so far, by the number squared.
    var recorded: [Int: Int] {
        lock.lock()
        defer { lock.unlock() }
        return squares
    }

    /// Records `square` as the square of `number`.
    func record(_ square: Int, for number: Int) {
        lock.lock()
        squares[number] = square
        lock.unlock()
    }
}

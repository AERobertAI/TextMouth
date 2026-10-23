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

    // MARK: - Reads Abandoned at Their Limit

    /// A read that never returns, and ignores its cancellation as
    /// AVFoundation's can, passes its limit, and its file is remembered: the
    /// next read of the same file is refused at once, with a sentence a
    /// listener understands, and never starts, so no second stuck read runs
    /// beside the first. Its limit is ten seconds, so only a refusal ends
    /// its wait in time.
    func testASecondReadOfAFileWhoseReadPassedItsLimitIsRefusedAtOnce() throws {
        let file = folder.appendingPathComponent("Fog Signals.m4b")
        try Data("never decoded".utf8).write(to: file)
        let abandoned = AsyncBridge.AbandonedReads()
        let stuck = StuckRead()
        defer { stuck.release() }

        XCTAssertThrowsError(
            try AsyncBridge.waitForResult(reading: file, timeLimit: .milliseconds(200), abandoned: abandoned) { await stuck.run() }
        ) { error in
            XCTAssertEqual(error as? AsyncBridge.TimeLimitExceeded, AsyncBridge.TimeLimitExceeded(limit: .milliseconds(200)))
        }
        XCTAssertEqual(stuck.starts, 1)

        let started = Date()
        XCTAssertThrowsError(
            try AsyncBridge.waitForResult(reading: file, timeLimit: .seconds(10), abandoned: abandoned) { await stuck.run() }
        ) { error in
            XCTAssertEqual(error as? AsyncBridge.AbandonedEarlier, AsyncBridge.AbandonedEarlier())
            XCTAssertEqual(
                error.localizedDescription,
                "TextMouth stopped reading this audio earlier because it took too long, and won't try again until TextMouth is opened again."
            )
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the second read was not refused at once")
        XCTAssertEqual(stuck.starts, 1, "a second read of the file started")
    }

    /// Only the file as the stuck read found it is refused: another file is
    /// read, a read that fails with its own error is tried again, and the
    /// same file written again since is read. A folder of tracks has no
    /// size or date of its own here, so it is known by its path alone.
    func testOnlyTheFileAsTheStuckReadFoundItIsRefused() throws {
        let file = folder.appendingPathComponent("Fog Signals.m4b")
        let other = folder.appendingPathComponent("Harbour Notices.m4b")
        try Data("never decoded".utf8).write(to: file)
        try Data("read at once".utf8).write(to: other)
        let abandoned = AsyncBridge.AbandonedReads()
        let stuck = StuckRead()
        defer { stuck.release() }
        XCTAssertThrowsError(
            try AsyncBridge.waitForResult(reading: file, timeLimit: .milliseconds(200), abandoned: abandoned) { await stuck.run() }
        )

        XCTAssertEqual(try AsyncBridge.waitForResult(reading: other, timeLimit: .seconds(10), abandoned: abandoned) { 7 }, 7)
        XCTAssertThrowsError(
            try AsyncBridge.waitForResult(reading: other, timeLimit: .seconds(10), abandoned: abandoned) { () async throws -> Int in
                throw Refusal(reason: "the ferry has left")
            }
        ) { error in
            XCTAssertEqual(error as? Refusal, Refusal(reason: "the ferry has left"))
        }
        XCTAssertEqual(try AsyncBridge.waitForResult(reading: other, timeLimit: .seconds(10), abandoned: abandoned) { 8 }, 8)
        try Data("never decoded, now written again".utf8).write(to: file)
        XCTAssertEqual(try AsyncBridge.waitForResult(reading: file, timeLimit: .seconds(10), abandoned: abandoned) { 9 }, 9)
        XCTAssertEqual(stuck.starts, 1)

        let tracks = folder.appendingPathComponent("Breakwater", isDirectory: true)
        try FileManager.default.createDirectory(at: tracks, withIntermediateDirectories: true)
        XCTAssertNil(AsyncBridge.AbandonedReads.Read(of: tracks).stamp)
        abandoned.remember(AsyncBridge.AbandonedReads.Read(of: tracks))
        try Data("a track added".utf8).write(to: tracks.appendingPathComponent("01.m4a"))
        XCTAssertTrue(abandoned.contains(AsyncBridge.AbandonedReads.Read(of: tracks)))
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

    /// The audio parser and analysis, of a file and of a folder of tracks,
    /// wait through the app's memory of abandoned reads: a file remembered
    /// there is refused at once, and not read. The files are this test's
    /// own, removed when it ends, so nothing else is ever refused for them.
    func testTheParserAndAnalysisRefuseAFileWhoseReadWasAbandoned() throws {
        let file = folder.appendingPathComponent("Harbour Notices.wav")
        try AudioTestFixtures.writeSilence(to: file, duration: 2)
        let tracks = folder.appendingPathComponent("Breakwater", isDirectory: true)
        try FileManager.default.createDirectory(at: tracks, withIntermediateDirectories: true)
        try AudioTestFixtures.writeSilence(to: tracks.appendingPathComponent("01.wav"), duration: 2)
        AsyncBridge.AbandonedReads.session.remember(AsyncBridge.AbandonedReads.Read(of: file))
        AsyncBridge.AbandonedReads.session.remember(AsyncBridge.AbandonedReads.Read(of: tracks))

        XCTAssertThrowsError(try BookParser.parse(url: file, format: .audio)) { error in
            XCTAssertEqual(error as? AsyncBridge.AbandonedEarlier, AsyncBridge.AbandonedEarlier())
        }
        // The packages are never created, so analysis finds no saved index.
        for (title, location) in [("Harbour Notices", file), ("Breakwater", tracks)] {
            let book = Book(
                title: title,
                format: .audio,
                filePath: location.path,
                md5Hash: UUID().uuidString,
                tmbDirectoryName: "AsyncBridgeTests-\(UUID().uuidString).tmb"
            )
            XCTAssertThrowsError(try BookContentAnalysisService.load(book: book), title) { error in
                XCTAssertEqual(error as? AsyncBridge.AbandonedEarlier, AsyncBridge.AbandonedEarlier(), title)
            }
        }
    }
}

/// A stand-in for an AVFoundation read that never returns and ignores its
/// task's cancellation: each run waits on a continuation that only
/// `release()` resumes, which the test calls as it ends, so no task
/// outlives it.
private final class StuckRead: Sendable {
    /// The runs started, whether they are released, and those waiting.
    private struct State: Sendable {
        var starts = 0
        var released = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// How many runs have started.
    var starts: Int {
        state.withLock { $0.starts }
    }

    /// Counts the run as started, then waits until `release()`, whatever
    /// its task's cancellation says.
    func run() async -> Int {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waits = state.withLock { current -> Bool in
                current.starts += 1
                guard !current.released else { return false }
                current.waiting.append(continuation)
                return true
            }
            if !waits {
                continuation.resume()
            }
        }
        return 0
    }

    /// Ends every run waiting, and lets any later run end at once.
    func release() {
        let waiting = state.withLock { current -> [CheckedContinuation<Void, Never>] in
            current.released = true
            let waiting = current.waiting
            current.waiting = []
            return waiting
        }
        waiting.forEach { $0.resume() }
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

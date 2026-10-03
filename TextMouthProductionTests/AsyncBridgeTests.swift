import XCTest
@testable import TextMouth

/// The bridge that lets synchronous parsing and analysis wait for async work
/// (TODO Q08). It replaced private copies in `BookParser` and
/// `BookContentAnalysisService`, so these tests pin what every copy did: the
/// work's own value or error comes back, only once the work has finished,
/// from a task that does not run on the waiting thread.
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

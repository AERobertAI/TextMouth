import XCTest
@testable import TextMouth

/// The app's one file watcher (`FileEventWatcher`, FR39 step 1), over real files in a folder of the test's own inside the
/// isolated test root. Every wait has a limit, and every folder is removed when the test ends.
@MainActor
final class FileEventWatcherTests: XCTestCase {
    // MARK: - Support

    /// What a watcher reported, and the descriptors it opened and closed.
    @MainActor
    private final class Recorder {
        var settledBursts: [DispatchSource.FileSystemEvent] = []
        var gaveUp = 0
        var opens = 0
        var closes = 0

        /// The calls to hand a watcher so that opens and closes are counted around the real ones.
        var calls: FileEventWatcher.Calls {
            let system = FileEventWatcher.Calls.system
            return FileEventWatcher.Calls(
                openForEvents: { [self] path in
                    opens += 1
                    return system.openForEvents(path)
                },
                close: { [self] descriptor in
                    closes += 1
                    system.close(descriptor)
                }
            )
        }
    }

    /// A file's place in a folder of this test's own; the folder is removed when the test ends.
    private func makeFileURL(named name: String = "watched.json") throws -> URL {
        let directory = TextMouthPaths.root.appendingPathComponent("FileEventWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent(name)
    }

    /// A started watcher of `url` that records into `recorder`, with a short quiet period and short retries so a test
    /// waits little; it is stopped when the test ends.
    private func makeWatcher(
        _ url: URL,
        _ recorder: Recorder,
        isAvailable: @escaping @MainActor () -> Bool = { true },
        retryDelays: [Duration] = [.milliseconds(20), .milliseconds(20), .milliseconds(20)],
        checksWhenAttached: Bool = false
    ) -> FileEventWatcher {
        let watcher = FileEventWatcher(
            file: { url },
            isAvailable: isAvailable,
            quietPeriod: .milliseconds(60),
            retryDelays: retryDelays,
            checksWhenAttached: checksWhenAttached,
            calls: recorder.calls,
            settled: { recorder.settledBursts.append($0) },
            gaveUp: { recorder.gaveUp += 1 }
        )
        watcher.start()
        addTeardownBlock { watcher.stop() }
        return watcher
    }

    /// Replaces the file at `url` as an editor's atomic save does: a new file is renamed over the old one.
    private func atomicSave(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    // MARK: - Settling

    /// A burst of writes reports once, after the quiet period, not once for each write.
    func testABurstOfWritesSettlesOnce() throws {
        let url = try makeFileURL()
        try Data("one".utf8).write(to: url)
        let recorder = Recorder()
        _ = makeWatcher(url, recorder)

        for index in 0..<5 { try Data("text \(index)".utf8).write(to: url) }

        XCTAssertTrue(waitUntil(timeout: 5) { !recorder.settledBursts.isEmpty })
        // Longer than the quiet period: a second report would arrive by now.
        _ = waitUntil(timeout: 0.4) { false }
        XCTAssertEqual(recorder.settledBursts.count, 1)
        XCTAssertTrue(recorder.settledBursts[0].contains(.write))
    }

    /// A newly attached file is checked once, with no events, when the watcher asks for it: an edit saved before the
    /// watcher attached reports no event of its own.
    func testANewlyAttachedFileIsCheckedWhenAskedFor() throws {
        let url = try makeFileURL()
        try Data("one".utf8).write(to: url)
        let recorder = Recorder()
        _ = makeWatcher(url, recorder, checksWhenAttached: true)

        XCTAssertTrue(waitUntil(timeout: 5) { recorder.settledBursts.count == 1 })
        XCTAssertEqual(recorder.settledBursts[0], [])
    }

    /// Without that request, attaching reports nothing.
    func testAttachingReportsNothingUnlessAskedTo() throws {
        let url = try makeFileURL()
        try Data("one".utf8).write(to: url)
        let recorder = Recorder()
        let watcher = makeWatcher(url, recorder)

        _ = waitUntil(timeout: 0.4) { false }

        XCTAssertTrue(watcher.isArmed)
        XCTAssertEqual(recorder.settledBursts.count, 0)
    }

    // MARK: - Following the file

    /// After an atomic save replaces the file, the watcher listens to the new one: a later write in place is noticed too.
    func testAReplacedFileIsFollowedToLaterWrites() throws {
        let url = try makeFileURL()
        try Data("one".utf8).write(to: url)
        let recorder = Recorder()
        _ = makeWatcher(url, recorder)

        try atomicSave("two", to: url)
        XCTAssertTrue(waitUntil(timeout: 5) { recorder.settledBursts.count == 1 })

        try Data("three".utf8).write(to: url)
        XCTAssertTrue(waitUntil(timeout: 5) { recorder.settledBursts.count == 2 })
        XCTAssertEqual(recorder.opens, 2, "one open for each file")
    }

    /// A file removed for a moment and put back is found again, with no event to announce it.
    func testAFileThatReappearsAfterAGapIsWatchedAgain() throws {
        let url = try makeFileURL()
        try Data("one".utf8).write(to: url)
        let recorder = Recorder()
        let watcher = makeWatcher(url, recorder, retryDelays: [.milliseconds(100), .milliseconds(100), .milliseconds(100), .milliseconds(100)])

        try FileManager.default.removeItem(at: url)
        XCTAssertTrue(waitUntil(timeout: 5) { !watcher.isArmed })
        try Data("two".utf8).write(to: url)

        XCTAssertTrue(waitUntil(timeout: 5) { watcher.isArmed })
        XCTAssertEqual(recorder.gaveUp, 0)
    }

    /// A file that never comes back is given up on, once, after every retry.
    func testAFileThatNeverComesBackIsGivenUpOn() throws {
        let url = try makeFileURL()
        let recorder = Recorder()
        let watcher = makeWatcher(url, recorder)

        XCTAssertTrue(waitUntil(timeout: 5) { recorder.gaveUp == 1 })
        XCTAssertFalse(watcher.isArmed)
        _ = waitUntil(timeout: 0.3) { false }
        XCTAssertEqual(recorder.gaveUp, 1)
    }

    /// While the file may not be watched, nothing is opened and nothing is looked for.
    func testAnUnavailableFileIsNotWatchedOrLookedFor() throws {
        let url = try makeFileURL()
        try Data("one".utf8).write(to: url)
        let recorder = Recorder()
        let watcher = makeWatcher(url, recorder, isAvailable: { false })

        _ = waitUntil(timeout: 0.4) { false }

        XCTAssertFalse(watcher.isArmed)
        XCTAssertEqual(recorder.opens, 0)
        XCTAssertEqual(recorder.gaveUp, 0)
    }

    /// Asking the watcher to rearm when its file is where it listens reopens nothing.
    func testRearmingKeepsTheWatchedFile() throws {
        let url = try makeFileURL()
        try Data("one".utf8).write(to: url)
        let recorder = Recorder()
        let watcher = makeWatcher(url, recorder)

        watcher.rearm()
        watcher.rearm()

        XCTAssertEqual(recorder.opens, 1)
    }

    // MARK: - Stopping

    /// Stopping closes the descriptor and ends the reports, even of a burst under way.
    func testStoppingClosesTheDescriptorAndEndsReports() throws {
        let url = try makeFileURL()
        try Data("one".utf8).write(to: url)
        let recorder = Recorder()
        let watcher = makeWatcher(url, recorder)

        try Data("two".utf8).write(to: url)
        watcher.stop()

        XCTAssertTrue(waitUntil(timeout: 5) { recorder.closes == 1 })
        _ = waitUntil(timeout: 0.4) { false }
        XCTAssertEqual(recorder.settledBursts.count, 0)
        XCTAssertFalse(watcher.isArmed)
    }

    /// A watcher dropped without `stop()` closes its descriptor all the same.
    func testADroppedWatcherClosesItsDescriptor() throws {
        let url = try makeFileURL()
        try Data("one".utf8).write(to: url)
        let recorder = Recorder()
        var watcher: FileEventWatcher? = FileEventWatcher(file: { url }, calls: recorder.calls, settled: { _ in })
        watcher?.start()
        XCTAssertEqual(recorder.opens, 1)
        XCTAssertEqual(recorder.closes, 0)

        watcher = nil

        XCTAssertTrue(waitUntil(timeout: 5) { recorder.closes == 1 })
    }

    /// A watcher that was never started listens to nothing.
    func testRearmingBeforeStartDoesNothing() throws {
        let url = try makeFileURL()
        try Data("one".utf8).write(to: url)
        let recorder = Recorder()
        let watcher = FileEventWatcher(file: { url }, calls: recorder.calls, settled: { _ in })

        watcher.rearm()

        XCTAssertFalse(watcher.isArmed)
        XCTAssertEqual(recorder.opens, 0)
    }

    // MARK: - What it opens

    /// The descriptor an open off the main thread returned, read back on the main thread once the open has finished.
    private final class OpenResult: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Int32?

        var descriptor: Int32? { lock.withLock { stored } }

        func record(_ descriptor: Int32) { lock.withLock { stored = descriptor } }
    }

    /// A FIFO by the file's name is not watched, and opening it returns at once. A blocking open waited for a writer,
    /// forever, on the main thread (November 23, 2026). The open runs off the main thread here, so that a blocking open
    /// fails this test rather than hanging the suite; the pipe's other end is then opened, which releases the stuck open.
    func testAFIFOByTheFilesNameIsNotOpenedAndTheOpenNeverWaits() throws {
        let url = try makeFileURL()
        XCTAssertEqual(mkfifo(url.path, 0o644), 0, "no pipe could be made")
        let path = url.path
        let result = OpenResult()
        let opened = expectation(description: "the open returned")
        DispatchQueue.global().async {
            result.record(FileEventWatcher.openRegularFileForEvents(path))
            opened.fulfill()
        }

        guard XCTWaiter.wait(for: [opened], timeout: 2) == .completed else {
            let writer = open(path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { close(writer) }
            XCTFail("Opening a FIFO by the file's name waited for a writer")
            return
        }
        XCTAssertEqual(result.descriptor, -1, "a FIFO is no file to watch")
    }

    /// A regular file opens for events; a folder by the file's name does not, nor does a path with nothing at it.
    func testOnlyARegularFileOpensForEvents() throws {
        let url = try makeFileURL()
        try Data("one".utf8).write(to: url)
        let descriptor = FileEventWatcher.openRegularFileForEvents(url.path)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        if descriptor >= 0 { close(descriptor) }

        let folder = try makeFileURL(named: "folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        XCTAssertEqual(FileEventWatcher.openRegularFileForEvents(folder.path), -1)
        XCTAssertEqual(FileEventWatcher.openRegularFileForEvents(url.deletingLastPathComponent().appendingPathComponent("absent.json").path), -1)
    }
}

import os
import XCTest
@testable import TextMouth

/// The folder's shared file work (FR43): a coordinated call that cannot finish is cancelled at its limit, and the
/// Debug-only folder seam of the iPhone's interface test.
final class SyncFolderIOTests: XCTestCase {
    /// A presenter that never lets a writer in, so a coordinated write on its file waits for it for ever: only a
    /// cancel gets the caller out.
    private final class StubbornPresenter: NSObject, NSFilePresenter {
        let presentedItemURL: URL?
        let presentedItemOperationQueue = OperationQueue()
        init(file: URL) { presentedItemURL = file }
        func relinquishPresentedItem(toWriter writer: @escaping @Sendable ((@Sendable () -> Void)?) -> Void) {
            // Never calls `writer`: the coordinator waits on this.
        }
    }

    /// A coordinated write that can't start is cancelled at its limit: the body never runs, the caller is told the
    /// file hasn't arrived, and it takes about the limit, not for ever.
    func testACoordinationThatCannotStartIsCancelledAtItsLimit() throws {
        let file = try makeSandboxDirectory("folder-io-cancel").appendingPathComponent("held.json")
        try Data("x".utf8).write(to: file)
        let presenter = StubbornPresenter(file: file)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }

        let started = ContinuousClock.now
        XCTAssertThrowsError(try SyncFolderIO.coordinated(writing: file, replacing: true, within: 0.5) { _ in
            XCTFail("the body ran though the coordination never began")
            return 1
        }) { error in
            XCTAssertEqual(error as? SyncProblem, .notDownloaded(device: file.deletingLastPathComponent().lastPathComponent))
        }
        let took = started.duration(to: ContinuousClock.now)
        XCTAssertLessThan(took, .seconds(10), "the call gave up at its limit")
        XCTAssertGreaterThanOrEqual(took, .milliseconds(400), "and not before it")
    }

    /// A virtual clock for the wait: sleeping moves it on at once, so no real time decides a test.
    ///
    /// `@unchecked Sendable`: `offset` is read and changed only under `lock`.
    private final class VirtualTime: @unchecked Sendable {
        private let lock = NSLock()
        private let origin = ContinuousClock.now
        private var offset = Duration.zero
        var now: ContinuousClock.Instant { lock.lock(); defer { lock.unlock() }; return origin + offset }
        func advance(_ duration: Duration) { lock.lock(); offset += duration; lock.unlock() }
    }

    /// A download that stays `.downloading` with no byte arriving is stalled and times out; one whose bytes move is not.
    /// Time is virtual: each poll moves the clock 30 ms, and nothing waits for real.
    func testADownloadStuckInDownloadingTimesOutButOneThatMovesDoesNot() async throws {
        let file = URL(fileURLWithPath: "/Users/reader/Scratch/stuck.bin")
        let time = VirtualTime()
        let polls = OSAllocatedUnfairLock(initialState: 0)
        // Stuck: the state says downloading for ever, the bytes never change.
        do {
            try await SyncFolderIO.waitUntilHere(
                file, within: .milliseconds(300), items: UbiquitousItemStatusProvider(), reachability: .online, pollInterval: .milliseconds(30),
                state: { _ in polls.withLock { $0 += 1; return $0 == 1 ? .notDownloaded : .downloading } }, progress: { _ in 100 },
                now: { time.now }, sleep: { time.advance($0) }
            )
            XCTFail("a stuck download must time out")
        } catch { XCTAssertEqual(error as? SyncProblem, .notDownloaded(device: "Scratch")) }

        // Moving: bytes grow at every look, so the clock restarts, until the file is here (far past the 300 ms limit in virtual time).
        let looks = OSAllocatedUnfairLock(initialState: 0)
        try await SyncFolderIO.waitUntilHere(
            file, within: .milliseconds(300), items: UbiquitousItemStatusProvider(), reachability: .online, pollInterval: .milliseconds(30),
            state: { _ in looks.withLock { $0 += 1; return $0 < 30 ? (($0 == 1) ? .notDownloaded : .downloading) : .downloaded } },
            progress: { _ in Int64(looks.withLock { $0 }) },
            now: { time.now }, sleep: { time.advance($0) }
        )
    }

    /// A file that is `.downloading` before the wait begins (iCloud Drive started it on its own) is waited for by the progress
    /// rule: one that moves slowly finishes, and one that does not move times out.
    func testAFileAlreadyDownloadingIsWaitedForByItsProgress() async throws {
        let file = URL(fileURLWithPath: "/Users/reader/Scratch/started.bin")
        let time = VirtualTime()
        let looks = OSAllocatedUnfairLock(initialState: 0)
        try await SyncFolderIO.waitUntilHere(
            file, within: .milliseconds(300), items: UbiquitousItemStatusProvider(), reachability: .online, pollInterval: .milliseconds(30),
            state: { _ in looks.withLock { $0 += 1; return $0 < 40 ? .downloading : .downloaded } },
            progress: { _ in Int64(looks.withLock { $0 }) },
            now: { time.now }, sleep: { time.advance($0) }
        )
        XCTAssertGreaterThanOrEqual(looks.withLock { $0 }, 40, "it waited past the 300 ms limit, as the bytes kept arriving")

        do {
            try await SyncFolderIO.waitUntilHere(
                file, within: .milliseconds(300), items: UbiquitousItemStatusProvider(), reachability: .online, pollInterval: .milliseconds(30),
                state: { _ in .downloading }, progress: { _ in 5 }, now: { time.now }, sleep: { time.advance($0) }
            )
            XCTFail("a download that never moves must time out")
        } catch { XCTAssertEqual(error as? SyncProblem, .notDownloaded(device: "Scratch")) }
    }

    /// The network going while a download waits is said at once, not at the limit.
    func testGoingOfflineInsideTheWaitIsReportedAtOnce() async throws {
        let file = URL(fileURLWithPath: "/Users/reader/Scratch/stuck.bin")
        let asks = OSAllocatedUnfairLock(initialState: 0)
        let reachability = NetworkReachability(isOnline: { asks.withLock { $0 += 1; return $0 < 3 } })
        do {
            try await SyncFolderIO.waitUntilHere(
                file, within: .seconds(30), items: UbiquitousItemStatusProvider(), reachability: reachability, pollInterval: .milliseconds(10),
                state: { _ in .notDownloaded }, progress: { _ in 1 }
            )
            XCTFail("offline")
        } catch { XCTAssertEqual(error as? SyncProblem, .offline) }
    }

    /// The test seam names a folder only in a Debug build, and a folder inside it counts.
    func testTheSeamFolder() {
        #if DEBUG
        let environment = ["TEXTMOUTH_SYNC_FOLDER": "/Users/reader/Scratch/sync"]
        XCTAssertNotNil(SyncCenter.seamFolder(environment: environment))
        XCTAssertTrue(SyncCenter.isSeamFolder(URL(fileURLWithPath: "/Users/reader/Scratch/sync"), environment: environment))
        XCTAssertTrue(SyncCenter.isSeamFolder(URL(fileURLWithPath: "/Users/reader/Scratch/sync/TextMouth Sync"), environment: environment))
        XCTAssertFalse(SyncCenter.isSeamFolder(URL(fileURLWithPath: "/Users/reader/Scratch/syncing"), environment: environment))
        XCTAssertNil(SyncCenter.seamFolder(environment: [:]))
        XCTAssertFalse(SyncCenter.isSeamFolder(URL(fileURLWithPath: "/Users/reader/Scratch/sync"), environment: [:]))
        #else
        XCTAssertNil(SyncCenter.seamFolder(environment: ["TEXTMOUTH_SYNC_FOLDER": "/x"]), "a Release build never reads it")
        #endif
    }

    /// The upload rule: a folder that carries no sync flags reports nothing.
    func testALocalFileReportsNoUploadState() throws {
        let file = try makeSandboxDirectory("folder-io-upload").appendingPathComponent("a.json")
        try Data("x".utf8).write(to: file)
        XCTAssertEqual(SyncFolderIO.uploadState(of: file, items: UbiquitousItemStatusProvider()), .notReported)
    }
}

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
        func relinquishPresentedItem(toWriter writer: @escaping ((() -> Void)?) -> Void) {
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

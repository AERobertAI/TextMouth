import XCTest
@testable import TextMouth

/// The small files a cloud library opens with besides the ones it waits for
/// (the settings, the substitutions, the statistics, and each feed's
/// record): after the library opens, those only in the cloud are fetched on
/// background queues, never a book or an episode, and each service is told
/// when its file is on this Mac. The sync service and the fetch are
/// scripted, in folders inside the test sandbox.
@MainActor
final class LibraryLaunchFilesTests: XCTestCase {

    /// Only the launch files that are only in the cloud are fetched, by name
    /// in the data directory, and the service that reads each is told; a
    /// book's file that is only in the cloud is never read.
    func testOnlyTheLaunchFilesInTheCloudAreFetchedAndTheirServicesTold() throws {
        let scene = try LaunchScene(test: self, label: "LaunchFiles", inCloud: true)
        let root = scene.fixture.root
        let substitutions = root.appendingPathComponent("substitutions.json")
        let feedID = UUID()
        let record = FeedPaths.recordFile(of: feedID, in: FeedPaths.recordsFolder(in: root))
        try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: record)
        let book = root.appendingPathComponent("Library/Sea Charts/Atlas.tmb/content.md")
        try FileManager.default.createDirectory(at: book.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("text".utf8).write(to: book)
        for file in [substitutions, record, book] {
            scene.keepInCloud(file)
        }

        let model = scene.launch()

        XCTAssertTrue(waitUntil(timeout: 5) { scene.takeUp.calls.count == 2 }, "heard \(scene.takeUp.calls)")
        XCTAssertEqual(
            Set(scene.fetched.names(in: root)),
            ["substitutions.json", DataDirectoryPaths.relativeName(of: record, in: root)]
        )
        XCTAssertEqual(Set(scene.takeUp.calls), ["substitutions", "feedRecords"])
        XCTAssertTrue(model.hasStartedLibrary)
        XCTAssertTrue(waitUntil(timeout: 2) { model.libraryFilesBeingRead.isEmpty })
    }

    /// A file that cannot be fetched is logged, not announced to its service,
    /// and no longer counts as being read.
    func testAFailedLaunchFileTellsNoService() throws {
        let scene = try LaunchScene(test: self, label: "LaunchFileFails", inCloud: true)
        scene.keepInCloud(scene.fixture.root.appendingPathComponent("reading_stats.json"))
        scene.fetchFails = true

        let model = scene.launch()

        XCTAssertTrue(waitUntil(timeout: 5) { scene.fetched.urls.count == 1 })
        XCTAssertTrue(waitUntil(timeout: 2) { model.libraryFilesBeingRead.isEmpty })
        XCTAssertEqual(scene.takeUp.calls, [])
    }

    /// A library that is not in a cloud location fetches nothing.
    func testALibraryOutsideTheCloudFetchesNothing() throws {
        let scene = try LaunchScene(test: self, label: "LaunchLocal", inCloud: false)
        scene.keepInCloud(scene.fixture.root.appendingPathComponent("substitutions.json"))

        _ = scene.launch()
        _ = waitUntil(timeout: 0.4) { false }

        XCTAssertEqual(scene.fetched.urls, [])
        XCTAssertEqual(scene.takeUp.calls, [])
    }

    /// With twelve feed records only in the cloud and a silent sync service,
    /// only eight reads are started; the rest start as the first return.
    func testNoMoreThanEightLaunchFilesAreReadAtOnce() throws {
        let scene = try LaunchScene(test: self, label: "LaunchCap", inCloud: true)
        let folder = FeedPaths.recordsFolder(in: scene.fixture.root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for _ in 0..<12 {
            let record = FeedPaths.recordFile(of: UUID(), in: folder)
            try Data("{}".utf8).write(to: record)
            scene.keepInCloud(record)
        }
        let gate = scene.holdFetches()
        defer { gate.signal() }

        // Kept alive: the fetch holds the model weakly.
        let model = scene.launch()
        defer { withExtendedLifetime(model) {} }

        XCTAssertTrue(waitUntil(timeout: 5) { scene.fetched.urls.count == 8 }, "started \(scene.fetched.urls.count)")
        _ = waitUntil(timeout: 0.4) { false }
        XCTAssertEqual(scene.fetched.urls.count, 8, "more than eight reads were out at once")
        gate.signal()
        XCTAssertTrue(waitUntil(timeout: 8) { scene.fetched.urls.count == 12 }, "the queued reads never started")
    }

    /// A read still out is not started again by a second look, so no threads
    /// pile up behind a file the sync service never answers.
    func testAReadStillOutIsNotStartedAgain() throws {
        let scene = try LaunchScene(test: self, label: "LaunchHeld", inCloud: true)
        scene.keepInCloud(scene.fixture.root.appendingPathComponent("config.json"))
        let gate = scene.holdFetches()
        let model = scene.launch()
        XCTAssertTrue(waitUntil(timeout: 5) { scene.fetched.urls.count == 1 })

        model.fetchLaunchFilesInBackground()
        _ = waitUntil(timeout: 0.4) { false }

        XCTAssertEqual(scene.fetched.urls.count, 1)
        gate.signal()
        XCTAssertTrue(waitUntil(timeout: 5) { scene.takeUp.calls == ["settings"] })
    }
}

// MARK: - The Scripted LaunchScene

/// A custom library in a sandbox, in a scripted cloud location or not, with a
/// scripted fetch and recorders standing in for the services that read the
/// launch files.
@MainActor
private final class LaunchScene {
    /// The library on its "volume".
    let fixture: LibraryFixture
    /// The scripted sync service.
    let cloud = FakeCloudItemStatusProvider()
    /// Every file the fetch was asked for.
    let fetched = FetchRecord()
    /// The services told that their files arrived.
    let takeUp = TakeUpRecord()
    /// Whether the fetch throws an offline error.
    var fetchFails = false
    /// Holds the fetch until signalled, when set.
    private var hold: DispatchSemaphore?

    /// Lays out the library, in Google Drive as the scripted service says
    /// when `inCloud`, and installs the service until the test ends.
    init(test: XCTestCase, label: String, inCloud: Bool) throws {
        fixture = try LibraryFixture(test: test, label: label)
        // A hold left shut by a failed assertion is opened when the test ends.
        test.addTeardownBlock { @MainActor [weak self] in self?.hold?.signal() }
        if inCloud {
            cloud.setLocation(.cloud(.googleDrive), of: fixture.root)
        }
        let previous = CloudServices.itemStatus
        CloudServices.itemStatus = cloud
        test.addTeardownBlock { @MainActor in CloudServices.itemStatus = previous }
    }

    /// Makes the sync service say `file` is only in the cloud.
    func keepInCloud(_ file: URL) {
        cloud.setStatus(
            CloudItemStatus(state: .notDownloaded, isUploaded: true, byteCount: 120, hasUnresolvedConflicts: false, downloadError: nil),
            of: file
        )
    }

    /// Holds every read until the returned semaphore is signalled.
    func holdFetches() -> DispatchSemaphore {
        let semaphore = DispatchSemaphore(value: 0)
        hold = semaphore
        return semaphore
    }

    /// Starts a library model with the scripted fetch, whose services are
    /// the recorders.
    func launch() -> LibraryViewModel {
        let fetched = fetched
        let fails = fetchFails
        let hold = hold
        let environment = DataDirectoryEnvironment(
            preferences: fixture.preferences,
            volumeNotifications: fixture.volumeNotifications,
            libraryFetch: { file in
                fetched.record(file)
                if let hold {
                    _ = hold.wait(timeout: .now() + 10)
                    hold.signal()
                }
                if fails { throw URLError(.notConnectedToInternet) }
            }
        )
        let model = LibraryViewModel(dataDirectoryEnvironment: environment)
        // The fetch starts once this turn ends, so the recorders are in place
        // before any service is told.
        let takeUp = takeUp
        model.launchFileTakeUp = LibraryLaunchFileTakeUp(
            settings: { takeUp.calls.append("settings") },
            substitutions: { takeUp.calls.append("substitutions") },
            readingStatistics: { takeUp.calls.append("readingStatistics") },
            feedRecords: { takeUp.calls.append("feedRecords") }
        )
        return model
    }
}

/// The files the scripted fetch was asked for, from any thread.
private final class FetchRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []

    func record(_ url: URL) { lock.withLock { recorded.append(url) } }

    var urls: [URL] { lock.withLock { recorded } }

    /// The files by name in the data directory `root`.
    func names(in root: URL) -> [String] {
        urls.map { DataDirectoryPaths.relativeName(of: $0, in: root) }
    }
}

/// Which services were told their files arrived, in order.
@MainActor
private final class TakeUpRecord {
    var calls: [String] = []
}

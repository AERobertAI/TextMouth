import SwiftUI
import XCTest
@testable import TextMouth

/// A library whose own files are only in the cloud, as Google Drive's Stream
/// mode leaves them after a restart, fetches them itself and opens by itself.
/// The sync service and the fetch are scripted, in folders inside the test
/// sandbox: no real cloud drive is used, and no file is ever made dataless.
@MainActor
final class LibraryCloudFetchTests: XCTestCase {

    // MARK: - Launch

    /// A launch with library.json only in the cloud fetches it, opens the
    /// library by itself, and the books load. VoiceOver hears that the
    /// library is available, once, and nothing about it being unavailable.
    func testLaunchFetchesTheIndexAndOpensByItself() throws {
        let world = try CloudWorld(test: self, label: "FetchIndex")
        world.keepInCloud(world.index)

        let model = world.launch()
        XCTAssertEqual(
            model.dataDirectoryUnavailability,
            .gettingFromCloud(.googleDrive, folder: world.fixture.root.path, files: ["library.json"])
        )
        XCTAssertFalse(model.hasStartedLibrary)

        XCTAssertTrue(waitUntil(timeout: 5) { model.hasStartedLibrary }, "the library never opened")
        XCTAssertNil(model.dataDirectoryUnavailability)
        XCTAssertFalse(DataDirectoryGate.isClosed(world.fixture.root))
        XCTAssertEqual(model.library.folders.map(\.fullPath), [LibraryFixture.folderName])
        XCTAssertEqual(world.fetched.names(in: world.fixture.root), ["library.json"])
        XCTAssertEqual(world.announcements.messages, ["The library is available."])
    }

    /// The Feeds folder only in the cloud is fetched first; once it is
    /// listed, a feed's folder and index it holds are named and fetched on
    /// the next pass; then the library opens.
    func testFeedsAreFetchedAcrossPasses() throws {
        let world = try CloudWorld(test: self, label: "FetchFeeds")
        let feeds = FeedPaths.recordsFolder(in: world.fixture.root)
        try FileManager.default.createDirectory(at: feeds, withIntermediateDirectories: true)
        let feedID = UUID()
        let itemsFolder = FeedPaths.itemsFolder(of: feedID, in: world.fixture.root)
        let feedIndex = FeedPaths.indexFile(of: feedID, in: world.fixture.root)
        world.keepInCloud(feeds)
        world.keepInCloud(itemsFolder)
        world.keepInCloud(feedIndex)
        // The Feeds folder's listing, only in the cloud, shows the feed's
        // folder and index once it is fetched.
        world.whenFetched(feeds) {
            try FileManager.default.createDirectory(at: itemsFolder, withIntermediateDirectories: true)
            try FeedIndexFiles.encoded(FeedIndex(feedID: feedID, books: [])).write(to: feedIndex)
        }

        let model = world.launch()

        XCTAssertTrue(waitUntil(timeout: 5) { model.hasStartedLibrary }, "the library never opened")
        XCTAssertNil(model.dataDirectoryUnavailability)
        XCTAssertEqual(
            world.fetched.names(in: world.fixture.root),
            ["Feeds", DataDirectoryPaths.relativeName(of: itemsFolder, in: world.fixture.root),
             DataDirectoryPaths.relativeName(of: feedIndex, in: world.fixture.root)]
        )
    }

    /// Only the files the check names are fetched: a book's file that is
    /// only in the cloud is never read.
    func testNoBookFileIsEverFetched() throws {
        let world = try CloudWorld(test: self, label: "OnlyNamed")
        let book = world.fixture.root.appendingPathComponent("Library/Sea Charts/Atlas.tmb/content.md")
        try FileManager.default.createDirectory(at: book.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("text".utf8).write(to: book)
        world.keepInCloud(book)
        world.keepInCloud(world.index)
        world.keepInCloud(LibraryIdentity.markerURL(in: world.fixture.root))

        let model = world.launch()

        XCTAssertTrue(waitUntil(timeout: 5) { model.hasStartedLibrary }, "the library never opened")
        XCTAssertEqual(Set(world.fetched.names(in: world.fixture.root)), ["library.json", LibraryIdentity.fileName])
        XCTAssertFalse(world.fetched.urls.contains(book))
    }

    // MARK: - Failing

    /// A fetch that fails, as when the Mac is offline, stops after the one
    /// pass instead of looping, says so and why, and Try Again starts over
    /// and opens the library once the files can be read.
    func testAFailedFetchStopsSaysSoAndTryAgainStartsOver() throws {
        let world = try CloudWorld(test: self, label: "Offline")
        world.keepInCloud(world.index)
        world.fetchFails.set(true)

        let model = world.launch()

        XCTAssertTrue(waitUntil(timeout: 5) { model.dataDirectoryUnavailability?.isGettingFromCloud == false }, "the fetch never ended")
        guard case .cloudFetchFailed(let provider, _, let files, let ending)? = model.dataDirectoryUnavailability else {
            return XCTFail("unexpected reason \(String(describing: model.dataDirectoryUnavailability))")
        }
        XCTAssertEqual(provider, .googleDrive)
        XCTAssertEqual(files, ["library.json"])
        XCTAssertEqual(ending, "a read failed (library.json: NSURLErrorDomain -1009)")
        XCTAssertFalse(model.hasStartedLibrary)
        XCTAssertTrue(DataDirectoryGate.isClosed(world.fixture.root))
        XCTAssertEqual(world.fetched.urls.count, 1, "the failed fetch looped")
        // Nothing more is read while it sits there.
        _ = waitUntil(timeout: 0.3) { false }
        XCTAssertEqual(world.fetched.urls.count, 1)

        world.fetchFails.set(false)
        let retried = model.retryDataDirectory()
        XCTAssertFalse(retried, "the library can't be open before the files arrive")
        XCTAssertEqual(model.dataDirectoryUnavailability?.isGettingFromCloud, true)
        XCTAssertTrue(waitUntil(timeout: 5) { model.hasStartedLibrary }, "Try Again never opened the library")
        XCTAssertEqual(world.fetched.urls.count, 2)
        XCTAssertEqual(
            world.announcements.messages,
            [
                "The library is still not available. "
                    + DataDirectoryUnavailability.gettingFromCloud(.googleDrive, folder: "", files: []).explanation,
                "The library is available."
            ]
        )
    }

    /// A fetch whose reads succeed but leave the same files in the cloud
    /// makes no progress: it ends after one pass, with the failure shown.
    func testAFetchThatMakesNoProgressEnds() throws {
        let world = try CloudWorld(test: self, label: "NoProgress")
        world.keepInCloud(world.index)
        world.arrivals = false

        let model = world.launch()

        XCTAssertTrue(waitUntil(timeout: 5) { model.dataDirectoryUnavailability?.isGettingFromCloud == false }, "the fetch never ended")
        guard case .cloudFetchFailed(_, _, _, let ending)? = model.dataDirectoryUnavailability else {
            return XCTFail("unexpected reason \(String(describing: model.dataDirectoryUnavailability))")
        }
        XCTAssertEqual(ending, "the same files were still only in the cloud")
        _ = waitUntil(timeout: 0.3) { false }
        XCTAssertEqual(world.fetched.urls.count, 1)
        XCTAssertNil(model.libraryFetchTask)
    }

    // MARK: - While Fetching

    /// Try Again during a fetch starts no second fetch, says the library is
    /// still not available, and the first fetch still opens the library.
    func testTryAgainDuringAFetchStartsNoSecondFetch() throws {
        let world = try CloudWorld(test: self, label: "TryAgainDuring")
        world.keepInCloud(world.index)
        let gate = world.holdFetches()

        let model = world.launch()
        XCTAssertTrue(waitUntil(timeout: 5) { world.fetched.urls.count == 1 }, "the fetch never started")
        let retried = model.retryDataDirectory()
        _ = waitUntil(timeout: 0.2) { false }

        XCTAssertFalse(retried)
        XCTAssertEqual(world.fetched.urls.count, 1, "Try Again started a second fetch")
        XCTAssertEqual(model.dataDirectoryUnavailability?.isGettingFromCloud, true)

        gate.release()
        XCTAssertTrue(waitUntil(timeout: 5) { model.hasStartedLibrary }, "the library never opened")
        XCTAssertEqual(world.fetched.urls.count, 1)
    }

    /// Choosing another library during a fetch drops the fetch before the new
    /// library is recorded: a pass that returns while TextMouth waits to open
    /// again opens nothing, checks nothing, and shows nothing new.
    func testChoosingAnotherLibraryDropsTheFetch() async throws {
        let world = try CloudWorld(test: self, label: "Switch")
        world.keepInCloud(world.index)
        let gate = world.holdFetches()
        let model = world.launch()
        XCTAssertTrue(waitUntil(timeout: 5) { world.fetched.urls.count == 1 }, "the fetch never started")
        let chosen = try makeSandboxDirectory("SwitchChosen")
        _ = try LibraryIdentity.adopt(in: chosen)
        let relaunch = SwitchRelaunch()
        let before = model.dataDirectoryUnavailability

        let switching = Task { await model.useLibraryReturningOutcome(at: chosen, relaunching: relaunch.relauncher) }
        XCTAssertTrue(waitUntil(timeout: 5) { relaunch.isWaiting }, "TextMouth never asked to open again")
        XCTAssertNil(model.libraryFetchTask, "the fetch was not dropped before the new library was recorded")
        gate.release()
        _ = waitUntil(timeout: 0.5) { false }
        relaunch.finish()
        let outcome = await switching.value

        XCTAssertTrue(outcome.succeeded, outcome.failureMessage ?? "")
        XCTAssertEqual(model.dataDirectoryUnavailability, before, "the dropped fetch changed the screen")
        XCTAssertFalse(model.hasStartedLibrary)
        XCTAssertEqual(world.announcements.messages, [])
    }

    // MARK: - Stuck and Slow Reads

    /// One stuck read stops no other: the other file is read and fetched, the
    /// failure shows after the stall limit and says the sync service gave no
    /// answer and that this Mac is offline, the stuck file is held so neither
    /// the fetch nor Try Again reads it again, and when it returns late the
    /// check runs and the library opens.
    func testAStuckReadStopsNoOtherAndOpensTheLibraryWhenItReturns() throws {
        let world = try CloudWorld(test: self, label: "Stuck")
        let marker = LibraryIdentity.markerURL(in: world.fixture.root)
        world.keepInCloud(marker)
        world.keepInCloud(world.index)
        world.stallLimit = .seconds(2)
        world.reachability = .offline
        let gate = world.holdFetches(of: marker)

        let model = world.launch()

        XCTAssertTrue(waitUntil(timeout: 8) { model.dataDirectoryUnavailability?.isGettingFromCloud == false }, "the stall never showed")
        guard case .cloudFetchFailed(_, _, _, let ending)? = model.dataDirectoryUnavailability else {
            return XCTFail("unexpected reason \(String(describing: model.dataDirectoryUnavailability))")
        }
        XCTAssertEqual(ending, "no answer within 2 seconds, and this Mac is offline")
        XCTAssertEqual(Set(world.fetched.names(in: world.fixture.root)), ["library.json", LibraryIdentity.fileName])
        XCTAssertEqual(model.libraryFilesBeingRead, [marker.standardizedFileURL.path])

        // Try Again rechecks without reading the stuck file again.
        XCTAssertFalse(model.retryDataDirectory())
        XCTAssertEqual(world.fetched.urls.count, 2, "Try Again read the stuck file again")
        XCTAssertEqual(model.dataDirectoryUnavailability?.isGettingFromCloud, false)

        gate.release()
        XCTAssertTrue(waitUntil(timeout: 5) { model.hasStartedLibrary }, "the late read never opened the library")
        XCTAssertNil(model.dataDirectoryUnavailability)
        XCTAssertTrue(model.libraryFilesBeingRead.isEmpty)
        XCTAssertEqual(world.announcements.messages.last, "The library is available.")
    }

    /// A read that fails fast just after a restart is retried a few times
    /// while the screen keeps saying the files are on their way, and the
    /// library opens when a retry succeeds.
    func testAFailedReadIsRetriedBeforeTheFailureShows() throws {
        let world = try CloudWorld(test: self, label: "Retries")
        world.keepInCloud(world.index)
        world.retryDelays = [.milliseconds(50), .milliseconds(50), .milliseconds(50)]
        world.failuresLeft.set(2)

        let model = world.launch()

        XCTAssertTrue(waitUntil(timeout: 5) { world.fetched.urls.count == 2 })
        XCTAssertEqual(model.dataDirectoryUnavailability?.isGettingFromCloud, true, "the failure showed before the retries")
        XCTAssertTrue(waitUntil(timeout: 5) { model.hasStartedLibrary }, "the library never opened")
        XCTAssertEqual(world.fetched.urls.count, 3)
    }

    /// Retries that all fail end in the failure, after the first read and one
    /// read for each retry, and no more.
    func testRetriesThatAllFailEndInTheFailure() throws {
        let world = try CloudWorld(test: self, label: "RetriesFail")
        world.keepInCloud(world.index)
        world.retryDelays = [.milliseconds(20), .milliseconds(20)]
        world.fetchFails.set(true)

        let model = world.launch()

        XCTAssertTrue(waitUntil(timeout: 5) { model.dataDirectoryUnavailability?.isGettingFromCloud == false })
        _ = waitUntil(timeout: 0.3) { false }
        XCTAssertEqual(world.fetched.urls.count, 3)
        XCTAssertNil(model.libraryFetchTask)
    }

    /// A reason found while a fetch runs does not stay on the screen when the
    /// files are only in the cloud again: Try Again finds the folder gone,
    /// then back with its files in the cloud, and the screen says they are
    /// on their way, with no second fetch.
    func testTheReasonFollowsTryAgainDuringAFetch() throws {
        let world = try CloudWorld(test: self, label: "Stale")
        world.keepInCloud(world.index)
        let gate = world.holdFetches()
        let model = world.launch()
        XCTAssertTrue(waitUntil(timeout: 5) { world.fetched.urls.count == 1 })
        try world.fixture.takeAway()
        XCTAssertFalse(model.retryDataDirectory())
        XCTAssertEqual(model.dataDirectoryUnavailability, .folderMissing(folder: world.fixture.root.path))

        try world.fixture.bringBack()
        XCTAssertFalse(model.retryDataDirectory())

        XCTAssertEqual(model.dataDirectoryUnavailability?.isGettingFromCloud, true)
        XCTAssertEqual(world.fetched.urls.count, 1)
        gate.release()
    }

    /// A fetched marker that names another library ends in that reason, not
    /// in an open library.
    func testAFetchedMarkerOfAnotherLibraryIsRefused() throws {
        let world = try CloudWorld(test: self, label: "OtherLibrary")
        DataDirectoryPreferences.expectedIdentity.write(UUID(), to: world.fixture.preferences)
        world.keepInCloud(LibraryIdentity.markerURL(in: world.fixture.root))

        let model = world.launch()

        XCTAssertTrue(waitUntil(timeout: 5) { model.dataDirectoryUnavailability == .differentLibrary(folder: world.fixture.root.path) })
        XCTAssertFalse(model.hasStartedLibrary)
        XCTAssertNil(model.libraryFetchTask)
    }

    // MARK: - The Screen

    /// The screen announces again when its reason changes, as when the fetch
    /// ends: one announcement for each reason it shows.
    func testTheScreenAnnouncesEachNewReason() {
        let announced = AnnouncementCount()
        let box = ReasonBox(.gettingFromCloud(.googleDrive, folder: "/x/TextMouth", files: ["library.json"]))
        let screen = ReasonScreen(box: box, onAnnounce: { announced.count += 1 })

        withHostedView(screen, until: { $0.fittingSize.height > 0 }) { _ in
            XCTAssertTrue(waitUntil(timeout: 5) { announced.count == 1 }, "the first reason was not announced")
            box.reason = .cloudFetchFailed(.googleDrive, folder: "/x/TextMouth", files: ["library.json"], ending: "")
            XCTAssertTrue(waitUntil(timeout: 5) { announced.count == 2 }, "the new reason was not announced")
        }
    }

    // MARK: - Losing the Library While Running

    /// A library whose index leaves this Mac while TextMouth runs is
    /// fetched again, and opens again by itself.
    func testALibraryLostWhileRunningIsFetchedAndReopened() throws {
        let world = try CloudWorld(test: self, label: "LostWhileRunning")
        let model = world.launch()
        XCTAssertTrue(model.hasStartedLibrary)
        XCTAssertNil(model.dataDirectoryUnavailability)
        var returned = 0
        let observer = NotificationCenter.default.addObserver(forName: .dataDirectoryDidBecomeAvailable, object: nil, queue: .main) { _ in
            returned += 1
        }
        addTeardownBlock { NotificationCenter.default.removeObserver(observer) }

        world.keepInCloud(world.index)
        model.dataDirectoryMayHaveVanished()

        XCTAssertEqual(model.dataDirectoryUnavailability?.isGettingFromCloud, true)
        XCTAssertTrue(waitUntil(timeout: 5) { model.dataDirectoryUnavailability == nil }, "the library never came back")
        XCTAssertEqual(returned, 1)
        XCTAssertEqual(model.library.folders.map(\.fullPath), [LibraryFixture.folderName])
        XCTAssertEqual(world.announcements.messages, ["The library is available."])
    }

    // MARK: - Words

    /// The heading, reason, and announcement of each state, with and without
    /// a known service, and the log line that names the files by their names
    /// in the data directory and never an absolute path.
    func testTheWordsOfEachState() {
        let folder = "/Users/reader/Library/CloudStorage/GoogleDrive-reader@example.com/My Drive/TextMouth"
        let getting = DataDirectoryUnavailability.gettingFromCloud(.googleDrive, folder: folder, files: ["library.json", "Feeds"])
        let failed = DataDirectoryUnavailability.cloudFetchFailed(
            .googleDrive, folder: folder, files: ["Feeds"], ending: "a read failed (Feeds: NSURLErrorDomain -1009)"
        )

        XCTAssertEqual(DataDirectoryUnavailableText.title(for: getting), "Getting Your Library")
        XCTAssertEqual(DataDirectoryUnavailableText.title(for: failed), "Library Not Available")
        XCTAssertEqual(
            getting.explanation,
            "Some of the library's files are in Google Drive and aren't on this Mac yet. "
                + "TextMouth is getting them now, and the library opens when they arrive."
        )
        XCTAssertEqual(
            failed.explanation,
            "TextMouth couldn't get the library's files from Google Drive. "
                + "Check that Google Drive is running and that this Mac is online, then choose Try Again."
        )
        XCTAssertEqual(
            DataDirectoryUnavailableText.announcement(for: getting),
            "Getting Your Library. " + getting.explanation
        )
        XCTAssertEqual(
            DataDirectoryUnavailability.gettingFromCloud(nil, folder: folder, files: []).explanation,
            "Some of the library's files are in the cloud and aren't on this Mac yet. "
                + "TextMouth is getting them now, and the library opens when they arrive."
        )
        XCTAssertEqual(
            DataDirectoryUnavailability.cloudFetchFailed(nil, folder: folder, files: [], ending: "").explanation,
            "TextMouth couldn't get the library's files from the cloud. "
                + "Check that the cloud service is running and that this Mac is online, then choose Try Again."
        )
        let name = DataDirectoryPaths.shortName(of: URL(fileURLWithPath: folder))
        XCTAssertEqual(getting.logDescription, "getting library.json, Feeds in \(name) from Google Drive")
        XCTAssertEqual(
            failed.logDescription,
            "could not get Feeds in \(name) from Google Drive: a read failed (Feeds: NSURLErrorDomain -1009)"
        )
        XCTAssertFalse(getting.logDescription.contains("/Users"))
        XCTAssertFalse(failed.logDescription.contains("/Users"))
        XCTAssertEqual(
            StorageSettingsView.statusText(
                isRecoveringIndex: false, directoryExists: true, isLibraryUnavailable: true,
                unavailableStatus: DataDirectoryUnavailableText.title(for: getting)
            ),
            "Getting Your Library"
        )
    }

    /// Many files are listed in the log by a few names and a count.
    func testALongListOfFilesIsShortenedInTheLog() {
        let files = (1...10).map { "Feeds/feed\($0)/index.json" }
        XCTAssertEqual(
            DataDirectoryUnavailability.listed(files),
            files.prefix(8).joined(separator: ", ") + " and 2 more"
        )
    }

    /// VoiceOver hears each state once: fetching, then the failure.
    func testEachStateIsAnnouncedOnce() throws {
        let world = try CloudWorld(test: self, label: "AnnounceOnce")
        world.keepInCloud(world.index)
        world.arrivals = false
        let gate = world.holdFetches()
        let model = world.launch()

        model.announceDataDirectoryUnavailability()
        model.announceDataDirectoryUnavailability()
        gate.release()
        XCTAssertTrue(waitUntil(timeout: 5) { model.dataDirectoryUnavailability?.isGettingFromCloud == false })
        model.announceDataDirectoryUnavailability()
        model.announceDataDirectoryUnavailability()

        XCTAssertEqual(
            world.announcements.messages,
            [
                "Getting Your Library. Some of the library's files are in Google Drive and aren't on this Mac yet. "
                    + "TextMouth is getting them now, and the library opens when they arrive.",
                "Library Not Available. TextMouth couldn't get the library's files from Google Drive. "
                    + "Check that Google Drive is running and that this Mac is online, then choose Try Again."
            ]
        )
    }

    /// The names of the files the check waits for, relative to the data
    /// directory, and the check naming exactly those.
    func testTheCheckNamesTheFilesItWaitsFor() throws {
        let world = try CloudWorld(test: self, label: "Naming")
        world.keepInCloud(world.index)
        let check = DataDirectoryCheck(root: world.fixture.root, isDefaultLocation: false, expectedIdentity: nil, bookmark: nil)

        let (outcome, pending) = check.runNamingPending(itemStatus: world.cloud)

        XCTAssertEqual(outcome, .unavailable(.notDownloaded(.googleDrive, folder: world.fixture.root.path)))
        XCTAssertEqual(pending.map { DataDirectoryPaths.relativeName(of: $0, in: world.fixture.root) }, ["library.json"])
        let local = check.runNamingPending(itemStatus: LocalItemStatusProvider())
        XCTAssertEqual(local.pending, [])
        XCTAssertEqual(DataDirectoryPaths.relativeName(of: URL(fileURLWithPath: "/elsewhere/file.txt"), in: world.fixture.root), "file.txt")
    }

    // MARK: - The Real Fetch

    /// The real fetch reads a file and lists a folder, both local in the
    /// sandbox, and throws for what isn't there.
    func testTheRealFetchReadsFilesAndFoldersAndThrowsForMissingOnes() throws {
        let directory = try makeSandboxDirectory("RealFetch")
        let file = directory.appendingPathComponent("library.json")
        try Data("{}".utf8).write(to: file)

        XCTAssertNoThrow(try LibraryFileFetcher.fetch(file))
        XCTAssertNoThrow(try LibraryFileFetcher.fetch(directory))
        XCTAssertThrowsError(try LibraryFileFetcher.fetch(directory.appendingPathComponent("missing.json")))
    }
}

// MARK: - The Scripted World

/// A custom library in a sandbox that a scripted sync service holds, and a
/// scripted fetch: reading a file marks it arrived (unless `arrivals` is
/// false), or throws an offline error while `fetchFails`.
@MainActor
private final class CloudWorld {
    /// The library on its "volume".
    let fixture: LibraryFixture
    /// The scripted sync service.
    let cloud = FakeCloudItemStatusProvider()
    /// Every file the fetch was asked for, in order.
    let fetched = FetchLog()
    /// Whether the fetch throws an offline error.
    let fetchFails = Flag()
    /// What VoiceOver was told.
    let announcements = AnnouncementLog()
    /// How long a fetch waits for its reads.
    var stallLimit: Duration = .seconds(30)
    /// The waits between the retries of a fetch.
    var retryDelays: [Duration] = []
    /// Whether this Mac is online, as a stalled fetch's log line says.
    var reachability: NetworkReachability = .online
    /// How many more reads fail, each with an offline error, before reads
    /// succeed again.
    let failuresLeft = Counter()
    /// Whether a read brings the file to this Mac.
    var arrivals: Bool {
        get { arrivalFlag.value }
        set { arrivalFlag.set(newValue) }
    }
    /// Backs `arrivals`, which the fetch reads from its own thread.
    private let arrivalFlag = Flag(true)
    /// What reading a file also does in the scripted cloud, by path.
    private let effects = EffectTable()
    /// Makes the fetch wait until released, when set.
    private let hold = HoldBox()

    /// library.json in the library.
    var index: URL { fixture.root.appendingPathComponent("library.json") }

    /// Lays out the library, puts it in Google Drive as the scripted service
    /// says, installs the service and the announcement log until the test
    /// ends.
    init(test: XCTestCase, label: String) throws {
        fixture = try LibraryFixture(test: test, label: label)
        cloud.setLocation(.cloud(.googleDrive), of: fixture.root)
        let previousService = CloudServices.itemStatus
        CloudServices.itemStatus = cloud
        let previousPoster = VoiceOverAnnouncer.poster
        let log = announcements
        VoiceOverAnnouncer.poster = { announcement, _ in log.record(announcement.message) }
        test.addTeardownBlock { @MainActor in
            CloudServices.itemStatus = previousService
            VoiceOverAnnouncer.poster = previousPoster
        }
    }

    /// Makes the sync service say `file` is only in the cloud.
    func keepInCloud(_ file: URL) {
        cloud.setStatus(Self.status(.notDownloaded), of: file)
    }

    /// Runs `effect` when `file` is read, as a listing of a cloud folder
    /// shows what it holds once it arrives.
    func whenFetched(_ file: URL, _ effect: @escaping @Sendable () throws -> Void) {
        effects.set(effect, for: file)
    }

    /// Makes the fetch wait until the returned gate is released: every read,
    /// or only the read of `file`.
    func holdFetches(of file: URL? = nil) -> FetchGate {
        hold.install(for: file)
    }

    /// Starts a library model under test with the scripted fetch.
    func launch() -> LibraryViewModel {
        let cloud = cloud
        let fetched = fetched
        let fetchFails = fetchFails
        let arrivalFlag = arrivalFlag
        let effects = effects
        let hold = hold
        let failuresLeft = failuresLeft
        let environment = DataDirectoryEnvironment(
            preferences: fixture.preferences,
            volumeNotifications: fixture.volumeNotifications,
            libraryFetch: { file in
                fetched.record(file)
                hold.waitIfHeld(for: file)
                if fetchFails.value || failuresLeft.takeOne() { throw URLError(.notConnectedToInternet) }
                try effects.run(for: file)
                if arrivalFlag.value { cloud.setStatus(Self.status(.downloaded), of: file) }
            }
        )
        let model = LibraryViewModel(dataDirectoryEnvironment: environment)
        // The fetch's first pass starts once this turn ends, so these
        // settings are in place before it reads.
        model.libraryFetchStallLimit = stallLimit
        model.libraryFetchRetryDelays = retryDelays
        model.libraryFetchReachability = reachability
        return model
    }

    /// A status in `state`, as the scripted service reports a file in it.
    private nonisolated static func status(_ state: CloudItemState) -> CloudItemStatus {
        CloudItemStatus(state: state, isUploaded: true, byteCount: 120, hasUnresolvedConflicts: false, downloadError: nil)
    }
}

/// A thread-safe boolean, read by the scripted fetch on its own thread.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool

    init(_ value: Bool = false) { stored = value }

    var value: Bool { lock.withLock { stored } }

    func set(_ value: Bool) { lock.withLock { stored = value } }
}

/// The files the scripted fetch was asked for, in order.
private final class FetchLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []

    func record(_ url: URL) { lock.withLock { recorded.append(url) } }

    var urls: [URL] { lock.withLock { recorded } }

    /// The files by name in the data directory `root`.
    func names(in root: URL) -> [String] {
        urls.map { DataDirectoryPaths.relativeName(of: $0, in: root) }
    }
}

/// What VoiceOver was told, in order.
@MainActor
private final class AnnouncementLog {
    private(set) var messages: [String] = []

    func record(_ message: String) { messages.append(message) }
}

/// What reading a scripted file also does, by standardized path.
private final class EffectTable: @unchecked Sendable {
    private let lock = NSLock()
    private var effects: [String: @Sendable () throws -> Void] = [:]

    func set(_ effect: @escaping @Sendable () throws -> Void, for file: URL) {
        lock.withLock { effects[file.standardizedFileURL.path] = effect }
    }

    func run(for file: URL) throws {
        let effect = lock.withLock { effects[file.standardizedFileURL.path] }
        try effect?()
    }
}

/// Lets a test hold the scripted fetch on its background thread.
private final class HoldBox: @unchecked Sendable {
    private let lock = NSLock()
    private var gate: DispatchSemaphore?
    /// The standardized path of the one file held, or nil when every read is.
    private var heldPath: String?

    /// Holds every fetch from now on, or only the read of `file`, until the
    /// returned gate is released.
    func install(for file: URL?) -> FetchGate {
        let semaphore = DispatchSemaphore(value: 0)
        lock.withLock {
            gate = semaphore
            heldPath = file?.standardizedFileURL.path
        }
        return FetchGate(semaphore: semaphore)
    }

    /// Waits (at most ten seconds, so a broken test can't hang) when the
    /// read of `file` is held.
    func waitIfHeld(for file: URL) {
        let held = lock.withLock { () -> DispatchSemaphore? in
            guard let gate, heldPath == nil || heldPath == file.standardizedFileURL.path else { return nil }
            return gate
        }
        guard let held else { return }
        _ = held.wait(timeout: .now() + 10)
        held.signal()
    }
}

/// A thread-safe count of failures still to come.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining = 0

    func set(_ count: Int) { lock.withLock { remaining = count } }

    /// Whether a failure is still due; takes it.
    func takeOne() -> Bool {
        lock.withLock {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }
}

/// The reason a test screen shows, changed while it is on screen.
@MainActor
private final class ReasonBox: ObservableObject {
    @Published var reason: DataDirectoryUnavailability

    init(_ reason: DataDirectoryUnavailability) { self.reason = reason }
}

/// How many times a test screen asked for an announcement.
@MainActor
private final class AnnouncementCount {
    var count = 0
}

/// The Library Not Available screen showing the box's reason.
private struct ReasonScreen: View {
    @ObservedObject var box: ReasonBox
    let onAnnounce: () -> Void

    var body: some View {
        DataDirectoryUnavailableView(
            unavailability: box.reason,
            notice: nil,
            focusDelay: 0,
            onAnnounce: onAnnounce,
            onTryAgain: {},
            onQuit: {}
        )
    }
}

/// A relauncher whose "open again" waits until the test lets it finish,
/// opening and quitting nothing.
@MainActor
private final class SwitchRelaunch {
    /// Whether TextMouth has asked to open again and waits.
    private(set) var isWaiting = false
    private var continuation: CheckedContinuation<Void, Never>?

    var relauncher: TextMouthRelauncher {
        TextMouthRelauncher(
            openNewInstance: { [self] in
                isWaiting = true
                await withCheckedContinuation { continuation = $0 }
            },
            quit: {}
        )
    }

    /// Lets the waiting "open again" return.
    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

/// Releases the fetches a `HoldBox` holds.
private struct FetchGate {
    fileprivate let semaphore: DispatchSemaphore

    func release() { semaphore.signal() }
}

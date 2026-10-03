import XCTest
@testable import TextMouth

/// Cloud state, downloads, and removals of whole books (FR02,
/// `BookCloudStorageService`). Packages are real folders in the sandbox; the
/// state of their files comes from a scripted sync service
/// (`FakeCloudItemStatusProvider`), so no real cloud drive is used. A
/// download's waits between checks are scripted too: each wait plays one
/// step of a test's script, so no real time passes.
final class BookCloudStorageServiceTests: XCTestCase {
    /// The scripted sync service: each file's state and each folder's
    /// location by path.
    private var items: FakeCloudItemStatusProvider!
    /// The event lines the storage wrote.
    private var events: EventRecorder!

    override func setUp() {
        super.setUp()
        items = FakeCloudItemStatusProvider()
        events = EventRecorder()
    }

    // MARK: - Where the Library Lives

    /// The library's location is the data directory's.
    func testTheLibrarysLocationIsTheDataDirectorys() {
        items.setLocation(.cloud(.dropbox), of: TextMouthPaths.root)

        XCTAssertEqual(makeStorage().libraryLocation(), .cloud(.dropbox))
    }

    // MARK: - A Book's State

    /// In a library on the startup disk or another volume, every book is
    /// local, whatever its files say.
    func testEveryBookOfALibraryOutsideTheCloudIsLocal() throws {
        let book = try makePackage(["content.md"])
        items.setStatus(managed(.notDownloaded), of: book["content.md"])

        for location in [StorageLocation.local, .otherVolume(name: "Archive Disk")] {
            items.setLocation(location, of: TextMouthPaths.root)
            XCTAssertEqual(makeStorage().state(of: book.package), .local, "\(location)")
        }
    }

    /// A package that has not arrived on this Mac is waiting for sync.
    func testAPackageNotOnThisMacIsWaitingForSync() throws {
        putLibraryInTheCloud()
        let absent = try makeSandboxDirectory("CloudBooks").appendingPathComponent("Absent.tmb", isDirectory: true)

        let state = makeStorage().state(of: BookPackage(bookID: UUID(), url: absent, isPackage: true, isAudio: false))

        XCTAssertEqual(state, .waitingForSync)
    }

    /// Any file only in the cloud puts the book in the cloud, even while
    /// another is being downloaded.
    func testAnyFileOnlyInTheCloudPutsTheBookInTheCloud() throws {
        putLibraryInTheCloud()
        let book = try makePackage(["audio.m4b", "bookInfo.json", "content.md"])
        items.setStatus(managed(.notDownloaded), of: book["audio.m4b"])
        items.setStatus(managed(.downloaded), of: book["bookInfo.json"])
        items.setStatus(managed(.downloading), of: book["content.md"])

        XCTAssertEqual(makeStorage().state(of: book.package), .inCloud)
    }

    /// With nothing only in the cloud, a file being downloaded makes the
    /// book downloading, with its progress.
    func testAFileBeingDownloadedMakesTheBookDownloading() throws {
        putLibraryInTheCloud()
        let book = try makePackage(["bookInfo.json", "content.md"])
        items.setStatus(managed(.downloaded, bytes: 100), of: book["bookInfo.json"])
        items.setStatus(managed(.downloading, bytes: 300), of: book["content.md"])

        XCTAssertEqual(
            makeStorage().state(of: book.package),
            .downloading(BookDownloadProgress(completedFiles: 1, totalFiles: 2, completedBytes: 100, totalBytes: 400))
        )
    }

    /// Every file on this Mac makes the book downloaded; a file no sync
    /// service manages is on this Mac too.
    func testEveryFileOnThisMacMakesTheBookDownloaded() throws {
        putLibraryInTheCloud()
        let book = try makePackage(["bookInfo.json", "content.md"])
        items.setStatus(managed(.downloaded), of: book["bookInfo.json"])
        items.setStatus(.local(byteCount: 10), of: book["content.md"])

        XCTAssertEqual(makeStorage().state(of: book.package), .downloaded)
    }

    /// Finder's .DS_Store is no part of a book, so it never puts one in the
    /// cloud.
    func testDSStoreIsNoPartOfABook() throws {
        putLibraryInTheCloud()
        let book = try makePackage([".DS_Store", "content.md"])
        items.setStatus(managed(.notDownloaded), of: book[".DS_Store"])
        items.setStatus(managed(.downloaded), of: book["content.md"])

        XCTAssertEqual(makeStorage().state(of: book.package), .downloaded)
    }

    /// Files in the package's folders count as much as files at its top.
    func testFilesInsideThePackagesFoldersCount() throws {
        putLibraryInTheCloud()
        let book = try makePackage(["cachedAudio/0001.caf", "content.md"])
        items.setStatus(managed(.notDownloaded), of: book["cachedAudio/0001.caf"])
        items.setStatus(managed(.downloaded), of: book["content.md"])

        XCTAssertEqual(makeStorage().state(of: book.package), .inCloud)
    }

    /// A folder the system will not list without downloading it, the
    /// package's own or one inside it, puts the book in the cloud.
    func testAFolderOnlyInTheCloudPutsTheBookInTheCloud() throws {
        putLibraryInTheCloud()
        let book = try makePackage(["cachedAudio/0001.caf", "content.md"])
        items.setStatus(managed(.downloaded), of: book["cachedAudio/0001.caf"])
        items.setStatus(managed(.downloaded), of: book["content.md"])
        let audioFolder = book["cachedAudio/0001.caf"].deletingLastPathComponent()

        for refused in [book.package.url, audioFolder] {
            let storage = makeStorage(readFolder: { folder in
                if samePath(folder, refused) { throw downloadRefusal }
                return try BookCloudStorageService.readFolder(folder)
            })
            XCTAssertEqual(storage.state(of: book.package), .inCloud, refused.lastPathComponent)
        }
    }

    /// A package that cannot be listed for another reason is in the cloud
    /// as far as anyone can tell: nothing shows its files are here.
    func testAPackageThatCannotBeListedIsInTheCloud() throws {
        putLibraryInTheCloud()
        let book = try makePackage(["content.md"])
        items.setStatus(managed(.downloaded), of: book["content.md"])

        let storage = makeStorage(readFolder: { _ in throw CocoaError(.fileReadNoPermission) })

        XCTAssertEqual(storage.state(of: book.package), .inCloud)
    }

    /// A file that vanished after the listing is no longer part of the book.
    func testAFileThatVanishedIsNoLongerPartOfTheBook() throws {
        putLibraryInTheCloud()
        let book = try makePackage(["content.md", "vanished.txt"])
        items.setStatus(managed(.downloaded), of: book["content.md"])

        XCTAssertEqual(makeStorage().state(of: book.package), .downloaded)
    }

    /// An old book without a package is its own file: in the cloud,
    /// downloaded, or not arrived, as that file is.
    func testABookWithoutAPackageIsItsOwnFile() throws {
        putLibraryInTheCloud()
        let file = try makeSandboxDirectory("CloudBooks").appendingPathComponent("Old Book.epub")
        try Data(count: 10).write(to: file)
        let package = BookPackage(bookID: UUID(), url: file, isPackage: false, isAudio: false)
        let storage = makeStorage()

        items.setStatus(managed(.notDownloaded), of: file)
        XCTAssertEqual(storage.state(of: package), .inCloud)
        items.setStatus(managed(.downloaded), of: file)
        XCTAssertEqual(storage.state(of: package), .downloaded)
        items.setStatus(.missing, of: file)
        XCTAssertEqual(storage.state(of: package), .waitingForSync)
    }

    /// A listing holds every regular file but .DS_Store, in folders too, in
    /// path order; links hold no book content and are left out.
    func testAListingHoldsEveryRegularFileButDSStoreInPathOrder() throws {
        let book = try makePackage(["b.txt", "a.txt", ".DS_Store", "cachedAudio/0001.caf", "cachedAudio/.DS_Store"])
        try FileManager.default.createSymbolicLink(
            at: book.package.url.appendingPathComponent("link.txt"),
            withDestinationURL: book["a.txt"]
        )

        let listing = try makeStorage().listing(of: book.package)

        XCTAssertEqual(paths(listing.files), paths([book["a.txt"], book["b.txt"], book["cachedAudio/0001.caf"]]))
        XCTAssertEqual(listing.foldersInCloud, [])
    }

    /// Errors that say nothing is at a path are recognized, wrapped or not.
    func testMissingItemErrorsAreRecognized() {
        XCTAssertTrue(BookCloudStorageService.isMissingItem(CocoaError(.fileReadNoSuchFile)))
        XCTAssertTrue(BookCloudStorageService.isMissingItem(CocoaError(.fileNoSuchFile)))
        XCTAssertTrue(BookCloudStorageService.isMissingItem(POSIXError(.ENOENT)))
        XCTAssertTrue(BookCloudStorageService.isMissingItem(
            CocoaError(.fileReadUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(.ENOENT)])
        ))
        XCTAssertFalse(BookCloudStorageService.isMissingItem(CocoaError(.fileReadNoPermission)))
        XCTAssertFalse(BookCloudStorageService.isMissingItem(downloadRefusal))
    }

    // MARK: - Progress

    /// With every file still to come reporting a size, progress goes by
    /// size.
    func testProgressBySize() {
        let statuses = [managed(.downloaded, bytes: 100), managed(.notDownloaded, bytes: 300)]

        let progress = BookCloudStorageService.progress(of: statuses, foldersInCloud: 0, bySize: true)

        XCTAssertTrue(BookCloudStorageService.sizesAreKnown(of: statuses, foldersInCloud: 0))
        XCTAssertEqual(progress, BookDownloadProgress(completedFiles: 1, totalFiles: 2, completedBytes: 100, totalBytes: 400))
        XCTAssertEqual(progress.percent, 25)
    }

    /// A file still to come that reports no size, as a dataless iCloud
    /// Drive file can, means counting files; a file already here may report
    /// any size.
    func testAFileToComeWithoutASizeMeansCountingFiles() {
        XCTAssertFalse(BookCloudStorageService.sizesAreKnown(
            of: [managed(.downloaded, bytes: 100), managed(.notDownloaded, bytes: 0)],
            foldersInCloud: 0
        ))
        XCTAssertFalse(BookCloudStorageService.sizesAreKnown(of: [managed(.downloading, bytes: nil)], foldersInCloud: 0))
        XCTAssertTrue(BookCloudStorageService.sizesAreKnown(
            of: [managed(.downloaded, bytes: 0), managed(.notDownloaded, bytes: 5)],
            foldersInCloud: 0
        ))
    }

    /// Counting files leaves the bytes at zero, so the progress counts files.
    func testProgressByFiles() {
        let statuses = [managed(.downloaded, bytes: 100), managed(.notDownloaded, bytes: 0), managed(.downloading, bytes: 0)]

        let progress = BookCloudStorageService.progress(of: statuses, foldersInCloud: 0, bySize: false)

        XCTAssertEqual(progress, BookDownloadProgress(completedFiles: 1, totalFiles: 3, completedBytes: 0, totalBytes: 0))
        XCTAssertEqual(progress.percent, 33)
    }

    /// A folder still in the cloud counts as one file to come, of unknown
    /// size.
    func testAFolderInTheCloudCountsAsOneFileToCome() {
        let statuses = [managed(.downloaded, bytes: 100)]

        let progress = BookCloudStorageService.progress(of: statuses, foldersInCloud: 1, bySize: false)

        XCTAssertFalse(BookCloudStorageService.sizesAreKnown(of: statuses, foldersInCloud: 1))
        XCTAssertEqual(progress, BookDownloadProgress(completedFiles: 1, totalFiles: 2, completedBytes: 0, totalBytes: 0))
    }

    /// A local file counts as done, and a vanished one not at all.
    func testLocalFilesAreDoneAndVanishedOnesDoNotCount() {
        let statuses = [CloudItemStatus.local(byteCount: 50), .missing, managed(.notDownloaded, bytes: 150)]

        XCTAssertEqual(
            BookCloudStorageService.progress(of: statuses, foldersInCloud: 0, bySize: true),
            BookDownloadProgress(completedFiles: 1, totalFiles: 2, completedBytes: 50, totalBytes: 200)
        )
    }

    // MARK: - Downloading

    /// A book whose files are all here finishes at once: nothing is asked
    /// for, reported, or logged.
    func testABookAlreadyHereFinishesAtOnce() async throws {
        let book = try makePackage(["bookInfo.json", "content.md"])
        items.setStatus(managed(.downloaded), of: book["bookInfo.json"])
        items.setStatus(managed(.downloaded), of: book["content.md"])

        let steps = try await collect(makeStorage().download(book.package))

        XCTAssertEqual(steps, [])
        XCTAssertEqual(items.downloadRequests, [])
        XCTAssertEqual(events.recorded, [])
    }

    /// A download asks for each missing file once, reports progress as each
    /// file arrives, and finishes once all are here, logging its start and
    /// end with the package's name and the service.
    func testADownloadAsksForEachMissingFileAndReportsEachArrival() async throws {
        let book = try makePackage(["audio.m4b", "bookInfo.json", "content.md"])
        let items = self.items!
        items.setLocation(.cloud(.dropbox), of: book.package.url)
        items.setStatus(managed(.notDownloaded, bytes: 700), of: book["audio.m4b"])
        items.setStatus(managed(.downloaded, bytes: 100), of: book["bookInfo.json"])
        items.setStatus(managed(.notDownloaded, bytes: 200), of: book["content.md"])
        let polls = ScriptedPolls([
            { items.setStatus(managed(.downloading, bytes: 200), of: book["content.md"]) },
            { items.setStatus(managed(.downloaded, bytes: 200), of: book["content.md"]) },
            { items.setStatus(managed(.downloading, bytes: 700), of: book["audio.m4b"]) },
            { items.setStatus(managed(.downloaded, bytes: 700), of: book["audio.m4b"]) },
        ])

        let steps = try await collect(makeStorage(sleep: { try await polls.sleep($0) }).download(book.package))

        XCTAssertEqual(steps, [
            BookDownloadProgress(completedFiles: 1, totalFiles: 3, completedBytes: 100, totalBytes: 1_000),
            BookDownloadProgress(completedFiles: 2, totalFiles: 3, completedBytes: 300, totalBytes: 1_000),
            BookDownloadProgress(completedFiles: 3, totalFiles: 3, completedBytes: 1_000, totalBytes: 1_000),
        ])
        XCTAssertEqual(steps.map(\.percent), [10, 30, 100])
        XCTAssertEqual(paths(items.downloadRequests), paths([book["audio.m4b"], book["content.md"]]))
        XCTAssertEqual(polls.sleeps, 4)
        XCTAssertEqual(events.tags, ["CLOUD_DOWNLOAD_STARTED", "CLOUD_DOWNLOAD_FINISHED"])
        let started = try XCTUnwrap(events.recorded.first)
        XCTAssertEqual(started, "CLOUD_DOWNLOAD_STARTED: \(book.package.url.lastPathComponent): 2 of 3 files to come from Dropbox")
        XCTAssertFalse(events.recorded.joined().contains(HostedTestSandbox.home.path), "no absolute path")
    }

    /// When the files still to come report no size, the progress counts
    /// files for the whole download.
    func testProgressCountsFilesWhenTheFilesToComeReportNoSize() async throws {
        let book = try makePackage(["audio.m4b", "content.md"])
        let items = self.items!
        items.setStatus(managed(.notDownloaded, bytes: 0), of: book["audio.m4b"])
        items.setStatus(managed(.downloaded, bytes: 100), of: book["content.md"])
        let polls = ScriptedPolls([
            { items.setStatus(managed(.downloaded, bytes: 900), of: book["audio.m4b"]) },
        ])

        let steps = try await collect(makeStorage(sleep: { try await polls.sleep($0) }).download(book.package))

        XCTAssertEqual(steps, [
            BookDownloadProgress(completedFiles: 1, totalFiles: 2, completedBytes: 0, totalBytes: 0),
            BookDownloadProgress(completedFiles: 2, totalFiles: 2, completedBytes: 0, totalBytes: 0),
        ])
        XCTAssertEqual(steps.map(\.percent), [50, 100])
    }

    /// Offline, a book with files only in the cloud fails at once: nothing
    /// is asked for and nothing waits.
    func testAnOfflineMacFailsAtOnce() async throws {
        let book = try makePackage(["content.md"])
        items.setStatus(managed(.notDownloaded), of: book["content.md"])

        let steps = await download(makeStorage(reachability: .offline).download(book.package), failsWith: .offline)

        XCTAssertEqual(steps, [])
        XCTAssertEqual(items.downloadRequests, [])
        XCTAssertEqual(events.tags, ["CLOUD_DOWNLOAD_FAILED"])
    }

    /// Offline, a book already here still opens: there is nothing to fetch.
    func testAnOfflineMacStillFinishesABookAlreadyHere() async throws {
        let book = try makePackage(["content.md"])
        items.setStatus(managed(.downloaded), of: book["content.md"])

        let steps = try await collect(makeStorage(reachability: .offline).download(book.package))

        XCTAssertEqual(steps, [])
    }

    /// A download with nothing arriving and nothing being downloaded gives
    /// up once the stall limit has passed: four checks for two seconds.
    func testADownloadWithNothingMovingStalls() async throws {
        let book = try makePackage(["content.md"])
        items.setStatus(managed(.notDownloaded), of: book["content.md"])
        let polls = ScriptedPolls()

        let steps = await download(
            makeStorage(sleep: { try await polls.sleep($0) }, stallLimit: .seconds(2)).download(book.package),
            failsWith: .stalled(seconds: 2)
        )

        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(polls.sleeps, 4)
        XCTAssertEqual(items.downloadRequests.count, 1, "asked for once")
        XCTAssertEqual(events.tags, ["CLOUD_DOWNLOAD_STARTED", "CLOUD_DOWNLOAD_FAILED"])
    }

    /// A file the sync service is downloading keeps a stall away, however
    /// long it takes.
    func testAFileBeingDownloadedKeepsAStallAway() async throws {
        let book = try makePackage(["content.md"])
        let items = self.items!
        items.setStatus(managed(.notDownloaded), of: book["content.md"])
        // Downloading from the first check, for ten checks, then here.
        let quiet: @Sendable () -> Void = {}
        var script: [@Sendable () -> Void] = [{ items.setStatus(managed(.downloading), of: book["content.md"]) }]
        script += Array(repeating: quiet, count: 9)
        script.append { items.setStatus(managed(.downloaded), of: book["content.md"]) }
        let polls = ScriptedPolls(script)

        _ = try await collect(makeStorage(sleep: { try await polls.sleep($0) }, stallLimit: .seconds(2)).download(book.package))

        XCTAssertEqual(polls.sleeps, 11)
    }

    /// Each file that arrives starts the stall limit again.
    func testEachArrivalStartsTheStallLimitAgain() async throws {
        let book = try makePackage(["a.txt", "b.txt", "c.txt"])
        let items = self.items!
        for name in ["a.txt", "b.txt", "c.txt"] {
            items.setStatus(managed(.notDownloaded), of: book[name])
        }
        // Two quiet checks before each arrival: never the four that stall.
        var script: [@Sendable () -> Void] = []
        for name in ["a.txt", "b.txt", "c.txt"] {
            script += [{}, {}, { items.setStatus(managed(.downloaded), of: book[name]) }]
        }
        let polls = ScriptedPolls(script)

        let steps = try await collect(makeStorage(sleep: { try await polls.sleep($0) }, stallLimit: .seconds(2)).download(book.package))

        XCTAssertEqual(steps.map(\.completedFiles), [0, 1, 2, 3])
    }

    /// A stall while the network is gone is reported as being offline,
    /// which says more than a stall.
    func testAStallWhileOfflineSaysTheMacIsOffline() async throws {
        let book = try makePackage(["content.md"])
        items.setStatus(managed(.notDownloaded), of: book["content.md"])
        let network = SharedFlag(true)
        let polls = ScriptedPolls([{ network.set(false) }])
        let storage = makeStorage(
            reachability: NetworkReachability { network.isOn },
            sleep: { try await polls.sleep($0) },
            stallLimit: .seconds(2)
        )

        _ = await download(storage.download(book.package), failsWith: .offline)

        XCTAssertEqual(polls.sleeps, 4)
    }

    /// A download error a file still reports at the next check ends the
    /// download with the service's words.
    func testADownloadErrorAFileKeepsReportingEndsTheDownload() async throws {
        let book = try makePackage(["content.md"])
        let items = self.items!
        items.setStatus(managed(.notDownloaded), of: book["content.md"])
        let polls = ScriptedPolls([
            { items.setStatus(managed(.notDownloaded, error: "The disk is full."), of: book["content.md"]) },
        ])

        _ = await download(
            makeStorage(sleep: { try await polls.sleep($0) }).download(book.package),
            failsWith: .provider("The disk is full.")
        )

        XCTAssertEqual(polls.sleeps, 2)
    }

    /// An error left from an earlier attempt, cleared once the new request
    /// gets going, never ends the download.
    func testAnErrorFromAnEarlierAttemptDoesNotEndTheDownload() async throws {
        let book = try makePackage(["content.md"])
        let items = self.items!
        items.setStatus(managed(.notDownloaded, error: "The network connection was lost."), of: book["content.md"])
        let polls = ScriptedPolls([
            {},
            { items.setStatus(managed(.downloading), of: book["content.md"]) },
            { items.setStatus(managed(.downloaded), of: book["content.md"]) },
        ])

        let steps = try await collect(makeStorage(sleep: { try await polls.sleep($0) }).download(book.package))

        XCTAssertEqual(steps.last?.percent, 100)
    }

    /// A request the sync service refuses ends the download with its words.
    func testARefusedRequestEndsTheDownload() async throws {
        let book = try makePackage(["content.md"])
        items.setStatus(managed(.notDownloaded), of: book["content.md"])
        let refusal = CocoaError(.featureUnsupported)
        items.failDownloads(with: refusal)

        _ = await download(makeStorage().download(book.package), failsWith: .provider(refusal.localizedDescription))

        XCTAssertEqual(events.tags, ["CLOUD_DOWNLOAD_STARTED", "CLOUD_DOWNLOAD_FAILED"])
    }

    /// A package that disappears while it downloads ends the download.
    func testAPackageThatDisappearsEndsTheDownload() async throws {
        let book = try makePackage(["content.md"])
        items.setStatus(managed(.notDownloaded), of: book["content.md"])
        let polls = ScriptedPolls([{ try? FileManager.default.removeItem(at: book.package.url) }])

        _ = await download(makeStorage(sleep: { try await polls.sleep($0) }).download(book.package), failsWith: .packageMissing)
    }

    /// A package that is not on this Mac fails at once.
    func testAPackageNotOnThisMacFailsAtOnce() async throws {
        let absent = try makeSandboxDirectory("CloudBooks").appendingPathComponent("Absent.tmb", isDirectory: true)
        let package = BookPackage(bookID: UUID(), url: absent, isPackage: true, isAudio: false)

        _ = await download(makeStorage().download(package), failsWith: .packageMissing)

        XCTAssertEqual(items.downloadRequests, [])
        XCTAssertEqual(events.tags, ["CLOUD_DOWNLOAD_FAILED"])
    }

    /// A package folder only in the cloud is asked for first; once it can
    /// be listed, each of its files is asked for, and the files count.
    func testAFolderOnlyInTheCloudIsAskedForAndThenItsFiles() async throws {
        let book = try makePackage(["bookInfo.json", "content.md"])
        let items = self.items!
        items.setStatus(managed(.notDownloaded, bytes: 10), of: book["bookInfo.json"])
        items.setStatus(managed(.notDownloaded, bytes: 10), of: book["content.md"])
        let listable = SharedFlag(false)
        let polls = ScriptedPolls([
            { listable.set(true) },
            {
                items.setStatus(managed(.downloaded, bytes: 10), of: book["bookInfo.json"])
                items.setStatus(managed(.downloaded, bytes: 10), of: book["content.md"])
            },
        ])
        let packageFolder = book.package.url
        let storage = makeStorage(sleep: { try await polls.sleep($0) }, readFolder: { folder in
            if !listable.isOn && samePath(folder, packageFolder) { throw downloadRefusal }
            return try BookCloudStorageService.readFolder(folder)
        })

        let steps = try await collect(storage.download(book.package))

        XCTAssertEqual(steps, [
            BookDownloadProgress(completedFiles: 0, totalFiles: 1, completedBytes: 0, totalBytes: 0),
            BookDownloadProgress(completedFiles: 0, totalFiles: 2, completedBytes: 0, totalBytes: 0),
            BookDownloadProgress(completedFiles: 2, totalFiles: 2, completedBytes: 0, totalBytes: 0),
        ])
        XCTAssertEqual(paths(items.downloadRequests), paths([packageFolder, book["bookInfo.json"], book["content.md"]]))
    }

    /// A file that goes back to the cloud during the download is asked for
    /// again.
    func testAFileThatGoesBackToTheCloudIsAskedForAgain() async throws {
        let book = try makePackage(["content.md"])
        let items = self.items!
        items.setStatus(managed(.notDownloaded), of: book["content.md"])
        let polls = ScriptedPolls([
            { items.setStatus(managed(.downloading), of: book["content.md"]) },
            { items.setStatus(managed(.notDownloaded), of: book["content.md"]) },
            {},
            { items.setStatus(managed(.downloaded), of: book["content.md"]) },
        ])

        _ = try await collect(makeStorage(sleep: { try await polls.sleep($0) }).download(book.package))

        XCTAssertEqual(paths(items.downloadRequests), paths([book["content.md"], book["content.md"]]))
    }

    /// Cancelling the task that iterates a download stops it: no check and
    /// no request follows, and the download says it stopped.
    func testCancellingTheIteratingTaskStopsEveryCheckAndRequest() async throws {
        let book = try makePackage(["a.txt", "b.txt"])
        items.setStatus(managed(.notDownloaded), of: book["a.txt"])
        items.setStatus(managed(.notDownloaded), of: book["b.txt"])
        let polls = HeldPolls()
        let stream = makeStorage(sleep: { try await polls.sleep($0) }).download(book.package)
        let firstStep = expectation(description: "the first progress")
        firstStep.assertForOverFulfill = false
        let consumer = Task {
            for try await _ in stream {
                firstStep.fulfill()
            }
        }
        await fulfillment(of: [firstStep], timeout: 10)
        let requested = items.downloadRequests
        let stopped = events.expectation(forLineTagged: "CLOUD_DOWNLOAD_STOPPED")

        consumer.cancel()
        await fulfillment(of: [stopped], timeout: 10)

        try await consumer.value
        XCTAssertEqual(requested.count, 2)
        XCTAssertEqual(items.downloadRequests, requested, "no request after the cancellation")
        XCTAssertEqual(polls.sleeps, 1, "no check after the cancellation")
        XCTAssertEqual(events.tags, ["CLOUD_DOWNLOAD_STARTED", "CLOUD_DOWNLOAD_STOPPED"])
    }

    /// Ending the iteration stops the download as well.
    func testEndingTheIterationStopsTheDownload() async throws {
        let book = try makePackage(["content.md"])
        items.setStatus(managed(.notDownloaded), of: book["content.md"])
        let polls = HeldPolls()
        let stopped = events.expectation(forLineTagged: "CLOUD_DOWNLOAD_STOPPED")

        for try await _ in makeStorage(sleep: { try await polls.sleep($0) }).download(book.package) {
            break
        }
        await fulfillment(of: [stopped], timeout: 10)

        XCTAssertEqual(polls.sleeps, 1)
        XCTAssertEqual(items.downloadRequests.count, 1)
    }

    // MARK: - Removing a Download

    /// While any file has changes waiting to upload, the removal is refused
    /// before any local copy is removed.
    func testRemovalIsRefusedWhileAChangeWaitsToUpload() throws {
        let book = try makePackage(["bookInfo.json", "content.md", "cover.jpg"])
        items.setStatus(managed(.downloaded), of: book["bookInfo.json"])
        items.setStatus(managed(.downloaded, uploaded: false), of: book["content.md"])
        items.setStatus(managed(.notDownloaded), of: book["cover.jpg"])

        XCTAssertThrowsError(try makeStorage().removeDownload(of: book.package)) { error in
            XCTAssertEqual(error as? BookCloudError, .notUploaded)
        }
        XCTAssertEqual(items.removalRequests, [])
        XCTAssertEqual(events.tags, ["CLOUD_DOWNLOAD_REMOVAL_FAILED"])
    }

    /// A removal removes the local copy of each downloaded file and leaves
    /// the rest alone.
    func testRemovalRemovesEachDownloadedFile() throws {
        let book = try makePackage(["bookInfo.json", "content.md", "cover.jpg", "notes.txt"])
        items.setStatus(managed(.downloaded), of: book["bookInfo.json"])
        items.setStatus(managed(.downloaded), of: book["content.md"])
        items.setStatus(managed(.notDownloaded), of: book["cover.jpg"])
        items.setStatus(managed(.downloading), of: book["notes.txt"])

        try makeStorage().removeDownload(of: book.package)

        XCTAssertEqual(paths(items.removalRequests), paths([book["bookInfo.json"], book["content.md"]]))
        XCTAssertEqual(events.recorded, ["CLOUD_DOWNLOAD_REMOVED: \(book.package.url.lastPathComponent): 2 of 4 files"])
    }

    /// A removal the sync service refuses fails with its words.
    func testARefusedRemovalFailsWithTheServicesWords() throws {
        let book = try makePackage(["content.md"])
        items.setStatus(managed(.downloaded), of: book["content.md"])
        let refusal = CocoaError(.fileWriteNoPermission)
        let events = self.events!
        let storage = BookCloudStorageService(
            items: RefusingRemovals(base: items, refusal: refusal),
            reachability: .online,
            logEvent: { events.record($0) }
        )

        XCTAssertThrowsError(try storage.removeDownload(of: book.package)) { error in
            XCTAssertEqual(error as? BookCloudError, .provider(refusal.localizedDescription))
        }
        XCTAssertEqual(events.tags, ["CLOUD_DOWNLOAD_REMOVAL_FAILED"])
    }

    /// A package not on this Mac has no download to remove.
    func testRemovingTheDownloadOfAPackageNotHereFails() throws {
        let absent = try makeSandboxDirectory("CloudBooks").appendingPathComponent("Absent.tmb", isDirectory: true)

        XCTAssertThrowsError(
            try makeStorage().removeDownload(of: BookPackage(bookID: UUID(), url: absent, isPackage: true, isAudio: false))
        ) { error in
            XCTAssertEqual(error as? BookCloudError, .packageMissing)
        }
    }

    // MARK: - Installation

    /// The app installs the real services at launch, and the hosted tests'
    /// library, in their sandbox on the startup disk, still reads as local.
    @MainActor
    func testTheInstalledServicesSeeALocalLibrary() async throws {
        XCTAssertTrue(CloudServices.itemStatus is UbiquitousItemStatusProvider)
        XCTAssertTrue(CloudServices.bookStorage is BookCloudStorageService)
        let items = CloudServices.itemStatus
        let storage = CloudServices.bookStorage
        let book = try makePackage(["content.md"])

        let (rootLocation, libraryLocation, state) = await Task.detached {
            (items.location(of: TextMouthPaths.root), storage.libraryLocation(), storage.state(of: book.package))
        }.value

        XCTAssertEqual(rootLocation, .local)
        XCTAssertEqual(libraryLocation, .local)
        XCTAssertEqual(state, .local)
    }

    // MARK: - Performance

    /// Reading the state of 700 books of three files each reads metadata
    /// only: in a local library, only where the library lives; in a cloud
    /// library, each package's listing and each file's state. The times
    /// are printed for the record.
    func testTheStateOfSevenHundredBooksReadsOnlyMetadata() throws {
        let library = try makeSandboxDirectory("CloudPerformance")
        let packages = try (0..<700).map { index in
            let folder = library.appendingPathComponent("Book \(index).tmb", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["book.epub", "bookInfo.json", "content.md"] {
                try Data(count: 64).write(to: folder.appendingPathComponent(name))
            }
            return BookPackage(bookID: UUID(), url: folder, isPackage: true, isAudio: false)
        }
        let localLibrary = BookCloudStorageService(items: UbiquitousItemStatusProvider(), logEvent: { _ in })
        let cloudLibrary = BookCloudStorageService(items: CloudLibraryOnThisMac(), logEvent: { _ in })
        let clock = ContinuousClock()
        var localStates: [BookCloudState] = []
        var cloudStates: [BookCloudState] = []

        let localTime = clock.measure { localStates = packages.map(localLibrary.state(of:)) }
        let cloudTime = clock.measure { cloudStates = packages.map(cloudLibrary.state(of:)) }

        print("CLOUD_STATE_TIMING: 700 packages of 3 files: local library \(localTime), cloud library \(cloudTime)")
        XCTAssertTrue(localStates.allSatisfy { $0 == .local })
        XCTAssertTrue(cloudStates.allSatisfy { $0 == .downloaded })
        XCTAssertLessThan(cloudTime, .seconds(20), "a pass reads metadata only")
    }

    // MARK: - Helpers

    /// Storage on the scripted sync service, writing its events to
    /// `events`. A test that never waits gets a sleep that fails it.
    private func makeStorage(
        reachability: NetworkReachability = .online,
        sleep: @escaping BookCloudStorageService.Sleep = { _ in XCTFail("this download never waits") },
        stallLimit: Duration = BookCloudStorageService.defaultStallLimit,
        readFolder: @escaping BookCloudStorageService.FolderReader = { try BookCloudStorageService.readFolder($0) }
    ) -> BookCloudStorageService {
        let events = self.events!
        return BookCloudStorageService(
            items: items,
            reachability: reachability,
            sleep: sleep,
            stallLimit: stallLimit,
            readFolder: readFolder,
            logEvent: { events.record($0) }
        )
    }

    /// Puts the data directory in iCloud Drive, as the scripted sync service
    /// reports it.
    private func putLibraryInTheCloud() {
        items.setLocation(.cloud(.iCloudDrive), of: TextMouthPaths.root)
    }

    /// A package folder in the sandbox holding a small file for each name
    /// (a name may hold folders, as "cachedAudio/0001.caf").
    private func makePackage(_ names: [String]) throws -> TestPackage {
        let folder = try makeSandboxDirectory("CloudBooks")
            .appendingPathComponent("Book-\(UUID().uuidString.prefix(8)).tmb", isDirectory: true)
        var files: [String: URL] = [:]
        for name in names {
            let file = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: 8).write(to: file)
            files[name] = file
        }
        return TestPackage(package: BookPackage(bookID: UUID(), url: folder, isPackage: true, isAudio: false), files: files)
    }

    /// Every progress a download reports, once it finishes.
    private func collect(_ download: AsyncThrowingStream<BookDownloadProgress, Error>) async throws -> [BookDownloadProgress] {
        var steps: [BookDownloadProgress] = []
        for try await step in download {
            steps.append(step)
        }
        return steps
    }

    /// Every progress a download reports before it fails, checking that it
    /// fails with `expected`.
    private func download(
        _ download: AsyncThrowingStream<BookDownloadProgress, Error>,
        failsWith expected: BookCloudError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> [BookDownloadProgress] {
        var steps: [BookDownloadProgress] = []
        do {
            for try await step in download {
                steps.append(step)
            }
            XCTFail("the download finished", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? BookCloudError, expected, file: file, line: line)
        }
        return steps
    }

    /// The standardized paths of `urls`, for comparing URLs however their
    /// folders are spelled.
    private func paths(_ urls: [URL]) -> [String] {
        urls.map { $0.standardizedFileURL.path }
    }
}

// MARK: - Test Values

/// The refusal to list a folder that is only in the cloud, as `FileManager`
/// reports it inside `DatalessFiles.withoutDownloading`.
private let downloadRefusal = CocoaError(.fileReadUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(.EDEADLK)])

/// The status of a file a sync service manages.
private func managed(
    _ state: CloudItemState,
    bytes: Int64? = 100,
    uploaded: Bool = true,
    error: String? = nil
) -> CloudItemStatus {
    CloudItemStatus(state: state, isUploaded: uploaded, byteCount: bytes, hasUnresolvedConflicts: false, downloadError: error)
}

/// Whether two URLs name the same item, however their folders are spelled.
private func samePath(_ first: URL, _ second: URL) -> Bool {
    first.standardizedFileURL.path == second.standardizedFileURL.path
}

/// A package a test made in the sandbox, with its files by name.
private struct TestPackage: Sendable {
    /// The package.
    let package: BookPackage
    /// Its files, by the names the test gave them.
    let files: [String: URL]

    /// The file the test named `name`.
    subscript(_ name: String) -> URL {
        guard let file = files[name] else { preconditionFailure("The test made no file named \(name)") }
        return file
    }
}

// MARK: - Scripted Waits

/// A download's waits, scripted by a test: each wait plays the test's next
/// step, such as files changing state, and returns at once, so a download
/// goes through its checks without real time passing. After the last step a
/// wait changes nothing; past `limit` waits one throws, so a download that
/// never ends fails its test instead of hanging the suite.
private final class ScriptedPolls: @unchecked Sendable {
    /// Thrown by a wait past the limit.
    struct RunawayDownload: Error {}

    /// Guards `steps` and `count`.
    private let lock = NSLock()
    /// The steps still to play, in order.
    private var steps: [@Sendable () -> Void]
    /// How many times the download waited.
    private var count = 0
    /// The most waits a download may take.
    private let limit: Int

    /// Waits that play `steps` in order, at most `limit` of them.
    init(_ steps: [@Sendable () -> Void] = [], limit: Int = 200) {
        self.steps = steps
        self.limit = limit
    }

    /// How many times the download waited.
    var sleeps: Int {
        lock.withLock { count }
    }

    /// The download's wait: plays the next step at once.
    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        let step = try lock.withLock { () throws -> (@Sendable () -> Void)? in
            count += 1
            guard count <= limit else { throw RunawayDownload() }
            return steps.isEmpty ? nil : steps.removeFirst()
        }
        step?()
    }
}

/// Waits that last until the download's task is cancelled, so a test can
/// stop a download while it waits.
private final class HeldPolls: @unchecked Sendable {
    /// Guards `count`.
    private let lock = NSLock()
    /// How many times the download waited.
    private var count = 0

    /// How many times the download waited.
    var sleeps: Int {
        lock.withLock { count }
    }

    /// The download's wait: an hour, far longer than any test, which the
    /// cancellation ends at once.
    func sleep(_ duration: Duration) async throws {
        lock.withLock { count += 1 }
        try await Task.sleep(for: .seconds(3_600))
    }
}

/// A flag a test turns on or off while a download runs.
private final class SharedFlag: @unchecked Sendable {
    /// Guards `value`.
    private let lock = NSLock()
    /// Whether the flag is on.
    private var value: Bool

    /// A flag that starts `on` or off.
    init(_ on: Bool) {
        value = on
    }

    /// Whether the flag is on.
    var isOn: Bool {
        lock.withLock { value }
    }

    /// Turns the flag on or off.
    func set(_ on: Bool) {
        lock.withLock { value = on }
    }
}

// MARK: - Event Lines

/// The event lines a storage wrote, and expectations met once a line with a
/// given tag is written.
private final class EventRecorder: @unchecked Sendable {
    /// Guards `lines` and `waiting`.
    private let lock = NSLock()
    /// The lines, in order.
    private var lines: [String] = []
    /// Expectations still waiting for a line with their tag.
    private var waiting: [(tag: String, expectation: XCTestExpectation)] = []

    /// Records `line`, meeting the expectations waiting for its tag.
    func record(_ line: String) {
        let tag = Self.tag(of: line)
        lock.withLock {
            lines.append(line)
            for waiter in waiting where waiter.tag == tag {
                waiter.expectation.fulfill()
            }
            waiting.removeAll { $0.tag == tag }
        }
    }

    /// The lines, in order.
    var recorded: [String] {
        lock.withLock { lines }
    }

    /// Each line's tag, in order.
    var tags: [String] {
        recorded.map(Self.tag(of:))
    }

    /// An expectation met once a line tagged `tag` is written, or at once
    /// when one already was.
    func expectation(forLineTagged tag: String) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "a \(tag) line")
        lock.withLock {
            if lines.contains(where: { Self.tag(of: $0) == tag }) {
                expectation.fulfill()
            } else {
                waiting.append((tag, expectation))
            }
        }
        return expectation
    }

    /// The tag a line begins with: everything before its first colon.
    private static func tag(of line: String) -> String {
        String(line.prefix { $0 != ":" })
    }
}

// MARK: - Providers

/// A sync service that refuses every removal and otherwise answers as
/// `base` does.
private struct RefusingRemovals: CloudItemStatusProviding {
    /// The service that answers everything else.
    let base: FakeCloudItemStatusProvider
    /// What every removal throws.
    let refusal: CocoaError

    func location(of folder: URL) -> StorageLocation { base.location(of: folder) }
    func status(of file: URL) -> CloudItemStatus { base.status(of: file) }
    func requestDownload(of file: URL) throws { try base.requestDownload(of: file) }
    func removeLocalCopy(of file: URL) throws { throw refusal }
}

/// A cloud library whose files are ordinary files on this Mac: every
/// folder is in iCloud Drive, and each file's state is read for real.
private struct CloudLibraryOnThisMac: CloudItemStatusProviding {
    /// Reads each file's state from the file system.
    private let files = UbiquitousItemStatusProvider()

    func location(of folder: URL) -> StorageLocation { .cloud(.iCloudDrive) }
    func status(of file: URL) -> CloudItemStatus { files.status(of: file) }
    func requestDownload(of file: URL) throws { XCTFail("nothing is downloaded") }
    func removeLocalCopy(of file: URL) throws { XCTFail("nothing is removed") }
}

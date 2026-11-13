import Darwin
import XCTest
@testable import TextMouth

/// Cloud state, downloads, and removals of whole books (FR02,
/// `BookCloudStorageService`). Packages are real folders in the sandbox; the
/// state of their files comes from a scripted sync service
/// (`FakeCloudItemStatusProvider`), so no real cloud drive is used. A
/// download's waits between checks are scripted too: each wait plays one
/// step of a test's script, so no real time passes. So is the progress the
/// sync service publishes for a file (`ScriptedPublisher`), which a test
/// publishes from its script.
final class BookCloudStorageServiceTests: XCTestCase {
    /// The scripted sync service: each file's state and each folder's
    /// location by path.
    private var items: FakeCloudItemStatusProvider!
    /// The event lines the storage wrote.
    private var events: EventRecorder!
    /// The progress the scripted sync service publishes for files, which
    /// publishes nothing unless a test says so.
    private var publisher: ScriptedPublisher!

    override func setUp() {
        super.setUp()
        items = FakeCloudItemStatusProvider()
        events = EventRecorder()
        publisher = ScriptedPublisher()
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

    /// A package is listed with dataless files left in the cloud, folders
    /// within it included, so a listing never downloads anything.
    func testAPackageIsListedWithoutDownloading() throws {
        let book = try makePackage(["cachedAudio/0001.caf", "content.md"])
        let policies = DatalessPolicyRecorder()
        let storage = makeStorage(readFolder: { folder in
            policies.record()
            return try BookCloudStorageService.readFolder(folder)
        })

        _ = try storage.listing(of: book.package)

        XCTAssertEqual(policies.recorded, [IOPOL_MATERIALIZE_DATALESS_FILES_OFF, IOPOL_MATERIALIZE_DATALESS_FILES_OFF])
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

    /// A book needs room for the files not on this Mac yet, as they report
    /// their sizes, read without downloading anything: the files already here
    /// take none; a file still to come that reports no size makes the need
    /// unknown (nil), which the reading list's downloads read as no bytes,
    /// checked against the reserve alone; a book wholly here needs nothing.
    func testABookNeedsTheBytesOfItsFilesNotYetHere() throws {
        let book = try makePackage(["audio.m4b", "content.md", "cover.jpg"])
        items.setStatus(managed(.notDownloaded, bytes: 900), of: book["audio.m4b"])
        items.setStatus(managed(.notDownloaded, bytes: 40), of: book["content.md"])
        items.setStatus(managed(.downloaded, bytes: 5), of: book["cover.jpg"])
        let storage = makeStorage()

        XCTAssertEqual(storage.bytesToDownload(of: book.package), 940)
        XCTAssertEqual(items.downloadRequests, [], "reading the need downloaded something")

        items.setStatus(managed(.notDownloaded, bytes: 0), of: book["content.md"])
        XCTAssertNil(storage.bytesToDownload(of: book.package), "a file without a size gave a figure")

        items.setStatus(managed(.downloaded, bytes: 900), of: book["audio.m4b"])
        items.setStatus(managed(.downloaded, bytes: 40), of: book["content.md"])
        XCTAssertEqual(storage.bytesToDownload(of: book.package), 0)
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

    // MARK: - Progress Within a File

    /// The part of a file still to come that the sync service publishes
    /// counts toward the progress, by size: a book whose 900-byte file is
    /// still to come, beside a 100-byte record already here, moves as that
    /// file does. The download listens to the package as a whole and to
    /// that file, never to the record, and stops listening once it ends.
    func testAPublishedPartOfAFileCountsBySize() async throws {
        let book = try makePackage(["audio.m4b", "bookInfo.json"])
        let items = self.items!
        let publisher = self.publisher!
        items.setStatus(managed(.notDownloaded, bytes: 900), of: book["audio.m4b"])
        items.setStatus(managed(.downloaded, bytes: 100), of: book["bookInfo.json"])
        let polls = ScriptedPolls([
            {
                items.setStatus(managed(.downloading, bytes: 900), of: book["audio.m4b"])
                publisher.publish(0.4, of: book["audio.m4b"])
            },
            { publisher.publish(0.6, of: book["audio.m4b"]) },
            { items.setStatus(managed(.downloaded, bytes: 900), of: book["audio.m4b"]) },
        ])

        let steps = try await collect(makeStorage(sleep: { try await polls.sleep($0) }).download(book.package))

        XCTAssertEqual(steps, [
            BookDownloadProgress(completedFiles: 1, totalFiles: 2, completedBytes: 100, totalBytes: 1_000),
            BookDownloadProgress(completedFiles: 1, totalFiles: 2, completedBytes: 460, totalBytes: 1_000),
            BookDownloadProgress(completedFiles: 1, totalFiles: 2, completedBytes: 640, totalBytes: 1_000),
            BookDownloadProgress(completedFiles: 2, totalFiles: 2, completedBytes: 1_000, totalBytes: 1_000),
        ])
        XCTAssertEqual(steps.map(\.percent), [10, 46, 64, 100])
        XCTAssertEqual(
            publisher.filesListenedTo,
            paths([book.package.url, book["audio.m4b"]]),
            "listened to a file already here, or not to the package"
        )
        XCTAssertEqual(publisher.listeningCount, 0, "a listening outlived the download")
    }

    /// By files, as when the file still to come reports no size, its
    /// published part counts as that part of one file.
    func testAPublishedPartOfAFileCountsByFiles() async throws {
        let book = try makePackage(["audio.m4b", "content.md"])
        let items = self.items!
        let publisher = self.publisher!
        items.setStatus(managed(.notDownloaded, bytes: 0), of: book["audio.m4b"])
        items.setStatus(managed(.downloaded, bytes: 100), of: book["content.md"])
        let polls = ScriptedPolls([
            { publisher.publish(0.5, of: book["audio.m4b"]) },
            { items.setStatus(managed(.downloaded, bytes: 900), of: book["audio.m4b"]) },
        ])

        let steps = try await collect(makeStorage(sleep: { try await polls.sleep($0) }).download(book.package))

        XCTAssertEqual(steps, [
            BookDownloadProgress(completedFiles: 1, totalFiles: 2, completedBytes: 0, totalBytes: 0),
            BookDownloadProgress(completedFiles: 1, totalFiles: 2, completedBytes: 0, totalBytes: 0, partialFiles: 0.5),
            BookDownloadProgress(completedFiles: 2, totalFiles: 2, completedBytes: 0, totalBytes: 0),
        ])
        XCTAssertEqual(steps.map(\.percent), [50, 75, 100])
    }

    /// A download listens to the package as a whole and to each file still
    /// to come, those found later in a folder that arrives included, and to
    /// no file already here.
    func testADownloadListensToEachFileStillToCome() async throws {
        let book = try makePackage(["bookInfo.json", "content.md", "parts/0001.mp3"])
        let items = self.items!
        items.setStatus(managed(.downloaded, bytes: 10), of: book["bookInfo.json"])
        items.setStatus(managed(.notDownloaded, bytes: 10), of: book["content.md"])
        items.setStatus(managed(.notDownloaded, bytes: 10), of: book["parts/0001.mp3"])
        let partsFolder = book.package.url.appendingPathComponent("parts", isDirectory: true)
        let listable = SharedFlag(false)
        let polls = ScriptedPolls([
            { listable.set(true) },
            {
                items.setStatus(managed(.downloaded, bytes: 10), of: book["content.md"])
                items.setStatus(managed(.downloaded, bytes: 10), of: book["parts/0001.mp3"])
            },
        ])
        let storage = makeStorage(sleep: { try await polls.sleep($0) }, readFolder: { folder in
            if !listable.isOn && samePath(folder, partsFolder) { throw downloadRefusal }
            return try BookCloudStorageService.readFolder(folder)
        })

        _ = try await collect(storage.download(book.package))

        XCTAssertEqual(
            publisher.filesListenedTo,
            paths([book.package.url, book["content.md"], book["parts/0001.mp3"]])
        )
        XCTAssertEqual(publisher.listeningCount, 0, "a listening outlived the download")
    }

    /// Every listening stops when the download fails, and when its
    /// iteration ends before the download does.
    func testListeningStopsWhenTheDownloadFailsOrIsStopped() async throws {
        let book = try makePackage(["content.md"])
        items.setStatus(managed(.notDownloaded), of: book["content.md"])
        let polls = ScriptedPolls()

        _ = await download(
            makeStorage(sleep: { try await polls.sleep($0) }, stallLimit: .seconds(1)).download(book.package),
            failsWith: .stalled(seconds: 1)
        )
        XCTAssertEqual(publisher.filesListenedTo.count, 2, "the package and its file")
        XCTAssertEqual(publisher.listeningCount, 0, "a failed download kept listening")

        let held = HeldPolls()
        for try await _ in makeStorage(sleep: { try await held.sleep($0) }).download(book.package) {
            break
        }
        await fulfillment(of: [publisher.expectationThatListeningEnds()], timeout: 10)
        XCTAssertEqual(publisher.filesListenedTo.count, 4, "the package and its file again")
    }

    /// A part published lower than one heard before, as when the sync
    /// service starts the file's download again, never takes the progress
    /// back; a file published whole counts 99 percent until it is here.
    func testAPublishedPartNeverTakesTheProgressBack() async throws {
        let book = try makePackage(["audio.m4b"])
        let items = self.items!
        let publisher = self.publisher!
        items.setStatus(managed(.notDownloaded, bytes: 1_000), of: book["audio.m4b"])
        let polls = ScriptedPolls([
            { publisher.publish(0.6, of: book["audio.m4b"]) },
            { publisher.publish(0.2, of: book["audio.m4b"]) },
            { publisher.publish(1, of: book["audio.m4b"]) },
            { items.setStatus(managed(.downloaded, bytes: 1_000), of: book["audio.m4b"]) },
        ])

        let steps = try await collect(makeStorage(sleep: { try await polls.sleep($0) }).download(book.package))

        XCTAssertEqual(steps.map(\.percent), [0, 60, 99, 100])
    }

    /// A part is counted in whole percent of its file, so a part that grows
    /// within one percent, as it may at every check of a long download,
    /// reports nothing new.
    func testAPublishedPartCountsInWholePercent() async throws {
        let book = try makePackage(["audio.m4b"])
        let items = self.items!
        let publisher = self.publisher!
        items.setStatus(managed(.notDownloaded, bytes: 1_000), of: book["audio.m4b"])
        let polls = ScriptedPolls([
            { publisher.publish(0.401, of: book["audio.m4b"]) },
            { publisher.publish(0.409, of: book["audio.m4b"]) },
            { items.setStatus(managed(.downloaded, bytes: 1_000), of: book["audio.m4b"]) },
        ])

        let steps = try await collect(makeStorage(sleep: { try await polls.sleep($0) }).download(book.package))

        XCTAssertEqual(steps.map(\.completedBytes), [0, 400, 1_000])
    }

    /// A part heard of a file is forgotten once the file is here, so a file
    /// that then goes back to the cloud counts from nothing again.
    func testAFileBackInTheCloudCountsFromNothingAgain() async throws {
        let book = try makePackage(["audio.m4b", "cover.jpg"])
        let items = self.items!
        let publisher = self.publisher!
        items.setStatus(managed(.notDownloaded, bytes: 900), of: book["audio.m4b"])
        items.setStatus(managed(.notDownloaded, bytes: 100), of: book["cover.jpg"])
        let polls = ScriptedPolls([
            { publisher.publish(0.5, of: book["audio.m4b"]) },
            { items.setStatus(managed(.downloaded, bytes: 900), of: book["audio.m4b"]) },
            { items.setStatus(managed(.notDownloaded, bytes: 900), of: book["audio.m4b"]) },
            { publisher.publish(0.2, of: book["audio.m4b"]) },
            {
                items.setStatus(managed(.downloaded, bytes: 900), of: book["audio.m4b"])
                items.setStatus(managed(.downloaded, bytes: 100), of: book["cover.jpg"])
            },
        ])

        let steps = try await collect(makeStorage(sleep: { try await polls.sleep($0) }).download(book.package))

        XCTAssertEqual(steps.map(\.percent), [0, 45, 90, 0, 18, 100])
    }

    /// A part that keeps growing keeps a stall away, even while the sync
    /// service reports the file as not being downloaded: the four quiet
    /// checks that make a two-second stall never come.
    func testAGrowingPublishedPartKeepsAStallAway() async throws {
        let book = try makePackage(["audio.m4b"])
        let items = self.items!
        let publisher = self.publisher!
        let audio = book["audio.m4b"]
        items.setStatus(managed(.notDownloaded, bytes: 1_000), of: audio)
        var script: [@Sendable () -> Void] = []
        for tenth in 1...6 {
            script.append { publisher.publish(Double(tenth) / 10, of: audio) }
        }
        script.append { items.setStatus(managed(.downloaded, bytes: 1_000), of: audio) }
        let polls = ScriptedPolls(script)

        let steps = try await collect(
            makeStorage(sleep: { try await polls.sleep($0) }, stallLimit: .seconds(2)).download(book.package)
        )

        XCTAssertEqual(polls.sleeps, 7)
        XCTAssertEqual(steps.map(\.percent), [0, 10, 20, 30, 40, 50, 60, 100])
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

    /// A removal the sync service refuses fails as a removal, never as a
    /// download, with the service's words.
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
            XCTAssertEqual(error as? BookCloudError, .removalFailed(refusal.localizedDescription))
        }
        XCTAssertEqual(events.recorded, [
            "CLOUD_DOWNLOAD_REMOVAL_FAILED: \(book.package.url.lastPathComponent): "
                + "the sync service said: \(refusal.localizedDescription)",
        ])
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

    // MARK: - A Package Synced as One Item, or File by File
    //
    // iCloud Drive syncs a book's .tmb package as one item: the package
    // carries the sync flags, its files carry none, and a request for one of
    // them is refused as for an item that doesn't exist. Google Drive and
    // Dropbox sync each file, and their package folders carry flags too
    // (`syncAsOneItem` and `syncFileByFile` script both, as measured on the
    // real drives on October 3). Each operation is checked both ways.

    /// The package is the item the sync service syncs only when it carries
    /// sync flags of its own and none of its listed files does, which holds
    /// too when no file is listed because the whole package is only in the
    /// cloud. Then it alone is what is synced; otherwise each file is. An
    /// old book without a package has no such item.
    func testThePackageIsTheSyncedItemOnlyWhenItAloneCarriesFlags() {
        typealias FileStatus = BookCloudStorageService.FileStatus
        let folder = URL(fileURLWithPath: "/Users/reader/Library/Mobile Documents/com~apple~CloudDocs/Book.tmb", isDirectory: true)
        /// The book's file called `name`, or its folder when `name` is nil,
        /// on this Mac and carrying flags of its own or not.
        func item(_ name: String?, flags: Bool) -> FileStatus {
            let url = name.map { folder.appendingPathComponent($0) } ?? folder
            return FileStatus(url: url, status: managed(.downloaded), carriesSyncFlags: flags)
        }
        /// The survey of the book holding `files`, whose folder carries flags
        /// as `packageFlags` says, or that has no package when it is nil.
        func survey(packageFlags: Bool?, files: [FileStatus]) -> BookCloudStorageService.Survey {
            BookCloudStorageService.Survey(
                listing: BookCloudStorageService.PackageListing(files: files.map(\.url)),
                files: files,
                package: packageFlags.map { item(nil, flags: $0) }
            )
        }
        let flagless = [item("bookInfo.json", flags: false), item("content.md", flags: false)]
        let flagged = [item("bookInfo.json", flags: true), item("content.md", flags: true)]
        let mixed = [item("bookInfo.json", flags: true), item("content.md", flags: false)]

        XCTAssertEqual(survey(packageFlags: true, files: flagless).packageItem, item(nil, flags: true), "as on iCloud Drive")
        XCTAssertEqual(survey(packageFlags: true, files: []).packageItem, item(nil, flags: true), "only in the cloud")
        XCTAssertNil(survey(packageFlags: true, files: flagged).packageItem, "as on Google Drive")
        XCTAssertNil(survey(packageFlags: true, files: mixed).packageItem, "one file carries flags")
        XCTAssertNil(survey(packageFlags: false, files: flagless).packageItem, "nothing carries flags")
        XCTAssertNil(survey(packageFlags: nil, files: flagless).packageItem, "no package")
        XCTAssertEqual(survey(packageFlags: true, files: flagless).syncedItems.map(\.url), [folder])
        XCTAssertEqual(survey(packageFlags: true, files: flagged).syncedItems.map(\.url), flagged.map(\.url))
    }

    /// A package synced as one item and on this Mac is downloaded.
    func testAPackageSyncedAsOneItemAndHereIsDownloaded() throws {
        putLibraryInTheCloud()
        let book = try makePackage(["bookInfo.json", "content.md"])
        syncAsOneItem(book, package: managed(.downloaded, bytes: nil))

        XCTAssertEqual(makeStorage().state(of: book.package), .downloaded)
    }

    /// A package synced as one item that is only in the cloud is in the
    /// cloud, then downloading while the sync service brings it whole,
    /// counted as one item still to come: its folder stays only in the
    /// cloud until the whole package arrives.
    func testAPackageSyncedAsOneItemIsInTheCloudThenDownloadingWhole() throws {
        putLibraryInTheCloud()
        let book = try makePackage(["bookInfo.json", "content.md"])
        syncAsOneItem(book, package: managed(.notDownloaded, bytes: nil))
        let storage = makeStorage(readFolder: listing(refusing: book.package.url, while: SharedFlag(true)))

        XCTAssertEqual(storage.state(of: book.package), .inCloud)
        items.setStatus(managed(.downloading, bytes: nil), of: book.package.url)
        XCTAssertEqual(
            storage.state(of: book.package),
            .downloading(BookDownloadProgress(completedFiles: 0, totalFiles: 1, completedBytes: 0, totalBytes: 0))
        )
    }

    /// A package whose files carry flags of their own is surveyed file by
    /// file, though its folder carries flags as well, as on Google Drive: a
    /// file only in the cloud puts the book in the cloud, and a file being
    /// downloaded makes it downloading.
    func testAPackageWhoseFilesCarryFlagsIsSurveyedFileByFile() throws {
        putLibraryInTheCloud()
        let book = try makePackage(["bookInfo.json", "content.md"])
        syncFileByFile(book, files: managed(.downloaded, bytes: 10))
        let storage = makeStorage()

        items.setStatus(managed(.notDownloaded, bytes: 10), of: book["content.md"])
        XCTAssertEqual(storage.state(of: book.package), .inCloud)
        items.setStatus(managed(.downloading, bytes: 10), of: book["content.md"])
        XCTAssertEqual(
            storage.state(of: book.package),
            .downloading(BookDownloadProgress(completedFiles: 1, totalFiles: 2, completedBytes: 10, totalBytes: 20))
        )
    }

    /// While a package synced as one item has changes waiting to upload,
    /// removing its download is refused before anything is removed, though
    /// its files report no upload flag: a flag they leave out never counts
    /// as uploaded when the package's own says otherwise.
    func testRemovingAPackageSyncedAsOneItemIsRefusedWhileItUploads() throws {
        let book = try makePackage(["bookInfo.json", "content.md"])
        syncAsOneItem(book, package: managed(.downloaded, bytes: nil, uploaded: false))

        XCTAssertThrowsError(try makeStorage().removeDownload(of: book.package)) { error in
            XCTAssertEqual(error as? BookCloudError, .notUploaded)
        }
        XCTAssertEqual(items.removalRequests, [])
        XCTAssertEqual(events.tags, ["CLOUD_DOWNLOAD_REMOVAL_FAILED"])
    }

    /// Removing the download of a package synced as one item removes the
    /// package's local copy, as one item, and asks nothing for a file,
    /// which the sync service would refuse as an item that doesn't exist.
    func testRemovingAPackageSyncedAsOneItemRemovesThePackageWhole() throws {
        let book = try makePackage(["bookInfo.json", "content.md"])
        syncAsOneItem(book, package: managed(.downloaded, bytes: nil))

        try makeStorage().removeDownload(of: book.package)

        XCTAssertEqual(paths(items.removalRequests), paths([book.package.url]))
        XCTAssertEqual(events.recorded, ["CLOUD_DOWNLOAD_REMOVED: \(book.package.url.lastPathComponent): 2 of 2 files, as one package"])
    }

    /// A package synced as one item that is only in the cloud has no local
    /// copy to remove.
    func testAPackageSyncedAsOneItemOnlyInTheCloudHasNothingToRemove() throws {
        let book = try makePackage(["content.md"])
        syncAsOneItem(book, package: managed(.notDownloaded, bytes: nil))
        let storage = makeStorage(readFolder: listing(refusing: book.package.url, while: SharedFlag(true)))

        try storage.removeDownload(of: book.package)

        XCTAssertEqual(items.removalRequests, [])
        XCTAssertEqual(events.recorded, ["CLOUD_DOWNLOAD_REMOVED: \(book.package.url.lastPathComponent): 0 of 0 files, as one package"])
    }

    /// A package whose files carry flags of their own is removed file by
    /// file, and refused while any file waits to upload, as on Google Drive;
    /// what its folder's own upload flag says does not count, since only
    /// the files' local copies are removed.
    func testAPackageWhoseFilesCarryFlagsIsRemovedFileByFile() throws {
        let book = try makePackage(["bookInfo.json", "content.md"])
        syncFileByFile(book, files: managed(.downloaded))
        items.setStatus(managed(.downloaded, bytes: nil, uploaded: false), of: book.package.url)

        try makeStorage().removeDownload(of: book.package)
        XCTAssertEqual(paths(items.removalRequests), paths([book["bookInfo.json"], book["content.md"]]))

        items.setStatus(managed(.downloaded, uploaded: false), of: book["content.md"])
        XCTAssertThrowsError(try makeStorage().removeDownload(of: book.package)) { error in
            XCTAssertEqual(error as? BookCloudError, .notUploaded)
        }
        XCTAssertEqual(items.removalRequests.count, 2, "nothing more was removed")
    }

    /// A package synced as one item is asked for whole, never file by file,
    /// which the sync service would refuse: here its folder is on this Mac
    /// while its files are only in the cloud.
    func testAPackageSyncedAsOneItemIsAskedForWholeNeverFileByFile() async throws {
        let book = try makePackage(["bookInfo.json", "content.md"])
        let items = try XCTUnwrap(self.items)
        syncAsOneItem(book, package: managed(.downloaded, bytes: nil))
        for name in ["bookInfo.json", "content.md"] {
            items.setStatus(managed(.notDownloaded, bytes: 10), of: book[name], carriesSyncFlags: false)
        }
        let polls = ScriptedPolls([
            {
                for name in ["bookInfo.json", "content.md"] {
                    items.setStatus(managed(.downloaded, bytes: 10), of: book[name], carriesSyncFlags: false)
                }
            },
        ])

        let steps = try await collect(makeStorage(sleep: { try await polls.sleep($0) }).download(book.package))

        XCTAssertEqual(steps.map(\.percent), [0, 100])
        XCTAssertEqual(paths(items.downloadRequests), paths([book.package.url]))
    }

    /// A package synced as one item and only in the cloud is asked for
    /// whole, once, and counts as one item still to come until it arrives
    /// with every file; the start's event line says the service syncs the
    /// package as one item.
    func testAPackageSyncedAsOneItemOnlyInTheCloudIsAskedForWhole() async throws {
        let book = try makePackage(["bookInfo.json", "content.md"])
        let items = try XCTUnwrap(self.items)
        let package = book.package.url
        items.setLocation(.cloud(.iCloudDrive), of: package)
        syncAsOneItem(book, package: managed(.notDownloaded, bytes: nil))
        let inCloud = SharedFlag(true)
        let polls = ScriptedPolls([
            { items.setStatus(managed(.downloading, bytes: nil), of: package) },
            {},
            {
                inCloud.set(false)
                items.setStatus(managed(.downloaded, bytes: nil), of: package)
            },
        ])
        let storage = makeStorage(sleep: { try await polls.sleep($0) }, readFolder: listing(refusing: package, while: inCloud))

        let steps = try await collect(storage.download(book.package))

        XCTAssertEqual(steps, [
            BookDownloadProgress(completedFiles: 0, totalFiles: 1, completedBytes: 0, totalBytes: 0),
            BookDownloadProgress(completedFiles: 2, totalFiles: 2, completedBytes: 0, totalBytes: 0),
        ])
        XCTAssertEqual(paths(items.downloadRequests), paths([package]))
        XCTAssertEqual(
            events.recorded.first,
            "CLOUD_DOWNLOAD_STARTED: \(package.lastPathComponent): 1 of 1 files to come from iCloud Drive, "
                + "which syncs the package as one item"
        )
    }

    /// What the sync service publishes for a package as a whole moves the
    /// progress of a package only in the cloud, counted as one item still to
    /// come, as iCloud Drive's package-level fractions reach the reader's
    /// bar; the download listens to the package alone, since it lists no
    /// file, and stops listening once the package is here.
    func testWhatIsPublishedForAPackageMovesItsProgress() async throws {
        let book = try makePackage(["bookInfo.json", "content.md"])
        let items = try XCTUnwrap(self.items)
        let publisher = try XCTUnwrap(self.publisher)
        let package = book.package.url
        syncAsOneItem(book, package: managed(.notDownloaded, bytes: nil))
        let inCloud = SharedFlag(true)
        let polls = ScriptedPolls([
            {
                items.setStatus(managed(.downloading, bytes: nil), of: package)
                publisher.publish(0.4, of: package)
            },
            { publisher.publish(0.8, of: package) },
            {
                inCloud.set(false)
                items.setStatus(managed(.downloaded, bytes: nil), of: package)
            },
        ])
        let storage = makeStorage(sleep: { try await polls.sleep($0) }, readFolder: listing(refusing: package, while: inCloud))

        let steps = try await collect(storage.download(book.package))

        XCTAssertEqual(steps, [
            BookDownloadProgress(completedFiles: 0, totalFiles: 1, completedBytes: 0, totalBytes: 0),
            BookDownloadProgress(completedFiles: 0, totalFiles: 1, completedBytes: 0, totalBytes: 0, partialFiles: 0.4),
            BookDownloadProgress(completedFiles: 0, totalFiles: 1, completedBytes: 0, totalBytes: 0, partialFiles: 0.8),
            BookDownloadProgress(completedFiles: 2, totalFiles: 2, completedBytes: 0, totalBytes: 0),
        ])
        XCTAssertEqual(steps.map(\.percent), [0, 40, 80, 100])
        XCTAssertEqual(publisher.filesListenedTo, paths([package]))
        XCTAssertEqual(publisher.listeningCount, 0, "a listening outlived the download")
    }

    /// What the sync service publishes for a package as a whole counts for
    /// each of its files still to come, here by size: half the package is
    /// half of each such file, unless a file's own published part is further
    /// along.
    func testAPartPublishedForThePackageCountsForEachFileStillToCome() async throws {
        let book = try makePackage(["audio.m4b", "cover.jpg"])
        let items = try XCTUnwrap(self.items)
        let publisher = try XCTUnwrap(self.publisher)
        syncAsOneItem(book, package: managed(.downloaded, bytes: nil))
        items.setStatus(managed(.notDownloaded, bytes: 900), of: book["audio.m4b"], carriesSyncFlags: false)
        items.setStatus(managed(.notDownloaded, bytes: 100), of: book["cover.jpg"], carriesSyncFlags: false)
        let polls = ScriptedPolls([
            { publisher.publish(0.5, of: book.package.url) },
            { publisher.publish(0.8, of: book["audio.m4b"]) },
            {
                items.setStatus(managed(.downloaded, bytes: 900), of: book["audio.m4b"], carriesSyncFlags: false)
                items.setStatus(managed(.downloaded, bytes: 100), of: book["cover.jpg"], carriesSyncFlags: false)
            },
        ])

        let steps = try await collect(makeStorage(sleep: { try await polls.sleep($0) }).download(book.package))

        XCTAssertEqual(steps.map(\.completedBytes), [0, 500, 770, 1_000])
        XCTAssertEqual(steps.map(\.percent), [0, 50, 77, 100])
    }

    /// A package synced as one item that the sync service is downloading
    /// keeps a stall away, however long it takes: the four quiet checks that
    /// make a two-second stall never come.
    func testAPackageSyncedAsOneItemBeingDownloadedKeepsAStallAway() async throws {
        let book = try makePackage(["content.md"])
        let items = try XCTUnwrap(self.items)
        let package = book.package.url
        syncAsOneItem(book, package: managed(.notDownloaded, bytes: nil))
        let inCloud = SharedFlag(true)
        // Downloading from the first check, for ten checks, then here whole.
        let quiet: @Sendable () -> Void = {}
        var script: [@Sendable () -> Void] = [{ items.setStatus(managed(.downloading, bytes: nil), of: package) }]
        script += Array(repeating: quiet, count: 9)
        script.append {
            inCloud.set(false)
            items.setStatus(managed(.downloaded, bytes: nil), of: package)
        }
        let polls = ScriptedPolls(script)
        let storage = makeStorage(
            sleep: { try await polls.sleep($0) },
            stallLimit: .seconds(2),
            readFolder: listing(refusing: package, while: inCloud)
        )

        let steps = try await collect(storage.download(book.package))

        XCTAssertEqual(polls.sleeps, 11)
        XCTAssertEqual(steps.last?.percent, 100)
    }

    /// A download error the package synced as one item still reports at the
    /// next check ends its download with the service's words.
    func testADownloadErrorThePackageKeepsReportingEndsItsDownload() async throws {
        let book = try makePackage(["content.md"])
        let items = try XCTUnwrap(self.items)
        let package = book.package.url
        syncAsOneItem(book, package: managed(.notDownloaded, bytes: nil))
        let polls = ScriptedPolls([
            { items.setStatus(managed(.notDownloaded, bytes: nil, error: "The disk is full."), of: package) },
        ])
        let storage = makeStorage(
            sleep: { try await polls.sleep($0) },
            readFolder: listing(refusing: package, while: SharedFlag(true))
        )

        _ = await download(storage.download(book.package), failsWith: .provider("The disk is full."))

        XCTAssertEqual(polls.sleeps, 2)
    }

    /// A package whose files carry flags of their own downloads file by
    /// file, its folder's flags notwithstanding, as on Google Drive: the
    /// missing file is asked for, the download listens to the package and to
    /// that file, and the part published for the file counts.
    func testAPackageWhoseFilesCarryFlagsDownloadsFileByFile() async throws {
        let book = try makePackage(["audio.m4b", "bookInfo.json"])
        let items = try XCTUnwrap(self.items)
        let publisher = try XCTUnwrap(self.publisher)
        syncFileByFile(book, files: managed(.downloaded, bytes: 100))
        items.setStatus(managed(.notDownloaded, bytes: 900), of: book["audio.m4b"])
        let polls = ScriptedPolls([
            { publisher.publish(0.5, of: book["audio.m4b"]) },
            { items.setStatus(managed(.downloaded, bytes: 900), of: book["audio.m4b"]) },
        ])

        let steps = try await collect(makeStorage(sleep: { try await polls.sleep($0) }).download(book.package))

        XCTAssertEqual(steps.map(\.percent), [10, 55, 100])
        XCTAssertEqual(paths(items.downloadRequests), paths([book["audio.m4b"]]))
        XCTAssertEqual(publisher.filesListenedTo, paths([book.package.url, book["audio.m4b"]]))
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

    /// Storage on the scripted sync service, writing its events to `events`
    /// and listening to `publisher`. A test that never waits gets a sleep
    /// that fails it.
    private func makeStorage(
        reachability: NetworkReachability = .online,
        sleep: @escaping BookCloudStorageService.Sleep = { _ in XCTFail("this download never waits") },
        stallLimit: Duration = BookCloudStorageService.defaultStallLimit,
        readFolder: @escaping BookCloudStorageService.FolderReader = { try BookCloudStorageService.readFolder($0) }
    ) -> BookCloudStorageService {
        let events = self.events!
        let publisher = self.publisher!
        return BookCloudStorageService(
            items: items,
            reachability: reachability,
            sleep: sleep,
            stallLimit: stallLimit,
            readFolder: readFolder,
            logEvent: { events.record($0) },
            listenForProgress: { file, hear in publisher.listen(to: file, hearing: hear) }
        )
    }

    /// Puts the data directory in iCloud Drive, as the scripted sync service
    /// reports it.
    private func putLibraryInTheCloud() {
        items.setLocation(.cloud(.iCloudDrive), of: TextMouthPaths.root)
    }

    /// Scripts `book` as iCloud Drive syncs a package, as one item: the
    /// package has `status` and carries the sync flags, and each file, on
    /// this Mac and `fileBytes` long, carries none, so the scripted service
    /// refuses a request for one as for an item that doesn't exist.
    private func syncAsOneItem(_ book: TestPackage, package status: CloudItemStatus, fileBytes: Int64 = 10) {
        guard let items = self.items else { return XCTFail("setUp made no scripted sync service") }
        items.setStatus(status, of: book.package.url)
        for file in book.files.values {
            items.setStatus(managed(.downloaded, bytes: fileBytes), of: file, carriesSyncFlags: false)
        }
    }

    /// Scripts `book` as Google Drive syncs a package, file by file: each
    /// file has `status` and carries its own sync flags, and so does the
    /// package's folder, which is on this Mac and reports no size.
    private func syncFileByFile(_ book: TestPackage, files status: CloudItemStatus) {
        guard let items = self.items else { return XCTFail("setUp made no scripted sync service") }
        items.setStatus(managed(.downloaded, bytes: nil), of: book.package.url)
        for file in book.files.values {
            items.setStatus(status, of: file)
        }
    }

    /// A folder listing that refuses to list `folder` while `inCloud` is
    /// on, as the system refuses a folder only in the cloud, and lists every
    /// other folder from the sandbox.
    private func listing(refusing folder: URL, while inCloud: SharedFlag) -> BookCloudStorageService.FolderReader {
        { candidate in
            if inCloud.isOn && samePath(candidate, folder) { throw downloadRefusal }
            return try BookCloudStorageService.readFolder(candidate)
        }
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

// MARK: - Published Progress

/// The progress a sync service publishes for files, scripted by a test: a
/// download listens to it as it would to the system's
/// (`BookCloudStorageService.ProgressListener`), and a fraction the test
/// publishes for a file reaches each of the file's listeners at once. It
/// records which files were listened to, and which listenings are still
/// going.
private final class ScriptedPublisher: @unchecked Sendable {
    /// One listening still going.
    private struct Listener {
        /// The standardized path of the file it listens to.
        let path: String
        /// How it hears a fraction.
        let hear: @Sendable (Double) -> Void
    }

    /// Guards every variable below: downloads listen and stop from their
    /// own threads, and tests publish from theirs.
    private let lock = NSLock()
    /// The listenings still going, by the number each got.
    private var listeners: [Int: Listener] = [:]
    /// The number the next listening gets.
    private var nextNumber = 0
    /// The standardized path of each file listened to, in the order the
    /// listening began.
    private var listenedPaths: [String] = []
    /// Expectations met once no listening is left.
    private var waitingForTheEnd: [XCTestExpectation] = []

    /// Listens to `file`, handing each fraction published for it to `hear`,
    /// until the returned closure is called.
    func listen(to file: URL, hearing hear: @escaping @Sendable (Double) -> Void) -> @Sendable () -> Void {
        let path = file.standardizedFileURL.path
        let number = lock.withLock { () -> Int in
            defer { nextNumber += 1 }
            listeners[nextNumber] = Listener(path: path, hear: hear)
            listenedPaths.append(path)
            return nextNumber
        }
        return { [weak self] in self?.stopListening(number) }
    }

    /// Publishes `fraction` of `file` to each of its listeners.
    func publish(_ fraction: Double, of file: URL) {
        let path = file.standardizedFileURL.path
        // Each hears it outside the lock, so a listener may do anything.
        let hearing = lock.withLock { listeners.values.filter { $0.path == path }.map(\.hear) }
        for hear in hearing {
            hear(fraction)
        }
    }

    /// The standardized paths of the files listened to, in order.
    var filesListenedTo: [String] {
        lock.withLock { listenedPaths }
    }

    /// How many listenings are still going.
    var listeningCount: Int {
        lock.withLock { listeners.count }
    }

    /// An expectation met once no listening is left, or at once when none
    /// is.
    func expectationThatListeningEnds() -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "every listening ended")
        lock.withLock {
            if listeners.isEmpty {
                expectation.fulfill()
            } else {
                waitingForTheEnd.append(expectation)
            }
        }
        return expectation
    }

    /// Ends the listening numbered `number`, meeting the expectations that
    /// wait for the last to end.
    private func stopListening(_ number: Int) {
        lock.withLock {
            listeners[number] = nil
            guard listeners.isEmpty else { return }
            waitingForTheEnd.forEach { $0.fulfill() }
            waitingForTheEnd.removeAll()
        }
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
private struct RefusingRemovals: SyncFlagReporting {
    /// The service that answers everything else.
    let base: FakeCloudItemStatusProvider
    /// What every removal throws.
    let refusal: CocoaError

    func location(of folder: URL) -> StorageLocation { base.location(of: folder) }
    func status(of file: URL) -> CloudItemStatus { base.status(of: file) }
    func flaggedStatus(of item: URL) -> FlaggedItemStatus { base.flaggedStatus(of: item) }
    func requestDownload(of file: URL) throws { try base.requestDownload(of: file) }
    func removeLocalCopy(of file: URL) throws { throw refusal }
}

/// A cloud library whose files are ordinary files on this Mac: every
/// folder is in iCloud Drive, and each file's state, and its flags, are
/// read for real, so no item carries sync flags of its own.
private struct CloudLibraryOnThisMac: SyncFlagReporting {
    /// Reads each file's state from the file system.
    private let files = UbiquitousItemStatusProvider()

    func location(of folder: URL) -> StorageLocation { .cloud(.iCloudDrive) }
    func status(of file: URL) -> CloudItemStatus { files.status(of: file) }
    func flaggedStatus(of item: URL) -> FlaggedItemStatus { files.flaggedStatus(of: item) }
    func requestDownload(of file: URL) throws { XCTFail("nothing is downloaded") }
    func removeLocalCopy(of file: URL) throws { XCTFail("nothing is removed") }
}

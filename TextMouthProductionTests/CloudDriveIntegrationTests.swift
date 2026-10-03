import Darwin
import XCTest
@testable import TextMouth

/// The cloud services against real sync services (FR02): opt-in tests that
/// run only when `TEXTMOUTH_CLOUD_TEST_ROOTS` lists folders named
/// “TextMouth Cloud Tests” on cloud drives (`CloudDriveTestRoots`), and skip
/// otherwise, as in every ordinary run.
///
/// On each listed drive, every test works only inside a new run folder of
/// its own, writes only small test files there (random bytes, or, for the
/// small library, the repository's TestData books), and deletes the folder
/// when it ends, even after a failure. The one exception is asked for by
/// name: with `TEXTMOUTH_CLOUD_TEST_KEEP_SMALL_LIBRARY` set to 1, the small
/// library is built at the top of the test folder and stays. Nothing else
/// on the drive is read, listed, or changed, and the app's library stays in
/// the hosted tests' sandbox.
/// Uploads and downloads are checked once a second, up to a limit
/// (`CloudDriveWait`).
///
/// The tests assert only what the cloud contract promises: the states, the
/// refusal to read without downloading, a download finishing, a clone
/// staying readable, and the run folders going. For each of the plan's open
/// questions they record the answer each drive gave, as an activity with an
/// attachment, and print every answer in one table when the class ends.
///
/// iCloud Drive syncs a book's package as one item: the package carries the
/// sync flags and its files none, and it refuses a request for one of those
/// files. So the tests ask for and remove what the book service would
/// (`syncedItems(of:)`): the package there, each file elsewhere; they count
/// a file without flags as uploaded once its package is (`areUploaded`); and
/// a file counts as only in the cloud when it or its package is dataless.
final class CloudDriveIntegrationTests: XCTestCase {

    /// The folders this run uses, read before each test.
    private var roots: [CloudDriveTestRoot] = []

    /// The file-level status provider the app installs at launch.
    private let items = UbiquitousItemStatusProvider()

    /// The book storage service the app installs at launch, on `items`.
    private var storage: BookCloudStorageService {
        BookCloudStorageService(items: items)
    }

    /// The longest a refusal to read may take and still count as at once:
    /// generous for a busy Mac, and far below any download.
    private static let atOnce: Duration = .seconds(5)

    override func setUp() async throws {
        try await super.setUp()
        roots = try CloudDriveTestRoots.requireRoots()
    }

    /// Prints every answer this run found, in one table naming each drive.
    override class func tearDown() {
        let findings = CloudDriveFindings.shared.all
        if !findings.isEmpty {
            print("CLOUD DRIVE ANSWERS\n\(CloudDriveFindings.table(of: findings))")
        }
        super.tearDown()
    }

    // MARK: - A Book's Round Trip (Steps 1 to 7)

    /// A package of a 5 MB, a 50 KB, and a 1 KB file goes to the cloud and
    /// back on each drive. It uploads; a download request for what is
    /// already here changes nothing; the local copies of the items the drive
    /// syncs, the package as one item on iCloud Drive and each file
    /// elsewhere, can be removed, leaving the files only in the cloud; a
    /// read with downloading switched off is refused at once; the book
    /// service downloads the package again, its progress in order; and a
    /// working copy cloned from it stays readable after the original's local
    /// copies are removed. Answers questions 1 to 5.
    func testABookPackageGoesToTheCloudAndComesBack() async throws {
        await forEachRoot(label: "round-trip") { root, run in
            let package = try SyntheticPackage.write(named: "Round Trip.tmb", in: run)
            let uploaded = try await requireUpload(of: package, on: root)
            try assertDownloadRequestChangesNothing(in: package, on: root)

            let beforeRemoval = package.files.map(FileSnapshot.read)
            let removed: Duration
            do {
                removed = try await removeLocalCopies(of: package, on: root)
            } catch {
                await recordAnswer("No: \(error.localizedDescription)", to: .downloadAndRemovalRequests, on: root)
                throw error
            }
            let whileRemoved = package.files.map(FileSnapshot.read)
            await recordSizes(of: package, whileRemoved: whileRemoved, on: root)
            assertReadIsRefused(of: package.files[0], in: package, on: root)

            let download = await downloadThroughService(package, on: root)
            await recordAnswer(
                requestsAnswer(uploaded: uploaded, removed: removed, download: download, of: package, on: root),
                to: .downloadAndRemovalRequests,
                on: root
            )
            guard download.finished else {
                throw CloudDriveStepFailure(reason: "The package did not come back, so the clone was not tried.")
            }
            let afterDownload = package.files.map(FileSnapshot.read)
            await recordModificationTimes(
                of: package,
                before: beforeRemoval,
                whileRemoved: whileRemoved,
                after: afterDownload,
                on: root
            )
            try await checkCloneAfterRemoval(of: package, on: root)
        }
    }

    // MARK: - A Package Renamed In (Step 8)

    /// A package built in this Mac's Import Staging folder and renamed into
    /// the drive with rename(2), as an import publishes a staged package.
    /// Records whether every file uploads, and whether the book service
    /// then removes the book's download and downloads it again as one book
    /// (question 6).
    func testAPackageRenamedInFromThisMacsFolders() async throws {
        await forEachRoot(label: "renamed") { root, run in
            let staging = MachineLocalPaths.importStaging
                .appendingPathComponent("CloudDriveIntegrationTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: staging) }
            guard ReaderWorkingCopies.isOnSameVolume(staging, as: run) else {
                await recordAnswer(
                    "Not applicable: this Mac's Import Staging folder is on another volume than "
                        + "\(root.driveName)'s folder, so a staged package is copied there, not renamed.",
                    to: .renamedPackage,
                    on: root
                )
                return
            }
            let staged = try SyntheticPackage.write(named: "Renamed.tmb", in: staging)
            let package = staged.moved(to: run.appendingPathComponent("Renamed.tmb", isDirectory: true))
            try Self.renameItem(staged.url, to: package.url)

            let uploaded = try await CloudDriveWait.until(limit: CloudDriveWait.upload) { areUploaded(package.files, on: root) }
            guard let uploaded else {
                await recordAnswer(
                    "Unknown: not every file was reported uploaded within "
                        + "\(CloudDriveWait.describe(CloudDriveWait.upload)) of the rename "
                        + "(\(describeStatuses(of: package.files, in: package.url))).",
                    to: .renamedPackage,
                    on: root
                )
                return
            }
            let removal = await removeDownloadAsOneBook(package, on: root)
            let download = await CloudDriveDownloadRecord.follow(
                storage.download(package.bookPackage),
                limit: CloudDriveWait.download
            )
            let downloaded = download.finished && package.filesNotIntact().isEmpty
            let downloadWords = downloaded
                ? "the book service downloaded them all again in \(CloudDriveWait.describe(download.elapsed))"
                : "the book service's download \(describe(download.outcome, on: root))"
            await recordAnswer(
                "\(removal.succeeded && downloaded ? "Yes" : "Partly"): all \(package.files.count) files uploaded "
                    + "within \(CloudDriveWait.describe(uploaded)) of the rename; \(removal.words); \(downloadWords).",
                to: .renamedPackage,
                on: root
            )
        }
    }

    // MARK: - A Dot-Folder (Step 9)

    /// A file in a dot-folder, `.hidden-test/file.txt`, written beside the
    /// same file in a visible folder: records whether the drive uploads the
    /// hidden one (question 7). The visible one shows how long an upload
    /// takes, so a hidden file still waiting at the limit while the visible
    /// one is up means the drive leaves dot-folders alone.
    func testAFileInADotFolder() async throws {
        await forEachRoot(label: "dot-folder") { root, run in
            let hidden = try Self.writeTextFile(at: run.appendingPathComponent(".hidden-test/file.txt"))
            let visible = try Self.writeTextFile(at: run.appendingPathComponent("visible-test/file.txt"))
            let clock = ContinuousClock()
            let start = clock.now
            var visibleUploaded: Duration?

            let hiddenUploaded = try await CloudDriveWait.until(limit: CloudDriveWait.upload) {
                if visibleUploaded == nil, areUploaded([visible], on: root) {
                    visibleUploaded = clock.now - start
                }
                return areUploaded([hidden], on: root)
            }

            let control = visibleUploaded.map { "the same file in a visible folder uploaded within \(CloudDriveWait.describe($0))" }
                ?? "the same file in a visible folder was not reported uploaded either"
            let answer: String
            if let hiddenUploaded {
                answer = "Yes: .hidden-test/file.txt uploaded within \(CloudDriveWait.describe(hiddenUploaded)); \(control)."
            } else if visibleUploaded != nil {
                answer = "No: .hidden-test/file.txt was not reported uploaded within "
                    + "\(CloudDriveWait.describe(CloudDriveWait.upload)), while \(control) "
                    + "(\(describeStatuses(of: [hidden])))."
            } else {
                answer = "Unknown: within \(CloudDriveWait.describe(CloudDriveWait.upload)), neither file was "
                    + "reported uploaded (\(describeStatuses(of: [hidden, visible])))."
            }
            await recordAnswer(answer, to: .dotFolder, on: root)
        }
    }

    // MARK: - Remove Download While Uploading (Step 10)

    /// A package holding one new 20 MB file, whose download the book service
    /// is asked to remove at once, while the file is still uploading:
    /// records whether it refuses with `notUploaded` (question 8). Best
    /// effort: a fast upload can finish before the call.
    func testRemovingADownloadWhileItUploads() async throws {
        await forEachRoot(label: "uploading") { root, run in
            let package = try SyntheticPackage.write(
                named: "Uploading.tmb",
                in: run,
                files: [.init(name: "large-20MB.bin", byteCount: 20 * 1024 * 1024)]
            )
            let file = package.files[0]
            let flags = Self.metadata(of: file)
            let packageFlags = Self.metadata(of: package.url)

            let answer: String
            do {
                try storage.removeDownload(of: package.bookPackage)
                answer = "No: removeDownload returned without refusing, and the file is now "
                    + "\(items.status(of: file).state)."
            } catch BookCloudError.notUploaded {
                answer = "Yes: removeDownload refused with notUploaded."
            } catch {
                answer = "Not with notUploaded: removeDownload threw \(describe(error, on: root))"
            }
            await recordAnswer(
                "\(answer) Just before the call, the drive reported the file "
                    + "\(Self.describeFlags(flags)), and the package \(Self.describeFlags(packageFlags)).",
                to: .removalWhileUploading,
                on: root
            )
        }
    }

    // MARK: - A Small Library for the Manual Test Matrix

    /// The variable that, set to 1, keeps the small library on each drive
    /// for the manual test matrix, at the top of its test folder.
    private static let keepSmallLibraryVariable = "TEXTMOUTH_CLOUD_TEST_KEEP_SMALL_LIBRARY"

    /// The small library's folder name.
    private static let smallLibraryName = "Small Library"

    /// The library index's file name in a data directory, as the app's
    /// own check for a library names it (`DataDirectoryRequest`).
    private static let libraryIndexName = "library.json"

    /// The ten TestData books of the small library: text in every format
    /// the app reads, and two DAISY books with audio.
    private static let smallLibraryBooks = [
        "alice.epub", "alice.docx", "frankenstein.html", "pride.txt", "sample.md",
        "test_book.docx", "test_formatted.pdf", "test_with_outline.pdf",
        "hyperion_daisy.zip", "lathe_of_heaven_daisy.zip",
    ]

    /// Builds “Small Library”, a ten-book TextMouth library, on each drive,
    /// for the manual test matrix. The books are imported by the app's own
    /// import path inside the sandbox, gathered with a library index and an
    /// identity into a library folder in this Mac's Import Staging folder,
    /// and renamed into the drive, where the app's own check finds a library
    /// to use. Notes how long the drive took to upload it.
    ///
    /// The library is built in the run folder and deleted with it, unless
    /// `TEXTMOUTH_CLOUD_TEST_KEEP_SMALL_LIBRARY` is 1: then it is built at
    /// the top of the test folder and stays there, for a person to choose
    /// with Use This Library. A small library already there is never
    /// replaced.
    func testASmallLibraryForManualTesting() async throws {
        let keep = ProcessInfo.processInfo.environment[Self.keepSmallLibraryVariable] == "1"
        await forEachRoot(label: "small-library") { root, run in
            let library = (keep ? root.folder : run).appendingPathComponent(Self.smallLibraryName, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: library.path) else {
                throw CloudDriveStepFailure(reason: "\(library.path) is there already; remove it to build a new one.")
            }
            let staged = try buildSmallLibrary(toBePublishedAt: library)
            try Self.renameItem(staged, to: library)
            try assertHoldsTheSmallLibrary(library, on: root)

            let files = Self.regularFiles(in: library)
            let bytes = files.compactMap { FileSnapshot.read($0)?.byteCount }.reduce(0, +)
            let uploaded = try await CloudDriveWait.until(limit: CloudDriveWait.upload) { areUploaded(files, on: root) }
            let upload = uploaded.map { "uploaded within \(CloudDriveWait.describe($0))" }
                ?? "not all reported uploaded within \(CloudDriveWait.describe(CloudDriveWait.upload))"
            let note = "\(root.driveName): Small Library, \(Self.smallLibraryBooks.count) books in \(files.count) files "
                + "(\(bytes) bytes), \(upload); "
                + (keep ? "kept at \(library.path)." : "deleted with the run folder.")
            print("CLOUD DRIVE SMALL LIBRARY: \(note)")
            await keepNote(note, as: "\(root.driveName), small library")
        }
    }

    /// Imports the small library's books through the app's own import path
    /// into the sandbox's library, then gathers them into a new library
    /// folder in this Mac's Import Staging folder: their packages in its
    /// Library folder, a library index naming where each book's file will
    /// be once the folder is at `destination`, and a library identity.
    /// Returns the folder, which the test's end removes if it is still
    /// there.
    private func buildSmallLibrary(toBePublishedAt destination: URL) throws -> URL {
        let staging = MachineLocalPaths.importStaging
            .appendingPathComponent("CloudDriveSmallLibrary-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: staging) }
        let folder = staging.appendingPathComponent(Self.smallLibraryName, isDirectory: true)
        let packages = folder.appendingPathComponent(TextMouthPaths.libraryFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: true)
        let publishedPackages = destination.appendingPathComponent(TextMouthPaths.libraryFolderName, isDirectory: true)

        var books: [Book] = []
        for name in Self.smallLibraryBooks {
            var book = try FileImportService.importFile(from: requireFile(name))
            let imported = book.tmbDirectory
            addTeardownBlock { try? FileManager.default.removeItem(at: imported) }
            let packageName = imported.lastPathComponent
            try FileManager.default.moveItem(at: imported, to: packages.appendingPathComponent(packageName, isDirectory: true))
            let published = publishedPackages.appendingPathComponent(packageName, isDirectory: true)
            guard let filePath = Self.relocated(book.filePath, from: imported, to: published) else {
                throw CloudDriveStepFailure(reason: "\(name)'s book file, \(book.filePath), is outside its package.")
            }
            book.filePath = filePath
            books.append(book)
        }
        let index = folder.appendingPathComponent(Self.libraryIndexName, isDirectory: false)
        try Self.libraryIndexData(of: Library(books: books)).write(to: index, options: .withoutOverwriting)
        _ = try LibraryIdentity.adopt(in: folder)
        return folder
    }

    /// Asserts that the folder at `library` holds the small library as the
    /// app would use it: an index of the ten books, each book's file where
    /// the index says, an identity, and the app's own check finding a
    /// library there.
    private func assertHoldsTheSmallLibrary(_ library: URL, on root: CloudDriveTestRoot) throws {
        let drive = root.driveName
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let index = library.appendingPathComponent(Self.libraryIndexName, isDirectory: false)
        let books = try decoder.decode(Library.self, from: Data(contentsOf: index)).books

        XCTAssertEqual(books.count, Self.smallLibraryBooks.count, "\(drive): the index lists \(books.map(\.title))")
        for book in books {
            XCTAssertTrue(book.filePath.hasPrefix(library.path + "/"), "\(drive): \(book.title) is at \(book.filePath)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: book.filePath), "\(drive): \(book.title) has no file")
        }
        XCTAssertNotNil(try LibraryIdentity.read(in: library), "\(drive): the library has no identity")
        XCTAssertEqual(DataDirectoryRequest.reasonToIgnore(library), "it holds a TextMouth library already", drive)
    }

    /// The library index of `library` as the app writes library.json: ISO
    /// 8601 dates, pretty printed, as `LibraryPersistenceService` encodes it.
    private static func libraryIndexData(of library: Library) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        return try encoder.encode(library)
    }

    /// `path`, of the package at `oldPackage` or of a file inside it, at the
    /// same place in the package at `newPackage`; nil for a path outside the
    /// package.
    private static func relocated(_ path: String, from oldPackage: URL, to newPackage: URL) -> String? {
        let old = oldPackage.standardizedFileURL.path
        let new = newPackage.standardizedFileURL.path
        let moving = URL(fileURLWithPath: path).standardizedFileURL.path
        if moving == old {
            return new
        }
        guard moving.hasPrefix(old + "/") else { return nil }
        return new + moving.dropFirst(old.count)
    }

    /// Every regular file inside `folder`, at any depth, hidden ones too.
    private static func regularFiles(in folder: URL) -> [URL] {
        let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        return (items?.allObjects as? [URL] ?? []).filter { item in
            (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
    }

    // MARK: - Running on Each Drive

    /// Runs `body` once for each test root, in a new run folder of its own
    /// that is deleted when the test ends, even after a failure. A failure
    /// on one drive is reported under its name and does not stop the others.
    private func forEachRoot(label: String, _ body: (CloudDriveTestRoot, URL) async throws -> Void) async {
        for root in roots {
            do {
                let run = try CloudDriveRunFolder.make(in: root, label: label)
                addTeardownBlock {
                    do {
                        try CloudDriveRunFolder.remove(run)
                    } catch {
                        XCTFail("\(root.driveName): the run folder \(run.path) could not be deleted: \(error)")
                    }
                    XCTAssertFalse(
                        FileManager.default.fileExists(atPath: run.path),
                        "\(root.driveName): the run folder \(run.path) is still there"
                    )
                }
                try await body(root, run)
            } catch {
                XCTFail("\(root.driveName): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Uploads

    /// Waits, within the upload limit, until the sync service reports every
    /// file of `package` uploaded, and returns how long that took. Throws
    /// when the limit runs out: nothing after it can be tested without a
    /// copy in the cloud.
    private func requireUpload(of package: SyntheticPackage, on root: CloudDriveTestRoot) async throws -> Duration {
        let files = package.files
        guard let elapsed = try await CloudDriveWait.until(limit: CloudDriveWait.upload, { areUploaded(files, on: root) }) else {
            throw CloudDriveStepFailure(
                reason: "\(files.count) new files were not reported uploaded within "
                    + "\(CloudDriveWait.describe(CloudDriveWait.upload)). Is \(root.driveName) running, "
                    + "signed in, and not paused? \(describeStatuses(of: files, in: package.url))"
            )
        }
        for file in files {
            let status = items.status(of: file)
            XCTAssertEqual(status.state, .downloaded, "\(root.driveName): \(file.lastPathComponent)")
            XCTAssertTrue(status.isUploaded, "\(root.driveName): \(file.lastPathComponent)")
        }
        return elapsed
    }

    /// Whether the sync service reports each of `files` uploaded: by the
    /// file's own flags or, for a file that carries none, as inside an
    /// iCloud Drive package, by the flags of the package holding it, looked
    /// for inside `root`'s folder only (`CloudDriveUploads`). The flags
    /// count as the system gives them, so a drive that says nothing about
    /// uploading never counts as done, where the status provider would read
    /// a missing flag as uploaded.
    private func areUploaded(_ files: [URL], on root: CloudDriveTestRoot) -> Bool {
        files.allSatisfy { file in
            let package = CloudDriveUploads.package(holding: file, inside: root.folder)
            return CloudDriveUploads.isUploaded(file: Self.metadata(of: file), package: package.flatMap(Self.metadata(of:)))
        }
    }

    /// The items the book service asks for and removes for `package`: the
    /// package itself where the drive syncs it as one item (iCloud Drive),
    /// and otherwise each of its files (`BookCloudStorageService.Survey`).
    private func syncedItems(of package: SyntheticPackage) throws -> [URL] {
        try storage.survey(of: package.bookPackage).syncedItems.map(\.url)
    }

    /// Whether `file` of `package` is only in the cloud: it reads as not
    /// downloaded, and it, or its package, is dataless. iCloud Drive makes a
    /// package it syncs as one item dataless whole, and then nothing inside
    /// it can be looked up.
    private func isInCloud(_ file: URL, of package: SyntheticPackage) -> Bool {
        items.status(of: file).state == .notDownloaded
            && (DatalessFiles.isDataless(file) || DatalessFiles.isDataless(package.url))
    }

    /// What the status provider reads of `file`, its flags as the system
    /// gives them, read without downloading; nil when it cannot be read.
    private static func metadata(of file: URL) -> UbiquitousItemStatusProvider.Metadata? {
        DatalessFiles.withoutDownloading {
            try? UbiquitousItemStatusProvider.readFreshMetadata(of: file, keys: UbiquitousItemStatusProvider.statusKeys)
        }
    }

    // MARK: - Steps 2 to 4

    /// Step 2: asking the sync service to download the items it syncs of a
    /// package already on this Mac (`syncedItems(of:)`) neither fails nor
    /// changes its files.
    private func assertDownloadRequestChangesNothing(in package: SyntheticPackage, on root: CloudDriveTestRoot) throws {
        for item in try syncedItems(of: package) {
            XCTAssertNoThrow(try items.requestDownload(of: item), "\(root.driveName): \(item.lastPathComponent)")
        }
        for file in package.files {
            XCTAssertEqual(items.status(of: file).state, .downloaded, "\(root.driveName): \(file.lastPathComponent)")
            XCTAssertFalse(DatalessFiles.isDataless(file), "\(root.driveName): \(file.lastPathComponent)")
        }
        XCTAssertEqual(package.filesNotIntact(), [], "\(root.driveName): a download request changed files")
    }

    /// Step 3: asks the sync service to remove the local copy of each item
    /// it syncs of `package` (`removeLocalCopy`), the package itself or each
    /// file, then waits, within the removal limit, until every file is only
    /// in the cloud (`isInCloud(_:of:)`). Returns how long that took; throws
    /// when a removal is refused or does not happen in time.
    private func removeLocalCopies(of package: SyntheticPackage, on root: CloudDriveTestRoot) async throws -> Duration {
        let clock = ContinuousClock()
        let start = clock.now
        for item in try syncedItems(of: package) {
            do {
                try items.removeLocalCopy(of: item)
            } catch {
                throw CloudDriveStepFailure(
                    reason: "\(root.driveName) refused to remove the local copy of \(item.lastPathComponent): "
                        + CloudDriveFindings.describe(error)
                )
            }
        }
        let removed = try await CloudDriveWait.until(limit: CloudDriveWait.removal) {
            package.files.allSatisfy { isInCloud($0, of: package) }
        }
        guard removed != nil else {
            throw CloudDriveStepFailure(
                reason: "Local copies were still on this Mac \(CloudDriveWait.describe(CloudDriveWait.removal)) "
                    + "after their removal was asked for: \(describeStatuses(of: package.files, in: package.url))"
            )
        }
        return clock.now - start
    }

    /// Step 4: a read of a file of `package` only in the cloud, with
    /// downloading switched off, fails at once with the download refusal,
    /// and the file stays in the cloud.
    private func assertReadIsRefused(of file: URL, in package: SyntheticPackage, on root: CloudDriveTestRoot) {
        let clock = ContinuousClock()
        let start = clock.now
        let read = DatalessFiles.withoutDownloading { Result { try Data(contentsOf: file) } }
        let elapsed = clock.now - start

        switch read {
        case .success:
            XCTFail("\(root.driveName): \(file.lastPathComponent) was read with downloading switched off")
        case .failure(let error):
            XCTAssertTrue(
                DatalessFiles.isDownloadRefusal(error),
                "\(root.driveName): not the download refusal: \(CloudDriveFindings.describe(error))"
            )
        }
        XCTAssertLessThan(elapsed, Self.atOnce, "\(root.driveName): the refusal took \(elapsed)")
        XCTAssertTrue(isInCloud(file, of: package), "\(root.driveName): the refused read downloaded the file")
    }

    // MARK: - Step 5: Downloading Through the Book Service

    /// Step 5: downloads `package` through the book service, listening
    /// meanwhile for the progress the system publishes for its files and for
    /// the package as a whole (question 2), and records with it the
    /// percentages the book service reported, which fold in what it heard.
    /// Asserts that the progress came in order and that the download
    /// finished with every file on this Mac, holding what was written.
    private func downloadThroughService(_ package: SyntheticPackage, on root: CloudDriveTestRoot) async -> CloudDriveDownloadRecord {
        let listenedTo = package.files + [package.url]
        let published = PublishedProgressRecorder()
        published.subscribe(to: listenedTo)
        let download = await CloudDriveDownloadRecord.follow(
            storage.download(package.bookPackage),
            limit: CloudDriveWait.download
        )
        published.stop()
        let percents = download.updates.map { "\($0.percent)" }.joined(separator: ", ")
        await recordAnswer(
            "\(published.summary(of: listenedTo)) The book service reported \(percents.isEmpty ? "no" : percents) percent.",
            to: .publishedProgress,
            on: root
        )
        assertFinished(download, of: package, on: root)
        return download
    }

    /// Asserts that `download` finished with every file of `package` on
    /// this Mac, holding what was written, and that its progress came in
    /// order and ended complete.
    private func assertFinished(_ download: CloudDriveDownloadRecord, of package: SyntheticPackage, on root: CloudDriveTestRoot) {
        let drive = root.driveName
        guard download.finished else {
            return XCTFail(
                "\(drive): the download \(describe(download.outcome, on: root)) after "
                    + "\(CloudDriveWait.describe(download.elapsed)), with progress \(download.updates)"
            )
        }
        XCTAssertFalse(download.updates.isEmpty, "\(drive): the download reported no progress")
        XCTAssertTrue(download.isInOrder, "\(drive): the progress went back: \(download.updates)")
        XCTAssertEqual(download.updates.last?.completedFiles, package.files.count, "\(drive): \(download.updates)")
        XCTAssertEqual(download.updates.last?.totalFiles, package.files.count, "\(drive): \(download.updates)")
        XCTAssertEqual(download.updates.last?.percent, 100, "\(drive): \(download.updates)")
        for file in package.files {
            XCTAssertEqual(items.status(of: file).state, .downloaded, "\(drive): \(file.lastPathComponent)")
            XCTAssertFalse(DatalessFiles.isDataless(file), "\(drive): \(file.lastPathComponent)")
        }
        XCTAssertEqual(package.filesNotIntact(), [], "\(drive): files differ after the download")
    }

    // MARK: - Step 7: A Working Copy

    /// Step 7 (question 5): clones the downloaded package into a Working
    /// Copies folder as an audiobook's reader does, removes the original
    /// files' local copies, and reads the clone with downloading switched
    /// off: every file must still hold what was written.
    private func checkCloneAfterRemoval(of package: SyntheticPackage, on root: CloudDriveTestRoot) async throws {
        let copiesFolder = MachineLocalPaths.workingCopies
            .appendingPathComponent("CloudDriveIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: copiesFolder) }
        let copies = ReaderWorkingCopies(folder: copiesFolder)

        let result = DatalessFiles.withoutDownloading {
            copies.makeCopy(of: package.bookPackage, isDataless: DatalessFiles.isDataless)
        }

        guard let copy = result.copy else {
            if ReaderWorkingCopies.isOnSameVolume(package.url, as: copiesFolder) {
                XCTFail("\(root.driveName): no working copy was made: \(result)")
                await recordAnswer("Unknown: no clone could be made (\(result)).", to: .cloneAfterEviction, on: root)
            } else {
                await recordAnswer(
                    "Not applicable: \(root.driveName)'s folder is on another volume than this Mac's "
                        + "Working Copies folder, so no clone is made.",
                    to: .cloneAfterEviction,
                    on: root
                )
            }
            return
        }
        let removed = try await removeLocalCopies(of: package, on: root)
        let unreadable = package.filesNotIntact(at: copy.location(of:))

        XCTAssertEqual(unreadable, [], "\(root.driveName): the clone lost files when the original's local copies went")
        await recordAnswer(
            unreadable.isEmpty
                ? "Yes: every file of the clone read in full, with downloading switched off, after the "
                    + "original's \(package.files.count) local copies were removed (within \(CloudDriveWait.describe(removed)))."
                : "No: the clone's \(unreadable.joined(separator: ", ")) could not be read in full after the "
                    + "original's local copies were removed.",
            to: .cloneAfterEviction,
            on: root
        )
        try copy.remove()
    }

    // MARK: - Step 8: Removing a Download as One Book

    /// Asks the book service to remove `package`'s download, as Remove
    /// Download does, and waits, within the removal limit, for every file
    /// to be only in the cloud (`isInCloud(_:of:)`). Returns whether that
    /// happened, and what happened in words.
    private func removeDownloadAsOneBook(_ package: SyntheticPackage, on root: CloudDriveTestRoot) async -> (succeeded: Bool, words: String) {
        do {
            try storage.removeDownload(of: package.bookPackage)
            let removed = try await CloudDriveWait.until(limit: CloudDriveWait.removal) {
                package.files.allSatisfy { isInCloud($0, of: package) }
            }
            guard let removed else {
                return (
                    false,
                    "after Remove Download, files were still on this Mac (\(describeStatuses(of: package.files, in: package.url)))"
                )
            }
            return (true, "Remove Download left all of them dataless within \(CloudDriveWait.describe(removed))")
        } catch {
            return (false, "Remove Download failed: \(describe(error, on: root))")
        }
    }

    // MARK: - Recording Answers

    /// Records question 3: the sizes lstat and the status provider report
    /// for each removed file, beside its real size.
    private func recordSizes(of package: SyntheticPackage, whileRemoved snapshots: [FileSnapshot?], on root: CloudDriveTestRoot) async {
        let real: [Int64?] = package.files.map { file in package.contents[file.lastPathComponent].map { Int64($0.count) } }
        let listed = snapshots.map { $0?.byteCount }
        let reported = package.files.map { items.status(of: $0).byteCount }
        let verdict: String
        if listed == real && reported == real {
            verdict = "The real size"
        } else if (listed + reported).allSatisfy({ $0 == 0 }) {
            verdict = "0"
        } else if (listed + reported).allSatisfy({ $0 == nil }) {
            // iCloud Drive makes a package it syncs as one item dataless
            // whole, and then nothing inside it can be looked up.
            verdict = "Unknown: no file could be looked up while its package was only in the cloud"
        } else {
            verdict = "Not always the real size"
        }
        await recordAnswer(
            "\(verdict): real sizes \(Self.list(real)); lstat \(Self.list(listed)); status \(Self.list(reported)).",
            to: .evictedFileSize,
            on: root
        )
    }

    /// Records question 4: each file's modification time, to the
    /// nanosecond, before its local copy was removed, while it was removed,
    /// and after the download.
    private func recordModificationTimes(
        of package: SyntheticPackage,
        before: [FileSnapshot?],
        whileRemoved: [FileSnapshot?],
        after: [FileSnapshot?],
        on root: CloudDriveTestRoot
    ) async {
        /// The modification times of `snapshots`, "none" where no file was.
        func times(_ snapshots: [FileSnapshot?]) -> [String] {
            snapshots.map { $0?.modificationTime ?? "none" }
        }
        let kept = times(before) == times(after) && !before.contains(nil)
        let details = package.files.indices.map { index in
            "\(package.files[index].lastPathComponent) \(times(before)[index]) before, "
                + "\(times(whileRemoved)[index]) removed, \(times(after)[index]) after"
        }
        await recordAnswer(
            "\(kept ? "Yes, to the nanosecond" : "No"): \(details.joined(separator: "; ")).",
            to: .modificationTime,
            on: root
        )
    }

    /// The answer to question 1, from how the upload, the removals, and the
    /// download went.
    private func requestsAnswer(
        uploaded: Duration,
        removed: Duration,
        download: CloudDriveDownloadRecord,
        of package: SyntheticPackage,
        on root: CloudDriveTestRoot
    ) -> String {
        let removal = "after the upload (within \(CloudDriveWait.describe(uploaded))), evictUbiquitousItem left all "
            + "\(package.files.count) files dataless within \(CloudDriveWait.describe(removed))"
        guard download.finished else {
            return "Removal yes, download no: \(removal), but the book service's download "
                + "(startDownloadingUbiquitousItem) \(describe(download.outcome, on: root))."
        }
        return "Yes: \(removal), and startDownloadingUbiquitousItem, through the book service, brought them all "
            + "back within \(CloudDriveWait.describe(download.elapsed))."
    }

    /// How a download ended, in words.
    private func describe(_ outcome: CloudDriveDownloadRecord.Outcome, on root: CloudDriveTestRoot) -> String {
        switch outcome {
        case .finished:
            return "finished"
        case .failed(let error):
            return "failed: \(describe(error, on: root))"
        case .timedOut:
            return "was still waiting at the \(CloudDriveWait.describe(CloudDriveWait.download)) limit"
        }
    }

    /// `error` in words: a cloud error as the app explains it, any other
    /// with its domain and code.
    private func describe(_ error: Error, on root: CloudDriveTestRoot) -> String {
        if let cloudError = error as? BookCloudError {
            return "\(cloudError) (“\(cloudError.explanation(in: root.provider))”)"
        }
        return CloudDriveFindings.describe(error)
    }

    /// Each of `files` with its state and the drive's flags, for messages,
    /// after the flags of `package`, the package holding them, when given:
    /// on iCloud Drive only the package carries flags.
    private func describeStatuses(of files: [URL], in package: URL? = nil) -> String {
        let packageWords = package.map { ["\($0.lastPathComponent) (the package): \(Self.describeFlags(Self.metadata(of: $0)))"] }
        let fileWords = files.map { file in
            "\(file.lastPathComponent): \(items.status(of: file).state), \(Self.describeFlags(Self.metadata(of: file)))"
        }
        return ((packageWords ?? []) + fileWords).joined(separator: "; ")
    }

    /// An item's sync flags as the drive reported them, in words.
    private static func describeFlags(_ metadata: UbiquitousItemStatusProvider.Metadata?) -> String {
        guard let metadata else { return "unreadable" }
        /// A flag's value, or "unreported".
        func flag(_ value: Bool?) -> String {
            value.map { "\($0)" } ?? "unreported"
        }
        return "managed \(flag(metadata.isUbiquitousItem)), uploaded \(flag(metadata.isUploaded)), "
            + "dataless \(metadata.isDataless)"
    }

    /// `sizes` as "5242880, 51200, 1024", with "none" for an unknown size.
    private static func list(_ sizes: [Int64?]) -> String {
        sizes.map { $0.map { "\($0)" } ?? "none" }.joined(separator: ", ")
    }

    // MARK: - Files

    /// Renames `source` to `destination` with rename(2), as a staged import
    /// is published; throws the system's error when it fails.
    private static func renameItem(_ source: URL, to destination: URL) throws {
        let failure = source.withUnsafeFileSystemRepresentation { from -> Int32 in
            destination.withUnsafeFileSystemRepresentation { to -> Int32 in
                guard let from, let to else { return EINVAL }
                return Darwin.rename(from, to) == 0 ? 0 : errno
            }
        }
        guard failure == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
    }

    /// Writes a line of text to a new file at `url`, making its folder, and
    /// returns `url`.
    private static func writeTextFile(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: false)
        try Data("TextMouth cloud test \(UUID().uuidString)\n".utf8).write(to: url, options: .withoutOverwriting)
        return url
    }
}

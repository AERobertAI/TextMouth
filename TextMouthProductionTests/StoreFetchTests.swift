import XCTest
@testable import TextMouth

/// A book fetched from the store onto a device that lacks it (FR43, section
/// 6): checked against each blob's name and size, staged, then moved in, the
/// device's own record kept, a stop resumed, and a damaged blob never in the package.
final class StoreFetchTests: XCTestCase {
    /// A made-up book.
    private let bookID = UUID(uuidString: "55555555-5555-5555-5555-555555555555") ?? UUID()

    /// A world: one device backed a book up, another holds a placeholder for it.
    private struct World {
        var drive: SyncTestDrive
        var fetch: StoreFetch
        var backup: StoreBackupResult
        var placeholder: URL
        var original: URL
    }

    /// Backs up a book of three files and makes the other device's placeholder.
    private func makeWorld() throws -> World {
        let sandbox = try makeSandboxDirectory("store-fetch")
        let original = sandbox.appendingPathComponent("A.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try Data("the book's text, long enough to matter".utf8).write(to: original.appendingPathComponent("book.txt"))
        try Data("{\"title\":\"Theirs\"}".utf8).write(to: original.appendingPathComponent("bookInfo.json"))
        try Data("an index".utf8).write(to: original.appendingPathComponent("contentIndex.json"))
        let drive = SyncTestDrive(root: sandbox.appendingPathComponent("cloud", isDirectory: true))
        let folder = SyncFolder(root: drive.root, access: drive)
        let storeID = UUID()
        let backup = try StoreBackup(folder: folder, storeID: storeID, staging: sandbox.appendingPathComponent("StagingA")).back(up: original, bookID: bookID)

        // The other device: its own record, and a pointer naming the manifest, every file away.
        let placeholder = sandbox.appendingPathComponent("B.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: placeholder, withIntermediateDirectories: true)
        try Data("{\"title\":\"Mine\"}".utf8).write(to: placeholder.appendingPathComponent("bookInfo.json"))
        let pointer = StoreFetch.placeholderPointer(storeID: storeID, manifestName: backup.manifestName, manifest: backup.manifest)
        try StoreFetch.write(pointer, in: placeholder)
        let fetch = StoreFetch(folder: folder, storeID: storeID, staging: sandbox.appendingPathComponent("StagingB"))
        return World(drive: drive, fetch: fetch, backup: backup, placeholder: placeholder, original: original)
    }

    /// A placeholder is missing files, and says how many bytes a fetch needs.
    func testAPlaceholderIsMissingFilesAndKnowsItsSize() throws {
        let world = try makeWorld()
        XCTAssertTrue(StoreFetch.isMissingFiles(world.placeholder))
        XCTAssertEqual(StoreFetch.bytesToFetch(world.placeholder), world.backup.manifest.files.reduce(0) { $0 + $1.size })
        XCTAssertFalse(StoreFetch.isMissingFiles(world.original.deletingLastPathComponent()), "a folder without a pointer is whole")
    }

    /// A fetch brings in every file, byte for byte, and keeps the device's own record.
    func testFetchBringsTheBookAndKeepsTheRecord() async throws {
        let world = try makeWorld()
        let reported = ProgressLog()
        let contentPath = try await world.fetch.fetch(package: world.placeholder) { files, bytes, _, _ in reported.add(files, bytes) }
        XCTAssertEqual(contentPath, "book.txt", "the content file keeps the name it had where it was backed up")
        XCTAssertEqual(try Data(contentsOf: world.placeholder.appendingPathComponent("book.txt")), try Data(contentsOf: world.original.appendingPathComponent("book.txt")))
        XCTAssertEqual(try String(contentsOf: world.placeholder.appendingPathComponent("bookInfo.json"), encoding: .utf8), "{\"title\":\"Mine\"}", "the device's own record")
        XCTAssertFalse(StoreFetch.isMissingFiles(world.placeholder))
        XCTAssertEqual(reported.files.last, 3)
        XCTAssertEqual(reported.files, reported.files.sorted(), "progress only goes up")
        XCTAssertEqual(StoreFetch.bytesToFetch(world.placeholder), 0)
    }

    /// A blob that doesn't match its name is refused and never reaches the package.
    func testADamagedBlobIsRefused() async throws {
        let world = try makeWorld()
        let text = try XCTUnwrap(world.backup.manifest.files.first { $0.path == "book.txt" })
        let blob = world.fetch.folder.bookFolder(bookID).appendingPathComponent(text.blob)
        try world.drive.write(Data("tampered, and a different size".utf8), to: blob, replacing: true)
        do {
            try await world.fetch.fetch(package: world.placeholder)
            XCTFail("a damaged blob")
        } catch { XCTAssertEqual(error as? SyncProblem, .damaged(file: text.blob)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: world.placeholder.appendingPathComponent("book.txt").path))
    }

    /// A blob not downloaded stops the fetch at once offline, or at the limit; the next fetch goes on from there.
    func testAStopResumesWhereItLeftOff() async throws {
        let world = try makeWorld()
        let text = try XCTUnwrap(world.backup.manifest.files.first { $0.path == "book.txt" })
        world.drive.setNotDownloaded(text.blob)
        world.drive.setOffline(true)
        do {
            try await world.fetch.fetch(package: world.placeholder)
            XCTFail("offline")
        } catch { XCTAssertEqual(error as? SyncProblem, .offline) }
        // Files before the stop stay; the pointer says which.
        let partial = try XCTUnwrap(StoreFetch.pointer(in: world.placeholder))
        XCTAssertTrue(StoreFetch.isMissingFiles(world.placeholder))
        XCTAssertEqual(partial.files.first { $0.path == "book.txt" }?.onThisDevice, false)

        world.drive.setNotDownloaded(text.blob, false)
        world.drive.setOffline(false)
        try await world.fetch.fetch(package: world.placeholder)
        XCTAssertFalse(StoreFetch.isMissingFiles(world.placeholder))
    }

    /// A manifest path that would leave the package is refused, and nothing is written outside it.
    func testAManifestPathLeavingThePackageIsRefused() async throws {
        let world = try makeWorld()
        var hostile = world.backup.manifest
        hostile.files[0].path = "../escape.txt"
        let data = try SyncFormats.encode(hostile)
        let name = StoreBackup.manifestName(for: data)
        try world.drive.write(data, to: world.fetch.folder.bookFolder(bookID).appendingPathComponent(name), replacing: false)
        var pointer = try XCTUnwrap(StoreFetch.pointer(in: world.placeholder))
        pointer.manifest = name
        try StoreFetch.write(pointer, in: world.placeholder)
        do {
            try await world.fetch.fetch(package: world.placeholder)
            XCTFail("a path leaving the package")
        } catch { XCTAssertEqual(error as? SyncProblem, .damaged(file: "../escape.txt")) }
        let outside = world.placeholder.deletingLastPathComponent().appendingPathComponent("escape.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    /// A manifest whose bytes are not what its name says is refused.
    func testAManifestThatIsNotItsNameIsRefused() async throws {
        let world = try makeWorld()
        let url = world.fetch.folder.bookFolder(bookID).appendingPathComponent(world.backup.manifestName)
        try world.drive.write(Data("{\"formatVersion\":1}".utf8), to: url, replacing: true)
        do {
            try await world.fetch.fetch(package: world.placeholder)
            XCTFail("a swapped manifest")
        } catch { XCTAssertEqual(error as? SyncProblem, .damaged(file: world.backup.manifestName)) }
    }

    /// What may be fetched: relative plain paths, a digest, a blob named by it.
    func testWhatIsSafeToFetch() {
        let digest = String(repeating: "a", count: 64)
        func file(_ path: String, blob: String? = nil, sha: String? = nil) -> StoreManifest.File {
            StoreManifest.File(path: path, sha256: sha ?? digest, blob: blob ?? digest + ".epub", role: "content", size: 1)
        }
        XCTAssertTrue(StoreFetch.isSafe(file("book.epub")))
        XCTAssertTrue(StoreFetch.isSafe(file("tracks/01.mp3")))
        XCTAssertFalse(StoreFetch.isSafe(file("../x")))
        XCTAssertFalse(StoreFetch.isSafe(file("a/../../x")))
        XCTAssertFalse(StoreFetch.isSafe(file("/etc/passwd")))
        XCTAssertFalse(StoreFetch.isSafe(file("a//b")))
        XCTAssertFalse(StoreFetch.isSafe(file("")))
        XCTAssertFalse(StoreFetch.isSafe(file("book.epub", blob: "../" + digest + ".epub")))
        XCTAssertFalse(StoreFetch.isSafe(file("book.epub", blob: "other.epub")))
        XCTAssertFalse(StoreFetch.isSafe(file("book.epub", sha: "short")))
    }

    /// A placeholder made from a row alone, with an empty file list, is missing files: Download Now through
    /// the book storage fetches them, with the manifest's totals, and the book is whole afterwards.
    func testAnEmptyPointerIsMissingAndDownloadNowFetchesIt() async throws {
        let world = try makeWorld()
        var pointer = try XCTUnwrap(StoreFetch.pointer(in: world.placeholder))
        pointer.files = []
        try StoreFetch.write(pointer, in: world.placeholder)
        XCTAssertTrue(StoreFetch.isMissingFiles(world.placeholder), "an empty list is not complete")
        XCTAssertNil(StoreFetch.bytesToFetch(world.placeholder), "the manifest knows the size, the pointer does not")

        let fetch = world.fetch
        let storage = StoreBookStorage(wrapping: LocalBookStorage(), isSyncOn: { true }) { package in
            AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        try await fetch.fetch(package: package.url) { files, bytes, totalFiles, totalBytes in
                            continuation.yield(BookDownloadProgress(completedFiles: files, totalFiles: totalFiles, completedBytes: bytes, totalBytes: totalBytes))
                        }
                        continuation.finish()
                    } catch { continuation.finish(throwing: error) }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        let package = BookPackage(bookID: bookID, url: world.placeholder, isPackage: true, isAudio: false)
        XCTAssertEqual(storage.state(of: package), .inCloud)
        var last: BookDownloadProgress?
        for try await progress in storage.download(package) { last = progress }
        XCTAssertEqual(last?.totalFiles, world.backup.manifest.files.count, "totals come from the manifest")
        XCTAssertEqual(last?.percent, 100)
        XCTAssertFalse(StoreFetch.isMissingFiles(world.placeholder))
        XCTAssertEqual(storage.state(of: package), .local)
    }

    /// A fetch stopped part way still reads as missing files, goes on from where it stopped, and fetches only the rest;
    /// until then opening the book takes the download path (the storage says In Cloud).
    func testAPartialFetchReadsAsMissingAndResumes() async throws {
        let world = try makeWorld()
        var pointer = try XCTUnwrap(StoreFetch.pointer(in: world.placeholder))
        pointer.files = []
        try StoreFetch.write(pointer, in: world.placeholder)
        let storage = StoreBookStorage(wrapping: LocalBookStorage(), isSyncOn: { true })
        let package = BookPackage(bookID: bookID, url: world.placeholder, isPackage: true, isAudio: false)

        // The last file's blob has not arrived: the fetch stops after the others.
        let last = try XCTUnwrap(world.backup.manifest.files.last)
        world.drive.setNotDownloaded(last.blob)
        do {
            try await world.fetch.fetch(package: world.placeholder)
            XCTFail("the last blob is not here")
        } catch { XCTAssertEqual(error as? SyncProblem, .notDownloaded(device: bookID.uuidString.lowercased())) }

        XCTAssertTrue(StoreFetch.isMissingFiles(world.placeholder), "a stopped fetch is not a whole book")
        XCTAssertEqual(storage.state(of: package), .inCloud, "opening it takes the download path")
        let listed = try XCTUnwrap(StoreFetch.pointer(in: world.placeholder)).files
        XCTAssertEqual(listed.count, world.backup.manifest.files.count, "every file is listed from the start")
        XCTAssertEqual(listed.filter(\.onThisDevice).count, listed.count - 1)

        // It arrives: the next fetch fetches only the rest.
        world.drive.setNotDownloaded(last.blob, false)
        let reported = ProgressLog()
        try await world.fetch.fetch(package: world.placeholder) { files, bytes, _, _ in reported.add(files, bytes) }
        XCTAssertEqual(reported.files, [world.backup.manifest.files.count], "only the last file was fetched")
        XCTAssertFalse(StoreFetch.isMissingFiles(world.placeholder))
        XCTAssertEqual(storage.state(of: package), .local)
    }

    /// A book edited on another device (the same path, new bytes) is fetched again: the old text is never marked present
    /// under the new digest.
    func testAChangedFileIsFetchedAgainAndTheOldBytesAreNotMarkedPresent() async throws {
        let world = try makeWorld()
        try await world.fetch.fetch(package: world.placeholder)
        let old = try Data(contentsOf: world.placeholder.appendingPathComponent("book.txt"))
        XCTAssertEqual(old, Data("the book's text, long enough to matter".utf8))

        // The text is edited where the book came from, and backed up again: a new manifest.
        try Data("the edited text".utf8).write(to: world.original.appendingPathComponent("book.txt"))
        let backup = StoreBackup(folder: world.fetch.folder, storeID: world.fetch.storeID, staging: world.fetch.staging.appendingPathComponent("again"))
        let second = try backup.back(up: world.original, bookID: bookID)
        XCTAssertNotEqual(second.manifestName, world.backup.manifestName)
        var pointer = try XCTUnwrap(StoreFetch.pointer(in: world.placeholder))
        pointer.manifest = second.manifestName
        try StoreFetch.write(pointer, in: world.placeholder)

        let reported = ProgressLog()
        try await world.fetch.fetch(package: world.placeholder) { files, bytes, _, _ in reported.add(files, bytes) }
        XCTAssertEqual(try Data(contentsOf: world.placeholder.appendingPathComponent("book.txt")), Data("the edited text".utf8))
        let listed = try XCTUnwrap(StoreFetch.pointer(in: world.placeholder)).files
        let book = try XCTUnwrap(listed.first { $0.path == "book.txt" })
        XCTAssertEqual(book.sha256, second.manifest.files.first { $0.path == "book.txt" }?.sha256, "recorded under the new digest")
        XCTAssertTrue(book.onThisDevice)
        XCTAssertEqual(reported.files, [3], "only the changed file was fetched again: the other two already matched the manifest")
    }

    /// While sync is off the book storage reads no pointer: a placeholder's package is answered as the live storage does.
    func testNoPointerIsReadWhileSyncIsOff() throws {
        let world = try makeWorld()
        let storage = StoreBookStorage(wrapping: LocalBookStorage(), isSyncOn: { false })
        let package = BookPackage(bookID: bookID, url: world.placeholder, isPackage: true, isAudio: false)
        XCTAssertEqual(storage.state(of: package), .local)
        XCTAssertNil(storage.bytesToDownload(of: package))
        let on = StoreBookStorage(wrapping: LocalBookStorage(), isSyncOn: { true })
        XCTAssertEqual(on.state(of: package), .inCloud)
    }

    /// A pointer of another store is not fetched.
    func testAnotherStoreIsRefused() async throws {
        var world = try makeWorld()
        world.fetch = StoreFetch(folder: world.fetch.folder, storeID: UUID(), staging: world.fetch.staging)
        do {
            try await world.fetch.fetch(package: world.placeholder)
            XCTFail("another store")
        } catch { XCTAssertEqual(error as? SyncProblem, .anotherStore) }
    }

    /// A cancelled fetch stops between files and leaves the pointer true.
    func testCancellationStopsBetweenFiles() async throws {
        let world = try makeWorld()
        // The task starts only once it is cancelled, so a fetch that ignored cancellation would bring every file.
        let task = Task { () -> String? in
            while !Task.isCancelled { await Task.yield() }
            return try await world.fetch.fetch(package: world.placeholder)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled fetch went on")
        } catch is CancellationError {
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(StoreFetch.isMissingFiles(world.placeholder), "nothing was fetched")
        // Whatever the pointer claims is here, is here.
        for file in StoreFetch.pointer(in: world.placeholder)?.files ?? [] where file.onThisDevice {
            XCTAssertTrue(FileManager.default.fileExists(atPath: world.placeholder.appendingPathComponent(file.path).path), file.path)
        }
    }
}

/// Collects the fetch's progress reports.
///
/// `@unchecked Sendable`: `values` is read and changed only under `lock`.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func add(_ files: Int, _ bytes: Int64) { lock.lock(); values.append(files); lock.unlock() }
    var files: [Int] { lock.lock(); defer { lock.unlock() }; return values }
}

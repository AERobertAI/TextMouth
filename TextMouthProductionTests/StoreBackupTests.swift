import XCTest
@testable import TextMouth

/// A book's backup into the store (FR43, section 8): blobs named by their
/// SHA-256 and never copied twice or over a file, a manifest that leaves out
/// the pointer and caches, the order and the budget, and what a crash
/// halfway leaves.
final class StoreBackupTests: XCTestCase {
    /// A made-up book.
    private let bookID = UUID(uuidString: "44444444-4444-4444-4444-444444444444") ?? UUID()

    /// A package with a content file, a record, and things the manifest leaves out.
    private func makePackage(in sandbox: URL, content: String = "Chapter one.") throws -> URL {
        let package = sandbox.appendingPathComponent("Book.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("cachedAudio"), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: package.appendingPathComponent("book.epub"))
        try Data("{\"title\":\"T\"}".utf8).write(to: package.appendingPathComponent("bookInfo.json"))
        try Data("text".utf8).write(to: package.appendingPathComponent("content.md"))
        try Data("junk".utf8).write(to: package.appendingPathComponent(".DS_Store"))
        try Data("cache".utf8).write(to: package.appendingPathComponent("cachedAudio/a.caf"))
        return package
    }

    /// A package whose book file is a ZIP with an encrypted entry, beside its derived text and
    /// the plain copy a password removal leaves while it writes.
    private func makeProtectedPackage(in sandbox: URL) throws -> URL {
        let package = sandbox.appendingPathComponent("Locked.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let zip = try makeTemporaryZip(prefix: "locked", entries: ["a.txt": Data("words".utf8)])
        try FileManager.default.moveItem(at: zip, to: package.appendingPathComponent("book.epub"))
        try markEncrypted(["a.txt"], in: package.appendingPathComponent("book.epub"))
        for (name, text) in [
            ("bookInfo.json", "{\"title\":\"T\"}"), ("content.md", "plain words"), ("content.md.edited-1", "plain words"),
            ("contentIndex.json", "{\"headings\":[\"Zebra\"]}"), (".unprotecting-ABC", "the whole book, plain")
        ] {
            try Data(text.utf8).write(to: package.appendingPathComponent(name))
        }
        return package
    }

    /// A protected book's backup holds neither its derived text nor a password removal's plain copy;
    /// the same files around an unprotected book are backed up (bar the plain copy, which never is).
    func testAProtectedBooksDerivedTextAndPlainCopyAreNotBackedUp() throws {
        let sandbox = try makeSandboxDirectory("store-backup-protected")
        let (backup, _) = makeBackup(sandbox)
        let locked = try makeProtectedPackage(in: sandbox)
        let result = try backup.back(up: locked, bookID: bookID)
        XCTAssertEqual(result.manifest.files.map(\.path), ["book.epub", "bookInfo.json"])

        // The control: with no password the derived text goes, so the omission above is the protection's.
        let plain = try makePackage(in: sandbox)
        try Data("{}".utf8).write(to: plain.appendingPathComponent("contentIndex.json"))
        try Data("x".utf8).write(to: plain.appendingPathComponent(".unprotecting-ABC"))
        let other = try backup.back(up: plain, bookID: UUID())
        XCTAssertEqual(other.manifest.files.map(\.path), ["book.epub", "bookInfo.json", "content.md", "contentIndex.json"])
    }

    /// The plain copy of a password removal is left out wherever it sits, so a sync during the removal never copies it.
    func testThePlainCopyOfAPasswordRemovalIsLeftOut() {
        XCTAssertTrue(StoreBackup.isLeftOut(".unprotecting-8F2C"))
        XCTAssertTrue(StoreBackup.isLeftOut("sub/.unprotecting-8F2C"))
        XCTAssertFalse(StoreBackup.isLeftOut("book.epub"))
    }

    /// A backup into a fresh sandbox drive.
    private func makeBackup(_ sandbox: URL) -> (backup: StoreBackup, drive: SyncTestDrive) {
        let drive = SyncTestDrive(root: sandbox.appendingPathComponent("cloud", isDirectory: true))
        let folder = SyncFolder(root: drive.root, access: drive)
        return (StoreBackup(folder: folder, storeID: UUID(), staging: sandbox.appendingPathComponent("Staging", isDirectory: true)), drive)
    }

    /// The names of the files of a drive's folder.
    private func names(_ drive: SyncTestDrive, _ url: URL) throws -> [String] {
        try drive.list(url).map(\.name)
    }

    /// Blobs are named by SHA-256; the manifest lists content, record and other, and nothing else.
    func testBackupWritesBlobsAndAManifest() throws {
        let sandbox = try makeSandboxDirectory("store-backup")
        let package = try makePackage(in: sandbox)
        let (backup, drive) = makeBackup(sandbox)
        let result = try backup.back(up: package, bookID: bookID)
        XCTAssertEqual(result.manifest.files.map(\.path), ["book.epub", "bookInfo.json", "content.md"])
        XCTAssertEqual(result.manifest.files.map(\.role), ["content", "record", "other"])
        for file in result.manifest.files {
            XCTAssertTrue(SyncNames.isDigest(file.sha256))
            XCTAssertTrue(file.blob.hasPrefix(file.sha256))
        }
        let digest = try FileDigest.sha256(of: package.appendingPathComponent("book.epub"))
        XCTAssertEqual(result.manifest.files[0].sha256, digest)
        XCTAssertEqual(result.manifest.files[0].blob, digest + ".epub")
        let stored = try names(drive, backup.folder.bookFolder(bookID))
        XCTAssertTrue(stored.contains(digest + ".epub"))
        XCTAssertTrue(stored.contains(result.manifestName))
        XCTAssertEqual(stored.count, 4, "three blobs and a manifest")
    }

    /// The pointer names the manifest and the files, and is not itself in the manifest.
    func testPointerIsWrittenAndLeftOutOfTheManifest() throws {
        let sandbox = try makeSandboxDirectory("store-backup-pointer")
        let package = try makePackage(in: sandbox)
        let (backup, _) = makeBackup(sandbox)
        let result = try backup.back(up: package, bookID: bookID)
        let pointer = try SyncValueCoding.makeDecoder().decode(StorePointer.self, from: Data(contentsOf: package.appendingPathComponent(StorePointer.fileName)))
        XCTAssertEqual(pointer.manifest, result.manifestName)
        XCTAssertNil(pointer.uploaded)
        XCTAssertTrue(pointer.files.allSatisfy(\.onThisDevice))
        // A second backup: the pointer is not a file of the manifest, so the manifest is the same.
        let again = try backup.back(up: package, bookID: bookID)
        XCTAssertEqual(again.manifestName, result.manifestName)
    }

    /// A blob already there isn't copied again, and a second backup copies nothing.
    func testNothingIsCopiedTwice() throws {
        let sandbox = try makeSandboxDirectory("store-backup-twice")
        let package = try makePackage(in: sandbox)
        let (backup, drive) = makeBackup(sandbox)
        let first = try backup.back(up: package, bookID: bookID)
        XCTAssertGreaterThan(first.bytesCopied, 0)
        let copiedBefore = drive.copiedNames.count
        let second = try backup.back(up: package, bookID: bookID)
        XCTAssertEqual(second.bytesCopied, 0)
        XCTAssertEqual(drive.copiedNames.count, copiedBefore)
        // The same text in another book is the same blob.
        let other = UUID()
        let copy = try makePackage(in: try makeSandboxDirectory("store-backup-copy"))
        _ = try backup.back(up: copy, bookID: other)
        XCTAssertEqual(try names(drive, backup.folder.bookFolder(other)).filter { $0.hasSuffix(".epub") }.count, 1)
    }

    /// An edited file gets a new blob and manifest, and the old ones stay (nothing is written over).
    func testAnEditMakesNewFilesAndKeepsTheOld() throws {
        let sandbox = try makeSandboxDirectory("store-backup-edit")
        let package = try makePackage(in: sandbox)
        let (backup, drive) = makeBackup(sandbox)
        let first = try backup.back(up: package, bookID: bookID)
        try Data("Chapter one, edited.".utf8).write(to: package.appendingPathComponent("book.epub"))
        let second = try backup.back(up: package, bookID: bookID)
        XCTAssertNotEqual(first.manifestName, second.manifestName)
        let stored = try names(drive, backup.folder.bookFolder(bookID))
        XCTAssertTrue(stored.contains(first.manifestName))
        XCTAssertTrue(stored.contains(second.manifestName))
    }

    /// A bookInfo.json change alone makes no new manifest.
    func testARecordChangeAloneNeedsNoNewManifest() throws {
        let files = [
            StoreManifest.File(path: "book.epub", sha256: "a", blob: "a.epub", role: "content", size: 1),
            StoreManifest.File(path: "bookInfo.json", sha256: "b", blob: "b.json", role: "record", size: 1),
        ]
        let manifest = StoreManifest(formatVersion: 1, bookID: bookID, files: files)
        var changed = files
        changed[1].sha256 = "c"
        XCTAssertFalse(StoreBackup.needsNewManifest(existing: manifest, files: changed))
        changed[0].sha256 = "d"
        XCTAssertTrue(StoreBackup.needsNewManifest(existing: manifest, files: changed))
        XCTAssertTrue(StoreBackup.needsNewManifest(existing: nil, files: files))
    }

    /// A package holding a symbolic link isn't backed up, and nothing is copied.
    func testASymbolicLinkRefusesTheBook() throws {
        let sandbox = try makeSandboxDirectory("store-backup-link")
        let package = try makePackage(in: sandbox)
        try FileManager.default.createSymbolicLink(at: package.appendingPathComponent("link.epub"), withDestinationURL: package.appendingPathComponent("book.epub"))
        let (backup, drive) = makeBackup(sandbox)
        XCTAssertThrowsError(try backup.back(up: package, bookID: bookID)) {
            XCTAssertEqual($0 as? SyncProblem, .damaged(file: "link.epub"))
        }
        XCTAssertTrue(drive.copiedNames.isEmpty)
    }

    /// A book that doesn't fit the budget is refused before anything is copied.
    func testBudgetRefusesBeforeCopying() throws {
        let sandbox = try makeSandboxDirectory("store-backup-budget")
        let package = try makePackage(in: sandbox)
        let (backup, drive) = makeBackup(sandbox)
        XCTAssertThrowsError(try backup.back(up: package, bookID: bookID, budget: 5)) {
            XCTAssertEqual($0 as? StoreBackup.BudgetError, .overBudget)
        }
        XCTAssertTrue(drive.copiedNames.isEmpty)
    }

    /// The budget is 2 GB, or the free space less 1 GB when that is less.
    func testBudgetLimit() {
        XCTAssertEqual(StoreBackupBudget.limit(freeSpace: 100_000_000_000), 2_000_000_000)
        XCTAssertEqual(StoreBackupBudget.limit(freeSpace: 2_500_000_000), 1_500_000_000)
        XCTAssertEqual(StoreBackupBudget.limit(freeSpace: 500_000_000), 0)
    }

    /// Text books go first, then smaller first, the same way every run.
    func testOrder() {
        let a = StoreBackupCandidate(bookID: UUID(), isText: false, bytes: 10)
        let b = StoreBackupCandidate(bookID: UUID(), isText: true, bytes: 500)
        let c = StoreBackupCandidate(bookID: UUID(), isText: true, bytes: 5)
        XCTAssertEqual(StoreBackup.order([a, b, c]), [c, b, a])
    }

    /// A copy interrupted halfway, then run afresh, leaves no partial blob and nothing doubled.
    func testInterruptedBackupResumes() throws {
        let sandbox = try makeSandboxDirectory("store-backup-interrupt")
        let package = try makePackage(in: sandbox)
        let (backup, drive) = makeBackup(sandbox)
        drive.failCopies(after: 1)
        XCTAssertThrowsError(try backup.back(up: package, bookID: bookID))
        drive.failCopies(after: nil)
        let result = try backup.back(up: package, bookID: bookID)
        let stored = try names(drive, backup.folder.bookFolder(bookID))
        XCTAssertEqual(stored.count, 4)
        XCTAssertEqual(Set(drive.copiedNames).count, drive.copiedNames.count, "no blob went twice")
        XCTAssertTrue(stored.contains(result.manifestName))
    }

    /// Uploaded once the drive says so, uploading while any file is, failed with its reason; evicted after.
    func testUploadStatesAndEviction() throws {
        let sandbox = try makeSandboxDirectory("store-backup-upload")
        let package = try makePackage(in: sandbox)
        let (backup, drive) = makeBackup(sandbox)
        let result = try backup.back(up: package, bookID: bookID)
        drive.setUpload(.uploading)
        XCTAssertEqual(backup.uploadState(of: result, bookID: bookID), .uploading)
        drive.setUpload(.uploaded)
        drive.setUpload(.failed(.outOfSpace), forName: result.manifestName)
        XCTAssertEqual(backup.uploadState(of: result, bookID: bookID), .failed(.outOfSpace))
        drive.setUpload(.notReported, forName: result.manifestName)
        XCTAssertEqual(backup.uploadState(of: result, bookID: bookID), .uploaded)
        drive.setUpload(.notReported)
        XCTAssertEqual(backup.uploadState(of: result, bookID: bookID), .notReported)

        try backup.markUploaded(package: package, bookID: bookID, result: result)
        let pointer = try SyncValueCoding.makeDecoder().decode(StorePointer.self, from: Data(contentsOf: package.appendingPathComponent(StorePointer.fileName)))
        XCTAssertEqual(pointer.uploaded, result.manifestName)
        XCTAssertEqual(backup.evictBlobs(of: result, bookID: bookID), result.uploadNames.count)
    }
}

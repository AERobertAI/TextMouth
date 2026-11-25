import XCTest
@testable import TextMouth

/// `PhoneSyncFolderAccess` (FR43), on the iPhone's file system and its
/// coordinator: listing, reading, staged writes and clones, the upload flags,
/// the bookmark, and the mapping of the system's errors. Every folder is a
/// new one in the test's own temporary folder, which is a plain local folder:
/// no test touches iCloud Drive or the person's library, and none deletes
/// anything (the system clears its temporary folder).
final class PhoneSyncFolderAccessTests: XCTestCase {
    /// A new, empty folder in the temporary folder.
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("phone-sync-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// An access over a bookmark of `folder`; the network is as `online` says.
    private func makeAccess(for folder: URL, online: Bool = true) throws -> PhoneSyncFolderAccess {
        PhoneSyncFolderAccess(
            bookmark: try PhoneSyncFolderAccess.makeBookmark(of: folder),
            reachability: NetworkReachability { online },
            writeLimit: .seconds(10)
        )
    }

    // MARK: - The Bookmark

    /// A bookmark finds the folder again, and the body runs with its URL.
    func testTheBookmarkFindsTheFolder() async throws {
        let folder = try makeFolder()
        let access = try makeAccess(for: folder)
        let found = try await access.withFolder { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        XCTAssertEqual(found, folder.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    /// Data that is no bookmark is a missing folder, not a trap.
    func testADamagedBookmarkIsAMissingFolder() async {
        let access = PhoneSyncFolderAccess(bookmark: Data([1, 2, 3]))
        do {
            _ = try await access.withFolder { _ in 0 }
            XCTFail("a damaged bookmark found a folder")
        } catch {
            XCTAssertEqual(error as? SyncProblem, .folderMissing)
        }
    }

    // MARK: - Listing

    /// Files are listed by name with their sizes, on this device.
    func testListsFilesWithTheirSizes() throws {
        let folder = try makeFolder()
        try Data(count: 10).write(to: folder.appendingPathComponent("a.json"))
        let items = try makeAccess(for: folder).list(folder)
        XCTAssertEqual(items, [SyncFolderItem(name: "a.json", size: 10, isOnThisDevice: true)])
    }

    /// iCloud Drive's hidden stand-in for a file only in the cloud is listed under the file's own name, off this device.
    func testAStandInIsListedUnderTheRealName() throws {
        let folder = try makeFolder()
        try Data().write(to: folder.appendingPathComponent(".0001.changes.json.icloud"))
        let items = try makeAccess(for: folder).list(folder)
        XCTAssertEqual(items, [SyncFolderItem(name: "0001.changes.json", size: nil, isOnThisDevice: false)])
    }

    /// Only a real stand-in name is read as one.
    func testNameBehindStandIn() {
        XCTAssertEqual(PhoneSyncFolderAccess.nameBehindStandIn(".a.json.icloud"), "a.json")
        XCTAssertNil(PhoneSyncFolderAccess.nameBehindStandIn("a.json"))
        XCTAssertNil(PhoneSyncFolderAccess.nameBehindStandIn(".hidden"))
        XCTAssertNil(PhoneSyncFolderAccess.nameBehindStandIn(".icloud"))
        XCTAssertNil(PhoneSyncFolderAccess.nameBehindStandIn("..icloud"))
    }

    /// A folder that isn't there is `.folderMissing`.
    func testListingAMissingFolder() throws {
        let folder = try makeFolder().appendingPathComponent("gone", isDirectory: true)
        XCTAssertThrowsError(try makeAccess(for: folder).list(folder)) {
            XCTAssertEqual($0 as? SyncProblem, .folderMissing)
        }
    }

    // MARK: - Writing and Reading

    /// A write is read back whole; a second write without `replacing` is `.exists` and leaves the file as it was.
    func testWriteNeverReplacesUnlessAsked() async throws {
        let folder = try makeFolder()
        let access = try makeAccess(for: folder)
        let file = folder.appendingPathComponent("store.json")
        try access.write(Data("one".utf8), to: file, replacing: false)
        XCTAssertThrowsError(try access.write(Data("two".utf8), to: file, replacing: false)) {
            XCTAssertEqual($0 as? SyncProblem, .exists)
        }
        let afterRefusal = try await access.read(file, within: .seconds(5))
        XCTAssertEqual(afterRefusal, Data("one".utf8))
        try access.write(Data("three".utf8), to: file, replacing: true)
        let afterReplacing = try await access.read(file, within: .seconds(5))
        XCTAssertEqual(afterReplacing, Data("three".utf8))
    }

    /// A copy-in puts the file's bytes at the destination and never over a file already there.
    func testCopyInNeverReplaces() async throws {
        let folder = try makeFolder()
        let access = try makeAccess(for: folder)
        let source = folder.appendingPathComponent("source.bin")
        try Data("blob".utf8).write(to: source)
        let destination = folder.appendingPathComponent("copy.bin")
        try access.copyIn(source, to: destination)
        let copied = try await access.read(destination, within: .seconds(5))
        XCTAssertEqual(copied, Data("blob".utf8))
        XCTAssertThrowsError(try access.copyIn(source, to: destination)) {
            XCTAssertEqual($0 as? SyncProblem, .exists)
        }
    }

    /// A file that isn't there is not downloaded yet, naming the device whose folder it is in.
    func testReadingAFileThatIsNotThere() async throws {
        let folder = try makeFolder().appendingPathComponent("device-1", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let access = try makeAccess(for: folder)
        do {
            _ = try await access.read(folder.appendingPathComponent("0001.changes.json"), within: .seconds(5))
            XCTFail("a missing file was read")
        } catch {
            XCTAssertEqual(error as? SyncProblem, .notDownloaded(device: "device-1"))
        }
    }

    /// Offline matters only for a file that isn't on the phone: one that is there reads at once.
    func testAFileOnThePhoneReadsWhileOffline() async throws {
        let folder = try makeFolder()
        let file = folder.appendingPathComponent("a.json")
        try Data("x".utf8).write(to: file)
        let data = try await makeAccess(for: folder, online: false).read(file, within: .seconds(5))
        XCTAssertEqual(data, Data("x".utf8))
    }

    // MARK: - Upload State and Errors

    /// A file no sync service manages reports no upload state, so a copy there counts as sent.
    func testALocalFileReportsNoUploadState() throws {
        let folder = try makeFolder()
        let file = folder.appendingPathComponent("a.json")
        try Data("x".utf8).write(to: file)
        XCTAssertEqual(try makeAccess(for: folder).uploadState(of: file), .notReported)
    }

    /// The system's errors become the plan's problems; one of ours passes through, and any other error is left as it is.
    func testErrorsBecomeProblems() {
        let outOfSpace = CocoaError(.fileWriteOutOfSpace)
        let noFile = CocoaError(.fileReadNoSuchFile)
        let cancelled = CocoaError(.userCancelled)
        XCTAssertEqual(PhoneSyncFolderAccess.problem(for: outOfSpace, whenMissing: .folderMissing) as? SyncProblem, .outOfSpace)
        XCTAssertEqual(PhoneSyncFolderAccess.problem(for: noFile, whenMissing: .folderMissing) as? SyncProblem, .folderMissing)
        XCTAssertEqual(
            PhoneSyncFolderAccess.problem(for: cancelled, whenMissing: .folderMissing, whenCancelled: .offline) as? SyncProblem,
            .offline
        )
        XCTAssertEqual(PhoneSyncFolderAccess.problem(for: SyncProblem.exists, whenMissing: .folderMissing) as? SyncProblem, .exists)
        let other = CocoaError(.fileReadCorruptFile)
        XCTAssertEqual((PhoneSyncFolderAccess.problem(for: other, whenMissing: .folderMissing) as NSError).code, other.errorCode)
    }

    /// A coordination that finishes in time returns its value, and its timer cancels nothing.
    func testBoundedCoordinationReturnsItsValue() throws {
        let value = try PhoneSyncFolderAccess.runCoordinated(within: .seconds(30)) { _ in 42 }
        XCTAssertEqual(value, 42)
    }
}

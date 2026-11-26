import XCTest
@testable import TextMouth

/// `PhoneSyncFolderAccess` (FR43), on the iPhone's file system and its
/// coordinator: the bookmark and its renewal, the folder moved or deleted,
/// listing, staged writes and copies into folders not yet made, a fetch that
/// never reads a blob whole, the upload flags, and the mapping of the system's
/// errors. Every folder is a new one in the test's own temporary folder, a plain
/// local folder: no test touches iCloud Drive or the person's library, and none
/// deletes anything (the system clears its temporary folder).
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
            pollInterval: .milliseconds(20)
        )
    }

    /// The path of `url` with links resolved, so two spellings of one place compare equal.
    private func canonical(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    // MARK: - The Bookmark

    /// A bookmark finds the folder again, and the body runs with its URL.
    func testTheBookmarkFindsTheFolder() async throws {
        let folder = try makeFolder()
        let access = try makeAccess(for: folder)
        let found = try await access.withFolder { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        XCTAssertEqual(found, canonical(folder))
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

    /// A stale bookmark is renewed, whatever the system thinks of it: the resolver and the maker are stand-ins that say it is
    /// stale; a current one is not renewed, and one that finds nothing throws `.folderMissing` and renews nothing.
    func testAStaleBookmarkIsRenewed() throws {
        let place = URL(fileURLWithPath: "/Users/reader/Library/Mobile Documents/com~apple~CloudDocs/TextMouth Sync", isDirectory: true)
        let fresh = Data([9, 9])
        var made: [URL] = []
        let renewed = try PhoneSyncFolderAccess.renewedBookmark(
            for: Data([1]),
            resolving: { _ in (place, true) },
            making: { made.append($0); return fresh }
        )
        XCTAssertEqual(renewed, fresh)
        XCTAssertEqual(made, [place])
        XCTAssertNil(try PhoneSyncFolderAccess.renewedBookmark(for: Data([1]), resolving: { _ in (place, false) }, making: { _ in fresh }))
        XCTAssertThrowsError(
            try PhoneSyncFolderAccess.renewedBookmark(for: Data([1]), resolving: { _ in throw SyncProblem.folderMissing })
        ) { XCTAssertEqual($0 as? SyncProblem, .folderMissing) }
    }

    /// The case the plan cares about: the folder was picked, so its bookmark was made while it was there, and later it was
    /// moved. (Nothing is deleted: a move leaves the old place empty as a deletion does, and the bookmark follows the folder.)
    /// The old place is a missing folder for a listing and for a read, never a system error, and the bookmark still finds the
    /// folder at its new place.
    func testAMovedFolderIsMissingWhereItWasAndFoundWhereItWent() async throws {
        let parent = try makeFolder()
        let original = parent.appendingPathComponent("TextMouth Sync", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let file = original.appendingPathComponent("store.json")
        try Data("x".utf8).write(to: file)
        // As the picker would: the bookmark is made while the folder is there.
        let access = try makeAccess(for: original)

        let moved = parent.appendingPathComponent("Moved Away", isDirectory: true)
        try FileManager.default.moveItem(at: original, to: moved)

        XCTAssertThrowsError(try access.list(original)) { XCTAssertEqual($0 as? SyncProblem, .folderMissing) }
        do {
            _ = try await access.read(file, within: .seconds(5))
            XCTFail("a file of a moved folder was read where it was")
        } catch {
            XCTAssertEqual(error as? SyncProblem, .folderMissing)
        }
        let found = try await access.withFolder { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        XCTAssertEqual(found, canonical(moved))
    }

    /// A bookmark that now names something that is not a folder is a missing folder, not a trap or a system error.
    func testABookmarkOfAFileIsNotAFolder() async throws {
        let file = try makeFolder().appendingPathComponent("not-a-folder.txt")
        try Data("x".utf8).write(to: file)
        let access = PhoneSyncFolderAccess(bookmark: try PhoneSyncFolderAccess.makeBookmark(of: file))
        do {
            _ = try await access.withFolder { _ in 0 }
            XCTFail("a file was opened as the sync folder")
        } catch {
            XCTAssertEqual(error as? SyncProblem, .folderMissing)
        }
    }

    /// A folder deleted in Files is moved to Recently Deleted and the bookmark follows it there, yet it is gone as a sync
    /// folder: a path through `.Trash` or Recently Deleted is missing. (The place is made in the sandbox; where iOS really
    /// keeps it is a hand check.)
    func testAFolderInTheTrashIsMissing() async throws {
        let trashed = try makeFolder().appendingPathComponent(".Trash", isDirectory: true).appendingPathComponent("TextMouth Sync", isDirectory: true)
        try FileManager.default.createDirectory(at: trashed, withIntermediateDirectories: true)
        let access = PhoneSyncFolderAccess(bookmark: try PhoneSyncFolderAccess.makeBookmark(of: trashed))
        do {
            _ = try await access.withFolder { _ in 0 }
            XCTFail("a deleted folder was still the sync folder")
        } catch {
            XCTAssertEqual(error as? SyncProblem, .folderMissing)
        }
    }

    // MARK: - Listing

    /// Files are listed by name with their sizes, on this device; hidden names, which are never the store's, are left out.
    func testListsFilesWithTheirSizesAndDropsHiddenNames() throws {
        let folder = try makeFolder()
        try Data(count: 10).write(to: folder.appendingPathComponent("a.json"))
        try Data(count: 3).write(to: folder.appendingPathComponent(".DS_Store"))
        let items = try makeAccess(for: folder).list(folder)
        XCTAssertEqual(items, [SyncFolderItem(name: "a.json", size: 10, isOnThisDevice: true)])
    }

    /// iCloud Drive's hidden stand-in for a file only in the cloud is listed under the file's own name, off this device.
    func testAStandInIsListedUnderTheRealName() throws {
        let folder = try makeFolder()
        try Data().write(to: folder.appendingPathComponent(".0001.changes.json.icloud"))
        let items = try makeAccess(for: folder).list(folder)
        XCTAssertEqual(items.map(\.name), ["0001.changes.json"])
        XCTAssertEqual(items.map(\.isOnThisDevice), [false])
    }

    /// A folder that isn't there is `.folderMissing`. (The bookmark is of a folder that exists, since a bookmark of none can't
    /// be made; the one listed is not there.)
    func testListingAMissingFolder() throws {
        let parent = try makeFolder()
        let folder = parent.appendingPathComponent("gone", isDirectory: true)
        XCTAssertThrowsError(try makeAccess(for: parent).list(folder)) { XCTAssertEqual($0 as? SyncProblem, .folderMissing) }
    }

    // MARK: - Writing into Folders Not Made Yet

    /// The store writes into folders it has not made, as the Mac's access allows: a first `Devices/<id>/device.json`, and a
    /// blob's folder. Both folders are made, and the files are whole.
    func testWriteAndCopyMakeTheFileFolder() async throws {
        let root = try makeFolder()
        let access = try makeAccess(for: root)
        let device = root.appendingPathComponent("Devices/abc/device.json")
        try access.write(Data("device".utf8), to: device, replacing: true)
        let written = try await access.read(device, within: .seconds(5))
        XCTAssertEqual(written, Data("device".utf8))

        let source = root.appendingPathComponent("source.bin")
        try Data("blob".utf8).write(to: source)
        let blob = root.appendingPathComponent("Books/b1/abcdef.epub")
        try access.copyIn(source, to: blob)
        let copied = try await access.read(blob, within: .seconds(5))
        XCTAssertEqual(copied, Data("blob".utf8))
    }

    /// A blob is made whole under a hidden name and moved in: after a copy nothing hidden is left beside it, and a copy that
    /// fails (its source is not there) leaves nothing under the final name, which the backup would trust.
    func testACopyLeavesNoHalfFile() throws {
        let root = try makeFolder()
        let access = try makeAccess(for: root)
        let blobFolder = root.appendingPathComponent("Books/b1", isDirectory: true)
        let source = root.appendingPathComponent("source.bin")
        try Data("blob".utf8).write(to: source)
        try access.copyIn(source, to: blobFolder.appendingPathComponent("good.epub"))
        XCTAssertThrowsError(try access.copyIn(root.appendingPathComponent("not-there.bin"), to: blobFolder.appendingPathComponent("bad.epub")))
        let names = try FileManager.default.contentsOfDirectory(atPath: blobFolder.path).sorted()
        XCTAssertEqual(names, ["good.epub"])
    }

    /// A write is read back whole; a second write without `replacing` is `.exists` and leaves the file as it was.
    func testWriteNeverReplacesUnlessAsked() async throws {
        let folder = try makeFolder()
        let access = try makeAccess(for: folder)
        let file = folder.appendingPathComponent("store.json")
        try access.write(Data("one".utf8), to: file, replacing: false)
        XCTAssertThrowsError(try access.write(Data("two".utf8), to: file, replacing: false)) { XCTAssertEqual($0 as? SyncProblem, .exists) }
        let afterRefusal = try await access.read(file, within: .seconds(5))
        XCTAssertEqual(afterRefusal, Data("one".utf8))
        try access.write(Data("three".utf8), to: file, replacing: true)
        let afterReplacing = try await access.read(file, within: .seconds(5))
        XCTAssertEqual(afterReplacing, Data("three".utf8))
    }

    /// A copy-in never goes over a file already there.
    func testCopyInNeverReplaces() throws {
        let folder = try makeFolder()
        let access = try makeAccess(for: folder)
        let source = folder.appendingPathComponent("source.bin")
        try Data("blob".utf8).write(to: source)
        let destination = folder.appendingPathComponent("copy.bin")
        try access.copyIn(source, to: destination)
        XCTAssertThrowsError(try access.copyIn(source, to: destination)) { XCTAssertEqual($0 as? SyncProblem, .exists) }
    }

    // MARK: - Reading and Fetching

    /// A large book is copied out of the folder to a file, never read whole into memory: a fetch makes the destination's
    /// folder and copies the bytes there. (That nothing sits in memory is the copy's own; the fetch is the Mac's, which the
    /// phone now shares, where the default would have read the blob through `read`.)
    func testAFetchCopiesToAFileInANewFolder() async throws {
        let folder = try makeFolder()
        let access = try makeAccess(for: folder)
        let blob = folder.appendingPathComponent("Books/b1/abc.epub")
        try access.write(Data(repeating: 7, count: 1_000_000), to: blob, replacing: false)
        let destination = folder.appendingPathComponent("elsewhere/b1/abc.epub")
        try await access.fetch(blob, to: destination, within: .seconds(5))
        XCTAssertEqual(try Data(contentsOf: destination).count, 1_000_000)
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

    /// The system's errors become the plan's problems; one of ours passes through, a permission refusal means the folder can
    /// no longer be reached, and any other error is left as it is.
    func testErrorsBecomeProblems() {
        func problem(_ error: Error) -> SyncProblem? {
            PhoneSyncFolderAccess.problem(for: error, missing: .notDownloaded(device: "d")) as? SyncProblem
        }
        XCTAssertEqual(problem(CocoaError(.fileWriteOutOfSpace)), .outOfSpace)
        XCTAssertEqual(problem(CocoaError(.fileReadNoSuchFile)), .notDownloaded(device: "d"))
        XCTAssertEqual(problem(CocoaError(.fileReadNoPermission)), .folderMissing)
        XCTAssertEqual(problem(CocoaError(.fileWriteNoPermission)), .folderMissing)
        XCTAssertEqual(problem(CocoaError(.userCancelled)), .notDownloaded(device: "d"))
        XCTAssertEqual(problem(SyncProblem.exists), .exists)
        let other = CocoaError(.fileReadCorruptFile)
        XCTAssertNil(problem(other))
        XCTAssertEqual((PhoneSyncFolderAccess.problem(for: other, missing: .folderMissing) as NSError).code, other.errorCode)
    }
}

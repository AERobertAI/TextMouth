import XCTest
@testable import TextMouth

/// The Mac's access to the sync folder (FR43), on real files in the test's
/// sandbox: the folder found by its bookmark, listing that never downloads,
/// writes that never go over a file but `device.json`'s, and the states of a
/// plain local folder, which reports no upload state at all.
final class PlainSyncFolderAccessTests: XCTestCase {
    /// An access to a new sandbox folder, and the folder.
    private func makeAccess() throws -> (access: PlainSyncFolderAccess, folder: URL) {
        let folder = try makeSandboxDirectory("plain-access").appendingPathComponent("TextMouth Sync", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bookmark = try XCTUnwrap(DataDirectoryPreferences.makeBookmark(of: folder))
        return (PlainSyncFolderAccess(bookmark: bookmark), folder)
    }

    /// The bookmark leads to the folder, and the body gets its URL.
    func testWithFolderFindsTheFolder() async throws {
        let (access, folder) = try makeAccess()
        let found = try await access.withFolder { $0.standardizedFileURL.path }
        XCTAssertEqual(found, folder.standardizedFileURL.path)
    }

    /// A bookmark that leads nowhere, or whose folder is gone, is a missing folder.
    func testAMissingFolderIsSaid() async throws {
        let broken = PlainSyncFolderAccess(bookmark: Data("not a bookmark".utf8))
        do {
            _ = try await broken.withFolder { $0 }
            XCTFail("no folder")
        } catch { XCTAssertEqual(error as? SyncProblem, .folderMissing) }
    }

    /// Listing names the files with their sizes, leaves hidden files out, and says each is here.
    func testListNamesFilesAndSkipsHiddenOnes() throws {
        let (access, folder) = try makeAccess()
        try Data("abc".utf8).write(to: folder.appendingPathComponent("a.json"))
        try Data("x".utf8).write(to: folder.appendingPathComponent(".DS_Store"))
        let items = try access.list(folder)
        XCTAssertEqual(items, [SyncFolderItem(name: "a.json", size: 3, isOnThisDevice: true)])
    }

    /// A file written is read back; one that is there is not written over, except when replacing is asked for.
    func testWriteNeverGoesOverAFileUnlessAskedTo() async throws {
        let (access, folder) = try makeAccess()
        let file = folder.appendingPathComponent("Devices/d/device.json")
        try access.write(Data("one".utf8), to: file, replacing: false)
        XCTAssertThrowsError(try access.write(Data("two".utf8), to: file, replacing: false)) {
            XCTAssertEqual($0 as? SyncProblem, .exists)
        }
        let kept = try await access.read(file, within: .seconds(1))
        XCTAssertEqual(kept, Data("one".utf8))
        try access.write(Data("two".utf8), to: file, replacing: true)
        let replaced = try await access.read(file, within: .seconds(1))
        XCTAssertEqual(replaced, Data("two".utf8))
    }

    /// A write is made whole under a hidden name and moved in: nothing half-made is left beside it.
    func testNothingHalfMadeIsLeftBeside() throws {
        let (access, folder) = try makeAccess()
        try access.write(Data("x".utf8), to: folder.appendingPathComponent("a.json"), replacing: false)
        let source = folder.deletingLastPathComponent().appendingPathComponent("s.bin")
        try Data("y".utf8).write(to: source)
        try access.copyIn(source, to: folder.appendingPathComponent("b.bin"))
        let raw = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(raw, ["a.json", "b.bin"])
    }

    /// What counts as a deleted folder, and that the access reports one as missing.
    func testAFolderInATrashIsMissing() async throws {
        XCTAssertTrue(SyncFolderIO.isDeleted(URL(fileURLWithPath: "/Users/reader/.Trash/TextMouth Sync")))
        XCTAssertTrue(SyncFolderIO.isDeleted(URL(fileURLWithPath: "/private/var/mobile/Recently Deleted/TextMouth Sync")))
        XCTAssertFalse(SyncFolderIO.isDeleted(URL(fileURLWithPath: "/Users/reader/Documents/TextMouth Sync")))
        let trashed = try makeSandboxDirectory("plain-trash").appendingPathComponent(".Trash/TextMouth Sync", isDirectory: true)
        try FileManager.default.createDirectory(at: trashed, withIntermediateDirectories: true)
        let access = PlainSyncFolderAccess(bookmark: try XCTUnwrap(DataDirectoryPreferences.makeBookmark(of: trashed)))
        do {
            _ = try await access.withFolder { $0 }
            XCTFail("in a trash")
        } catch { XCTAssertEqual(error as? SyncProblem, .folderMissing) }
    }

    /// The shared helper sweeps old half-made files and leaves recent ones and every other file.
    func testSweepingPartialFiles() throws {
        let (access, folder) = try makeAccess()
        let old = folder.appendingPathComponent(".partial-old")
        let recent = folder.appendingPathComponent(".partial-recent")
        let kept = folder.appendingPathComponent("a.json")
        for url in [old, recent, kept] { try Data("x".utf8).write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7_200)], ofItemAtPath: old.path)
        access.sweepPartialFiles(in: folder, olderThan: 3_600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
    }

    /// A copy in makes the folders above it, and is refused over a file.
    func testCopyInMakesFoldersAndRefusesOverAFile() throws {
        let (access, folder) = try makeAccess()
        let source = folder.deletingLastPathComponent().appendingPathComponent("source.bin")
        try Data("blob".utf8).write(to: source)
        let target = folder.appendingPathComponent("Books/b/blob.bin")
        try access.copyIn(source, to: target)
        XCTAssertEqual(try Data(contentsOf: target), Data("blob".utf8))
        XCTAssertThrowsError(try access.copyIn(source, to: target)) {
            XCTAssertEqual($0 as? SyncProblem, .exists)
        }
    }

    /// A fetch copies a file out, leaving the original in place.
    func testFetchCopiesAFileOut() async throws {
        let (access, folder) = try makeAccess()
        let file = folder.appendingPathComponent("blob.bin")
        try Data("blob".utf8).write(to: file)
        let destination = folder.deletingLastPathComponent().appendingPathComponent("out/blob.bin")
        try await access.fetch(file, to: destination, within: .seconds(1))
        XCTAssertEqual(try Data(contentsOf: destination), Data("blob".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    /// A plain local folder reports no upload state, so a copy counts as sent.
    func testALocalFolderReportsNoUploadState() throws {
        let (access, folder) = try makeAccess()
        let file = folder.appendingPathComponent("a.json")
        try Data("a".utf8).write(to: file)
        XCTAssertEqual(access.uploadState(of: file), .notReported)
    }
}

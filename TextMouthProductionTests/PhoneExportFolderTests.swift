import XCTest
@testable import TextMouth

/// `PhoneExportFolder`: the folder the iPhone's exports go to, kept as a
/// bookmark in the preferences (FR31). A folder in the test's sandbox stands
/// for the one the system's picker returns: a bookmark of it behaves the same
/// way, round trips, and goes stale or lost the same way.
final class PhoneExportFolderTests: XCTestCase {

    // MARK: - Keeping

    /// A folder kept is the folder found again, by its bookmark, and its name
    /// is the folder's own.
    func testAKeptFolderRoundTrips() throws {
        let defaults = makeSandboxedPreferences("PhoneExportFolder")
        let folder = try makeSandboxDirectory("Harbour Exports")

        let kept = PhoneExportFolder.keep(folder, in: defaults)
        let found = PhoneExportFolder.kept(in: defaults)

        XCTAssertEqual(kept?.url, folder)
        XCTAssertEqual(found?.url.resolvingSymlinksInPath(), folder.resolvingSymlinksInPath())
        // The sandbox names a folder after its label and a UUID.
        XCTAssertTrue(found?.name.hasPrefix("Harbour Exports") == true, "the name is the folder's: \(String(describing: found?.name))")
        XCTAssertNotNil(defaults.data(forKey: PhoneExportFolder.bookmarkKey))
    }

    /// With nothing kept there is no folder, and keeping another replaces the
    /// first.
    func testNothingKeptAndAnotherReplacesTheFirst() throws {
        let defaults = makeSandboxedPreferences("PhoneExportFolderNone")
        let first = try makeSandboxDirectory("First Exports")
        let second = try makeSandboxDirectory("Second Exports")
        XCTAssertNil(PhoneExportFolder.kept(in: defaults))

        PhoneExportFolder.keep(first, in: defaults)
        PhoneExportFolder.keep(second, in: defaults)

        XCTAssertEqual(PhoneExportFolder.kept(in: defaults)?.url.resolvingSymlinksInPath(), second.resolvingSymlinksInPath())
    }

    /// A folder that is gone is forgotten: the next look finds none, and the
    /// bookmark is dropped, so the sheet asks for a folder again rather than
    /// failing every file.
    func testALostFolderIsForgotten() throws {
        let defaults = makeSandboxedPreferences("PhoneExportFolderLost")
        let parent = try makeSandboxDirectory("Lost Parent")
        let folder = parent.appendingPathComponent("Gone Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        PhoneExportFolder.keep(folder, in: defaults)

        try FileManager.default.removeItem(at: folder)

        XCTAssertNil(PhoneExportFolder.kept(in: defaults))
        XCTAssertNil(defaults.data(forKey: PhoneExportFolder.bookmarkKey), "the lost bookmark was kept")
    }

    /// What was kept as a folder and is now a file is lost too: an export
    /// cannot go into a file.
    func testAFolderReplacedByAFileIsForgotten() throws {
        let defaults = makeSandboxedPreferences("PhoneExportFolderFile")
        let file = try makeSandboxDirectory("File Parent").appendingPathComponent("Exports.txt")
        try Data("not a folder".utf8).write(to: file)
        PhoneExportFolder.keep(file, in: defaults)

        XCTAssertNil(PhoneExportFolder.kept(in: defaults))
        XCTAssertNil(defaults.data(forKey: PhoneExportFolder.bookmarkKey))
    }

    /// Bytes that are no bookmark at all are forgotten, not trusted.
    func testADamagedBookmarkIsForgotten() {
        let defaults = makeSandboxedPreferences("PhoneExportFolderDamaged")
        defaults.set(Data("damaged".utf8), forKey: PhoneExportFolder.bookmarkKey)

        XCTAssertNil(PhoneExportFolder.kept(in: defaults))
        XCTAssertNil(defaults.data(forKey: PhoneExportFolder.bookmarkKey))
    }

    /// Forgetting drops the kept folder.
    func testForgettingDropsTheFolder() throws {
        let defaults = makeSandboxedPreferences("PhoneExportFolderForget")
        PhoneExportFolder.keep(try makeSandboxDirectory("Forgotten Exports"), in: defaults)

        PhoneExportFolder.forget(in: defaults)

        XCTAssertNil(PhoneExportFolder.kept(in: defaults))
    }

    /// A folder that was moved is found where it is, by its bookmark, under the name it has there.
    func testAMovedFolderIsFoundWhereItIs() throws {
        let defaults = makeSandboxedPreferences("PhoneExportFolderMoved")
        let parent = try makeSandboxDirectory("Moved Parent")
        let before = parent.appendingPathComponent("Before Exports", isDirectory: true)
        let after = parent.appendingPathComponent("After Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)
        PhoneExportFolder.keep(before, in: defaults)

        try FileManager.default.moveItem(at: before, to: after)
        let found = PhoneExportFolder.kept(in: defaults)

        XCTAssertEqual(found?.url.resolvingSymlinksInPath(), after.resolvingSymlinksInPath())
        XCTAssertEqual(found?.name, "After Exports")
    }

    /// A bookmark gone stale (a moved folder's is) is made again from the folder as it was found, so the next
    /// launch finds a bookmark that is not stale, and the folder is not lost.
    func testAStaleBookmarkIsMadeAgain() throws {
        let defaults = makeSandboxedPreferences("PhoneExportFolderStale")
        let parent = try makeSandboxDirectory("Stale Parent")
        let before = parent.appendingPathComponent("Old Place", isDirectory: true)
        let after = parent.appendingPathComponent("New Place", isDirectory: true)
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)
        PhoneExportFolder.keep(before, in: defaults)
        try FileManager.default.moveItem(at: before, to: after)

        _ = PhoneExportFolder.kept(in: defaults)

        var isStale = false
        let data = try XCTUnwrap(defaults.data(forKey: PhoneExportFolder.bookmarkKey), "the folder was forgotten")
        let resolved = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale)
        XCTAssertFalse(isStale, "the bookmark was kept stale")
        XCTAssertEqual(resolved.resolvingSymlinksInPath(), after.resolvingSymlinksInPath())
    }

    /// The name is read once, when the folder is kept: the folder that `keep` returns says the name the folder has
    /// then, and the one found later says the same.
    func testTheNameIsReadWhenTheFolderIsKept() throws {
        let defaults = makeSandboxedPreferences("PhoneExportFolderNamed")
        let folder = try makeSandboxDirectory("Read Once Exports")

        let kept = try XCTUnwrap(PhoneExportFolder.keep(folder, in: defaults))

        XCTAssertEqual(kept.name, PhoneExportFolder.name(of: folder))
        XCTAssertEqual(PhoneExportFolder.kept(in: defaults)?.name, kept.name)
        XCTAssertEqual(PhoneExportFolder(url: folder, name: "Downloads").name, "Downloads", "a name given is the name kept")
    }

    // MARK: - Name and Access

    /// The name is the folder's localized name where the system gives one,
    /// and its own name otherwise, never its path.
    func testTheNameIsNeverThePath() throws {
        let folder = try makeSandboxDirectory("Named Exports")

        let name = PhoneExportFolder(url: folder).name

        XCTAssertFalse(name.contains("/"))
        XCTAssertTrue(name.hasPrefix("Named Exports"), name)
        XCTAssertEqual(PhoneExportFolder(url: URL(fileURLWithPath: "/Users/reader/Missing Folder")).name, "Missing Folder")
    }

    /// Holding access to a folder and letting it go does no harm, however
    /// often it is let go: a sandbox folder is no security-scoped URL, which
    /// holds nothing.
    func testHoldingAccessIsHarmlessForAnUnscopedFolder() throws {
        let folder = PhoneExportFolder(url: try makeSandboxDirectory("Held Exports"))

        let release = folder.holdAccess()
        release()
        release()

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.url.path))
    }
}

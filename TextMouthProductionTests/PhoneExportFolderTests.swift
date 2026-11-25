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

import XCTest
@testable import TextMouth

/// Where this Mac keeps its library (FR02): choosing a custom data directory
/// records its path, a bookmark of the folder, and the identity of the
/// library in it, each in a preferences store of the test's own; resetting
/// to the default forgets the path and the bookmark.
@MainActor
final class DataDirectoryPreferencesTests: XCTestCase {

    /// A custom data directory holding a library: its path, a bookmark that
    /// leads back to the folder, and the library's identity are recorded.
    func testChoosingAFolderRecordsItsPathBookmarkAndIdentity() throws {
        let store = makeSandboxedPreferences("records-location")
        let folder = try makeSandboxDirectory("Chosen")
        let identity = try LibraryIdentity.adopt(in: folder).identity

        TextMouthPaths.setCustomRoot(folder, in: store)

        XCTAssertEqual(DataDirectoryPreferences.customPath.read(from: store), folder.path)
        XCTAssertEqual(DataDirectoryPreferences.expectedIdentity.read(from: store), identity.id)
        let bookmark = try XCTUnwrap(DataDirectoryPreferences.bookmark.read(from: store), "no bookmark recorded")
        XCTAssertEqual(try Self.folder(resolving: bookmark), folder.resolvingSymlinksInPath().path)
    }

    /// A folder whose library has no identity yet replaces the identity
    /// expected before: none is expected until the library opens and is
    /// given one.
    func testChoosingAFolderWithoutAnIdentityExpectsNone() throws {
        let store = makeSandboxedPreferences("no-identity")
        DataDirectoryPreferences.expectedIdentity.write(UUID(), to: store)
        let folder = try makeSandboxDirectory("Unmarked")

        TextMouthPaths.setCustomRoot(folder, in: store)

        XCTAssertNil(DataDirectoryPreferences.expectedIdentity.read(from: store))
        XCTAssertNotNil(DataDirectoryPreferences.bookmark.read(from: store))
    }

    /// Resetting to the default location forgets the custom path and its
    /// bookmark.
    func testResettingToTheDefaultForgetsThePathAndBookmark() throws {
        let store = makeSandboxedPreferences("reset")
        TextMouthPaths.setCustomRoot(try makeSandboxDirectory("Before"), in: store)

        TextMouthPaths.setCustomRoot(nil, in: store)

        XCTAssertNil(store.object(forKey: DataDirectoryPreferences.customPath.key))
        XCTAssertNil(store.object(forKey: DataDirectoryPreferences.bookmark.key))
    }

    /// A location that doesn't exist yet has nothing to bookmark: its path
    /// is recorded alone, and an earlier bookmark is not left behind.
    func testAMissingFolderIsRecordedWithoutABookmark() throws {
        let store = makeSandboxedPreferences("missing")
        TextMouthPaths.setCustomRoot(try makeSandboxDirectory("Earlier"), in: store)
        let missing = try makeSandboxDirectory("Parent").appendingPathComponent("Not Yet", isDirectory: true)

        TextMouthPaths.setCustomRoot(missing, in: store)

        XCTAssertEqual(DataDirectoryPreferences.customPath.read(from: store), missing.path)
        XCTAssertNil(DataDirectoryPreferences.bookmark.read(from: store))
    }

    // MARK: - Finding the Folder at Launch

    /// The app's first data directory is a renamed custom folder, found
    /// through its bookmark, and the preferences name it from then on, with
    /// a fresh bookmark; the debug log says so.
    func testLaunchFindsARenamedDataDirectoryThroughItsBookmark() throws {
        let home = try makeSandboxDirectory("RelocatingHome")
        let store = makeSandboxedPreferences("relocating")
        let original = home.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        _ = try LibraryIdentity.adopt(in: original)
        TextMouthPaths.setCustomRoot(original, in: store)
        let renamed = home.appendingPathComponent("Backup 2", isDirectory: true)
        try FileManager.default.moveItem(at: original, to: renamed)
        let app = TextMouthRuntime(isHostedTest: false, homeDirectory: home, preferences: store)

        let root = TextMouthPaths.root(for: app)

        let renamedPath = renamed.resolvingSymlinksInPath().path
        XCTAssertEqual(root.resolvingSymlinksInPath().path, renamedPath)
        let recorded = try XCTUnwrap(DataDirectoryPreferences.customPath.read(from: store))
        XCTAssertEqual(URL(fileURLWithPath: recorded).resolvingSymlinksInPath().path, renamedPath)
        let bookmark = try XCTUnwrap(DataDirectoryPreferences.bookmark.read(from: store))
        XCTAssertEqual(try Self.folder(resolving: bookmark), renamedPath)
        let logged = "DATA_DIRECTORY_FOUND: \(DataDirectoryPaths.shortName(of: original))"
        XCTAssertTrue(waitUntil(timeout: 5) { !self.debugLogLines(containing: logged).isEmpty }, "nothing logged")
    }

    /// A custom data directory that is there is used as named; a missing
    /// one that no bookmark finds stays as named, for the launch check to
    /// explain, and its preferences are left as they were.
    func testLaunchUsesTheNamedDataDirectoryWhenTheBookmarkFindsNothingElse() throws {
        let home = try makeSandboxDirectory("NamedHome")
        let store = makeSandboxedPreferences("named")
        let present = home.appendingPathComponent("Present", isDirectory: true)
        try FileManager.default.createDirectory(at: present, withIntermediateDirectories: false)
        let app = TextMouthRuntime(isHostedTest: false, homeDirectory: home, preferences: store)

        TextMouthPaths.setCustomRoot(present, in: store)
        XCTAssertEqual(TextMouthPaths.root(for: app).path, present.path)

        let missing = home.appendingPathComponent("Unplugged", isDirectory: true)
        TextMouthPaths.setCustomRoot(missing, in: store)
        XCTAssertEqual(TextMouthPaths.root(for: app).path, missing.path)
        XCTAssertEqual(DataDirectoryPreferences.customPath.read(from: store), missing.path)
    }

    // MARK: - Machine-Local

    /// The location preferences describe this Mac, so config.json never
    /// carries them.
    func testTheLocationPreferencesAreMachineLocal() {
        let local = Set(ConfigService.AppConfig.Portability.localStoreKeys)

        XCTAssertTrue(Set(DataDirectoryPreferences.keys).isSubset(of: local), "\(local)")
        XCTAssertEqual(DataDirectoryPreferences.keys.count, Set(DataDirectoryPreferences.keys).count)
    }

    // MARK: - Helpers

    /// The real path of the folder `bookmark` leads to.
    private static func folder(resolving bookmark: Data) throws -> String {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return url.resolvingSymlinksInPath().path
    }
}

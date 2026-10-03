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

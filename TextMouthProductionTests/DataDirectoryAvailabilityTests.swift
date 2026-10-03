import XCTest
@testable import TextMouth

/// The data directory check (FR02), in folders inside the test sandbox: the
/// default location is always available; a custom one only when its folder
/// is there, readable, and holds this library; a renamed folder is found
/// through its bookmark; and an index only in the cloud is asked for and
/// waited for. The check reads metadata only and creates nothing.
final class DataDirectoryAvailabilityTests: XCTestCase {

    // MARK: - The Default Location

    /// The default location is available even when it is missing, as on a
    /// first launch, and the check itself creates nothing there.
    func testTheDefaultLocationIsAvailableEvenWhenMissing() throws {
        let home = try makeSandboxDirectory("DefaultHome")
        let root = TextMouthPaths.defaultRoot(in: home)
        var check = makeCheck(root: root)
        check.isDefaultLocation = true

        XCTAssertEqual(check.run(itemStatus: LocalItemStatusProvider()), .available(nil, relocatedTo: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    // MARK: - Missing Folders

    /// A custom location that is missing is unavailable, named in full, and
    /// nothing is created there.
    func testAMissingCustomLocationIsUnavailableAndNothingIsCreated() throws {
        let root = try makeSandboxDirectory("MissingCustom").appendingPathComponent("Library Drive", isDirectory: true)

        let outcome = makeCheck(root: root).run(itemStatus: LocalItemStatusProvider())

        XCTAssertEqual(outcome, .unavailable(.folderMissing(folder: root.path)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    /// A custom location inside a cloud service's folder that is itself
    /// missing, as when the service is signed out: unavailable, saying so,
    /// and none of the missing parents is created.
    func testAMissingCloudServiceFolderIsNamedAndNothingIsCreated() throws {
        let home = try makeSandboxDirectory("SignedOutHome")
        let service = home.appendingPathComponent("Library/CloudStorage/GoogleDrive-reader@example.com", isDirectory: true)
        let root = service.appendingPathComponent("My Drive/TextMouth", isDirectory: true)

        let outcome = makeCheck(root: root).run(itemStatus: LocalItemStatusProvider())

        XCTAssertEqual(
            outcome,
            .unavailable(.cloudFolderMissing(.googleDrive, serviceFolderMissing: true, folder: root.path))
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library").path))
    }

    /// A cloud service's folder that is there, without the library's folder:
    /// the service may still be syncing it.
    func testAMissingFolderInAPresentCloudServiceFolderMaySyncLater() throws {
        let home = try makeSandboxDirectory("SyncingHome")
        let service = home.appendingPathComponent("Library/CloudStorage/Dropbox", isDirectory: true)
        try FileManager.default.createDirectory(at: service, withIntermediateDirectories: true)
        let root = service.appendingPathComponent("TextMouth", isDirectory: true)

        let outcome = makeCheck(root: root).run(itemStatus: LocalItemStatusProvider())

        XCTAssertEqual(outcome, .unavailable(.cloudFolderMissing(.dropbox, serviceFolderMissing: false, folder: root.path)))
    }

    // MARK: - What the Folder Holds

    /// A folder holding the identity this Mac expects is available.
    func testAFolderHoldingThisLibraryIsAvailable() throws {
        let root = try makeSandboxDirectory("ThisLibrary")
        let identity = try LibraryIdentity.adopt(in: root).identity

        let outcome = makeCheck(root: root, expecting: identity.id).run(itemStatus: LocalItemStatusProvider())

        XCTAssertEqual(outcome, .available(identity, relocatedTo: nil))
    }

    /// A folder holding another library's identity is unavailable.
    func testAFolderHoldingADifferentLibraryIsUnavailable() throws {
        let root = try makeSandboxDirectory("OtherLibrary")
        _ = try LibraryIdentity.adopt(in: root)

        let outcome = makeCheck(root: root, expecting: UUID()).run(itemStatus: LocalItemStatusProvider())

        XCTAssertEqual(outcome, .unavailable(.differentLibrary(folder: root.path)))
    }

    /// With no identity expected yet, a folder's marker is accepted as it is.
    func testAMarkerIsAcceptedWhenNoIdentityIsExpectedYet() throws {
        let root = try makeSandboxDirectory("FirstMarker")
        let identity = try LibraryIdentity.adopt(in: root).identity

        XCTAssertEqual(makeCheck(root: root).run(itemStatus: LocalItemStatusProvider()), .available(identity, relocatedTo: nil))
    }

    /// A library from before identities is known by its library.json.
    func testALibraryWithoutAnIdentityIsKnownByItsIndex() throws {
        let root = try makeSandboxDirectory("UnmarkedLibrary")
        try Data("{}".utf8).write(to: root.appendingPathComponent("library.json"))

        let outcome = makeCheck(root: root, expecting: UUID()).run(itemStatus: LocalItemStatusProvider())

        XCTAssertEqual(outcome, .available(nil, relocatedTo: nil))
    }

    /// A folder holding neither a marker nor an index holds no library.
    func testAFolderWithoutALibraryIsUnavailable() throws {
        let root = try makeSandboxDirectory("EmptyFolder")

        XCTAssertEqual(
            makeCheck(root: root).run(itemStatus: LocalItemStatusProvider()),
            .unavailable(.libraryMissing(folder: root.path))
        )
    }

    /// A damaged marker is reported rather than accepted or replaced.
    func testADamagedMarkerIsUnavailable() throws {
        let root = try makeSandboxDirectory("DamagedMarker")
        try Data("not json".utf8).write(to: LibraryIdentity.markerURL(in: root))

        guard case .unavailable(.identityUnreadable(let folder, _)) = makeCheck(root: root).run(
            itemStatus: LocalItemStatusProvider()
        ) else {
            return XCTFail("A damaged marker was not reported")
        }
        XCTAssertEqual(folder, root.path)
    }

    /// A file where the folder should be is unavailable.
    func testAFileAtTheLocationIsNotAFolder() throws {
        let file = try makeSandboxDirectory("FileInstead").appendingPathComponent("TextMouth")
        try Data("not a folder".utf8).write(to: file)

        XCTAssertEqual(
            makeCheck(root: file).run(itemStatus: LocalItemStatusProvider()),
            .unavailable(.notAFolder(folder: file.path))
        )
    }

    /// A folder TextMouth may not read is unavailable, saying why.
    func testAFolderThatCannotBeReadIsUnavailable() throws {
        let root = try makeSandboxDirectory("Locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        // Registered after the folder, so it runs first: the folder can then
        // be removed.
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        }

        XCTAssertEqual(
            makeCheck(root: root).run(itemStatus: LocalItemStatusProvider()),
            .unavailable(.unreadable(folder: root.path, reason: "permission denied"))
        )
    }

    // MARK: - The Bookmark

    /// A folder renamed since it was chosen is found through its bookmark
    /// when it holds this library.
    func testTheBookmarkFindsARenamedFolderHoldingThisLibrary() throws {
        let base = try makeSandboxDirectory("Renamed")
        let original = base.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        let identity = try LibraryIdentity.adopt(in: original).identity
        let bookmark = try XCTUnwrap(DataDirectoryPreferences.makeBookmark(of: original))
        let renamed = base.appendingPathComponent("Backup 2", isDirectory: true)
        try FileManager.default.moveItem(at: original, to: renamed)
        var check = makeCheck(root: original, expecting: identity.id)
        check.bookmark = bookmark

        guard case .available(let found, let relocated?) = check.run(itemStatus: LocalItemStatusProvider()) else {
            return XCTFail("The renamed folder was not found")
        }
        XCTAssertEqual(found, identity)
        XCTAssertEqual(relocated.resolvingSymlinksInPath().path, renamed.resolvingSymlinksInPath().path)
        XCTAssertEqual(check.relocatedLibrary()?.folder.resolvingSymlinksInPath().path, renamed.resolvingSymlinksInPath().path)
    }

    /// A bookmark leading to a folder that now holds another library is not
    /// followed.
    func testTheBookmarkIsNotFollowedToAnotherLibrary() throws {
        let base = try makeSandboxDirectory("Swapped")
        let original = base.appendingPathComponent("Backup", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        _ = try LibraryIdentity.adopt(in: original)
        let bookmark = try XCTUnwrap(DataDirectoryPreferences.makeBookmark(of: original))
        try FileManager.default.moveItem(at: original, to: base.appendingPathComponent("Elsewhere", isDirectory: true))
        var check = makeCheck(root: original, expecting: UUID())
        check.bookmark = bookmark

        XCTAssertEqual(check.run(itemStatus: LocalItemStatusProvider()), .unavailable(.folderMissing(folder: original.path)))
        XCTAssertNil(check.relocatedLibrary())
    }

    /// A folder moved to the Trash is not opened as if it had been renamed.
    func testTheBookmarkIsNotFollowedIntoTheTrash() throws {
        let base = try makeSandboxDirectory("Trashed")
        let original = base.appendingPathComponent("TextMouth", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        let identity = try LibraryIdentity.adopt(in: original).identity
        let bookmark = try XCTUnwrap(DataDirectoryPreferences.makeBookmark(of: original))
        let trash = base.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        try FileManager.default.moveItem(at: original, to: trash.appendingPathComponent("TextMouth", isDirectory: true))
        var check = makeCheck(root: original, expecting: identity.id)
        check.bookmark = bookmark

        XCTAssertEqual(check.run(itemStatus: LocalItemStatusProvider()), .unavailable(.folderMissing(folder: original.path)))
    }

    // MARK: - Files Only in the Cloud

    /// A library index only in the cloud is unavailable with the download
    /// reason, naming the service, and its download is requested.
    func testAnIndexOnlyInTheCloudIsAskedForAndWaitedFor() throws {
        let root = try makeSandboxDirectory("CloudIndex")
        let identity = try LibraryIdentity.adopt(in: root).identity
        let index = root.appendingPathComponent("library.json")
        try Data("{}".utf8).write(to: index)
        let cloud = FakeCloudItemStatusProvider()
        cloud.setLocation(.cloud(.googleDrive), of: root)
        cloud.setStatus(Self.status(.notDownloaded), of: index)

        let outcome = makeCheck(root: root, expecting: identity.id).run(itemStatus: cloud)

        XCTAssertEqual(outcome, .unavailable(.notDownloaded(.googleDrive, folder: root.path)))
        XCTAssertEqual(cloud.downloadRequests.map(\.lastPathComponent), ["library.json"])
        XCTAssertEqual(
            DataDirectoryUnavailability.notDownloaded(.googleDrive, folder: root.path).explanation,
            "The library index is in Google Drive and isn't on this Mac yet."
        )
    }

    /// An identity marker only in the cloud, still downloading, is asked for
    /// too, and the library waits for it.
    func testAMarkerOnlyInTheCloudIsAskedFor() throws {
        let root = try makeSandboxDirectory("CloudMarker")
        _ = try LibraryIdentity.adopt(in: root)
        let cloud = FakeCloudItemStatusProvider()
        cloud.setLocation(.cloud(.iCloudDrive), of: root)
        cloud.setStatus(Self.status(.downloading), of: LibraryIdentity.markerURL(in: root))

        let outcome = makeCheck(root: root).run(itemStatus: cloud)

        XCTAssertEqual(outcome, .unavailable(.notDownloaded(.iCloudDrive, folder: root.path)))
        XCTAssertEqual(cloud.downloadRequests.map(\.lastPathComponent), [LibraryIdentity.fileName])
    }

    /// A downloaded index in a cloud folder is used like a local one, and
    /// nothing is asked of the sync service.
    func testADownloadedIndexInTheCloudIsAvailable() throws {
        let root = try makeSandboxDirectory("CloudDownloaded")
        let identity = try LibraryIdentity.adopt(in: root).identity
        let index = root.appendingPathComponent("library.json")
        try Data("{}".utf8).write(to: index)
        let cloud = FakeCloudItemStatusProvider()
        cloud.setLocation(.cloud(.dropbox), of: root)
        cloud.setStatus(Self.status(.downloaded), of: index)
        cloud.setStatus(Self.status(.downloaded), of: LibraryIdentity.markerURL(in: root))

        XCTAssertEqual(makeCheck(root: root, expecting: identity.id).run(itemStatus: cloud), .available(identity, relocatedTo: nil))
        XCTAssertEqual(cloud.downloadRequests, [])
    }

    // MARK: - Wording

    /// Each reason reads as one plain explanation naming where.
    func testEachReasonExplainsItselfPlainly() {
        let folder = "/Users/reader/Library/CloudStorage/GoogleDrive-reader@example.com/My Drive/TextMouth"
        let cases: [(DataDirectoryUnavailability, String)] = [
            (.driveNotConnected(volume: "Backup", folder: "/Volumes/Backup/TextMouth"),
             "The drive “Backup” isn't connected."),
            (.cloudFolderMissing(.googleDrive, serviceFolderMissing: true, folder: folder),
             "The folder \(folder) can't be found. Google Drive may be signed out or not running."),
            (.cloudFolderMissing(.iCloudDrive, serviceFolderMissing: true, folder: "/i/TextMouth"),
             "The folder /i/TextMouth can't be found. iCloud Drive may be turned off or signed out."),
            (.cloudFolderMissing(.dropbox, serviceFolderMissing: false, folder: "/d/TextMouth"),
             "The folder /d/TextMouth can't be found. It may have been moved or renamed, "
                + "or Dropbox may not have synced it to this Mac yet."),
            (.folderMissing(folder: "/Users/reader/Books"), "The folder /Users/reader/Books can't be found."),
            (.notAFolder(folder: "/Users/reader/Books"), "There is a file at /Users/reader/Books, not a folder."),
            (.unreadable(folder: "/Users/reader/Books", reason: "permission denied"),
             "TextMouth can't read the folder /Users/reader/Books: permission denied."),
            (.libraryMissing(folder: "/x"), "The folder is there, but the library isn't in it."),
            (.differentLibrary(folder: "/x"), "The folder is there, but it holds a different TextMouth library."),
            (.notDownloaded(nil, folder: "/x"), "The library index is in the cloud and isn't on this Mac yet."),
        ]
        for (reason, explanation) in cases {
            XCTAssertEqual(reason.explanation, explanation)
        }
    }

    /// A missing folder on a drive that isn't mounted is a drive that isn't
    /// connected; on a mounted one, or anywhere else, a missing folder. The
    /// questions about /Volumes are answered here, so nothing looks there.
    func testAMissingFolderIsNamedByItsDriveOrCloudService() {
        func reason(_ path: String, mounted: Bool = false, present: Set<String> = []) -> DataDirectoryUnavailability {
            .missingFolder(path, isMountedVolume: { _ in mounted }, exists: { present.contains($0) })
        }

        XCTAssertEqual(
            reason("/Volumes/Backup/Libraries/TextMouth"),
            .driveNotConnected(volume: "Backup", folder: "/Volumes/Backup/Libraries/TextMouth")
        )
        XCTAssertEqual(reason("/Volumes/Backup/TextMouth", mounted: true), .folderMissing(folder: "/Volumes/Backup/TextMouth"))
        XCTAssertEqual(
            reason("/Users/reader/Library/Mobile Documents/com~apple~CloudDocs/TextMouth"),
            .cloudFolderMissing(
                .iCloudDrive,
                serviceFolderMissing: true,
                folder: "/Users/reader/Library/Mobile Documents/com~apple~CloudDocs/TextMouth"
            )
        )
        XCTAssertEqual(
            reason(
                "/Users/reader/Library/CloudStorage/OneDrive-Personal/TextMouth",
                present: ["/Users/reader/Library/CloudStorage/OneDrive-Personal"]
            ),
            .cloudFolderMissing(
                .other("OneDrive"),
                serviceFolderMissing: false,
                folder: "/Users/reader/Library/CloudStorage/OneDrive-Personal/TextMouth"
            )
        )
        XCTAssertEqual(reason("/Users/reader/TextMouth"), .folderMissing(folder: "/Users/reader/TextMouth"))
    }

    /// A path in a cloud service's folder names the service and the
    /// service's own folder; Trash folders are told apart from look-alikes.
    func testCloudServiceFoldersAndTrashFoldersAreReadFromPaths() {
        let drive = "/Users/reader/Library/CloudStorage/GoogleDrive-reader@example.com"
        let found = DataDirectoryPaths.cloudFolder(holding: drive + "/My Drive/TextMouth")
        XCTAssertEqual(found?.provider, .googleDrive)
        XCTAssertEqual(found?.serviceFolder, drive)
        XCTAssertNil(DataDirectoryPaths.cloudFolder(holding: "/Users/reader/Documents/TextMouth"))
        XCTAssertTrue(DataDirectoryPaths.isInTrash("/Users/reader/.Trash/TextMouth"))
        XCTAssertTrue(DataDirectoryPaths.isInTrash("/Volumes/Backup/.Trashes/501/TextMouth"))
        XCTAssertFalse(DataDirectoryPaths.isInTrash("/Users/reader/Trash Talk/TextMouth"))
    }

    // MARK: - Fixtures

    /// A check of the custom location `root`, expecting `identity`.
    private func makeCheck(root: URL, expecting identity: UUID? = nil) -> DataDirectoryCheck {
        DataDirectoryCheck(
            root: root,
            isDefaultLocation: false,
            expectedIdentity: identity,
            bookmark: nil
        )
    }

    /// A status in `state`, as a sync service reports a file in it.
    private static func status(_ state: CloudItemState) -> CloudItemStatus {
        CloudItemStatus(state: state, isUploaded: true, byteCount: 120, hasUnresolvedConflicts: false, downloadError: nil)
    }
}

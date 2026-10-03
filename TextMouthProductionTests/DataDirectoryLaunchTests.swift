import AppKit
import XCTest
@testable import TextMouth

/// The library model's data-directory gate (FR02), with a preferences store
/// and a volume notification center of the test's own, in folders inside
/// the test sandbox: a library missing at launch is neither loaded nor
/// created, and Try Again loads it once it is back; a renamed folder is
/// used where its bookmark found it; an index only in the cloud is asked for
/// and waited for; and a library lost while TextMouth runs, through an
/// unmounted volume or a write that found its folder gone, stops saving
/// until Try Again reads it afresh.
@MainActor
final class DataDirectoryLaunchTests: XCTestCase {

    // MARK: - Launch

    /// A custom library missing at launch makes the model unavailable, says
    /// why, and creates nothing; Try Again, once it is back, runs the whole
    /// startup and shows the library, and says so.
    func testTryAgainLoadsALibraryThatWasMissingAtLaunch() throws {
        let fixture = try LibraryFixture(test: self, label: "MissingAtLaunch")
        try fixture.takeAway()

        let model = LibraryViewModel(dataDirectoryEnvironment: fixture.environment)

        XCTAssertEqual(model.dataDirectoryUnavailability, .folderMissing(folder: fixture.root.path))
        XCTAssertFalse(model.hasStartedLibrary)
        XCTAssertTrue(DataDirectoryGate.isClosed(fixture.root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path), "startup created the missing library")

        try fixture.bringBack()
        var retried = false
        let announcements = recordingAnnouncements {
            retried = model.retryDataDirectory()
        }

        XCTAssertTrue(retried)
        XCTAssertNil(model.dataDirectoryUnavailability)
        XCTAssertTrue(model.hasStartedLibrary)
        XCTAssertFalse(DataDirectoryGate.isClosed(fixture.root))
        XCTAssertEqual(model.library.folders.map(\.fullPath), [LibraryFixture.folderName])
        XCTAssertEqual(announcements.announcements.map(\.message), ["The library is available."])
    }

    /// Try Again while the library is still missing keeps it unavailable,
    /// loads nothing, and says why again.
    func testTryAgainWhileTheLibraryIsStillMissingSaysWhyAgain() throws {
        let fixture = try LibraryFixture(test: self, label: "StillMissing")
        try fixture.takeAway()
        let model = LibraryViewModel(dataDirectoryEnvironment: fixture.environment)

        var retried = true
        let announcements = recordingAnnouncements {
            retried = model.retryDataDirectory()
        }

        XCTAssertFalse(retried)
        XCTAssertFalse(model.hasStartedLibrary)
        XCTAssertEqual(
            announcements.announcements.map(\.message),
            ["The library is still not available. The folder \(fixture.root.path) can't be found."]
        )
    }

    /// A library opening for the first time since identities came in is
    /// given one, which becomes the identity this Mac expects.
    func testALibraryWithoutAnIdentityIsGivenOneAsItOpens() throws {
        let fixture = try LibraryFixture(test: self, label: "Unmarked", marked: false)

        let model = LibraryViewModel(dataDirectoryEnvironment: fixture.environment)

        XCTAssertNil(model.dataDirectoryUnavailability)
        let identity = try XCTUnwrap(try LibraryIdentity.read(in: fixture.root))
        XCTAssertEqual(DataDirectoryPreferences.expectedIdentity.read(from: fixture.preferences), identity.id)
    }

    /// A library renamed since it was chosen is opened where its bookmark
    /// found it: the data directory moves there and the stored path follows.
    func testARenamedLibraryIsOpenedWhereItsBookmarkFoundIt() throws {
        let fixture = try LibraryFixture(test: self, label: "Renamed")
        let renamed = fixture.root.deletingLastPathComponent().appendingPathComponent("Renamed Library", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.root, to: renamed)

        let model = LibraryViewModel(dataDirectoryEnvironment: fixture.environment)

        XCTAssertNil(model.dataDirectoryUnavailability)
        let renamedPath = renamed.resolvingSymlinksInPath().path
        XCTAssertEqual(TextMouthPaths.root.resolvingSymlinksInPath().path, renamedPath)
        let stored = try XCTUnwrap(DataDirectoryPreferences.customPath.read(from: fixture.preferences))
        XCTAssertEqual(URL(fileURLWithPath: stored).resolvingSymlinksInPath().path, renamedPath)
        XCTAssertEqual(model.library.folders.map(\.fullPath), [LibraryFixture.folderName])
    }

    /// A library whose index is only in the cloud is unavailable until it
    /// arrives, and its download is requested.
    func testALibraryWhoseIndexIsOnlyInTheCloudWaitsForIt() throws {
        let fixture = try LibraryFixture(test: self, label: "CloudIndex")
        let cloud = FakeCloudItemStatusProvider()
        cloud.setLocation(.cloud(.googleDrive), of: fixture.root)
        cloud.setStatus(
            CloudItemStatus(state: .notDownloaded, isUploaded: true, byteCount: 0, hasUnresolvedConflicts: false, downloadError: nil),
            of: fixture.root.appendingPathComponent("library.json")
        )
        installCloudItemStatus(cloud)

        let model = LibraryViewModel(dataDirectoryEnvironment: fixture.environment)

        XCTAssertEqual(model.dataDirectoryUnavailability, .notDownloaded(.googleDrive, folder: fixture.root.path))
        XCTAssertEqual(cloud.downloadRequests.map(\.lastPathComponent), ["library.json"])
        XCTAssertFalse(model.hasStartedLibrary)
    }

    // MARK: - Losing the Library While Running

    /// An unmounted volume that held the library makes it unavailable:
    /// saving stops, nothing is created where it was, and Try Again, once it
    /// is back, reads library.json afresh and saves again.
    func testAnUnmountedVolumeStopsSavingUntilTryAgainReadsTheLibraryAfresh() throws {
        let fixture = try LibraryFixture(test: self, label: "Unmounted")
        let model = LibraryViewModel(dataDirectoryEnvironment: fixture.environment)
        XCTAssertNil(model.dataDirectoryUnavailability)
        try fixture.takeAway()

        fixture.volumeNotifications.post(
            name: NSWorkspace.didUnmountNotification,
            object: NSWorkspace.shared,
            userInfo: [NSWorkspace.volumeURLUserInfoKey: fixture.volume]
        )

        XCTAssertTrue(waitUntil(timeout: 5) { model.dataDirectoryUnavailability != nil }, "the unmount went unnoticed")
        XCTAssertEqual(model.dataDirectoryUnavailability, .folderMissing(folder: fixture.root.path))
        model.library.folders.append(BookFolder(name: "Made While Away"))
        model.save()
        LibraryPersistenceService.flushPendingSave()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path), "a save recreated the library")

        // The drive comes back holding a change made elsewhere meanwhile.
        try fixture.bringBack(addingFolder: "Made Elsewhere")
        XCTAssertTrue(model.retryDataDirectory())

        XCTAssertEqual(Set(model.library.folders.map(\.fullPath)), [LibraryFixture.folderName, "Made Elsewhere"])
        model.save()
        LibraryPersistenceService.flushPendingSave()
        XCTAssertNotNil(try fixture.index().folders.first { $0.fullPath == "Made Elsewhere" })
    }

    /// Another volume unmounting changes nothing.
    func testAnotherVolumeUnmountingChangesNothing() throws {
        let fixture = try LibraryFixture(test: self, label: "OtherVolume")
        let model = LibraryViewModel(dataDirectoryEnvironment: fixture.environment)

        model.volumeDidUnmount(URL(fileURLWithPath: "/Volumes/Some Other Drive", isDirectory: true))

        XCTAssertNil(model.dataDirectoryUnavailability)
    }

    /// A save that finds the library's folder gone makes it unavailable.
    func testASaveThatFindsTheFolderGoneMakesTheLibraryUnavailable() throws {
        let fixture = try LibraryFixture(test: self, label: "VanishedOnSave")
        let model = LibraryViewModel(dataDirectoryEnvironment: fixture.environment)
        try fixture.takeAway()

        model.save()
        LibraryPersistenceService.flushPendingSave()

        XCTAssertTrue(waitUntil(timeout: 5) { model.dataDirectoryUnavailability != nil }, "the failed save went unnoticed")
        XCTAssertEqual(model.dataDirectoryUnavailability, .folderMissing(folder: fixture.root.path))
        PersistenceFailureCenter.shared.reset()
    }

    // MARK: - Helpers

    /// Makes `provider` the app's cloud item status until the test ends.
    private func installCloudItemStatus(_ provider: any CloudItemStatusProviding) {
        let previous = CloudServices.itemStatus
        CloudServices.itemStatus = provider
        addTeardownBlock { @MainActor in CloudServices.itemStatus = previous }
    }
}

/// A custom library inside a "volume" folder of the test's own, made the
/// data directory until the test ends, with a preferences store and a volume
/// notification center of its own. It can be taken away, as an unplugged
/// drive is, and brought back. Taking it away copies it aside and removes
/// it, rather than moving it, since a bookmark follows a moved folder.
@MainActor
private struct LibraryFixture {
    /// The folder row every fixture library holds.
    static let folderName = "Sea Charts"

    /// The folder standing for the volume that holds the library.
    let volume: URL
    /// The data directory.
    let root: URL
    /// Where the library waits while it is away.
    let aside: URL
    /// The store naming the data directory and the library expected there.
    let preferences: UserDefaults
    /// Where the test announces unmounted volumes.
    let volumeNotifications = NotificationCenter()

    /// The environment the library model under test uses.
    var environment: DataDirectoryEnvironment {
        DataDirectoryEnvironment(preferences: preferences, volumeNotifications: volumeNotifications)
    }

    /// Lays out a library, with an identity marker unless `marked` is false,
    /// chooses it in the fixture's store, and makes it the data directory.
    init(test: XCTestCase, label: String, marked: Bool = true) throws {
        let scratch = try test.makeDataDirectoryMoveDestination(label).deletingLastPathComponent()
        volume = scratch.appendingPathComponent("Volume", isDirectory: true)
        root = volume.appendingPathComponent("TextMouth", isDirectory: true)
        aside = scratch.appendingPathComponent("Aside", isDirectory: true)
        preferences = test.makeSandboxedPreferences(label)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try Self.write(Library(folders: [BookFolder(name: Self.folderName)]), to: root)
        if marked {
            _ = try LibraryIdentity.adopt(in: root)
        }
        TextMouthPaths.setCustomRoot(root, in: preferences)
        StorageBoundary.shared.publish(root: root)
        let root = root
        test.addTeardownBlock { DataDirectoryGate.open(root) }
    }

    /// Takes the library away: copied aside, then removed.
    func takeAway() throws {
        try FileManager.default.copyItem(at: root, to: aside)
        try FileManager.default.removeItem(at: root)
    }

    /// Brings the library back, as a copy of what was taken away, with the
    /// folder row `addingFolder` added to its index when given, as another
    /// Mac might have.
    func bringBack(addingFolder: String? = nil) throws {
        try FileManager.default.copyItem(at: aside, to: root)
        try FileManager.default.removeItem(at: aside)
        if let addingFolder {
            var library = try index()
            library.folders.append(BookFolder(name: addingFolder))
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Library/\(addingFolder)", isDirectory: true),
                withIntermediateDirectories: true
            )
            try Self.write(library, to: root)
        }
    }

    /// The library.json in the data directory now.
    func index() throws -> Library {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Library.self, from: Data(contentsOf: root.appendingPathComponent("library.json")))
    }

    /// Writes `library` as `root`'s library.json.
    private static func write(_ library: Library, to root: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(library).write(to: root.appendingPathComponent("library.json"), options: .atomic)
    }
}

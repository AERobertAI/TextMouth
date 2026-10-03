import XCTest
@testable import TextMouth

/// Never creating a missing data directory (FR02): the default location is
/// created when missing, as on a first launch, and given its identity; a
/// custom one, or any folder above it, never is; library folders are made
/// only inside an existing data directory; and nothing is created while the
/// library model has found the data directory unavailable.
@MainActor
final class DataDirectoryCreationTests: XCTestCase {

    // MARK: - The Default Location

    /// A missing default location is created with its folders, and the new
    /// library is given its identity.
    func testTheDefaultLocationIsCreatedWhenMissingAndGivenAnIdentity() throws {
        let root = try makeSandboxDirectory("FirstLaunch").appendingPathComponent(".TextMouth", isDirectory: true)

        try TextMouthPaths.ensureDirectoryStructure(at: root, isDefaultLocation: true)

        XCTAssertTrue(Self.isFolder(root.appendingPathComponent("Library")))
        // Its Logs folder too, where the logs go by default: the log writer
        // never makes a folder in the data directory itself.
        XCTAssertTrue(Self.isFolder(root.appendingPathComponent("Logs")))
        XCTAssertNotNil(try LibraryIdentity.read(in: root), "the new library has no identity")
    }

    /// An existing default location keeps the identity it has.
    func testAnExistingDefaultLocationKeepsItsIdentity() throws {
        let root = try makeSandboxDirectory("ExistingDefault")
        let identity = try LibraryIdentity.adopt(in: root).identity

        try TextMouthPaths.ensureDirectoryStructure(at: root, isDefaultLocation: true)

        XCTAssertEqual(try LibraryIdentity.read(in: root), identity)
    }

    // MARK: - Custom Locations

    /// A missing custom location is never created: the call fails, saying
    /// the library isn't available.
    func testAMissingCustomLocationIsNeverCreated() throws {
        let root = try makeSandboxDirectory("Unplugged").appendingPathComponent("TextMouth", isDirectory: true)

        XCTAssertThrowsError(try TextMouthPaths.ensureDirectoryStructure(at: root, isDefaultLocation: false)) { error in
            XCTAssertEqual((error as? DataDirectoryUnavailableError)?.root.path, root.path)
            XCTAssertEqual(error.localizedDescription, "The library at \(root.path) isn't available.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    /// No missing parent of a custom location is created either, as a
    /// signed-out cloud drive's folders would be.
    func testNoMissingParentOfACustomLocationIsCreated() throws {
        let drive = try makeSandboxDirectory("CloudStorage").appendingPathComponent("GoogleDrive-reader", isDirectory: true)
        let root = drive.appendingPathComponent("My Drive/TextMouth", isDirectory: true)

        XCTAssertThrowsError(try TextMouthPaths.ensureDirectoryStructure(at: root, isDefaultLocation: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: drive.path))
    }

    /// An existing custom location gets its folders inside it. Its identity
    /// is the library model's to give, when the library opens.
    func testAnExistingCustomLocationGetsItsFoldersInside() throws {
        let root = try makeSandboxDirectory("ChosenFolder")

        try TextMouthPaths.ensureDirectoryStructure(at: root, isDefaultLocation: false)

        XCTAssertTrue(Self.isFolder(root.appendingPathComponent("Library")))
        XCTAssertTrue(Self.isFolder(root.appendingPathComponent("Logs")))
        XCTAssertNil(try LibraryIdentity.read(in: root))
    }

    // MARK: - The Gate

    /// Nothing is created in a data directory the library model found
    /// unavailable, whether it is the default location or a custom one.
    func testNothingIsCreatedWhileTheGateIsClosed() throws {
        let custom = try makeSandboxDirectory("ClosedCustom")
        let defaultRoot = try makeSandboxDirectory("ClosedDefault").appendingPathComponent(".TextMouth", isDirectory: true)
        DataDirectoryGate.close(custom)
        DataDirectoryGate.close(defaultRoot)
        addTeardownBlock {
            DataDirectoryGate.open(custom)
            DataDirectoryGate.open(defaultRoot)
        }

        XCTAssertThrowsError(try TextMouthPaths.ensureDirectoryStructure(at: custom, isDefaultLocation: false))
        XCTAssertThrowsError(try TextMouthPaths.ensureDirectoryStructure(at: defaultRoot, isDefaultLocation: true))

        XCTAssertFalse(FileManager.default.fileExists(atPath: custom.appendingPathComponent("Library").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: custom.appendingPathComponent("Logs").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultRoot.path))
        XCTAssertTrue(DataDirectoryGate.isClosed(custom.appendingPathComponent(".", isDirectory: true)))
    }

    // MARK: - Library Folders

    /// A library folder is created only inside an existing data directory:
    /// with the data directory missing, nothing is created at all.
    func testLibraryFoldersAreCreatedOnlyInsideAnExistingDataDirectory() throws {
        let root = try makeDataDirectoryMoveDestination("Subfolders")
        StorageBoundary.shared.publish(root: root)

        XCTAssertThrowsError(try TextMouthPaths.ensureLibrarySubfolder("Charts/Harbors"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try TextMouthPaths.ensureLibrarySubfolder("Charts/Harbors")

        XCTAssertTrue(Self.isFolder(root.appendingPathComponent("Library/Charts/Harbors")))
    }

    // MARK: - Helpers

    /// Whether a folder is at `url`.
    private static func isFolder(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
    }
}

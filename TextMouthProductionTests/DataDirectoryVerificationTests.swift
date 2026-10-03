import XCTest
@testable import TextMouth

/// The hazards of a data directory that is missing at launch, or that
/// another Mac names (FR02 findings 1, 2, and 4), checked in folders inside
/// the test sandbox, never in /Volumes. Each failed on main before the fix:
/// - startup must neither load an empty library in place of a missing one
///   nor create anything where it was, so a save can never write an empty
///   index over the real one when the drive comes back;
/// - startup must create no missing parent of the data directory, so a
///   signed-out cloud folder never becomes a new local library;
/// - an outside edit of config.json naming a location this Mac doesn't have
///   must not start a move.
@MainActor
final class DataDirectoryVerificationTests: XCTestCase {

    // MARK: - (b) Missing Parents

    /// A custom data directory whose parent folders are missing too, as a
    /// signed-out cloud drive's are: startup creates none of them.
    func testStartupCreatesNoMissingParentOfTheCustomDataDirectory() throws {
        let scratch = try makeDataDirectoryMoveDestination("MissingParents").deletingLastPathComponent()
        let drive = scratch.appendingPathComponent("GoogleDrive-reader", isDirectory: true)
        let root = drive.appendingPathComponent("My Drive/TextMouth", isDirectory: true)
        TextMouthPaths.setCustomRoot(root)
        StorageBoundary.shared.publish(root: root)

        let model = LibraryViewModel()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: drive.path),
            "Startup created the missing parents of the data directory: \(Self.listing(of: drive)); "
                + "the model shows \(model.library.books.count) books"
        )
    }

    // MARK: - Fixtures

    /// Every item below `folder`, relative to it and sorted, for messages.
    private static func listing(of folder: URL) -> String {
        let items = FileManager.default.enumerator(atPath: folder.path)?.compactMap { $0 as? String } ?? []
        return items.isEmpty ? "nothing" : items.sorted().joined(separator: ", ")
    }
}

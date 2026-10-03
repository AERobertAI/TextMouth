import XCTest
@testable import TextMouth

extension XCTestCase {
    /// Where a data-directory move in this test may put the data directory:
    /// a folder named "Moved Data" that does not exist yet, inside a scratch
    /// folder of the test's own.
    ///
    /// A published move takes the data directory of the whole test process
    /// with it (TODO S04), so when the test ends, before anything else this
    /// helper arranges, the writes still queued are made and the data
    /// directory goes back to where it is now. Then config.json's copy of
    /// the setting is put back, then the scratch folder is removed; the
    /// data-directory preferences (its path, bookmark, and the identity
    /// expected there) are put back too.
    /// Call it after making any fixture whose teardown writes into the data
    /// directory, such as an integration world, so those writes land where
    /// they began.
    @MainActor
    func makeDataDirectoryMoveDestination(_ label: String) throws -> URL {
        preservePreferences(DataDirectoryPreferences.keys)
        // Teardown blocks run last registered first: the scratch folder's
        // removal, registered here, runs after the two blocks below.
        let scratch = try makeSandboxDirectory(label)

        let config = ConfigService.shared
        let savedConfigPath = config.config.dataDirectoryPath
        addTeardownBlock {
            guard config.config.dataDirectoryPath != savedConfigPath else { return }
            config.config.dataDirectoryPath = savedConfigPath
            config.saveToDisk()
        }

        let root = TextMouthPaths.root
        addTeardownBlock {
            restoreDataDirectory(root)
        }
        return scratch.appendingPathComponent("Moved Data", isDirectory: true)
    }
}

/// Makes the data directory at `root` the current one again, when a test
/// moved it elsewhere. Writes still queued are made first, so they land in
/// the test's data directory and never in the one put back. Nothing
/// changes when it is already there.
func restoreDataDirectory(_ root: URL) {
    guard TextMouthPaths.root.path != root.path else { return }
    LibraryPersistenceService.flushPendingSave()
    StorageBoundary.shared.publish(root: root)
}

import XCTest
@testable import TextMouth

// Shared fixtures for the integration tests (TODO Q04). Each of those tests
// enters a repaired workflow at its real boundary (a menu command's import,
// a library save, a notification the router hears, a running sleep timer,
// a reader's chapter end, a reader's load) and checks what the user would
// notice, rather than calling the helper the repair introduced.

// MARK: - A Library Folder of the Test's Own

/// A folder of one test's own inside the hosted tests' isolated library.
///
/// Work done in it leaves its traces where nothing else writes, so the
/// folder's complete listing, hidden names included, shows exactly what the
/// work left behind: a published package, or the hidden package an import
/// stages before publishing.
struct IntegrationLibraryFolder {
    /// The folder's path inside the library, as books and folders name it.
    let path: String

    /// The folder on disk.
    var url: URL {
        TextMouthPaths.libraryDir.appendingPathComponent(path, isDirectory: true)
    }

    /// Every name in the folder, hidden ones included, or none when the
    /// folder does not exist.
    func entries() throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: url.path))
    }

    /// Removes the folder and everything in it. Queued package writes are
    /// made first, so none can land in a package after it is gone, and write
    /// permission is given back to every directory first, since a test may
    /// have made one read-only.
    func remove() {
        LibraryPersistenceService.flushPendingSave()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if let enumerator = FileManager.default.enumerator(atPath: url.path) {
            for case let relative as String in enumerator {
                chmod(url.appendingPathComponent(relative).path, 0o755)
            }
        }
        chmod(url.path, 0o755)
        try? FileManager.default.removeItem(at: url)
    }
}

extension XCTestCase {
    /// A new library folder of this test's own, named after `label`, that is
    /// removed with everything in it when the test ends. The folder is not
    /// created here: the work under test creates it as it would any folder.
    func makeIntegrationLibraryFolder(_ label: String) -> IntegrationLibraryFolder {
        let folder = IntegrationLibraryFolder(path: "\(label) \(UUID().uuidString.prefix(8))")
        addTeardownBlock { folder.remove() }
        return folder
    }
}

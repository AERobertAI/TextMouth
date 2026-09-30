import XCTest
@testable import TextMouth

/// Books recorded before `.tmb` packages existed are moved into packages by
/// the startup repair. Each copy must be proven identical to its original
/// before that original is removed, and nothing already in the library may
/// be overwritten or trusted unchecked (TODO S03).
///
/// Every test works in a sandbox of its own (see `makeSandbox()`): loose
/// files in a scratch directory and packages in a library folder no other
/// test uses, all inside the isolated test root and removed afterwards.
@MainActor
final class LegacyBookMigrationTests: XCTestCase {

    // MARK: - Content Fingerprint

    /// A fingerprint is the file's size and the MD5 hash duplicate detection
    /// uses, and it matches only a file holding exactly the same bytes: a
    /// shorter copy fails on size, and a copy of the same size with a
    /// changed byte fails on the hash.
    func testFingerprintMatchesOnlyAFileWithTheSameBytes() throws {
        let sandbox = makeSandbox()
        let original = try sandbox.makeFile("original.txt", contents: "Every byte matters.")
        let fingerprint = try ContentFingerprint(of: original)

        XCTAssertEqual(fingerprint.byteCount, 19)
        XCTAssertEqual(fingerprint.md5Hash, try FileImportService.md5Hash(of: original))
        XCTAssertTrue(fingerprint.matchesFile(at: try sandbox.makeFile("copy.txt", contents: "Every byte matters.")))
        XCTAssertFalse(fingerprint.matchesFile(at: try sandbox.makeFile("partial.txt", contents: "Every byte")))
        XCTAssertFalse(fingerprint.matchesFile(at: try sandbox.makeFile("altered.txt", contents: "Every bite matters.")))
        XCTAssertFalse(fingerprint.matchesFile(at: sandbox.scratchDirectory.appendingPathComponent("missing.txt")))
    }

    /// Only a regular file has a fingerprint. A folder is refused before it
    /// is hashed, and a symbolic link is refused rather than followed, so
    /// neither can ever pass as a verified copy.
    func testFolderAndLinkHaveNoFingerprint() throws {
        let sandbox = makeSandbox()
        let target = try sandbox.makeFile("target.txt", contents: "Linked text")
        let folder = sandbox.scratchDirectory.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = sandbox.scratchDirectory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let targetFingerprint = try ContentFingerprint(of: target)

        for item in [folder, link] {
            XCTAssertThrowsError(try ContentFingerprint(of: item), item.lastPathComponent) { error in
                XCTAssertEqual(error as? ContentFingerprintError, .notARegularFile)
            }
            XCTAssertFalse(targetFingerprint.matchesFile(at: item), item.lastPathComponent)
        }
    }

    // MARK: - Sandbox

    /// One test's loose files and library folder.
    private struct Sandbox {
        /// A directory for loose files, such as originals, outside the library.
        let scratchDirectory: URL
        /// A library folder no other test uses; this test's packages go here.
        let folderPath: String

        /// The folder's directory under the library.
        var libraryFolder: URL {
            TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        }

        /// Writes `contents` to a file named `name` in the scratch directory.
        func makeFile(_ name: String, contents: String) throws -> URL {
            try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
            let url = scratchDirectory.appendingPathComponent(name)
            try Data(contents.utf8).write(to: url)
            return url
        }
    }

    /// Creates this test's sandbox and removes it when the test ends. Until
    /// then the Trash preference is off, so an original the migration
    /// removes is deleted rather than put in the developer's real Trash.
    private func makeSandbox() -> Sandbox {
        let sandbox = Sandbox(
            scratchDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("LegacyBookMigration-\(UUID().uuidString)", isDirectory: true),
            folderPath: "Legacy Migration \(UUID().uuidString.prefix(8))"
        )
        let previousTrashPreference = ConfigService.shared.config.moveToTrashInsteadOfDeleting
        ConfigService.shared.config.moveToTrashInsteadOfDeleting = false
        addTeardownBlock { @MainActor in
            ConfigService.shared.config.moveToTrashInsteadOfDeleting = previousTrashPreference
            try? FileManager.default.removeItem(at: sandbox.scratchDirectory)
            try? FileManager.default.removeItem(at: sandbox.libraryFolder)
        }
        return sandbox
    }
}

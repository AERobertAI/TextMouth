import XCTest
@testable import TextMouth

/// Exercise folder edits against both the model and real temporary storage.
@MainActor
final class FolderSafetyTests: XCTestCase {
    /// Old library indexes can predate folder-name validation. A destructive
    /// command must reject their root/traversal paths even when no books match.
    func testDeletionRejectsUnsafeLegacyFolderPaths() throws {
        XCTAssertTrue(TextMouthPaths.root.path.contains("TextMouthTests-"))
        try TextMouthPaths.ensureDirectoryStructure()
        let sentinel = TextMouthPaths.libraryDir.appendingPathComponent("Retain-\(UUID().uuidString).txt")
        try Data("Retain library".utf8).write(to: sentinel)
        defer { try? FileManager.default.removeItem(at: sentinel) }
        for name in ["", ".", ".."] {
            let folder = BookFolder(name: name)
            let viewModel = LibraryViewModel()
            viewModel.library = Library(folders: [folder])

            viewModel.removeFolderAndEverything(folder)

            XCTAssertTrue(viewModel.showError)
            XCTAssertEqual(viewModel.library.folders.map(\.id), [folder.id])
            XCTAssertEqual(try String(contentsOf: sentinel), "Retain library")
        }
    }

    /// Special components must never become a user-created library folder.
    func testCreationRejectsTraversalAndReservedNames() {
        for name in [".", "..", "  ..  ", "", "\0", "Book.TMB", "__recent__"] {
            var library = Library()
            XCTAssertNil(library.createFolder(name: name), name)
            XCTAssertTrue(library.folders.isEmpty, name)
        }
    }

    /// Preserve the established slash-to-hyphen behavior for ordinary titles.
    func testCreationNormalizesNamesAndRejectsUnsafeParents() {
        var library = Library()
        XCTAssertEqual(library.createFolder(name: "  Essays/Reports  ")?.name, "Essays-Reports")
        XCTAssertNil(library.createFolder(name: "Child", parentPath: "../Outside"))
        XCTAssertNil(library.createFolder(name: "Child", parentPath: "/Absolute"))
    }

    /// New names are stored in NFC with the user's casing, while decomposed
    /// names saved by older versions remain valid library paths.
    func testFolderNamesAreStoredComposedAndLegacyDecomposedPathsStayValid() throws {
        let decomposed = "Cafe\u{301} Notes"
        let composed = "Caf\u{E9} Notes"

        let normalized = try XCTUnwrap(BookFolder.normalizedName("  \(decomposed)  "))
        XCTAssertTrue(normalized.unicodeScalars.elementsEqual(composed.unicodeScalars))
        XCTAssertEqual(BookFolder.normalizedName("MiXeD Case"), "MiXeD Case")
        XCTAssertTrue(BookFolder.isValidLibraryPath("Work/\(decomposed)"))

        var library = Library()
        let folder = try XCTUnwrap(library.createFolder(name: decomposed))
        XCTAssertTrue(folder.name.unicodeScalars.elementsEqual(composed.unicodeScalars))
    }

    /// Reject a rename or move before any book or descendant paths change.
    func testRenameAndMoveRejectTraversal() throws {
        var library = Library()
        let folder = try XCTUnwrap(library.createFolder(name: "Original"))
        XCTAssertFalse(library.renameFolder(id: folder.id, to: ".."))
        XCTAssertFalse(library.moveFolder(id: folder.id, toParentPath: "../Outside"))
        XCTAssertEqual(library.folders.first?.fullPath, "Original")
    }

    /// A colliding file makes directory creation fail without leaving a row.
    func testFailedDirectoryCreationDoesNotPublishFolder() throws {
        let name = "FolderCollision-\(UUID().uuidString)"
        let url = TextMouthPaths.libraryDir.appendingPathComponent(name)
        try TextMouthPaths.ensureDirectoryStructure()
        try Data("keep".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let viewModel = LibraryViewModel()
        viewModel.library = Library()

        viewModel.createFolder(name: name, parentPath: "")

        XCTAssertTrue(viewModel.library.folders.isEmpty)
        XCTAssertTrue(viewModel.showError)
        XCTAssertEqual(try String(contentsOf: url), "keep")
    }

    /// Renaming a tree must create empty descendants as well as book packages.
    func testRenamingEmptyFolderTreeCreatesDestinationDirectories() throws {
        let name = "EmptyTree-\(UUID().uuidString)"
        let renamed = name + "-Renamed"
        let viewModel = LibraryViewModel()
        viewModel.library = Library()
        viewModel.createFolder(name: name, parentPath: "")
        viewModel.createFolder(name: "Child", parentPath: name)
        defer {
            for path in [name, renamed] {
                try? FileManager.default.removeItem(at: TextMouthPaths.libraryDir.appendingPathComponent(path))
            }
        }
        let folder = try XCTUnwrap(viewModel.library.folders.first { $0.name == name })

        viewModel.renameFolder(folder, to: renamed)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: TextMouthPaths.libraryDir.appendingPathComponent(renamed + "/Child").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: TextMouthPaths.libraryDir.appendingPathComponent(name).path
        ))
    }
}

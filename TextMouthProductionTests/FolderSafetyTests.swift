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

    // MARK: - Equivalent Folder Names

    /// Both volume policies, so every rule runs whichever way the test
    /// machine's own volume behaves.
    private let bothPolicies: [FolderPathEquivalence] = [.caseInsensitive, .caseSensitive]

    /// A book record for model-only tests; nothing is written to disk.
    private func book(_ title: String, folder: String) -> Book {
        Book(title: title, format: .txt, filePath: "/tmp/\(title).txt", md5Hash: title, folderPath: folder)
    }

    /// The conflict a folder edit threw, or nil when the edit succeeded.
    /// Closures do not infer typed throws in this language mode, so the edit
    /// is taken as an untyped throwing closure and its error cast back.
    private func conflict(
        _ edit: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> FolderOperationConflict? {
        do {
            try edit()
            return nil
        } catch let conflict as FolderOperationConflict {
            return conflict
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
            return nil
        }
    }

    /// A case variant collides only where the volume ignores case, while a
    /// normalization variant collides on every volume. Refusals name the
    /// folder that already exists.
    func testCreationRejectsEquivalentNamesUnderEachVolumePolicy() {
        for rule in bothPolicies {
            var library = Library()
            XCTAssertNil(conflict { _ = try library.createFolderThrowing(name: "Reports", equivalence: rule) })
            XCTAssertNil(conflict { _ = try library.createFolderThrowing(name: "Caf\u{E9}", equivalence: rule) })

            XCTAssertEqual(
                conflict { _ = try library.createFolderThrowing(name: "Cafe\u{301}", equivalence: rule) },
                .nameInUse(proposedPath: "Caf\u{E9}", existingPath: "Caf\u{E9}")
            )
            let caseVariant = conflict {
                _ = try library.createFolderThrowing(name: "reports", equivalence: rule)
            }
            if rule.isCaseSensitive {
                XCTAssertNil(caseVariant)
                XCTAssertEqual(library.folders.map(\.fullPath), ["Reports", "Caf\u{E9}", "reports"])
            } else {
                XCTAssertEqual(caseVariant, .nameInUse(proposedPath: "reports", existingPath: "Reports"))
                XCTAssertEqual(library.folders.map(\.fullPath), ["Reports", "Caf\u{E9}"])
            }
        }
    }

    /// A parent typed in another spelling files the new folder under the
    /// stored spelling where the volume ignores case, so it lists there.
    func testCreationAdoptsTheStoredSpellingOfAnEquivalentParent() throws {
        var insensitive = Library()
        try insensitive.createFolderThrowing(name: "Reports", equivalence: .caseInsensitive)
        let child = try insensitive.createFolderThrowing(
            name: "Q1", parentPath: "REPORTS", equivalence: .caseInsensitive
        )
        XCTAssertEqual(child.parentPath, "Reports")
        XCTAssertEqual(insensitive.subfolders(of: "Reports").map(\.name), ["Q1"])

        var sensitive = Library()
        try sensitive.createFolderThrowing(name: "Reports", equivalence: .caseSensitive)
        let separate = try sensitive.createFolderThrowing(
            name: "Q1", parentPath: "REPORTS", equivalence: .caseSensitive
        )
        XCTAssertEqual(separate.parentPath, "REPORTS")
    }

    /// Changing only a folder's capitalization renames that same folder under
    /// either policy, carrying its books, subfolders, and sort setting. A
    /// sibling with an equivalent name blocks a rename only where the volume
    /// ignores case.
    func testRenameAllowsCaseOnlyChangeAndRejectsEquivalentSiblings() throws {
        for rule in bothPolicies {
            var library = Library()
            let reports = try library.createFolderThrowing(name: "reports", equivalence: rule)
            try library.createFolderThrowing(name: "Q1", parentPath: "reports", equivalence: rule)
            let archive = try library.createFolderThrowing(name: "Archive", equivalence: rule)
            library.addBook(book("Budget", folder: "reports/Q1"))
            library.setSortSetting(FolderSortSetting(sortField: .author, sortAscending: false), for: "reports")

            XCTAssertNil(conflict {
                try library.renameFolderThrowing(id: reports.id, to: "Reports", equivalence: rule)
            })
            XCTAssertEqual(library.folders.map(\.fullPath), ["Reports", "Reports/Q1", "Archive"])
            XCTAssertEqual(library.books.first?.folderPath, "Reports/Q1")
            XCTAssertEqual(library.sortSetting(for: "Reports").sortField, .author)
            XCTAssertEqual(
                conflict { try library.renameFolderThrowing(id: reports.id, to: "Reports", equivalence: rule) },
                .unchanged
            )

            let siblingRename = conflict {
                try library.renameFolderThrowing(id: archive.id, to: "REPORTS", equivalence: rule)
            }
            if rule.isCaseSensitive {
                XCTAssertNil(siblingRename)
            } else {
                XCTAssertEqual(siblingRename, .nameInUse(proposedPath: "REPORTS", existingPath: "Reports"))
                XCTAssertEqual(library.folders.first { $0.id == archive.id }?.name, "Archive")
            }
        }
    }

    /// A folder saved with a decomposed name can be renamed to the composed
    /// spelling of the same name under either policy; the stored name and the
    /// paths inside it change to the composed form.
    func testNormalizationOnlyRenameRewritesTheStoredSpelling() throws {
        for rule in bothPolicies {
            let legacy = BookFolder(name: "Cafe\u{301}")
            var library = Library(books: [book("Menu", folder: "Cafe\u{301}")], folders: [legacy])

            XCTAssertNil(conflict {
                try library.renameFolderThrowing(id: legacy.id, to: "Caf\u{E9}", equivalence: rule)
            })

            let renamed = try XCTUnwrap(library.folders.first)
            XCTAssertTrue(BookFolder.spellingsMatch(renamed.name, "Caf\u{E9}"))
            XCTAssertTrue(BookFolder.spellingsMatch(library.books[0].folderPath, "Caf\u{E9}"))
        }
    }

    /// Moving beside an equivalent name is refused only where the volume
    /// ignores case, and a refused move changes nothing.
    func testMoveRejectsEquivalentNamesAtTheDestinationOnlyWhereCaseIsIgnored() throws {
        for rule in bothPolicies {
            var library = Library()
            try library.createFolderThrowing(name: "Inbox", equivalence: rule)
            let reports = try library.createFolderThrowing(name: "Reports", parentPath: "Inbox", equivalence: rule)
            try library.createFolderThrowing(name: "Archive", equivalence: rule)
            try library.createFolderThrowing(name: "reports", parentPath: "Archive", equivalence: rule)
            library.addBook(book("Budget", folder: "Inbox/Reports"))

            let move = conflict {
                try library.moveFolderThrowing(id: reports.id, toParentPath: "Archive", equivalence: rule)
            }

            if rule.isCaseSensitive {
                XCTAssertNil(move)
                XCTAssertEqual(library.books[0].folderPath, "Archive/Reports")
            } else {
                XCTAssertEqual(move, .nameInUse(proposedPath: "Archive/Reports", existingPath: "Archive/reports"))
                XCTAssertEqual(library.folders.first { $0.id == reports.id }?.fullPath, "Inbox/Reports")
                XCTAssertEqual(library.books[0].folderPath, "Inbox/Reports")
            }
        }
    }

    /// On a case-insensitive volume a destination typed in another spelling
    /// resolves to the stored folder: it is filed under that spelling, is
    /// recognized as the folder's own subtree, or as its current parent.
    func testMoveResolvesDestinationSpellingOnCaseInsensitiveVolumes() throws {
        var library = Library()
        let work = try library.createFolderThrowing(name: "Work", equivalence: .caseInsensitive)
        let quarter = try library.createFolderThrowing(name: "Q1", parentPath: "Work", equivalence: .caseInsensitive)
        let notes = try library.createFolderThrowing(name: "Notes", equivalence: .caseInsensitive)

        XCTAssertEqual(
            conflict { try library.moveFolderThrowing(id: work.id, toParentPath: "WORK/q1", equivalence: .caseInsensitive) },
            .destinationInsideFolder(folderPath: "Work", destinationPath: "Work/Q1")
        )
        XCTAssertEqual(
            conflict { try library.moveFolderThrowing(id: quarter.id, toParentPath: "work", equivalence: .caseInsensitive) },
            .unchanged
        )
        XCTAssertNil(conflict {
            try library.moveFolderThrowing(id: notes.id, toParentPath: "wOrK/q1", equivalence: .caseInsensitive)
        })
        XCTAssertEqual(library.folders.first { $0.id == notes.id }?.parentPath, "Work/Q1")
        XCTAssertEqual(library.subfolders(of: "Work/Q1").map(\.name), ["Notes"])
    }

    /// Refusals read as complete sentences that name the folders involved.
    func testConflictMessagesNameTheFoldersInvolved() {
        XCTAssertEqual(
            FolderOperationConflict.nameInUse(proposedPath: "Work/reports", existingPath: "Work/Reports").message,
            "A folder named \"Reports\" already exists in \"Work\". Names that differ only in "
                + "capitalization or accent encoding refer to the same folder on this disk."
        )
        XCTAssertEqual(
            FolderOperationConflict.nameInUse(proposedPath: "Sub", existingPath: "Sub").message,
            "A folder named \"Sub\" already exists in Library Root."
        )
        XCTAssertEqual(
            FolderOperationConflict.namesCollide(
                firstPath: "Old/Reports", secondPath: "Old/reports", parentPath: "Target"
            ).message,
            "The folders \"Reports\" and \"reports\" cannot both be moved into \"Target\", "
                + "because their names refer to the same folder on this disk."
        )
        XCTAssertEqual(
            FolderOperationConflict.tooDeep("A/B/C/D/E").message,
            "That would place \"A/B/C/D/E\" 5 levels deep, but folders can be nested at most 4 levels."
        )
        XCTAssertEqual(
            FolderOperationConflict.destinationInsideFolder(folderPath: "A", destinationPath: "A/B").message,
            "Choose a destination outside \"A\". \"A/B\" is that folder or one of its subfolders."
        )
    }

    // MARK: - Removing a Folder and Moving Its Contents

    /// Asserts that a refused edit left folders, books, and sort settings as
    /// they were in `snapshot`.
    private func assertUnchanged(
        _ library: Library,
        since snapshot: Library,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(library.folders, snapshot.folders, file: file, line: line)
        XCTAssertEqual(library.books, snapshot.books, file: file, line: line)
        XCTAssertEqual(library.folderSortSettings, snapshot.folderSortSettings, file: file, line: line)
    }

    /// A library with "Old" (holding "Sub" and "Notes", with books in "Old"
    /// and "Old/Sub" and a sort setting on "Old/Sub") and "Target" (holding
    /// `targetChild`), built under `rule`. Returns the library and "Old".
    private func removalLibrary(
        targetChild: String,
        rule: FolderPathEquivalence
    ) throws -> (library: Library, old: BookFolder) {
        var library = Library()
        let old = try library.createFolderThrowing(name: "Old", equivalence: rule)
        try library.createFolderThrowing(name: "Sub", parentPath: "Old", equivalence: rule)
        try library.createFolderThrowing(name: "Notes", parentPath: "Old", equivalence: rule)
        try library.createFolderThrowing(name: "Target", equivalence: rule)
        try library.createFolderThrowing(name: targetChild, parentPath: "Target", equivalence: rule)
        library.addBook(book("Loose", folder: "Old"))
        library.addBook(book("Filed", folder: "Old/Sub"))
        library.setSortSetting(FolderSortSetting(sortField: .author, sortAscending: false), for: "Old/Sub")
        return (library, old)
    }

    /// A subfolder whose name is already used at the destination refuses the
    /// removal under both policies when spelled identically, and where the
    /// volume ignores case when only the capitalization differs.
    func testRemovalRejectsSubfolderNamesAlreadyUsedAtTheDestination() throws {
        for rule in bothPolicies {
            let fixture = try removalLibrary(targetChild: "Notes", rule: rule)
            var library = fixture.library
            XCTAssertEqual(
                conflict {
                    try library.removeFolderThrowing(id: fixture.old.id, movingContentsTo: "Target", equivalence: rule)
                },
                .nameInUse(proposedPath: "Target/Notes", existingPath: "Target/Notes")
            )
            XCTAssertFalse(library.removeFolder(id: fixture.old.id, movingContentsTo: "Target", equivalence: rule))
            assertUnchanged(library, since: fixture.library)
        }

        for rule in bothPolicies {
            let fixture = try removalLibrary(targetChild: "sub", rule: rule)
            var library = fixture.library
            let removal = conflict {
                try library.removeFolderThrowing(id: fixture.old.id, movingContentsTo: "Target", equivalence: rule)
            }
            if rule.isCaseSensitive {
                XCTAssertNil(removal)
                XCTAssertEqual(
                    library.folders.map(\.fullPath).sorted(),
                    ["Target", "Target/Notes", "Target/Sub", "Target/sub"]
                )
            } else {
                XCTAssertEqual(removal, .nameInUse(proposedPath: "Target/Sub", existingPath: "Target/sub"))
                assertUnchanged(library, since: fixture.library)
            }
        }
    }

    /// Subfolders whose names differ only in case would collide with each
    /// other when moved together onto a case-insensitive volume.
    func testRemovalRejectsSubfoldersThatWouldCollideWithEachOther() {
        for rule in bothPolicies {
            let old = BookFolder(name: "Old")
            let original = Library(folders: [
                old,
                BookFolder(name: "Reports", parentPath: "Old"),
                BookFolder(name: "reports", parentPath: "Old"),
            ])
            var library = original

            let removal = conflict {
                try library.removeFolderThrowing(id: old.id, movingContentsTo: "", equivalence: rule)
            }

            if rule.isCaseSensitive {
                XCTAssertNil(removal)
                XCTAssertEqual(library.folders.map(\.fullPath), ["Reports", "reports"])
            } else {
                XCTAssertEqual(
                    removal,
                    .namesCollide(firstPath: "Old/Reports", secondPath: "Old/reports", parentPath: "")
                )
                assertUnchanged(library, since: original)
            }
        }
    }

    /// The destination can be neither the removed folder nor anything inside
    /// it, including a spelling the volume treats as the same folder.
    func testRemovalRejectsDestinationsInsideTheRemovedFolder() throws {
        for rule in bothPolicies {
            let fixture = try removalLibrary(targetChild: "Other", rule: rule)
            var library = fixture.library
            for destination in ["Old", "Old/Sub"] {
                XCTAssertEqual(
                    conflict {
                        try library.removeFolderThrowing(id: fixture.old.id, movingContentsTo: destination, equivalence: rule)
                    },
                    .destinationInsideFolder(folderPath: "Old", destinationPath: destination)
                )
            }
            assertUnchanged(library, since: fixture.library)
        }

        let fixture = try removalLibrary(targetChild: "Other", rule: .caseInsensitive)
        var library = fixture.library
        XCTAssertEqual(
            conflict {
                try library.removeFolderThrowing(
                    id: fixture.old.id, movingContentsTo: "OLD/sub", equivalence: .caseInsensitive
                )
            },
            .destinationInsideFolder(folderPath: "Old", destinationPath: "Old/Sub")
        )
        assertUnchanged(library, since: fixture.library)
    }

    /// Moving contents deeper must keep every relocated subfolder within
    /// `BookFolder.maxDepth`.
    func testRemovalRejectsSubtreesThatWouldExceedTheDepthLimit() throws {
        for rule in bothPolicies {
            var library = Library()
            let top = try library.createFolderThrowing(name: "A", equivalence: rule)
            try library.createFolderThrowing(name: "B", parentPath: "A", equivalence: rule)
            try library.createFolderThrowing(name: "C", parentPath: "A/B", equivalence: rule)
            try library.createFolderThrowing(name: "X", equivalence: rule)
            try library.createFolderThrowing(name: "Y", parentPath: "X", equivalence: rule)
            try library.createFolderThrowing(name: "Z", parentPath: "X/Y", equivalence: rule)
            library.addBook(book("Deep", folder: "A/B/C"))
            let original = library

            XCTAssertEqual(
                conflict { try library.removeFolderThrowing(id: top.id, movingContentsTo: "X/Y/Z", equivalence: rule) },
                .tooDeep("X/Y/Z/B/C")
            )
            assertUnchanged(library, since: original)
        }
    }

    /// The destination must be the library root or an existing folder, and
    /// the folder being removed must still be in the library.
    func testRemovalRejectsMissingOrInvalidDestinations() throws {
        let fixture = try removalLibrary(targetChild: "Other", rule: .caseInsensitive)
        var library = fixture.library

        XCTAssertEqual(
            conflict { try library.removeFolderThrowing(id: fixture.old.id, movingContentsTo: "Nowhere") },
            .destinationNotFound("Nowhere")
        )
        XCTAssertEqual(
            conflict { try library.removeFolderThrowing(id: fixture.old.id, movingContentsTo: "../Outside") },
            .invalidPath("../Outside")
        )
        XCTAssertEqual(
            conflict { try library.removeFolderThrowing(id: UUID(), movingContentsTo: "") },
            .folderNotFound
        )
        assertUnchanged(library, since: fixture.library)
    }

    /// The removed folder's own name is free for its contents, a destination
    /// in another spelling resolves to the stored folder, and books and sort
    /// settings keep their structure.
    func testRemovalReusesTheRemovedNameAndResolvesDestinationSpelling() throws {
        for rule in bothPolicies {
            var library = Library()
            let outer = try library.createFolderThrowing(name: "Books", equivalence: rule)
            try library.createFolderThrowing(name: "Books", parentPath: "Books", equivalence: rule)
            library.addBook(book("Inner", folder: "Books/Books"))

            XCTAssertNil(conflict {
                try library.removeFolderThrowing(id: outer.id, movingContentsTo: "", equivalence: rule)
            })
            XCTAssertEqual(library.folders.map(\.fullPath), ["Books"])
            XCTAssertEqual(library.books.first?.folderPath, "Books")
        }

        let fixture = try removalLibrary(targetChild: "Other", rule: .caseInsensitive)
        var library = fixture.library
        XCTAssertNil(conflict {
            try library.removeFolderThrowing(
                id: fixture.old.id, movingContentsTo: "tArGeT", equivalence: .caseInsensitive
            )
        })
        XCTAssertEqual(
            library.folders.map(\.fullPath).sorted(),
            ["Target", "Target/Notes", "Target/Other", "Target/Sub"]
        )
        XCTAssertEqual(library.books.first { $0.title == "Loose" }?.folderPath, "Target")
        XCTAssertEqual(library.books.first { $0.title == "Filed" }?.folderPath, "Target/Sub")
        XCTAssertEqual(library.sortSetting(for: "Target/Sub").sortField, .author)
        XCTAssertNil(library.folderSortSettings["Old/Sub"])
    }
}

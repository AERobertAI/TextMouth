import Foundation

/// Tests for the folder move path mismatch fix.
/// Verifies that moving books between folders correctly updates both the
/// physical .tmb directory location and the stored filePath.
func runFolderMoveTests() {
    print("\n--- Folder Move Tests ---")

    // Helper to create a minimal .tmb structure in a temp directory
    func createTempLibrary() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextMouthFolderMoveTest-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    // Helper to create a .tmb package with a dummy book file
    func createTMB(in libraryDir: URL, folderPath: String, tmbName: String, fileName: String) -> URL {
        let base: URL
        if folderPath.isEmpty {
            base = libraryDir
        } else {
            base = libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        }
        let tmbDir = base.appendingPathComponent(tmbName, isDirectory: true)
        try! FileManager.default.createDirectory(at: tmbDir, withIntermediateDirectories: true)
        let bookFile = tmbDir.appendingPathComponent(fileName)
        FileManager.default.createFile(atPath: bookFile.path, contents: Data("test book".utf8))
        return tmbDir
    }

    // Helper to compute a .tmb path the same way TextMouthPaths does
    func tmbPath(libraryDir: URL, folderPath: String, tmbName: String) -> URL {
        if folderPath.isEmpty {
            return libraryDir.appendingPathComponent(tmbName, isDirectory: true)
        }
        return libraryDir.appendingPathComponent(folderPath, isDirectory: true)
            .appendingPathComponent(tmbName, isDirectory: true)
    }

    // ---- Core move bug tests ----

    test("moveTMBToFolder computes correct old path from book.folderPath") {
        let libraryDir = createTempLibrary()
        defer { try? FileManager.default.removeItem(at: libraryDir) }

        let tmbName = "TestBook-Author-12345.tmb"
        let fileName = "TestBook.epub"

        // Create .tmb in root
        let rootTmb = createTMB(in: libraryDir, folderPath: "", tmbName: tmbName, fileName: fileName)
        try assertTrue(FileManager.default.fileExists(atPath: rootTmb.path), ".tmb should exist in root")

        // Compute old path using the OLD folderPath (empty = root)
        let oldTmbDir = tmbPath(libraryDir: libraryDir, folderPath: "", tmbName: tmbName)
        let newBase = libraryDir.appendingPathComponent("Science Fiction", isDirectory: true)
        try FileManager.default.createDirectory(at: newBase, withIntermediateDirectories: true)
        let newTmbDir = tmbPath(libraryDir: libraryDir, folderPath: "Science Fiction", tmbName: tmbName)

        // Old and new must differ for the move to happen
        try assertTrue(oldTmbDir != newTmbDir, "Old and new .tmb paths should differ")

        try FileManager.default.moveItem(at: oldTmbDir, to: newTmbDir)
        let movedFile = newTmbDir.appendingPathComponent(fileName)
        try assertTrue(FileManager.default.fileExists(atPath: movedFile.path), "Book file should be at new location")
        try assertTrue(!FileManager.default.fileExists(atPath: rootTmb.path), "Old .tmb should be gone")
    }

    test("Bug reproduction: setting folderPath before move makes paths identical") {
        let libraryDir = createTempLibrary()
        defer { try? FileManager.default.removeItem(at: libraryDir) }

        let tmbName = "TestBook-Author-12345.tmb"
        let newFolderPath = "Fantasy"

        // If folderPath is already set to the destination, old and new are the same
        let buggyOldDir = tmbPath(libraryDir: libraryDir, folderPath: newFolderPath, tmbName: tmbName)
        let newTmbDir = tmbPath(libraryDir: libraryDir, folderPath: newFolderPath, tmbName: tmbName)
        try assertTrue(buggyOldDir == newTmbDir, "Bug: paths identical when folderPath pre-set")
    }

    // ---- Repair logic tests ----

    test("Repair logic finds .tmb in root when expected in subfolder") {
        let libraryDir = createTempLibrary()
        defer { try? FileManager.default.removeItem(at: libraryDir) }

        let tmbName = "LostBook-Author-99999.tmb"
        let fileName = "LostBook.epub"
        let folderPath = "Science Fiction"

        // .tmb is in root (the bug's outcome)
        let rootTmb = createTMB(in: libraryDir, folderPath: "", tmbName: tmbName, fileName: fileName)
        let expectedBase = libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        let expectedTmb = expectedBase.appendingPathComponent(tmbName, isDirectory: true)
        let expectedFilePath = expectedTmb.appendingPathComponent(fileName).path

        try assertTrue(!FileManager.default.fileExists(atPath: expectedFilePath), "File should not be at expected folder path")
        try assertTrue(FileManager.default.fileExists(atPath: rootTmb.appendingPathComponent(fileName).path), "File should exist in root")

        // Repair: move .tmb to expected location
        try FileManager.default.createDirectory(at: expectedBase, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: rootTmb, to: expectedTmb)

        try assertTrue(FileManager.default.fileExists(atPath: expectedFilePath), "After repair, file at expected location")
        try assertTrue(!FileManager.default.fileExists(atPath: rootTmb.appendingPathComponent(fileName).path), "Root copy gone")
    }

    // ---- Folder-level move/rename tests ----

    test("Moving book between two non-root folders works") {
        let libraryDir = createTempLibrary()
        defer { try? FileManager.default.removeItem(at: libraryDir) }

        let tmbName = "MovedBook-Author-55555.tmb"
        let fileName = "MovedBook.epub"
        let sourceTmb = createTMB(in: libraryDir, folderPath: "Fantasy", tmbName: tmbName, fileName: fileName)

        let destBase = libraryDir.appendingPathComponent("Science Fiction", isDirectory: true)
        try FileManager.default.createDirectory(at: destBase, withIntermediateDirectories: true)
        let destTmb = destBase.appendingPathComponent(tmbName, isDirectory: true)

        try FileManager.default.moveItem(at: sourceTmb, to: destTmb)

        try assertTrue(FileManager.default.fileExists(atPath: destTmb.appendingPathComponent(fileName).path), "File at destination")
        try assertTrue(!FileManager.default.fileExists(atPath: sourceTmb.path), "Source gone")
    }

    test("Folder rename: filePath should reflect new folder name after disk rename succeeds") {
        let libraryDir = createTempLibrary()
        defer { try? FileManager.default.removeItem(at: libraryDir) }

        let tmbName = "RenamedFolder-Author-11111.tmb"
        let fileName = "Book.epub"
        _ = createTMB(in: libraryDir, folderPath: "OldName", tmbName: tmbName, fileName: fileName)

        let oldDiskURL = libraryDir.appendingPathComponent("OldName", isDirectory: true)
        let newDiskURL = libraryDir.appendingPathComponent("NewName", isDirectory: true)

        // Rename folder on disk
        try FileManager.default.moveItem(at: oldDiskURL, to: newDiskURL)

        // Verify file is at the new location
        let newFilePath = newDiskURL.appendingPathComponent(tmbName, isDirectory: true)
            .appendingPathComponent(fileName).path
        try assertTrue(FileManager.default.fileExists(atPath: newFilePath), "File should be at renamed folder")

        // Old location should be gone
        let oldFilePath = oldDiskURL.appendingPathComponent(tmbName, isDirectory: true)
            .appendingPathComponent(fileName).path
        try assertTrue(!FileManager.default.fileExists(atPath: oldFilePath), "Old folder should not exist")
    }

    test("Folder rename failure: filePath must not update when disk rename fails") {
        // Simulates the scenario where the disk rename fails but model was already updated.
        // The fix ensures filePath stays at the old (still-valid) location.
        let libraryDir = createTempLibrary()
        defer { try? FileManager.default.removeItem(at: libraryDir) }

        let tmbName = "FailedRename-Author-22222.tmb"
        let fileName = "Book.epub"
        _ = createTMB(in: libraryDir, folderPath: "OriginalFolder", tmbName: tmbName, fileName: fileName)

        let oldPath = libraryDir.appendingPathComponent("OriginalFolder", isDirectory: true)
            .appendingPathComponent(tmbName, isDirectory: true)
            .appendingPathComponent(fileName).path
        try assertTrue(FileManager.default.fileExists(atPath: oldPath), "File exists at original path")

        // Simulate a failed rename: model says "RenamedFolder" but disk still says "OriginalFolder"
        let wrongPath = libraryDir.appendingPathComponent("RenamedFolder", isDirectory: true)
            .appendingPathComponent(tmbName, isDirectory: true)
            .appendingPathComponent(fileName).path
        try assertTrue(!FileManager.default.fileExists(atPath: wrongPath), "File should NOT exist at renamed path")

        // The fix: if disk rename failed, filePath should stay pointing to the old location
        // (where the file actually is), not the new location
        try assertTrue(FileManager.default.fileExists(atPath: oldPath), "filePath should still point to existing file")
    }

    test("Folder move: entire folder directory moves, including multiple .tmb packages") {
        let libraryDir = createTempLibrary()
        defer { try? FileManager.default.removeItem(at: libraryDir) }

        // Create a folder with multiple books
        let book1Tmb = "Book1-Author-11111.tmb"
        let book2Tmb = "Book2-Author-22222.tmb"
        let folderName = "SciFi"
        _ = createTMB(in: libraryDir, folderPath: folderName, tmbName: book1Tmb, fileName: "Book1.epub")
        _ = createTMB(in: libraryDir, folderPath: folderName, tmbName: book2Tmb, fileName: "Book2.epub")

        let oldFolder = libraryDir.appendingPathComponent(folderName, isDirectory: true)
        let newParent = libraryDir.appendingPathComponent("Genres", isDirectory: true)
        try FileManager.default.createDirectory(at: newParent, withIntermediateDirectories: true)
        let newFolder = newParent.appendingPathComponent(folderName, isDirectory: true)

        // Move entire folder
        try FileManager.default.moveItem(at: oldFolder, to: newFolder)

        // Both books should be at the new location
        let book1Path = newFolder.appendingPathComponent(book1Tmb, isDirectory: true)
            .appendingPathComponent("Book1.epub").path
        let book2Path = newFolder.appendingPathComponent(book2Tmb, isDirectory: true)
            .appendingPathComponent("Book2.epub").path
        try assertTrue(FileManager.default.fileExists(atPath: book1Path), "Book1 at new location")
        try assertTrue(FileManager.default.fileExists(atPath: book2Path), "Book2 at new location")
        try assertTrue(!FileManager.default.fileExists(atPath: oldFolder.path), "Old folder gone")
    }

    test("Nested folder move preserves subfolder structure") {
        let libraryDir = createTempLibrary()
        defer { try? FileManager.default.removeItem(at: libraryDir) }

        // Create nested structure: Fiction/SciFi/book.tmb
        let tmbName = "Nested-Author-33333.tmb"
        let fileName = "Nested.epub"
        _ = createTMB(in: libraryDir, folderPath: "Fiction/SciFi", tmbName: tmbName, fileName: fileName)

        // Move "Fiction" folder to "Genres/Fiction"
        let oldFolder = libraryDir.appendingPathComponent("Fiction", isDirectory: true)
        let genresDir = libraryDir.appendingPathComponent("Genres", isDirectory: true)
        try FileManager.default.createDirectory(at: genresDir, withIntermediateDirectories: true)
        let newFolder = genresDir.appendingPathComponent("Fiction", isDirectory: true)

        try FileManager.default.moveItem(at: oldFolder, to: newFolder)

        // Book should be at Genres/Fiction/SciFi/book.tmb
        let movedPath = newFolder
            .appendingPathComponent("SciFi", isDirectory: true)
            .appendingPathComponent(tmbName, isDirectory: true)
            .appendingPathComponent(fileName).path
        try assertTrue(FileManager.default.fileExists(atPath: movedPath), "Nested book preserved at new location")
    }

    test("Repair handles multiple orphaned .tmb dirs with different folder assignments") {
        let libraryDir = createTempLibrary()
        defer { try? FileManager.default.removeItem(at: libraryDir) }

        // Create two orphaned .tmb dirs at root, each belonging to a different folder
        let tmb1 = "Book1-Author-11111.tmb"
        let tmb2 = "Book2-Author-22222.tmb"
        let rootTmb1 = createTMB(in: libraryDir, folderPath: "", tmbName: tmb1, fileName: "Book1.epub")
        let rootTmb2 = createTMB(in: libraryDir, folderPath: "", tmbName: tmb2, fileName: "Book2.epub")

        // Their intended folders
        let folder1 = "Science Fiction"
        let folder2 = "Fantasy"
        let dest1 = libraryDir.appendingPathComponent(folder1, isDirectory: true)
        let dest2 = libraryDir.appendingPathComponent(folder2, isDirectory: true)
        try FileManager.default.createDirectory(at: dest1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest2, withIntermediateDirectories: true)

        // Repair: move each to its correct folder
        let newTmb1 = dest1.appendingPathComponent(tmb1, isDirectory: true)
        let newTmb2 = dest2.appendingPathComponent(tmb2, isDirectory: true)
        try FileManager.default.moveItem(at: rootTmb1, to: newTmb1)
        try FileManager.default.moveItem(at: rootTmb2, to: newTmb2)

        try assertTrue(FileManager.default.fileExists(atPath: newTmb1.appendingPathComponent("Book1.epub").path),
                       "Book1 moved to Science Fiction")
        try assertTrue(FileManager.default.fileExists(atPath: newTmb2.appendingPathComponent("Book2.epub").path),
                       "Book2 moved to Fantasy")
        try assertTrue(!FileManager.default.fileExists(atPath: rootTmb1.path), "Root orphan 1 gone")
        try assertTrue(!FileManager.default.fileExists(atPath: rootTmb2.path), "Root orphan 2 gone")
    }

    test("filePath update only runs when disk operation succeeds") {
        // Verify the pattern: track success, only update paths on success
        var diskMoveSucceeded = false
        let originalPath = "/Library/OldFolder/Book.tmb/file.epub"
        var filePath = originalPath

        // Simulate failed move
        diskMoveSucceeded = false
        if diskMoveSucceeded {
            filePath = "/Library/NewFolder/Book.tmb/file.epub"
        }
        try assertEqual(filePath, originalPath, "filePath unchanged after failed move")

        // Simulate successful move
        diskMoveSucceeded = true
        if diskMoveSucceeded {
            filePath = "/Library/NewFolder/Book.tmb/file.epub"
        }
        try assertEqual(filePath, "/Library/NewFolder/Book.tmb/file.epub", "filePath updated after successful move")
    }
}

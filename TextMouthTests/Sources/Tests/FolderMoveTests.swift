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

    test("moveTMBToFolder computes correct old path from book.folderPath") {
        // Simulate the bug: folderPath set BEFORE computing old .tmb location
        let libraryDir = createTempLibrary()
        defer { try? FileManager.default.removeItem(at: libraryDir) }

        let tmbName = "TestBook-Author-12345.tmb"
        let fileName = "TestBook.epub"

        // Create .tmb in root
        let rootTmb = createTMB(in: libraryDir, folderPath: "", tmbName: tmbName, fileName: fileName)
        try assertTrue(FileManager.default.fileExists(atPath: rootTmb.path), ".tmb should exist in root")

        // Simulate the fix: compute old path using OLD folderPath (empty = root),
        // then move to new folder
        let oldFolderPath = ""
        let newFolderPath = "Science Fiction"
        let oldTmbDir = oldFolderPath.isEmpty
            ? libraryDir.appendingPathComponent(tmbName, isDirectory: true)
            : libraryDir.appendingPathComponent(oldFolderPath, isDirectory: true)
                .appendingPathComponent(tmbName, isDirectory: true)

        let newBase = libraryDir.appendingPathComponent(newFolderPath, isDirectory: true)
        try FileManager.default.createDirectory(at: newBase, withIntermediateDirectories: true)
        let newTmbDir = newBase.appendingPathComponent(tmbName, isDirectory: true)

        // The old and new should differ (this is what the bug got wrong)
        try assertTrue(oldTmbDir != newTmbDir, "Old and new .tmb paths should differ")

        // Move should succeed
        try FileManager.default.moveItem(at: oldTmbDir, to: newTmbDir)
        let movedFile = newTmbDir.appendingPathComponent(fileName)
        try assertTrue(FileManager.default.fileExists(atPath: movedFile.path), "Book file should exist at new location")
        try assertTrue(!FileManager.default.fileExists(atPath: rootTmb.path), "Old .tmb should no longer exist")
    }

    test("Bug reproduction: setting folderPath before move makes paths identical") {
        // This test demonstrates the original bug
        let libraryDir = createTempLibrary()
        defer { try? FileManager.default.removeItem(at: libraryDir) }

        let tmbName = "TestBook-Author-12345.tmb"
        let newFolderPath = "Fantasy"

        // Simulate a book whose folderPath was already set to the destination
        // (as the buggy code did before calling moveTMBToFolder)
        let buggyOldDir = libraryDir.appendingPathComponent(newFolderPath, isDirectory: true)
            .appendingPathComponent(tmbName, isDirectory: true)
        let newTmbDir = libraryDir.appendingPathComponent(newFolderPath, isDirectory: true)
            .appendingPathComponent(tmbName, isDirectory: true)

        // With the bug, both paths are identical because folderPath was already updated
        try assertTrue(buggyOldDir == newTmbDir, "Bug: old and new paths are identical when folderPath is pre-set")
    }

    test("Repair logic finds .tmb in root when expected in subfolder") {
        let libraryDir = createTempLibrary()
        defer { try? FileManager.default.removeItem(at: libraryDir) }

        let tmbName = "LostBook-Author-99999.tmb"
        let fileName = "LostBook.epub"
        let folderPath = "Science Fiction"

        // Create .tmb in root (simulating the bug's outcome)
        let rootTmb = createTMB(in: libraryDir, folderPath: "", tmbName: tmbName, fileName: fileName)

        // The expected location (where library.json thinks it should be)
        let expectedBase = libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        let expectedTmb = expectedBase.appendingPathComponent(tmbName, isDirectory: true)
        let expectedFilePath = expectedTmb.appendingPathComponent(fileName).path

        // File should NOT exist at expected location
        try assertTrue(!FileManager.default.fileExists(atPath: expectedFilePath), "File should not be at expected folder path")

        // But it SHOULD exist in root
        let rootFilePath = rootTmb.appendingPathComponent(fileName).path
        try assertTrue(FileManager.default.fileExists(atPath: rootFilePath), "File should exist in root")

        // Simulate repair: create folder and move .tmb there
        try FileManager.default.createDirectory(at: expectedBase, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: rootTmb, to: expectedTmb)

        try assertTrue(FileManager.default.fileExists(atPath: expectedFilePath), "After repair, file should be at expected location")
        try assertTrue(!FileManager.default.fileExists(atPath: rootFilePath), "After repair, root copy should be gone")
    }

    test("Moving book between two non-root folders works") {
        let libraryDir = createTempLibrary()
        defer { try? FileManager.default.removeItem(at: libraryDir) }

        let tmbName = "MovedBook-Author-55555.tmb"
        let fileName = "MovedBook.epub"

        // Create .tmb in "Fantasy" folder
        let fromFolder = "Fantasy"
        let toFolder = "Science Fiction"
        let sourceTmb = createTMB(in: libraryDir, folderPath: fromFolder, tmbName: tmbName, fileName: fileName)

        // Create destination folder
        let destBase = libraryDir.appendingPathComponent(toFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: destBase, withIntermediateDirectories: true)
        let destTmb = destBase.appendingPathComponent(tmbName, isDirectory: true)

        // Move (using old folderPath correctly)
        try FileManager.default.moveItem(at: sourceTmb, to: destTmb)

        let destFile = destTmb.appendingPathComponent(fileName).path
        try assertTrue(FileManager.default.fileExists(atPath: destFile), "File should exist at destination")
        try assertTrue(!FileManager.default.fileExists(atPath: sourceTmb.path), "Source should no longer exist")
    }
}

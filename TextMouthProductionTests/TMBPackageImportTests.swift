import XCTest
@testable import TextMouth

/// Regression coverage for validated adoption of external .tmb packages.
final class TMBPackageImportTests: XCTestCase {
    func testExternalPackageIsCopiedIntoManagedLibrary() throws {
        let external = try makePackage()
        defer { try? FileManager.default.removeItem(at: external) }

        let book = try FileImportService.importTMBPackage(from: external)
        defer { try? FileManager.default.removeItem(at: book.tmbDirectory) }

        XCTAssertTrue(book.filePath.hasPrefix(TextMouthPaths.libraryDir.path + "/"))
        XCTAssertFalse(book.filePath.hasPrefix(external.path + "/"))
        XCTAssertEqual(book.folderPath, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.filePath))

        try FileManager.default.removeItem(at: external)
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.filePath))
    }

    func testPackageWithTraversalFilenameIsRejected() throws {
        let external = try makePackage(originalFileName: "../outside.txt")
        defer { try? FileManager.default.removeItem(at: external) }

        XCTAssertThrowsError(try FileImportService.inspectTMBPackage(at: external))
    }

    func testPackageWithMismatchedContentHashIsRejected() throws {
        let external = try makePackage(metadataHash: "incorrect")
        defer { try? FileManager.default.removeItem(at: external) }

        XCTAssertThrowsError(try FileImportService.inspectTMBPackage(at: external)) { error in
            XCTAssertTrue(error.localizedDescription.contains("hash"))
        }
    }

    func testPackageWithSymlinkedContentIsRejected() throws {
        let external = try makePackage()
        defer { try? FileManager.default.removeItem(at: external) }
        let content = external.appendingPathComponent("book.txt")
        try FileManager.default.removeItem(at: content)
        try FileManager.default.createSymbolicLink(atPath: content.path, withDestinationPath: "/tmp")

        XCTAssertThrowsError(try FileImportService.inspectTMBPackage(at: external))
    }

    private func makePackage(
        originalFileName: String = "book.txt",
        metadataHash: String? = nil
    ) throws -> URL {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let safeContent = package.appendingPathComponent("book.txt")
        try Data("package content".utf8).write(to: safeContent)
        let hash = try FileImportService.md5Hash(of: safeContent)
        let info = BookInfo(
            metadata: BookMetadata(
                title: "External Book",
                author: "Package Author",
                format: .txt,
                md5Hash: metadataHash ?? hash,
                originalFileName: originalFileName,
                folderPath: "Untrusted/Folder",
                bookID: UUID()
            ),
            state: BookState(tmbDirectoryName: package.lastPathComponent)
        )
        try info.save(to: package)
        return package
    }
}

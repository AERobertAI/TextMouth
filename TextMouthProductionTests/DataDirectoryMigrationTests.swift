import XCTest
@testable import TextMouth

/// Regression coverage for recoverable data-directory migration.
final class DataDirectoryMigrationTests: XCTestCase {
    func testMigrationPublishesValidatedCopyAndRetainsSource() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let destination = base.appendingPathComponent("Destination", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let library = try makeLibrary(at: source)

        let migrated = try DataDirectoryMigrator.prepareMigration(
            from: source,
            to: destination,
            library: library
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(migrated.books[0].filePath.hasPrefix(destination.path + "/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: migrated.books[0].filePath))
        let package = destination.appendingPathComponent("Library/\(migrated.books[0].tmbDirectoryName)")
        let migratedInfo = try BookInfo.load(from: package)
        XCTAssertEqual(migratedInfo.metadata.folderPath, "")
        XCTAssertEqual(migratedInfo.contentIndex?.totalWordCount, 1)
        XCTAssertEqual(migratedInfo.contentIndex?.version, BookContentIndex.currentVersion)
    }

    func testNonemptyDestinationIsNeverOverwritten() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let destination = base.appendingPathComponent("Destination", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let library = try makeLibrary(at: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sentinel = destination.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)

        XCTAssertThrowsError(
            try DataDirectoryMigrator.prepareMigration(from: source, to: destination, library: library)
        )
        XCTAssertEqual(try String(contentsOf: sentinel), "keep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testMissingTrackedBookRejectsMigrationWithoutPublishingDestination() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let destination = base.appendingPathComponent("Destination", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        var library = try makeLibrary(at: source)
        try FileManager.default.removeItem(atPath: library.books[0].filePath)

        XCTAssertThrowsError(
            try DataDirectoryMigrator.prepareMigration(from: source, to: destination, library: library)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    private func makeLibrary(at root: URL) throws -> Library {
        let packageName = "\(UUID().uuidString).tmb"
        let package = root.appendingPathComponent("Library/\(packageName)", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Logs", isDirectory: true),
            withIntermediateDirectories: true
        )
        let content = package.appendingPathComponent("book.txt")
        try Data("migration".utf8).write(to: content)
        var book = Book(
            title: "Migrated Book",
            format: .txt,
            filePath: content.path,
            md5Hash: "hash",
            tmbDirectoryName: packageName
        )
        let index = BookContentIndex.build(
            fromChapters: [Chapter(title: "Migration", text: "migration")],
            format: .txt
        )
        book.applyContentIndexSummary(index)
        var info = book.makeBookInfo()
        info.contentIndex = index
        try info.save(to: package)
        return Library(books: [book])
    }
}

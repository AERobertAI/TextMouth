import XCTest
@testable import TextMouth

final class SharedPackageMigrationTests: XCTestCase {
    func testLegacySharedPackageIsSeparatedWithoutChangingItsOwner() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let libraryDirectory = root.appendingPathComponent("Library", isDirectory: true)
        let folder = "Anthologies"
        let packageName = "Shared-Legacy-1700000000.tmb"
        let package = libraryDirectory
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent(packageName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)

        let ownerSource = package.appendingPathComponent("volume-1.txt")
        let otherSource = package.appendingPathComponent("volume-2.txt")
        try Data("owner content".utf8).write(to: ownerSource)
        try Data("other content".utf8).write(to: otherSource)
        try Data("derived cache".utf8).write(
            to: TextMouthPaths.contentMarkdownPath(in: package)
        )

        var owner = Book(
            title: "Annual Collection",
            format: .txt,
            filePath: ownerSource.path,
            md5Hash: "owner-hash",
            folderPath: folder,
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
            tmbDirectoryName: packageName,
            cacheFormatVersion: MarkdownCacheService.currentCacheVersion
        )
        let ownerIndex = BookContentIndex.build(
            fromChapters: [Chapter(title: "Owner", text: "owner content")],
            format: .txt
        )
        owner.applyContentIndexSummary(ownerIndex)
        var ownerInfo = owner.makeBookInfo()
        ownerInfo.contentIndex = ownerIndex
        try ownerInfo.save(to: package)

        let other = Book(
            title: "Annual Collection",
            format: .txt,
            filePath: otherSource.path,
            md5Hash: "other-hash",
            folderPath: folder,
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
            tmbDirectoryName: packageName,
            cacheFormatVersion: MarkdownCacheService.currentCacheVersion,
            contentIndexVersion: BookContentIndex.currentVersion
        )
        var library = Library(books: [other, owner])

        let separated = FileImportService.separateSharedTMBPackages(
            library: &library,
            libraryDirectory: libraryDirectory
        )

        XCTAssertEqual(separated, 1)
        let retainedOwner = try XCTUnwrap(library.books.first { $0.id == owner.id })
        let repairedOther = try XCTUnwrap(library.books.first { $0.id == other.id })
        XCTAssertEqual(retainedOwner.tmbDirectoryName, packageName)
        XCTAssertNotEqual(repairedOther.tmbDirectoryName, packageName)
        XCTAssertTrue(repairedOther.tmbDirectoryName.contains(other.id.uuidString.lowercased()))
        XCTAssertNil(repairedOther.cacheFormatVersion)
        XCTAssertNil(repairedOther.contentIndexVersion)
        XCTAssertNil(repairedOther.totalWordCount)
        XCTAssertNil(repairedOther.totalCharacterCount)

        let repairedPackage = libraryDirectory
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent(repairedOther.tmbDirectoryName, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repairedOther.filePath))
        XCTAssertEqual(try String(contentsOfFile: repairedOther.filePath), "other content")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: TextMouthPaths.contentMarkdownPath(in: repairedPackage).path
        ))
        let repairedInfo = try BookInfo.load(from: repairedPackage)
        XCTAssertEqual(repairedInfo.metadata.bookID, other.id)
        XCTAssertEqual(repairedInfo.state.tmbDirectoryName, repairedOther.tmbDirectoryName)
        XCTAssertNil(repairedInfo.contentIndex)

        let retainedInfo = try BookInfo.load(from: package)
        XCTAssertEqual(retainedInfo.metadata.bookID, owner.id)
        XCTAssertEqual(retainedInfo.contentIndex, ownerIndex)
    }

    func testUniquePackagesAreLeftUntouched() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var library = Library(books: [
            Book(
                title: "Unique",
                format: .txt,
                filePath: root.appendingPathComponent("book.txt").path,
                md5Hash: "hash",
                tmbDirectoryName: "Unique.tmb"
            )
        ])

        XCTAssertEqual(
            FileImportService.separateSharedTMBPackages(
                library: &library,
                libraryDirectory: root
            ),
            0
        )
        XCTAssertEqual(library.books[0].tmbDirectoryName, "Unique.tmb")
    }
}

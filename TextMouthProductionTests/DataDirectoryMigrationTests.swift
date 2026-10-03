import XCTest
@testable import TextMouth

/// Regression coverage for recoverable data-directory migration.
final class DataDirectoryMigrationTests: XCTestCase {
    // MARK: - Overlapping Folders (F20)

    /// An alias must not bypass the no-parent/no-child migration rule and
    /// cause the staging copy to be written recursively into its own source.
    /// The refusal says how the folders overlap and names the link and the
    /// real folders (TODO S10).
    func testSymlinkCannotDisguiseDestinationInsideSource() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("Source", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let library = try makeLibrary(at: source)
        let alias = base.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let realSource = source.resolvingSymlinksInPath().path
        let refusals: [(destination: URL, overlap: DataDirectoryOverlap, realDestination: String)] = [
            (alias, .sameFolder, realSource),
            (alias.appendingPathComponent("Nested", isDirectory: true), .destinationInsideSource, realSource + "/Nested"),
        ]

        for refusal in refusals {
            XCTAssertThrowsError(
                try DataDirectoryMigrator.prepareMigration(from: source, to: refusal.destination, library: library)
            ) { error in
                guard case DataDirectoryMigrationError.invalidRelationship(let overlap, _, let destination) = error else {
                    return XCTFail("Expected relationship rejection, received \(error)")
                }
                XCTAssertEqual(overlap, refusal.overlap)
                XCTAssertEqual(destination.named.path, refusal.destination.path)
                XCTAssertEqual(destination.real.path, refusal.realDestination)
                let explanation = error.localizedDescription
                for path in [refusal.destination.path, refusal.realDestination, realSource] {
                    XCTAssertTrue(explanation.contains(path), "\(explanation) names \(path)")
                }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("Nested").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.books[0].filePath))
    }

    /// A new location that contains the current data directory, here a link
    /// to the folder holding it, is refused before anything is copied, and
    /// the refusal names the link and both real folders.
    func testNewLocationContainingTheDataDirectoryIsRefused() throws {
        let base = try makeMigrationBase()
        let parent = base.appendingPathComponent("Parent", isDirectory: true)
        let source = parent.appendingPathComponent(".TextMouth", isDirectory: true)
        let library = try makeLibrary(at: source)
        let link = base.appendingPathComponent("ParentLink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: parent)
        let before = try snapshot(of: base)

        XCTAssertThrowsError(
            try DataDirectoryMigrator.prepareMigration(from: source, to: link, library: library)
        ) { error in
            guard case DataDirectoryMigrationError.invalidRelationship(let overlap, _, _) = error else {
                return XCTFail("Expected relationship rejection, received \(error)")
            }
            XCTAssertEqual(overlap, .sourceInsideDestination)
            let explanation = error.localizedDescription
            for path in [link.path, parent.resolvingSymlinksInPath().path, source.resolvingSymlinksInPath().path] {
                XCTAssertTrue(explanation.contains(path), "\(explanation) names \(path)")
            }
        }
        XCTAssertEqual(try snapshot(of: base), before, "nothing was copied or changed")
    }

    /// Each overlap is explained in words that name both real folders, and
    /// every link that leads to one, exactly as the status line shows them
    /// and VoiceOver reads them.
    func testOverlapRefusalsNameBothRealFolders() {
        let current = location("/Users/reader/.TextMouth")
        let linkedCurrent = location("/Users/reader/.TextMouth", real: "/Volumes/Archive/.TextMouth")
        func refusal(_ overlap: DataDirectoryOverlap, _ source: DataDirectoryLocation, _ destination: DataDirectoryLocation) -> String {
            DataDirectoryMigrationError.invalidRelationship(overlap, source: source, destination: destination)
                .localizedDescription
        }

        XCTAssertEqual(
            refusal(.sameFolder, current, location("/Users/reader/Shortcut", real: "/Users/reader/.TextMouth")),
            "The new location, /Users/reader/Shortcut, leads to /Users/reader/.TextMouth, "
                + "which is the current data directory. Choose another location."
        )
        XCTAssertEqual(
            refusal(.sameFolder, linkedCurrent, location("/Volumes/Archive/.TextMouth")),
            "The new location, /Volumes/Archive/.TextMouth, is the current data directory, "
                + "where /Users/reader/.TextMouth leads. Choose another location."
        )
        XCTAssertEqual(
            refusal(.destinationInsideSource, current, location("/Users/reader/.TextMouth/Backup")),
            "The new location, /Users/reader/.TextMouth/Backup, is inside the current data directory, "
                + "/Users/reader/.TextMouth. Choose a location outside it."
        )
        XCTAssertEqual(
            refusal(.sourceInsideDestination, linkedCurrent, location("/Volumes/Archive")),
            "The new location, /Volumes/Archive, contains the current data directory, "
                + "/Volumes/Archive/.TextMouth, where /Users/reader/.TextMouth leads. "
                + "Choose a location that does not contain it."
        )
    }

    /// A name spelled through /private leads to the same folder as the
    /// spelling without it, so it is not described as a link.
    func testPrivateSpellingIsNotALink() {
        XCTAssertFalse(location("/private/tmp/Data/.TextMouth", real: "/tmp/Data/.TextMouth").isAlias)
        XCTAssertTrue(location("/tmp/Link/.TextMouth", real: "/tmp/Data/.TextMouth").isAlias)
    }

    // MARK: - Publication

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

    /// While library index writes are suspended, migration refuses before
    /// copying anything: the copy's library.json would publish the
    /// provisional library that stands in for an unreadable index.
    func testMigrationWaitsWhileTheLibraryIndexIsUnreadable() throws {
        let sandbox = try LibraryIndexSandbox.capture()
        defer { sandbox.restore() }
        try sandbox.stage(.truncated, at: sandbox.indexURL)
        _ = LibraryPersistenceService.load()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let destination = base.appendingPathComponent("Destination", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let library = try makeLibrary(at: source)

        XCTAssertThrowsError(
            try DataDirectoryMigrator.prepareMigration(from: source, to: destination, library: library)
        ) { error in
            guard case LibraryIndexRecoveryError.indexUnreadable = error else {
                return XCTFail("Expected the unreadable-index refusal, received \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Fixtures

    /// A new, empty folder in the temporary directory for one test's
    /// locations, removed when the test ends.
    private func makeMigrationBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataDirectoryMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return base
    }

    /// Everything under `folder`, by its path inside it: each file's bytes,
    /// each link's target, and each folder as an empty entry ending in "/".
    /// Equal snapshots mean nothing in the folder was added, removed, or
    /// changed. Links are recorded, never followed.
    private func snapshot(of folder: URL) throws -> [String: Data] {
        var entries: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(atPath: folder.path)
        while let relativePath = enumerator?.nextObject() as? String {
            let item = folder.appendingPathComponent(relativePath)
            switch enumerator?.fileAttributes?[.type] as? FileAttributeType {
            case .typeSymbolicLink?:
                entries[relativePath] = Data(try FileManager.default.destinationOfSymbolicLink(atPath: item.path).utf8)
            case .typeDirectory?:
                entries[relativePath + "/"] = Data()
            default:
                entries[relativePath] = try Data(contentsOf: item)
            }
        }
        return entries
    }

    /// A location named `named` that leads to `real`, or to itself when
    /// `real` is nil, without asking the file system.
    private func location(_ named: String, real: String? = nil) -> DataDirectoryLocation {
        DataDirectoryLocation(
            named: URL(fileURLWithPath: named),
            real: URL(fileURLWithPath: real ?? named)
        )
    }
}

extension XCTestCase {
    /// Lays out a data directory at `root` holding one packaged plain-text
    /// book with its analysis, and returns the library naming that book.
    /// The library is not written as `root`'s library.json. Shared by the
    /// data-directory and sandbox-container migration tests.
    func makeLibrary(at root: URL) throws -> Library {
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

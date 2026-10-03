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

    // MARK: - Linked Locations (S10)

    /// Acceptance (TODO S10): a data directory that is a link to a folder
    /// elsewhere is copied from that folder, never as the link. The new
    /// location holds a real copy whose books, named through the link or
    /// through the folder, all moved; the folder keeps its library.json,
    /// package records, and books byte for byte, and the link is untouched.
    func testLinkedDataDirectoryIsCopiedFromTheFolderItLeadsTo() throws {
        let base = try makeMigrationBase()
        let folder = base.appendingPathComponent("Elsewhere/Data", isDirectory: true)
        let home = base.appendingPathComponent("Home", isDirectory: true)
        let link = home.appendingPathComponent(".TextMouth")
        let destination = base.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        // One book named through the link, as the app names them, and one
        // named through the folder it leads to.
        let library = Library(books: try makeLibrary(at: link).books + makeLibrary(at: folder).books)
        try LibraryIndexSandbox.encoded(library).write(to: folder.appendingPathComponent("library.json"))
        let folderBefore = try snapshot(of: folder)

        let migrated = try DataDirectoryMigrator.prepareMigration(from: link, to: destination, library: library)

        XCTAssertThrowsError(
            try FileManager.default.destinationOfSymbolicLink(atPath: destination.path),
            "the new location is a real folder, not another link to the data"
        )
        XCTAssertEqual(try snapshot(of: folder), folderBefore, "the folder the link leads to is unchanged")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), folder.path)
        XCTAssertEqual(migrated.books.count, 2)
        for book in migrated.books {
            XCTAssertTrue(book.filePath.hasPrefix(destination.path + "/Library/"), book.filePath)
            XCTAssertEqual(try String(contentsOfFile: book.filePath, encoding: .utf8), "migration")
        }
        XCTAssertEqual(try publishedLibrary(in: destination).books.map(\.filePath), migrated.books.map(\.filePath))
    }

    /// Acceptance (TODO S10): a new location that is a link to an empty
    /// folder elsewhere receives the data in that folder. The link stays,
    /// still leading there, nothing is put beside it, and the books are
    /// named through it, as the preferences will name the data directory.
    func testLinkToAnEmptyFolderReceivesTheDataInThatFolder() throws {
        let base = try makeMigrationBase()
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let elsewhere = base.appendingPathComponent("Elsewhere", isDirectory: true)
        let folder = elsewhere.appendingPathComponent("Empty", isDirectory: true)
        let chosen = base.appendingPathComponent("Chosen", isDirectory: true)
        let link = chosen.appendingPathComponent(".TextMouth")
        let library = try makeLibrary(at: source)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let sourceBefore = try snapshot(of: source)

        let migrated = try DataDirectoryMigrator.prepareMigration(from: source, to: link, library: library)

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), folder.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: chosen.path), [".TextMouth"])
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)),
            ["Library", "Logs", "library.json"]
        )
        let book = try XCTUnwrap(migrated.books.first)
        XCTAssertTrue(book.filePath.hasPrefix(link.path + "/Library/"), book.filePath)
        XCTAssertEqual(try String(contentsOfFile: book.filePath, encoding: .utf8), "migration")
        XCTAssertEqual(try publishedLibrary(in: folder).books.map(\.filePath), [book.filePath])
        XCTAssertEqual(try snapshot(of: source), sourceBefore)
        XCTAssertEqual(stagingLeft(in: elsewhere), [])
    }

    /// A new location that is a link leading nowhere, to a missing folder or
    /// back to itself, is refused before anything is copied, naming the
    /// link and what it points to. Nothing is created where it points.
    func testLinkThatLeadsNowhereIsRefused() throws {
        let base = try makeMigrationBase()
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let library = try makeLibrary(at: source)
        let missing = base.appendingPathComponent("Unmounted/Data").path
        let dangling = base.appendingPathComponent("Dangling")
        let looping = base.appendingPathComponent("Looping")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: missing)
        try FileManager.default.createSymbolicLink(atPath: looping.path, withDestinationPath: looping.path)
        let before = try snapshot(of: base)

        for (link, target) in [(dangling, missing), (looping, looping.path)] {
            XCTAssertThrowsError(
                try DataDirectoryMigrator.prepareMigration(from: source, to: link, library: library)
            ) { error in
                guard case DataDirectoryMigrationError.unreachableLink(let refused, let refusedTarget) = error else {
                    return XCTFail("Expected the unreachable-link refusal, received \(error)")
                }
                XCTAssertEqual(refused.named.path, link.path)
                XCTAssertEqual(refusedTarget, target)
                XCTAssertEqual(
                    error.localizedDescription,
                    "The new location, \(link.path), is a link to \(target), which cannot be found. "
                        + "Choose another location."
                )
            }
        }
        XCTAssertEqual(try snapshot(of: base), before, "nothing was created, copied, or changed")
    }

    /// A new location that is a link to a folder holding anything is
    /// refused as that folder would be, and the folder is left as it was.
    func testLinkToAFolderThatIsNotEmptyIsRefused() throws {
        let base = try makeMigrationBase()
        let source = base.appendingPathComponent("Source", isDirectory: true)
        let library = try makeLibrary(at: source)
        let folder = base.appendingPathComponent("Elsewhere/Occupied", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: folder.appendingPathComponent("keep.txt"))
        let link = base.appendingPathComponent("Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let before = try snapshot(of: base)

        XCTAssertThrowsError(
            try DataDirectoryMigrator.prepareMigration(from: source, to: link, library: library)
        ) { error in
            guard case DataDirectoryMigrationError.destinationNotEmpty = error else {
                return XCTFail("Expected the not-empty refusal, received \(error)")
            }
        }
        XCTAssertEqual(try snapshot(of: base), before)
    }

    // MARK: - Fixtures

    /// The names of the hidden staging folders a migration left in `folder`.
    private func stagingLeft(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix(DataDirectoryMigrator.stagingNamePrefix) }
    }

    /// The library index published in the data directory at `root`.
    private func publishedLibrary(in root: URL) throws -> Library {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Library.self, from: Data(contentsOf: root.appendingPathComponent("library.json")))
    }

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

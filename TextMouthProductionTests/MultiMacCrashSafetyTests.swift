import XCTest
@testable import TextMouth

/// What another Mac sharing a library in the cloud can leave in the shared
/// files, fed to the code that reads each one (FR02 polish: several Macs).
///
/// Two Macs syncing one library can leave a sync service's conflict copy
/// beside a file (iCloud Drive's "name 2.json", Google Drive's
/// "name (1).json", Dropbox's "name (… conflicted copy …).json"), a file cut
/// short, a file whose content is only in the cloud, a package that
/// disappeared, a session lease of their own, and a library.json that lists
/// packages not on this Mac yet. None of these may crash TextMouth, hang its
/// main thread, or delete anything: it may log a line, show the recovery
/// sheet or the Library Not Available screen, or leave a row as it is.
/// Merging what two Macs wrote is left for later.
///
/// Real dataless files only come from a sync service, so a file "only in the
/// cloud" is either reported so by a fake sync service
/// (`FakeCloudItemStatusProvider`) or read through a reader that refuses as
/// a dataless file does (`EDEADLK`).
@MainActor
final class MultiMacCrashSafetyTests: XCTestCase {

    // MARK: - library.json

    /// Conflict copies beside library.json are never read or touched: the
    /// index itself loads, and writes go on.
    func testConflictCopiesBesideTheLibraryIndexAreLeftAlone() throws {
        _ = try makeOwnDataDirectory("IndexConflicts")
        let book = try makePackagedBook("Moby-Dick")
        let index = TextMouthPaths.libraryIndexFile
        try LibraryPersistenceService.encodedIndex(Library(books: [book])).write(to: index)
        let theirs = try LibraryPersistenceService.encodedIndex(Library(books: [book, bookNotHereYet("Emma")]))
        let copies = try writeConflictCopies(of: index, holding: theirs)

        let loaded = LibraryPersistenceService.load()

        XCTAssertEqual(loaded.library?.books.map(\.id), [book.id])
        XCTAssertFalse(LibraryPersistenceService.areIndexWritesSuspended)
        for copy in copies {
            XCTAssertEqual(try Data(contentsOf: copy), theirs, copy.lastPathComponent)
        }
    }

    /// A library.json cut short, as a write interrupted on another Mac can
    /// leave it, enters index recovery: its bytes are preserved beside it,
    /// and no save is written over it until the user chooses.
    func testAHalfWrittenLibraryIndexIsPreservedAndNotWrittenOver() throws {
        _ = try makeOwnDataDirectory("IndexHalf")
        let index = TextMouthPaths.libraryIndexFile
        let half = halfOf(try LibraryPersistenceService.encodedIndex(Library(books: [try makePackagedBook("Moby-Dick")])))
        try half.write(to: index)
        addTeardownBlock { LibraryPersistenceService.resumeIndexWrites() }

        let loaded = LibraryPersistenceService.load()

        guard case .unreadable(let failure) = loaded else {
            return XCTFail("a half-written index loaded as \(loaded)")
        }
        XCTAssertTrue(LibraryPersistenceService.areIndexWritesSuspended)
        XCTAssertEqual(try failure.quarantineURL.map { try Data(contentsOf: $0) }, half)

        LibraryPersistenceService.save(Library())
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(try Data(contentsOf: index), half, "the index was written over")
    }

    /// A library.json only in the cloud keeps the library unavailable, and
    /// is asked of the sync service, never read or downloaded on the spot.
    func testALibraryIndexOnlyInTheCloudLeavesTheLibraryUnavailable() throws {
        let root = try makeSandboxDirectory("IndexInCloud")
        let index = root.appendingPathComponent("library.json")
        let placeholder = Data("{}".utf8)
        try placeholder.write(to: index)
        let provider = FakeCloudItemStatusProvider()
        provider.setLocation(.cloud(.iCloudDrive), of: root)
        provider.setStatus(onlyInTheCloud, of: index)
        let check = DataDirectoryCheck(root: root, isDefaultLocation: false, expectedIdentity: nil, bookmark: nil)

        let outcome = check.run(itemStatus: provider)

        XCTAssertEqual(outcome, .unavailable(.notDownloaded(.iCloudDrive, folder: root.path)))
        XCTAssertEqual(provider.downloadRequests, [index])
        XCTAssertEqual(try Data(contentsOf: index), placeholder)
    }

    /// A library.json that lists packages not on this Mac yet, imported on
    /// another Mac and not synced here, keeps every row through the startup
    /// repair, and nothing is made where the packages will arrive.
    func testALibraryIndexListingPackagesNotHereYetKeepsEveryRow() throws {
        _ = try makeOwnDataDirectory("IndexAhead")
        let here = try makePackagedBook("Moby-Dick")
        let notHere = [bookNotHereYet("Emma"), bookNotHereYet("Dracula")]
        let library = Library(books: [here] + notHere)
        try LibraryPersistenceService.encodedIndex(library).write(to: TextMouthPaths.libraryIndexFile)
        let model = LibraryViewModel(initializeServices: false)
        model.library = try XCTUnwrap(LibraryPersistenceService.load().library)

        model.migrateOldBooksIfNeeded()
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(model.library.books.map(\.id), library.books.map(\.id), "a row was dropped")
        for book in notHere {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: book.tmbDirectory.path),
                "a package was made for \(book.title), which isn't here yet"
            )
        }
        XCTAssertEqual(
            LibraryPersistenceService.load().library?.books.map(\.id),
            library.books.map(\.id),
            "library.json lost a row"
        )
    }

    // MARK: - Package Records

    /// A conflict copy of a whole package, as two Macs writing one book's
    /// package can leave ("Book 2.tmb"), is not adopted as a second book,
    /// and stays where it is.
    func testAConflictCopyOfAPackageIsNotAdoptedAsASecondBook() throws {
        _ = try makeOwnDataDirectory("PackageConflict")
        let book = try makePackagedBook("Moby-Dick")
        let copyName = book.tmbDirectoryName.replacingOccurrences(of: ".tmb", with: " 2.tmb")
        let copy = book.tmbDirectory.deletingLastPathComponent().appendingPathComponent(copyName, isDirectory: true)
        try FileManager.default.copyItem(at: book.tmbDirectory, to: copy)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])

        model.migrateOldBooksIfNeeded()

        XCTAssertEqual(model.library.books.map(\.id), [book.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), "the conflict copy was removed")
    }

    /// Conflict copies of a book's record inside its package are never
    /// read: the record loads as it is, and a save writes the record alone.
    func testConflictCopiesOfARecordAreLeftAlone() throws {
        _ = try makeOwnDataDirectory("RecordConflicts")
        let book = try makePackagedBook("Moby-Dick")
        let record = TextMouthPaths.bookInfoPath(in: book.tmbDirectory)
        let theirs = halfOf(try Data(contentsOf: record))
        let copies = try writeConflictCopies(of: record, holding: theirs)

        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).metadata.bookID, book.id)
        var renamed = book
        renamed.title = "Moby-Dick; or, The Whale"
        LibraryPersistenceService.saveBookInfo(for: renamed)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).metadata.title, renamed.title)
        for copy in copies {
            XCTAssertEqual(try Data(contentsOf: copy), theirs, copy.lastPathComponent)
        }
    }

    /// A package another Mac left with its record cut short is not adopted,
    /// and is left as it is for that Mac to finish.
    func testAPackageWithAHalfWrittenRecordIsSkippedAndKept() throws {
        _ = try makeOwnDataDirectory("RecordHalf")
        let orphan = try makePackagedBook("Moby-Dick")
        let record = TextMouthPaths.bookInfoPath(in: orphan.tmbDirectory)
        let half = halfOf(try Data(contentsOf: record))
        try half.write(to: record)
        let model = LibraryViewModel(initializeServices: false)

        model.migrateOldBooksIfNeeded()

        XCTAssertEqual(model.library.books, [])
        XCTAssertEqual(try Data(contentsOf: record), half)
    }

    /// A save for a book whose package another Mac removed makes no package
    /// again: the write is dropped, with one log line.
    func testASaveForAPackageThatDisappearedMakesNothing() throws {
        _ = try makeOwnDataDirectory("PackageRemoved")
        let book = try makePackagedBook("Moby-Dick")
        try FileManager.default.removeItem(at: book.tmbDirectory)

        LibraryPersistenceService.saveBookInfo(for: book)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertFalse(FileManager.default.fileExists(atPath: book.tmbDirectory.path))
    }

    /// A package that disappeared reads as waiting for sync in a cloud
    /// library; nothing is asked of the sync service for it, and a kept
    /// book waiting so is not downloaded.
    func testAPackageThatDisappearedWaitsForSync() async throws {
        _ = try makeOwnDataDirectory("PackageGone")
        let gone = try makePackagedBook("Moby-Dick")
        try FileManager.default.removeItem(at: gone.tmbDirectory)
        let provider = FakeCloudItemStatusProvider()
        provider.setLocation(.cloud(.iCloudDrive), of: TextMouthPaths.root)
        let storage = BookCloudStorageService(items: provider, logEvent: { _ in })
        let states = BookCloudStates()

        await states.refresh([BookPackage(gone)], using: storage)

        XCTAssertEqual(states.state(of: gone.id), .waitingForSync)
        let kept = KeptBooks(file: nil)
        kept.keep([gone.id])
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [gone])
        XCTAssertNil(LibraryCloudCommands(states: states, kept: kept, storage: { storage }).downloadEvictedKeptBooks(in: model))
        XCTAssertEqual(provider.downloadRequests, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.tmbDirectory.path))
    }

    // MARK: - library-identity.json

    /// Conflict copies of the identity marker, even one naming another
    /// identity, change nothing: the marker itself decides, and stands.
    func testConflictCopiesOfTheIdentityMarkerChangeNothing() throws {
        let root = try makeSandboxDirectory("IdentityConflicts")
        let identity = try LibraryIdentity.adopt(in: root).identity
        let marker = LibraryIdentity.markerURL(in: root)
        let theirs = try identityData(LibraryIdentity(id: UUID(), created: Date(timeIntervalSince1970: 1_790_000_000)))
        let copies = try writeConflictCopies(of: marker, holding: theirs)
        try Data("{\"books\": [], \"folders\": []}".utf8).write(to: root.appendingPathComponent("library.json"))
        let check = DataDirectoryCheck(root: root, isDefaultLocation: false, expectedIdentity: identity.id, bookmark: nil)

        XCTAssertEqual(check.run(itemStatus: LocalItemStatusProvider()), .available(identity, relocatedTo: nil))
        XCTAssertEqual(try LibraryIdentity.adopt(in: root).identity, identity)
        for copy in copies {
            XCTAssertEqual(try Data(contentsOf: copy), theirs, copy.lastPathComponent)
        }
    }

    /// An identity marker cut short shows the Library Not Available screen
    /// with the reason, and is never replaced, not even by giving the
    /// library an identity again.
    func testAHalfWrittenIdentityMarkerShowsTheUnavailableScreenAndIsKept() throws {
        let root = try makeSandboxDirectory("IdentityHalf")
        let marker = LibraryIdentity.markerURL(in: root)
        let half = halfOf(try identityData(LibraryIdentity(id: UUID(), created: Date(timeIntervalSince1970: 1_790_000_000))))
        try half.write(to: marker)
        try Data("{\"books\": [], \"folders\": []}".utf8).write(to: root.appendingPathComponent("library.json"))
        let check = DataDirectoryCheck(root: root, isDefaultLocation: false, expectedIdentity: UUID(), bookmark: nil)

        let outcome = check.run(itemStatus: LocalItemStatusProvider())

        guard case .unavailable(.identityUnreadable(let folder, _)) = outcome else {
            return XCTFail("a half-written marker gave \(outcome)")
        }
        XCTAssertEqual(folder, root.path)
        XCTAssertThrowsError(try LibraryIdentity.adopt(in: root))
        XCTAssertEqual(try Data(contentsOf: marker), half)
    }

    /// An identity marker only in the cloud is asked of the sync service,
    /// and the library waits for it rather than reading it on the spot.
    func testAnIdentityMarkerOnlyInTheCloudIsAskedForNotRead() throws {
        let root = try makeSandboxDirectory("IdentityInCloud")
        let marker = LibraryIdentity.markerURL(in: root)
        try identityData(LibraryIdentity(id: UUID(), created: Date(timeIntervalSince1970: 1_790_000_000))).write(to: marker)
        try Data("{\"books\": [], \"folders\": []}".utf8).write(to: root.appendingPathComponent("library.json"))
        let provider = FakeCloudItemStatusProvider()
        provider.setLocation(.cloud(.googleDrive), of: root)
        provider.setStatus(onlyInTheCloud, of: marker)
        let check = DataDirectoryCheck(root: root, isDefaultLocation: false, expectedIdentity: UUID(), bookmark: nil)

        XCTAssertEqual(check.run(itemStatus: provider), .unavailable(.notDownloaded(.googleDrive, folder: root.path)))
        XCTAssertEqual(provider.downloadRequests, [marker])
    }

    // MARK: - Sessions

    /// Another Mac's lease, refreshed a moment ago, brings the warning, and
    /// stays as that Mac wrote it.
    func testAnotherMacsLeaseIsWarnedAboutAndKept() throws {
        let harness = try LeaseHarness(test: self)
        let theirs = try harness.writeOtherMac(named: "Galley", activeSecondsAgo: 30)
        let bytes = try Data(contentsOf: theirs)

        harness.lease.refresh()

        XCTAssertEqual(harness.warnings.map(\.computerName), ["Galley"])
        XCTAssertEqual(try Data(contentsOf: theirs), bytes, "another Mac's lease was changed")
    }

    /// Another Mac's lease cut short is judged by its modification date,
    /// naming no computer, and stays as it is.
    func testAHalfWrittenLeaseFromAnotherMacIsJudgedByItsDateAndKept() throws {
        let harness = try LeaseHarness(test: self)
        let theirs = try harness.writeOtherMac(named: "Galley", activeSecondsAgo: 30)
        let half = halfOf(try Data(contentsOf: theirs))
        try half.write(to: theirs)
        try FileManager.default.setAttributes(
            [.modificationDate: harness.now.addingTimeInterval(-30)],
            ofItemAtPath: theirs.path
        )

        harness.lease.refresh()

        XCTAssertEqual(
            harness.warnings,
            [LibrarySessionLease.OtherMac(computerName: LibrarySessionLease.anotherMac, minutesAgo: 0)]
        )
        XCTAssertEqual(try Data(contentsOf: theirs), half)
    }

    /// A conflict copy of this Mac's own lease, which a sync service makes
    /// when this Mac's newer lease meets an older one on its way back
    /// ("<ID> 2.json", "<ID> (1).json"), is not another Mac: TextMouth never
    /// warns that it is open on this very Mac, and the copies stay.
    func testAConflictCopyOfThisMacsOwnLeaseIsNotAnotherMac() throws {
        let harness = try LeaseHarness(test: self)
        harness.lease.refresh()
        let own = harness.sessions.appendingPathComponent("\(harness.lease.macID).json")
        let copies = try writeConflictCopies(of: own, holding: Data(contentsOf: own))

        harness.lease.refresh()

        XCTAssertEqual(harness.warnings, [], "this Mac was warned about itself")
        for copy in copies {
            XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), copy.lastPathComponent)
        }
    }

    // MARK: - config.json

    /// Conflict copies beside config.json are never read, and a save writes
    /// config.json alone.
    func testConflictCopiesBesideTheSettingsAreLeftAlone() throws {
        let file = try makeSandboxDirectory("ConfigConflicts").appendingPathComponent("config.json")
        try ConfigService.fileData(for: ConfigService.AppConfig()).write(to: file)
        let theirs = halfOf(try ConfigService.fileData(for: ConfigService.AppConfig()))
        let copies = try writeConflictCopies(of: file, holding: theirs)

        let service = ConfigService(fileURL: file)
        service.config.wordsPerMinute = 333
        service.saveToDisk()

        XCTAssertEqual(service.loadedFile, .decoded)
        XCTAssertEqual(try ConfigService.decode(Data(contentsOf: file)).wordsPerMinute, 333)
        for copy in copies {
            XCTAssertEqual(try Data(contentsOf: copy), theirs, copy.lastPathComponent)
        }
    }

    /// A config.json cut short is left as it is for correction: loading it
    /// changes nothing on disk.
    func testAHalfWrittenSettingsFileIsLeftAsItIs() throws {
        let file = try makeSandboxDirectory("ConfigHalf").appendingPathComponent("config.json")
        let half = halfOf(try ConfigService.fileData(for: ConfigService.AppConfig()))
        try half.write(to: file)

        let service = ConfigService(fileURL: file)

        XCTAssertEqual(service.loadedFile, .unreadable)
        XCTAssertEqual(try Data(contentsOf: file), half)
    }

    /// A config.json only in the cloud is neither read, which would wait on
    /// the network, nor written over, which would replace what another Mac
    /// saved.
    func testASettingsFileOnlyInTheCloudIsNeitherReadNorWritten() throws {
        let file = try makeSandboxDirectory("ConfigInCloud").appendingPathComponent("config.json")
        let theirs = try ConfigService.fileData(for: ConfigService.AppConfig())
        try theirs.write(to: file)
        let writes = WriteCounter()
        let service = ConfigService(fileURL: file, fileOperations: ConfigService.FileOperations(
            write: { data, url in
                writes.count += 1
                try data.write(to: url, options: .atomic)
            },
            openForEvents: { _ in -1 },
            close: { _ in },
            read: { _ in throw POSIXError(.EDEADLK) }
        ))

        service.config.wordsPerMinute = 333
        service.saveToDisk()

        XCTAssertEqual(service.loadedFile, .missing)
        XCTAssertEqual(writes.count, 0)
        XCTAssertEqual(try Data(contentsOf: file), theirs)
    }

    // MARK: - reading_stats.json

    /// Conflict copies beside the statistics are never read, and a save
    /// writes reading_stats.json alone.
    func testConflictCopiesBesideTheStatisticsAreLeftAlone() throws {
        let file = try makeSandboxDirectory("StatsConflicts").appendingPathComponent("reading_stats.json")
        try statsData(totalSeconds: 600).write(to: file)
        let theirs = try statsData(totalSeconds: 9_000)
        let copies = try writeConflictCopies(of: file, holding: theirs)

        let service = ReadingStatsService(fileURL: file)
        addTeardownBlock { @MainActor in service.shutdown() }
        service.save()
        ReadingStatsService.waitForQueuedSaves()

        XCTAssertEqual(service.stats.totalListeningSeconds, 600)
        for copy in copies {
            XCTAssertEqual(try Data(contentsOf: copy), theirs, copy.lastPathComponent)
        }
    }

    // MARK: - substitutions.json

    /// Conflict copies beside the substitution rules are never read.
    func testConflictCopiesBesideTheSubstitutionsAreLeftAlone() throws {
        reloadTheAppsRulesWhenTheTestEnds()
        let root = try makeOwnDataDirectory("RulesConflicts")
        let file = root.appendingPathComponent("substitutions.json")
        try rulesData(named: ["Harbor"]).write(to: file)
        let theirs = try rulesData(named: ["Galley", "Chart Room"])
        let copies = try writeConflictCopies(of: file, holding: theirs)
        let service = TextSubstitutionService.shared

        service.loadRules()

        XCTAssertEqual(service.rules.map(\.name), ["Harbor"])
        for copy in copies {
            XCTAssertEqual(try Data(contentsOf: copy), theirs, copy.lastPathComponent)
        }
    }

    // MARK: - reading-checkpoints.json

    /// A checkpoint journal cut short names no book, and the startup repair
    /// changes no row because of it.
    func testAHalfWrittenCheckpointJournalChangesNothing() throws {
        _ = try makeOwnDataDirectory("JournalHalf")
        let book = try makePackagedBook("Moby-Dick")
        let whole = try JSONSerialization.data(withJSONObject: ["books": [book.id.uuidString]])
        try halfOf(whole).write(to: TextMouthPaths.readingCheckpointsFile)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])

        XCTAssertEqual(LibraryPersistenceService.booksWithCheckpointsAhead(), [])
        model.migrateOldBooksIfNeeded()

        XCTAssertEqual(model.library.books, [book])
    }

    /// A checkpoint journal naming books whose packages aren't on this Mac,
    /// or that this library doesn't hold, changes no row.
    func testACheckpointJournalNamingBooksNotHereChangesNothing() throws {
        _ = try makeOwnDataDirectory("JournalAhead")
        let here = try makePackagedBook("Moby-Dick")
        let notHere = bookNotHereYet("Emma")
        let journal = ["books": [notHere.id.uuidString, here.id.uuidString, UUID().uuidString]]
        try JSONSerialization.data(withJSONObject: journal).write(to: TextMouthPaths.readingCheckpointsFile)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [here, notHere])

        model.migrateOldBooksIfNeeded()

        XCTAssertEqual(model.library.books, [here, notHere])
    }

    // MARK: - Fixtures

    /// A file's state as a sync service reports a file only in the cloud.
    private let onlyInTheCloud = CloudItemStatus(
        state: .notDownloaded,
        isUploaded: true,
        byteCount: 0,
        hasUnresolvedConflicts: false,
        downloadError: nil
    )

    /// A data directory of the test's own, with its Library folder, made the
    /// current one until the test ends, and its gate opened then.
    private func makeOwnDataDirectory(_ label: String) throws -> URL {
        let root = try makeDataDirectoryMoveDestination(label)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Library", isDirectory: true),
            withIntermediateDirectories: true
        )
        StorageBoundary.shared.publish(root: root)
        addTeardownBlock { DataDirectoryGate.open(root) }
        return root
    }

    /// A book in a package of its own at the top of the current data
    /// directory's Library folder, its file and its record written, as
    /// another Mac's import leaves it once it has synced.
    private func makePackagedBook(_ title: String) throws -> Book {
        let packageName = "\(title)-\(UUID().uuidString.prefix(8)).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: "", tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let file = package.appendingPathComponent("\(title).txt")
        try Data("Call me Ishmael.".utf8).write(to: file)
        let book = Book(
            title: title,
            format: .txt,
            filePath: file.path,
            md5Hash: UUID().uuidString,
            lastOpened: Date(timeIntervalSince1970: 1_790_000_000),
            tmbDirectoryName: packageName
        )
        try book.saveBookInfoThrowing()
        return book
    }

    /// A book library.json can list whose package isn't on this Mac yet:
    /// another Mac imported it, and its package hasn't synced.
    private func bookNotHereYet(_ title: String) -> Book {
        let packageName = "\(title)-\(UUID().uuidString.prefix(8)).tmb"
        let file = TextMouthPaths.tmbPath(folderPath: "", tmbName: packageName).appendingPathComponent("\(title).txt")
        return Book(
            title: title,
            format: .txt,
            filePath: file.path,
            md5Hash: UUID().uuidString,
            lastOpened: Date(timeIntervalSince1970: 1_790_000_000),
            tmbDirectoryName: packageName
        )
    }

    /// Writes the conflict copies sync services make of `file` when two Macs
    /// write it, each holding `contents`, and returns them: iCloud Drive's
    /// "name 2.json", Google Drive's "name (1).json", and Dropbox's
    /// "name (Galley's conflicted copy 2026-10-03).json".
    @discardableResult
    private func writeConflictCopies(of file: URL, holding contents: Data) throws -> [URL] {
        let name = file.deletingPathExtension().lastPathComponent
        let folder = file.deletingLastPathComponent()
        let copies = ["\(name) 2", "\(name) (1)", "\(name) (Galley's conflicted copy 2026-10-03)"].map {
            folder.appendingPathComponent($0).appendingPathExtension(file.pathExtension)
        }
        for copy in copies {
            try contents.write(to: copy)
        }
        return copies
    }

    /// The first half of `data`, as a write interrupted on another Mac
    /// leaves a file.
    private func halfOf(_ data: Data) -> Data {
        data.prefix(data.count / 2)
    }

    /// An identity marker's bytes, as `LibraryIdentity` writes them.
    private func identityData(_ identity: LibraryIdentity) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(identity)
    }

    /// reading_stats.json's bytes for statistics with `totalSeconds` of
    /// listening, all of it on one day and one book.
    private func statsData(totalSeconds: TimeInterval) throws -> Data {
        var stats = ReadingStats()
        stats.addListening(totalSeconds, bookID: UUID(), dayKey: "2026-10-02")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(stats)
    }

    /// substitutions.json's bytes for plain rules with the names given.
    private func rulesData(named names: [String]) throws -> Data {
        try JSONEncoder().encode(names.map {
            SubstitutionRule(name: $0, pattern: $0.lowercased(), replacement: $0, isRegex: false)
        })
    }

    /// When the test ends, has the app's substitution service read the test
    /// host's own rules again, in the data directory in use now. Call it
    /// before the test makes a data directory of its own: teardown runs last
    /// what was registered first, so this runs once that data directory is
    /// put back and removed.
    private func reloadTheAppsRulesWhenTheTestEnds() {
        let sandboxRoot = TextMouthPaths.root
        addTeardownBlock { @MainActor in
            restoreDataDirectory(sandboxRoot)
            TextSubstitutionService.shared.loadRules()
        }
    }
}

/// Counts the writes a test's file operations make.
@MainActor
private final class WriteCounter {
    /// How many writes were made.
    var count = 0
}

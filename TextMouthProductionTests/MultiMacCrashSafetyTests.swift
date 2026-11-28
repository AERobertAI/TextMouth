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
        _ = try makeCurrentDataDirectory("IndexConflicts")
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
        _ = try makeCurrentDataDirectory("IndexHalf")
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
        _ = try makeCurrentDataDirectory("IndexAhead")
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
        _ = try makeCurrentDataDirectory("PackageConflict")
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
        _ = try makeCurrentDataDirectory("RecordConflicts")
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
        _ = try makeCurrentDataDirectory("RecordHalf")
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
        _ = try makeCurrentDataDirectory("PackageRemoved")
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
        _ = try makeCurrentDataDirectory("PackageGone")
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
    func testAnotherMacsLeaseIsWarnedAboutAndKept() async throws {
        let harness = try LeaseHarness(test: self)
        let theirs = try harness.writeOtherMac(named: "Galley", activeSecondsAgo: 30)
        let bytes = try Data(contentsOf: theirs)

        await harness.lease.refresh()

        XCTAssertEqual(harness.warnings.map(\.computerName), ["Galley"])
        XCTAssertEqual(try Data(contentsOf: theirs), bytes, "another Mac's lease was changed")
    }

    /// Another Mac's lease cut short is judged by its modification date,
    /// naming no computer, and stays as it is.
    func testAHalfWrittenLeaseFromAnotherMacIsJudgedByItsDateAndKept() async throws {
        let harness = try LeaseHarness(test: self)
        let theirs = try harness.writeOtherMac(named: "Galley", activeSecondsAgo: 30)
        let half = halfOf(try Data(contentsOf: theirs))
        try half.write(to: theirs)
        try FileManager.default.setAttributes(
            [.modificationDate: harness.now.addingTimeInterval(-30)],
            ofItemAtPath: theirs.path
        )

        await harness.lease.refresh()

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
    func testAConflictCopyOfThisMacsOwnLeaseIsNotAnotherMac() async throws {
        let harness = try LeaseHarness(test: self)
        await harness.lease.refresh()
        let own = harness.sessions.appendingPathComponent("\(harness.lease.macID).json")
        let copies = try writeConflictCopies(of: own, holding: Data(contentsOf: own))

        await harness.lease.refresh()

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

        let service = makeConfigService(fileURL: file)
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

        let service = makeConfigService(fileURL: file)

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
        let service = makeConfigService(fileURL: file, fileOperations: ConfigService.FileOperations(
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

    /// Statistics only in the cloud are not read on the main thread, which
    /// would wait on the network: the sync service is asked for them, and
    /// this session's listening stands in. No save replaces the file
    /// meanwhile; the first save that finds it on this Mac adds that
    /// listening to what it holds.
    func testStatisticsOnlyInTheCloudAreNeverSavedOver() throws {
        let file = try makeSandboxDirectory("StatsInCloud").appendingPathComponent("reading_stats.json")
        let theirs = try statsData(totalSeconds: 9_000)
        try theirs.write(to: file)
        let provider = FakeCloudItemStatusProvider()
        installItemStatus(provider)
        let reader = CloudFileReader()
        let service = ReadingStatsService(fileURL: file, readFile: { try reader.read($0) })
        addTeardownBlock { @MainActor in service.shutdown() }

        XCTAssertTrue(service.statsAwaitFileInCloud)
        XCTAssertEqual(service.stats.totalListeningSeconds, 0)
        XCTAssertEqual(provider.downloadRequests, [file])

        let book = UUID()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        service.startSession(bookID: book, at: start)
        service.endSession(at: start.addingTimeInterval(120))
        ReadingStatsService.waitForQueuedSaves()
        XCTAssertEqual(try Data(contentsOf: file), theirs, "the stand-ins were saved over the file in the cloud")

        // The file is on this Mac now: the next save adds to what it holds.
        reader.isInCloud = false
        service.startSession(bookID: book, at: start.addingTimeInterval(200))
        service.endSession(at: start.addingTimeInterval(260))
        ReadingStatsService.waitForQueuedSaves()

        XCTAssertFalse(service.statsAwaitFileInCloud)
        XCTAssertEqual(service.stats.totalListeningSeconds, 9_180)
        XCTAssertEqual(service.stats.bookListeningSeconds[book.uuidString], 180)
        XCTAssertEqual(try decodedStats(at: file).totalListeningSeconds, 9_180)
    }

    /// Statistics found only in the cloud are taken up the moment the library's
    /// fetch brings the file (`fileMayHaveArrived()`), without waiting for a
    /// save: nothing is written over the file meanwhile or by the hook, and
    /// the listening credited meanwhile is added to what the file holds.
    func testStatisticsThatArriveAreTakenUpByTheFetchWithoutASave() throws {
        let file = try makeSandboxDirectory("StatsArrive").appendingPathComponent("reading_stats.json")
        let theirs = try statsData(totalSeconds: 9_000)
        try theirs.write(to: file)
        installItemStatus(FakeCloudItemStatusProvider())
        let reader = CloudFileReader()
        let service = ReadingStatsService(fileURL: file, readFile: { try reader.read($0) })
        addTeardownBlock { @MainActor in service.shutdown() }
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        service.startSession(bookID: UUID(), at: start)
        service.endSession(at: start.addingTimeInterval(120))
        ReadingStatsService.waitForQueuedSaves()

        service.fileMayHaveArrived()

        XCTAssertTrue(service.statsAwaitFileInCloud, "the file is still in the cloud")
        XCTAssertEqual(try Data(contentsOf: file), theirs)

        reader.isInCloud = false
        service.fileMayHaveArrived()

        XCTAssertFalse(service.statsAwaitFileInCloud)
        XCTAssertEqual(service.stats.totalListeningSeconds, 9_120)
        XCTAssertEqual(try Data(contentsOf: file), theirs, "taking the file up wrote over it")
    }

    /// A settings file found only in the cloud is merged by the fetch's hook
    /// once it arrives, without a restart: a setting changed here meanwhile
    /// keeps its new value, every other one takes the file's, and until then
    /// nothing is written over the file.
    func testSettingsThatArriveAreMergedByTheFetchWithoutARestart() throws {
        let file = try makeSandboxDirectory("ConfigArrive").appendingPathComponent("config.json")
        var theirConfig = ConfigService.AppConfig()
        theirConfig.pitchMultiplier = 1.5
        let theirs = try ConfigService.fileData(for: theirConfig)
        try theirs.write(to: file)
        let inCloud = CloudFlag()
        let service = makeConfigService(fileURL: file, fileOperations: ConfigService.FileOperations(
            write: { data, url in try data.write(to: url, options: .atomic) },
            openForEvents: { _ in -1 },
            close: { _ in },
            read: { url in
                if inCloud.value { throw POSIXError(.EDEADLK) }
                return try Data(contentsOf: url)
            }
        ))
        // The very first change is made while the file is in the cloud, with
        // no save attempted before it: loading the file recorded the
        // settings then in use as what it held.
        service.config.wordsPerMinute = 333
        service.saveToDisk()
        service.fileMayHaveArrived()
        XCTAssertEqual(try Data(contentsOf: file), theirs, "the file in the cloud was written over")

        inCloud.value = false
        service.fileMayHaveArrived()

        XCTAssertEqual(service.config.wordsPerMinute, 333, "the change made meanwhile was lost")
        XCTAssertEqual(service.config.pitchMultiplier, 1.5, "the file's setting was not taken up")
        let saved = try ConfigService.decode(Data(contentsOf: file))
        XCTAssertEqual(saved.wordsPerMinute, 333)
        XCTAssertEqual(saved.pitchMultiplier, 1.5)
    }

    /// Statistics cut short, as a write interrupted on another Mac leaves
    /// them, are preserved beside the file before anything replaces it, so
    /// nothing they held is lost; the statistics start afresh, and the next
    /// save writes them.
    func testHalfWrittenStatisticsArePreservedBeforeTheyAreReplaced() throws {
        let file = try makeSandboxDirectory("StatsHalf").appendingPathComponent("reading_stats.json")
        let half = halfOf(try statsData(totalSeconds: 9_000))
        try half.write(to: file)

        let service = ReadingStatsService(fileURL: file)
        addTeardownBlock { @MainActor in service.shutdown() }

        XCTAssertEqual(service.stats.totalListeningSeconds, 0)
        let copies = LibraryIndexQuarantine.existingCopies(of: file)
        XCTAssertEqual(copies.count, 1, "the half-written statistics were not preserved")
        XCTAssertEqual(try copies.first.map { try Data(contentsOf: $0) }, half)

        let start = Date(timeIntervalSince1970: 1_790_000_000)
        service.startSession(bookID: UUID(), at: start)
        service.endSession(at: start.addingTimeInterval(60))
        ReadingStatsService.waitForQueuedSaves()

        XCTAssertEqual(try decodedStats(at: file).totalListeningSeconds, 60)
        XCTAssertEqual(try copies.first.map { try Data(contentsOf: $0) }, half, "the preserved copy changed")
    }

    /// Statistics that stood in for a file add to what the file holds: each
    /// day's, each book's, and the total listening, and the books finished
    /// that the file doesn't list yet.
    func testStandInStatisticsAddToTheFilesOwn() {
        let shared = UUID()
        let other = UUID()
        let finished = FinishedBookEntry(
            bookID: shared.uuidString,
            title: "Moby-Dick",
            dateFinished: Date(timeIntervalSince1970: 1_790_000_000)
        )
        var file = ReadingStats()
        file.addListening(100, bookID: shared, dayKey: "2026-10-01")
        file.finishedBooks = [finished]
        var standIn = ReadingStats()
        standIn.addListening(30, bookID: shared, dayKey: "2026-10-01")
        standIn.addListening(20, bookID: other, dayKey: "2026-10-03")
        standIn.finishedBooks = [
            finished,
            FinishedBookEntry(bookID: other.uuidString, title: "Emma", dateFinished: Date(timeIntervalSince1970: 1_790_100_000)),
        ]

        let sum = file.adding(standIn)

        XCTAssertEqual(sum.totalListeningSeconds, 150)
        XCTAssertEqual(sum.dailyListeningSeconds, ["2026-10-01": 130, "2026-10-03": 20])
        XCTAssertEqual(sum.bookListeningSeconds, [shared.uuidString: 130, other.uuidString: 20])
        XCTAssertEqual(sum.finishedBooks.map(\.title), ["Moby-Dick", "Emma"])
        XCTAssertEqual(sum.dayKeyVersion, file.dayKeyVersion)
    }

    // MARK: - substitutions.json

    /// Conflict copies beside the substitution rules are never read.
    func testConflictCopiesBesideTheSubstitutionsAreLeftAlone() throws {
        reloadTheAppsRulesWhenTheTestEnds()
        let root = try makeCurrentDataDirectory("RulesConflicts")
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

    /// Substitution rules cut short, as a write interrupted on another Mac
    /// leaves them, are preserved beside the file before the next save
    /// replaces it, so none of the user's own rules is lost; the standard
    /// rules stand in meanwhile.
    func testHalfWrittenSubstitutionsArePreservedBeforeTheyAreReplaced() throws {
        reloadTheAppsRulesWhenTheTestEnds()
        let root = try makeCurrentDataDirectory("RulesHalf")
        let file = root.appendingPathComponent("substitutions.json")
        let half = halfOf(try rulesData(named: ["Harbor", "Galley"]))
        try half.write(to: file)
        let service = TextSubstitutionService.shared

        service.loadRules()

        XCTAssertEqual(service.rules.map(\.name), TextSubstitutionService.defaultRules.map(\.name))
        let copies = LibraryIndexQuarantine.existingCopies(of: file)
        XCTAssertEqual(copies.count, 1, "the half-written rules were not preserved")
        XCTAssertEqual(try copies.first.map { try Data(contentsOf: $0) }, half)

        service.addRule(SubstitutionRule(name: "Chart Room", pattern: "chart", replacement: "chart", isRegex: false))

        XCTAssertEqual(
            try JSONDecoder().decode([SubstitutionRule].self, from: Data(contentsOf: file)).last?.name,
            "Chart Room"
        )
        XCTAssertEqual(try copies.first.map { try Data(contentsOf: $0) }, half, "the preserved copy changed")
    }

    /// Substitution rules only in the cloud are not read on the main
    /// thread: the sync service is asked for them, once, and the standard
    /// rules stand in. A change made meanwhile is reported unsaved, and
    /// nothing is written over the file; once it is on this Mac, its rules
    /// replace the stand-ins, and the change is no longer pending.
    func testSubstitutionsOnlyInTheCloudAreNeverSavedOver() throws {
        reloadTheAppsRulesWhenTheTestEnds()
        let center = cleanSharedFailureCenter()
        let root = try makeCurrentDataDirectory("RulesInCloud")
        let file = root.appendingPathComponent("substitutions.json")
        let theirs = try rulesData(named: ["Harbor"])
        try theirs.write(to: file)
        let provider = FakeCloudItemStatusProvider()
        installItemStatus(provider)
        let reader = CloudFileReader()
        let service = TextSubstitutionService.shared
        readTheAppsRules(through: reader)

        service.loadRules()

        XCTAssertTrue(service.rulesAwaitFileInCloud)
        XCTAssertEqual(service.rules.map(\.name), TextSubstitutionService.defaultRules.map(\.name))

        service.addRule(SubstitutionRule(name: "Galley", pattern: "galley", replacement: "galley", isRegex: false))
        service.readFileWaitingInTheCloud()

        XCTAssertEqual(try Data(contentsOf: file), theirs, "the stand-ins were saved over the file in the cloud")
        XCTAssertEqual(center.outstandingFailures().map(\.subject), [.substitutions])
        XCTAssertEqual(provider.downloadRequests, [file], "the sync service is asked once")

        // The file is on this Mac now.
        reader.isInCloud = false
        service.readFileWaitingInTheCloud()

        XCTAssertFalse(service.rulesAwaitFileInCloud)
        XCTAssertEqual(service.rules.map(\.name), ["Harbor"])
        XCTAssertEqual(try Data(contentsOf: file), theirs)
        XCTAssertTrue(center.outstandingFailures().isEmpty, "the stand-ins' change is still reported")
    }

    /// On a new Mac whose library is in the cloud, a first launch that finds
    /// no substitutions.json, which the sync service hasn't brought down
    /// yet, has the standard rules stand in and writes nothing, so it makes
    /// no file of its own for the sync service to set against another
    /// Mac's. A rule changed then writes the rules, the change with them.
    func testTheStandardRulesAreWrittenOnlyOnceARuleChanges() throws {
        reloadTheAppsRulesWhenTheTestEnds()
        let root = try makeCurrentDataDirectory("RulesFirstLaunch")
        let file = root.appendingPathComponent("substitutions.json")
        let service = TextSubstitutionService.shared

        service.loadRules()

        XCTAssertTrue(service.rulesStandInForMissingFile)
        XCTAssertEqual(service.rules.map(\.name), TextSubstitutionService.defaultRules.map(\.name))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: file.path),
            "the standard rules were written before any rule changed"
        )

        service.addRule(SubstitutionRule(name: "Galley", pattern: "galley", replacement: "galley", isRegex: false))

        XCTAssertFalse(service.rulesStandInForMissingFile)
        XCTAssertEqual(
            try JSONDecoder().decode([SubstitutionRule].self, from: Data(contentsOf: file)).map(\.name),
            TextSubstitutionService.defaultRules.map(\.name) + ["Galley"]
        )
    }

    /// The rules the sync service brings down after that first launch, from
    /// another Mac, are taken up as the app becomes active, in place of the
    /// standard rules, and the file stays exactly as it came, with no copy
    /// of this Mac's beside it.
    func testSubstitutionsThatArriveLaterAreTakenUpAsTheyCame() throws {
        reloadTheAppsRulesWhenTheTestEnds()
        let root = try makeCurrentDataDirectory("RulesArriveLater")
        let file = root.appendingPathComponent("substitutions.json")
        let service = TextSubstitutionService.shared
        service.loadRules()
        let theirs = try rulesData(named: ["Harbor", "Chart Room"])
        try theirs.write(to: file)

        // As the app becomes active.
        service.readFileThatArrived()

        XCTAssertFalse(service.rulesStandInForMissingFile)
        XCTAssertEqual(service.rules.map(\.name), ["Harbor", "Chart Room"])
        XCTAssertEqual(try Data(contentsOf: file), theirs, "the rules that arrived were written over")
        XCTAssertEqual(try rulesFiles(in: root), ["substitutions.json"], "another copy of the rules was made")
    }

    /// A rule changed before the app has taken up rules that arrived
    /// meanwhile takes them up instead of writing the standard rules over
    /// them: the file holds the user's own rules, from another Mac, and stays
    /// exactly as it came, while the change made to the stand-ins is dropped,
    /// as one made while the library was unavailable is.
    func testARuleChangedAfterTheRulesArriveWritesNothingOverThem() throws {
        reloadTheAppsRulesWhenTheTestEnds()
        let root = try makeCurrentDataDirectory("RulesArriveBeforeAChange")
        let file = root.appendingPathComponent("substitutions.json")
        let service = TextSubstitutionService.shared
        service.loadRules()
        let theirs = try rulesData(named: ["Harbor"])
        try theirs.write(to: file)

        service.addRule(SubstitutionRule(name: "Galley", pattern: "galley", replacement: "galley", isRegex: false))

        XCTAssertFalse(service.rulesStandInForMissingFile)
        XCTAssertEqual(service.rules.map(\.name), ["Harbor"])
        XCTAssertEqual(try Data(contentsOf: file), theirs, "the standard rules were written over the rules that arrived")
        XCTAssertEqual(try rulesFiles(in: root), ["substitutions.json"], "another copy of the rules was made")
    }

    // MARK: - reading-checkpoints.json

    /// A checkpoint journal cut short names no book, and the startup repair
    /// changes no row because of it.
    func testAHalfWrittenCheckpointJournalChangesNothing() throws {
        _ = try makeCurrentDataDirectory("JournalHalf")
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
        _ = try makeCurrentDataDirectory("JournalAhead")
        let here = try makePackagedBook("Moby-Dick")
        let notHere = bookNotHereYet("Emma")
        let journal = ["books": [notHere.id.uuidString, here.id.uuidString, UUID().uuidString]]
        try JSONSerialization.data(withJSONObject: journal).write(to: TextMouthPaths.readingCheckpointsFile)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [here, notHere])

        model.migrateOldBooksIfNeeded()

        XCTAssertEqual(model.library.books, [here, notHere])
    }

    // MARK: - Small Files That Arrive Apart (Risk 5)

    // A sync service can bring a library's small files down one at a time
    // (risk 5 of LOCAL-FIRST-LIBRARY-RESEARCH-2026-11-13.md). In a cloud
    // location a file not here beside the others is waited for, or stood in
    // for, and never made afresh in its place; in a folder elsewhere it is
    // what it always was.

    /// The identity marker without library.json beside it, in a cloud
    /// location, is waited for as a file only in the cloud is, not opened
    /// as a library with no index; nothing is made. Elsewhere, or once the
    /// listener has chosen to open without the index, it opens as before.
    func testAnIdentityWithoutItsIndexInTheCloudIsWaitedFor() throws {
        let root = try makeSandboxDirectory("IdentityWithoutIndex")
        let identity = try LibraryIdentity.adopt(in: root).identity
        let provider = FakeCloudItemStatusProvider()
        provider.setLocation(.cloud(.googleDrive), of: root)
        let check = DataDirectoryCheck(root: root, isDefaultLocation: false, expectedIdentity: identity.id, bookmark: nil)

        let (outcome, pending) = check.runNamingPending(itemStatus: provider)

        XCTAssertEqual(outcome, .unavailable(.notDownloaded(.googleDrive, folder: root.path)))
        XCTAssertEqual(pending.map(\.lastPathComponent), ["library.json"])
        XCTAssertEqual(DataDirectoryCheck.awaitedFile(among: pending, in: root), .index)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path))
        XCTAssertEqual(check.run(itemStatus: FakeCloudItemStatusProvider()), .available(identity, relocatedTo: nil),
                       "a folder elsewhere opens without its index, as before")
        var chosen = check
        chosen.opensWithoutItsIndex = true
        XCTAssertEqual(chosen.run(itemStatus: provider), .available(identity, relocatedTo: nil))
    }

    /// library.json without its identity marker, in a cloud location, is
    /// waited for and never given a new identity, whether or not this Mac
    /// knows the library's identity: a Mac given the folder knows none while
    /// the file is still coming. A folder elsewhere opens it as before, and
    /// so does the library once the listener chose to open it without the
    /// file.
    func testAnIndexWithoutItsIdentityInTheCloudIsWaitedFor() throws {
        let root = try makeSandboxDirectory("IndexWithoutIdentity")
        try Data("{\"books\":[]}".utf8).write(to: root.appendingPathComponent("library.json"))
        let provider = FakeCloudItemStatusProvider()
        provider.setLocation(.cloud(.iCloudDrive), of: root)
        for expected in [UUID(), nil] {
            let check = DataDirectoryCheck(root: root, isDefaultLocation: false, expectedIdentity: expected, bookmark: nil)

            let (outcome, pending) = check.runNamingPending(itemStatus: provider)

            XCTAssertEqual(outcome, .unavailable(.notDownloaded(.iCloudDrive, folder: root.path)), "expecting \(String(describing: expected))")
            XCTAssertEqual(pending.map(\.lastPathComponent), ["library-identity.json"])
            XCTAssertNil(try LibraryIdentity.read(in: root), "the library was given an identity")
            XCTAssertEqual(check.run(itemStatus: FakeCloudItemStatusProvider()), .available(nil, relocatedTo: nil), "a folder elsewhere waited")
        }
        // The file awaited is the one to restore where this Mac knows the
        // identity, and the one to give anew where it knows none.
        let pending = [LibraryIdentity.markerURL(in: root)]
        XCTAssertEqual(DataDirectoryCheck.awaitedFile(among: pending, in: root), .identity)
        XCTAssertEqual(DataDirectoryCheck.awaitedFile(among: pending, in: root, expectingIdentity: false), .identityNotKnown)
        // The listener's choice to open without the identity file lets it open.
        var chosen = DataDirectoryCheck(root: root, isDefaultLocation: false, expectedIdentity: nil, bookmark: nil)
        chosen.opensWithoutItsIdentity = true
        XCTAssertEqual(chosen.run(itemStatus: provider), .available(nil, relocatedTo: nil))
    }

    /// Only a file missing beside the other is the one awaited: not an index
    /// only in the cloud, nor a file missing with the other missing too, nor
    /// more files than one.
    func testOnlyAFileMissingBesideTheOtherIsAwaited() throws {
        let root = try makeSandboxDirectory("AwaitedFile")
        let index = root.appendingPathComponent("library.json")
        let marker = LibraryIdentity.markerURL(in: root)

        XCTAssertNil(DataDirectoryCheck.awaitedFile(among: [index], in: root), "neither file is here")
        _ = try LibraryIdentity.adopt(in: root)
        XCTAssertEqual(DataDirectoryCheck.awaitedFile(among: [index], in: root), .index)
        XCTAssertNil(DataDirectoryCheck.awaitedFile(among: [index, marker], in: root), "two files pending")
        try Data("{}".utf8).write(to: index)
        XCTAssertNil(DataDirectoryCheck.awaitedFile(among: [index], in: root), "the index is here, only in the cloud")
    }

    /// In a cloud location, statistics not on this Mac at all may not have
    /// arrived yet: fresh ones stand in, a look as the file may have come
    /// keeps waiting and writes nothing, and once the other Mac's file is
    /// here the next save adds this session's listening to it.
    func testStatisticsNotHereYetInTheCloudAreTakenUpAndNeverWrittenOver() throws {
        let folder = try makeSandboxDirectory("StatsNotHereYet")
        let file = folder.appendingPathComponent("reading_stats.json")
        let provider = FakeCloudItemStatusProvider()
        provider.setLocation(.cloud(.googleDrive), of: folder)
        installItemStatus(provider)
        let service = ReadingStatsService(fileURL: file)
        addTeardownBlock { @MainActor in service.shutdown() }

        XCTAssertTrue(service.statsAwaitFileInCloud)
        service.fileMayHaveArrived()
        XCTAssertTrue(service.statsAwaitFileInCloud, "a look that found nothing ended the wait")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the stand-ins were written in the file's place")

        try statsData(totalSeconds: 9_000).write(to: file)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        service.startSession(bookID: UUID(), at: start)
        service.endSession(at: start.addingTimeInterval(120))
        ReadingStatsService.waitForQueuedSaves()

        XCTAssertFalse(service.statsAwaitFileInCloud)
        XCTAssertEqual(service.stats.totalListeningSeconds, 9_120)
        XCTAssertEqual(try decodedStats(at: file).totalListeningSeconds, 9_120)
    }

    /// Statistics that never come, as in a library new to the cloud, are
    /// saved once there is listening to keep.
    func testStatisticsThatNeverComeAreSavedOnceThereIsListening() throws {
        let folder = try makeSandboxDirectory("StatsNeverCome")
        let file = folder.appendingPathComponent("reading_stats.json")
        let provider = FakeCloudItemStatusProvider()
        provider.setLocation(.cloud(.dropbox), of: folder)
        installItemStatus(provider)
        let service = ReadingStatsService(fileURL: file)
        addTeardownBlock { @MainActor in service.shutdown() }
        let start = Date(timeIntervalSince1970: 1_790_000_000)

        service.startSession(bookID: UUID(), at: start)
        service.endSession(at: start.addingTimeInterval(120))
        ReadingStatsService.waitForQueuedSaves()

        XCTAssertFalse(service.statsAwaitFileInCloud)
        XCTAssertEqual(try decodedStats(at: file).totalListeningSeconds, 120)
    }

    /// One Mac, a folder elsewhere: statistics with no file start fresh,
    /// waiting for nothing, and are saved as before.
    func testStatisticsWithNoFileElsewhereStartFreshAsBefore() throws {
        let file = try makeSandboxDirectory("StatsLocal").appendingPathComponent("reading_stats.json")
        installItemStatus(FakeCloudItemStatusProvider())
        let service = ReadingStatsService(fileURL: file)
        addTeardownBlock { @MainActor in service.shutdown() }
        let start = Date(timeIntervalSince1970: 1_790_000_000)

        XCTAssertFalse(service.statsAwaitFileInCloud)
        service.startSession(bookID: UUID(), at: start)
        service.endSession(at: start.addingTimeInterval(60))
        ReadingStatsService.waitForQueuedSaves()

        XCTAssertEqual(try decodedStats(at: file).totalListeningSeconds, 60)
    }

    /// In a cloud location, a config.json not on this Mac at all is not
    /// written from this Mac's settings by the launch's save; once it is
    /// here, the library's fetch hook merges it, the other Mac's settings
    /// standing, and nothing was written over its place meanwhile.
    func testSettingsNotHereYetInTheCloudAreNotWrittenAtLaunch() throws {
        let folder = try makeSandboxDirectory("ConfigNotHereYet")
        let file = folder.appendingPathComponent("config.json")
        let provider = FakeCloudItemStatusProvider()
        provider.setLocation(.cloud(.googleDrive), of: folder)
        installItemStatus(provider)
        let service = makeConfigService(at: file)

        service.saveToDisk(creatingAwaitedFile: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the launch wrote this Mac's settings in the file's place")

        var theirs = ConfigService.AppConfig()
        theirs.wordsPerMinute = 222
        let theirBytes = try ConfigService.fileData(for: theirs)
        try theirBytes.write(to: file)
        service.fileMayHaveArrived()

        XCTAssertEqual(service.config.wordsPerMinute, 222, "the other Mac's settings did not stand")
        XCTAssertEqual(try Data(contentsOf: file), theirBytes)
    }

    /// A setting changed while config.json is awaited is saved, making the
    /// file, as substitutions.json is made once a rule changes.
    func testASettingChangedWhileTheSettingsAreAwaitedIsSaved() throws {
        let folder = try makeSandboxDirectory("ConfigChangedWhileAwaited")
        let file = folder.appendingPathComponent("config.json")
        let provider = FakeCloudItemStatusProvider()
        provider.setLocation(.cloud(.googleDrive), of: folder)
        installItemStatus(provider)
        let service = makeConfigService(at: file)
        service.saveToDisk(creatingAwaitedFile: false)

        service.config.wordsPerMinute = 300
        service.saveToDisk()

        XCTAssertEqual(try ConfigService.decode(Data(contentsOf: file)).wordsPerMinute, 300)
    }

    /// A reader opening a book, a window restored at launch included, notes
    /// it as the last book opened, but never makes a config.json that has
    /// not arrived in a cloud location: the guard lasts past the first
    /// book. A setting changed afterwards, which a save merged with it, does
    /// write the file.
    func testOpeningABookNeverMakesTheSettingsFileThatHasNotArrived() async throws {
        let folder = try makeSandboxDirectory("ConfigOpenBook")
        let file = folder.appendingPathComponent("config.json")
        let provider = FakeCloudItemStatusProvider()
        provider.setLocation(.cloud(.googleDrive), of: folder)
        installItemStatus(provider)
        let service = makeConfigService(fileURL: file, fileOperations: ConfigService.FileOperations(
            write: { data, url in try data.write(to: url, options: .atomic) },
            openForEvents: { _ in -1 },
            close: { _ in }
        ), saveDelay: .milliseconds(20))
        service.saveToDisk(creatingAwaitedFile: false)
        let model = LibraryViewModel(initializeServices: false)

        model.registerOpenBook(UUID(), config: service)
        // Well past the save's delay.
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "opening a book wrote this Mac's settings in the file's place")

        // A changed setting's save, merged with the open's, makes the file.
        model.registerOpenBook(UUID(), config: service)
        service.config.wordsPerMinute = 310
        service.scheduleSave()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(try ConfigService.decode(Data(contentsOf: file)).wordsPerMinute, 310, "a changed setting was not written")
    }

    /// One Mac, a folder elsewhere: the launch's save writes a missing
    /// config.json from the settings, as before.
    func testSettingsWithNoFileElsewhereAreWrittenAtLaunchAsBefore() throws {
        let file = try makeSandboxDirectory("ConfigLocal").appendingPathComponent("config.json")
        installItemStatus(FakeCloudItemStatusProvider())
        let service = makeConfigService(at: file)
        service.config.wordsPerMinute = 260

        service.saveToDisk(creatingAwaitedFile: false)

        XCTAssertEqual(try ConfigService.decode(Data(contentsOf: file)).wordsPerMinute, 260)
    }

    // MARK: - Fixtures

    /// A settings service for `file`, writing as the app does and watching
    /// nothing.
    private func makeConfigService(at file: URL) -> ConfigService {
        makeConfigService(fileURL: file, fileOperations: ConfigService.FileOperations(
            write: { data, url in try data.write(to: url, options: .atomic) },
            openForEvents: { _ in -1 },
            close: { _ in }
        ))
    }

    /// A file's state as a sync service reports a file only in the cloud.
    private let onlyInTheCloud = CloudItemStatus(
        state: .notDownloaded,
        isUploaded: true,
        byteCount: 0,
        hasUnresolvedConflicts: false,
        downloadError: nil
    )

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

    /// The statistics in reading_stats.json at `file`.
    private func decodedStats(at file: URL) throws -> ReadingStats {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ReadingStats.self, from: Data(contentsOf: file))
    }

    /// Makes `provider` the app's file-level cloud service until the test
    /// ends, when the one in use now is put back.
    private func installItemStatus(_ provider: any CloudItemStatusProviding) {
        let previous = CloudServices.itemStatus
        CloudServices.itemStatus = provider
        addTeardownBlock { @MainActor in CloudServices.itemStatus = previous }
    }

    /// The names of the files in the data directory at `root` that hold
    /// substitution rules: substitutions.json, and any copy beside it.
    private func rulesFiles(in root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("substitutions") }
            .sorted()
    }

    /// substitutions.json's bytes for plain rules with the names given.
    private func rulesData(named names: [String]) throws -> Data {
        try JSONEncoder().encode(names.map {
            SubstitutionRule(name: $0, pattern: $0.lowercased(), replacement: $0, isRegex: false)
        })
    }

    /// Has the app's substitution service read its file through `reader`
    /// until the test ends, when it reads the app's way again.
    private func readTheAppsRules(through reader: CloudFileReader) {
        TextSubstitutionService.shared.readFile = { try reader.read($0) }
        addTeardownBlock { @MainActor in
            TextSubstitutionService.shared.readFile = SavedFile.readWithoutDownloading
        }
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

/// A flag a test's file operations read, set from the test.
@MainActor
private final class CloudFlag {
    /// Whether the file is only in the cloud.
    var value = true
}

/// Counts the writes a test's file operations make.
@MainActor
private final class WriteCounter {
    /// How many writes were made.
    var count = 0
}

/// Reads a file as the app does, except that while `isInCloud` it refuses
/// as a read of a dataless file does with downloading off (`EDEADLK`): only
/// a sync service makes real dataless files.
private final class CloudFileReader {
    /// Whether the file's content is only in the cloud.
    var isInCloud = true

    /// The file's bytes, or the refusal while it is in the cloud.
    func read(_ url: URL) throws -> Data {
        if isInCloud {
            throw POSIXError(.EDEADLK)
        }
        return try Data(contentsOf: url)
    }
}

import Combine
import XCTest
@testable import TextMouth

/// Moving the data directory, as Change Location… does, while other storage
/// work is under way (TODO S04). Most tests hold a writer at a test seam
/// after it has chosen where it writes, start the move, let the writer go
/// on once the move says it waits for it, and look at where its work
/// landed.
///
/// Before TODO S04 the move did not wait. An import held this way published
/// its package in the old data directory after the move, a pending library
/// save wrote the old rows into the new library.json, and a text cache
/// rebuild wrote its content.md into the old package. Rebuild Directory,
/// which moves misplaced packages and adopts the ones the library does not
/// list, waits the same way.
@MainActor
final class StorageGenerationMoveTests: XCTestCase {

    // MARK: - Reproductions

    /// An import held after it has chosen its destination finishes before
    /// the move copies anything: its book is in the library, in the moved
    /// data directory, and the copy of its folder is exactly the folder it
    /// was copied from, with no staged package in it.
    func testImportHeldAfterChoosingItsDestinationLandsInTheMovedDataDirectory() async throws {
        let world = try makeIntegrationWorld("Storage Move Import")
        let model = world.library
        let source = try makeTextSource(named: "Fairway Buoy Log.txt")
        let destination = try makeDataDirectoryMoveDestination("ImportDuringMove")
        let oldFolder = Self.folder(world.folder.path, under: TextMouthPaths.root)
        let held = holdFirstImport(of: model, at: .copying)
        model.importSingleFileAsync(from: source, toFolder: world.folder.path)
        await fulfillment(of: [held.reached], timeout: 10)

        var waits: [StorageWork?] = []
        let outcome = await model.moveDataDirectoryReturningOutcome(to: destination) { work in
            waits.append(work)
            // The import may go on once the move says it waits for it.
            if work == .importing { held.gate.signal() }
        }

        XCTAssertTrue(outcome.succeeded, outcome.failureMessage ?? "")
        XCTAssertEqual(waits, [.importing, nil])
        let book = try XCTUnwrap(
            model.library.books.first { $0.sourceFilePath == source.path },
            "The move did not wait for the import to add its book"
        )
        let movedFolder = Self.folder(world.folder.path, under: destination)
        var problems: [String] = []
        if !book.filePath.hasPrefix(destination.path + "/") {
            problems.append("the library row is not in the moved data directory")
        }
        if !FileManager.default.fileExists(atPath: movedFolder.appendingPathComponent(book.tmbDirectoryName).path) {
            problems.append("the moved data directory has no package for the book")
        }
        if Self.entries(of: oldFolder) != Self.entries(of: movedFolder) {
            problems.append(
                "the old folder holds \(Self.entries(of: oldFolder).sorted()), its copy \(Self.entries(of: movedFolder).sorted())"
            )
        }
        XCTAssertEqual(problems, [])
    }

    /// A library save pending when the move starts is made before the copy,
    /// so when the move hands the library its new rows nothing is left to
    /// write: the old library.json is not written again, and the new one
    /// names its books in the moved data directory.
    func testPendingLibrarySaveWrittenAsTheMovePublishes() async throws {
        let world = try makeIntegrationWorld("Storage Move Save")
        let model = world.library
        let book = try world.importBook(from: try makeTextSource(named: "Tide Table Notes.txt"))
        let destination = try makeDataDirectoryMoveDestination("SaveDuringMove")
        let oldRoot = TextMouthPaths.root
        let oldIndex = TextMouthPaths.libraryIndexFile
        let newIndex = destination.appendingPathComponent("library.json")
        LibraryPersistenceService.flushPendingSave()

        // The save waiting for its timer: the library with the book under
        // the old data directory.
        model.save()
        var observed: (oldIndexRewritten: Bool, newIndexNamesOldRoot: [String])?
        let subscription = model.$library.dropFirst().first().sink { _ in
            // The move has published the copy and is handing the library its
            // new rows: the pending save's timer fires now.
            let before = try? Data(contentsOf: oldIndex)
            LibraryPersistenceService.flushPendingSave()
            observed = (
                (try? Data(contentsOf: oldIndex)) != before,
                Self.titles(in: newIndex, under: oldRoot)
            )
        }
        defer { subscription.cancel() }

        let outcome = await model.moveDataDirectoryReturningOutcome(to: destination)

        XCTAssertTrue(outcome.succeeded, outcome.failureMessage ?? "")
        let afterPublication = try XCTUnwrap(observed, "The move never handed the library its new rows")
        XCTAssertFalse(afterPublication.oldIndexRewritten, "The old data directory's library.json was written after the move")
        XCTAssertEqual(afterPublication.newIndexNamesOldRoot, [], "The moved library.json names books in the old data directory")
        XCTAssertTrue(try XCTUnwrap(model.library.books.first { $0.id == book.id }).filePath.hasPrefix(destination.path + "/"))
    }

    /// A text cache rebuild held after it has chosen where its content.md
    /// goes finishes before the move copies anything: the moved package
    /// holds the rebuilt cache and the record that describes it, and
    /// nothing appears in the old package afterwards.
    func testTextCacheRebuiltDuringTheMoveIsWrittenInTheMovedDataDirectory() async throws {
        let world = try makeIntegrationWorld("Storage Move Cache")
        let model = world.library
        let book = try world.importBook(from: try makeTextSource(named: "Channel Soundings.txt"))
        let oldPackage = book.tmbDirectory
        try FileManager.default.removeItem(at: MarkdownCacheService.cacheURL(for: book))
        let destination = try makeDataDirectoryMoveDestination("CacheDuringMove")
        let held = holdExtraction(of: [book.id])
        model.extractMissingContentCaches()
        await fulfillment(of: [held.reached], timeout: 10)

        var waits: [StorageWork?] = []
        let outcome = await model.moveDataDirectoryReturningOutcome(to: destination) { work in
            waits.append(work)
            if work == .textExtraction { held.gate.signal() }
        }
        let oldPackageAfterMove = Self.entries(of: oldPackage)

        await waitFor(model.textExtraction.$isExtracting, "the rebuild finished") { !$0 }
        XCTAssertTrue(outcome.succeeded, outcome.failureMessage ?? "")
        XCTAssertEqual(waits, [.textExtraction, nil])
        let moved = try XCTUnwrap(model.library.books.first { $0.id == book.id })
        let movedPackage = Self.folder(world.folder.path, under: destination).appendingPathComponent(moved.tmbDirectoryName)
        var problems: [String] = []
        if !FileManager.default.fileExists(atPath: movedPackage.appendingPathComponent("content.md").path) {
            problems.append("the moved package has no content.md")
        }
        let appeared = Self.entries(of: oldPackage).subtracting(oldPackageAfterMove)
        if !appeared.isEmpty {
            problems.append("appeared in the old package after the move: \(appeared.sorted())")
        }
        if BookContentAnalysisService.completedTextCacheIndex(for: moved) == nil {
            problems.append("the moved package's record does not describe a cache it holds")
        }
        XCTAssertEqual(problems, [])
    }

    // MARK: - Work Held Until the Move Publishes

    /// An import queued behind the one under way is held until the move has
    /// published, while the import overlay says why it waits, and then
    /// chooses its destination in the moved data directory: nothing of it
    /// is ever written in the old one.
    func testImportQueuedBehindTheCurrentOneRunsInTheMovedDataDirectory() async throws {
        let world = try makeIntegrationWorld("Storage Move Held Import")
        let model = world.library
        let first = try makeTextSource(named: "Leading Lights.txt")
        let second = try makeTextSource(named: "Range Markers.txt")
        let destination = try makeDataDirectoryMoveDestination("HeldImportDuringMove")
        let oldFolder = Self.folder(world.folder.path, under: TextMouthPaths.root)
        let toldItWaits = expectation(description: "the overlay said the import waits for the move")
        let messages = model.importProgress.$state
            .filter { $0.message == LibraryViewModel.importWaitingForMoveMessage }
            .first()
            .sink { _ in toldItWaits.fulfill() }
        defer { messages.cancel() }
        let held = holdFirstImport(of: model, at: .copying)
        model.importSingleFileAsync(from: first, toFolder: world.folder.path)
        model.importSingleFileAsync(from: second, toFolder: world.folder.path)
        await fulfillment(of: [held.reached], timeout: 10)

        let outcome = await model.moveDataDirectoryReturningOutcome(to: destination) { work in
            switch work {
            case .importing:
                held.gate.signal()
            case nil:
                // Copy only once the second import is known to be held.
                await self.fulfillment(of: [toldItWaits], timeout: 10)
            default:
                break
            }
        }

        XCTAssertTrue(outcome.succeeded, outcome.failureMessage ?? "")
        await waitFor(model.$library, "the held import added its book") { library in
            library.books.contains { $0.sourceFilePath == second.path }
        }
        let book = try XCTUnwrap(model.library.books.first { $0.sourceFilePath == second.path })
        XCTAssertTrue(book.filePath.hasPrefix(destination.path + "/"), "The held import's book is not in the moved data directory")
        XCTAssertFalse(
            Self.entries(of: oldFolder).contains(book.tmbDirectoryName),
            "The held import published its package in the old data directory"
        )
        XCTAssertFalse(Self.entries(of: oldFolder).contains(where: ImportStaging.isStagedPackageName))
    }

    /// A text cache batch's next book is held until the move has published
    /// and then rebuilt in the moved package, never in the old one.
    func testExtractionQueuedBehindTheCurrentBookRunsInTheMovedDataDirectory() async throws {
        let world = try makeIntegrationWorld("Storage Move Held Extraction")
        let model = world.library
        let first = try world.importBook(from: try makeTextSource(named: "Soundings North.txt"))
        let second = try world.importBook(from: try makeTextSource(named: "Soundings South.txt"))
        for book in [first, second] {
            try FileManager.default.removeItem(at: MarkdownCacheService.cacheURL(for: book))
        }
        let secondOldPackage = second.tmbDirectory
        let destination = try makeDataDirectoryMoveDestination("HeldExtractionDuringMove")
        let held = holdExtraction(of: [first.id, second.id])
        model.extractMissingContentCaches()
        await fulfillment(of: [held.reached], timeout: 10)

        let outcome = await model.moveDataDirectoryReturningOutcome(to: destination) { work in
            if work == .textExtraction { held.gate.signal() }
        }

        await waitFor(model.textExtraction.$isExtracting, "the batch finished") { !$0 }
        XCTAssertTrue(outcome.succeeded, outcome.failureMessage ?? "")
        for book in [first, second] {
            let moved = try XCTUnwrap(model.library.books.first { $0.id == book.id })
            XCTAssertNotNil(
                BookContentAnalysisService.completedTextCacheIndex(for: moved),
                "\(book.title) has no rebuilt cache in the moved data directory"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: secondOldPackage.appendingPathComponent("content.md").path),
            "The held book's cache was written in the old package"
        )
    }

    /// A duplicate question asked before the move is answered about the
    /// moved copy: Keep Both adds the new copy with its file in the moved
    /// data directory.
    func testDuplicateQuestionAskedBeforeTheMoveKeepsTheMovedCopy() async throws {
        let world = try makeIntegrationWorld("Storage Move Question")
        let model = world.library
        let source = try makeTextSource(named: "Anchorage Notes.txt")
        _ = try world.importBook(from: source)
        model.importSingleFileAsync(from: source, toFolder: world.folder.path)
        await waitFor(model.$importDecisions, "the duplicate question was asked") { $0.current != nil }
        let question = try XCTUnwrap(model.importDecisions.current)
        let destination = try makeDataDirectoryMoveDestination("QuestionDuringMove")

        let outcome = await model.moveDataDirectoryReturningOutcome(to: destination)
        let answer = model.answerImportDecision(question.id, with: .keepBoth)

        XCTAssertTrue(outcome.succeeded, outcome.failureMessage ?? "")
        XCTAssertTrue(answer.succeeded, answer.failureMessage ?? "")
        let kept = try XCTUnwrap(model.library.books.first { $0.id == question.bookID })
        XCTAssertTrue(kept.filePath.hasPrefix(destination.path + "/"), "The kept copy is not in the moved data directory")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.filePath))
    }

    /// A duplicate question already asked when a move begins can't be
    /// answered while the library is copied. Replace Existing would delete
    /// the library's copy from the old data directory after the copy took
    /// it, so the moved library would keep a stray package of the replaced
    /// book, for adoption to bring back once no other copy of it is listed.
    /// The answer is refused, saying why, and the question stays asked; once
    /// the move ends, the same answer replaces the moved copy and leaves
    /// nothing of it behind. The new copy takes the replaced book's ID
    /// (ST04), with the new copy's package.
    func testReplaceAnsweredWhileTheLibraryIsCopiedWaitsForTheMoveToEnd() async throws {
        keepDeletionsOutOfTheTrash()
        useAfterImportingBehavior(.keepOriginal)
        let world = try makeIntegrationWorld("Storage Move Replace")
        let model = world.library
        let source = try makeTextSource(named: "Tide Table Errata.txt")
        let existing = try world.importBook(from: source)
        model.importSingleFileAsync(from: source, toFolder: world.folder.path)
        await waitFor(model.$importDecisions, "the duplicate question was asked") { $0.current != nil }
        let question = try XCTUnwrap(model.importDecisions.current)
        let questionID = question.id
        let destination = try makeDataDirectoryMoveDestination("ReplaceDuringMove")
        let duringCopy = AnswerDuringCopy()
        let observer = DataDirectoryCopyObserver(
            report: { progress in
                // Every item is copied and nothing is published yet: the
                // moment an answer would leave the most behind.
                guard progress.isComplete else { return }
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        guard duringCopy.outcome == nil else { return }
                        duringCopy.outcome = model.answerImportDecision(questionID, with: .replaceExisting)
                        duringCopy.questionStillAsked = model.importDecisions.current?.id == questionID
                    }
                }
            },
            isCancelled: { false }
        )

        let move = await DataDirectoryMigrator.$copyObserver.withValue(observer) {
            await model.moveDataDirectoryReturningOutcome(to: destination)
        }
        let answerAfterMove = model.answerImportDecision(questionID, with: .replaceExisting)

        XCTAssertTrue(move.succeeded, move.failureMessage ?? "")
        XCTAssertEqual(duringCopy.outcome, .failure(DataDirectoryMoveWording.importAnswerRefusal))
        XCTAssertEqual(duringCopy.questionStillAsked, true, "the refused answer settled the question")
        XCTAssertTrue(answerAfterMove.succeeded, answerAfterMove.failureMessage ?? "")
        XCTAssertNil(model.importDecisions.current)
        XCTAssertEqual(
            model.library.books.filter { $0.id == existing.id }.count, 1,
            "the book is not listed once, under its own ID"
        )
        let replacement = try XCTUnwrap(model.library.books.first { $0.id == existing.id })
        XCTAssertEqual(
            replacement.tmbDirectoryName,
            question.duplicate?.book.tmbDirectoryName,
            "Replace kept the library's copy"
        )
        XCTAssertTrue(replacement.filePath.hasPrefix(destination.path + "/"), "The new copy is not in the moved data directory")
        XCTAssertEqual(
            Self.entries(of: Self.folder(world.folder.path, under: destination)),
            [replacement.tmbDirectoryName],
            "The moved library folder holds more than the new copy's package"
        )
    }

    // MARK: - Removal and the Move

    /// A book removed, with its package deleted, while the move waits for
    /// an import is not in the moved data directory, and nothing there
    /// brings it back.
    func testBookRemovedWhileTheMoveWaitsIsNotInTheMovedDataDirectory() async throws {
        let world = try makeIntegrationWorld("Storage Move Removal")
        let model = world.library
        let removed = try world.importBook(from: try makeTextSource(named: "Old Moorings.txt"))
        let kept = try world.importBook(from: try makeTextSource(named: "New Moorings.txt"))
        let destination = try makeDataDirectoryMoveDestination("RemovalDuringMove")
        let held = holdFirstImport(of: model, at: .copying)
        model.importSingleFileAsync(from: try makeTextSource(named: "Buoyage.txt"), toFolder: world.folder.path)
        await fulfillment(of: [held.reached], timeout: 10)

        var removal: OperationOutcome?
        let outcome = await model.moveDataDirectoryReturningOutcome(to: destination) { work in
            guard work == .importing else { return }
            removal = model.removeBooksAndDeleteReturningOutcome([removed], deletePackage: Self.deletePermanently)
            held.gate.signal()
        }

        XCTAssertTrue(outcome.succeeded, outcome.failureMessage ?? "")
        XCTAssertEqual(removal?.succeeded, true, removal?.failureMessage ?? "the removal did not run")
        XCTAssertFalse(model.library.books.contains { $0.id == removed.id })
        XCTAssertTrue(try XCTUnwrap(model.library.books.first { $0.id == kept.id }).filePath.hasPrefix(destination.path + "/"))
        let movedFolder = Self.folder(world.folder.path, under: destination)
        XCTAssertFalse(Self.entries(of: movedFolder).contains(removed.tmbDirectoryName), "The removed package was copied")
        XCTAssertEqual(Self.adoptedPackages(of: model, in: Self.folder(world.folder.path, under: destination)), 0, "A removed book came back")
    }

    /// A book removed from the library only while the move waits keeps its
    /// package, which moves with its removal marker and stays out of the
    /// moved library.
    func testBookRemovedFromTheLibraryOnlyWhileTheMoveWaitsStaysOut() async throws {
        let world = try makeIntegrationWorld("Storage Move Retirement")
        let model = world.library
        let retired = try world.importBook(from: try makeTextSource(named: "Laid-Up Hulls.txt"))
        let destination = try makeDataDirectoryMoveDestination("RetirementDuringMove")
        let held = holdFirstImport(of: model, at: .copying)
        model.importSingleFileAsync(from: try makeTextSource(named: "Slipway Notes.txt"), toFolder: world.folder.path)
        await fulfillment(of: [held.reached], timeout: 10)

        let outcome = await model.moveDataDirectoryReturningOutcome(to: destination) { work in
            guard work == .importing else { return }
            model.removeBooksFromLibraryOnly([retired])
            held.gate.signal()
        }

        XCTAssertTrue(outcome.succeeded, outcome.failureMessage ?? "")
        XCTAssertFalse(model.library.books.contains { $0.id == retired.id })
        let movedPackage = Self.folder(world.folder.path, under: destination).appendingPathComponent(retired.tmbDirectoryName)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: TextMouthPaths.removedFromLibraryMarkerPath(in: movedPackage).path),
            "The package did not move with its removal marker"
        )
        XCTAssertEqual(Self.adoptedPackages(of: model, in: Self.folder(world.folder.path, under: destination)), 0, "A book removed from the library came back")
    }

    /// A removal confirmed after the move, of books the confirmation took
    /// before it, removes each book where the move put it: its moved
    /// package is deleted, and nothing brings the book back.
    func testRemovalConfirmedAfterTheMoveDeletesTheMovedPackage() async throws {
        let world = try makeIntegrationWorld("Storage Move Confirmation")
        let model = world.library
        let book = try world.importBook(from: try makeTextSource(named: "Wreck Chart.txt"))
        // What the removal confirmation holds while the user reads it.
        let confirmed = [book]
        let destination = try makeDataDirectoryMoveDestination("RemovalAfterMove")
        let outcome = await model.moveDataDirectoryReturningOutcome(to: destination)
        XCTAssertTrue(outcome.succeeded, outcome.failureMessage ?? "")

        let removal = model.removeBooksAndDeleteReturningOutcome(confirmed, deletePackage: Self.deletePermanently)

        XCTAssertTrue(removal.succeeded, removal.failureMessage ?? "")
        XCTAssertFalse(model.library.books.contains { $0.id == book.id })
        let movedPackage = Self.folder(world.folder.path, under: destination).appendingPathComponent(book.tmbDirectoryName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: movedPackage.path), "The moved package was not deleted")
        XCTAssertEqual(Self.adoptedPackages(of: model, in: Self.folder(world.folder.path, under: destination)), 0, "The removed book came back")
    }

    // MARK: - Rebuild Directory

    /// Rebuild Directory waits, as a move does, for an import that has
    /// published its package but not yet added its book to the library,
    /// before it adopts the packages the library does not list: the import
    /// adds its book first, so its package is never adopted as an orphan as
    /// well, and the library lists the book once. (Before, the rebuild ran at
    /// once on the main actor and adopted the package, and the import then
    /// found its book already in the library.)
    func testRebuildWaitsForAnImportThatHasNotAddedItsBook() async throws {
        let world = try makeIntegrationWorld("Storage Rebuild Import")
        let model = world.library
        // The import's package, published in the library folder, whose book
        // is not in the library yet.
        let book = try FileImportService.importFileWithReport(
            from: try makeTextSource(named: "Harbor Pilot Notes.txt"),
            toFolder: world.folder.path
        ).book
        let adding = AddingBook()
        let gate = DispatchSemaphore(value: 0)
        addTeardownBlock { gate.signal() }
        let held = HeldWriter(reached: expectation(description: "the import was under way"), gate: gate)
        // The rest of the import: storage work on a background thread that
        // adds its book on the main queue, as the library's imports do.
        DispatchQueue.global().async {
            StorageBoundary.shared.perform(.importing) { _ in
                held.reached.fulfill()
                held.gate.wait()
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        adding.foundAlreadyListed = model.library.books.contains { $0.id == book.id }
                        model.library.addBook(book)
                    }
                }
            }
        }
        await fulfillment(of: [held.reached], timeout: 10)

        var waits: [StorageWork?] = []
        let outcome = await model.rebuildDirectoryReturningOutcome { work in
            waits.append(work)
            // The import may go on once the rebuild says it waits for it.
            if work == .importing { held.gate.signal() }
        }

        XCTAssertTrue(outcome.succeeded, outcome.failureMessage ?? "")
        XCTAssertEqual(waits, [.importing, nil])
        XCTAssertEqual(
            adding.foundAlreadyListed,
            false,
            "the rebuild adopted the import's package before the import added its book"
        )
        XCTAssertEqual(model.library.books.filter { $0.id == book.id }.count, 1)
    }

    // MARK: - Fixtures

    /// Deletes a book's package as Remove & Delete does, after the same
    /// checks, but permanently: no test reaches the user's Trash.
    private static let deletePermanently: (Book) throws -> Void = { book in
        let package = try FileImportService.managedPackageURLForDeletion(book)
        try FileManager.default.removeItem(at: package)
    }

    /// How many packages in `folder`, a library folder of the test's own,
    /// orphan adoption would bring back into `model`'s library, as a launch
    /// or Rebuild Directory adopts them.
    private static func adoptedPackages(of model: LibraryViewModel, in folder: URL) -> Int {
        var library = model.library
        return FileImportService.adoptOrphanedTMBPackages(library: &library, libraryDirectory: folder)
    }

    /// A plain-text book file, `name`, in a scratch folder of the test's
    /// own. Its text begins with its name, so no two are copies of one book.
    private func makeTextSource(named name: String) throws -> URL {
        let file = try makeSandboxDirectory("StorageMoveSource").appendingPathComponent(name)
        try Data("\(name)\n\nThe pilot boards at the fairway buoy.\n\nSlack water comes an hour after high tide.\n".utf8)
            .write(to: file)
        return file
    }

    /// Waits until `publisher` publishes a value that satisfies `condition`,
    /// its current value included, and fails the test, described by
    /// `description`, after `timeout` seconds. The main actor runs
    /// meanwhile, as imports and text cache batches need it to: spinning
    /// the run loop from an async test would hold it.
    private func waitFor<Value>(
        _ publisher: Published<Value>.Publisher,
        _ description: String,
        timeout: TimeInterval = 20,
        until condition: @escaping (Value) -> Bool
    ) async {
        let met = expectation(description: description)
        let subscription = publisher.first(where: condition).sink { _ in met.fulfill() }
        await fulfillment(of: [met], timeout: timeout)
        subscription.cancel()
    }

    /// A writer held at a test seam: `reached` is fulfilled once it gets
    /// there, and it goes on once `gate` is signaled.
    private struct HeldWriter {
        let reached: XCTestExpectation
        let gate: DispatchSemaphore
    }

    /// Holds the first import `model` queues at `step` until the returned
    /// gate opens; later imports pass. The gate opens, and the seam is
    /// removed, when the test ends.
    private func holdFirstImport(of model: LibraryViewModel, at step: ImportStep) -> HeldWriter {
        let held = HeldWriter(reached: expectation(description: "the import reached \(step)"), gate: DispatchSemaphore(value: 0))
        let first = FirstTime()
        let queue = model.importOperationQueue
        queue.stepObserver = { reached, _ in
            guard reached == step, first.claim() else { return }
            held.reached.fulfill()
            held.gate.wait()
        }
        addTeardownBlock {
            queue.stepObserver = nil
            held.gate.signal()
        }
        return held
    }

    /// Holds the first cache generation of any of `bookIDs` after it has
    /// chosen where its content.md goes, until the returned gate opens;
    /// later ones pass. The gate opens, and the seam is removed, when the
    /// test ends.
    private func holdExtraction(of bookIDs: Set<UUID>) -> HeldWriter {
        let held = HeldWriter(reached: expectation(description: "the rebuild chose its cache's place"), gate: DispatchSemaphore(value: 0))
        let first = FirstTime()
        MarkdownCacheService.extractionObserver = { book in
            guard bookIDs.contains(book.id), first.claim() else { return }
            held.reached.fulfill()
            held.gate.wait()
        }
        addTeardownBlock {
            MarkdownCacheService.extractionObserver = nil
            held.gate.signal()
        }
        return held
    }

    /// The library folder `path` inside the data directory at `root`.
    private static func folder(_ path: String, under root: URL) -> URL {
        root.appendingPathComponent("Library", isDirectory: true).appendingPathComponent(path, isDirectory: true)
    }

    /// Every name in `directory`, hidden ones included; none when it is missing.
    private static func entries(of directory: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    /// The titles of the books the library index at `index` places inside
    /// the data directory at `root`; none when the index cannot be read.
    private static func titles(in index: URL, under root: URL) -> [String] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: index),
              let library = try? decoder.decode(Library.self, from: data) else { return [] }
        return library.books.filter { $0.filePath.hasPrefix(root.path + "/") }.map(\.title)
    }
}

/// What an import a test stands in for found as it added its book to the
/// library, on the main actor.
@MainActor
private final class AddingBook {
    /// Whether the library already listed the book; nil until it was added.
    var foundAlreadyListed: Bool?
}

/// What answering an import question during a move's copy gave, on the
/// main actor.
@MainActor
private final class AnswerDuringCopy {
    /// What the answer did; nil until the copy was complete.
    var outcome: OperationOutcome?
    /// Whether the question was still being asked after the answer.
    var questionStillAsked: Bool?
}

/// Answers true exactly once, to whichever thread asks first.
private final class FirstTime: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// Whether this is the first claim.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

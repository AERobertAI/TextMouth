import os
import XCTest
@testable import TextMouth

/// How an export puts each file into the folder chosen (FR31, `BookExportDelivery`):
/// the iPhone's coordinated copy never replaces anything, copies a folder
/// whole, numbers a taken name, and leaves no scratch folder behind, however
/// the export ends. One file serves both apps' test bundles: the Mac's host
/// tests the iPhone's copy too, and the iPhone runs it where it is used.
///
/// Every file lives in a sandbox folder of the test's own; nothing reaches the
/// user's files.
final class BookExportDeliveryTests: XCTestCase {

    // MARK: - The copy itself

    /// A file is copied to a free name whole, and its source stays where it
    /// was for the export to remove with its scratch folder.
    func testTheCoordinatedCopyDeliversAFileToAFreeName() throws {
        let folder = try makeSandboxDirectory("Delivery Copy")
        let source = folder.appendingPathComponent("source.txt")
        let target = folder.appendingPathComponent("target.txt")
        try Data("new".utf8).write(to: source)

        try BookExportDelivery.coordinatedCopy.deliver(source, target, BookExportCancellation())

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "new", "the copy leaves the scratch file to the export")
    }

    /// The copy refuses a name that is taken, as the Mac's move does: it
    /// throws `fileWriteFileExists`, and the file there keeps its bytes.
    func testTheCoordinatedCopyNeverReplacesAFile() throws {
        let folder = try makeSandboxDirectory("Delivery Refuse")
        let source = folder.appendingPathComponent("source.txt")
        let target = folder.appendingPathComponent("target.txt")
        try Data("new".utf8).write(to: source)
        try Data("Someone else's".utf8).write(to: target)

        XCTAssertThrowsError(try BookExportDelivery.coordinatedCopy.deliver(source, target, BookExportCancellation())) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteFileExists)
        }

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "Someone else's")
    }

    /// A folder, such as an RTFD package or an audiobook's tracks, is copied
    /// with everything in it, nested folders included.
    func testTheCoordinatedCopyCopiesAFolderWhole() throws {
        let folder = try makeSandboxDirectory("Delivery Folder")
        let package = folder.appendingPathComponent("package.rtfd", isDirectory: true)
        let nested = package.appendingPathComponent("Images", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: package.appendingPathComponent("TXT.rtf"))
        try Data("deeper".utf8).write(to: nested.appendingPathComponent("cover.txt"))
        let copy = folder.appendingPathComponent("copy.rtfd", isDirectory: true)

        try BookExportDelivery.coordinatedCopy.deliver(package, copy, BookExportCancellation())

        XCTAssertEqual(try String(contentsOf: copy.appendingPathComponent("TXT.rtf"), encoding: .utf8), "inside")
        XCTAssertEqual(try String(contentsOf: copy.appendingPathComponent("Images/cover.txt"), encoding: .utf8), "deeper")
    }

    /// The iPhone's scratch folder is inside the app's temporary folder, new
    /// and empty each time, and asks the system for no folder near the target.
    func testTheCoordinatedCopyMakesItsScratchFolderInTheTemporaryFolder() throws {
        let target = try makeSandboxDirectory("Delivery Scratch").appendingPathComponent("target.txt")

        let first = try BookExportDelivery.coordinatedCopy.makeScratchFolder(target)
        let second = try BookExportDelivery.coordinatedCopy.makeScratchFolder(target)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.deletingLastPathComponent().standardizedFileURL, FileManager.default.temporaryDirectory.standardizedFileURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: first.path), [])
    }

    /// The copy makes the folder of its target, and the folders above it, under the coordinator, as the move makes them
    /// (a book's folder, a track folder): the target may be several folders down in a folder that holds none of them.
    func testTheCoordinatedCopyMakesTheFoldersOfItsTarget() throws {
        let folder = try makeSandboxDirectory("Delivery Folders")
        let source = folder.appendingPathComponent("source.txt")
        try Data("new".utf8).write(to: source)
        let target = folder.appendingPathComponent("Book/Tracks/01.txt")

        try BookExportDelivery.coordinatedCopy.deliver(source, target, BookExportCancellation())

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new")
    }

    /// A Stop already pressed delivers nothing and makes no folder: the copy throws `CancellationError` first. (A Stop
    /// that comes while a coordination waits on a file provider cancels it through the export's cancellation; a test
    /// has no provider to hold one.)
    func testAStoppedCopyDeliversNothingAndMakesNoFolder() throws {
        let folder = try makeSandboxDirectory("Delivery Stopped")
        let source = folder.appendingPathComponent("source.txt")
        try Data("new".utf8).write(to: source)
        let target = folder.appendingPathComponent("Book/01.txt")
        let stop = BookExportCancellation()
        stop.cancel()

        XCTAssertThrowsError(try BookExportDelivery.coordinatedCopy.deliver(source, target, stop)) { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Book").path))
    }

    /// A Stop that comes between the copy's two coordinations, after the folder is made and before the file is, lands no
    /// file: the copy throws `CancellationError` and the target is not made.
    func testAStopBetweenTheTwoCoordinationsLandsNoFile() throws {
        let folder = try makeSandboxDirectory("Delivery Stopped Between")
        let source = folder.appendingPathComponent("source.txt")
        try Data("new".utf8).write(to: source)
        let target = folder.appendingPathComponent("Book/01.txt")
        let stop = BookExportCancellation()

        XCTAssertThrowsError(
            try BookExportDelivery.copyCoordinated(source, to: target, cancellation: stop, betweenCoordinations: { stop.cancel() })
        ) { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "A file landed after Stop")
    }

    // MARK: - The scratch folders an earlier run left

    /// The sweep removes the scratch folders last changed more than a day before now, and leaves a newer one, a folder
    /// of another name, and a file of the name.
    func testTheSweepRemovesOnlyTheStaleScratchFolders() throws {
        let temporary = try makeSandboxDirectory("Delivery Sweep")
        let prefix = BookExportDelivery.scratchFolderPrefix
        let now = Date()
        func make(_ name: String, changed: Date, isFolder: Bool = true) throws -> URL {
            let url = temporary.appendingPathComponent(name, isDirectory: isFolder)
            if isFolder {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try Data("x".utf8).write(to: url)
            }
            try FileManager.default.setAttributes([.modificationDate: changed], ofItemAtPath: url.path)
            return url
        }
        let stale = try make("\(prefix)stale", changed: now.addingTimeInterval(-2 * 24 * 60 * 60))
        let fresh = try make("\(prefix)fresh", changed: now.addingTimeInterval(-60 * 60))
        let other = try make("Another folder", changed: now.addingTimeInterval(-9 * 24 * 60 * 60))
        let file = try make("\(prefix)file", changed: now.addingTimeInterval(-9 * 24 * 60 * 60), isFolder: false)

        BookExportDelivery.removeStaleScratchFolders(in: temporary, now: now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "a stale scratch folder was left")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "a scratch folder of the last hour was removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "a folder of another name was removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "a file was removed")
    }

    /// An export starts by sweeping, through its delivery, and the Mac's delivery has nothing to sweep.
    func testAnExportSweepsThroughItsDeliveryAndTheMacsHasNothingToSweep() throws {
        let sandbox = try makeSandboxDirectory("Delivery Sweep Asked")
        let asked = ScratchRecord()
        let sweeping = BookExportDelivery(
            makeScratchFolder: BookExportDelivery.coordinatedCopy.makeScratchFolder,
            deliver: BookExportDelivery.coordinatedCopy.deliver,
            removeStaleScratchFolders: { asked.note(sandbox) }
        )

        sweeping.removeStaleScratchFolders()
        BookExportDelivery.moving.removeStaleScratchFolders()

        XCTAssertEqual(asked.folders, [sandbox], "the delivery was not asked to sweep, or the Mac's was")
    }

    // MARK: - An export through each delivery

    /// An export through the coordinated copy writes the book's file under the
    /// name the plan chose: a name that is taken is followed by a number, and
    /// the file that was there is untouched.
    func testAnExportThroughTheCopyNumbersATakenNameAndKeepsTheFileThere() throws {
        let sandbox = try makeSandboxDirectory("Delivery Export")
        let destination = sandbox.appendingPathComponent("Chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("Someone else's".utf8).write(to: destination.appendingPathComponent("Harbour.txt"))
        let offer = try makeOffer(named: "Harbour.txt", bytes: "the book", in: sandbox)

        let outcome = BookExportService.export(
            [offer], kinds: [.originalFile], to: destination, delivery: .coordinatedCopy
        )

        XCTAssertEqual(outcome.exported.map(\.lastPathComponent), ["Harbour 2.txt"])
        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Harbour.txt"), encoding: .utf8), "Someone else's")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Harbour 2.txt"), encoding: .utf8), "the book")
    }

    /// Whatever way an export ends, no scratch folder is left: after it
    /// delivered a file, after Stop was pressed before the file was put in
    /// place, and after the delivery failed.
    func testNoScratchFolderIsLeftHoweverTheExportEnds() throws {
        let sandbox = try makeSandboxDirectory("Delivery Scratch Left")
        let offer = try makeOffer(named: "Harbour.txt", bytes: "the book", in: sandbox)

        // Delivered.
        let delivered = ScratchRecord()
        let deliveredFolder = sandbox.appendingPathComponent("Delivered", isDirectory: true)
        let done = BookExportService.export(
            [offer], kinds: [.originalFile], to: deliveredFolder, delivery: delivery(recording: delivered)
        )
        XCTAssertEqual(done.exported.count, 1)

        // Stopped after the file was made and before it was put in place.
        let stopped = ScratchRecord()
        let token = BookExportCancellation()
        let stoppedFolder = sandbox.appendingPathComponent("Stopped", isDirectory: true)
        let stoppedOutcome = BookExportService.export(
            [offer],
            kinds: [.originalFile],
            to: stoppedFolder,
            cancellation: token,
            delivery: delivery(recording: stopped, whenMade: { token.cancel() })
        )
        XCTAssertTrue(stoppedOutcome.wasCancelled)
        XCTAssertEqual(stoppedOutcome.exported, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stoppedFolder.path), "Stop left a folder in the destination")

        // The delivery failed: the file is a failure, named, and nothing is left.
        let failed = ScratchRecord()
        let failedFolder = sandbox.appendingPathComponent("Failed", isDirectory: true)
        let failedOutcome = BookExportService.export(
            [offer],
            kinds: [.originalFile],
            to: failedFolder,
            delivery: delivery(recording: failed, delivering: { _, _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        )
        XCTAssertEqual(failedOutcome.exported, [])
        XCTAssertEqual(failedOutcome.failures.map(\.name), ["Harbour.txt"])

        for record in [delivered, stopped, failed] {
            XCTAssertEqual(record.folders.count, 1, "each file is made in one scratch folder")
            for folder in record.folders {
                XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "a scratch folder was left behind")
            }
        }
    }

    /// A writer that fails leaves no scratch folder and nothing in the folder chosen, and a book the memory guard refuses
    /// never makes a scratch folder at all; each is a failure named by its file, and the other books still export.
    func testAWritersErrorAndAMemoryRefusalLeaveNothingBehind() throws {
        let sandbox = try makeSandboxDirectory("Delivery Failures")
        let offer = try makeConvertedOffer(in: sandbox)
        let failing = BookExportConversion.text(TextExportConversion(FailingWriter(), options: NoTextExportOptions()))

        let afterError = ScratchRecord()
        let errorFolder = sandbox.appendingPathComponent("Error", isDirectory: true)
        let errored = BookExportService.export(
            [offer], kinds: [.markdown], conversions: [.markdown: failing], to: errorFolder, delivery: delivery(recording: afterError)
        )
        XCTAssertEqual(errored.exported, [])
        XCTAssertEqual(errored.failures.map(\.reason), ["The writer cannot write this book."])
        XCTAssertEqual(afterError.folders.count, 1, "the writer's file was made in one scratch folder")
        for folder in afterError.folders {
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "the writer's scratch folder was left")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: errorFolder.path), "the writer's error left a folder in the destination")

        let afterRefusal = ScratchRecord()
        let refusalFolder = sandbox.appendingPathComponent("Refusal", isDirectory: true)
        let refused = BookExportService.export(
            [offer], kinds: [.markdown], conversions: [.markdown: .markdown], to: refusalFolder,
            delivery: delivery(recording: afterRefusal),
            memoryGuard: { _, _ in throw TextExportError("No room.") }
        )
        XCTAssertEqual(refused.failures.map(\.reason), ["No room."])
        XCTAssertEqual(afterRefusal.folders, [], "a refused book made a scratch folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: refusalFolder.path), "the refusal left a folder in the destination")
    }

    /// The Mac's way still moves: through `.moving` the scratch file is gone
    /// from where it was made, and the file is in the folder chosen.
    func testTheMovingDeliveryStillMovesTheFileIn() throws {
        let sandbox = try makeSandboxDirectory("Delivery Moving")
        let destination = sandbox.appendingPathComponent("Chosen", isDirectory: true)
        let offer = try makeOffer(named: "Harbour.txt", bytes: "the book", in: sandbox)

        let outcome = BookExportService.export([offer], kinds: [.originalFile], to: destination, delivery: .moving)

        XCTAssertEqual(outcome.exported.map(\.lastPathComponent), ["Harbour.txt"])
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Harbour.txt"), encoding: .utf8), "the book")
    }

    // MARK: - Helpers

    /// The scratch folders an export asked a delivery for, kept in a lock
    /// since the export runs the delivery's closures off the test's thread.
    private final class ScratchRecord: Sendable {
        private let made = OSAllocatedUnfairLock<[URL]>(initialState: [])

        /// The folders made so far.
        var folders: [URL] { made.withLock { $0 } }

        /// Notes a folder made.
        func note(_ folder: URL) { made.withLock { $0.append(folder) } }
    }

    /// The coordinated copy, noting each scratch folder it makes in `record`,
    /// running `whenMade` once the folder exists, and, when `delivering` is
    /// given, delivering through that in place of the copy.
    private func delivery(
        recording record: ScratchRecord,
        whenMade: @escaping @Sendable () -> Void = {},
        delivering: (@Sendable (URL, URL, BookExportCancellation) throws -> Void)? = nil
    ) -> BookExportDelivery {
        BookExportDelivery(
            makeScratchFolder: { target in
                let folder = try BookExportDelivery.coordinatedCopy.makeScratchFolder(target)
                record.note(folder)
                whenMade()
                return folder
            },
            deliver: delivering ?? BookExportDelivery.coordinatedCopy.deliver
        )
    }

    /// A writer whose every book fails, with a sentence of its own.
    private struct FailingWriter: TextExportWriter {
        let id = "failing"
        let name = "Failing"
        let hint = "Fails."
        let fileExtension = "fail"

        func write(_ document: ExportDocument, options: NoTextExportOptions, to url: URL, cancellation: BookExportCancellation) throws {
            throw TextExportError("The writer cannot write this book.")
        }
    }

    /// An offer, made by hand, of a book's Markdown, which a conversion converts.
    private func makeConvertedOffer(in folder: URL) throws -> BookExportOffer {
        let cache = folder.appendingPathComponent("Converted \(UUID().uuidString).md")
        try Data("# Harbour\n\nThe pilot boat ties up at the slip.\n".utf8).write(to: cache)
        let book = Book(title: "Harbour", format: .markdown, filePath: cache.path, md5Hash: "")
        let file = BookExportFile(
            source: .converted(from: cache, book: ExportBookDetails(book), by: .markdown),
            path: "Harbour - Text.md",
            byteCount: 50
        )
        let item = BookExportItem(kind: .markdown, folderName: nil, files: [file], fileInCloud: nil)
        return BookExportOffer(book: book, items: [item], isPackageInCloud: false)
    }

    /// An offer, made by hand, of one book's own file, named `name` and
    /// holding `bytes`, which is made in `folder`.
    private func makeOffer(named name: String, bytes: String, in folder: URL) throws -> BookExportOffer {
        let source = folder.appendingPathComponent("Source \(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: source)
        let book = Book(title: "Harbour", format: .markdown, filePath: source.path, md5Hash: "")
        let file = BookExportFile(source: .copy(source), path: name, byteCount: Int64(bytes.utf8.count))
        let item = BookExportItem(kind: .originalFile, folderName: nil, files: [file], fileInCloud: nil)
        return BookExportOffer(book: book, items: [item], isPackageInCloud: false)
    }
}

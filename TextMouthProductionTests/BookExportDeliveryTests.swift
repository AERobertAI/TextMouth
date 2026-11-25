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

        try BookExportDelivery.coordinatedCopy.deliver(source, target)

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

        XCTAssertThrowsError(try BookExportDelivery.coordinatedCopy.deliver(source, target)) { error in
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

        try BookExportDelivery.coordinatedCopy.deliver(package, copy)

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
            delivery: delivery(recording: failed, delivering: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
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
        delivering: (@Sendable (URL, URL) throws -> Void)? = nil
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

import XCTest
@testable import TextMouth

/// `PhoneImportCopyPlan`, `PhoneImportStallWatch`, `PhoneImportCopyItem`, and
/// `PhoneImportCopyRun`: the iPhone's coordinated copy, run here on the Mac
/// over real files in the test's sandbox, through a real `NSFileCoordinator`.
/// Nothing here is in iCloud, so no download is ever waited on, and every wait
/// has a limit.
@MainActor
final class PhoneImportCopyTests: XCTestCase {

    // MARK: - The Plan

    /// Each item's scratch folder is its own, under `tmp/PhoneImport`.
    func testScratchFoldersAreUnderPhoneImport() {
        let temporary = URL(fileURLWithPath: "/private/var/mobile/tmp", isDirectory: true)
        let id = UUID()
        XCTAssertEqual(PhoneImportCopyPlan.scratchRoot(in: temporary).path, "/private/var/mobile/tmp/PhoneImport")
        XCTAssertEqual(
            PhoneImportCopyPlan.scratchFolder(in: temporary, id: id).path,
            "/private/var/mobile/tmp/PhoneImport/\(id.uuidString)"
        )
    }

    /// Room means twice the size free; an unknown amount is given the
    /// benefit of the doubt; the doubling never overflows.
    func testRoomIsTwiceTheSize() {
        XCTAssertEqual(PhoneImportCopyPlan.neededBytes(forSourceBytes: 1_000), 2_000)
        XCTAssertTrue(PhoneImportCopyPlan.hasRoom(availableBytes: 2_000, sourceBytes: 1_000))
        XCTAssertFalse(PhoneImportCopyPlan.hasRoom(availableBytes: 1_999, sourceBytes: 1_000))
        XCTAssertTrue(PhoneImportCopyPlan.hasRoom(availableBytes: nil, sourceBytes: 1_000))
        XCTAssertEqual(PhoneImportCopyPlan.neededBytes(forSourceBytes: .max), .max)
    }

    /// An iCloud placeholder stands for its real file; no other name does.
    func testPlaceholderNames() {
        XCTAssertEqual(PhoneImportCopyPlan.realFileName(ofPlaceholder: ".Dune.epub.icloud"), "Dune.epub")
        XCTAssertNil(PhoneImportCopyPlan.realFileName(ofPlaceholder: "Dune.epub"))
        XCTAssertNil(PhoneImportCopyPlan.realFileName(ofPlaceholder: ".icloud"))
        XCTAssertNil(PhoneImportCopyPlan.realFileName(ofPlaceholder: ".hidden"))
    }

    /// A file inside a folder is told apart from the folder itself and from
    /// a folder whose name only begins the same.
    func testIsInside() {
        let inbox = URL(fileURLWithPath: "/tmp/Documents/Inbox", isDirectory: true)
        XCTAssertTrue(PhoneImportCopyPlan.isInside(URL(fileURLWithPath: "/tmp/Documents/Inbox/Dune.epub"), folder: inbox))
        XCTAssertFalse(PhoneImportCopyPlan.isInside(inbox, folder: inbox))
        XCTAssertFalse(PhoneImportCopyPlan.isInside(URL(fileURLWithPath: "/tmp/Documents/Inbox2/Dune.epub"), folder: inbox))
    }

    // MARK: - The Stall Limit

    /// No change in the marker for two minutes is a stall; any change starts
    /// the count again; the first marker is only the baseline.
    func testStallWatch() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var watch = PhoneImportStallWatch(startingAt: start)
        let still = PhoneImportStallWatch.Marker(downloadedFiles: 0, localBytes: 0)
        watch.note(still, at: start.addingTimeInterval(5))
        XCTAssertFalse(watch.hasStalled(at: start.addingTimeInterval(119)))
        XCTAssertTrue(watch.hasStalled(at: start.addingTimeInterval(120)))

        watch.note(PhoneImportStallWatch.Marker(downloadedFiles: 0, localBytes: 4_096), at: start.addingTimeInterval(100))
        XCTAssertFalse(watch.hasStalled(at: start.addingTimeInterval(219)))
        XCTAssertTrue(watch.hasStalled(at: start.addingTimeInterval(220)))
    }

    // MARK: - Planning an Item

    /// A file is one item of one file, named as it is, with its size.
    func testPlanningAFile() throws {
        let folder = try makeSandboxDirectory("PhoneImportPlanFile")
        let file = folder.appendingPathComponent("Dune.epub")
        try Data(repeating: 7, count: 300).write(to: file)

        let item = try PhoneImportCopyItem.plan(for: file)

        XCTAssertFalse(item.isFolder)
        XCTAssertEqual(item.name, "Dune.epub")
        XCTAssertEqual(item.files.map(\.relativePath), ["Dune.epub"])
        XCTAssertEqual(item.byteCount, 300)
        XCTAssertFalse(item.needsDownload)
    }

    /// A folder is one item of each of its files, by their paths inside it,
    /// in order, with a placeholder named for its real file.
    func testPlanningAFolder() throws {
        let sandbox = try makeSandboxDirectory("PhoneImportPlanFolder")
        let book = sandbox.appendingPathComponent("Radio Drama", isDirectory: true)
        try FileManager.default.createDirectory(at: book.appendingPathComponent("Disc 1"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: book.appendingPathComponent("Disc 1/01.mp3"))
        try Data(repeating: 2, count: 20).write(to: book.appendingPathComponent("02.mp3"))
        try Data().write(to: book.appendingPathComponent(".03.mp3.icloud"))

        let item = try PhoneImportCopyItem.plan(for: book)

        XCTAssertTrue(item.isFolder)
        XCTAssertEqual(item.name, "Radio Drama")
        XCTAssertEqual(item.files.map(\.relativePath), ["02.mp3", "03.mp3", "Disc 1/01.mp3"])
        XCTAssertEqual(item.byteCount, 30)
        XCTAssertTrue(item.needsDownload, "A placeholder is only in the cloud")
    }

    // MARK: - A Run

    /// A file and a folder are copied, keeping their names and the folder's
    /// shape, each in a scratch folder of its own, and the run says so once.
    func testARunCopiesFilesAndFolders() throws {
        let sandbox = try makeSandboxDirectory("PhoneImportRun")
        let file = sandbox.appendingPathComponent("Dune.epub")
        try Data("the spice".utf8).write(to: file)
        let book = sandbox.appendingPathComponent("Radio Drama", isDirectory: true)
        try FileManager.default.createDirectory(at: book.appendingPathComponent("Disc 1"), withIntermediateDirectories: true)
        try Data("track".utf8).write(to: book.appendingPathComponent("Disc 1/01.mp3"))
        let temporary = sandbox.appendingPathComponent("tmp", isDirectory: true)
        var statuses: [PhoneImportCopyRun.Status?] = []
        let run = PhoneImportCopyRun(
            sources: [file, book],
            temporaryDirectory: temporary,
            availableBytes: { _ in .max },
            statusChanged: { statuses.append($0) }
        )

        let outcome = try XCTUnwrap(waitForOutcome(of: run))

        guard case .copied(let copies) = outcome else { return XCTFail("Not copied: \(outcome)") }
        XCTAssertEqual(copies.map(\.lastPathComponent), ["Dune.epub", "Radio Drama"])
        XCTAssertEqual(try Data(contentsOf: copies[0]), Data("the spice".utf8))
        XCTAssertEqual(try Data(contentsOf: copies[1].appendingPathComponent("Disc 1/01.mp3")), Data("track".utf8))
        let root = PhoneImportCopyPlan.scratchRoot(in: temporary).standardizedFileURL.resolvingSymlinksInPath().path
        for copy in copies {
            XCTAssertTrue(PhoneImportCopyPlan.isInside(copy, folder: URL(fileURLWithPath: root)), copy.path)
        }
        XCTAssertNotEqual(copies[0].deletingLastPathComponent(), copies[1].deletingLastPathComponent())
        XCTAssertEqual(statuses.compactMap { $0?.name }, ["Dune", "Radio Drama"])
        XCTAssertEqual(statuses.last.flatMap { $0 }, nil, "The card hears the run is over")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "The original is never touched")
    }

    /// Without room for twice the size, nothing is copied.
    func testARunWithoutRoomCopiesNothing() throws {
        let sandbox = try makeSandboxDirectory("PhoneImportNoRoom")
        let file = sandbox.appendingPathComponent("Dune.epub")
        try Data(repeating: 1, count: 1_000).write(to: file)
        let temporary = sandbox.appendingPathComponent("tmp", isDirectory: true)
        let run = PhoneImportCopyRun(sources: [file], temporaryDirectory: temporary, availableBytes: { _ in 1_999 })

        XCTAssertEqual(waitForOutcome(of: run), .noRoom)
        XCTAssertFalse(FileManager.default.fileExists(atPath: PhoneImportCopyPlan.scratchRoot(in: temporary).path))
    }

    /// Cancelled as it starts, a run ends cancelled, once, and copies nothing.
    func testACancelledRunEndsCancelled() throws {
        let sandbox = try makeSandboxDirectory("PhoneImportCancel")
        let file = sandbox.appendingPathComponent("Dune.epub")
        try Data("the spice".utf8).write(to: file)
        let temporary = sandbox.appendingPathComponent("tmp", isDirectory: true)
        let run = PhoneImportCopyRun(sources: [file], temporaryDirectory: temporary, availableBytes: { _ in .max })

        XCTAssertEqual(waitForOutcome(of: run, cancellingAtOnce: true), .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: PhoneImportCopyPlan.scratchRoot(in: temporary).path))
    }

    /// A file that isn't there fails the run, naming it.
    func testAMissingFileFailsTheRun() throws {
        let sandbox = try makeSandboxDirectory("PhoneImportMissing")
        let missing = sandbox.appendingPathComponent("Gone.epub")
        let run = PhoneImportCopyRun(sources: [missing], temporaryDirectory: sandbox, availableBytes: { _ in .max })

        guard case .failed(let name, _) = waitForOutcome(of: run) else { return XCTFail("Not failed") }
        XCTAssertEqual(name, "Gone.epub")
    }

    // MARK: - Helpers

    /// Starts `run`, cancelling it at once when asked, and waits up to ten
    /// seconds for its one outcome; nil if none came.
    private func waitForOutcome(of run: PhoneImportCopyRun, cancellingAtOnce: Bool = false) -> PhoneImportCopyRun.Outcome? {
        let ended = expectation(description: "The run ends")
        ended.assertForOverFulfill = true
        var outcome: PhoneImportCopyRun.Outcome?
        run.start { result in
            outcome = result
            ended.fulfill()
        }
        if cancellingAtOnce { run.cancel() }
        wait(for: [ended], timeout: 10)
        return outcome
    }
}

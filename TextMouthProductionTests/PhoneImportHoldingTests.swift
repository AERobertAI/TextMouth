import XCTest
@testable import TextMouth

/// `PhoneImportHolding` and `PhoneImportRecord`: files held until the library
/// has started, whether an opened file's book opens, the moment the scratch
/// copies may be swept, and the record that names an import TextMouth's
/// closing stopped.
final class PhoneImportHoldingTests: XCTestCase {

    // MARK: - Holding

    /// Files are held in the order they came, and taken once.
    func testHeldFilesAreTakenOnceInOrder() {
        var holding = PhoneImportHolding()
        let first = URL(fileURLWithPath: "/tmp/Dune.epub")
        let second = URL(fileURLWithPath: "/tmp/Emma.txt")
        holding.hold([first])
        holding.hold([second])

        XCTAssertEqual(holding.takeHeldFiles(), [first, second])
        XCTAssertEqual(holding.takeHeldFiles(), [])
    }

    // MARK: - Routing

    /// A playing book is never stopped by a file another app sends.
    func testAPlayingBookMeansImportOnly() {
        XCTAssertEqual(PhoneImportHolding.route(isBookPlaying: true), .importOnly)
        XCTAssertEqual(PhoneImportHolding.route(isBookPlaying: false), .importAndOpen)
    }

    // MARK: - The Sweep's Moment

    /// Nothing is swept while the library imports, a question waits, a copy
    /// runs, or a file is held.
    func testNoSweepWhileAnythingIsUnderWay() {
        var holding = PhoneImportHolding()
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertEqual(holding.sweepDecision(isImporting: true, hasQuestion: false, isCopying: false, at: now), .notNow)
        XCTAssertEqual(holding.sweepDecision(isImporting: false, hasQuestion: true, isCopying: false, at: now), .notNow)
        XCTAssertEqual(holding.sweepDecision(isImporting: false, hasQuestion: false, isCopying: true, at: now), .notNow)
        holding.hold([URL(fileURLWithPath: "/tmp/Dune.epub")])
        XCTAssertEqual(holding.sweepDecision(isImporting: false, hasQuestion: false, isCopying: false, at: now), .notNow)
        _ = holding.takeHeldFiles()
        XCTAssertEqual(holding.sweepDecision(isImporting: false, hasQuestion: false, isCopying: false, at: now), .now)
    }

    /// Just after a hand-off the sweep waits out the quiet period, since the
    /// import queue counts the import a turn later; once it has passed, the
    /// sweep goes ahead.
    func testASweepWaitsOutTheQuietPeriodAfterAHandOff() {
        var holding = PhoneImportHolding()
        let handOff = Date(timeIntervalSinceReferenceDate: 1_000)
        holding.noteHandOff(at: handOff)

        XCTAssertEqual(
            holding.sweepDecision(isImporting: false, hasQuestion: false, isCopying: false, at: handOff.addingTimeInterval(1)),
            .after(PhoneImportHolding.quietPeriod - 1)
        )
        XCTAssertEqual(
            holding.sweepDecision(
                isImporting: false, hasQuestion: false, isCopying: false,
                at: handOff.addingTimeInterval(PhoneImportHolding.quietPeriod)
            ),
            .now
        )
    }

    /// An Inbox file is removed only once it has been there for the grace,
    /// so a file just arriving is never taken from under its call.
    func testInboxFilesAreSweptAfterTheirGrace() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        XCTAssertFalse(PhoneImportHolding.sweepsInboxFile(addedAt: now.addingTimeInterval(-1), at: now))
        XCTAssertTrue(PhoneImportHolding.sweepsInboxFile(addedAt: now.addingTimeInterval(-PhoneImportHolding.inboxGrace), at: now))
        XCTAssertTrue(PhoneImportHolding.sweepsInboxFile(addedAt: nil, at: now))
    }

    // MARK: - The Record

    /// The record survives a write and a read, as it must across a kill.
    func testRecordRoundTrips() throws {
        let folder = try makeSandboxDirectory("PhoneImportRecord")
        let file = PhoneImportRecord.file(in: folder.appendingPathComponent("PhoneImport", isDirectory: true))
        let record = PhoneImportRecord(entries: [
            .init(name: "Dune", copyPath: "/tmp/PhoneImport/A/Dune.epub"),
            .init(name: "Mac Books", copyPath: nil),
        ])
        try record.save(to: file)

        XCTAssertEqual(PhoneImportRecord.load(from: file), record)
        XCTAssertNil(PhoneImportRecord.load(from: folder.appendingPathComponent("missing.json")))
    }

    /// An item whose copy became a book was imported before the close and is
    /// not named; one with no copy yet, or whose copy is no book, is.
    func testStoppedNamesLeaveOutWhatWasImported() {
        let record = PhoneImportRecord(entries: [
            .init(name: "Dune", copyPath: "/tmp/PhoneImport/A/Dune.epub"),
            .init(name: "Emma", copyPath: "/tmp/PhoneImport/B/Emma.txt"),
            .init(name: "Radio Drama", copyPath: nil),
        ])

        XCTAssertEqual(record.stoppedNames(importedPaths: ["/tmp/PhoneImport/A/Dune.epub"]), ["Emma", "Radio Drama"])
        XCTAssertEqual(record.stoppedNames(importedPaths: []), ["Dune", "Emma", "Radio Drama"])
    }
}

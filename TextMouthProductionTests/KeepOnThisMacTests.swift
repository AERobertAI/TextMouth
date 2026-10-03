import XCTest
@testable import TextMouth

/// Keep on This Mac (FR02 polish): the set of books this Mac keeps
/// downloaded is this Mac's own, saved in its own folder and never in the
/// library, which every Mac reads.
@MainActor
final class KeepOnThisMacTests: XCTestCase {

    // MARK: - The Set and Its File

    /// The set round-trips through its file: a new set made from the same
    /// file holds what the last one kept, and stopping keeping a book takes
    /// it out of the file too.
    func testTheSetRoundTripsThroughItsFile() throws {
        let file = try makeSandboxDirectory("KeptBooks").appendingPathComponent("Kept Books.json")
        let first = UUID()
        let second = UUID()

        let kept = KeptBooks(file: file)
        kept.keep([first, second])

        XCTAssertEqual(KeptBooks(file: file).bookIDs, [first, second])

        kept.stopKeeping([first])

        XCTAssertEqual(KeptBooks(file: file).bookIDs, [second])
    }

    /// The file lists the kept books' IDs in order, so the same set always
    /// writes the same bytes, and people can read it.
    func testTheFileListsTheIDsInOrder() throws {
        let file = try makeSandboxDirectory("KeptBooksOrder").appendingPathComponent("Kept Books.json")
        let ids = (0..<3).map { _ in UUID() }

        KeptBooks(file: file).keep(ids)

        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [String]]
        XCTAssertEqual(saved?["books"], ids.map(\.uuidString).sorted())
    }

    /// With no file yet, as on this Mac's first launch, no book is kept,
    /// and nothing is written until a book is kept.
    func testNoFileKeepsNoBook() throws {
        let file = try makeSandboxDirectory("KeptBooksNone").appendingPathComponent("Kept Books.json")

        let kept = KeptBooks(file: file)

        XCTAssertTrue(kept.bookIDs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// A damaged file keeps no book, and is preserved beside itself before
    /// the next save replaces it, so nothing it held is lost.
    func testADamagedFileKeepsNoBookAndIsPreserved() throws {
        let folder = try makeSandboxDirectory("KeptBooksDamaged")
        let file = folder.appendingPathComponent("Kept Books.json")
        let damaged = Data("{\"books\": [\"0F".utf8)
        try damaged.write(to: file)

        let kept = KeptBooks(file: file)

        XCTAssertTrue(kept.bookIDs.isEmpty)
        let copies = LibraryIndexQuarantine.existingCopies(of: file)
        XCTAssertEqual(copies.count, 1, "the damaged file was not preserved")
        XCTAssertEqual(try copies.first.map { try Data(contentsOf: $0) }, damaged)

        kept.keep([UUID()])

        XCTAssertEqual(try copies.first.map { try Data(contentsOf: $0) }, damaged, "the preserved copy changed")
    }

    /// Keeping and stopping report the books they changed, and change
    /// nothing, writing nothing, for books already as asked.
    func testKeepingAndStoppingReportWhatChanged() throws {
        let file = try makeSandboxDirectory("KeptBooksChanges").appendingPathComponent("Kept Books.json")
        let first = UUID()
        let second = UUID()
        let kept = KeptBooks(file: file)

        XCTAssertEqual(kept.keep([first]), [first])
        XCTAssertEqual(kept.keep([first, second]), [second])
        XCTAssertEqual(kept.keep([first]), [])
        XCTAssertEqual(kept.stopKeeping([first, UUID()]), [first])
        XCTAssertEqual(kept.stopKeeping([first]), [])
        XCTAssertEqual(kept.bookIDs, [second])
    }

    /// The set counts the kept books among those it is given.
    func testTheSetCountsKeptBooks() {
        let books = [cloudTestBook("Moby-Dick"), cloudTestBook("Emma"), cloudTestBook("Dracula")]
        let kept = KeptBooks(file: nil)

        XCTAssertEqual(kept.count(of: books), 0)

        kept.keep([books[0].id, books[2].id, UUID()])

        XCTAssertEqual(kept.count(of: books), 2)
        XCTAssertTrue(kept.contains(books[0].id))
        XCTAssertFalse(kept.contains(books[1].id))
    }

    /// The app's set is saved in this Mac's own folder, which never syncs,
    /// and never in the data directory, which another Mac can open.
    func testTheAppsSetIsSavedInThisMacsOwnFolder() {
        let file = MachineLocalPaths.keptBooks
        XCTAssertEqual(KeptBooks.shared.file, file)
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL, MachineLocalPaths.root.standardizedFileURL)
        XCTAssertFalse(
            file.standardizedFileURL.path.hasPrefix(TextMouthPaths.root.standardizedFileURL.path + "/"),
            "the set must not sync with the library"
        )
    }
}

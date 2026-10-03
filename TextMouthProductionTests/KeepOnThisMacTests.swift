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

    // MARK: - Remove Download

    /// Remove Download refuses a kept book without asking the storage: the
    /// book keeps its download, and the window shows, and VoiceOver hears,
    /// why and what to do.
    func testRemoveDownloadRefusesAKeptBook() async {
        let book = cloudTestBook()
        let fixture = CommandFixture(books: [book], states: [book.id: .downloaded])
        fixture.kept.keep([book.id])

        var refusal: LibraryCloudRefusal?
        let said = await announcements {
            refusal = await fixture.commands.removeDownloads(of: [book], in: fixture.model, from: nil)
        }

        let explanation = BookCloudError.keptOnThisMac.explanation(in: .iCloudDrive)
        XCTAssertEqual(refusal, LibraryCloudRefusal(title: "Download Not Removed", message: explanation))
        XCTAssertEqual(said, [explanation])
        XCTAssertEqual(fixture.fake.downloadsRemoved, [])
        XCTAssertEqual(fixture.states.state(of: book.id), .downloaded)
        XCTAssertEqual(fixture.storage.mainThreadCalls, 0)
    }

    /// In a selection, the books not kept lose their downloads, and the kept
    /// one keeps its own, with the reason said once.
    func testRemoveDownloadOfASelectionSparesTheKeptBooks() async {
        let kept = cloudTestBook("Moby-Dick")
        let other = cloudTestBook("Emma", author: "Jane Austen")
        let fixture = CommandFixture(books: [kept, other], states: [kept.id: .downloaded, other.id: .downloaded])
        fixture.kept.keep([kept.id])

        var refusal: LibraryCloudRefusal?
        _ = await announcements {
            refusal = await fixture.commands.removeDownloads(of: [kept, other], in: fixture.model, from: nil)
        }

        XCTAssertEqual(fixture.fake.downloadsRemoved, [other.id])
        XCTAssertEqual(fixture.states.state(of: other.id), .inCloud)
        XCTAssertEqual(fixture.states.state(of: kept.id), .downloaded)
        XCTAssertEqual(
            refusal?.message,
            "Removed the download of Emma. It stays in iCloud Drive. The download of Moby-Dick wasn't removed. "
                + BookCloudError.keptOnThisMac.explanation(in: .iCloudDrive)
        )
    }

    /// The refusal says why, and names the command that lifts it.
    func testTheRefusalNamesTheCommandThatLiftsIt() {
        XCTAssertEqual(
            BookCloudError.keptOnThisMac.explanation(in: .dropbox),
            "The book is kept on this Mac, so its download can't be removed. Choose Stop Keeping on This Mac first."
        )
    }
}

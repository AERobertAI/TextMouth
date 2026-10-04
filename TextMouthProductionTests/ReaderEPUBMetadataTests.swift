import Combine
import os
import XCTest
@testable import TextMouth

/// A reader shows an EPUB's package metadata, which its metadata editor
/// starts from, without the open ever waiting for it. A book whose row
/// keeps the metadata, as the row of every book imported since rows kept it
/// does, shows it with the book and never reads the EPUB for it; any other
/// EPUB has it read from its file off the main thread once the book shows.
/// Either way the reader shows exactly what it showed when every open read
/// the file: the file's metadata with the book's own edits laid over it.
///
/// Each book is a copy of TestData's Alice EPUB, imported into a world of
/// the test's own. Nothing plays.
@MainActor
final class ReaderEPUBMetadataTests: XCTestCase {

    // MARK: - Kept in the Row

    /// An imported EPUB shows its metadata the moment the book shows, the
    /// same title, author, language, and every other field as reading the
    /// file at open showed, and the file is never read for it.
    func testAnImportedEPUBShowsItsMetadataWithTheBookWithoutReadingTheFile() throws {
        let world = try makeIntegrationWorld("Reader EPUB Metadata Kept")
        let book = try importAlice(into: world)
        let expected = try Self.metadataAsEveryOpenReadIt(for: book)
        let reads = MetadataReads()

        let reader = world.openReader(for: book)
        reader.readEPUBMetadata = reads.counting(reader.readEPUBMetadata)
        let shownWithTheBook = metadataAsTheBookShows(in: reader)

        XCTAssertEqual(shownWithTheBook?.allFields, expected.allFields, "the metadata did not show with the book")
        XCTAssertEqual(reader.epubMetadata?.title, "Alice's Adventures in Wonderland")
        XCTAssertEqual(reader.epubMetadata?.author, "Lewis Carroll")
        XCTAssertEqual(reader.epubMetadata?.language, "en")
        // A read the open had started off the main thread would have
        // counted by now.
        settle()
        XCTAssertEqual(reads.made, 0, "the reader read the EPUB for metadata its book's row keeps")
    }

    // MARK: - Read After the Book Shows

    /// An EPUB whose row keeps none of its metadata, as the row of a book
    /// imported before rows kept it, shows its book without waiting for the
    /// metadata, which is read from the file once, off the main thread, and
    /// is then exactly what reading it at open showed.
    func testAnEPUBWhoseRowKeepsNoMetadataShowsItOnceReadAfterTheBook() throws {
        let world = try makeIntegrationWorld("Reader EPUB Metadata Read")
        let book = withoutKeptMetadata(try importAlice(into: world), in: world)
        let expected = try Self.metadataAsEveryOpenReadIt(for: book)
        let reads = MetadataReads()

        let reader = world.openReader(for: book)
        reader.readEPUBMetadata = reads.counting(reader.readEPUBMetadata)

        XCTAssertNil(metadataAsTheBookShows(in: reader), "the book waited for its metadata to show")
        XCTAssertTrue(waitUntil(timeout: 10) { reader.epubMetadata != nil }, "the metadata never showed")
        XCTAssertEqual(reader.epubMetadata?.allFields, expected.allFields)
        XCTAssertEqual(reader.epubMetadata?.title, "Alice's Adventures in Wonderland")
        XCTAssertEqual(reader.epubMetadata?.author, "Lewis Carroll")
        XCTAssertEqual(reader.epubMetadata?.language, "en")
        settle()
        XCTAssertEqual(reads.made, 1, "the EPUB's metadata was not read exactly once")
    }

    /// An edit the library makes while the metadata is read is shown with
    /// it: the book's own edits are laid over the file's metadata from the
    /// book as it is when the read ends (TODO P10).
    func testAnEditTheLibraryMakesWhileTheMetadataIsReadIsShown() throws {
        let world = try makeIntegrationWorld("Reader EPUB Metadata Library Edit")
        let book = withoutKeptMetadata(try importAlice(into: world), in: world)
        let held = HeldMetadataRead()
        addTeardownBlock { held.release() }
        let reader = world.openReader(for: book)
        reader.readEPUBMetadata = held.read
        waitForReaderToLoad(reader)

        let edited = Self.edit(of: try Self.metadataAsEveryOpenReadIt(for: book))
        let save = world.library.saveEPUBMetadata(edited, for: book, writingToFile: false)
        XCTAssertNotNil(save.savedBook, save.message)
        held.release()

        XCTAssertTrue(waitUntil(timeout: 10) { reader.epubMetadata != nil }, "the metadata never showed")
        XCTAssertEqual(reader.epubMetadata?.allFields, edited.allFields)
    }

    /// Metadata the reader's own editor saves while the file is read stays
    /// as saved: the read, ending after the save, shows nothing over it.
    func testMetadataTheReaderSavesWhileTheFileIsReadStays() throws {
        let world = try makeIntegrationWorld("Reader EPUB Metadata Reader Save")
        let book = withoutKeptMetadata(try importAlice(into: world), in: world)
        let held = HeldMetadataRead()
        addTeardownBlock { held.release() }
        let reader = world.openReader(for: book)
        reader.readEPUBMetadata = held.read
        waitForReaderToLoad(reader)

        let edited = Self.edit(of: try Self.metadataAsEveryOpenReadIt(for: book))
        // The save's announcement is recorded rather than spoken.
        var outcome: OperationOutcome?
        _ = recordingAnnouncements { outcome = reader.saveEPUBMetadata(edited, writeToFile: false) }
        XCTAssertEqual(outcome, .success("Metadata saved to the library only; the EPUB file is unchanged."))
        held.release()

        XCTAssertTrue(waitUntil(timeout: 10) { held.hasEnded }, "the read never ended")
        settle()
        XCTAssertEqual(reader.epubMetadata?.allFields, edited.allFields)
    }

    /// A reader closed while its EPUB's metadata is read shows none once the
    /// read ends, and nothing else happens then.
    func testAReaderClosedWhileTheFileIsReadShowsNoMetadata() throws {
        let world = try makeIntegrationWorld("Reader EPUB Metadata Closed")
        let book = withoutKeptMetadata(try importAlice(into: world), in: world)
        let held = HeldMetadataRead()
        addTeardownBlock { held.release() }
        let reader = world.openReader(for: book)
        reader.readEPUBMetadata = held.read
        waitForReaderToLoad(reader)

        reader.close()
        held.release()

        XCTAssertTrue(waitUntil(timeout: 10) { held.hasEnded }, "the read never ended")
        settle()
        XCTAssertNil(reader.epubMetadata)
    }

    /// An EPUB whose metadata cannot be read shows none, as when every open
    /// read it: the metadata editor then opens the library's Book Info.
    func testAnEPUBWhoseMetadataCannotBeReadShowsNone() throws {
        let world = try makeIntegrationWorld("Reader EPUB Metadata Unreadable")
        let book = withoutKeptMetadata(try importAlice(into: world), in: world)
        let failing = HeldMetadataRead(failing: true)
        failing.release()
        let reader = world.openReader(for: book)
        reader.readEPUBMetadata = failing.read
        waitForReaderToLoad(reader)

        XCTAssertNil(reader.errorMessage, "the book did not open")
        XCTAssertTrue(waitUntil(timeout: 10) { failing.hasEnded }, "the read never ended")
        settle()
        XCTAssertNil(reader.epubMetadata)
    }

    // MARK: - Fixtures

    /// TestData's Alice EPUB.
    private static let aliceFixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("TestData/alice.epub")

    /// A copy of the Alice EPUB, imported into `world` as the developer
    /// imports a book, so its row keeps the EPUB's metadata.
    private func importAlice(into world: IntegrationWorld) throws -> Book {
        let copy = try makeSandboxDirectory("Reader EPUB Metadata").appendingPathComponent("alice.epub")
        try FileManager.default.copyItem(at: Self.aliceFixture, to: copy)
        return try world.importBook(from: copy)
    }

    /// `book` as the library holds a book imported before rows kept an
    /// EPUB's metadata: without any of it, in the library's row too.
    private func withoutKeptMetadata(_ book: Book, in world: IntegrationWorld) -> Book {
        var legacy = book
        legacy.epubPublisher = nil
        legacy.epubPublicationDate = nil
        legacy.epubISBN = nil
        legacy.epubLanguage = nil
        legacy.epubIdentifier = nil
        legacy.epubVersion = nil
        if let row = world.library.library.books.firstIndex(where: { $0.id == book.id }) {
            world.library.library.books[row] = legacy
        }
        XCTAssertNil(legacy.keptEPUBMetadata, "the row still keeps the EPUB's metadata")
        return legacy
    }

    /// The metadata a reader showed for `book` when every open read it from
    /// the file: the file's metadata with the book's own edits laid over it.
    private static func metadataAsEveryOpenReadIt(for book: Book) throws -> EPUBMetadata {
        book.mergingEditableEPUBMetadata(try EPUBParser.readMetadata(url: book.bookFileURL))
    }

    /// `metadata` with its title, author, publisher, and publication date
    /// edited, as the metadata editor edits them; the rest is the file's.
    private static func edit(of metadata: EPUBMetadata) -> EPUBMetadata {
        var edited = metadata
        edited.title = "Under the Hill"
        edited.author = "Ottoline Pryce-Mbeki"
        edited.publisher = "Harbour Steps Press"
        edited.publicationDate = "1907-03-02"
        return edited
    }

    /// Waits for `reader` to show its book, and returns the EPUB metadata it
    /// showed at that moment, as Loading gave way to the book.
    private func metadataAsTheBookShows(in reader: ReaderViewModel) -> EPUBMetadata? {
        var shown: EPUBMetadata?
        // The end of Loading is published as it is about to take effect,
        // after the metadata that shows with the book is in place.
        let watch = reader.$isLoading.dropFirst().first { !$0 }.sink { _ in shown = reader.epubMetadata }
        defer { watch.cancel() }
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.errorMessage, "the book did not open")
        return shown
    }

    /// Lets queued main-queue work run, such as the result of a read handed
    /// back to the reader.
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
}

// MARK: - Reads a Test Watches

/// Counts the reads of EPUB metadata a reader makes, from any thread.
private final class MetadataReads: Sendable {
    /// How many reads were made so far.
    private let count = OSAllocatedUnfairLock(initialState: 0)

    /// How many reads were made.
    var made: Int {
        count.withLock { $0 }
    }

    /// `read`, counting each read made through it.
    func counting(
        _ read: @escaping @Sendable (URL) throws -> EPUBMetadata
    ) -> @Sendable (URL) throws -> EPUBMetadata {
        { [self] url in
            count.withLock { $0 += 1 }
            return try read(url)
        }
    }
}

/// A read of EPUB metadata that waits until the test lets it go, so a test
/// can act while a reader's read is under way, and that says when it has
/// ended. Safe to use from any thread.
private final class HeldMetadataRead: Sendable {
    /// Opened by `release()`; the read waits for it.
    private let gate = DispatchSemaphore(value: 0)
    /// Whether the read has ended, with metadata or failing.
    private let ended = OSAllocatedUnfairLock(initialState: false)
    /// Whether the read fails, as the read of a damaged EPUB does.
    private let fails: Bool

    /// A held read that reads the file, or fails when `fails`.
    init(failing fails: Bool = false) {
        self.fails = fails
    }

    /// Whether the read has ended.
    var hasEnded: Bool {
        ended.withLock { $0 }
    }

    /// The read to hand a reader: it waits for `release()`, then reads the
    /// EPUB at the URL it is given, or fails.
    var read: @Sendable (URL) throws -> EPUBMetadata {
        { [self] url in
            gate.wait()
            defer { ended.withLock { $0 = true } }
            if fails {
                throw CocoaError(.fileReadCorruptFile)
            }
            return try EPUBParser.readMetadata(url: url)
        }
    }

    /// Lets the read go on. Calling it again does no harm.
    func release() {
        gate.signal()
    }
}

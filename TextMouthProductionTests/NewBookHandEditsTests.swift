import XCTest
import ZIPFoundation
@testable import TextMouth

/// The record of hand edits (`Book.handEdits`) each way a book comes into
/// the library begins with (finding #1291).
///
/// Only the ordinary file import begins one, kept since the import
/// (`Book.HandEdits.noneSinceImport`): its title and author are what the
/// metadata reader read in the very file the launch refresh reads again, so
/// the refresh may bring every field the file names up to date. Every other
/// way in begins none, so the refresh replaces nothing but an author shown
/// as Unknown, and only with a name: a feed's download, a recording, New
/// from Text, and an audio or DAISY archive take their names from somewhere
/// else than that file, and a package keeps the record its bookInfo.json
/// carries, or none when that is gone. Each import goes into a library
/// folder of the test's own, and the library index is put back afterwards.
final class NewBookHandEditsTests: XCTestCase {
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox?
    /// The library folder this test imports into.
    private var folderPath = ""
    /// Where this test's source files are written, outside the library.
    private var sources = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
        folderPath = "New Book Hand Edits \(UUID().uuidString.prefix(8))"
        sources = FileManager.default.temporaryDirectory
            .appendingPathComponent("NewBookHandEditsSources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        sandbox?.restore()
        try? FileManager.default.removeItem(at: TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true))
        try? FileManager.default.removeItem(at: sources)
    }

    // MARK: - The File Import

    /// A book imported from a file of each format the file import takes
    /// (EPUB, Word, PDF, a DAISY book's archive of text, plain text,
    /// Markdown, HTML, and audio) begins a record kept since its import,
    /// with nothing edited by hand, in its row and in its package's record,
    /// and is stamped by the metadata reader that named it.
    func testEveryFormatTheFileImportTakesBeginsItsRecordAtTheImport() throws {
        let audio = sources.appendingPathComponent("Harbour Bells.wav")
        try AudioTestFixtures.writeSilence(to: audio)
        let files: [URL] = [
            try requireFile("alice.epub"),
            try requireFile("alice.docx"),
            try requireFile("test_formatted.pdf"),
            try requireFile("daisy202_test.zip"),
            try writeSource("Harbour Notes.txt", "Notes on the harbour wall.\n\nThe tide came in at noon."),
            try writeSource("Harbour Notes.md", "# Harbour Notes\n\nThe tide came in at noon."),
            try writeSource("Harbour Notes.html", "<html><body><h1>Harbour Notes</h1><p>The tide came in at noon.</p></body></html>"),
            audio,
        ]

        for file in files {
            let book = try FileImportService.importFileWithReport(from: file, toFolder: folderPath).book

            try assertRecord(of: book, is: .noneSinceImport, file.lastPathComponent)
            XCTAssertEqual(book.metadataReaderVersion, ImportedFileMetadata.readerVersion, file.lastPathComponent)
        }
    }

    /// Each book of a ZIP batch is imported as a file, and begins the same
    /// record.
    func testEachBookOfAZIPBatchBeginsItsRecordAtTheImport() throws {
        let archive = try makeTemporaryZip(prefix: "NewBookBatch", entries: [
            "Tide Tables.txt": Data("High water at noon, low water at six.".utf8),
            "Harbour Lights.md": Data("# Harbour Lights\n\nThe green light marks the breakwater.".utf8),
        ])
        addTeardownBlock { try? FileManager.default.removeItem(at: archive) }

        let result = try FileImportService.importZip(from: archive, toFolder: folderPath)

        XCTAssertEqual(result.books.count, 2, "\(result.failures)")
        for book in result.books {
            try assertRecord(of: book, is: .noneSinceImport, book.title)
        }
    }

    // MARK: - Books Named Elsewhere Than Their File

    /// Text entered with New from Text, a title typed with or without an
    /// author, begins no record.
    func testNewFromTextBeginsNoRecord() throws {
        let attributed = try importText(title: "Trail Log", author: "Ranger Station")
        let unattributed = try importText(title: "Trail Log, Day Two", author: "")

        try assertRecord(of: attributed, is: nil)
        try assertRecord(of: unattributed, is: nil)
    }

    /// A recording, named in the recording window, begins no record.
    func testARecordingBeginsNoRecord() async throws {
        let take = sources.appendingPathComponent("Take.caf")
        try RecordingAudioFixtures.writeTake(to: take, duration: 1)
        let encoded = sources.appendingPathComponent("Take.m4a")
        try await RecordingEncoder.encode(take: take, to: encoded, title: "Harbour Walk")
        let origin = BookOrigin(
            kind: .recording,
            recordedAt: Date(timeIntervalSince1970: 1_790_000_000),
            duration: 1,
            inputDeviceName: "MacBook Air Microphone",
            originalTake: nil
        )

        let book = try FileImportService.importRecording(
            audio: encoded,
            take: nil,
            origin: origin,
            title: "Harbour Walk",
            toFolder: folderPath
        ).book

        try assertRecord(of: book, is: nil)
    }

    /// A feed's downloads, an episode and an article, begin no record, so
    /// the refresh, which reads an episode's own tags, never replaces the
    /// title and author the feed gave with what the file names.
    func testAFeedsDownloadsBeginNoRecordSoTheirNamesStayTheFeeds() throws {
        let feed = Feed(
            feedURL: try XCTUnwrap(URL(string: "https://example.com/harbour-radio.xml")),
            folderID: UUID(),
            subscribedDate: Date(timeIntervalSince1970: 1_790_000_000)
        )
        let item = FeedItem(
            id: "episode-12",
            title: "Episode 12: The Breakwater",
            firstSeen: Date(timeIntervalSince1970: 1_790_000_000),
            author: "Harbour Radio"
        )
        let download = sources.appendingPathComponent("download.wav")
        try AudioTestFixtures.writeSilence(to: download)

        let episode = try FeedEpisodeImporter.importEpisode(
            download,
            named: "Episode 12 The Breakwater.wav",
            item: item,
            of: feed,
            toFolder: folderPath,
            dateAdded: Date()
        ).book
        let article = try FeedEpisodeImporter.importArticle(
            html: FeedEpisodeImporter.articleHTML(for: item, of: feed, body: "<p>The breakwater held.</p>"),
            item: item,
            of: feed,
            toFolder: folderPath,
            dateAdded: Date()
        ).book

        try assertRecord(of: episode, is: nil)
        try assertRecord(of: article, is: nil)
        let tags = MetadataReading(bookID: episode.id, named: [.title: "ep12_final_mix", .author: "Studio B"])
        XCTAssertEqual(LibraryViewModel.refreshedValues(of: episode, from: tags), [:])
    }

    /// An archive of audio tracks, named by the archive, and a DAISY
    /// talking book's archive, named by its navigation document, each
    /// become an audiobook whose record is not begun.
    func testAudioAndDAISYArchivesBeginNoRecord() throws {
        let tracks = sources.appendingPathComponent("Harbour Lectures", isDirectory: true)
        try FileManager.default.createDirectory(at: tracks, withIntermediateDirectories: true)
        for name in ["01.wav", "02.wav"] {
            try AudioTestFixtures.writeSilence(to: tracks.appendingPathComponent(name))
        }
        let audioArchive = sources.appendingPathComponent("Harbour Lectures.zip")
        try FileManager.default.zipItem(at: tracks, to: audioArchive, shouldKeepParent: false)

        let lectures = try FileImportService.importAudioZipWithReport(from: audioArchive, toFolder: folderPath).book
        let survey = try FileImportService.importDAISYAudioZipWithReport(
            from: try makeDAISYAudioArchive(title: "Tide Survey"),
            toFolder: folderPath
        ).book

        XCTAssertEqual(lectures.title, "Harbour Lectures")
        XCTAssertEqual(survey.title, "Tide Survey")
        try assertRecord(of: lectures, is: nil)
        try assertRecord(of: survey, is: nil)
    }

    // MARK: - What the Launch Refresh Takes

    /// What the launch refresh takes from what a newer reader names: every
    /// field it may replace, for a book the file import named; for a book
    /// named by what the user typed, never the title, and the author only
    /// when it is shown as Unknown. A file that names no title, read with
    /// the refresh's empty fallback, names none, so no file name or empty
    /// title ever stands in.
    func testTheRefreshBringsAFileImportUpToDateButNeverATypedTitle() throws {
        let fromFile = try FileImportService.importFileWithReport(from: requireFile("alice.epub"), toFolder: folderPath).book
        let attributed = try importText(title: "Harbour Notes", author: "Port Clerk")
        let unattributed = try importText(title: "Harbour Notes, Second Week", author: "")
        let newer: Book.MetadataValues = [.title: "A Newer Title", .author: "A Newer Author"]

        XCTAssertEqual(refreshed(fromFile, newer), newer)
        XCTAssertEqual(refreshed(attributed, newer), [:])
        XCTAssertEqual(refreshed(unattributed, newer), [.author: "A Newer Author"])
        let untitled = MetadataReading(bookID: fromFile.id, read: ImportedFileMetadata(title: ""))
        XCTAssertEqual(untitled.named, [:])
        XCTAssertEqual(LibraryViewModel.refreshedValues(of: fromFile, from: untitled), [:])
    }

    // MARK: - Books Rebuilt from a Package

    /// A package imported into the library keeps the record its
    /// bookInfo.json carries, one begun by an edit included, and a package
    /// whose record carries none gets none.
    func testAnImportedPackageKeepsTheRecordItCarries() throws {
        let carried: [Book.HandEdits?] = [Book.HandEdits(fields: [.title], sinceImport: false), nil]
        for record in carried {
            let package = try makePackage(handEdits: record, in: sources)

            let book = try FileImportService.importTMBPackageWithReport(from: package).book
            addTeardownBlock { try? FileManager.default.removeItem(at: book.tmbDirectory) }

            try assertRecord(of: book, is: record, String(describing: record))
        }
    }

    /// A package whose bookInfo.json is gone, as Remove from Library Only
    /// leaves it, is rebuilt from its removal marker, whose title and author
    /// may be the user's own, without a record, even when the record it
    /// lost had one; imported, it publishes a record without one.
    func testAPackageRebuiltFromItsRemovalMarkerBeginsNoRecord() throws {
        let package = try makePackage(handEdits: .noneSinceImport, in: sources)
        let lost = try BookInfo.load(from: package)
        let book = Book(record: lost, filePath: "", folderPath: "", tmbDirectoryName: package.lastPathComponent)
        try RemovedFromLibraryMarker(book: book).write(into: package)
        try FileManager.default.removeItem(at: TextMouthPaths.bookInfoPath(in: package))

        let rebuilt = try FileImportService.reconstructedBook(
            inPackage: package,
            marker: try RemovedFromLibraryMarker.read(in: package),
            folderPath: "",
            dateAdded: Date()
        )
        XCTAssertEqual(rebuilt.id, book.id)
        XCTAssertNil(rebuilt.handEdits)

        let imported = try FileImportService.importTMBPackageWithReport(from: package).book
        addTeardownBlock { try? FileManager.default.removeItem(at: imported.tmbDirectory) }
        XCTAssertEqual(imported.id, book.id)
        try assertRecord(of: imported, is: nil)
    }

    /// An orphaned package the library adopts at launch keeps the record
    /// its bookInfo.json carries, and one whose record carries none gets
    /// none.
    func testAnAdoptedPackageKeepsTheRecordItCarries() throws {
        let library = sources.appendingPathComponent("Library", isDirectory: true)
        let edited = Book.HandEdits(fields: [.author], sinceImport: true)
        let withRecord = try makePackage(handEdits: edited, in: library)
        let withoutRecord = try makePackage(handEdits: nil, in: library)

        var adopted = Library()
        let count = FileImportService.adoptOrphanedTMBPackages(library: &adopted, libraryDirectory: library)

        XCTAssertEqual(count, 2)
        let records = Dictionary(uniqueKeysWithValues: adopted.books.map { ($0.tmbDirectoryName, $0.handEdits) })
        XCTAssertEqual(records[withRecord.lastPathComponent], .some(edited))
        XCTAssertEqual(records[withoutRecord.lastPathComponent], .some(nil))
    }

    // MARK: - Checks and Fixtures

    /// Checks that `book`'s row and its package's record (bookInfo.json)
    /// both hold `expected` as the book's record of hand edits.
    private func assertRecord(
        of book: Book,
        is expected: Book.HandEdits?,
        _ context: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(book.handEdits, expected, "\(context): the row", file: file, line: line)
        let record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(record.metadata.handEdits, expected, "\(context): the package's record", file: file, line: line)
    }

    /// The fields of `book` the launch refresh replaces when its file names
    /// `named` (`LibraryViewModel.refreshedValues(of:from:)`).
    private func refreshed(_ book: Book, _ named: Book.MetadataValues) -> Book.MetadataValues {
        LibraryViewModel.refreshedValues(of: book, from: MetadataReading(bookID: book.id, named: named))
    }

    /// The book New from Text makes of a line of text titled `title`, with
    /// `author` as entered.
    private func importText(title: String, author: String) throws -> Book {
        try FileImportService.importText(
            "Notes kept on the harbour wall by \(title).",
            title: title,
            author: author,
            fileName: TextImportPolicy.textFilename(for: title),
            toFolder: folderPath
        ).book
    }

    /// A source file named `name` holding `text`, outside the library.
    private func writeSource(_ name: String, _ text: String) throws -> URL {
        let url = sources.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// A package in `parent`, outside the managed library unless `parent`
    /// is a library of the test's own, holding one text file of its own and
    /// a record describing it that carries `handEdits`.
    private func makePackage(handEdits: Book.HandEdits?, in parent: URL) throws -> URL {
        let name = "Harbour Charts \(UUID().uuidString.prefix(8))"
        let package = parent.appendingPathComponent("\(name).tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let content = package.appendingPathComponent("\(name).txt")
        try Data("Soundings for \(name): four fathoms at the harbour mouth.".utf8).write(to: content)
        let info = BookInfo(
            metadata: BookMetadata(
                title: name,
                author: "Port Authority",
                format: .txt,
                md5Hash: try FileImportService.md5Hash(of: content),
                originalFileName: content.lastPathComponent,
                bookID: UUID(),
                handEdits: handEdits
            ),
            state: BookState(tmbDirectoryName: package.lastPathComponent)
        )
        try info.save(to: package)
        return package
    }

    /// A DAISY 2.02 talking book titled `title` as a ZIP archive: one
    /// heading, whose one clip is the first second of a two-second silent
    /// wave file. Removed when the test ends.
    private func makeDAISYAudioArchive(title: String) throws -> URL {
        let ncc = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head>
        <meta name="dc:title" content="\(title)"/>
        <meta name="dc:creator" content="Harbour Office"/>
        </head><body>
        <h1 id="h1"><a href="part1.smil#p1">Soundings</a></h1>
        </body></html>
        """
        let smil = """
        <?xml version="1.0" encoding="utf-8"?>
        <smil><body><seq>
        <par id="p1"><text src="text.html#t1"/><audio src="part1.wav" clip-begin="npt=0.000s" clip-end="npt=1.000s"/></par>
        </seq></body></smil>
        """
        let wave = sources.appendingPathComponent("part1.wav")
        try AudioTestFixtures.writeSilence(to: wave, duration: 2)
        let archive = try makeTemporaryZip(prefix: "NewBookDAISY", entries: [
            "ncc.html": Data(ncc.utf8),
            "part1.smil": Data(smil.utf8),
            "part1.wav": try Data(contentsOf: wave),
        ])
        addTeardownBlock { try? FileManager.default.removeItem(at: archive) }
        return archive
    }
}

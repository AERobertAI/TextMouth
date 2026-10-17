import XCTest
import ZIPFoundation
@testable import TextMouth

/// Damaged audio, and navigation that does not fit its audio, fail the
/// import itself (TODO I04). The parser's errors reach the import through
/// the analysis every audio import runs before it publishes a book (TODO
/// S02), so the failure names the archive, the step, the file, and the
/// problem, and nothing is left in the library. DAISY clip ends that run
/// only slightly past their file, as encoder padding leaves them, still
/// import. Each test imports into a library folder of its own, removed
/// when it ends; its sources are written outside the library.
final class AudioMediaImportTests: XCTestCase {
    /// The library folder this test imports into.
    private var folderPath: String!
    /// Where this test's source files are written, outside the library.
    private var sources: URL!

    override func setUpWithError() throws {
        folderPath = "Audio Media Import \(UUID().uuidString.prefix(8))"
        sources = try AudioTestFixtures.makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed partway.
        if let folderPath {
            try? FileManager.default.removeItem(at: TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true))
        }
        if let sources {
            try? FileManager.default.removeItem(at: sources)
        }
    }

    // MARK: - Damaged Audio

    /// An archive with one track that is text, not audio, fails while
    /// reading its audio, naming that track by its path in the archive.
    func testAudioArchiveWithATextTrackFailsNamingIt() throws {
        let name = "Lecture Series \(UUID().uuidString.prefix(8))"
        let archive = try makeAudioArchive(named: name, keepingItsFolder: true) { folder in
            try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("01.wav"))
            try AudioTestFixtures.writePlainText(to: folder.appendingPathComponent("02.mp3"))
        }

        assertImportFails(
            of: archive,
            with: FileImportService.importAudioZipWithReport(from:toFolder:observer:),
            because: "The file “\(name)/02.mp3” in this audiobook is damaged or incomplete: "
                + "it cannot be opened as audio. " + AudioMediaAdvice.damage
        )
    }

    /// An archive with a track cut short, which opens with its full length
    /// and used to fail only partway through playback, now fails at import.
    func testAudioArchiveWithATrackCutShortFailsNamingIt() throws {
        let archive = try makeAudioArchive(named: "Night Ferry \(UUID().uuidString.prefix(8))") { folder in
            try AudioTestFixtures.writeAACSilence(to: folder.appendingPathComponent("01.m4a"))
            try AudioTestFixtures.writeTruncatedAAC(to: folder.appendingPathComponent("02.m4a"), keepingAudioFraction: 0.5)
        }

        assertImportFails(
            of: archive,
            with: FileImportService.importAudioZipWithReport(from:toFolder:observer:),
            because: "The file “02.m4a” in this audiobook is damaged or incomplete: "
                + "its audio breaks off before the length the file declares. "
                + AudioMediaAdvice.damage
        )
    }

    /// A single audiobook file cut short fails at import, in the words
    /// playback uses for such a file, carrying the probe's finding.
    func testSingleFileCutShortFailsAtImport() throws {
        let source = sources.appendingPathComponent("Ferry Log \(UUID().uuidString.prefix(8)).m4a")
        try AudioTestFixtures.writeTruncatedAAC(to: source, keepingAudioFraction: 0.5)

        let failure = assertImportFails(
            of: source,
            with: FileImportService.importFileWithReport(from:toFolder:observer:),
            because: "The file \(source.lastPathComponent) is damaged, unreadable, or not an audio file."
        )

        guard case .unplayableAudio(let playbackFailure)? = failure?.underlying as? FileImportError else {
            return XCTFail("Expected an unplayable-audio failure, got \(String(describing: failure?.underlying))")
        }
        XCTAssertEqual(
            playbackFailure.underlyingError as Error? as? AudioParseError,
            .unplayableFile(file: source.lastPathComponent, problem: .endsEarly)
        )
    }

    // MARK: - Navigation That Does Not Fit Its Audio

    /// An archive whose manifest starts a section past the end of its file
    /// fails, naming the heading, the times, and the file's real length.
    func testAudioArchiveWhoseSectionStartsPastItsFileFailsNamingIt() throws {
        let archive = try makeAudioArchive(named: "Harbor Lectures \(UUID().uuidString.prefix(8))") { folder in
            try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"), duration: 2)
            let manifest = AudioManifest(segments: [
                AudioSegment(title: "Opening", file: "a.wav", startTime: 0, endTime: 1),
                AudioSegment(title: "Chapter 12", file: "a.wav", startTime: 5, endTime: 6)
            ])
            try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
        }

        assertImportFails(
            of: archive,
            with: FileImportService.importAudioZipWithReport(from:toFolder:observer:),
            because: "The heading “Chapter 12” starts 5 seconds into its file “a.wav”, which is only 2 seconds long. "
                + AudioMediaAdvice.mismatch
        )
    }

    /// A DAISY book whose last clip ends far past its audio fails at
    /// import, naming the heading, the clip's end, and the file's length.
    func testDAISYBookWhoseClipsRunFarPastTheAudioFailsNamingTheHeading() throws {
        let book = try makeDAISYBook(title: "Harbor Soundings \(UUID().uuidString)", lastClipEnds: (9, 1))

        assertImportFails(
            of: book,
            with: FileImportService.importDAISYAudioZipWithReport(from:toFolder:observer:),
            because: "The heading “Leadline Readings” ends 9 seconds into its file “part1.wav”, "
                + "which is only 2 seconds long. "
                + AudioMediaAdvice.mismatch
        )
    }

    /// A DAISY book whose last clips end a fraction of a second past their
    /// files, as encoder padding leaves them, imports. Each heading ends
    /// with its file in the saved index, and the move is logged.
    func testDAISYBookWithPaddedClipEndsImportsEndingEachHeadingWithItsFile() throws {
        let title = "Harbor Soundings \(UUID().uuidString)"
        let book = try makeDAISYBook(title: title, lastClipEnds: (2.3, 1.05))

        let imported = try FileImportService.importDAISYAudioZipWithReport(from: book, toFolder: folderPath)

        XCTAssertEqual(try folderEntries(), [imported.book.tmbDirectoryName])
        let index = try XCTUnwrap(BookInfo.load(from: imported.book.tmbDirectory).contentIndex)
        XCTAssertEqual(index.chapters.map(\.title), ["Leadline Readings", "Breakwater Survey"])
        XCTAssertEqual(index.restoredAudioSegments()?.map(\.endTime), [2, 1])
        let tag = "\(AudioBookParser.clampLogTag): \(title): "
        let logged = debugLogLines(containing: tag).compactMap { line in
            line.range(of: tag).map { String(line[$0.lowerBound...]) }
        }
        XCTAssertEqual(logged, [
            tag + "part1.wav: moved 1 section's end back to the file's measured end of 2.000 s, from 0.300 s past it",
            tag + "part2.wav: moved 1 section's end back to the file's measured end of 1.000 s, from 0.050 s past it"
        ])
    }

    /// The library's own ZIP import sends an archive holding a DAISY book
    /// with audio to the audio importer: it opens the archive a second
    /// time, finds the audio there, and the book imports as an audio book
    /// (TODO Q06 pins this before the archive is opened through another
    /// initializer; `DAISYPackageImportTests` covers the archive without
    /// audio). The import saves the library, so the hosted test root's
    /// library index is put back afterwards, and the archive is kept.
    @MainActor
    func testLibraryImportsADAISYArchiveWithAudioAsAnAudioBook() throws {
        let index = try LibraryIndexSandbox.capture()
        defer { index.restore() }
        useAfterImportingBehavior(.keepOriginal)
        let title = "Harbor Soundings \(UUID().uuidString)"
        let book = try makeDAISYBook(title: title, lastClipEnds: (2, 1))
        XCTAssertTrue(DAISYParser.isDAISYZip(url: book))
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()

        model.importZipAsync(from: book, toFolder: folderPath)

        XCTAssertTrue(
            eventually(within: 60) { !model.library.books.isEmpty || model.showError },
            "the import never finished"
        )
        XCTAssertFalse(model.showError, model.errorMessage ?? "")
        XCTAssertEqual(model.library.books.map(\.format), [.audio])
        XCTAssertEqual(model.library.books.map(\.title), [title])
    }

    // MARK: - The Manifest's Title and Author

    /// An archive whose manifest gives a blank title and author names the
    /// book after the archive and leaves its author unknown, as a manifest
    /// without them does; a real title and author name the book.
    func testBlankManifestTitleAndAuthorFallBackAndRealOnesAreKept() throws {
        let blankName = "Harbor Blank \(UUID().uuidString.prefix(8))"
        let blank = try makeAudioArchive(named: blankName) { folder in
            try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"), duration: 1)
            try Data(#"{"title": "   ", "author": ""}"#.utf8).write(to: folder.appendingPathComponent("manifest.json"))
        }
        let named = try makeAudioArchive(named: "Harbor Named \(UUID().uuidString.prefix(8))") { folder in
            try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"), duration: 1)
            try Data(#"{"title": "Harbor Plays", "author": "Wenzel Okafor"}"#.utf8).write(to: folder.appendingPathComponent("manifest.json"))
        }

        let blankBook = try FileImportService.importAudioZipWithReport(from: blank, toFolder: folderPath).book
        let namedBook = try FileImportService.importAudioZipWithReport(from: named, toFolder: folderPath).book

        XCTAssertEqual(blankBook.title, blankName)
        XCTAssertEqual(blankBook.author, Book.unknownAuthor)
        XCTAssertEqual(namedBook.title, "Harbor Plays")
        XCTAssertEqual(namedBook.author, "Wenzel Okafor")
    }

    // MARK: - Helpers

    /// An import function as these tests call it: the source, the library
    /// folder, and the observer told of each step.
    private typealias Importer = (URL, String, ImportStepObserver?) throws -> ImportedBook

    /// Imports `source` into this test's folder with `importer` and asserts
    /// that it fails while reading its audio because of `problem`: the
    /// failure names the source and the step, the debug log records it
    /// once, nothing is left in the folder, and the source keeps its
    /// bytes. Returns the failure.
    @discardableResult
    private func assertImportFails(
        of source: URL,
        with importer: Importer,
        because problem: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> ImportFailure? {
        let bytes = try? Data(contentsOf: source)
        let logLine = "IMPORT_FAILED: \(source.lastPathComponent): Reading its audio failed: \(problem)"
        var failure: ImportFailure?

        XCTAssertThrowsError(try importer(source, folderPath, nil), file: file, line: line) { error in
            failure = error as? ImportFailure
        }

        XCTAssertEqual(failure?.fileName, source.lastPathComponent, file: file, line: line)
        XCTAssertEqual(failure?.step, .readingAudio, file: file, line: line)
        XCTAssertEqual(failure?.reason, "Reading its audio failed: \(problem)", file: file, line: line)
        XCTAssertEqual(debugLogLines(containing: logLine).count, 1, file: file, line: line)
        XCTAssertEqual((try? folderEntries()) ?? [], [], "left behind", file: file, line: line)
        XCTAssertEqual(try? Data(contentsOf: source), bytes, "the source must be untouched", file: file, line: line)
        return failure
    }

    /// A ZIP archive named `name`.zip holding the files `write` puts in the
    /// folder it is given: at the archive's top level, or inside a folder
    /// named `name` when `keepingItsFolder`, as Finder's Compress command
    /// makes it.
    private func makeAudioArchive(
        named name: String,
        keepingItsFolder: Bool = false,
        write: (URL) throws -> Void
    ) throws -> URL {
        let folder = sources.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write(folder)
        let archive = sources.appendingPathComponent("\(name).zip")
        try FileManager.default.zipItem(at: folder, to: archive, shouldKeepParent: keepingItsFolder)
        return archive
    }

    /// A DAISY 2.02 talking book as a ZIP archive titled `title`: two
    /// headings, each read from its own SMIL file and its own WAVE file
    /// (two seconds and one second long), each in two clips. The last clip
    /// of each file ends at `lastClipEnds` seconds; the DAISY converter
    /// ends each heading there, as the next heading plays from another file.
    private func makeDAISYBook(title: String, lastClipEnds: (first: Double, second: Double)) throws -> URL {
        let ncc = """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head>
        <meta name="dc:title" content="\(title)"/>
        <meta name="dc:creator" content="Odile Marchetti"/>
        </head><body>
        <h1 id="h1"><a href="part1.smil#p1">Leadline Readings</a></h1>
        <h1 id="h2"><a href="part2.smil#p3">Breakwater Survey</a></h1>
        </body></html>
        """
        let part1 = try Self.wave(lasting: 2, in: sources)
        let part2 = try Self.wave(lasting: 1, in: sources)
        let archive = try makeTemporaryZip(prefix: "AudioMediaDAISY", entries: [
            "ncc.html": Data(ncc.utf8),
            "part1.smil": Data(Self.smil(audio: "part1.wav", firstPar: 1, split: 1, end: lastClipEnds.first).utf8),
            "part2.smil": Data(Self.smil(audio: "part2.wav", firstPar: 3, split: 0.5, end: lastClipEnds.second).utf8),
            "part1.wav": part1,
            "part2.wav": part2
        ])
        addTeardownBlock { try? FileManager.default.removeItem(at: archive) }
        return archive
    }

    /// A DAISY 2.02 SMIL file of two clips of `audio`, in pars numbered
    /// from `firstPar`: from the start to `split` seconds, then on to `end`.
    private static func smil(audio: String, firstPar: Int, split: Double, end: Double) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <smil><body><seq>
        <par id="p\(firstPar)"><text src="text.html#t\(firstPar)"/><audio src="\(audio)" clip-begin="npt=0.000s" clip-end="npt=\(String(format: "%.3f", split))s"/></par>
        <par id="p\(firstPar + 1)"><text src="text.html#t\(firstPar + 1)"/><audio src="\(audio)" clip-begin="npt=\(String(format: "%.3f", split))s" clip-end="npt=\(String(format: "%.3f", end))s"/></par>
        </seq></body></smil>
        """
    }

    /// The bytes of a silent WAVE file lasting `seconds`, written in `folder`.
    private static func wave(lasting seconds: TimeInterval, in folder: URL) throws -> Data {
        let file = folder.appendingPathComponent("\(UUID().uuidString).wav")
        try AudioTestFixtures.writeSilence(to: file, duration: seconds)
        return try Data(contentsOf: file)
    }

    /// Every name in this test's library folder, hidden ones included; none
    /// when the folder does not exist.
    private func folderEntries() throws -> Set<String> {
        let folder = TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    }
}

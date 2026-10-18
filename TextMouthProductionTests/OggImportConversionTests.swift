import XCTest
@testable import TextMouth

/// Every import converts its Ogg audio to AAC before anything reads it as a
/// book or plays it (B06, item 2): a ZIP of tracks, a folder of tracks, and
/// a single file, each in a new step, Converting its audio, that comes
/// after the manifest's check and before Reading its audio. The manifest
/// follows the renamed tracks; what was imported from is never touched.
/// The Ogg fixtures are only ever decoded offline, never played.
final class OggImportConversionTests: XCTestCase {
    private var folder: URL!
    private var importedPackages: [URL] = []

    override func setUpWithError() throws {
        folder = try AudioTestFixtures.makeTemporaryDirectory()
    }

    override func tearDown() {
        for package in importedPackages { try? FileManager.default.removeItem(at: package) }
        importedPackages = []
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    // MARK: - The Step's Words

    /// The overlay counts a book's tracks as they convert; a single file
    /// needs no count, and a failure names the step.
    func testTheStepIsCalledConvertingItsAudioAndCountsTheTracks() {
        XCTAssertEqual(
            ImportProgressWording.book("Radio Dramas.zip", step: .convertingImportedAudio(done: 12, of: 176)),
            "“Radio Dramas.zip”, converting its audio: 12 of 176 tracks"
        )
        XCTAssertEqual(
            ImportProgressWording.book("Radio Dramas.zip", number: 2, of: 5, step: .convertingImportedAudio(done: 0, of: 2)),
            "Book 2 of 5: “Radio Dramas.zip”, converting its audio: 0 of 2 tracks"
        )
        XCTAssertEqual(
            ImportProgressWording.book("Elegy.ogg", step: .convertingImportedAudio(done: 0, of: 1)),
            "“Elegy.ogg”, converting its audio"
        )
        XCTAssertEqual(ImportProgressWording.tracks(done: 0, of: 1), "0 of 1 track")
        let failure = ImportFailure(
            fileName: "Elegy.ogg",
            step: .convertingImportedAudio(done: 0, of: 1),
            underlying: ImportAudioConverter.Failure.unreadable(fileName: "Elegy.ogg")
        )
        XCTAssertEqual(
            failure.errorDescription,
            "Could not import “Elegy.ogg”. Converting its audio failed: The Ogg audio file Elegy.ogg could not be read for converting to AAC."
        )
    }

    // MARK: - A ZIP of Tracks

    /// A ZIP of Ogg tracks with a manifest naming them as .ogg files
    /// imports as AAC: the manifest's check reads the archive's names, the
    /// tracks convert after it and before the audio is read, the manifest
    /// is renamed to match, its order and titles stay, no Ogg file is left
    /// in the package, and the archive is untouched.
    func testAZIPOfOggTracksImportsAsAACWithItsManifestRenamed() throws {
        try OggTestFixtures.skipUnlessOggDecodes()
        let source = folder.appendingPathComponent("Radio Dramas")
        try OggTestFixtures.copy(OggTestFixtures.vorbis, to: source, as: "elegy.ogg")
        try OggTestFixtures.copy(OggTestFixtures.opus, to: source, as: "two.opus")
        try Data(#"{"title": "Harbor Dramas", "order": ["two.opus", "elegy.ogg"], "chapters": {"elegy.ogg": "The Elegy"}}"#.utf8)
            .write(to: source.appendingPathComponent("manifest.json"))
        let archive = folder.appendingPathComponent("Radio Dramas.zip")
        try FileManager.default.zipItem(at: source, to: archive, shouldKeepParent: false)
        let archiveBytes = try Data(contentsOf: archive)
        var steps: [ImportStep] = []

        let imported = try FileImportService.importAudioZipWithReport(from: archive) { step, _ in
            steps.append(step)
        }
        importedPackages.append(imported.book.tmbDirectory)

        let audio = URL(fileURLWithPath: imported.book.filePath)
        XCTAssertEqual(imported.book.title, "Harbor Dramas")
        XCTAssertEqual(try AudioBookParser.trackPaths(in: audio).sorted(), ["elegy.m4a", "two.m4a"])
        XCTAssertTrue(ImportAudioConverter.oggFiles(in: audio).isEmpty)
        let manifest = AudioManifest.read(inAudioFolder: audio)?.manifest
        XCTAssertEqual(manifest?.order, ["two.m4a", "elegy.m4a"])
        XCTAssertEqual(manifest?.chapters, ["elegy.m4a": "The Elegy"])
        let loaded = try BookContentAnalysisService.load(book: imported.book)
        XCTAssertEqual(loaded.content.chapters.map(\.title), ["two", "The Elegy"])
        XCTAssertEqual(try Data(contentsOf: archive), archiveBytes)
        guard let manifestCheck = steps.firstIndex(of: .readingManifest),
              let firstCount = steps.firstIndex(of: .convertingImportedAudio(done: 0, of: 2)),
              let lastCount = steps.firstIndex(of: .convertingImportedAudio(done: 2, of: 2)),
              let reading = steps.firstIndex(of: .readingAudio) else {
            return XCTFail("Every step must be reported: \(steps)")
        }
        XCTAssertLessThan(manifestCheck, firstCount)
        XCTAssertLessThan(firstCount, lastCount)
        XCTAssertLessThan(lastCount, reading)
    }

    /// An Ogg track that can't be converted fails the import at Converting
    /// its audio, and nothing is published.
    func testATrackThatCannotConvertFailsTheImportAtItsStep() throws {
        try OggTestFixtures.skipUnlessOggDecodes()
        let source = folder.appendingPathComponent("Broken Dramas")
        try OggTestFixtures.copy(OggTestFixtures.vorbis, to: source, as: "01.ogg")
        try Data("not audio".utf8).write(to: source.appendingPathComponent("02.ogg"))
        let archive = folder.appendingPathComponent("Broken Dramas.zip")
        try FileManager.default.zipItem(at: source, to: archive, shouldKeepParent: false)

        do {
            let imported = try FileImportService.importAudioZipWithReport(from: archive)
            importedPackages.append(imported.book.tmbDirectory)
            XCTFail("An archive with a broken Ogg track must not import")
        } catch let failure as ImportFailure {
            XCTAssertEqual(failure.step.activity, "Converting its audio")
            XCTAssertEqual(failure.underlying as? ImportAudioConverter.Failure, .unreadable(fileName: "02.ogg"))
        }
    }

    // MARK: - A Folder and a File

    /// A folder of Ogg tracks imports as AAC, its manifest's tracks list
    /// renamed in the package, while the folder imported from keeps its Ogg
    /// files and its manifest as they were.
    func testAFolderOfOggTracksImportsAsAACAndTheFolderStaysAsItWas() throws {
        try OggTestFixtures.skipUnlessOggDecodes()
        let source = folder.appendingPathComponent("Harbor Plays")
        try OggTestFixtures.copy(OggTestFixtures.vorbis, to: source, as: "a.ogg")
        try OggTestFixtures.copy(OggTestFixtures.vorbis, to: source, as: "b.oga")
        let manifestJSON = Data(#"{"tracks": ["b.oga", "a.ogg"]}"#.utf8)
        try manifestJSON.write(to: source.appendingPathComponent("manifest.json"))

        let imported = try FileImportService.importAudioFolderWithReport(from: source)
        importedPackages.append(imported.book.tmbDirectory)

        let audio = URL(fileURLWithPath: imported.book.filePath)
        XCTAssertEqual(try AudioBookParser.trackPaths(in: audio).sorted(), ["a.m4a", "b.m4a"])
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: audio.appendingPathComponent("manifest.json")))
        XCTAssertEqual((written as? [String: Any])?["tracks"] as? [String], ["b.m4a", "a.m4a"])
        XCTAssertEqual(OggTestFixtures.names(in: source), ["a.ogg", "b.oga", "manifest.json"])
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("manifest.json")), manifestJSON)
    }

    /// A single Ogg file opened as a book imports as an .m4a file, which is
    /// the book's file; the file imported from is untouched, and the book is
    /// still known by that file's checksum, so importing it again finds the
    /// duplicate.
    func testASingleOggFileImportsAsAnM4AFile() throws {
        try OggTestFixtures.skipUnlessOggDecodes()
        let source = try OggTestFixtures.copy(OggTestFixtures.vorbis, to: folder, as: "Elegy.ogg")
        let sourceBytes = try Data(contentsOf: source)
        var steps: [ImportStep] = []

        let imported = try FileImportService.importFileWithReport(from: source) { step, _ in
            steps.append(step)
        }
        importedPackages.append(imported.book.tmbDirectory)

        XCTAssertEqual(URL(fileURLWithPath: imported.book.filePath).lastPathComponent, "Elegy.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.book.filePath))
        XCTAssertEqual(OggTestFixtures.names(in: URL(fileURLWithPath: imported.book.filePath).deletingLastPathComponent())
            .filter { ImportAudioConverter.isOgg(URL(fileURLWithPath: $0)) }, [])
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertEqual(imported.book.md5Hash, try FileImportService.md5Hash(of: source))
        XCTAssertTrue(steps.contains(.convertingImportedAudio(done: 1, of: 1)))
        let loaded = try BookContentAnalysisService.load(book: imported.book)
        XCTAssertEqual(loaded.content.chapters.count, 1)
    }
}

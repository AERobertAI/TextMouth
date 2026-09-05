import XCTest
import ZIPFoundation
@testable import TextMouth

/// Real media fixtures exercise archive discovery and the reader's directory
/// parser together, without starting audio playback or using personal files.
final class AudioDirectoryImportTests: XCTestCase {
    /// Completing an audiobook in loop mode must reload its audio backend,
    /// rather than passing the placeholder chapter's spaces to speech.
    @MainActor
    func testLoopRestartsTheAudioBackendAtTheBeginning() async throws {
        let packageName = "\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: "", tmbName: packageName)
        defer { try? FileManager.default.removeItem(at: package) }
        let source = package.appendingPathComponent("Track.wav")
        try writeSilence(to: source)
        var book = Book(
            title: "Looping Audio", format: .audio, filePath: source.path,
            md5Hash: UUID().uuidString, tmbDirectoryName: packageName
        )
        book.localEndOfBookBehavior = EndOfBookBehavior.loop.rawValue
        let library = LibraryViewModel()
        library.library = Library(books: [book])
        let reader = ReaderViewModel(
            book: book, libraryViewModel: library,
            settingsViewModel: SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        )
        let savedStats = reader.readingStatsService.stats
        defer {
            reader.close()
            reader.readingStatsService.stats = savedStats
            reader.readingStatsService.save()
        }
        reader.content = try await AudioBookParser.parse(url: source)
        reader.isLoading = false
        reader.currentCharacterOffset = 5

        reader.handleEndOfBook()

        XCTAssertTrue(reader.audioPlaybackService.isPlaying)
        XCTAssertFalse(reader.speechService.isSpeaking)
        XCTAssertTrue(reader.isCurrentlyPlaying)
        XCTAssertEqual(reader.currentChapterIndex, 0)
        XCTAssertEqual(reader.currentCharacterOffset, 0)
    }

    /// Finder wrapper folders are valid, while resource forks and links are not
    /// playable chapters. Numeric ordering also applies to disc directories.
    func testNestedFilesUseRelativeNaturalOrderAndIgnoreMetadata() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeSilence(to: directory.appendingPathComponent("Disc 10/Track.wav"))
        try writeSilence(to: directory.appendingPathComponent("Disc 2/Track.wav"))
        try writeSilence(to: directory.appendingPathComponent("__MACOSX/._Track.wav"))
        try writeSilence(to: directory.appendingPathComponent(".hidden.wav"))
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("link.wav"),
            withDestinationURL: directory.appendingPathComponent("Disc 2/Track.wav")
        )

        let parsed = try await AudioBookParser.parseDirectory(url: directory)

        XCTAssertEqual(parsed.filePaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       ["Disc 2/Track.wav", "Disc 10/Track.wav"].map {
                           directory.appendingPathComponent($0).resolvingSymlinksInPath().path
                       })
        XCTAssertEqual(parsed.content.chapters.count, 2)
        XCTAssertTrue(parsed.content.chapters.allSatisfy { !$0.text.isEmpty })
    }

    /// A repeated manifest entry must not repeat a chapter, and identical
    /// basenames in separate directories must not select the wrong disc.
    func testManifestOrdersRelativePathsOnceAndPreservesTitles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["Disc 1/Track.wav", "Disc 2/Track.wav", "Extra.wav"] {
            try writeSilence(to: directory.appendingPathComponent(name))
        }
        let manifest = AudioManifest(
            title: "Recorded Lectures", author: "Lecturer",
            chapters: ["Disc 2/Track.wav": "Second Disc"],
            order: ["Disc 2/Track.wav", "Disc 2/Track.wav", "Disc 1/Track.wav"], segments: nil
        )
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))

        let parsed = try await AudioBookParser.parseDirectory(url: directory)

        XCTAssertEqual(parsed.filePaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       ["Disc 2/Track.wav", "Disc 1/Track.wav", "Extra.wav"].map {
                           directory.appendingPathComponent($0).resolvingSymlinksInPath().path
                       })
        XCTAssertEqual(parsed.content.chapters.first?.title, "Second Disc")
    }

    /// Reject external paths and invalid clip timing before constructing a
    /// document or handing a manifest-provided path to AVFoundation.
    func testInvalidSegmentsAreRejected() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeSilence(to: directory.appendingPathComponent("Track.wav"))
        let invalidSegments = [
            AudioSegment(title: "Outside", file: "../Track.wav", startTime: 0, endTime: 1),
            AudioSegment(title: "Negative", file: "Track.wav", startTime: -1, endTime: 1),
            AudioSegment(title: "Reversed", file: "Track.wav", startTime: 2, endTime: 1)
        ]
        for segment in invalidSegments {
            let manifest = AudioManifest(segments: [segment])
            try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
            do {
                _ = try await AudioBookParser.parseDirectory(url: directory)
                XCTFail("Accepted invalid segment: \(segment.title)")
            } catch AudioParseError.invalidSegment {
                // This is the expected, actionable parser error.
            }
        }
    }

    /// Exercise the production ZIP importer and its persisted content index,
    /// including the wrapper directory produced by Finder's Compress command.
    func testWrappedAudioZIPImportsReadableChapters() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Lectures")
        try writeSilence(to: source.appendingPathComponent("Part 1.wav"))
        let archive = directory.appendingPathComponent("Lectures.zip")
        try FileManager.default.zipItem(at: source, to: archive, shouldKeepParent: true)

        let book = try FileImportService.importAudioZip(from: archive)
        defer { try? FileManager.default.removeItem(at: book.tmbDirectory) }
        let loaded = try BookContentAnalysisService.load(book: book)

        XCTAssertEqual(loaded.content.chapters.count, 1)
        XCTAssertTrue(loaded.audioFilePaths?.first?.hasSuffix("Lectures/Part 1.wav") == true)
        XCTAssertTrue(loaded.audioFilePaths?.allSatisfy { FileManager.default.fileExists(atPath: $0) } == true)
        XCTAssertTrue(loaded.usedPersistedIndex)
    }

    /// Every fixture lives under a unique temporary directory.
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Write a one-second mono PCM WAV. Real media avoids relying on a parser's
    /// fallback behavior for corrupt dummy files.
    private func writeSilence(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data("RIFF".utf8)
        appendLittleEndian(UInt32(36 + 16_000), to: &data)
        data.append(Data("WAVEfmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt32(8_000), to: &data)
        appendLittleEndian(UInt32(16_000), to: &data)
        appendLittleEndian(UInt16(2), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        appendLittleEndian(UInt32(16_000), to: &data)
        data.append(Data(count: 16_000))
        try data.write(to: url)
    }

    /// WAV header integers use little-endian byte order on every host.
    private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var encoded = value.littleEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }
}

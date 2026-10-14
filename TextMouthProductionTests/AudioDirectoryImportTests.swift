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
        try AudioTestFixtures.writeSilence(to: source)
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
        try AudioTestFixtures.writeSilence(to: directory.appendingPathComponent("Disc 10/Track.wav"))
        try AudioTestFixtures.writeSilence(to: directory.appendingPathComponent("Disc 2/Track.wav"))
        try AudioTestFixtures.writeSilence(to: directory.appendingPathComponent("__MACOSX/._Track.wav"))
        try AudioTestFixtures.writeSilence(to: directory.appendingPathComponent(".hidden.wav"))
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
            try AudioTestFixtures.writeSilence(to: directory.appendingPathComponent(name))
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
        try AudioTestFixtures.writeSilence(to: directory.appendingPathComponent("Track.wav"))
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
        try AudioTestFixtures.writeSilence(to: source.appendingPathComponent("Part 1.wav"))
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

    /// An archive of real Ogg tracks, one Vorbis and one Opus, imports as
    /// one audiobook with a heading for each track, each checked and
    /// measured by AVFoundation as every track is. The fixtures are
    /// two-second 440 Hz tones, made with ffmpeg 7.1:
    /// `ffmpeg -f lavfi -i "sine=frequency=440:duration=2:sample_rate=22050"
    /// -ac 1 -c:a libvorbis -q:a 0 ogg-vorbis-tone.ogg`, and the same at
    /// 48,000 Hz with `-c:a libopus -b:a 16k ogg-opus-tone.opus`.
    func testOggAudioZIPImportsOneChapterPerTrack() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.isOperatingSystemAtLeast(
                OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)
            ),
            "AVFoundation plays Ogg audio from macOS 15.4 on."
        )
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Radio Dramas")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: try requireFile("audio/ogg-vorbis-tone.ogg"), to: source.appendingPathComponent("elegy.ogg")
        )
        try FileManager.default.copyItem(
            at: try requireFile("audio/ogg-opus-tone.opus"), to: source.appendingPathComponent("two.opus")
        )
        let archive = directory.appendingPathComponent("Radio Dramas.zip")
        try FileManager.default.zipItem(at: source, to: archive, shouldKeepParent: false)

        XCTAssertTrue(LibraryViewModel.isAudioZip(url: archive))
        let book = try FileImportService.importAudioZip(from: archive)
        defer { try? FileManager.default.removeItem(at: book.tmbDirectory) }
        let loaded = try BookContentAnalysisService.load(book: book)

        XCTAssertEqual(book.format, .audio)
        XCTAssertEqual(loaded.content.chapters.map(\.title), ["elegy", "two"])
        XCTAssertEqual(loaded.audioFilePaths?.count, 2)
        // Each two-second tone holds about 20 placeholder characters, at
        // 10 a second, whatever its codec's priming adds.
        for chapter in loaded.content.chapters {
            XCTAssertTrue((19...21).contains(chapter.text.count), "\(chapter.title): \(chapter.text.count)")
        }
    }

    /// Every fixture lives under a unique temporary directory.
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

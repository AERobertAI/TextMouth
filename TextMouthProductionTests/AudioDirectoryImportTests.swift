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

    /// A book folder that is itself a symbolic link is read as the folder it
    /// leads to, once, with the links inside it still passed over: the scan
    /// found its tracks, and the book parses from the link as from the folder.
    /// A link that leads nowhere is still refused, not read as empty.
    func testABookFolderThatIsASymbolicLinkIsReadAsTheFolderItLeadsTo() async throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let real = base.appendingPathComponent("Real", isDirectory: true)
        for name in ["Disc 1/Track.wav", "Disc 2/Track.wav"] {
            try AudioTestFixtures.writeSilence(to: real.appendingPathComponent(name))
        }
        // A link inside the folder, which stays passed over.
        try FileManager.default.createSymbolicLink(
            at: real.appendingPathComponent("link.wav"),
            withDestinationURL: real.appendingPathComponent("Disc 1/Track.wav")
        )
        let link = base.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let expected = ["Disc 1/Track.wav", "Disc 2/Track.wav"]
        XCTAssertEqual(
            try AudioBookParser.trackPaths(in: real, scan: .importing), expected,
            "the folder itself reads wrong, so the fixture is not what this test thinks"
        )
        for scan in [AudioBookParser.TrackScan.importing, .package] {
            XCTAssertEqual(
                try AudioBookParser.trackPaths(in: link, scan: scan), expected,
                "the folder's tracks through its link, \(scan)"
            )
        }
        let parsed = try await AudioBookParser.parseDirectory(url: link)
        XCTAssertEqual(parsed.content.chapters.count, 2, "chapters of the book read through the link")
        XCTAssertEqual(
            parsed.filePaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            expected.map { real.appendingPathComponent($0).resolvingSymlinksInPath().path }
        )

        // A link to nothing is no folder: refused, as an unreadable folder is.
        let dangling = base.appendingPathComponent("Dangling")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: base.appendingPathComponent("Gone"))
        XCTAssertThrowsError(try AudioBookParser.audioFiles(in: dangling), "a link to nothing was read")
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
    /// one audiobook with a heading for each track, each converted to AAC,
    /// checked, and measured by AVFoundation as every track is. The fixtures are
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
        // The tracks were converted to AAC as they were imported (B06), so
        // nothing hands Ogg audio to a player.
        XCTAssertEqual(
            loaded.audioFilePaths?.map { URL(fileURLWithPath: $0).lastPathComponent },
            ["elegy.m4a", "two.m4a"]
        )
        // Each two-second tone holds about 20 placeholder characters, at
        // 10 a second, whatever its codec's priming adds.
        for chapter in loaded.content.chapters {
            XCTAssertTrue((19...21).contains(chapter.text.count), "\(chapter.title): \(chapter.text.count)")
        }
    }

    // MARK: - Where the Archive Keeps Its Manifest

    /// Finder's Compress command puts a folder's contents under the
    /// folder's name, so a manifest made beside the tracks lands inside
    /// that folder. The import finds it there, and the book takes its
    /// title, author, order, and titles, the manifest naming each track
    /// from the folder that holds it; a track it leaves out follows.
    func testManifestInsideTheArchivesOneFolderArrangesTheBook() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Radio Plays")
        for name in ["a.wav", "b.wav", "c.wav"] {
            try AudioTestFixtures.writeSilence(to: source.appendingPathComponent(name))
        }
        try writeManifest(
            #"{"title": "Harbor Plays", "author": "Wenzel Okafor", "order": ["c.wav", "a.wav"], "chapters": {"c.wav": "Ninth Floor"}}"#,
            in: source
        )
        let archive = directory.appendingPathComponent("Radio Plays.zip")
        try FileManager.default.zipItem(at: source, to: archive, shouldKeepParent: true)

        let book = try FileImportService.importAudioZip(from: archive)
        defer { try? FileManager.default.removeItem(at: book.tmbDirectory) }
        let loaded = try BookContentAnalysisService.load(book: book)

        XCTAssertEqual(book.title, "Harbor Plays")
        XCTAssertEqual(book.author, "Wenzel Okafor")
        XCTAssertEqual(loaded.content.chapters.map(\.title), ["Ninth Floor", "a", "b"])
        XCTAssertEqual(
            loaded.audioFilePaths?.map { URL(fileURLWithPath: $0).pathComponents.suffix(2).joined(separator: "/") },
            ["Radio Plays/c.wav", "Radio Plays/a.wav", "Radio Plays/b.wav"]
        )
    }

    /// A manifest at the archive's top level arranges the book as it always
    /// has, naming a track in a folder by the folder too.
    func testManifestAtTheArchivesTopLevelStillArrangesTheBook() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Harbor Plays")
        for name in ["Disc 1/01.wav", "Disc 1/02.wav"] {
            try AudioTestFixtures.writeSilence(to: source.appendingPathComponent(name))
        }
        try writeManifest(
            #"{"title": "Harbor Plays", "order": ["Disc 1/02.wav"], "chapters": {"Disc 1/02.wav": "Ninth Floor"}}"#,
            in: source
        )
        let archive = directory.appendingPathComponent("Harbor Plays.zip")
        try FileManager.default.zipItem(at: source, to: archive, shouldKeepParent: false)

        let book = try FileImportService.importAudioZip(from: archive)
        defer { try? FileManager.default.removeItem(at: book.tmbDirectory) }
        let loaded = try BookContentAnalysisService.load(book: book)

        XCTAssertEqual(book.title, "Harbor Plays")
        XCTAssertEqual(loaded.content.chapters.map(\.title), ["Ninth Floor", "01"])
    }

    /// Two folders at the archive's top level are no wrapper: a manifest
    /// inside one of them is not read, and the book is named by its archive
    /// and its tracks by their files, in Finder's order.
    func testManifestInsideOneOfTwoFoldersIsNotRead() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Two Parts")
        try AudioTestFixtures.writeSilence(to: source.appendingPathComponent("Part One/a.wav"))
        try AudioTestFixtures.writeSilence(to: source.appendingPathComponent("Part Two/b.wav"))
        try writeManifest(
            #"{"title": "Not This Title", "chapters": {"a.wav": "Not This Heading"}}"#,
            in: source.appendingPathComponent("Part One")
        )
        let archive = directory.appendingPathComponent("Two Parts.zip")
        try FileManager.default.zipItem(at: source, to: archive, shouldKeepParent: false)

        let book = try FileImportService.importAudioZip(from: archive)
        defer { try? FileManager.default.removeItem(at: book.tmbDirectory) }
        let loaded = try BookContentAnalysisService.load(book: book)

        XCTAssertEqual(book.title, "Two Parts")
        XCTAssertEqual(loaded.content.chapters.map(\.title), ["a", "b"])
    }

    /// An archive Finder compressed, its tracks and a manifest with a tracks
    /// list in one folder, imports arranged by the list, and opens from the
    /// index the import saved with both headings of each group's first
    /// track, the group's first.
    func testTracksListInTheArchivesOneFolderArrangesTheSavedBook() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Radio Dramas")
        for name in ["where_is_everybody.wav", "one_for_the_angels.wav", "mr_denton_on_dooms_day.wav", "king_nine_will_not_return.wav"] {
            try AudioTestFixtures.writeSilence(to: source.appendingPathComponent(name))
        }
        try writeManifest(AudioManifestTests.exampleJSON.replacingOccurrences(of: ".ogg", with: ".wav"), in: source)
        let archive = directory.appendingPathComponent("Radio Dramas.zip")
        try FileManager.default.zipItem(at: source, to: archive, shouldKeepParent: true)

        let book = try FileImportService.importAudioZip(from: archive)
        defer { try? FileManager.default.removeItem(at: book.tmbDirectory) }
        let loaded = try BookContentAnalysisService.load(book: book)

        XCTAssertTrue(loaded.usedPersistedIndex)
        XCTAssertEqual(book.title, "Radio Dramas")
        XCTAssertEqual(book.author, "Various")
        XCTAssertEqual(loaded.content.allHeadings.map { "\($0.level) \($0.text) @\($0.chapterIndex)" }, [
            "1 Season One @0", "2 Where Is Everybody? @0", "2 One for the Angels @1",
            "2 mr_denton_on_dooms_day @2", "1 Season Two @3", "2 king_nine_will_not_return @3"
        ])
    }

    /// The sections of a manifest inside the one folder name their files
    /// from that folder too, and play from inside it.
    func testSectionsOfAManifestInsideTheOneFolderNameFilesFromIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Lectures")
        try AudioTestFixtures.writeSilence(to: source.appendingPathComponent("a.wav"), duration: 2)
        try JSONEncoder().encode(AudioManifest(segments: [
            AudioSegment(title: "Opening", file: "a.wav", startTime: 0, endTime: 1),
            AudioSegment(title: "Closing", file: "a.wav", startTime: 1, endTime: 0)
        ])).write(to: source.appendingPathComponent("manifest.json"))

        let parsed = try await AudioBookParser.parseDirectory(url: directory)

        XCTAssertEqual(parsed.content.chapters.map(\.title), ["Opening", "Closing"])
        XCTAssertEqual(parsed.segments?.map(\.file), ["Lectures/a.wav", "Lectures/a.wav"])
    }

    // MARK: - Free Space

    /// A folder of tracks is checked against the disk's free space before
    /// any track is copied, as an archive is: with less free than the
    /// tracks need plus the reserve the import keeps, the import is refused
    /// in the words of a full disk, nothing is left in the library, and the
    /// folder is untouched; with room, the same folder imports. Both the
    /// tracks' size alone and the reserve alone are enough to refuse.
    func testAFolderOfTracksIsRefusedBeforeCopyingWhenTheDiskLacksRoom() throws {
        let sandbox = try LibraryIndexSandbox.capture()
        let libraryFolder = "Audio Space \(UUID().uuidString.prefix(8))"
        addTeardownBlock {
            sandbox.restore()
            try? FileManager.default.removeItem(at: TextMouthPaths.libraryDir.appendingPathComponent(libraryFolder, isDirectory: true))
        }
        let directory = temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Two Tracks")
        try AudioTestFixtures.writeSilence(to: source.appendingPathComponent("one.wav"), duration: 1)
        try AudioTestFixtures.writeSilence(to: source.appendingPathComponent("two.wav"), duration: 1)
        let trackBytes = try ["one.wav", "two.wav"].reduce(Int64(0)) { total, name in
            total + Int64(try XCTUnwrap(source.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize))
        }
        let before = try Set(FileManager.default.contentsOfDirectory(atPath: source.path))
        let refusal = "Copying it into the library failed: There isn’t enough free space on the disk."

        // Less free than the tracks need, no reserve; then exactly the
        // tracks' size free but a reserve to keep.
        let tooLittle = Self.limits(reserve: 0, freeSpace: trackBytes - 1)
        let reserveEatsIt = Self.limits(reserve: 1, freeSpace: trackBytes)
        for (label, limits) in [("tracks alone", tooLittle), ("reserve", reserveEatsIt)] {
            XCTAssertThrowsError(
                try ArchiveLimits.$current.withValue(limits) {
                    try FileImportService.importAudioFolderWithReport(from: source, toFolder: libraryFolder)
                },
                label
            ) { error in
                let failure = error as? ImportFailure
                XCTAssertEqual(failure?.step, .copying, label)
                XCTAssertEqual(failure?.reason, refusal, label)
            }
            let entries = (try? FileManager.default.contentsOfDirectory(
                atPath: TextMouthPaths.libraryDir.appendingPathComponent(libraryFolder).path
            )) ?? []
            XCTAssertEqual(entries, [], "\(label): nothing may stay staged or published")
            XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: source.path)), before, label)
        }

        // Room for the tracks and the reserve: the same folder imports.
        let roomy = Self.limits(reserve: 1, freeSpace: trackBytes + 1)
        let imported = try ArchiveLimits.$current.withValue(roomy) {
            try FileImportService.importAudioFolderWithReport(from: source, toFolder: libraryFolder)
        }
        XCTAssertEqual(imported.book.format, .audio)
    }

    /// Limits that change nothing but the disk: the standard ones, with
    /// `reserve` bytes to keep and `freeSpace` bytes free on every disk.
    static func limits(reserve: Int64, freeSpace: Int64) -> ArchiveLimits {
        var limits = ArchiveLimits.standard
        limits.freeSpaceReserve = reserve
        limits.freeSpace = { _ in freeSpace }
        return limits
    }

    /// Every fixture lives under a unique temporary directory.
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Write `json`, exactly as given, as the manifest.json in `folder`.
    private func writeManifest(_ json: String, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: folder.appendingPathComponent("manifest.json"))
    }
}

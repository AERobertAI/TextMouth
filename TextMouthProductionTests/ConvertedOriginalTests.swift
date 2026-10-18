import XCTest
@testable import TextMouth

/// The setting that keeps the original of audio an import converts (FMT14):
/// the setting, its words, and (further down) what an import does with it.
/// Every file these tests touch lives in a folder of their own.
@MainActor
final class ConvertedOriginalTests: XCTestCase {
    // MARK: - The setting

    /// A fresh configuration keeps no originals: only imports made while the
    /// user has turned the setting on keep anything.
    func testTheSettingIsOffByDefault() {
        XCTAssertFalse(ConfigService.AppConfig().keepsOriginalOfConvertedAudio)
    }

    /// The setting is written to config.json under its own name and read back.
    func testTheSettingRoundTripsThroughTheConfigFile() throws {
        var config = ConfigService.AppConfig()
        config.keepsOriginalOfConvertedAudio = true

        let data = try ConfigService.fileData(for: config)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["keepsOriginalOfConvertedAudio"] as? Bool, true)

        let decoded = try JSONDecoder().decode(ConfigService.AppConfig.self, from: data)
        XCTAssertTrue(decoded.keepsOriginalOfConvertedAudio)
    }

    /// A config.json written before the setting existed reads as off.
    func testAFileWithoutTheKeyReadsAsOff() throws {
        let decoded = try JSONDecoder().decode(
            ConfigService.AppConfig.self,
            from: Data(#"{"wordsPerMinute": 200}"#.utf8)
        )
        XCTAssertFalse(decoded.keepsOriginalOfConvertedAudio)
    }

    /// A wrongly typed value falls back to off instead of failing the file.
    func testAWronglyTypedValueReadsAsOff() throws {
        let decoded = try JSONDecoder().decode(
            ConfigService.AppConfig.self,
            from: Data(#"{"keepsOriginalOfConvertedAudio": "yes"}"#.utf8)
        )
        XCTAssertFalse(decoded.keepsOriginalOfConvertedAudio)
    }

    /// The settings model reads and saves the setting through config.json,
    /// and announces a change made to the file itself, so the control always
    /// shows the choice in force.
    func testTheSettingsModelSavesAndAnnouncesTheSetting() throws {
        let model = try makeIsolatedSettings("keeporig-settings")
        XCTAssertFalse(model.keepsOriginalOfConvertedAudio)

        model.keepsOriginalOfConvertedAudio = true
        XCTAssertTrue(model.keepsOriginalOfConvertedAudio)

        // A change made to the configuration itself reaches the model's
        // subscribers (the control redraws from it).
        var announced = 0
        let subscription = model.objectWillChange.sink { announced += 1 }
        defer { subscription.cancel() }
        model.keepsOriginalOfConvertedAudio = false
        XCTAssertFalse(model.keepsOriginalOfConvertedAudio)
        XCTAssertGreaterThan(announced, 0)
    }

    // MARK: - The words

    /// The control's label, hint, and both captions, word for word.
    func testTheWordsAreAsAgreed() {
        XCTAssertEqual(ConvertedOriginalWording.label, "Keep originals of converted audio")
        XCTAssertEqual(
            ConvertedOriginalWording.hint,
            "Also keeps each audio file that an import converts, such as Ogg or AC-3, inside the book's package."
        )
        XCTAssertEqual(
            ConvertedOriginalWording.caption(keeping: true),
            "Audio that TextMouth converts at import keeps its original file too, which takes about as much disk "
                + "space again. Export offers it as the Original file. Feed episodes are not kept: they can be "
                + "downloaded again."
        )
        XCTAssertEqual(
            ConvertedOriginalWording.caption(keeping: false),
            "Audio that TextMouth converts at import keeps only the converted file."
        )
    }

    // MARK: - Keeping and listing the originals (no decoding)

    /// A conversion record for `source`, which names a stand-in for a
    /// converted file: `keepSources` only moves the source.
    private func conversion(of source: URL) -> ImportAudioConverter.Conversion {
        ImportAudioConverter.Conversion(
            source: source,
            converted: source.deletingPathExtension().appendingPathExtension("m4a"),
            duration: 1,
            secondsTaken: 0.1,
            bytesBefore: 1,
            bytesAfter: 1,
            bitRate: nil
        )
    }

    /// Each source moves under its path from the base, the folders are made,
    /// nothing is left where the source was, and the files come back in
    /// Finder's order by their paths ("2" before "10").
    func testKeepSourcesMovesEachSourceUnderItsPathFromTheBase() throws {
        let package = try makeTestDirectory("keeporig-keep")
        let base = package.appendingPathComponent("audio", isDirectory: true)
        let names = ["Disc 1/10.ogg", "Disc 1/2.ogg", "cover-less.ogg"]
        var conversions: [ImportAudioConverter.Conversion] = []
        for name in names {
            let source = base.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: source.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(name.utf8).write(to: source)
            conversions.append(conversion(of: source))
        }

        try ImportAudioConverter.keepSources(of: conversions, from: base, inPackage: package)

        let kept = package.appendingPathComponent(".convertedOriginals", isDirectory: true)
        XCTAssertEqual(ImportAudioConverter.keptOriginalsFolderName, ".convertedOriginals")
        XCTAssertEqual(
            ImportAudioConverter.keptOriginals(inPackage: package).map { AudioBookParser.relativeName(of: $0, in: kept) },
            ["cover-less.ogg", "Disc 1/2.ogg", "Disc 1/10.ogg"]
        )
        for name in names {
            XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent(name).path), name)
            XCTAssertEqual(try Data(contentsOf: kept.appendingPathComponent(name)), Data(name.utf8))
        }
    }

    /// A package that kept nothing lists nothing.
    func testAPackageWithoutTheFolderKeptNothing() throws {
        let package = try makeTestDirectory("keeporig-none")
        XCTAssertEqual(ImportAudioConverter.keptOriginals(inPackage: package), [])
    }

    /// A source that cannot be kept (a file is already kept under that path)
    /// throws, so the import fails at its step instead of losing the file.
    func testKeepSourcesThrowsWhenTheFileCannotBeMoved() throws {
        let package = try makeTestDirectory("keeporig-clash")
        let source = package.appendingPathComponent("a.ogg")
        try Data("new".utf8).write(to: source)
        let kept = package.appendingPathComponent(".convertedOriginals/a.ogg")
        try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: kept)

        XCTAssertThrowsError(
            try ImportAudioConverter.keepSources(of: [conversion(of: source)], from: package, inPackage: package)
        )
        XCTAssertEqual(try Data(contentsOf: source), Data("new".utf8), "the source stays where it was")
    }

    /// The setting is read through the main thread from an import's own
    /// thread, and a feed episode never keeps an original.
    func testTheSettingIsReadFromAnotherThreadAndNeverForAFeedEpisode() {
        setKeepsOriginals(true)
        XCTAssertTrue(FileImportService.keepsOriginalsOfConvertedAudio(feedLink: nil))
        XCTAssertFalse(FileImportService.keepsOriginalsOfConvertedAudio(
            feedLink: FeedBookLink(feedID: UUID(), itemID: "guid:one")
        ))

        // The main thread waits in the expectation's run loop, which lets
        // the other thread's hop to the main thread through.
        let read = expectation(description: "read from another thread")
        read.assertForOverFulfill = false
        var fromOtherThread: Bool?
        DispatchQueue.global().async {
            let value = FileImportService.keepsOriginalsOfConvertedAudio(feedLink: nil)
            Task { @MainActor in
                fromOtherThread = value
                read.fulfill()
            }
        }
        wait(for: [read], timeout: 10)
        XCTAssertEqual(fromOtherThread, true)

        setKeepsOriginals(false)
        XCTAssertFalse(FileImportService.keepsOriginalsOfConvertedAudio(feedLink: nil))
    }

    // MARK: - What an import keeps

    /// The setting is changed for one test and put back when it ends.
    private func setKeepsOriginals(_ keeps: Bool) {
        let service = ConfigService.shared
        let previous = service.config.keepsOriginalOfConvertedAudio
        service.config.keepsOriginalOfConvertedAudio = keeps
        addTeardownBlock { @MainActor in service.config.keepsOriginalOfConvertedAudio = previous }
    }

    /// A folder of the test's own for what it imports from, and the
    /// packages it imports are removed when the test ends.
    private func makeSourceFolder() throws -> URL {
        let source = try AudioTestFixtures.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: source) }
        return source
    }

    /// Removes `package` when the test ends.
    private func removeAtEnd(_ package: URL) {
        addTeardownBlock { try? FileManager.default.removeItem(at: package) }
    }

    /// With the setting on, a single .ogg file's package keeps the file
    /// under its own name, byte for byte, beside the .m4a that is the book's
    /// file; the file imported from is untouched.
    func testASingleOggFileKeepsItsOriginalWhenTheSettingIsOn() throws {
        try OggTestFixtures.skipUnlessOggDecodes()
        setKeepsOriginals(true)
        let folder = try makeSourceFolder()
        let source = try OggTestFixtures.copy(OggTestFixtures.vorbis, to: folder, as: "Elegy.ogg")
        let sourceBytes = try Data(contentsOf: source)

        let imported = try FileImportService.importFileWithReport(from: source)
        removeAtEnd(imported.book.tmbDirectory)

        let kept = imported.book.tmbDirectory.appendingPathComponent(".convertedOriginals/Elegy.ogg")
        XCTAssertEqual(try Data(contentsOf: kept), sourceBytes)
        XCTAssertEqual(URL(fileURLWithPath: imported.book.filePath).lastPathComponent, "Elegy.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.book.filePath))
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertEqual(ImportAudioConverter.keptOriginals(inPackage: imported.book.tmbDirectory).map(\.lastPathComponent), ["Elegy.ogg"])
        // Nothing but the converted file is the book's: the original is in
        // no listing, so the book reads as one chapter.
        XCTAssertEqual(try BookContentAnalysisService.load(book: imported.book).content.chapters.count, 1)
        XCTAssertEqual(
            try FileImportService.retainedContentURL(in: imported.book.tmbDirectory).lastPathComponent,
            "Elegy.m4a"
        )
    }

    /// With the setting on, a folder of an .ogg and a track that is not
    /// converted keeps only the .ogg, and the kept original is in none of the
    /// listings that find a book's files.
    func testAFolderKeepsOnlyTheOriginalsOfWhatItConvertedAndNoListingShowsThem() throws {
        try OggTestFixtures.skipUnlessOggDecodes()
        setKeepsOriginals(true)
        let source = try makeSourceFolder().appendingPathComponent("Harbor Plays", isDirectory: true)
        try OggTestFixtures.copy(OggTestFixtures.vorbis, to: source, as: "01.ogg")
        try AudioTestFixtures.writeAACSilence(to: source.appendingPathComponent("02.m4a"))
        try Data(#"{"tracks": ["01.ogg", "02.m4a"]}"#.utf8).write(to: source.appendingPathComponent("manifest.json"))

        let imported = try FileImportService.importAudioFolderWithReport(from: source)
        let package = imported.book.tmbDirectory
        removeAtEnd(package)

        // Only the converted track's original, under its path in the folder.
        XCTAssertEqual(
            ImportAudioConverter.keptOriginals(inPackage: package).map(\.lastPathComponent),
            ["01.ogg"]
        )
        XCTAssertEqual(OggTestFixtures.names(in: source), ["01.ogg", "02.m4a", "manifest.json"], "the folder imported from is untouched")

        // Every listing of a book's files passes the hidden folder by.
        let audio = URL(fileURLWithPath: imported.book.filePath)
        XCTAssertEqual(try AudioBookParser.trackPaths(in: audio), ["01.m4a", "02.m4a"])
        XCTAssertEqual(try AudioBookParser.trackPaths(in: package), ["audio/01.m4a", "audio/02.m4a"])
        XCTAssertEqual(
            try AudioBookParser.audioFiles(in: package).map(\.lastPathComponent),
            ["01.m4a", "02.m4a"]
        )
        XCTAssertEqual(try FileImportService.retainedContentURL(in: package).lastPathComponent, "audio")
        XCTAssertFalse(FileImportService.isPackageContentName(ImportAudioConverter.keptOriginalsFolderName))
        XCTAssertEqual(AudioManifestLocation.find(in: audio)?.url.lastPathComponent, "manifest.json")
        XCTAssertNil(AudioManifestLocation.find(in: package), "the package's own files are not a folder of tracks")
        XCTAssertEqual(try BookContentAnalysisService.load(book: imported.book).content.chapters.count, 2)
        XCTAssertEqual(ImportAudioConverter.oggFiles(in: package), [])
        XCTAssertEqual(ImportAudioConverter.filesToConvert(in: package), [])
    }

    /// A hidden folder beside a wrapper folder does not stop the manifest
    /// inside the wrapper from being found (the folder's one folder).
    func testTheKeptFolderDoesNotHideAWrapperFoldersManifest() throws {
        let folder = try makeTestDirectory("keeporig-wrapper")
        let wrapper = folder.appendingPathComponent("Radio Dramas", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: true)
        try Data(#"{"tracks": []}"#.utf8).write(to: wrapper.appendingPathComponent("manifest.json"))
        let kept = folder.appendingPathComponent(".convertedOriginals", isDirectory: true)
        try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: kept.appendingPathComponent("manifest.json"))
        try Data("x".utf8).write(to: kept.appendingPathComponent("01.ogg"))

        let location = AudioManifestLocation.find(in: folder)
        XCTAssertEqual(location?.prefix, "Radio Dramas/")
        XCTAssertEqual(location?.url.deletingLastPathComponent().lastPathComponent, "Radio Dramas")
    }

    /// With the setting off, as it is by default, the package keeps no
    /// folder of originals.
    func testNothingIsKeptWhenTheSettingIsOff() throws {
        try OggTestFixtures.skipUnlessOggDecodes()
        setKeepsOriginals(false)
        let folder = try makeSourceFolder()
        let source = try OggTestFixtures.copy(OggTestFixtures.vorbis, to: folder, as: "Elegy.ogg")

        let imported = try FileImportService.importFileWithReport(from: source)
        removeAtEnd(imported.book.tmbDirectory)

        XCTAssertFalse(OggTestFixtures.names(in: imported.book.tmbDirectory).contains(".convertedOriginals"))
        XCTAssertEqual(ImportAudioConverter.keptOriginals(inPackage: imported.book.tmbDirectory), [])
    }

    /// A feed episode keeps no original, even with the setting on: it can be
    /// downloaded again. The import goes through `publishReadableBook` with
    /// the episode's `FeedBookLink`, as every feed download does.
    func testAFeedEpisodeKeepsNoOriginalEvenWhenTheSettingIsOn() throws {
        try OggTestFixtures.skipUnlessOggDecodes()
        setKeepsOriginals(true)
        let feed = Feed(
            feedURL: try XCTUnwrap(URL(string: "https://example.com/harbour-radio.xml")),
            folderID: UUID(),
            subscribedDate: Date(timeIntervalSince1970: 1_790_000_000)
        )
        let item = FeedItem(
            id: "episode-3",
            title: "Episode 3: The Tide Table",
            firstSeen: Date(timeIntervalSince1970: 1_790_000_000),
            author: "Harbour Radio"
        )
        let download = try OggTestFixtures.copy(OggTestFixtures.vorbis, to: try makeSourceFolder(), as: "download.ogg")
        addTeardownBlock { try? FileManager.default.removeItem(at: FeedPaths.itemsFolder(of: feed.id, in: TextMouthPaths.root)) }

        let imported = try FeedEpisodeImporter.importEpisode(
            download,
            named: "Episode 3.ogg",
            item: item,
            of: feed,
            dateAdded: Date()
        )

        XCTAssertEqual(URL(fileURLWithPath: imported.book.filePath).pathExtension, "m4a", "it was converted")
        XCTAssertFalse(OggTestFixtures.names(in: imported.book.tmbDirectory).contains(".convertedOriginals"))
    }

    /// Deleting a book deletes its package, and the kept original with it.
    func testDeletingABookDeletesItsKeptOriginalWithThePackage() throws {
        try OggTestFixtures.skipUnlessOggDecodes()
        setKeepsOriginals(true)
        // A permanent deletion: the test must not fill the user's Trash.
        let service = ConfigService.shared
        let previousTrash = service.config.moveToTrashInsteadOfDeleting
        service.config.moveToTrashInsteadOfDeleting = false
        addTeardownBlock { @MainActor in service.config.moveToTrashInsteadOfDeleting = previousTrash }
        let source = try OggTestFixtures.copy(OggTestFixtures.vorbis, to: try makeSourceFolder(), as: "Elegy.ogg")
        let imported = try FileImportService.importFileWithReport(from: source)
        removeAtEnd(imported.book.tmbDirectory)
        let kept = imported.book.tmbDirectory.appendingPathComponent(".convertedOriginals/Elegy.ogg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))

        try FileImportService.deleteBookPackage(imported.book)

        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.book.tmbDirectory.path))
    }
}

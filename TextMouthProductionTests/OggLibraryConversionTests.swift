import XCTest
@testable import TextMouth

/// The books already in the library have their Ogg audio converted to AAC
/// once (B06, item 3), each committed on its own with its places kept, while
/// their readers refuse to play them; and nothing hands Ogg to a player any
/// more (item 4). No test here plays anything: the Ogg fixtures are only
/// decoded offline, and a reader is only asked whether it may play.
@MainActor
final class OggLibraryConversionTests: XCTestCase {
    // MARK: - The Library's Books, Once

    /// The first launch converts a book of Ogg tracks: its tracks become
    /// .m4a files, renamed in its manifest and its record, its order, titles,
    /// and reading position unchanged, and the Ogg files and any hidden
    /// files gone. A second launch makes no pass.
    func testTheLaunchConvertsABookOfOggTracksOnceKeepingItsPlaces() async throws {
        try OggTestFixtures.skipUnlessOggDecodes()
        let world = try makeIntegrationWorld("Ogg Library Tracks")
        let book = try makeOggBook(
            in: world,
            title: "Harbor Dramas",
            tracks: ["01.ogg": OggTestFixtures.vorbis, "02.opus": OggTestFixtures.opus],
            manifest: #"{"order": ["02.opus", "01.ogg"], "chapters": {"01.ogg": "Opening"}}"#
        )
        world.library.updateBook(id: book.id) { row in
            row.readingPosition = ReadingPosition(chapterIndex: 1, characterOffset: 5)
        }
        let preferences = makeSandboxedPreferences("Ogg Library Tracks")

        let first = await convertOnce(world, preferences: preferences)

        XCTAssertEqual(first, LibraryViewModel.OggConversionOutcome(converted: 1, waiting: 0))
        let folder = URL(fileURLWithPath: book.filePath)
        XCTAssertEqual(OggTestFixtures.names(in: folder), ["01.m4a", "02.m4a", "manifest.json"])
        let manifest = AudioManifest.read(inAudioFolder: folder)?.manifest
        XCTAssertEqual(manifest?.order, ["02.m4a", "01.m4a"])
        XCTAssertEqual(manifest?.chapters, ["01.m4a": "Opening"])
        guard let row = world.library.bookByID(book.id) else { return XCTFail("The book left the library") }
        XCTAssertEqual(row.readingPosition?.chapterIndex, 1)
        XCTAssertEqual(row.readingPosition?.characterOffset, 5)
        let loaded = try BookContentAnalysisService.load(book: row)
        XCTAssertTrue(loaded.usedPersistedIndex, "The record must name the converted tracks")
        XCTAssertEqual(loaded.content.chapters.map(\.title), ["02", "Opening"])
        XCTAssertEqual(loaded.audioFilePaths?.map { URL(fileURLWithPath: $0).lastPathComponent }, ["02.m4a", "01.m4a"])
        XCTAssertFalse(world.library.oggConversion.isConverting(book.id))

        let second = await convertOnce(world, preferences: preferences)
        XCTAssertNil(second, "The one-time conversion was made again")
    }

    /// A book of one Ogg file takes its .m4a as its file, in its row and
    /// its record, and the Ogg file is deleted.
    func testABookOfOneOggFileTakesItsM4AFile() async throws {
        try OggTestFixtures.skipUnlessOggDecodes()
        let world = try makeIntegrationWorld("Ogg Library File")
        let book = try makeOggBook(in: world, title: "Elegy", file: ("Elegy.ogg", OggTestFixtures.vorbis))

        let outcome = await convertOnce(world, preferences: makeSandboxedPreferences("Ogg Library File"))

        XCTAssertEqual(outcome, LibraryViewModel.OggConversionOutcome(converted: 1, waiting: 0))
        guard let row = world.library.bookByID(book.id) else { return XCTFail("The book left the library") }
        XCTAssertEqual(URL(fileURLWithPath: row.filePath).lastPathComponent, "Elegy.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: row.filePath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.filePath))
        XCTAssertEqual(row.md5Hash, book.md5Hash, "The book stays known by the file it was imported from")
        XCTAssertEqual(try BookContentAnalysisService.load(book: row).content.chapters.count, 1)
    }

    /// A book whose files are only in the cloud is left as it was, nothing
    /// downloaded, and the pass is made again at the next launch.
    func testABookOnlyInTheCloudWaitsAndThePassIsMadeAgain() async throws {
        try OggTestFixtures.skipUnlessOggDecodes()
        let world = try makeIntegrationWorld("Ogg Library Cloud")
        let book = try makeOggBook(in: world, title: "Far Away", tracks: ["01.ogg": OggTestFixtures.vorbis], manifest: nil)
        let preferences = makeSandboxedPreferences("Ogg Library Cloud")
        let inCloud = MaintenanceFileAccess(isDataless: { _ in true })

        let first = await convertOnce(world, preferences: preferences, access: inCloud)

        XCTAssertEqual(first, LibraryViewModel.OggConversionOutcome(converted: 0, waiting: 1))
        XCTAssertEqual(OggTestFixtures.names(in: URL(fileURLWithPath: book.filePath)), ["01.ogg"])
        let again = await convertOnce(world, preferences: preferences)
        XCTAssertEqual(again, LibraryViewModel.OggConversionOutcome(converted: 1, waiting: 0))
    }

    /// A track that can't be converted leaves the book exactly as it was:
    /// its Ogg files, its manifest, and nothing hidden left behind.
    func testAConversionThatFailsLeavesTheBookAsItWas() async throws {
        try OggTestFixtures.skipUnlessOggDecodes()
        let world = try makeIntegrationWorld("Ogg Library Failure")
        let manifestJSON = #"{"order": ["02.ogg", "01.ogg"]}"#
        let book = try makeOggBook(
            in: world,
            title: "Broken Dramas",
            tracks: ["01.ogg": OggTestFixtures.vorbis, "02.ogg": OggTestFixtures.vorbis],
            manifest: manifestJSON
        )
        let folder = URL(fileURLWithPath: book.filePath)
        try Data("no longer audio".utf8).write(to: folder.appendingPathComponent("02.ogg"))

        let result = await world.library.convertImportedAudio(ofBook: book.id)

        XCTAssertEqual(result, .waiting(.failed("The Ogg audio file 02.ogg could not be read for converting to AAC.")))
        XCTAssertEqual(OggTestFixtures.names(in: folder), ["01.ogg", "02.ogg", "manifest.json"])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("manifest.json"), encoding: .utf8), manifestJSON)
    }

    /// A book whose conversion failed is not tried again before the next
    /// launch: a request for it starts nothing, and its reader says when
    /// it will be tried again.
    func testABookThatFailedIsNotTriedAgainBeforeTheNextLaunch() async throws {
        try OggTestFixtures.skipUnlessOggDecodes()
        let world = try makeIntegrationWorld("Ogg Library Failed Once")
        let book = try makeOggBook(
            in: world,
            title: "Stubborn Dramas",
            tracks: ["01.ogg": OggTestFixtures.vorbis],
            manifest: nil
        )
        let folder = URL(fileURLWithPath: book.filePath)
        try Data("no longer audio".utf8).write(to: folder.appendingPathComponent("01.ogg"))
        let reader = world.openReader(for: book)
        let loaded = await eventually { reader.content != nil }
        XCTAssertTrue(loaded, "The reader never loaded its book")

        guard case .waiting(.failed) = await world.library.convertImportedAudio(ofBook: book.id) else {
            return XCTFail("The conversion must fail")
        }
        world.library.requestOggConversion(ofBook: book.id)

        XCTAssertTrue(world.library.oggConversion.hasFailed(book.id))
        XCTAssertFalse(world.library.oggConversion.isConverting(book.id), "A failed book must not be queued again")
        XCTAssertFalse(reader.chapterAudioIsClearOfOgg())
        XCTAssertEqual(
            reader.errorMessage,
            "This book's audio could not be converted from Ogg to AAC. TextMouth tries again the next time it starts."
        )
        XCTAssertFalse(world.library.oggConversion.isConverting(book.id))
    }

    // MARK: - While a Book Converts

    /// The overlay says how far the book under way has got, counting its
    /// tracks; a late count changes nothing, and the book counts as
    /// converting until it ends.
    func testTheOverlaySaysHowFarTheBookHasGot() {
        let progress = OggConversionProgress()
        let bookID = UUID()

        progress.begin(bookID: bookID, title: "tri-Zone-Radio-Dromas", tracks: 176)
        progress.reach(12)
        progress.reach(11)

        XCTAssertTrue(progress.isConverting)
        XCTAssertTrue(progress.isConverting(bookID))
        XCTAssertEqual(progress.message, "Converting audio: 12 of 176 tracks of “tri-Zone-Radio-Dromas”")
        XCTAssertEqual(progress.current, 12)
        XCTAssertEqual(OggConversionProgress.title, "Converting Audio")
        XCTAssertEqual(CountWording.part(1, of: 1, OggConversionProgress.itemNoun), "1 of 1 track converted")
        progress.end(bookID: bookID)
        XCTAssertFalse(progress.isConverting)
        XCTAssertFalse(progress.isConverting(bookID))
        XCTAssertEqual(progress.message, "")
    }

    /// A book that waits for disk space is named in an alert saying how
    /// much it needs.
    func testTheSpaceAlertSaysHowMuchEachBookNeeds() {
        XCTAssertEqual(OggConversionWording.notEnoughSpaceTitle, "Not Enough Space to Convert Audio")
        XCTAssertEqual(
            OggConversionWording.notEnoughSpace([("Harbor Dramas", 4_200_000_000)]),
            "“Harbor Dramas” needs \(ImportProgressWording.size(4_200_000_000)) free to convert its Ogg audio to AAC. "
                + "Free some space, and TextMouth converts it at the next launch."
        )
    }

    /// While its book converts, a reader refuses to play, saying so, and
    /// hands nothing to the player. The book here is silent WAV, so nothing
    /// Ogg is near a player even should the refusal fail.
    func testAReaderRefusesToPlayABookBeingConverted() async throws {
        let world = try makeIntegrationWorld("Ogg Reader Converting")
        let book = try world.makeSilentAudioBook(title: "Quiet Dramas", trackDurations: [0.2, 0.2])
        let reader = world.openReader(for: book)
        let loaded = await eventually { reader.content != nil }
        XCTAssertTrue(loaded, "The reader never loaded its book")
        world.library.oggConversion.begin(bookID: book.id, title: book.title, tracks: 2)
        defer { world.library.oggConversion.end(bookID: book.id) }

        XCTAssertFalse(reader.chapterAudioIsClearOfOgg())
        XCTAssertEqual(reader.errorMessage, ReaderOggWording.beingConverted)
        XCTAssertEqual(reader.errorMessage, "This book's audio is being converted from Ogg to AAC. It plays once the conversion ends.")
        XCTAssertFalse(reader.isCurrentlyPlaying)
    }

    /// A reader of a book still in Ogg refuses to play it, says its audio
    /// needs converting, and starts its conversion; once that ends, the
    /// reader's chapters are AAC and clear to play. Play is never pressed.
    func testAReaderOfABookStillInOggStartsItsConversion() async throws {
        try OggTestFixtures.skipUnlessOggDecodes()
        let world = try makeIntegrationWorld("Ogg Reader Request")
        let book = try makeOggBook(
            in: world,
            title: "Late Dramas",
            tracks: ["01.ogg": OggTestFixtures.vorbis, "02.ogg": OggTestFixtures.vorbis],
            manifest: nil
        )
        let reader = world.openReader(for: book)
        let loaded = await eventually { reader.content != nil }
        XCTAssertTrue(loaded, "The reader never loaded its book")

        XCTAssertFalse(reader.chapterAudioIsClearOfOgg())
        XCTAssertEqual(
            reader.errorMessage,
            "This book's audio needs converting from Ogg to AAC before it plays. TextMouth is converting it now, and it plays once the conversion ends."
        )
        XCTAssertTrue(world.library.oggConversion.isConverting(book.id))

        let converted = await eventually(timeout: 30) {
            !world.library.oggConversion.isConverting(book.id)
                && reader.chapterAudioSource(forChapterAt: 0).files.allSatisfy { $0.pathExtension == "m4a" }
        }
        XCTAssertTrue(converted, "The book's conversion never reached its reader")
        XCTAssertTrue(reader.chapterAudioIsClearOfOgg())
    }

    // MARK: - The Last Guard

    /// The audio service refuses an Ogg file before it makes a player for
    /// it, as an unreadable file, so nothing can play it.
    func testTheAudioServiceRefusesAnOggFileBeforeMakingAPlayer() throws {
        let folder = try AudioTestFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ogg = try OggTestFixtures.copy(OggTestFixtures.vorbis, to: folder, as: "elegy.ogg")
        let opus = try OggTestFixtures.copy(OggTestFixtures.opus, to: folder, as: "two.OPUS")
        let service = AudioPlaybackService()

        XCTAssertEqual(AudioPlaybackService.fileProblem(at: ogg), .fileUnreadable)
        XCTAssertEqual(AudioPlaybackService.fileProblem(at: opus), .fileUnreadable)
        XCTAssertEqual(AudioPlaybackService.fileProblem(at: folder.appendingPathComponent("gone.ogg")), .fileMissing)
        XCTAssertFalse(service.load(url: ogg))
        XCTAssertEqual(service.failure?.reason, .fileUnreadable)
        XCTAssertFalse(service.isPlaying)
    }

    // MARK: - Helpers

    /// Makes the one-time conversion as the launch makes it, waiting for it,
    /// and returns what it did: nil when it was made already.
    private func convertOnce(
        _ world: IntegrationWorld,
        preferences: UserDefaults,
        access: MaintenanceFileAccess = .live
    ) async -> LibraryViewModel.OggConversionOutcome? {
        await withCheckedContinuation { continuation in
            world.library.convertImportedAudioOnce(preferences: preferences, access: access) { outcome in
                continuation.resume(returning: outcome)
            }
        }
    }

    /// A book of Ogg tracks in the world's library, as an import made it
    /// before B06: each of `tracks`, a name and the fixture copied there, in
    /// a folder of its package, with `manifest` beside them when given,
    /// indexed and listed.
    private func makeOggBook(in world: IntegrationWorld, title: String, tracks: [String: String], manifest: String?) throws -> Book {
        let packageName = "\(UUID().uuidString).tmb"
        let folder = TextMouthPaths.tmbPath(folderPath: world.folder.path, tmbName: packageName)
            .appendingPathComponent("Tracks", isDirectory: true)
        for (name, fixture) in tracks {
            try OggTestFixtures.copy(fixture, to: folder, as: name)
        }
        if let manifest {
            try Data(manifest.utf8).write(to: folder.appendingPathComponent(AudioManifest.fileName))
        }
        return try indexAndList(Book(
            title: title,
            format: .audio,
            filePath: folder.path,
            md5Hash: UUID().uuidString,
            folderPath: world.folder.path,
            tmbDirectoryName: packageName
        ), in: world)
    }

    /// A book of one Ogg file, `file`'s name and fixture, in its package in
    /// the world's library, indexed and listed.
    private func makeOggBook(in world: IntegrationWorld, title: String, file: (name: String, fixture: String)) throws -> Book {
        let packageName = "\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: world.folder.path, tmbName: packageName)
        let copy = try OggTestFixtures.copy(file.fixture, to: package, as: file.name)
        return try indexAndList(Book(
            title: title,
            format: .audio,
            filePath: copy.path,
            md5Hash: UUID().uuidString,
            folderPath: world.folder.path,
            tmbDirectoryName: packageName
        ), in: world)
    }

    /// Indexes `book` as an import indexes it, saves its record with the
    /// index, and lists it in `world`'s library.
    private func indexAndList(_ book: Book, in world: IntegrationWorld) throws -> Book {
        // The probe is a stand-in that reports two seconds for every track:
        // the real one never decodes Ogg audio in TextMouth (B09).
        let analysis = try BookContentAnalysisService.analyzeAudio(
            book: book,
            url: URL(fileURLWithPath: book.filePath),
            prober: AudioMediaProber { _ in .success(2) }
        )
        try book.saveBookInfoThrowing(contentIndex: analysis.index)
        world.library.library.addBook(book)
        return book
    }
}

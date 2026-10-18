import XCTest
@testable import TextMouth

/// An M3U or M3U8 playlist of local files imports as one book of tracks
/// (FMT10): through the folder import's own staging, copying, manifest
/// check, conversion, and publishing, with a manifest written from the
/// playlist's order and `#EXTINF` titles. The entries it skips are told in
/// a notice, a stream or a list with nothing to import is refused in words,
/// and neither the playlist nor its tracks are ever changed or deleted.
/// Each test copies a sample folder whole into its own sandbox and imports
/// into a library folder of its own. Nothing is played.
final class PlaylistImportTests: XCTestCase {
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox! // lint-ok: made in setUpWithError before every test
    /// The library folder this test imports into.
    private var folderPath: String! // lint-ok: made in setUpWithError before every test
    /// Where this test's playlists and tracks are written, outside the library.
    private var sources: URL! // lint-ok: made in setUpWithError before every test

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
        folderPath = "Playlist Import \(UUID().uuidString.prefix(8))"
        sources = try makeSandboxDirectory("playlist-sources")
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed partway.
        sandbox?.restore()
        if let folderPath {
            try? FileManager.default.removeItem(at: TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true))
        }
    }

    // MARK: - The Samples

    /// The Latin-1 sample imports as a book named for its file, with its
    /// four tracks in the playlist's order, `more/tone4.wav` among them,
    /// each headed by its `#EXTINF` title; the playlist and its tracks are
    /// as they were, and nothing was skipped.
    func testTheLatinOnePlaylistImportsFourTracksInItsOrder() throws {
        let folder = try copySampleFolder("m3u")
        let before = try snapshot(of: folder)

        let imported = try FileImportService.importPlaylistWithReport(
            from: folder.appendingPathComponent("playlist.m3u"), toFolder: folderPath
        )

        XCTAssertEqual(imported.book.title, "playlist")
        XCTAssertEqual(imported.book.format, .audio)
        XCTAssertNil(imported.notice)
        XCTAssertEqual(try manifestFiles(of: imported.book), ["tone1.wav", "tone2.wav", "tone3.wav", "more/tone4.wav"])
        XCTAssertEqual(try chapterTitles(of: imported.book), [
            "Café tone, 440 Hz", "Señal two - 660 Hz", "Third (subfolder-free)", "Fourth in a subfolder",
        ])
        XCTAssertEqual(try snapshot(of: folder), before)
    }

    /// The edge-case sample gives its two usable tracks, in its order, and
    /// a notice naming its four skipped entries in order, each with its
    /// reason.
    func testTheEdgeCasePlaylistImportsTwoTracksAndNamesTheFourSkipped() throws {
        let folder = try copySampleFolder("m3u")

        let imported = try FileImportService.importPlaylistWithReport(
            from: folder.appendingPathComponent("edge-cases.m3u"), toFolder: folderPath
        )

        XCTAssertEqual(try manifestFiles(of: imported.book), ["tone2.wav", "tone1.wav"])
        XCTAssertEqual(
            imported.notice,
            "TextMouth skipped 4 entries of “edge-cases.m3u”: “missing-file.wav” (not found), "
                + "“../outside-the-folder.wav” (outside the playlist's folder), "
                + "“/System/Library/Sounds/Basso.aiff” (outside the playlist's folder), "
                + "and “http://example.invalid/stream.mp3” (a web address)."
        )
        XCTAssertEqual(imported.announcement, imported.notice)
    }

    /// The UTF-8 sample gives three tracks headed by their non-ASCII titles,
    /// and skips nothing.
    func testTheUTF8PlaylistImportsThreeTracksWithTheirHeadings() throws {
        let folder = try copySampleFolder("m3u8")

        let imported = try FileImportService.importPlaylistWithReport(
            from: folder.appendingPathComponent("playlist.m3u8"), toFolder: folderPath
        )

        XCTAssertEqual(imported.book.title, "playlist")
        XCTAssertEqual(try chapterTitles(of: imported.book), ["Zażółć — 第一 (440 Hz)", "Café ❤ two", "Τρίτο (880 Hz)"])
        XCTAssertNil(imported.notice)
    }

    /// An HLS media playlist and an HLS master playlist are refused with the
    /// streaming sentence while the source is read, and nothing is left in
    /// the library folder.
    func testHLSPlaylistsAreRefusedAsStreamsAndLeaveNothingBehind() throws {
        let folder = try copySampleFolder("m3u8")
        for name in ["hls-media.m3u8", "hls-master.m3u8"] {
            let failure = try refusal(of: folder.appendingPathComponent(name))
            XCTAssertEqual(failure.underlying as? PlaylistImportError, .streaming, name)
            XCTAssertEqual(
                failure.errorDescription,
                "Could not import “\(name)”. Reading the file failed: "
                    + "It is a streaming playlist for audio on the web, which TextMouth does not import.",
                name
            )
        }
        XCTAssertEqual(try libraryFolderEntries(), [])
    }

    // MARK: - Playlists Made in the Test

    /// A playlist of two Ogg tones imports with both converted to .m4a, the
    /// manifest naming the .m4a files and keeping the playlist's titles. No
    /// Ogg file is left in the package, and the Ogg files are unchanged.
    func testOggTracksAreConvertedAndTheManifestFollowsTheirNewNames() throws {
        try OggTestFixtures.skipUnlessOggDecodes()
        let folder = sources.appendingPathComponent("Radio", isDirectory: true)
        try OggTestFixtures.copy(OggTestFixtures.vorbis, to: folder, as: "one.ogg")
        try OggTestFixtures.copy(OggTestFixtures.vorbis, to: folder, as: "two.ogg")
        let playlist = try write("#EXTM3U\n#EXTINF:2,First\none.ogg\n#EXTINF:2,Second\ntwo.ogg\n", to: "Radio/radio.m3u")
        let before = try snapshot(of: folder)

        let imported = try FileImportService.importPlaylistWithReport(from: playlist, toFolder: folderPath)

        let audio = URL(fileURLWithPath: imported.book.filePath)
        XCTAssertEqual(OggTestFixtures.names(in: audio), ["manifest.json", "one.m4a", "two.m4a"])
        XCTAssertEqual(try manifestFiles(of: imported.book), ["one.m4a", "two.m4a"])
        XCTAssertEqual(try chapterTitles(of: imported.book), ["First", "Second"])
        XCTAssertEqual(try snapshot(of: folder), before)
    }

    /// A file listed twice is one track, and the notice says the second
    /// listing was a repeat.
    func testAFileListedTwiceIsOneTrackAndTheNoticeSaysSo() throws {
        let playlist = try makePlaylist("tracks.m3u", listing: ["a.wav", "b.wav", "a.wav"], tracks: ["a.wav", "b.wav"])

        let imported = try FileImportService.importPlaylistWithReport(from: playlist, toFolder: folderPath)

        XCTAssertEqual(try manifestFiles(of: imported.book), ["a.wav", "b.wav"])
        XCTAssertEqual(imported.notice, "TextMouth skipped 1 entry of “tracks.m3u”: “a.wav” (listed before).")
    }

    /// Two spellings of one file that differ only in case are one track on
    /// this Mac's disk; the second is told as listed before, and nothing
    /// is copied over the first.
    func testASecondSpellingOfATrackInAnotherCaseIsSkippedAsListedBefore() {
        let first = M3UPlaylist.Track(url: sources.appendingPathComponent("Tone.wav"), path: "Tone.wav", title: nil)
        let second = M3UPlaylist.Track(url: sources.appendingPathComponent("tone.wav"), path: "tone.wav", title: nil)
        let other = M3UPlaylist.Track(url: sources.appendingPathComponent("b.wav"), path: "b.wav", title: nil)
        let earlier = M3UPlaylist.Skipped(location: "gone.wav", reason: .missing)

        let result = FileImportService.distinctTracks(
            of: M3UPlaylist.Resolution(tracks: [first, second, other], skipped: [earlier])
        )

        XCTAssertEqual(result.tracks, [first, other])
        XCTAssertEqual(result.skipped, [earlier, M3UPlaylist.Skipped(location: "tone.wav", reason: .listedBefore)])
    }

    /// An empty playlist, and one whose every entry is skipped, are refused
    /// with the sentence, the second with the list of what was skipped.
    func testAPlaylistWithNoUsableTrackIsRefusedWithTheSkippedList() throws {
        let empty = try write("#EXTM3U\n", to: "empty.m3u")
        let emptyFailure = try refusal(of: empty)
        XCTAssertEqual(
            emptyFailure.errorDescription,
            "Could not import “empty.m3u”. Reading the file failed: "
                + "It names no audio file in its own folder that TextMouth can import."
        )

        let skipping = try write("missing.wav\nhttp://example.invalid/a.mp3\n", to: "skipping.m3u")
        let failure = try refusal(of: skipping)
        XCTAssertEqual(
            failure.errorDescription,
            "Could not import “skipping.m3u”. Reading the file failed: "
                + "It names no audio file in its own folder that TextMouth can import. "
                + "It skipped 2 entries: “missing.wav” (not found) and “http://example.invalid/a.mp3” (a web address)."
        )
        XCTAssertEqual(try libraryFolderEntries(), [])
    }

    /// A playlist of only web addresses is refused with its own sentence.
    func testAPlaylistOfOnlyWebAddressesIsRefused() throws {
        let playlist = try write("http://example.invalid/a.mp3\nhttps://example.invalid/b.mp3\n", to: "web.m3u")

        let failure = try refusal(of: playlist)

        XCTAssertEqual(failure.underlying as? PlaylistImportError, .onlyWebAddresses)
        XCTAssertEqual(
            failure.errorDescription,
            "Could not import “web.m3u”. Reading the file failed: "
                + "It lists only web addresses, and TextMouth imports only files on this Mac."
        )
        XCTAssertEqual(try libraryFolderEntries(), [])
    }

    /// `#PLAYLIST:` names the book; without it the file's name does.
    func testThePlaylistDirectiveGivesTheBookItsTitle() throws {
        let named = try makePlaylist("named.m3u", listing: ["#PLAYLIST:A Title", "a.wav"], tracks: ["a.wav"])
        let unnamed = try makePlaylist("Evening Mix.m3u8", listing: ["a.wav"], tracks: ["a.wav"], in: "Other")

        let namedBook = try FileImportService.importPlaylistWithReport(from: named, toFolder: folderPath).book
        let unnamedBook = try FileImportService.importPlaylistWithReport(from: unnamed, toFolder: folderPath).book

        XCTAssertEqual(namedBook.title, "A Title")
        XCTAssertEqual(unnamedBook.title, "Evening Mix")
    }

    /// A name spelled decomposed (NFD) in the playlist finds the file whose
    /// name is composed (NFC) on disk.
    func testANameInDecomposedFormFindsTheFileInComposedForm() throws {
        let composed = "Caf\u{E9}.wav"
        let decomposed = "Cafe\u{301}.wav"
        let playlist = try makePlaylist("accents.m3u", listing: [decomposed], tracks: [composed])

        let imported = try FileImportService.importPlaylistWithReport(from: playlist, toFolder: folderPath)

        XCTAssertEqual(try chapterTitles(of: imported.book).count, 1)
        XCTAssertNil(imported.notice)
    }

    /// Sixty entries, copies of one tone under sixty names, import as sixty
    /// tracks in the playlist's order.
    func testSixtyEntriesImportSixtyTracksInOrder() throws {
        let names = (1...60).map { String(format: "t%02d.wav", $0) }
        let listing = names.enumerated().flatMap { ["#EXTINF:1,Track \($0.offset + 1)", $0.element] }
        let playlist = try makePlaylist("sixty.m3u", listing: listing, tracks: names)

        let imported = try FileImportService.importPlaylistWithReport(from: playlist, toFolder: folderPath)

        XCTAssertEqual(try manifestFiles(of: imported.book), names)
        XCTAssertEqual(try chapterTitles(of: imported.book), (1...60).map { "Track \($0)" })
    }

    // MARK: - Duplicates and the Original

    /// The same playlist imported twice has the same checksum, so it is a
    /// duplicate; the same tracks under another playlist's name are not.
    func testTheSamePlaylistImportedTwiceHasOneChecksum() throws {
        let playlist = try makePlaylist("again.m3u", listing: ["a.wav", "b.wav"], tracks: ["a.wav", "b.wav"])
        let renamed = sources.appendingPathComponent("again two.m3u")
        try FileManager.default.copyItem(at: playlist, to: renamed)

        let first = try FileImportService.importPlaylistWithReport(from: playlist, toFolder: folderPath)
        let second = try FileImportService.importPlaylistWithReport(from: playlist, toFolder: folderPath)
        let third = try FileImportService.importPlaylistWithReport(from: renamed, toFolder: folderPath)

        XCTAssertEqual(second.book.md5Hash, first.book.md5Hash)
        XCTAssertNotEqual(third.book.md5Hash, first.book.md5Hash)
    }

    /// A playlist import never allows its original to be deleted: its
    /// tracks belong to the listener's music folders.
    func testAPlaylistImportNeverMayDeleteItsOriginal() throws {
        let playlist = try makePlaylist("keep.m3u", listing: ["a.wav"], tracks: ["a.wav"])

        let imported = try FileImportService.importPlaylistWithReport(from: playlist, toFolder: folderPath)

        XCTAssertTrue(imported.isFromFolder)
        XCTAssertFalse(imported.mayDeleteOriginal)
        XCTAssertEqual(imported.book.sourceFilePath, playlist.path)
    }

    /// With "After Importing a Book" set to delete, or to ask, the playlist
    /// and its tracks are still there, and no question about them is asked.
    /// The same playlist imported again is a duplicate whose question never
    /// offers to delete the playlist.
    @MainActor
    func testTheLibraryNeverDeletesOrOffersToDeleteAPlaylistOrItsTracks() throws {
        // A regression must remove only this test's sandbox, never reach the user's Trash.
        keepDeletionsOutOfTheTrash()
        let playlist = try makePlaylist("music.m3u", listing: ["a.wav", "b.wav"], tracks: ["a.wav", "b.wav"])

        for behavior in [ImportDeleteBehavior.deleteAfterImport, .askEachTime] {
            let label = "\(behavior)"
            let model = LibraryViewModel(initializeServices: false)
            model.library = Library()
            let imported = try FileImportService.importPlaylistWithReport(from: playlist, toFolder: folderPath)
            withImportDeleteBehavior(behavior) {
                model.completeSingleImportedBook(imported, originalURL: playlist)
            }

            XCTAssertTrue(model.library.books.contains { $0.id == imported.book.id }, label)
            XCTAssertTrue(model.importDecisions.isEmpty, label)
            for name in ["music.m3u", "a.wav", "b.wav"] {
                XCTAssertTrue(FileManager.default.fileExists(atPath: sources.appendingPathComponent(name).path), "\(label): \(name)")
            }
        }

        let model = LibraryViewModel(initializeServices: false)
        let first = try FileImportService.importPlaylistWithReport(from: playlist, toFolder: folderPath)
        let second = try FileImportService.importPlaylistWithReport(from: playlist, toFolder: folderPath)
        model.library = Library(books: [first.book])
        withImportDeleteBehavior(.deleteAfterImport) {
            model.completeSingleImportedBook(second, originalURL: playlist)
        }
        let duplicate = try XCTUnwrap(model.importDecisions.current?.duplicate)
        XCTAssertNil(duplicate.originalURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: playlist.path))
    }

    /// The notice of skipped entries is presented as a warning is, through
    /// the library's alert, and the book is not opened over it.
    @MainActor
    func testTheSkippedEntriesAreToldInTheLibrarysAlertAndTheBookIsNotOpened() throws {
        let playlist = try makePlaylist("alert.m3u", listing: ["a.wav", "gone.wav"], tracks: ["a.wav"])
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()
        let opened = OpenedBooks(recordingFor: model)

        let imported = try FileImportService.importPlaylistWithReport(from: playlist, toFolder: folderPath)
        model.completeSingleImportedBook(imported, originalURL: playlist, request: ImportRequest(opensAfterImport: true))

        XCTAssertEqual(model.errorMessage, "TextMouth skipped 1 entry of “alert.m3u”: “gone.wav” (not found).")
        XCTAssertTrue(model.showError)
        XCTAssertEqual(opened.ids, [])
        XCTAssertTrue(model.library.books.contains { $0.id == imported.book.id })
    }

    // MARK: - The Words

    /// The refusals, and the notice for one entry, two entries, and twelve
    /// (ten named, then how many more).
    func testTheWordsOfTheRefusalsAndTheNotice() {
        func skipped(_ count: Int) -> [M3UPlaylist.Skipped] {
            (1...count).map { M3UPlaylist.Skipped(location: "n\($0).wav", reason: .missing) }
        }

        XCTAssertEqual(
            PlaylistImportWording.streaming,
            "It is a streaming playlist for audio on the web, which TextMouth does not import."
        )
        XCTAssertEqual(
            PlaylistImportWording.onlyWebAddresses,
            "It lists only web addresses, and TextMouth imports only files on this Mac."
        )
        XCTAssertEqual(
            PlaylistImportWording.noTrack(skipped: []),
            "It names no audio file in its own folder that TextMouth can import."
        )
        XCTAssertNil(PlaylistImportWording.notice(playlistName: "a.m3u", skipped: []))
        XCTAssertEqual(
            PlaylistImportWording.notice(playlistName: "a.m3u", skipped: skipped(1)),
            "TextMouth skipped 1 entry of “a.m3u”: “n1.wav” (not found)."
        )
        XCTAssertEqual(
            PlaylistImportWording.notice(playlistName: "a.m3u", skipped: skipped(2)),
            "TextMouth skipped 2 entries of “a.m3u”: “n1.wav” (not found) and “n2.wav” (not found)."
        )
        XCTAssertEqual(
            PlaylistImportWording.notice(playlistName: "a.m3u", skipped: skipped(3)),
            "TextMouth skipped 3 entries of “a.m3u”: “n1.wav” (not found), “n2.wav” (not found), and “n3.wav” (not found)."
        )
        let twelve = (1...10).map { "“n\($0).wav” (not found)" }.joined(separator: ", ")
        XCTAssertEqual(
            PlaylistImportWording.notice(playlistName: "a.m3u", skipped: skipped(12)),
            "TextMouth skipped 12 entries of “a.m3u”: \(twelve), and 2 more."
        )
        XCTAssertEqual(
            PlaylistImportWording.noTrack(skipped: skipped(12)),
            "It names no audio file in its own folder that TextMouth can import. It skipped 12 entries: \(twelve), and 2 more."
        )
    }

    /// An import's warning and its notice come to the listener as one
    /// message, the warning first; either alone is itself.
    func testTheAnnouncementJoinsTheWarningAndTheNotice() {
        var imported = ImportedBook(book: Book(title: "T", format: .audio, filePath: "/x", md5Hash: "h"))
        XCTAssertNil(imported.announcement)
        imported.notice = "Notice."
        XCTAssertEqual(imported.announcement, "Notice.")
        imported.report.omissions = [ExtractionOmission(chapterNumber: 1, member: "a.xhtml", reason: .missingMember)]
        XCTAssertEqual(imported.announcement, "\(imported.warning ?? "") Notice.")
        XCTAssertNotNil(imported.warning)
    }

    // MARK: - Helpers

    /// Copies the sample folder `name` of `TestData/format-samples` whole
    /// into the sandbox (the samples are never changed) and returns the copy.
    private func copySampleFolder(_ name: String) throws -> URL {
        let samples = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestData/format-samples", isDirectory: true)
        let copy = sources.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.copyItem(at: samples.appendingPathComponent(name), to: copy)
        return copy
    }

    /// Writes `text` to `path` in the sandbox, making its folders, and
    /// returns the file.
    @discardableResult
    private func write(_ text: String, to path: String) throws -> URL {
        let url = sources.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Writes a playlist named `name` listing `listing`, one line each,
    /// beside tracks (short tones) named `tracks`, in the sandbox's folder
    /// `folder` (its top when empty), and returns the playlist.
    private func makePlaylist(_ name: String, listing: [String], tracks: [String], in folder: String = "") throws -> URL {
        let directory = folder.isEmpty ? sources.standardizedFileURL : sources.appendingPathComponent(folder, isDirectory: true)
        // One tone, written once and copied to the other names.
        var firstTone: URL?
        for track in tracks {
            let destination = directory.appendingPathComponent(track)
            if let tone = firstTone {
                try FileManager.default.copyItem(at: tone, to: destination)
            } else {
                try AudioTestFixtures.writeSilence(to: destination, duration: 0.2)
                firstTone = destination
            }
        }
        return try write(listing.joined(separator: "\n") + "\n", to: (folder.isEmpty ? "" : folder + "/") + name)
    }

    /// Imports `playlist`, which must be refused, and returns the failure.
    private func refusal(of playlist: URL, file: StaticString = #filePath, line: UInt = #line) throws -> ImportFailure {
        do {
            _ = try FileImportService.importPlaylistWithReport(from: playlist, toFolder: folderPath)
        } catch let failure as ImportFailure {
            XCTAssertEqual(failure.step, .readingSource, file: file, line: line)
            return failure
        }
        XCTFail("\(playlist.lastPathComponent) was imported, not refused", file: file, line: line)
        throw NotRefused()
    }

    /// Thrown after a failed assertion that a playlist was refused, to end
    /// the test that asked.
    private struct NotRefused: Error {}

    /// The files the book's manifest lists as tracks, in its order.
    private func manifestFiles(of book: Book) throws -> [String] {
        let manifest = URL(fileURLWithPath: book.filePath).appendingPathComponent("manifest.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest))
        let tracks = try XCTUnwrap((object as? [String: Any])?["tracks"] as? [Any])
        return try tracks.map { entry in
            if let name = entry as? String { return name }
            return try XCTUnwrap((entry as? [String: Any])?["file"] as? String)
        }
    }

    /// The headings of the book's chapters, in order, as the reader reads it.
    private func chapterTitles(of book: Book) throws -> [String] {
        try BookContentAnalysisService.load(book: book).content.chapters.map(\.title)
    }

    /// Every file under `folder` with its bytes, by its path from `folder`,
    /// to show that an import changed nothing.
    private func snapshot(of folder: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            files[String(url.path.dropFirst(folder.path.count))] = try Data(contentsOf: url)
        }
        return files
    }

    /// The names in this test's library folder; none when it does not exist.
    private func libraryFolderEntries() throws -> Set<String> {
        let folder = TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    }

    /// Runs `body` with the "After Importing a Book" preference set to
    /// `behavior`, restoring the previous preference afterwards.
    @MainActor
    private func withImportDeleteBehavior(_ behavior: ImportDeleteBehavior, _ body: () throws -> Void) rethrows {
        let config = ConfigService.shared
        let previous = config.config.importDeleteBehavior
        config.config.importDeleteBehavior = behavior
        defer { config.config.importDeleteBehavior = previous }
        try body()
    }
}

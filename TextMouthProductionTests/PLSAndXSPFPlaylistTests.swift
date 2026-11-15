import UniformTypeIdentifiers
import XCTest
@testable import TextMouth

/// PLS and XSPF playlists (FMT12): read into the same `M3UPlaylist` an M3U
/// file makes, so the import after them is the one FMT10 built. These tests
/// pin the two readers, the words of their refusals, the way a pronunciation
/// lexicon with the .pls extension is told apart, and the import of the two
/// sample playlists as books of tracks. Nothing is played.
final class PLSAndXSPFPlaylistTests: XCTestCase {
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox! // lint-ok: made in setUpWithError before every test
    /// The library folder this test imports into.
    private var folderPath: String! // lint-ok: made in setUpWithError before every test
    /// Where this test's playlists and tracks are copied, outside the library.
    private var sources: URL! // lint-ok: made in setUpWithError before every test

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
        folderPath = "PLS XSPF Import \(UUID().uuidString.prefix(8))"
        sources = FileManager.default.temporaryDirectory
            .appendingPathComponent("pls-xspf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed partway.
        sandbox?.restore()
        if let folderPath {
            try? FileManager.default.removeItem(at: TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true))
        }
    }

    // MARK: - PLS

    /// Entries come in the order of their numbers, whatever order the lines
    /// are in, with keys in any capitals; a number past nine is after nine.
    func testPLSEntriesAreOrderedByNumberAndKeysIgnoreCase() {
        let playlist = M3UPlaylist.parsePLS("""
        [playlist]
        FILE10=ten.wav
        file2=two.wav
        Title2=Second
        File1 = one.wav
        TITLE1 = First
        NumberOfEntries=3
        Version=2
        """)
        XCTAssertEqual(playlist.entries.map(\.location), ["one.wav", "two.wav", "ten.wav"])
        XCTAssertEqual(playlist.entries.map(\.title), ["First", "Second", nil])
        XCTAssertNil(playlist.title)
        XCTAssertFalse(playlist.isStreaming)
    }

    /// Comments, blank values, other keys, a repeated number, a byte-order
    /// mark, and CR line ends are all handled; the line is where `File` was.
    func testPLSIgnoresWhatItDoesNotKnow() {
        let playlist = M3UPlaylist.parsePLS(
            "\u{FEFF}[playlist]\r; a comment\rFile1=a.wav\rFile1=again.wav\rFile2=\rLength1=5\rFileX=nope\rFile3=c.wav\r"
        )
        XCTAssertEqual(playlist.entries.map(\.location), ["a.wav", "c.wav"])
        XCTAssertEqual(playlist.entries.map(\.line), [3, 8])
    }

    /// A PLS file of web addresses (internet radio) lists only web
    /// addresses, as the import refuses.
    func testPLSOfRadioStationsListsOnlyWebAddresses() {
        let playlist = M3UPlaylist.parsePLS("[playlist]\nFile1=http://radio.example/stream\nTitle1=Radio\n")
        XCTAssertTrue(playlist.listsOnlyWebAddresses)
    }

    /// XML is told from a playlist by its first character.
    func testLooksLikeXML() {
        XCTAssertTrue(M3UPlaylist.looksLikeXML("\u{FEFF}\n  <?xml version=\"1.0\"?><lexicon/>"))
        XCTAssertFalse(M3UPlaylist.looksLikeXML("[playlist]\nFile1=<a>.wav"))
        XCTAssertFalse(M3UPlaylist.looksLikeXML(""))
    }

    // MARK: - XSPF

    /// The playlist's own title, each track's first location and title, in
    /// order; a track with no location is passed over; creators and
    /// durations are ignored, and entities are read.
    func testXSPFGivesTheTitleAndTheTracksInOrder() throws {
        let playlist = try M3UPlaylist.parseXSPF(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <playlist version="1" xmlns="http://xspf.org/ns/0/">
          <title> Mix &amp; Match </title>
          <creator>Someone</creator>
          <trackList>
            <track><location>a.wav</location><location>other.wav</location><title>One &amp; only</title><duration>10</duration></track>
            <track><title>No location</title></track>
            <track><location>b%20c.wav</location><creator>X</creator></track>
          </trackList>
        </playlist>
        """.utf8), fileName: "mix.xspf")
        XCTAssertEqual(playlist.title, "Mix & Match")
        XCTAssertEqual(playlist.entries.map(\.location), ["a.wav", "b%20c.wav"])
        XCTAssertEqual(playlist.entries.map(\.title), ["One & only", nil])
        XCTAssertFalse(playlist.isStreaming)
    }

    /// Elements with a namespace prefix are read as the same elements, and
    /// a title inside an extension or a track's own list is not the playlist's.
    func testXSPFWithPrefixesAndNestedTitles() throws {
        let playlist = try M3UPlaylist.parseXSPF(Data("""
        <x:playlist version="1" xmlns:x="http://xspf.org/ns/0/">
          <x:extension application="a"><x:title>not the playlist's</x:title></x:extension>
          <x:title>Real</x:title>
          <x:trackList><x:track><x:location>a.wav</x:location></x:track></x:trackList>
        </x:playlist>
        """.utf8), fileName: "p.xspf")
        XCTAssertEqual(playlist.title, "Real")
        XCTAssertEqual(playlist.entries.map(\.location), ["a.wav"])
    }

    /// A relative location is resolved against `xml:base`, a track's own
    /// base wins, and an absolute location is left as written. A base on the
    /// web makes a web address, which the import refuses.
    func testXSPFResolvesLocationsAgainstXMLBase() throws {
        let playlist = try M3UPlaylist.parseXSPF(Data("""
        <playlist version="1" xmlns="http://xspf.org/ns/0/" xml:base="http://example.com/music/">
          <trackList>
            <track><location>a.mp3</location></track>
            <track xml:base="file:///Users/x/Music/"><location>b.wav</location></track>
            <track><location>file:///Users/x/c.wav</location></track>
            <track><location>/abs/d.wav</location></track>
          </trackList>
        </playlist>
        """.utf8), fileName: "p.xspf")
        XCTAssertEqual(playlist.entries.map(\.location), [
            "http://example.com/music/a.mp3", "file:///Users/x/Music/b.wav", "file:///Users/x/c.wav", "/abs/d.wav",
        ])
    }

    /// An XSPF playlist that declares an entity, of either kind, is refused
    /// in words, not read with the entity as nothing.
    func testXSPFWithADeclaredEntityIsRefused() {
        for declaration in [#"<!ENTITY t "Tone">"#, #"<!ENTITY s SYSTEM "file:///nowhere/at/all">"#] {
            let data = Data("""
            <?xml version="1.0"?>
            <!DOCTYPE playlist [\(declaration)]>
            <playlist version="1" xmlns="http://xspf.org/ns/0/"><trackList><track><location>a.wav</location><title>&t; one</title></track></trackList></playlist>
            """.utf8)
            XCTAssertThrowsError(try M3UPlaylist.parseXSPF(data, fileName: "p.xspf"), declaration) {
                XCTAssertEqual($0 as? M3UPlaylistError, .declaresEntities(fileName: "p.xspf"))
                XCTAssertEqual(
                    $0.localizedDescription,
                    "The playlist “p.xspf” uses XML entities of its own, which TextMouth does not read."
                )
            }
        }
    }

    /// A file that is no XML, a cut-off one, and another kind of XML are
    /// refused with the playlist's name.
    func testXSPFRefusals() {
        for text in ["not xml", "<playlist><trackList><track>", "<html><body/></html>"] {
            XCTAssertThrowsError(try M3UPlaylist.parseXSPF(Data(text.utf8), fileName: "p.xspf"), text) {
                XCTAssertEqual($0 as? M3UPlaylistError, .notReadable(fileName: "p.xspf"))
            }
        }
    }

    // MARK: - Reading Files

    /// The extensions of playlists include PLS and XSPF in any capitals.
    func testPLSAndXSPFFilesArePlaylists() {
        for name in ["a.pls", "a.PLS", "a.xspf", "a.Xspf", "a.m3u", "a.m3u8"] {
            XCTAssertTrue(M3UPlaylist.isPlaylist(URL(fileURLWithPath: "/tmp/\(name)")), name)
        }
        XCTAssertFalse(M3UPlaylist.isPlaylist(URL(fileURLWithPath: "/tmp/a.xml")))
    }

    /// `read(at:)` reads each kind by its extension, and a .pls file that is
    /// a pronunciation lexicon is refused, with the way to use it.
    func testReadingByExtensionAndTheLexiconWithTheSameExtension() throws {
        let pls = try write("[playlist]\nFile1=a.wav\n", to: "a.pls")
        XCTAssertEqual(try M3UPlaylist.read(at: pls).entries.map(\.location), ["a.wav"])

        let xspf = try write(
            "<playlist version=\"1\"><trackList><track><location>b.wav</location></track></trackList></playlist>",
            to: "b.xspf"
        )
        XCTAssertEqual(try M3UPlaylist.read(at: xspf).entries.map(\.location), ["b.wav"])

        let lexicon = try write("<?xml version=\"1.0\"?><lexicon version=\"1.0\"/>", to: "lexicon.pls")
        XCTAssertThrowsError(try M3UPlaylist.read(at: lexicon)) {
            XCTAssertEqual($0 as? M3UPlaylistError, .pronunciationLexicon(fileName: "lexicon.pls"))
            XCTAssertEqual($0.localizedDescription, PlaylistImportWording.pronunciationLexicon(fileName: "lexicon.pls"))
        }
    }

    /// The lexicon refusal advises on the Mac, naming the button as the
    /// settings tab does, and stops after "not a playlist." where there is no
    /// such tab (the iPhone).
    func testTheLexiconRefusalAdvisesOnlyWhereTheTabIs() {
        XCTAssertEqual(
            PlaylistImportWording.pronunciationLexicon(fileName: "a.pls", advising: true),
            "“a.pls” is a pronunciation lexicon, not a playlist. To use it, choose Import Rules… on the Text tab in Settings."
        )
        XCTAssertEqual(
            PlaylistImportWording.pronunciationLexicon(fileName: "a.pls", advising: false),
            "“a.pls” is a pronunciation lexicon, not a playlist."
        )
        XCTAssertTrue(PlaylistImportWording.pronunciationLexicon(fileName: "a.pls", advising: true)
            .contains(PronunciationLexiconWording.importButton))
        #if os(macOS)
        XCTAssertTrue(PlaylistImportWording.hasLexiconImport)
        #endif
    }

    /// The words of the two new refusals.
    func testTheWordsOfTheRefusals() {
        XCTAssertEqual(
            M3UPlaylistError.notReadable(fileName: "p.xspf").errorDescription,
            "The playlist “p.xspf” is not a complete, valid playlist file."
        )
    }

    /// The Open Book panel offers PLS and XSPF files.
    func testThePanelOffersPLSAndXSPF() throws {
        for ext in ["pls", "xspf"] {
            let type = try XCTUnwrap(UTType(filenameExtension: ext), ext)
            XCTAssertTrue(FileImportService.supportedTypes.contains { type.conforms(to: $0) }, ext)
        }
    }

    // MARK: - The Samples

    /// The PLS sample imports as a book named for its file, with its three
    /// tracks in the playlist's order headed by their titles (the Latin 1
    /// one read as Latin 1), and the sample itself is left as it was.
    func testThePLSSampleImportsThreeTracks() throws {
        let folder = try copySampleFolder("pls-playlist")
        let before = try snapshot(of: folder)

        let imported = try FileImportService.importPlaylistWithReport(
            from: folder.appendingPathComponent("playlist.pls"), toFolder: folderPath
        )

        XCTAssertEqual(imported.book.title, "playlist")
        XCTAssertEqual(imported.book.format, .audio)
        XCTAssertNil(imported.notice)
        XCTAssertEqual(try manifestFiles(of: imported.book), ["tone1.wav", "tone2.wav", "tone3.wav"])
        XCTAssertEqual(try chapterTitles(of: imported.book), ["First tone, 440 Hz", "Second tone, café", "Third tone"])
        XCTAssertEqual(try snapshot(of: folder), before)
    }

    /// The XSPF sample imports as a book named by the playlist's own title,
    /// with the two tracks in the folder, and tells that the entry outside
    /// the folder was skipped.
    func testTheXSPFSampleImportsTwoTracksAndSkipsTheOutsideEntry() throws {
        let folder = try copySampleFolder("xspf")

        let imported = try FileImportService.importPlaylistWithReport(
            from: folder.appendingPathComponent("playlist.xspf"), toFolder: folderPath
        )

        XCTAssertEqual(imported.book.title, "Three tones — café")
        XCTAssertEqual(try manifestFiles(of: imported.book), ["tone1.wav", "tone3.wav"])
        XCTAssertEqual(try chapterTitles(of: imported.book), ["First tone", "Third tone & last"])
        let notice = try XCTUnwrap(imported.notice)
        XCTAssertTrue(notice.contains("playlist.xspf"), notice)
        XCTAssertTrue(notice.contains("outside the playlist's folder"), notice)
    }

    /// A PLS file of web addresses is refused as only web addresses.
    func testAPLSOfWebAddressesIsRefused() throws {
        let playlist = try write("[playlist]\nFile1=http://radio.example/live\n", to: "radio.pls")
        XCTAssertThrowsError(try FileImportService.importPlaylistWithReport(from: playlist, toFolder: folderPath)) { error in
            XCTAssertTrue(error.localizedDescription.contains(PlaylistImportWording.onlyWebAddresses), "\(error)")
        }
    }

    /// A pronunciation lexicon named .pls is refused with the way to use it.
    func testALexiconIsRefusedAsAPlaylist() throws {
        let lexicon = try write("<?xml version=\"1.0\"?><lexicon version=\"1.0\"/>", to: "lexicon.pls")
        XCTAssertThrowsError(try FileImportService.importPlaylistWithReport(from: lexicon, toFolder: folderPath)) { error in
            XCTAssertTrue(error.localizedDescription.contains("is a pronunciation lexicon, not a playlist"), "\(error)")
        }
    }

    // MARK: - Helpers

    /// Writes `text` to `name` in this test's sandbox, and returns the file.
    private func write(_ text: String, to name: String) throws -> URL {
        let url = sources.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Copies the sample folder `name` whole into the sandbox.
    private func copySampleFolder(_ name: String) throws -> URL {
        let samples = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestData/format-samples", isDirectory: true)
        let copy = sources.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.copyItem(at: samples.appendingPathComponent(name), to: copy)
        return copy
    }

    /// The files the book's manifest lists, in order.
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
}

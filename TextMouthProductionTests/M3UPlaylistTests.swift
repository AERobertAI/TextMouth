import XCTest
@testable import TextMouth

/// Reading an M3U or M3U8 playlist and deciding which entries are files
/// TextMouth may use (FMT10): `parse` on canned text, `read` and `resolve` on
/// the playlist samples in `TestData/format-samples`, and `resolve` on
/// folders each test makes. Nothing is played, and no audio framework opens
/// a file: the listed files are only looked for on disk.
final class M3UPlaylistTests: XCTestCase {
    private var folder: URL! // lint-ok: made in setUpWithError before every test

    override func setUpWithError() throws {
        folder = try AudioTestFixtures.makeTemporaryDirectory()
    }

    override func tearDown() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    // MARK: - Helpers

    /// The samples' folder in the source tree: `TestData/format-samples`.
    private static let samplesFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestData/format-samples", isDirectory: true)

    /// Copy the sample folder `name` whole into this test's temporary folder
    /// (the samples are never changed) and return the copy.
    private func copySampleFolder(_ name: String) throws -> URL {
        let copy = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.copyItem(at: Self.samplesFolder.appendingPathComponent(name), to: copy)
        return copy
    }

    /// Write `text` to `name` in the temporary folder (creating the folders
    /// on the way) and return the file.
    @discardableResult
    private func write(_ text: String, to name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Make a small file named `name` (its bytes are not audio; only its
    /// name and presence matter to `resolve`).
    @discardableResult
    private func touch(_ name: String) throws -> URL {
        try write("x", to: name)
    }

    /// The playlist `lines` resolved in the temporary folder.
    private func resolve(_ lines: [String]) -> M3UPlaylist.Resolution {
        M3UPlaylist.parse(lines.joined(separator: "\n")).resolve(inFolder: folder)
    }

    /// The `[location, reason words]` pairs of `resolution.skipped`, for comparing.
    private func skips(_ resolution: M3UPlaylist.Resolution) -> [[String]] {
        resolution.skipped.map { [$0.location, $0.reason.words] }
    }

    // MARK: - parse

    /// CRLF line ends and a leading byte-order mark read like plain lines,
    /// and each entry is numbered by its line.
    func testParseHandlesCRLFAndByteOrderMark() {
        let playlist = M3UPlaylist.parse("\u{FEFF}#EXTM3U\r\n\r\na.mp3\r\n  b.mp3  \r\rc.mp3")
        XCTAssertEqual(playlist.entries.map(\.location), ["a.mp3", "b.mp3", "c.mp3"])
        XCTAssertEqual(playlist.entries.map(\.line), [3, 4, 6])
        XCTAssertFalse(playlist.isStreaming)
    }

    /// An #EXTINF gives the next entry its title, and only that entry.
    func testExtinfTitleIsForTheNextEntryOnly() {
        let playlist = M3UPlaylist.parse("#EXTINF:12,First\na.mp3\nb.mp3")
        XCTAssertEqual(playlist.entries.map(\.title), ["First", nil])
    }

    /// The title follows the first comma outside a quoted attribute value.
    func testExtinfWithAttributes() {
        let playlist = M3UPlaylist.parse("#EXTINF:-1 tvg-name=\"a,b\" group-title=\"x\",Title, with comma\na.mp3")
        XCTAssertEqual(playlist.entries.first?.title, "Title, with comma")
    }

    /// An #EXTINF with no comma outside quotes, or a blank title, leaves the
    /// title nil.
    func testExtinfWithoutATitle() {
        let playlist = M3UPlaylist.parse("#EXTINF:5\na.mp3\n#EXTINF:5,   \nb.mp3\n#EXTINF:5 tvg-name=\"a,b\"\nc.mp3")
        XCTAssertEqual(playlist.entries.map(\.title), [nil, nil, nil])
    }

    /// #PLAYLIST names the playlist, a blank one leaves the name, and other
    /// # lines are comments, not entries.
    func testPlaylistTitleCommentsAndBlankLines() {
        let playlist = M3UPlaylist.parse("#EXTM3U\n#PLAYLIST: My Mix \n# a comment\n\n   \na.mp3\n#PLAYLIST:\n")
        XCTAssertEqual(playlist.entries.map(\.location), ["a.mp3"])
        XCTAssertEqual(playlist.title, "My Mix")
        XCTAssertNil(M3UPlaylist.parse("#PLAYLIST:  \na.mp3").title)
    }

    /// An empty text is an empty playlist.
    func testEmptyPlaylist() {
        let playlist = M3UPlaylist.parse("")
        XCTAssertTrue(playlist.entries.isEmpty)
        XCTAssertNil(playlist.title)
        XCTAssertFalse(playlist.listsOnlyWebAddresses)
        XCTAssertEqual(playlist.resolve(inFolder: folder), M3UPlaylist.Resolution(tracks: [], skipped: []))
    }

    /// The HLS samples, a media and a master playlist, are streaming.
    func testHLSSamplesAreStreaming() throws {
        for name in ["hls-media.m3u8", "hls-master.m3u8"] {
            let playlist = try M3UPlaylist.read(at: Self.samplesFolder.appendingPathComponent("m3u8/\(name)"))
            XCTAssertTrue(playlist.isStreaming, name)
        }
    }

    /// Playlist files are recognized by extension, in any case.
    func testIsPlaylist() {
        XCTAssertTrue(M3UPlaylist.isPlaylist(URL(fileURLWithPath: "/a/list.m3u")))
        XCTAssertTrue(M3UPlaylist.isPlaylist(URL(fileURLWithPath: "/a/list.M3U8")))
        XCTAssertFalse(M3UPlaylist.isPlaylist(URL(fileURLWithPath: "/a/list.txt")))
    }

    // MARK: - read

    /// The Latin-1 sample reads by the decoder's fallback, with its titles.
    func testReadLatin1Sample() throws {
        let sample = try copySampleFolder("m3u")
        let playlist = try M3UPlaylist.read(at: sample.appendingPathComponent("playlist.m3u"))
        XCTAssertEqual(playlist.entries.map(\.title), [
            "Café tone, 440 Hz", "Señal two - 660 Hz", "Third (subfolder-free)", "Fourth in a subfolder",
        ])
    }

    /// A playlist over 4 MiB is refused by name; one exactly at the limit is read.
    func testReadRefusesAFileOverFourMebibytes() throws {
        // One entry, then a comment line padding the file to the limit.
        let entry = "track.mp3\n"
        let padding = "#" + String(repeating: "x", count: M3UPlaylist.maximumByteCount - entry.utf8.count - 1)
        let atLimit = try write(entry + padding, to: "limit.m3u")
        XCTAssertEqual(try M3UPlaylist.read(at: atLimit).entries.count, 1)

        let large = try write(entry + padding + "x", to: "large.m3u")
        XCTAssertThrowsError(try M3UPlaylist.read(at: large)) { error in
            XCTAssertEqual(error as? M3UPlaylistError, .tooLarge(fileName: "large.m3u"))
            XCTAssertEqual(error.localizedDescription, "The playlist “large.m3u” is too large to read.")
        }
    }

    /// A file that cannot be opened throws the system's error as it is.
    func testReadOfAMissingFileThrows() {
        XCTAssertThrowsError(try M3UPlaylist.read(at: folder.appendingPathComponent("none.m3u"))) { error in
            XCTAssertNil(error as? M3UPlaylistError)
        }
    }

    // MARK: - resolve on the samples

    /// The Latin-1 sample gives four tracks in order, the last found through
    /// a backslash path into `more/`.
    func testResolveLatin1Sample() throws {
        let sample = try copySampleFolder("m3u")
        let resolution = try M3UPlaylist.read(at: sample.appendingPathComponent("playlist.m3u")).resolve(inFolder: sample)
        XCTAssertEqual(resolution.tracks.map(\.path), ["tone1.wav", "tone2.wav", "tone3.wav", "more/tone4.wav"])
        XCTAssertEqual(resolution.tracks.map(\.title), [
            "Café tone, 440 Hz", "Señal two - 660 Hz", "Third (subfolder-free)", "Fourth in a subfolder",
        ])
        XCTAssertTrue(resolution.skipped.isEmpty)
        XCTAssertEqual(resolution.tracks.map(\.url.lastPathComponent), ["tone1.wav", "tone2.wav", "tone3.wav", "tone4.wav"])
    }

    /// The edge-case sample keeps its two real files and names what it skips.
    func testResolveEdgeCasesSample() throws {
        let sample = try copySampleFolder("m3u")
        let resolution = try M3UPlaylist.read(at: sample.appendingPathComponent("edge-cases.m3u")).resolve(inFolder: sample)
        XCTAssertEqual(resolution.tracks.map(\.path), ["tone2.wav", "tone1.wav"])
        XCTAssertEqual(skips(resolution), [
            ["missing-file.wav", "not found"],
            ["../outside-the-folder.wav", "outside the playlist's folder"],
            ["/System/Library/Sounds/Basso.aiff", "outside the playlist's folder"],
            ["http://example.invalid/stream.mp3", "a web address"],
        ])
    }

    /// The UTF-8 sample gives three tracks with their titles.
    func testResolveUTF8Sample() throws {
        let sample = try copySampleFolder("m3u8")
        let resolution = try M3UPlaylist.read(at: sample.appendingPathComponent("playlist.m3u8")).resolve(inFolder: sample)
        XCTAssertEqual(resolution.tracks.map(\.path), ["tone1.wav", "tone2.wav", "tone3.wav"])
        XCTAssertEqual(resolution.tracks.map(\.title), ["Zażółć — 第一 (440 Hz)", "Café ❤ two", "Τρίτο (880 Hz)"])
    }

    // MARK: - resolve on made folders

    /// A symbolic link inside the folder that points outside is outside, and
    /// a link to a file inside is that file.
    func testSymbolicLinkPointingOutsideIsOutside() throws {
        let other = try AudioTestFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: other) }
        let target = other.appendingPathComponent("elsewhere.wav")
        try Data("x".utf8).write(to: target)
        let real = try touch("inner/real.wav")
        let inner = real.deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(at: inner.appendingPathComponent("link.wav"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: inner.appendingPathComponent("alias.wav"), withDestinationURL: real)

        let resolution = resolve(["inner/link.wav", "inner/alias.wav"])
        XCTAssertEqual(skips(resolution), [["inner/link.wav", "outside the playlist's folder"]])
        XCTAssertEqual(resolution.tracks.map(\.path), ["inner/real.wav"])
    }

    /// `realpath(3)` of `url`, to compare with what `resolve` found.
    private func realPath(_ url: URL) throws -> String {
        let resolved = try XCTUnwrap(realpath(url.path, nil))
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// A component that cannot be resolved (missing, a dangling link, or a
    /// link loop) before `/../extras/diary.m4a`, with `extras` a link to a
    /// folder outside, must not hide the outside: Foundation removes
    /// `x/..` by name and the link is then followed. The outside file is
    /// never a track (review item 2).
    func testUnresolvableComponentBeforeParentDoesNotHideALinkOutside() throws {
        let other = try AudioTestFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: other) }
        try Data("x".utf8).write(to: other.appendingPathComponent("diary.m4a"))
        let fileManager = FileManager.default
        try fileManager.createSymbolicLink(at: folder.appendingPathComponent("extras"), withDestinationURL: other)
        try fileManager.createSymbolicLink(
            at: folder.appendingPathComponent("dangling"),
            withDestinationURL: folder.appendingPathComponent("no-such-target"))
        try fileManager.createSymbolicLink(atPath: folder.appendingPathComponent("loopA").path, withDestinationPath: "loopB")
        try fileManager.createSymbolicLink(atPath: folder.appendingPathComponent("loopB").path, withDestinationPath: "loopA")

        let entries = [
            "nothing-here/../extras/diary.m4a", "dangling/../extras/diary.m4a", "loopA/../extras/diary.m4a",
            "extras/diary.m4a",
        ]
        let resolution = resolve(entries)
        XCTAssertTrue(resolution.tracks.isEmpty)
        XCTAssertEqual(skips(resolution), entries.map { [$0, "outside the playlist's folder"] })
    }

    /// A link inside the folder to a file inside gives the fully resolved
    /// file: its URL has no link left in it.
    func testFoundTrackHasItsFullyResolvedURL() throws {
        let real = try touch("inner/real.wav")
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("alias.wav"), withDestinationURL: real)
        let resolution = resolve(["alias.wav"])
        XCTAssertEqual(resolution.tracks.map(\.path), ["inner/real.wav"])
        XCTAssertEqual(resolution.tracks.first?.url.path, try realPath(real))
    }

    /// A playlist folder spelled `/tmp/…` (a link to `/private/tmp/…`) finds
    /// its files, whichever way the two sides are resolved.
    func testFolderGivenThroughTheTmpLink() throws {
        let name = "m3usafety-\(UUID().uuidString)"
        let real = URL(fileURLWithPath: "/private/tmp/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: real) }
        try Data("x".utf8).write(to: real.appendingPathComponent("tone.wav"))

        let throughTheLink = URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true)
        let resolution = M3UPlaylist.parse("tone.wav").resolve(inFolder: throughTheLink)
        XCTAssertEqual(resolution.tracks.map(\.path), ["tone.wav"])
        XCTAssertEqual(resolution.tracks.first?.url.path, "/private/tmp/\(name)/tone.wav")
        XCTAssertTrue(resolution.skipped.isEmpty)
    }

    /// A path that goes up and back down inside the folder is inside; a
    /// sibling folder whose name starts with the folder's name, the folder
    /// itself, and a path above it are outside.
    func testParentComponentsAndNamePrefixes() throws {
        try touch("tone1.wav")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("more"), withIntermediateDirectories: true)
        let sibling = URL(fileURLWithPath: folder.path + "-extra", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sibling) }
        try Data("x".utf8).write(to: sibling.appendingPathComponent("a.wav"))

        let siblingEntry = "../\(sibling.lastPathComponent)/a.wav"
        let resolution = resolve(["more/../tone1.wav", siblingEntry, ".", "./", ".."])
        XCTAssertEqual(resolution.tracks.map(\.path), ["tone1.wav"])
        XCTAssertEqual(resolution.skipped.map(\.reason.words), Array(repeating: "outside the playlist's folder", count: 4))
    }

    /// A percent-escaped name is decoded when the escaped one is not there,
    /// and a file really named with a percent sign is found as it is.
    func testPercentEscapes() throws {
        try touch("tone 1.wav")
        try touch("100%.wav")
        let resolution = resolve(["tone%201.wav", "100%.wav", "nothing%20here.wav"])
        XCTAssertEqual(resolution.tracks.map(\.path), ["tone 1.wav", "100%.wav"])
        XCTAssertEqual(skips(resolution), [["nothing%20here.wav", "not found"]])
    }

    /// A file: URL inside the folder is a track (escapes decoded); one
    /// outside is outside; another scheme is a web address, in any case.
    func testFileURLs() throws {
        try touch("tone 1.wav")
        let inside = URL(fileURLWithPath: folder.path + "/tone 1.wav").absoluteString
        let outside = URL(fileURLWithPath: "/System/Library/Sounds/Basso.aiff").absoluteString
        let resolution = resolve([inside, outside, "FTP://host/a.mp3", "https://example.invalid/a.mp3"])
        XCTAssertEqual(resolution.tracks.map(\.path), ["tone 1.wav"])
        XCTAssertEqual(skips(resolution), [
            [outside, "outside the playlist's folder"],
            ["FTP://host/a.mp3", "a web address"],
            ["https://example.invalid/a.mp3", "a web address"],
        ])
    }

    /// A folder, a text file, and a missing file are named with their reasons;
    /// an upper-case extension is still audio.
    func testFolderNotAudioAndMissing() throws {
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("album.mp3"), withIntermediateDirectories: true)
        try touch("notes.txt")
        try touch("LOUD.MP3")
        let resolution = resolve(["album.mp3", "notes.txt", "gone.mp3", "LOUD.MP3"])
        XCTAssertEqual(skips(resolution), [
            ["album.mp3", "a folder"], ["notes.txt", "not an audio file"], ["gone.mp3", "not found"],
        ])
        XCTAssertEqual(resolution.tracks.map(\.path), ["LOUD.MP3"])
    }

    /// The same file spelled twice is a track once, and the others are listed before.
    func testRepeatedFileIsListedBefore() throws {
        try touch("tone1.wav")
        let resolution = resolve(["tone1.wav", "./tone1.wav", "more/../tone1.wav"])
        XCTAssertEqual(resolution.tracks.count, 1)
        XCTAssertEqual(skips(resolution), [["./tone1.wav", "listed before"], ["more/../tone1.wav", "listed before"]])
    }

    /// A name spelled decomposed (NFD) in the playlist finds the file named
    /// precomposed (NFC) on disk, and the two spellings are one file.
    func testUnicodeNormalizationForms() throws {
        let precomposed = "caf\u{E9}.wav"
        let decomposed = "cafe\u{301}.wav"
        try touch(precomposed)
        let resolution = resolve([decomposed, precomposed])
        XCTAssertEqual(resolution.tracks.count, 1)
        XCTAssertEqual(resolution.tracks.first?.path.precomposedStringWithCanonicalMapping, precomposed)
        XCTAssertEqual(resolution.skipped.map(\.reason.words), ["listed before"])
    }

    /// A Windows drive path is outside the folder, never looked for.
    func testWindowsDrivePath() {
        let resolution = resolve(["C:\\Music\\x.mp3", "d:/x.mp3"])
        XCTAssertTrue(resolution.tracks.isEmpty)
        XCTAssertEqual(skips(resolution), [
            ["C:\\Music\\x.mp3", "outside the playlist's folder"], ["d:/x.mp3", "outside the playlist's folder"],
        ])
    }

    /// A playlist of web addresses only is flagged; one with a file is not.
    func testListsOnlyWebAddresses() {
        XCTAssertTrue(M3UPlaylist.parse("http://a.invalid/1.mp3\nhttps://a.invalid/2.mp3").listsOnlyWebAddresses)
        XCTAssertFalse(M3UPlaylist.parse("http://a.invalid/1.mp3\n2.mp3").listsOnlyWebAddresses)
        XCTAssertFalse(M3UPlaylist.parse("file:///a/1.mp3").listsOnlyWebAddresses)
        XCTAssertFalse(M3UPlaylist.parse("C:\\a.mp3").listsOnlyWebAddresses)
    }

    /// Each reason has the words a listener hears.
    func testSkipReasonWords() {
        let all: [M3UPlaylist.SkipReason] = [.webAddress, .outsideFolder, .missing, .folder, .notAudio, .listedBefore]
        XCTAssertEqual(all.map(\.words), [
            "a web address", "outside the playlist's folder", "not found", "a folder", "not an audio file", "listed before",
        ])
    }

    /// Five thousand entries parse and resolve in under two seconds.
    func testFiveThousandEntries() throws {
        try touch("tone1.wav")
        // A mix of a repeated real file, missing files, and web addresses.
        var lines = ["#EXTM3U"]
        for index in 0..<5_000 {
            lines.append("#EXTINF:1,Track \(index)")
            lines.append(["tone1.wav", "missing\(index).wav", "http://a.invalid/\(index).mp3"][index % 3])
        }
        let text = lines.joined(separator: "\r\n")
        let start = Date()
        let playlist = M3UPlaylist.parse(text)
        let resolution = playlist.resolve(inFolder: folder)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(playlist.entries.count, 5_000)
        XCTAssertEqual(resolution.tracks.count, 1)
        XCTAssertEqual(resolution.skipped.count, 4_999)
        XCTAssertLessThan(elapsed, 2)
    }
}

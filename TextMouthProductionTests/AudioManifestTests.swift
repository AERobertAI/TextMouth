import XCTest
@testable import TextMouth

/// The manifest.json an archive of audio tracks can carry: where it is
/// found, how its names are spelled, and how it is read. Each test lays out
/// an audiobook's folder of its own under the temporary directory; the
/// tracks are empty files, since nothing here plays or measures them.
final class AudioManifestTests: XCTestCase {
    /// The audiobook folder this test lays out, removed when it ends.
    private var folder: URL!

    override func setUpWithError() throws {
        folder = try AudioTestFixtures.makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed.
        if let folder {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: - Where the Manifest Lies

    /// A manifest at the folder's top level is found there, and names
    /// tracks from the top level, a track in a folder by its folder too.
    func testManifestAtTheTopLevelIsFoundThere() throws {
        try write("{}", to: "manifest.json")
        try write("", to: "Discs/01.ogg")

        let location = try XCTUnwrap(AudioManifestLocation.find(in: folder))

        XCTAssertEqual(location.url.lastPathComponent, "manifest.json")
        XCTAssertEqual(location.url.deletingLastPathComponent().path, folder.path)
        XCTAssertEqual(location.prefix, "")
        XCTAssertEqual(location.name(ofTrackAt: "Discs/01.ogg"), "Discs/01.ogg")
        XCTAssertEqual(location.path(ofTrackNamed: "Discs/01.ogg"), "Discs/01.ogg")
    }

    /// Finder's Compress command puts a folder's contents under the
    /// folder's name, with its resource forks in `__MACOSX`: a manifest
    /// made beside the tracks is found inside that one folder, and names
    /// the tracks from there. Hidden entries and `__MACOSX` beside the
    /// folder do not count against it.
    func testManifestInsideTheOnlyFolderIsFoundThere() throws {
        try write("{}", to: "Radio Plays/manifest.json")
        try write("", to: "Radio Plays/elegy.ogg")
        try write("", to: "__MACOSX/Radio Plays/._elegy.ogg")
        try write("", to: ".DS_Store")

        let location = try XCTUnwrap(AudioManifestLocation.find(in: folder))

        XCTAssertEqual(location.url.lastPathComponent, "manifest.json")
        XCTAssertEqual(location.url.deletingLastPathComponent().lastPathComponent, "Radio Plays")
        XCTAssertEqual(location.prefix, "Radio Plays/")
        XCTAssertEqual(location.name(ofTrackAt: "Radio Plays/elegy.ogg"), "elegy.ogg")
        XCTAssertEqual(location.path(ofTrackNamed: "elegy.ogg"), "Radio Plays/elegy.ogg")
    }

    /// A manifest at the top level is the one used, even when the one
    /// folder beside it holds another.
    func testManifestAtTheTopLevelComesFirst() throws {
        try write("{}", to: "manifest.json")
        try write("{}", to: "Radio Plays/manifest.json")

        XCTAssertEqual(try XCTUnwrap(AudioManifestLocation.find(in: folder)).prefix, "")
    }

    /// Two visible folders at the top level are no wrapper: a manifest in
    /// either is not looked for, and only a top-level one would count.
    func testTwoFoldersAtTheTopLevelHaveNoWrapper() throws {
        try write("{}", to: "Part One/manifest.json")
        try write("", to: "Part One/01.ogg")
        try write("", to: "Part Two/02.ogg")

        XCTAssertNil(AudioManifestLocation.find(in: folder))
    }

    /// A visible file beside the one folder means the folder is no
    /// wrapper either.
    func testAFileBesideTheOneFolderMeansNoWrapper() throws {
        try write("{}", to: "Radio Plays/manifest.json")
        try write("", to: "cover.jpg")

        XCTAssertNil(AudioManifestLocation.find(in: folder))
    }

    /// A wrapper folder without a manifest, and a folder with nothing at
    /// all, have none.
    func testFolderWithoutAManifestHasNone() throws {
        XCTAssertNil(AudioManifestLocation.find(in: folder))
        try write("", to: "Radio Plays/elegy.ogg")
        XCTAssertNil(AudioManifestLocation.find(in: folder))
    }

    /// A symbolic link to a folder is not a wrapper folder: what it leads
    /// to is not inside the book.
    func testALinkedFolderIsNoWrapper() throws {
        let elsewhere = try AudioTestFixtures.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try Data("{}".utf8).write(to: elsewhere.appendingPathComponent("manifest.json"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("Radio Plays"), withDestinationURL: elsewhere)

        XCTAssertNil(AudioManifestLocation.find(in: folder))
    }

    // MARK: - Reading the Manifest

    /// A manifest is read wherever it lies, with its location, and a UTF-8
    /// byte order mark at its start is passed over.
    func testManifestIsReadPastAByteOrderMark() throws {
        let json = Data(#"{"title": "Harbor Plays", "author": "Wenzel Okafor"}"#.utf8)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Radio Plays"), withIntermediateDirectories: true)
        try (Data([0xEF, 0xBB, 0xBF]) + json).write(to: folder.appendingPathComponent("Radio Plays/manifest.json"))

        let found = try XCTUnwrap(AudioManifest.read(inAudioFolder: folder))

        XCTAssertEqual(found.manifest.title, "Harbor Plays")
        XCTAssertEqual(found.manifest.author, "Wenzel Okafor")
        XCTAssertEqual(found.location.prefix, "Radio Plays/")
    }

    /// A manifest that cannot be decoded is read as none, so a book whose
    /// manifest went wrong after its import still opens, in Finder's order.
    func testManifestThatCannotBeDecodedIsReadAsNone() throws {
        try write(#"{"title": 7}"#, to: "manifest.json")
        XCTAssertNil(AudioManifest.read(inAudioFolder: folder))
        try write("not JSON at all", to: "manifest.json")
        XCTAssertNil(AudioManifest.read(inAudioFolder: folder))
    }

    // MARK: - Helpers

    /// Write `text` as UTF-8 to `path` inside this test's folder, making
    /// the folders on the way.
    private func write(_ text: String, to path: String) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

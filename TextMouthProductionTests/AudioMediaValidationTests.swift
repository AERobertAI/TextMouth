import XCTest
@testable import TextMouth

/// An audiobook's media is checked before its sections are trusted (TODO
/// I04). Every file is real audio written by `AudioTestFixtures`, in a folder
/// of the test's own under the temporary directory.
final class AudioMediaValidationTests: XCTestCase {
    /// The audiobook folder this test parses, removed when the test ends.
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

    // MARK: - Valid Media Parses As Before

    /// A converted DAISY book's sections, two sharing one file and one
    /// playing a second file to its end, parse exactly as they always have:
    /// the same titles, headings, files, and sections, and ten placeholder
    /// characters per second of audio, with a section shorter than a second
    /// still given a second's worth.
    func testValidSectionsParseExactlyAsBefore() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"), duration: 2)
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("b.wav"), duration: 1)
        let sections = [
            AudioSegment(title: "Opening", file: "a.wav", startTime: 0, endTime: 0.5),
            AudioSegment(title: "Harbor Survey", file: "a.wav", startTime: 0.5, endTime: 2),
            AudioSegment(title: "Closing Notes", file: "b.wav", startTime: 0, endTime: 0)
        ]
        try writeManifest(title: "Harbor Soundings", author: "Odile Marchetti", sections: sections)

        let parsed = try await AudioBookParser.parseDirectory(url: folder)

        XCTAssertEqual(parsed.content.title, "Harbor Soundings")
        XCTAssertEqual(parsed.content.author, "Odile Marchetti")
        XCTAssertEqual(parsed.content.chapters.map(\.title), ["Opening", "Harbor Survey", "Closing Notes"])
        XCTAssertEqual(parsed.content.chapters.map(\.text.count), [10, 15, 10])
        XCTAssertEqual(
            parsed.content.chapters.map { $0.headings.map { "\($0.level) \($0.text) @\($0.chapterIndex):\($0.characterOffset)" } },
            [["1 Opening @0:0"], ["1 Harbor Survey @1:0"], ["1 Closing Notes @2:0"]]
        )
        XCTAssertEqual(parsed.filePaths, ["a.wav", "a.wav", "b.wav"].map { folder.appendingPathComponent($0).path })
        XCTAssertEqual(describe(parsed.segments), describe(sections))
    }

    /// A folder of tracks without sections still makes one heading per
    /// track, in Finder's order, titled by the manifest where it names the
    /// track and by the file's name otherwise.
    func testValidTracksParseExactlyAsBefore() async throws {
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("Disc 1/01.wav"), duration: 1)
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("Disc 1/02.wav"), duration: 2)
        try writeManifest(chapterTitles: ["Disc 1/02.wav": "Tide Tables"])

        let parsed = try await AudioBookParser.parseDirectory(url: folder)

        XCTAssertEqual(parsed.content.chapters.map(\.title), ["01", "Tide Tables"])
        XCTAssertEqual(parsed.content.chapters.map(\.text.count), [10, 20])
        XCTAssertEqual(
            parsed.filePaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            ["Disc 1/01.wav", "Disc 1/02.wav"].map { folder.appendingPathComponent($0).resolvingSymlinksInPath().path }
        )
        XCTAssertNil(parsed.segments)
    }

    /// A single file without chapter markers is one section, titled by its
    /// file name, as long as the file plays.
    func testValidSingleFileParsesExactlyAsBefore() async throws {
        let file = folder.appendingPathComponent("Ferry Timetables.wav")
        try AudioTestFixtures.writeSilence(to: file, duration: 2)

        let content = try await AudioBookParser.parse(url: file)

        XCTAssertEqual(content.title, "Ferry Timetables")
        XCTAssertEqual(content.author, "Unknown")
        XCTAssertEqual(content.chapters.map(\.title), ["Ferry Timetables"])
        XCTAssertEqual(content.chapters.map(\.text.count), [20])
    }

    // MARK: - Helpers

    /// Write this test's manifest.json: the book's title and author, the
    /// titles of whole-file tracks, and the sections, as an import or the
    /// DAISY converter writes it.
    private func writeManifest(
        title: String? = nil,
        author: String? = nil,
        chapterTitles: [String: String]? = nil,
        sections: [AudioSegment]? = nil
    ) throws {
        let manifest = AudioManifest(title: title, author: author, chapters: chapterTitles, segments: sections)
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
    }

    /// Sections as "title | file | start–end" lines, which compare as a
    /// whole and read clearly in a failure message (`AudioSegment` is not
    /// `Equatable`).
    private func describe(_ sections: [AudioSegment]?) -> [String] {
        (sections ?? []).map { "\($0.title) | \($0.file) | \($0.startTime)–\($0.endTime)" }
    }
}

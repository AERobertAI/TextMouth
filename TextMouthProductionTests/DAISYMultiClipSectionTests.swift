import XCTest
@testable import TextMouth

/// A DAISY heading whose narration continues past one audio clip, into
/// other files or other parts of one, plays every clip in order (TODO I03).
/// These tests cover a section's clips as manifest.json stores them.
final class DAISYMultiClipSectionTests: XCTestCase {

    // MARK: - Sections in manifest.json

    /// A section written before sections held several clips names one file
    /// and one time range; it reads as a section of exactly that one clip.
    func testSectionWithoutAClipListReadsAsOneClip() throws {
        let json = #"{"title":"Tide Tables","file":"Disc 1/03.mp3","startTime":12.5,"endTime":40}"#

        let segment = try JSONDecoder().decode(AudioSegment.self, from: Data(json.utf8))

        XCTAssertEqual(segment.title, "Tide Tables")
        XCTAssertEqual(segment.clips, [AudioClip(file: "Disc 1/03.mp3", startTime: 12.5, endTime: 40)])
        XCTAssertEqual(segment.file, "Disc 1/03.mp3")
        XCTAssertEqual(segment.startTime, 12.5)
        XCTAssertEqual(segment.endTime, 40)
    }

    /// A one-clip section is written exactly as it always was, with no
    /// clip list, so manifests of one-clip sections do not change.
    func testOneClipSectionIsWrittenWithoutAClipList() throws {
        let segment = AudioSegment(title: "Tide Tables", file: "03.mp3", startTime: 12.5, endTime: 40)

        XCTAssertEqual(
            try Self.sortedJSON(segment),
            #"{"endTime":40,"file":"03.mp3","startTime":12.5,"title":"Tide Tables"}"#
        )
    }

    /// A section of several clips lists every clip and reads back the same,
    /// and still keeps its first clip where a reader that knows one clip
    /// per section looks for it.
    func testSeveralClipSectionRoundTripsAndKeepsItsFirstClipWhereOlderReadersLook() throws {
        let segment = try XCTUnwrap(AudioSegment(title: "Harbor Survey", clips: Self.threeFiles))
        let data = try JSONEncoder().encode(segment)

        XCTAssertEqual(try JSONDecoder().decode(AudioSegment.self, from: data), segment)
        let older = try JSONDecoder().decode(OneClipSection.self, from: data)
        XCTAssertEqual(older.title, "Harbor Survey")
        XCTAssertEqual(older.file, "a.mp3")
        XCTAssertEqual(older.startTime, 30)
        XCTAssertEqual(older.endTime, 60)
    }

    /// A manifest's sections, of one clip and of several, survive a round
    /// trip through manifest.json together.
    func testManifestKeepsEverySectionsClips() throws {
        let manifest = AudioManifest(
            title: "Harbor Soundings",
            author: "Odile Marchetti",
            segments: [
                AudioSegment(title: "Opening", file: "a.mp3", startTime: 0, endTime: 30),
                try XCTUnwrap(AudioSegment(title: "Harbor Survey", clips: Self.threeFiles))
            ]
        )

        let decoded = try JSONDecoder().decode(AudioManifest.self, from: JSONEncoder().encode(manifest))

        XCTAssertEqual(decoded.segments, manifest.segments)
    }

    /// An empty clip list, as a hand-edited manifest could hold, names no
    /// clip at all; the section's own fields still give its one clip.
    func testEmptyClipListFallsBackToTheSectionsOwnClip() throws {
        let json = #"{"title":"Coda","file":"c.mp3","startTime":1,"endTime":0,"clips":[]}"#

        let segment = try JSONDecoder().decode(AudioSegment.self, from: Data(json.utf8))

        XCTAssertEqual(segment.clips, [AudioClip(file: "c.mp3", startTime: 1, endTime: 0)])
    }

    /// The clip list, when present, is the section: fields that disagree
    /// with its first clip, as a hand edit can leave them, are ignored.
    func testClipListWinsOverTheFieldsBesideIt() throws {
        let json = #"{"title":"Coda","file":"stale.mp3","startTime":9,"endTime":9.5,"clips":"#
            + #"[{"file":"b.mp3","startTime":0,"endTime":2},{"file":"c.mp3","startTime":0,"endTime":3}]}"#

        let segment = try JSONDecoder().decode(AudioSegment.self, from: Data(json.utf8))

        XCTAssertEqual(segment.clips, [
            AudioClip(file: "b.mp3", startTime: 0, endTime: 2),
            AudioClip(file: "c.mp3", startTime: 0, endTime: 3)
        ])
        XCTAssertEqual(segment.file, "b.mp3")
    }

    /// A section always plays something, so there is no section of no clips.
    func testSectionNeedsAtLeastOneClip() {
        XCTAssertNil(AudioSegment(title: "Silence", clips: []))
    }

    /// Mapping a section's clips keeps every clip, in order, and the title.
    func testMappingClipsKeepsEveryClipInOrder() throws {
        let segment = try XCTUnwrap(AudioSegment(title: "Harbor Survey", clips: Self.threeFiles))

        let shifted = segment.mappingClips { clip in
            AudioClip(file: clip.file, startTime: clip.startTime + 1, endTime: clip.endTime)
        }

        XCTAssertEqual(shifted.title, "Harbor Survey")
        XCTAssertEqual(shifted.clips.map(\.file), ["a.mp3", "b.mp3", "c.mp3"])
        XCTAssertEqual(shifted.clips.map(\.startTime), [31, 1, 1])
    }

    // MARK: - Fixtures

    /// One heading's clips in three files: the second half of the first
    /// file, the start of the second, and all of the third (an end of 0
    /// plays to the end of the file).
    private static let threeFiles = [
        AudioClip(file: "a.mp3", startTime: 30, endTime: 60),
        AudioClip(file: "b.mp3", startTime: 0, endTime: 45.5),
        AudioClip(file: "c.mp3", startTime: 0, endTime: 0)
    ]

    /// A section as a release that knew one clip per section decoded it.
    private struct OneClipSection: Decodable {
        var title: String
        var file: String
        var startTime: Double
        var endTime: Double
    }

    /// `segment` as JSON with its keys sorted, so a test can compare it
    /// with the exact text manifest.json holds.
    private static func sortedJSON(_ segment: AudioSegment) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(segment), as: UTF8.self)
    }
}

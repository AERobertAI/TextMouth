import XCTest
@testable import TextMouth

/// A transcript from outside TextMouth's recognizer, in the one transcript
/// store (FMT23, FMT25): where it came from, kept in transcript.json and in
/// the book's record so that a later TextMouth's values survive.
@MainActor
final class OutsideTranscriptTests: XCTestCase {

    // MARK: - Where a Transcript Came From

    /// A source is written with its keys sorted, as transcript.json writes
    /// every key, and leaves out a file name it does not have; it reads its
    /// origin and format as this TextMouth knows them.
    func testASourceIsWrittenWithItsKeysSorted() throws {
        XCTAssertEqual(
            try Self.sortedJSON(Self.lectureSource),
            #"{"fileName":"lecture.vtt","format":"webvtt","origin":"attached"}"#
        )
        XCTAssertEqual(try Self.sortedJSON(Self.podcastSource), #"{"format":"podcast-json","origin":"podcast"}"#)
        XCTAssertEqual(Self.lectureSource.knownOrigin, .attached)
        XCTAssertEqual(Self.lectureSource.knownFormat, .webVTT)
        XCTAssertEqual(Self.podcastSource.knownOrigin, .podcast)
        XCTAssertEqual(Self.podcastSource.knownFormat, .podcastJSON)
    }

    /// An origin and a format a later TextMouth wrote, which this one does
    /// not know, are read as they were written, known as neither, and
    /// written back unchanged.
    func testASourceALaterTextMouthWroteIsReadAndWrittenBackUnchanged() throws {
        let source = try Self.laterSource()

        XCTAssertEqual(source.origin, "radio")
        XCTAssertEqual(source.format, "ttml")
        XCTAssertEqual(source.fileName, "evening.ttml")
        XCTAssertNil(source.knownOrigin)
        XCTAssertNil(source.knownFormat)
        XCTAssertEqual(try Self.sortedJSON(source), Self.laterSourceJSON)
    }

    /// A transcript.json holding a later TextMouth's source is found in its
    /// package, not set aside as unusable, and saving the transcript again
    /// writes the source as it was.
    func testATranscriptHoldingALaterSourceIsFoundInItsPackage() throws {
        var transcript = TranscriptFixtures.twoFiles
        transcript.source = try Self.laterSource()
        let package = try makeSandboxDirectory("outside-later-source")
        let bytes = try TranscriptStore.encoded(transcript)
        try bytes.write(to: package.appendingPathComponent("transcript.json"))

        let lookup = TranscriptStore.read(from: package)

        XCTAssertEqual(lookup, .found(transcript))
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains(#""source":\#(Self.laterSourceJSON)"#))
        guard case .found(let found) = lookup else { return XCTFail("the transcript was not found") }
        XCTAssertEqual(try TranscriptStore.encoded(found), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: package.path), ["transcript.json"])
    }

    /// A transcript recognition made, which has no source, is written
    /// without one, key for key as before, and reads back the same; its
    /// note has no source either, and the record writes none.
    func testATranscriptWithoutASourceIsWrittenAsBefore() throws {
        let bytes = try TranscriptStore.encoded(TranscriptFixtures.twoFiles)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])

        XCTAssertEqual(Set(object.keys), ["app", "createdAt", "files", "locale", "model", "version"])
        let decoded = try TranscriptStore.decoded(bytes)
        XCTAssertEqual(decoded, TranscriptFixtures.twoFiles)
        XCTAssertNil(decoded.source)
        XCTAssertNil(decoded.note.source)
        let note = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded.note)) as? [String: Any])
        XCTAssertEqual(Set(note.keys), ["createdAt", "locale", "version"])
    }

    /// A transcript with a source reads back with it, and its note, which
    /// the book's record keeps, names the same source.
    func testATranscriptWithASourceReadsBackWithItAndItsNoteFollows() throws {
        var transcript = TranscriptFixtures.twoFiles
        transcript.source = Self.lectureSource

        XCTAssertEqual(try TranscriptStore.decoded(try TranscriptStore.encoded(transcript)), transcript)
        XCTAssertEqual(
            transcript.note,
            TranscriptNote(
                version: Transcript.currentVersion,
                locale: "en-US",
                createdAt: TranscriptFixtures.date,
                source: Self.lectureSource
            )
        )
    }

    /// A file's name keeps no folder before it, so no path of the
    /// listener's is ever kept or shown, and a name of nothing but white
    /// space is no name.
    func testAFileNameKeepsNoFolder() {
        func name(_ given: String) -> String? {
            TranscriptSource(origin: .attached, format: .subRip, fileName: given).fileName
        }

        XCTAssertEqual(name("lecture one.srt"), "lecture one.srt")
        XCTAssertEqual(name("Talks/2026/lecture.srt"), "lecture.srt")
        XCTAssertEqual(name("/Volumes/Archive/lecture.srt"), "lecture.srt")
        XCTAssertNil(name(""))
        XCTAssertNil(name(" \t "))
        XCTAssertNil(name("/"))
        XCTAssertNil(TranscriptSource(origin: .attached, format: .subRip).fileName)
    }

    // MARK: - Helpers

    /// The source of a transcript attached from one WebVTT file.
    private static let lectureSource = TranscriptSource(origin: .attached, format: .webVTT, fileName: "lecture.vtt")

    /// The source of a podcast's own transcript, read from no file of a
    /// name worth keeping.
    private static let podcastSource = TranscriptSource(origin: .podcast, format: .podcastJSON)

    /// A source as a later TextMouth might write it: an origin and a format
    /// this one does not know, with the keys sorted.
    private static let laterSourceJSON = #"{"fileName":"evening.ttml","format":"ttml","origin":"radio"}"#

    /// `laterSourceJSON`, read.
    private static func laterSource() throws -> TranscriptSource {
        try JSONDecoder().decode(TranscriptSource.self, from: Data(laterSourceJSON.utf8))
    }

    /// `value` as JSON with its keys sorted, as transcript.json is written.
    private static func sortedJSON(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

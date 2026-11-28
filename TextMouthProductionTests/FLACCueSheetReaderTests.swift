import XCTest
@testable import TextMouth

/// A FLAC file's CUESHEET block, and a cue sheet kept in its CUESHEET
/// comment, read by hand as chapters (FMT24, `FLACCueSheetReader`): the
/// sample's block, the sample with its CHAPTER comments hidden (so
/// AVFoundation finds none and the block is read), and blocks built here,
/// damaged ones included. Nothing is played.
final class FLACCueSheetReaderTests: XCTestCase {
    /// The sample's block gives its three tracks at their samples, the
    /// lead-out left out, and no embedded sheet.
    func testTheSampleBlockGivesThreeTracksAtTheirSamples() throws {
        let tracks = try XCTUnwrap(FLACCueSheetReader.read(at: Self.sample))

        XCTAssertEqual(tracks.sampleRate, 22_050)
        XCTAssertEqual(tracks.starts, [
            .init(number: 1, sample: 0), .init(number: 2, sample: 33_222), .init(number: 3, sample: 66_150),
        ])
        XCTAssertNil(tracks.embeddedSheet)
        let chapters = FLACCueSheetReader.chapters(of: tracks)
        XCTAssertEqual(chapters.map(\.title), ["Track 1", "Track 2", "Track 3"])
        XCTAssertEqual(chapters.map(\.start), [0, 33_222.0 / 22_050, 3])
    }

    /// The sample's own CHAPTER comments, which AVFoundation reads, are its
    /// chapters: the block never overrules them.
    func testTheSamplesCommentsWinOverItsBlock() async throws {
        let chapters = await AudioPlaybackService.extractChapters(from: Self.sample)
        XCTAssertEqual(chapters.map(\.title), ["Tone 440 Hz", "Tone 660 Hz - second", "Tone 880 Hz (café)"])
    }

    /// With its comment block turned into padding, the sample has no
    /// chapters AVFoundation reads, and its block's tracks become its
    /// chapters: each lasting until the next, the last to the end of the
    /// file's 4 seconds.
    func testWithoutItsCommentsTheSampleTakesItsChaptersFromTheBlock() async throws {
        let folder = try makeSandboxDirectory("flac-cuesheet")
        let copy = folder.appendingPathComponent("three-tones.flac")
        var bytes = [UInt8](try Data(contentsOf: Self.sample))
        let comment = try XCTUnwrap(Self.blockHeaderOffset(ofType: 4, in: bytes), "the sample keeps a comment block")
        // Padding (type 1), keeping the flag that marks the last block.
        bytes[comment] = (bytes[comment] & 0x80) | 1
        try Data(bytes).write(to: copy)

        let chapters = await AudioPlaybackService.extractChapters(from: copy)

        XCTAssertEqual(chapters.map(\.title), ["Track 1", "Track 2", "Track 3"])
        XCTAssertEqual(chapters.map(\.startTime), [0, 33_222.0 / 22_050, 3])
        XCTAssertEqual(chapters.map(\.duration).reduce(0, +), 4, accuracy: 0.01)
    }

    /// An ID3v2 tag before the "fLaC" marker, which some taggers write, is
    /// passed over; a file that is no FLAC has no tracks.
    func testATagBeforeTheMarkerIsPassedOverAndOtherFilesHaveNone() throws {
        let folder = try makeSandboxDirectory("flac-id3")
        let tagged = folder.appendingPathComponent("tagged.flac")
        let tag: [UInt8] = Array("ID3".utf8) + [4, 0, 0, 0, 0, 0, 20] + [UInt8](repeating: 0, count: 20)
        try Data(tag + [UInt8](try Data(contentsOf: Self.sample))).write(to: tagged)
        XCTAssertEqual(FLACCueSheetReader.read(at: tagged)?.starts.count, 3)

        let wave = folder.appendingPathComponent("tone.flac")
        try FileManager.default.copyItem(at: CueSheetTests.sample("cue/part1.wav"), to: wave)
        XCTAssertNil(FLACCueSheetReader.read(at: wave))
        XCTAssertEqual(FLACCueSheetReader.chapters(at: wave), [])
        XCTAssertFalse(FLACCueSheetReader.mayHoldCueSheet(CueSheetTests.sample("cue/part1.wav")))
        XCTAssertTrue(FLACCueSheetReader.mayHoldCueSheet(URL(fileURLWithPath: "/a/B.FLAC")))
    }

    // MARK: - Blocks Built Here

    /// A track begins at its index point 1, after any pregap of point 0;
    /// data tracks and the lead-out (170 or 255) are left out.
    func testTracksBeginAtIndexPointOneAndDataTracksAreLeftOut() {
        let block = Self.cueSheetBlock([
            (offset: 0, number: 1, isAudio: true, points: [(1, 0)]),
            (offset: 1_000, number: 2, isAudio: false, points: [(1, 0)]),
            (offset: 2_000, number: 3, isAudio: true, points: [(0, 0), (1, 500)]),
            (offset: 9_000, number: 4, isAudio: true, points: []),
            (offset: 10_000, number: 170, isAudio: true, points: []),
        ])
        XCTAssertEqual(FLACCueSheetReader.trackStarts(inCueSheetBlock: block), [
            .init(number: 1, sample: 0), .init(number: 3, sample: 2_500), .init(number: 4, sample: 9_000),
        ])
    }

    /// A sheet kept in the CUESHEET comment titles the block's tracks by
    /// their numbers, a track it does not name keeping "Track N"; without a
    /// block, the sheet's own tracks are the chapters.
    func testAnEmbeddedSheetTitlesTheTracks() throws {
        let text = "FILE \"rip.wav\" WAVE\n  TRACK 01 AUDIO\n    TITLE \"Overture\"\n    INDEX 01 00:00:00\n"
            + "  TRACK 02 AUDIO\n    INDEX 01 00:01:00\n"
        let block = Self.commentBlock(["TITLE=Rip", "cuesheet=" + text])
        XCTAssertEqual(FLACCueSheetReader.cueSheetComment(inVorbisCommentBlock: block), text)
        let sheet = CueSheet.parse(try XCTUnwrap(FLACCueSheetReader.cueSheetComment(inVorbisCommentBlock: block)))

        let withBlock = FLACCueSheetReader.Tracks(
            sampleRate: 1_000, starts: [.init(number: 1, sample: 0), .init(number: 2, sample: 1_000)], embeddedSheet: sheet
        )
        XCTAssertEqual(FLACCueSheetReader.chapters(of: withBlock).map(\.title), ["Overture", "Track 2"])

        let alone = FLACCueSheetReader.Tracks(sampleRate: 1_000, starts: [], embeddedSheet: sheet)
        XCTAssertEqual(FLACCueSheetReader.chapters(of: alone), [
            NeroChapterReader.Chapter(title: "Overture", start: 0),
            NeroChapterReader.Chapter(title: "Track 2", start: 1),
        ])
        XCTAssertNil(FLACCueSheetReader.cueSheetComment(inVorbisCommentBlock: Self.commentBlock(["TITLE=Rip"])))
    }

    /// A block or comment cut anywhere, and bytes of any kind, never trap:
    /// what was read whole before the break is kept, and nothing else.
    func testDamagedBlocksNeverTrap() {
        let block = Self.cueSheetBlock([
            (offset: 0, number: 1, isAudio: true, points: [(1, 0)]),
            (offset: 5_000, number: 2, isAudio: true, points: [(1, 0)]),
        ])
        for length in 0...block.count {
            let starts = FLACCueSheetReader.trackStarts(inCueSheetBlock: Array(block.prefix(length)))
            XCTAssertLessThanOrEqual(starts.count, 2, "cut at \(length)")
        }
        let comments = Self.commentBlock(["CUESHEET=TRACK 01 AUDIO"])
        for length in 0...comments.count {
            _ = FLACCueSheetReader.cueSheetComment(inVorbisCommentBlock: Array(comments.prefix(length)))
        }
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let noise = (0..<Int.random(in: 0...600, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            _ = FLACCueSheetReader.trackStarts(inCueSheetBlock: noise)
            _ = FLACCueSheetReader.cueSheetComment(inVorbisCommentBlock: noise)
            _ = FLACCueSheetReader.streamInfoSampleRate(noise)
        }
        // A track whose offset and index point overflow together is left out.
        let huge = Self.cueSheetBlock([(offset: UInt64.max, number: 1, isAudio: true, points: [(1, 1)])])
        XCTAssertEqual(FLACCueSheetReader.trackStarts(inCueSheetBlock: huge), [])
    }

    // MARK: - Helpers

    /// The FLAC sample with three CHAPTER comments and a CUESHEET block.
    static let sample = CueSheetTests.sample("flac-chapters/three-tones.flac")

    /// Where the header of the first metadata block of `type` lies in the
    /// FLAC file `bytes`, walking from just past "fLaC"; nil when it has none.
    static func blockHeaderOffset(ofType type: UInt8, in bytes: [UInt8]) -> Int? {
        var position = 4
        while position + 4 <= bytes.count {
            let length = Int(bytes[position + 1]) << 16 | Int(bytes[position + 2]) << 8 | Int(bytes[position + 3])
            if bytes[position] & 0x7F == type { return position }
            if bytes[position] & 0x80 != 0 { return nil }
            position += 4 + length
        }
        return nil
    }

    /// A CUESHEET block's bytes listing `tracks`, each with its index points
    /// (number, offset from the track's own).
    static func cueSheetBlock(
        _ tracks: [(offset: UInt64, number: UInt8, isAudio: Bool, points: [(UInt8, UInt64)])]
    ) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: 128) + bigEndian(0, 8) + [0] + [UInt8](repeating: 0, count: 258)
        block.append(UInt8(tracks.count))
        for track in tracks {
            block += bigEndian(track.offset, 8) + [track.number] + [UInt8](repeating: 0, count: 12)
            block += [track.isAudio ? 0 : 0x80] + [UInt8](repeating: 0, count: 13) + [UInt8(track.points.count)]
            for (number, offset) in track.points {
                block += bigEndian(offset, 8) + [number, 0, 0, 0]
            }
        }
        return block
    }

    /// A VORBIS_COMMENT block's bytes holding `comments`.
    static func commentBlock(_ comments: [String]) -> [UInt8] {
        let vendor = Array("test vendor".utf8)
        var block = littleEndian(UInt32(vendor.count)) + vendor + littleEndian(UInt32(comments.count))
        for comment in comments {
            let bytes = Array(comment.utf8)
            block += littleEndian(UInt32(bytes.count)) + bytes
        }
        return block
    }

    /// `value` as `count` big-endian bytes.
    static func bigEndian(_ value: UInt64, _ count: Int) -> [UInt8] {
        (0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> (UInt64($0) * 8)) }
    }

    /// `value` as four little-endian bytes.
    static func littleEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (UInt32($0) * 8)) }
    }
}

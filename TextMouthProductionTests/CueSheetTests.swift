import XCTest
@testable import TextMouth

/// A cue sheet's text read as TextMouth reads it (FMT24, `CueSheet`): the
/// sheet's title and performer, its files, and each audio track's title,
/// performer, file, and start in frames of 1/75 second, from both samples and
/// from sheets written here. Nothing is played or imported.
final class CueSheetTests: XCTestCase {
    // MARK: - The Samples

    /// album.cue (UTF-8 with a byte-order mark, CRLF, comments, a pregap)
    /// gives its title and performer, its one file, and three tracks: the
    /// second with a performer of its own and its pregap ignored, the third
    /// at 37 frames past two seconds.
    func testTheAlbumSampleGivesItsTitlePerformerFileAndThreeTracks() throws {
        let sheet = try CueSheet.read(at: Self.sample("cue/album.cue"))

        XCTAssertEqual(sheet.title, "Three Tracks — café")
        XCTAssertEqual(sheet.performer, "Sample Maker")
        XCTAssertEqual(sheet.files, ["album.wav"])
        XCTAssertEqual(sheet.tracks, [
            CueSheet.Track(number: 1, title: "One: 440 Hz", performer: nil, fileIndex: 0, startFrame: 0),
            CueSheet.Track(number: 2, title: "Two: 660 Hz", performer: "Track Performer", fileIndex: 0, startFrame: 75),
            CueSheet.Track(number: 3, title: "Three: 880 Hz", performer: nil, fileIndex: 0, startFrame: 187),
        ])
        XCTAssertEqual(sheet.tracks.map(\.startTime), [0, 1, 187.0 / 75])
        XCTAssertEqual(try XCTUnwrap(sheet.tracks.last).startTime, 2.4933, accuracy: 0.0001)
    }

    /// two-files.cue (Latin 1, LF) gives its title with its accent and two
    /// files, the second's track beginning at that file's own start.
    func testTheTwoFilesSampleInLatinOneGivesBothFiles() throws {
        let sheet = try CueSheet.read(at: Self.sample("cue/two-files.cue"))

        XCTAssertEqual(sheet.title, "Two files, café")
        XCTAssertNil(sheet.performer)
        XCTAssertEqual(sheet.files, ["part1.wav", "part2.wav"])
        XCTAssertEqual(sheet.tracks.map(\.title), ["Part one, first half", "Part one, second half", "Part two"])
        XCTAssertEqual(sheet.tracks.map(\.fileIndex), [0, 0, 1])
        XCTAssertEqual(sheet.tracks.map(\.startFrame), [0, 75, 0])
    }

    // MARK: - Times

    /// A time is minutes (up to six digits), seconds below 60, and frames
    /// below 75, each in ASCII digits; anything else is no time.
    func testATimeIsMinutesSecondsAndSeventyFifthsOfASecond() {
        let times: [(String, Int?)] = [
            ("00:00:00", 0), ("00:00:01", 1), ("00:01:00", 75), ("00:02:37", 187), ("01:00:00", 4_500),
            ("0:2:37", 187), ("120:00:00", 540_000), ("999999:59:74", 999_999 * 4_500 + 59 * 75 + 74),
            ("00:60:00", nil), ("00:00:75", nil), ("1234567:00:00", nil), ("00:00", nil), ("00:00:00:00", nil),
            ("+1:00:00", nil), ("-1:00:00", nil), ("aa:00:00", nil), ("", nil), ("::", nil), ("٠١:٠٠:٠٠", nil),
        ]
        var mismatches: [String] = []
        for (time, expected) in times where CueSheet.frames(in: Substring(time)) != expected {
            mismatches.append("\(time): \(String(describing: CueSheet.frames(in: Substring(time)))), not \(String(describing: expected))")
        }
        XCTAssertEqual(mismatches, [])
    }

    // MARK: - Lines Written Here

    /// INDEX 00 (the pregap) and the later index numbers mark no start: the
    /// track begins at its INDEX 01, and a second INDEX 01 is passed over.
    func testOnlyATracksFirstIndexOneIsItsStart() {
        let sheet = CueSheet.parse("""
        FILE "a.wav" WAVE
          TRACK 01 AUDIO
            INDEX 00 00:00:00
            INDEX 01 00:02:00
            INDEX 02 00:03:00
            INDEX 01 00:04:00
        """)
        XCTAssertEqual(sheet.tracks.map(\.startFrame), [150])
    }

    /// A FILE line inside a track (the layout that appends each gap to the
    /// track before) moves the track's start into the file it names.
    func testAFileLineInsideATrackMovesItsStartIntoThatFile() {
        let sheet = CueSheet.parse("""
        FILE "01.wav" WAVE
          TRACK 01 AUDIO
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            INDEX 00 03:22:45
        FILE "02.wav" WAVE
            INDEX 01 00:00:00
        """)
        XCTAssertEqual(sheet.files, ["01.wav", "02.wav"])
        XCTAssertEqual(sheet.tracks.map(\.fileIndex), [0, 1])
        XCTAssertEqual(sheet.tracks.map(\.startFrame), [0, 0])
    }

    /// A data track, a track with no INDEX 01, and an INDEX 01 before any
    /// FILE line place nothing; a track without a type is audio.
    func testOnlyAudioTracksWithAStartInAFileAreKept() {
        let sheet = CueSheet.parse("""
        TRACK 09 AUDIO
          INDEX 01 00:00:00
        FILE "image.bin" BINARY
          TRACK 01 AUDIO
            INDEX 01 00:00:00
          TRACK 02 MODE1/2352
            INDEX 01 00:10:00
          TRACK 03 AUDIO
            INDEX 00 00:20:00
          TRACK 04
            INDEX 01 00:30:00
        """)
        XCTAssertEqual(sheet.tracks.map(\.number), [1, 4])
    }

    /// Commands are read in any letter case; values with or without quotation
    /// marks; a FILE name without them is everything before its type; a
    /// quoted value runs to its last quotation mark, or to the line's end
    /// when it is never closed; blank text is no text; REM lines and unknown
    /// commands are ignored; and lines may end in CR alone.
    func testCommandsAndValuesAreReadLeniently() {
        let sheet = CueSheet.parse(
            "rem DATE 2026\rTitle Words Without Quotes\rperformer \"\"\r"
                + "file My Album.wav wave\rtrack 1 audio\r  title \"Say \"Hi\" twice\"\r  isrc ABC\r  index 01 00:00:00\r"
                + "TRACK 02 AUDIO\r  TITLE \"Never closed\r  PERFORMER \"  \"\r  INDEX 01 00:05:00\r"
                + "FILE lonely.wav\rTRACK 03 AUDIO\rINDEX 01 00:00:00\r"
        )
        XCTAssertEqual(sheet.title, "Words Without Quotes")
        XCTAssertNil(sheet.performer)
        XCTAssertEqual(sheet.files, ["My Album.wav", "lonely.wav"])
        XCTAssertEqual(sheet.tracks.map(\.title), ["Say \"Hi\" twice", "Never closed", nil])
        XCTAssertEqual(sheet.tracks.map(\.performer), [nil, nil, nil])
        XCTAssertEqual(sheet.tracks.map(\.fileIndex), [0, 0, 1])
    }

    /// A sheet larger than the most TextMouth reads is refused by its name,
    /// and one at the limit is read.
    func testASheetPastTheLimitIsRefused() throws {
        let folder = try makeSandboxDirectory("cue-limit")
        let large = folder.appendingPathComponent("large.cue")
        try Data(repeating: 0x20, count: CueSheet.maximumByteCount + 1).write(to: large)
        XCTAssertThrowsError(try CueSheet.read(at: large)) { error in
            XCTAssertEqual(error as? CueSheetError, .tooLarge(fileName: "large.cue"))
            XCTAssertEqual(error.localizedDescription, "The cue sheet “large.cue” is too large to read.")
        }
        let limit = folder.appendingPathComponent("limit.cue")
        try Data(repeating: 0x20, count: CueSheet.maximumByteCount).write(to: limit)
        XCTAssertEqual(try CueSheet.read(at: limit).tracks, [])
    }

    /// A folder named like a sheet is not read as one.
    func testAFolderNamedLikeASheetIsNoSheet() throws {
        let folder = try makeSandboxDirectory("cue-folder").appendingPathComponent("album.cue", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertThrowsError(try CueSheet.read(at: folder))
        XCTAssertTrue(CueSheet.isCueSheet(folder))
        XCTAssertTrue(CueSheet.isCueSheet(URL(fileURLWithPath: "/a/ALBUM.CUE")))
    }

    // MARK: - Helpers

    /// The sample at `path` in TestData/format-samples.
    static func sample(_ path: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestData/format-samples", isDirectory: true)
            .appendingPathComponent(path)
    }
}

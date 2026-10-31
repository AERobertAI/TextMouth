import AppKit
import XCTest
@testable import TextMouth

/// Export of a transcript as captions (FMT23): the WebVTT and SubRip
/// writers' exact output, a transcript laid on the book's timeline, and
/// the transcript read for export.
@MainActor
final class TranscriptExportTests: XCTestCase {

    // MARK: - The Writers

    /// Two cues: the first from the start to 900 ms, the second an hour, two
    /// minutes, three seconds, and four milliseconds in, whose text holds
    /// every character WebVTT escapes.
    private static let twoCues = [
        TimedTextCue(startMilliseconds: 0, endMilliseconds: 900, text: "Ferry lines are cast off."),
        TimedTextCue(startMilliseconds: 3_723_004, endMilliseconds: 3_723_500, text: "a < b & c > d"),
    ]

    /// WebVTT: the WEBVTT line, then each cue after a blank line, its timing
    /// line in hours, minutes, seconds, and milliseconds over its text, with
    /// `<`, `&`, and `>` escaped.
    func testWebVTTWritesTheHeaderThenEachCueEscaped() {
        XCTAssertEqual(
            WebVTTWriter.text(of: Self.twoCues),
            "WEBVTT\n"
                + "\n00:00:00.000 --> 00:00:00.900\nFerry lines are cast off.\n"
                + "\n01:02:03.004 --> 01:02:03.500\na &lt; b &amp; c &gt; d\n"
        )
    }

    /// SubRip: each cue numbered from 1, timed with a comma before the
    /// milliseconds, its text as it is, every line ended by CR LF, and the
    /// cues apart by a blank line.
    func testSubRipNumbersEachCueAndEndsEveryLineWithCRLF() {
        XCTAssertEqual(
            SubRipWriter.text(of: Self.twoCues),
            "1\r\n00:00:00,000 --> 00:00:00,900\r\nFerry lines are cast off.\r\n"
                + "\r\n"
                + "2\r\n01:02:03,004 --> 01:02:03,500\r\na < b & c > d\r\n"
        )
    }

    /// The hours take two digits up to the 99th, and as many as they need
    /// from the 100th on; each part carries into the next at its limit.
    func testTheTimesInEveryPlace() {
        let cues = [
            TimedTextCue(startMilliseconds: 3_599_999, endMilliseconds: 3_600_000, text: "On the hour."),
            TimedTextCue(startMilliseconds: 360_000_000, endMilliseconds: 360_061_001, text: "Still talking."),
        ]
        XCTAssertEqual(
            WebVTTWriter.text(of: cues),
            "WEBVTT\n"
                + "\n00:59:59.999 --> 01:00:00.000\nOn the hour.\n"
                + "\n100:00:00.000 --> 100:01:01.001\nStill talking.\n"
        )
        XCTAssertEqual(
            SubRipWriter.text(of: cues),
            "1\r\n00:59:59,999 --> 01:00:00,000\r\nOn the hour.\r\n"
                + "\r\n"
                + "2\r\n100:00:00,000 --> 100:01:01,001\r\nStill talking.\r\n"
        )
    }

    /// No cues: the WEBVTT line alone, and nothing at all for SubRip but its
    /// byte-order mark among the file's bytes.
    func testNoCuesWriteTheHeaderAloneOrNothing() {
        XCTAssertEqual(WebVTTWriter.text(of: []), "WEBVTT\n")
        XCTAssertEqual(SubRipWriter.text(of: []), "")
        XCTAssertEqual(TranscriptExportFormat.webVTT.fileBytes(of: []), Data("WEBVTT\n".utf8))
        XCTAssertEqual(TranscriptExportFormat.subRip.fileBytes(of: []), Data([0xEF, 0xBB, 0xBF]))
    }

    /// The files' bytes are UTF-8: SubRip's after the UTF-8 byte-order mark,
    /// every line ended by CR LF; WebVTT's with no mark and no CR.
    func testTheFileBytes() {
        let cues = [TimedTextCue(startMilliseconds: 0, endMilliseconds: 1_000, text: "Smørrebrød at the café — naïve?")]

        let vtt = TranscriptExportFormat.webVTT.fileBytes(of: cues)
        XCTAssertEqual(vtt, Data("WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nSmørrebrød at the café — naïve?\n".utf8))
        XCTAssertFalse(vtt.contains(0x0D), "WebVTT's lines end with LF alone")

        let srt = TranscriptExportFormat.subRip.fileBytes(of: Self.twoCues + cues)
        XCTAssertEqual(
            srt,
            Data([0xEF, 0xBB, 0xBF]) + Data(SubRipWriter.text(of: Self.twoCues + cues).utf8),
            "the byte-order mark, then the text in UTF-8"
        )
        XCTAssertTrue(
            SubRipWriter.text(of: cues).hasSuffix("Smørrebrød at the café — naïve?\r\n"),
            "the text is written as it is"
        )
        // Every LF ends a CR LF, and every CR begins one.
        let bytes = Array(srt)
        let pairs = zip(bytes, bytes.dropFirst()).filter { $0 == 0x0D && $1 == 0x0A }.count
        XCTAssertEqual(bytes.filter { $0 == 0x0A }.count, pairs)
        XCTAssertEqual(bytes.filter { $0 == 0x0D }.count, pairs)
        XCTAssertEqual(pairs, 11, "three lines and a blank line for each cue but the last")
    }

    /// A cue's text holding line breaks, tabs, and runs of spaces is written
    /// on one line, its words one space apart, in either format.
    func testACueTextWithLineBreaksIsWrittenOnOneLine() {
        let cues = [TimedTextCue(startMilliseconds: 0, endMilliseconds: 2_000, text: " First line,\nsecond\tline,\r\n  third. ")]
        XCTAssertEqual(
            WebVTTWriter.text(of: cues),
            "WEBVTT\n\n00:00:00.000 --> 00:00:02.000\nFirst line, second line, third.\n"
        )
        XCTAssertEqual(
            SubRipWriter.text(of: cues),
            "1\r\n00:00:00,000 --> 00:00:02,000\r\nFirst line, second line, third.\r\n"
        )
    }

    /// A cue left with no text is passed over, and SubRip numbers only the
    /// cues it writes. WebVTT requires a cue to end after it begins, so a cue
    /// lasting no time ends a millisecond later there, while SubRip keeps its
    /// times; WebVTT also leaves out a control character no player shows.
    func testABlankCueIsPassedOverAndAnInstantLastsAMillisecondInWebVTT() {
        let cues = [
            TimedTextCue(startMilliseconds: 0, endMilliseconds: 500, text: " \n "),
            TimedTextCue(startMilliseconds: 1_000, endMilliseconds: 1_000, text: "Bell\u{07}."),
        ]
        XCTAssertEqual(WebVTTWriter.text(of: cues), "WEBVTT\n\n00:00:01.000 --> 00:00:01.001\nBell.\n")
        XCTAssertEqual(SubRipWriter.text(of: cues), "1\r\n00:00:01,000 --> 00:00:01,000\r\nBell\u{07}.\r\n")
    }

    // MARK: - The Book's Timeline

    /// `TranscriptFixtures.twoFiles` on the book's timeline: the first file's
    /// sentences at their times, the second's 9,000 ms later, the first
    /// file's length; each cue its sentence's text, with no voice and no
    /// words.
    func testTheSecondFilesCuesComeAfterTheFirstFile() {
        XCTAssertEqual(
            TranscriptFixtures.twoFiles.bookTimelineCues,
            [
                TimedTextCue(startMilliseconds: 0, endMilliseconds: 2_400, text: "Quillwort grows by the ferry slip."),
                TimedTextCue(startMilliseconds: 2_400, endMilliseconds: 5_100, text: "Tide tables hang in the harbor office."),
                TimedTextCue(startMilliseconds: 5_100, endMilliseconds: 6_960, text: "Nobody reads them twice."),
                TimedTextCue(startMilliseconds: 9_000, endMilliseconds: 10_980, text: "The salt road bends east."),
                TimedTextCue(startMilliseconds: 10_980, endMilliseconds: 12_900, text: "Carts wait at the toll."),
            ]
        )
    }

    /// Each file is moved along by every file before it, a file without
    /// sentences included, not by the one before it alone; a book of one
    /// file keeps that file's times.
    func testEachFileIsMovedAlongByEveryFileBeforeIt() {
        let threeFiles = TranscriptFixtures.transcript([
            (path: "01.wav", duration: 1_000, sentences: [TranscriptFixtures.sentence("One.", from: 100, to: 900)]),
            (path: "02.wav", duration: 2_000, sentences: []),
            (path: "03.wav", duration: 3_000, sentences: [TranscriptFixtures.sentence("Three.", from: 0, to: 500)]),
        ])
        XCTAssertEqual(
            threeFiles.bookTimelineCues,
            [
                TimedTextCue(startMilliseconds: 100, endMilliseconds: 900, text: "One."),
                TimedTextCue(startMilliseconds: 3_000, endMilliseconds: 3_500, text: "Three."),
            ]
        )

        let oneFile = TranscriptFixtures.transcript([
            (path: "Whole.wav", duration: 5_000, sentences: [TranscriptFixtures.sentence("Alone.", from: 1_200, to: 2_000)]),
        ])
        XCTAssertEqual(
            oneFile.bookTimelineCues,
            [TimedTextCue(startMilliseconds: 1_200, endMilliseconds: 2_000, text: "Alone.")]
        )
    }

    /// A sentence beginning after its file's recorded length takes its place
    /// among the next file's cues, in the order they begin on the book's
    /// timeline, as WebVTT lists cues; cues beginning together keep the
    /// transcript's order.
    func testCuesAreInTheOrderTheyBeginOnTheBooksTimeline() {
        let transcript = TranscriptFixtures.transcript([
            (path: "01.wav", duration: 2_000, sentences: [
                TranscriptFixtures.sentence("Early.", from: 0, to: 1_000),
                TranscriptFixtures.sentence("Overrun.", from: 2_500, to: 3_000),
            ]),
            (path: "02.wav", duration: 2_000, sentences: [
                TranscriptFixtures.sentence("Next.", from: 0, to: 400),
                TranscriptFixtures.sentence("Together.", from: 500, to: 900),
            ]),
        ])
        XCTAssertEqual(transcript.bookTimelineCues.map(\.text), ["Early.", "Next.", "Overrun.", "Together."])
        XCTAssertEqual(transcript.bookTimelineCues.map(\.startMilliseconds), [0, 2_000, 2_500, 2_500])
    }

    /// Lengths too large to add up, which only a damaged transcript.json
    /// could hold, keep every later time at the largest one rather than
    /// trapping, and the writers still write every cue.
    func testLengthsTooLargeToAddUpHoldAtTheLargestTime() {
        let transcript = TranscriptFixtures.transcript([
            (path: "01.wav", duration: Int.max, sentences: [TranscriptFixtures.sentence("First.", from: 0, to: 1_000)]),
            (path: "02.wav", duration: Int.max, sentences: [TranscriptFixtures.sentence("Second.", from: 0, to: 1_000)]),
            (path: "03.wav", duration: 1_000, sentences: [TranscriptFixtures.sentence("Third.", from: 0, to: 1_000)]),
        ])

        let cues = transcript.bookTimelineCues

        XCTAssertEqual(cues.map(\.startMilliseconds), [0, Int.max, Int.max])
        XCTAssertEqual(cues.map(\.endMilliseconds), [1_000, Int.max, Int.max])
        // Int.max milliseconds: 2,562,047,788,015 hours, 12 minutes, 55.807 seconds.
        let largest = "2562047788015:12:55.807 --> 2562047788015:12:55.807"
        XCTAssertEqual(
            WebVTTWriter.text(of: cues),
            "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nFirst.\n\n\(largest)\nSecond.\n\n\(largest)\nThird.\n"
        )
    }

    // MARK: - The Conversion

    /// A transcript is exported as captions only when transcript.json holds
    /// one that passes validation, as the store reads it; any other is
    /// refused with the words the export names it by.
    func testOnlyAUsableTranscriptIsExported() throws {
        XCTAssertEqual(
            try Transcript.exportable(from: TranscriptStore.encoded(TranscriptFixtures.twoFiles)),
            TranscriptFixtures.twoFiles
        )
        var laterLayout = TranscriptFixtures.twoFiles
        laterLayout.version = Transcript.currentVersion + 1
        let laterBytes = try TranscriptStore.encoded(laterLayout)
        for bytes in [Data("not a transcript".utf8), laterBytes] {
            XCTAssertThrowsError(try Transcript.exportable(from: bytes)) { error in
                XCTAssertEqual(error as? TranscriptExportError, .unusable)
            }
        }
        XCTAssertEqual(
            TranscriptExportError.unusable.localizedDescription,
            "The book's transcript couldn't be read, so it wasn't exported."
        )
    }
}

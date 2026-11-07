import AppKit
import XCTest
import ZIPFoundation
@testable import TextMouth

/// Export of a transcript as captions (FMT23): the WebVTT and SubRip
/// writers' exact output, a transcript laid on the book's timeline, the
/// Transcript checkbox's Convert transcript to picker and the words it
/// changes, and real exports of an audiobook of two tracks, through the
/// service and through the dialog.
///
/// SwiftUI builds the spoken labels of its own checkboxes only for a
/// connected assistive app, so the checkbox's and the picker's words are
/// pinned through `BookExportWording` and the model, where they come from.
/// Every export goes to a sandbox folder, never the user's Documents, and no
/// test reads or writes the live library.
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
    /// milliseconds, its text as it is but for the `<` that a `>` after it
    /// would make a tag (`&lt;`), every line ended by CR LF, and the cues
    /// apart by a blank line.
    func testSubRipNumbersEachCueAndEndsEveryLineWithCRLF() {
        XCTAssertEqual(
            SubRipWriter.text(of: Self.twoCues),
            "1\r\n00:00:00,000 --> 00:00:00,900\r\nFerry lines are cast off.\r\n"
                + "\r\n"
                + "2\r\n01:02:03,004 --> 01:02:03,500\r\na &lt; b & c > d\r\n"
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
    /// times; both leave out a control character no player shows.
    func testABlankCueIsPassedOverAndAnInstantLastsAMillisecondInWebVTT() {
        let cues = [
            TimedTextCue(startMilliseconds: 0, endMilliseconds: 500, text: " \n "),
            TimedTextCue(startMilliseconds: 1_000, endMilliseconds: 1_000, text: "Bell\u{07}."),
        ]
        XCTAssertEqual(WebVTTWriter.text(of: cues), "WEBVTT\n\n00:00:01.000 --> 00:00:01.001\nBell.\n")
        XCTAssertEqual(SubRipWriter.text(of: cues), "1\r\n00:00:01,000 --> 00:00:01,000\r\nBell.\r\n")
    }

    /// A time before 0 is written as 0, and a cue that would end before it
    /// begins ends where it begins in SubRip and a millisecond after in
    /// WebVTT, never before: a player drops a cue that ends before it begins.
    func testATimeBeforeZeroAndAnEndBeforeTheStartAreHeldInRange() {
        let cues = [
            TimedTextCue(startMilliseconds: -500, endMilliseconds: 400, text: "Early."),
            TimedTextCue(startMilliseconds: 2_000, endMilliseconds: 1_500, text: "Backwards."),
        ]
        XCTAssertEqual(
            WebVTTWriter.text(of: cues),
            "WEBVTT\n\n00:00:00.000 --> 00:00:00.400\nEarly.\n\n00:00:02.000 --> 00:00:02.001\nBackwards.\n"
        )
        XCTAssertEqual(
            SubRipWriter.text(of: cues),
            "1\r\n00:00:00,000 --> 00:00:00,400\r\nEarly.\r\n\r\n2\r\n00:00:02,000 --> 00:00:02,000\r\nBackwards.\r\n"
        )
    }

    // MARK: - Reading It Back

    /// Sentences that hold what a caption file gives a meaning to: an arrow
    /// (WebVTT forbids it in a cue's text; SubRip would begin a timing line
    /// with it), tags, character references, a SubRip override, a cue number,
    /// a WebVTT block word, control characters, and plain text in other
    /// scripts. (A cue's text is one line of single spaces, as the readers
    /// give it.)
    private static let hostileTexts = [
        "Plain sentence.", "a --> b", "00:00:01,000 --> 00:00:02,000", "ends with an arrow -->", "--> begins with one",
        "a --&gt; b", "5 < 6 and 7 > 3", "a < b & c > d", "I said <i>hello</i> there.", "<v Ana>not a voice</v>",
        "only a lone < sign", "only a lone > sign", "AT&T and R&D", "x &lt; y typed out", "&amp;lt; twice",
        "&#65; and &#x42; typed out", "&nbsp;&lrm;&rlm;", "{\\an8}Top of the frame", "mid {\\i1}text{\\i0} here",
        "a { brace and a \\ slash", "12345", "7", "NOTE this is not a comment", "WEBVTT", "STYLE", "REGION",
        "Ana: Hello there.", "Smørrebrød at the café — naïve? 日本語 😀", "quote \" and apostrophe '",
        "<c.loud>a class</c>", "<00:00:01.000>a timestamp tag", "- - > not an arrow", "--", "---> three hyphens",
        "\u{FEFF}a mark first", "zero\u{200B}width",
    ]

    /// Writes `cues` as `format` (the file's bytes, byte-order mark and all)
    /// and reads the file with the format's own reader.
    private static func readBack(_ cues: [TimedTextCue], as format: TranscriptExportFormat) throws -> TimedTextDocument {
        let bytes = format.fileBytes(of: cues)
        switch format {
        case .webVTT: return try WebVTTReader.read(bytes)
        case .subRip: return try SubRipReader.read(bytes)
        }
    }

    /// Each hostile sentence alone, and between two plain ones, is read back
    /// from the file as the same words at the same times, in either format:
    /// none is lost, none swallows its neighbours, none changes.
    func testHostileSentencesReadBackAsTheyWere() throws {
        for format in TranscriptExportFormat.allCases {
            for text in Self.hostileTexts {
                let alone = [TimedTextCue(startMilliseconds: 1_000, endMilliseconds: 2_000, text: text)]
                XCTAssertEqual(try Self.readBack(alone, as: format).cues, alone, "\(format.name): \(text)")

                let between = [
                    TimedTextCue(startMilliseconds: 0, endMilliseconds: 500, text: "Before."),
                    TimedTextCue(startMilliseconds: 600, endMilliseconds: 900, text: text),
                    TimedTextCue(startMilliseconds: 1_000, endMilliseconds: 1_500, text: "After."),
                ]
                XCTAssertEqual(try Self.readBack(between, as: format).cues, between, "\(format.name) between: \(text)")
            }
        }
    }

    /// All the hostile sentences in one file, each in a cue of its own, come
    /// back as the same cues in the same order.
    func testAFileOfAllTheHostileSentencesReadsBackWhole() throws {
        let cues = Self.hostileTexts.enumerated().map {
            TimedTextCue(startMilliseconds: $0.offset * 1_000, endMilliseconds: $0.offset * 1_000 + 900, text: $0.element)
        }
        for format in TranscriptExportFormat.allCases {
            XCTAssertEqual(try Self.readBack(cues, as: format).cues, cues, format.name)
        }
    }

    /// Cues that overlap, cues that begin together, a cue inside another, and
    /// a cue at the 100th hour all come back with their times, in order.
    func testOverlappingCuesAndLongTimesReadBackWithTheirTimes() throws {
        let cues = [
            TimedTextCue(startMilliseconds: 5_000, endMilliseconds: 9_000, text: "Long."),
            TimedTextCue(startMilliseconds: 5_000, endMilliseconds: 6_000, text: "Together."),
            TimedTextCue(startMilliseconds: 6_000, endMilliseconds: 7_000, text: "Inside."),
            TimedTextCue(startMilliseconds: 8_500, endMilliseconds: 10_000, text: "Across."),
            TimedTextCue(startMilliseconds: 359_999_000, endMilliseconds: 360_000_000, text: "The hundredth hour."),
        ]
        for format in TranscriptExportFormat.allCases {
            XCTAssertEqual(try Self.readBack(cues, as: format).cues, cues, format.name)
        }
    }

    /// An instant (a sentence with no duration) reads back beginning where it
    /// did: ending where it did in SubRip, a millisecond later in WebVTT.
    func testASentenceWithNoDurationReadsBackFromWhereItBegan() throws {
        let instant = [TimedTextCue(startMilliseconds: 4_000, endMilliseconds: 4_000, text: "Click.")]
        XCTAssertEqual(try Self.readBack(instant, as: .subRip).cues, instant)
        XCTAssertEqual(
            try Self.readBack(instant, as: .webVTT).cues,
            [TimedTextCue(startMilliseconds: 4_000, endMilliseconds: 4_001, text: "Click.")]
        )
    }

    /// SubRip writes the few strings a reader or player takes for something
    /// else as character references, and nothing more: the exact lines.
    func testSubRipWritesWhatWouldBeTakenForMarkupAsReferences() {
        func written(_ text: String) -> String {
            SubRipWriter.text(of: [TimedTextCue(startMilliseconds: 0, endMilliseconds: 1_000, text: text)])
        }
        let head = "1\r\n00:00:00,000 --> 00:00:01,000\r\n"
        XCTAssertEqual(written("a --> b"), head + "a --&gt; b\r\n")
        XCTAssertEqual(written("5 < 6 and 7 > 3"), head + "5 &lt; 6 and 7 > 3\r\n")
        XCTAssertEqual(written("only a lone < sign"), head + "only a lone < sign\r\n")
        XCTAssertEqual(written("{\\an8}Top"), head + "&#123;\\an8}Top\r\n")
        XCTAssertEqual(written("a { brace"), head + "a { brace\r\n")
        XCTAssertEqual(written("x &lt; y"), head + "x &amp;lt; y\r\n")
        XCTAssertEqual(written("&#65;"), head + "&amp;#65;\r\n")
        XCTAssertEqual(written("AT&T and a - > b -- c"), head + "AT&T and a - > b -- c\r\n")
        XCTAssertEqual(written("12345"), head + "12345\r\n")
    }

    /// A control character no player shows is left out of SubRip as of
    /// WebVTT, a NUL above all: a file holding one is taken for UTF-16 by a
    /// reader. White space controls keep the words apart.
    func testControlCharactersAreLeftOutOfSubRip() throws {
        for scalar: UInt32 in [0x00, 0x01, 0x07, 0x1B, 0x7F, 0x9F] {
            let text = "before" + String(Unicode.Scalar(scalar)!) + "after"
            let bytes = TranscriptExportFormat.subRip.fileBytes(
                of: [TimedTextCue(startMilliseconds: 0, endMilliseconds: 1_000, text: text)]
            )
            XCTAssertFalse(bytes.contains(UInt8(truncatingIfNeeded: scalar)) && scalar < 0x80, "U+\(String(scalar, radix: 16))")
            XCTAssertEqual(try SubRipReader.read(bytes).cues.map(\.text), ["beforeafter"], "U+\(String(scalar, radix: 16))")
        }
        let spaced = TranscriptExportFormat.subRip.fileBytes(
            of: [TimedTextCue(startMilliseconds: 0, endMilliseconds: 1_000, text: "page\u{0C}Start\u{0B}here")]
        )
        XCTAssertEqual(try SubRipReader.read(spaced).cues.map(\.text), ["page Start here"])
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

    /// A transcript of timed words (the recognizer's, or a Podcasting 2.0
    /// one) is exported by sentence: one cue for each sentence, its words
    /// neither cues of their own nor kept in the cue, and a sentence's voice
    /// is already in its text. The file holds the sentences' text and times.
    func testTimedWordsAreExportedBySentenceAlone() throws {
        let transcript = TranscriptFixtures.twoFiles
        XCTAssertTrue(
            transcript.files.allSatisfy { $0.sentences.allSatisfy { !$0.words.isEmpty } },
            "the fixture times every word"
        )
        let cues = transcript.bookTimelineCues
        XCTAssertEqual(cues.count, 5, "one cue for each of the five sentences")
        XCTAssertTrue(cues.allSatisfy { $0.words.isEmpty && $0.voice == nil })
        let read = try WebVTTReader.read(TranscriptExportFormat.webVTT.fileBytes(of: cues))
        XCTAssertEqual(read.cues, cues)
    }

    /// An edited or cleaned-up transcript is exported as it now reads: the
    /// editor and the cleanup both rewrite the sentence in transcript.json
    /// (`TranscriptSentence.rewrite(as:)`), which is the file the captions
    /// are made of, so the cue holds the new text at the sentence's old time.
    func testAnEditedSentenceIsExportedAsEdited() throws {
        var transcript = TranscriptFixtures.twoFiles
        transcript.files[1].sentences[0].rewrite(as: "The salt road bends east, then north.")
        let cues = transcript.bookTimelineCues
        XCTAssertEqual(
            cues[3],
            TimedTextCue(startMilliseconds: 9_000, endMilliseconds: 10_980, text: "The salt road bends east, then north.")
        )
        XCTAssertEqual(cues.map(\.text).filter { $0.contains("salt road") }, ["The salt road bends east, then north."])
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

    /// The timed-text conversion takes its format's extension and name, and
    /// applies to the transcript alone; each format has its picker tag, and
    /// JSON and Markdown's tag is no format's.
    func testTheTimedTextConversion() {
        XCTAssertEqual(BookExportConversion.timedText(.webVTT).fileExtension, "vtt")
        XCTAssertEqual(BookExportConversion.timedText(.subRip).fileExtension, "srt")
        XCTAssertEqual(BookExportConversion.timedText(.webVTT).name, "WebVTT")
        XCTAssertEqual(BookExportConversion.timedText(.subRip).name, "SubRip")
        for kind in BookExportKind.allCases {
            XCTAssertEqual(BookExportConversion.timedText(.webVTT).applies(to: kind), kind == .transcript, "\(kind)")
        }
        XCTAssertEqual(TranscriptExportFormat.allCases.map(\.timedTextFormat), [.webVTT, .subRip])
        XCTAssertEqual(TranscriptExportFormat.allCases.map(\.choiceID), ["transcript-webvtt", "transcript-srt"])
        XCTAssertEqual(TranscriptExportFormat.jsonAndMarkdownChoiceID, "transcript-json")
        XCTAssertEqual(TranscriptExportFormat(choiceID: "transcript-webvtt"), .webVTT)
        XCTAssertEqual(TranscriptExportFormat(choiceID: "transcript-srt"), .subRip)
        XCTAssertNil(TranscriptExportFormat(choiceID: "transcript-json"))
        XCTAssertNil(TranscriptExportFormat(choiceID: "vtt"))
    }

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

    // MARK: - The Picker

    /// The Transcript checkbox's picker offers JSON and Markdown, then every
    /// text writer, then WebVTT, then SubRip, with the hints the user hears.
    /// The first choice and the last two are pinned exactly; the writers are
    /// those of `TextExportWriters.all`, exactly as Text as Markdown's picker
    /// lists them after Markdown, so a writer added later is checked against
    /// itself and this test stays green.
    func testTheTranscriptsChoicesAreJSONAndMarkdownThenEachWriterThenTheCaptions() {
        let model = BookExportModel(books: [])
        let choices = model.conversionChoices(for: .transcript)
        XCTAssertEqual(
            choices.first,
            BookExportConversionChoice(
                id: "transcript-json",
                name: "JSON and Markdown",
                hint: "The transcript as TextMouth keeps it, in JSON, with its text as Markdown."
            )
        )
        XCTAssertEqual(
            Array(choices.dropFirst().dropLast(2)),
            TextExportWriters.all.map { BookExportConversionChoice(id: $0.id, name: $0.name, hint: $0.hint) }
        )
        XCTAssertEqual(
            Array(choices.suffix(2)),
            [
                BookExportConversionChoice(
                    id: "transcript-webvtt",
                    name: "WebVTT",
                    hint: "Captions in WebVTT, which web browsers and most players read: "
                        + "one file for the book, timed from the start of its audio."
                ),
                BookExportConversionChoice(
                    id: "transcript-srt",
                    name: "SubRip",
                    hint: "Captions in SubRip (.srt), which nearly every player reads: "
                        + "one file for the book, timed from the start of its audio."
                ),
            ]
        )
        let textChoices = model.conversionChoices(for: .markdown)
        XCTAssertEqual(textChoices.first?.id, "markdown")
        XCTAssertEqual(Array(textChoices.dropFirst()), Array(choices.dropFirst().dropLast(2)), "one list of writers")
    }

    /// The picker beside Transcript is called "Convert transcript to", and
    /// every other, Text as Markdown's included, keeps "Convert to", so the
    /// two never sound alike when one export shows both.
    func testThePickersLabels() {
        XCTAssertEqual(BookExportWording.convertToLabel(for: .transcript), "Convert transcript to")
        XCTAssertEqual(BookExportWording.convertToLabel(for: .markdown), "Convert to")
        for kind in BookExportKind.allCases where kind != .transcript {
            XCTAssertEqual(BookExportWording.convertToLabel(for: kind), BookExportWording.convertToLabel, "\(kind)")
        }
        XCTAssertEqual(BookExportWording.convertToLabel, "Convert to")
    }

    /// A new dialog's transcript is on JSON and Markdown, which makes no
    /// conversion: today's export. While the transcript is checked, WebVTT or
    /// SubRip makes it captions; unchecking it takes the conversion away and
    /// keeps the choice, checking it again brings the conversion back, and
    /// JSON and Markdown takes it away again.
    func testTheTranscriptsConversionFollowsItsChoiceWhileChecked() {
        let model = BookExportModel(books: [])
        XCTAssertEqual(model.conversionID(for: .transcript), "transcript-json")
        XCTAssertEqual(model.conversionChoice(for: .transcript)?.name, "JSON and Markdown")
        model.setChecked(true, for: .transcript)
        XCTAssertEqual(model.conversions, [:], "JSON and Markdown is today's export")

        model.setConversionID("transcript-webvtt", for: .transcript)
        XCTAssertEqual(model.conversions, [.transcript: .timedText(.webVTT)])
        model.setConversionID("transcript-srt", for: .transcript)
        XCTAssertEqual(model.conversions, [.transcript: .timedText(.subRip)])
        XCTAssertNil(model.optionsView(for: .transcript), "captions take no options")

        model.setChecked(false, for: .transcript)
        XCTAssertEqual(model.conversions, [:], "an unchecked transcript passes no conversion")
        XCTAssertEqual(model.conversionID(for: .transcript), "transcript-srt", "the choice outlives the checkbox")

        model.setChecked(true, for: .transcript)
        XCTAssertEqual(model.conversions, [.transcript: .timedText(.subRip)])
        model.setConversionID("transcript-json", for: .transcript)
        XCTAssertEqual(model.conversions, [:])
    }

    /// An id the transcript's picker does not list changes nothing, and
    /// neither does a transcript's id beside Text as Markdown or beside a
    /// kind with no picker.
    func testAnIdThePickerDoesNotListChangesNothing() {
        let model = BookExportModel(books: [])
        model.setChecked(true, for: .transcript)
        model.setChecked(true, for: .markdown)
        model.setConversionID("transcript-webvtt", for: .transcript)

        for id in ["markdown", "transcript", "transcript-vtt", "vtt", ""] {
            model.setConversionID(id, for: .transcript)
        }
        model.setConversionID("transcript-srt", for: .markdown)
        model.setConversionID("transcript-srt", for: .audio)

        XCTAssertEqual(model.conversionID(for: .transcript), "transcript-webvtt")
        XCTAssertEqual(model.conversionID(for: .markdown), "markdown")
        XCTAssertEqual(model.conversionID(for: .audio), "markdown", "a kind without a picker stays as it was")
        XCTAssertEqual(model.conversions, [.transcript: .timedText(.webVTT)])
    }

    // MARK: - The Checkbox's Words

    /// With one book: on JSON and Markdown, the checkbox says today's words;
    /// on WebVTT or SubRip, its label names the format with no count of
    /// files and no size (one file is written, of a size unknown until it
    /// is), and its hint says what the captions are.
    func testTheCheckboxWordsForEachChoiceWithOneBook() throws {
        let model = BookExportModel(books: [])
        let choice = BookExportChoice(kind: .transcript, items: [try transcriptItem(inCloud: false)], bookCount: 1)
        let size = ByteCountFormatter.string(fromByteCount: 3_000, countStyle: .file)

        XCTAssertEqual(model.label(for: choice), "Transcript, 2 files, \(size)")
        XCTAssertEqual(model.label(for: choice), choice.label, "today's label")
        XCTAssertEqual(model.hint(for: .transcript), BookExportWording.hint(for: .transcript), "today's hint")

        model.setConversionID("transcript-webvtt", for: .transcript)
        XCTAssertEqual(model.label(for: choice), "Transcript as WebVTT")
        XCTAssertEqual(
            model.hint(for: .transcript),
            "The transcript as WebVTT captions, one file for the book, timed from the start of its audio."
        )

        model.setConversionID("transcript-srt", for: .transcript)
        XCTAssertEqual(model.label(for: choice), "Transcript as SubRip")
        XCTAssertEqual(
            model.hint(for: .transcript),
            "The transcript as SubRip captions, one file for the book, timed from the start of its audio."
        )

        model.setConversionID("transcript-json", for: .transcript)
        XCTAssertEqual(model.label(for: choice), choice.label, "today's label again")
        XCTAssertEqual(model.hint(for: .transcript), BookExportWording.hint(for: .transcript), "today's hint again")
    }

    /// With several books: on a format, the label names it, then how many
    /// books hold the transcript on this Mac and how many only in the cloud,
    /// with no size; on JSON and Markdown, today's label, size included.
    func testTheCheckboxWordsForEachChoiceWithSeveralBooks() throws {
        let model = BookExportModel(books: [])
        let onThisMac = try transcriptItem(inCloud: false)
        let choice = BookExportChoice(
            kind: .transcript,
            items: [onThisMac, onThisMac, try transcriptItem(inCloud: true)],
            bookCount: 3
        )
        let size = ByteCountFormatter.string(fromByteCount: 6_000, countStyle: .file)

        XCTAssertEqual(model.label(for: choice), "Transcript, 2 books, \(size), 1 book in the cloud")

        model.setConversionID("transcript-webvtt", for: .transcript)
        XCTAssertEqual(model.label(for: choice), "Transcript as WebVTT, 2 books, 1 book in the cloud")
        model.setConversionID("transcript-srt", for: .transcript)
        XCTAssertEqual(model.label(for: choice), "Transcript as SubRip, 2 books, 1 book in the cloud")
        XCTAssertEqual(
            model.hint(for: .transcript),
            "The transcript as SubRip captions, one file for the book, timed from the start of its audio."
        )

        model.setConversionID("transcript-json", for: .transcript)
        XCTAssertEqual(model.label(for: choice), choice.label)
    }

    /// Only the transcript's label names what it is written as: every other
    /// kind ignores the name, and a transcript only in the cloud says so
    /// after it.
    func testOnlyTheTranscriptsLabelNamesWhatItIsWrittenAs() {
        for kind in BookExportKind.allCases where kind != .transcript {
            XCTAssertEqual(
                BookExportWording.choiceLabel(
                    kind: kind, bookCount: 1, availableItemCount: 1, fileCount: 2, byteCount: 1_200_000,
                    inCloudCount: 0, transcriptAs: "WebVTT"
                ),
                BookExportWording.choiceLabel(
                    kind: kind, bookCount: 1, availableItemCount: 1, fileCount: 2, byteCount: 1_200_000,
                    inCloudCount: 0
                ),
                "\(kind)"
            )
        }
        XCTAssertEqual(
            BookExportWording.choiceLabel(
                kind: .transcript, bookCount: 1, availableItemCount: 0, fileCount: 0, byteCount: 0,
                inCloudCount: 1, transcriptAs: "SubRip"
            ),
            "Transcript as SubRip, in the cloud"
        )
        XCTAssertEqual(BookExportWording.transcriptName(as: "WebVTT"), "Transcript as WebVTT")
        XCTAssertEqual(BookExportWording.transcriptName(as: "HTML"), "Transcript as HTML")
    }

    /// With a text writer chosen beside Transcript (TODO 3984), the checkbox
    /// reads "Transcript as HTML", with no count of files and no size, and
    /// its hint says the transcript's text is written as HTML; the checked
    /// transcript converts with the writer, and Text as Markdown's choice
    /// stays its own.
    func testAWriterChosenForTheTranscriptNamesItsText() throws {
        let model = BookExportModel(books: [])
        let choice = BookExportChoice(kind: .transcript, items: [try transcriptItem(inCloud: false)], bookCount: 1)
        model.setChecked(true, for: .transcript)

        model.setConversionID("html", for: .transcript)

        XCTAssertEqual(model.conversionID(for: .transcript), "html")
        XCTAssertEqual(model.conversionChoice(for: .transcript)?.name, "HTML")
        XCTAssertEqual(model.label(for: choice), "Transcript as HTML")
        XCTAssertEqual(
            model.hint(for: .transcript),
            "The transcript's text as HTML, made from the Markdown TextMouth reads it from."
        )
        XCTAssertEqual(model.conversions[.transcript]?.fileExtension, "html")
        XCTAssertEqual(model.conversions[.transcript]?.name, "HTML")
        XCTAssertNil(model.optionsView(for: .transcript), "HTML takes no options")
        XCTAssertEqual(model.conversionID(for: .markdown), "markdown", "Text as Markdown's choice is its own")
        // A text conversion makes the text's files and the transcript's.
        for kind in BookExportKind.allCases {
            XCTAssertEqual(
                BookExportConversion.markdown.applies(to: kind),
                kind == .markdown || kind == .transcript,
                "\(kind)"
            )
        }
    }

    /// A braille writer chosen beside Transcript shows its options view under
    /// the picker while the transcript is checked, and none while it is not,
    /// as it does beside Text as Markdown.
    func testABrailleWritersOptionsShowUnderTheTranscriptsPickerWhileChecked() throws {
        let braille = try XCTUnwrap(TextExportWriters.all.first { $0 is BRFExportWriter }, "the BRF writer")
        let model = BookExportModel(books: [])
        model.setConversionID(braille.id, for: .transcript)

        XCTAssertNil(model.optionsView(for: .transcript), "unchecked: no options")
        model.setChecked(true, for: .transcript)
        XCTAssertNotNil(model.optionsView(for: .transcript), "checked: the writer's options")
        XCTAssertEqual(model.conversions[.transcript]?.fileExtension, braille.fileExtension)
        model.setChecked(false, for: .transcript)
        XCTAssertNil(model.optionsView(for: .transcript), "unchecked again: no options")
    }

    // MARK: - Exporting

    /// The plan of a transcript written as SubRip: one file,
    /// "<stem> - Transcript.srt", converted from the book's transcript.json,
    /// and not the Markdown the offer lists beside it.
    func testThePlanOfSubRipIsOneFileAndNoMarkdown() throws {
        let world = try makeIntegrationWorld("Transcript Export Plan")
        let book = try makeTranscribedBook(in: world)
        let stem = BookExportService.fileNameStem(for: book.title)
        let destination = try makeSandboxDirectory("Transcript Export Plan Destination")
        let offer = BookExportService.offer(for: book)
        XCTAssertEqual(
            offer.item(.transcript)?.files.map(\.path),
            ["\(stem) - Transcript.json", "\(stem) - Transcript.md"],
            "the offer lists the transcript and its Markdown"
        )

        let plan = BookExportService.plan(
            [offer],
            kinds: [.transcript],
            conversions: [.transcript: .timedText(.subRip)],
            in: destination
        )

        XCTAssertEqual(plan.files.map(\.file.path), ["\(stem) - Transcript.srt"])
        XCTAssertEqual(plan.files.map(\.target), [destination.appendingPathComponent("\(stem) - Transcript.srt")])
        XCTAssertEqual(
            plan.files.map(\.file.source),
            [.converted(
                from: TextMouthPaths.transcriptPath(in: book.tmbDirectory),
                book: ExportBookDetails(book),
                by: .timedText(.subRip)
            )]
        )
        XCTAssertEqual(plan.booksInCloud, [])
    }

    /// The Convert transcript to picker offers every text writer, EPUB 3
    /// among them, and the EPUB writer makes an e-book of the transcript's
    /// text alone, as every text writer does: one .epub, a sound package
    /// (its mimetype first), whose chapters hold each track's sentences,
    /// with the "&" escaped, and no transcript.json beside it.
    func testATranscriptExportsAsAnEPUB() throws {
        let world = try makeIntegrationWorld("Transcript Export EPUB")
        let book = try makeTranscribedBook(in: world)
        let destination = try makeSandboxDirectory("Transcript Export EPUB Destination")
        let model = BookExportModel(books: [book])
        XCTAssertTrue(
            model.conversionChoices(for: .transcript).contains { $0.id == EPUBExportWriter().id },
            "the transcript's picker leaves out EPUB"
        )
        let epub = BookExportConversion.text(TextExportConversion(EPUBExportWriter(), options: NoTextExportOptions()))

        let outcome = BookExportService.export(
            [BookExportService.offer(for: book)], kinds: [.transcript], conversions: [.transcript: epub], to: destination
        )

        XCTAssertEqual(outcome.failures, [])
        let file = try XCTUnwrap(outcome.exported.first)
        XCTAssertEqual(outcome.exported.map(\.pathExtension), ["epub"])
        let archive = try Archive(url: file, accessMode: .read)
        XCTAssertEqual(archive.map(\.path).first, "mimetype")
        var xhtml = ""
        for entry in archive where entry.path.hasSuffix(".xhtml") {
            var bytes = Data()
            _ = try archive.extract(entry) { bytes.append($0) }
            xhtml += String(decoding: bytes, as: UTF8.self)
        }
        for sentence in ["Gulls argue over the net shed.", "Berths 4 &amp; 5 stay shut till noon.", "The pilot boat ties up at the slip."] {
            XCTAssertTrue(xhtml.contains(sentence), "the e-book lacks “\(sentence)”")
        }
    }

    /// Captions of a book whose transcript.json is only in the cloud, its
    /// Markdown on this Mac, are refused as any export of a file in the cloud
    /// is (S4): the book is named as not downloaded, never skipped in
    /// silence, and nothing is downloaded. Its text, which is on this Mac,
    /// still exports as text.
    func testCaptionsOfATranscriptOnlyInTheCloudNameTheBook() throws {
        let world = try makeIntegrationWorld("Transcript Export Cloud")
        let book = try makeTranscribedBook(in: world)
        let transcript = TextMouthPaths.transcriptPath(in: book.tmbDirectory)
        let paths = Set([transcript.standardizedFileURL.path])
        let cloud = MaintenanceFileAccess(
            isDataless: { paths.contains($0.standardizedFileURL.path) },
            refusesRead: { paths.contains($0.standardizedFileURL.path) }
        )
        let destination = try makeSandboxDirectory("Transcript Export Cloud Destination")

        let offer = BookExportService.offer(for: book, access: cloud)
        let captions = BookExportService.export(
            [offer], kinds: [.transcript], conversions: [.transcript: .timedText(.webVTT)], to: destination, access: cloud
        )
        let text = BookExportService.export(
            [offer], kinds: [.transcript], conversions: [.transcript: .text(TextExportConversion(HTMLExportWriter(), options: NoTextExportOptions()))],
            to: destination, access: cloud
        )

        XCTAssertEqual(offer.item(.transcript)?.transcriptInCloud, transcript)
        XCTAssertEqual(captions.exported, [])
        XCTAssertEqual(captions.booksInCloud, [BookExportBookName(book)])
        XCTAssertEqual(
            BookExportWording.finished(captions, folderName: "Exports"),
            "\(book.title) isn't downloaded. Download it first: select it in the library, then choose Download Now."
        )
        XCTAssertEqual(text.exported.map(\.pathExtension), ["html"])
        XCTAssertEqual(text.booksInCloud, [])
    }

    /// Exporting the transcript as WebVTT writes exactly one file, the book's
    /// captions: the first track's sentences at their times, the second
    /// track's 3,000 ms later, after the first track, and the "&" escaped.
    func testExportingAsWebVTTWritesTheBooksCaptions() throws {
        let world = try makeIntegrationWorld("Transcript Export WebVTT")
        let book = try makeTranscribedBook(in: world)
        let stem = BookExportService.fileNameStem(for: book.title)
        let folder = try makeSandboxDirectory("Transcript Export WebVTT Folder")

        let outcome = BookExportService.export(
            [BookExportService.offer(for: book)],
            kinds: [.transcript],
            conversions: [.transcript: .timedText(.webVTT)],
            to: folder
        )

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.exported.map(\.lastPathComponent), ["\(stem) - Transcript.vtt"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["\(stem) - Transcript.vtt"])
        XCTAssertEqual(
            try Data(contentsOf: folder.appendingPathComponent("\(stem) - Transcript.vtt")),
            Data(Self.harbourWebVTT.utf8)
        )
    }

    /// Exporting the transcript as SubRip writes exactly one file: the same
    /// captions in SubRip, after the byte-order mark, with CR LF line ends
    /// and the "&" as it is.
    func testExportingAsSubRipWritesTheBooksCaptions() throws {
        let world = try makeIntegrationWorld("Transcript Export SubRip")
        let book = try makeTranscribedBook(in: world)
        let stem = BookExportService.fileNameStem(for: book.title)
        let folder = try makeSandboxDirectory("Transcript Export SubRip Folder")

        let outcome = BookExportService.export(
            [BookExportService.offer(for: book)],
            kinds: [.transcript],
            conversions: [.transcript: .timedText(.subRip)],
            to: folder
        )

        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["\(stem) - Transcript.srt"])
        XCTAssertEqual(
            try Data(contentsOf: folder.appendingPathComponent("\(stem) - Transcript.srt")),
            Data([0xEF, 0xBB, 0xBF]) + Data(Self.harbourSubRip.utf8)
        )
    }

    /// A transcript.json that holds no usable transcript is not exported as
    /// captions: nothing is written, and the export names the file with why,
    /// in the words the dialog says.
    func testATranscriptThatCannotBeReadIsNotExported() throws {
        let world = try makeIntegrationWorld("Transcript Export Unusable")
        let book = try world.makeSilentAudioBook(title: "Harbour Captions", trackDurations: [3, 2])
        let stem = BookExportService.fileNameStem(for: book.title)
        var laterLayout = try TranscriptFixtures.transcript(of: book, sentences: Self.harbourSentences)
        laterLayout.version = Transcript.currentVersion + 1
        let laterBytes = try TranscriptStore.encoded(laterLayout)
        // Bytes cut short partway, and a transcript of a later layout.
        let unusable = [Data("{\"version\": 1, \"files\": [".utf8), laterBytes]

        for (number, bytes) in unusable.enumerated() {
            try bytes.write(to: TextMouthPaths.transcriptPath(in: book.tmbDirectory))
            let folder = try makeSandboxDirectory("Transcript Export Unusable Folder \(number)")

            let outcome = BookExportService.export(
                [BookExportService.offer(for: book)],
                kinds: [.transcript],
                conversions: [.transcript: .timedText(.webVTT)],
                to: folder
            )

            XCTAssertEqual(outcome.exported, [], "case \(number)")
            XCTAssertEqual(
                outcome.failures,
                [BookExportFailure(
                    name: "\(stem) - Transcript.vtt",
                    reason: "The book's transcript couldn't be read, so it wasn't exported."
                )],
                "case \(number)"
            )
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [], "case \(number)")
            XCTAssertEqual(
                BookExportWording.finished(outcome, folderName: "Captions"),
                "Couldn't export \(stem) - Transcript.vtt: The book's transcript couldn't be read, so it wasn't exported.",
                "case \(number)"
            )
        }
    }

    // MARK: - Through the Dialog

    /// Through the dialog: checking the transcript alone and choosing WebVTT
    /// exports exactly the book's .vtt, announces it, and leaves the dialog
    /// nothing to say, so it closes.
    func testTheDialogExportsTheTranscriptAsWebVTT() async throws {
        let world = try makeIntegrationWorld("Transcript Export Dialog")
        let book = try makeTranscribedBook(in: world)
        let stem = BookExportService.fileNameStem(for: book.title)
        let folder = try makeSandboxDirectory("Transcript Export Dialog Folder")
        let model = BookExportModel(books: [book], library: world.library, destination: folder)
        await model.load()
        for kind in model.checked {
            model.setChecked(false, for: kind)
        }
        model.setChecked(true, for: .transcript)
        model.setConversionID("transcript-webvtt", for: .transcript)
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        let exported = await model.export()
        let outcome = try XCTUnwrap(exported)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["\(stem) - Transcript.vtt"])
        XCTAssertEqual(
            try String(contentsOf: folder.appendingPathComponent("\(stem) - Transcript.vtt"), encoding: .utf8),
            Self.harbourWebVTT
        )
        XCTAssertTrue(BookExportModel.didEverything(outcome), "the dialog closes")
        XCTAssertNil(model.summary, "the dialog has nothing to say")
        XCTAssertEqual(
            announcements.messages,
            ["Exported 1 item to \(BookExportWording.folderName(of: folder))."]
        )
    }

    /// Through the dialog, with HTML chosen beside the transcript alone (TODO
    /// 3984): the export writes exactly "<stem> - Transcript.html", the
    /// transcript's text as a web page, and not its transcript.json.
    func testTheDialogExportsTheTranscriptsTextAsHTML() async throws {
        let world = try makeIntegrationWorld("Transcript Export HTML")
        let book = try makeTranscribedBook(in: world)
        let stem = BookExportService.fileNameStem(for: book.title)
        let folder = try makeSandboxDirectory("Transcript Export HTML Folder")
        let model = BookExportModel(books: [book], library: world.library, destination: folder)
        await model.load()
        for kind in model.checked {
            model.setChecked(false, for: kind)
        }
        model.setChecked(true, for: .transcript)
        model.setConversionID("html", for: .transcript)
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        let exported = await model.export()
        let outcome = try XCTUnwrap(exported)

        XCTAssertTrue(BookExportModel.didEverything(outcome), "the dialog closes")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["\(stem) - Transcript.html"])
        let page = try String(contentsOf: folder.appendingPathComponent("\(stem) - Transcript.html"), encoding: .utf8)
        for sentence in [
            "Gulls argue over the net shed.",
            "Berths 4 &amp; 5 stay shut till noon.",
            "The pilot boat ties up at the slip.",
        ] {
            XCTAssertTrue(page.contains(sentence), "the page lacks \"\(sentence)\"")
        }
        XCTAssertEqual(
            announcements.messages,
            ["Exported 1 item to \(BookExportWording.folderName(of: folder))."]
        )
    }

    /// The dialog draws a picker beside Transcript only while it is checked:
    /// on JSON and Markdown at first, listing its choices, and showing the
    /// format chosen.
    func testTheDialogDrawsTheTranscriptsPickerWhileItIsChecked() throws {
        let world = try makeIntegrationWorld("Transcript Export Drawn")
        let book = try makeTranscribedBook(in: world)
        let model = BookExportModel(books: [book], destination: try makeSandboxDirectory("Transcript Export Drawn Folder"))

        withHostedView(BookExportSheet(model: model, close: {}), until: { self.checkboxes(in: $0).count == 2 }) { hostingView in
            XCTAssertEqual(
                checkboxes(in: hostingView).count,
                2,
                "Audio and Transcript; the dialog is \(model.phase), listing \(model.choices.map(\.kind))"
            )
            XCTAssertFalse(model.isChecked(.transcript))
            XCTAssertEqual(popUps(in: hostingView).count, 0, "Transcript is unchecked: no picker")

            model.setChecked(true, for: .transcript)
            XCTAssertTrue(waitUntil(timeout: 5) {
                hostingView.layoutSubtreeIfNeeded()
                return self.popUps(in: hostingView).count == 1
            }, "checking the transcript draws its picker")
            XCTAssertEqual(popUps(in: hostingView).first?.titleOfSelectedItem, "JSON and Markdown")
            XCTAssertEqual(
                popUps(in: hostingView).first?.itemTitles,
                ["JSON and Markdown"] + TextExportWriters.all.map { $0.name } + ["WebVTT", "SubRip"]
            )

            model.setConversionID("transcript-srt", for: .transcript)
            XCTAssertTrue(waitUntil(timeout: 5) {
                hostingView.layoutSubtreeIfNeeded()
                return self.popUps(in: hostingView).first?.titleOfSelectedItem == "SubRip"
            }, "the picker shows the format chosen")

            model.setChecked(false, for: .transcript)
            XCTAssertTrue(waitUntil(timeout: 5) {
                hostingView.layoutSubtreeIfNeeded()
                return self.popUps(in: hostingView).isEmpty
            }, "unchecking the transcript takes its picker away")
        }
    }

    // MARK: - Support

    /// What is heard in the two tracks of "Harbour Captions": two sentences
    /// in its 3-second first track, one holding an "&", and one in its
    /// 2-second second track. The words are invented, so a line of the debug
    /// log that quoted them would stand out.
    private static let harbourSentences: [String: [TranscriptSentence]] = [
        "01.wav": [
            TranscriptFixtures.sentence("Gulls argue over the net shed.", from: 0, to: 1_500),
            TranscriptFixtures.sentence("Berths 4 & 5 stay shut till noon.", from: 1_500, to: 2_940),
        ],
        "02.wav": [
            TranscriptFixtures.sentence("The pilot boat ties up at the slip.", from: 0, to: 1_920),
        ],
    ]

    /// The captions of "Harbour Captions" in WebVTT.
    private static let harbourWebVTT = [
        "WEBVTT",
        "",
        "00:00:00.000 --> 00:00:01.500",
        "Gulls argue over the net shed.",
        "",
        "00:00:01.500 --> 00:00:02.940",
        "Berths 4 &amp; 5 stay shut till noon.",
        "",
        "00:00:03.000 --> 00:00:04.920",
        "The pilot boat ties up at the slip.",
    ].joined(separator: "\n") + "\n"

    /// The captions of "Harbour Captions" in SubRip, without the byte-order
    /// mark its file begins with.
    private static let harbourSubRip = [
        "1",
        "00:00:00,000 --> 00:00:01,500",
        "Gulls argue over the net shed.",
        "",
        "2",
        "00:00:01,500 --> 00:00:02,940",
        "Berths 4 & 5 stay shut till noon.",
        "",
        "3",
        "00:00:03,000 --> 00:00:04,920",
        "The pilot boat ties up at the slip.",
    ].joined(separator: "\r\n") + "\r\n"

    /// "Harbour Captions", an audiobook of two silent tracks of 3 and 2
    /// seconds in `world`, transcribed as `harbourSentences` say: its
    /// transcript.json and the Markdown written from it installed as a
    /// transcription installs them.
    private func makeTranscribedBook(in world: IntegrationWorld) throws -> Book {
        let book = try world.makeSilentAudioBook(title: "Harbour Captions", trackDurations: [3, 2])
        let transcript = try TranscriptFixtures.transcript(of: book, sentences: Self.harbourSentences)
        XCTAssertEqual(
            transcript.files.map(\.durationMilliseconds),
            [3_000, 2_000],
            "the tracks' lengths, by which the second track's captions are moved"
        )
        try TranscriptStore.install(transcript, for: book)
        return book
    }

    /// A transcript item as a transcribed audiobook's offer lists it: its
    /// transcript.json and the Markdown written from it, of 2,000 and 1,000
    /// bytes, only in the cloud when `inCloud`. Its files are never read.
    private func transcriptItem(inCloud: Bool) throws -> BookExportItem {
        let package = try makeSandboxDirectory("Transcript Export Item")
        let transcript = TextMouthPaths.transcriptPath(in: package)
        return BookExportItem(
            kind: .transcript,
            folderName: nil,
            files: [
                BookExportFile(source: .copy(transcript), path: "Harbour Captions - Transcript.json", byteCount: 2_000),
                BookExportFile(
                    source: .copy(package.appendingPathComponent("content.md")),
                    path: "Harbour Captions - Transcript.md",
                    byteCount: 1_000
                ),
            ],
            fileInCloud: inCloud ? transcript : nil
        )
    }

    /// The checkboxes SwiftUI drew inside `view`: the untitled AppKit
    /// buttons, leaving out the pickers' pop-up buttons.
    private func checkboxes(in view: NSView) -> [NSButton] {
        descendants(of: view, as: NSButton.self).filter { !($0 is NSPopUpButton) && $0.title.isEmpty }
    }

    /// The pop-up buttons SwiftUI drew inside `view`: the Convert to pickers.
    private func popUps(in view: NSView) -> [NSPopUpButton] {
        descendants(of: view, as: NSPopUpButton.self)
    }
}

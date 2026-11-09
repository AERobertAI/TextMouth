import XCTest
@testable import TextMouth

/// The WebVTT and SubRip readers (FMT23): `WebVTTReader` and `SubRipReader`
/// turn a file's bytes into a `TimedTextDocument`, sharing the timestamp
/// grammar, the markup and character references, and the finishing of the
/// cue list (`TimedTextMarkup`). The files are third-party data, so the
/// tests prove what the readers take, what they pass over and count, what
/// they refuse, and that nothing a file holds makes them fail any other
/// way. The samples are copied into a folder of the test's own before they
/// are read; no test plays sound.
final class TimedTextReaderTests: XCTestCase {

    // MARK: - Helpers

    /// A cue without timed words, from `start` to `end` milliseconds.
    private func cue(_ start: Int, _ end: Int, _ text: String, voice: String? = nil) -> TimedTextCue {
        TimedTextCue(startMilliseconds: start, endMilliseconds: end, text: text, voice: voice)
    }

    /// `text` read as the bytes of a WebVTT file.
    private func webVTT(_ text: String, maximumCues: Int = TimedTextLimits.maximumCues) throws -> TimedTextDocument {
        try WebVTTReader.read(Data(text.utf8), maximumCues: maximumCues)
    }

    /// `text` read as the bytes of a SubRip file.
    private func subRip(_ text: String, maximumCues: Int = TimedTextLimits.maximumCues) throws -> TimedTextDocument {
        try SubRipReader.read(Data(text.utf8), maximumCues: maximumCues)
    }

    /// The one cue of a WebVTT file whose one cue runs from 1 to 2 seconds
    /// and holds the lines `text`.
    private func webVTTCue(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> TimedTextCue {
        let document = try webVTT("WEBVTT\n\n00:01.000 --> 00:02.000\n\(text)\n")
        XCTAssertEqual(document.cues.count, 1, file: file, line: line)
        return try XCTUnwrap(document.cues.first, file: file, line: line)
    }

    /// The one cue of a SubRip file whose one cue, numbered 1, runs from 1 to
    /// 2 seconds and holds the lines `text`.
    private func subRipCue(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> TimedTextCue {
        let document = try subRip("1\n00:00:01,000 --> 00:00:02,000\n\(text)\n")
        XCTAssertEqual(document.cues.count, 1, file: file, line: line)
        return try XCTUnwrap(document.cues.first, file: file, line: line)
    }

    /// Asserts that `read` throws `expected`.
    private func assertRefuses(
        _ expected: TimedTextError, _ label: String = "",
        file: StaticString = #filePath, line: UInt = #line, _ read: () throws -> TimedTextDocument
    ) {
        XCTAssertThrowsError(try read(), label, file: file, line: line) { error in
            XCTAssertEqual(error as? TimedTextError, expected, label, file: file, line: line)
        }
    }

    /// Asserts that each reader either reads `data` into a document that
    /// keeps every promise `TimedTextDocument` makes, or refuses it with a
    /// `TimedTextError`, and fails in no other way. `label` names the case.
    private func assertReadsOrRefuses(_ data: Data, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let readers: [(format: TimedTextFormat, read: (Data, Int) throws -> TimedTextDocument)] = [
            (.webVTT, WebVTTReader.read), (.subRip, SubRipReader.read),
        ]
        for reader in readers {
            do {
                let document = try reader.read(data, TimedTextLimits.maximumCues)
                assertKeepsItsPromises(document, format: reader.format, "\(label), \(reader.format.name)", file: file, line: line)
            } catch is TimedTextError {
                // A refusal in the readers' own words is an answer too.
            } catch {
                XCTFail("\(label), \(reader.format.name): \(error)", file: file, line: line)
            }
        }
    }

    /// Asserts what every document read promises: its format, at least one
    /// cue, in the order they begin, each ending at or after its start and
    /// no later than `TimedTextLimits.maximumCueMilliseconds`, with plain text that
    /// is never blank and a voice that is nil or never blank, and whose
    /// sentences make a transcript `Transcript.validationFailure()` accepts.
    private func assertKeepsItsPromises(
        _ document: TimedTextDocument, format: TimedTextFormat, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(document.format, format, label, file: file, line: line)
        XCTAssertFalse(document.cues.isEmpty, label, file: file, line: line)
        XCTAssertEqual(document.cues.map(\.startMilliseconds), document.cues.map(\.startMilliseconds).sorted(), label, file: file, line: line)
        for cue in document.cues {
            XCTAssertTrue((0...cue.endMilliseconds).contains(cue.startMilliseconds), label, file: file, line: line)
            XCTAssertLessThanOrEqual(cue.endMilliseconds, TimedTextLimits.maximumCueMilliseconds, label, file: file, line: line)
            XCTAssertFalse(cue.text.isEmpty, label, file: file, line: line)
            XCTAssertEqual(cue.text, TimedTextCue.plainText(cue.text), label, file: file, line: line)
            XCTAssertNotEqual(cue.voice, "", label, file: file, line: line)
            XCTAssertNotEqual(cue.lastVoice, "", label, file: file, line: line)
        }
        // The promise that matters to a listener: the sentences made of the
        // cues, voices named, are ones a transcript trusts.
        assertSentencesAreTrusted(document, label, file: file, line: line)
    }

    /// A linear congruential generator (Knuth's MMIX constants) with a fixed
    /// seed, so the test's random bytes are the same on every run:
    /// `SystemRandomNumberGenerator` cannot be seeded. Each byte is the top
    /// eight bits of the state, the well-mixed ones; an LCG's low bits
    /// repeat quickly.
    private struct SeededBytes {
        /// The generator's state.
        private var state: UInt64

        /// A generator that starts from `seed`.
        init(seed: UInt64) {
            state = seed
        }

        /// The next byte.
        mutating func next() -> UInt8 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 56)
        }
    }

    // MARK: - The Samples

    /// The WebVTT sample (a header with text, a comment of two lines and one
    /// of one line, a cue identifier, cue settings, `<v>` and `<v.loud>`
    /// voices, `&amp;` and `<b>`, both forms of time, and a cue of two lines)
    /// reads as exactly its four cues, none passed over.
    func testTheWebVTTSampleReadsAsItsFourCues() throws {
        let sample = try copyOfFormatSample("vtt/tone4.vtt")
        let document = try WebVTTReader.read(Data(contentsOf: sample))

        XCTAssertEqual(document.format, .webVTT)
        XCTAssertEqual(document.cues, [
            cue(0, 900, "First tone, 440 hertz.", voice: "Ana"),
            cue(1_000, 1_900, "Second tone, 550 hertz & bold.", voice: "Ben"),
            cue(2_000, 2_900, "Third tone, café 660 hertz. Second line of the cue.", voice: "Ana"),
            cue(3_000, 3_900, "The fourth, 880 hertz, with no speaker."),
        ])
        XCTAssertEqual(document.skippedCueCount, 0)
    }

    /// The WebVTT sample's sentences name the speaker each time the speaker
    /// changes, Ana, Ben, and Ana again, and the cue with no speaker names
    /// nobody.
    func testTheWebVTTSamplesSentencesNameEachChangeOfSpeaker() throws {
        let sample = try copyOfFormatSample("vtt/tone4.vtt")
        let sentences = try WebVTTReader.read(Data(contentsOf: sample)).sentences

        XCTAssertEqual(sentences.map(\.text), [
            "Ana: First tone, 440 hertz.",
            "Ben: Second tone, 550 hertz & bold.",
            "Ana: Third tone, café 660 hertz. Second line of the cue.",
            "The fourth, 880 hertz, with no speaker.",
        ])
    }

    /// The SubRip sample (CR LF line endings, times with a comma, an `<i>`
    /// tag, and a cue of two lines) reads as exactly its four cues, with no
    /// voices, none passed over.
    func testTheSubRipSampleReadsAsItsFourCues() throws {
        let sample = try copyOfFormatSample("srt/tone4.srt")
        let document = try SubRipReader.read(Data(contentsOf: sample))

        XCTAssertEqual(document.format, .subRip)
        XCTAssertEqual(document.cues, [
            cue(0, 900, "This sentence belongs to the first tone, 440 hertz."),
            cue(1_000, 1_900, "This one belongs to the second tone, 550 hertz."),
            cue(2_000, 2_900, "Third tone, 660 hertz. A café, an étude."),
            cue(3_000, 3_900, "The fourth and last tone is 880 hertz."),
        ])
        XCTAssertEqual(document.skippedCueCount, 0)
    }

    // MARK: - Timestamps

    /// No control character that is not white space reaches a WebVTT or
    /// SubRip cue's text or voice (S2), written in the file or as a
    /// character reference, and a cue of nothing but control characters is
    /// passed over as blank.
    func testControlCharactersNeverReachACuesTextOrVoice() throws {
        XCTAssertEqual(
            try webVTTCue("Bell\u{7} and escape\u{1B} and delete\u{7F} and CSI\u{9B}.").text,
            "Bell and escape and delete and CSI."
        )
        XCTAssertEqual(try webVTTCue("By reference &#7;and&#27; here.").text, "By reference and here.")
        XCTAssertEqual(try webVTTCue("<v A\u{7}na>Hello.").voice, "Ana")
        XCTAssertEqual(try subRipCue("Bell\u{7} and escape\u{1B} and CSI\u{9B}.").text, "Bell and escape and CSI.")
        let blank = try webVTT("WEBVTT\n\n00:01.000 --> 00:02.000\n\u{7}\u{1B}\n\n00:03.000 --> 00:04.000\nWords.\n")
        XCTAssertEqual(blank.cues.map(\.text), ["Words."])
        XCTAssertEqual(blank.skippedCueCount, 1)
    }

    /// Every rule of the timestamp grammar, by the times it reads: hours,
    /// minutes, and seconds, or minutes and seconds; fields of one digit;
    /// hours of three digits and any value; minutes alone of four digits
    /// and any value; a "." or a "," before the fraction; a fraction of one
    /// to three digits read as tenths to thousandths, and its later digits
    /// dropped; and no fraction at all.
    func testTimestampsThatRead() {
        let readings: [(text: String, milliseconds: Int)] = [
            ("00:00:01.000", 1_000),
            ("00:01.000", 1_000),
            ("0:01.5", 1_500),
            ("1:02.5", 62_500),
            ("0:0:1", 1_000),
            ("00:01", 1_000),
            ("1:59:59.123", 7_199_123),
            ("100:00:00.000", 360_000_000),
            ("999:59:59.999", 3_599_999_999),
            ("75:00.000", 4_500_000),
            ("9999:59.999", 599_999_999),
            ("00:00:01,500", 1_500),
            ("00:00.5", 500),
            ("00:00.05", 50),
            ("00:00.005", 5),
            ("00:00.0059", 5),
            ("00:00.9999", 999),
            ("00:00.123456789012345678901234567890", 123),
        ]
        for reading in readings {
            XCTAssertEqual(TimedTextTimestamp.milliseconds(Substring(reading.text)), reading.milliseconds, reading.text)
        }
    }

    /// A timestamp is read from a slice of a longer line as from a string of
    /// its own.
    func testATimestampReadsFromASliceOfALine() throws {
        let line = "start 00:01:02.250 end"
        let slice = try XCTUnwrap(line.split(separator: " ")[safe: 1])

        XCTAssertEqual(TimedTextTimestamp.milliseconds(slice), 62_250)
    }

    /// Every way a text is no timestamp: one field or four, an empty field,
    /// a separator with no fraction after it, 60 seconds or 60 minutes,
    /// fields of too many digits, a letter, a sign, a space, another
    /// separator or two of them, and digits that are not ASCII.
    func testTimestampsThatDoNotRead() {
        let refusals = [
            "", "01", "1.000",
            "1:2:3:4", "00:00:00:01.000",
            ":01.000", "00::01.000", "00:01:", "a:00.000",
            "00:01.", "00:01,",
            "00:60.000", "00:00:60,000", "00:60:00.000",
            "1000:00:00.000", "00:100:00.000", "10000:00.000", "00:001.000",
            "00:1a.000", "00:01.0x0",
            "-1:00.000", "+1:00.000", "00:01.-5",
            " 00:01.000", "00:01.000 ", "0 0:01.000", "00 :01.000", "00:01\t.000",
            "00:01;000", "00:01..5", "00:01.5.", "00:01:02.000.5",
            "\u{FF10}0:01.000",
            "\u{0660}\u{0660}:\u{0660}\u{0661}.\u{0660}\u{0660}\u{0660}",
        ]
        for text in refusals {
            XCTAssertNil(TimedTextTimestamp.milliseconds(Substring(text)), text.debugDescription)
        }
    }

    // MARK: - WebVTT's Header and Blocks

    /// A WebVTT file begins with `WEBVTT`, alone or followed by a space or a
    /// tab and anything.
    func testAWebVTTFileBeginsWithItsSignatureLine() throws {
        for signature in ["WEBVTT", "WEBVTT ", "WEBVTT - four tones", "WEBVTT\tcaptions"] {
            let document = try webVTT("\(signature)\n\n00:01.000 --> 00:02.000\nHello.\n")
            XCTAssertEqual(document.cues.map(\.text), ["Hello."], signature)
        }
    }

    /// A file that does not begin with the signature line is no WebVTT file:
    /// `WEBVTTX`, an empty file, a blank first line, the word in lowercase or
    /// after a space, a shorter word, and a file of cues alone.
    func testAFileWithoutItsSignatureLineIsNotWebVTT() {
        let cueBlock = "00:01.000 --> 00:02.000\nHello.\n"
        let texts = [
            "WEBVTTX\n\n" + cueBlock, "", "\nWEBVTT\n\n" + cueBlock, "webvtt\n\n" + cueBlock,
            " WEBVTT\n\n" + cueBlock, "WEBVT\n\n" + cueBlock, cueBlock,
        ]
        for text in texts {
            assertRefuses(.notTimedText(.webVTT), text.debugDescription) { try webVTT(text) }
        }
    }

    /// The header's lines, up to the first blank line, are ignored.
    func testTheHeaderIsIgnoredUpToTheFirstBlankLine() throws {
        let document = try webVTT("WEBVTT\nKind: captions\nLanguage: en\n\n00:01.000 --> 00:02.000\nHello.\n")

        XCTAssertEqual(document.cues, [cue(1_000, 2_000, "Hello.")])
        XCTAssertEqual(document.skippedCueCount, 0)
    }

    /// A line holding "-->" ends the header as a blank line does, as in the
    /// W3C's reader, so a cue written right after the signature line or the
    /// header's lines is kept (decision 1).
    func testATimingLineEndsTheHeader() throws {
        let afterSignature = try webVTT("WEBVTT\n00:01.000 --> 00:02.000\nHello.\n\n00:02.000 --> 00:03.000\nAgain.\n")
        XCTAssertEqual(afterSignature.cues.map(\.text), ["Hello.", "Again."])

        let afterHeader = try webVTT("WEBVTT\nKind: captions\n00:01.000 --> 00:02.000\nHello.\n")
        XCTAssertEqual(afterHeader.cues.map(\.text), ["Hello."])
    }

    /// Comments (`NOTE`), style sheets (`STYLE`), and regions (`REGION`) are
    /// ignored, without being counted as cues passed over: the word alone or
    /// followed by a space or a tab, before the cues and between them.
    func testCommentStyleAndRegionBlocksAreIgnoredWithoutBeingCounted() throws {
        let document = try webVTT("""
        WEBVTT

        NOTE
        A comment of two lines,
        both ignored.

        NOTE a comment on one line

        NOTE\tafter a tab

        STYLE
        ::cue { color: yellow }

        REGION
        id:lower width:40%

        00:01.000 --> 00:02.000
        Hello.

        NOTE between the cues

        00:02.000 --> 00:03.000
        Again.
        """)

        XCTAssertEqual(document.cues.map(\.text), ["Hello.", "Again."])
        XCTAssertEqual(document.skippedCueCount, 0)
    }

    /// Only the words themselves begin a comment, a style sheet, or a
    /// region: a block beginning `NOTES` or `STYLESHEET` is a cue, and that
    /// line its identifier.
    func testOnlyTheWordsThemselvesBeginABlockHoldingNoCue() throws {
        let document = try webVTT("WEBVTT\n\nNOTES\n00:01.000 --> 00:02.000\nHello.\n\nSTYLESHEET\n00:02.000 --> 00:03.000\nAgain.\n")

        XCTAssertEqual(document.cues.map(\.text), ["Hello.", "Again."])
    }

    /// A cue's identifier, the line before its timing line, is ignored, as
    /// are the cue settings after its end; a block with no "-->" in its
    /// first two lines holds no cue, and is not counted.
    func testIdentifiersAndCueSettingsAreIgnored() throws {
        let document = try webVTT("""
        WEBVTT

        intro
        00:01.000 --> 00:02.000 align:start position:10% line:0
        Hello.

        00:02.000 --> 00:03.000\tvertical:rl
        Again.

        A stray line of text.

        3
        00:03.000 --> 00:04.000
        Third.
        """)

        XCTAssertEqual(document.cues, [
            cue(1_000, 2_000, "Hello."), cue(2_000, 3_000, "Again."), cue(3_000, 4_000, "Third."),
        ])
        XCTAssertEqual(document.skippedCueCount, 0)
    }

    /// A line holding "-->" that cannot be its block's timing line ends the
    /// block and begins the next, as in the W3C's reader (decision 1): a
    /// file missing the blank line between two cues reads as two cues,
    /// never as one whose text holds a timing line; a cue right after a
    /// comment or two stray lines is kept; and a timing line right after
    /// another leaves the first cue no text, so it is counted.
    func testATimingLineThatCannotBeItsBlocksBeginsTheNext() throws {
        let missingBlank = try webVTT("WEBVTT\n\n00:01.000 --> 00:02.000\nOne.\n00:02.000 --> 00:03.000\nTwo.\n")
        XCTAssertEqual(missingBlank.cues, [cue(1_000, 2_000, "One."), cue(2_000, 3_000, "Two.")])

        let afterComment = try webVTT("WEBVTT\n\nNOTE a comment\n00:01.000 --> 00:02.000\nHello.\n")
        XCTAssertEqual(afterComment.cues.map(\.text), ["Hello."])

        let afterStrayLines = try webVTT("WEBVTT\n\nstray\nlines\n00:01.000 --> 00:02.000\nHello.\n")
        XCTAssertEqual(afterStrayLines.cues.map(\.text), ["Hello."])
        XCTAssertEqual(afterStrayLines.skippedCueCount, 0)

        let twoTimingLines = try webVTT("WEBVTT\n\n00:01.000 --> 00:02.000\n00:02.000 --> 00:03.000\nTwo.\n")
        XCTAssertEqual(twoTimingLines.cues.map(\.text), ["Two."])
        XCTAssertEqual(twoTimingLines.skippedCueCount, 1)
    }

    // MARK: - Encodings and Line Endings

    /// A byte-order mark and CR LF line endings, as Windows tools write them,
    /// read like a plain file, in WebVTT (where the mark comes before the
    /// signature line) and in SubRip; so do the lone CR line endings of the
    /// classic Mac OS.
    func testAByteOrderMarkAndOtherLineEndingsRead() throws {
        let webVTTWithMark = try webVTT("\u{FEFF}WEBVTT\r\n\r\n00:01.000 --> 00:02.000\r\nHello.\r\n")
        XCTAssertEqual(webVTTWithMark.cues, [cue(1_000, 2_000, "Hello.")])

        let subRipWithMark = try subRip("\u{FEFF}1\r\n00:00:01,000 --> 00:00:02,000\r\nHello.\r\n\r\n")
        XCTAssertEqual(subRipWithMark.cues, [cue(1_000, 2_000, "Hello.")])

        let classicMac = try webVTT("WEBVTT\r\r00:01.000 --> 00:02.000\rHello.\r")
        XCTAssertEqual(classicMac.cues, [cue(1_000, 2_000, "Hello.")])
    }

    /// A file in UTF-16 with its byte-order mark reads.
    func testAUTF16FileReads() throws {
        var data = Data([0xFF, 0xFE])
        data.append(try XCTUnwrap("WEBVTT\n\n00:01.000 --> 00:02.000\nZoë.\n".data(using: .utf16LittleEndian)))

        XCTAssertEqual(try WebVTTReader.read(data).cues, [cue(1_000, 2_000, "Zoë.")])
    }

    /// A SubRip file in Windows-1252, the bytes of "café" with 0xE9, reads
    /// as "café".
    func testAWindows1252SubRipFileReadsInItsEncoding() throws {
        var data = Data("1\r\n00:00:01,000 --> 00:00:02,000\r\nA caf".utf8)
        data.append(0xE9)
        data.append(Data(" at the corner.\r\n".utf8))

        XCTAssertEqual(try SubRipReader.read(data).cues, [cue(1_000, 2_000, "A café at the corner.")])
    }

    /// A SubRip file in Shift JIS, as Japanese subtitle tools write one,
    /// reads as its Japanese text and not as a string of accented
    /// letters: eight lines are enough for the encoding to be known.
    func testAShiftJISSubRipFileReadsInItsEncoding() throws {
        let sentences = [
            "こんにちは、今日はいい天気ですね。", "はい、散歩に行きましょう。", "駅の近くに新しい喫茶店ができました。",
            "コーヒーが大好きなので、楽しみです。", "それでは、三時に会いましょう。", "遅れないように気をつけてください。",
            "雨が降るかもしれないので、傘を持って行きます。", "では、後でまたお会いしましょう。",
        ]
        let text = sentences.enumerated().map { number, sentence in
            "\(number + 1)\r\n00:00:\(String(format: "%02d", number * 2)),000 --> 00:00:\(String(format: "%02d", number * 2 + 1)),500\r\n\(sentence)\r\n"
        }.joined(separator: "\r\n")
        let data = try XCTUnwrap(text.data(using: .shiftJIS))

        let document = try SubRipReader.read(data)

        XCTAssertEqual(document.cues.map(\.text), sentences)
    }

    /// A file whose byte-order mark names UTF-16, but whose bytes are not
    /// UTF-16, is not timed text, and each reader says so in its own words.
    func testBytesNotInTheEncodingTheirMarkNamesAreNotTimedText() {
        let data = Data([0xFF, 0xFE, 0x57])

        assertRefuses(.notTimedText(.webVTT)) { try WebVTTReader.read(data) }
        assertRefuses(.notTimedText(.subRip)) { try SubRipReader.read(data) }
    }

    // MARK: - Cues Passed Over

    /// Each kind of cue that cannot be used is passed over and counted: a
    /// start that does not read, an end that does not read or is missing,
    /// an end before its start, text that is nothing but markup and white
    /// space, and no text at all. The cue after them is kept.
    func testEachUnusableCueIsPassedOverAndCounted() throws {
        let document = try webVTT("""
        WEBVTT

        00:0x.000 --> 00:02.000
        A start that does not read.

        00:01.000 --> 2 seconds
        An end that does not read.

        00:01.000 -->
        No end at all.

        00:03.000 --> 00:02.000
        An end before its start.

        00:01.000 --> 00:02.000
        <b> </b> <i></i>

        00:01.000 --> 00:02.000

        00:04.000 --> 00:05.000
        Kept.
        """)

        XCTAssertEqual(document.cues, [cue(4_000, 5_000, "Kept.")])
        XCTAssertEqual(document.skippedCueCount, 6)
    }

    /// SubRip passes over and counts the same cues, and a cue may end where
    /// it begins.
    func testSubRipPassesOverTheSameCues() throws {
        let document = try subRip("""
        1
        00:00:03,000 --> 00:00:02,000
        Backwards.

        2
        00:00:01,000 --> 00:00:02,000
        {\\an8}<i></i>

        3
        00:00:04,000 --> 00:00:04,000
        An instant.
        """)

        XCTAssertEqual(document.cues, [cue(4_000, 4_000, "An instant.")])
        XCTAssertEqual(document.skippedCueCount, 2)
    }

    /// A cue may end at `TimedTextLimits.maximumCueMilliseconds`, 1,000
    /// hours, and no later: one ending a millisecond after, or beginning
    /// after it, is passed over and counted. The grammar writes hours in
    /// three digits, so the test's limit is written in four, which does not
    /// read at all.
    func testTheLongestTimeIsKeptAndOneMillisecondMoreIsNot() throws {
        XCTAssertEqual(TimedTextLimits.maximumCueMilliseconds, 3_600_000_000)
        let document = try webVTT("""
        WEBVTT

        999:59:59.000 --> 999:59:59.999
        The last millisecond the grammar writes.

        1000:00:00.000 --> 1000:00:01.000
        Past the end.
        """)

        XCTAssertEqual(document.cues, [cue(3_599_999_000, 3_599_999_999, "The last millisecond the grammar writes.")])
        XCTAssertEqual(document.skippedCueCount, 1)
    }

    /// A cue timed past 100 hours, the length a single audio file may have
    /// (`Transcript.maximumMilliseconds`), is read in either format, as a
    /// book of more than 100 hours exports them (S: cue times past 100
    /// hours could not be read back by Attach Transcript...); the sentences
    /// are cut into the book's files afterwards, each counted from its file.
    func testCuesPast100HoursAreRead() throws {
        let past = Transcript.maximumMilliseconds
        let vtt = try webVTT("""
        WEBVTT

        99:59:59.000 --> 100:00:00.000
        Inside the hundredth hour.

        100:00:00.001 --> 100:00:01.000
        Past the hundredth hour.

        250:30:15.500 --> 250:30:16.000
        Far past.
        """)
        let subRipCues = try subRip("""
        1
        100:00:00,001 --> 100:00:01,000
        Past the hundredth hour.
        """)

        XCTAssertEqual(vtt.skippedCueCount, 0)
        XCTAssertEqual(vtt.cues.map(\.endMilliseconds), [past, past + 1_000, 902_416_000])
        XCTAssertEqual(subRipCues.cues, [cue(past + 1, past + 1_000, "Past the hundredth hour.")])
    }

    // MARK: - Markup

    /// Every tag is removed and its text stays: a timestamp tag, a class, a
    /// bold, an italic, an underline, a language, ruby and its text, and
    /// each closing tag.
    func testTagsAreRemovedAndTheirTextStays() throws {
        let tagged = try webVTTCue(
            "<00:00:01.500>Timed, <c.yellow.bg_blue>classed</c>, <b>bold</b>, <i>italic</i>, "
                + "<u>underlined</u>, <lang fr>français</lang>, <ruby>base<rt>reading</rt></ruby>."
        )

        XCTAssertEqual(tagged.text, "Timed, classed, bold, italic, underlined, français, basereading.")
        XCTAssertNil(tagged.voice)
    }

    /// A cue's voice is the first voice tag's annotation, and the tag leaves
    /// no trace in the text.
    func testTheFirstVoiceTagGivesTheCueItsVoice() throws {
        let spoken = try webVTTCue("<v Ana>Hello.</v>")

        XCTAssertEqual(spoken.voice, "Ana")
        XCTAssertEqual(spoken.text, "Hello.")
    }

    /// Another voice in the same cue is named where its tag stood ("Ben: "),
    /// once for each change of speaker: the same voice again puts nothing
    /// in, and the first voice is named again when she speaks after another.
    func testAnotherVoiceInOneCueIsNamedWhereItsTagStood() throws {
        let twoVoices = try webVTTCue("<v Ana>Hello.\n<v Ben>Hi.")
        XCTAssertEqual(twoVoices.voice, "Ana")
        XCTAssertEqual(twoVoices.text, "Hello. Ben: Hi.")

        XCTAssertEqual(try webVTTCue("<v Ana>Hello.\n<v Ana>Again.").text, "Hello. Again.")
        XCTAssertEqual(
            try webVTTCue("<v Ana>One.\n<v Ben>Two.\n<v Ben>Three.\n<v Ana>Four.").text,
            "One. Ben: Two. Three. Ana: Four."
        )
    }

    /// A cue in which another voice takes over ends in that voice, and the
    /// sentences name speakers by it: the next cue in the first voice names
    /// her again (else a listener hears her words as Ben's), and one in the
    /// second voice names nobody, since Ben spoke last. A cue that ends in
    /// its own voice has no last voice.
    func testTheVoiceThatSpeaksLastInACueIsTheOneNamedLast() throws {
        let handedOver = try webVTT("""
            WEBVTT

            00:01.000 --> 00:02.000
            <v Ana>Hi.<v Ben>Hello.

            00:03.000 --> 00:04.000
            <v Ana>Bye.

            00:05.000 --> 00:06.000
            <v Ana>Again.
            """)
        XCTAssertEqual(handedOver.cues.map(\.lastVoice), ["Ben", nil, nil])
        XCTAssertEqual(handedOver.sentences.map(\.text), ["Ana: Hi. Ben: Hello.", "Ana: Bye.", "Again."])

        let continued = try webVTT("""
            WEBVTT

            00:01.000 --> 00:02.000
            <v Ana>Hi.<v Ben>Hello.<v Ana>Yes.<v Ben>No.

            00:03.000 --> 00:04.000
            <v Ben>Right.
            """)
        XCTAssertEqual(continued.cues.map(\.lastVoice), ["Ben", nil])
        XCTAssertEqual(continued.sentences.map(\.text), ["Ana: Hi. Ben: Hello. Ana: Yes. Ben: No.", "Right."])
    }

    /// A voice's classes are not its name (`<v.loud.first Ben>` is "Ben"),
    /// and the white space of its annotation is made plain.
    func testAVoicesClassesAndWhiteSpaceAreNotItsName() throws {
        XCTAssertEqual(try webVTTCue("<v.loud.first Ben>Hi.").voice, "Ben")
        XCTAssertEqual(try webVTTCue("<v\tAna   Paula  >Hi.").voice, "Ana Paula")
    }

    /// Only a tag named `v` alone is a voice tag: `<vx Ana>` and `<V Ana>`
    /// are other tags, removed without naming anybody.
    func testOnlyATagNamedVAloneIsAVoice() throws {
        for text in ["<vx Ana>Hi.", "<V Ana>Hi.", "<voice Ana>Hi."] {
            let unvoiced = try webVTTCue(text)
            XCTAssertNil(unvoiced.voice, text)
            XCTAssertEqual(unvoiced.text, "Hi.", text)
        }
    }

    /// A voice tag naming nobody (`<v>`, `<v.loud>`, `<v   >`) gives no
    /// voice, puts nothing in the text, and leaves the voice named last as
    /// it was; the cue's voice is the first that names somebody
    /// (decision 2).
    func testAVoiceTagNamingNobodyLeavesNoTrace() throws {
        for text in ["<v>Hello.", "<v.loud>Hello.", "<v   >Hello."] {
            let unnamed = try webVTTCue(text)
            XCTAssertNil(unnamed.voice, text)
            XCTAssertEqual(unnamed.text, "Hello.", text)
        }

        let between = try webVTTCue("<v Ana>One.\n<v>Two.\n<v Ana>Three.")
        XCTAssertEqual(between.voice, "Ana")
        XCTAssertEqual(between.text, "One. Two. Three.")

        let namedLater = try webVTTCue("<v>One.\n<v Ben>Two.")
        XCTAssertEqual(namedLater.voice, "Ben")
        XCTAssertEqual(namedLater.text, "One. Two.")
    }

    /// A name put in never runs into the words before it: a space comes
    /// first when no white space stands before the tag (decision 3).
    func testANamePutInNeverRunsIntoTheWordsBeforeIt() throws {
        XCTAssertEqual(try webVTTCue("<v Ana>Hi.<v Ben>Hello.").text, "Hi. Ben: Hello.")
        XCTAssertEqual(try webVTTCue("<v Ana>Hi. <v Ben>Hello.").text, "Hi. Ben: Hello.")
    }

    /// A voice's character references are decoded, as the W3C's reader
    /// decodes an annotation, so the voice and the names put in read like
    /// the text; a name put in is never decoded a second time (decision 4).
    func testAVoicesCharacterReferencesAreDecodedOnce() throws {
        let voiced = try webVTTCue("<v Ana &amp; Ben>Together.\n<v Zo&#235;>Alone.\n<v &amp;lt;tag&amp;gt;>Odd.")

        XCTAssertEqual(voiced.voice, "Ana & Ben")
        XCTAssertEqual(voiced.text, "Together. Zoë: Alone. &lt;tag&gt;: Odd.")
    }

    /// Character references are decoded after the tags are removed:
    /// `&lt;b&gt;` is the text "<b>", never a tag; a decoded "&" is never
    /// read again (`&amp;lt;` is "&lt;"); a reference that a tag split in
    /// two is whole once the tag is gone; and the named references each
    /// become their character, the no-break space a space once the text is
    /// made plain.
    func testCharacterReferencesAreDecodedAfterTheTags() throws {
        XCTAssertEqual(try webVTTCue("&lt;b&gt;not bold&lt;/b&gt;").text, "<b>not bold</b>")
        XCTAssertEqual(try webVTTCue("&amp;lt;").text, "&lt;")
        XCTAssertEqual(try webVTTCue("&am<b>p;").text, "&")
        XCTAssertEqual(
            try webVTTCue("Q&amp;A, &quot;quoted&quot;, it&apos;s, 1&nbsp;2").text,
            "Q&A, \"quoted\", it's, 1 2"
        )
    }

    /// A numeric reference becomes the character it numbers, in decimal or
    /// in hexadecimal after an `x` or an `X`, in up to seven digits.
    func testNumericReferencesBecomeTheirCharacters() throws {
        XCTAssertEqual(
            try webVTTCue("Caf&#233;, &#x1F600;, &#X1F600;, &#x00E9;, &#0000233;").text,
            "Café, 😀, 😀, é, é"
        )
    }

    /// A reference that names no character TextMouth takes stays as written:
    /// U+0000, a name it does not know, no digits, more than seven digits, a
    /// surrogate, a number past Unicode, a digit that is not decimal, and an
    /// "&" with no ";".
    func testReferencesThatNameNoCharacterStayAsWritten() throws {
        let written = "&#0; &bogus; &#; &#x; &#00000233; &#xD800; &#x110000; &#12a; AT&T & co"

        XCTAssertEqual(try webVTTCue(written).text, written)
    }

    /// The marks of text direction, `&lrm;` and `&rlm;`, are removed.
    func testMarksOfDirectionAreRemoved() throws {
        XCTAssertEqual(try webVTTCue("left&lrm;to&rlm;right").text, "lefttoright")
    }

    /// A "<" with no ">" after it is text, with everything after it, in
    /// either format; one with a ">" after it begins a tag, since a file
    /// writes the character as `&lt;`.
    func testALoneLessThanSignIsText() throws {
        XCTAssertEqual(try webVTTCue("1 < 2, and 3 <= 4").text, "1 < 2, and 3 <= 4")
        XCTAssertEqual(try subRipCue("x < y").text, "x < y")
        XCTAssertEqual(try webVTTCue("x < y and y > z").text, "x z")
    }

    /// SubRip's overrides (`{\an8}`) are removed from a SubRip cue, while a
    /// `{\` with no `}` after it stays, and braces without a backslash are
    /// text; a WebVTT cue keeps an override as text.
    func testSubRipOverridesAreRemovedInSubRipAlone() throws {
        XCTAssertEqual(try subRipCue("{\\an8}At the top.").text, "At the top.")
        XCTAssertEqual(try subRipCue("{\\b1}Bold{\\b0} and {plain} braces.").text, "Bold and {plain} braces.")
        XCTAssertEqual(try subRipCue("{\\an8 <i>open</i>").text, "{\\an8 open")
        XCTAssertEqual(try subRipCue("x < y {\\an8}z").text, "x < y z")
        XCTAssertEqual(try webVTTCue("{\\an8}At the top.").text, "{\\an8}At the top.")
    }

    /// A combining mark right after a tag's ">" does not hide the tag's end,
    /// as it would among Swift's characters, where the two are one: the tag
    /// is removed, and the mark stays with the text after it.
    func testACombiningMarkAfterATagDoesNotHideIt() throws {
        XCTAssertEqual(try webVTTCue("<b>\u{0301}x</b>").text, "\u{0301}x")
        XCTAssertEqual(try webVTTCue("<v Ana>\u{0301}Hi.").voice, "Ana")
    }

    // MARK: - SubRip's Structure

    /// A cue number written without the blank line before it ends the cue
    /// before it, and is never its text (item 12).
    func testACueNumberWithoutTheBlankLineBeforeItIsNotText() throws {
        let document = try subRip("1\n00:00:01,000 --> 00:00:02,000\nFirst.\n2\n00:00:03,000 --> 00:00:04,000\nSecond.\n")

        XCTAssertEqual(document.cues, [cue(1_000, 2_000, "First."), cue(3_000, 4_000, "Second.")])
    }

    /// A line of digits is text when no timing line follows it, and spaces
    /// around a cue's number are allowed.
    func testDigitsNotFollowedByATimingLineAreText() throws {
        let document = try subRip(
            "1\n00:00:01,000 --> 00:00:02,000\nWe counted to\n3\n\n 2 \n00:00:03,000 --> 00:00:04,000\nThen to\n 4 \nand on.\n"
        )

        XCTAssertEqual(document.cues.map(\.text), ["We counted to 3", "Then to 4 and on."])
    }

    /// A cue's text ends at the next line holding "-->", even with no blank
    /// line or number before it.
    func testACuesTextEndsAtTheNextTimingLine() throws {
        let document = try subRip("00:00:01,000 --> 00:00:02,000\nOne.\n00:00:02,000 --> 00:00:03,000\nTwo.\n")

        XCTAssertEqual(document.cues, [cue(1_000, 2_000, "One."), cue(2_000, 3_000, "Two.")])
    }

    /// A line holding "-->" whose times do not read counts one cue passed
    /// over, and its lines up to the next blank line are never text
    /// (item 13).
    func testAnUnreadableTimingLineIsCountedAndItsLinesIgnored() throws {
        let document = try subRip(
            "1\n00:00:0X,000 --> 00:00:02,000\nLost words.\nMore lost words.\n\n2\n00:00:03,000 --> 00:00:04,000\nKept.\n"
        )

        XCTAssertEqual(document.cues, [cue(3_000, 4_000, "Kept.")])
        XCTAssertEqual(document.skippedCueCount, 1)
    }

    /// The lines after an unreadable timing line end where a cue's text
    /// would, so a broken cue missing the blank line after it does not take
    /// the next cue with it, numbered or not (decision 5).
    func testAnUnreadableTimingLineDoesNotTakeTheNextCue() throws {
        let numbered = try subRip("1\n00:00:0X,000 --> 00:00:02,000\nLost.\n2\n00:00:03,000 --> 00:00:04,000\nKept.\n")
        XCTAssertEqual(numbered.cues, [cue(3_000, 4_000, "Kept.")])
        XCTAssertEqual(numbered.skippedCueCount, 1)

        let unnumbered = try subRip("00:00:01,000 --> soon\nLost.\n00:00:03,000 --> 00:00:04,000\nKept.\n")
        XCTAssertEqual(unnumbered.cues, [cue(3_000, 4_000, "Kept.")])
        XCTAssertEqual(unnumbered.skippedCueCount, 1)
    }

    /// Cue numbers need not be in order, nor be there at all: the cues are
    /// read by their timing lines.
    func testCueNumbersNeedNotBeInOrderOrPresent() throws {
        let document = try subRip("""
        7
        00:00:03,000 --> 00:00:04,000
        Third.

        00:00:01,000 --> 00:00:02,000
        First, with no number.

        1
        00:00:02,000 --> 00:00:03,000
        Second.
        """)

        XCTAssertEqual(document.cues.map(\.text), ["First, with no number.", "Second.", "Third."])
        XCTAssertEqual(document.skippedCueCount, 0)
    }

    /// The coordinates some tools write after the times
    /// (`X1:40 X2:600 Y1:20 Y2:50`) are ignored, and a time written with a
    /// "." reads as one written with a ",".
    func testCoordinatesAfterTheTimesAreIgnored() throws {
        let document = try subRip(
            "1\n00:00:01,000 --> 00:00:02,500  X1:40 X2:600 Y1:20 Y2:50\nPlaced.\n\n2\n00:00:03.000 --> 00:00:04.000\nDotted.\n"
        )

        XCTAssertEqual(document.cues, [cue(1_000, 2_500, "Placed."), cue(3_000, 4_000, "Dotted.")])
    }

    /// Lines before the first timing line are ignored, and not counted.
    func testLinesBeforeTheFirstTimingLineAreIgnored() throws {
        let document = try subRip("Made with a subtitle editor\n\n\n1\n00:00:01,000 --> 00:00:02,000\nHello.\n")

        XCTAssertEqual(document.cues, [cue(1_000, 2_000, "Hello.")])
        XCTAssertEqual(document.skippedCueCount, 0)
    }

    // MARK: - Finishing

    /// A file of more cues than `maximumCues` is refused as soon as one too
    /// many is kept, in either format; as many as the limit read, and cues
    /// passed over do not count toward it.
    func testMoreCuesThanTheLimitAreRefused() throws {
        let fourCues = (1...4).map { "00:0\($0).000 --> 00:0\($0).500\nCue \($0).\n" }.joined(separator: "\n")
        assertRefuses(.tooManyCues(limit: 3)) { try webVTT("WEBVTT\n\n" + fourCues, maximumCues: 3) }
        XCTAssertEqual(try webVTT("WEBVTT\n\n" + fourCues, maximumCues: 4).cues.count, 4)

        let withOnePassedOver = try webVTT("WEBVTT\n\n" + fourCues + "\n00:09.000 --> 00:08.000\nBackwards.\n", maximumCues: 4)
        XCTAssertEqual(withOnePassedOver.cues.count, 4)
        XCTAssertEqual(withOnePassedOver.skippedCueCount, 1)

        let fourNumberedCues = (1...4).map { "\($0)\n00:00:0\($0),000 --> 00:00:0\($0),500\nCue \($0).\n" }.joined(separator: "\n")
        assertRefuses(.tooManyCues(limit: 3)) { try subRip(fourNumberedCues, maximumCues: 3) }
        XCTAssertEqual(try subRip(fourNumberedCues, maximumCues: 4).cues.count, 4)
    }

    /// A file holding no cue that can be used is refused, in its format's
    /// words: a WebVTT file of its signature line alone, of a comment alone,
    /// or of cues all passed over; an empty SubRip file, one of text alone,
    /// or one whose only cue cannot be used.
    func testAFileWithNoUsableCueIsRefused() {
        for text in ["WEBVTT", "WEBVTT\n\nNOTE only a comment\n", "WEBVTT\n\n00:02.000 --> 00:01.000\nBackwards.\n"] {
            assertRefuses(.noCues(.webVTT), text.debugDescription) { try webVTT(text) }
        }
        for text in ["", "Just a line of text.\n", "1\n00:00:0X,000 --> 00:00:01,000\nBroken.\n"] {
            assertRefuses(.noCues(.subRip), text.debugDescription) { try subRip(text) }
        }
    }

    /// Cues come back in the order they begin, whatever order the file gives
    /// them, and cues that begin together keep the file's order.
    func testCuesComeBackInTheOrderTheyBegin() throws {
        let document = try webVTT("""
        WEBVTT

        00:02.000 --> 00:03.000
        At two seconds, first in the file.

        00:01.000 --> 00:02.000
        At one second.

        00:02.000 --> 00:02.500
        At two seconds, second in the file.

        00:02.000 --> 00:04.000
        At two seconds, third in the file.
        """)

        XCTAssertEqual(document.cues.map(\.text), [
            "At one second.",
            "At two seconds, first in the file.",
            "At two seconds, second in the file.",
            "At two seconds, third in the file.",
        ])
    }

    // MARK: - Robustness

    /// Every prefix of each sample, cut every 5 bytes (inside a timing line,
    /// a tag, a reference, or the two bytes of an "é"), either reads or is
    /// refused with a `TimedTextError`, by either reader.
    func testEveryPrefixOfTheSamplesReadsOrIsRefused() throws {
        for samplePath in ["vtt/tone4.vtt", "srt/tone4.srt"] {
            let bytes = try Data(contentsOf: copyOfFormatSample(samplePath))
            for length in stride(from: 0, through: bytes.count, by: 5) {
                assertReadsOrRefuses(bytes.prefix(length), "\(samplePath) cut at \(length)")
            }
        }
    }

    /// Random bytes, a few kilobytes at a time from a fixed seed, either
    /// read or are refused with a `TimedTextError`, by either reader; half
    /// of them follow a signature line, so the WebVTT reader reads past it
    /// into the noise.
    func testRandomBytesReadOrAreRefused() {
        var generator = SeededBytes(seed: 0x7E57_F00D)
        for round in 0..<48 {
            let count = Int(generator.next()) * 16
            var bytes = (0..<count).map { _ in generator.next() }
            if round.isMultiple(of: 2) {
                bytes.insert(contentsOf: Array("WEBVTT\n\n".utf8), at: 0)
            }
            assertReadsOrRefuses(Data(bytes), "random round \(round)")
        }
    }

    /// Text made of the formats' own pieces in a random order from a fixed
    /// seed (arrows, times, tags open and closed, references whole and cut,
    /// overrides, digits, line breaks, a combining mark) either reads or is
    /// refused with a `TimedTextError`, by either reader: noise of the kind
    /// that takes every path through the markup.
    func testScrambledMarkupReadsOrIsRefused() {
        let pieces = [
            "<", ">", "&", ";", "#", "x", "{", "\\", "}", "-->", " --> ", "0", "1", "5", "9", ":", ".", ",",
            "\n", "\n\n", " ", "\t", "v", "<v ", "NOTE", "WEBVTT\n", "é", "\u{0301}", "&#", "&amp;", "<v Ana>",
            "00:00:01.000", "00:01,500", "\r", "\u{FEFF}",
        ]
        var generator = SeededBytes(seed: 0x5C2A_4B1E)
        for round in 0..<160 {
            var text = round.isMultiple(of: 2) ? "WEBVTT\n\n" : ""
            for _ in 0...Int(generator.next()) {
                text += pieces[safe: Int(generator.next()) % pieces.count] ?? ""
            }
            assertReadsOrRefuses(Data(text.utf8), "scrambled round \(round): \(text.debugDescription)")
        }
    }

    /// Each sample, damaged at random from a fixed seed (up to six bytes
    /// changed, added, or removed; 300 times each), either reads into a
    /// document whose sentences a transcript trusts or is refused with a
    /// `TimedTextError`, by either reader: the damage a truncated download
    /// or a bad disk does inside a tag, a time, a reference, or a
    /// multi-byte character.
    func testRandomlyDamagedSamplesReadOrAreRefused() throws {
        var generator = SeededGenerator(state: 0xD43A6E)
        for samplePath in ["vtt/tone4.vtt", "srt/tone4.srt"] {
            let bytes = try Data(contentsOf: copyOfFormatSample(samplePath))
            for round in 0..<300 {
                assertReadsOrRefuses(damaged(bytes, using: &generator), "\(samplePath), damage round \(round)")
            }
        }
    }

    /// The lines of a text (`TimedTextMarkup.Lines`, held as offsets into
    /// the text's bytes) are exactly the lines splitting it at each line
    /// feed gives, empty ones at the start, the end, and between two line
    /// feeds included, and an empty text is one empty line.
    func testTheLinesOfATextAreWhatSplittingItAtLineFeedsGives() throws {
        var generator = SeededBytes(seed: 0x11E5)
        let alphabet: [UInt8] = [10, 97, 98]
        var texts: [[UInt8]] = [[], [10], [97], [10, 10], [97, 10], [10, 97], [97, 10, 98, 10, 10, 99]]
        for _ in 0..<60 {
            texts.append((0..<Int(generator.next() % 48)).map { _ in alphabet[Int(generator.next()) % alphabet.count] })
        }

        for bytes in texts {
            let lines = try XCTUnwrap(TimedTextMarkup.Lines(bytes: bytes))
            let expected = bytes.split(separator: 10, omittingEmptySubsequences: false)
            XCTAssertEqual(lines.count, expected.count, "\(bytes)")
            XCTAssertEqual(lines.map { Array($0) }, expected.map { Array($0) }, "\(bytes)")
        }
    }

    /// A file of millions of blank lines is held as offsets, not as a
    /// slice of bytes for each (some 640 MB for 20 million lines on a Mac
    /// with 8 GB), and is read by either reader in a moment.
    func testAFileOfNothingButBlankLinesReadsInAMoment() throws {
        let blank = [UInt8](repeating: 10, count: 4_000_000)
        let webVTTFile = Data("WEBVTT\n\n00:01.000 --> 00:02.000\nHello.\n".utf8) + blank
        let subRipFile = Data("1\n00:00:01,000 --> 00:00:02,000\nHello.\n".utf8) + blank

        var texts: [String] = []
        let elapsed = try ContinuousClock().measure {
            texts = [try WebVTTReader.read(webVTTFile).cues[0].text, try SubRipReader.read(subRipFile).cues[0].text]
        }

        XCTAssertEqual(texts, ["Hello.", "Hello."])
        XCTAssertLessThan(elapsed, .seconds(10))
    }

    /// A hostile cue of 150,000 "<" and "{\" with no ">" or "}" after them
    /// stays as text and reads in a moment, in either format: each is known
    /// at once to have no closer, rather than by reading the rest of the cue
    /// again for each, which would take minutes. The limit leaves the
    /// moment it takes room fifty times over.
    func testAHostileCueReadsInAMoment() throws {
        let hostile = String(repeating: "<{\\", count: 150_000)
        var texts: [String] = []
        let elapsed = try ContinuousClock().measure {
            texts = [try subRipCue(hostile).text, try webVTTCue(hostile).text]
        }

        // The characters stay text (no tag or override is taken from them),
        // up to the most one cue keeps.
        let kept = String(hostile.prefix(TimedTextLimits.maximumCueCharacters))
        XCTAssertEqual(texts.map { $0 == kept }, [true, true], "each cue keeps its first characters as text")
        XCTAssertLessThan(elapsed, .seconds(10))
    }

    // MARK: - One Cue's Length

    /// A text of `count` sentences, "Sentence 1 is here. Sentence 2 is
    /// here. ...", on one line.
    private func sentences(_ count: Int) -> String {
        (1...count).map { "Sentence \($0) is here." }.joined(separator: " ")
    }

    /// A cue longer than the most one keeps is cut where a sentence ends,
    /// and is counted; a cue no longer is kept whole and not counted. The
    /// cut is the beginning of the text, in both file formats.
    func testACueLongerThanTheLimitIsCutWhereASentenceEnds() throws {
        let limit = TimedTextLimits.maximumCueCharacters
        let long = sentences(2_000)
        XCTAssertGreaterThan(long.count, limit, "the test's text is not longer than the limit")
        let cues = [("WebVTT", try webVTTCue(long)), ("SubRip", try subRipCue(long))]
        for (format, cue) in cues {
            XCTAssertTrue(cue.isCutShort, "\(format): a cue of \(long.count) characters was not marked cut")
            XCTAssertLessThanOrEqual(cue.text.count, limit, "\(format): the cut cue is longer than the limit")
            XCTAssertGreaterThan(cue.text.count, limit / 2, "\(format): the cut went back more than it needed to")
            XCTAssertTrue(cue.text.hasSuffix("is here."), "\(format): the cue ends mid-sentence: ...\(cue.text.suffix(30))")
            XCTAssertTrue(long.hasPrefix(cue.text), "\(format): the cue is not the beginning of the text")
        }

        // Exactly the limit is whole; one more character is cut.
        let exact = String(repeating: "a", count: limit)
        XCTAssertFalse(try webVTTCue(exact).isCutShort)
        XCTAssertEqual(try webVTTCue(exact).text.count, limit)
        XCTAssertTrue(try webVTTCue(exact + "a").isCutShort)
        let document = try webVTT("WEBVTT\n\n00:01.000 --> 00:02.000\n\(long)\n\n00:03.000 --> 00:04.000\nShort.\n")
        XCTAssertEqual(document.cutCueCount, 1)
        XCTAssertEqual(document.cues.map(\.isCutShort), [true, false])
    }

    /// Without a sentence's end in the second half of the text, a cue is
    /// cut at the last space; without a space, at the limit itself.
    func testACueWithoutASentenceEndIsCutBetweenWordsOrAtTheLimit() throws {
        let limit = TimedTextLimits.maximumCueCharacters
        let words = try webVTTCue(String(repeating: "word ", count: limit)).text
        XCTAssertTrue(words.hasSuffix("word"), "cut mid-word: ...\(words.suffix(12))")
        XCTAssertLessThanOrEqual(words.count, limit)
        XCTAssertGreaterThan(words.count, limit - 5)

        let unbroken = try webVTTCue(String(repeating: "x", count: limit * 3)).text
        XCTAssertEqual(unbroken.count, limit)

        // A sentence's end in the first half only is not worth cutting back
        // to: the text goes to its last space instead.
        let early = "Done." + String(repeating: " word", count: limit)
        let cut = try webVTTCue(early).text
        XCTAssertTrue(cut.hasSuffix("word"), "...\(cut.suffix(12))")
        XCTAssertGreaterThan(cut.count, limit - 10)
    }

    /// A speaker's name is kept to its limit, as the cue's voice and as a
    /// name put in the text where another voice takes over, so a name of
    /// megabytes is not copied into every sentence where the speaker
    /// changes.
    func testASpeakersNameIsKeptToItsLimit() throws {
        let limit = TimedTextLimits.maximumVoiceNameCharacters
        let name = String(repeating: "N", count: limit * 50)

        let cue = try webVTTCue("<v \(name)>Hello.<v Ben>Hi.<v \(name)>Again.")

        XCTAssertEqual(cue.voice?.count, limit)
        XCTAssertEqual(cue.text, "Hello. Ben: Hi. \(String(repeating: "N", count: limit)): Again.")
        XCTAssertFalse(cue.isCutShort)
    }

    /// 5 MB of one cue, the worst a fetched transcript may be, reads in a
    /// moment and keeps only the limit.
    func testAFiveMegabyteCueReadsInAMomentAndKeepsTheLimit() throws {
        let text = String(repeating: "a ", count: 2_500_000)
        var cue: TimedTextCue?
        let elapsed = try ContinuousClock().measure {
            cue = try webVTTCue(text)
        }

        XCTAssertEqual(cue?.isCutShort, true)
        XCTAssertLessThanOrEqual(cue?.text.count ?? .max, TimedTextLimits.maximumCueCharacters)
        XCTAssertLessThan(elapsed, .seconds(10))
    }
}

// MARK: - What the Reader Tests Share

extension XCTestCase {
    /// Asserts that the sentences of `document` make a transcript TextMouth
    /// trusts (`Transcript.validationFailure()`), and that each word of a
    /// cue still lies over the characters it lay over in the cue's text
    /// after a voice is named before it. `label` names the case.
    func assertSentencesAreTrusted(
        _ document: TimedTextDocument, _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        // A cue may be timed past a single file's 100 hours, on a book's
        // timeline; the sentences are laid across files of 100 hours as an
        // attach cuts them (`OutsideTranscript.split`), and the transcript
        // those make is the one that must be trusted.
        let files = (0..<10).map {
            TranscriptionPlan.File(path: "a\($0).mp3", url: URL(fileURLWithPath: "/nonexistent/a\($0).mp3"), duration: 360_000)
        }
        let byFile = OutsideTranscript.split(document.sentences, across: files)
        let transcript = TranscriptFixtures.transcript(files.compactMap { planFile in
            byFile[planFile.path].map { (path: planFile.path, duration: 360_000_000, sentences: $0) }
        })
        XCTAssertNil(transcript.validationFailure(), label, file: file, line: line)
        for (cue, sentence) in zip(document.cues, document.sentences) {
            let before = Array(cue.text.utf16)
            let after = Array(sentence.text.utf16)
            for (original, moved) in zip(cue.words, sentence.words) {
                guard original.characterOffset + original.characterCount <= before.count,
                      moved.characterOffset + moved.characterCount <= after.count else {
                    XCTFail("\(label): a word lies outside its text", file: file, line: line)
                    continue
                }
                XCTAssertEqual(
                    Array(before[original.characterOffset..<(original.characterOffset + original.characterCount)]),
                    Array(after[moved.characterOffset..<(moved.characterOffset + moved.characterCount)]),
                    "\(label): a word moved onto other characters", file: file, line: line
                )
            }
        }
    }

    /// `data` with between one and six bytes changed, added, or removed at
    /// places `generator` picks, so a run is the same each time.
    func damaged(_ data: Data, using generator: inout SeededGenerator) -> Data {
        var bytes = [UInt8](data)
        for _ in 0..<Int(1 + generator.next() % 6) where !bytes.isEmpty {
            let position = Int(generator.next() % UInt64(bytes.count))
            switch generator.next() % 3 {
            case 0: bytes[position] = UInt8(truncatingIfNeeded: generator.next())
            case 1: bytes.insert(UInt8(truncatingIfNeeded: generator.next()), at: position)
            default: bytes.remove(at: position)
            }
        }
        return Data(bytes)
    }
}

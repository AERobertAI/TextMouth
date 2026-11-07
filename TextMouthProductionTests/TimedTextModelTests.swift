import XCTest
@testable import TextMouth

/// The timed-text model every transcript reader shares (FMT23, FMT25;
/// `TextMouth/Models/TimedText.swift`): the formats' raw values, which files
/// keep, their extensions and names, how a file is known by its extension,
/// a cue's plain text, the sentences a file read makes, every reason a file
/// is refused, word for word, and the bounds a file is read within.
final class TimedTextModelTests: XCTestCase {

    // MARK: - Helpers

    /// A cue without timed words, from `start` to `end` milliseconds.
    private func cue(_ start: Int, _ end: Int, _ text: String, voice: String? = nil) -> TimedTextCue {
        TimedTextCue(startMilliseconds: start, endMilliseconds: end, text: text, voice: voice)
    }

    // MARK: - Formats

    /// The raw values are kept in transcript.json and bookInfo.json, where a
    /// transcript records where it came from, so they are pinned: a changed
    /// value would leave every file written before it unreadable.
    func testTheFormatsRawValuesNeverChange() {
        XCTAssertEqual(TimedTextFormat.webVTT.rawValue, "webvtt")
        XCTAssertEqual(TimedTextFormat.subRip.rawValue, "srt")
        XCTAssertEqual(TimedTextFormat.podcastJSON.rawValue, "podcast-json")
        XCTAssertEqual(TimedTextFormat.allCases, [.webVTT, .subRip, .podcastJSON])
    }

    /// A raw value read back from a file gives its format, through Codable
    /// as the stores read it, and an unknown one gives none.
    func testAFormatReadsBackFromItsRawValue() throws {
        let encoded = try JSONEncoder().encode([TimedTextFormat.subRip, .webVTT, .podcastJSON])
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"["srt","webvtt","podcast-json"]"#)
        XCTAssertEqual(try JSONDecoder().decode([TimedTextFormat].self, from: encoded), [.subRip, .webVTT, .podcastJSON])
        XCTAssertNil(TimedTextFormat(rawValue: "vtt"))
    }

    /// Each format's extension, without its dot, and its name as the screen
    /// shows it and VoiceOver speaks it.
    func testEachFormatHasItsExtensionAndName() {
        XCTAssertEqual(TimedTextFormat.webVTT.fileExtension, "vtt")
        XCTAssertEqual(TimedTextFormat.subRip.fileExtension, "srt")
        XCTAssertEqual(TimedTextFormat.podcastJSON.fileExtension, "json")
        XCTAssertEqual(TimedTextFormat.webVTT.name, "WebVTT")
        XCTAssertEqual(TimedTextFormat.subRip.name, "SubRip")
        XCTAssertEqual(TimedTextFormat.podcastJSON.name, "Podcasting 2.0 JSON")
    }

    /// A transcript file is known by its extension in any letter case,
    /// WebVTT preferred to SubRip, while a JSON file, a text file, and a
    /// file without an extension never are: too many other files end in
    /// .json.
    func testACueFileIsKnownByItsExtensionInAnyCase() {
        for fileExtension in ["vtt", "VTT", "Vtt"] {
            XCTAssertEqual(TimedTextFormat.cueFileFormat(forExtension: fileExtension), .webVTT, fileExtension)
        }
        for fileExtension in ["srt", "SRT"] {
            XCTAssertEqual(TimedTextFormat.cueFileFormat(forExtension: fileExtension), .subRip, fileExtension)
        }
        for fileExtension in ["json", "txt", ""] {
            XCTAssertNil(TimedTextFormat.cueFileFormat(forExtension: fileExtension), fileExtension)
        }
        XCTAssertEqual(TimedTextFormat.cueFileFormats, [.webVTT, .subRip])
    }

    // MARK: - Plain Text

    /// A cue's plain text makes each run of white space one space (tabs,
    /// line breaks, no-break spaces, and runs of spaces alike) and leaves
    /// none at either end; text of white space alone is empty.
    func testPlainTextMakesEachRunOfWhiteSpaceOneSpace() {
        XCTAssertEqual(
            TimedTextCue.plainText("\t Two\tlines,\nthen\n\na\u{00A0}no-break   space \u{00A0}\n"),
            "Two lines, then a no-break space"
        )
        XCTAssertEqual(TimedTextCue.plainText(" \t\n\u{00A0} "), "")
        XCTAssertEqual(TimedTextCue.plainText("Already plain."), "Already plain.")
    }

    /// A cue's plain text is what splitting at white space and joining with
    /// single spaces gives, for every mixture of white space of every kind,
    /// letters, a combining mark, a zero-width space (not white space), and
    /// an emoji: 500 texts from a fixed seed.
    func testPlainTextIsWhatSplittingAtWhiteSpaceAndJoiningGives() {
        let pieces = [" ", "\t", "\n", "\r\n", "\u{00A0}", "\u{2028}", "a", "bc", "e\u{0301}", "\u{200B}", "\u{1F600}"]
        var generator = SeededGenerator(state: 0x91A1_77E5)
        for _ in 0..<500 {
            let raw = (0..<Int(generator.next() % 24)).map { _ in pieces[Int(generator.next() % UInt64(pieces.count))] }
                .joined()
            let expected = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")

            XCTAssertEqual(TimedTextCue.plainText(raw), expected, raw.debugDescription)
        }
    }

    // MARK: - Sentences

    /// A cue's voice is named before its text when it is not the voice
    /// named last: not again for the next cue of the same voice, not for a
    /// cue without a voice, which leaves the voice named last as it was, and
    /// again once another voice has spoken. Ana, Ana, nobody, Ben, Ana names
    /// voices on the first, fourth, and fifth cues.
    func testAVoiceIsNamedEachTimeTheSpeakerChanges() {
        let document = TimedTextDocument(format: .webVTT, cues: [
            cue(0, 900, "One.", voice: "Ana"),
            cue(1_000, 1_900, "Two.", voice: "Ana"),
            cue(2_000, 2_900, "Three."),
            cue(3_000, 3_900, "Four.", voice: "Ben"),
            cue(4_000, 4_900, "Five.", voice: "Ana"),
        ])
        let sentences = document.sentences

        XCTAssertEqual(sentences.map(\.text), ["Ana: One.", "Two.", "Three.", "Ben: Four.", "Ana: Five."])
        XCTAssertEqual(sentences.map(\.startMilliseconds), [0, 1_000, 2_000, 3_000, 4_000])
        XCTAssertEqual(sentences.map(\.endMilliseconds), [900, 1_900, 2_900, 3_900, 4_900])
    }

    /// A cue without a voice between two cues of the same voice does not
    /// make the second name it again: the voice named last is still hers.
    func testACueWithoutAVoiceLeavesTheVoiceNamedLast() {
        let document = TimedTextDocument(format: .podcastJSON, cues: [
            cue(0, 900, "One.", voice: "Ana"),
            cue(1_000, 1_900, "Two."),
            cue(2_000, 2_900, "Three.", voice: "Ana"),
        ])

        XCTAssertEqual(document.sentences.map(\.text), ["Ana: One.", "Two.", "Three."])
    }

    /// A named cue's words move along by the name's length in UTF-16 units,
    /// so each still lies over its own characters: "Zoë: " is 5 units (and
    /// 6 bytes of UTF-8), "DJ 🎧: " is 7 units (and 6 characters).
    func testANamedCuesWordsMoveAlongByTheName() throws {
        let word = TranscriptWord(
            characterOffset: 6, characterCount: 5, startMilliseconds: 1_400, endMilliseconds: 1_900, confidence: 0.75
        )
        // The "ë" is written as one character, U+00EB, as a precomposed name is.
        for (voice, shift) in [("Zo\u{00EB}", 5), ("DJ \u{1F3A7}", 7)] {
            let document = TimedTextDocument(format: .podcastJSON, cues: [
                TimedTextCue(startMilliseconds: 1_000, endMilliseconds: 2_000, text: "Hello there", voice: voice, words: [word]),
            ])
            let sentence = try XCTUnwrap(document.sentences.first)
            let moved = try XCTUnwrap(sentence.words.first)

            XCTAssertEqual(sentence.text, "\(voice): Hello there")
            XCTAssertEqual(moved.characterOffset, 6 + shift, voice)
            XCTAssertEqual(moved.characterCount, 5, voice)
            XCTAssertEqual(moved.startMilliseconds, 1_400, voice)
            XCTAssertEqual(moved.endMilliseconds, 1_900, voice)
            XCTAssertEqual(moved.confidence, 0.75, voice)
            let range = try XCTUnwrap(
                Range(NSRange(location: moved.characterOffset, length: moved.characterCount), in: sentence.text)
            )
            XCTAssertEqual(sentence.text[range], "there", voice)
        }
    }

    /// The words of a cue named by nobody, or by the voice named last, keep
    /// their places.
    func testAnUnnamedCuesWordsKeepTheirPlaces() throws {
        let word = TranscriptWord(
            characterOffset: 0, characterCount: 4, startMilliseconds: 1_000, endMilliseconds: 1_300, confidence: nil
        )
        let document = TimedTextDocument(format: .podcastJSON, cues: [
            cue(0, 900, "Hi.", voice: "Ana"),
            TimedTextCue(startMilliseconds: 1_000, endMilliseconds: 2_000, text: "Well, then.", voice: "Ana", words: [word]),
        ])
        let second = try XCTUnwrap(document.sentences.last)

        XCTAssertEqual(second.text, "Well, then.")
        XCTAssertEqual(second.words, [word])
    }

    // MARK: - Why a File Is Not Read

    /// Every reason a file is refused, word for word, as the screen shows
    /// it, VoiceOver speaks it, and a braille display shows it.
    func testEveryReasonAFileIsRefusedIsWordedForTheListener() {
        XCTAssertEqual(
            TimedTextError.tooLarge(byteLimit: 5 * 1_048_576).errorDescription,
            "The file is larger than the 5 MB TextMouth reads as a transcript."
        )
        XCTAssertEqual(
            TimedTextError.tooLarge(byteLimit: 20 * 1_048_576).errorDescription,
            "The file is larger than the 20 MB TextMouth reads as a transcript."
        )
        XCTAssertEqual(
            TimedTextError.notTimedText(.webVTT).errorDescription,
            "The file isn't a WebVTT transcript TextMouth can read."
        )
        XCTAssertEqual(
            TimedTextError.notTimedText(.subRip).errorDescription,
            "The file isn't a SubRip transcript TextMouth can read."
        )
        XCTAssertEqual(
            TimedTextError.notTimedText(.podcastJSON).errorDescription,
            "The file isn't a Podcasting 2.0 JSON transcript TextMouth can read."
        )
        XCTAssertEqual(
            TimedTextError.unsupportedVersion(.podcastJSON, "2.0.0").errorDescription,
            "The file is a Podcasting 2.0 JSON transcript of version 2.0.0, which TextMouth doesn't read."
        )
        XCTAssertEqual(
            TimedTextError.noCues(.webVTT).errorDescription,
            "The WebVTT file holds no timed text TextMouth can use."
        )
        XCTAssertEqual(
            TimedTextError.noCues(.subRip).errorDescription,
            "The SubRip file holds no timed text TextMouth can use."
        )
        XCTAssertEqual(
            TimedTextError.tooManyCues(limit: 3).errorDescription,
            "The file holds more than 3 timed passages, more than TextMouth reads."
        )
        // The limit is written as the listener's Mac writes numbers.
        XCTAssertEqual(
            TimedTextError.tooManyCues(limit: TimedTextLimits.maximumCues).errorDescription,
            "The file holds more than \(250_000.formatted()) timed passages, more than TextMouth reads."
        )
    }

    // MARK: - Bounds

    /// The bounds a file is read within, as the charter set them: 20 MB from
    /// this Mac, 5 MB for a podcast's transcript and 1 MB for its chapters,
    /// 250,000 cues, and 5 seconds past the end of the audio.
    func testTheBoundsAreTheChartersOwn() {
        XCTAssertEqual(TimedTextLimits.localFileBytes, 20_971_520)
        XCTAssertEqual(TimedTextLimits.podcastTranscriptBytes, 5_242_880)
        XCTAssertEqual(TimedTextLimits.podcastChaptersBytes, 1_048_576)
        XCTAssertEqual(TimedTextLimits.maximumCues, 250_000)
        XCTAssertEqual(TimedTextLimits.pastTheEndMarginMilliseconds, 5_000)
    }
}

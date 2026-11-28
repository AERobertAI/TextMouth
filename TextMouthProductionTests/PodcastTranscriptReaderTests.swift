import XCTest
@testable import TextMouth

/// `PodcastTranscriptReader` reads a podcast episode's own transcript, in
/// Podcasting 2.0's JSON format, into timed text (FMT25): its usable
/// segments in the order they begin, each run of one speaker's words
/// gathered into a sentence that keeps every word's time. The sample is
/// copied into the test's own folder first; every other case is a small file
/// made here. No test plays sound or opens audio.
final class PodcastTranscriptReaderTests: XCTestCase {
    // MARK: - Helpers

    /// A transcript file listing `segments`, of `version` (left out when
    /// nil), as JSON bytes.
    private func transcript(_ segments: [Any], version: Any? = "1.0.0") throws -> Data {
        var file: [String: Any] = ["segments": segments]
        file["version"] = version
        return try podcastingJSON(file)
    }

    /// A segment whose fields hold exactly the values given, so a case can
    /// give any of them as a number, as text, or as anything else; a nil
    /// field is left out.
    private func segment(body: Any? = nil, startTime: Any? = nil, endTime: Any? = nil, speaker: Any? = nil) -> [String: Any] {
        var fields: [String: Any] = [:]
        fields["body"] = body
        fields["startTime"] = startTime
        fields["endTime"] = endTime
        fields["speaker"] = speaker
        return fields
    }

    /// A segment of `body` spoken by `speaker` from `start` to `end`
    /// milliseconds, its times written in seconds, as the format gives them.
    private func segment(_ body: String, from start: Int, to end: Int, speaker: String? = "Ana") -> [String: Any] {
        segment(body: body, startTime: seconds(start), endTime: seconds(end), speaker: speaker)
    }

    /// Each word of `text` (split at its spaces) as a segment of its own,
    /// spoken by `speaker`: the first begins at `start` milliseconds, and
    /// each lasts 100 ms, the next beginning as it ends.
    private func words(_ text: String, from start: Int = 0, speaker: String? = "Ana") -> [[String: Any]] {
        text.split(separator: " ").enumerated().map { index, word in
            segment(String(word), from: start + index * 100, to: start + index * 100 + 100, speaker: speaker)
        }
    }

    /// `milliseconds` as the seconds a Podcasting 2.0 file gives.
    private func seconds(_ milliseconds: Int) -> Double {
        Double(milliseconds) / 1_000
    }

    /// Each cue of `document` on one line, as "0...900 Ana: First tone.":
    /// its times, who speaks it ("nobody" when it names no one), and its text.
    private func lines(_ document: TimedTextDocument) -> [String] {
        document.cues.map { "\($0.startMilliseconds)...\($0.endMilliseconds) \($0.voice ?? "nobody"): \($0.text)" }
    }

    /// Each of `words` as the characters it covers in `text` and when it was
    /// spoken, as "fourth 3100...3200"; "outside the text" for a word that
    /// does not lie inside it.
    private func wordLines(_ words: [TranscriptWord], in text: String) -> [String] {
        let units = Array(text.utf16)
        return words.map { word in
            let end = word.characterOffset + word.characterCount
            guard word.characterOffset >= 0, word.characterCount > 0, end <= units.count else {
                return "outside the text"
            }
            let covered = String(decoding: units[word.characterOffset..<end], as: UTF16.self)
            return "\(covered) \(word.startMilliseconds)...\(word.endMilliseconds)"
        }
    }

    /// The sample transcript, read from a copy of it.
    private func readSample() throws -> TimedTextDocument {
        try PodcastTranscriptReader.read(Data(contentsOf: copyOfFormatSample("podcast-transcript-json/transcript.json")))
    }

    /// Whether a transcript of one 4-second file holding `document`'s
    /// sentences is one TextMouth trusts: nil when it is, or the reason.
    private func validationFailure(of document: TimedTextDocument) -> String? {
        TranscriptFixtures.transcript([(path: "tone4.wav", duration: 4_000, sentences: document.sentences)])
            .validationFailure()
    }

    /// Asserts that reading `data` with `maximumCues` throws `expected`.
    private func assertRefuses(
        _ data: Data,
        with expected: TimedTextError,
        maximumCues: Int = TimedTextLimits.maximumCues,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try PodcastTranscriptReader.read(data, maximumCues: maximumCues), file: file, line: line) { error in
            XCTAssertEqual(error as? TimedTextError, expected, file: file, line: line)
        }
    }

    // MARK: - The Sample

    /// The sample reads as four cues: three segments of several words, each
    /// a cue of its own spoken by the speaker it names, then Ben's eight
    /// words gathered into one sentence, which times each word where it
    /// lies in the text ("fourth" at offset 4, 6 long, 3100 to 3200 ms).
    func testTheSampleReadsAsThreeSentencesThenEightWordsGathered() throws {
        let document = try readSample()

        XCTAssertEqual(document.format, .podcastJSON)
        XCTAssertEqual(document.skippedCueCount, 0)
        XCTAssertEqual(lines(document), [
            "0...900 Ana: This sentence belongs to the first tone, 440 hertz.",
            "1000...1900 Ben: This one belongs to the second tone, 550 hertz.",
            "2000...2900 Ana: Third tone, 660 hertz. A café, an étude.",
            "3000...3800 Ben: The fourth and last tone is 880 hertz.",
        ])
        // A segment of several words times none of them.
        XCTAssertEqual(document.cues.map(\.words.count), [0, 0, 0, 8])
        let gathered = try XCTUnwrap(document.cues.last)
        XCTAssertEqual(wordLines(gathered.words, in: gathered.text), [
            "The 3000...3100", "fourth 3100...3200", "and 3200...3300", "last 3300...3400",
            "tone 3400...3500", "is 3500...3600", "880 3600...3700", "hertz. 3700...3800",
        ])
        XCTAssertEqual(
            gathered.words.dropFirst().first,
            TranscriptWord(characterOffset: 4, characterCount: 6, startMilliseconds: 3_100, endMilliseconds: 3_200, confidence: nil)
        )
    }

    /// The sample's sentences name the speaker each time it changes, which
    /// here is every sentence; the gathered sentence's words move along by
    /// its name, "Ben: ", so each still lies over its own characters; and a
    /// transcript of the sentences is one TextMouth trusts.
    func testTheSamplesSentencesNameEachSpeakerAndMakeATrustedTranscript() throws {
        let document = try readSample()
        let sentences = document.sentences

        XCTAssertEqual(sentences.map(\.text), [
            "Ana: This sentence belongs to the first tone, 440 hertz.",
            "Ben: This one belongs to the second tone, 550 hertz.",
            "Ana: Third tone, 660 hertz. A café, an étude.",
            "Ben: The fourth and last tone is 880 hertz.",
        ])
        let gatheredCue = try XCTUnwrap(document.cues.last)
        let gatheredSentence = try XCTUnwrap(sentences.last)
        XCTAssertEqual(gatheredSentence.words.map(\.characterOffset), gatheredCue.words.map { $0.characterOffset + 5 })
        XCTAssertEqual(
            wordLines(gatheredSentence.words, in: gatheredSentence.text),
            wordLines(gatheredCue.words, in: gatheredCue.text)
        )
        XCTAssertNil(validationFailure(of: document))
    }

    /// No control character that is not white space reaches a segment's text
    /// or its speaker (S2), as NUL and BEL in a feed's JSON would otherwise
    /// reach a downloaded episode's text.
    func testControlCharactersNeverReachASegmentsTextOrSpeaker() throws {
        let document = try PodcastTranscriptReader.read(transcript([
            segment("before\u{0}after, and a bell\u{7}.", from: 0, to: 900, speaker: "A\u{0}na"),
        ]))

        XCTAssertEqual(lines(document), ["0...900 Ana: beforeafter, and a bell."])
    }

    // MARK: - Versions

    /// A file of major version 1 is read however it writes its version
    /// ("1.0.0", "1", "1.5"); so is one whose version is a number rather
    /// than text, and one that gives none.
    func testVersionOneAndAVersionThatIsNotTextAreRead() throws {
        for version: Any? in ["1.0.0", "1", "1.5", 1.0, nil] {
            let document = try PodcastTranscriptReader.read(transcript([segment("Hello there.", from: 0, to: 900)], version: version))
            XCTAssertEqual(lines(document), ["0...900 Ana: Hello there."], "version \(String(describing: version))")
        }
    }

    /// A file of another major version is refused, naming its version as
    /// the file gives it, cut to its first 20 characters.
    func testAnotherMajorVersionIsRefusedByName() throws {
        let hello = [segment("Hello there.", from: 0, to: 900)]
        assertRefuses(try transcript(hello, version: "2.0.0"), with: .unsupportedVersion(.podcastJSON, "2.0.0"))
        assertRefuses(try transcript(hello, version: ""), with: .unsupportedVersion(.podcastJSON, ""))

        let long = "2.0.0-" + String(repeating: "b", count: 34)
        XCTAssertEqual(long.count, 40)
        assertRefuses(try transcript(hello, version: long), with: .unsupportedVersion(.podcastJSON, "2.0.0-bbbbbbbbbbbbbb"))
    }

    // MARK: - What Is Not a Transcript

    /// What is not a Podcasting 2.0 transcript is refused as one: bytes that
    /// are not JSON, no bytes, an array at the top, a file without segments,
    /// and segments that are not a list.
    func testWhatIsNotATranscriptIsRefused() throws {
        let cases = try [
            Data("WEBVTT\n\n00:00.000 --> 00:01.000\nHello there.".utf8),
            Data(),
            podcastingJSON([segment("Hello there.", from: 0, to: 900)]),
            podcastingJSON(["version": "1.0.0"]),
            podcastingJSON(["version": "1.0.0", "segments": segment("Hello there.", from: 0, to: 900)]),
        ]
        for data in cases {
            assertRefuses(data, with: .notTimedText(.podcastJSON))
        }
    }

    /// A file with no segments, or none that can be used, holds no cues,
    /// and is refused as such.
    func testAFileWithNoUsableSegmentIsRefused() throws {
        assertRefuses(try transcript([]), with: .noCues(.podcastJSON))
        assertRefuses(try transcript([5, segment(body: "   ", startTime: 0, endTime: 1)]), with: .noCues(.podcastJSON))
    }

    // MARK: - Segments Passed Over

    /// An element of the list that is not an object (a number, text, null,
    /// or a list) is passed over and counted, and the segments around it
    /// are read.
    func testElementsThatAreNotObjectsArePassedOverAndCounted() throws {
        let document = try PodcastTranscriptReader.read(transcript([
            5, "Hello there.", NSNull(), [1, 2], segment("Hello there.", from: 0, to: 900),
        ]))

        XCTAssertEqual(lines(document), ["0...900 Ana: Hello there."])
        XCTAssertEqual(document.skippedCueCount, 4)
    }

    /// A time given as text holding a number is read as that number of
    /// seconds.
    func testTimesGivenAsTextAreRead() throws {
        let document = try PodcastTranscriptReader.read(transcript([
            segment(body: "Hello there.", startTime: "1.5", endTime: "2", speaker: "Ana"),
        ]))

        XCTAssertEqual(lines(document), ["1500...2000 Ana: Hello there."])
    }

    /// A segment is passed over and counted when a time is missing,
    /// negative, true, text that reads as no finite number ("nan", which
    /// Swift reads as NaN, "inf", "soon"), or later than the latest moment
    /// a transcript may place a sentence; a segment at that very moment is
    /// read.
    func testSegmentsWithUnusableTimesArePassedOverAndCounted() throws {
        let maximum = Transcript.maximumMilliseconds
        let unusable = [
            segment(body: "No start.", endTime: 1),
            segment(body: "No end.", startTime: 0),
            segment(body: "A negative start.", startTime: -1, endTime: 1),
            segment(body: "A negative end.", startTime: 0, endTime: -0.5),
            segment(body: "A start of true.", startTime: true, endTime: 1),
            segment(body: "A start of nan.", startTime: "nan", endTime: 1),
            segment(body: "An end of inf.", startTime: 0, endTime: "inf"),
            segment(body: "A start of soon.", startTime: "soon", endTime: 1),
            segment(body: "An end past the maximum.", startTime: 0, endTime: seconds(maximum + 1)),
        ]
        let atTheMaximum = segment(body: "At the maximum.", startTime: seconds(maximum), endTime: seconds(maximum))

        let document = try PodcastTranscriptReader.read(transcript(unusable + [atTheMaximum]))

        XCTAssertEqual(lines(document), ["\(maximum)...\(maximum) nobody: At the maximum."])
        XCTAssertEqual(document.skippedCueCount, unusable.count)
    }

    /// A segment that ends before it starts is passed over and counted; one
    /// that ends as it starts is read.
    func testASegmentEndingBeforeItStartsIsPassedOver() throws {
        let document = try PodcastTranscriptReader.read(transcript([
            segment("Backwards in time.", from: 2_000, to: 1_999),
            segment("No time at all.", from: 3_000, to: 3_000),
        ]))

        XCTAssertEqual(lines(document), ["3000...3000 Ana: No time at all."])
        XCTAssertEqual(document.skippedCueCount, 1)
    }

    /// A segment whose body is a number, is missing, or holds nothing but
    /// white space is passed over and counted; the white space of a body
    /// that is read is finished as every cue's is, each run one space and
    /// none at either end.
    func testBodiesThatAreNotTextOrBlankArePassedOver() throws {
        let document = try PodcastTranscriptReader.read(transcript([
            segment(body: 42, startTime: 0, endTime: 1),
            segment(startTime: 0, endTime: 1, speaker: "Ana"),
            segment(body: " \n\t\u{00A0}", startTime: 0, endTime: 1),
            segment(body: "  Two\n lines,\tone   cue. ", startTime: 1, endTime: 2),
        ]))

        XCTAssertEqual(lines(document), ["1000...2000 nobody: Two lines, one cue."])
        XCTAssertEqual(document.skippedCueCount, 3)
    }

    /// A speaker is finished as a cue's text is; one that is blank, or is
    /// not text, names nobody, and its segment is still read.
    func testBlankSpeakersAndOnesThatAreNotTextNameNobody() throws {
        let document = try PodcastTranscriptReader.read(transcript([
            segment(body: "First sentence here.", startTime: 0, endTime: 1, speaker: "  Ana \n Lee "),
            segment(body: "Second sentence here.", startTime: 1, endTime: 2, speaker: " \t "),
            segment(body: "Third sentence here.", startTime: 2, endTime: 3, speaker: ""),
            segment(body: "Fourth sentence here.", startTime: 3, endTime: 4, speaker: 7),
        ]))

        XCTAssertEqual(document.cues.map(\.voice), ["Ana Lee", nil, nil, nil])
        XCTAssertEqual(document.skippedCueCount, 0)
    }

    // MARK: - Order

    /// Segments are put in the order they begin before any word is
    /// gathered, and segments that begin together keep the file's order.
    func testSegmentsAreOrderedByStartKeepingTheFilesOrderForTies() throws {
        let document = try PodcastTranscriptReader.read(transcript([
            segment("world.", from: 100, to: 200),
            segment("Said second, listed first.", from: 1_000, to: 1_500, speaker: "Ben"),
            segment("Hello", from: 0, to: 100),
            segment("Said second, listed second.", from: 1_000, to: 1_200, speaker: "Ben"),
        ]))

        XCTAssertEqual(lines(document), [
            "0...200 Ana: Hello world.",
            "1000...1500 Ben: Said second, listed first.",
            "1000...1200 Ben: Said second, listed second.",
        ])
        XCTAssertNil(validationFailure(of: document))
    }

    // MARK: - Words Into Sentences

    /// Words gather while one speaker speaks them: a word of another speaker
    /// begins another sentence, and words that name nobody gather together.
    func testWordsGatherByTheirSpeaker() throws {
        let document = try PodcastTranscriptReader.read(transcript(
            words("Good morning", from: 0, speaker: "Ana")
                + words("to you", from: 200, speaker: "Ben")
                + words("and you", from: 400, speaker: nil)
                + words("said Ana", from: 600, speaker: "Ana")
        ))

        XCTAssertEqual(lines(document), [
            "0...200 Ana: Good morning",
            "200...400 Ben: to you",
            "400...600 nobody: and you",
            "600...800 Ana: said Ana",
        ])
    }

    /// Words gather while each begins less than a second after the word
    /// before it ends: a silence of 999 ms joins two words, and one of
    /// exactly 1,000 ms begins another sentence.
    func testASilenceOfASecondBeginsAnotherSentence() throws {
        XCTAssertEqual(PodcastTranscriptReader.wordGapMilliseconds, 1_000)

        let joined = try PodcastTranscriptReader.read(transcript([
            segment("Joined", from: 0, to: 500),
            segment("here", from: 1_499, to: 1_600),
        ]))
        XCTAssertEqual(lines(joined), ["0...1600 Ana: Joined here"])

        let split = try PodcastTranscriptReader.read(transcript([
            segment("Split", from: 0, to: 500),
            segment("here", from: 1_500, to: 1_600),
        ]))
        XCTAssertEqual(lines(split), ["0...500 Ana: Split", "1500...1600 Ana: here"])
    }

    /// A word that begins before the word ahead of it ends joins it; the
    /// sentence ends at the latest end among its words, which need not be
    /// its last word's; and each word keeps its own time.
    func testOverlappingWordsJoinAndTheSentenceEndsAtTheLatestEnd() throws {
        let document = try PodcastTranscriptReader.read(transcript([
            segment("Long", from: 0, to: 2_000),
            segment("short", from: 500, to: 700),
            segment("words.", from: 1_200, to: 1_500),
        ]))

        XCTAssertEqual(lines(document), ["0...2000 Ana: Long short words."])
        let sentence = try XCTUnwrap(document.cues.first)
        XCTAssertEqual(wordLines(sentence.words, in: sentence.text), ["Long 0...2000", "short 500...700", "words. 1200...1500"])
        XCTAssertNil(validationFailure(of: document))
    }

    /// A word ending in ".", "?", "!", or "…" ends its sentence, even with
    /// closing quotation marks or brackets after the mark, and the next
    /// word begins another; a "." inside a word ends nothing.
    func testAWordEndingASentenceEndsItsCue() throws {
        let document = try PodcastTranscriptReader.read(transcript(words(
            "Who goes? It cost 3.5 pounds. Then “stop!” She waited… (Quietly.) He said.\" [Sic.] Fine.’ Done"
        )))

        XCTAssertEqual(document.cues.map(\.text), [
            "Who goes?",
            "It cost 3.5 pounds.",
            "Then “stop!”",
            "She waited…",
            "(Quietly.)",
            "He said.\"",
            "[Sic.]",
            "Fine.’",
            "Done",
        ])
    }

    /// A sentence gathers at most 60 words: the 61st word of an unbroken
    /// run begins another.
    func testASentenceGathersAtMostSixtyWords() throws {
        XCTAssertEqual(PodcastTranscriptReader.maximumWordsPerSentence, 60)
        let run = (1...61).map { "w\($0)" }.joined(separator: " ")

        let document = try PodcastTranscriptReader.read(transcript(words(run)))

        XCTAssertEqual(document.cues.map(\.words.count), [60, 1])
        XCTAssertEqual(document.cues.map(\.startMilliseconds), [0, 6_000])
        XCTAssertEqual(document.cues.last?.text, "w61")
        XCTAssertNil(validationFailure(of: document))
    }

    /// A segment of several words ends the sentence being gathered and is a
    /// cue of its own, timing no words; the word after it begins another
    /// sentence, and a lone word is a cue of one timed word.
    func testASegmentOfSeveralWordsEndsTheSentenceBeingGathered() throws {
        let document = try PodcastTranscriptReader.read(transcript(
            words("One two", from: 0)
                + [segment("A whole sentence.", from: 200, to: 900)]
                + words("three", from: 900)
        ))

        XCTAssertEqual(lines(document), [
            "0...200 Ana: One two",
            "200...900 Ana: A whole sentence.",
            "900...1000 Ana: three",
        ])
        XCTAssertEqual(document.cues.map(\.words.count), [2, 0, 1])
        XCTAssertEqual(
            document.cues.last?.words,
            [TranscriptWord(characterOffset: 0, characterCount: 5, startMilliseconds: 900, endMilliseconds: 1_000, confidence: nil)]
        )
    }

    // MARK: - Hostile Files

    /// Asserts that `data` is refused with a `TimedTextError`, or read into
    /// a document whose sentences a transcript trusts; `label` names the case.
    private func assertReadsOrRefuses(_ data: Data, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        do {
            let document = try PodcastTranscriptReader.read(data)
            assertSentencesAreTrusted(document, label, file: file, line: line)
        } catch is TimedTextError {
            // A refusal in the reader's own words is an answer too.
        } catch {
            XCTFail("\(label): \(error)", file: file, line: line)
        }
    }

    /// Files made to cost or to trap (lists nested 20,000 deep, numbers
    /// beyond a Double, times written as hexadecimal, "-0", or "nan", a
    /// body of 5 MB) are read or refused in a moment, and what is read is
    /// trusted: no time overflows, and none passes the latest moment.
    func testHostileFilesReadOrAreRefusedInAMoment() {
        let deep = String(repeating: "[", count: 20_000) + String(repeating: "]", count: 20_000)
        let bigBody = String(repeating: "word ", count: 1_000_000)
        let times = ["1e308", "1e999", "-0", "-0.0", "0x10", "1e-400", "nan", "Infinity", "360000", "360000.0004", "360000.001"]
        var files: [String: String] = [
            "nested list": "{\"segments\": \(deep)}",
            "nested element": "{\"segments\": [{\"startTime\": 0, \"endTime\": 1, \"body\": \(deep)}]}",
            "a body of 5 MB": "{\"segments\": [{\"startTime\": 0, \"endTime\": 1, \"body\": \"\(bigBody)\"}]}",
        ]
        for time in times {
            files["time \(time) as text"] = "{\"segments\": [{\"startTime\": \"\(time)\", \"endTime\": \"\(time)\", \"body\": \"a b\"}]}"
            files["time \(time) as a number"] = "{\"segments\": [{\"startTime\": \(time), \"endTime\": \(time), \"body\": \"a b\"}]}"
        }

        let elapsed = ContinuousClock().measure {
            for (label, json) in files {
                assertReadsOrRefuses(Data(json.utf8), label)
            }
        }

        XCTAssertLessThan(elapsed, .seconds(20))
    }

    /// The sample, damaged at random from a fixed seed (up to six bytes
    /// changed, added, or removed; 400 times), and cut at every length,
    /// is read into trusted sentences or refused with a `TimedTextError`.
    func testTheDamagedSampleReadsOrIsRefused() throws {
        let bytes = try Data(contentsOf: copyOfFormatSample("podcast-transcript-json/transcript.json"))
        var generator = SeededGenerator(state: 0x50D_CA57)
        for length in 0...bytes.count {
            assertReadsOrRefuses(bytes.prefix(length), "cut at \(length)")
        }
        for round in 0..<400 {
            assertReadsOrRefuses(damaged(bytes, using: &generator), "damage round \(round)")
        }
    }

    // MARK: - The Limit

    /// More cues than the limit refuses the file, naming the limit, and as
    /// many as the limit is read; words gathered into sentences count as
    /// the sentences they make.
    func testMoreCuesThanTheLimitAreRefused() throws {
        let threeSentences = try transcript([
            segment("The first one.", from: 0, to: 900),
            segment("The second one.", from: 1_000, to: 1_900),
            segment("The third one.", from: 2_000, to: 2_900),
        ])
        assertRefuses(threeSentences, with: .tooManyCues(limit: 2), maximumCues: 2)
        XCTAssertEqual(try PodcastTranscriptReader.read(threeSentences, maximumCues: 3).cues.count, 3)

        let twoSentencesOfWords = try transcript(words("One sentence here. And another one."))
        XCTAssertEqual(try PodcastTranscriptReader.read(twoSentencesOfWords, maximumCues: 2).cues.count, 2)
    }

    /// One segment's text longer than a cue keeps is cut where a sentence
    /// ends and counted, and so is a speaker's name past its limit, which a
    /// transcript puts before the text each time the speaker changes.
    func testALongSegmentAndALongSpeakersNameAreCut() throws {
        let limit = TimedTextLimits.maximumCueCharacters
        let long = (1...2_000).map { "Sentence \($0) is here." }.joined(separator: " ")
        let name = String(repeating: "N", count: TimedTextLimits.maximumVoiceNameCharacters * 50)

        let document = try PodcastTranscriptReader.read(
            transcript([segment(long, from: 0, to: 900, speaker: name), segment("Short.", from: 1_000, to: 1_900, speaker: name)])
        )

        XCTAssertEqual(document.cues.map(\.isCutShort), [true, false])
        XCTAssertEqual(document.cutCueCount, 1)
        let first = try XCTUnwrap(document.cues.first)
        XCTAssertLessThanOrEqual(first.text.count, limit)
        XCTAssertTrue(first.text.hasSuffix("is here."), "the cue ends mid-sentence: ...\(first.text.suffix(30))")
        XCTAssertTrue(long.hasPrefix(first.text), "the cue is not the beginning of the text")
        XCTAssertEqual(first.voice?.count, TimedTextLimits.maximumVoiceNameCharacters)
    }

    /// Words of a feed that times every word are gathered into a sentence
    /// of sixty at most, but not past the limit one cue keeps: sixty words
    /// of 4,000 characters make cues of two words each, none cut.
    func testWordsAreNotGatheredPastTheLimitOfOneCue() throws {
        let bigWord = String(repeating: "w", count: 4_000)
        let segments = (0..<60).map { segment(bigWord, from: $0 * 100, to: $0 * 100 + 100) }

        let document = try PodcastTranscriptReader.read(transcript(segments))

        XCTAssertEqual(document.cues.count, 30, "sixty words of 4,000 characters were not made two to a cue")
        let longest = document.cues.map(\.text.count).max() ?? 0
        XCTAssertLessThanOrEqual(longest, TimedTextLimits.maximumCueCharacters, "a cue is longer than the limit")
        XCTAssertEqual(document.cutCueCount, 0)
        assertSentencesAreTrusted(document, "sixty long words")
    }
}

// MARK: - Writing Podcasting 2.0 Files

extension XCTestCase {
    /// `object` as JSON bytes, for a Podcasting 2.0 file a test makes
    /// (FMT25). JSONSerialization raises, ending the test host, for an
    /// object it cannot write (one holding NaN, say), so such an object
    /// fails the test instead, and gives no bytes.
    func podcastingJSON(_ object: Any, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            XCTFail("JSON cannot hold \(object)", file: file, line: line)
            return Data()
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}

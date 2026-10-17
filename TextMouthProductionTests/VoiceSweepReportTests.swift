import XCTest

/// The pure half of the voice sweep: the sample, the counts, the Markdown
/// report, and the circuit breaker, tested with synthetic results. No
/// synthesizer is involved, so these run on every Mac.
final class VoiceSweepReportTests: XCTestCase {

    // MARK: - Fixtures

    /// A fixed instant and zone, so that the date line is the same everywhere.
    private let date = Date(timeIntervalSince1970: 1_792_000_000)
    private let utc = TimeZone(identifier: "UTC") ?? .gmt

    /// A result with the fields a test does not care about filled in.
    private func result(
        _ name: String,
        outcome: VoiceSweepOutcome = .ok,
        identifier: String? = nil,
        language: String = "en-US",
        quality: String = "default",
        buffers: Int = 12,
        frames: Int = 44_100,
        sampleRate: Double = 22_050,
        wallSeconds: Double = 1.5,
        note: String = ""
    ) -> VoiceSweepResult {
        VoiceSweepResult(
            identifier: identifier ?? "com.example.voice.\(name)", name: name, language: language,
            quality: quality, outcome: outcome, buffers: buffers, frames: frames,
            sampleRate: sampleRate, wallSeconds: wallSeconds, note: note
        )
    }

    /// The report for `results` in the fixed zone.
    private func report(_ results: [VoiceSweepResult]) -> String {
        VoiceSweepReport.markdown(
            results: results, macOS: "macOS 26.0", date: date, sample: "Sample text.", timeZone: utc
        )
    }

    /// The report's lines between the heading `start` and the next level-2
    /// heading (or the end), for tests of one section.
    private func section(_ heading: String, of markdown: String) -> [String] {
        let lines = markdown.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: heading) else { return [] }
        let rest = lines[(start + 1)...]
        return Array(rest.prefix { !$0.hasPrefix("## ") })
    }

    // MARK: - The sample

    /// The sample holds digits, a bracket pair, and a long sentence, and stays
    /// short enough to render in seconds.
    func testTheSampleHoldsDigitsABracketPairAndALongSentence() {
        let text = VoiceSweepSample.text
        XCTAssertTrue(text.contains(where: \.isNumber), "no digits")
        XCTAssertTrue(text.contains("["), "no opening bracket")
        XCTAssertTrue(text.contains("]"), "no closing bracket")
        XCTAssertGreaterThan(text.split(separator: " ").count, 50, "fewer than 50 words")
        XCTAssertLessThan(text.count, 700)
        XCTAssertGreaterThan(VoiceSweepSample.longSentence.split(separator: " ").count, 50)
        XCTAssertTrue(VoiceSweepSample.longSentence.contains(","), "the long sentence has no commas")
    }

    /// The four parts are all in the text, in order, so that the sample is the
    /// same on every run.
    func testTheSampleIsItsFourPartsInOrder() {
        XCTAssertEqual(
            VoiceSweepSample.text,
            [VoiceSweepSample.numbers, VoiceSweepSample.punctuation, VoiceSweepSample.aside,
             VoiceSweepSample.longSentence].joined(separator: " ")
        )
        XCTAssertTrue(VoiceSweepSample.numbers.contains("3:45"))
        XCTAssertTrue(VoiceSweepSample.punctuation.contains("(quietly)"))
    }

    // MARK: - The result

    /// The duration is the frames over the sample rate, and 0 without a rate.
    func testDurationIsFramesOverSampleRate() {
        XCTAssertEqual(result("A", frames: 44_100, sampleRate: 22_050).durationSeconds, 2, accuracy: 0.0001)
        XCTAssertEqual(result("B", frames: 100, sampleRate: 0).durationSeconds, 0)
        XCTAssertEqual(result("C", frames: 0, sampleRate: 22_050).durationSeconds, 0)
    }

    /// How a render counts, from how it ended and the frames it wrote.
    func testClassifyingHowARenderEnded() {
        XCTAssertEqual(VoiceSweepOutcome.classify(end: .finished, frames: 100), .ok)
        XCTAssertEqual(VoiceSweepOutcome.classify(end: .finished, frames: 0), .noAudio)
        XCTAssertEqual(VoiceSweepOutcome.classify(end: .cancelled, frames: 0), .noAudio, "a refusal")
        XCTAssertEqual(VoiceSweepOutcome.classify(end: .cancelled, frames: 100), .stoppedEarly)
        XCTAssertEqual(VoiceSweepOutcome.classify(end: nil, frames: 0), .timedOut)
        XCTAssertEqual(VoiceSweepOutcome.classify(end: nil, frames: 100), .timedOut, "wrote, but never ended")
    }

    /// A measured result carries the voice, the counts, and a note that says
    /// what went wrong and adds the voice's own word.
    func testAMeasuredResultCarriesTheVoiceAndANote() {
        let voice = VoiceSweepVoice(
            identifier: "id.1", name: "Zarvox", language: "en-US", quality: "default", note: "A novelty voice."
        )
        let timedOut = VoiceSweepResult.measured(
            voice, end: nil, buffers: 3, frames: 900, sampleRate: 22_050, wallSeconds: 20, watchdogSeconds: 20
        )
        XCTAssertEqual(timedOut.outcome, .timedOut)
        XCTAssertEqual(timedOut.identifier, "id.1")
        XCTAssertEqual(timedOut.buffers, 3)
        XCTAssertEqual(
            timedOut.note, "The render did not end within 20 seconds, after 900 frames. A novelty voice."
        )
        let fine = VoiceSweepResult.measured(
            voice, end: .finished, buffers: 3, frames: 900, sampleRate: 22_050, wallSeconds: 2, watchdogSeconds: 20
        )
        XCTAssertEqual(fine.outcome, .ok)
        XCTAssertEqual(fine.note, "A novelty voice.")
        let untried = VoiceSweepResult.notTried(voice)
        XCTAssertEqual(untried.outcome, .notTried)
        XCTAssertEqual(untried.frames, 0)
    }

    // MARK: - The counts line

    /// The counts line has the shape the script reads.
    func testTheCountsLine() {
        let results = [
            result("A"), result("B"), result("C", outcome: .noAudio), result("D", outcome: .timedOut),
            result("E", outcome: .timedOut), result("F", outcome: .notTried),
        ]
        XCTAssertEqual(
            VoiceSweepReport.countsLine(results), "6 voices: 2 ok, 1 no audio, 2 timed out, 1 not tried"
        )
        XCTAssertTrue(report(results).contains("\n6 voices: 2 ok, 1 no audio, 2 timed out, 1 not tried\n"))
    }

    /// A voice that stopped early is counted only when there is one, and one
    /// voice is not "1 voices".
    func testTheCountsLineNamesStoppedEarlyAndOneVoice() {
        XCTAssertEqual(
            VoiceSweepReport.countsLine([result("A", outcome: .stoppedEarly)]),
            "1 voice: 0 ok, 0 no audio, 0 timed out, 0 not tried, 1 stopped early"
        )
    }

    // MARK: - The problems

    /// The problems section lists exactly the voices that were not ok.
    func testProblemsListExactlyTheVoicesThatAreNotOK() {
        let results = [
            result("Fine"), result("Mute", outcome: .noAudio, note: "The engine refused."),
            result("Slow", outcome: .timedOut), result("Fine Too"),
            result("Cut", outcome: .stoppedEarly), result("Skipped", outcome: .notTried),
        ]
        let problems = section("## Problems", of: report(results)).filter { $0.hasPrefix("- ") }
        XCTAssertEqual(problems.count, 4)
        for name in ["Mute", "Slow", "Cut", "Skipped"] {
            XCTAssertEqual(problems.filter { $0.contains("\(name), ") }.count, 1, name)
        }
        XCTAssertFalse(problems.contains { $0.contains("Fine") })
        // A problem line gives the name, language, quality, identifier, outcome, and note.
        XCTAssertTrue(problems.contains {
            $0 == "- Mute, en-US, default, com.example.voice.Mute: no audio. The engine refused."
        }, problems.joined(separator: "\n"))
    }

    /// When every voice is ok, the problems section says so.
    func testProblemsSaysSoWhenThereAreNone() {
        let lines = section("## Problems", of: report([result("A"), result("B")]))
        XCTAssertTrue(lines.contains("No problems: every voice rendered audio."))
        XCTAssertFalse(lines.contains { $0.hasPrefix("- ") })
    }

    /// Voices not tried are explained with the breaker's limit.
    func testNotTriedVoicesAreExplained() {
        let lines = section("## Problems", of: report([result("A", outcome: .notTried)]))
        XCTAssertTrue(lines.contains { $0.contains("3 timeouts in a row") && $0.contains("not tried") })
        let none = section("## Problems", of: report([result("A", outcome: .timedOut)]))
        XCTAssertFalse(none.contains { $0.contains("in a row") })
    }

    // MARK: - The voices

    /// Each voice has a level-3 heading and the bullet lines, in words.
    func testEachVoiceHasAHeadingAndBulletLines() {
        let text = report([result("Samantha", quality: "premium", note: "Heard twice.")])
        XCTAssertTrue(text.hasPrefix("# Voice sweep\n"))
        XCTAssertTrue(text.contains("- Mac: macOS 26.0"))
        XCTAssertTrue(text.contains("- Date: 2026-10-"))
        XCTAssertTrue(text.contains("- Sample: Sample text."))
        let lines = section("## Voices", of: text)
        XCTAssertTrue(lines.contains("### Samantha (en-US)"))
        XCTAssertTrue(lines.contains("- Identifier: com.example.voice.Samantha"))
        XCTAssertTrue(lines.contains("- Quality: premium"))
        XCTAssertTrue(lines.contains("- Outcome: ok"))
        XCTAssertTrue(lines.contains("- Duration: 2.0 seconds"))
        XCTAssertTrue(lines.contains("- Buffers: 12 (44100 frames at 22050 Hz)"))
        XCTAssertTrue(lines.contains("- Time taken: 1.5 seconds"))
        XCTAssertTrue(lines.contains("- Note: Heard twice."))
    }

    /// A voice with no audio has no duration, and the report has no tables.
    func testAVoiceWithoutAudioHasNoDuration() {
        let text = report([result("Mute", outcome: .noAudio, buffers: 0, frames: 0, sampleRate: 0)])
        XCTAssertTrue(text.contains("- Duration: none"))
        XCTAssertTrue(text.contains("- Buffers: 0\n"))
        XCTAssertFalse(text.contains("|"), "a table")
    }

    /// A name with a quote, a slash, or a line break stays on its heading line
    /// and is spoken as it is written.
    func testANameWithAQuoteOrASlashIsKeptAsItIs() {
        let name = "Zarvox \"The Robot\" / Bad News"
        let text = report([result(name, language: "en-US"), result("Two\nLines")])
        XCTAssertTrue(text.contains("### Zarvox \"The Robot\" / Bad News (en-US)\n"))
        XCTAssertTrue(text.contains("### Two Lines (en-US)\n"))
    }

    /// Zero voices produce a report that says so.
    func testTheReportForZeroVoicesSaysSo() {
        let text = report([])
        XCTAssertTrue(text.contains("0 voices: 0 ok, 0 no audio, 0 timed out, 0 not tried"))
        XCTAssertTrue(text.contains("No voices were swept"))
        XCTAssertFalse(text.contains("## Voices"))
    }

    /// The report ends with a newline and holds no emoji.
    func testTheReportEndsWithANewlineAndHasNoEmoji() {
        let text = report([result("A"), result("B", outcome: .timedOut)])
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertFalse(text.unicodeScalars.contains { $0.properties.isEmojiPresentation })
    }

    // MARK: - The breaker

    /// Three timeouts in a row trip the breaker, and not before.
    func testTheBreakerTripsOnThreeTimeoutsInARow() {
        var breaker = VoiceSweepBreaker()
        XCTAssertFalse(breaker.shouldStop)
        breaker.record(.timedOut)
        breaker.record(.timedOut)
        XCTAssertFalse(breaker.shouldStop, "tripped after two")
        breaker.record(.timedOut)
        XCTAssertTrue(breaker.shouldStop)
    }

    /// An answer, good or a refusal, ends a run of timeouts.
    func testTheBreakerResetsOnAnAnswer() {
        for answer in [VoiceSweepOutcome.ok, .noAudio, .stoppedEarly] {
            var breaker = VoiceSweepBreaker()
            breaker.record(.timedOut)
            breaker.record(.timedOut)
            breaker.record(answer)
            XCTAssertEqual(breaker.consecutiveTimeouts, 0, "\(answer)")
            breaker.record(.timedOut)
            breaker.record(.timedOut)
            XCTAssertFalse(breaker.shouldStop, "\(answer): the run did not start again from zero")
        }
    }
}

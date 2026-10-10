import AVFoundation
import XCTest
@testable import TextMouth

/// What TextMouth shows when the Mac's speech engine refuses a passage twice
/// and speech stops there (B05): the speech service's record of its newest
/// transition lines, which the report shows in place of reading the log
/// files.
///
/// Nothing here speaks: the speech service hands its utterances to a
/// recorder in place of the synthesizer, and its text is longer than speech
/// ever renders.
@MainActor
final class SpeechRefusalReportTests: XCTestCase {

    // MARK: - The Newest Transition Lines

    /// The record keeps only the newest lines, oldest first, and lets go of
    /// the oldest one by one as new lines come.
    func testTheRecentLinesKeepOnlyTheNewest() {
        var record = RecentTransitionLines(capacity: 3)
        XCTAssertEqual(record.lines, [])

        for number in 1...5 {
            record.append("LINE_\(number): offset=\(number)", level: .event)
        }

        XCTAssertEqual(record.lines.map(\.message), ["LINE_3: offset=3", "LINE_4: offset=4", "LINE_5: offset=5"])
        XCTAssertEqual(RecentTransitionLines().capacity, 40, "a speech service keeps its last 40 lines")
        XCTAssertEqual(RecentTransitionLines.defaultCapacity, 40)

        var none = RecentTransitionLines(capacity: 0)
        none.append("DIRECT_RETRY_FAILED: offset=0", level: .event)
        XCTAssertEqual(none.lines, [], "a record of no lines keeps none")
    }

    /// A kept line reads as the log file writes it: the time as the log
    /// writer writes it, then a trace line's mark, then the words, so that
    /// it can be searched for in the file.
    func testARecentLineReadsAsTheLogFileWritesIt() {
        let time = Date(timeIntervalSince1970: 1_791_590_400)
        var record = RecentTransitionLines()
        record.append("CHUNK_START: offset=0 len=1000", level: .trace, at: time)
        record.append("DIRECT_RETRY_FAILED: offset=0 chunkStart=0 chunkEnd=1000", level: .event, at: time)

        XCTAssertEqual(record.lines.map(\.logged), [
            "2026-10-10 00:00:00 +0000: TRACE playback: CHUNK_START: offset=0 len=1000",
            "2026-10-10 00:00:00 +0000: DIRECT_RETRY_FAILED: offset=0 chunkStart=0 chunkEnd=1000",
        ])
    }

    /// Speech keeps every line it writes to its transition log, the routine
    /// ones the file gets only while tracing is on included, and the lines
    /// hold offsets and lengths, never the book's words.
    func testSpeechKeepsItsTransitionLinesAndNoWordsOfTheBook() throws {
        try XCTSkipIf(
            DiagnosticLog.TraceSwitch.environmentTurnsTracingOn(ProcessInfo.processInfo.environment),
            "TEXTMOUTH_TRACE_LOG turns tracing on for this whole run"
        )
        setAppTracing(false)
        let speech = makeRecordedSpeech()
        defer { speech.stop() }

        speech.speak(Self.longText)
        speech.stop()

        let messages = speech.recentTransitionLines.lines.map(\.message)
        XCTAssertTrue(messages.contains { $0.hasPrefix("RENDER_SKIP: text too large") }, "\(messages)")
        XCTAssertTrue(messages.contains { $0.hasPrefix("CHUNK_START: offset=0 len=") }, "\(messages)")
        XCTAssertTrue(speech.recentTransitionLines.lines.allSatisfy { $0.level == .trace }, "\(messages)")
        for word in Self.wordsOfTheBook {
            XCTAssertFalse(messages.contains { $0.contains(word) }, "\(word) reached the lines: \(messages)")
        }
    }

    // MARK: - Helpers

    /// The words `longText` is made of, none of which a line may hold.
    private static let wordsOfTheBook = ["Quillwort", "salt", "ferry", "slip"]

    /// A text longer than speech ever renders, so it is spoken in chunks,
    /// directly, and never rendered.
    private static let longText: String = {
        let sentence = "Quillwort edges the salt flats beyond the ferry slip. "
        return String(repeating: sentence, count: SpeechRenderCoordinator.maximumTextLength / sentence.utf16.count + 400)
    }()

    /// A speech service with preferences of its own whose direct utterances
    /// go to a recorder in place of the synthesizer, so nothing is heard.
    private func makeRecordedSpeech() -> SpeechService {
        let speech = SpeechService(userDefaults: makeSandboxedPreferences("speech-refusal-report"))
        speech._directUtteranceRecorderForTesting = { _ in }
        return speech
    }
}

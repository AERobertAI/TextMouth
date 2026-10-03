import XCTest
@testable import TextMouth

/// What diagnostic log lines may say (TODO Q07, `DiagnosticLog`): never the
/// book's text, labels, or rules, only offsets, lengths, names, and
/// package-relative paths. These tests turn tracing on, so the chattiest
/// lines are written too, and read what actually reached the logs.
final class LogContentPolicyTests: XCTestCase {

    // MARK: - Speech

    /// Speech's transition lines describe a chunk by its offsets and
    /// lengths, never by its words. The text is long enough to be spoken in
    /// chunks and too long to render, and speech stops before the main run
    /// loop turns, so nothing is heard.
    func testSpeechTransitionLinesHoldLengthsNotText() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        setAppTracing(true)
        let text = String(repeating: "Quillwort edges the salt flats beyond the ferry slip. ", count: 2_000)
        XCTAssertGreaterThan(text.utf16.count, SpeechRenderCoordinator.maximumTextLength)
        let speech = SpeechService(userDefaults: makeSandboxedPreferences("log-policy.speech"))
        defer { speech.stop() }

        let lines = logLines(in: .speechTransitions) {
            speech.speak(text)
            speech.stop()
        }

        XCTAssertTrue(
            lines.contains { $0.contains("TRACE playback: RENDER_SKIP: text too large (\(text.utf16.count) UTF-16 units") },
            "\(lines)"
        )
        XCTAssertTrue(lines.contains { $0.contains("TRACE playback: CHUNK_START: offset=0 len=") }, "\(lines)")
        for word in ["Quillwort", "flats", "ferry"] {
            XCTAssertFalse(lines.contains { $0.contains(word) }, "\(word) reached the log: \(lines)")
        }
    }

    /// With tracing off, ordinary speech writes nothing to speech's log:
    /// starting a chunk is routine, not an event.
    func testOrdinarySpeechWritesNoTransitionLinesWhileTracingIsOff() throws {
        try XCTSkipIf(
            DiagnosticLog.TraceSwitch.environmentTurnsTracingOn(ProcessInfo.processInfo.environment),
            "TEXTMOUTH_TRACE_LOG turns tracing on for this whole run"
        )
        try TextMouthPaths.ensureDirectoryStructure()
        setAppTracing(false)
        let text = String(repeating: "Tide tables hang in the harbor office. ", count: 300)
        let speech = SpeechService(userDefaults: makeSandboxedPreferences("log-policy.speech-quiet"))
        defer { speech.stop() }

        let lines = logLines(in: .speechTransitions) {
            speech.speak(text)
            speech.stop()
        }

        XCTAssertEqual(lines, [])
    }
}

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

    // MARK: - VoiceOver Focus

    /// A focus diagnostic names a view by its class, role, identifier, and
    /// the length of its label, never the label: a row's label can be one
    /// of the book's headings.
    @MainActor
    func testFocusDescriptionOfAViewGivesItsLabelsLengthNotItsText() {
        let row = NSView()
        row.setAccessibilityRole(.row)
        row.setAccessibilityLabel("Chapter Seven: The Salt Road")
        row.setAccessibilityIdentifier("heading-row")

        XCTAssertEqual(
            VoiceOverFocusDiagnostics.describe(row),
            "NSView role=AXRow labelLength=28 id='heading-row'"
        )
        XCTAssertEqual(VoiceOverFocusDiagnostics.describe(responder: row), VoiceOverFocusDiagnostics.describe(row))
        XCTAssertEqual(VoiceOverFocusDiagnostics.describe(responder: nil), "nil")
    }

    /// An accessibility element that is not a view, such as a search
    /// result's, is described the same way, without its label's text.
    @MainActor
    func testFocusDescriptionOfAnElementGivesItsLabelsLengthNotItsText() {
        let result = NSAccessibilityElement()
        result.setAccessibilityRole(.staticText)
        result.setAccessibilityLabel("the tide turned at noon")
        result.setAccessibilityIdentifier("search-result")

        XCTAssertEqual(
            VoiceOverFocusDiagnostics.describe(result),
            "NSAccessibilityElement role=AXStaticText labelLength=23 id='search-result'"
        )
    }

    /// A focus diagnostic names a window by its number and identifier, never
    /// by its title, which for a reader is the book's title. The window is
    /// never shown.
    @MainActor
    func testFocusDescriptionOfAWindowLeavesOutItsTitle() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.title = "The Salt Road Atlas"
        window.identifier = NSUserInterfaceItemIdentifier("focus-diagnostics-test-window")

        let description = VoiceOverFocusDiagnostics.describe(window: window)

        XCTAssertEqual(description, "window #\(window.windowNumber) id='focus-diagnostics-test-window'")
        XCTAssertFalse(description.contains("Salt Road"), description)
    }

    // MARK: - Media Routing

    /// Media-route bookkeeping, logged for every focus change, command, and
    /// device change, is playback trace in the debug log: absent while
    /// tracing is off, and marked as trace while it is on.
    @MainActor
    func testMediaRouteLinesAreTrace() throws {
        try XCTSkipIf(
            DiagnosticLog.TraceSwitch.environmentTurnsTracingOn(ProcessInfo.processInfo.environment),
            "TEXTMOUTH_TRACE_LOG turns tracing on for this whole run"
        )
        try TextMouthPaths.ensureDirectoryStructure()
        let coordinator = NowPlayingService(installsSystemIntegrations: false)

        setAppTracing(false)
        let quiet = logLines(in: .debug) { setUpMediaSession(on: coordinator) }
        setAppTracing(true)
        let traced = logLines(in: .debug) { setUpMediaSession(on: coordinator) }

        XCTAssertFalse(quiet.contains { $0.contains("MEDIA_ROUTE") }, "\(quiet)")
        XCTAssertTrue(traced.contains { $0.contains(": TRACE playback: MEDIA_ROUTE: setup owner=") }, "\(traced)")
    }

    /// Set up one reader's media session on `coordinator`, with controls that
    /// do nothing and no Bluetooth monitoring.
    @MainActor
    private func setUpMediaSession(on coordinator: NowPlayingService) {
        NowPlayingSession(ownerID: UUID(), coordinator: coordinator).setup(
            onPlay: {},
            onPause: {},
            onAudioRouteInvalidated: {},
            onAudioRouteChangePause: {},
            onTogglePlayPause: {},
            onSkipForward: {},
            onSkipBackward: {},
            isCurrentlyPlaying: { false },
            bluetoothMonitoring: false
        )
    }
}

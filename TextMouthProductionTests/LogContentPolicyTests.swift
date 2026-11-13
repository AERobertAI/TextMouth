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

    // MARK: - Rejected Content Index

    /// A saved content index whose heading label disagrees with the reading
    /// text is set aside with a reason the debug log records as it is
    /// (`CONTENT_INDEX_REJECTED: <title>: <reason>`). The reason is built
    /// outside any log call, where the source scan cannot see it, and a
    /// label is the book's own text, so the reason names the heading by its
    /// place, with where the two labels first differ and how long each is
    /// in UTF-16 units, never by either label.
    func testRejectedIndexReasonGivesHeadingLengthsNotLabels() throws {
        let relabelings: [(indexed: String, reading: String, difference: String)] = [
            // The same length, differing midway.
            ("Quillwort Landing", "Quillwort Harbour", "offset 10 (lengths 17 and 17)"),
            // The index's label is the start of the text's.
            ("Ferry Slip", "Ferry Slip Ledger", "offset 10 (lengths 10 and 17)"),
            // An emoji is two UTF-16 units.
            ("📖 Pilot Notes", "📖 Pilot Charts", "offset 9 (lengths 14 and 15)"),
            // A label where the index has an empty one.
            ("", "Breakwater", "offset 0 (lengths 0 and 10)"),
        ]
        for relabeling in relabelings {
            let indexed = [
                Chapter(title: "Shore", text: "Gulls over the pier.", headings: [Heading(level: 1, text: relabeling.indexed)]),
            ]
            var reading = indexed
            reading[0].headings[0].text = relabeling.reading

            let index = BookContentIndex.build(fromChapters: indexed, format: .epub)
            let reason = try XCTUnwrap(index.alignmentFailure(with: reading), relabeling.reading)

            XCTAssertEqual(
                reason,
                "chapters[0].headings[0].text differs from the reading text's label at UTF-16 \(relabeling.difference)"
            )
            for word in (relabeling.indexed + " " + relabeling.reading).split(separator: " ") {
                XCTAssertFalse(reason.contains(word), "\(word) reached the reason: \(reason)")
            }
        }
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

    // MARK: - The Source

    /// No log call writes book text, a substitution rule's contents, or an
    /// absolute path, and no trace call writes a title: the code in a call's
    /// arguments, its string literals' own words aside, reads none of the
    /// properties that hold them, except for their lengths. Tagged string
    /// literals, the event lines built before they are logged, are held to
    /// the same rules but may name a book's title.
    func testNoLogCallWritesBookTextRulesTitlesOrAbsolutePaths() throws {
        let sources = try AppSourceFile.all()
        let calls = sources.flatMap { LogCallScanner.calls(in: $0.text, file: $0.name) }

        // A scanner that found nothing would pass without checking anything.
        XCTAssertGreaterThan(calls.count, 150, "log calls found")
        for function in LogCallScanner.loggingFunctions {
            XCTAssertTrue(calls.contains { $0.function == function.name }, "no call to \(function.name) found")
        }
        let violations = calls.flatMap(LogCallScanner.violations(in:))
            + sources.flatMap { LogCallScanner.taggedLiteralViolations(in: $0.text, file: $0.name) }
        XCTAssertEqual(violations.map(\.description), [])
    }

    /// The scanner finds what the policy forbids however a call is laid out,
    /// and lets through lengths, titles in events, loggable paths, and words
    /// that are only words in a literal.
    func testScannerFindsWhatThePolicyForbids() {
        let sample = #"""
        func sample() {
            DiagnosticLog.trace(.playback, "chunk \(speakText)")
            DiagnosticLog.trace(.playback, "chunk of \(speakText.utf16Length) units")
            transitionLog(
                .trace,
                "CHUNK_START: \(chapter.text.prefix(20))"
            )
            DiagnosticLog.event(.import, "IMPORT_FAILED: \(book.title): \(reason)")
            voiceOverFocusLog("window \(window.title) is ready")
            DiagnosticLog.trace(.focus, "speakText and chapter.text are only words here")
            DiagnosticLog.event(.storage, "moved to \(DiagnosticLog.loggablePath(book.filePath))")
            DiagnosticLog.event(.storage, "saved at \(url.path)")
            DiagnosticLog.log(.trace, .playback, "rule \(rule.pattern) applied")
            timerLog(.event, "START for \(book.title)")
            let line = "EPUB_BROKEN: \(modifiedText)"
        }
        """#

        let calls = LogCallScanner.calls(in: sample, file: "Sample.swift")
        let found = (calls.flatMap(LogCallScanner.violations(in:))
            + LogCallScanner.taggedLiteralViolations(in: sample, file: "Sample.swift"))
            .sorted { ($0.line, $0.found) < ($1.line, $1.found) }

        XCTAssertEqual(calls.map(\.line), [2, 3, 4, 8, 9, 10, 11, 12, 13, 14])
        XCTAssertEqual(calls.map(\.level), [.trace, .trace, .trace, .event, .trace, .trace, .event, .event, .trace, .event])
        XCTAssertEqual(found.map(\.description), [
            "Sample.swift:2: speakText in DiagnosticLog.trace",
            "Sample.swift:4: .text in transitionLog",
            "Sample.swift:6: .text in a tagged line",
            "Sample.swift:9: .title in voiceOverFocusLog",
            "Sample.swift:12: .path in DiagnosticLog.event",
            "Sample.swift:13: .pattern in DiagnosticLog.log",
            "Sample.swift:15: modifiedText in a tagged line",
        ])
    }

    // MARK: - Tags

    /// The tags that begin the debug log's event lines. Tooling and the TODO
    /// search the logs for them, so each is part of the logs' interface:
    /// rename one only together with everything that reads it.
    private static let eventTags = [
        // The tags TODO Q07 names.
        "AUDIO_SEGMENT_CLAMPED", "BOOK_METADATA_DROPPED", "CONTENT_ANALYSIS_DROPPED",
        "CONTENT_INDEX_REJECTED", "EPUB_INCOMPLETE_CONTENT", "FOLDER_REPAIR", "IMPORT_FAILED",
        "LEGACY_MIGRATION", "READING_STATS_DAY_KEYS", "STORED_VALUE_REPAIRED", "TEXT_ENCODING_FALLBACK",
        // A text file's encoding guessed at its import (FMT16), and a book read again in the encoding the
        // listener chose in Book Information, or automatically (encodingchoice).
        "TEXT_ENCODING_GUESS", "TEXT_ENCODING_CHANGED",
        // A braille book read again with the braille file characters the listener chose in Book
        // Information (braillecodes), and with the braille table (its braille code) the listener chose
        // there.
        "BRAILLE_FILE_CODE_CHANGED", "BRAILLE_TABLE_CHANGED",
        // The data directory: a move and what it waits for (TODO S04); a library found again, lost,
        // or back, a switch to another library, the library's identity and session lease, and the
        // files read once it is back (FR02).
        "DATA_DIRECTORY_AVAILABLE", "DATA_DIRECTORY_FOUND", "DATA_DIRECTORY_LOST", "DATA_DIRECTORY_MOVE",
        "DATA_DIRECTORY_SWITCH", "DATA_DIRECTORY_UNAVAILABLE", "DATA_DIRECTORY_UNMOUNTED",
        "LIBRARY_IDENTITY", "LIBRARY_SESSION", "READING_STATS_FILE", "SUBSTITUTIONS_FILE",
        // Recording from a microphone (FR04): a take starting, stopping, or ending on its own, and
        // a capture that fell back to the microphone's own format; a take saved as a book; and the
        // takes a crash or a forced quit left in the Recordings folder, found at launch.
        "RECORDING_CAPTURE_FAILED", "RECORDING_FORMAT_FALLBACK", "RECORDING_INTERRUPTED", "RECORDING_STARTED",
        "RECORDING_START_FAILED", "RECORDING_STOPPED", "RECORDING_STOP_FAILED",
        "RECORDING_SAVED", "RECORDING_WINDOW_REFUSED", "RECORDING_TAKES_RECOVERED",
        // Audio editing (FR04): an edit history that cannot be used, preserved beside itself; edits
        // saved into a book's audio; the originals of recordings and edited audiobooks the policy
        // removed; the filter presets' file, unusable or only in the cloud; the audio editor
        // window's failures to open, save, or record; and the caches a crash left, removed at launch.
        "AUDIO_EDITS_FILE", "AUDIO_EDITS_SAVED", "AUDIO_ORIGINALS_SWEPT", "AUDIO_ORIGINAL_REMOVAL_FAILED",
        "AUDIO_FILTERS_FILE", "AUDIO_EDITOR", "AUDIO_EDIT_CACHES_SWEPT",
        // Cloud libraries (FR02): a book's download and the removal of its download, the library's
        // Download Now and Remove Download, Keep on This Mac and the downloads of kept books, the
        // reader's downloads and working copies, a maintenance pass leaving books in the cloud,
        // and a record save leaving a record there.
        "BOOK_RECORD_IN_CLOUD",
        "CLOUD_DOWNLOAD_FAILED", "CLOUD_DOWNLOAD_FINISHED", "CLOUD_DOWNLOAD_REMOVAL_FAILED",
        "CLOUD_DOWNLOAD_REMOVED", "CLOUD_DOWNLOAD_STARTED", "CLOUD_DOWNLOAD_STOPPED",
        "DOWNLOAD_NOW_FAILED", "DOWNLOAD_NOW_FINISHED", "DOWNLOAD_NOW_STARTED",
        "KEEP_ON_MAC", "KEPT_BOOK_DOWNLOAD_FAILED", "KEPT_BOOK_DOWNLOAD_FINISHED", "KEPT_BOOK_DOWNLOAD_STARTED",
        "REMOVE_DOWNLOAD_FINISHED", "REMOVE_DOWNLOAD_REFUSED", "REMOVE_DOWNLOAD_STARTED",
        "READER_DOWNLOAD_CANCELLED", "READER_DOWNLOAD_FAILED", "READER_DOWNLOAD_FINISHED",
        "READER_DOWNLOAD_STARTED", "READER_READ_REFUSED",
        "WORKING_COPIES_SWEPT", "WORKING_COPY_LEFT", "WORKING_COPY_MADE", "WORKING_COPY_REMOVED",
        "WORKING_COPY_SKIPPED", "MAINTENANCE_SKIPPED_IN_CLOUD",
        // Podcast and article feeds (FR03): their records and this Mac's fetch details; subscribing,
        // refreshing, and moved or repaired feeds; downloads; and played items and the deletion of
        // their downloads.
        "FEED_RECORD_IN_CLOUD", "FEED_RECORD_SAVE_FAILED", "FEED_RECORD_UNREADABLE", "FEED_FETCH_STATE_SAVE_FAILED",
        "FEED_SUBSCRIBED", "FEED_UNSUBSCRIBED", "FEED_REFRESHED", "FEED_REFRESH_FAILED", "FEED_MOVED",
        "FEED_PARSE_REPAIRED",
        "FEED_DOWNLOAD_STARTED", "FEED_DOWNLOAD_FINISHED", "FEED_DOWNLOAD_FAILED", "FEED_DOWNLOAD_CANCELLED",
        "FEED_ITEM_PLAYED", "FEED_DOWNLOAD_DELETED", "FEED_DOWNLOAD_DELETE_FAILED", "FEED_SWEEP_LEFT_IN_CLOUD",
        // The listener's own deletion of a download in use, refused (feed follow-ups item 1).
        "FEED_DOWNLOAD_DELETE_REFUSED",
        // A rule's deletions waiting while a data-directory move holds storage work.
        "FEED_DOWNLOAD_DELETE_WAITING",
        // Feed items in their feeds' own folders (FR11): each feed's index and the first launch's
        // move into it; a download kept, restored, set aside, or held aside, and an article's
        // earlier text kept; the rules' downloads, waits, and removals; Cancel; the feed's
        // choice moved; Move to Library…; Unsubscribe and Resubscribe; and the return of a
        // gone feed's downloads.
        "FEED_INDEX", "FEED_INDEX_IN_CLOUD", "FEED_INDEX_NEWER", "FEED_INDEX_UNREADABLE",
        "FEED_DOWNLOADS_MOVE", "FEED_DOWNLOADS_MOVED", "FEED_DOWNLOAD_MOVE_FAILED", "FEED_DOWNLOAD_MOVE_REFUSED",
        "FEED_ITEMS_KEPT", "FEED_ITEMS_DOWNLOADED_AGAIN",
        "FEED_DOWNLOAD_CACHE_LEFT", "FEED_DOWNLOAD_DISCARDED", "FEED_DOWNLOAD_FORGOTTEN", "FEED_DOWNLOAD_LEFT",
        "FEED_DOWNLOAD_RESTORED", "FEED_DOWNLOAD_HELD_ASIDE", "FEED_ARTICLE_TEXT_KEPT",
        // What a Delete Download cut short held aside, swept at the next launch, or left for the one after.
        "FEED_HELD_ASIDE_SWEPT", "FEED_HELD_ASIDE_LEFT",
        "FEED_PACKAGE_PUT_BACK", "FEED_PACKAGE_SET_ASIDE_LEFT", "FEED_PACKAGE_SET_ASIDE_REMOVED", "FEED_PACKAGE_SWAP_FAILED",
        "FEED_KEPT_PACKAGE_DELETE_FAILED", "FEED_KEPT_PACKAGES_PUT_OFF",
        "FEED_RULE_DOWNLOADS", "FEED_RULE_LEFT_IN_CLOUD", "FEED_RULE_PUT_OFF", "FEED_SWEEP_PUT_OFF",
        "FEED_DOWNLOAD_WAITING", "FEED_DOWNLOADS_CANCELLED", "FEED_ITEM_POLICY_MOVED",
        "FEED_ITEM_MOVED_TO_LIBRARY", "FEED_MOVE_TO_LIBRARY_FAILED", "FEED_MOVE_TO_LIBRARY_PUT_OFF", "FEED_LIBRARY_BOOK_GONE",
        "FEED_RESUBSCRIBED", "FEED_RECORD_ABSENT", "FEED_RECORD_BACK",
        "FEED_DOWNLOADS_RETURN", "FEED_DOWNLOADS_RETURNED", "FEED_DOWNLOAD_RETURN_FAILED",
        // Delete Feed… (FR14): a feed deleted; one that stays, its index unwritten, so nothing went,
        // a file it could not delete, or a download in use; and a folder left behind: the feed's own in the data
        // directory, or its emptied library folder.
        "FEED_DELETED", "FEED_DELETE_PUT_OFF", "FEED_DELETE_STOPPED", "FEED_DELETE_REFUSED",
        "FEED_DELETE_FOLDER_LEFT", "FEED_DELETE_FOLDER_KEPT",
        // The logs themselves (the user's decision of October 3): lines changing place between the
        // data directory's Logs folder and this Mac's, and a log started over because it could not
        // be renamed to its older generation.
        "LOG_LOCATION", "LOG_ROTATION",
        // Export and Edit Text (FR05): how an export ended and each file it could not write; an edit
        // made in the user's own editor taken as the book's text, refused, left because the book's own
        // file changed too, or not committed; a rebuild of the text refused over an edit not taken,
        // and the user's text kept aside before a rebuild replaced it.
        "BOOK_EXPORT", "BOOK_EXPORT_FAILED",
        "TEXT_EDIT_ADOPTED", "TEXT_EDIT_FAILED", "TEXT_EDIT_REFUSED", "TEXT_EDIT_SOURCE_CHANGED",
        "TEXT_EDIT_HELD", "TEXT_EDIT_KEPT",
        // A text book spoken into one audio file (FMT43): how the export ended, with its chapters and seconds.
        "SPEECH_EXPORT",
        // The Move to Folder… and Move to Library… sheet appearing, with the places and items it lists.
        "MOVE_SHEET_SHOWN",
        // A reader's load that could not read its book's files because the library moved them
        // (TODO P10), loading the book again from where it is.
        "READER_LOAD_AFTER_MOVE",
        // Every other tag the debug log's events begin with.
        "ARCHIVE_EXTRACTION_LEFT", "ARCHIVE_EXTRACTION_REMOVED",
        "AUDIO_PLAYBACK_FAILED", "BOOK_FINISHED", "BUILD_IDENTITY", "CACHE_STALE", "CONFIG_FILE", "DAISY_INCOMPLETE_CONTENT",
        "DAISY_PACKAGE_MISSING", "DAISY_PACKAGE_WHOLE_FOLDER", "DOCX_DAMAGED_METADATA",
        "DOCX_INCOMPLETE_CONTENT", "EPUB_METADATA_WRITE_FAILED", "FINISHED_BOOKS_AT_END", "IMPORT_CANCELLED", "IMPORT_STAGING_LEFT",
        "IMPORT_STAGING_REMOVED", "LIBRARY_INDEX", "LIBRARY_REMOVAL", "MIGRATION_STAGING_LEFT",
        "MIGRATION_STAGING_REMOVED", "ORIGINAL_KEPT", "PERSISTENCE_FAILURE",
        "PERSISTENCE_RECOVERED", "PERSISTENCE_WITHDRAWN", "PLAYBACK_RESUME_REJECTED", "SPEECH_PLAYER_EXCEPTION",
        "AUDIO_ENGINE_START_FAILED",
        "READING_TEXT_CACHE_REJECTED", "READING_TEXT_CACHE_SWEPT", "TMB_ID_LISTED", "TMB_RECONCILE", "TRACE_SUPPRESSED",
        // Transcripts of audiobooks (FR05): a transcript.json that cannot be used, preserved beside itself;
        // a transcript whose audio changed since; and a transcript text written again from its transcript.
        "TRANSCRIPT_FILE", "TRANSCRIPT_STALE", "TRANSCRIPT_TEXT_REBUILT",
        // The experimental transcript cleanup (FR05): the user's copy of its rules, unusable or only in the
        // cloud; a cleanup saved; and a cleanup undone.
        "TRANSCRIPT_CLEANUP_RULES", "TRANSCRIPT_CLEANED_UP", "TRANSCRIPT_CLEANUP_UNDONE",
        // Transcriptions (FR05): one starting, and one finishing with its words and seconds, cancelled, or
        // failed with why.
        "TRANSCRIPTION_STARTED", "TRANSCRIPTION_FINISHED", "TRANSCRIPTION_CANCELLED", "TRANSCRIPTION_FAILED",
        // Braille (October 20, 2026): one of this Mac's tables refused by its check, and why.
        "BRAILLE_MAC_TABLE_REFUSED",
        // Library index (V03): rows of library.json a newer TextMouth wrote, kept as they are, counted.
        "LIBRARY_ROWS_KEPT",
        // Replace Existing (ST04): a duplicate's new copy taking the old copy's place under its ID, and what an
        // undone replacement could not put back in the new copy's package.
        "DUPLICATE_REPLACED", "DUPLICATE_REPLACE_UNDONE",
        // A duplicate's new copy whose question was never answered (TODO 3780): discarded by the launch's repair,
        // or not discarded, or not marked as waiting, and why.
        "DUPLICATE_UNANSWERED",
        // Keep Both refused because the mark that a new copy awaits its answer could not be taken off it; the
        // system's reason goes here, not into the sentence the listener hears.
        "DUPLICATE_KEEP_FAILED",
        // A package left unadopted because its record names a book the library lists in another package.
        "ORPHAN_ID_LISTED",
    ]

    /// Each tag still begins a string literal in the app's code, so none was
    /// renamed. EPUB's incomplete-content tag is built from the book's
    /// format, so its parts are checked instead.
    func testEventTagsAreUnchangedInTheSource() throws {
        let code = try AppSourceFile.all()
            .map { LogCallScanner.withoutCommentLines($0.text) }
            .joined(separator: "\n")

        for tag in Self.eventTags where tag != "EPUB_INCOMPLETE_CONTENT" {
            let spelled = ["\"\(tag):", "\"\(tag) ", "\"\(tag)\""].contains { code.contains($0) }
            XCTAssertTrue(spelled, "\(tag) no longer begins a string literal in the app's code")
        }
        XCTAssertEqual("\(BookFormat.epub.rawValue.uppercased())_INCOMPLETE_CONTENT", "EPUB_INCOMPLETE_CONTENT")
        XCTAssertTrue(code.contains("_INCOMPLETE_CONTENT\""))
    }

    /// An event line is written with nothing before its tag but the
    /// timestamp, so a search for a tag at the start of a line finds it.
    func testEventLinesBeginWithTheirTag() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let marker = UUID().uuidString

        for tag in Self.eventTags {
            DiagnosticLog.event(.storage, "\(tag): tag check \(marker)")
        }

        let lines = debugLogLines(containing: marker)
        XCTAssertEqual(lines.count, Self.eventTags.count)
        for tag in Self.eventTags {
            XCTAssertTrue(
                lines.contains {
                    $0.hasSuffix(": \(tag): tag check \(marker)") && $0.components(separatedBy: ": ").count == 3
                },
                tag
            )
        }
    }

    // MARK: - The Writer

    /// Every line goes through `DiagnosticLog`, the one place that applies
    /// the policy: no other file calls the writer beneath it. And only
    /// TextMouthPaths, where the logs' folder is resolved, hands lines to
    /// the log writer itself.
    func testOnlyThePolicyCallsTheWriter() throws {
        let sources = try AppSourceFile.all()
        let callers = { (function: String) in
            sources.filter { source in
                LogCallScanner.calls(in: source.text, file: source.name).contains { $0.function == function }
            }.map(\.name)
        }
        let writingDirectly = callers("TextMouthPaths.appendLog")

        XCTAssertEqual(callers("LogWriter.shared.append"), ["TextMouthPaths.swift"], "a line went around TextMouthPaths")
        XCTAssertTrue(writingDirectly.contains("DiagnosticLog.swift"), "the policy writes through the writer")
        for file in writingDirectly where file != "DiagnosticLog.swift" {
            XCTFail(
                "\(file) calls TextMouthPaths.appendLog directly, around the log policy. Replace "
                    + "`TextMouthPaths.appendLog(to: TextMouthPaths.debugLogFile, message: line)` with "
                    + "`DiagnosticLog.event(.import, line)` for a one-off tagged line, or "
                    + "`DiagnosticLog.trace(.playback, line)` for routine chatter, in the category that fits."
            )
        }
    }
}

// MARK: - The Log Call Scanner

/// Finds the app's log calls in Swift source, and what in them breaks
/// `DiagnosticLog`'s content policy. A lexer, not a parser: it knows string
/// literals, their interpolations, and parentheses, which is all a log
/// call's arguments need. Lines that are only comments are skipped.
private enum LogCallScanner {

    /// A function that writes log lines, and the level of its lines.
    struct LoggingFunction {
        /// The name a call spells, qualified as callers write it.
        let name: String
        /// The level of its lines, or nil when its first argument names it.
        let level: DiagnosticLog.Level?
        /// The one file to look in, for a name too common to look for
        /// everywhere.
        var file: String?
    }

    /// Every function that writes a log line.
    static let loggingFunctions = [
        LoggingFunction(name: "DiagnosticLog.event", level: .event),
        LoggingFunction(name: "DiagnosticLog.trace", level: .trace),
        LoggingFunction(name: "DiagnosticLog.log", level: nil),
        LoggingFunction(name: "SleepTimerService.log", level: nil),
        LoggingFunction(name: "timerLog", level: nil),
        LoggingFunction(name: "transitionLog", level: nil),
        LoggingFunction(name: "routingLog", level: nil),
        LoggingFunction(name: "voiceOverFocusLog", level: .trace),
        LoggingFunction(name: "diagnostic", level: .trace, file: "NowPlayingService.swift"),
        // The writer itself, which only the policy calls; a call anywhere
        // else is found, and `testOnlyThePolicyCallsTheWriter` fails it.
        LoggingFunction(name: "TextMouthPaths.appendLog", level: .event),
        // The log writer beneath it, which only TextMouthPaths calls.
        LoggingFunction(name: "LogWriter.shared.append", level: .event),
    ]

    /// One log call.
    struct Call {
        /// The file it is in.
        let file: String
        /// The line its name is on.
        let line: Int
        /// The function it calls.
        let function: String
        /// The level of the line it writes.
        let level: DiagnosticLog.Level
        /// The code of its arguments: string literals' own words left out,
        /// their interpolations kept.
        let code: String
    }

    /// Something a line must not hold, and where it was found.
    struct Violation: CustomStringConvertible {
        let file: String
        let line: Int
        let found: String
        var description: String { "\(file):\(line): \(found)" }
    }

    // MARK: Rules

    /// Properties that hold book text, the contents of a substitution rule,
    /// or an accessibility label, which can hold either.
    static let bookTextPattern =
        #"\b(chapterText|speakText|modifiedText|currentText|speechString|excerpt|accessibilityLabel)\b|\.(text|pattern|replacement)\b"#

    /// Properties that hold an absolute path.
    static let absolutePathPattern = #"\.(path|filePath|absoluteString)\b"#

    /// Properties that hold a title, which only events may write.
    static let titlePattern = #"\.title\b|\b[a-z][A-Za-z0-9]*Title\b"#

    /// What may follow such a property to log only its length.
    static let lengthPattern = #"^(\.utf16Length|\.utf16\.count|\.count|\.isEmpty|\.length)\b"#

    /// The start of a string literal that begins with a tag: an event line.
    static let taggedLiteralPattern = #""[A-Z][A-Z0-9]*(_[A-Z0-9]+)+[: ]"#

    // MARK: Checking

    /// What `call` must not write: book text and rules anywhere, absolute
    /// paths outside `DiagnosticLog.loggablePath`, and titles in trace lines.
    static func violations(in call: Call) -> [Violation] {
        var found = matches(of: bookTextPattern, in: call.code)
            + matches(of: absolutePathPattern, in: withoutLoggablePaths(call.code))
        if call.level == .trace {
            found += matches(of: titlePattern, in: call.code)
        }
        return found.map { Violation(file: call.file, line: call.line, found: "\($0) in \(call.function)") }
    }

    /// What the tagged string literals in `source`, the text of the file
    /// named `file`, must not hold: book text, rules, or absolute paths.
    /// Titles are allowed, since a tagged line is an event.
    static func taggedLiteralViolations(in source: String, file: String) -> [Violation] {
        var violations: [Violation] = []
        let lines = withoutCommentLines(source).components(separatedBy: "\n")
        for (offset, line) in lines.enumerated() {
            let text = line as NSString
            for match in regex(taggedLiteralPattern).matches(in: line, range: NSRange(location: 0, length: text.length)) {
                let code = interpolationCode(ofLiteralStartingWith: Array(text.substring(from: match.range.location)))
                let found = matches(of: bookTextPattern, in: code)
                    + matches(of: absolutePathPattern, in: withoutLoggablePaths(code))
                violations += found.map { Violation(file: file, line: offset + 1, found: "\($0) in a tagged line") }
            }
        }
        return violations
    }

    /// The text of each match of `pattern` in `code` that is not followed
    /// by a length, such as `.utf16Length`.
    private static func matches(of pattern: String, in code: String) -> [String] {
        let text = code as NSString
        let length = regex(lengthPattern)
        return regex(pattern).matches(in: code, range: NSRange(location: 0, length: text.length)).compactMap { match in
            let rest = text.substring(from: match.range.location + match.range.length)
            let isLength = length.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) != nil
            return isLength ? nil : text.substring(with: match.range)
        }
    }

    /// `code` without the `loggablePath(…)` calls in it, whose paths reach
    /// the line in the form the policy allows.
    private static func withoutLoggablePaths(_ code: String) -> String {
        var characters = Array(code)
        let name = Array("loggablePath(")
        while let start = firstIndex(of: name, in: characters, from: 0) {
            // From its opening parenthesis to the one that closes it.
            var end = start + name.count - 1
            var depth = 0
            repeat {
                if characters[end] == "(" { depth += 1 } else if characters[end] == ")" { depth -= 1 }
                end += 1
            } while depth > 0 && end < characters.count
            characters.removeSubrange(start..<end)
        }
        return String(characters)
    }

    /// A compiled pattern. The patterns are constants, so a failure is a
    /// mistake in this file.
    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    // MARK: Finding Calls

    /// The log calls in `source`, the text of the file named `file`, in
    /// the order of their lines.
    static func calls(in source: String, file: String) -> [Call] {
        let characters = Array(withoutCommentLines(source))
        var calls: [Call] = []
        for function in loggingFunctions where function.file == nil || function.file == file {
            let name = Array(function.name + "(")
            var index = 0
            while let start = firstIndex(of: name, in: characters, from: index) {
                index = start + name.count
                guard isCall(characters, at: start),
                      let code = argumentCode(in: characters, from: index) else { continue }
                calls.append(Call(
                    file: file,
                    line: lineNumber(of: start, in: characters),
                    function: function.name,
                    level: function.level ?? level(namedFirstIn: code),
                    code: code
                ))
            }
        }
        return calls.sorted { $0.line < $1.line }
    }

    /// `source` with each line that is only a comment emptied, so line
    /// numbers stay as they are.
    static func withoutCommentLines(_ source: String) -> String {
        source.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : $0 }
            .joined(separator: "\n")
    }

    /// Where `pattern` first occurs in `characters` at or after `start`.
    private static func firstIndex(of pattern: [Character], in characters: [Character], from start: Int) -> Int? {
        var index = start
        while index + pattern.count <= characters.count {
            if characters[index] == pattern[0],
               zip(characters[index..<index + pattern.count], pattern).allSatisfy({ $0 == $1 }) {
                return index
            }
            index += 1
        }
        return nil
    }

    /// Whether the name at `start` is called there, rather than ending a
    /// longer name or being declared.
    private static func isCall(_ characters: [Character], at start: Int) -> Bool {
        if start > 0 {
            let previous = characters[start - 1]
            if previous.isLetter || previous.isNumber || previous == "_" { return false }
        }
        let before = String(characters[max(0, start - 16)..<start])
        return !before.trimmingCharacters(in: .whitespaces).hasSuffix("func")
    }

    /// The code of a call's arguments, from `start`, just after its opening
    /// parenthesis, to the parenthesis that closes it: string literals' own
    /// words left out, their interpolations kept. Nil when it never closes.
    private static func argumentCode(in characters: [Character], from start: Int) -> String? {
        var code = ""
        var depth = 1
        var inLiteral = false
        // The depth at which each open interpolation began.
        var interpolationDepths: [Int] = []
        var index = start
        while index < characters.count, index - start < 10_000 {
            let character = characters[index]
            if inLiteral {
                if character == "\\", index + 1 < characters.count {
                    if characters[index + 1] == "(" {
                        // An interpolation: code again until it closes.
                        interpolationDepths.append(depth)
                        depth += 1
                        inLiteral = false
                        code.append(" ")
                    }
                    index += 2
                    continue
                }
                if character == "\"" { inLiteral = false }
                index += 1
                continue
            }
            switch character {
            case "\"":
                inLiteral = true
            case "(":
                depth += 1
                code.append(character)
            case ")":
                depth -= 1
                if depth == 0 { return code }
                if interpolationDepths.last == depth {
                    // The interpolation closed: back inside its literal.
                    interpolationDepths.removeLast()
                    inLiteral = true
                    code.append(" ")
                } else {
                    code.append(character)
                }
            default:
                code.append(character)
            }
            index += 1
        }
        return nil
    }

    /// The code of the interpolations in the one-line string literal that
    /// `literal` starts with, its opening quote first.
    private static func interpolationCode(ofLiteralStartingWith literal: [Character]) -> String {
        var code = ""
        var index = 1
        while index < literal.count, literal[index] != "\"" {
            guard literal[index] == "\\", index + 1 < literal.count else {
                index += 1
                continue
            }
            guard literal[index + 1] == "(" else {
                // An escaped character, such as a quote.
                index += 2
                continue
            }
            var depth = 1
            index += 2
            while index < literal.count, depth > 0 {
                if literal[index] == "(" { depth += 1 } else if literal[index] == ")" { depth -= 1 }
                if depth > 0 { code.append(literal[index]) }
                index += 1
            }
            code.append(" ")
        }
        return code
    }

    /// The level the code of a call's arguments names first: an event only
    /// when it says so, so a level held in a variable counts as trace, the
    /// stricter.
    private static func level(namedFirstIn code: String) -> DiagnosticLog.Level {
        code.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(".event") ? .event : .trace
    }

    /// The line, counting from 1, that `index` falls on.
    private static func lineNumber(of index: Int, in characters: [Character]) -> Int {
        characters[..<index].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }
}

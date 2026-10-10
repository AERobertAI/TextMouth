import AVFoundation
import XCTest
@testable import TextMouth

/// What TextMouth shows when the Mac's speech engine refuses a passage twice
/// and speech stops there (B05): the speech service's record of its newest
/// transition lines, which the report shows in place of reading the log
/// files; the passages around the refusal; and the report's words, line by
/// line, pinned without a window.
///
/// Only a text book is spoken by the speech engine: an audiobook plays its
/// audio files, and its transcript is shown, never spoken, so no refusal
/// can stop it. Nothing here speaks: the speech service hands its utterances
/// to a recorder in place of the synthesizer, and its text is longer than
/// speech ever renders.
@MainActor
final class SpeechRefusalReportTests: XCTestCase {

    // MARK: - Passages

    /// In the middle of a long chapter, a passage holds a hundred units
    /// before where speech stopped and four hundred from there on, says in
    /// words where the refused text begins, and that it goes on past the
    /// passage, and to where.
    func testAPassageHoldsAFewHundredUnitsAroundTheStop() {
        let text = String(repeating: "abcdefghij", count: 100)

        let passage = SpeechRefusalPassage(of: text, around: 250, refused: 250..<900)

        XCTAssertEqual(passage.range, 150..<650)
        XCTAssertEqual(passage.refusedRange, 250..<900)
        XCTAssertEqual(passage.before, String(repeating: "abcdefghij", count: 10))
        XCTAssertEqual(passage.refused, String(repeating: "abcdefghij", count: 40))
        XCTAssertEqual(passage.after, "")
        XCTAssertEqual(SpeechRefusalWording.passageLines(passage), [
            String(repeating: "abcdefghij", count: 10),
            "The refused text begins here, at character 250.",
            String(repeating: "abcdefghij", count: 40),
            "The refused text goes on past this passage, to character 900.",
        ])
    }

    /// At a chapter's start, nothing comes before the refused text, and a
    /// refused text that ends inside the passage is followed by the rest.
    func testAPassageAtAChaptersStart() {
        let text = "The tide turned at dawn."

        let passage = SpeechRefusalPassage(of: text, around: 0, refused: 0..<9)

        XCTAssertEqual(passage.range, 0..<24)
        XCTAssertEqual(SpeechRefusalWording.passageLines(passage), [
            "The refused text begins here, at character 0.",
            "The tide ",
            "The refused text ends here, at character 9.",
            "turned at dawn.",
        ])
    }

    /// At a chapter's end, the passage holds the hundred units before it and
    /// nothing after, with no slice past the end.
    func testAPassageAtAChaptersEnd() {
        let text = String(repeating: "abcdefghij", count: 20)

        let passage = SpeechRefusalPassage(of: text, around: 200, refused: 200..<200)

        XCTAssertEqual(passage.range, 100..<200)
        XCTAssertEqual(SpeechRefusalWording.passageLines(passage), [
            String(repeating: "abcdefghij", count: 10),
            "The refused text begins here, at character 200.",
            "The refused text ends here, at character 200.",
        ])
    }

    /// Offsets that do not fit the text at all, past its end, before its
    /// start, or in an empty text, are kept inside it, so a passage is
    /// always a slice of its text and nothing traps.
    func testAPassageKeepsEveryOffsetInsideItsText() {
        let text = String(repeating: "abcdefghij", count: 20)

        let past = SpeechRefusalPassage(of: text, around: 5_000, refused: 4_000..<6_000)
        XCTAssertEqual(past.range, 100..<200)
        XCTAssertEqual(past.refusedRange, 200..<200)
        XCTAssertEqual(past.before, String(repeating: "abcdefghij", count: 10))

        let before = SpeechRefusalPassage(of: text, around: -50, refused: -100 ..< -10)
        XCTAssertEqual(before.range, 0..<200)
        XCTAssertEqual(before.refusedRange, 0..<0)
        XCTAssertEqual(SpeechRefusalWording.passageLines(before), [
            "The refused text begins here, at character 0.",
            "The refused text ends here, at character 0.",
            text,
        ])

        let empty = SpeechRefusalPassage(of: "", around: 3, refused: 1..<7)
        XCTAssertEqual(empty.range, 0..<0)
        XCTAssertEqual(SpeechRefusalWording.passageLines(empty), [
            "The refused text begins here, at character 0.",
            "The refused text ends here, at character 0.",
        ])

        // A stop outside the refused text counts as its nearer end.
        let outside = SpeechRefusalPassage(of: text, around: 10, refused: 50..<60, unitsBefore: 5, unitsAfter: 20)
        XCTAssertEqual(outside.range, 45..<70)
        XCTAssertEqual(outside.refusedRange, 50..<60)
    }

    /// A passage never splits a character: an offset inside an emoji's two
    /// UTF-16 units, or between a letter and its combining accent, moves back
    /// to the start of the character, at every edge.
    func testAPassageNeverSplitsACharacter() {
        let emoji = SpeechRefusalPassage(of: "ab\u{1F642}cd", around: 3, refused: 3..<5, unitsBefore: 1, unitsAfter: 1)
        XCTAssertEqual(emoji.range, 2..<4)
        XCTAssertEqual(emoji.refusedRange, 2..<5)
        XCTAssertEqual(SpeechRefusalWording.passageLines(emoji), [
            "The refused text begins here, at character 2.",
            "\u{1F642}",
            "The refused text goes on past this passage, to character 5.",
        ])

        let accent = SpeechRefusalPassage(of: "xe\u{0301}y", around: 2, refused: 2..<3, unitsBefore: 0, unitsAfter: 1)
        XCTAssertEqual(accent.range, 1..<3)
        XCTAssertEqual(SpeechRefusalWording.passageLines(accent), [
            "The refused text begins here, at character 1.",
            "e\u{0301}",
            "The refused text ends here, at character 3.",
        ])
    }

    /// The refused utterance's own text begins where the refused text
    /// begins in the spoken text, and its passage counts from there.
    func testAPassageOfTheRefusedTextCountsFromItsStart() {
        let handed = "\u{2039}sm\u{203A}Gulls"

        let passage = SpeechRefusalPassage(of: handed, startingAt: 23, around: 23, refused: 23..<32)

        XCTAssertEqual(passage.range, 23..<32)
        XCTAssertEqual(SpeechRefusalWording.passageLines(passage), [
            "The refused text begins here, at character 23.",
            handed,
            "The refused text ends here, at character 32.",
        ])
    }

    // MARK: - The Report's Words

    /// The words the sheet and VoiceOver use, each pinned once.
    func testTheReportsFixedWords() {
        XCTAssertEqual(SpeechRefusalWording.heading, "Speech Stopped")
        XCTAssertEqual(
            SpeechRefusalWording.summary,
            "The Mac's speech engine refused to speak the text here, twice, so speech stopped. Play tries again from the same place."
        )
        XCTAssertEqual(
            SpeechRefusalWording.announcement,
            "Speech stopped: the speech engine refused this passage. Details are in the book's window."
        )
        XCTAssertEqual(SpeechRefusalWording.detailsLabel, "Details")
        XCTAssertEqual(SpeechRefusalWording.copyTitle, "Copy Details")
        XCTAssertEqual(SpeechRefusalWording.copyHint, "Copies the whole report as plain text, to paste where it helps find the cause")
        XCTAssertEqual(SpeechRefusalWording.copiedAnnouncement, "Details copied")
        XCTAssertEqual(SpeechRefusalWording.closeTitle, "Close")
        XCTAssertEqual(SpeechRefusalWording.closeHint, "Closes the report; Play tries the passage again")
    }

    /// A text book's report, line by line: the chapter's spoken text leaves
    /// out its heading line, nine units, so the book's offsets run nine
    /// ahead of the spoken text's, and the refused text was handed to the
    /// engine with every bracket silent.
    func testTheReportOfATextBookLineByLine() {
        let report = Self.sampleReport()

        XCTAssertEqual(report.lines, [
            "Speech Stopped",
            "The Mac's speech engine refused to speak the text here, twice, so speech stopped. Play tries again from the same place.",
            "",
            "Where",
            "Book: Quay Ledger (Plain Text)",
            "Position: Tides. Heading 2 of 2. 42 percent. 3 hours remaining.",
            "Chapter 1 of 1 (chapter=0 in the logs): Harbour Ledger",
            "Speech stopped at character 38 of 75 in the chapter.",
            "In the spoken text, whose offsets the speech log gives: speech stopped at character 29; the refused text runs from character 29 to 66.",
            "Refused here: 1 time while this window has been open.",
            "Time: 2026-10-10 00:00:00 +0000",
            "",
            "The passage as the book has it, characters 0 to 75 of chapter 1:",
            "Moorings\nThe harbour bell rang twice. ",
            "The refused text begins here, at character 38.",
            "<sm>Gulls</sm> wheeled over the quay.",
            "The refused text ends here, at character 75.",
            "",
            "The text handed to the speech engine, after the substitutions and the markup guard, characters 29 to 66 of the spoken text:",
            "The refused text begins here, at character 29.",
            "\u{2039}sm\u{203A}Gulls\u{2039}/sm\u{203A} wheeled over the quay.",
            "The refused text ends here, at character 66.",
            "Markup guard: strict, every angle bracket silent, from character 29 to 66 of the spoken text.",
            "",
            "Voice and speed",
            "Voice: Samantha (com.apple.voice.compact.en-US.Samantha), en-US, Standard quality",
            "Speed: 200 words per minute; rate 0.43, pitch 1.00, volume 1.00",
            "",
            "This Mac",
            "macOS: Version 26.3.1 (Build 25D2128)",
            "TextMouth: version 0.1.2, build 7, Debug, commit abc1234, built 2026-10-09T17:00:00Z",
            "",
            "Speech log, its last 2 lines, offsets and lengths only:",
            "2026-10-10 00:00:00 +0000: TRACE playback: CHUNK_START: offset=29 len=37 end=66 totalText=66",
            "2026-10-10 00:00:00 +0000: DIRECT_RETRY_FAILED: offset=29 chunkStart=29 chunkEnd=66; speech stopped, the listener told",
        ])
        XCTAssertEqual(report.text, report.lines.joined(separator: "\n"))
        XCTAssertEqual(report.place, SpeechRefusalPlace(chapterIndex: 0, characterOffset: 38))
    }

    /// What a report says when it knows less: the system's default voice, a
    /// build that recorded no details, a chapter without a title or
    /// position, the usual markup guard, no log lines, and a place refused
    /// more than once.
    func testTheReportWhenLittleIsKnown() {
        let refusal = SpeechRefusal(
            offset: 0,
            refusedRange: 0..<4,
            refusedText: "Tide",
            strictlyGuardedRange: nil,
            voice: nil,
            wordsPerMinute: 349.6,
            rate: 0.6,
            pitchMultiplier: 1.5,
            volume: 0.25,
            recentLines: []
        )
        let report = SpeechRefusalReport(
            bookTitle: "Quay Ledger",
            bookFormat: "EPUB",
            position: "",
            chapterIndex: 2,
            chapterCount: 5,
            chapterTitle: nil,
            chapterText: "Tide",
            toChapterOffset: { $0 },
            refusal: refusal,
            systemVersion: "Version 26.3.1 (Build 25D2128)",
            build: BuildIdentity(info: [:], executablePath: nil),
            time: Date(timeIntervalSince1970: 1_791_590_400),
            timesRefusedHere: 3
        )
        let lines = report.lines

        XCTAssertFalse(lines.contains { $0.hasPrefix("Position:") }, "\(lines)")
        XCTAssertTrue(lines.contains("Chapter 3 of 5 (chapter=2 in the logs)"), "\(lines)")
        XCTAssertTrue(lines.contains("Refused here: 3 times while this window has been open."), "\(lines)")
        XCTAssertTrue(lines.contains("Markup guard: the usual one, which silences only the brackets of tag-shaped text."), "\(lines)")
        XCTAssertTrue(lines.contains("Voice: the system's default voice"), "\(lines)")
        XCTAssertTrue(lines.contains("Speed: 350 words per minute; rate 0.60, pitch 1.50, volume 0.25"), "\(lines)")
        XCTAssertTrue(lines.contains("TextMouth: no build details recorded"), "\(lines)")
        XCTAssertEqual(lines.last, "Speech log: no lines.")
    }

    /// The map a reader gives may put the refused text's ends out of order,
    /// or outside the chapter: the report keeps them in order and inside it.
    func testTheReportKeepsMappedOffsetsInsideTheChapter() {
        let refusal = SpeechRefusal(
            offset: 10,
            refusedRange: 10..<20,
            refusedText: "0123456789",
            strictlyGuardedRange: 10..<20,
            voice: nil,
            wordsPerMinute: 200,
            rate: 0.5,
            pitchMultiplier: 1,
            volume: 1,
            recentLines: []
        )

        let report = SpeechRefusalReport(
            bookTitle: "Quay Ledger",
            bookFormat: "Plain Text",
            position: "",
            chapterIndex: 0,
            chapterCount: 1,
            chapterTitle: nil,
            chapterText: "abcdefghij",
            // Backwards, and far past the chapter's end.
            toChapterOffset: { 1_000 - $0 },
            refusal: refusal,
            systemVersion: "",
            build: BuildIdentity(info: [:], executablePath: nil),
            time: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(report.chapterOffset, 10)
        XCTAssertEqual(report.bookPassage.range, 0..<10)
        XCTAssertEqual(report.bookPassage.refusedRange, 10..<10)
        XCTAssertEqual(report.timesRefusedHere, 1)
    }

    // MARK: - One Report at a Time

    /// A reader shows one report at a time: a second refusal replaces the
    /// report shown, each place counts its own refusals, and closing the
    /// report forgets it but not the counts.
    func testTheReaderCountsEachPlaceAndShowsOneReport() {
        var alert = SpeechRefusalAlert()
        XCTAssertNil(alert.report)

        alert.show(Self.sampleReport())
        XCTAssertEqual(alert.report?.timesRefusedHere, 1)

        alert.show(Self.sampleReport())
        XCTAssertEqual(alert.report?.timesRefusedHere, 2, "the same place is counted again")
        XCTAssertTrue(alert.report?.lines.contains("Refused here: 2 times while this window has been open.") == true)

        alert.show(Self.sampleReport(stoppingAt: 31))
        XCTAssertEqual(alert.report?.timesRefusedHere, 1, "another place counts its own")
        XCTAssertEqual(alert.report?.chapterOffset, 40)

        alert.report = nil
        alert.show(Self.sampleReport())
        XCTAssertEqual(alert.report?.timesRefusedHere, 3, "closing the report forgot the count")
    }

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

    /// The report of a refusal in a text book whose one chapter is
    /// `"Moorings\nThe harbour bell rang twice. <sm>Gulls</sm> wheeled over
    /// the quay."` and whose spoken text leaves out the heading line, so
    /// that the book's offsets run nine ahead of the spoken text's. Speech
    /// was refused from the tag on, strictly guarded, and stopped at
    /// `offset` of the spoken text.
    static func sampleReport(stoppingAt offset: Int = 29) -> SpeechRefusalReport {
        let chapter = "Moorings\nThe harbour bell rang twice. <sm>Gulls</sm> wheeled over the quay."
        let time = Date(timeIntervalSince1970: 1_791_590_400)
        var lines = RecentTransitionLines()
        lines.append("CHUNK_START: offset=29 len=37 end=66 totalText=66", level: .trace, at: time)
        lines.append("DIRECT_RETRY_FAILED: offset=29 chunkStart=29 chunkEnd=66; speech stopped, the listener told", level: .event, at: time)
        let refusal = SpeechRefusal(
            offset: offset,
            refusedRange: 29..<66,
            refusedText: "\u{2039}sm\u{203A}Gulls\u{2039}/sm\u{203A} wheeled over the quay.",
            strictlyGuardedRange: 29..<66,
            voice: SpeechRefusal.Voice(
                name: "Samantha",
                identifier: "com.apple.voice.compact.en-US.Samantha",
                language: "en-US",
                quality: "Standard"
            ),
            wordsPerMinute: 200,
            rate: 0.4304,
            pitchMultiplier: 1,
            volume: 1,
            recentLines: lines.lines
        )
        return SpeechRefusalReport(
            bookTitle: "Quay Ledger",
            bookFormat: "Plain Text",
            position: "Tides. Heading 2 of 2. 42 percent. 3 hours remaining.",
            chapterIndex: 0,
            chapterCount: 1,
            chapterTitle: "Harbour Ledger",
            chapterText: chapter,
            toChapterOffset: { $0 + 9 },
            refusal: refusal,
            systemVersion: "Version 26.3.1 (Build 25D2128)",
            build: BuildIdentity(
                info: [
                    "CFBundleShortVersionString": "0.1.2",
                    "CFBundleVersion": "7",
                    "TextMouthGitCommit": "abc1234",
                    "TextMouthBuildDate": "2026-10-09T17:00:00Z",
                    "TextMouthBuildConfiguration": "Debug",
                ],
                executablePath: nil
            ),
            time: time
        )
    }

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

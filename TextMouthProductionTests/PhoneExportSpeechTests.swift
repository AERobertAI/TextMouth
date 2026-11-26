import XCTest
@testable import TextMouth

/// The iPhone's spoken audio export (FR31, phase 2), as plain values the Mac's test host reads: the rows the sheet shows
/// under Text as spoken audio, the bar with Close in Stop's place while the file is made and the Stop row, the card at the
/// top of the Library, and what the system's continued task shows and measures. The sheet, the card, and the task draw
/// and carry only what these decide.
///
/// Nothing here speaks: no synthesizer is made.
@MainActor
final class PhoneExportSpeechTests: XCTestCase {

    // MARK: - A Book and a Voice

    /// A voice that is not a Personal Voice.
    private let moira = SpeechExportVoiceInfo(identifier: "com.apple.voice.compact.en-IE.Moira", name: "Moira", isPersonalVoice: false)

    /// The options for a book with `headings` (none for a book without), spoken by `voice` at the speed and pitch given.
    private func makeState(
        headings: [Heading] = [
            Heading(level: 1, text: "Chapter 1", chapterIndex: 0, characterOffset: 0),
            Heading(level: 2, text: "Notes", chapterIndex: 0, characterOffset: 120),
            Heading(level: 1, text: "Chapter 2", chapterIndex: 1, characterOffset: 0)
        ],
        voice: SpeechExportVoiceInfo? = nil,
        wordsPerMinute: Double = 200,
        pitch: Double = 1.0
    ) -> SpeechExportOptionsState {
        SpeechExportOptionsState(
            headings: headings,
            skippedHeadingIDs: [],
            voice: voice ?? moira,
            settings: SpeechExportVoiceSettings(voiceIdentifier: (voice ?? moira).identifier, wordsPerMinute: wordsPerMinute, pitch: pitch)
        )
    }

    // MARK: - The Rows

    /// The row of `control` among `rows`, nil when there is none.
    private func row(_ control: PhoneExportOffer.SpeechRow.Control, in rows: [PhoneExportOffer.SpeechRow]) -> PhoneExportOffer.SpeechRow? {
        rows.first { $0.control == control }
    }

    /// The notes among `rows`, in order.
    private func notes(in rows: [PhoneExportOffer.SpeechRow]) -> [PhoneExportOffer.SpeechRow] {
        rows.filter { $0.control == .note }
    }

    /// A book with headings has the Mac's rows in the Mac's order, each with its label, its value, and its hint, and the
    /// licence line in the iPhone's words: the sheet draws these and nothing else, so this is what VoiceOver says.
    func testTheRowsAreTheMacsInTheMacsOrderWithTheirWords() {
        let rows = PhoneExportOffer.speechRows(makeState())

        XCTAssertEqual(rows.map(\.control), [
            .choice(.format), .choice(.from), .choice(.through), .speed, .pitch, .note, .note
        ])
        XCTAssertEqual(rows.map(\.label).prefix(5), ["Format", "From", "To", "Speed", "Pitch"])
        XCTAssertTrue(row(.choice(.format), in: rows)?.value?.hasPrefix("M4B") == true, "Format says \(String(describing: row(.choice(.format), in: rows)?.value))")
        XCTAssertEqual(row(.choice(.from), in: rows)?.value, "Beginning of the book")
        XCTAssertEqual(row(.choice(.through), in: rows)?.value, "End of the book")
        XCTAssertEqual(row(.speed, in: rows)?.value, "200 words per minute")
        XCTAssertEqual(row(.pitch, in: rows)?.value, SpeechExportWording.pitchValue(1.0))
        XCTAssertEqual(rows.filter { $0.control != .note }.map(\.hint), [
            SpeechExportWording.formatHint, SpeechExportWording.fromHint, SpeechExportWording.throughHint,
            SpeechExportWording.speedHint, SpeechExportWording.pitchHint
        ])
        XCTAssertEqual(row(.choice(.from), in: rows)?.hint, "Where the audio begins: the book's beginning, or a heading.")
        XCTAssertEqual(row(.choice(.through), in: rows)?.hint, "The heading whose section ends the audio, with its subheadings, or the end of the book.")
        // The notes: the voice, then the licence in the iPhone's words (a test on the Mac asks for them).
        XCTAssertEqual(notes(in: rows).map(\.label), [SpeechExportWording.voiceLine(moira), SpeechExportWording.licence])
        XCTAssertTrue(rows.allSatisfy { $0.control != .note || ($0.value == nil && $0.hint.isEmpty) })
    }

    /// The choices the rows name are the options' own: choosing a heading for From changes the From row's value, and one
    /// past the To moves the To with it, as on the Mac.
    func testTheFromAndToRowsFollowTheRangeInReadingOrder() throws {
        let state = makeState()
        let first = try XCTUnwrap(state.headings.first)
        let second = try XCTUnwrap(state.headings.dropFirst().first)

        state.setFrom(second.id)

        let rows = PhoneExportOffer.speechRows(state)
        XCTAssertEqual(row(.choice(.from), in: rows)?.value, SpeechExportWording.headingItem(second, isSkipped: false))
        XCTAssertEqual(row(.choice(.through), in: rows)?.value, "End of the book")
        state.setThrough(first.id)
        XCTAssertEqual(
            row(.choice(.from), in: PhoneExportOffer.speechRows(state))?.value,
            SpeechExportWording.headingItem(first, isSkipped: false), "To before From moves From"
        )
    }

    /// A book without headings says the whole of it is exported, in place of From and To.
    func testABookWithoutHeadingsSaysSoInPlaceOfFromAndTo() {
        let rows = PhoneExportOffer.speechRows(makeState(headings: []))

        XCTAssertEqual(rows.map(\.control), [.choice(.format), .note, .speed, .pitch, .note, .note])
        XCTAssertEqual(notes(in: rows).first?.label, "This book has no headings, so all of it is exported.")
        XCTAssertFalse(rows.contains { $0.label == "From" || $0.label == "To" })
    }

    /// MP3 for more headings than an MP3 has chapters for says so right after the Format row, as on the Mac.
    func testTheMP3NoteFollowsTheFormatRow() {
        let headings = (0..<300).map { Heading(level: 1, text: "Heading \($0 + 1)", chapterIndex: $0, characterOffset: 0) }
        let state = makeState(headings: headings)
        XCTAssertFalse(PhoneExportOffer.speechRows(state).contains { $0.label == SpeechExportWording.mp3ChapterLimit(headings: 300) })

        state.format = .mp3

        let rows = PhoneExportOffer.speechRows(state)
        XCTAssertEqual(rows.dropFirst().first?.control, .note)
        XCTAssertEqual(rows.dropFirst().first?.label, SpeechExportWording.mp3ChapterLimit(headings: 300))
    }

    /// A voice that cannot be recorded, or none at all, is the refusal's own sentence in the voice line, in the
    /// iPhone's words on the iPhone; the rows still list.
    func testTheVoiceLineSaysWhyWhenThereIsNoUsableVoice() {
        let personal = SpeechExportVoiceInfo(identifier: "personal", name: "Ottilie", isPersonalVoice: true)

        let rows = PhoneExportOffer.speechRows(makeState(voice: personal))

        XCTAssertEqual(
            notes(in: rows).first?.label,
            SpeechExportError.personalVoice(name: "Ottilie").description(onPhone: SpeechRefusalWording.runsOnPhone)
        )
    }

    /// The pitch steps as the reader's and Settings' pitch sliders do.
    func testThePitchStepsAsSettingsDoes() {
        XCTAssertEqual(PhoneExportOffer.pitchStep, 0.1)
    }

    // MARK: - The Bar and the Stop Row

    /// While the other kinds are written, Stop leads the bar with the export's hint, and with the spoken audio hint when
    /// spoken audio is exported; while the spoken audio file is made, Close takes its place, with its hint, and Stop is
    /// a row of its own with the hint that says the chapters are kept.
    func testCloseTakesStopsPlaceWhileTheSpokenAudioFileIsMade() {
        let writing = PhoneExportOffer.bar(stage: .exporting, canExport: false, isExportingSpeech: true, isMakingSpeech: false)
        XCTAssertEqual(writing.leading.role, .stop)
        XCTAssertEqual(writing.leading.hint, SpeechExportWording.stopHint)
        let plain = PhoneExportOffer.bar(stage: .exporting, canExport: false)
        XCTAssertEqual(plain.leading.role, .stop)
        XCTAssertEqual(plain.leading.hint, "Stops the export. The file being made is not kept.")

        let making = PhoneExportOffer.bar(stage: .exporting, canExport: false, isExportingSpeech: true, isMakingSpeech: true)
        XCTAssertEqual(making.leading.role, .close)
        XCTAssertEqual(making.leading.title, "Close")
        XCTAssertEqual(making.leading.hint, "Closes Export. The export goes on, and the Library shows how far it has come.")

        let stop = PhoneExportOffer.stopRow(stage: .exporting, isMakingSpeech: true)
        XCTAssertEqual(stop?.role, .stop)
        XCTAssertEqual(stop?.title, "Stop")
        XCTAssertEqual(stop?.hint, SpeechExportWording.stopHint)
        // Never with Stop in the bar, and never when nothing runs.
        XCTAssertNil(PhoneExportOffer.stopRow(stage: .exporting, isMakingSpeech: false))
        XCTAssertNil(PhoneExportOffer.stopRow(stage: .ready, isMakingSpeech: true))
        XCTAssertNil(PhoneExportOffer.stopRow(stage: .finished, isMakingSpeech: true))
    }

    /// Before and after an export the bar is as it was: Cancel, and Close once it has ended, however spoken audio goes.
    func testTheBarBeforeAndAfterIsUnchangedBySpokenAudio() {
        XCTAssertEqual(PhoneExportOffer.bar(stage: .ready, canExport: true, isExportingSpeech: true, isMakingSpeech: true).leading.role, .cancel)
        XCTAssertEqual(PhoneExportOffer.bar(stage: .finished, canExport: true, isMakingSpeech: true).leading.role, .close)
        XCTAssertEqual(PhoneExportOffer.bar(stage: .finished, canExport: true).leading.hint, "")
    }

    // MARK: - Share…

    /// Share… is offered once an export has ended with a file written, with its hint, and never before or without a file.
    func testShareIsOfferedOnlyAfterAnExportThatWroteFiles() {
        let share = PhoneExportOffer.shareButton(stage: .finished, exportedCount: 2)

        XCTAssertEqual(share?.title, "Share…")
        XCTAssertEqual(share?.hint, "Sends the files just exported to another app or person.")
        XCTAssertNil(PhoneExportOffer.shareButton(stage: .finished, exportedCount: 0), "nothing was written to send")
        XCTAssertNil(PhoneExportOffer.shareButton(stage: .exporting, exportedCount: 2))
        XCTAssertNil(PhoneExportOffer.shareButton(stage: .ready, exportedCount: 2))
        XCTAssertNil(PhoneExportOffer.shareButton(stage: .listing, exportedCount: 2))
    }

    // MARK: - The Library's Card

    /// The card shows the sheet's title and the progress with Stop while the export runs, and the Mac's sentence with Close
    /// once it has ended; none before.
    func testTheCardSaysTheProgressWithStopAndThenTheEndWithClose() {
        XCTAssertNil(PhoneExportOffer.card(stage: .ready, title: "Export Moby-Dick", progressText: nil, fraction: nil, finishedWords: nil))
        XCTAssertNil(PhoneExportOffer.card(stage: .listing, title: "Export Moby-Dick", progressText: nil, fraction: nil, finishedWords: nil))

        let running = PhoneExportOffer.card(
            stage: .exporting, title: "Export Moby-Dick", progressText: "Speaking chapter 3 of 12…", fraction: 0.25, finishedWords: nil
        )
        XCTAssertEqual(running?.title, "Export Moby-Dick")
        XCTAssertEqual(running?.status, "Speaking chapter 3 of 12…")
        XCTAssertEqual(running?.fraction, 0.25)
        XCTAssertEqual(running?.stop?.title, "Stop")
        XCTAssertEqual(running?.stop?.hint, SpeechExportWording.stopHint)
        XCTAssertNil(running?.close)

        let ended = PhoneExportOffer.card(
            stage: .finished, title: "Export Moby-Dick", progressText: nil, fraction: nil, finishedWords: "Exported 1 item to Downloads."
        )
        XCTAssertEqual(ended?.status, "Exported 1 item to Downloads.")
        XCTAssertNil(ended?.fraction)
        XCTAssertNil(ended?.stop)
        XCTAssertEqual(ended?.close?.title, "Close")
    }

    // MARK: - The Continued Task

    /// The task shows the sheet's title, the progress words as its subtitle, and the fraction in a thousand units; a
    /// fraction outside 0 to 1 is held to it, and none counts as nothing done.
    func testTheTaskMirrorsTheTitleTheWordsAndTheFraction() {
        let update = PhoneExportTaskMirror.update(title: "Export Moby-Dick", progressText: "Speaking chapter 3 of 12…", fraction: 0.2504)

        XCTAssertEqual(update.title, "Export Moby-Dick")
        XCTAssertEqual(update.subtitle, "Speaking chapter 3 of 12…")
        XCTAssertEqual(update.completedUnits, 250)
        XCTAssertEqual(PhoneExportTaskMirror.totalUnits, 1_000)
        XCTAssertEqual(PhoneExportTaskMirror.update(title: "t", progressText: nil, fraction: nil).completedUnits, 0)
        XCTAssertEqual(PhoneExportTaskMirror.update(title: "t", progressText: nil, fraction: nil).subtitle, "")
        XCTAssertEqual(PhoneExportTaskMirror.update(title: "t", progressText: nil, fraction: -3).completedUnits, 0)
        XCTAssertEqual(PhoneExportTaskMirror.update(title: "t", progressText: nil, fraction: 7).completedUnits, 1_000)
        XCTAssertEqual(PhoneExportTaskMirror.update(title: "t", progressText: nil, fraction: 1).completedUnits, PhoneExportTaskMirror.totalUnits)
    }

    /// The fraction only rises with the export: each later fraction gives no fewer units, so the task's bar never goes back.
    func testTheTaskProgressNeverGoesBack() {
        let fractions = stride(from: 0.0, through: 1.0, by: 0.0173).map { $0 }
        let units = fractions.map { PhoneExportTaskMirror.update(title: "t", progressText: nil, fraction: $0).completedUnits }

        XCTAssertEqual(units, units.sorted())
    }
}

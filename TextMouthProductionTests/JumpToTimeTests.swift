import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// Go to Time's one field and Go to Percent's labelled field (P08, REV13): a
/// time read as people write it, its limit the end of the book's clock, an
/// audiobook's time counted on its recording at every speed, a text book's
/// at its words per minute, each heading's time landing on its heading, and
/// each panel's field one labelled edit text. Pure (`RecordingTimeFixtures`
/// readers, whose content each test assigns), except the hosted checks of
/// the panels' fields, which draw them offscreen in a fixed frame.
@MainActor
final class JumpToTimeTests: XCTestCase {
    private typealias Fixtures = RecordingTimeFixtures

    /// The one-file book's length, 9:41:07.4.
    private let recordingLength = RecordingTimeFixtures.oneFileDuration

    // MARK: - The Field

    /// Go to Time's field reads a time as it is shown, spoken, or pasted:
    /// hours, minutes, and seconds, minutes alone, or seconds alone, with
    /// or without a tenth, spaces ignored.
    func testTheFieldReadsATimeAsPeopleWriteIt() {
        let forms: [(text: String, seconds: TimeInterval)] = [
            ("1:02:03", 3_723), ("62:03", 3_723), ("3723", 3_723), (" 1 : 02 : 03 ", 3_723),
            ("12:04.3", 724.3), ("2:13:05", 7_985), ("133:05", 7_985), ("7985", 7_985), ("2:13:05.4", 7_985.4),
        ]
        for form in forms {
            guard case .value(let read) = JumpInputValidator.time(form.text, length: recordingLength, count: .recording) else {
                XCTFail("\"\(form.text)\" was refused")
                continue
            }
            XCTAssertEqual(read, form.seconds, accuracy: 1e-9, form.text)
        }
    }

    /// What is not a time is refused with what to type, and impossible
    /// minutes or seconds with what is wrong, as the audio editor refuses
    /// them.
    func testTheFieldRefusesWhatIsNotATime() {
        for text in ["", "  ", "soon", "1:2:3:4", "-5", "1e3"] {
            XCTAssertEqual(JumpInputValidator.time(text, length: recordingLength, count: .recording), .error(TimeEntry.howToType), text)
        }
        XCTAssertEqual(JumpInputValidator.time("1:60", length: recordingLength, count: .recording), .error(TimeEntry.secondsTooLarge))
        XCTAssertEqual(JumpInputValidator.time("1:60:00", length: recordingLength, count: .recording), .error(TimeEntry.minutesTooLarge))
    }

    /// The limit is the recording's length, whatever the speed: the length
    /// as it is shown, in whole seconds, is taken; a time a hair past it is
    /// its end; a second past it, or hours too many to count, are refused,
    /// naming the recording's length. A text book's limit is its reading
    /// time, refused as before.
    func testTheLimitIsTheRecordingsLength() {
        let refusal = "Time exceeds the recording's length. The recording lasts 9 hours, 41 minutes, 7 seconds."
        XCTAssertEqual(JumpInputValidator.time("9:41:07", length: recordingLength, count: .recording), .value(34_867))
        XCTAssertEqual(JumpInputValidator.time("9:41:07.43", length: recordingLength, count: .recording), .value(recordingLength))
        XCTAssertEqual(JumpInputValidator.time("9:41:08", length: recordingLength, count: .recording), .error(refusal))
        XCTAssertEqual(JumpInputValidator.time("\(Int.max):00:00", length: recordingLength, count: .recording), .error(refusal))
        XCTAssertEqual(
            JumpInputValidator.time("1:00:01", length: 3_600, count: .words(perMinute: 500)),
            .error("Time exceeds book length. Maximum is 1 hour.")
        )
        XCTAssertEqual(JumpInputValidator.time("1:00:00", length: 3_600, count: .words(perMinute: 500)), .value(3_600))
    }

    /// Every sentence is a constant, pinned word for word.
    func testTheSentencesAreFixed() {
        XCTAssertEqual(ReaderTimeWording.recordingTimeFieldLabel, "Time in the recording")
        XCTAssertEqual(ReaderTimeWording.timeFieldLabel(.recording), "Time in the recording")
        XCTAssertEqual(ReaderTimeWording.timeFieldLabel(.words(perMinute: 500)), "Time at 500 words a minute")
        XCTAssertEqual(ReaderTimeWording.timeFieldLabel(.words(perMinute: 199.9)), "Time at 199 words a minute")
        XCTAssertEqual(ReaderTimeWording.timeFieldHint, "Type a time, such as 12:04.3, 1:02:03, or 75.5.")
        XCTAssertEqual(ReaderTimeWording.percentFieldLabel, "Percent through the book")
        XCTAssertEqual(ReaderTimeWording.percentFieldHint, "Type a percent from 0 to 100, such as 47.5.")
        XCTAssertEqual(
            ReaderTimeWording.pastTheEnd(34_867.4, .recording),
            "Time exceeds the recording's length. The recording lasts 9 hours, 41 minutes, 7 seconds."
        )
        XCTAssertEqual(ReaderTimeWording.pastTheEnd(3_600, .words(perMinute: 500)), "Time exceeds book length. Maximum is 1 hour.")
        XCTAssertEqual(ReaderTimeWording.jumped(to: 7_985, .recording), "Jumped to 2 hours, 13 minutes, 5 seconds in the recording.")
        XCTAssertEqual(ReaderTimeWording.jumped(to: 7_985, .words(perMinute: 500)), "Jumped to 2 hours, 13 minutes, 5 seconds.")
        XCTAssertEqual(ReaderTimeWording.jumped(toPercent: 47.5), "Jumped to 47.5 percent.")
        XCTAssertEqual(ReaderTimeWording.wordsAMinute(500), "500 words a minute")
        XCTAssertEqual(ReaderTimeWording.wordsAMinute(.nan), "0 words a minute")
        XCTAssertEqual(ReaderTimeWording.wordsAMinute(.infinity), "0 words a minute")
    }

    // MARK: - Through the Reader

    /// The design's book, one file of 9:41:07.4 with the reading position
    /// at 2:13:05: at 0.5x, 1x, and 2x Go to Time starts at "2:13:05" and
    /// Jump leaves the position where it is (at 2x it once went back to
    /// 1:06:32), saying so; a time from the recording past half the book,
    /// which 2x once refused, lands on it.
    func testTheDesignsBookStaysPutAtEverySpeed() throws {
        let reader = Fixtures.makeReader(format: .audio)
        defer { reader.close() }
        reader.content = try Fixtures.audioContent(.oneFile)

        for speed in [0.5, 1, 2] {
            reader.audioSpeed = speed
            reader.currentChapterIndex = 0
            reader.currentCharacterOffset = 79_850
            XCTAssertEqual(reader.goToTimeStartingText, "2:13:05", "at \(speed)x")

            XCTAssertNil(reader.goToTime(typed: reader.goToTimeStartingText))
            XCTAssertEqual(reader.currentCharacterOffset, 79_850, "at \(speed)x")
            XCTAssertEqual(reader.lastAnnouncement, "Jumped to 2 hours, 13 minutes, 5 seconds in the recording.")

            XCTAssertNil(reader.goToTime(typed: "8:00:00"))
            XCTAssertEqual(reader.currentCharacterOffset, 288_000, "at \(speed)x")
            XCTAssertEqual(
                reader.goToTime(typed: "9:41:08"),
                "Time exceeds the recording's length. The recording lasts 9 hours, 41 minutes, 7 seconds."
            )
            XCTAssertEqual(reader.currentCharacterOffset, 288_000, "a refused time moved the position")
        }
    }

    /// For an audiobook of every layout, at 0.5x, 1x, and 2x, a place's
    /// time from Go to Time is its time in the recording, the same at every
    /// speed, and Jump comes back within a second of the place, give or
    /// take the half tenth a place is rounded to.
    func testGoToTimeComesBackToItsPlaceForEveryLayoutAndSpeed() throws {
        for layout in Fixtures.Layout.allCases {
            let reader = Fixtures.makeReader(format: .audio)
            defer { reader.close() }
            let content = try Fixtures.audioContent(layout)
            reader.content = content
            let clock = PlaceClock.recording(of: content.contentIndex)

            for place in Fixtures.samplePlaces(on: clock) {
                let placeTime = clock.time(of: place)
                for speed in [0.5, 1, 2] {
                    reader.audioSpeed = speed
                    reader.currentChapterIndex = place.chapterIndex
                    reader.currentCharacterOffset = place.characterOffset
                    let starting = reader.goToTimeStartingText
                    XCTAssertEqual(starting, TimeFormatting.format(placeTime), "\(layout) at \(speed)x")

                    XCTAssertNil(reader.goToTime(typed: starting), "\(layout) at \(speed)x: \(starting)")
                    let landed = clock.time(chapterIndex: reader.currentChapterIndex, characterOffset: reader.currentCharacterOffset)
                    XCTAssertLessThan(abs(placeTime - landed), 1.05 + 1e-9, "\(layout) at \(speed)x: \(starting)")
                }
            }
        }
    }

    /// Every heading's time as the Headings sheet shows it, typed into Go to
    /// Time at 2x, lands exactly on that heading, for every layout.
    func testEveryHeadingsSheetTimeLandsOnItsHeading() throws {
        for layout in Fixtures.Layout.allCases {
            let reader = Fixtures.makeReader(format: .audio)
            defer { reader.close() }
            reader.content = try Fixtures.audioContent(layout)
            reader.audioSpeed = 2

            for row in timeInRows(of: reader) {
                XCTAssertNil(reader.goToTime(typed: row.infoText), "\(layout): \(row.infoText)")
                XCTAssertEqual(reader.currentChapterIndex, row.heading.chapterIndex, "\(layout): \(row.heading.text) at \(row.infoText)")
                XCTAssertEqual(reader.currentCharacterOffset, row.heading.characterOffset, "\(layout): \(row.heading.text)")
            }
        }
    }

    /// A text book's Go to Time counts its words at its speed, as before,
    /// and says so: at 200 and 500 words a minute its field is "Time at 500
    /// words a minute", its starting value the position's time at that
    /// speed, Jump comes back within a second of the position and says so
    /// as before, and every heading's time from the Headings sheet lands
    /// on it.
    func testATextBooksGoToTimeCountsItsWordsAtItsSpeed() throws {
        let reader = Fixtures.makeReader(format: .txt)
        defer { reader.close() }
        let content = Fixtures.textContent()
        reader.content = content
        let total = Double(content.totalCharacterCount)

        for wordsPerMinute in [200.0, 500.0] {
            reader.speechService.wordsPerMinute = wordsPerMinute
            let readingTime = content.estimatedReadingTime(wpm: wordsPerMinute)
            let clock = try XCTUnwrap(reader.placeClock)
            XCTAssertEqual(ReaderTimeWording.timeFieldLabel(reader.timeCount), "Time at \(Int(wordsPerMinute)) words a minute")

            for place in Fixtures.samplePlaces(on: clock) {
                reader.currentChapterIndex = place.chapterIndex
                reader.currentCharacterOffset = place.characterOffset
                let global = content.globalOffset(chapterIndex: place.chapterIndex, localOffset: place.characterOffset)
                let placeTime = clock.time(of: place)
                XCTAssertEqual(placeTime, readingTime * Double(global) / total, accuracy: 1e-6)
                let starting = reader.goToTimeStartingText
                XCTAssertEqual(starting, TimeFormatting.format(placeTime))

                XCTAssertNil(reader.goToTime(typed: starting))
                let landed = clock.time(chapterIndex: reader.currentChapterIndex, characterOffset: reader.currentCharacterOffset)
                let halfUnit = 0.5 / clock.unitsPerSecond
                XCTAssertLessThan(abs(placeTime - landed), 1 + halfUnit + 1e-9, "\(starting) at \(wordsPerMinute) words a minute")
                let typed = try XCTUnwrap(Fixtures.typedBack(starting))
                XCTAssertEqual(reader.lastAnnouncement, "Jumped to \(TimeFormatting.spoken(typed)).")
            }

            for row in timeInRows(of: reader) {
                XCTAssertNil(reader.goToTime(typed: row.infoText))
                XCTAssertEqual(reader.currentChapterIndex, row.heading.chapterIndex, "\(row.heading.text) at \(row.infoText)")
                XCTAssertEqual(reader.currentCharacterOffset, row.heading.characterOffset, "\(row.heading.text) at \(row.infoText)")
            }
        }
    }

    /// Go to Percent jumps to the percent typed and says so, and refuses
    /// what is not a percent, as it did.
    func testGoToPercentJumpsOrSaysWhy() throws {
        let reader = Fixtures.makeReader(format: .txt)
        defer { reader.close() }
        reader.content = Fixtures.textContent()

        XCTAssertNil(reader.goToPercent(typed: "47.5"))
        XCTAssertEqual(reader.lastAnnouncement, "Jumped to 47.5 percent.")
        XCTAssertEqual(reader.percentComplete, 47.5, accuracy: 0.05)
        XCTAssertEqual(reader.goToPercent(typed: ""), "Enter a percent.")
        XCTAssertEqual(reader.goToPercent(typed: "101"), "Percent must be between 0 and 100.")
    }

    // MARK: - The Panels' Fields

    /// Go to Time's panel draws one field, labelled "Time in the recording"
    /// for an audiobook, with what to type as its hint. It keeps the text
    /// field's role, which VoiceOver speaks as "edit text" (an overridden
    /// value once made it plain "text"), and its value is the time it holds,
    /// the starting time at 2x as at 1x; no Hours, Minutes, or Seconds field
    /// is left.
    func testGoToTimesFieldIsOneLabelledEditText() throws {
        let reader = Fixtures.makeReader(format: .audio)
        defer { reader.close() }
        reader.content = try Fixtures.audioContent(.oneFile)
        reader.audioSpeed = 2
        reader.currentCharacterOffset = 79_850
        let panel = JumpToTimePanel(viewModel: reader, onJump: {}, onCancel: {})

        try withHostedField(panel, holding: "2:13:05") { field, controls in
            XCTAssertEqual(field.role, .textField)
            XCTAssertEqual(field.label, "Time in the recording")
            XCTAssertEqual(field.hint, TimeEntry.howToType)
            XCTAssertEqual(field.element.accessibilityValue() as? String, "2:13:05")
            XCTAssertEqual(controls.filter { $0.role == .textField }.count, 1)
            XCTAssertTrue(controls.allSatisfy { !["Hours", "Minutes", "Seconds"].contains($0.label) })
        }
    }

    /// A text book's Go to Time field names its speed: "Time at 500 words a
    /// minute".
    func testATextBooksGoToTimeFieldNamesItsSpeed() throws {
        let reader = Fixtures.makeReader(format: .txt)
        defer { reader.close() }
        reader.content = Fixtures.textContent()
        reader.speechService.wordsPerMinute = 500
        let panel = JumpToTimePanel(viewModel: reader, onJump: {}, onCancel: {})

        try withHostedField(panel, holding: "0:00") { field, _ in
            XCTAssertEqual(field.role, .textField)
            XCTAssertEqual(field.label, "Time at 500 words a minute")
            XCTAssertEqual(field.hint, TimeEntry.howToType)
        }
    }

    /// Go to Percent's panel draws one field, labelled "Percent through the
    /// book", with what to type as its hint, the text field's role, and the
    /// starting percent as its value; the unit is in the label, not a word
    /// after the field.
    func testGoToPercentsFieldIsOneLabelledEditText() throws {
        let reader = Fixtures.makeReader(format: .txt)
        defer { reader.close() }
        reader.content = Fixtures.textContent()
        let starting = String(format: "%.1f", reader.displayPercentComplete)
        let panel = JumpToPercentPanel(viewModel: reader, onJump: {}, onCancel: {})

        try withHostedField(panel, holding: starting) { field, controls in
            XCTAssertEqual(field.role, .textField)
            XCTAssertEqual(field.label, "Percent through the book")
            XCTAssertEqual(field.hint, "Type a percent from 0 to 100, such as 47.5.")
            XCTAssertEqual(field.element.accessibilityValue() as? String, starting)
            XCTAssertEqual(controls.filter { $0.role == .textField }.count, 1)
        }
    }

    /// A time typed into Go to Time's field is the field's value, and Return
    /// jumps to it and closes the panel. Skipped where an offscreen window
    /// gives the field no keyboard focus or takes no key.
    func testATypedTimeIsTheFieldsValueAndReturnJumpsToIt() throws {
        let reader = Fixtures.makeReader(format: .audio)
        defer { reader.close() }
        reader.content = try Fixtures.audioContent(.oneFile)
        var closed = false
        let panel = JumpToTimePanel(viewModel: reader, onJump: { closed = true }, onCancel: {})

        try withHostedField(panel, holding: "0:00") { field, _ in
            let hostingView = field.hostingView
            let textField = try XCTUnwrap(
                editableTextFields(in: hostingView).first { $0.placeholderString == "Time in the recording" },
                "the field was not drawn"
            )
            try typeReplacingText("1:02:03", in: textField, of: hostingView)
            XCTAssertEqual(field.element.accessibilityValue() as? String, "1:02:03")

            _ = pressReturnKey(in: hostingView)
            settleHostedView(hostingView)
            guard closed else { throw XCTSkip("This macOS hands an offscreen window's field no Return") }
            XCTAssertEqual(reader.currentCharacterOffset, 37_230)
            XCTAssertEqual(reader.lastAnnouncement, "Jumped to 1 hour, 2 minutes, 3 seconds in the recording.")
        }
    }

    // MARK: - Helpers

    /// The Headings sheet's Time In rows for `reader`'s headings, each shown.
    private func timeInRows(of reader: ReaderViewModel) -> [HeadingNavigatorView.HeadingListItem] {
        let headings = reader.content?.allHeadings ?? []
        return HeadingNavigatorView.headingItems(
            for: reader,
            displayed: headings,
            allHeadings: headings,
            skippedIDs: [],
            mode: .timeIntoBook
        )
    }

    /// Hosts `panel` offscreen in a frame of its own fixed size, so the
    /// window never follows its content, waits until its text field holds
    /// `text` (the panel fills it as it opens), and passes that field's
    /// accessibility attributes and every control's to `body`. Skipped where
    /// hosted windows expose no accessibility elements.
    private func withHostedField<Panel: View>(
        _ panel: Panel,
        holding text: String,
        _ body: (HostedField, [AccessibleControl]) throws -> Void
    ) throws {
        try skipUnlessHostedWindowsExposeAccessibility()
        let size = NSSize(width: 640, height: 120)
        try withHostedView(
            panel.frame(width: size.width, height: size.height),
            size: size,
            until: { hostingView in
                self.accessibleControls(in: hostingView).contains {
                    $0.role == .textField && ($0.element.accessibilityValue() as? String) == text
                }
            }
        ) { hostingView in
            let controls = accessibleControls(in: hostingView)
            let control = try XCTUnwrap(
                controls.first { $0.role == .textField },
                "no text field among \(controls.map { "\($0.role.rawValue) \($0.label)" })"
            )
            try body(HostedField(control: control, hostingView: hostingView), controls)
        }
    }

    /// A hosted panel's text field as VoiceOver reads it, with the view
    /// hosting it.
    private struct HostedField {
        let control: AccessibleControl
        let hostingView: NSView

        var element: NSAccessibilityProtocol { control.element }
        var role: NSAccessibility.Role { control.role }
        var label: String { control.label }
        var hint: String { control.hint }
    }
}

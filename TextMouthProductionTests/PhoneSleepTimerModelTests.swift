import XCTest
@testable import TextMouth

/// `PhoneSleepTimerModel`: the phone's Sleep Timer sheet's timers, focus,
/// limits, and words, by the spec's "The Sleep Timer sheet".
final class PhoneSleepTimerModelTests: XCTestCase {
    /// The presets are the Mac's.
    func testThePresetsAreTheMacs() {
        XCTAssertEqual(PhoneSleepTimerModel.presetMinutes, [10, 15, 30, 45, 60])
    }

    /// Focus lands on the last timer used, a custom number of minutes on
    /// the custom timer's Set, and with none used yet on the first preset.
    func testFocusLandsOnTheLastTimerUsed() {
        XCTAssertEqual(PhoneSleepTimerModel.openingFocus(lastUsed: nil), .preset(minutes: 10))
        XCTAssertEqual(PhoneSleepTimerModel.openingFocus(lastUsed: .minutes(45)), .preset(minutes: 45))
        XCTAssertEqual(PhoneSleepTimerModel.openingFocus(lastUsed: .minutes(20)), .custom)
        XCTAssertEqual(PhoneSleepTimerModel.openingFocus(lastUsed: .endOfHeading), .endOfHeading)
        XCTAssertEqual(PhoneSleepTimerModel.openingFocus(lastUsed: .endOfBook), .endOfBook)
    }

    /// The custom field starts at a custom last timer's minutes, so Set
    /// repeats it, and otherwise at the Mac's 30.
    func testTheCustomFieldStartsAtTheLastCustomTimer() {
        XCTAssertEqual(PhoneSleepTimerModel.openingCustomMinutes(lastUsed: .minutes(20)), 20)
        XCTAssertEqual(PhoneSleepTimerModel.openingCustomMinutes(lastUsed: .minutes(15)), 30)
        XCTAssertEqual(PhoneSleepTimerModel.openingCustomMinutes(lastUsed: .endOfBook), 30)
        XCTAssertEqual(PhoneSleepTimerModel.openingCustomMinutes(lastUsed: nil), 30)
        XCTAssertEqual(PhoneSleepTimerModel.openingCustomMinutes(lastUsed: .minutes(1000)), 480)
    }

    /// What's typed is held to the Mac's 1 to 480 minutes; no whole number
    /// is no timer.
    func testTypedMinutesAreHeldToTheMacsLimits() {
        XCTAssertEqual(PhoneSleepTimerModel.customMinutes(typed: " 25 "), 25)
        XCTAssertEqual(PhoneSleepTimerModel.customMinutes(typed: "0"), 1)
        XCTAssertEqual(PhoneSleepTimerModel.customMinutes(typed: "999"), 480)
        XCTAssertNil(PhoneSleepTimerModel.customMinutes(typed: "half an hour"))
        XCTAssertNil(PhoneSleepTimerModel.customMinutes(typed: ""))
    }

    /// Each choice sets its timer and is named in the Mac's words.
    func testEachChoiceSetsItsTimerInTheMacsWords() {
        XCTAssertEqual(PhoneSleepTimerModel.duration(of: .preset(minutes: 15), customMinutes: 30), .minutes(15))
        XCTAssertEqual(PhoneSleepTimerModel.duration(of: .custom, customMinutes: 600), .minutes(480))
        XCTAssertEqual(PhoneSleepTimerModel.duration(of: .endOfHeading, customMinutes: 30), .endOfHeading)
        XCTAssertEqual(PhoneSleepTimerModel.duration(of: .endOfBook, customMinutes: 30), .endOfBook)

        XCTAssertEqual(PhoneSleepTimerModel.label(of: .preset(minutes: 15), customMinutes: 30), "Set timer for 15 minutes and start playing")
        XCTAssertEqual(PhoneSleepTimerModel.label(of: .custom, customMinutes: 1), "Set timer for 1 minute and start playing")
        XCTAssertEqual(PhoneSleepTimerModel.label(of: .endOfHeading, customMinutes: 30), "Stop at the end of this heading and start playing")
        XCTAssertEqual(PhoneSleepTimerModel.label(of: .endOfBook, customMinutes: 30), "Stop at the end of the book and start playing")
    }

    /// What's said once a timer is set is the Mac's sentence.
    func testTheWordsAfterSettingAreTheMacs() {
        XCTAssertEqual(PhoneSleepTimerModel.setAnnouncement(.minutes(15)), "Timer set for 15 minutes.")
        XCTAssertEqual(PhoneSleepTimerModel.setAnnouncement(.endOfHeading), "Sleep timer: stops at the end of this heading.")
    }

    /// The custom field's hint names no Return key.
    func testTheCustomHintIsThePhones() {
        XCTAssertEqual(
            PhoneSleepTimerModel.customMinutesHint,
            "Type the minutes, or change them 5 at a time with Adjust minutes. Set sets the timer and starts playing."
        )
    }

    /// The reader's value is "Off" without a timer, else the Mac's status.
    func testTheReadersValueIsOffOrTheMacsStatus() {
        XCTAssertEqual(PhoneSleepTimerModel.readerValue(isActive: false, spokenStatus: ""), "Off")
        XCTAssertEqual(PhoneSleepTimerModel.readerValue(isActive: true, spokenStatus: "4:59 remaining"), "4:59 remaining")
        XCTAssertEqual(PhoneSleepTimerModel.readerValue(isActive: true, spokenStatus: ""), "Off")
    }

    /// The note under New Timer is the Mac's, by whether a timer runs.
    func testTheNewTimerNoteFollowsTheTimer() {
        XCTAssertEqual(PhoneSleepTimerModel.newTimerNote(isActive: true), "Setting a new timer replaces the current one.")
        XCTAssertEqual(PhoneSleepTimerModel.newTimerNote(isActive: false), "Pause playback after:")
    }

    /// The wait for the words before the book starts has a limit.
    func testTheWaitBeforePlayingHasALimit() {
        XCTAssertGreaterThan(PhoneSleepTimerModel.longestWaitBeforePlaying, 0)
        XCTAssertLessThanOrEqual(PhoneSleepTimerModel.longestWaitBeforePlaying, 5)
    }
}

/// `PhoneSleepTimerVocabulary`: each word is the Mac's Sleep Timer sheet's,
/// read from its own source.
final class PhoneSleepTimerVocabularyTests: XCTestCase {
    /// Every inline word is in `SleepTimerView` as the phone has it.
    func testEveryWordIsTheMacsSleepTimerSheets() throws {
        let macView = try String(
            contentsOf: AppSourceFile.folder.appendingPathComponent("Views/Reader/SleepTimerView.swift"),
            encoding: .utf8
        )
        let words = [
            "Text(\"\(PhoneSleepTimerVocabulary.title)\")",
            "Button(\"\(PhoneSleepTimerVocabulary.close)\")",
            ".accessibilityHint(\"\(PhoneSleepTimerVocabulary.closeHint)\")",
            "Text(\"\(PhoneSleepTimerVocabulary.currentTimer)\")",
            "Button(\"\(PhoneSleepTimerVocabulary.resetTimer)\")",
            ".accessibilityHint(\"\(PhoneSleepTimerVocabulary.resetTimerHint)\")",
            "Button(\"\(PhoneSleepTimerVocabulary.cancelTimer)\", role: .destructive)",
            ".accessibilityHint(\"\(PhoneSleepTimerVocabulary.cancelTimerHint)\")",
            "\"\(PhoneSleepTimerVocabulary.cancelled)\"",
            "Text(\"\(PhoneSleepTimerVocabulary.newTimer)\")",
            "\"\(PhoneSleepTimerVocabulary.replacesCurrent)\"",
            "\"\(PhoneSleepTimerVocabulary.pausePlaybackAfter)\"",
            "TextField(\"\(PhoneSleepTimerVocabulary.minutesField)\", value: $customMinutes, format: .number)",
            ".accessibilityLabel(\"\(PhoneSleepTimerVocabulary.customMinutesLabel)\")",
            "Button(\"\(PhoneSleepTimerVocabulary.set)\")",
        ]

        for word in words {
            XCTAssertTrue(macView.contains(word), "The Mac's Sleep Timer sheet no longer says \(word)")
        }
    }
}

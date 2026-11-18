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

        XCTAssertEqual(PhoneSleepTimerModel.label(of: .preset(minutes: 15), customMinutes: 30), "Set timer for 15 minutes")
        XCTAssertEqual(PhoneSleepTimerModel.label(of: .custom, customMinutes: 1), "Set timer for 1 minute")
        XCTAssertEqual(PhoneSleepTimerModel.label(of: .endOfHeading, customMinutes: 30), "Stop at the end of this heading")
        XCTAssertEqual(PhoneSleepTimerModel.label(of: .endOfBook, customMinutes: 30), "Stop at the end of the book")
        // What the minute buttons also do is their hint, the Mac's (FR35).
        XCTAssertEqual(SleepTimerView.minutesTimerHint, "Plays the book.")
    }

    /// What's said once a timer is set is the Mac's sentence.
    func testTheWordsAfterSettingAreTheMacs() {
        XCTAssertEqual(PhoneSleepTimerModel.setAnnouncement(.minutes(15)), "Timer set for 15 minutes.")
        XCTAssertEqual(PhoneSleepTimerModel.setAnnouncement(.endOfHeading), "Sleep timer: stops at the end of this heading.")
    }

    /// The custom field's hint on the phone is the range alone: the phone has no Return key to name, so its hint is
    /// not the Mac's, which also says what Return does (the review of FR35's cuts).
    func testTheCustomHintIsThePhonesOwn() {
        XCTAssertEqual(PhoneSleepTimerModel.customMinutesHint, "Takes 1 to 480 minutes.")
        XCTAssertEqual(PhoneSleepTimerModel.customMinutesHint, SleepTimerView.customMinutesRangeHint)
        XCTAssertEqual(SleepTimerView.customMinutesHint, "Takes 1 to 480 minutes. Return sets the timer and plays the book.")
        XCTAssertNotEqual(PhoneSleepTimerModel.customMinutesHint, SleepTimerView.customMinutesHint)
        XCTAssertEqual(PhoneSleepTimerModel.customMinutesRange, SleepTimerView.customMinutesRange)
    }

    /// The reader's value is "Off" without a timer, else the Mac's status.
    func testTheReadersValueIsOffOrTheMacsStatus() {
        XCTAssertEqual(PhoneSleepTimerModel.readerValue(isActive: false, spokenStatus: ""), "Off")
        XCTAssertEqual(PhoneSleepTimerModel.readerValue(isActive: true, spokenStatus: "4:59 remaining"), "4:59 remaining")
        XCTAssertEqual(PhoneSleepTimerModel.readerValue(isActive: true, spokenStatus: ""), "Off")
    }

    /// The note under New Timer is the Mac's, by whether a timer runs.
    func testTheNewTimerNoteFollowsTheTimer() {
        XCTAssertEqual(PhoneSleepTimerModel.newTimerNote(isActive: true), "A new timer replaces the one running.")
        XCTAssertEqual(PhoneSleepTimerModel.newTimerNote(isActive: false), "Pause playback after:")
    }

    /// The wait for the words before the book starts has a limit.
    func testTheWaitBeforePlayingHasALimit() {
        XCTAssertGreaterThan(PhoneSleepTimerModel.longestWaitBeforePlaying, 0)
        XCTAssertLessThanOrEqual(PhoneSleepTimerModel.longestWaitBeforePlaying, 5)
    }
}

/// `PhoneSleepTimerVocabulary`: each word is the Mac's Sleep Timer sheet's,
/// the static the Mac's sheet shows, with its English as it was.
final class PhoneSleepTimerVocabularyTests: XCTestCase {
    /// Every word the phone takes from the Mac's sheet is the Mac's own
    /// static, which the Mac's sheet shows where the word once sat inline
    /// (`shownAs`, read from its source), and its English has not changed.
    /// The words were inline literals of `SleepTimerView`, which this test
    /// found in its source; they became its localized statics (FR35), which
    /// both sheets read, so the source check looks for each static instead.
    func testEveryWordIsTheMacsSleepTimerSheets() throws {
        let macView = try String(
            contentsOf: AppSourceFile.folder.appendingPathComponent("Views/Reader/SleepTimerView.swift"),
            encoding: .utf8
        )
        let words: [(phone: String, mac: String, english: String, shownAs: String)] = [
            (PhoneSleepTimerVocabulary.title, SleepTimerView.title, "Sleep Timer", "Text(Self.title)"),
            (PhoneSleepTimerVocabulary.close, SleepTimerView.closeTitle, "Close", "Button(Self.closeTitle)"),
            (PhoneSleepTimerVocabulary.closeHint, SleepTimerView.closeHint,
             "Returns to the book.", ".accessibilityHint(Self.closeHint)"),
            (PhoneSleepTimerVocabulary.currentTimer, SleepTimerView.currentTimerHeading,
             "Current Timer", "Text(Self.currentTimerHeading)"),
            (PhoneSleepTimerVocabulary.resetTimer, SleepTimerView.resetTimerTitle, "Reset Timer", "Button(Self.resetTimerTitle)"),
            (PhoneSleepTimerVocabulary.resetTimerHint, SleepTimerView.resetTimerHint,
             "Restarts the timer at its full length and plays the book.", ".accessibilityHint(Self.resetTimerHint)"),
            (PhoneSleepTimerVocabulary.cancelTimer, SleepTimerView.cancelTimerTitle,
             "Cancel Timer", "Button(Self.cancelTimerTitle, role: .destructive)"),
            (PhoneSleepTimerVocabulary.cancelled, SleepTimerView.cancelledAnnouncement,
             "Sleep timer cancelled.", "announceToVoiceOver(Self.cancelledAnnouncement)"),
            (PhoneSleepTimerVocabulary.newTimer, SleepTimerView.newTimerHeading, "New Timer", "Text(Self.newTimerHeading)"),
            (PhoneSleepTimerVocabulary.replacesCurrent, SleepTimerView.newTimerNote(isActive: true),
             "A new timer replaces the one running.", "Text(Self.newTimerNote(isActive: sleepTimerService.isActive))"),
            (PhoneSleepTimerVocabulary.pausePlaybackAfter, SleepTimerView.newTimerNote(isActive: false),
             "Pause playback after:", "Text(Self.newTimerNote(isActive: sleepTimerService.isActive))"),
            (PhoneSleepTimerVocabulary.minutesField, SleepTimerView.minutesFieldTitle,
             "Minutes", "TextField(Self.minutesFieldTitle, value: $customMinutes, format: .number)"),
            (PhoneSleepTimerVocabulary.customMinutesLabel, SleepTimerView.customMinutesLabel,
             "Custom minutes", ".accessibilityLabel(Self.customMinutesLabel)"),
            (PhoneSleepTimerVocabulary.set, SleepTimerView.setTitle, "Set", "Button(Self.setTitle)"),
        ]

        for word in words {
            XCTAssertEqual(word.phone, word.mac, "The phone's word is not the Mac's \(word.shownAs)")
            XCTAssertEqual(word.mac, word.english, "The Mac's \(word.shownAs) changed its English")
            XCTAssertTrue(macView.contains(word.shownAs), "The Mac's Sleep Timer sheet no longer shows \(word.shownAs)")
        }
    }

    /// The iPhone's Sleep Timer sheet closes with the Mac's localized Close, not `PhoneAppWording.close`'s English
    /// (finding 4 of the pilot's review). The source is read, since the language cannot change in the test host.
    func testThePhonesSheetShowsTheMacsClose() throws {
        let sheet = try String(
            contentsOf: AppSourceFile.folder.appendingPathComponent("Platform/iOS/Views/Reader/PhoneSleepTimerSheet.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(sheet.contains("PhoneSheetButton(title: PhoneSleepTimerVocabulary.close,"))
        XCTAssertFalse(sheet.contains("PhoneAppWording.close"))
    }
}

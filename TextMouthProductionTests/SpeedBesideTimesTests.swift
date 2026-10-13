import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The setting that names the speed beside time left and total time (P08,
/// the user's answer 18: "Maybe, maybe a setting for more info, make sure it
/// works on both audio and text."). It is off by default, and while it is
/// off every surface reads as before. With it on, an audiobook not at 1x
/// names its speed ("3:44:01 left at 2.0x", "remaining at 2.0 times
/// speed"), and a text book its words a minute ("at 500 words a minute"),
/// on the reader's status row, in the Headings sheet's durations, in Where
/// Am I? (brief and full), and in Copy Reading Position's time left.
/// config.json carries it as "includeSpeedWithTimes". Pure: readers from
/// `RecordingTimeFixtures`, settings on preferences of the test's own.
@MainActor
final class SpeedBesideTimesTests: XCTestCase {
    private typealias Fixtures = RecordingTimeFixtures

    // MARK: - The Setting

    /// The setting is off until it is turned on, and config.json carries
    /// it: a file that names it sets it, and a file without it leaves it
    /// alone.
    func testTheSettingIsOffByDefaultAndConfigCarriesIt() throws {
        let settings = makeSettings("recordingtime-speed-default")
        XCTAssertFalse(settings.includeSpeedWithTimes)

        let named = try JSONDecoder().decode(ConfigService.AppConfig.self, from: Data(#"{"includeSpeedWithTimes": true}"#.utf8))
        XCTAssertEqual(named.includeSpeedWithTimes, true)
        let without = try JSONDecoder().decode(ConfigService.AppConfig.self, from: Data(#"{"autoPlayOnNavigate": true}"#.utf8))
        XCTAssertNil(without.includeSpeedWithTimes)
        XCTAssertTrue(ConfigService.AppConfig.Portability.mirrored.contains {
            $0.storeKey == "includeSpeedWithTimes" && $0.field == "includeSpeedWithTimes"
        })
    }

    /// The setting's words, pinned.
    func testTheSettingsWordsAreFixed() {
        XCTAssertEqual(ReaderTimeWording.settingTitle, "Include the speed with time left and total time")
        XCTAssertEqual(ReaderTimeWording.settingSection, "Times")
        XCTAssertEqual(
            ReaderTimeWording.settingHint,
            "Adds the speed they count at, such as 2.0x for an audiobook not at 1x, or 500 words a minute for a text book, "
                + "in the reader, Where Am I?, Copy Reading Position, and the Headings sheet's durations."
        )
    }

    /// The setting's checkbox is in Playback settings, named plainly, with
    /// what it does as its hint, unchecked until it is turned on. Hosted in
    /// a frame of its own fixed size, tall enough for every section. SwiftUI
    /// builds a checkbox's accessibility element only for a connected
    /// assistive app, so where none is exposed the test is skipped; its
    /// words are pinned without a window above.
    func testTheSettingsCheckboxIsInPlaybackSettings() throws {
        try skipUnlessHostedWindowsExposeAccessibility()
        let settings = makeSettings("recordingtime-speed-tab")
        let size = NSSize(width: 600, height: 1800)
        try withHostedView(
            PlaybackSettingsView().environmentObject(settings).frame(width: size.width, height: size.height),
            size: size,
            // The tab is drawn once its fade-out stepper, which AppKit
            // exposes itself, is there.
            until: { hostingView in
                self.accessibleControls(in: hostingView).contains { $0.role == .incrementor }
            }
        ) { hostingView in
            let checkboxes = accessibleControls(in: hostingView).filter { $0.role == .checkBox }
            guard !checkboxes.isEmpty else {
                throw XCTSkip("This session exposes no SwiftUI checkbox in a hosted window")
            }
            let checkbox = try XCTUnwrap(
                checkboxes.first { $0.label == ReaderTimeWording.settingTitle },
                "the setting's checkbox was not drawn among \(checkboxes.map(\.label))"
            )
            XCTAssertEqual(checkbox.role, .checkBox)
            XCTAssertEqual(checkbox.hint, ReaderTimeWording.settingHint)
            XCTAssertEqual((checkbox.element.accessibilityValue() as? NSNumber)?.boolValue, false)
        }
    }

    // MARK: - The Words

    /// With the setting off, the status row's time left and total read as
    /// they always have, shown and spoken.
    func testWithTheSettingOffTheTimesReadAsBefore() {
        XCTAssertEqual(ReaderTimeWording.timeLeftShown("3:44:01", nil), "3:44:01 left")
        XCTAssertEqual(ReaderTimeWording.timeLeftSpoken(13_441, nil), "3 hours, 44 minutes, 1 second remaining at current speed")
        XCTAssertEqual(ReaderTimeWording.totalShown("4:50:33", nil), "Total: 4:50:33")
        XCTAssertEqual(ReaderTimeWording.totalSpoken(17_433, nil), "Total time: 4 hours, 50 minutes, 33 seconds")
        XCTAssertEqual(ReaderTimeWording.shownSpeed(nil), "")
        XCTAssertEqual(ReaderTimeWording.spokenSpeed(nil), "")
    }

    /// With it on, an audiobook not at 1x names its speed beside its time
    /// left and its total, shown as on its speed control and spoken in
    /// words.
    func testAnAudiobookNotAtNormalSpeedNamesIt() {
        let speed = ReaderTimeWording.ListeningSpeed.audio(2)
        XCTAssertEqual(ReaderTimeWording.timeLeftShown("3:44:01", speed), "3:44:01 left at 2.0x")
        XCTAssertEqual(
            ReaderTimeWording.timeLeftSpoken(13_441, speed),
            "3 hours, 44 minutes, 1 second remaining at 2.0 times speed"
        )
        XCTAssertEqual(ReaderTimeWording.totalShown("4:50:33", speed), "Total: 4:50:33 at 2.0x")
        XCTAssertEqual(
            ReaderTimeWording.totalSpoken(17_433, speed),
            "Total time: 4 hours, 50 minutes, 33 seconds at 2.0 times speed"
        )
        XCTAssertEqual(ReaderTimeWording.shownSpeed(.audio(1.25)), " at 1.25x")
        XCTAssertEqual(ReaderTimeWording.spokenSpeed(.audio(0.5)), " at 0.5 times speed")
    }

    /// An audiobook at 1x, which its times already are, names nothing even
    /// with the setting on; a speed a hair from 1x snaps to it, as the
    /// player snaps it.
    func testAnAudiobookAtNormalSpeedReadsAsBefore() {
        let speed = ReaderTimeWording.ListeningSpeed.audio(1)
        XCTAssertEqual(ReaderTimeWording.timeLeftShown("3:44:01", speed), "3:44:01 left")
        XCTAssertEqual(ReaderTimeWording.timeLeftSpoken(13_441, speed), "3 hours, 44 minutes, 1 second remaining at current speed")
        XCTAssertEqual(ReaderTimeWording.totalShown("4:50:33", speed), "Total: 4:50:33")
        XCTAssertEqual(ReaderTimeWording.totalSpoken(17_433, speed), "Total time: 4 hours, 50 minutes, 33 seconds")
        XCTAssertEqual(ReaderTimeWording.shownSpeed(.audio(1.000_000_1)), "")
    }

    /// With it on, a text book names its words a minute beside its time
    /// left and total, shown and spoken alike.
    func testATextBookNamesItsWordsAMinute() {
        let speed = ReaderTimeWording.ListeningSpeed.words(perMinute: 500)
        XCTAssertEqual(ReaderTimeWording.timeLeftShown("2:10:24", speed), "2:10:24 left at 500 words a minute")
        XCTAssertEqual(
            ReaderTimeWording.timeLeftSpoken(7_824, speed),
            "2 hours, 10 minutes, 24 seconds remaining at 500 words a minute"
        )
        XCTAssertEqual(ReaderTimeWording.totalShown("4:20:49", speed), "Total: 4:20:49 at 500 words a minute")
        XCTAssertEqual(
            ReaderTimeWording.totalSpoken(15_649, speed),
            "Total time: 4 hours, 20 minutes, 49 seconds at 500 words a minute"
        )
    }

    // MARK: - The Reader

    /// The reader names no speed while the setting is off, whatever its
    /// speed; turned on, it names an audiobook's speed and a text book's
    /// words a minute, following each as it changes.
    func testTheReaderNamesItsSpeedOnlyWithTheSettingOn() throws {
        let settings = makeSettings("recordingtime-speed-reader")
        let audio = Fixtures.makeReader(format: .audio, settings: settings)
        defer { audio.close() }
        audio.content = try Fixtures.audioContent(.oneFile)
        audio.audioSpeed = 2
        let text = Fixtures.makeReader(format: .txt, settings: settings)
        defer { text.close() }
        text.content = Fixtures.textContent()
        text.speechService.wordsPerMinute = 500

        XCTAssertNil(audio.namedListeningSpeed)
        XCTAssertNil(text.namedListeningSpeed)

        settings.includeSpeedWithTimes = true
        XCTAssertEqual(audio.namedListeningSpeed, .audio(2))
        XCTAssertEqual(text.namedListeningSpeed, .words(perMinute: 500))
        audio.audioSpeed = 1.5
        text.speechService.wordsPerMinute = 200
        XCTAssertEqual(audio.namedListeningSpeed, .audio(1.5))
        XCTAssertEqual(text.namedListeningSpeed, .words(perMinute: 200))
    }

    /// The Headings sheet's durations name the speed only with the setting
    /// on: as before while it is off; "at 2.0x", shown, and "at 2.0 times
    /// speed", spoken, at 2x; nothing more at 1x; "at 500 words a minute"
    /// for a text book. Its time into the book, a place, never names one.
    func testTheHeadingsSheetsDurationsNameTheSpeedWithTheSettingOn() throws {
        let settings = makeSettings("recordingtime-speed-headings")
        let audio = Fixtures.makeReader(format: .audio, settings: settings)
        defer { audio.close() }
        audio.content = try Fixtures.audioContent(.filePerChapter)
        audio.audioSpeed = 2

        let durationsOff = rows(of: audio, mode: .timeEstimate)
        let timesInOff = rows(of: audio, mode: .timeIntoBook)
        XCTAssertFalse(durationsOff.isEmpty)
        for row in durationsOff {
            XCTAssertFalse(row.infoText.contains(" at "), row.infoText)
            XCTAssertFalse(row.accessibilitySuffix.contains(" at "), row.accessibilitySuffix)
        }

        settings.includeSpeedWithTimes = true
        let durationsOn = rows(of: audio, mode: .timeEstimate)
        for (on, off) in zip(durationsOn, durationsOff) {
            XCTAssertEqual(on.infoText, off.infoText + " at 2.0x")
            XCTAssertEqual(on.accessibilitySuffix, off.accessibilitySuffix + " at 2.0 times speed")
        }
        XCTAssertEqual(rows(of: audio, mode: .timeIntoBook), timesInOff)

        audio.audioSpeed = 1
        for row in rows(of: audio, mode: .timeEstimate) {
            XCTAssertFalse(row.infoText.contains(" at "), row.infoText)
        }

        let text = Fixtures.makeReader(format: .txt, settings: settings)
        defer { text.close() }
        text.content = Fixtures.textContent()
        text.speechService.wordsPerMinute = 500
        for row in rows(of: text, mode: .timeEstimate) {
            XCTAssertTrue(row.infoText.hasSuffix(" at 500 words a minute"), row.infoText)
            XCTAssertTrue(row.accessibilitySuffix.hasSuffix(" at 500 words a minute"), row.accessibilitySuffix)
        }
    }

    /// While the setting is off, Where Am I? (brief and full) and Copy
    /// Reading Position read as before; with it on, each names the speed
    /// beside the book's time left, and the full Where Am I? beside the
    /// total too, while the time left in the heading, said just after the
    /// book's, names none. An audiobook at 1x reads as before.
    func testWhereAmIAndTheCopiedPositionNameTheSpeedWithTheSettingOn() {
        let heading = Fixtures.headingPosition(number: 26, of: 412)
        let brief = { (speed: ReaderTimeWording.ListeningSpeed?) in
            ReaderViewModel.briefWhereAmISummary(
                bookTitle: "Dune",
                locationTitle: "The Battle",
                headingPosition: heading,
                percentComplete: 22.9,
                timeRemaining: 13_441,
                speed: speed
            )
        }
        XCTAssertEqual(brief(nil), "Dune. The Battle. Heading 26 of 412. 23 percent. 3 hours, 44 minutes, 1 second remaining.")
        XCTAssertEqual(brief(.audio(1)), brief(nil))
        XCTAssertEqual(
            brief(.audio(2)),
            "Dune. The Battle. Heading 26 of 412. 23 percent. 3 hours, 44 minutes, 1 second remaining at 2.0 times speed."
        )
        XCTAssertEqual(
            brief(.words(perMinute: 500)),
            "Dune. The Battle. Heading 26 of 412. 23 percent. 3 hours, 44 minutes, 1 second remaining at 500 words a minute."
        )

        let full = { (speed: ReaderTimeWording.ListeningSpeed?) in
            ReaderViewModel.fullWhereAmISummary(
                bookTitle: "Dune",
                locationTitle: "The Battle",
                headingPosition: heading,
                percentComplete: 22.9,
                timeRemaining: 13_441,
                timeRemainingInHeading: 600,
                totalTime: 17_433,
                speed: speed
            )
        }
        XCTAssertEqual(
            full(nil),
            "Dune. The Battle. Heading 26 of 412. 23 percent through the book. 3 hours, 44 minutes, 1 second remaining. "
                + "10 minutes remaining in this heading. Total book time: 4 hours, 50 minutes, 33 seconds."
        )
        XCTAssertEqual(
            full(.audio(2)),
            "Dune. The Battle. Heading 26 of 412. 23 percent through the book. "
                + "3 hours, 44 minutes, 1 second remaining at 2.0 times speed. 10 minutes remaining in this heading. "
                + "Total book time: 4 hours, 50 minutes, 33 seconds at 2.0 times speed."
        )

        let copied = { (speed: ReaderTimeWording.ListeningSpeed?) in
            ReaderViewModel.readingPositionSummary(
                bookTitle: "Dune",
                author: "Frank Herbert",
                locationTitle: "The Battle",
                headingPosition: heading,
                percentComplete: 22.9,
                formattedTimeRemaining: "3:44:01",
                speed: speed
            )
        }
        XCTAssertEqual(copied(nil), "Dune | by Frank Herbert | The Battle | Heading 26 of 412 | 22.9% through | 3:44:01 remaining")
        XCTAssertEqual(copied(.audio(1)), copied(nil))
        XCTAssertEqual(
            copied(.audio(2)),
            "Dune | by Frank Herbert | The Battle | Heading 26 of 412 | 22.9% through | 3:44:01 remaining at 2.0x"
        )
        XCTAssertEqual(
            copied(.words(perMinute: 500)),
            "Dune | by Frank Herbert | The Battle | Heading 26 of 412 | 22.9% through | 3:44:01 remaining at 500 words a minute"
        )
    }

    /// A reader names its speed in Where Am I? and the copied position only
    /// with the setting on, and a finished book says only that it is.
    func testTheReadersSummariesFollowTheSetting() throws {
        let settings = makeSettings("recordingtime-speed-summaries")
        let reader = Fixtures.makeReader(format: .audio, settings: settings)
        defer { reader.close() }
        reader.content = try Fixtures.audioContent(.oneFile)
        reader.audioSpeed = 2
        reader.currentCharacterOffset = 79_850

        XCTAssertFalse(reader.buildBriefWhereAmI().contains("times speed"), reader.buildBriefWhereAmI())
        XCTAssertFalse(reader.readingPositionText.contains("remaining at"), reader.readingPositionText)
        settings.includeSpeedWithTimes = true
        XCTAssertTrue(reader.buildBriefWhereAmI().hasSuffix("remaining at 2.0 times speed."), reader.buildBriefWhereAmI())
        XCTAssertTrue(reader.readingPositionText.hasSuffix("remaining at 2.0x"), reader.readingPositionText)

        let finished = ReaderViewModel.readingPositionSummary(
            bookTitle: "Dune",
            author: "Frank Herbert",
            locationTitle: "Appendix",
            headingPosition: Fixtures.headingPosition(number: 40, of: 40),
            percentComplete: 100,
            formattedTimeRemaining: "0:00",
            isFinished: true,
            speed: .audio(2)
        )
        XCTAssertEqual(finished, "Dune | by Frank Herbert | Appendix | Heading 40 of 40 | \(EndOfBookWording.finishedProgress)")
    }

    // MARK: - The Sheet Follows A Speed Change

    /// An audiobook's timing changes when its speed does, so the open
    /// Headings sheet rebuilds its Durations, and stays the same while
    /// nothing it depends on moves.
    func testTheRowTimingFollowsAnAudiobooksSpeed() throws {
        let audio = Fixtures.makeReader(format: .audio, settings: makeSettings("recordingtime-speed-timing-audio"))
        defer { audio.close() }
        audio.content = try Fixtures.audioContent(.oneFile)
        audio.audioSpeed = 1

        let normal = HeadingNavigatorView.RowTiming(of: audio)
        XCTAssertEqual(HeadingNavigatorView.RowTiming(of: audio), normal, "An unchanged reader changed its timing")
        audio.audioSpeed = 2
        let fast = HeadingNavigatorView.RowTiming(of: audio)
        XCTAssertNotEqual(fast, normal, "A new audio speed left the timing alone")
        XCTAssertEqual(fast.listeningSpeed, 2)
        audio.audioSpeed = 1
        XCTAssertEqual(HeadingNavigatorView.RowTiming(of: audio), normal, "The timing did not return with the speed")
    }

    /// A text book's timing changes when its words a minute do, and hears
    /// its lengths at 1 whatever they are (its clock counts the words).
    func testTheRowTimingFollowsATextBooksWordsAMinute() {
        let text = Fixtures.makeReader(format: .txt, settings: makeSettings("recordingtime-speed-timing-text"))
        defer { text.close() }
        text.content = Fixtures.textContent()
        text.speechService.wordsPerMinute = 200

        let slow = HeadingNavigatorView.RowTiming(of: text)
        text.speechService.wordsPerMinute = 500
        let fast = HeadingNavigatorView.RowTiming(of: text)
        XCTAssertNotEqual(fast, slow, "New words a minute left the timing alone")
        XCTAssertEqual(slow.listeningSpeed, 1)
        XCTAssertEqual(fast.listeningSpeed, 1)
        XCTAssertEqual(fast.count, .words(perMinute: 500))
    }

    /// Flipping the setting that names the speed changes the timing, for an
    /// audiobook and for a text book; a setting that has nothing to do with
    /// times does not. The settings are the test's own.
    func testTheRowTimingFollowsTheSettingAndNoOtherSetting() throws {
        let settings = makeSettings("recordingtime-speed-timing-setting")
        let audio = Fixtures.makeReader(format: .audio, settings: settings)
        defer { audio.close() }
        audio.content = try Fixtures.audioContent(.oneFile)
        audio.audioSpeed = 2
        let text = Fixtures.makeReader(format: .txt, settings: settings)
        defer { text.close() }
        text.content = Fixtures.textContent()
        text.speechService.wordsPerMinute = 500

        let audioOff = HeadingNavigatorView.RowTiming(of: audio)
        let textOff = HeadingNavigatorView.RowTiming(of: text)
        XCTAssertNil(audioOff.namedSpeed)
        XCTAssertNil(textOff.namedSpeed)

        settings.includeSpeedWithTimes = true
        defer { settings.includeSpeedWithTimes = false }
        XCTAssertEqual(HeadingNavigatorView.RowTiming(of: audio).namedSpeed, .audio(2))
        XCTAssertNotEqual(HeadingNavigatorView.RowTiming(of: audio), audioOff)
        XCTAssertEqual(HeadingNavigatorView.RowTiming(of: text).namedSpeed, .words(perMinute: 500))
        XCTAssertNotEqual(HeadingNavigatorView.RowTiming(of: text), textOff)

        let audioOn = HeadingNavigatorView.RowTiming(of: audio)
        settings.showSpeedInPlaybackControls.toggle()
        XCTAssertEqual(HeadingNavigatorView.RowTiming(of: audio), audioOn, "A setting unrelated to times changed the timing")
    }

    /// The sheet's snapshot of its reader changes when the speed does, so
    /// the snapshot republishes and the sheet hears it.
    func testTheSheetsReaderStateChangesWithTheSpeed() throws {
        let audio = Fixtures.makeReader(format: .audio, settings: makeSettings("recordingtime-speed-state-audio"))
        defer { audio.close() }
        audio.content = try Fixtures.audioContent(.oneFile)
        audio.audioSpeed = 1
        let atNormal = HeadingNavigatorView.ReaderState(of: audio)
        XCTAssertEqual(HeadingNavigatorView.ReaderState(of: audio), atNormal, "An unchanged reader changed its state")
        audio.audioSpeed = 2
        XCTAssertNotEqual(HeadingNavigatorView.ReaderState(of: audio), atNormal)

        let text = Fixtures.makeReader(format: .txt, settings: makeSettings("recordingtime-speed-state-text"))
        defer { text.close() }
        text.content = Fixtures.textContent()
        text.speechService.wordsPerMinute = 200
        let slow = HeadingNavigatorView.ReaderState(of: text)
        text.speechService.wordsPerMinute = 500
        XCTAssertNotEqual(HeadingNavigatorView.ReaderState(of: text), slow)
    }

    // MARK: - Helpers

    /// Settings without services, on preferences of this test's own, so a
    /// setting turned on here reaches no other test.
    private func makeSettings(_ label: String) -> SettingsViewModel {
        SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: makeSandboxedPreferences(label)
        )
    }

    /// The Headings sheet's rows for `reader`'s headings in `mode`, each
    /// shown.
    private func rows(
        of reader: ReaderViewModel,
        mode: HeadingNavigatorView.HeadingDisplayMode
    ) -> [HeadingNavigatorView.HeadingListItem] {
        let headings = reader.content?.allHeadings ?? []
        return HeadingNavigatorView.headingItems(
            for: reader,
            displayed: headings,
            allHeadings: headings,
            skippedIDs: [],
            mode: mode
        )
    }
}

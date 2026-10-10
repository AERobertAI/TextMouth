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
/// on the reader's status row and in the Headings sheet's durations.
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

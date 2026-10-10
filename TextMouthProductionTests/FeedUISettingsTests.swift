import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The Feeds tab of Preferences (FR03): the seven feed settings, each a
/// labelled control, the three numbers with their units in their words and
/// their off values as checkboxes, saved to the preferences store within
/// the settings' ranges; and Refresh All Feeds Now, from the tab and the
/// Library menu, saying what came. The settings live in a sandboxed store.
@MainActor
final class FeedUISettingsTests: XCTestCase {

    // MARK: - The Words

    /// Each number's caption says the setting and its value with its unit,
    /// or what its off value means.
    func testEachNumberSaysItsValueWithItsUnit() {
        let delete = FeedThresholdWording.deleteDownloadsAfterPlaying
        let rule = SettingsPolicy.feedDeleteDownloadsDaysAfterPlayed
        XCTAssertEqual(delete.caption(1, rule: rule), "Delete downloads after playing: 1 day")
        XCTAssertEqual(delete.caption(7, rule: rule), "Delete downloads after playing: 7 days")
        XCTAssertEqual(delete.caption(0, rule: rule), "Delete downloads after playing: at once")
        XCTAssertEqual(delete.caption(-1, rule: rule), "Delete downloads after playing: never")
        XCTAssertEqual(delete.offTitle, "Never delete played downloads")

        let keep = FeedThresholdWording.keepEntries
        XCTAssertEqual(keep.caption(10, rule: SettingsPolicy.feedKeepEntries), "Keep the newest: 10 entries")
        XCTAssertEqual(keep.caption(1, rule: SettingsPolicy.feedKeepEntries), "Keep the newest: 1 entry")
        XCTAssertEqual(keep.caption(-1, rule: SettingsPolicy.feedKeepEntries), "Keep the newest: every entry")

        let interval = FeedThresholdWording.refreshInterval
        XCTAssertEqual(interval.caption(1, rule: SettingsPolicy.feedRefreshIntervalHours), "Refresh feeds every: 1 hour")
        XCTAssertEqual(interval.caption(6, rule: SettingsPolicy.feedRefreshIntervalHours), "Refresh feeds every: 6 hours")
        XCTAssertEqual(
            interval.caption(0, rule: SettingsPolicy.feedRefreshIntervalHours),
            "Refresh feeds every: only at launch and when you ask"
        )
    }

    /// Checking a number's off checkbox stores its off value, while the
    /// field and stepper keep showing the last number, which unchecking the
    /// box stores again; the number remembered as the control opens is the
    /// value, or the default while the setting is off.
    func testTheOffCheckboxStoresTheOffValueAndRestoresTheLastNumber() {
        let delete = SettingsPolicy.feedDeleteDownloadsDaysAfterPlayed
        XCTAssertEqual(FeedThresholdControl.value(off: true, remembering: 30, rule: delete), -1)
        XCTAssertEqual(FeedThresholdControl.value(off: false, remembering: 30, rule: delete), 30)
        XCTAssertEqual(FeedThresholdControl.shownNumber(-1, remembering: 30, rule: delete), 30)
        XCTAssertEqual(FeedThresholdControl.shownNumber(0, remembering: 30, rule: delete), 0, "0, at once, is a number, not off")
        XCTAssertTrue(FeedThresholdControl.isOff(-5, rule: delete), "a number below the off value is off")
        XCTAssertEqual(FeedThresholdControl.onValue(-1, rule: delete), delete.defaultValue)
        XCTAssertEqual(FeedThresholdControl.onValue(30, rule: delete), 30)

        // The interval's off value is 0: refreshing only at launch and when
        // the listener asks.
        let interval = SettingsPolicy.feedRefreshIntervalHours
        XCTAssertTrue(FeedThresholdControl.isOff(0, rule: interval))
        XCTAssertEqual(FeedThresholdControl.value(off: true, remembering: 6, rule: interval), 0)
        XCTAssertEqual(FeedThresholdControl.shownNumber(0, remembering: 6, rule: interval), 6)
    }

    /// Every setting saves through the settings model within its range: a
    /// number below the off value is the off value, and one above the range
    /// its top.
    func testTheSettingsSaveWithinTheirRanges() {
        let store = makeSandboxedPreferences("FeedUISettingsRanges")
        let settings = makeSettings(store)
        XCTAssertEqual(settings.feedSettings, .standard)

        var changed = settings.feedSettings
        changed.keepEntries = 5_000
        changed.deleteDownloadsDaysAfterPlayed = -5
        changed.refreshIntervalHours = 500
        changed.autoDownload = true
        changed.refreshAlert = true
        changed.notifications = true
        changed.refreshAtLaunch = false
        settings.feedSettings = changed

        let saved = FeedSettings.read(from: store)
        XCTAssertEqual(saved.keepEntries, SettingsPolicy.feedKeepEntries.range.upperBound)
        XCTAssertEqual(saved.deleteDownloadsDaysAfterPlayed, -1)
        XCTAssertEqual(saved.refreshIntervalHours, 168)
        XCTAssertTrue(saved.autoDownload)
        XCTAssertTrue(saved.refreshAlert)
        XCTAssertTrue(saved.notifications)
        XCTAssertFalse(saved.refreshAtLaunch)

        changed.refreshIntervalHours = -3
        settings.feedSettings = changed
        XCTAssertEqual(FeedSettings.read(from: store).refreshIntervalHours, 0)
        XCTAssertNil(FeedSettings.read(from: store).refreshInterval)
    }

    // MARK: - The Tab as Drawn

    /// The tab draws, for each number, a number field wide enough for it and
    /// a stepper speaking it with its unit; the "List and download" pop-up
    /// menu (FR11; `FeedItemUIPolicyControlsTests` checks what it says and
    /// saves); and a checkbox for each switch and each off value, showing
    /// the settings. Its steppers save what VoiceOver's increment does with
    /// them, and while a number is off, its stepper is dimmed and keeps
    /// saying the number unchecking restores. A setting changed while the
    /// tab is open, as config.json changes it, never asks permission for
    /// notifications.
    ///
    /// SwiftUI's checkboxes take no press from a test: they have no action
    /// of their own, and join the accessibility tree only for a connected
    /// assistive app. So, as the Repeated Symbols tests do, the test stores
    /// what checking or unchecking each box stores, computed as its binding
    /// computes it, and checks that the tab shows it.
    func testTheTabDrawsLabelledControlsThatSave() throws {
        let settings = makeSettings(makeSandboxedPreferences("FeedUISettingsDrawn"))
        let world = try FeedTestWorld(self, label: "FeedUISettingsDrawnWorld")
        // Notifications not yet asked about: asking would count a request.
        let notifier = FakeFeedNotifier(authorization: .notDetermined, answer: .denied)
        let view = FeedSettingsView(center: world.center, announce: { _ in }, notifier: notifier)
            .environmentObject(settings)

        withHostedView(view, size: NSSize(width: 700, height: 800), until: {
            self.descendants(of: $0, as: NSStepper.self).count == 3
        }) { hosting in
            // The refresh interval, how many of the newest, and the days
            // before deleting played downloads.
            XCTAssertEqual(descendants(of: hosting, as: NSStepper.self).count, 3)
            XCTAssertEqual(feedEditableFields(in: hosting).count, 3, "a number field for each number")
            XCTAssertEqual(descendants(of: hosting, as: NSPopUpButton.self).count, 1, "no List and download pop-up menu")
            XCTAssertTrue(
                waitUntil {
                    hosting.layoutSubtreeIfNeeded()
                    return feedEditableFields(in: hosting).allSatisfy { $0.frame.width >= 40 }
                },
                "a number field too narrow for its number: \(feedEditableFields(in: hosting).map(\.frame.width))"
            )
            // In reading order: refresh at launch; only at launch and when I
            // ask; never delete played downloads; the alert; notifications.
            XCTAssertEqual(feedCheckboxes(in: hosting).map { $0.state == .on }, [true, false, false, false, false])

            // Each stepper, found by its spoken label, says its number with
            // its unit; raised by one as VoiceOver raises it, it saves its
            // own number one higher.
            let controls = accessibleControls(in: hosting)
            @MainActor func stepper(_ wording: FeedThresholdWording) -> NSAccessibilityProtocol? {
                controls.first { $0.role == .incrementor && $0.label == wording.label }?.element
            }
            if !controls.isEmpty {
                XCTAssertEqual(stepper(.refreshInterval)?.accessibilityValueDescription(), "1 hour", "\(controls.map(\.label))")
                XCTAssertEqual(stepper(.deleteDownloadsAfterPlaying)?.accessibilityValueDescription(), "1 day")
                for wording in [FeedThresholdWording.refreshInterval, .deleteDownloadsAfterPlaying] {
                    _ = stepper(wording)?.accessibilityPerformIncrement()
                }
                XCTAssertTrue(
                    waitUntil {
                        settings.feedSettings.refreshIntervalHours == 2
                            && settings.feedSettings.deleteDownloadsDaysAfterPlayed == 2
                    },
                    "the steppers saved \(settings.feedSettings)"
                )
            }
            let numbers = settings.feedSettings

            // Every box pressed, as its binding stores it: each switch turned
            // over, and each number's off value stored.
            var pressed = numbers
            pressed.refreshAtLaunch.toggle()
            pressed.refreshAlert.toggle()
            pressed.notifications.toggle()
            pressed.refreshIntervalHours = Self.stored(off: true, numbers, \.refreshIntervalHours, SettingsPolicy.feedRefreshIntervalHours)
            pressed.deleteDownloadsDaysAfterPlayed = Self.stored(
                off: true, numbers, \.deleteDownloadsDaysAfterPlayed, SettingsPolicy.feedDeleteDownloadsDaysAfterPlayed
            )
            settings.feedSettings = pressed
            XCTAssertTrue(
                waitUntil {
                    hosting.layoutSubtreeIfNeeded()
                    return feedCheckboxes(in: hosting).map { $0.state == .on } == [false, true, true, true, true]
                },
                "the checkboxes show \(feedCheckboxes(in: hosting).map { $0.state == .on })"
            )
            if !controls.isEmpty {
                XCTAssertTrue(waitUntil { stepper(.deleteDownloadsAfterPlaying)?.isAccessibilityEnabled() == false }, "a stepper stayed available while off")
                XCTAssertEqual(
                    stepper(.refreshInterval)?.accessibilityValueDescription(),
                    FeedThresholdWording.refreshInterval.valuePhrase(numbers.refreshIntervalHours),
                    "a stepper forgot the number unchecking restores"
                )
            }

            // The off boxes unchecked again: each number comes back.
            var unchecked = pressed
            unchecked.refreshIntervalHours = Self.stored(off: false, numbers, \.refreshIntervalHours, SettingsPolicy.feedRefreshIntervalHours)
            unchecked.deleteDownloadsDaysAfterPlayed = Self.stored(
                off: false, numbers, \.deleteDownloadsDaysAfterPlayed, SettingsPolicy.feedDeleteDownloadsDaysAfterPlayed
            )
            settings.feedSettings = unchecked
            XCTAssertTrue(
                waitUntil {
                    hosting.layoutSubtreeIfNeeded()
                    return feedCheckboxes(in: hosting).map { $0.state == .on } == [false, false, false, true, true]
                },
                "the checkboxes show \(feedCheckboxes(in: hosting).map { $0.state == .on })"
            )
            if !controls.isEmpty {
                XCTAssertTrue(waitUntil { stepper(.deleteDownloadsAfterPlaying)?.isAccessibilityEnabled() == true }, "a stepper stayed dimmed")
            }
            XCTAssertEqual(notifier.requests, 0, "notifications turned on elsewhere asked for permission")
        }
    }

    /// What a number's off checkbox stores as it becomes `off`, for the
    /// number at `keyPath` in `numbers`, the last number before it.
    private static func stored(
        off: Bool,
        _ numbers: FeedSettings,
        _ keyPath: KeyPath<FeedSettings, Int>,
        _ rule: ThresholdSettingRule
    ) -> Int {
        FeedThresholdControl.value(off: off, remembering: numbers[keyPath: keyPath], rule: rule)
    }

    // MARK: - Refresh All Feeds

    /// Refresh All Feeds says it started, then how many feeds it refreshed,
    /// how many new items came, and which feeds failed; with no feeds it
    /// says so.
    func testRefreshAllFeedsSaysWhatCame() async throws {
        let world = try FeedTestWorld(self, label: "FeedUIRefreshAll")
        var heard: [String] = []

        await world.start()
        await world.center.refreshAllSaying { heard.append($0) }
        XCTAssertEqual(heard, [FeedSettingsWording.refreshing, "There are no feeds to refresh."])

        let first = FeedXML.Item(guid: "ep-1", title: "The first visit", published: world.day(-3), enclosure: "https://atlas.example/1.mp3")
        world.server.serve("/atlas.xml", .feed(FeedXML.rss(title: "The Tactile Atlas", items: [first])))
        world.server.serve("/notes.xml", .feed(FeedXML.rss(title: "Harbour Notes", items: [first])))
        _ = try await world.subscribe("/atlas.xml")
        _ = try await world.center.subscribe(to: world.server.url("/notes.xml").absoluteString, into: .folder(world.bookFolder.id))
        let newer = FeedXML.Item(guid: "ep-2", title: "A map you can touch", published: world.day(1), enclosure: "https://atlas.example/2.mp3")
        world.server.serve("/atlas.xml", .feed(FeedXML.rss(title: "The Tactile Atlas", items: [newer, first])))
        world.server.serve("/notes.xml", StubResponse(status: 410))
        world.advance(by: 2 * 86_400)
        heard = []

        let presenter = LibraryFeedsPresenter()
        presenter.announce = { message, _ in heard.append(message) }
        await presenter.refreshAll(in: FeedCommandContext(center: world.center, library: world.library, window: nil)).value

        XCTAssertEqual(heard, [
            FeedSettingsWording.refreshing,
            "Refreshed 2 feeds: 1 new episode. Couldn't refresh Harbour Notes.",
        ])
    }

    // MARK: - Helpers

    /// A settings model on the sandboxed store `store`, never mirrored to
    /// config.json.
    private func makeSettings(_ store: UserDefaults) -> SettingsViewModel {
        SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: store
        )
    }
}

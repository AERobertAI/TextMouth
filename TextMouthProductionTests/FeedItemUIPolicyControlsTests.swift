import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The "List and download" pop-up menu and its number (FR11, branch C), in
/// the Feeds tab of Settings and in Feed Info: the words VoiceOver speaks
/// for the menu, its three choices, their hints, and the number; the
/// sentence VoiceOver hears once a change takes effect, ten seconds after
/// the last one; and the tab's controls as drawn, which VoiceOver finds by
/// their labels and which save what is chosen. The settings live in
/// sandboxed stores.
@MainActor
final class FeedItemUIPolicyControlsTests: XCTestCase {

    // MARK: - The Words

    /// The pop-up menu is "List and download", and each choice's title says
    /// the number in force, in Settings for every feed's items and in Feed
    /// Info for the feed's own: the user's answer to question 2, with the
    /// number's words following the number ("newest 3").
    func testTheChoicesTitlesSayTheNumberInForce() {
        XCTAssertEqual(FeedWording.listAndDownloadLabel, "List and download")
        XCTAssertEqual(FeedItemPolicy.Choice.allCases.map { FeedWording.itemPolicyTitle($0, count: 5, noun: nil) }, [
            "Every item listed, newest 5 downloaded",
            "Every item listed, downloads by hand",
            "Only the newest 5 listed",
        ])
        XCTAssertEqual(FeedWording.itemPolicyTitle(.everyListedNewestDownloaded, count: 3, noun: nil), "Every item listed, newest 3 downloaded")
        XCTAssertEqual(FeedWording.itemPolicyTitle(.onlyNewestListed, count: 1, noun: nil), "Only the newest 1 listed")
        XCTAssertEqual(FeedWording.itemPolicyTitle(FeedItemPolicy(choice: .onlyNewestListed, newestCount: 12), noun: nil), "Only the newest 12 listed")
        XCTAssertEqual(FeedWording.itemPolicyTitle(.standard, noun: nil), "Every item listed, newest 5 downloaded")

        // Feed Info names the feed's own items; a feed of both kinds has
        // items, as Settings does.
        XCTAssertEqual(FeedWording.itemPolicyTitle(.everyListedNewestDownloaded, count: 5, noun: .episode), "Every episode listed, newest 5 downloaded")
        XCTAssertEqual(FeedWording.itemPolicyTitle(.everyListedDownloadsByHand, count: 5, noun: .article), "Every article listed, downloads by hand")
        XCTAssertEqual(FeedWording.itemPolicyTitle(.everyListedNewestDownloaded, count: 2, noun: .item), "Every item listed, newest 2 downloaded")
        XCTAssertEqual(FeedWording.itemPolicyTitle(.onlyNewestListed, count: 7, noun: .episode), "Only the newest 7 listed")
    }

    /// Each choice's hint is one sentence saying what it lists, what
    /// downloads, and what becomes of the rest, with the number in force,
    /// for every feed's episodes and articles or for the feed's own items.
    /// "Only the newest" lists those of the newest not played, fewer once
    /// some are played, never the newest 5 unplayed (REV13 feeds 6).
    func testEachChoicesHintSaysWhatItDoes() {
        XCTAssertEqual(
            FeedWording.itemPolicyHint(.everyListedNewestDownloaded, count: 5, noun: nil),
            "Lists every episode and article with what you did with it, keeps the newest 5 downloaded, "
                + "and removes older downloads it made, keeping their place, bookmarks, and settings."
        )
        XCTAssertEqual(
            FeedWording.itemPolicyHint(.everyListedDownloadsByHand, count: 5, noun: nil),
            "Lists every episode and article; nothing downloads by itself, and a download stays until you delete it "
                + "or its days after playing pass."
        )
        XCTAssertEqual(
            FeedWording.itemPolicyHint(.onlyNewestListed, count: 5, noun: nil),
            "Lists those of the newest 5 you haven't played, and every download, and downloads only what you ask for; "
                + "the others keep their records and come back when you list more."
        )
        // A feed's own words: its items, and "read" for articles.
        XCTAssertEqual(
            FeedWording.itemPolicyHint(.everyListedNewestDownloaded, count: 3, noun: .episode),
            "Lists every episode with what you did with it, keeps the newest 3 downloaded, "
                + "and removes older downloads it made, keeping their place, bookmarks, and settings."
        )
        XCTAssertEqual(
            FeedWording.itemPolicyHint(.onlyNewestListed, count: 2, noun: .article),
            "Lists those of the newest 2 you haven't read, and every download, and downloads only what you ask for; "
                + "the others keep their records and come back when you list more."
        )
        XCTAssertTrue(FeedWording.itemPolicyHint(.everyListedDownloadsByHand, count: 5, noun: .item).hasPrefix("Lists every episode and article;"))
    }

    /// The number is "How many of the newest", spoken with its unit, the
    /// feed's own noun in Feed Info; it counts for the first and third
    /// choices and not under downloads by hand, where it is dimmed; and
    /// the line under the controls says a change takes effect once it has
    /// stayed unchanged for ten seconds, the engine's own wait.
    func testTheNumberIsWordedWithItsUnit() {
        XCTAssertEqual(FeedWording.newestCountLabel, "How many of the newest")
        XCTAssertEqual(FeedWording.newestCountValue(5, noun: nil), "5 items")
        XCTAssertEqual(FeedWording.newestCountValue(1, noun: nil), "1 item")
        XCTAssertEqual(FeedWording.newestCountValue(5, noun: .episode), "5 episodes")
        XCTAssertEqual(FeedWording.newestCountValue(1, noun: .article), "1 article")
        XCTAssertEqual(FeedWording.newestCountCaption(5, noun: nil), "How many of the newest: 5 items")
        XCTAssertEqual(
            FeedWording.newestCountHint(noun: nil),
            "How many of each feed's newest episodes and articles are kept downloaded, or listed, from 1 to 2,000"
        )
        XCTAssertEqual(
            FeedWording.newestCountHint(noun: .episode),
            "How many of this feed's newest episodes are kept downloaded, or listed, from 1 to 2,000"
        )
        XCTAssertEqual(SettingsPolicy.feedNewestCount.range, 1...2_000)

        XCTAssertTrue(FeedItemPolicy(choice: .everyListedNewestDownloaded, newestCount: 5).usesNewestCount)
        XCTAssertFalse(FeedItemPolicy(choice: .everyListedDownloadsByHand, newestCount: 5).usesNewestCount)
        XCTAssertTrue(FeedItemPolicy(choice: .onlyNewestListed, newestCount: 5).usesNewestCount)

        XCTAssertEqual(FeedCenter.itemPolicyQuietTime, .seconds(10))
        XCTAssertEqual(
            FeedWording.itemPolicyQuietNote,
            "The list follows a change of List and download at once; what downloads or goes "
                + "waits until the change has stayed for ten seconds, and VoiceOver announces it then."
        )
        XCTAssertEqual(
            FeedSettingsWording.perFeedNote,
            "A feed can have its own List and download choice and its own days before deleting played downloads, "
                + "in its Feed Info."
        )
    }

    /// Feed Info's "Use the global setting" checkbox names the global
    /// choice as Settings words it.
    func testFeedInfosCheckboxNamesTheGlobalChoice() {
        XCTAssertEqual(
            FeedWording.useGlobal(FeedWording.itemPolicyTitle(.standard, noun: nil)),
            "Use the global setting (Every item listed, newest 5 downloaded)"
        )
        XCTAssertEqual(
            FeedWording.useGlobal(FeedWording.itemPolicyTitle(FeedItemPolicy(choice: .onlyNewestListed, newestCount: 3), noun: nil)),
            "Use the global setting (Only the newest 3 listed)"
        )
    }

    /// What VoiceOver hears once a change takes effect: the global choice,
    /// a feed's own, worded with its items, or a feed back on the global
    /// setting, which is named as Settings words it.
    func testTheSentencesSaidWhenAChangeTakesEffect() {
        let global = FeedItemPolicy(choice: .everyListedNewestDownloaded, newestCount: 3)
        XCTAssertEqual(
            FeedWording.itemPolicyApplied(global: global),
            "List and download is now in effect: Every item listed, newest 3 downloaded."
        )
        XCTAssertEqual(
            FeedWording.itemPolicyApplied(
                feedTitle: "Finish It!",
                own: FeedItemPolicy(choice: .everyListedNewestDownloaded, newestCount: 2),
                global: global,
                noun: .episode
            ),
            "List and download for Finish It! is now in effect: Every episode listed, newest 2 downloaded."
        )
        XCTAssertEqual(
            FeedWording.itemPolicyApplied(feedTitle: "Finish It!", own: nil, global: global, noun: .episode),
            "List and download for Finish It! now follows the global setting: Every item listed, newest 3 downloaded."
        )
    }

    // MARK: - Taking Effect

    /// A change of the global number made twice within the wait is heard
    /// once, after the wait and not before, with the number it settled on;
    /// a feed's own choice is heard after its own wait, worded with its
    /// items; the feed's return to the global setting is heard too; and a
    /// feed gone during its wait is heard of no more.
    func testVoiceOverHearsWhenAChangeTakesEffect() async throws {
        let world = try FeedTestWorld(self, label: "FeedItemUIApplied", worksOnItsOwn: true)
        FeedSettings.refreshAtLaunchPreference.write(false, to: world.preferences)
        FeedSettings.refreshIntervalHoursPreference.write(0, to: world.preferences)
        // A choice that downloads by hand, so no pass downloads anything.
        FeedSettings.itemsPreference.write(.onlyNewestListed, to: world.preferences)
        let arrivals = FeedArrivals(center: world.center, notifier: InertFeedNotifier())
        var heard: [String] = []
        arrivals.announce = { heard.append($0) }
        await world.start()
        world.server.serve("/ferries.xml", .feed(FeedXML.rss(title: "Night Ferries", items: [
            FeedXML.Item(guid: "ep-1", title: "A crossing at dusk", published: world.day(-1), enclosure: "https://ferries.example/1.mp3"),
        ])))
        let feed = try await world.subscribe("/ferries.xml")
        await waitFor("the engine's own work ends") { !world.center.isSweeping }
        XCTAssertEqual(world.sleep.requestedWaits, [], "a wait started before any change")

        FeedSettings.newestCountPreference.write(1, to: world.preferences)
        await waitFor("the wait starts") { world.sleep.requestedWaits.count == 1 }
        FeedSettings.newestCountPreference.write(3, to: world.preferences)
        await waitFor("the wait starts over") { world.sleep.requestedWaits.count == 2 }
        XCTAssertEqual(heard, [], "a change was heard before it took effect")
        world.sleep.wakeOldest()
        await waitFor("the global change is heard") { !heard.isEmpty }
        XCTAssertEqual(heard, ["List and download is now in effect: Only the newest 3 listed."])

        world.center.setItemPolicy(FeedItemPolicy(choice: .everyListedDownloadsByHand, newestCount: 2), of: feed.id)
        await waitFor("the feed's wait starts") { world.sleep.requestedWaits.count == 3 }
        world.sleep.wakeOldest()
        await waitFor("the feed's change is heard") { heard.count == 2 }
        XCTAssertEqual(heard.last, "List and download for Night Ferries is now in effect: Every episode listed, downloads by hand.")

        world.center.setItemPolicy(nil, of: feed.id)
        await waitFor("the next wait starts") { world.sleep.requestedWaits.count == 4 }
        world.sleep.wakeOldest()
        await waitFor("the return to the global setting is heard") { heard.count == 3 }
        XCTAssertEqual(heard.last, "List and download for Night Ferries now follows the global setting: Only the newest 3 listed.")

        world.center.setItemPolicy(FeedItemPolicy(choice: .onlyNewestListed, newestCount: 9), of: feed.id)
        await waitFor("the last wait starts") { world.sleep.requestedWaits.count == 5 }
        // Gone, its record with it: unsubscribing keeps a feed, whose
        // rules still act, since FR11's branch D.
        world.center.store.remove(feed.id)
        world.sleep.wakeOldest()
        await waitFor("the wait ends") { !world.center.isWaitingOnItemPolicyChange }
        await waitFor("the engine's own work ends") { !world.center.isSweeping }
        XCTAssertEqual(heard.count, 3, "a feed gone during its wait was heard of: \(heard)")
        withExtendedLifetime(arrivals) {}
    }

    /// A feed's own change made within the global change's wait is heard
    /// with it, after the global setting's sentence, rather than lost under
    /// it (feed review item 20).
    func testAFeedsChangeWithinTheGlobalWaitIsHeardToo() async throws {
        let world = try FeedTestWorld(self, label: "FeedItemUIAppliedBoth", worksOnItsOwn: true)
        FeedSettings.refreshAtLaunchPreference.write(false, to: world.preferences)
        FeedSettings.refreshIntervalHoursPreference.write(0, to: world.preferences)
        // A choice that downloads by hand, so no pass downloads anything.
        FeedSettings.itemsPreference.write(.onlyNewestListed, to: world.preferences)
        let arrivals = FeedArrivals(center: world.center, notifier: InertFeedNotifier())
        var heard: [String] = []
        arrivals.announce = { heard.append($0) }
        await world.start()
        world.server.serve("/ferries.xml", .feed(FeedXML.rss(title: "Night Ferries", items: [
            FeedXML.Item(guid: "ep-1", title: "A crossing at dusk", published: world.day(-1), enclosure: "https://ferries.example/1.mp3"),
        ])))
        let feed = try await world.subscribe("/ferries.xml")
        await waitFor("the engine's own work ends") { !world.center.isSweeping }

        FeedSettings.newestCountPreference.write(3, to: world.preferences)
        await waitFor("the wait starts") { world.sleep.requestedWaits.count == 1 }
        world.center.setItemPolicy(FeedItemPolicy(choice: .everyListedDownloadsByHand, newestCount: 2), of: feed.id)
        await waitFor("the wait starts over") { world.sleep.requestedWaits.count == 2 }
        world.sleep.wakeOldest()
        await waitFor("the changes are heard") { !heard.isEmpty }

        XCTAssertEqual(heard, [
            "List and download is now in effect: Only the newest 3 listed. "
                + "List and download for Night Ferries is now in effect: Every episode listed, downloads by hand.",
        ])
        await waitFor("the engine's own work ends") { !world.center.isSweeping }
        withExtendedLifetime(arrivals) {}
    }

    // MARK: - The Tab as Drawn

    /// The Feeds tab draws the List and download pop-up menu, which
    /// VoiceOver finds by its label, hearing the choice in force as its
    /// value and the choice's sentence as its hint, with three titles that
    /// say the number; a choice made in the menu is saved; and the number's
    /// stepper says the number with its unit, saves what VoiceOver's
    /// increment does, and is dimmed while downloads are by hand.
    func testTheTabsPopUpMenuSpeaksTheChoiceAndSavesIt() throws {
        let settings = makeSettings(makeSandboxedPreferences("FeedItemUIPopUp"))
        let world = try FeedTestWorld(self, label: "FeedItemUIPopUpWorld")
        let notifier = FakeFeedNotifier(authorization: .denied, answer: .denied)
        let view = FeedSettingsView(center: world.center, announce: { _ in }, notifier: notifier)
            .environmentObject(settings)

        try withHostedView(view, size: NSSize(width: 700, height: 800), until: {
            !self.descendants(of: $0, as: NSPopUpButton.self).isEmpty && self.descendants(of: $0, as: NSStepper.self).count == 3
        }) { hosting in
            let popUp = try XCTUnwrap(descendants(of: hosting, as: NSPopUpButton.self).first)
            XCTAssertEqual(descendants(of: hosting, as: NSPopUpButton.self).count, 1, "one pop-up menu in the tab")
            XCTAssertEqual(popUp.itemTitles, [
                "Every item listed, newest 5 downloaded", "Every item listed, downloads by hand", "Only the newest 5 listed",
            ])
            XCTAssertEqual(popUp.titleOfSelectedItem, "Every item listed, newest 5 downloaded")

            // Chosen in the menu, as VoiceOver's press of a menu item
            // chooses it: the item's own action runs, as AppKit runs it
            // when the item is picked, and the choice is saved. SwiftUI
            // gives the pop-up button itself no action.
            let choices = try XCTUnwrap(popUp.menu, "the pop-up has no menu")
            choices.performActionForItem(at: 2)
            XCTAssertTrue(
                waitUntil { settings.feedSettings.itemPolicy.choice == .onlyNewestListed },
                "the choice made in the menu was not saved: \(settings.feedSettings.itemPolicy)"
            )

            let controls = accessibleControls(in: hosting)
            guard !controls.isEmpty else { return }
            @MainActor func control(_ label: String, _ role: NSAccessibility.Role) -> AccessibleControl? {
                accessibleControls(in: hosting).first { $0.role == role && $0.label == label }
            }
            let menu = try XCTUnwrap(control(FeedWording.listAndDownloadLabel, .popUpButton), "\(controls.map(\.label))")
            XCTAssertEqual(menu.element.accessibilityValue() as? String, "Only the newest 5 listed")
            // SwiftUI gives the menu the new choice's hint as it redraws,
            // on a later turn of the run loop.
            XCTAssertTrue(
                waitUntil {
                    hosting.layoutSubtreeIfNeeded()
                    return control(FeedWording.listAndDownloadLabel, .popUpButton)?.hint
                        == FeedWording.itemPolicyHint(.onlyNewestListed, count: 5, noun: nil)
                },
                "the hint did not follow the choice: \(control(FeedWording.listAndDownloadLabel, .popUpButton)?.hint ?? "none")"
            )
            let stepper = try XCTUnwrap(control(FeedWording.newestCountLabel, .incrementor), "\(controls.map(\.label))")
            XCTAssertEqual(stepper.valueDescription, "5 items")
            XCTAssertEqual(stepper.hint, FeedWording.newestCountHint(noun: nil))
            _ = stepper.element.accessibilityPerformIncrement()
            XCTAssertTrue(waitUntil { settings.feedSettings.itemPolicy.newestCount == 6 }, "the stepper saved \(settings.feedSettings.itemPolicy)")
            XCTAssertTrue(
                waitUntil {
                    hosting.layoutSubtreeIfNeeded()
                    return popUp.itemTitles.last == "Only the newest 6 listed"
                },
                "the titles did not follow the number: \(popUp.itemTitles)"
            )

            // Downloads by hand count no number: the stepper is dimmed, and
            // keeps the number for the next choice that counts.
            var byHand = settings.feedSettings
            byHand.itemPolicy.choice = .everyListedDownloadsByHand
            settings.feedSettings = byHand
            XCTAssertTrue(
                waitUntil { control(FeedWording.newestCountLabel, .incrementor)?.element.isAccessibilityEnabled() == false },
                "the number stayed available under downloads by hand"
            )
            XCTAssertEqual(control(FeedWording.newestCountLabel, .incrementor)?.valueDescription, "6 items")
            XCTAssertTrue(
                waitUntil { control(FeedWording.listAndDownloadLabel, .popUpButton)?.hint == FeedWording.itemPolicyHint(.everyListedDownloadsByHand, count: 6, noun: nil) },
                "the hint did not follow the choice"
            )
        }
    }

    // MARK: - The User's Feeds

    /// What the user's Feeds settings and two feeds' Feed Info say after
    /// this build's first launch, on records shaped like theirs
    /// (`UsersFeeds`; their settings assumed as TextMouth shipped them): the
    /// Feeds tab shows the new default, "Every item listed, newest 5
    /// downloaded", with 5 for its number; each feed uses the global
    /// setting, its pop-up menu worded with its own items, "Finish It!"'s
    /// episodes and "The Digital Antiquarian"'s mix of articles and
    /// episodes; and neither feed is in Unopened, since every item of each
    /// was published before its subscription.
    func testTheUsersFeedsAfterTheFirstLaunch() async throws {
        let world = try FeedTestWorld(self, label: "FeedItemUIUsersFeeds")
        let users = try UsersFeeds(world)
        try users.write(to: world)
        world.library.library.books.append(users.articleRow(in: world))

        await world.start()

        let global = FeedSettings.read(from: world.preferences).itemPolicy
        XCTAssertEqual(FeedWording.itemPolicyTitle(global, noun: nil), "Every item listed, newest 5 downloaded")
        XCTAssertEqual(FeedWording.newestCountCaption(global.newestCount, noun: nil), "How many of the newest: 5 items")
        XCTAssertEqual(
            FeedWording.useGlobal(FeedWording.itemPolicyTitle(global, noun: nil)),
            "Use the global setting (Every item listed, newest 5 downloaded)"
        )
        let expected: [(FeedRecord, FeedWording.ItemNoun, String)] = [
            (users.finishIt, .episode, "Every episode listed, newest 5 downloaded"),
            (users.antiquarian, .item, "Every item listed, newest 5 downloaded"),
        ]
        for (record, noun, title) in expected {
            let model = FeedInfoModel(feedID: record.feed.id, center: world.center, library: world.library)
            XCTAssertTrue(model.usesGlobalItemPolicy, "\(record.feed.title) has a choice of its own")
            XCTAssertEqual(world.center.counts(of: record.feed.id).noun, noun, record.feed.title)
            XCTAssertEqual(FeedWording.itemPolicyTitle(model.itemPolicy, noun: noun), title)
            XCTAssertEqual(FeedWording.newestCountValue(model.itemPolicy.newestCount, noun: noun), "5 \(noun.plural)")
        }
        XCTAssertEqual(world.center.counts(of: users.finishIt.feed.id).listed, 381)
        XCTAssertEqual(
            LibraryFeedsSectionRows.rows(at: LibraryLocation(category: .unopened, folderPath: ""), center: world.center),
            [],
            "a feed whose items are all its back catalogue is in Unopened"
        )
    }

    // MARK: - Helpers

    /// A settings model on the sandboxed store `store`, never mirrored to
    /// config.json.
    private func makeSettings(_ store: UserDefaults) -> SettingsViewModel {
        SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false, userDefaults: store)
    }
}

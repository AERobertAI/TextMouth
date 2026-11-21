import SwiftUI
import XCTest
@testable import TextMouth

/// Feed Info's three listening controls (FR19): what happens when an
/// episode ends, skipping the finished ones, and downloading the next one
/// before the playing one ends. The model's properties read the feed's
/// options and save through the engine, which stores nothing for the
/// standard ones; the hosted sheet draws the controls, in the feed's own
/// words, and saves a choice at once.
@MainActor
final class FeedListeningOptionsSheetTests: XCTestCase {

    // MARK: - Fixtures

    /// A world with one subscribed feed: a feed of two episodes, or, with
    /// `articles`, of two articles (items with no audio to download).
    @MainActor
    private struct Subscribed {
        let world: FeedTestWorld
        let feed: Feed

        /// The feed's record now.
        var record: FeedRecord? { world.center.store.record(of: feed.id) }
    }

    /// Subscribes to a feed of two episodes, or two articles, in a world
    /// of `label`'s own.
    private func subscribe(label: String, articles: Bool = false) async throws -> Subscribed {
        let world = try FeedTestWorld(self, label: label)
        let specs: [(guid: String, day: Double)] = [("ep-1", 1.0), ("ep-2", 0.5)]
        let items = specs.map { spec -> FeedXML.Item in
            let guid = spec.guid
            return FeedXML.Item(
                guid: guid,
                title: "Item \(guid)",
                published: world.day(spec.day),
                enclosure: articles ? nil : world.server.url("/audio/\(guid).m4a").absoluteString,
                enclosureType: "audio/mp4",
                link: "https://atlas.example/\(guid)"
            )
        }
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: items)))
        await world.start()
        let outcome = try await world.center.subscribe(
            to: world.server.url("/feed.xml").absoluteString,
            into: .newFolder(inParentPath: world.folder.path)
        )
        guard case .subscribed(let feed) = outcome else {
            throw NSError(domain: "FeedListeningOptionsSheetTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(outcome)"])
        }
        return Subscribed(world: world, feed: feed)
    }

    /// Feed Info's model for the subscribed feed, reading the global "When
    /// book ends" from `defaults`.
    private func makeModel(_ subscribed: Subscribed, defaults: UserDefaults) -> FeedInfoModel {
        FeedInfoModel(
            feedID: subscribed.feed.id,
            center: subscribed.world.center,
            library: subscribed.world.library,
            defaults: defaults
        )
    }

    /// A private preferences suite for one test, removed when it ends, with
    /// the global "When book ends" set to `behavior`.
    private func makeDefaults(_ name: String, behavior: EndOfBookBehavior = .stop) -> UserDefaults {
        let suite = "FeedListeningOptionsSheetTests.\(name)"
        // A suite name is global to the process: clear what an earlier run
        // left, and again when this test ends.
        UserDefaults().removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(behavior.rawValue, forKey: SettingsPolicy.endOfBookBehavior.key)
        return defaults
    }

    // MARK: - The Model

    /// A feed with no options of its own reads as the standard ones, and
    /// the model initializer without `defaults` still compiles, as the
    /// command runner and older tests call it.
    func testAFeedWithNoOptionsReadsAsStandard() async throws {
        let subscribed = try await subscribe(label: "FeedListeningModelStandard")
        let model = FeedInfoModel(feedID: subscribed.feed.id, center: subscribed.world.center, library: subscribed.world.library)
        XCTAssertEqual(model.listeningOptions, .standard)
        XCTAssertNil(model.episodeEnd)
        XCTAssertTrue(model.skipsFinishedEpisodes)
        XCTAssertTrue(model.predownloadsNextEpisode)
        XCTAssertNil(subscribed.record?.feed.listeningOptions)
    }

    /// Each property writes through the engine into the feed's record, and
    /// reads back what the record holds.
    func testEachPropertyWritesThroughTheEngine() async throws {
        let subscribed = try await subscribe(label: "FeedListeningModelWrites")
        let model = makeModel(subscribed, defaults: makeDefaults("Writes"))

        model.episodeEnd = .playBookAbove
        XCTAssertEqual(subscribed.record?.feed.listeningOptions, ListeningOptions(continuation: .playBookAbove))
        XCTAssertEqual(model.episodeEnd, .playBookAbove)

        model.skipsFinishedEpisodes = false
        XCTAssertEqual(
            subscribed.record?.feed.listeningOptions,
            ListeningOptions(continuation: .playBookAbove, skipsFinished: false)
        )
        XCTAssertFalse(model.skipsFinishedEpisodes)

        model.predownloadsNextEpisode = false
        XCTAssertEqual(
            subscribed.record?.feed.listeningOptions,
            ListeningOptions(continuation: .playBookAbove, skipsFinished: false, predownloadsNext: false)
        )
        XCTAssertFalse(model.predownloadsNextEpisode)
        // The other two choices stayed as they were through each write.
        XCTAssertEqual(model.episodeEnd, .playBookAbove)
        XCTAssertEqual(model.listeningOptions.skipsFinished, false)
    }

    /// Choosing the first choice, "Use the global setting", stores nil, and
    /// so does putting every choice back to its default: standard options
    /// are never stored.
    func testStandardChoicesStoreNothing() async throws {
        let subscribed = try await subscribe(label: "FeedListeningModelStandardStores")
        let model = makeModel(subscribed, defaults: makeDefaults("StandardStores"))

        model.episodeEnd = .stop
        XCTAssertNotNil(subscribed.record?.feed.listeningOptions)
        // The first choice alone, with the other two still default.
        model.episodeEnd = nil
        XCTAssertNil(subscribed.record?.feed.listeningOptions, "the first choice stored options")

        // Every choice changed, then every choice put back.
        model.episodeEnd = .playBookBelow
        model.skipsFinishedEpisodes = false
        model.predownloadsNextEpisode = false
        XCTAssertNotNil(subscribed.record?.feed.listeningOptions)
        model.episodeEnd = nil
        model.skipsFinishedEpisodes = true
        model.predownloadsNextEpisode = true
        XCTAssertNil(subscribed.record?.feed.listeningOptions, "standard options were stored")
    }

    /// The model reads the global "When book ends" from its preferences,
    /// each time it is asked.
    func testTheModelReadsTheGlobalSettingFromItsDefaults() async throws {
        let subscribed = try await subscribe(label: "FeedListeningModelGlobal")
        let defaults = makeDefaults("Global", behavior: .loop)
        let model = makeModel(subscribed, defaults: defaults)
        XCTAssertEqual(model.globalEndOfBookBehavior, .loop)
        defaults.set(EndOfBookBehavior.continueNext.rawValue, forKey: SettingsPolicy.endOfBookBehavior.key)
        XCTAssertEqual(model.globalEndOfBookBehavior, .continueNext)
    }

    /// Whether listening goes on to another episode, for every choice of
    /// the feed against every global setting: the one below or above, yes;
    /// Stop, no; and "Use the global setting", yes only for Continue to Next
    /// Book.
    func testListeningGoesOnForEveryChoiceAgainstEveryGlobalSetting() async throws {
        let subscribed = try await subscribe(label: "FeedListeningModelGoesOn")
        let defaults = makeDefaults("GoesOn")
        let model = makeModel(subscribed, defaults: defaults)

        let choices: [ReadingList.Continuation?] = [nil, .playBookBelow, .playBookAbove, .stop]
        for behavior in EndOfBookBehavior.allCases {
            defaults.set(behavior.rawValue, forKey: SettingsPolicy.endOfBookBehavior.key)
            for choice in choices {
                model.episodeEnd = choice
                let expected: Bool
                switch choice {
                case .playBookBelow, .playBookAbove: expected = true
                case .stop: expected = false
                case nil: expected = behavior == .continueNext
                }
                XCTAssertEqual(
                    model.continuesToAnotherEpisode, expected,
                    "feed \(String(describing: choice)), global \(behavior.rawValue)"
                )
            }
        }
    }

    // MARK: - The Sheet as Drawn

    /// The size Feed Info is hosted at: a little more than its own fixed
    /// 520 by 600, so no control is clipped out of the window. The sheet
    /// carries a fixed frame of its own, so it cannot outgrow the window.
    private let hostSize = NSSize(width: 560, height: 760)

    /// Feed Info for `subscribed`, with `model`, hosted until its three
    /// pop-up buttons are drawn, then handed to `body` with the hosting view.
    private func withFeedInfo(
        _ model: FeedInfoModel,
        _ subscribed: Subscribed,
        _ body: (NSView) throws -> Void
    ) rethrows {
        let sheet = FeedInfoSheet(
            model: model,
            feedFolders: LibraryFeedFolders(center: subscribed.world.center),
            requestUnsubscribe: { nil },
            onUnsubscribe: { _ in },
            onDone: {}
        )
        try withHostedView(sheet, size: hostSize, until: {
            self.descendants(of: $0, as: NSPopUpButton.self).count == 4
                && feedCheckboxes(in: $0).count == 5
        }, body)
    }

    /// The pop-up button of Feed Info that is When an episode ends: the
    /// one of four choices whose first is "Use the global setting" (Open the
    /// next episode in has three).
    private func endPopUp(in hosting: NSView) -> NSPopUpButton? {
        descendants(of: hosting, as: NSPopUpButton.self).first {
            $0.itemTitles.count == 4 && $0.itemTitles.first?.hasPrefix("Use the global setting (") == true
        }
    }

    /// The pop-up button of Feed Info that is Open the next episode in: the
    /// one of three choices whose first is "Use the global setting".
    private func windowPopUp(in hosting: NSView) -> NSPopUpButton? {
        descendants(of: hosting, as: NSPopUpButton.self).first {
            $0.itemTitles.count == 3 && $0.itemTitles.first?.hasPrefix("Use the global setting (") == true
        }
    }

    /// Feed Info draws the new pop-up with its four choices in order, the
    /// first naming the global setting, and two more checkboxes, both on
    /// and available while the global setting continues to the next episode.
    func testTheSheetDrawsTheThreeListeningControls() async throws {
        let subscribed = try await subscribe(label: "FeedListeningDrawn")
        let model = makeModel(subscribed, defaults: makeDefaults("Drawn", behavior: .continueNext))

        withFeedInfo(model, subscribed) { hosting in
            let popUp = endPopUp(in: hosting)
            XCTAssertEqual(popUp?.itemTitles, [
                "Use the global setting (Continue to Next Book)",
                "Play the episode below",
                "Play the episode above",
                "Stop",
            ])
            XCTAssertEqual(popUp?.titleOfSelectedItem, "Use the global setting (Continue to Next Book)")
            XCTAssertEqual(popUp?.isEnabled, true)

            // Two Use the global setting checkboxes and an off checkbox, then
            // the two new ones, in reading order.
            let checkboxes = feedCheckboxes(in: hosting)
            XCTAssertEqual(checkboxes.count, 5)
            XCTAssertEqual(checkboxes.dropFirst(3).map(\.state), [.on, .on], "Skip finished and Download the next are on by default")
            XCTAssertEqual(checkboxes.dropFirst(3).map(\.isEnabled), [true, true])
        }
    }

    /// Feed Info draws Open the next episode in with its three choices, the
    /// first naming the global one; it is available while the feed's episodes
    /// go on and dimmed, with its hint saying so, while they do not (0.2.5).
    func testTheWindowPopUpIsDimmedWhileEpisodesDoNotGoOn() async throws {
        let subscribed = try await subscribe(label: "FeedListeningWindow")
        let model = makeModel(subscribed, defaults: makeDefaults("Window", behavior: .continueNext))
        XCTAssertNil(model.nextEpisodeWindow)
        XCTAssertEqual(model.globalNextBookWindow, .thisWindow)

        withFeedInfo(model, subscribed) { hosting in
            let popUp = windowPopUp(in: hosting)
            XCTAssertEqual(popUp?.itemTitles, ["Use the global setting (This Window)", "This Window", "A New Window"])
            XCTAssertEqual(popUp?.isEnabled, true)
        }

        model.nextEpisodeWindow = .newWindow
        XCTAssertEqual(subscribed.record?.feed.listeningOptions, ListeningOptions(nextBookWindow: .newWindow))
        model.episodeEnd = .stop
        withFeedInfo(model, subscribed) { hosting in
            let popUp = windowPopUp(in: hosting)
            XCTAssertEqual(popUp?.titleOfSelectedItem, "A New Window", "the choice is kept while dimmed")
            XCTAssertEqual(popUp?.isEnabled, false)
            if hostedWindowsExposeAccessibility() {
                let picker = accessibleControls(in: hosting).first {
                    $0.role == .popUpButton && $0.label == "Open the next episode in"
                }
                XCTAssertEqual(picker?.hint, NextBookWindowWording.hint(.episode, enabled: false))
            }
        }
    }

    /// The pop-up shows the choice the feed has: the one above, and Stop.
    func testThePopUpShowsTheFeedsChoice() async throws {
        let subscribed = try await subscribe(label: "FeedListeningSelected")
        let model = makeModel(subscribed, defaults: makeDefaults("Selected"))

        for (choice, title) in [
            (ReadingList.Continuation.playBookAbove, "Play the episode above"),
            (.stop, "Stop"),
        ] {
            model.episodeEnd = choice
            withFeedInfo(model, subscribed) { hosting in
                XCTAssertEqual(endPopUp(in: hosting)?.titleOfSelectedItem, title)
            }
        }
    }

    /// The Download the next episode checkbox is available exactly while
    /// listening would go on to another episode, and is available again once
    /// the choice changes; its own choice is kept while it is dimmed.
    func testTheDownloadCheckboxIsAvailableExactlyWhileListeningGoesOn() async throws {
        let subscribed = try await subscribe(label: "FeedListeningDimmed")
        // The global setting stops, so a feed that follows it stops too.
        let model = makeModel(subscribed, defaults: makeDefaults("Dimmed", behavior: .stop))
        model.predownloadsNextEpisode = false

        withFeedInfo(model, subscribed) { hosting in
            @MainActor func downloadCheckbox() -> NSButton? { feedCheckboxes(in: hosting).last }
            @MainActor func isAvailable(_ expected: Bool) -> Bool {
                waitUntil {
                    hosting.layoutSubtreeIfNeeded()
                    return downloadCheckbox()?.isEnabled == expected
                }
            }
            XCTAssertTrue(isAvailable(false), "available while the feed follows a global setting that stops")
            // Dimmed, it still draws the choice it keeps.
            XCTAssertEqual(downloadCheckbox()?.state, .off)
            // Skip finished is not tied to it.
            XCTAssertEqual(feedCheckboxes(in: hosting).dropLast().last?.isEnabled, true)

            model.episodeEnd = .playBookBelow
            XCTAssertTrue(isAvailable(true), "dimmed while the feed plays the episode below")
            model.episodeEnd = .playBookAbove
            XCTAssertTrue(isAvailable(true), "dimmed while the feed plays the episode above")
            model.episodeEnd = .stop
            XCTAssertTrue(isAvailable(false), "available while the feed stops")
            XCTAssertFalse(model.predownloadsNextEpisode, "the dimmed choice was not kept")
        }
    }

    /// The global setting at Continue to Next Book makes the checkbox
    /// available for a feed that follows it.
    func testTheDownloadCheckboxFollowsTheGlobalSettingForAFeedThatFollowsIt() async throws {
        let subscribed = try await subscribe(label: "FeedListeningDimmedGlobal")
        let model = makeModel(subscribed, defaults: makeDefaults("DimmedGlobal", behavior: .continueNext))
        withFeedInfo(model, subscribed) { hosting in
            XCTAssertEqual(feedCheckboxes(in: hosting).last?.isEnabled, true)
        }
    }

    /// A feed of articles says "article" in every control's words.
    func testAFeedOfArticlesSaysArticle() async throws {
        let subscribed = try await subscribe(label: "FeedListeningArticles", articles: true)
        let model = makeModel(subscribed, defaults: makeDefaults("Articles", behavior: .continueNext))
        XCTAssertEqual(
            ListeningOptionsWording.Noun(subscribed.world.center.counts(of: subscribed.feed.id).noun),
            .article
        )

        withFeedInfo(model, subscribed) { hosting in
            XCTAssertEqual(endPopUp(in: hosting)?.itemTitles, [
                "Use the global setting (Continue to Next Book)",
                "Play the article below",
                "Play the article above",
                "Stop",
            ])
            if hostedWindowsExposeAccessibility() {
                let labels = accessibleControls(in: hosting).map(\.label)
                XCTAssertTrue(labels.contains("When an article ends"), "\(labels)")
            }
        }
        // The words, pinned where the hosted window cannot show them.
        XCTAssertEqual(ListeningOptionsWording.continuationLabel(.article), "When an article ends")
        XCTAssertEqual(ListeningOptionsWording.skipFinishedLabel(.article), "Skip finished articles")
        XCTAssertEqual(
            ListeningOptionsWording.predownloadLabel(.article),
            "Download the next article before this one ends"
        )
    }

    /// The sheet shows the wording functions' output, not a copy of it: the
    /// pop-up's titles are `continuationTitle` for each choice, and, where
    /// the session exposes accessibility, the controls speak the label and
    /// hint functions' output.
    func testTheSheetShowsTheWordingFunctionsOutput() async throws {
        let subscribed = try await subscribe(label: "FeedListeningWording")
        let model = makeModel(subscribed, defaults: makeDefaults("Wording", behavior: .loop))

        withFeedInfo(model, subscribed) { hosting in
            let expectedTitles = [nil, ReadingList.Continuation.playBookBelow, .playBookAbove, .stop].map {
                ListeningOptionsWording.continuationTitle($0, noun: .episode, global: .loop)
            }
            XCTAssertEqual(endPopUp(in: hosting)?.itemTitles, expectedTitles)
            XCTAssertEqual(expectedTitles.first, "Use the global setting (Loop to Start)")

            // Only the pop-up is exposed as a control here: SwiftUI builds its
            // checkboxes' accessibility elements only for a connected
            // assistive app, so their words are pinned by the wording tests.
            if hostedWindowsExposeAccessibility() {
                let controls = accessibleControls(in: hosting)
                let picker = controls.first { $0.role == .popUpButton && $0.label == ListeningOptionsWording.continuationLabel(.episode) }
                XCTAssertEqual(picker?.hint, ListeningOptionsWording.continuationHint(.episode))
            }
        }
    }

    // MARK: - Choosing in the Sheet

    /// Runs each of `attempts` in turn until `condition` holds, waiting a
    /// moment after each for SwiftUI to hand the change on; whether it held
    /// at the end.
    private func savesAfterTrying(_ attempts: [() -> Void], until condition: () -> Bool) -> Bool {
        for attempt in attempts {
            attempt()
            if waitUntil(timeout: 1, condition) { return true }
        }
        return false
    }

    /// Choosing in the hosted pop-up saves into the feed's record, and the
    /// first choice stores nothing again.
    func testChoosingInTheHostedPopUpSaves() async throws {
        let subscribed = try await subscribe(label: "FeedListeningChoose")
        let model = makeModel(subscribed, defaults: makeDefaults("Choose"))

        try withFeedInfo(model, subscribed) { hosting in
            let popUp = try XCTUnwrap(endPopUp(in: hosting))
            // Choosing a menu item runs the action SwiftUI gave the item;
            // the pop-up's own target and action are the second way.
            @MainActor func choose(_ index: Int, until condition: () -> Bool) -> Bool {
                savesAfterTrying(
                    [
                        { popUp.menu?.performActionForItem(at: index) },
                        { popUp.selectItem(at: index); _ = popUp.target?.perform(popUp.action, with: popUp) },
                    ],
                    until: condition
                )
            }
            XCTAssertTrue(
                choose(3) { subscribed.record?.feed.listeningOptions?.continuation == .stop },
                "choosing Stop did not save: \(String(describing: subscribed.record?.feed.listeningOptions))"
            )
            XCTAssertTrue(
                choose(1) { subscribed.record?.feed.listeningOptions?.continuation == .playBookBelow },
                "choosing the episode below did not save"
            )
            // The first choice, Use the global setting, is the standard one
            // here, so the record keeps no options at all.
            XCTAssertTrue(
                choose(0) { subscribed.record?.feed.listeningOptions == nil },
                "choosing the global setting did not clear the options"
            )
        }
    }

    /// Each new checkbox saves its choice. SwiftUI gives its checkbox no
    /// target or action a test can press (see `feedCheckboxes`), so the
    /// click's own path, the model's setter the checkbox's binding calls, is
    /// driven directly, and the checkbox is checked to draw what was saved.
    func testTheCheckboxesSaveAndDrawTheirChoice() async throws {
        let subscribed = try await subscribe(label: "FeedListeningCheckboxes")
        let model = makeModel(subscribed, defaults: makeDefaults("Checkboxes", behavior: .continueNext))

        withFeedInfo(model, subscribed) { hosting in
            @MainActor func state(of index: Int) -> NSControl.StateValue? {
                let boxes = feedCheckboxes(in: hosting)
                return boxes.indices.contains(index) ? boxes[index].state : nil
            }
            @MainActor func draws(_ index: Int, _ expected: NSControl.StateValue) -> Bool {
                waitUntil {
                    hosting.layoutSubtreeIfNeeded()
                    return state(of: index) == expected
                }
            }

            model.skipsFinishedEpisodes = false
            XCTAssertEqual(subscribed.record?.feed.listeningOptions?.skipsFinished, false)
            XCTAssertTrue(draws(3, .off), "Skip finished did not draw the choice saved")

            model.predownloadsNextEpisode = false
            XCTAssertEqual(subscribed.record?.feed.listeningOptions?.predownloadsNext, false)
            XCTAssertTrue(draws(4, .off), "Download the next did not draw the choice saved")

            // Back on, both: the record keeps nothing again.
            model.skipsFinishedEpisodes = true
            model.predownloadsNextEpisode = true
            XCTAssertNil(subscribed.record?.feed.listeningOptions)
            XCTAssertTrue(draws(3, .on))
            XCTAssertTrue(draws(4, .on))
        }
    }
}

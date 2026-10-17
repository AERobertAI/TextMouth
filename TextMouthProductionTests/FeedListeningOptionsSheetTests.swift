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
}

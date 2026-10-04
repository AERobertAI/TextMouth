import AppKit
import XCTest
@testable import TextMouth

/// The announcements of new items (FR03): after a refresh TextMouth makes by
/// itself brings new episodes, an alert naming the feeds and counts, shown
/// once, by the Library window in front, with the refresh alert setting on;
/// and a notification for each feed, with the notifications setting on and
/// notifications allowed, through a fake notification center, so no test
/// reaches the system's or shows a permission prompt. A refresh the listener
/// asks for alerts and notifies nothing.
@MainActor
final class FeedUIArrivalsTests: XCTestCase {

    // MARK: - The Alert

    /// A scheduled refresh that brings a new episode, with the refresh
    /// alert on, leaves an alert naming the feed and the count, which the
    /// first Library window in front takes, and no other.
    func testAScheduledRefreshsNewItemsAreAlertedOnceInFront() async throws {
        let harness = try await Harness(self, label: "FeedUIArrivalsAlert", alert: true)

        await harness.refreshWithANewEpisode(origin: .scheduled)

        let alert = try XCTUnwrap(harness.arrivals.pendingAlert)
        XCTAssertEqual(alert.title, "New Episodes")
        XCTAssertEqual(alert.message, "The Tactile Atlas: 1 new episode.")
        // Two windows' identities, each kept alive, so the second can never
        // take the first's freed address, and with it its identity.
        let firstWindow = NSObject()
        let secondWindow = NSObject()
        let first = ObjectIdentifier(firstWindow)
        let second = ObjectIdentifier(secondWindow)
        defer { withExtendedLifetime((firstWindow, secondWindow)) {} }
        XCTAssertFalse(harness.arrivals.claimAlert(by: first, isKeyWindow: false), "a window not in front took the alert")
        XCTAssertTrue(harness.arrivals.claimAlert(by: first, isKeyWindow: true))
        XCTAssertFalse(harness.arrivals.claimAlert(by: second, isKeyWindow: true), "a second window took the alert")
        XCTAssertTrue(harness.arrivals.claimAlert(by: first, isKeyWindow: false), "the window lost the alert it showed")

        harness.arrivals.dismissAlert()
        XCTAssertNil(harness.arrivals.pendingAlert)
        XCTAssertFalse(harness.arrivals.claimAlert(by: first, isKeyWindow: true))
        XCTAssertTrue(harness.notifier.posted.isEmpty, "notifications were posted with the setting off")
    }

    /// A refresh the listener asked for, a refresh that brought nothing
    /// new, and a refresh with the alert setting off alert nothing.
    func testOnlyARefreshTextMouthMadeWithTheSettingOnAlerts() async throws {
        let listener = try await Harness(self, label: "FeedUIArrivalsListener", alert: true, notifications: true)
        await listener.refreshWithANewEpisode(origin: .listener)
        XCTAssertNil(listener.arrivals.pendingAlert)
        await listener.arrivals.posting?.value
        XCTAssertTrue(listener.notifier.posted.isEmpty)

        let nothing = try await Harness(self, label: "FeedUIArrivalsNothing", alert: true)
        await nothing.world.center.refreshAll(origin: .scheduled)
        XCTAssertNil(nothing.arrivals.pendingAlert)

        let off = try await Harness(self, label: "FeedUIArrivalsOff")
        await off.refreshWithANewEpisode(origin: .launch)
        XCTAssertNil(off.arrivals.pendingAlert)
    }

    // MARK: - Notifications

    /// With notifications on and allowed, a refresh TextMouth made by
    /// itself posts one notification for each feed with new items, titled
    /// with the feed and naming the newest item.
    func testNotificationsPostOnePerFeedWhenAllowed() async throws {
        let harness = try await Harness(self, label: "FeedUIArrivalsNotify", notifications: true, authorization: .allowed)

        await harness.refreshWithANewEpisode(origin: .launch)
        await harness.arrivals.posting?.value

        XCTAssertEqual(harness.notifier.posted.map(\.title), ["The Tactile Atlas"])
        XCTAssertEqual(harness.notifier.posted.first?.body, "New episode: “A map you can touch”")
        XCTAssertEqual(harness.notifier.posted.first?.threadID, "feed-\(harness.feed.id.uuidString)")
        XCTAssertNil(harness.arrivals.pendingAlert, "an alert showed with the alert setting off")
        XCTAssertEqual(harness.notifier.requests, 0, "a refresh asked for permission")
    }

    /// Refused notifications post nothing.
    func testRefusedNotificationsPostNothing() async throws {
        let harness = try await Harness(self, label: "FeedUIArrivalsRefused", notifications: true, authorization: .denied)

        await harness.refreshWithANewEpisode(origin: .scheduled)
        await harness.arrivals.posting?.value

        XCTAssertTrue(harness.notifier.posted.isEmpty)
    }

    /// Turning the setting on asks permission the first time only, and
    /// returns the answer for the setting's help.
    func testTurningNotificationsOnAsksTheFirstTimeOnly() async {
        let notifier = FakeFeedNotifier(authorization: .notDetermined, answer: .allowed)
        let first = await FeedArrivals.settingTurnedOn(notifier)
        XCTAssertEqual(first, .allowed)
        XCTAssertEqual(notifier.requests, 1)
        let second = await FeedArrivals.settingTurnedOn(notifier)
        XCTAssertEqual(second, .allowed)
        XCTAssertEqual(notifier.requests, 1, "permission was asked twice")

        let refused = FakeFeedNotifier(authorization: .denied, answer: .allowed)
        let answer = await FeedArrivals.settingTurnedOn(refused)
        XCTAssertEqual(answer, .denied)
        XCTAssertEqual(refused.requests, 0, "a refusal was asked about again")
        XCTAssertEqual(
            FeedWording.notificationsRefused,
            "TextMouth isn't allowed to post notifications. Turn them on in System Settings, Notifications, TextMouth."
        )
    }

    /// The words of the alert and of a notification, for one item, several,
    /// and kinds mixed.
    func testTheArrivalsWords() {
        let feedID = UUID()
        let one = FeedArrival(feedID: feedID, feedTitle: "Atlas", count: 1, noun: .episode, latestTitle: "Maps")
        let three = FeedArrival(feedID: UUID(), feedTitle: "Notes", count: 3, noun: .article, latestTitle: "Trams")
        XCTAssertEqual(FeedArrivalAlert(arrivals: [one]).title, "New Episodes")
        XCTAssertEqual(FeedArrivalAlert(arrivals: [one, three]).title, "New Items")
        XCTAssertEqual(FeedArrivalAlert(arrivals: [one, three]).message, "Atlas: 1 new episode. Notes: 3 new articles.")
        let date = Date(timeIntervalSince1970: 1_791_000_000)
        XCTAssertEqual(FeedWording.notification(for: one, refreshedAt: date).body, "New episode: “Maps”")
        XCTAssertEqual(FeedWording.notification(for: three, refreshedAt: date).body, "3 new articles, the newest “Trams”")
        XCTAssertEqual(FeedWording.notification(for: one, refreshedAt: date).identifier, "feed-\(feedID.uuidString)-1791000000")
    }

    // MARK: - Harness

    /// A feed of one episode in a world whose engine refreshes on a stub
    /// server, the arrivals heard through a fake notification center, and
    /// the two settings as each test sets them.
    @MainActor
    private final class Harness {
        let world: FeedTestWorld
        let feed: Feed
        let notifier: FakeFeedNotifier
        let arrivals: FeedArrivals

        init(
            _ test: XCTestCase,
            label: String,
            alert: Bool = false,
            notifications: Bool = false,
            authorization: FeedNotificationAuthorization = .allowed
        ) async throws {
            world = try FeedTestWorld(test, label: label)
            FeedSettings.refreshAlertPreference.write(alert, to: world.preferences)
            FeedSettings.notificationsPreference.write(notifications, to: world.preferences)
            let first = FeedXML.Item(guid: "ep-1", title: "The first visit", published: world.day(-3), enclosure: "https://atlas.example/1.mp3")
            world.server.serve("/feed.xml", .feed(FeedXML.rss(items: [first])))
            feed = try await world.subscribe("/feed.xml")
            notifier = FakeFeedNotifier(authorization: authorization, answer: authorization)
            arrivals = FeedArrivals(center: world.center, notifier: notifier)
        }

        /// Serves the feed with a new episode, a day on, and refreshes every
        /// feed as `origin` would.
        func refreshWithANewEpisode(origin: FeedRefreshOrigin) async {
            let first = FeedXML.Item(guid: "ep-1", title: "The first visit", published: world.day(-3), enclosure: "https://atlas.example/1.mp3")
            let newer = FeedXML.Item(guid: "ep-2", title: "A map you can touch", published: world.day(1), enclosure: "https://atlas.example/2.mp3")
            world.server.serve("/feed.xml", .feed(FeedXML.rss(items: [newer, first])))
            world.advance(by: 2 * 86_400)
            await world.center.refreshAll(origin: origin)
        }
    }
}

/// A notification center of a test's own: it answers whether notifications
/// are allowed as the test says, counts the permission requests, gives the
/// answer the test chose, and keeps every notification posted.
@MainActor
final class FakeFeedNotifier: FeedNotifying {
    /// Whether notifications are allowed now.
    private(set) var current: FeedNotificationAuthorization
    /// What a permission request answers.
    let answer: FeedNotificationAuthorization
    /// How many times permission was asked.
    private(set) var requests = 0
    /// Every notification posted, in order.
    private(set) var posted: [FeedNotification] = []

    init(authorization: FeedNotificationAuthorization, answer: FeedNotificationAuthorization) {
        current = authorization
        self.answer = answer
    }

    func authorization() async -> FeedNotificationAuthorization {
        current
    }

    func requestAuthorization() async -> FeedNotificationAuthorization {
        requests += 1
        current = answer
        return answer
    }

    func post(_ notification: FeedNotification) async {
        posted.append(notification)
    }
}

import AppKit
import Combine
import Foundation
import UserNotifications

// MARK: - New Items Arriving (FR03)

/// What one feed brought in a refresh (FR03): how many new items, of what
/// kind, and the newest one's title.
struct FeedArrival: Equatable, Sendable {
    /// The feed.
    let feedID: UUID
    /// The feed's title.
    let feedTitle: String
    /// How many items arrived as new.
    let count: Int
    /// What the new items are called.
    let noun: FeedWording.ItemNoun
    /// The newest new item's title, if the record still keeps it.
    let latestTitle: String?

    /// What each feed of `summary` brought, by title, leaving out the feeds
    /// that brought nothing; the items are read from `center`'s records.
    @MainActor
    static func arrivals(in summary: FeedRefreshSummary, center: FeedCenter) -> [FeedArrival] {
        summary.reports.compactMap { report in
            guard !report.newItemIDs.isEmpty else { return nil }
            let record = center.store.record(of: report.feedID)
            let items = report.newItemIDs.compactMap { record?.item($0) }
            return FeedArrival(
                feedID: report.feedID,
                feedTitle: report.feedTitle,
                count: report.newItemIDs.count,
                noun: .of(items),
                latestTitle: items.first?.title
            )
        }
    }
}

/// The alert a Library window shows after a refresh TextMouth made by
/// itself brought new items, with the refresh alert setting on (FR03).
struct FeedArrivalAlert: Identifiable, Equatable {
    /// Tells two alerts apart.
    let id = UUID()
    /// What came, feed by feed.
    let arrivals: [FeedArrival]

    /// The alert's title: "New Episodes", "New Articles", or "New Items".
    var title: String {
        let nouns = Set(arrivals.map(\.noun))
        let noun = nouns.count == 1 ? (nouns.first ?? .item) : .item
        return "New \(noun.plural.capitalized)"
    }

    /// The alert's message: a sentence for each feed, "Planet Money: 2 new
    /// episodes."
    var message: String {
        arrivals.map { FeedWording.arrivalSentence($0) }.joined(separator: " ")
    }
}

// MARK: - Notifications

/// Whether TextMouth may post notifications.
enum FeedNotificationAuthorization: Equatable, Sendable {
    /// The listener has not been asked yet.
    case notDetermined
    /// The listener refused, or turned them off in System Settings.
    case denied
    /// They are allowed.
    case allowed
}

/// One notification of new items (FR03).
struct FeedNotification: Equatable, Sendable {
    /// Its identity, unique to the refresh that posted it.
    let identifier: String
    /// Its title: the feed's.
    let title: String
    /// Its words: what came.
    let body: String
    /// The thread it joins in Notification Center: one per feed.
    let threadID: String
}

/// Posts the feed reader's notifications and asks permission for them: the
/// system's notification center in the app, or a test's stand-in.
@MainActor
protocol FeedNotifying: AnyObject {
    /// Whether TextMouth may post notifications now.
    func authorization() async -> FeedNotificationAuthorization
    /// Asks the listener's permission, as the system asks it, and returns
    /// the answer.
    func requestAuthorization() async -> FeedNotificationAuthorization
    /// Posts `notification` at once.
    func post(_ notification: FeedNotification) async
}

/// The system's notification center (FR03). Notifications show as banners
/// even while TextMouth is in front, where feeds refresh, so VoiceOver reads
/// them out.
@MainActor
final class SystemFeedNotifier: FeedNotifying {
    /// Lets banners show while TextMouth is in front.
    private let presenter = FeedNotificationPresenter()
    /// Whether `presenter` is the notification center's delegate yet.
    private var isPresenterInstalled = false

    func authorization() async -> FeedNotificationAuthorization {
        await Self.currentAuthorization()
    }

    func requestAuthorization() async -> FeedNotificationAuthorization {
        installPresenter()
        _ = await Self.askPermission()
        return await Self.currentAuthorization()
    }

    func post(_ notification: FeedNotification) async {
        installPresenter()
        await Self.add(notification)
    }

    /// Makes `presenter` the notification center's delegate, once.
    private func installPresenter() {
        guard !isPresenterInstalled else { return }
        isPresenterInstalled = true
        UNUserNotificationCenter.current().delegate = presenter
    }

    /// The authorization the system holds for TextMouth now.
    nonisolated private static func currentAuthorization() async -> FeedNotificationAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        default:
            return .allowed
        }
    }

    /// Asks the system to ask the listener; whether they allowed it.
    nonisolated private static func askPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Hands `notification` to the system, to show at once; a failure,
    /// such as notifications turned off, posts nothing.
    nonisolated private static func add(_ notification: FeedNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.threadIdentifier = notification.threadID
        let request = UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// The notification center's delegate, which lets TextMouth's banners show
/// while it is in front (FR03): by default macOS keeps them quiet then.
final class FeedNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

/// A notifier that posts nothing, never asks, and says notifications are
/// not allowed: a process hosting tests uses it, so no test reaches the
/// system's notification center or shows a permission prompt.
@MainActor
final class InertFeedNotifier: FeedNotifying {
    func authorization() async -> FeedNotificationAuthorization { .denied }
    func requestAuthorization() async -> FeedNotificationAuthorization { .denied }
    func post(_ notification: FeedNotification) async {}
}

// MARK: - Announcing Arrivals

/// The feed reader's announcement of new items (FR03): after a refresh
/// TextMouth makes by itself, at launch or on the interval, brings new
/// episodes or articles, an alert naming the feeds and counts, in a Library
/// window once one is in front, when the refresh alert setting is on; and a
/// notification for each feed, when the notifications setting is on. A
/// refresh the listener asks for is answered where it was asked, by
/// VoiceOver, never here. Both read the engine's events (`FeedCenter.events`).
///
/// It also says, through VoiceOver, when a change of the "List and
/// download" choice or its number takes effect (FR11): ten seconds after
/// the last change, wherever it was made (Settings, Feed Info, or
/// config.json), whichever window is in front by then.
@MainActor
final class FeedArrivals: ObservableObject {
    /// The app's: the app's engine and the system's notification center, or
    /// in a process hosting tests a notifier that posts nothing.
    static let shared = FeedArrivals(center: .shared, notifier: appNotifier())

    /// The notifier the app uses: the system's, except in a process hosting
    /// tests, where none may reach the system's notification center.
    private static func appNotifier() -> any FeedNotifying {
        if TextMouthRuntime.current.isHostedTest {
            return InertFeedNotifier()
        }
        return SystemFeedNotifier()
    }

    /// The engine heard.
    let center: FeedCenter
    /// Posts the notifications.
    let notifier: any FeedNotifying
    /// The alert waiting to be shown or showing, if any.
    @Published private(set) var pendingAlert: FeedArrivalAlert?
    /// The Library window showing the alert, once one has taken it.
    @Published private(set) var alertWindow: ObjectIdentifier?
    /// The notifications posting now, which tests await.
    private(set) var posting: Task<Void, Never>?
    /// Speaks what took effect: through VoiceOver, from the window in
    /// front, unless a test listens instead.
    var announce: @MainActor (String) -> Void = { VoiceOverAnnouncer.announce($0) }
    /// Hears the engine's events.
    private var subscription: AnyCancellable?

    /// Arrivals heard from `center`, notified through `notifier`.
    init(center: FeedCenter, notifier: any FeedNotifying) {
        self.center = center
        self.notifier = notifier
        // Sent on the main actor, by the engine.
        subscription = center.events.sink { [weak self] event in
            self?.handle(event)
        }
    }

    /// Announces what a refresh of every feed that TextMouth made by itself
    /// brought, as the settings say, and says when a change of the "List
    /// and download" choice took effect (FR11); anything else changes
    /// nothing.
    func handle(_ event: FeedEvent) {
        switch event {
        case .refreshedAll(let summary) where summary.origin.isDiscretionary:
            announceArrivals(in: summary)
        case let .itemPolicyApplied(global, feedIDs):
            if let sentence = FeedWording.itemPolicyApplied(global: global, feedIDs: feedIDs, in: center) {
                announce(sentence)
            }
        default:
            break
        }
    }

    /// Announces what `summary`, a refresh of every feed that TextMouth made
    /// by itself, brought: an alert, a notification for each feed, or both,
    /// as the settings say; nothing when nothing new came.
    private func announceArrivals(in summary: FeedRefreshSummary) {
        let arrivals = FeedArrival.arrivals(in: summary, center: center)
        guard !arrivals.isEmpty else { return }
        let settings = center.settings
        if settings.refreshAlert {
            // A newer refresh's alert takes the place of one not yet
            // dismissed, in the window already showing it, if any: taking
            // the alert from that window would dismiss it, and the
            // dismissal would forget the new one.
            pendingAlert = FeedArrivalAlert(arrivals: arrivals)
        }
        if settings.notifications {
            let notifier = notifier
            let notifications = arrivals.map { FeedWording.notification(for: $0, refreshedAt: center.environment.now()) }
            posting = Task {
                guard await notifier.authorization() == .allowed else { return }
                for notification in notifications {
                    await notifier.post(notification)
                }
            }
        }
    }

    /// Whether the Library window `windowID` shows the waiting alert: the
    /// first Library window in front to ask takes it, so the alert shows
    /// once, where the listener is, and waits while no Library window is in
    /// front, as at launch before the Library window is up.
    @discardableResult
    func claimAlert(by windowID: ObjectIdentifier?, isKeyWindow: Bool) -> Bool {
        guard pendingAlert != nil, let windowID else { return false }
        if alertWindow == windowID { return true }
        guard alertWindow == nil, isKeyWindow else { return false }
        alertWindow = windowID
        return true
    }

    /// Forgets the alert once it is dismissed.
    func dismissAlert() {
        pendingAlert = nil
        alertWindow = nil
    }

    /// Asks permission for notifications as the setting is turned on, the
    /// first time only (FR03): once asked, the system remembers the answer,
    /// and asking again shows nothing.
    /// - Returns: Whether notifications are allowed now, for the setting's
    ///   help to say so when they are not.
    static func settingTurnedOn(_ notifier: any FeedNotifying) async -> FeedNotificationAuthorization {
        let current = await notifier.authorization()
        guard current == .notDetermined else { return current }
        return await notifier.requestAuthorization()
    }
}

// MARK: - Words

extension FeedWording {
    /// One feed's arrivals as the alert says them: "Planet Money: 2 new
    /// episodes."
    static func arrivalSentence(_ arrival: FeedArrival) -> String {
        "\(arrival.feedTitle): \(arrival.count) new \(arrival.count == 1 ? arrival.noun.singular : arrival.noun.plural)."
    }

    /// The notification of one feed's arrivals: titled with the feed, and
    /// saying "New episode: “How tides are measured”" for one, or "3 new
    /// episodes, the newest “How tides are measured”".
    static func notification(for arrival: FeedArrival, refreshedAt date: Date) -> FeedNotification {
        let body: String
        switch (arrival.count, arrival.latestTitle) {
        case (1, let title?):
            body = "New \(arrival.noun.singular): “\(title)”"
        case (_, let title?):
            body = "\(arrival.count) new \(arrival.noun.plural), the newest “\(title)”"
        case (_, nil):
            body = "\(arrival.count) new \(arrival.count == 1 ? arrival.noun.singular : arrival.noun.plural)"
        }
        return FeedNotification(
            identifier: "feed-\(arrival.feedID.uuidString)-\(Int(date.timeIntervalSince1970))",
            title: arrival.feedTitle,
            body: body,
            threadID: "feed-\(arrival.feedID.uuidString)"
        )
    }

    /// What the notifications setting's help says while notifications are
    /// not allowed.
    static let notificationsRefused = "TextMouth isn't allowed to post notifications. Turn them on in System Settings, Notifications, TextMouth."
}

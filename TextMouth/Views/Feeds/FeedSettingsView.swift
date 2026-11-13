import SwiftUI

// MARK: - Preferences, Feeds (FR03)

/// The Feeds tab of Preferences (FR03): the feed settings the listener
/// decided on October 4 and changed on October 7 (FR11), each a labelled
/// control, with the unit in the words of every number (`FeedSettings`,
/// kept through `SettingsViewModel.feedSettings`, which config.json
/// mirrors), and Refresh All Feeds Now.
///
/// What every feed lists and downloads is the "List and download" pop-up
/// menu and its number (`FeedItemPolicyControls`, FR11). The two numbers
/// with an off value are drawn as the Repeated Symbols threshold is, each
/// with its off value as a checkbox (`FeedThresholdControl`): refreshing
/// only at launch and when asked, and never deleting a played download.
struct FeedSettingsView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    /// The feed engine Refresh All Feeds Now refreshes: the app's, unless a
    /// test shows its own.
    var center: FeedCenter = .shared
    /// Speaks what Refresh All Feeds Now found: through VoiceOver, unless a
    /// test listens instead.
    var announce: @MainActor (String) -> Void = { VoiceOverAnnouncer.announce($0) }
    /// Asks permission for notifications and says whether they are allowed:
    /// the system's notification center, unless a test stands in.
    var notifier: any FeedNotifying = FeedArrivals.shared.notifier

    /// Whether Refresh All Feeds Now is refreshing.
    @State private var isRefreshing = false
    /// Whether TextMouth may post notifications, as last asked.
    @State private var notificationAuthorization: FeedNotificationAuthorization?

    var body: some View {
        Form {
            Section {
                Toggle(FeedSettingsWording.refreshAtLaunch, isOn: binding(\.refreshAtLaunch))
                    .accessibilityHint(FeedSettingsWording.refreshAtLaunchHint)
                FeedThresholdControl(
                    rule: SettingsPolicy.feedRefreshIntervalHours,
                    wording: .refreshInterval,
                    value: binding(\.refreshIntervalHours)
                )
                HStack(spacing: 8) {
                    Button(FeedSettingsWording.refreshAllNow) {
                        refreshAll()
                    }
                    .disabled(isRefreshing || center.feeds.isEmpty)
                    .accessibilityHint(FeedSettingsWording.refreshAllNowHint)
                    if isRefreshing {
                        SheetWorkIndicator(label: FeedSettingsWording.refreshing)
                    }
                }
            } header: {
                Text(FeedSettingsWording.refreshingHeading)
            }

            Section {
                FeedItemPolicyControls(policy: binding(\.itemPolicy), noun: nil)
                FeedThresholdControl(
                    rule: SettingsPolicy.feedDeleteDownloadsDaysAfterPlayed,
                    wording: .deleteDownloadsAfterPlaying,
                    value: binding(\.deleteDownloadsDaysAfterPlayed)
                )
                Text(FeedSettingsWording.perFeedNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(FeedSettingsWording.itemsHeading)
            }

            Section {
                Toggle(FeedSettingsWording.refreshAlert, isOn: binding(\.refreshAlert))
                    .accessibilityHint(FeedSettingsWording.refreshAlertHint)
                Toggle(FeedSettingsWording.notifications, isOn: notificationsBinding)
                    .accessibilityHint(notificationsHint)
                    .help(notificationsHint)
                if refusesNotifications {
                    Text(FeedWording.notificationsRefused)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text(FeedSettingsWording.newItemsHeading)
            }
        }
        .padding()
        .task {
            notificationAuthorization = await notifier.authorization()
        }
    }

    /// The notifications setting: turning it on asks permission the first
    /// time, and the setting's help then says whether it was refused.
    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { settingsViewModel.feedSettings.notifications },
            set: { isOn in
                binding(\.notifications).wrappedValue = isOn
                guard isOn else { return }
                let notifier = notifier
                Task {
                    notificationAuthorization = await FeedArrivals.settingTurnedOn(notifier)
                }
            }
        )
    }

    /// Whether notifications are on but TextMouth may not post them.
    private var refusesNotifications: Bool {
        settingsViewModel.feedSettings.notifications && notificationAuthorization == .denied
    }

    /// The notifications setting's help: what it does, and, while
    /// notifications are refused, how to allow them.
    private var notificationsHint: String {
        refusesNotifications
            ? "\(FeedSettingsWording.notificationsHint). \(FeedWording.notificationsRefused)"
            : FeedSettingsWording.notificationsHint
    }

    /// A binding to one feed setting, saved as it changes.
    private func binding<Value>(_ keyPath: WritableKeyPath<FeedSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settingsViewModel.feedSettings[keyPath: keyPath] },
            set: { value in
                var settings = settingsViewModel.feedSettings
                settings[keyPath: keyPath] = value
                settingsViewModel.feedSettings = settings
            }
        )
    }

    /// Refreshes every feed now, as the listener asked, and says what came.
    private func refreshAll() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let center = center
        let announce = announce
        Task {
            await center.refreshAllSaying(announce)
            isRefreshing = false
        }
    }
}

// MARK: - Words

/// The words of the Feeds tab of Preferences (FR03).
enum FeedSettingsWording {
    /// The tab's name.
    static let tabTitle = "Feeds"
    /// The first group's heading.
    static let refreshingHeading = "Refreshing"
    /// The second group's heading.
    static let itemsHeading = "Episodes and Articles"
    /// The third group's heading.
    static let newItemsHeading = "When New Episodes Arrive"

    /// Refreshing at launch.
    static let refreshAtLaunch = "Refresh every feed when TextMouth opens"
    /// Its hint: a feed the listener unsubscribed from is never checked
    /// (FR11, branch D).
    static let refreshAtLaunchHint = "Checks every feed you're subscribed to for new episodes and articles once the library has opened"
    /// Refresh All Feeds Now.
    static let refreshAllNow = "Refresh All Feeds Now"
    /// Its hint, which leaves out the feeds unsubscribed from, as Refresh
    /// All does (board #1816).
    static let refreshAllNowHint = "Checks every feed you're subscribed to now and says what came"
    /// What shows, and VoiceOver hears, while every feed is refreshed.
    static let refreshing = "Refreshing all feeds…"
    /// The note under the group's settings, naming the two a feed may have
    /// of its own.
    static let perFeedNote = "A feed can have its own List and download choice and its own days before deleting "
        + "played downloads, in its Feed Info."
    /// The refresh alert.
    static let refreshAlert = "Show an alert when a refresh brings new episodes"
    /// Its hint.
    static let refreshAlertHint = "After a refresh TextMouth makes by itself, at launch or on the interval, an alert names the feeds with new episodes and articles"
    /// Notifications.
    static let notifications = "Post a notification for each feed with new episodes"
    /// Its hint.
    static let notificationsHint = "After a refresh TextMouth makes by itself, a notification names each feed with new episodes and articles"
}

extension FeedWording {
    /// What VoiceOver hears once every feed has been refreshed because the
    /// listener asked: how many feeds, how many new items, and which feeds
    /// could not be refreshed. `center` names the new items' kind. With no
    /// feed checked it says why: there is none, or every feed is one the
    /// listener unsubscribed from, which is never checked (board #1816).
    @MainActor
    static func refreshedAll(_ summary: FeedRefreshSummary, in center: FeedCenter) -> String {
        guard !summary.reports.isEmpty else {
            return center.feeds.isEmpty ? noFeedsToRefresh : everyFeedUnsubscribed
        }
        let newItems = summary.reports.flatMap { report in
            report.newItemIDs.compactMap { center.store.record(of: report.feedID)?.item($0) }
        }
        let noun = ItemNoun.of(newItems)
        let found = newItemsFound(summary.newItemCount, noun)
        var sentence = "Refreshed \(CountWording.phrase(summary.reports.count, singular: "feed", plural: "feeds")): \(found)"
        if !summary.failedFeedTitles.isEmpty {
            sentence += " Couldn't refresh \(CountWording.list(summary.failedFeedTitles))."
        }
        return sentence
    }

    /// What a refresh found, as the end of Refresh All Feeds' sentence:
    /// "nothing new." for none, otherwise the count of new items of the kind
    /// `noun` names, as in "1 new episode." and "3 new articles.".
    static func newItemsFound(_ count: Int, _ noun: ItemNoun) -> String {
        guard count > 0 else { return "nothing new." }
        return CountWording.phrase(count, singular: "new \(noun.singular)", plural: "new \(noun.plural)") + "."
    }

    /// What Refresh All Feeds says with no feed in the library.
    static let noFeedsToRefresh = "There are no feeds to refresh."
    /// What Refresh All Feeds says when every feed in the library is one
    /// the listener unsubscribed from, which no refresh checks (FR11,
    /// branch D; board #1816).
    static let everyFeedUnsubscribed = "Every feed in your library is unsubscribed, so none was checked. "
        + "Choose Resubscribe on a feed's row, or in its Feed Info, to check it again."
}

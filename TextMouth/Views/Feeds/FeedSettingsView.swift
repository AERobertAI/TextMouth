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
            ? SentenceWording.joined([
                // Translators: Ends the notifications setting's hint with a full stop, before the sentence that says notifications are refused. %@ is the hint, without its full stop.
                InterfaceText.line("common.valuePeriod", "\(FeedSettingsWording.notificationsHint)."),
                FeedWording.notificationsRefused,
            ])
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
    static var tabTitle: String { FeedWording.feedsSectionTitle }
    /// The first group's heading.
    static var refreshingHeading: String {
        // Translators: Heading of the first group of the Feeds tab of Settings: how feeds are refreshed. Title case.
        InterfaceText.line("feedSettings.refreshingHeading", "Refreshing")
    }
    /// The second group's heading.
    static var itemsHeading: String {
        // Translators: Heading of the second group of the Feeds tab of Settings: what is listed and downloaded. Title case.
        InterfaceText.line("feedSettings.itemsHeading", "Episodes and Articles")
    }
    /// The third group's heading.
    static var newItemsHeading: String {
        // Translators: Heading of the third group of the Feeds tab of Settings: alerts and notifications. Title case.
        InterfaceText.line("feedSettings.newItemsHeading", "When New Episodes Arrive")
    }

    /// Refreshing at launch.
    static var refreshAtLaunch: String {
        // Translators: Label of the switch in the Feeds tab of Settings that refreshes every feed at launch.
        InterfaceText.line("feedSettings.refreshAtLaunch", "Refresh every feed when TextMouth opens")
    }
    /// Its hint: a feed the listener unsubscribed from is never checked
    /// (FR11, branch D).
    static var refreshAtLaunchHint: String {
        // Translators: VoiceOver hint of the switch that refreshes every feed at launch.
        InterfaceText.line("feedSettings.refreshAtLaunchHint", "Checks every subscribed feed once the library has opened")
    }
    /// Refresh All Feeds Now.
    static var refreshAllNow: String {
        // Translators: Title of the button in the Feeds tab of Settings that refreshes every feed at once. Title case.
        InterfaceText.line("feedSettings.refreshAllNow", "Refresh All Feeds Now")
    }
    /// Its hint, which leaves out the feeds unsubscribed from, as Refresh
    /// All does (board #1816).
    static var refreshAllNowHint: String {
        // Translators: VoiceOver hint of the Refresh All Feeds Now button.
        InterfaceText.line("feedSettings.refreshAllNowHint", "Checks every subscribed feed and says what came")
    }
    /// What shows, and VoiceOver hears, while every feed is refreshed.
    static var refreshing: String {
        // Translators: What the Feeds tab of Settings shows and VoiceOver says while every feed is being refreshed.
        InterfaceText.line("feedSettings.refreshing", "Refreshing all feeds…")
    }
    /// The note under the group's settings, naming the two a feed may have
    /// of its own.
    static var perFeedNote: String {
        // Translators: The note under the Feeds tab's settings. The first %@ is the name of the List and download choice; the second is the name of the Feed Info sheet.
        InterfaceText.line("feedSettings.perFeedNote", "A feed can have its own \(FeedWording.listAndDownloadLabel) choice and its own days before deleting played downloads, in its \(FeedWording.feedInfoName).")
    }
    /// The refresh alert.
    static var refreshAlert: String {
        // Translators: Label of the switch that shows an alert after a refresh TextMouth made by itself brought new items.
        InterfaceText.line("feedSettings.refreshAlert", "Show an alert when a refresh brings new episodes")
    }
    /// Its hint.
    static var refreshAlertHint: String {
        // Translators: VoiceOver hint of the switch that shows an alert after a refresh TextMouth made by itself.
        InterfaceText.line("feedSettings.refreshAlertHint", "After an automatic refresh, an alert names the feeds with new episodes and articles")
    }
    /// Notifications.
    static var notifications: String {
        // Translators: Label of the switch that posts a notification for each feed with new items after a refresh.
        InterfaceText.line("feedSettings.notifications", "Post a notification for each feed with new episodes")
    }
    /// Its hint.
    static var notificationsHint: String {
        // Translators: VoiceOver hint of the switch that posts notifications for new items.
        InterfaceText.line("feedSettings.notificationsHint", "After an automatic refresh, a notification names each feed with new episodes and articles")
    }
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
        // Translators: What VoiceOver says once Refresh All Feeds has refreshed the feeds. The first %@ is how many feeds, such as "3 feeds"; the second is what the refresh found, such as "2 new episodes." or "nothing new.", with its full stop.
        var sentences = [InterfaceText.line("feed.refreshedAll.withCounts", "Refreshed \(CountWording.feeds(summary.reports.count)): \(found)")]
        if !summary.failedFeedTitles.isEmpty {
            // Translators: The end of what VoiceOver says after Refresh All Feeds when some feeds could not be refreshed. %@ is a list of their titles.
            sentences.append(InterfaceText.line("feed.refreshedAll.couldnt", "Couldn't refresh \(CountWording.list(summary.failedFeedTitles))."))
        }
        return SentenceWording.joined(sentences)
    }

    /// What a refresh found, as the end of Refresh All Feeds' sentence:
    /// "nothing new." for none, otherwise the count of new items of the kind
    /// `noun` names, as in "1 new episode." and "3 new articles.".
    static func newItemsFound(_ count: Int, _ noun: ItemNoun) -> String {
        guard count > 0 else {
            // Translators: What Refresh All Feeds found when no feed has anything new, after "Refreshed 3 feeds:". Lower case, with its full stop.
            return InterfaceText.line("feed.newItemsFound.nothing", "nothing new.")
        }
        return noun.choose(
            // Translators: What Refresh All Feeds found, after "Refreshed 3 feeds:". %lld is how many new episodes. With its full stop.
            episode: InterfaceText.line("feed.newItemsFound.episodes", "\(number: count) new episodes."),
            // Translators: What Refresh All Feeds found, after "Refreshed 3 feeds:". %lld is how many new articles. With its full stop.
            article: InterfaceText.line("feed.newItemsFound.articles", "\(number: count) new articles."),
            // Translators: What Refresh All Feeds found, after "Refreshed 3 feeds:". %lld is how many new items, episodes and articles. With its full stop.
            item: InterfaceText.line("feed.newItemsFound.anyKind", "\(number: count) new items."))
    }

    /// What Refresh All Feeds says with no feed in the library.
    static var noFeedsToRefresh: String {
        // Translators: What VoiceOver says when Refresh All Feeds finds no feed in the library.
        InterfaceText.line("feed.noFeedsToRefresh", "There are no feeds to refresh.")
    }
    /// What Refresh All Feeds says when every feed in the library is one
    /// the listener unsubscribed from, which no refresh checks (FR11,
    /// branch D; board #1816).
    static var everyFeedUnsubscribed: String {
        // Translators: What VoiceOver says when Refresh All Feeds finds only unsubscribed feeds. The first %@ is the name of the Resubscribe command; the second is the name of the Feed Info sheet.
        InterfaceText.line("feed.everyFeedUnsubscribed", "Every feed is unsubscribed, so none was checked. Choose \(resubscribeTitle) on a feed's row, or in its \(feedInfoName), to check it again.")
    }
}

import SwiftUI

// MARK: - The List and Download Choice, Drawn (FR11)

/// The "List and download" choice and its number (FR11, branch C), as the
/// Feeds tab of Settings and each feed's Feed Info draw them:
/// - a pop-up menu labelled "List and download", whose value is the choice
///   in force and whose hint is that choice's own sentence; its three
///   titles say the number in force ("Every item listed, newest 5
///   downloaded"), so they follow it as it changes;
/// - the number, "How many of the newest", a number field and a stepper
///   drawn as every feed number is (`FeedNumberField`), from 1 to 2,000,
///   dimmed under "Every item listed, downloads by hand", which counts
///   none, and kept for the next choice that does;
/// - under them, the choice's sentence for whoever reads the screen,
///   hidden from VoiceOver, which hears it as the pop-up menu's hint, and a
///   line saying when a change takes effect, which VoiceOver reads too.
///
/// A change is saved at once, through `policy`. The feed engine acts on it
/// once it has stayed unchanged for ten seconds
/// (`FeedCenter.itemPolicyQuietTime`), and VoiceOver hears it then
/// (`FeedEvent.itemPolicyApplied`, `FeedArrivals`).
struct FeedItemPolicyControls: View {
    /// The choice and its number, saved as they change.
    @Binding var policy: FeedItemPolicy
    /// What a feed's items are called, for Feed Info's words ("Every
    /// episode listed, …"); nil for Settings, whose words serve every feed
    /// ("Every item listed, …").
    let noun: FeedWording.ItemNoun?
    /// Whether the controls are unavailable, as while Feed Info follows the
    /// global setting.
    var isDisabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(FeedWording.listAndDownloadLabel, selection: $policy.choice) {
                ForEach(FeedItemPolicy.Choice.allCases, id: \.self) { choice in
                    Text(FeedWording.itemPolicyTitle(choice, count: policy.newestCount, noun: noun))
                        .tag(choice)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel(FeedWording.listAndDownloadLabel)
            .accessibilityHint(hint)
            .help(hint)
            .disabled(isDisabled)

            VStack(alignment: .leading, spacing: 6) {
                // The caption repeats what the field and stepper say, so it
                // is hidden from VoiceOver rather than read twice, as every
                // feed number's caption is.
                Text(FeedWording.newestCountCaption(policy.newestCount, noun: noun))
                    .accessibilityHidden(true)
                HStack(spacing: 6) {
                    // A number typed is validated as it is set: the policy
                    // moves it into 1 to 2,000.
                    FeedNumberField(
                        label: FeedWording.newestCountLabel,
                        hint: FeedWording.newestCountHint(noun: noun),
                        spokenValue: FeedWording.newestCountValue(policy.newestCount, noun: noun),
                        range: SettingsPolicy.feedNewestCount.range,
                        number: $policy.newestCount
                    )
                    Spacer(minLength: 0)
                }
            }
            .disabled(isDisabled || !policy.usesNewestCount)

            // The choice's sentence, for whoever reads the screen. VoiceOver
            // hears it as the pop-up menu's hint, so it is hidden here rather
            // than read twice.
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            // When a change takes effect, which nothing else says: read by
            // VoiceOver as it is shown.
            Text(FeedWording.itemPolicyQuietNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The hint of the choice in force, which the screen shows under the
    /// controls too.
    private var hint: String {
        FeedWording.itemPolicyHint(policy.choice, count: policy.newestCount, noun: noun)
    }
}

// MARK: - Words

extension FeedWording {
    // MARK: The Choice

    /// The pop-up menu's label, as Settings and Feed Info show it and
    /// VoiceOver speaks it.
    static var listAndDownloadLabel: String {
        // Translators: Label of the pop-up menu that chooses how many of a feed's items are listed and downloaded, in Settings and Feed Info. Sentences name it.
        InterfaceText.line("feed.listAndDownloadLabel", "List and download")
    }

    /// The title of `choice` counting `count` of the newest, as the pop-up
    /// menu shows it and VoiceOver speaks it as the menu's value. `noun`
    /// names a feed's items, in Feed Info; nil, in Settings, words the
    /// choice for every feed. The number in force is in the words, so they
    /// follow it: "Every item listed, newest 5 downloaded", "Every episode
    /// listed, downloads by hand", "Only the newest 3 listed".
    static func itemPolicyTitle(_ choice: FeedItemPolicy.Choice, count: Int, noun: ItemNoun?) -> String {
        let kind = noun ?? .item
        switch choice {
        case .everyListedNewestDownloaded:
            return kind.choose(
                // Translators: A choice of the List and download pop-up menu, in Feed Info, for a feed of episodes: every episode is listed and the newest ones downloaded. %lld is how many of the newest.
                episode: InterfaceText.line("feed.itemPolicyTitle.newestDownloadedEpisode", "Every episode listed, newest \(number: count) downloaded"),
                // Translators: A choice of the List and download pop-up menu, in Feed Info, for a feed of articles: every article is listed and the newest ones downloaded. %lld is how many of the newest.
                article: InterfaceText.line("feed.itemPolicyTitle.newestDownloadedArticle", "Every article listed, newest \(number: count) downloaded"),
                // Translators: A choice of the List and download pop-up menu, in Settings or for a feed of both kinds: every item is listed and the newest ones downloaded. %lld is how many of the newest.
                item: InterfaceText.line("feed.itemPolicyTitle.newestDownloadedItem", "Every item listed, newest \(number: count) downloaded"))
        case .everyListedDownloadsByHand:
            return kind.choose(
                // Translators: A choice of the List and download pop-up menu, in Feed Info, for a feed of episodes: every episode is listed and the listener downloads by hand.
                episode: InterfaceText.line("feed.itemPolicyTitle.byHandEpisode", "Every episode listed, downloads by hand"),
                // Translators: A choice of the List and download pop-up menu, in Feed Info, for a feed of articles: every article is listed and the listener downloads by hand.
                article: InterfaceText.line("feed.itemPolicyTitle.byHandArticle", "Every article listed, downloads by hand"),
                // Translators: A choice of the List and download pop-up menu, in Settings or for a feed of both kinds: every item is listed and the listener downloads by hand.
                item: InterfaceText.line("feed.itemPolicyTitle.byHandItem", "Every item listed, downloads by hand"))
        case .onlyNewestListed:
            // Translators: A choice of the List and download pop-up menu: only the newest items are listed. %lld is how many.
            return InterfaceText.line("feed.itemPolicyTitle.onlyNewestListed", "Only the newest \(number: count) listed")
        }
    }

    /// The title of `policy`'s choice, counting its own number.
    static func itemPolicyTitle(_ policy: FeedItemPolicy, noun: ItemNoun?) -> String {
        itemPolicyTitle(policy.choice, count: policy.newestCount, noun: noun)
    }

    /// The hint of `choice` counting `count` of the newest: one sentence
    /// saying what it lists, what downloads, and what becomes of the rest,
    /// worded for `noun`'s items, or for every feed's when nil. VoiceOver
    /// speaks it after a pause, and the screen shows it under the controls.
    static func itemPolicyHint(_ choice: FeedItemPolicy.Choice, count: Int, noun: ItemNoun?) -> String {
        // The feed's own noun, or, for every feed and for a feed of both
        // kinds, "episode and article": each hint is written whole for it.
        let kind = noun ?? .item
        switch choice {
        case .everyListedNewestDownloaded:
            return kind.choose(
                // Translators: VoiceOver hint of the List and download choice for a feed of episodes: every episode is listed, the newest are downloaded, older downloads TextMouth made are removed. %lld is how many of the newest.
                episode: InterfaceText.line("feed.everyListedNewestDownloaded.episode", "Lists every episode, keeps the newest \(number: count) downloaded, and removes older downloads it made, keeping their place, bookmarks, and settings."),
                // Translators: VoiceOver hint of the List and download choice for a feed of articles: every article is listed, the newest are downloaded, older downloads TextMouth made are removed. %lld is how many of the newest.
                article: InterfaceText.line("feed.everyListedNewestDownloaded.article", "Lists every article, keeps the newest \(number: count) downloaded, and removes older downloads it made, keeping their place, bookmarks, and settings."),
                // Translators: VoiceOver hint of the List and download choice in Settings or for a feed of both kinds: every episode and article is listed, the newest are downloaded, older downloads TextMouth made are removed. %lld is how many of the newest.
                item: InterfaceText.line("feed.everyListedNewestDownloaded.episodeArticle", "Lists every episode and article, keeps the newest \(number: count) downloaded, and removes older downloads it made, keeping their place, bookmarks, and settings."))
        case .everyListedDownloadsByHand:
            return kind.choose(
                // Translators: VoiceOver hint of the List and download choice for a feed of episodes when the listener downloads by hand.
                episode: InterfaceText.line("feed.everyListedDownloadsByHand.episodeDownload", "Lists every episode; nothing downloads by itself, and a download stays until you delete it or its days after playing pass."),
                // Translators: VoiceOver hint of the List and download choice for a feed of articles when the listener downloads by hand.
                article: InterfaceText.line("feed.everyListedDownloadsByHand.article", "Lists every article; nothing downloads by itself, and a download stays until you delete it or its days after playing pass."),
                // Translators: VoiceOver hint of the List and download choice in Settings or for a feed of both kinds when the listener downloads by hand.
                item: InterfaceText.line("feed.everyListedDownloadsByHand.episodeArticle", "Lists every episode and article; nothing downloads by itself, and a download stays until you delete it or its days after playing pass."))
        case .onlyNewestListed:
            // Those of the newest `count` not yet played, so fewer than
            // `count` once some are played, never the newest `count`
            // unplayed (REV13 feeds 6); a played item still downloaded
            // stays listed, as every download does
            // (`FeedRecord.listedItems(under:hasFile:)`).
            return noun == .article
                // Translators: VoiceOver hint of the List and download choice for a feed of articles when only the newest are listed. %lld is how many of the newest.
                ? InterfaceText.line("feed.itemPolicyHint.onlyNewestListed.read", "Lists the newest \(number: count) you haven't read, and every download. Downloads only what you ask for; the others keep their records and return when you list more.")
                // Translators: VoiceOver hint of the List and download choice for a feed of episodes, in Settings, or for a feed of both kinds when only the newest are listed. %lld is how many of the newest.
                : InterfaceText.line("feed.itemPolicyHint.onlyNewestListed.played", "Lists the newest \(number: count) you haven't played, and every download. Downloads only what you ask for; the others keep their records and return when you list more.")
        }
    }

    // MARK: The Number

    /// The number's label: the field's and the stepper's spoken label.
    static var newestCountLabel: String {
        // Translators: Label of the number field and stepper that say how many of a feed's newest items are listed or downloaded.
        InterfaceText.line("feed.newestCountLabel", "How many of the newest")
    }

    /// The number as the stepper speaks it, with the items' noun: "5 items",
    /// or, in Feed Info, "5 episodes".
    static func newestCountValue(_ count: Int, noun: ItemNoun?) -> String {
        FeedWording.count(count, noun ?? .item)
    }

    /// The number's caption above its field, which says what the field and
    /// the stepper say: "How many of the newest: 5 items".
    static func newestCountCaption(_ count: Int, noun: ItemNoun?) -> String {
        SentenceWording.labelled(newestCountLabel, newestCountValue(count, noun: noun))
    }

    /// The number's spoken hint, for every feed's items or for `noun`'s.
    static func newestCountHint(noun: ItemNoun?) -> String {
        switch noun {
        case .episode?:
            // Translators: VoiceOver hint of the number of the newest items, for a feed of episodes. The range is the limits of the number.
            return InterfaceText.line("feed.newestCountHint.episode", "Newest episodes kept downloaded or listed, from 1 to 2,000")
        case .article?:
            // Translators: VoiceOver hint of the number of the newest items, for a feed of articles. The range is the limits of the number.
            return InterfaceText.line("feed.newestCountHint.article", "Newest articles kept downloaded or listed, from 1 to 2,000")
        case .item?:
            // Translators: VoiceOver hint of the number of the newest items, for a feed of both episodes and articles. The range is the limits of the number.
            return InterfaceText.line("feed.newestCountHint.item", "Newest items kept downloaded or listed, from 1 to 2,000")
        case nil:
            // Translators: VoiceOver hint of the number of the newest items, in Settings, for every feed. The range is the limits of the number.
            return InterfaceText.line("feed.newestCountHint.nil", "Newest episodes and articles kept downloaded or listed, from 1 to 2,000")
        }
    }

    /// The line saying when a change of the choice or its number takes
    /// effect: the list changes at once, while what downloads or goes
    /// waits until the change has stayed for
    /// `FeedCenter.itemPolicyQuietTime`, so typing 15 never passes through
    /// 1, and VoiceOver hears it then.
    static var itemPolicyQuietNote: String {
        // Translators: The note under the List and download controls: when a change takes effect. %@ is the name of the List and download choice.
        InterfaceText.line("feed.itemPolicyQuietNote", "The list follows a change of \(listAndDownloadLabel) at once; what downloads or goes waits until the change has stayed for ten seconds, and VoiceOver announces it then.")
    }

    // MARK: Taking Effect

    /// What VoiceOver hears once a change of the global choice or its
    /// number takes effect: "List and download is now in effect: Every item
    /// listed, newest 3 downloaded."
    static func itemPolicyApplied(global: FeedItemPolicy) -> String {
        // Translators: What VoiceOver says once a change of the global List and download choice takes effect. The first %@ is the name of the choice; the second is the choice now in force, such as "Every item listed, newest 3 downloaded".
        InterfaceText.line("feed.itemPolicyApplied.inEffect", "\(listAndDownloadLabel) is now in effect: \(itemPolicyTitle(global, noun: nil)).")
    }

    /// What VoiceOver hears once a change of the feed titled `feedTitle`
    /// takes effect: its own choice (`own`), worded with its items' `noun`,
    /// "List and download for Finish It! is now in effect: Every episode
    /// listed, newest 3 downloaded."; or, once it uses the global setting
    /// again (`own` nil), "List and download for Finish It! now follows the
    /// global setting: Every item listed, newest 5 downloaded."
    static func itemPolicyApplied(feedTitle: String, own: FeedItemPolicy?, global: FeedItemPolicy, noun: ItemNoun) -> String {
        guard let own else {
            // Translators: What VoiceOver says once a feed uses the global List and download choice again. The first %@ is the name of the choice; the second is the feed's title; the third is the global choice now in force.
            return InterfaceText.line("feed.itemPolicyApplied.follows", "\(listAndDownloadLabel) for \(feedTitle) now follows the global setting: \(itemPolicyTitle(global, noun: nil)).")
        }
        // Translators: What VoiceOver says once a change of a feed's own List and download choice takes effect. The first %@ is the name of the choice; the second is the feed's title; the third is the choice now in force.
        return InterfaceText.line("feed.itemPolicyApplied.forFeedInEffect", "\(listAndDownloadLabel) for \(feedTitle) is now in effect: \(itemPolicyTitle(own, noun: noun)).")
    }

    /// What VoiceOver hears once changes take effect in `center`
    /// (`FeedEvent.itemPolicyApplied`): the global setting's sentence when
    /// `global` changed, which covers every feed, then a sentence for each
    /// of the feeds `feedIDs` whose own changed that `center` still has, by
    /// title, an unsubscribed one among them, since its rules still act
    /// (FR11, branch D), so a feed's change made within the global change's
    /// wait is heard too (feed review item 20); nil when none is.
    @MainActor
    static func itemPolicyApplied(global: Bool, feedIDs: Set<UUID>, in center: FeedCenter) -> String? {
        let globalPolicy = center.settings.itemPolicy
        let feeds = center.feeds.filter { feedIDs.contains($0.id) }.map { feed in
            itemPolicyApplied(
                feedTitle: feed.title,
                own: feed.itemPolicyOverride,
                global: globalPolicy,
                noun: center.counts(of: feed.id).noun
            )
        }
        let sentences = (global ? [itemPolicyApplied(global: globalPolicy)] : []) + feeds
        return sentences.isEmpty ? nil : SentenceWording.joined(sentences)
    }
}

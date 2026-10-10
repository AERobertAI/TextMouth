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
    static let listAndDownloadLabel = "List and download"

    /// The title of `choice` counting `count` of the newest, as the pop-up
    /// menu shows it and VoiceOver speaks it as the menu's value. `noun`
    /// names a feed's items, in Feed Info; nil, in Settings, words the
    /// choice for every feed. The number in force is in the words, so they
    /// follow it: "Every item listed, newest 5 downloaded", "Every episode
    /// listed, downloads by hand", "Only the newest 3 listed".
    static func itemPolicyTitle(_ choice: FeedItemPolicy.Choice, count: Int, noun: ItemNoun?) -> String {
        let item = (noun ?? .item).singular
        switch choice {
        case .everyListedNewestDownloaded:
            return "Every \(item) listed, newest \(count) downloaded"
        case .everyListedDownloadsByHand:
            return "Every \(item) listed, downloads by hand"
        case .onlyNewestListed:
            return "Only the newest \(count) listed"
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
        let items = everyItemPhrase(noun)
        switch choice {
        case .everyListedNewestDownloaded:
            return "Lists every \(items) with what you did with it, keeps the newest \(count) downloaded, "
                + "and removes older downloads it made, keeping their place, bookmarks, and settings."
        case .everyListedDownloadsByHand:
            return "Lists every \(items); nothing downloads by itself, and a download stays until you delete it "
                + "or its days after playing pass."
        case .onlyNewestListed:
            let played = noun == .article ? "read" : "played"
            return "Lists the newest \(count), leaving out those you have \(played), and downloads only what you ask for; "
                + "the others keep their records and come back when you list more."
        }
    }

    /// What follows "every" in a choice's hint: the feed's own noun, or,
    /// for every feed and for a feed of both kinds, "episode and article".
    private static func everyItemPhrase(_ noun: ItemNoun?) -> String {
        switch noun {
        case .episode?: return ItemNoun.episode.singular
        case .article?: return ItemNoun.article.singular
        case .item?, nil: return "episode and article"
        }
    }

    // MARK: The Number

    /// The number's label: the field's and the stepper's spoken label.
    static let newestCountLabel = "How many of the newest"

    /// The number as the stepper speaks it, with the items' noun: "5 items",
    /// or, in Feed Info, "5 episodes".
    static func newestCountValue(_ count: Int, noun: ItemNoun?) -> String {
        FeedWording.count(count, noun ?? .item)
    }

    /// The number's caption above its field, which says what the field and
    /// the stepper say: "How many of the newest: 5 items".
    static func newestCountCaption(_ count: Int, noun: ItemNoun?) -> String {
        "\(newestCountLabel): \(newestCountValue(count, noun: noun))"
    }

    /// The number's spoken hint, for every feed's items or for `noun`'s.
    static func newestCountHint(noun: ItemNoun?) -> String {
        let whose = noun.map { "this feed's newest \($0.plural)" } ?? "each feed's newest episodes and articles"
        return "How many of \(whose) are kept downloaded, or listed, from 1 to 2,000"
    }

    /// The line saying when a change of the choice or its number takes
    /// effect: once it has stayed unchanged for
    /// `FeedCenter.itemPolicyQuietTime`, so typing 15 never passes through
    /// 1, and VoiceOver hears it then.
    static let itemPolicyQuietNote = "A change of List and download takes effect once it has stayed unchanged for "
        + "ten seconds, and VoiceOver announces it then."

    // MARK: Taking Effect

    /// What VoiceOver hears once a change of the global choice or its
    /// number takes effect: "List and download is now in effect: Every item
    /// listed, newest 3 downloaded."
    static func itemPolicyApplied(global: FeedItemPolicy) -> String {
        "List and download is now in effect: \(itemPolicyTitle(global, noun: nil))."
    }

    /// What VoiceOver hears once a change of the feed titled `feedTitle`
    /// takes effect: its own choice (`own`), worded with its items' `noun`,
    /// "List and download for Finish It! is now in effect: Every episode
    /// listed, newest 3 downloaded."; or, once it uses the global setting
    /// again (`own` nil), "List and download for Finish It! now follows the
    /// global setting: Every item listed, newest 5 downloaded."
    static func itemPolicyApplied(feedTitle: String, own: FeedItemPolicy?, global: FeedItemPolicy, noun: ItemNoun) -> String {
        guard let own else {
            return "List and download for \(feedTitle) now follows the global setting: \(itemPolicyTitle(global, noun: nil))."
        }
        return "List and download for \(feedTitle) is now in effect: \(itemPolicyTitle(own, noun: noun))."
    }

    /// What VoiceOver hears once a change made for `feedIDs` takes effect in
    /// `center` (`FeedEvent.itemPolicyApplied`): the global setting's
    /// sentence when nil, which covers every feed, or a sentence for each of
    /// those feeds still subscribed, by title; nil when none is.
    @MainActor
    static func itemPolicyApplied(to feedIDs: Set<UUID>?, in center: FeedCenter) -> String? {
        let global = center.settings.itemPolicy
        guard let feedIDs else { return itemPolicyApplied(global: global) }
        let sentences = center.feeds.filter { feedIDs.contains($0.id) }.map { feed in
            itemPolicyApplied(
                feedTitle: feed.title,
                own: feed.itemPolicyOverride,
                global: global,
                noun: center.counts(of: feed.id).noun
            )
        }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}

import Foundation

// MARK: - The Feed Reader's Words (FR03)

/// The words the feed reader's interface shows and VoiceOver speaks (FR03),
/// defined once here so a sheet, a row, a menu, and an announcement that
/// say the same thing say it the same way, and the hosted tests pin them.
///
/// SwiftUI builds the spoken labels of its own text and buttons only for a
/// connected assistive app, so every label is made by a function here and
/// tested through it.
enum FeedWording {
    // MARK: Add Feed

    /// The Library menu's command.
    static let addFeedCommand = "Add Feed…"
    /// The Library window's toolbar button's title.
    static let addFeedToolbarTitle = "Add Feed"
    /// The Library menu's command that refreshes every feed now.
    static let refreshAllCommand = "Refresh All Feeds"
    /// The toolbar button's spoken label.
    static let addFeedButtonLabel = "Add a podcast or article feed"
    /// The toolbar button's spoken hint.
    static let addFeedButtonHint = "Opens a sheet where you type a feed's address and choose where its folder goes"
    /// The Add Feed sheet's heading.
    static let addFeedTitle = "Add Feed"
    /// The address field's visible caption and spoken label.
    static let addressLabel = "Feed or web page address"
    /// The address field's spoken hint.
    static let addressHint = "Type or paste a feed's address, or the address of a web page that names its feed, then press Return"
    /// The line under the address field.
    static let addressHelp = "A podcast's or site's feed address, such as a link ending in .rss or .xml, or the address of a web page that names its feed."
    /// The folder picker's visible caption.
    static let folderCaption = "Put the feed's folder in"
    /// The folder picker's spoken label.
    static let folderLabel = "Folder to hold the feed's own folder"
    /// The line under the folder picker, naming the folder chosen.
    static func folderHelp(parentPath: String) -> String {
        let place = parentPath.isEmpty ? LibraryFolderOption.rootLabel : parentPath
        return "TextMouth makes a folder named after the feed in \(place), and its episodes and articles download into it."
    }
    /// The Subscribe button's title.
    static let subscribeTitle = "Subscribe"
    /// What the sheet shows, and VoiceOver hears, while it reads the address.
    static let checkingAddress = "Checking the address…"

    /// What the sheet says, and VoiceOver hears, when the address is a web
    /// page naming `count` feeds, so the listener chooses one.
    static func choosePrompt(count: Int) -> String {
        "That page names \(count) feeds. Choose one, then Subscribe."
    }
    /// The radio group's visible caption.
    static let chooseCaption = "Feeds on this page"
    /// The radio group's spoken label.
    static let chooseLabel = "Feeds on this page"
    /// The Back button's title, which returns to the address.
    static let backTitle = "Back"

    /// One feed a page names, as the radio group lists it: its title on the
    /// page and its address without the scheme, or the address alone when
    /// the page gives no title.
    static func linkTitle(_ link: FeedLink) -> String {
        let address = shortAddress(link.url)
        guard let title = link.title, !title.isEmpty else { return address }
        return "\(title), \(address)"
    }

    /// `url` as a listener reads it: its host and path, without the scheme
    /// or a trailing slash, and with its query, which some feed addresses
    /// need.
    static func shortAddress(_ url: URL) -> String {
        var path = url.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        let query = url.query.map { "?" + $0 } ?? ""
        return (url.host ?? url.absoluteString) + path + query
    }

    // MARK: Search

    /// The Search field's visible caption and spoken label.
    static let searchLabel = "Search for a podcast"
    /// The Search field's spoken hint.
    static let searchHint = "Type words from a podcast's title or its publisher's name, then press Return to search Apple's podcast directory"
    /// The Search button's title.
    static let searchButtonTitle = "Search"
    /// What the sheet shows, and VoiceOver hears, while it searches.
    static let searching = "Searching for podcasts…"

    /// What VoiceOver hears when a search for `term` found `count` podcasts:
    /// "3 podcasts found for “braille”."
    static func podcastsFound(count: Int, term: String) -> String {
        "\(CountWording.phrase(count, singular: "podcast", plural: "podcasts")) found for “\(term)”."
    }

    /// What the sheet says, and VoiceOver hears, when a search for `term`
    /// found nothing.
    static func noPodcastsFound(term: String) -> String {
        "No podcasts were found for “\(term)”. Try other words, or type the feed's address."
    }

    /// The spoken label of the list of podcasts found: "Search results, 3
    /// podcasts".
    static func searchResultsLabel(count: Int) -> String {
        "Search results, \(CountWording.phrase(count, singular: "podcast", plural: "podcasts"))"
    }

    /// The line under a podcast's title in the list: who publishes it and
    /// how many episodes it has, as far as the directory says ("by Small
    /// Hours Audio, 23 episodes"); nil when it says neither.
    static func searchResultDetails(_ result: FeedDirectoryResult) -> String? {
        var parts: [String] = []
        if let author = result.author {
            parts.append("by \(author)")
        }
        if let count = result.episodeCount {
            parts.append(CountWording.phrase(count, singular: "episode", plural: "episodes"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// A podcast found, as VoiceOver reads its row: its title, then the
    /// line under it ("Dots and Dashes, by Small Hours Audio, 23 episodes").
    static func searchResultLabel(_ result: FeedDirectoryResult) -> String {
        [result.title, searchResultDetails(result)].compactMap { $0 }.joined(separator: ", ")
    }

    /// The spoken label of a podcast's own Subscribe button.
    static func subscribeToResultLabel(_ result: FeedDirectoryResult) -> String {
        "Subscribe to \(result.title)"
    }

    /// The spoken hint of a podcast's own Subscribe button.
    static let subscribeToResultHint = "Puts this podcast's feed address in the address field and subscribes to it"

    // MARK: Nouns

    /// What a feed's items are called: episodes when they all offer audio
    /// or video, articles when none do, and items when the feed mixes them.
    enum ItemNoun: Hashable, Sendable {
        case episode
        case article
        case item

        /// The noun for `items`: episodes for none, as for a podcast with no
        /// episodes yet.
        static func of(_ items: [FeedItem]) -> ItemNoun {
            let articles = items.filter(\.isArticle).count
            if articles == 0 { return .episode }
            return articles == items.count ? .article : .item
        }

        /// The noun for one.
        var singular: String {
            switch self {
            case .episode: return "episode"
            case .article: return "article"
            case .item: return "item"
            }
        }

        /// The noun for any other count.
        var plural: String {
            singular + "s"
        }
    }

    /// `count` items of the kind `noun` names: "1 episode", "12 articles".
    static func count(_ count: Int, _ noun: ItemNoun) -> String {
        CountWording.phrase(count, singular: noun.singular, plural: noun.plural)
    }

    // MARK: A Feed's Size (October 7, 2026)

    /// The word that ends a feed's size when the library lists fewer of its
    /// entries than the feed does: "10 of 381 episodes listed". It is the
    /// "List and download" choice's own word, which decides how many are
    /// listed (FR11), so the words point at what changes the number; the
    /// user chose it over "kept" (question 10), since every record is kept
    /// now.
    static let listedNote = "listed"
    /// The words before the size of a feed longer than TextMouth reads
    /// (`FeedEntryTotal.listsMore`): "10 of more than 2000 episodes listed".
    static let moreThanNote = "more than"

    /// A feed's size as the library lists it, which every count of a feed
    /// starts with (`countsPhrase(_:)`): when the feed lists more entries
    /// than the library does (`FeedEntryTotal.exceeds(_:)`), the number
    /// listed of the feed's size, "10 of 381 episodes listed", "0 of 1
    /// episode listed", "10 of more than 2000 episodes listed", so the
    /// number listed is never taken for the feed's size; otherwise, or
    /// while the size is not known, the number listed alone, as it always
    /// read: "12 episodes", "1 article". The number comes first, as in
    /// every other count of a feed, and the noun agrees with the number
    /// before it. The screen and VoiceOver say the same words.
    static func sizePhrase(listed: Int, total: FeedEntryTotal?, noun: ItemNoun) -> String {
        guard let total, total.exceeds(listed) else { return count(listed, noun) }
        return "\(listed) of \(entriesPhrase(total, noun: noun)) \(listedNote)"
    }

    /// The size of the feed `counts` counts: its items listed of the
    /// entries it lists (`sizePhrase(listed:total:noun:)`).
    static func sizePhrase(_ counts: FeedItemCounts) -> String {
        sizePhrase(listed: counts.listed, total: counts.total, noun: counts.noun)
    }

    /// A feed's size as the words after "of" say it: its entries counted
    /// with `noun`, "381 episodes", "1 episode", or, without a noun, as a
    /// heading counts its rows, "381"; "more than" comes first for a feed
    /// longer than TextMouth reads.
    static func entriesPhrase(_ total: FeedEntryTotal, noun: ItemNoun?) -> String {
        let number = noun.map { count(total.count, $0) } ?? "\(total.count)"
        return total.listsMore ? "\(moreThanNote) \(number)" : number
    }

    // MARK: After Subscribing

    /// What VoiceOver hears once a subscription is made: the feed's size as
    /// its row says it, "Subscribed to Planet Money: 10 of 381 episodes
    /// listed.", or, listing every entry, "Subscribed to Planet Money: 12
    /// episodes."
    static func subscribed(title: String, counts: FeedItemCounts) -> String {
        "Subscribed to \(title): \(sizePhrase(counts))."
    }

    /// The plain-http warning's title.
    static let insecureTitle = "This Feed Uses Plain http"

    /// The plain-http warning shown once, right after subscribing to a feed
    /// that uses plain http (`Feed.usesInsecureTransport`), which also says
    /// the subscription was made.
    static func insecureMessage(title: String) -> String {
        "Subscribed to \(title). This feed uses plain http, so what it sends can be read or changed on the way; TextMouth still loads it."
    }
}

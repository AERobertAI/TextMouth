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

    // The Library menu's command is named by its action
    // (`ShortcutAction.addFeed.title`), one name for the menu, the Shortcuts
    // tab, and config.json.

    /// The Library menu's command that refreshes every feed now.
    static var refreshAllCommand: String {
        String(localized: "Refresh All Feeds",
               comment: "Title of the Library menu's command that refreshes every feed now. Title case.")
    }
    /// What Add Feed does, spoken as its hint in the Add to Library sheet.
    static var addFeedButtonHint: String {
        String(localized: "Opens a sheet where you type a feed's address and choose where its folder goes",
               comment: "VoiceOver hint of the Add Feed button in the Add to Library sheet.")
    }
    /// The Add Feed sheet's heading.
    static var addFeedTitle: String {
        String(localized: "Add Feed",
               comment: "Heading of the sheet where the listener subscribes to a feed. Title case.")
    }
    /// The address field's visible caption and spoken label.
    static var addressLabel: String {
        String(localized: "Feed or web page address",
               comment: "Caption and VoiceOver label of the field where the listener types a feed's address.")
    }
    /// The address field's spoken hint.
    static var addressHint: String {
        String(localized: "Type or paste a feed's address, or the address of a web page that names its feed, then press Return",
               comment: "VoiceOver hint of the field where the listener types a feed's address. Return is the Return key.")
    }
    /// The line under the address field.
    static var addressHelp: String {
        String(localized: "A podcast's or site's feed address, such as a link ending in .rss or .xml, or the address of a web page that names its feed.",
               comment: "The line under the address field of the Add Feed sheet. .rss and .xml are file extensions.")
    }
    /// The folder picker's visible caption.
    static var folderCaption: String {
        String(localized: "Put the feed's folder in",
               comment: "Caption of the folder picker of the Add Feed sheet: the library folder that will hold the feed's own folder.")
    }
    /// The folder picker's spoken label.
    static var folderLabel: String {
        String(localized: "Folder to hold the feed's own folder",
               comment: "VoiceOver label of the folder picker of the Add Feed sheet.")
    }
    /// The line under the folder picker, naming the folder chosen.
    static func folderHelp(parentPath: String) -> String {
        let place = parentPath.isEmpty ? LibraryFolderOption.rootLabel : parentPath
        return String(localized: "TextMouth makes a folder named after the feed in \(place), and its episodes and articles download into it.",
                      comment: "The line under the folder picker of the Add Feed sheet. %@ is the library folder chosen, or the name of the library's top level.")
    }
    /// The Subscribe button's title.
    static var subscribeTitle: String {
        String(localized: "Subscribe",
               comment: "Title of the button that subscribes to a feed, in the Add Feed sheet.")
    }
    /// What the sheet shows, and VoiceOver hears, while it reads the address.
    static var checkingAddress: String {
        String(localized: "Checking the address…",
               comment: "What the Add Feed sheet shows and VoiceOver says while it reads the address typed.")
    }

    /// What the sheet says, and VoiceOver hears, when the address is a web
    /// page naming `count` feeds, so the listener chooses one.
    static func choosePrompt(count: Int) -> String {
        String(localized: "That page names \(count) feeds. Choose one, then Subscribe.",
               comment: "What the Add Feed sheet says when a web page names several feeds. %lld is how many feeds the page names. Subscribe is the name of the Subscribe button.")
    }
    /// The radio group's visible caption.
    static var chooseCaption: String {
        String(localized: "Feeds on this page",
               comment: "Caption of the choice of feeds a web page names, in the Add Feed sheet.")
    }
    /// The radio group's spoken label.
    static var chooseLabel: String { chooseCaption }
    /// The Back button's title, which returns to the address.
    static var backTitle: String {
        String(localized: "Back",
               comment: "Title of the button that returns to the address field in the Add Feed sheet.")
    }

    /// One feed a page names, as the radio group lists it: its title on the
    /// page and its address without the scheme, or the address alone when
    /// the page gives no title.
    static func linkTitle(_ link: FeedLink) -> String {
        let address = shortAddress(link.url)
        guard let title = link.title, !title.isEmpty else { return address }
        return SentenceWording.commaJoined([title, address])
    }

    /// `url` as a listener reads it: its host and path, without the scheme
    /// or a trailing slash, and with its query, which some feed addresses
    /// need.
    static func shortAddress(_ url: URL) -> String {
        var path = url.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        let query = url.query.map { "?" + $0 } ?? "" // l10n: no (a web address's own punctuation)
        return (url.host ?? url.absoluteString) + path + query
    }

    // MARK: Search

    /// The Search field's visible caption and spoken label.
    static var searchLabel: String {
        String(localized: "Search for a podcast",
               comment: "Caption and VoiceOver label of the field where the listener searches Apple's podcast directory.")
    }
    /// The Search field's spoken hint.
    static var searchHint: String {
        String(localized: "Type words from a podcast's title or its publisher's name, then press Return to search Apple's podcast directory",
               comment: "VoiceOver hint of the podcast search field. Return is the Return key.")
    }
    /// The Search button's title.
    static var searchButtonTitle: String {
        String(localized: "Search",
               comment: "Title of the button that searches Apple's podcast directory.")
    }
    /// What the sheet shows, and VoiceOver hears, while it searches.
    static var searching: String {
        String(localized: "Searching for podcasts…",
               comment: "What the Add Feed sheet shows and VoiceOver says while a podcast search runs.")
    }

    /// What VoiceOver hears when a search for `term` found `count` podcasts:
    /// "3 podcasts found for “braille”."
    static func podcastsFound(count: Int, term: String) -> String {
        String(localized: "\(count) podcasts found for “\(term)”.",
               comment: "What VoiceOver says when a podcast search found podcasts. %lld is how many; %@ is the words searched for.")
    }

    /// What the sheet says, and VoiceOver hears, when a search for `term`
    /// found nothing.
    static func noPodcastsFound(term: String) -> String {
        String(localized: "No podcasts were found for “\(term)”. Try other words, or type the feed's address.",
               comment: "What the Add Feed sheet says when a podcast search found nothing. %@ is the words searched for.")
    }

    /// The spoken label of the list of podcasts found: "Search results, 3
    /// podcasts".
    static func searchResultsLabel(count: Int) -> String {
        String(localized: "Search results, \(count) podcasts",
               comment: "VoiceOver label of the list of podcasts a search found. %lld is how many podcasts.")
    }

    /// The line under a podcast's title in the list: who publishes it and
    /// how many episodes it has, as far as the directory says ("by Small
    /// Hours Audio, 23 episodes"); nil when it says neither.
    static func searchResultDetails(_ result: FeedDirectoryResult) -> String? {
        var parts: [String] = []
        if let author = result.author {
            parts.append(String(localized: "by \(author)",
                                comment: "Who publishes a podcast, in the line under its title in the search results. %@ is the publisher's name."))
        }
        if let count = result.episodeCount {
            parts.append(CountWording.episodes(count))
        }
        return parts.isEmpty ? nil : SentenceWording.commaJoined(parts)
    }

    /// A podcast found, as VoiceOver reads its row: its title, then the
    /// line under it ("Dots and Dashes, by Small Hours Audio, 23 episodes").
    static func searchResultLabel(_ result: FeedDirectoryResult) -> String {
        SentenceWording.commaJoined([result.title, searchResultDetails(result)].compactMap { $0 })
    }

    /// The spoken label of a podcast's own Subscribe button.
    static func subscribeToResultLabel(_ result: FeedDirectoryResult) -> String {
        String(localized: "Subscribe to \(result.title)",
               comment: "VoiceOver label of the Subscribe button of one podcast in the search results. %@ is the podcast's title.")
    }

    /// The spoken hint of a podcast's own Subscribe button.
    static var subscribeToResultHint: String {
        String(localized: "Puts this podcast's feed address in the address field and subscribes to it",
               comment: "VoiceOver hint of the Subscribe button of one podcast in the search results.")
    }

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

    }

    /// `count` items of the kind `noun` names: "1 episode", "12 articles".
    static func count(_ count: Int, _ noun: ItemNoun) -> String {
        switch noun {
        case .episode: return CountWording.episodes(count)
        case .article: return CountWording.articles(count)
        case .item:
            return String(localized: "\(count) items",
                          comment: "A count of a feed's items when it holds both episodes and articles. %lld is the number of items.")
        }
    }

    // MARK: A Feed's Size (October 7, 2026)

    /// The word that ends a feed's size when the library lists fewer of its
    /// entries than the feed does: "10 of 381 episodes listed". It is the
    /// "List and download" choice's own word, which decides how many are
    /// listed (FR11), so the words point at what changes the number; the
    /// user chose it over "kept" (question 10), since every record is kept
    /// now.

    /// The words before the size of a feed longer than TextMouth reads
    /// (`FeedEntryTotal.listsMore`): "10 of more than 2000 episodes listed".


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
        return String(localized: "\(listed) of \(entriesPhrase(total, noun: noun)) listed",
                      comment: "A feed's size when the library lists fewer entries than the feed has. The first %lld is how many are listed; %@ is the feed's size with its noun, such as \"381 episodes\" or \"more than 2000 episodes\".")
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
        let number = noun.map { count(total.count, $0) } ?? total.count.formatted()
        guard total.listsMore else { return number }
        return String(localized: "more than \(number)",
                      comment: "A feed's size when it is longer than TextMouth reads. %@ is the size, such as \"2000 episodes\" or just \"2000\".")
    }

    // MARK: After Subscribing

    /// What VoiceOver hears once a subscription is made: the feed's size as
    /// its row says it, "Subscribed to Planet Money: 10 of 381 episodes
    /// listed.", or, listing every entry, "Subscribed to Planet Money: 12
    /// episodes."
    static func subscribed(title: String, counts: FeedItemCounts) -> String {
        String(localized: "Subscribed to \(title): \(sizePhrase(counts)).",
               comment: "What VoiceOver says once a subscription is made. The first %@ is the feed's title; the second is the feed's size, such as \"10 of 381 episodes listed\" or \"12 episodes\".")
    }

    /// The plain-http warning's title.
    static var insecureTitle: String {
        String(localized: "This Feed Uses Plain http",
               comment: "Title of the warning shown once after subscribing to a feed whose address uses plain http, which is not encrypted. Title case.")
    }

    /// The plain-http warning shown once, right after subscribing to a feed
    /// that uses plain http (`Feed.usesInsecureTransport`), which also says
    /// the subscription was made.
    static func insecureMessage(title: String) -> String {
        String(localized: "Subscribed to \(title). This feed uses plain http, so what it sends can be read or changed on the way; TextMouth still loads it.",
               comment: "The warning shown once after subscribing to a feed whose address uses plain http. %@ is the feed's title.")
    }
}

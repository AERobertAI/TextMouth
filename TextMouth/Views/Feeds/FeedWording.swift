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

    // MARK: Nouns

    /// What a feed's items are called: episodes when they all offer audio
    /// or video, articles when none do, and items when the feed mixes them.
    enum ItemNoun: Equatable, Sendable {
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

    // MARK: After Subscribing

    /// What VoiceOver hears once a subscription is made: "Subscribed to
    /// Planet Money: 12 episodes."
    static func subscribed(title: String, itemCount: Int, noun: ItemNoun) -> String {
        "Subscribed to \(title): \(count(itemCount, noun))."
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

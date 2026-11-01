import Foundation

/// Every word the listening options' controls say and speak (FR19): the
/// three controls of a feed's Feed Info and of a folder's settings sheet,
/// their choices, and their hints. One place, so the two sheets say the
/// same thing and a test pins each string, since the listener hears them
/// through VoiceOver and reads them in braille.
enum ListeningOptionsWording {

    // MARK: Nouns

    /// What the items that follow one another are called: a feed's episodes,
    /// articles, or items, or a plain folder's books.
    enum Noun: Hashable, Sendable {
        case episode
        case article
        case item
        case book

        /// The noun for a feed whose items are called `feedNoun`
        /// (`FeedWording.ItemNoun`).
        init(_ feedNoun: FeedWording.ItemNoun) {
            switch feedNoun {
            case .episode: self = .episode
            case .article: self = .article
            case .item: self = .item
            }
        }

        /// The noun for one: "episode".
        var singular: String {
            switch self {
            case .episode: return "episode"
            case .article: return "article"
            case .item: return "item"
            case .book: return "book"
            }
        }

        /// The noun for any other count: "episodes".
        var plural: String { singular + "s" }

        /// The word before the noun for one: "an episode", "a book".
        var article: String { self == .book ? "a" : "an" }

        /// Whose items they are: "this feed's" for a feed's, "this
        /// folder's" for a folder's.
        var owner: String { self == .book ? "this folder's" : "this feed's" }

        /// Where the one below and the one above are found: "the list" for
        /// a feed's items, "the folder" for a folder's books.
        fileprivate var place: String { self == .book ? "the folder" : "the list" }
    }

    // MARK: When an Item Ends

    /// The label of the choice of what happens when an item ends: "When an
    /// episode ends", "When a book ends".
    static func continuationLabel(_ noun: Noun) -> String {
        "When \(noun.article) \(noun.singular) ends"
    }

    /// The name of one choice of what happens when an item ends. The choice
    /// of nil is "Use the global setting", which names the global
    /// setting's own value in parentheses, since the choice means whatever
    /// that is: "Use the global setting (Continue to Next Book)".
    static func continuationTitle(
        _ choice: ReadingList.Continuation?,
        noun: Noun,
        global: EndOfBookBehavior
    ) -> String {
        switch choice {
        case nil: return "Use the global setting (\(global.rawValue))"
        case .playBookBelow: return "Play the \(noun.singular) below"
        case .playBookAbove: return "Play the \(noun.singular) above"
        case .stop: return "Stop"
        }
    }

    /// The hint of the choice of what happens when an item ends.
    static func continuationHint(_ noun: Noun) -> String {
        "What happens when one of \(noun.owner) \(noun.plural) ends: "
            + "play the \(noun.singular) below it or the one above it in \(noun.place), "
            + "stop, or follow the global setting"
    }

    // MARK: Skipping Finished Items

    /// The label of the switch that passes over finished items: "Skip
    /// finished episodes".
    static func skipFinishedLabel(_ noun: Noun) -> String {
        "Skip finished \(noun.plural)"
    }

    /// The hint of the switch that passes over finished items.
    static func skipFinishedHint(_ noun: Noun) -> String {
        "When listening goes on to another \(noun.singular), pass over the \(noun.plural) already finished"
    }

    // MARK: Downloading the Next Item

    /// The label of the switch that downloads the next item before the
    /// playing one ends: "Download the next episode before this one ends".
    static func predownloadLabel(_ noun: Noun) -> String {
        "Download the next \(noun.singular) before this one ends"
    }

    /// The hint of the switch that downloads the next item. While listening
    /// does not go on from one item to another, the switch can do nothing,
    /// and the hint says when it is available instead of what it does.
    static func predownloadHint(_ noun: Noun, enabled: Bool) -> String {
        guard enabled else {
            return "Available only while \(noun.owner) \(noun.plural) go on to another \(noun.singular) when one ends"
        }
        let lead = Int(ListeningOptions.predownloadLeadTime / 60)
        return "When \(CountWording.minutes(lead)) or less of the \(noun.singular) playing are left, "
            + "download the \(noun.singular) that plays next, if it is not on this Mac yet"
    }
}

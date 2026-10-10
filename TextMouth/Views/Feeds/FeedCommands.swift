import SwiftUI

// MARK: - The Feed Reader's Commands (FR03)

/// A command for a whole feed (FR03), offered by its row in the Feeds
/// section and by its folder's row, in the context menu and as a VoiceOver
/// action under the same name.
enum FeedCommand: Hashable, Sendable {
    /// Check Feed: refreshes the feed now.
    case checkFeed
    /// Feed Info…: shows what the feed says of itself, and its own settings.
    case feedInfo
    /// Mark All Played: marks every item played.
    case markAllPlayed
    /// Unsubscribe…: ends the subscription, after a confirmation.
    case unsubscribe
}

/// One feed command, as a menu or a row's VoiceOver actions offer it.
struct FeedAction: Identifiable, Equatable, Sendable {
    /// What the command does.
    let command: FeedCommand
    /// The feed it acts on.
    let feedID: UUID
    /// Its title in the menu, which is also its VoiceOver action's name.
    let title: String

    /// A row offers each command at most once, so the command identifies it.
    var id: FeedCommand { command }

    /// The command's role in a menu: Unsubscribe ends something, and says
    /// so.
    var role: ButtonRole? {
        command == .unsubscribe ? .destructive : nil
    }

    /// The commands for the feed `feedID`, whose items are called `noun`, in
    /// menu order. Every one is always offered: Mark All Played with nothing
    /// left to mark says so.
    static func actions(for feedID: UUID, noun: FeedWording.ItemNoun) -> [FeedAction] {
        [
            FeedAction(command: .checkFeed, feedID: feedID, title: FeedWording.checkFeedTitle),
            FeedAction(command: .feedInfo, feedID: feedID, title: FeedWording.feedInfoTitle),
            FeedAction(command: .markAllPlayed, feedID: feedID, title: FeedWording.markAllPlayedTitle(noun)),
            FeedAction(command: .unsubscribe, feedID: feedID, title: FeedWording.unsubscribeTitle),
        ]
    }
}

/// A command for one of a feed's items (FR03), offered by its row: an item
/// row, or, for an item downloaded into its feed's folder, its book's row,
/// beside the book's own commands.
enum FeedItemCommand: Hashable, Sendable {
    /// Open: opens the item's book, downloading it first when needed.
    case open
    /// Download: downloads the item, or tries a failed download again.
    case download
    /// Cancel Download: stops the item's download, or takes it from the
    /// queue.
    case cancelDownload
    /// Delete Download: deletes the item's book and keeps the item.
    case deleteDownload
    /// Mark Played (an article: Mark Read).
    case markPlayed
    /// Mark Unplayed (an article: Mark Unread).
    case markUnplayed
    /// Show Description…: the item's text in a sheet.
    case showDescription
    /// Show in Finder: the item's book's package in Finder.
    case showInFinder
    /// Delete Episode… (an article: Delete Article…): hides the item for
    /// good, after a confirmation.
    case deleteItem
}

/// One item command, as a menu or a row's VoiceOver actions offer it.
struct FeedItemAction: Identifiable, Equatable, Sendable {
    /// What the command does.
    let command: FeedItemCommand
    /// The feed the item belongs to.
    let feedID: UUID
    /// The item's identity.
    let itemID: FeedItem.ID
    /// The item's title, which announcements and confirmations name.
    let itemTitle: String
    /// Whether the item is an article rather than an episode.
    let isArticle: Bool
    /// Its title in the menu, which is also its VoiceOver action's name.
    let title: String

    /// A row offers each command at most once, so the command identifies it.
    var id: FeedItemCommand { command }

    /// The command's role in a menu: Delete Episode hides the item for
    /// good, and says so.
    var role: ButtonRole? {
        command == .deleteItem ? .destructive : nil
    }

    /// The commands an item offers, in menu order, by where its download
    /// stands:
    /// - Open, on an item row (a book's row has its own);
    /// - Download for an item not downloaded, whose download failed, or
    ///   whose download the newest-N rule put off (FR11), which downloads it
    ///   now, and Cancel Download for one waiting in the queue or
    ///   downloading;
    /// - Mark Played for an unplayed item, or Mark Unplayed;
    /// - Show Description…;
    /// - for a downloaded item, Show in Finder on an item row (a book's row
    ///   has its own), and Delete Download;
    /// - Delete Episode….
    /// - Parameters:
    ///   - onBookRow: Whether the commands are for a downloaded item's book's
    ///     row, which offers Open and Show in Finder itself.
    static func actions(
        feedID: UUID,
        itemID: FeedItem.ID,
        itemTitle: String,
        state: FeedItemState,
        isPlayed: Bool,
        isArticle: Bool,
        onBookRow: Bool = false
    ) -> [FeedItemAction] {
        var commands: [FeedItemCommand] = []
        if !onBookRow {
            commands.append(.open)
        }
        switch state {
        case .notDownloaded, .waiting, .failed:
            commands.append(.download)
        case .downloading:
            commands.append(.cancelDownload)
        case .downloaded:
            break
        }
        commands.append(isPlayed ? .markUnplayed : .markPlayed)
        commands.append(.showDescription)
        if state.bookID != nil {
            if !onBookRow {
                commands.append(.showInFinder)
            }
            commands.append(.deleteDownload)
        }
        commands.append(.deleteItem)
        return commands.map { command in
            FeedItemAction(
                command: command,
                feedID: feedID,
                itemID: itemID,
                itemTitle: itemTitle,
                isArticle: isArticle,
                title: FeedWording.title(of: command, isArticle: isArticle)
            )
        }
    }

    /// The commands of the item row showing `content`.
    static func actions(for content: FeedItemRowContent) -> [FeedItemAction] {
        actions(
            feedID: content.feedID,
            itemID: content.id,
            itemTitle: content.title,
            state: content.state,
            isPlayed: content.isPlayed,
            isArticle: content.isArticle
        )
    }
}

// MARK: - The Commands' Words

extension FeedWording {
    /// Check Feed's title.
    static let checkFeedTitle = "Check Feed"
    /// Feed Info's title.
    static let feedInfoTitle = "Feed Info…"
    /// Unsubscribe's title.
    static let unsubscribeTitle = "Unsubscribe…"

    /// Mark All Played's title, or Mark All Read's for a feed of articles.
    static func markAllPlayedTitle(_ noun: ItemNoun) -> String {
        noun == .article ? "Mark All Read" : "Mark All Played"
    }

    /// The title of the item command `command`, for an article when
    /// `isArticle`.
    static func title(of command: FeedItemCommand, isArticle: Bool) -> String {
        switch command {
        case .open: return "Open"
        case .download: return "Download"
        case .cancelDownload: return "Cancel Download"
        case .deleteDownload: return "Delete Download"
        case .markPlayed: return isArticle ? "Mark Read" : "Mark Played"
        case .markUnplayed: return isArticle ? "Mark Unread" : "Mark Unplayed"
        case .showDescription: return "Show Description…"
        case .showInFinder: return "Show in Finder"
        case .deleteItem: return deleteItemButton(isArticle: isArticle) + "…"
        }
    }

    // MARK: Checking

    /// What VoiceOver hears once Check Feed has checked the feed titled
    /// `title`: how many new items it brought, or why it failed.
    static func checked(_ report: FeedRefreshReport, noun: ItemNoun) -> String {
        switch report.outcome {
        case .updated(let newItemIDs) where !newItemIDs.isEmpty:
            return "\(report.feedTitle): \(newItemIDs.count) new \(newItemIDs.count == 1 ? noun.singular : noun.plural)."
        case .updated, .unchanged, .skipped:
            return "\(report.feedTitle): no new \(noun.plural)."
        case .failed(let message):
            return message
        }
    }

    /// What VoiceOver hears as Check Feed starts.
    static func checking(title: String) -> String {
        "Checking \(title)…"
    }

    // MARK: Marking

    /// What VoiceOver hears once Mark All Played marked `count` items of the
    /// feed titled `title`, or found none to mark.
    static func markedAll(count: Int, title: String, noun: ItemNoun) -> String {
        let played = noun == .article ? "read" : "played"
        guard count > 0 else { return "Every \(noun.singular) of \(title) is already \(played)." }
        return "Marked \(FeedWording.count(count, noun)) of \(title) \(played)."
    }

    /// What VoiceOver hears once an item is marked played or unplayed.
    static func marked(title: String, played: Bool, isArticle: Bool) -> String {
        let word = played ? playedNote(isArticle: isArticle).lowercased() : (isArticle ? "unread" : "unplayed")
        return "Marked “\(title)” \(word)."
    }

    // MARK: Downloads

    /// What VoiceOver hears as Download starts.
    static func downloading(title: String) -> String {
        "Downloading “\(title)”."
    }

    /// What VoiceOver hears once Cancel Download stopped a download.
    static func downloadCancelled(title: String) -> String {
        "Stopped downloading “\(title)”."
    }

    /// What VoiceOver hears once Delete Download deleted a download.
    static func downloadDeleted(title: String) -> String {
        "Deleted the download of “\(title)”. It can be downloaded again."
    }

    /// The title of the alert saying why a download, or an item, could not
    /// be deleted.
    static let deleteRefusedTitle = "Couldn't Delete"

    // MARK: Deleting an Item

    /// The confirmation's button, which the menu's command names with an
    /// ellipsis, as it asks first: "Delete Episode", or "Delete Article".
    static func deleteItemButton(isArticle: Bool) -> String {
        isArticle ? "Delete Article" : "Delete Episode"
    }

    /// The title of the confirmation before Delete Episode or Delete
    /// Article.
    static func deleteItemQuestion(title: String) -> String {
        "Delete “\(title)”?"
    }

    /// The confirmation's message, saying what deleting does.
    static func deleteItemMessage(isArticle: Bool) -> String {
        let kind = isArticle ? "article" : "episode"
        return "The \(kind) leaves the list for good, and its download, if any, is deleted. Checking the feed won't bring it back."
    }

    /// What VoiceOver hears once an item is deleted.
    static func itemDeleted(title: String) -> String {
        "Deleted “\(title)”."
    }

    // MARK: Unsubscribing

    /// The title of the confirmation before Unsubscribe.
    static func unsubscribeQuestion(title: String) -> String {
        "Unsubscribe from \(title)?"
    }

    /// The Unsubscribe confirmation's button.
    static let unsubscribeButton = "Unsubscribe"

    /// The Unsubscribe confirmation's message: TextMouth stops checking the
    /// feed, and the books its downloads made stay where they are, named,
    /// the first three by title, as books. When the feed kept the places of
    /// `keptCount` downloads removed earlier (FR11, branch A2), the message
    /// ends by saying those go (REV10, item 3).
    static func unsubscribeMessage(bookTitles: [String], folderPath: String?, keptCount: Int = 0) -> String {
        let stops = "TextMouth stops checking this feed and forgets the items it hasn't downloaded."
        let place = folderPath.map { " in \($0)" } ?? ""
        let keptGo = keptRecordsDeleted(count: keptCount)
        guard !bookTitles.isEmpty else {
            return "\(stops) Nothing it downloaded is left\(folderPath == nil ? "" : "; its folder stays\(place)").\(keptGo)"
        }
        let shown = bookTitles.prefix(3).map { "“\($0)”" }
        let rest = bookTitles.count - shown.count
        let names = rest > 0
            ? shown.joined(separator: ", ") + ", and \(rest) more"
            : LibraryCloudWording.list(Array(shown))
        let these = bookTitles.count == 1 ? "This book it downloaded stays" : "These \(bookTitles.count) books it downloaded stay"
        return "\(stops) \(these)\(place): \(names).\(keptGo)"
    }

    /// The Unsubscribe confirmation's last sentence, with a space before it,
    /// when the feed kept what the listener had of `count` downloads removed
    /// earlier, which unsubscribing deletes; empty when it kept none.
    private static func keptRecordsDeleted(count: Int) -> String {
        guard count > 0 else { return "" }
        return count == 1
            ? " It also deletes the place, bookmarks, and transcript kept for 1 removed download."
            : " It also deletes the places, bookmarks, and transcripts kept for \(count) removed downloads."
    }

    /// What VoiceOver hears once a feed is unsubscribed from.
    static func unsubscribed(title: String, bookCount: Int) -> String {
        guard bookCount > 0 else { return "Unsubscribed from \(title)." }
        return "Unsubscribed from \(title). \(CountWording.phrase(bookCount, singular: "book it downloaded stays", plural: "books it downloaded stay")) in the library."
    }
}

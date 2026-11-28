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
    /// Unsubscribe…: stops checking the feed, after a confirmation (FR11,
    /// branch D); the feed stays.
    case unsubscribe
    /// Resubscribe: checks an unsubscribed feed again, from now on and at
    /// once (FR11, branch D).
    case resubscribe
    /// Delete Feed…: deletes the feed entirely, after a confirmation, the
    /// one command that does (FR14).
    case deleteFeed
}

/// One feed command, as a menu or a row's VoiceOver actions offer it.
struct FeedAction: Identifiable, Equatable, Sendable {
    /// What the command does.
    let command: FeedCommand
    /// The feed it acts on.
    let feedID: UUID
    /// Its title in the menu, which is also its VoiceOver action's name.
    let title: String
    /// Whether the command deletes something of the listener's, which it
    /// asks about first: Delete Feed… (FR14), and Unsubscribe… while the feed
    /// keeps places for removed downloads (FR11, branch D).
    var deletes = false

    /// A row offers each command at most once, so the command identifies it.
    var id: FeedCommand { command }

    /// The command's role in a menu: destructive for one that deletes
    /// something of the listener's, and says so.
    var role: ButtonRole? {
        deletes ? .destructive : nil
    }

    /// The commands for the feed `feedID`, whose items are called `noun`, in
    /// menu order, by whether the listener `isSubscribed` to it (FR11,
    /// branch D, the listener's "subscribe / resubscribe toggling action in
    /// the context menu for feeds"): Check Feed, Feed Info…, Mark All
    /// Played, and Unsubscribe for a subscribed feed; Feed Info…, Mark All
    /// Played, and Resubscribe for an unsubscribed one, which is not
    /// checked; and, last for both, Delete Feed…, the one command that
    /// deletes a feed (FR14). Unsubscribe is "Unsubscribe…", asking first,
    /// only when `unsubscribeAsks`, as it would delete the places the feed
    /// kept for removed downloads (FR14). Mark All Played with nothing left
    /// to mark says so.
    static func actions(
        for feedID: UUID,
        noun: FeedWording.ItemNoun,
        isSubscribed: Bool = true,
        unsubscribeAsks: Bool = true
    ) -> [FeedAction] {
        let markAll = FeedAction(command: .markAllPlayed, feedID: feedID, title: FeedWording.markAllPlayedTitle(noun))
        let info = FeedAction(command: .feedInfo, feedID: feedID, title: FeedWording.feedInfoTitle)
        let delete = FeedAction(command: .deleteFeed, feedID: feedID, title: FeedWording.deleteFeedTitle, deletes: true)
        guard isSubscribed else {
            return [info, markAll, FeedAction(command: .resubscribe, feedID: feedID, title: FeedWording.resubscribeTitle), delete]
        }
        return [
            FeedAction(command: .checkFeed, feedID: feedID, title: FeedWording.checkFeedTitle),
            info,
            markAll,
            FeedAction(
                command: .unsubscribe,
                feedID: feedID,
                title: FeedWording.unsubscribeTitle(asksFirst: unsubscribeAsks),
                deletes: unsubscribeAsks
            ),
            delete,
        ]
    }

    /// The commands for the feed `feedID` as `counts` count it: its items'
    /// noun, whether the listener is subscribed, and whether Unsubscribe
    /// would delete places kept for removed downloads, so asks first
    /// (`actions(for:noun:isSubscribed:unsubscribeAsks:)`).
    static func actions(for feedID: UUID, counts: FeedItemCounts) -> [FeedAction] {
        actions(
            for: feedID,
            noun: counts.noun,
            isSubscribed: counts.isSubscribed,
            unsubscribeAsks: counts.keptForRemovedDownloads > 0
        )
    }

    /// The commands for the feed `feedID` of `center` as it is now
    /// (`actions(for:counts:)`).
    @MainActor
    static func actions(for feedID: UUID, in center: FeedCenter) -> [FeedAction] {
        actions(for: feedID, counts: center.counts(of: feedID))
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
    /// Move to Library…: moves the item's download out of its feed into a
    /// folder of the library, as a book of its own, after asking which
    /// folder (FR11, branch D).
    case moveToLibrary
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
    ///   now; Cancel Download for one waiting in the queue or downloading,
    ///   and for one the rule put off, which then waits no more and is left
    ///   to the listener (FR11, branch C);
    /// - Mark Played for an unplayed item, or Mark Unplayed;
    /// - Show Description…;
    /// - Move to Library…, for a download in its feed's folder on its book's
    ///   row (`canMoveToLibrary`, FR11, branch D);
    /// - for a downloaded item, Show in Finder on an item row (a book's row
    ///   has its own), and Delete Download;
    /// - Delete Episode….
    ///
    /// An item moved into the library (FR11, branch D) offers Open, which
    /// opens its book there, Mark Played or Unplayed, Show Description…, and
    /// Delete Episode…, which hides its row and leaves the book: nothing
    /// downloads it again.
    /// - Parameters:
    ///   - onBookRow: Whether the commands are for a downloaded item's book's
    ///     row, which offers Open and Show in Finder itself.
    ///   - canMoveToLibrary: Whether the item's download, its book's row's
    ///     book, is its feed's, which Move to Library… can move.
    static func actions(
        feedID: UUID,
        itemID: FeedItem.ID,
        itemTitle: String,
        state: FeedItemState,
        isPlayed: Bool,
        isArticle: Bool,
        onBookRow: Bool = false,
        canMoveToLibrary: Bool = false
    ) -> [FeedItemAction] {
        var commands: [FeedItemCommand] = []
        if !onBookRow {
            commands.append(.open)
        }
        switch state {
        case .notDownloaded, .failed:
            commands.append(.download)
        case .waiting:
            commands += [.download, .cancelDownload]
        case .downloading:
            commands.append(.cancelDownload)
        case .downloaded, .inLibrary:
            break
        }
        commands.append(isPlayed ? .markUnplayed : .markPlayed)
        commands.append(.showDescription)
        if canMoveToLibrary, state.bookID != nil {
            commands.append(.moveToLibrary)
        }
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

    /// The Open command of the item row showing `content`, which the row's
    /// default action (VoiceOver's VO-Space) and Return both run: it opens
    /// the item's book, downloading the item first when needed. Every item
    /// row offers it.
    static func open(for content: FeedItemRowContent) -> FeedItemAction? {
        actions(for: content).first { $0.command == .open }
    }
}

// MARK: - The Commands' Words

extension FeedWording.ItemNoun {
    /// The text for this noun, which only the case that matches is asked
    /// for: a sentence that names the feed's items is written whole for each
    /// noun, so every language agrees its words with the noun.
    func choose(
        episode: @autoclosure () -> String,
        article: @autoclosure () -> String,
        item: @autoclosure () -> String
    ) -> String {
        switch self {
        case .episode: return episode()
        case .article: return article()
        case .item: return item()
        }
    }
}

extension FeedWording {
    /// Check Feed's title.
    static var checkFeedTitle: String {
        // Translators: Title of the command that checks a feed for new items now, in a feed's menu and among its VoiceOver actions. Title case.
        InterfaceText.line("feed.checkFeedTitle", "Check Feed")
    }
    /// Feed Info's title.
    static var feedInfoTitle: String {
        // Translators: Title of the command that shows a feed's information and its own settings, in a feed's menu and among its VoiceOver actions. The ellipsis says a sheet follows. Title case.
        InterfaceText.line("feed.feedInfoTitle", "Feed Info…")
    }
    /// The name of the Feed Info sheet, as a sentence names it.
    static var feedInfoName: String {
        // Translators: The name of the Feed Info command or sheet, without its ellipsis, as a sentence names it. Title case.
        InterfaceText.line("feed.feedInfoName", "Feed Info")
    }

    /// Unsubscribe's title: "Unsubscribe…" when it asks first, as it would
    /// delete the places the feed kept for removed downloads, and
    /// "Unsubscribe", with no ellipsis, when it acts at once (FR14).
    static func unsubscribeTitle(asksFirst: Bool) -> String {
        asksFirst
            // Translators: Title of the command that stops checking a feed, when it asks first because it would delete places and bookmarks kept for removed downloads. The ellipsis says a question follows. Title case.
            ? InterfaceText.line("feed.unsubscribeTitle", "Unsubscribe…")
            : unsubscribeButton
    }
    /// Resubscribe's title (FR11, branch D): no ellipsis, since it asks
    /// nothing first.
    static var resubscribeTitle: String {
        // Translators: Title of the command that checks an unsubscribed feed again, in a feed's menu and among its VoiceOver actions. Title case.
        InterfaceText.line("feed.resubscribeTitle", "Resubscribe")
    }

    /// Mark All Played's title, or Mark All Read's for a feed of articles.
    static func markAllPlayedTitle(_ noun: ItemNoun) -> String {
        noun == .article
            // Translators: Title of the command that marks every article of a feed read. Title case.
            ? InterfaceText.line("feed.markAllPlayedTitle.read", "Mark All Read")
            // Translators: Title of the command that marks every episode of a feed played. Title case.
            : InterfaceText.line("feed.markAllPlayedTitle.forPlayback", "Mark All Played")
    }

    /// The title of the item command `command`, for an article when
    /// `isArticle`.
    static func title(of command: FeedItemCommand, isArticle: Bool) -> String {
        switch command {
        case .open:
            // Translators: Title of the command that opens a feed item's book, downloading it first when needed. Title case.
            return InterfaceText.line("common.open", "Open")
        case .download:
            // Translators: Title of the command that downloads a feed item, or tries a failed download again. Title case.
            return InterfaceText.line("common.download", "Download")
        case .cancelDownload:
            // Translators: Title of the command that stops a feed item's download. Title case.
            return InterfaceText.line("common.cancelDownload", "Cancel Download")
        case .deleteDownload:
            // Translators: Title of the command that deletes a feed item's downloaded book and keeps the item. Title case.
            return InterfaceText.line("common.deleteDownload", "Delete Download")
        case .markPlayed:
            return isArticle
                // Translators: Title of the command that marks a feed's article read. Title case.
                ? InterfaceText.line("feed.title.markPlayed.read", "Mark Read")
                // Translators: Title of the command that marks a feed's episode played. Title case.
                : InterfaceText.line("feed.title.markPlayed.episode", "Mark Played")
        case .markUnplayed:
            return isArticle
                // Translators: Title of the command that marks a feed's article unread. Title case.
                ? InterfaceText.line("feed.title.markUnplayed.unread", "Mark Unread")
                // Translators: Title of the command that marks a feed's episode unplayed. Title case.
                : InterfaceText.line("feed.title.markUnplayed.episode", "Mark Unplayed")
        case .showDescription:
            // Translators: Title of the command that shows a feed item's text in a sheet. The ellipsis says a sheet follows. Title case.
            return InterfaceText.line("feed.title.showDescription", "Show Description…")
        case .moveToLibrary: return ShortcutAction.moveToLibrary.title
        case .showInFinder:
            // Translators: Title of the command that shows a feed item's book in Finder. Title case.
            return InterfaceText.line("common.showInFinder", "Show in Finder")
        case .deleteItem: return deleteItemTitle(isArticle: isArticle)
        }
    }

    // MARK: Checking

    /// What VoiceOver hears once Check Feed has checked the feed titled
    /// `title`: how many new items it brought, or why it failed.
    static func checked(_ report: FeedRefreshReport, noun: ItemNoun) -> String {
        let title = report.feedTitle
        switch report.outcome {
        case .updated(let newItemIDs) where !newItemIDs.isEmpty:
            let count = newItemIDs.count
            return noun.choose(
                // Translators: What VoiceOver says once Check Feed found new episodes. %@ is the feed's title; %lld is how many new episodes.
                episode: InterfaceText.line("feed.newEpisodes", "\(title): \(number: count) new episodes."),
                // Translators: What VoiceOver says once Check Feed found new articles. %@ is the feed's title; %lld is how many new articles.
                article: InterfaceText.line("feed.newArticles", "\(title): \(number: count) new articles."),
                // Translators: What VoiceOver says once Check Feed found new items, in a feed of episodes and articles. %@ is the feed's title; %lld is how many new items.
                item: InterfaceText.line("feed.newItems", "\(title): \(number: count) new items."))
        case .updated, .unchanged, .skipped:
            return noun.choose(
                // Translators: What VoiceOver says once Check Feed found no new episodes. %@ is the feed's title.
                episode: InterfaceText.line("feed.checked.updated.episodes", "\(title): no new episodes."),
                // Translators: What VoiceOver says once Check Feed found no new articles. %@ is the feed's title.
                article: InterfaceText.line("feed.checked.updated.articles", "\(title): no new articles."),
                // Translators: What VoiceOver says once Check Feed found no new items, in a feed of episodes and articles. %@ is the feed's title.
                item: InterfaceText.line("feed.checked.updated.items", "\(title): no new items."))
        case .failed(let message):
            return message
        }
    }

    /// What VoiceOver hears as Check Feed starts.
    static func checking(title: String) -> String {
        // Translators: What VoiceOver says as Check Feed starts. %@ is the feed's title.
        InterfaceText.line("feed.checking", "Checking \(title)…")
    }

    /// What VoiceOver hears when Check Feed is chosen for a feed the
    /// listener unsubscribed from (FR11, branch D), as from a menu drawn
    /// before Unsubscribe: nothing is checked.
    static func notChecked(title: String) -> String {
        // Translators: What VoiceOver says when Check Feed is chosen for an unsubscribed feed. The first %@ is the feed's title; the second is the name of the Resubscribe command.
        InterfaceText.line("feed.notChecked", "\(title) is unsubscribed, so TextMouth doesn't check it. Choose \(resubscribeTitle) to check it again.")
    }

    /// What VoiceOver hears as Resubscribe starts the check it makes at once
    /// (FR11, branch D); the check's outcome follows, as Check Feed's does
    /// (`checked(_:noun:)`).
    static func resubscribed(title: String) -> String {
        // Translators: What VoiceOver says as Resubscribe starts checking the feed. %@ is the feed's title.
        InterfaceText.line("feed.resubscribed", "Resubscribed to \(title). Checking it now…")
    }

    // MARK: Marking

    /// What VoiceOver hears once Mark All Played marked `count` items of the
    /// feed titled `title`, or found none to mark.
    static func markedAll(count: Int, title: String, noun: ItemNoun) -> String {
        guard count > 0 else {
            return noun.choose(
                // Translators: What VoiceOver says when Mark All Played finds no unplayed episode. %@ is the feed's title.
                episode: InterfaceText.line("feed.markedAll.episode", "Every episode of \(title) is already played."),
                // Translators: What VoiceOver says when Mark All Read finds no unread article. %@ is the feed's title.
                article: InterfaceText.line("feed.markedAll.article", "Every article of \(title) is already read."),
                // Translators: What VoiceOver says when Mark All Played finds no unplayed item, in a feed of episodes and articles. %@ is the feed's title.
                item: InterfaceText.line("feed.markedAll.item", "Every item of \(title) is already played."))
        }
        return noun.choose(
            // Translators: What VoiceOver says once Mark All Played marked episodes played. %lld is how many; %@ is the feed's title.
            episode: InterfaceText.line("feed.markedAll.episodes", "Marked \(number: count) episodes of \(title) played."),
            // Translators: What VoiceOver says once Mark All Read marked articles read. %lld is how many; %@ is the feed's title.
            article: InterfaceText.line("feed.markedAll.articles", "Marked \(number: count) articles of \(title) read."),
            // Translators: What VoiceOver says once Mark All Played marked items played, in a feed of episodes and articles. %lld is how many; %@ is the feed's title.
            item: InterfaceText.line("feed.markedAll.items", "Marked \(number: count) items of \(title) played."))
    }

    /// What VoiceOver hears once an item is marked played or unplayed.
    static func marked(title: String, played: Bool, isArticle: Bool) -> String {
        switch (played, isArticle) {
        case (true, false):
            // Translators: What VoiceOver says once an episode is marked played. %@ is the episode's title.
            return InterfaceText.line("feed.marked.played", "Marked “\(title)” played.")
        case (true, true):
            // Translators: What VoiceOver says once an article is marked read. %@ is the article's title.
            return InterfaceText.line("feed.marked.read", "Marked “\(title)” read.")
        case (false, false):
            // Translators: What VoiceOver says once an episode is marked unplayed. %@ is the episode's title.
            return InterfaceText.line("feed.marked.unplayed", "Marked “\(title)” unplayed.")
        case (false, true):
            // Translators: What VoiceOver says once an article is marked unread. %@ is the article's title.
            return InterfaceText.line("feed.marked.unread", "Marked “\(title)” unread.")
        }
    }

    // MARK: Downloads

    /// What VoiceOver hears as Download starts.
    static func downloading(title: String) -> String {
        // Translators: What VoiceOver says as Download starts. %@ is the episode's or article's title.
        InterfaceText.line("feed.downloading", "Downloading “\(title)”.")
    }

    /// What VoiceOver hears once Cancel Download stopped a download.
    static func downloadCancelled(title: String) -> String {
        // Translators: What VoiceOver says once Cancel Download stopped a download. %@ is the episode's or article's title.
        InterfaceText.line("feed.downloadCancelled", "Stopped downloading “\(title)”.")
    }

    /// What VoiceOver hears when Cancel Download comes too late, the book
    /// already being added to the library, which finishes all the same, as
    /// an import is never stopped partway; the feed downloads section's
    /// Cancel says it too of such a download
    /// (`FeedDownloadProgressWording.cancelled(stopped:finishing:comingBack:)`).
    static func alreadyBeingAdded(title: String) -> String {
        // Translators: What VoiceOver says when Cancel Download comes too late: the download's book is already being imported. %@ is the title.
        InterfaceText.line("feed.alreadyBeingAdded", "“\(title)” is already being added to the library.")
    }

    /// What VoiceOver hears once Cancel Download took back a download the
    /// newest-N rule had put off (FR11): it waits no more, and downloads
    /// only when the listener asks.
    static func waitingDownloadCancelled(title: String) -> String {
        // Translators: What VoiceOver says once Cancel Download took back a download that waited. The first %@ is the title; the second is the name of the Download command.
        InterfaceText.line("feed.waitingDownloadCancelled", "“\(title)” no longer waits to download; it downloads when you choose \(FeedWording.title(of: .download, isArticle: false)).")
    }

    /// What VoiceOver hears once Delete Download deleted a download: that it
    /// can be downloaded again, or, when its package kept what the listener
    /// had of it (FR11, branch A2), what waits for then, naming only what
    /// it holds (`kept`, feed review item 18): "Its place and bookmarks are
    /// kept for when you download it again."
    static func downloadDeleted(title: String, kept: KeptParts = []) -> String {
        // Translators: What VoiceOver says once Delete Download deleted a download. %@ is the title. A sentence about what is kept follows.
        let deleted = InterfaceText.line("feed.downloadDeleted", "Deleted the download of “\(title)”.")
        return SentenceWording.joined([deleted, kept.keptForRedownloadSentence])
    }

    /// What a package kept after its download went holds of the listener's
    /// that Delete Download names (feed review item 18): its place, its
    /// bookmarks, its own settings, and its transcript.
    struct KeptParts: OptionSet, Equatable, Sendable {
        let rawValue: Int
        static let place = KeptParts(rawValue: 1 << 0)
        static let bookmarks = KeptParts(rawValue: 1 << 1)
        static let settings = KeptParts(rawValue: 1 << 2)
        static let transcript = KeptParts(rawValue: 1 << 3)

        /// What the kept row `row` and its package at `package` hold, the
        /// package listed without downloading anything.
        static func of(_ row: Book, package: URL) -> KeptParts {
            var parts: KeptParts = []
            if row.readingPosition != nil { parts.insert(.place) }
            if !row.bookmarks.isEmpty { parts.insert(.bookmarks) }
            if row.hasOwnSettings { parts.insert(.settings) }
            if FeedItemPackage.entryNames(of: package).contains(where: TextMouthPaths.isTranscriptFile) {
                parts.insert(.transcript)
            }
            return parts
        }

        /// What the kept rows `rows` hold together, each package listed
        /// without downloading anything (FR14).
        static func of(_ rows: [Book]) -> KeptParts {
            rows.reduce(into: KeptParts()) { $0.formUnion(.of($1, package: $1.tmbDirectory)) }
        }

        /// The parts in the order said, each with whether its noun is plural
        /// as one package holds it.
        private static let order: [(part: KeptParts, isPlural: Bool)] = [
            (.place, false),
            (.bookmarks, true),
            (.settings, true),
            (.transcript, false),
        ]

        /// The noun of `part`, as one package holds it, or as several do.
        private static func noun(of part: KeptParts, several: Bool) -> String {
            switch part {
            case .place:
                return several
                    // Translators: The places in books that several deleted downloads kept, a noun inside a list such as "the places and bookmarks kept for 3 removed downloads". Lower case.
                    ? InterfaceText.line("keptParts.noun.place.places", "places")
                    // Translators: The place in the book that a deleted download kept, a noun inside a list such as "the place and bookmarks kept for 1 removed download". Lower case.
                    : InterfaceText.line("keptParts.noun.place.singular", "place")
            case .bookmarks:
                // Translators: The bookmarks that a deleted download or several kept, a noun inside a list such as "the place and bookmarks kept for 1 removed download". Lower case.
                return InterfaceText.line("keptParts.noun.bookmarks", "bookmarks")
            case .settings:
                // Translators: The settings of their own that a deleted download or several kept, a noun inside a list such as "the place and own settings kept for 1 removed download". Lower case.
                return InterfaceText.line("keptParts.noun.settings", "own settings")
            default:
                return several
                    // Translators: The transcripts that several deleted downloads kept, a noun inside a list such as "the places and transcripts kept for 3 removed downloads". Lower case.
                    ? InterfaceText.line("keptParts.noun.other.transcripts", "transcripts")
                    // Translators: The transcript that a deleted download kept, a noun inside a list such as "the place and transcript kept for 1 removed download". Lower case.
                    : InterfaceText.line("keptParts.noun.other.transcript", "transcript")
            }
        }

        /// The nouns of the parts held, in the order said: as one package
        /// holds them ("place", "bookmarks"), or as several do ("places",
        /// "transcripts").
        func nouns(several: Bool) -> [String] {
            Self.order.filter { contains($0.part) }.map { Self.noun(of: $0.part, several: several) }
        }

        /// Whether the parts, as one package holds them, take a plural verb:
        /// several of them, or bookmarks or own settings alone.
        var takesPluralVerb: Bool {
            let named = Self.order.filter { contains($0.part) }
            return named.count > 1 || named.first?.isPlural == true
        }

        /// What Delete Download says is kept for when the listener downloads
        /// the item again, in a whole sentence, "Its place and bookmarks are
        /// kept for when you download it again."; the sentence that says
        /// the item can be downloaded again when nothing is kept.
        var keptForRedownloadSentence: String {
            guard !isEmpty else {
                // Translators: What VoiceOver says after Delete Download deleted a download that kept nothing of the listener's: the item can be downloaded again.
                return InterfaceText.line("keptParts.keptForRedownloadSentence.downloaded", "It can be downloaded again.")
            }
            let list = CountWording.list(nouns(several: false))
            return takesPluralVerb
                // Translators: What VoiceOver says after Delete Download deleted a download whose package kept parts of the listener's. %@ is a list of what is kept, such as "place and bookmarks". The verb agrees with a list of several parts.
                ? InterfaceText.line("keptParts.keptForRedownloadSentence.valueWhen", "Its \(list) are kept for when you download it again.")
                // Translators: What VoiceOver says after Delete Download deleted a download whose package kept one part of the listener's. %@ is what is kept, such as "place" or "transcript".
                : InterfaceText.line("keptParts.keptForRedownloadSentence.value", "Its \(list) is kept for when you download it again.")
        }

        /// What is kept of one deleted download, as a whole sentence, "Its
        /// place and bookmarks are kept."; nil when nothing is.
        var keptSentence: String? {
            guard !isEmpty else { return nil }
            let list = CountWording.list(nouns(several: false))
            return takesPluralVerb
                // Translators: Sentence that says what is kept of one deleted download. %@ is a list of what is kept, such as "place and bookmarks". The verb agrees with a list of several parts.
                ? InterfaceText.line("keptParts.keptSentence.plural", "Its \(list) are kept.")
                // Translators: Sentence that says what is kept of one deleted download. %@ is one part that is kept, such as "place" or "transcript".
                : InterfaceText.line("keptParts.keptSentence.singular", "Its \(list) is kept.")
        }
    }

    /// The title of the alert saying why a download, or an item, could not
    /// be deleted.
    static var deleteRefusedTitle: String {
        // Translators: Title of the alert that says why a download or a feed item could not be deleted. Title case.
        InterfaceText.line("feed.deleteRefusedTitle", "Couldn't Delete")
    }

    // MARK: Moving Into the Library (FR11, Branch D)

    /// What `books`, feed items' downloads, are called together: episodes
    /// when all are audio, articles when none is, and items for a mix.
    static func noun(of books: [Book]) -> ItemNoun {
        let audio = books.filter { $0.format.isAudio }.count
        if audio == books.count { return .episode }
        return audio == 0 ? .article : .item
    }

    /// The Move to Library sheet's heading: "Move “Ep. 368” to Library" for
    /// one item, titled as `titles` names it, or "Move 3 Episodes to
    /// Library" for several, called `noun`.
    static func moveToLibraryHeading(titles: [String], noun: ItemNoun) -> String {
        guard titles.count != 1, !titles.isEmpty else {
            let title = titles.first ?? ""
            // Translators: Heading of the sheet that moves one feed item's download into the library. %@ is the item's title. Title case.
            return InterfaceText.line("feed.moveToLibraryHeading.named", "Move “\(title)” to Library")
        }
        let count = titles.count
        return noun.choose(
            // Translators: Heading of the sheet that moves several feed episodes into the library. %lld is how many. Title case.
            episode: InterfaceText.line("feed.moveToLibraryHeading.episodes", "Move \(number: count) Episodes to Library"),
            // Translators: Heading of the sheet that moves several feed articles into the library. %lld is how many. Title case.
            article: InterfaceText.line("feed.moveToLibraryHeading.articles", "Move \(number: count) Articles to Library"),
            // Translators: Heading of the sheet that moves several feed items, episodes and articles, into the library. %lld is how many. Title case.
            item: InterfaceText.line("feed.moveToLibraryHeading.items", "Move \(number: count) Items to Library"))
    }

    /// What Move to Library… does, which its sheet says under its heading,
    /// where VoiceOver reads it once, as the listener's design asked (its
    /// Move button no longer repeats it as a hint, REV13 feeds 8): "Moves
    /// this episode into a folder of your library, where it becomes a book
    /// you can edit; it leaves the feed", in an article's words for an
    /// article, and a plural's for several.
    static func moveToLibraryHint(count: Int, noun: ItemNoun) -> String {
        guard count != 1 else {
            return noun.choose(
                // Translators: What the Move to Library sheet says about one episode: it moves into a library folder as a book and leaves its feed.
                episode: InterfaceText.line("feed.moveToLibraryHint.episode", "Moves this episode into a library folder as a book you can edit; it leaves the feed"),
                // Translators: What the Move to Library sheet says about one article: it moves into a library folder as a book and leaves its feed.
                article: InterfaceText.line("feed.moveToLibraryHint.article", "Moves this article into a library folder as a book you can edit; it leaves the feed"),
                // Translators: What the Move to Library sheet says about one item, an episode or an article: it moves into a library folder as a book and leaves its feed.
                item: InterfaceText.line("feed.moveToLibraryHint.item", "Moves this item into a library folder as a book you can edit; it leaves the feed"))
        }
        return noun.choose(
            // Translators: What the Move to Library sheet says about several episodes: they move into a library folder as books and leave their feeds. %lld is how many.
            episode: InterfaceText.line("feed.moveToLibraryHint.episodes", "Moves these \(number: count) episodes into a library folder as books you can edit; they leave their feeds"),
            // Translators: What the Move to Library sheet says about several articles: they move into a library folder as books and leave their feeds. %lld is how many.
            article: InterfaceText.line("feed.moveToLibraryHint.articles", "Moves these \(number: count) articles into a library folder as books you can edit; they leave their feeds"),
            // Translators: What the Move to Library sheet says about several items, episodes and articles: they move into a library folder as books and leave their feeds. %lld is how many.
            item: InterfaceText.line("feed.moveToLibraryHint.items", "Moves these \(number: count) items into a library folder as books you can edit; they leave their feeds"))
    }

    /// What VoiceOver hears once Move to Library… moved the items titled
    /// `titles`, called `noun`, into the folder at `folderPath` ("" for the
    /// library's top level): "Moved “Ep. 368” into Podcasts/Keepers. It's a
    /// book of your library now, and its feed lists it In Library."
    static func movedToLibrary(titles: [String], noun: ItemNoun, folderPath: String) -> String {
        let place = folderPath.isEmpty
            // Translators: Where a book is when it is in no library folder, as in "Moved “Ep. 368” into the top of your library." Lower case.
            ? InterfaceText.line("feed.movedToLibrary.topLibrary", "the top of your library")
            : folderPath
        // The note a moved item's row carries, which the sentence names.
        let inLibrary = FeedItemState.inLibrary(bookID: UUID()).visibleNote
        guard titles.count != 1, !titles.isEmpty else {
            let title = titles.first ?? ""
            // Translators: What VoiceOver says once Move to Library moved one feed item into the library. The first %@ is the item's title; the second is the library folder, or "the top of your library"; the third is the note its feed's row shows, "In Library".
            return InterfaceText.line("feed.movedToLibrary.lists", "Moved “\(title)” into \(place). It's a library book now, and its feed lists it \(inLibrary).")
        }
        let count = titles.count
        return noun.choose(
            // Translators: What VoiceOver says once Move to Library moved several episodes into the library. %lld is how many; the first %@ is the library folder, or "the top of your library"; the second is the note their feeds' rows show, "In Library".
            episode: InterfaceText.line("feed.movedToLibrary.episodes", "Moved \(number: count) episodes into \(place). They're library books now, and their feeds list them \(inLibrary)."),
            // Translators: What VoiceOver says once Move to Library moved several articles into the library. %lld is how many; the first %@ is the library folder, or "the top of your library"; the second is the note their feeds' rows show, "In Library".
            article: InterfaceText.line("feed.movedToLibrary.articles", "Moved \(number: count) articles into \(place). They're library books now, and their feeds list them \(inLibrary)."),
            // Translators: What VoiceOver says once Move to Library moved several items, episodes and articles, into the library. %lld is how many; the first %@ is the library folder, or "the top of your library"; the second is the note their feeds' rows show, "In Library".
            item: InterfaceText.line("feed.movedToLibrary.items", "Moved \(number: count) items into \(place). They're library books now, and their feeds list them \(inLibrary)."))
    }

    /// What Move to Library… says when it moved some of the items asked for
    /// and others stayed in their feeds (REV13 feeds 5), as its sheet, left
    /// open, shows it and VoiceOver hears it: what moved, called `noun`, into
    /// the folder at `folderPath`, as `movedToLibrary(titles:noun:folderPath:)`
    /// says it, then what stayed and why, the items one reason kept named
    /// together: "Moved “Ep. 1” into Podcasts/Keepers. It's a book of your
    /// library now, and its feed lists it In Library. “Ep. 2” stays in its
    /// feed: The file couldn't be moved."
    static func partlyMovedToLibrary(
        moved: [String],
        noun: ItemNoun,
        folderPath: String,
        stayed: [(title: String, reason: String)]
    ) -> String {
        // Each reason once, in the order met, with the titles it kept.
        var reasons: [String] = []
        var titlesByReason: [String: [String]] = [:]
        for (title, reason) in stayed {
            if titlesByReason[reason] == nil {
                reasons.append(reason)
            }
            titlesByReason[reason, default: []].append(RemovalText.quoted(title))
        }
        let stays = reasons.map { reason in
            let titles = titlesByReason[reason] ?? []
            let list = CountWording.list(titles)
            return titles.count == 1
                // Translators: What the Move to Library sheet says about one item that stayed in its feed. The first %@ is its title in quotation marks; the second is the reason, a sentence or clause.
                ? InterfaceText.line("feed.stays.inItsFeed", "\(list) stays in its feed: \(reason)")
                // Translators: What the Move to Library sheet says about several items that stayed in their feeds for one reason. The first %@ is their titles in quotation marks; the second is the reason, a sentence or clause.
                : InterfaceText.line("feed.stays.inTheirFeeds", "\(list) stay in their feeds: \(reason)")
        }
        return SentenceWording.joined([movedToLibrary(titles: moved, noun: noun, folderPath: folderPath)] + stays)
    }

    /// What VoiceOver hears when Move to Library… is chosen with nothing it
    /// can move: no episode or article downloaded in its feed among the books
    /// chosen.
    static var nothingToMoveToLibrary: String {
        // Translators: What VoiceOver says when Move to Library is chosen and no selected book is a feed's download. %@ is the name of the Move to Library command, with its ellipsis.
        InterfaceText.line("feed.nothingToMoveToLibrary", "\(title(of: .moveToLibrary, isArticle: false)) moves an episode or article downloaded in its feed. Select one in its feed's folder.")
    }

    // MARK: Deleting an Item

    /// The confirmation's button, which the menu's command names with an
    /// ellipsis, as it asks first: "Delete Episode", or "Delete Article".
    static func deleteItemButton(isArticle: Bool) -> String {
        isArticle
            // Translators: Title of the button that confirms deleting a feed's article. Title case.
            ? InterfaceText.line("feed.deleteItemButton.article", "Delete Article")
            // Translators: Title of the button that confirms deleting a feed's episode. Title case.
            : InterfaceText.line("feed.deleteItemButton.episode", "Delete Episode")
    }

    /// The title of the command Delete Episode… or Delete Article…, which
    /// asks first.
    static func deleteItemTitle(isArticle: Bool) -> String {
        isArticle
            // Translators: Title of the command that deletes a feed's article, after a confirmation. The ellipsis says a question follows. Title case.
            ? InterfaceText.line("feed.deleteItemTitle.article", "Delete Article…")
            // Translators: Title of the command that deletes a feed's episode, after a confirmation. The ellipsis says a question follows. Title case.
            : InterfaceText.line("feed.deleteItemTitle.episode", "Delete Episode…")
    }

    /// The title of the confirmation before Delete Episode or Delete
    /// Article.
    static func deleteItemQuestion(title: String) -> String {
        // Translators: Title of the confirmation before a feed's episode or article is deleted. %@ is its title.
        InterfaceText.line("feed.deleteItemQuestion", "Delete “\(title)”?")
    }

    /// The confirmation's message, saying what deleting does: the item
    /// leaves the list and its download goes, and, when TextMouth keeps the
    /// listener's place, bookmarks, or transcript for it
    /// (`keepsListenerState`, FR11, branch A2), those go too. For an item
    /// moved into the library (`isInLibrary`, FR11, branch D), the item
    /// leaves the list and its book stays.
    static func deleteItemMessage(isArticle: Bool, keepsListenerState: Bool = false, isInLibrary: Bool = false) -> String {
        // Translators: The last sentence of the confirmation before a feed's episode or article is deleted: a refresh of the feed does not list it again.
        let comeBack = InterfaceText.line("feed.deleteItemMessage.checking", "Checking the feed won't bring it back.")
        guard !isInLibrary else {
            let leaves = isArticle
                // Translators: First sentence of the confirmation before an article that was moved into the library is deleted from its feed.
                ? InterfaceText.line("feed.deleteItemMessage.article", "The article leaves the list for good; the book it became in your library stays.")
                // Translators: First sentence of the confirmation before an episode that was moved into the library is deleted from its feed.
                : InterfaceText.line("feed.deleteItemMessage.episode", "The episode leaves the list for good; the book it became in your library stays.")
            return SentenceWording.joined([leaves, comeBack])
        }
        let leaves = isArticle
            // Translators: First sentence of the confirmation before an article is deleted from its feed.
            ? InterfaceText.line("feed.deleteItemMessage.articleDownload", "The article leaves the list for good, and its download, if any, is deleted.")
            // Translators: First sentence of the confirmation before an episode is deleted from its feed.
            : InterfaceText.line("feed.deleteItemMessage.episodeDownload", "The episode leaves the list for good, and its download, if any, is deleted.")
        guard keepsListenerState else { return SentenceWording.joined([leaves, comeBack]) }
        // Translators: A sentence of the confirmation before a feed's episode or article is deleted: what TextMouth kept of the listener's for it goes too.
        let kept = InterfaceText.line("feed.deleteItemMessage.bookmarks", "The place, bookmarks, and transcript kept for it are deleted too.")
        return SentenceWording.joined([leaves, kept, comeBack])
    }

    /// What VoiceOver hears once an item is deleted: for one moved into the
    /// library (`isInLibrary`, FR11, branch D), that its book stays.
    static func itemDeleted(title: String, isInLibrary: Bool = false) -> String {
        isInLibrary
            // Translators: What VoiceOver says once an item that was moved into the library is deleted from its feed. %@ is its title.
            ? InterfaceText.line("feed.itemDeleted.library", "Deleted “\(title)” from its feed; its book stays in your library.")
            // Translators: What VoiceOver says once a feed's episode or article is deleted. %@ is its title.
            : InterfaceText.line("feed.itemDeleted.alone", "Deleted “\(title)”.")
    }

    // MARK: Unsubscribing

    /// The title of the confirmation before Unsubscribe.
    static func unsubscribeQuestion(title: String) -> String {
        // Translators: Title of the confirmation before Unsubscribe. %@ is the feed's title.
        InterfaceText.line("feed.unsubscribeQuestion", "Unsubscribe from \(title)?")
    }

    /// The Unsubscribe confirmation's button.
    static var unsubscribeButton: String {
        // Translators: Title of the command that stops checking a feed when it acts at once, and of the confirmation's button. Title case.
        InterfaceText.line("feed.unsubscribeButton", "Unsubscribe")
    }

    /// The Unsubscribe confirmation's message, saying what unsubscribing
    /// does now (FR11, branch D): TextMouth stops checking the feed for new
    /// items, called `noun`, and the feed stays, with its settings and its
    /// `downloadCount` downloads, until Resubscribe checks it again. When
    /// unsubscribing would delete what the feed kept for `keptCount`
    /// downloads removed earlier (FR11, branch A2), which Unsubscribe asks
    /// about first only then (FR14), the message ends by naming what those
    /// packages hold (`keptParts`, REV13 item 5). "TextMouth stops checking
    /// this feed for new episodes. The feed stays in your library with its
    /// settings and its 2 downloaded episodes, and Resubscribe checks it
    /// again. It also deletes the places and bookmarks kept for 3 removed
    /// downloads."
    static func unsubscribeMessage(downloadCount: Int, keptCount: Int, keptParts: KeptParts, noun: ItemNoun) -> String {
        let stops = noun.choose(
            // Translators: The first sentence of the confirmation before Unsubscribe, for a feed of episodes.
            episode: InterfaceText.line("feed.unsubscribeMessage.episodes", "TextMouth stops checking this feed for new episodes."),
            // Translators: The first sentence of the confirmation before Unsubscribe, for a feed of articles.
            article: InterfaceText.line("feed.unsubscribeMessage.articles", "TextMouth stops checking this feed for new articles."),
            // Translators: The first sentence of the confirmation before Unsubscribe, for a feed of episodes and articles.
            item: InterfaceText.line("feed.unsubscribeMessage.items", "TextMouth stops checking this feed for new items."))
        let resubscribe = resubscribeTitle
        let stays = downloadCount > 0
            // Translators: A sentence of the confirmation before Unsubscribe: the feed stays, with its settings and its downloads. The first %@ is the downloads, such as "its 2 downloaded episodes"; the second is the name of the Resubscribe command.
            ? InterfaceText.line("feed.unsubscribeMessage.staysLibrarySettings", "The feed stays in your library with its settings and \(downloadsPhrase(downloadCount, noun)), and \(resubscribe) checks it again.")
            // Translators: A sentence of the confirmation before Unsubscribe: the feed stays, with its settings. %@ is the name of the Resubscribe command.
            : InterfaceText.line("feed.unsubscribeMessage.staysLibrary", "The feed stays in your library with its settings, and \(resubscribe) checks it again.")
        var sentences = [stops, stays]
        if keptCount > 0 {
            // Translators: The last sentence of the confirmation before Unsubscribe: what else it deletes. %@ is what the feed kept for removed downloads, such as "the places and bookmarks kept for 3 removed downloads".
            sentences.append(InterfaceText.line("feed.unsubscribeMessage.deletes", "It also deletes \(keptPhrase(count: keptCount, parts: keptParts))."))
        }
        return SentenceWording.joined(sentences)
    }

    /// What VoiceOver hears once the feed titled `title`, whose items are
    /// called `noun`, is unsubscribed from (FR11, branch D): checking
    /// stopped, its downloads stay, and what it kept of removed downloads
    /// was deleted, as `outcome` counts them, named by what those packages
    /// held (`keptParts`), as the question named it (`unsubscribeMessage`).
    /// "Unsubscribed from Finish It!: TextMouth no longer checks it for new
    /// episodes; its downloaded episode stays. The places and bookmarks kept
    /// for 3 removed downloads were deleted."
    static func unsubscribed(title: String, outcome: FeedUnsubscribeOutcome, keptParts: KeptParts = [], noun: ItemNoun) -> String {
        // The downloads that stay, as a clause after a semicolon, or nothing.
        var downloads = ""
        if outcome.downloadCount > 0 {
            let phrase = downloadsPhrase(outcome.downloadCount, noun)
            downloads = outcome.downloadCount == 1
                // Translators: A clause that ends the announcement of Unsubscribe: the one download the feed kept stays. %@ is the download, such as "its downloaded episode". Starts with a semicolon.
                ? InterfaceText.line("feed.unsubscribed.stays", "; \(phrase) stays")
                // Translators: A clause that ends the announcement of Unsubscribe: the feed's downloads stay. %@ is the downloads, such as "its 5 downloaded episodes". Starts with a semicolon.
                : InterfaceText.line("feed.unsubscribed.stay", "; \(phrase) stay")
        }
        let stopped = noun.choose(
            // Translators: What VoiceOver says once Unsubscribe is done, for a feed of episodes. The first %@ is the feed's title; the second is a clause about the downloads that stay, which may be empty.
            episode: InterfaceText.line("feed.unsubscribed.episodes", "Unsubscribed from \(title): TextMouth no longer checks it for new episodes\(downloads)."),
            // Translators: What VoiceOver says once Unsubscribe is done, for a feed of articles. The first %@ is the feed's title; the second is a clause about the downloads that stay, which may be empty.
            article: InterfaceText.line("feed.unsubscribed.articles", "Unsubscribed from \(title): TextMouth no longer checks it for new articles\(downloads)."),
            // Translators: What VoiceOver says once Unsubscribe is done, for a feed of episodes and articles. The first %@ is the feed's title; the second is a clause about the downloads that stay, which may be empty.
            item: InterfaceText.line("feed.unsubscribed.items", "Unsubscribed from \(title): TextMouth no longer checks it for new items\(downloads)."))
        guard outcome.deletedKeptCount > 0 else { return stopped }
        let count = outcome.deletedKeptCount
        let list = CountWording.list(keptParts.nouns(several: count > 1))
        let deleted: String
        if keptParts.nouns(several: false).isEmpty {
            // Translators: The last sentence of the announcement of Unsubscribe: what the feed kept for removed downloads whose packages held none of the named parts was deleted. %lld is how many removed downloads.
            deleted = InterfaceText.line("feed.unsubscribed.what", "What was kept for \(number: count) removed downloads was deleted.")
        } else if keptPhraseTakesPluralVerb(count: count, parts: keptParts) {
            // Translators: The last sentence of the announcement of Unsubscribe: what the feed kept for removed downloads was deleted. %@ is a list of what was kept, such as "places and bookmarks"; %lld is how many removed downloads. The verb is plural.
            deleted = InterfaceText.line("feed.unsubscribed.were", "The \(list) kept for \(number: count) removed downloads were deleted.")
        } else {
            // Translators: The last sentence of the announcement of Unsubscribe: what the feed kept for one removed download was deleted. %@ is one part that was kept, such as "transcript"; %lld is how many removed downloads. The verb is singular.
            deleted = InterfaceText.line("feed.unsubscribed.downloadsWas", "The \(list) kept for \(number: count) removed downloads was deleted.")
        }
        return SentenceWording.joined([stopped, deleted])
    }

    // MARK: What a Feed Holds (FR14)

    /// A feed's downloads, after "its": "its downloaded episode" for one,
    /// "its 5 downloaded episodes" for more, so "its 1 downloaded episode"
    /// is never said (REV13 item 5).
    static func downloadsPhrase(_ count: Int, _ noun: ItemNoun) -> String {
        if count == 1 {
            return noun.choose(
                // Translators: The one downloaded episode of a feed, inside a sentence about what Unsubscribe or Delete Feed does. Lower case.
                episode: InterfaceText.line("feed.downloadsPhrase.episode", "its downloaded episode"),
                // Translators: The one downloaded article of a feed, inside a sentence about what Unsubscribe or Delete Feed does. Lower case.
                article: InterfaceText.line("feed.downloadsPhrase.article", "its downloaded article"),
                // Translators: The one downloaded item, an episode or an article, of a feed, inside a sentence about what Unsubscribe or Delete Feed does. Lower case.
                item: InterfaceText.line("feed.downloadsPhrase.item", "its downloaded item"))
        }
        return noun.choose(
            // Translators: A feed's downloaded episodes, inside a sentence about what Unsubscribe or Delete Feed does. %lld is how many. Lower case.
            episode: InterfaceText.line("feed.downloadsPhrase.episodes", "its \(number: count) downloaded episodes"),
            // Translators: A feed's downloaded articles, inside a sentence about what Unsubscribe or Delete Feed does. %lld is how many. Lower case.
            article: InterfaceText.line("feed.downloadsPhrase.articles", "its \(number: count) downloaded articles"),
            // Translators: A feed's downloaded items, episodes and articles, inside a sentence about what Unsubscribe or Delete Feed does. %lld is how many. Lower case.
            item: InterfaceText.line("feed.downloadsPhrase.items", "its \(number: count) downloaded items"))
    }

    /// What a feed kept for `count` downloads removed earlier, naming only
    /// the parts their packages hold (`parts`, as REV12 item 18 had Delete
    /// Download say them): "the place and bookmarks kept for 1 removed
    /// download", "the places and transcripts kept for 3 removed downloads",
    /// or, for packages holding none of the parts named, as one kept for
    /// its edited text, "what was kept for 2 removed downloads".
    static func keptPhrase(count: Int, parts: KeptParts) -> String {
        let nouns = parts.nouns(several: count > 1)
        guard !nouns.isEmpty else {
            // Translators: What a feed kept for downloads the listener removed, when their packages held none of the parts named, inside a sentence about what Unsubscribe or Delete Feed does. %lld is how many removed downloads. Lower case.
            return InterfaceText.line("feed.keptPhrase.what", "what was kept for \(number: count) removed downloads")
        }
        let list = CountWording.list(nouns)
        // Translators: What a feed kept for downloads the listener removed, inside a sentence about what Unsubscribe or Delete Feed does. %@ is a list of what was kept, such as "places and bookmarks"; %lld is how many removed downloads. Lower case.
        return InterfaceText.line("feed.keptPhrase.downloads", "the \(list) kept for \(number: count) removed downloads")
    }

    /// Whether `keptPhrase(count:parts:)`, as a sentence's subject, takes a
    /// plural verb: for several removed downloads, or for one whose package
    /// holds several parts, or bookmarks or own settings alone; never "what
    /// was kept", which is one thing.
    static func keptPhraseTakesPluralVerb(count: Int, parts: KeptParts) -> Bool {
        guard !parts.nouns(several: false).isEmpty else { return false }
        return count > 1 || parts.takesPluralVerb
    }

    // MARK: Deleting a Feed (FR14)

    /// Delete Feed…'s title, in a feed's menu, among its VoiceOver actions,
    /// and in Feed Info: it asks first.
    static var deleteFeedTitle: String {
        // Translators: Title of the command that deletes a feed with its downloads, after a confirmation, in a feed's menu, among its VoiceOver actions, and in Feed Info. The ellipsis says a question follows. Title case.
        InterfaceText.line("feed.deleteFeedTitle", "Delete Feed…")
    }
    /// The Delete Feed confirmation's button.
    static var deleteFeedButton: String {
        // Translators: Title of the button that confirms deleting a feed. Title case.
        InterfaceText.line("feed.deleteFeedButton", "Delete Feed")
    }
    /// Delete Feed…'s spoken hint in Feed Info.
    static var deleteFeedHint: String {
        // Translators: VoiceOver hint of the Delete Feed button in Feed Info.
        InterfaceText.line("feed.deleteFeedHint", "Asks first, then deletes this feed, its downloads, and what it kept of downloads you removed")
    }

    /// The title of the confirmation before Delete Feed: "Delete the feed
    /// “Finish It!”?"
    static func deleteFeedQuestion(title: String) -> String {
        // Translators: Title of the confirmation before Delete Feed. %@ is the feed's title.
        InterfaceText.line("feed.deleteFeedQuestion", "Delete the feed “\(title)”?")
    }

    /// The Delete Feed confirmation's message (FR14), saying what goes, as
    /// the listener's answer asked: the feed, with its list and settings;
    /// its `downloads` downloads of items called `noun`, and what it kept for
    /// `kept` removed downloads, naming what those hold (`keptParts`), each
    /// to the Trash or for good as `mode` says; its library folder at
    /// `folderPath` when nothing else is in it; and, for a feed with
    /// downloads, Move to Library… for one to keep. "The feed leaves your
    /// library, with its list of episodes and its settings. It deletes its
    /// 5 downloaded episodes and the places and bookmarks kept for 3 removed
    /// downloads: they go to the Trash, where you can recover them until the
    /// Trash is emptied. Its folder “Podcasts/Finish It!” goes too when
    /// nothing else is in it. To keep an episode, choose Move to Library… on
    /// its row first." On an iPhone (`isPhone`) the last sentence is said
    /// only once the phone offers Move to Library… (`PhoneFeedRows.offers(_:)`),
    /// so it never names a command the phone's rows lack.
    static func deleteFeedMessage(
        downloads: Int,
        kept: Int,
        keptParts: KeptParts,
        noun: ItemNoun,
        folderPath: String?,
        mode: RemovalMode,
        isPhone: Bool = ThisDevice.isPhone
    ) -> String {
        var sentences = [noun.choose(
            // Translators: The first sentence of the confirmation before Delete Feed, for a feed of episodes.
            episode: InterfaceText.line("feed.sentences.episodes", "The feed leaves your library, with its list of episodes and its settings."),
            // Translators: The first sentence of the confirmation before Delete Feed, for a feed of articles.
            article: InterfaceText.line("feed.sentences.articles", "The feed leaves your library, with its list of articles and its settings."),
            // Translators: The first sentence of the confirmation before Delete Feed, for a feed of episodes and articles.
            item: InterfaceText.line("feed.sentences.items", "The feed leaves your library, with its list of items and its settings."))]
        var deleted: [String] = []
        if downloads > 0 {
            deleted.append(downloadsPhrase(downloads, noun))
        }
        if kept > 0 {
            deleted.append(keptPhrase(count: kept, parts: keptParts))
        }
        if !deleted.isEmpty {
            // Several things, or one kept package whose parts are said in
            // the plural, as "the place and bookmarks".
            let several = downloads + kept > 1 || (downloads == 0 && keptPhraseTakesPluralVerb(count: kept, parts: keptParts))
            sentences.append(deletesSentence(CountWording.list(deleted), several: several, mode: mode))
        }
        if let folderPath, !folderPath.isEmpty {
            // Translators: A sentence of the confirmation before Delete Feed: the feed's library folder is deleted too when it holds nothing else. %@ is the folder's path.
            sentences.append(InterfaceText.line("feed.folderGoesToo", "Its folder “\(folderPath)” goes too when nothing else is in it."))
        }
        // The way to keep a download, where the rows offer it.
        if downloads > 0, !isPhone || PhoneFeedRows.offers(.moveToLibrary) {
            let moveName = title(of: .moveToLibrary, isArticle: false)
            sentences.append(noun.choose(
                // Translators: The last sentence of the confirmation before Delete Feed, for a feed of episodes. %@ is the name of the Move to Library command.
                episode: InterfaceText.line("feed.keepEpisodeChoose", "To keep an episode, choose \(moveName) on its row first."),
                // Translators: The last sentence of the confirmation before Delete Feed, for a feed of articles. %@ is the name of the Move to Library command.
                article: InterfaceText.line("feed.keepArticleChoose", "To keep an article, choose \(moveName) on its row first."),
                // Translators: The last sentence of the confirmation before Delete Feed, for a feed of episodes and articles. %@ is the name of the Move to Library command.
                item: InterfaceText.line("feed.keepItemChoose", "To keep an item, choose \(moveName) on its row first.")))
        }
        return SentenceWording.joined(sentences)
    }

    /// The sentence of Delete Feed's confirmation that says what it deletes,
    /// `list`, and what becomes of it in the removal mode `mode`, whether
    /// `several` things go or one.
    private static func deletesSentence(_ list: String, several: Bool, mode: RemovalMode) -> String {
        switch (mode, several) {
        case (.keepFiles, true):
            // Translators: A sentence of the confirmation before Delete Feed, when the setting keeps files: what the feed deletes, several things, which stay in the library folder. %@ is a list of what is deleted.
            return InterfaceText.line("feed.deletesSentence.stay", "It deletes \(list): they stay in the TextMouth library folder.")
        case (.keepFiles, false):
            // Translators: A sentence of the confirmation before Delete Feed, when the setting keeps files: what the feed deletes, one thing, which stays in the library folder. %@ is what is deleted.
            return InterfaceText.line("feed.deletesSentence.stays", "It deletes \(list): it stays in the TextMouth library folder.")
        case (.moveToTrash, true):
            // Translators: A sentence of the confirmation before Delete Feed, when files go to the Trash: what the feed deletes, several things. %@ is a list of what is deleted.
            return InterfaceText.line("feed.deletesSentence.them", "It deletes \(list): they go to the Trash, where you can recover them until the Trash is emptied.")
        case (.moveToTrash, false):
            // Translators: A sentence of the confirmation before Delete Feed, when files go to the Trash: what the feed deletes, one thing. %@ is what is deleted.
            return InterfaceText.line("feed.deletesSentence.goes", "It deletes \(list): it goes to the Trash, where you can recover it until the Trash is emptied.")
        case (.deletePermanently, true):
            // Translators: A sentence of the confirmation before Delete Feed, when files are deleted permanently: what the feed deletes, several things. %@ is a list of what is deleted.
            return InterfaceText.line("feed.deletesSentence.permanentlyRecovered", "It deletes \(list): they are deleted permanently and cannot be recovered.")
        case (.deletePermanently, false):
            // Translators: A sentence of the confirmation before Delete Feed, when files are deleted permanently: what the feed deletes, one thing. %@ is what is deleted.
            return InterfaceText.line("feed.deletesSentence.deletedPermanentlyRecovered", "It deletes \(list): it is deleted permanently and cannot be recovered.")
        }
    }

    /// What VoiceOver hears once Delete Feed… deleted a feed whose items are
    /// called `noun` (FR14): what went, as `outcome` counts it, naming what
    /// the packages kept for removed downloads held (`keptParts`), as its
    /// question named them and Unsubscribe's announcement names them
    /// (`keptPhrase(count:parts:)`, REV14 feeds 9), and what became of its
    /// library folder. "Deleted the feed “Finish It!”, its 5 downloaded
    /// episodes, and the places and bookmarks kept for 3 removed downloads.
    /// Its folder “Podcasts/Finish It!” is gone too."
    static func deletedFeed(_ outcome: FeedDeleteOutcome, noun: ItemNoun, keptParts: KeptParts) -> String {
        // Translators: The feed itself, first in the list of what Delete Feed deleted, inside the announcement "Deleted the feed “Finish It!”, its 5 downloaded episodes, and ...". %@ is the feed's title. Lower case.
        var deleted = [InterfaceText.line("feed.deletedFeed", "the feed “\(outcome.title)”")]
        if outcome.deletedDownloads > 0 {
            deleted.append(downloadsPhrase(outcome.deletedDownloads, noun))
        }
        if outcome.deletedKeptPlaces > 0 {
            deleted.append(keptPhrase(count: outcome.deletedKeptPlaces, parts: keptParts))
        }
        // Translators: What VoiceOver says once Delete Feed deleted a feed. %@ is a list of what went: the feed, its downloads, and what it kept for removed downloads.
        let sentence = InterfaceText.line("common.deletedValue", "Deleted \(CountWording.list(deleted)).")
        let folder: String
        switch outcome.folder {
        case .deleted(let path):
            // Translators: A sentence of the announcement after Delete Feed: the feed's library folder was deleted too. %@ is the folder's path.
            folder = InterfaceText.line("feed.deletedFeed.folderGone", "Its folder “\(path)” is gone too.")
        case .stays(let path):
            // Translators: A sentence of the announcement after Delete Feed: the feed's library folder stays because it holds other things. %@ is the folder's path.
            folder = InterfaceText.line("feed.deletedFeed.stays", "Its folder “\(path)” stays, as something else is in it.")
        case .notDeleted(let path):
            // Translators: A sentence of the announcement after Delete Feed: the feed's library folder is empty but could not be deleted. %@ is the folder's path.
            folder = InterfaceText.line("feed.deletedFeed.notDeleted", "Its folder “\(path)” is empty, but could not be deleted.")
        case .none:
            return sentence
        }
        return SentenceWording.joined([sentence, folder])
    }

    /// Why Delete Feed… left the feed titled `title` as it is (FR14), as the
    /// alert after it says and VoiceOver hears: a download in use, open in a
    /// reader, being transcribed, or being exported (feed follow-ups item
    /// 1), an index that could not be saved, or the downloads or kept
    /// packages that could not go, each named with why, in the words of the
    /// removal setting `mode`.
    static func deleteFeedRefused(_ error: FeedDeleteError, title: String, mode: RemovalMode) -> String {
        switch error {
        case let .downloadInUse(download, use):
            // Translators: The next step after a refusal to delete a feed whose download is in use: "Close it, then choose Delete Feed… again." %@ is the name of the Delete Feed command. Lower case, without a full stop, to follow "then".
            let again = InterfaceText.line("feed.deleteFeedRefused.downloadInUse", "choose \(deleteFeedTitle) again")
            return use.refusal(of: RemovalText.quoted(download), retry: again)
        case .indexNotWritten:
            // Translators: Why Delete Feed did nothing: the library could not be saved first. %@ is the feed's title.
            return InterfaceText.line("feed.deleteFeedRefused.indexNotWritten", "TextMouth couldn't save the library before deleting the feed “\(title)”, so nothing was deleted.")
        case .filesStayed(let stayed):
            let stays = stayed.count == 1
                // Translators: The last line of the alert when Delete Feed could not delete one of the feed's items: the feed stays with it. %@ is the feed's title.
                ? InterfaceText.line("feed.deleteFeedRefused.filesStayed.stays", "The feed “\(title)” stays with it.")
                // Translators: The last line of the alert when Delete Feed could not delete several of the feed's items: the feed stays with them. %@ is the feed's title.
                : InterfaceText.line("feed.deleteFeedRefused.filesStayed.them", "The feed “\(title)” stays with them.")
            return mode.failureMessage(stayed, noun: .item) + "\n" + stays
        }
    }
}

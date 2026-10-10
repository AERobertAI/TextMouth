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

    /// The command's role in a menu: Unsubscribe stops the feed's checking
    /// and deletes what it kept of removed downloads (FR11, branch D), and
    /// says so.
    var role: ButtonRole? {
        command == .unsubscribe ? .destructive : nil
    }

    /// The commands for the feed `feedID`, whose items are called `noun`, in
    /// menu order, by whether the listener `isSubscribed` to it (FR11,
    /// branch D, the listener's "subscribe / resubscribe toggling action in
    /// the context menu for feeds"): Check Feed, Feed Info…, Mark All
    /// Played, and Unsubscribe… for a subscribed feed; Feed Info…, Mark All
    /// Played, and Resubscribe for an unsubscribed one, which is not
    /// checked. Mark All Played with nothing left to mark says so.
    static func actions(for feedID: UUID, noun: FeedWording.ItemNoun, isSubscribed: Bool = true) -> [FeedAction] {
        let markAll = FeedAction(command: .markAllPlayed, feedID: feedID, title: FeedWording.markAllPlayedTitle(noun))
        let info = FeedAction(command: .feedInfo, feedID: feedID, title: FeedWording.feedInfoTitle)
        guard isSubscribed else {
            return [info, markAll, FeedAction(command: .resubscribe, feedID: feedID, title: FeedWording.resubscribeTitle)]
        }
        return [
            FeedAction(command: .checkFeed, feedID: feedID, title: FeedWording.checkFeedTitle),
            info,
            markAll,
            FeedAction(command: .unsubscribe, feedID: feedID, title: FeedWording.unsubscribeTitle),
        ]
    }

    /// The commands for the feed `feedID` of `center` as it is now: its
    /// items' noun and whether the listener is subscribed come from its
    /// record (`actions(for:noun:isSubscribed:)`).
    @MainActor
    static func actions(for feedID: UUID, in center: FeedCenter) -> [FeedAction] {
        actions(
            for: feedID,
            noun: .of(center.listedItems(of: feedID)),
            isSubscribed: center.store.record(of: feedID)?.feed.isSubscribed ?? true
        )
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
}

// MARK: - The Commands' Words

extension FeedWording {
    /// Check Feed's title.
    static let checkFeedTitle = "Check Feed"
    /// Feed Info's title.
    static let feedInfoTitle = "Feed Info…"
    /// Unsubscribe's title.
    static let unsubscribeTitle = "Unsubscribe…"
    /// Resubscribe's title (FR11, branch D): no ellipsis, since it asks
    /// nothing first.
    static let resubscribeTitle = "Resubscribe"

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
        case .moveToLibrary: return ShortcutAction.moveToLibrary.title
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

    /// What VoiceOver hears when Check Feed is chosen for a feed the
    /// listener unsubscribed from (FR11, branch D), as from a menu drawn
    /// before Unsubscribe: nothing is checked.
    static func notChecked(title: String) -> String {
        "\(title) is unsubscribed, so TextMouth doesn't check it. Choose Resubscribe to check it again."
    }

    /// What VoiceOver hears as Resubscribe starts the check it makes at once
    /// (FR11, branch D); the check's outcome follows, as Check Feed's does
    /// (`checked(_:noun:)`).
    static func resubscribed(title: String) -> String {
        "Resubscribed to \(title). Checking it now…"
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

    /// What VoiceOver hears once Cancel Download took back a download the
    /// newest-N rule had put off (FR11): it waits no more, and downloads
    /// only when the listener asks.
    static func waitingDownloadCancelled(title: String) -> String {
        "“\(title)” no longer waits to download; it downloads when you choose Download."
    }

    /// What VoiceOver hears once Delete Download deleted a download: that it
    /// can be downloaded again, or, when its package kept what the listener
    /// had of it (FR11, branch A2), what waits for then, naming only what
    /// it holds (`kept`, feed review item 18): "Its place and bookmarks are
    /// kept for when you download it again."
    static func downloadDeleted(title: String, kept: KeptParts = []) -> String {
        let deleted = "Deleted the download of “\(title)”."
        guard let parts = kept.sentenceSubject else { return "\(deleted) It can be downloaded again." }
        return "\(deleted) \(parts) kept for when you download it again."
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
            if row.hasLocalVoiceSettings || !(row.skippedHeadingIDs ?? []).isEmpty || row.localEndOfBookBehavior != nil
                || row.localSkipForwardUnit != nil || row.localSkipBackwardUnit != nil {
                parts.insert(.settings)
            }
            if FeedItemPackage.entryNames(of: package).contains(where: TextMouthPaths.isTranscriptFile) {
                parts.insert(.transcript)
            }
            return parts
        }

        /// The parts as a sentence's subject with its verb, as in "Its
        /// place and bookmarks are", or "Its transcript is"; nil for none.
        var sentenceSubject: String? {
            // Each part's noun, in the order said, and whether it is plural.
            let nouns: [(part: KeptParts, noun: String, isPlural: Bool)] = [
                (.place, "place", false),
                (.bookmarks, "bookmarks", true),
                (.settings, "own settings", true),
                (.transcript, "transcript", false),
            ]
            let named = nouns.filter { contains($0.part) }
            guard let first = named.first else { return nil }
            let plural = named.count > 1 || first.isPlural
            return "Its \(LibraryCloudWording.list(named.map(\.noun))) \(plural ? "are" : "is")"
        }
    }

    /// The title of the alert saying why a download, or an item, could not
    /// be deleted.
    static let deleteRefusedTitle = "Couldn't Delete"

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
        guard titles.count != 1, !titles.isEmpty else { return "Move “\(titles.first ?? "")” to Library" }
        return "Move \(titles.count) \(noun.plural.capitalized) to Library"
    }

    /// What Move to Library… does, which its sheet says under its heading
    /// and VoiceOver hears as its Move button's hint, as the listener's
    /// design asked: "Moves this episode into a folder of your library,
    /// where it becomes a book you can edit; it leaves the feed", in an
    /// article's words for an article, and a plural's for several.
    static func moveToLibraryHint(count: Int, noun: ItemNoun) -> String {
        guard count != 1 else {
            return "Moves this \(noun.singular) into a folder of your library, where it becomes a book you can edit; it leaves the feed"
        }
        return "Moves these \(count) \(noun.plural) into a folder of your library, where they become books you can edit; they leave their feeds"
    }

    /// What VoiceOver hears once Move to Library… moved the items titled
    /// `titles`, called `noun`, into the folder at `folderPath` ("" for the
    /// library's top level): "Moved “Ep. 368” into Podcasts/Keepers. It's a
    /// book of your library now, and its feed lists it In Library."
    static func movedToLibrary(titles: [String], noun: ItemNoun, folderPath: String) -> String {
        let place = folderPath.isEmpty ? "the top of your library" : folderPath
        guard titles.count != 1, !titles.isEmpty else {
            return "Moved “\(titles.first ?? "")” into \(place). It's a book of your library now, and its feed lists it In Library."
        }
        return "Moved \(count(titles.count, noun)) into \(place). They're books of your library now, and their feeds list them In Library."
    }

    /// What VoiceOver hears when Move to Library… is chosen with nothing it
    /// can move: no episode or article downloaded in its feed among the books
    /// chosen.
    static let nothingToMoveToLibrary = "Move to Library… moves an episode or article downloaded in its feed. Select one in its feed's folder."

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

    /// The confirmation's message, saying what deleting does: the item
    /// leaves the list and its download goes, and, when TextMouth keeps the
    /// listener's place, bookmarks, or transcript for it
    /// (`keepsListenerState`, FR11, branch A2), those go too. For an item
    /// moved into the library (`isInLibrary`, FR11, branch D), the item
    /// leaves the list and its book stays.
    static func deleteItemMessage(isArticle: Bool, keepsListenerState: Bool = false, isInLibrary: Bool = false) -> String {
        let kind = isArticle ? "article" : "episode"
        guard !isInLibrary else {
            return "The \(kind) leaves the list for good; the book it became in your library stays. "
                + "Checking the feed won't bring it back."
        }
        let kept = keepsListenerState ? " The place, bookmarks, and transcript kept for it are deleted too." : ""
        return "The \(kind) leaves the list for good, and its download, if any, is deleted.\(kept) "
            + "Checking the feed won't bring it back."
    }

    /// What VoiceOver hears once an item is deleted: for one moved into the
    /// library (`isInLibrary`, FR11, branch D), that its book stays.
    static func itemDeleted(title: String, isInLibrary: Bool = false) -> String {
        isInLibrary ? "Deleted “\(title)” from its feed; its book stays in your library." : "Deleted “\(title)”."
    }

    // MARK: Unsubscribing

    /// The title of the confirmation before Unsubscribe.
    static func unsubscribeQuestion(title: String) -> String {
        "Unsubscribe from \(title)?"
    }

    /// The Unsubscribe confirmation's button.
    static let unsubscribeButton = "Unsubscribe"

    /// The Unsubscribe confirmation's message, saying what unsubscribing
    /// does now (FR11, branch D): TextMouth stops checking the feed for new
    /// items, called `noun`, and the feed stays, with its settings and its
    /// `downloadCount` downloads, until Resubscribe checks it again. When the
    /// feed kept the places of `keptCount` downloads removed earlier (FR11,
    /// branch A2), the message ends by saying those go. "TextMouth stops
    /// checking this feed for new episodes. The feed stays in your library
    /// with its settings and its 2 downloaded episodes, and Resubscribe
    /// checks it again. It also deletes the places, bookmarks, and
    /// transcripts kept for 3 removed downloads."
    static func unsubscribeMessage(downloadCount: Int, keptCount: Int, noun: ItemNoun) -> String {
        let stops = "TextMouth stops checking this feed for new \(noun.plural)."
        let downloads = downloadCount > 0 ? " and its \(downloadedCount(downloadCount, noun))" : ""
        let stays = "The feed stays in your library with its settings\(downloads), and Resubscribe checks it again."
        return "\(stops) \(stays)\(keptRecordsDeleted(count: keptCount))"
    }

    /// `count` downloads of items called `noun`: "1 downloaded episode", "2
    /// downloaded articles".
    private static func downloadedCount(_ count: Int, _ noun: ItemNoun) -> String {
        "\(count) downloaded \(count == 1 ? noun.singular : noun.plural)"
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

    /// What VoiceOver hears once the feed titled `title`, whose items are
    /// called `noun`, is unsubscribed from (FR11, branch D): checking
    /// stopped, its downloads stay, and what it kept of removed downloads
    /// was deleted, as `outcome` counts them, named as the question named
    /// it (`unsubscribeMessage`). "Unsubscribed from Finish It!: TextMouth
    /// no longer checks it for new episodes; its 2 downloaded episodes stay.
    /// The places, bookmarks, and transcripts kept for 3 removed downloads
    /// were deleted."
    static func unsubscribed(title: String, outcome: FeedUnsubscribeOutcome, noun: ItemNoun) -> String {
        let stays = outcome.downloadCount == 1 ? "stays" : "stay"
        let downloads = outcome.downloadCount > 0 ? "; its \(downloadedCount(outcome.downloadCount, noun)) \(stays)" : ""
        let stopped = "Unsubscribed from \(title): TextMouth no longer checks it for new \(noun.plural)\(downloads)."
        switch outcome.deletedKeptCount {
        case 0:
            return stopped
        case 1:
            return "\(stopped) The place, bookmarks, and transcript kept for 1 removed download were deleted."
        case let count:
            return "\(stopped) The places, bookmarks, and transcripts kept for \(count) removed downloads were deleted."
        }
    }
}

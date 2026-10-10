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
}

// MARK: - The Commands' Words

extension FeedWording {
    /// Check Feed's title.
    static let checkFeedTitle = "Check Feed"
    /// Feed Info's title.
    static let feedInfoTitle = "Feed Info…"

    /// Unsubscribe's title: "Unsubscribe…" when it asks first, as it would
    /// delete the places the feed kept for removed downloads, and
    /// "Unsubscribe", with no ellipsis, when it acts at once (FR14).
    static func unsubscribeTitle(asksFirst: Bool) -> String {
        asksFirst ? "Unsubscribe…" : "Unsubscribe"
    }
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

        /// What the kept rows `rows` hold together, each package listed
        /// without downloading anything (FR14).
        static func of(_ rows: [Book]) -> KeptParts {
            rows.reduce(into: KeptParts()) { $0.formUnion(.of($1, package: $1.tmbDirectory)) }
        }

        /// Each part's noun, in the order said, as one package holds it and
        /// as several do, and whether the one package's is plural.
        private static let nouns: [(part: KeptParts, one: String, several: String, isPlural: Bool)] = [
            (.place, "place", "places", false),
            (.bookmarks, "bookmarks", "bookmarks", true),
            (.settings, "own settings", "own settings", true),
            (.transcript, "transcript", "transcripts", false),
        ]

        /// The nouns of the parts held, in the order said: as one package
        /// holds them ("place", "bookmarks"), or as several do ("places",
        /// "transcripts").
        func nouns(several: Bool) -> [String] {
            Self.nouns.filter { contains($0.part) }.map { several ? $0.several : $0.one }
        }

        /// Whether the parts, as one package holds them, take a plural verb:
        /// several of them, or bookmarks or own settings alone.
        var takesPluralVerb: Bool {
            let named = Self.nouns.filter { contains($0.part) }
            return named.count > 1 || named.first?.isPlural == true
        }

        /// The parts as a sentence's subject with its verb, as in "Its
        /// place and bookmarks are", or "Its transcript is"; nil for none.
        var sentenceSubject: String? {
            let named = nouns(several: false)
            guard !named.isEmpty else { return nil }
            return "Its \(LibraryCloudWording.list(named)) \(takesPluralVerb ? "are" : "is")"
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
            titlesByReason[reason, default: []].append("“\(title)”")
        }
        let stays = reasons.map { reason in
            let titles = titlesByReason[reason] ?? []
            let stay = titles.count == 1 ? "stays in its feed" : "stay in their feeds"
            return "\(LibraryCloudWording.list(titles)) \(stay): \(reason)"
        }
        return ([movedToLibrary(titles: moved, noun: noun, folderPath: folderPath)] + stays).joined(separator: " ")
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
        let stops = "TextMouth stops checking this feed for new \(noun.plural)."
        let downloads = downloadCount > 0 ? " and its \(downloadsPhrase(downloadCount, noun))" : ""
        let stays = "The feed stays in your library with its settings\(downloads), and Resubscribe checks it again."
        let deletes = keptCount > 0 ? " It also deletes \(keptPhrase(count: keptCount, parts: keptParts))." : ""
        return "\(stops) \(stays)\(deletes)"
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
        let stays = outcome.downloadCount == 1 ? "stays" : "stay"
        let downloads = outcome.downloadCount > 0 ? "; its \(downloadsPhrase(outcome.downloadCount, noun)) \(stays)" : ""
        let stopped = "Unsubscribed from \(title): TextMouth no longer checks it for new \(noun.plural)\(downloads)."
        guard outcome.deletedKeptCount > 0 else { return stopped }
        let kept = keptPhrase(count: outcome.deletedKeptCount, parts: keptParts)
        let verb = keptPhraseTakesPluralVerb(count: outcome.deletedKeptCount, parts: keptParts) ? "were" : "was"
        return "\(stopped) \(kept.capitalizingFirstLetter) \(verb) deleted."
    }

    // MARK: What a Feed Holds (FR14)

    /// A feed's downloads, after "its": "downloaded episode" for one, "5
    /// downloaded episodes" for more, so "its 1 downloaded episode" is never
    /// said (REV13 item 5).
    static func downloadsPhrase(_ count: Int, _ noun: ItemNoun) -> String {
        count == 1 ? "downloaded \(noun.singular)" : "\(count) downloaded \(noun.plural)"
    }

    /// What a feed kept for `count` downloads removed earlier, naming only
    /// the parts their packages hold (`parts`, as REV12 item 18 had Delete
    /// Download say them): "the place and bookmarks kept for 1 removed
    /// download", "the places and transcripts kept for 3 removed downloads",
    /// or, for packages holding none of the parts named, as one kept for
    /// its edited text, "what was kept for 2 removed downloads".
    static func keptPhrase(count: Int, parts: KeptParts) -> String {
        let nouns = parts.nouns(several: count > 1)
        let what = nouns.isEmpty ? "what was" : "the \(LibraryCloudWording.list(nouns))"
        return "\(what) kept for \(CountWording.phrase(count, singular: "removed download", plural: "removed downloads"))"
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
    static let deleteFeedTitle = "Delete Feed…"
    /// The Delete Feed confirmation's button.
    static let deleteFeedButton = "Delete Feed"
    /// Delete Feed…'s spoken hint in Feed Info.
    static let deleteFeedHint = "Asks first, then deletes this feed, its downloads, and what it kept of downloads you removed"

    /// The title of the confirmation before Delete Feed: "Delete the feed
    /// “Finish It!”?"
    static func deleteFeedQuestion(title: String) -> String {
        "Delete the feed “\(title)”?"
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
    /// its row first."
    static func deleteFeedMessage(
        downloads: Int,
        kept: Int,
        keptParts: KeptParts,
        noun: ItemNoun,
        folderPath: String?,
        mode: RemovalMode
    ) -> String {
        var sentences = ["The feed leaves your library, with its list of \(noun.plural) and its settings."]
        var deleted: [String] = []
        if downloads > 0 {
            deleted.append("its \(downloadsPhrase(downloads, noun))")
        }
        if kept > 0 {
            deleted.append(keptPhrase(count: kept, parts: keptParts))
        }
        if !deleted.isEmpty {
            // Several things, or one kept package whose parts are said in
            // the plural, as "the place and bookmarks".
            let several = downloads + kept > 1 || (downloads == 0 && keptPhraseTakesPluralVerb(count: kept, parts: keptParts))
            sentences.append("It deletes \(LibraryCloudWording.list(deleted)): \(several ? "they" : "it") \(mode.outcomePhrase(plural: several)).")
        }
        if let folderPath, !folderPath.isEmpty {
            sentences.append("Its folder “\(folderPath)” goes too when nothing else is in it.")
        }
        if downloads > 0 {
            sentences.append("To keep an \(noun.singular), choose \(ShortcutAction.moveToLibrary.title) on its row first.")
        }
        return sentences.joined(separator: " ")
    }

    /// What VoiceOver hears once Delete Feed… deleted a feed whose items are
    /// called `noun` (FR14): what went, as `outcome` counts it, and what
    /// became of its library folder. "Deleted the feed “Finish It!”, its 5
    /// downloaded episodes, and what it kept for 3 removed downloads. Its
    /// folder “Podcasts/Finish It!” is gone too."
    static func deletedFeed(_ outcome: FeedDeleteOutcome, noun: ItemNoun) -> String {
        var deleted = ["the feed “\(outcome.title)”"]
        if outcome.deletedDownloads > 0 {
            deleted.append("its \(downloadsPhrase(outcome.deletedDownloads, noun))")
        }
        if outcome.deletedKeptPlaces > 0 {
            let removed = CountWording.phrase(outcome.deletedKeptPlaces, singular: "removed download", plural: "removed downloads")
            deleted.append("what it kept for \(removed)")
        }
        let sentence = "Deleted \(LibraryCloudWording.list(deleted))."
        switch outcome.folder {
        case .deleted(let path):
            return "\(sentence) Its folder “\(path)” is gone too."
        case .stays(let path):
            return "\(sentence) Its folder “\(path)” stays, as something else is in it."
        case .notDeleted(let path):
            return "\(sentence) Its folder “\(path)” is empty, but could not be deleted."
        case .none:
            return sentence
        }
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
            return use.refusal(of: "“\(download)”", retry: "choose \(deleteFeedTitle) again")
        case .indexNotWritten:
            return "TextMouth couldn't save the library before deleting the feed “\(title)”, so nothing was deleted."
        case .filesStayed(let stayed):
            return mode.failureMessage(stayed, noun: "item") + "\nThe feed “\(title)” stays with \(stayed.count == 1 ? "it" : "them")."
        }
    }
}

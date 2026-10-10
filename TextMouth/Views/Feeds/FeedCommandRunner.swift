import AppKit
import Foundation

// MARK: - Running the Feed Commands (FR03)

/// What a feed command works with: the engine, the library, and the window
/// it was chosen in, which announces what it did.
@MainActor
struct FeedCommandContext {
    /// The feed engine.
    let center: FeedCenter
    /// The library the window shows.
    let library: LibraryViewModel
    /// The window the command was chosen in, once known.
    let window: NSWindow?
}

extension FeedCenter {
    /// Refreshes every feed because the listener asked, from Library >
    /// Refresh All Feeds or Preferences, saying through `announce` that it
    /// started and, once done, what came (FR03).
    /// - Returns: How the refresh ended.
    @discardableResult
    func refreshAllSaying(_ announce: @escaping @MainActor (String) -> Void) async -> FeedRefreshSummary {
        announce(FeedSettingsWording.refreshing)
        let summary = await refreshAll(origin: .listener)
        announce(FeedWording.refreshedAll(summary, in: self))
        return summary
    }
}

/// A question asked before a command that can't be undone (FR03): Delete
/// Episode or Delete Article, and Unsubscribe, which Resubscribe undoes but
/// for the places kept for removed downloads, which it deletes (FR11,
/// branch D).
struct FeedConfirmation: Identifiable, Equatable {
    /// What confirming does.
    enum Kind: Equatable {
        /// Deletes the item `itemID` of the feed `feedID`, titled `title`.
        case deleteItem(feedID: UUID, itemID: FeedItem.ID, title: String)
        /// Unsubscribes from the feed `feedID`.
        case unsubscribe(feedID: UUID)
    }

    /// Tells two questions apart.
    let id = UUID()
    /// What confirming does.
    let kind: Kind
    /// The alert's title, a question.
    let title: String
    /// The alert's message, saying what will happen.
    let message: String
    /// The confirming button's title.
    let confirmTitle: String
}

extension LibraryFeedsPresenter {
    // MARK: A Feed's Commands

    /// Runs `action` for a feed, from its row in the Feeds section or its
    /// folder's row, saying what it did from the window it was chosen in.
    /// - Returns: The work Check Feed and Resubscribe started, which tests
    ///   await; nil for the commands that finish at once or ask first.
    @discardableResult
    func perform(_ action: FeedAction, in context: FeedCommandContext) -> Task<Void, Never>? {
        let center = context.center
        guard let feed = center.store.record(of: action.feedID)?.feed else { return nil }
        switch action.command {
        case .checkFeed:
            // A menu drawn before Unsubscribe may still offer it (FR11,
            // branch D): an unsubscribed feed is never checked.
            guard feed.isSubscribed else {
                announce(FeedWording.notChecked(title: feed.title), context.window)
                return nil
            }
            announce(FeedWording.checking(title: feed.title), context.window)
            let noun = FeedWording.ItemNoun.of(center.listedItems(of: feed.id))
            return Task {
                guard let report = await center.refresh(feed.id) else { return }
                announce(FeedWording.checked(report, noun: noun), context.window)
            }
        case .feedInfo:
            feedInfo = FeedInfoModel(feedID: feed.id, center: center, library: context.library)
        case .markAllPlayed:
            let noun = FeedWording.ItemNoun.of(center.listedItems(of: feed.id))
            let marked = center.markAllPlayed(of: feed.id)
            announce(FeedWording.markedAll(count: marked, title: feed.title, noun: noun), context.window)
        case .unsubscribe:
            confirmation = unsubscribeConfirmation(for: feed.id, in: context)
        case .resubscribe:
            return resubscribe(feed.id, in: context)
        }
        return nil
    }

    /// Subscribes again to the feed `feedID` (FR11, branch D), which asks
    /// nothing first: VoiceOver hears that it is checked now, and then what
    /// the check found, as Check Feed says it.
    /// - Returns: The check, which tests await; nil when the feed is
    ///   subscribed already, or gone.
    @discardableResult
    func resubscribe(_ feedID: UUID, in context: FeedCommandContext) -> Task<Void, Never>? {
        let center = context.center
        guard let feed = center.store.record(of: feedID)?.feed, !feed.isSubscribed else { return nil }
        let noun = FeedWording.ItemNoun.of(center.listedItems(of: feedID))
        announce(FeedWording.resubscribed(title: feed.title), context.window)
        return Task {
            guard let report = await center.resubscribe(feedID) else { return }
            announce(FeedWording.checked(report, noun: noun), context.window)
        }
    }

    /// The question asked before unsubscribing from the feed `feedID`, saying
    /// what happens now (FR11, branch D): checking stops, the feed stays
    /// with its settings and its downloads, which it counts, and what it
    /// kept of downloads removed earlier goes; nil once it is no longer
    /// subscribed.
    func unsubscribeConfirmation(for feedID: UUID, in context: FeedCommandContext) -> FeedConfirmation? {
        guard let feed = context.center.store.record(of: feedID)?.feed, feed.isSubscribed else { return nil }
        let rows = context.library.feedItemRows(of: feedID)
        return FeedConfirmation(
            kind: .unsubscribe(feedID: feedID),
            title: FeedWording.unsubscribeQuestion(title: feed.title),
            message: FeedWording.unsubscribeMessage(
                downloadCount: rows.downloaded.count,
                keptCount: rows.kept.count,
                noun: .of(context.center.listedItems(of: feedID))
            ),
            confirmTitle: FeedWording.unsubscribeButton
        )
    }

    /// Unsubscribes from the feed `feedID`, once confirmed (FR11, branch D):
    /// only checking stops, the feed staying with its folder, its settings,
    /// and its downloads, and the packages it kept for downloads removed
    /// earlier go (`FeedCenter.unsubscribe(_:)`); VoiceOver hears so at once.
    /// Feed Info, should it show the feed, stays open, offering Resubscribe.
    /// - Returns: What unsubscribing did; nil when the feed was no longer
    ///   subscribed, which changes nothing.
    @discardableResult
    func unsubscribe(_ feedID: UUID, in context: FeedCommandContext) -> FeedUnsubscribeOutcome? {
        guard let feed = context.center.store.record(of: feedID)?.feed else { return nil }
        let noun = FeedWording.ItemNoun.of(context.center.listedItems(of: feedID))
        guard let outcome = context.center.unsubscribe(feedID) else { return nil }
        announce(FeedWording.unsubscribed(title: feed.title, outcome: outcome, noun: noun), context.window)
        return outcome
    }

    // MARK: An Item's Commands

    /// Runs `action` for one of a feed's items, from its row or its book's
    /// row, saying what it did from the window it was chosen in. A refusal,
    /// such as Delete Download while the book is open, shows in an alert in
    /// the engine's words, which VoiceOver also hears.
    func perform(_ action: FeedItemAction, in context: FeedCommandContext) {
        let center = context.center
        guard let record = center.store.record(of: action.feedID), let item = record.item(action.itemID) else { return }
        let state = center.state(of: item, in: action.feedID)
        switch action.command {
        case .open:
            // A download, or a book moved into the library (FR11, branch D),
            // opens at once; anything else downloads first.
            if state.linkedBookID == nil {
                announce(FeedWording.downloadingToOpen(title: item.title), context.window)
            }
            center.open(item.id, of: record.feed.id)
        case .download:
            center.download(item.id, of: record.feed.id)
            announce(FeedWording.downloading(title: item.title), context.window)
        case .cancelDownload:
            center.cancelDownload(item.id, of: record.feed.id)
            // A download the newest-N rule put off was waiting, not under
            // way (FR11): say that it waits no more.
            let cancelled = state.waitingReason == nil
                ? FeedWording.downloadCancelled(title: item.title)
                : FeedWording.waitingDownloadCancelled(title: item.title)
            announce(cancelled, context.window)
        case .deleteDownload:
            do {
                try center.deleteDownload(item.id, of: record.feed.id)
                // A package that held the listener's place was kept, its
                // row waiting on the feed's shelf (FR11, branch A2).
                let keptPlace = context.library.feedItemRows(of: record.feed.id).kept[item.id] != nil
                announce(FeedWording.downloadDeleted(title: item.title, keptPlace: keptPlace), context.window)
            } catch {
                refuse(error, in: context)
            }
        case .markPlayed, .markUnplayed:
            let played = action.command == .markPlayed
            if played {
                center.markPlayed(item.id, of: record.feed.id)
            } else {
                center.markUnplayed(item.id, of: record.feed.id)
            }
            announce(FeedWording.marked(title: item.title, played: played, isArticle: item.isArticle), context.window)
        case .showDescription:
            itemDescription = FeedItemDescription(item, of: record.feed)
        case .showInFinder:
            if let bookID = state.bookID, let book = context.library.bookByID(bookID) {
                revealBooks([book])
            }
        case .deleteItem:
            confirmation = FeedConfirmation(
                kind: .deleteItem(feedID: record.feed.id, itemID: item.id, title: item.title),
                title: FeedWording.deleteItemQuestion(title: item.title),
                message: FeedWording.deleteItemMessage(
                    isArticle: item.isArticle,
                    keepsListenerState: keepsListenerState(of: item.id, in: record.feed.id, context),
                    isInLibrary: state.libraryBookID != nil
                ),
                confirmTitle: FeedWording.deleteItemButton(isArticle: item.isArticle)
            )
        }
    }

    /// Whether TextMouth keeps something of the listener's for the item
    /// `itemID` of the feed `feedID`, which Delete Episode deletes with it
    /// (FR11, branch A2): a package kept after its download went, or a
    /// download whose package holds the listener's place, playback times,
    /// bookmarks, settings, or transcript (`FeedItemPackage.holdsListenerState`).
    private func keepsListenerState(of itemID: FeedItem.ID, in feedID: UUID, _ context: FeedCommandContext) -> Bool {
        let rows = context.library.feedItemRows(of: feedID)
        if rows.kept[itemID] != nil {
            return true
        }
        guard let downloaded = rows.downloaded[itemID] else { return false }
        return FeedItemPackage.holdsListenerState(downloaded, package: downloaded.tmbDirectory)
    }

    // MARK: Every Feed

    /// Refreshes every feed now, as Library > Refresh All Feeds asks, and
    /// says what came, from the window it was chosen in.
    /// - Returns: The refresh, which tests await.
    @discardableResult
    func refreshAll(in context: FeedCommandContext) -> Task<Void, Never> {
        Task {
            await context.center.refreshAllSaying { [weak self] message in
                self?.announce(message, context.window)
            }
        }
    }

    // MARK: Confirmations

    /// Does what `confirmation` asked about, once the listener confirmed it.
    func confirm(_ confirmation: FeedConfirmation, in context: FeedCommandContext) {
        switch confirmation.kind {
        case let .deleteItem(feedID, itemID, title):
            do {
                try context.center.deleteItem(itemID, of: feedID)
                // An item moved into the library keeps its book there (FR11,
                // branch D), and its state says so after the deletion too.
                let inLibrary = context.center.store.record(of: feedID)?.item(itemID)?.state.libraryBookID != nil
                announce(FeedWording.itemDeleted(title: title, isInLibrary: inLibrary), context.window)
            } catch {
                refuse(error, in: context)
            }
        case .unsubscribe(let feedID):
            unsubscribe(feedID, in: context)
        }
    }

    /// Shows why a deletion was refused, in the engine's words for a book
    /// open in a reader and in the file system's otherwise, and says it.
    private func refuse(_ error: Error, in context: FeedCommandContext) {
        let message = (error as? BookCloudError)?.explanation(in: nil) ?? error.localizedDescription
        notice = FeedNotice(title: FeedWording.deleteRefusedTitle, message: message)
        announce(message, context.window)
    }
}

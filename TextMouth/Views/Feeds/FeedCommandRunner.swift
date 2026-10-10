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
/// Episode or Delete Article, and Unsubscribe.
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
    /// - Returns: The work Check Feed started, which tests await; nil for
    ///   the commands that finish at once or ask first.
    @discardableResult
    func perform(_ action: FeedAction, in context: FeedCommandContext) -> Task<Void, Never>? {
        let center = context.center
        guard let feed = center.store.record(of: action.feedID)?.feed else { return nil }
        switch action.command {
        case .checkFeed:
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
        }
        return nil
    }

    /// The question asked before unsubscribing from the feed `feedID`,
    /// naming the books its downloads made, which stay; nil once it is no
    /// longer subscribed.
    func unsubscribeConfirmation(for feedID: UUID, in context: FeedCommandContext) -> FeedConfirmation? {
        guard let feed = context.center.store.record(of: feedID)?.feed else { return nil }
        return FeedConfirmation(
            kind: .unsubscribe(feedID: feedID),
            title: FeedWording.unsubscribeQuestion(title: feed.title),
            message: FeedWording.unsubscribeMessage(
                bookTitles: downloadedBooks(of: feedID, in: context).map(\.title),
                folderPath: context.center.folderPath(of: feed)
            ),
            confirmTitle: FeedWording.unsubscribeButton
        )
    }

    /// Ends the subscription to the feed `feedID`, once confirmed: its
    /// downloads stay as books, and VoiceOver hears how many.
    func unsubscribe(_ feedID: UUID, in context: FeedCommandContext) {
        guard let feed = context.center.store.record(of: feedID)?.feed else { return }
        let books = downloadedBooks(of: feedID, in: context)
        context.center.unsubscribe(feedID)
        if feedInfo?.feedID == feedID {
            feedInfo = nil
        }
        announce(FeedWording.unsubscribed(title: feed.title, bookCount: books.count), context.window)
    }

    /// The books the feed `feedID`'s downloads made that the library lists,
    /// newest item first.
    private func downloadedBooks(of feedID: UUID, in context: FeedCommandContext) -> [Book] {
        context.center.listedItems(of: feedID).compactMap { item in
            context.center.downloadedRow(of: item, in: feedID)
        }
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
            if state.bookID == nil {
                announce(FeedWording.downloadingToOpen(title: item.title), context.window)
            }
            center.open(item.id, of: record.feed.id)
        case .download:
            center.download(item.id, of: record.feed.id)
            announce(FeedWording.downloading(title: item.title), context.window)
        case .cancelDownload:
            center.cancelDownload(item.id, of: record.feed.id)
            announce(FeedWording.downloadCancelled(title: item.title), context.window)
        case .deleteDownload:
            do {
                try center.deleteDownload(item.id, of: record.feed.id)
                announce(FeedWording.downloadDeleted(title: item.title), context.window)
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
                message: FeedWording.deleteItemMessage(isArticle: item.isArticle),
                confirmTitle: FeedWording.deleteItemButton(isArticle: item.isArticle)
            )
        }
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
                announce(FeedWording.itemDeleted(title: title), context.window)
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

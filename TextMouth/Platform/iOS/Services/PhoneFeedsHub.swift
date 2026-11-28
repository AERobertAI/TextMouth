import Combine
import Foundation

/// What the iPhone's screens share of the feed reader (FR53, phase F1): the
/// one presenter whose sheets and alerts the root shows
/// (`PhoneFeedPresentations`), and the way a Library row's command, or the
/// Add to Library sheet's Add Feed…, reaches the Mac's own command runner.
///
/// The Mac gives each Library window a `LibraryFeedsPresenter`; the phone has
/// one window, so one presenter serves every Library screen stacked in it. It
/// is shared code: this only decides where its announcements go (the phone's
/// announcer, queued after VoiceOver's own speech) and finds what a row's
/// command acts on. The commands themselves, their words, and their
/// confirmations are the Mac's (`FeedCommandRunner`).
@MainActor
final class PhoneFeedsHub {
    /// The app's one hub.
    static let shared = PhoneFeedsHub()

    /// The sheets and alerts the root shows, and the runner of every command.
    let presenter: LibraryFeedsPresenter

    /// The folder Add Feed… was chosen to put the feed's folder in, kept
    /// while the Add to Library sheet it was chosen in closes, since a sheet
    /// the choice opens would be refused while that one is still closing (as
    /// on the Mac, `AddToLibraryModel`). Nil when none was chosen.
    private var requestedAddFeedParent: String?

    /// The items the listener opened from a row, whose downloads open them when they end, so their ending is the reader
    /// opening and says itself (`PhoneFeedAnnouncements`).
    private var opening: Set<PhoneFeedAnnouncements.ItemKey> = []
    /// Hears the engine's announcements, once `listen(to:)` has been called.
    private var eventSubscription: AnyCancellable?

    /// A hub whose presenter says what it does through the phone's announcer.
    init(presenter: LibraryFeedsPresenter = LibraryFeedsPresenter()) {
        self.presenter = presenter
        // The phone has one window, so the Mac's "from the window it was chosen in" is nothing: what a command says is
        // queued after VoiceOver's own speech about the change, as the Library's other announcements are.
        presenter.announce = { message, _ in PhoneAnnouncer.say(message) }
    }

    // MARK: - Hearing the Downloads End

    /// Starts saying how the downloads the listener asked for end, as `center` announces them; once only, whichever
    /// screen asks first.
    func listen(to center: FeedCenter) {
        guard eventSubscription == nil else { return }
        eventSubscription = center.events
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak center] event in
                MainActor.assumeIsolated {
                    guard let self, let center else { return }
                    self.heard(event, in: center)
                }
            }
    }

    /// Says what `event` calls for (`PhoneFeedAnnouncements`), then forgets that the item it ends was being opened.
    func heard(_ event: FeedEvent, in center: FeedCenter) {
        if let words = PhoneFeedAnnouncements.words(for: event, in: center, opening: opening) {
            PhoneAnnouncer.say(words)
        }
        switch event {
        case .downloadFinished(let feedID, let itemID, _), .downloadFailed(let feedID, let itemID, _), .downloadCancelled(let feedID, let itemID):
            opening.remove(PhoneFeedAnnouncements.ItemKey(feedID: feedID, itemID: itemID))
        case .subscribed, .refreshed, .refreshedAll, .downloadStarted, .itemPolicyApplied:
            break
        }
    }

    // MARK: - Add Feed…

    /// Remembers that Add Feed… was chosen in the Add to Library sheet that
    /// puts books in the folder at `folderPath`, for `showRequestedAddFeed(in:)`
    /// to open once that sheet has closed.
    func requestAddFeed(parentPath folderPath: String) {
        requestedAddFeedParent = folderPath
    }

    /// Opens the Add Feed sheet if one was chosen, once the Add to Library
    /// sheet has closed: its feed's folder goes first in the folder the
    /// Library showed when it can hold one, else at the top.
    func showRequestedAddFeed(in library: LibraryViewModel) {
        guard let shown = requestedAddFeedParent else { return }
        requestedAddFeedParent = nil
        let feedFolders = LibraryFeedFolders.shared
        let parent = AddFeedPlaces.initialParent(shownPath: shown, in: library.library, feedFolders: feedFolders)
        // A turn later, so the sheet that has just closed has finished going.
        DispatchQueue.main.async { [presenter] in
            presenter.showAddFeed(center: library.feeds, parentPath: parent)
        }
    }

    // MARK: - A Row's Commands

    /// What a command works with: the engine, the library, and no window.
    func context(in library: LibraryViewModel) -> FeedCommandContext {
        FeedCommandContext(center: library.feeds, library: library, window: nil)
    }

    /// Runs the Mac's feed command `command` for the feed `feedID`, as its row offers it, saying what it did. Nothing
    /// happens once the feed is gone, or no longer offers the command (an unsubscribed feed's row offers Resubscribe).
    func perform(_ command: FeedCommand, feedID: UUID, in library: LibraryViewModel) {
        guard let action = PhoneFeedRows.feedAction(command, feedID: feedID, in: library.feeds) else { return }
        presenter.perform(action, in: context(in: library))
    }

    /// Runs the Mac's item command `command` for the item `itemID` of the feed `feedID`, from the item's row or its
    /// downloaded book's row, saying what it did; nothing once the item is gone.
    func perform(_ command: FeedItemCommand, feedID: UUID, itemID: FeedItem.ID, in library: LibraryViewModel) {
        guard let action = PhoneFeedRows.itemAction(command, feedID: feedID, itemID: itemID, in: library.feeds) else { return }
        // Open downloads an item that is not here and then opens it: the reader opening says that download's end.
        if command == .open, let item = library.feeds.store.record(of: feedID)?.item(itemID),
           library.feeds.state(of: item, in: feedID).linkedBookID == nil {
            opening.insert(PhoneFeedAnnouncements.ItemKey(feedID: feedID, itemID: itemID))
        }
        presenter.perform(action, in: context(in: library))
    }
}

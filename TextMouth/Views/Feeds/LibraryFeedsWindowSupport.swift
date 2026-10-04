import AppKit
import SwiftUI

// MARK: - A Library Window's Feed Sheets (FR03)

/// A notice the Library window shows about the feeds in an alert, with OK:
/// the plain-http warning after a subscription, or a command's refusal.
/// VoiceOver reads it as it appears.
struct FeedNotice: Identifiable, Equatable {
    /// Tells two notices apart, so a second one shows even with the same
    /// words.
    let id = UUID()
    /// The alert's title.
    let title: String
    /// The alert's message.
    let message: String
}

/// What one Library window shows for the feeds (FR03): the Add Feed sheet,
/// Feed Info, an item's description, the questions asked before a command
/// that can't be undone, and the notices that follow the commands, which it
/// also runs (`FeedCommandRunner.swift`). Each Library window has its own,
/// made once and kept for the window's life; the window does not observe
/// it, so a sheet opening or closing redraws only the sheets' host
/// (`LibraryFeedsWindowSupport`), never the library list.
@MainActor
final class LibraryFeedsPresenter: ObservableObject {
    /// The Add Feed sheet's work while the sheet shows.
    @Published var addFeed: AddFeedModel?
    /// The notice shown in an alert, if any.
    @Published var notice: FeedNotice?
    /// The Feed Info sheet's model while the sheet shows.
    @Published var feedInfo: FeedInfoModel?
    /// What the Show Description… sheet shows, while it shows.
    @Published var itemDescription: FeedItemDescription?
    /// The confirmation asked before a command that can't be undone, while
    /// it shows.
    @Published var confirmation: FeedConfirmation?

    /// Speaks what a command did, from the window it was chosen in: through
    /// VoiceOver, unless a test listens instead.
    var announce: @MainActor (String, NSWindow?) -> Void = { message, window in
        VoiceOverAnnouncer.announce(message, from: window)
    }
    /// Selects books' packages in Finder (Show in Finder), as the library's
    /// own command does, unless a test watches instead.
    var revealBooks: @MainActor ([Book]) -> Void = { books in
        LibraryCloudCommands.shared.showInFinder(books)
    }

    /// The feed subscribed to through the Add Feed sheet that just closed,
    /// which `addFeedDidClose(in:)` then tells the listener about.
    private(set) var justSubscribed: Feed?

    /// Opens the Add Feed sheet subscribing through `center`, its feed's
    /// folder going in the folder at `parentPath` until the listener
    /// chooses another. A sheet already open stays as it is.
    func showAddFeed(center: FeedCenter, parentPath: String) {
        guard addFeed == nil else { return }
        justSubscribed = nil
        addFeed = AddFeedModel(center: center, parentPath: parentPath)
    }

    /// Closes the Add Feed sheet once its subscription is made, keeping the
    /// feed for `addFeedDidClose(in:)`.
    func addFeedSubscribed(_ feed: Feed) {
        justSubscribed = feed
        addFeed = nil
    }

    /// Closes the Add Feed sheet without subscribing.
    func cancelAddFeed() {
        addFeed?.cancel()
        addFeed = nil
    }

    /// Tells the listener about the subscription the closed sheet made, from
    /// the Library window `window`, which is in front again: a feed using
    /// plain http shows its warning once, which says the subscription was
    /// made; any other is announced, a moment later, once VoiceOver has
    /// settled back on the library.
    func addFeedDidClose(in window: NSWindow?, center: FeedCenter) {
        guard let feed = justSubscribed else { return }
        justSubscribed = nil
        // The record as the engine keeps it now, read when the feed was.
        let current = center.store.record(of: feed.id)?.feed ?? feed
        if current.usesInsecureTransport {
            notice = FeedNotice(title: FeedWording.insecureTitle, message: FeedWording.insecureMessage(title: current.title))
            return
        }
        let items = center.listedItems(of: feed.id)
        let message = FeedWording.subscribed(title: current.title, itemCount: items.count, noun: .of(items))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            VoiceOverAnnouncer.announce(message, from: window)
        }
    }
}

// MARK: - The Window's Part

/// A Library window's part in the feed reader (FR03): it takes the Library
/// menu's feed commands when the window takes commands, and shows the Add
/// Feed sheet and the feed notices on the window.
struct LibraryFeedsWindowSupport: ViewModifier {
    /// What the window shows for the feeds.
    @ObservedObject var presenter: LibraryFeedsPresenter
    /// Which folders hold feeds, and the engine they follow.
    let feedFolders: LibraryFeedFolders
    /// The library the window shows.
    let library: LibraryViewModel
    /// The window, once known.
    let hostWindow: NSWindow?
    /// The folder the window shows ("" for the top level), and whether it
    /// shows folders at all, which decide where Add Feed first offers to
    /// put a feed's folder.
    let shownFolderPath: String?
    /// Whether this window takes the menu command `notification` posts.
    let takesCommand: (Notification) -> Bool
    /// The alert after a refresh TextMouth made by itself brought new
    /// items, which one Library window in front shows.
    @ObservedObject var arrivals: FeedArrivals = .shared

    func body(content: Content) -> some View {
        content
            // The arrivals alert waits for a Library window in front: one
            // that is key as the alert comes, or the first to become key.
            .onReceive(arrivals.$pendingAlert) { _ in
                claimArrivalsAlert()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                if let hostWindow, (notification.object as? NSWindow) === hostWindow {
                    claimArrivalsAlert()
                }
            }
            .alert(arrivals.pendingAlert?.title ?? "", isPresented: isShowingArrivals, presenting: arrivals.pendingAlert) { _ in
                Button("OK", role: .cancel) {
                    arrivals.dismissAlert()
                }
            } message: { alert in
                Text(alert.message)
            }
            .onReceive(NotificationCenter.default.publisher(for: .addFeed)) { notification in
                guard takesCommand(notification) else { return }
                showAddFeed()
            }
            .onReceive(NotificationCenter.default.publisher(for: .refreshAllFeeds)) { notification in
                guard takesCommand(notification) else { return }
                presenter.refreshAll(in: context)
            }
            .sheet(item: $presenter.addFeed, onDismiss: {
                presenter.addFeedDidClose(in: hostWindow, center: feedFolders.center)
            }, content: { model in
                AddFeedSheet(
                    model: model,
                    library: library.library,
                    feedFolders: feedFolders,
                    onCreateFolder: { name, parentPath in
                        library.createFolderReturningOutcome(name: name, parentPath: parentPath)
                    },
                    onSubscribed: { feed in presenter.addFeedSubscribed(feed) },
                    onCancel: { presenter.cancelAddFeed() }
                )
            })
            .sheet(item: $presenter.feedInfo) { model in
                FeedInfoSheet(
                    model: model,
                    feedFolders: feedFolders,
                    unsubscribeConfirmation: { presenter.unsubscribeConfirmation(for: model.feedID, in: context) },
                    onUnsubscribe: { presenter.unsubscribe(model.feedID, in: context) },
                    onDone: { presenter.feedInfo = nil }
                )
            }
            .sheet(item: $presenter.itemDescription) { description in
                FeedItemDescriptionSheet(description: description) {
                    presenter.itemDescription = nil
                }
            }
            .alert(presenter.notice?.title ?? "", isPresented: isShowingNotice, presenting: presenter.notice) { _ in
                Button("OK", role: .cancel) {}
            } message: { notice in
                Text(notice.message)
            }
            // The question before Delete Episode and Unsubscribe.
            .alert(presenter.confirmation?.title ?? "", isPresented: isConfirming, presenting: presenter.confirmation) { confirmation in
                Button(confirmation.confirmTitle, role: .destructive) {
                    presenter.confirm(confirmation, in: context)
                }
                Button("Cancel", role: .cancel) {}
            } message: { confirmation in
                Text(confirmation.message)
            }
    }

    /// What the feed commands chosen in this window work with.
    private var context: FeedCommandContext {
        FeedCommandContext(center: feedFolders.center, library: library, window: hostWindow)
    }

    /// Takes the arrivals alert for this window when it is in front and no
    /// other window has taken it. Run on the next turn, as the alert's
    /// publisher announces a new alert before it is stored.
    private func claimArrivalsAlert() {
        let window = hostWindow
        let arrivals = arrivals
        DispatchQueue.main.async {
            arrivals.claimAlert(by: window.map { ObjectIdentifier($0) }, isKeyWindow: window?.isKeyWindow ?? false)
        }
    }

    /// Whether this window shows the arrivals alert: only the window that
    /// took it; dismissing it forgets it.
    private var isShowingArrivals: Binding<Bool> {
        Binding(
            get: {
                guard arrivals.pendingAlert != nil, let hostWindow else { return false }
                return arrivals.alertWindow == ObjectIdentifier(hostWindow)
            },
            set: { isPresented in
                if !isPresented { arrivals.dismissAlert() }
            }
        )
    }

    /// Whether the confirmation's alert shows; dismissing it forgets the
    /// question.
    private var isConfirming: Binding<Bool> {
        Binding(
            get: { presenter.confirmation != nil },
            set: { isPresented in
                if !isPresented { presenter.confirmation = nil }
            }
        )
    }

    /// Opens the Add Feed sheet, its feed's folder going first in the folder
    /// the window shows, when that can hold one.
    private func showAddFeed() {
        let parent = AddFeedPlaces.initialParent(
            shownPath: shownFolderPath ?? "",
            in: library.library,
            feedFolders: feedFolders
        )
        presenter.showAddFeed(center: feedFolders.center, parentPath: parent)
    }

    /// Whether the notice's alert shows; dismissing it forgets the notice.
    private var isShowingNotice: Binding<Bool> {
        Binding(
            get: { presenter.notice != nil },
            set: { isPresented in
                if !isPresented { presenter.notice = nil }
            }
        )
    }
}

extension Notification.Name {
    /// Posted by Library > Add Feed… and the Library window's Add Feed
    /// button: the Library window that takes the command opens the Add Feed
    /// sheet (FR03).
    static let addFeed = Notification.Name("addFeed")
    /// Posted by Library > Refresh All Feeds: the Library window that takes
    /// the command refreshes every feed and says what came (FR03).
    static let refreshAllFeeds = Notification.Name("refreshAllFeeds")
}

/// The feed reader's keyboard shortcuts (FR03).
enum FeedShortcuts {
    /// Library > Add Feed…: Shift-Command-F, which no other menu command and
    /// no default shortcut uses (Command-F alone searches a book).
    static let addFeed = KeyboardShortcut("f", modifiers: [.command, .shift])
}

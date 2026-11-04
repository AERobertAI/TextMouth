#if os(macOS)
import AppKit
#else
import UIKit
#endif
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
    /// The Import OPML sheet's work while the sheet shows.
    @Published var opmlImport: OPMLImportModel?
    /// What Move to Library…'s sheet moves while it shows (FR11, branch D).
    @Published var moveToLibrary: MoveToLibraryRequest?

    /// Speaks what a command did, from the window it was chosen in: through
    /// VoiceOver, unless a test listens instead.
    var announce: @MainActor (String, PlatformWindow?) -> Void = { message, window in
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
    func addFeedDidClose(in window: PlatformWindow?, center: FeedCenter) {
        guard let feed = justSubscribed else { return }
        justSubscribed = nil
        // The record as the engine keeps it now, read when the feed was.
        let current = center.store.record(of: feed.id)?.feed ?? feed
        if current.usesInsecureTransport {
            notice = FeedNotice(title: FeedWording.insecureTitle, message: FeedWording.insecureMessage(title: current.title))
            return
        }
        let message = FeedWording.subscribed(title: current.title, counts: center.counts(of: feed.id))
        VoiceOverAnnouncer.announceAfterSheetCloses(message, from: window)
    }
}

// MARK: - The Window's Part

/// A Library window's part in the feed reader (FR03): it takes the Library
/// menu's feed commands (Add Feed…, Refresh All Feeds, Import OPML…, Export
/// OPML…) when the window takes commands, and shows on the window the feed
/// sheets (Add Feed, Feed Info, an item's description, Import OPML), the
/// questions before a command that can't be undone, the notices after the
/// commands, and the alert after a refresh TextMouth made by itself brought
/// new items, when this window takes it.
struct LibraryFeedsWindowSupport: ViewModifier {
    /// What the window shows for the feeds.
    @ObservedObject var presenter: LibraryFeedsPresenter
    /// Which folders hold feeds, and the engine they follow.
    let feedFolders: LibraryFeedFolders
    /// The library the window shows.
    let library: LibraryViewModel
    /// The window, once known.
    let hostWindow: PlatformWindow?
    /// The folder the window shows ("" for the top level), and whether it
    /// shows folders at all, which decide where Add Feed first offers to
    /// put a feed's folder.
    let shownFolderPath: String?
    /// Whether this window takes the menu command `notification` posts.
    let takesCommand: (Notification) -> Bool
    /// The books selected in the window now, which Move to Library…'s key
    /// acts on (FR11, branch D).
    var selectedBooks: () -> [Book] = { [] }
    /// The alert after a refresh TextMouth made by itself brought new
    /// items, which one Library window in front shows.
    @ObservedObject var arrivals: FeedArrivals = .shared

    /// The modifiers in four parts, applied in this order, each a function
    /// of its own: the whole chain as one expression took the compiler about
    /// eight seconds to type-check (board #1111), the slowest body in the
    /// app, and near the limit past which it gives up.
    func body(content: Content) -> some View {
        withAlerts(withSheets(withMenuCommands(withArrivalsAlert(content))))
    }

    /// The arrivals alert, which waits for a Library window in front: one
    /// that is key as the alert comes, or the first to become key.
    private func withArrivalsAlert(_ view: some View) -> some View {
        view
            .onReceive(arrivals.$pendingAlert) { _ in
                claimArrivalsAlert()
            }
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                if let hostWindow, (notification.object as? NSWindow) === hostWindow {
                    claimArrivalsAlert()
                }
            }
            #else
            // UIKit posts the same notification as a window becomes key.
            .onReceive(NotificationCenter.default.publisher(for: UIWindow.didBecomeKeyNotification)) { notification in
                if let hostWindow, (notification.object as? PlatformWindow) === hostWindow {
                    claimArrivalsAlert()
                }
            }
            #endif
            .alert(arrivals.pendingAlert?.title ?? "", isPresented: isShowingArrivals, presenting: arrivals.pendingAlert) { _ in
                Button("OK", role: .cancel) {
                    arrivals.dismissAlert()
                }
            } message: { alert in
                Text(alert.message)
            }
    }

    /// The Library menu's feed commands, which this window takes when it
    /// takes commands.
    private func withMenuCommands(_ view: some View) -> some View {
        view
            .onReceive(NotificationCenter.default.publisher(for: .addFeed)) { notification in
                guard takesCommand(notification) else { return }
                showAddFeed()
            }
            .onReceive(NotificationCenter.default.publisher(for: .refreshAllFeeds)) { notification in
                guard takesCommand(notification) else { return }
                presenter.refreshAll(in: context)
            }
            .onReceive(NotificationCenter.default.publisher(for: .importOPML)) { notification in
                guard takesCommand(notification) else { return }
                presenter.chooseOPMLFile(in: context, parentPath: initialParentPath)
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportOPML)) { notification in
                guard takesCommand(notification) else { return }
                presenter.chooseOPMLDestination(in: context)
            }
            // Move to Library…'s key, when the user gave it one (FR11,
            // branch D): the selected episodes and articles.
            .onReceive(NotificationCenter.default.publisher(for: .moveToLibrary)) { notification in
                guard takesCommand(notification) else { return }
                presenter.requestMoveToLibrary(selectedBooks(), in: context)
            }
    }

    /// The feed sheets: Import OPML, Add Feed, Feed Info, an item's
    /// description, and Move to Library… (FR11, branch D).
    private func withSheets(_ view: some View) -> some View {
        view
            .sheet(item: $presenter.opmlImport) { model in
                OPMLImportSheet(
                    model: model,
                    library: library.library,
                    feedFolders: feedFolders,
                    onCreateFolder: { name, parentPath in
                        library.createFolderReturningOutcome(name: name, parentPath: parentPath)
                    },
                    onClose: { presenter.opmlImport = nil }
                )
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
                    requestUnsubscribe: { presenter.requestUnsubscribe(model.feedID, in: context) },
                    // Confirmed in Feed Info's own alert: deletes only what
                    // that question named (REV14 feeds 1).
                    onUnsubscribe: { confirmation in presenter.confirm(confirmation, in: context) },
                    onResubscribe: { presenter.resubscribe(model.feedID, in: context) },
                    deleteFeedConfirmation: { presenter.deleteFeedConfirmation(for: model.feedID, in: context) },
                    onDeleteFeed: { presenter.deleteFeed(model.feedID, in: context) },
                    onDone: { presenter.feedInfo = nil }
                )
            }
            .sheet(item: $presenter.itemDescription) { description in
                FeedItemDescriptionSheet(description: description) {
                    presenter.itemDescription = nil
                }
            }
            // What the move did is said once the sheet has closed (REV11 F6).
            .modifier(MoveToLibrarySheetPresentation(
                request: $presenter.moveToLibrary,
                library: library,
                say: { message in presenter.announce(message, hostWindow) }
            ))
    }

    /// The notice after a command, and the question before one that can't
    /// be undone.
    private func withAlerts(_ view: some View) -> some View {
        view
            .alert(presenter.notice?.title ?? "", isPresented: isShowingNotice, presenting: presenter.notice) { _ in
                Button("OK", role: .cancel) {}
            } message: { notice in
                Text(notice.message)
            }
            // The question before Delete Episode, Unsubscribe, and Delete
            // Feed… (FR14).
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
        presenter.showAddFeed(center: feedFolders.center, parentPath: initialParentPath)
    }

    /// Where Add Feed and Import OPML first offer to put a feed's folder:
    /// the folder the window shows, when it can hold one, else the top
    /// level.
    private var initialParentPath: String {
        AddFeedPlaces.initialParent(shownPath: shownFolderPath ?? "", in: library.library, feedFolders: feedFolders)
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
    /// Posted by Library > Import OPML…: the Library window that takes the
    /// command asks for an OPML file and imports its subscriptions (FR03).
    static let importOPML = Notification.Name("importOPML")
    /// Posted by Library > Export OPML…: the Library window that takes the
    /// command asks where to save the subscriptions as OPML (FR03).
    static let exportOPML = Notification.Name("exportOPML")
}

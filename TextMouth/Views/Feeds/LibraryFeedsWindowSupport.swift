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
/// and the notices that follow its commands. Each Library window has its
/// own, made once and kept for the window's life; the window does not
/// observe it, so a sheet opening or closing redraws only the sheets' host
/// (`LibraryFeedsWindowSupport`), never the library list.
@MainActor
final class LibraryFeedsPresenter: ObservableObject {
    /// The Add Feed sheet's work while the sheet shows.
    @Published var addFeed: AddFeedModel?
    /// The notice shown in an alert, if any.
    @Published var notice: FeedNotice?

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

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .addFeed)) { notification in
                guard takesCommand(notification) else { return }
                showAddFeed()
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
            .alert(presenter.notice?.title ?? "", isPresented: isShowingNotice, presenting: presenter.notice) { _ in
                Button("OK", role: .cancel) {}
            } message: { notice in
                Text(notice.message)
            }
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
}

/// The feed reader's keyboard shortcuts (FR03).
enum FeedShortcuts {
    /// Library > Add Feed…: Shift-Command-F, which no other menu command and
    /// no default shortcut uses (Command-F alone searches a book).
    static let addFeed = KeyboardShortcut("f", modifiers: [.command, .shift])
}

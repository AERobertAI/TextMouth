import SwiftUI

/// What the feed reader presents over every iPhone screen (FR53, phase F1):
/// the Add Feed sheet, Feed Info, an item's description, the question asked
/// before a command that can't be undone, and the notice after a command.
/// The Mac's Library window shows the same on itself
/// (`LibraryFeedsWindowSupport`); the phone has one window, so the root shows
/// them for every Library screen stacked in it, and the Library's rows only
/// hand their commands to the hub (`PhoneFeedsHub`).
///
/// Each sheet and alert is a modifier of its own, so the type checker takes
/// the chain (the Mac's window support was split for the same reason).
struct PhoneFeedPresentations: ViewModifier {
    /// The app's model, whose library the feeds' commands work on.
    let model: PhoneAppModel
    /// What is presented, shared with every screen's rows.
    @ObservedObject private var presenter: LibraryFeedsPresenter

    /// The presentations over `model`.
    init(model: PhoneAppModel) {
        self.model = model
        presenter = PhoneFeedsHub.shared.presenter
    }

    func body(content: Content) -> some View {
        withAlerts(withSheets(content))
    }

    /// The library the commands run in.
    private var library: LibraryViewModel { model.library }

    /// What a command chosen in a sheet works with.
    private var context: FeedCommandContext {
        PhoneFeedsHub.shared.context(in: library)
    }

    // MARK: - Sheets

    /// Add Feed, Feed Info, and Show Description…, each over the Mac's model and in a phone sheet.
    private func withSheets(_ view: some View) -> some View {
        view
            .sheet(item: $presenter.addFeed, onDismiss: {
                presenter.addFeedDidClose(in: nil, center: library.feeds)
            }, content: { addFeed in
                PhoneAddFeedSheet(
                    model: addFeed,
                    library: library.library,
                    feedFolders: LibraryFeedFolders.shared,
                    onSubscribed: { feed in presenter.addFeedSubscribed(feed) },
                    onCancel: { presenter.cancelAddFeed() }
                )
            })
            .sheet(item: $presenter.feedInfo) { info in
                PhoneFeedInfoSheet(
                    model: info,
                    requestUnsubscribe: { presenter.requestUnsubscribe(info.feedID, in: context) },
                    // Confirmed in Feed Info's own alert: deletes only what that question named.
                    onUnsubscribe: { confirmation in presenter.confirm(confirmation, in: context) },
                    onResubscribe: { presenter.resubscribe(info.feedID, in: context) },
                    deleteFeedConfirmation: { presenter.deleteFeedConfirmation(for: info.feedID, in: context) },
                    onDeleteFeed: { presenter.deleteFeed(info.feedID, in: context) },
                    onDone: { presenter.feedInfo = nil }
                )
            }
            .sheet(item: $presenter.itemDescription) { description in
                PhoneFeedItemDescriptionSheet(description: description) {
                    presenter.itemDescription = nil
                }
            }
    }

    // MARK: - Alerts

    /// The notice after a command, and the question before one that can't be undone.
    private func withAlerts(_ view: some View) -> some View {
        view
            .alert(presenter.notice?.title ?? "", isPresented: isShowingNotice, presenting: presenter.notice) { _ in
                Button(FeedWording.okTitle, role: .cancel) {}
            } message: { notice in
                Text(notice.message)
            }
            // The question before Delete Episode, Unsubscribe, and Delete Feed… (FR14).
            .alert(presenter.confirmation?.title ?? "", isPresented: isConfirming, presenting: presenter.confirmation) { asked in
                Button(asked.confirmTitle, role: .destructive) {
                    presenter.confirm(asked, in: context)
                }
                Button(FeedWording.cancelTitle, role: .cancel) {}
            } message: { asked in
                Text(asked.message)
            }
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

    /// Whether the confirmation's alert shows; dismissing it forgets the question.
    private var isConfirming: Binding<Bool> {
        Binding(
            get: { presenter.confirmation != nil },
            set: { isPresented in
                if !isPresented { presenter.confirmation = nil }
            }
        )
    }
}

extension View {
    /// The feed reader's presentations, over this view.
    func phoneFeedPresentations(_ model: PhoneAppModel) -> some View {
        modifier(PhoneFeedPresentations(model: model))
    }
}

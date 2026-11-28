import SwiftUI

/// Feed Info… on the iPhone (FR53, phase F1), over the Mac's own
/// `FeedInfoModel` and in the Mac's words: what the feed says of itself and
/// how TextMouth keeps it, each a row VoiceOver reads as one element; its
/// description; and the two commands that end a subscription, Unsubscribe or
/// Resubscribe, and Delete Feed…. The feed's own settings and the folder its
/// downloads go to are phase F4's.
///
/// VoiceOver's order: the feed's title (a heading), Done, the rows (address,
/// web site, author, items, last check, subscription date, and a plain-http
/// warning where it applies), the description's heading and text, then the
/// subscription button and Delete Feed…. Each of those two asks first where
/// the Mac's does, in an alert of the sheet's own, and what it did is said by
/// the runner once the alert has closed.
struct PhoneFeedInfoSheet: View {
    /// What the sheet shows.
    @ObservedObject var model: FeedInfoModel
    /// The engine, observed so the items counted and the last check follow.
    @ObservedObject var center: FeedCenter
    /// Unsubscribes from the feed at once when that deletes nothing, or
    /// returns the question to ask first (FR14).
    let requestUnsubscribe: () -> FeedConfirmation?
    /// Unsubscribes, once the question given is confirmed, deleting only
    /// what it named.
    let onUnsubscribe: (FeedConfirmation) -> Void
    /// Subscribes again, checking the feed at once.
    let onResubscribe: () -> Void
    /// Asks for the Delete Feed question's words for the feed.
    let deleteFeedConfirmation: () -> FeedConfirmation?
    /// Deletes the feed, once confirmed, which closes the sheet.
    let onDeleteFeed: () -> Void
    /// Closes the sheet.
    let onDone: @MainActor () -> Void

    /// The question showing, Unsubscribe's or Delete Feed's, if any.
    @State private var confirmation: FeedConfirmation?

    /// A sheet for `model`, following `model.center`.
    init(
        model: FeedInfoModel,
        requestUnsubscribe: @escaping () -> FeedConfirmation?,
        onUnsubscribe: @escaping (FeedConfirmation) -> Void,
        onResubscribe: @escaping () -> Void,
        deleteFeedConfirmation: @escaping () -> FeedConfirmation?,
        onDeleteFeed: @escaping () -> Void,
        onDone: @escaping @MainActor () -> Void
    ) {
        _model = ObservedObject(wrappedValue: model)
        _center = ObservedObject(wrappedValue: model.center)
        self.requestUnsubscribe = requestUnsubscribe
        self.onUnsubscribe = onUnsubscribe
        self.onResubscribe = onResubscribe
        self.deleteFeedConfirmation = deleteFeedConfirmation
        self.onDeleteFeed = onDeleteFeed
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            Form {
                if let feed = model.feed {
                    let counts = center.counts(of: feed.id)
                    details(of: feed, counts: counts)
                    description(of: feed)
                    commands
                } else {
                    Section {
                        Text(FeedWording.feedGone)
                            .phonePrimaryText()
                            .phoneWholeWords()
                    }
                }
            }
            .navigationTitle(model.feed?.title ?? FeedWording.feedInfoTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                PhoneSheetButton(title: FeedWording.doneTitle, action: onDone)
            }
            .alert(confirmation?.title ?? "", isPresented: isConfirming, presenting: confirmation) { asked in
                Button(asked.confirmTitle, role: .destructive) {
                    confirmed(asked)
                }
                Button(FeedWording.cancelTitle, role: .cancel) {}
            } message: { asked in
                Text(asked.message)
            }
        }
    }

    // MARK: - Parts

    /// What the feed says of itself, and how TextMouth keeps it, its items counted as `counts`.
    private func details(of feed: Feed, counts: FeedItemCounts) -> some View {
        Section {
            row(FeedWording.addressLabelInInfo, feed.feedURL.absoluteString)
            if let site = feed.siteLink {
                row(FeedWording.siteLabel, site.absoluteString)
            }
            if let author = feed.author, !author.isEmpty {
                row(FeedWording.authorLabel, author)
            }
            row(FeedWording.itemsLabel(counts.noun), FeedWording.countsPhrase(counts))
            row(FeedWording.lastCheckLabel, center.checkWording(of: feed.id, now: Date()).visible)
            row(FeedWording.subscribedLabel, FeedWording.itemDate(feed.subscribedDate))
            if let unsubscribed = feed.unsubscribedDate {
                row(FeedWording.unsubscribedLabel, FeedWording.itemDate(unsubscribed))
            }
            if feed.usesInsecureTransport {
                row(FeedWording.securityLabel, FeedWording.insecureNote)
            }
        }
    }

    /// One labelled value, read as one element, "Address, https://…".
    private func row(_ name: String, _ value: String) -> some View {
        PhoneValueRow(name: name, value: value)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(SentenceWording.commaJoined([name, value]))
    }

    /// The feed's description under its heading, in a text area labelled with the feed's title, as the Mac's is.
    @ViewBuilder
    private func description(of feed: Feed) -> some View {
        if let summary = feed.summary?.plainText, !summary.isEmpty {
            Section {
                ReadOnlyTextArea(text: summary, label: FeedWording.descriptionTextLabel(title: feed.title))
                    .frame(minHeight: 160)
            } header: {
                Text(FeedWording.descriptionLabel)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    /// Unsubscribe or Resubscribe by the feed's state, then Delete Feed…, each with the Mac's hint.
    private var commands: some View {
        let toggle = FeedSubscriptionToggle(
            isSubscribed: model.feed?.isSubscribed != false,
            unsubscribeAsks: model.unsubscribeAsks
        )
        return Section {
            PhoneActionButton(title: toggle.title, role: toggle.isDestructive ? .destructive : nil) {
                if toggle.isSubscribed {
                    // At once when it deletes nothing; otherwise asked.
                    confirmation = requestUnsubscribe()
                } else {
                    onResubscribe()
                }
            }
            .accessibilityHint(toggle.hint)
            PhoneActionButton(title: FeedWording.deleteFeedTitle, role: .destructive) {
                confirmation = deleteFeedConfirmation()
            }
            .accessibilityHint(FeedWording.deleteFeedHint)
        }
    }

    // MARK: - Questions

    /// Whether the question's alert shows; dismissing it forgets the question.
    private var isConfirming: Binding<Bool> {
        Binding(
            get: { confirmation != nil },
            set: { isPresented in
                if !isPresented { confirmation = nil }
            }
        )
    }

    /// Does what the question `asked` asked about, once confirmed: Unsubscribe, or Delete Feed… (FR14). Feed Info asks about no item.
    private func confirmed(_ asked: FeedConfirmation) {
        switch asked.kind {
        case .unsubscribe:
            onUnsubscribe(asked)
        case .deleteFeed:
            onDeleteFeed()
        case .deleteItem:
            break
        }
    }
}

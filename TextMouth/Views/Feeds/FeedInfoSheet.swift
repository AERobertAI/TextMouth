import AppKit
import SwiftUI

// MARK: - Feed Info (FR03)

/// What Feed Info… shows and changes for one feed (FR03): what the feed says
/// of itself, where its downloads go, its items and last check, and its two
/// exceptions to the feed settings, each following the global setting until
/// the listener gives the feed its own.
@MainActor
final class FeedInfoModel: ObservableObject, Identifiable {
    /// The feed shown.
    let feedID: UUID
    /// The engine keeping it.
    let center: FeedCenter
    /// The library, for its folders.
    let library: LibraryViewModel
    /// The preferences the global "When book ends" is read from.
    private let defaults: UserDefaults

    /// Feed Info for the feed `feedID` of `center`, in `library`; `defaults`
    /// is where the global "When book ends" setting is read from (FR19).
    init(feedID: UUID, center: FeedCenter, library: LibraryViewModel, defaults: UserDefaults = .standard) {
        self.feedID = feedID
        self.center = center
        self.library = library
        self.defaults = defaults
    }

    /// The feed as its record holds it now, subscribed or not (FR11, branch
    /// D); nil once its record is gone.
    var feed: Feed? {
        center.store.record(of: feedID)?.feed
    }

    /// Whether Unsubscribe would delete the places the feed kept for removed
    /// downloads, so asks first (FR14).
    var unsubscribeAsks: Bool {
        !center.keptRowsUnsubscribeDeletes(of: feedID).isEmpty
    }

    /// The feed's settings as they apply to every feed.
    var globalSettings: FeedSettings {
        center.settings
    }

    // MARK: The Feed's Own Settings

    /// Whether the feed follows the global "List and download" choice and
    /// its number (FR11). Unchecking "Use the global setting" gives the feed
    /// the global choice as its own, to change from there; checking it
    /// again drops the feed's own.
    var usesGlobalItemPolicy: Bool {
        get { feed?.itemPolicyOverride == nil }
        set { center.setItemPolicy(newValue ? nil : globalSettings.itemPolicy, of: feedID) }
    }

    /// What the feed lists and downloads by itself (FR11): its own choice
    /// and number, or the global ones. Setting it gives the feed its own,
    /// which the feed engine acts on once it has stayed unchanged for ten
    /// seconds (`FeedCenter.setItemPolicy(_:of:)`).
    var itemPolicy: FeedItemPolicy {
        get { feed?.itemPolicy(under: globalSettings) ?? globalSettings.itemPolicy }
        set { center.setItemPolicy(newValue, of: feedID) }
    }

    /// Whether the feed follows the global days after playing that a
    /// download is deleted.
    var deletesAfterGlobalDays: Bool {
        get { feed?.deleteDownloadsDaysAfterPlayedOverride == nil }
        set { center.setDeleteDownloadsDaysAfterPlayed(newValue ? nil : globalSettings.deleteDownloadsDaysAfterPlayed, of: feedID) }
    }

    /// The days after playing that the feed's downloads are deleted: its
    /// own, or the global ones.
    var deleteDaysAfterPlaying: Int {
        get { feed?.deleteDownloadsDaysAfterPlayed(under: globalSettings) ?? globalSettings.deleteDownloadsDaysAfterPlayed }
        set { center.setDeleteDownloadsDaysAfterPlayed(newValue, of: feedID) }
    }

    // MARK: The Feed's Listening Options (FR19)

    /// The feed's listening options as its record holds them: the standard
    /// ones for a feed with none of its own. Setting them saves them at once
    /// through the engine, which stores nothing for the standard ones
    /// (`FeedCenter.setListeningOptions(_:of:)`).
    var listeningOptions: ListeningOptions {
        get { feed?.listeningOptions ?? .standard }
        set { center.setListeningOptions(newValue, of: feedID) }
    }

    /// What happens when one of the feed's episodes ends; nil is "Use the
    /// global setting".
    var episodeEnd: ReadingList.Continuation? {
        get { listeningOptions.continuation }
        set { listeningOptions.continuation = newValue }
    }

    /// Whether listening passes over the feed's finished episodes when it
    /// goes on to another.
    var skipsFinishedEpisodes: Bool {
        get { listeningOptions.skipsFinished }
        set { listeningOptions.skipsFinished = newValue }
    }

    /// Whether the episode that plays next is downloaded shortly before the
    /// playing one ends. Kept while the checkbox is dimmed.
    var predownloadsNextEpisode: Bool {
        get { listeningOptions.predownloadsNext }
        set { listeningOptions.predownloadsNext = newValue }
    }

    /// The global "When book ends" setting, which "Use the global setting"
    /// follows and names.
    var globalEndOfBookBehavior: EndOfBookBehavior {
        SettingsPolicy.endOfBookBehavior.storedValue(in: defaults)
    }

    /// Whether listening would go on from one of the feed's episodes to
    /// another, which is when downloading the next one can matter.
    var continuesToAnotherEpisode: Bool {
        listeningOptions.goesOn(under: globalEndOfBookBehavior)
    }

    // MARK: The Feed's Folder

    /// The path of the feed's folder, or "" when it is gone.
    var folderPath: String {
        feed.flatMap { center.folderPath(of: $0) } ?? ""
    }

    /// Lists the feed's items in the folder at `path` from now on, those
    /// already downloaded among them (`FeedCenter.setFolder(_:of:)`).
    func chooseFolder(atPath path: String) {
        guard let folder = library.library.folders.first(where: { $0.fullPath == path }) else { return }
        center.setFolder(folder.id, of: feedID)
    }

    /// The folders the feed's downloads may go to: any but another feed's,
    /// with a stand-in to choose from while its own is gone.
    func folderOptions(feedFolders: LibraryFeedFolders) -> [LibraryFolderOption] {
        let missing = folderPath.isEmpty ? [LibraryFolderOption(label: FeedWording.chooseFolderOption, path: "")] : []
        return missing + LibraryFolderOption.options(in: library.library, includingRoot: false) { folder in
            feedFolders.feedID(inFolder: folder.id).map { $0 == self.feedID } ?? true
        }
    }
}

/// The Feed Info sheet (FR03): the feed's title as its heading; its
/// address, web site, author, items, last check, and subscription date,
/// each a labelled value VoiceOver reads as one; the folder its downloads
/// go to, which can be changed; its description, under a Description
/// heading, in a text area labelled with the feed's title and read with
/// VoiceOver's text navigation; the two settings the feed may keep for
/// itself, each with "Use the global setting": its "List and download"
/// choice and number (FR11), worded with the feed's own noun, and its days
/// before deleting played downloads; one button that is Unsubscribe, which
/// asks first, saying what stays and what goes, only when it would delete
/// the places kept for removed downloads (FR14), or, for a feed the
/// listener unsubscribed from, Resubscribe, which checks it again at once
/// (FR11, branch D); Delete Feed…, which asks first and closes the sheet
/// once the feed is deleted (FR14); and Done, which Escape presses. Every
/// change is saved as it is made, and the sheet stays open across
/// Unsubscribe and Resubscribe.
struct FeedInfoSheet: View {
    /// What the sheet shows and changes.
    @ObservedObject var model: FeedInfoModel
    /// The engine, observed so the items counted and the last check follow.
    @ObservedObject var center: FeedCenter
    /// Which folders hold feeds.
    let feedFolders: LibraryFeedFolders
    /// Unsubscribes from the feed at once when that deletes nothing, or
    /// returns the question to ask first (FR14,
    /// `LibraryFeedsPresenter.requestUnsubscribe(_:in:)`).
    let requestUnsubscribe: () -> FeedConfirmation?
    /// Unsubscribes, once the question given is confirmed, deleting only
    /// what it named (REV14 feeds 1).
    let onUnsubscribe: (FeedConfirmation) -> Void
    /// Subscribes again, checking the feed at once (FR11, branch D).
    let onResubscribe: () -> Void
    /// Asks for the Delete Feed confirmation's words for the feed (FR14).
    let deleteFeedConfirmation: () -> FeedConfirmation?
    /// Deletes the feed, once confirmed, which closes the sheet (FR14).
    let onDeleteFeed: () -> Void
    /// Closes the sheet.
    let onDone: () -> Void

    /// The question showing, Unsubscribe's or Delete Feed's, if any.
    @State private var confirmation: FeedConfirmation?
    /// Why the last folder could not be made.
    @State private var folderFailure: String?
    /// Whether the folder picker's New Folder fields are shown, while
    /// Escape closes them, through their Cancel New Folder, rather than
    /// pressing Done (REV13 app 5).
    @State private var isMakingFolder: Bool

    /// A sheet for `model`, following `model.center`; `makingFolder` opens
    /// it with the folder picker's New Folder fields already shown, as the
    /// tests of the Escape key need.
    init(
        model: FeedInfoModel,
        feedFolders: LibraryFeedFolders,
        requestUnsubscribe: @escaping () -> FeedConfirmation?,
        onUnsubscribe: @escaping (FeedConfirmation) -> Void,
        onResubscribe: @escaping () -> Void = {},
        deleteFeedConfirmation: @escaping () -> FeedConfirmation? = { nil },
        onDeleteFeed: @escaping () -> Void = {},
        onDone: @escaping () -> Void,
        makingFolder: Bool = false
    ) {
        _model = ObservedObject(wrappedValue: model)
        _center = ObservedObject(wrappedValue: model.center)
        self.feedFolders = feedFolders
        self.requestUnsubscribe = requestUnsubscribe
        self.onUnsubscribe = onUnsubscribe
        self.onResubscribe = onResubscribe
        self.deleteFeedConfirmation = deleteFeedConfirmation
        self.onDeleteFeed = onDeleteFeed
        self.onDone = onDone
        _isMakingFolder = State(initialValue: makingFolder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let feed = model.feed {
                // Counted once, for the items' line and for the words of
                // the feed's own settings, which name its items.
                let counts = center.counts(of: feed.id)
                Text(feed.title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        details(of: feed, counts: counts)
                        Divider()
                        ownSettings(noun: counts.noun)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(FeedWording.feedGone)
            }
            OperationFailureNotice(message: folderFailure)
            HStack {
                // Unsubscribe… or Resubscribe by the feed's state, the
                // listener's toggle (FR11, branch D): one button whose title,
                // role, hint, and action follow the state, so VoiceOver's
                // focus stays on it as it toggles (REV13 item 2).
                let toggle = FeedSubscriptionToggle(
                    isSubscribed: model.feed?.isSubscribed != false,
                    unsubscribeAsks: model.unsubscribeAsks
                )
                Button(toggle.title, role: toggle.isDestructive ? .destructive : nil) {
                    if toggle.isSubscribed {
                        // At once when it deletes nothing; otherwise asked.
                        confirmation = requestUnsubscribe()
                    } else {
                        onResubscribe()
                    }
                }
                .accessibilityHint(toggle.hint)
                .disabled(model.feed == nil)
                Button(FeedWording.deleteFeedTitle, role: .destructive) {
                    confirmation = deleteFeedConfirmation()
                }
                .accessibilityHint(FeedWording.deleteFeedHint)
                .disabled(model.feed == nil)
                Spacer()
                // Escape presses Done: every change is kept as it is made,
                // and Return stays with the number fields, which it enters,
                // or with the picker's Create while its fields are shown.
                // While they are shown, Done gives Escape up, so only their
                // Cancel New Folder takes it, as the Move sheet's Cancel
                // does, and a second Escape presses Done (REV13 app 5).
                Button("Done", action: onDone)
                    .keyboardShortcut(isMakingFolder ? nil : KeyboardShortcut.cancelAction)
            }
        }
        .padding()
        .frame(width: 520, height: 600)
        .navigationTitle(FeedWording.feedInfoTitle)
        .alert(confirmation?.title ?? "", isPresented: isConfirming, presenting: confirmation) { confirmation in
            Button(confirmation.confirmTitle, role: .destructive) {
                confirmed(confirmation)
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    /// Does what the question `confirmation` asked about, once confirmed:
    /// Unsubscribe, or Delete Feed… (FR14). Feed Info asks about no item.
    private func confirmed(_ confirmation: FeedConfirmation) {
        switch confirmation.kind {
        case .unsubscribe:
            onUnsubscribe(confirmation)
        case .deleteFeed:
            onDeleteFeed()
        case .deleteItem:
            break
        }
    }

    // MARK: Parts

    /// What the feed says of itself, and how TextMouth keeps it, its items
    /// counted as `counts`.
    @ViewBuilder
    private func details(of feed: Feed, counts: FeedItemCounts) -> some View {
        FeedInfoValue(label: FeedWording.addressLabelInInfo, value: feed.feedURL.absoluteString)
        if let site = feed.siteLink {
            FeedInfoValue(label: FeedWording.siteLabel, value: site.absoluteString)
        }
        if let author = feed.author, !author.isEmpty {
            FeedInfoValue(label: FeedWording.authorLabel, value: author)
        }
        FeedInfoValue(label: FeedWording.itemsLabel(counts.noun), value: FeedWording.countsPhrase(counts))
        FeedInfoValue(label: FeedWording.lastCheckLabel, value: center.checkWording(of: feed.id, now: Date()).visible)
        FeedInfoValue(label: FeedWording.subscribedLabel, value: FeedWording.itemDate(feed.subscribedDate))
        // When the listener unsubscribed, which stopped its checking (FR11,
        // branch D).
        if let unsubscribed = feed.unsubscribedDate {
            FeedInfoValue(label: FeedWording.unsubscribedLabel, value: FeedWording.itemDate(unsubscribed))
        }
        if feed.usesInsecureTransport {
            FeedInfoValue(label: FeedWording.securityLabel, value: FeedWording.insecureNote)
        }

        // The picker's Create takes Return while its New Folder fields are
        // shown, from a number field too, whose number is entered as focus
        // leaves it; the sheet has no Return-key button of its own, and
        // its Done gives Escape up meanwhile (`isMakingFolder`).
        LibraryFolderPicker(
            options: model.folderOptions(feedFolders: feedFolders),
            newFolderParents: LibraryFolderOption.options(in: model.library.library) { folder in
                folder.depth < BookFolder.maxDepth && !feedFolders.holdsFeed(folder)
            },
            selection: Binding(get: { model.folderPath }, set: { model.chooseFolder(atPath: $0) }),
            caption: FeedWording.folderInfoCaption,
            accessibilityLabel: FeedWording.folderInfoLabel,
            onCreateFolder: { name, parentPath in
                model.library.createFolderReturningOutcome(name: name, parentPath: parentPath)
            },
            failureMessage: $folderFailure,
            isMakingFolder: $isMakingFolder
        )
        Text(FeedWording.folderInfoHelp)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if let summary = feed.summary?.plainText, !summary.isEmpty {
            Text(FeedWording.descriptionLabel)
                .font(.subheadline)
                .accessibilityAddTraits(.isHeader)
            // Labelled with the feed's title, as Show Description labels its
            // text area with the item's: labelled Description, VoiceOver
            // would say the heading's word twice in a row.
            ReadOnlyTextArea(text: summary, label: FeedWording.descriptionTextLabel(title: feed.title))
                .frame(height: 120)
        }
    }

    /// The two settings the feed may keep for itself, the first worded with
    /// `noun`, what the feed's items are called: its "List and download"
    /// choice and number (FR11), its checkbox naming the global choice as
    /// Settings words it, and its days before deleting played downloads.
    private func ownSettings(noun: FeedWording.ItemNoun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(FeedWording.ownSettingsHeading)
                .font(.subheadline)
                .accessibilityAddTraits(.isHeader)
            Toggle(
                FeedWording.useGlobal(FeedWording.itemPolicyTitle(model.globalSettings.itemPolicy, noun: nil)),
                isOn: Binding(get: { model.usesGlobalItemPolicy }, set: { model.usesGlobalItemPolicy = $0 })
            )
            .accessibilityHint(FeedWording.useGlobalHint)
            FeedItemPolicyControls(
                policy: Binding(get: { model.itemPolicy }, set: { model.itemPolicy = $0 }),
                noun: noun,
                isDisabled: model.usesGlobalItemPolicy
            )
            Toggle(
                FeedWording.useGlobal(
                    FeedThresholdWording.deleteDownloadsAfterPlaying.caption(
                        model.globalSettings.deleteDownloadsDaysAfterPlayed,
                        rule: SettingsPolicy.feedDeleteDownloadsDaysAfterPlayed
                    )
                ),
                isOn: Binding(get: { model.deletesAfterGlobalDays }, set: { model.deletesAfterGlobalDays = $0 })
            )
            .accessibilityHint(FeedWording.useGlobalHint)
            FeedThresholdControl(
                rule: SettingsPolicy.feedDeleteDownloadsDaysAfterPlayed,
                wording: .deleteDownloadsAfterPlaying,
                value: Binding(get: { model.deleteDaysAfterPlaying }, set: { model.deleteDaysAfterPlaying = $0 }),
                isDisabled: model.deletesAfterGlobalDays
            )
            listeningControls(noun: ListeningOptionsWording.Noun(noun))
        }
    }

    /// The feed's three listening controls (FR19), worded with `noun`: what
    /// happens when one of its items ends, whether listening passes over the
    /// finished ones, and whether the next one is downloaded before the
    /// playing one ends. Built as the Reading List's options bar builds its
    /// pop-up button and checkbox, so the keyboard and VoiceOver reach them
    /// as they reach any other; each choice is saved as it is made.
    @ViewBuilder
    private func listeningControls(noun: ListeningOptionsWording.Noun) -> some View {
        // The label is spoken from the control itself: a pop-up button takes
        // no label from the picker's title.
        let endLabel = ListeningOptionsWording.continuationLabel(noun)
        let endHint = ListeningOptionsWording.continuationHint(noun)
        Picker(endLabel, selection: Binding(get: { model.episodeEnd }, set: { model.episodeEnd = $0 })) {
            ForEach(FolderSettingsModel.continuationChoices, id: \.self) { choice in
                Text(ListeningOptionsWording.continuationTitle(choice, noun: noun, global: model.globalEndOfBookBehavior))
                    .tag(choice)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help(endHint)
        .accessibilityLabel(endLabel)
        .accessibilityHint(endHint)

        let skipLabel = ListeningOptionsWording.skipFinishedLabel(noun)
        let skipHint = ListeningOptionsWording.skipFinishedHint(noun)
        Toggle(skipLabel, isOn: Binding(get: { model.skipsFinishedEpisodes }, set: { model.skipsFinishedEpisodes = $0 }))
            .toggleStyle(.checkbox)
            .help(skipHint)
            .accessibilityLabel(skipLabel)
            .accessibilityHint(skipHint)

        // Dimmed while listening would stop at the end of an item, since
        // there is then no next one to download; the hint says so, and the
        // choice is kept for when listening goes on again.
        let goesOn = model.continuesToAnotherEpisode
        let downloadLabel = ListeningOptionsWording.predownloadLabel(noun)
        let downloadHint = ListeningOptionsWording.predownloadHint(noun, enabled: goesOn)
        Toggle(downloadLabel, isOn: Binding(get: { model.predownloadsNextEpisode }, set: { model.predownloadsNextEpisode = $0 }))
            .toggleStyle(.checkbox)
            .disabled(!goesOn)
            .help(downloadHint)
            .accessibilityLabel(downloadLabel)
            .accessibilityHint(downloadHint)
    }

    /// Whether a question shows; dismissing it forgets it.
    private var isConfirming: Binding<Bool> {
        Binding(
            get: { confirmation != nil },
            set: { isPresented in
                if !isPresented { confirmation = nil }
            }
        )
    }
}

/// Feed Info's one subscription button, as the feed's state makes it
/// (FR11, branch D; REV13 item 2): Unsubscribe for a feed the listener is
/// subscribed to, "Unsubscribe…", destructive and asking first, when it
/// would delete the places kept for removed downloads (FR14), or
/// Resubscribe for one unsubscribed from. One button, never two in turn,
/// so VoiceOver's focus stays on it as the state toggles.
struct FeedSubscriptionToggle: Equatable {
    /// Whether the listener is subscribed to the feed, so the button
    /// unsubscribes.
    let isSubscribed: Bool
    /// Whether Unsubscribe would delete the places the feed kept for
    /// removed downloads, so asks first (FR14).
    var unsubscribeAsks = true

    /// The button's title.
    var title: String {
        isSubscribed ? FeedWording.unsubscribeTitle(asksFirst: unsubscribeAsks) : FeedWording.resubscribeTitle
    }

    /// Whether the button's role is destructive: Unsubscribe deletes what
    /// the feed kept of removed downloads, when it kept some.
    var isDestructive: Bool {
        isSubscribed && unsubscribeAsks
    }

    /// The button's spoken hint.
    var hint: String {
        isSubscribed ? FeedWording.unsubscribeHint(asksFirst: unsubscribeAsks) : FeedWording.resubscribeHint
    }
}

/// One labelled value of Feed Info, and of a feed item's read-only Book
/// Info (FR11), which VoiceOver reads as one element, "Address, https://…",
/// and whose value can be selected and copied.
struct FeedInfoValue: View {
    /// What the value is.
    let label: String
    /// The value.
    let value: String
    /// The value as VoiceOver says it, where it differs from what is shown,
    /// as a duration shown "1:04:00" is said "1 hour, 4 minutes"; nil to say
    /// it as shown.
    var spokenValue: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(spokenValue ?? value)")
    }
}

// MARK: - Show Description…

/// What Show Description… shows of an item (FR03): its title, its feed and
/// date, its text, and its web page.
struct FeedItemDescription: Identifiable, Equatable {
    /// The item's identity.
    let id: FeedItem.ID
    /// The item's title.
    let title: String
    /// The feed's title, the item's date, and its duration, as one line.
    let details: String
    /// The item's text: its full content when the feed gives it, else its
    /// summary, else a sentence saying it has none.
    let text: String
    /// The item's web page, if the feed names one.
    let link: URL?

    /// What Show Description… shows of `item` of `feed`.
    init(_ item: FeedItem, of feed: Feed) {
        id = item.id
        title = item.title
        var details = [feed.title]
        if let published = item.published {
            details.append(FeedWording.itemDate(published))
        }
        if let duration = item.duration {
            details.append(TimeFormatting.spoken(duration))
        }
        self.details = details.joined(separator: ", ")
        let content = item.content?.plainText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary = item.summary?.plainText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        text = !content.isEmpty ? content : (!summary.isEmpty ? summary : FeedWording.noDescription(isArticle: item.isArticle))
        link = item.link
    }
}

/// The Show Description… sheet (FR03): the item's title as its heading, a
/// line naming its feed, date, and duration, and its text in a text area
/// that keyboard and VoiceOver focus start in, read with VoiceOver's text
/// navigation; Close, which Escape and Return press.
struct FeedItemDescriptionSheet: View {
    /// What the sheet shows.
    let description: FeedItemDescription
    /// Closes the sheet.
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(description.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(description.details)
                .font(.callout)
                .foregroundStyle(.secondary)
            ReadOnlyTextArea(text: description.text, label: FeedWording.descriptionTextLabel(title: description.title), takesFocus: true)
                .frame(minHeight: 240)
            if let link = description.link {
                FeedInfoValue(label: FeedWording.webPageLabel, value: link.absoluteString)
            }
            HStack {
                Spacer()
                // Return presses Close: nothing in the sheet takes typing.
                // A button carries one shortcut, so Escape closes through
                // the key equivalent below instead.
                Button("Close", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 520, height: 440)
        .navigationTitle(description.title)
        // Escape closes the sheet too, wherever focus is, as Return does.
        // Not the exit command: from the text area, an AppKit text view,
        // that command never reaches SwiftUI.
        .background(SilentKeyEquivalent(key: .escape, action: onClose))
    }
}

// MARK: - Words

extension FeedWording {
    /// Feed Info's line for a feed whose record went while it was open:
    /// unsubscribing keeps a feed (FR11, branch D), and Delete Feed… closes
    /// its own Feed Info (FR14), so only Delete Feed… in another window, or
    /// a record lost outside TextMouth, does.
    static let feedGone = "This feed is no longer in your library."
    /// The unsubscription date's label in Feed Info (FR11, branch D).
    static let unsubscribedLabel = "Unsubscribed"
    /// Unsubscribe's spoken hint in Feed Info (FR11, branch D): it asks
    /// first only when it would delete the places kept for removed
    /// downloads (FR14).
    static func unsubscribeHint(asksFirst: Bool) -> String {
        let stops = "stops checking this feed; the feed and its downloads stay"
        return asksFirst ? "Asks first, then \(stops)" : stops.capitalizingFirstLetter
    }
    /// Resubscribe's spoken hint in Feed Info (FR11, branch D).
    static let resubscribeHint = "Checks this feed again from now on, and at once"
    /// The address's label in Feed Info.
    static let addressLabelInInfo = "Address"
    /// The web site's label.
    static let siteLabel = "Web site"
    /// The author's label.
    static let authorLabel = "Published by"
    /// The items' label: "Episodes".
    static func itemsLabel(_ noun: ItemNoun) -> String {
        noun.plural.capitalized
    }
    /// The last check's label.
    static let lastCheckLabel = "Last check"
    /// The subscription date's label.
    static let subscribedLabel = "Subscribed"
    /// The plain-http note's label.
    static let securityLabel = "Security"
    /// The plain-http note in Feed Info.
    static let insecureNote = "Plain http: what this feed sends can be read or changed on the way."
    /// The folder picker's caption in Feed Info.
    static let folderInfoCaption = "Downloads go to"
    /// The folder picker's spoken label in Feed Info.
    static let folderInfoLabel = "Folder the feed's downloads go to"
    /// The line under Feed Info's folder picker. A feed's downloads stay in
    /// the feed's own folder in the data directory, and the library folder
    /// only lists them (FR11), so all of them follow the choice.
    static let folderInfoHelp = "Choosing another folder lists the feed's episodes and articles there instead, "
        + "those already downloaded too."
    /// The stand-in Feed Info's folder picker shows while the feed's folder is gone.
    static let chooseFolderOption = "Choose a folder"
    /// The Description heading in Feed Info; the text area under it is
    /// labelled `descriptionTextLabel(title:)`, so VoiceOver does not say
    /// Description twice.
    static let descriptionLabel = "Description"
    /// The heading of the feed's own settings.
    static let ownSettingsHeading = "This Feed's Settings"
    /// A "Use the global setting" checkbox's title, naming the global value:
    /// "Use the global setting (Every item listed, newest 5 downloaded)".
    static func useGlobal(_ globalCaption: String) -> String {
        "Use the global setting (\(globalCaption))"
    }
    /// A "Use the global setting" checkbox's hint.
    static let useGlobalHint = "When checked, this feed follows the setting in Settings, Feeds; uncheck it to give the feed its own"
    /// The web page's label in Show Description.
    static let webPageLabel = "Web page"
    /// The spoken label of a description's text area, naming whose it is:
    /// Feed Info's, with the feed's title, and Show Description's, with the
    /// item's.
    static func descriptionTextLabel(title: String) -> String {
        "Description of \(title)"
    }
    /// What Show Description says for an item without one.
    static func noDescription(isArticle: Bool) -> String {
        "This \(isArticle ? "article" : "episode") has no description."
    }
}

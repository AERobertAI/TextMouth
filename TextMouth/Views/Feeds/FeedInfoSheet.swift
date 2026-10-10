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

    /// Feed Info for the feed `feedID` of `center`, in `library`.
    init(feedID: UUID, center: FeedCenter, library: LibraryViewModel) {
        self.feedID = feedID
        self.center = center
        self.library = library
    }

    /// The feed as its record holds it now; nil once it is unsubscribed.
    var feed: Feed? {
        center.store.record(of: feedID)?.feed
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

    // MARK: The Feed's Folder

    /// The path of the feed's folder, or "" when it is gone.
    var folderPath: String {
        feed.flatMap { center.folderPath(of: $0) } ?? ""
    }

    /// Sends the feed's downloads from now on to the folder at `path`; the
    /// books it downloaded stay where they are.
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
/// before deleting played downloads; Unsubscribe…, which asks first and
/// names the books left behind; and Done, which Escape presses. Every
/// change is saved as it is made.
struct FeedInfoSheet: View {
    /// What the sheet shows and changes.
    @ObservedObject var model: FeedInfoModel
    /// The engine, observed so the items counted and the last check follow.
    @ObservedObject var center: FeedCenter
    /// Which folders hold feeds.
    let feedFolders: LibraryFeedFolders
    /// Asks for the Unsubscribe confirmation's words for the feed.
    let unsubscribeConfirmation: () -> FeedConfirmation?
    /// Unsubscribes, once confirmed.
    let onUnsubscribe: () -> Void
    /// Closes the sheet.
    let onDone: () -> Void

    /// The Unsubscribe confirmation showing, if any.
    @State private var confirmation: FeedConfirmation?
    /// Why the last folder could not be made.
    @State private var folderFailure: String?

    /// A sheet for `model`, following `model.center`.
    init(
        model: FeedInfoModel,
        feedFolders: LibraryFeedFolders,
        unsubscribeConfirmation: @escaping () -> FeedConfirmation?,
        onUnsubscribe: @escaping () -> Void,
        onDone: @escaping () -> Void
    ) {
        _model = ObservedObject(wrappedValue: model)
        _center = ObservedObject(wrappedValue: model.center)
        self.feedFolders = feedFolders
        self.unsubscribeConfirmation = unsubscribeConfirmation
        self.onUnsubscribe = onUnsubscribe
        self.onDone = onDone
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
                Button(FeedWording.unsubscribeTitle, role: .destructive) {
                    confirmation = unsubscribeConfirmation()
                }
                .disabled(model.feed == nil)
                Spacer()
                // Escape presses Done: every change is kept as it is made,
                // and Return stays with the number fields, which it enters,
                // or with the picker's Create while its fields are shown.
                Button("Done", action: onDone)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 520, height: 600)
        .navigationTitle(FeedWording.feedInfoTitle)
        .alert(confirmation?.title ?? "", isPresented: isConfirming, presenting: confirmation) { confirmation in
            Button(confirmation.confirmTitle, role: .destructive, action: onUnsubscribe)
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
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
        if feed.usesInsecureTransport {
            FeedInfoValue(label: FeedWording.securityLabel, value: FeedWording.insecureNote)
        }

        // The picker's Create takes Return while its New Folder fields are
        // shown, from a number field too, whose number is entered as focus
        // leaves it; no isMakingFolder binding, since the sheet has no
        // Return-key button of its own to stand down meanwhile.
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
            failureMessage: $folderFailure
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
            FeedReadOnlyText(text: summary, label: FeedWording.descriptionTextLabel(title: feed.title))
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
        }
    }

    /// Whether the Unsubscribe confirmation shows; dismissing it forgets it.
    private var isConfirming: Binding<Bool> {
        Binding(
            get: { confirmation != nil },
            set: { isPresented in
                if !isPresented { confirmation = nil }
            }
        )
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

// MARK: - Text Read With VoiceOver's Text Navigation

/// A text VoiceOver reads as a text area (FR03): its lines, words, and
/// letters reached with VoiceOver's text navigation and the arrow keys,
/// which also move its insertion point, and shown on a braille display as
/// they are, with selection and copying, but no typing. AppKit's text view
/// gives all of that, where a SwiftUI text gives a single static element.
struct FeedReadOnlyText: NSViewRepresentable {
    /// The text.
    let text: String
    /// The text area's spoken label.
    let label: String
    /// Whether the text takes keyboard focus as it appears, so VoiceOver
    /// starts in it.
    var takesFocus = false

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.font = .preferredFont(forTextStyle: .body)
            textView.textContainerInset = NSSize(width: 6, height: 6)
            textView.string = text
            textView.setAccessibilityLabel(label)
            if takesFocus {
                // Once the text view is in its window, after the sheet's
                // own animation.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak textView] in
                    guard let textView, let window = textView.window else { return }
                    window.makeFirstResponder(textView)
                    textView.setSelectedRange(NSRange(location: 0, length: 0))
                }
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.setAccessibilityLabel(label)
    }
}

// MARK: - A Key Equivalent Without a Button

/// A key that does what a button's key equivalent does, with no second
/// button (FR03): `key`, pressed with no modifier anywhere in the window,
/// runs `action`. A SwiftUI button carries one shortcut, so Show
/// Description's Close, whose shortcut is Return, answers Escape through
/// this. The view takes no space, draws nothing, and is no element to
/// VoiceOver.
struct SilentKeyEquivalent: NSViewRepresentable {
    /// The key.
    let key: KeyEquivalent
    /// What pressing it does.
    let action: () -> Void

    func makeNSView(context: Context) -> SilentKeyEquivalentView {
        let view = SilentKeyEquivalentView(frame: .zero)
        view.key = key
        view.action = action
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: SilentKeyEquivalentView, context: Context) {
        view.key = key
        view.action = action
    }

    /// No space at all, wherever the view is placed.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SilentKeyEquivalentView, context: Context) -> CGSize? {
        .zero
    }
}

/// The view that takes the key. AppKit offers every key pressed in a window
/// to each of the window's views as a key equivalent before the focused
/// view sees it, so the key works wherever focus is, as a button's shortcut
/// does, and before a focused text view can take it.
final class SilentKeyEquivalentView: NSView {
    /// The key, Escape until set.
    var key: KeyEquivalent = .escape
    /// What pressing it does; nothing until set.
    var action: () -> Void = {}

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty, event.charactersIgnoringModifiers == String(key.character) else {
            return super.performKeyEquivalent(with: event)
        }
        action()
        return true
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
            FeedReadOnlyText(text: description.text, label: FeedWording.descriptionTextLabel(title: description.title), takesFocus: true)
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
    /// Feed Info's line for a feed unsubscribed while it was open.
    static let feedGone = "This feed is no longer subscribed."
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
    /// The line under Feed Info's folder picker.
    static let folderInfoHelp = "Choosing another folder sends new downloads there; the books already downloaded stay where they are."
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

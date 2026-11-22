#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Importing Subscriptions (FR03)

/// How an OPML import ended (FR03): the feeds subscribed to, those already
/// subscribed, those in the library already that the listener unsubscribed
/// from, those that failed and why, which of the new ones use plain http,
/// and whether the listener stopped it.
struct OPMLImportSummary: Equatable {
    /// One subscription that failed.
    struct Failure: Equatable {
        /// The feed's title, as the file gives it.
        let title: String
        /// Why, in the engine's words.
        let reason: String
    }

    /// The titles of the feeds subscribed to.
    var subscribed: [String] = []
    /// The titles of the feeds subscribed to already, left as they were.
    var alreadySubscribed: [String] = []
    /// The titles, as the library has them, of the feeds in the library
    /// that the listener unsubscribed from (FR11, branch D): left
    /// unsubscribed, as the listener chose, and named, so Resubscribe can
    /// check them again (REV11, board #1814).
    var unsubscribed: [String] = []
    /// The subscriptions that failed.
    var failed: [Failure] = []
    /// The titles of the new feeds that use plain http.
    var insecure: [String] = []
    /// Whether the listener stopped the import before its end.
    var stopped = false

    /// What the sheet shows and VoiceOver hears once the import ends.
    var sentence: String {
        var parts: [String] = []
        parts.append(subscribed.isEmpty
            // Translators: What the Import OPML sheet says once the import ended and no feed was subscribed to.
            ? InterfaceText.line("opmlImportSummary.sentence.feed", "No feed was subscribed to.")
            // Translators: What the Import OPML sheet says once the import ended: how many feeds were subscribed to. %lld is how many.
            : InterfaceText.line("opmlImportSummary.sentence.feeds", "Subscribed to \(number: subscribed.count) feeds."))
        if !alreadySubscribed.isEmpty {
            // Translators: What the Import OPML sheet says of the feeds the file lists that were already subscribed to, left as they were. %lld is how many.
            parts.append(InterfaceText.line("opmlImportSummary.sentence.already", "\(number: alreadySubscribed.count) were subscribed already."))
        }
        if !unsubscribed.isEmpty {
            parts.append(FeedWording.importFoundUnsubscribed(unsubscribed))
        }
        if !failed.isEmpty {
            let named = failed.map {
                // Translators: A feed that could not be subscribed to, with the reason in parentheses. The first %@ is the feed's title; the second is the reason, in the engine's words.
                InterfaceText.line("common.valueInParentheses", "\($0.title) (\($0.reason))")
            }
            // Translators: What the Import OPML sheet says of the feeds that could not be subscribed to. %@ is a list of them, each with its reason.
            parts.append(InterfaceText.line("opmlImportSummary.sentence.subscribe", "Couldn't subscribe to \(CountWording.list(named))."))
        }
        if !insecure.isEmpty {
            parts.append(insecure.count == 1
                // Translators: What the Import OPML sheet says of one new feed whose address uses plain http, which is not encrypted. %@ is the feed's title.
                ? InterfaceText.line("opmlImportSummary.sentence.sends", "\(insecure.first ?? "") uses plain http, so others can read or change what it sends; TextMouth still loads it.")
                // Translators: What the Import OPML sheet says of several new feeds whose addresses use plain http, which is not encrypted. %@ is a list of their titles.
                : InterfaceText.line("opmlImportSummary.sentence.they", "\(CountWording.list(insecure)) use plain http, so others can read or change what they send; TextMouth still loads it."))
        }
        if stopped {
            // Translators: What the Import OPML sheet says once the listener stopped the import before its end.
            parts.append(InterfaceText.line("opmlImportSummary.sentence.stopped", "The import was stopped before its end."))
        }
        return SentenceWording.joined(parts)
    }
}

/// The work of the Import OPML sheet (FR03): the subscriptions an OPML file
/// lists, the folder their feeds' folders go in, and subscribing to each in
/// turn, as Add Feed does, into a folder of its own named after it.
@MainActor
final class OPMLImportModel: ObservableObject, Identifiable {
    /// How far the import has got.
    struct Progress: Equatable {
        /// The subscriptions done.
        let done: Int
        /// All of them.
        let total: Int
        /// The one being subscribed to.
        let current: String
    }

    /// The file's name, which the sheet names.
    let fileName: String
    /// The subscriptions the file lists, in order.
    let subscriptions: [OPMLSubscription]
    /// The path of the folder the feeds' folders go in; "" for the top level.
    @Published var parentPath: String
    /// How far the import has got, while it runs.
    @Published private(set) var progress: Progress?
    /// How the import ended, once it has.
    @Published private(set) var summary: OPMLImportSummary?

    /// The engine subscribed through.
    let center: FeedCenter
    /// Speaks how the import ended: through VoiceOver, unless a test listens.
    private let announce: @MainActor (String) -> Void
    /// The import under way.
    private var work: Task<Void, Never>?

    /// An import of `subscriptions`, read from the file `fileName`, through
    /// `center`, into new folders inside the folder at `parentPath`.
    init(
        fileName: String,
        subscriptions: [OPMLSubscription],
        center: FeedCenter,
        parentPath: String,
        announce: @escaping @MainActor (String) -> Void = { VoiceOverAnnouncer.announce($0) }
    ) {
        self.fileName = fileName
        self.subscriptions = subscriptions
        self.center = center
        self.parentPath = parentPath
        self.announce = announce
    }

    /// Whether the import runs now.
    var isRunning: Bool {
        progress != nil
    }

    /// Subscribes to each subscription in turn, skipping those subscribed
    /// already, and those in the library already that the listener
    /// unsubscribed from, which stay unsubscribed and are named (REV11,
    /// board #1814); a page naming several feeds subscribes to its first,
    /// the site's main feed. Returns the work, which tests await; nil while
    /// one runs or once one has ended.
    @discardableResult
    func start() -> Task<Void, Never>? {
        guard work == nil, summary == nil else { return nil }
        let choice = FeedFolderChoice.newFolder(inParentPath: parentPath)
        let work = Task {
            var summary = OPMLImportSummary()
            for (index, subscription) in subscriptions.enumerated() {
                if Task.isCancelled {
                    summary.stopped = true
                    break
                }
                progress = Progress(done: index, total: subscriptions.count, current: subscription.title)
                if let existing = center.subscribedFeed(at: subscription.feedURL) {
                    if existing.isSubscribed {
                        summary.alreadySubscribed.append(subscription.title)
                    } else {
                        summary.unsubscribed.append(existing.title)
                    }
                    continue
                }
                await subscribe(subscription, into: choice, recordingIn: &summary)
            }
            progress = nil
            self.summary = summary
            announce(summary.sentence)
        }
        self.work = work
        return work
    }

    /// Subscribes to `subscription` into `choice`, noting how it ended in
    /// `summary`.
    private func subscribe(
        _ subscription: OPMLSubscription,
        into choice: FeedFolderChoice,
        recordingIn summary: inout OPMLImportSummary
    ) async {
        do {
            var outcome = try await center.subscribe(to: subscription.feedURL.absoluteString, into: choice)
            if case .choose(let links) = outcome, let first = links.first {
                outcome = try await center.subscribe(to: first.url.absoluteString, into: choice)
            }
            guard case .subscribed(let feed) = outcome else {
                summary.failed.append(.init(title: subscription.title, reason: FeedSubscribeError.pageNamesNoFeed.message))
                return
            }
            summary.subscribed.append(feed.title)
            if center.store.record(of: feed.id)?.feed.usesInsecureTransport == true {
                summary.insecure.append(feed.title)
            }
        } catch let error as FeedSubscribeError {
            switch error {
            case .alreadySubscribed:
                summary.alreadySubscribed.append(subscription.title)
            case .unsubscribedAlready(let title):
                // A page that names a feed the listener unsubscribed from.
                summary.unsubscribed.append(title)
            default:
                summary.failed.append(.init(title: subscription.title, reason: error.message))
            }
        } catch {
            summary.failed.append(.init(title: subscription.title, reason: error.localizedDescription))
        }
    }

    /// Stops the import after the subscription under way.
    func stop() {
        work?.cancel()
    }
}

/// The Import OPML sheet (FR03): the file's name and how many feeds it
/// lists; the Move dialog's folder picker, choosing where the feeds' own
/// folders go, with New Folder; Import, which Return presses, except while
/// the picker's New Folder fields are shown, when Return presses their
/// Create and Import stands down, so one press does one thing; and Cancel,
/// which Escape presses and which stops an import under way, except while
/// those fields are shown, when Escape closes them first. While it
/// runs, the sheet says which feed it is subscribing to; once it ends, it
/// says how it went, which VoiceOver also hears, and Done, which Return
/// presses, closes it.
struct OPMLImportSheet: View {
    /// The sheet's work.
    @ObservedObject var model: OPMLImportModel
    /// The library, for the folder picker's places.
    let library: Library
    /// Which folders hold feeds, which are no place for a feed's folder.
    let feedFolders: LibraryFeedFolders
    /// Makes a folder from a name and a parent path.
    let onCreateFolder: (String, String) -> OperationOutcome
    /// Closes the sheet.
    let onClose: () -> Void

    /// Why the last folder could not be made.
    @State private var folderFailure: String?
    /// Whether the picker's new-folder fields are showing, while Return
    /// presses their Create rather than Import, and Escape closes them
    /// rather than the sheet.
    @State private var isMakingFolder: Bool

    /// A sheet doing `model`'s work in `library`, whose folder picker keeps
    /// off the folders `feedFolders` says hold feeds; `makingFolder` opens
    /// it with the new folder's fields already shown, as the tests of the
    /// Return key need.
    init(
        model: OPMLImportModel,
        library: Library,
        feedFolders: LibraryFeedFolders,
        onCreateFolder: @escaping (String, String) -> OperationOutcome,
        onClose: @escaping () -> Void,
        makingFolder: Bool = false
    ) {
        _model = ObservedObject(wrappedValue: model)
        self.library = library
        self.feedFolders = feedFolders
        self.onCreateFolder = onCreateFolder
        self.onClose = onClose
        _isMakingFolder = State(initialValue: makingFolder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(FeedWording.importTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(FeedWording.importLists(fileName: model.fileName, count: model.subscriptions.count))
                .fixedSize(horizontal: false, vertical: true)
                .modifier(InitialVoiceOverFocusModifier(isTarget: true))

            LibraryFolderPicker(
                options: AddFeedPlaces.parents(in: library, feedFolders: feedFolders),
                newFolderParents: AddFeedPlaces.newFolderParents(in: library, feedFolders: feedFolders),
                selection: $model.parentPath,
                caption: FeedWording.importFolderCaption,
                accessibilityLabel: FeedWording.importFolderLabel,
                onCreateFolder: onCreateFolder,
                failureMessage: $folderFailure,
                isDisabled: model.isRunning || model.summary != nil,
                isMakingFolder: $isMakingFolder
            )

            OperationFailureNotice(message: folderFailure)

            if let progress = model.progress {
                SheetWorkIndicator(label: FeedWording.importProgress(progress))
            }
            if let summary = model.summary {
                Text(summary.sentence)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if model.summary == nil {
                    Button(FeedWording.cancelTitle) {
                        model.stop()
                        onClose()
                    }
                    // Escape cancels, except while the new folder's fields
                    // are shown, when it closes them first (their Cancel
                    // New Folder) and a second Escape cancels.
                    .keyboardShortcut(isMakingFolder ? nil : KeyboardShortcut.cancelAction)
                    Spacer()
                    Button(FeedWording.importButton) {
                        model.start()
                    }
                    // Return imports, except while the new folder's fields
                    // are shown, when it presses their Create.
                    .keyboardShortcut(isMakingFolder ? nil : KeyboardShortcut.defaultAction)
                    .disabled(model.isRunning)
                } else {
                    Spacer()
                    Button(FeedWording.doneTitle, action: onClose)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding()
        .frame(width: 480)
        .navigationTitle(FeedWording.importTitle)
    }
}

// MARK: - Choosing and Saving Files

/// The OPML file type, for the Open and Save panels: OPML's own where the
/// system knows it, else any XML file.
enum OPMLFileType {
    /// The types the Open panel accepts.
    static var readable: [UTType] {
        [UTType(filenameExtension: "opml"), .xml].compactMap { $0 }
    }

    /// The type the Save panel writes.
    static var written: UTType {
        UTType(filenameExtension: "opml") ?? .xml
    }
}

extension LibraryFeedsPresenter {
    // MARK: Import OPML…

    /// Library > Import OPML…: asks for an OPML file in an Open panel on
    /// the window, reads it off the main thread, and opens the Import OPML
    /// sheet with its subscriptions, or says why it can't be read.
    func chooseOPMLFile(in context: FeedCommandContext, parentPath: String) {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = OPMLFileType.readable
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = FeedWording.importPanelMessage
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.readOPMLFile(url, in: context, parentPath: parentPath)
        }
        if let window = context.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
        #else
        // Phase 0: iOS has no Open panel, so choosing a file does nothing yet; phase 1 uses a file importer.
    #endif
    }

    /// Reads the OPML file at `url` off the main thread, then opens the
    /// Import OPML sheet with its subscriptions, or shows why it can't be
    /// read in an alert, which VoiceOver reads as it appears, as the feed
    /// commands' refusals are shown (REV14 feeds 6).
    /// - Returns: The reading, which tests await.
    @discardableResult
    func readOPMLFile(_ url: URL, in context: FeedCommandContext, parentPath: String) -> Task<Void, Never> {
        Task {
            let read = await OffMainWork.run(on: .global(qos: .userInitiated)) { () -> Result<[OPMLSubscription], OPMLReadError> in
                guard let data = try? Data(contentsOf: url) else { return .failure(.empty) }
                do throws(OPMLReadError) {
                    return .success(try FeedOPML.subscriptions(in: data))
                } catch {
                    return .failure(error)
                }
            }
            switch read {
            case .success(let subscriptions):
                opmlImport = OPMLImportModel(
                    fileName: url.lastPathComponent,
                    subscriptions: subscriptions,
                    center: context.center,
                    parentPath: parentPath
                )
            case .failure(let error):
                notice = FeedNotice(title: FeedWording.importFailedTitle, message: error.message)
            }
        }
    }

    // MARK: Export OPML…

    /// Library > Export OPML…: asks where to save the subscriptions in a
    /// Save panel on the window, and writes them there, or shows in an alert
    /// that there are none to export: no feed at all, or only feeds the
    /// listener unsubscribed from, which an export leaves out (REV11, board
    /// #1814). VoiceOver reads the alert as it appears (REV14 feeds 6).
    func chooseOPMLDestination(in context: FeedCommandContext) {
        #if os(macOS)
        guard context.center.feeds.contains(where: \.isSubscribed) else {
            let message = context.center.feeds.isEmpty ? FeedWording.nothingToExport : FeedWording.nothingSubscribedToExport
            notice = FeedNotice(title: FeedWording.exportFailedTitle, message: message)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [OPMLFileType.written]
        panel.nameFieldStringValue = FeedWording.exportFileName
        panel.message = FeedWording.exportPanelMessage
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.exportOPML(to: url, in: context)
        }
        if let window = context.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
        #else
        // Phase 0: iOS has no Save panel, so choosing a destination does nothing yet; phase 1 uses a file exporter.
    #endif
    }

    /// Writes every subscription to the OPML file `url`, and says how many
    /// went where, or shows in an alert why it couldn't be written. A
    /// feed the listener unsubscribed from is left out, as no
    /// subscription, so another reader importing the file never
    /// subscribes to it again, and the words say how many were left out
    /// (REV11, board #1814).
    func exportOPML(to url: URL, in context: FeedCommandContext) {
        let feeds = context.center.feeds.filter(\.isSubscribed)
        let leftOut = context.center.feeds.count - feeds.count
        let data = FeedOPML.document(listing: feeds, title: FeedWording.exportDocumentTitle, date: context.center.environment.now())
        do {
            try data.write(to: url, options: .atomic)
            announce(FeedWording.exported(count: feeds.count, fileName: url.lastPathComponent, unsubscribedCount: leftOut), context.window)
        } catch {
            notice = FeedNotice(title: FeedWording.exportFailedTitle, message: FeedWording.exportFailed(error.localizedDescription))
        }
    }
}

// MARK: - Words

extension FeedWording {
    /// Library > Import OPML….
    static var importCommand: String {
        // Translators: Title of the Library menu's command that imports an OPML file of subscriptions. The ellipsis says a panel follows. OPML is a file format; keep it.
        InterfaceText.line("feed.importCommand", "Import OPML…")
    }
    /// Library > Export OPML….
    static var exportCommand: String {
        // Translators: Title of the Library menu's command that exports the subscriptions as an OPML file. The ellipsis says a panel follows. OPML is a file format; keep it.
        InterfaceText.line("feed.exportCommand", "Export OPML…")
    }
    /// The Import OPML sheet's heading.
    static var importTitle: String {
        // Translators: Heading of the sheet that imports an OPML file of subscriptions. Title case.
        InterfaceText.line("feed.importTitle", "Import Subscriptions")
    }
    /// The Open panel's message.
    static var importPanelMessage: String {
        // Translators: The message of the Open panel that chooses an OPML file of subscriptions.
        InterfaceText.line("feed.importPanelMessage", "Choose an OPML file of subscriptions, as another feed reader exports them.")
    }
    /// The line naming the file and how many feeds it lists.
    static func importLists(fileName: String, count: Int) -> String {
        // Translators: The line of the Import OPML sheet that names the file and how many feeds it lists. %@ is the file's name; %lld is how many feeds.
        InterfaceText.line("feed.importLists", "\(fileName) lists \(number: count) feeds. Each gets its own folder, named after it.")
    }
    /// The folder picker's caption.
    static var importFolderCaption: String {
        // Translators: Caption of the folder picker of the Import OPML sheet: the library folder that will hold each feed's own folder.
        InterfaceText.line("feed.importFolderCaption", "Put the feeds' folders in")
    }
    /// The folder picker's spoken label.
    static var importFolderLabel: String {
        // Translators: VoiceOver label of the folder picker of the Import OPML sheet.
        InterfaceText.line("feed.importFolderLabel", "Folder to hold the imported feeds' folders")
    }
    /// The Import button.
    static var importButton: String {
        // Translators: Title of the button that starts an import, such as an OPML file of subscriptions.
        InterfaceText.line("common.import", "Import")
    }
    /// What the sheet shows, and VoiceOver can read, while it subscribes.
    static func importProgress(_ progress: OPMLImportModel.Progress) -> String {
        // Translators: What the Import OPML sheet shows while it subscribes to the feeds. The first %@ is the title of the feed being subscribed to; the first %lld is its number in the file; the second %lld is how many feeds the file lists.
        InterfaceText.line("feed.importProgress", "Subscribing to \(progress.current), \(number: progress.done + 1) of \(number: progress.total)…")
    }
    /// The title of the alert saying why an OPML file can't be read.
    static var importFailedTitle: String {
        // Translators: Title of the alert that says why an OPML file could not be read. Title case.
        InterfaceText.line("feed.importFailedTitle", "Couldn't Import Subscriptions")
    }
    /// The title of the alert saying why the subscriptions can't be exported.
    static var exportFailedTitle: String {
        // Translators: Title of the alert that says why the subscriptions could not be exported. Title case.
        InterfaceText.line("feed.exportFailedTitle", "Couldn't Export Subscriptions")
    }
    /// What Export OPML says with no subscription.
    static var nothingToExport: String {
        // Translators: What Export OPML says when the library has no feed.
        InterfaceText.line("feed.nothingToExport", "There are no subscriptions to export.")
    }
    /// What Export OPML says when every feed in the library is one the
    /// listener unsubscribed from, which an export leaves out (REV11).
    static var nothingSubscribedToExport: String {
        // Translators: What Export OPML says when every feed in the library is unsubscribed, which an export leaves out.
        InterfaceText.line("feed.nothingSubscribedToExport", "There are no subscriptions to export: every feed in your library is unsubscribed.")
    }
    /// What an import's summary says of the feeds it lists that are in the
    /// library already, unsubscribed from (FR11, branch D), named by their
    /// titles there: they stay unsubscribed, as the listener chose, and
    /// Resubscribe checks one again (REV11, board #1814). One is said as Add
    /// Feed says it.
    static func importFoundUnsubscribed(_ titles: [String]) -> String {
        guard titles.count != 1, !titles.isEmpty else {
            return FeedSubscribeError.unsubscribedAlready(title: titles.first ?? "").message
        }
        // Translators: What the Import OPML sheet says of several feeds the file lists that are in the library already, unsubscribed. The first %@ is a list of their titles; the second is the name of the Resubscribe command; the third is the name of the Feed Info sheet.
        return InterfaceText.line("feed.importFoundUnsubscribed", "\(CountWording.list(titles)) are in your library, unsubscribed. Choose \(resubscribeTitle) on a feed's row, or in its \(feedInfoName), to check it again.")
    }
    /// The Save panel's suggested file name.
    static let exportFileName = "TextMouth Subscriptions.opml" // l10n: no (a suggested file name, which other apps and scripts may look for)
    /// The Save panel's message.
    static var exportPanelMessage: String {
        // Translators: The message of the Save panel that saves the subscriptions as an OPML file.
        InterfaceText.line("feed.exportPanelMessage", "Save your subscriptions as an OPML file, which other feed readers import.")
    }
    /// The exported document's title.
    static var exportDocumentTitle: String {
        // Translators: The title written into an exported OPML file of subscriptions. Title case.
        InterfaceText.line("feed.exportDocumentTitle", "TextMouth Subscriptions")
    }
    /// What VoiceOver hears once the subscriptions are exported, with how
    /// many feeds the listener unsubscribed from were left out (REV11):
    /// "Exported 2 subscriptions to Mine.opml. 1 feed you unsubscribed from
    /// was left out."
    static func exported(count: Int, fileName: String, unsubscribedCount: Int = 0) -> String {
        // Translators: What VoiceOver says once the subscriptions are exported. %lld is how many; %@ is the file's name.
        let exported = InterfaceText.line("feed.exported.subscriptions", "Exported \(number: count) subscriptions to \(fileName).")
        guard unsubscribedCount > 0 else { return exported }
        // Translators: The end of what VoiceOver says once the subscriptions are exported: feeds the listener unsubscribed from are left out. %lld is how many.
        return SentenceWording.joined([exported, InterfaceText.line("feed.exported.unsubscribed", "\(number: unsubscribedCount) feeds you unsubscribed from were left out.")])
    }
    /// Why the subscriptions couldn't be written.
    static func exportFailed(_ reason: String) -> String {
        // Translators: Why the subscriptions could not be exported. %@ is the reason, from the system.
        InterfaceText.line("feed.exportFailed", "The subscriptions couldn't be saved: \(reason)")
    }
}

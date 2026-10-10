import AppKit
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
            ? "No feed was subscribed to."
            : "Subscribed to \(CountWording.phrase(subscribed.count, singular: "feed", plural: "feeds")).")
        if !alreadySubscribed.isEmpty {
            parts.append(CountWording.phrase(alreadySubscribed.count, singular: "was", plural: "were") + " subscribed already.")
        }
        if !unsubscribed.isEmpty {
            parts.append(FeedWording.importFoundUnsubscribed(unsubscribed))
        }
        if !failed.isEmpty {
            let named = failed.map { "\($0.title) (\($0.reason))" }
            parts.append("Couldn't subscribe to \(LibraryCloudWording.list(named)).")
        }
        if !insecure.isEmpty {
            let these = insecure.count == 1 ? "\(insecure.first ?? "") uses" : "\(LibraryCloudWording.list(insecure)) use"
            parts.append("\(these) plain http, so what is sent can be read or changed on the way; TextMouth still loads it.")
        }
        if stopped {
            parts.append("The import was stopped before its end.")
        }
        return parts.joined(separator: " ")
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
                    Button("Cancel") {
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
                    Button("Done", action: onClose)
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
    static let importCommand = "Import OPML…"
    /// Library > Export OPML….
    static let exportCommand = "Export OPML…"
    /// The Import OPML sheet's heading.
    static let importTitle = "Import Subscriptions"
    /// The Open panel's message.
    static let importPanelMessage = "Choose an OPML file of subscriptions, as another feed reader exports them."
    /// The line naming the file and how many feeds it lists.
    static func importLists(fileName: String, count: Int) -> String {
        "\(fileName) lists \(CountWording.phrase(count, singular: "feed", plural: "feeds")). Each gets a folder of its own, named after it."
    }
    /// The folder picker's caption.
    static let importFolderCaption = "Put the feeds' folders in"
    /// The folder picker's spoken label.
    static let importFolderLabel = "Folder to hold the imported feeds' folders"
    /// The Import button.
    static let importButton = "Import"
    /// What the sheet shows, and VoiceOver can read, while it subscribes.
    static func importProgress(_ progress: OPMLImportModel.Progress) -> String {
        "Subscribing to \(progress.current), \(progress.done + 1) of \(progress.total)…"
    }
    /// The title of the alert saying why an OPML file can't be read.
    static let importFailedTitle = "Couldn't Import Subscriptions"
    /// The title of the alert saying why the subscriptions can't be exported.
    static let exportFailedTitle = "Couldn't Export Subscriptions"
    /// What Export OPML says with no subscription.
    static let nothingToExport = "There are no subscriptions to export."
    /// What Export OPML says when every feed in the library is one the
    /// listener unsubscribed from, which an export leaves out (REV11).
    static let nothingSubscribedToExport = "There are no subscriptions to export: every feed in your library is unsubscribed."
    /// What an import's summary says of the feeds it lists that are in the
    /// library already, unsubscribed from (FR11, branch D), named by their
    /// titles there: they stay unsubscribed, as the listener chose, and
    /// Resubscribe checks one again (REV11, board #1814). One is said as Add
    /// Feed says it.
    static func importFoundUnsubscribed(_ titles: [String]) -> String {
        guard titles.count != 1, !titles.isEmpty else {
            return FeedSubscribeError.unsubscribedAlready(title: titles.first ?? "").message
        }
        return "\(LibraryCloudWording.list(titles)) are in your library, unsubscribed. "
            + "Choose Resubscribe on a feed's row, or in its Feed Info, to check it again."
    }
    /// The Save panel's suggested file name.
    static let exportFileName = "TextMouth Subscriptions.opml"
    /// The Save panel's message.
    static let exportPanelMessage = "Save your subscriptions as an OPML file, which other feed readers import."
    /// The exported document's title.
    static let exportDocumentTitle = "TextMouth Subscriptions"
    /// What VoiceOver hears once the subscriptions are exported, with how
    /// many feeds the listener unsubscribed from were left out (REV11):
    /// "Exported 2 subscriptions to Mine.opml. 1 feed you unsubscribed from
    /// was left out."
    static func exported(count: Int, fileName: String, unsubscribedCount: Int = 0) -> String {
        let exported = "Exported \(CountWording.phrase(count, singular: "subscription", plural: "subscriptions")) to \(fileName)."
        switch unsubscribedCount {
        case ...0:
            return exported
        case 1:
            return exported + " 1 feed you unsubscribed from was left out."
        default:
            return exported + " \(unsubscribedCount) feeds you unsubscribed from were left out."
        }
    }
    /// Why the subscriptions couldn't be written.
    static func exportFailed(_ reason: String) -> String {
        "The subscriptions couldn't be saved: \(reason)"
    }
}

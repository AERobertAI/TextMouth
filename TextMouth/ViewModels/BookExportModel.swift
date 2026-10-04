import AppKit
import Combine
import Foundation

// MARK: - The Export Setting

/// The preferences Export keeps (FR05), each defined once with its key and
/// stored form, for the settings model and config.json to share.
enum BookExportPreferences {
    /// Whether the reader's toolbar shows an Export button. Off until the
    /// user turns it on in Playback settings or config.json; File > Export…
    /// and the library's context menu are always there.
    static let showInReaderToolbar = StoredPreference.flag("showExportInReaderToolbar", default: false)
}

// MARK: - One Checkbox

/// One checkbox of the Export dialog: a kind, with what the books chosen
/// hold of it.
struct BookExportChoice: Equatable, Identifiable {
    /// The kind the checkbox exports.
    let kind: BookExportKind
    /// The books' items of this kind, in the order of the books.
    let items: [BookExportItem]
    /// How many books the dialog exports from.
    let bookCount: Int

    var id: BookExportKind { kind }

    /// The items that can be exported now: those on this Mac (FR02).
    var availableItems: [BookExportItem] {
        items.filter { !$0.isInCloud }
    }

    /// Whether anything of this kind can be exported now; the checkbox is
    /// unavailable otherwise.
    var isAvailable: Bool {
        !availableItems.isEmpty
    }

    /// How many of the items are only in the cloud.
    var inCloudCount: Int {
        items.count - availableItems.count
    }

    /// The checkbox's label, which the screen shows and VoiceOver speaks
    /// (`BookExportWording.choiceLabel`).
    var label: String {
        let available = availableItems
        return BookExportWording.choiceLabel(
            kind: kind,
            bookCount: bookCount,
            availableItemCount: available.count,
            fileCount: available.reduce(0) { $0 + $1.files.count },
            byteCount: available.reduce(0) { $0 + $1.byteCount },
            inCloudCount: inCloudCount
        )
    }

    /// The choices `offers` give: one for each kind any of their books
    /// holds, in the dialog's order.
    static func choices(for offers: [BookExportOffer]) -> [BookExportChoice] {
        BookExportKind.allCases.compactMap { kind in
            let items = offers.compactMap { $0.item(kind) }
            return items.isEmpty ? nil : BookExportChoice(kind: kind, items: items, bookCount: offers.count)
        }
    }
}

// MARK: - The Dialog's Model

/// The Export dialog of one or several books (FR05): what they can export,
/// which kinds are checked, where they go, and the export itself.
///
/// What the books hold is listed off the main thread when the dialog opens
/// (`load()`), and listed again for the books as the library holds them
/// when Export is pressed, so a book moved meanwhile is exported from where
/// it is. The export runs off the main thread too, with its progress here,
/// and ends with one announcement naming how many items went where, and
/// anything that could not be exported, in the cloud included.
@MainActor
final class BookExportModel: ObservableObject, Identifiable {
    /// Where the dialog is.
    enum Phase: Equatable {
        /// Finding what the books hold.
        case listing
        /// Showing the checkboxes, ready to export.
        case ready
        /// Exporting: how many files are done, out of how many.
        case exporting(done: Int, total: Int)
        /// The export ended, as the outcome says.
        case finished(BookExportOutcome)
    }

    /// Tells sheets presenting different dialogs apart.
    let id = UUID()
    /// The books to export, as they were chosen.
    let books: [Book]
    /// Where the dialog is now.
    @Published private(set) var phase: Phase = .listing
    /// The checkboxes, once the books have been listed.
    @Published private(set) var choices: [BookExportChoice] = []
    /// The books' offers, once listed.
    @Published private(set) var offers: [BookExportOffer] = []
    /// The kinds checked.
    @Published var checked: Set<BookExportKind> = []
    /// The folder the items go to.
    @Published var destination: URL
    /// What the last export said, kept in the dialog when it did not do
    /// everything asked.
    @Published private(set) var summary: String?

    /// How files are checked and read without downloading (FR02).
    private let access: MaintenanceFileAccess
    /// The books as the library holds them now, for the export.
    private let currentBooks: @MainActor ([Book]) -> [Book]
    /// The export under way's Cancel.
    private var cancellation: BookExportCancellation?

    /// The folder an export went to last this session, which the next
    /// dialog starts in.
    private static var lastDestination: URL?

    /// The folder the dialog starts in: where the last export this session
    /// went, or the Documents folder of the home the runtime names, which
    /// is the user's in the app and the test sandbox's under hosted tests
    /// (`TextMouthRuntime`), so no test can write into the user's files.
    static var defaultDestination: URL {
        lastDestination
            ?? TextMouthRuntime.current.homeDirectory.appendingPathComponent("Documents", isDirectory: true)
    }

    /// A dialog exporting `books`.
    /// - Parameters:
    ///   - books: The books chosen.
    ///   - library: The library, whose rows give the books as they are when
    ///     Export is pressed; nil exports the books as chosen.
    ///   - destination: The folder to start in; nil starts in
    ///     `defaultDestination`.
    ///   - access: How files are checked and read; tests pass a cloud of
    ///     their own.
    init(
        books: [Book],
        library: LibraryViewModel? = nil,
        destination: URL? = nil,
        access: MaintenanceFileAccess = .live
    ) {
        self.books = books
        self.destination = destination ?? Self.defaultDestination
        self.access = access
        currentBooks = { [weak library] chosen in
            chosen.map { library?.bookByID($0.id) ?? $0 }
        }
    }

    // MARK: Listing

    /// Lists what the books hold, off the main thread, and shows the
    /// checkboxes, the first kind that can be exported checked.
    func load() async {
        phase = .listing
        let listed = await Self.offers(for: books, access: access)
        offers = listed
        choices = BookExportChoice.choices(for: listed)
        if let first = choices.first(where: \.isAvailable) {
            checked = [first.kind]
        }
        phase = .ready
    }

    /// What `books` can export, listed off the main thread.
    private static func offers(for books: [Book], access: MaintenanceFileAccess) async -> [BookExportOffer] {
        await OffMainWork.run {
            books.map { BookExportService.offer(for: $0, access: access) }
        }
    }

    // MARK: State the Dialog Shows

    /// The dialog's title (`BookExportWording.title(bookTitles:)`).
    var title: String {
        BookExportWording.title(bookTitles: books.map(\.title))
    }

    /// Whether the checkbox of `kind` is checked.
    func isChecked(_ kind: BookExportKind) -> Bool {
        checked.contains(kind)
    }

    /// Checks or unchecks the checkbox of `kind`.
    func setChecked(_ isChecked: Bool, for kind: BookExportKind) {
        if isChecked {
            checked.insert(kind)
        } else {
            checked.remove(kind)
        }
    }

    /// Whether an export is under way.
    var isExporting: Bool {
        if case .exporting = phase { return true }
        return false
    }

    /// Whether Export can be pressed: the books are listed, nothing is
    /// being exported, and a checked kind has something on this Mac.
    var canExport: Bool {
        switch phase {
        case .listing, .exporting:
            return false
        case .ready, .finished:
            return choices.contains { checked.contains($0.kind) && $0.isAvailable }
        }
    }

    /// Why some of the books' items cannot be exported now, being only in
    /// the cloud (FR02), in the list's words; nil when none is.
    var cloudNotice: String? {
        let titles = offers
            .filter { offer in offer.isPackageInCloud || offer.items.contains(where: \.isInCloud) }
            .map(\.book.title)
        return titles.isEmpty ? nil : LibraryCloudWording.notDownloaded(titles: titles)
    }

    /// The export's progress as the dialog shows and speaks it, while one
    /// is under way.
    var progressText: String? {
        guard case .exporting(let done, let total) = phase else { return nil }
        return BookExportWording.progress(done: done, total: total)
    }

    // MARK: Exporting

    /// Exports the checked kinds of the books, as the library holds them
    /// now, into `destination`, off the main thread, and announces how it
    /// ended from `window`. The dialog keeps the summary when anything
    /// could not be exported.
    /// - Returns: What the export did; nil when it could not start.
    @discardableResult
    func export(announcingFrom window: NSWindow? = nil) async -> BookExportOutcome? {
        guard canExport else { return nil }
        let kinds = checked
        let folder = destination
        guard !Self.isInsideDataDirectory(folder) else {
            summary = BookExportWording.destinationInLibrary
            VoiceOverAnnouncer.announce(BookExportWording.destinationInLibrary, from: window)
            return nil
        }
        let access = self.access
        let cancellation = BookExportCancellation()
        self.cancellation = cancellation
        summary = nil
        phase = .exporting(done: 0, total: 0)
        Self.lastDestination = folder

        let books = currentBooks(self.books)
        // Each file done is shown on the main actor, as it is reported.
        let report: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor in
                self?.showProgress(done: done, total: total)
            }
        }
        let outcome = await OffMainWork.run {
            let offers = books.map { BookExportService.offer(for: $0, access: access) }
            return BookExportService.export(
                offers,
                kinds: kinds,
                to: folder,
                access: access,
                cancellation: cancellation,
                progress: report
            )
        }
        self.cancellation = nil
        phase = .finished(outcome)
        let words = BookExportWording.finished(outcome, folderName: BookExportWording.folderName(of: folder))
        summary = Self.didEverything(outcome) ? nil : words
        VoiceOverAnnouncer.announce(words, from: window)
        return outcome
    }

    /// Shows that `done` files of `total` are exported, while the export is
    /// still under way: a report arriving after it ended changes nothing.
    private func showProgress(done: Int, total: Int) {
        guard isExporting else { return }
        phase = .exporting(done: done, total: total)
    }

    /// Stops the export under way before its next file.
    func stop() {
        cancellation?.cancel()
    }

    /// Whether `folder` is TextMouth's data directory or inside it, where
    /// exported files would sit among the library's own folders and files.
    static func isInsideDataDirectory(_ folder: URL) -> Bool {
        let root = TextMouthPaths.root
        return folder.standardizedFileURL.path == root.standardizedFileURL.path
            || MaintenanceFileAccess.isItem(folder, inside: root)
    }

    /// Whether `outcome` did everything asked: wrote something, and met no
    /// failure, no book in the cloud, and no Cancel. The dialog then closes.
    static func didEverything(_ outcome: BookExportOutcome) -> Bool {
        !outcome.exported.isEmpty && outcome.failures.isEmpty && outcome.booksInCloud.isEmpty && !outcome.wasCancelled
    }

    // MARK: Choosing the Folder

    /// The folder chooser of the dialog's Choose Folder… button: one folder,
    /// with a button that makes a new one, starting in `folder`.
    static func makeDestinationPanel(startingIn folder: URL) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.title = BookExportWording.panelTitle
        panel.message = BookExportWording.panelMessage
        panel.prompt = BookExportWording.panelPrompt
        panel.directoryURL = folder
        return panel
    }

    /// Opens the folder chooser, as a sheet on `window` when there is one,
    /// and makes the folder chosen the destination.
    func chooseDestination(from window: NSWindow?) {
        let panel = Self.makeDestinationPanel(startingIn: destination)
        let take: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            self?.destination = folder
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: take)
        } else {
            panel.begin(completionHandler: take)
        }
    }
}

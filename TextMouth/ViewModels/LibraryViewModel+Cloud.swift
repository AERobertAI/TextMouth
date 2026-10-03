import AppKit
import Combine
import Foundation

// MARK: - FR02 Cloud Library: the List's Side
//
// The library list shows each book's cloud state from `BookCloudStates`
// (see BookCloudNote.swift). `LibraryCloudRefresher` keeps that record
// current while a Library window is visible, `LibraryCloudCommand` decides
// which cloud commands a book or a selection offers, and
// `LibraryCloudCommands` runs them. Every read of the file system goes
// through `BookCloudStorage`, off the main thread.

extension LibraryViewModel {
    /// The package of every book in the library, as the cloud services see
    /// it (FR02). Making them reads no file.
    var cloudPackages: [BookPackage] {
        library.books.map(BookPackage.init)
    }

    /// The package of every book that `states` records as downloading
    /// (PERF16): what a timed refresh reads while a book downloads. Making
    /// them reads no file.
    func cloudPackages(downloadingIn states: BookCloudStates) -> [BookPackage] {
        library.books
            .filter { states.state(of: $0.id)?.isDownloading == true }
            .map(BookPackage.init)
    }
}

// MARK: - Refresh Cadence

/// How long the library list waits between the cloud refreshes no event
/// starts (FR02). Pure, so tests can drive it.
enum LibraryCloudRefreshCadence {
    /// The wait while a Library window is visible and nothing downloads.
    static let whileVisible: Duration = .seconds(60)
    /// The wait while any book is downloading, so the list follows a
    /// download closely, including one that only the sync service reports,
    /// such as one Finder started.
    static let whileDownloading: Duration = .seconds(2)

    /// The wait before the next timed refresh: none while no Library window
    /// is visible, `whileDownloading` while any of `states` is a download,
    /// and `whileVisible` otherwise.
    static func interval<States: Sequence>(
        libraryWindowIsVisible: Bool,
        states: States
    ) -> Duration? where States.Element == BookCloudState {
        guard libraryWindowIsVisible else { return nil }
        return states.contains(where: \.isDownloading) ? whileDownloading : whileVisible
    }

    /// How many timed refreshes while a book downloads make up one that
    /// reads every book: as many as fit in `whileVisible`, so the rest of
    /// the list is read as often as when nothing downloads.
    static var downloadingRefreshesPerFullRefresh: Int {
        max(1, Int(whileVisible / whileDownloading))
    }

    /// Which books the `tick`th timed refresh of a timer waiting `interval`
    /// reads, counting from 1 (PERF16). While a book downloads, only the
    /// downloading books, which the list follows closely, except that every
    /// `downloadingRefreshesPerFullRefresh`th one reads every book;
    /// otherwise every book.
    static func scope(ofTick tick: Int, waiting interval: Duration) -> LibraryCloudRefreshScope {
        guard interval == whileDownloading else { return .everyBook }
        return tick % downloadingRefreshesPerFullRefresh == 0 ? .everyBook : .downloadingBooks
    }
}

/// Which books a cloud refresh reads (PERF16). The cases are ordered by
/// how much they read, so the greater of two requests covers both.
enum LibraryCloudRefreshScope: Comparable {
    /// Only the books recorded as downloading: the timed refreshes while a
    /// book downloads.
    case downloadingBooks
    /// Every book: what each event asks for, and what timed refreshes read
    /// while nothing downloads.
    case everyBook
}

// MARK: - Refresher

/// Keeps `BookCloudStates` current for the Library windows (FR02).
///
/// It refreshes when a Library window appears, when the app becomes active
/// while one is visible, after every change to where the library's books
/// are, and as `LibraryCloudRefreshCadence` says while one is visible:
/// every book, except that the timed refreshes while a book downloads read
/// only the downloading books (PERF16), and every book once a minute. Each
/// refresh is one call to `BookCloudStates.refresh(_:using:)`, which reads
/// off the main thread. Refreshes never overlap: a request made while one
/// runs starts one more right after it, reading every book any of the
/// requests asked for, so the last refresh always reads after the last
/// request.
@MainActor
final class LibraryCloudRefresher {
    /// Waits for a duration, throwing when the waiting task is cancelled.
    /// Tests pass their own, to step the timed refreshes by hand.
    typealias Sleep = @Sendable (Duration) async throws -> Void

    /// The refresher every Library window uses. In a process hosting tests
    /// it never refreshes, so the hosted app's Library window cannot change
    /// `BookCloudStates.shared` while a test uses it; tests make their own.
    static let shared = LibraryCloudRefresher(isEnabled: !TextMouthRuntime.current.isHostedTest)

    /// False for a refresher that never refreshes.
    let isEnabled: Bool
    /// The wait the timer uses, or nil while it is stopped.
    private(set) var timerInterval: Duration?

    /// The store the refreshes record into.
    private let states: BookCloudStates
    /// The book storage a refresh reads through, looked up when it starts.
    private let storage: @MainActor () -> any BookCloudStorage
    /// How the timer waits.
    private let sleep: Sleep
    /// Where the app's activation is posted.
    private let notificationCenter: NotificationCenter

    /// The library the Library windows show, whose books are refreshed.
    private weak var library: LibraryViewModel?
    /// The visible Library windows, each by the token it holds.
    private var visibleWindows: Set<UUID> = []
    /// The refreshes running now, back to back, if any.
    private var refreshing: Task<Void, Never>?
    /// What the refreshes requested while one ran asked to read, if any
    /// was requested: the widest of their scopes.
    private var scopeRequestedWhileRunning: LibraryCloudRefreshScope?
    /// The timer: it waits `timerInterval`, requests a refresh, and waits again.
    private var timer: Task<Void, Never>?
    /// What the refresher observes once a Library window has appeared: the
    /// library's packages, the app's activation, and the states.
    private var observers: Set<AnyCancellable> = []

    /// A refresher that records into `states` what `storage` reads.
    /// - Parameters:
    ///   - states: The store to record into.
    ///   - storage: The book storage to read through, looked up for each
    ///     refresh, so a storage installed later is used.
    ///   - sleep: How the timer waits.
    ///   - notificationCenter: Where `NSApplication.didBecomeActiveNotification`
    ///     is posted.
    ///   - isEnabled: False for a refresher that never refreshes.
    init(
        states: BookCloudStates = .shared,
        storage: @escaping @MainActor () -> any BookCloudStorage = { CloudServices.bookStorage },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        notificationCenter: NotificationCenter = .default,
        isEnabled: Bool = true
    ) {
        self.states = states
        self.storage = storage
        self.sleep = sleep
        self.notificationCenter = notificationCenter
        self.isEnabled = isEnabled
    }

    // MARK: Windows

    /// A Library window holding `token` appeared, showing `library`: it
    /// refreshes now, then on the cadence while any Library window is
    /// visible.
    func libraryWindowAppeared(_ token: UUID, showing library: LibraryViewModel) {
        guard isEnabled else { return }
        observe(library)
        visibleWindows.insert(token)
        requestRefresh()
        updateTimer()
    }

    /// The Library window holding `token` disappeared. The timed refreshes
    /// stop with the last visible one.
    func libraryWindowDisappeared(_ token: UUID) {
        visibleWindows.remove(token)
        updateTimer()
    }

    // MARK: Refreshing

    /// Refreshes the cloud states of the books `scope` names (every book,
    /// unless a timed refresh asks for less) now, or once more after the
    /// refresh that is running. Does nothing before a Library window has
    /// shown a library.
    func requestRefresh(_ scope: LibraryCloudRefreshScope = .everyBook) {
        guard isEnabled, library != nil else { return }
        guard refreshing == nil else {
            scopeRequestedWhileRunning = max(scopeRequestedWhileRunning ?? scope, scope)
            return
        }
        refreshing = Task { [weak self] in
            await self?.refreshUntilCurrent(scope)
        }
    }

    /// Waits until the refreshes running or requested now have finished.
    func waitForRefreshes() async {
        await refreshing?.value
    }

    /// Refreshes `scope`, then back to back what was requested meanwhile,
    /// until no request is left; then lets the next request start a new run.
    private func refreshUntilCurrent(_ scope: LibraryCloudRefreshScope) async {
        var next: LibraryCloudRefreshScope? = scope
        while let scope = next {
            scopeRequestedWhileRunning = nil
            guard let library else { break }
            await states.refresh(packages(of: library, in: scope), using: storage())
            next = scopeRequestedWhileRunning
        }
        refreshing = nil
    }

    /// The packages a refresh of `scope` reads in `library`.
    private func packages(of library: LibraryViewModel, in scope: LibraryCloudRefreshScope) -> [BookPackage] {
        switch scope {
        case .everyBook:
            return library.cloudPackages
        case .downloadingBooks:
            return library.cloudPackages(downloadingIn: states)
        }
    }

    // MARK: Observing

    /// Starts observing `library`, unless it is already observed: where its
    /// books are, the app's activation, and the states, whose downloads set
    /// the cadence.
    private func observe(_ library: LibraryViewModel) {
        guard self.library !== library else { return }
        self.library = library
        observers = []

        // After a book is added, removed, or moved, but not after a change,
        // such as a new reading position, that leaves every package where
        // it was. The library publishes its new value before storing it; the
        // refresh reads the library later, once it is stored.
        library.$library
            .map { $0.books.map(BookPackagePlace.init) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.requestRefresh() }
            .store(in: &observers)

        // When the app becomes active while a Library window shows the result.
        notificationCenter.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.appBecameActive() }
            .store(in: &observers)

        // Downloads set the cadence. The store publishes its new states
        // before holding them, so the timer is set from the published ones.
        states.$states
            .sink { [weak self] newStates in self?.updateTimer(for: newStates) }
            .store(in: &observers)
    }

    /// The app became active: refreshes when a Library window is visible to
    /// show what changed while it was in the background.
    private func appBecameActive() {
        guard !visibleWindows.isEmpty else { return }
        requestRefresh()
    }

    // MARK: Timer

    /// Starts, restarts, or stops the timer so it waits as the cadence says
    /// for `currentStates`, or for the store's states when nil. A timer
    /// already waiting the right interval keeps its place.
    private func updateTimer(for currentStates: [UUID: BookCloudState]? = nil) {
        let interval = LibraryCloudRefreshCadence.interval(
            libraryWindowIsVisible: !visibleWindows.isEmpty,
            states: (currentStates ?? states.states).values
        )
        guard interval != timerInterval else { return }
        timer?.cancel()
        timerInterval = interval
        timer = interval.map(startTimer(waiting:))
    }

    /// A timer that requests a refresh after every `interval` until it is
    /// cancelled, of the books the cadence says for each.
    private func startTimer(waiting interval: Duration) -> Task<Void, Never> {
        Task { [weak self, sleep] in
            var tick = 0
            while true {
                do {
                    try await sleep(interval)
                } catch {
                    return // Cancelled: a new cadence, or no window to refresh.
                }
                guard !Task.isCancelled, let self else { return }
                tick += 1
                self.requestRefresh(LibraryCloudRefreshCadence.scope(ofTick: tick, waiting: interval))
            }
        }
    }
}

/// Where a book's package is, as its library row tells: all a book's cloud
/// state depends on. The refresher compares these rather than whole rows,
/// so the frequent changes that move nothing, such as reading positions,
/// start no refresh.
private struct BookPackagePlace: Equatable {
    /// The book's ID.
    let bookID: UUID
    /// The library folder holding the book's package.
    let folderPath: String
    /// The package's folder name; empty for an old book without one.
    let tmbDirectoryName: String
    /// The book's file, inside its package.
    let filePath: String

    /// Where `book`'s package is.
    init(_ book: Book) {
        bookID = book.id
        folderPath = book.folderPath
        tmbDirectoryName = book.tmbDirectoryName
        filePath = book.filePath
    }
}

// MARK: - Commands Offered

extension BookCloudState {
    /// Whether Download Now can download the book: some of its files are
    /// only in the cloud, or its last download failed. A book downloading
    /// already, or not synced to this Mac yet, has nothing to download now.
    var canDownload: Bool {
        switch self {
        case .inCloud, .downloadFailed:
            return true
        case .local, .downloaded, .downloading, .waitingForSync:
            return false
        }
    }

    /// Whether Remove Download can remove the book's download: every file
    /// of the book is on this Mac.
    var canRemoveDownload: Bool {
        self == .downloaded
    }
}

/// A cloud command the library offers for a book or a selection (FR02),
/// in the row's context menu and as one of its VoiceOver actions.
struct LibraryCloudCommand: Identifiable, Equatable {
    /// What a command does.
    enum Kind: Equatable {
        /// Download Now: downloads books whose files are in the cloud.
        case download
        /// Remove Download: removes the local copies of downloaded books,
        /// which stay in the cloud.
        case removeDownload
        /// Show in Finder: selects the books' packages in Finder, where the
        /// sync service's own commands are, such as Keep Downloaded.
        case showInFinder
    }

    /// What the command does.
    let kind: Kind
    /// The books it acts on, in list order.
    let books: [Book]
    /// Its title in the menu, which is also its VoiceOver action's name.
    let title: String

    /// A list offers each kind of command at most once, so the kind
    /// identifies it.
    var id: Kind { kind }

    /// The cloud commands for `targets`, in menu order:
    /// - Download Now for the books not downloaded, and Remove Download for
    ///   the downloaded ones, both only in a cloud library;
    /// - Show in Finder, in every library, for each book whose package is on
    ///   this Mac (all but those waiting for sync).
    ///
    /// A book not checked yet offers only Show in Finder. A book open in a
    /// reader offers the same commands as any other; Remove Download then
    /// explains why it can't remove its download.
    /// - Parameters:
    ///   - targets: The clicked book, or the selection it is part of, in
    ///     list order.
    ///   - isSelection: Whether `targets` is a selection of several books,
    ///     so the titles count the books each command acts on.
    ///   - states: The books' recorded cloud states.
    @MainActor
    static func commands(for targets: [Book], isSelection: Bool, states: BookCloudStates) -> [LibraryCloudCommand] {
        let listed = targets.map { (book: $0, state: states.listedState(of: $0.id)) }
        let downloadable = listed.filter { $0.state?.canDownload == true }.map(\.book)
        let removable = listed.filter { $0.state?.canRemoveDownload == true }.map(\.book)
        let revealable = listed.filter { $0.state != .waitingForSync }.map(\.book)

        var commands: [LibraryCloudCommand] = []
        if !downloadable.isEmpty {
            commands.append(LibraryCloudCommand(
                kind: .download,
                books: downloadable,
                title: LibraryCloudWording.downloadTitle(count: downloadable.count, forSelection: isSelection)
            ))
        }
        if !removable.isEmpty {
            commands.append(LibraryCloudCommand(
                kind: .removeDownload,
                books: removable,
                title: LibraryCloudWording.removeDownloadTitle(count: removable.count, forSelection: isSelection)
            ))
        }
        if !revealable.isEmpty {
            commands.append(LibraryCloudCommand(
                kind: .showInFinder,
                books: revealable,
                title: LibraryCloudWording.showInFinderTitle(count: revealable.count, forSelection: isSelection)
            ))
        }
        return commands
    }
}

// MARK: - Running Commands

extension BookDownloadProgress {
    /// A download that has reported nothing yet, which the list shows as
    /// "Downloading 0%": a book waiting its turn in a Download Now of
    /// several books, or one whose first progress has not come in.
    static let notStarted = BookDownloadProgress(completedFiles: 0, totalFiles: 0, completedBytes: 0, totalBytes: 0)
}

/// Remove Download's refusal as the Library window that asked shows it, in
/// an alert; VoiceOver hears the same words announced.
struct LibraryCloudRefusal: Equatable {
    /// The alert's title.
    let title: String
    /// What was and wasn't removed, and why.
    let message: String
}

/// Runs the library list's cloud commands for a book or a selection (FR02).
/// It records what it learns in `BookCloudStates`, announces through
/// `VoiceOverAnnouncer` from the window that asked, and logs each command's
/// start and end, with every failure and refusal. Files are read and
/// changed off the main thread, by the book storage.
@MainActor
final class LibraryCloudCommands {
    /// The commands every Library window runs.
    static let shared = LibraryCloudCommands()

    /// The books the list is downloading or has queued to download, by ID.
    private(set) var booksDownloading: Set<UUID> = []
    /// The books whose downloads the list is removing now, by ID.
    private(set) var booksBeingRemoved: Set<UUID> = []

    /// The store the commands record into.
    private let states: BookCloudStates
    /// The books this Mac keeps downloaded (Keep on This Mac).
    private let kept: KeptBooks
    /// The book storage, looked up when each command runs.
    private let storage: @MainActor () -> any BookCloudStorage
    /// Asks for a refresh once a removal has recorded its states, so that a
    /// refresh which read the files before the removal can't leave its
    /// older reading behind.
    private let refreshAfterRemoval: @MainActor () -> Void
    /// Selects files in Finder.
    private let revealInFinder: @MainActor ([URL]) -> Void

    /// Commands that record into `states` and act through `storage`.
    /// - Parameters:
    ///   - states: The store to record into.
    ///   - kept: The books this Mac keeps downloaded.
    ///   - storage: The book storage to act through, looked up when each
    ///     command runs, so a storage installed later is used.
    ///   - refreshAfterRemoval: Asks for a refresh after a removal.
    ///   - revealInFinder: Selects files in Finder.
    init(
        states: BookCloudStates = .shared,
        kept: KeptBooks = .shared,
        storage: @escaping @MainActor () -> any BookCloudStorage = { CloudServices.bookStorage },
        refreshAfterRemoval: @escaping @MainActor () -> Void = { LibraryCloudRefresher.shared.requestRefresh() },
        revealInFinder: @escaping @MainActor ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    ) {
        self.states = states
        self.kept = kept
        self.storage = storage
        self.refreshAfterRemoval = refreshAfterRemoval
        self.revealInFinder = revealInFinder
    }

    /// Runs `command` for the Library window `window` shows, announcing
    /// from it. Download Now returns as soon as it starts; its downloads go
    /// on in the background.
    /// - Returns: Remove Download's refusal for the window to show, if any.
    @discardableResult
    func perform(_ command: LibraryCloudCommand, in library: LibraryViewModel, from window: NSWindow?) async -> LibraryCloudRefusal? {
        switch command.kind {
        case .download:
            download(command.books, in: library, from: window)
            return nil
        case .removeDownload:
            return await removeDownloads(of: command.books, in: library, from: window)
        case .showInFinder:
            showInFinder(command.books)
            return nil
        }
    }

    // MARK: Show in Finder

    /// Selects the packages of `books` in Finder (Show in Finder). Finder's
    /// Keep Downloaded, Google Drive's Offline Access, and Dropbox's Make
    /// available offline are there, for a book to stay on this Mac.
    func showInFinder(_ books: [Book]) {
        guard !books.isEmpty else { return }
        revealInFinder(books.map { BookPackage($0).url })
    }

    // MARK: Download Now

    /// Downloads `books` one after another (Download Now), recording each
    /// download's progress and how it ended, then announces one summary.
    ///
    /// Only books whose state still lets them download, and that the list is
    /// not downloading already, take part. Each shows "Downloading 0%" at
    /// once and stays its download's until that ends, so no refresh changes
    /// it meanwhile. Downloading one book at a time keeps a book waiting in
    /// the sync service's queue from counting as stalled.
    /// - Parameters:
    ///   - books: The books to download, in list order.
    ///   - library: The library they are in, which a book may leave or move
    ///     within while it waits.
    ///   - window: The window to announce from.
    /// - Returns: The task running the downloads, which tests await; nil
    ///   when no book needed downloading.
    @discardableResult
    func download(_ books: [Book], in library: LibraryViewModel, from window: NSWindow?) -> Task<Void, Never>? {
        let queued = books.filter { book in
            !booksDownloading.contains(book.id) && states.listedState(of: book.id)?.canDownload == true
        }
        guard !queued.isEmpty else { return nil }
        let provider = states.libraryLocation.provider
        for book in queued {
            booksDownloading.insert(book.id)
            states.beginDownload(of: book.id)
            states.record(.downloading(.notStarted), for: book.id)
        }
        let titles = queued.map(\.title)
        VoiceOverAnnouncer.announce(LibraryCloudWording.downloadStarted(titles: titles), from: window)
        DiagnosticLog.event(.storage, "DOWNLOAD_NOW_STARTED: \(LibraryCloudWording.list(titles))")

        let queuedIDs = queued.map(\.id)
        return Task { [self, weak window] in
            var downloaded: [String] = []
            var failed: [(title: String, explanation: String)] = []
            for bookID in queuedIDs {
                switch await downloadQueuedBook(bookID, in: library, provider: provider) {
                case .downloaded(let title)?:
                    downloaded.append(title)
                case .failed(let title, let explanation)?:
                    failed.append((title: title, explanation: explanation))
                case nil:
                    break
                }
            }
            DiagnosticLog.event(
                .storage,
                "DOWNLOAD_NOW_FINISHED: \(downloaded.count) downloaded, \(failed.count) failed"
            )
            if let summary = LibraryCloudWording.downloadFinished(downloaded: downloaded, failed: failed) {
                VoiceOverAnnouncer.announce(summary, from: window)
            }
        }
    }

    /// How one book's download ended, by the title the summary names.
    private enum DownloadEnding {
        /// Every file of the book is on this Mac.
        case downloaded(title: String)
        /// The download failed, for the reason the explanation gives.
        case failed(title: String, explanation: String)
    }

    /// Downloads the book `bookID` when its turn in a Download Now comes,
    /// as the library has it then, recording its progress and how it ended.
    /// Ends quietly, recording no ending, when the book has left the
    /// library, before or during its download, or when the task was
    /// cancelled; a later refresh then records what the storage says.
    private func downloadQueuedBook(
        _ bookID: UUID,
        in library: LibraryViewModel,
        provider: CloudProvider?
    ) async -> DownloadEnding? {
        defer {
            booksDownloading.remove(bookID)
            states.endDownload(of: bookID)
        }
        guard let book = library.bookByID(bookID) else { return nil }
        // Starting a download can read files, which can wait on the
        // network, so the storage is asked off the main thread.
        let package = BookPackage(book)
        let storage = storage()
        let progressReports = await Task.detached(priority: .userInitiated) {
            storage.download(package)
        }.value
        let ending: DownloadEnding
        do {
            for try await progress in progressReports {
                states.record(.downloading(progress), for: bookID)
            }
            // Cancelling the task ends the loop without an error, and
            // without a finished download.
            guard !Task.isCancelled else { return nil }
            ending = .downloaded(title: book.title)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return nil }
            let failure = (error as? BookCloudError) ?? .provider(error.localizedDescription)
            let explanation = failure.explanation(in: provider)
            DiagnosticLog.event(.storage, "DOWNLOAD_NOW_FAILED: \(book.title): \(explanation)")
            ending = .failed(title: book.title, explanation: explanation)
        }
        // A book removed from the library meanwhile has no row to tell.
        guard library.bookByID(bookID) != nil else { return nil }
        switch ending {
        case .downloaded:
            states.record(.downloaded, for: bookID)
        case .failed(_, let explanation):
            states.record(.downloadFailed(explanation), for: bookID)
        }
        return ending
    }

    // MARK: Remove Download

    /// Removes the downloads of `books` (Remove Download), keeping the books
    /// in the cloud, records them as in the cloud, and announces what
    /// happened from `window`.
    ///
    /// Only downloaded books take part, and none whose download the list is
    /// removing already, so asking twice removes once. A book open in a
    /// reader, or one kept on this Mac, is refused at once, without asking
    /// the storage (`BookCloudError.bookIsOpen`, `.keptOnThisMac`), and the
    /// storage refuses a book with changes not uploaded yet (`.notUploaded`);
    /// a refused book keeps its download. Nothing is deleted from the cloud,
    /// so nothing asks first. The removals read and change files, so they
    /// run off the main thread.
    /// - Returns: The refusal for `window` to show when any book keeps its
    ///   download; nil when every download was removed, or none could be.
    @discardableResult
    func removeDownloads(of books: [Book], in library: LibraryViewModel, from window: NSWindow?) async -> LibraryCloudRefusal? {
        let targets = books.filter { book in
            !booksBeingRemoved.contains(book.id) && states.listedState(of: book.id)?.canRemoveDownload == true
        }
        guard !targets.isEmpty else { return nil }
        let targetIDs = Set(targets.map(\.id))
        booksBeingRemoved.formUnion(targetIDs)
        defer { booksBeingRemoved.subtract(targetIDs) }
        let provider = states.libraryLocation.provider
        let storage = storage()
        // Each book's package, or why its download stays without asking the
        // storage: the book is open in a reader, or kept on this Mac.
        let requests = targets.map { book -> Result<BookPackage, BookCloudError> in
            if library.openBookIDs.contains(book.id) { return .failure(.bookIsOpen) }
            if kept.contains(book.id) { return .failure(.keptOnThisMac) }
            return .success(BookPackage(book))
        }
        DiagnosticLog.event(
            .storage,
            "REMOVE_DOWNLOAD_STARTED: \(LibraryCloudWording.list(targets.map(\.title)))"
        )

        let failures = await Task.detached(priority: .userInitiated) {
            requests.map { request -> BookCloudError? in
                let package: BookPackage
                switch request {
                case .failure(let refusal):
                    return refusal
                case .success(let found):
                    package = found
                }
                do {
                    try storage.removeDownload(of: package)
                    return nil
                } catch {
                    // Any other error is the removal's failure too, never a
                    // download's, which `.provider` would say.
                    return (error as? BookCloudError) ?? .removalFailed(error.localizedDescription)
                }
            }
        }.value

        var removed: [String] = []
        var refused: [(title: String, explanation: String)] = []
        for (book, failure) in zip(targets, failures) {
            if let failure {
                let explanation = failure.explanation(in: provider)
                refused.append((title: book.title, explanation: explanation))
                DiagnosticLog.event(.storage, "REMOVE_DOWNLOAD_REFUSED: \(book.title): \(explanation)")
            } else {
                removed.append(book.title)
                states.record(.inCloud, for: book.id)
            }
        }
        if !removed.isEmpty {
            refreshAfterRemoval()
        }
        DiagnosticLog.event(
            .storage,
            "REMOVE_DOWNLOAD_FINISHED: \(removed.count) removed, \(refused.count) refused"
        )

        guard let message = LibraryCloudWording.removalFinished(
            removed: removed,
            refused: refused,
            provider: provider
        ) else { return nil }
        VoiceOverAnnouncer.announce(message, from: window)
        guard !refused.isEmpty else { return nil }
        return LibraryCloudRefusal(
            title: LibraryCloudWording.removalRefusedTitle(refusedCount: refused.count),
            message: message
        )
    }
}

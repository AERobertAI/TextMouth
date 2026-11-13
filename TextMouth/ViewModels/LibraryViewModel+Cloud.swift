#if os(macOS)
import AppKit
#else
import UIKit
#endif
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
/// request. After each refresh, the books kept on this Mac that it found
/// only in the cloud are downloaded again (Keep on This Mac).
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
    /// What follows each refresh, with the library it read: downloading
    /// again the kept books it found only in the cloud.
    private let afterRefresh: @MainActor (LibraryViewModel) -> Void

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
    ///   - afterRefresh: What follows each refresh: the list's commands
    ///     download again the kept books found only in the cloud.
    init(
        states: BookCloudStates = .shared,
        storage: @escaping @MainActor () -> any BookCloudStorage = { CloudServices.bookStorage },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        notificationCenter: NotificationCenter = .default,
        isEnabled: Bool = true,
        afterRefresh: @escaping @MainActor (LibraryViewModel) -> Void = {
            LibraryCloudCommands.shared.downloadEvictedKeptBooks(in: $0)
        }
    ) {
        self.states = states
        self.storage = storage
        self.sleep = sleep
        self.notificationCenter = notificationCenter
        self.isEnabled = isEnabled
        self.afterRefresh = afterRefresh
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
    /// Each refresh is followed by `afterRefresh`, which reads only what the
    /// refresh recorded.
    private func refreshUntilCurrent(_ scope: LibraryCloudRefreshScope) async {
        var next: LibraryCloudRefreshScope? = scope
        while let scope = next {
            scopeRequestedWhileRunning = nil
            guard let library else { break }
            await states.refresh(packages(of: library, in: scope), using: storage())
            afterRefresh(library)
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
        notificationCenter.publisher(for: PlatformApplication.didBecomeActiveNotification)
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
        /// Keep on This Mac: keeps books downloaded on this Mac from now on,
        /// downloading at once those in the cloud (`KeptBooks`).
        case keepOnThisMac
        /// Stop Keeping on This Mac: leaves books' downloads to the sync
        /// service and Remove Download again.
        case stopKeepingOnThisMac
        /// Show in Finder: selects the books' packages in Finder, where the
        /// sync service's own commands are, such as Keep Downloaded.
        case showInFinder

        /// The command's title for `count` books: its plain name for the one
        /// book a menu is for, or a title counting the books of a selection.
        func title(count: Int, forSelection: Bool) -> String {
            switch self {
            case .download:
                return LibraryCloudWording.downloadTitle(count: count, forSelection: forSelection)
            case .removeDownload:
                return LibraryCloudWording.removeDownloadTitle(count: count, forSelection: forSelection)
            case .keepOnThisMac:
                return LibraryCloudWording.keepTitle(count: count, forSelection: forSelection)
            case .stopKeepingOnThisMac:
                return LibraryCloudWording.stopKeepingTitle(count: count, forSelection: forSelection)
            case .showInFinder:
                return LibraryCloudWording.showInFinderTitle(count: count, forSelection: forSelection)
            }
        }
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
    /// - Keep on This Mac for the books this Mac doesn't keep, and Stop
    ///   Keeping on This Mac for the ones it does, both only in a cloud
    ///   library, whatever each book's state, so a book waiting for sync can
    ///   be kept before it arrives;
    /// - Show in Finder, in every library, for each book whose package is on
    ///   this Mac (all but those waiting for sync).
    ///
    /// A book not checked yet offers no Download Now or Remove Download. A
    /// book open in a reader, or kept on this Mac, offers the same commands
    /// as any other; Remove Download then explains why it can't remove its
    /// download.
    /// - Parameters:
    ///   - targets: The clicked book, or the selection it is part of, in
    ///     list order.
    ///   - isSelection: Whether `targets` is a selection of several books,
    ///     so the titles count the books each command acts on.
    ///   - states: The books' recorded cloud states.
    ///   - kept: The IDs of the books this Mac keeps downloaded.
    @MainActor
    static func commands(
        for targets: [Book],
        isSelection: Bool,
        states: BookCloudStates,
        kept: Set<UUID>
    ) -> [LibraryCloudCommand] {
        let listed = targets.map { (book: $0, state: states.listedState(of: $0.id)) }
        let inCloudLibrary = states.showsCloudNotes ? targets : []
        let offered: [(kind: Kind, books: [Book])] = [
            (.download, listed.filter { $0.state?.canDownload == true }.map(\.book)),
            (.removeDownload, listed.filter { $0.state?.canRemoveDownload == true }.map(\.book)),
            (.keepOnThisMac, inCloudLibrary.filter { !kept.contains($0.id) }),
            (.stopKeepingOnThisMac, inCloudLibrary.filter { kept.contains($0.id) }),
            (.showInFinder, listed.filter { $0.state != .waitingForSync }.map(\.book)),
        ]
        // A command is offered only for the books it suits, and only when
        // there is at least one.
        return offered.compactMap { kind, books in
            guard !books.isEmpty else { return nil }
            return LibraryCloudCommand(
                kind: kind,
                books: books,
                title: kind.title(count: books.count, forSelection: isSelection)
            )
        }
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

    /// How long a kept book whose download failed waits before a refresh
    /// downloads it again on its own: long enough that a Mac offline, or a
    /// sync service paused, isn't asked every minute, short enough that the
    /// book comes back soon after the network does. Download Now and Keep on
    /// This Mac never wait.
    static let keptBookRetryDelay: TimeInterval = 5 * 60

    /// The books the list is downloading or has queued to download, by ID.
    private(set) var booksDownloading: Set<UUID> = []
    /// The books whose downloads the list is removing now, by ID.
    private(set) var booksBeingRemoved: Set<UUID> = []
    /// When each kept book whose last download failed may be downloaded
    /// again by a refresh, by ID.
    private var keptBookRetryTimes: [UUID: Date] = [:]

    /// The store the commands record into.
    private let states: BookCloudStates
    /// The books this Mac keeps downloaded (Keep on This Mac, and the
    /// reading list's books while this Mac keeps them).
    let kept: KeptBooks
    /// The book storage, looked up when each command runs.
    private let storage: @MainActor () -> any BookCloudStorage
    /// Asks for a refresh once a removal has recorded its states, so that a
    /// refresh which read the files before the removal can't leave its
    /// older reading behind.
    private let refreshAfterRemoval: @MainActor () -> Void
    /// Selects files in Finder.
    private let revealInFinder: @MainActor ([URL]) -> Void
    /// The time now, which decides when a failed kept book is tried again.
    private let now: @MainActor () -> Date
    /// The free bytes on the volume holding a location: what the quiet
    /// downloads of kept books check before they start
    /// (`ArchiveLimits.volumeFreeSpace(at:)`, unless a test supplies its own).
    private let freeSpace: @Sendable (URL) -> Int64?
    /// The bytes the quiet downloads leave free on the volume
    /// (`ArchiveLimits.standard.freeSpaceReserve`, as an import leaves).
    private let freeSpaceReserve: Int64
    /// The books whose size and room a plan is reading now, which a second
    /// refresh must not plan again.
    private(set) var booksBeingPlanned: Set<UUID> = []
    /// The reading list's books the listener has been told of: that they
    /// download, or that there is no room (`readingListDownloadsStarted`), so
    /// a refresh that finds them evicted again, or still short of room,
    /// says nothing more.
    private var booksToldOfReadingListDownload: Set<UUID> = []

    /// Commands that record into `states` and act through `storage`.
    /// - Parameters:
    ///   - states: The store to record into.
    ///   - kept: The books this Mac keeps downloaded.
    ///   - storage: The book storage to act through, looked up when each
    ///     command runs, so a storage installed later is used.
    ///   - refreshAfterRemoval: Asks for a refresh after a removal.
    ///   - revealInFinder: Selects files in Finder.
    ///   - now: The time now: the system clock, unless a test sets it.
    ///   - freeSpace: The free bytes on the volume holding a location.
    ///   - freeSpaceReserve: The bytes downloads leave free on that volume.
    init(
        states: BookCloudStates = .shared,
        kept: KeptBooks = .shared,
        storage: @escaping @MainActor () -> any BookCloudStorage = { CloudServices.bookStorage },
        refreshAfterRemoval: @escaping @MainActor () -> Void = { LibraryCloudRefresher.shared.requestRefresh() },
        revealInFinder: @escaping @MainActor ([URL]) -> Void = {
            // iOS has no Finder to reveal files in (phase 0): it does nothing.
            #if os(macOS)
            NSWorkspace.shared.activateFileViewerSelecting($0)
            #endif
        },
        now: @escaping @MainActor () -> Date = { Date() },
        freeSpace: @escaping @Sendable (URL) -> Int64? = { ArchiveLimits.volumeFreeSpace(at: $0) },
        freeSpaceReserve: Int64 = ArchiveLimits.standard.freeSpaceReserve
    ) {
        self.states = states
        self.kept = kept
        self.storage = storage
        self.refreshAfterRemoval = refreshAfterRemoval
        self.revealInFinder = revealInFinder
        self.now = now
        self.freeSpace = freeSpace
        self.freeSpaceReserve = freeSpaceReserve
    }

    /// Runs `command` for the Library window `window` shows, announcing
    /// from it. Download Now, and Keep on This Mac for books in the cloud,
    /// return as soon as their downloads start; the downloads go on in the
    /// background.
    /// - Returns: Remove Download's refusal for the window to show, if any.
    @discardableResult
    func perform(_ command: LibraryCloudCommand, in library: LibraryViewModel, from window: PlatformWindow?) async -> LibraryCloudRefusal? {
        switch command.kind {
        case .download:
            download(command.books, in: library, from: window)
        case .removeDownload:
            return await removeDownloads(of: command.books, in: library, from: window)
        case .keepOnThisMac:
            keep(command.books, in: library, from: window)
        case .stopKeepingOnThisMac:
            stopKeeping(command.books, from: window)
        case .showInFinder:
            showInFinder(command.books)
        }
        return nil
    }

    // MARK: Keep on This Mac

    /// Keeps `books` on this Mac (Keep on This Mac): each stays downloaded
    /// from now on (`KeptBooks`). Those whose state lets them download, only
    /// in the cloud or left there by a failed download, start downloading
    /// at once, as Download Now downloads them, their rows showing
    /// "Downloading". VoiceOver hears one sentence saying both, then the
    /// downloads' summary when they end. Books kept already change nothing.
    /// - Returns: The task running the downloads, which tests await; nil
    ///   when no book needed downloading.
    @discardableResult
    func keep(_ books: [Book], in library: LibraryViewModel, from window: PlatformWindow?) -> Task<Void, Never>? {
        let newlyKept = kept.keep(books.map(\.id))
        let keptNow = books.filter { newlyKept.contains($0.id) }
        guard !keptNow.isEmpty else { return nil }
        let downloadable = keptNow.filter(canStartDownload)
        let titles = keptNow.map(\.title)
        DiagnosticLog.event(.storage, "KEEP_ON_MAC: keeping \(CountWording.list(titles)) on this Mac")
        VoiceOverAnnouncer.announce(
            LibraryCloudWording.keepStarted(titles: titles, downloading: downloadable.count),
            from: window
        )
        return download(downloadable, in: library, from: window, origin: .keepOnThisMac)
    }

    /// Stops keeping `books` on this Mac (Stop Keeping on This Mac), and
    /// tells VoiceOver which books. Nothing is downloaded or removed now:
    /// their downloads stay until the sync service, or Remove Download,
    /// removes them. Books not kept change nothing.
    func stopKeeping(_ books: [Book], from window: PlatformWindow?) {
        let released = kept.stopKeeping(books.map(\.id))
        let titles = books.filter { released.contains($0.id) }.map(\.title)
        guard !titles.isEmpty else { return }
        released.forEach { keptBookRetryTimes[$0] = nil }
        // A book the reading list also keeps stays kept; the words say so.
        let stillKept = books.filter { released.contains($0.id) && kept.isKeptForReadingList($0.id) }.count
        DiagnosticLog.event(.storage, "KEEP_ON_MAC: stopped keeping \(CountWording.list(titles)) on this Mac")
        VoiceOverAnnouncer.announce(
            LibraryCloudWording.stoppedKeeping(titles: titles, stillKept: stillKept),
            from: window
        )
    }

    /// Keep on This Mac (`keeping`) or Stop Keeping on This Mac, chosen in
    /// the Library menu for `selection`, the books selected in `window`'s
    /// list, in list order. It runs the command a row of the selection
    /// offers, on the books that command acts on; when no row would offer
    /// it, VoiceOver hears why nothing changed: the library isn't in the
    /// cloud, no book is selected, or every one is already as asked.
    /// - Returns: The task running the downloads a keep started, which tests
    ///   await; nil when none started.
    @discardableResult
    func setKeptFromMenu(
        _ keeping: Bool,
        for selection: [Book],
        in library: LibraryViewModel,
        from window: PlatformWindow?
    ) -> Task<Void, Never>? {
        let kind: LibraryCloudCommand.Kind = keeping ? .keepOnThisMac : .stopKeepingOnThisMac
        let offered = LibraryCloudCommand.commands(
            for: selection,
            isSelection: selection.count > 1,
            states: states,
            kept: kept.bookIDs
        )
        guard let command = offered.first(where: { $0.kind == kind }) else {
            VoiceOverAnnouncer.announce(
                LibraryCloudWording.keepMenuRefusal(
                    keeping: keeping,
                    selected: selection.map(\.title),
                    inCloudLibrary: states.showsCloudNotes,
                    keptOnlyForReadingList: selection.filter { kept.isKeptOnlyForReadingList($0.id) }.count
                ),
                from: window
            )
            return nil
        }
        guard keeping else {
            stopKeeping(command.books, from: window)
            return nil
        }
        return keep(command.books, in: library, from: window)
    }

    /// Downloads again each book of `library` kept on this Mac that the
    /// latest refresh recorded as only in the cloud: the sync service
    /// removed its download, while TextMouth ran or before it started. The
    /// cloud refresher calls this after each refresh.
    ///
    /// The rows show "Downloading", and KEPT_BOOK_DOWNLOAD lines log the
    /// downloads. A kept book whose last download failed waits
    /// `keptBookRetryDelay` before a refresh tries it again, so a Mac
    /// offline isn't asked every minute; a book waiting for sync downloads
    /// once it has arrived.
    ///
    /// Only the books that fit start: the volume's free space, less the
    /// reserve, must hold what each still needs
    /// (`planDownloads(of:)`), so a first refresh after an update cannot
    /// fill the Mac with a long reading list. Nobody asked just then, so
    /// VoiceOver hears one notice, at medium priority, the first time the
    /// reading list's books start or find no room
    /// (`announceReadingListDownloads`); other kept books are silent.
    /// - Returns: The task running the downloads, which tests await; nil
    ///   when no kept book needed downloading.
    @discardableResult
    func downloadEvictedKeptBooks(in library: LibraryViewModel) -> Task<Void, Never>? {
        guard states.showsCloudNotes, kept.keepsAnyBook else { return nil }
        let time = now()
        let evicted = library.library.books.filter { book in
            kept.isKept(book.id)
                && states.listedState(of: book.id) == .inCloud
                && (keptBookRetryTimes[book.id].map { $0 <= time } ?? true)
        }
        return downloadWhatFits(of: evicted, in: library, from: nil, origin: .keptBookRefresh)
    }

    /// Downloads the books the listener has just added to the reading list
    /// (Add to Reading List), when the library is in the cloud and this Mac
    /// keeps the list's books, those that fit in the free space
    /// (`downloadWhatFits`). The notice that they download, and that some
    /// found no room, is one at medium priority, after the add's own words
    /// (`announceReadingListDownloads`); the end of the downloads is
    /// announced as Download Now's is. Books that reach the list another
    /// way, as a sync from another Mac brings them, download with the
    /// refresh's kept books (`downloadEvictedKeptBooks(in:)`). Only books
    /// only in the cloud download; the others change nothing.
    /// - Returns: The task running the downloads, which tests await; nil
    ///   when none started.
    @discardableResult
    func downloadBooksAddedToReadingList(_ books: [Book], in library: LibraryViewModel, from window: PlatformWindow?) -> Task<Void, Never>? {
        guard states.showsCloudNotes, kept.keepsReadingListBooks else { return nil }
        return downloadWhatFits(of: books, in: library, from: window, origin: .readingListAdd)
    }

    /// Forgets which of the reading list's books the listener has been told
    /// of, so turning the choice to keep them on again says what it starts.
    func forgetReadingListDownloadNotices() {
        booksToldOfReadingListDownload = []
    }

    /// Plans the downloads of those of `books` that can start now, starts
    /// the ones that fit, and tells the listener about the reading list's
    /// books among them once. Returns the task that plans and downloads;
    /// nil, planning nothing, when no book can start.
    ///
    /// The planning reads the books' sizes and the volume's free space off
    /// the main thread, since both can wait on the file system or the
    /// network. Books being planned by an earlier call are left to it.
    private func downloadWhatFits(
        of books: [Book],
        in library: LibraryViewModel,
        from window: PlatformWindow?,
        origin: DownloadOrigin
    ) -> Task<Void, Never>? {
        let candidates = books.filter { canStartDownload($0) && !booksBeingPlanned.contains($0.id) }
        guard !candidates.isEmpty else { return nil }
        let candidateIDs = Set(candidates.map(\.id))
        booksBeingPlanned.formUnion(candidateIDs)
        return Task { [self] in
            let plan = await planDownloads(of: candidates)
            booksBeingPlanned.subtract(candidateIDs)
            // The states may have moved on while the plan was read.
            let starting = plan.fits.filter(canStartDownload)
            announceReadingListDownloads(starting: starting, short: plan.short, origin: origin, from: window)
            await download(starting, in: library, from: window, origin: origin)?.value
        }
    }

    /// Which of `books` fit in the space free on the library's volume, in
    /// order, each taking what it still needs to download, less the reserve
    /// (`freeSpaceReserve`) that stays free; the rest are short of room.
    /// A book whose size is unknown takes nothing, so with room above the
    /// reserve it starts. Nothing is short when the volume's free space
    /// cannot be told. Reads off the main thread, and downloads nothing.
    private func planDownloads(of books: [Book]) async -> (fits: [Book], short: [Book]) {
        let storage = storage()
        let packages = books.map { BookPackage($0) }
        let root = TextMouthPaths.root
        let freeSpace = freeSpace
        let reads = await Task.detached(priority: .userInitiated) {
            (free: freeSpace(root), needs: packages.map { storage.bytesToDownload(of: $0) })
        }.value
        guard let free = reads.free else { return (books, []) }
        var room = free - freeSpaceReserve
        var fits: [Book] = []
        var short: [Book] = []
        for (book, need) in zip(books, reads.needs) {
            let bytes = need ?? 0
            if bytes <= room {
                fits.append(book)
                room -= bytes
            } else {
                short.append(book)
            }
        }
        return (fits, short)
    }

    /// Tells the listener, once for each book, that the reading list's books
    /// among `starting` download and that those among `short` found no room
    /// (`LibraryCloudWording.readingListDownloadsStarted`), at medium
    /// priority, so it waits for the words just said. Books the listener
    /// has been told of are left out, so a refresh that finds a book evicted
    /// again, or still short of room, says nothing more; nothing is said when
    /// no book is new to the listener, or none is the list's.
    private func announceReadingListDownloads(
        starting: [Book],
        short: [Book],
        origin: DownloadOrigin,
        from window: PlatformWindow?
    ) {
        // The books just added are the list's by that fact: the list's kept set
        // is handed over a turn after the list changes.
        let newToTheListener = { (book: Book) in
            (origin == .readingListAdd || self.kept.isKeptForReadingList(book.id))
                && !self.booksToldOfReadingListDownload.contains(book.id)
        }
        let started = starting.filter(newToTheListener)
        let notFitting = short.filter(newToTheListener)
        guard !started.isEmpty || !notFitting.isEmpty else { return }
        booksToldOfReadingListDownload.formUnion((started + notFitting).map(\.id))
        VoiceOverAnnouncer.announce(
            LibraryCloudWording.readingListDownloadsStarted(
                titles: started.map(\.title),
                short: notFitting.count,
                quietly: origin == .keptBookRefresh
            ),
            from: window,
            priority: .medium
        )
    }

    /// Notes how a download of the book `bookID` ended, for a kept book: a
    /// failure makes refreshes wait `keptBookRetryDelay` before they try it
    /// again, and a success lets the next eviction be downloaded at once.
    private func noteKeptBookDownload(_ bookID: UUID, failed: Bool) {
        guard kept.isKept(bookID) else { return }
        keptBookRetryTimes[bookID] = failed ? now().addingTimeInterval(Self.keptBookRetryDelay) : nil
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
    func download(_ books: [Book], in library: LibraryViewModel, from window: PlatformWindow?) -> Task<Void, Never>? {
        download(books, in: library, from: window, origin: .downloadNow)
    }

    /// Why the list downloads books, which decides what VoiceOver hears and
    /// which lines the log gets.
    private enum DownloadOrigin {
        /// Download Now: VoiceOver hears the start and the end.
        case downloadNow
        /// Keep on This Mac, for the kept books in the cloud: Keep on This
        /// Mac announced the start, so VoiceOver hears only the end.
        case keepOnThisMac
        /// A refresh found kept books only in the cloud: nobody asked just
        /// then, so VoiceOver hears nothing but the reading list's one notice
        /// (`announceReadingListDownloads`), and the rows show the downloads.
        case keptBookRefresh
        /// Add to Reading List, for the books added in a cloud library: the
        /// notice at medium priority tells the start, and VoiceOver hears the
        /// end as Download Now's.
        case readingListAdd

        /// Whether the download itself tells VoiceOver which books start
        /// downloading, as Download Now does.
        var announcesStart: Bool {
            self == .downloadNow
        }

        /// Whether VoiceOver hears how the downloads ended.
        var announcesEnd: Bool {
            self != .keptBookRefresh
        }

        /// The tags of the lines logged as the downloads start, as one of
        /// them fails, and once they have all ended. Each tag is spelled out
        /// whole, so a search of the source finds it.
        var logTags: (started: String, failed: String, finished: String) {
            switch self {
            case .downloadNow:
                return ("DOWNLOAD_NOW_STARTED", "DOWNLOAD_NOW_FAILED", "DOWNLOAD_NOW_FINISHED")
            case .keepOnThisMac, .keptBookRefresh, .readingListAdd:
                return ("KEPT_BOOK_DOWNLOAD_STARTED", "KEPT_BOOK_DOWNLOAD_FAILED", "KEPT_BOOK_DOWNLOAD_FINISHED")
            }
        }
    }

    /// Whether a download of `book` can start now: its recorded state lets
    /// it download, and the list isn't downloading it already.
    private func canStartDownload(_ book: Book) -> Bool {
        !booksDownloading.contains(book.id) && states.listedState(of: book.id)?.canDownload == true
    }

    /// Downloads those of `books` that can start downloading now, one after
    /// another, as `download(_:in:from:)` describes, saying and logging what
    /// `origin` calls for.
    private func download(
        _ books: [Book],
        in library: LibraryViewModel,
        from window: PlatformWindow?,
        origin: DownloadOrigin
    ) -> Task<Void, Never>? {
        let queued = books.filter(canStartDownload)
        guard !queued.isEmpty else { return nil }
        let provider = states.libraryLocation.provider
        for book in queued {
            booksDownloading.insert(book.id)
            states.beginDownload(of: book.id)
            states.record(.downloading(.notStarted), for: book.id)
        }
        let titles = queued.map(\.title)
        if origin.announcesStart {
            VoiceOverAnnouncer.announce(LibraryCloudWording.downloadStarted(titles: titles), from: window)
        }
        DiagnosticLog.event(.storage, "\(origin.logTags.started): \(CountWording.list(titles))")

        let queuedIDs = queued.map(\.id)
        return Task { [self, weak window] in
            var downloaded: [String] = []
            var failed: [(title: String, explanation: String)] = []
            for bookID in queuedIDs {
                switch await downloadQueuedBook(bookID, in: library, provider: provider, origin: origin) {
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
                "\(origin.logTags.finished): \(downloaded.count) downloaded, \(failed.count) failed"
            )
            if origin.announcesEnd,
               let summary = LibraryCloudWording.downloadFinished(downloaded: downloaded, failed: failed) {
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

    /// Downloads the book `bookID` when its turn among the books queued for
    /// `origin` comes, as the library has it then, recording its progress
    /// and how it ended. Ends quietly, recording no ending, when the book has
    /// left the library, before or during its download, or when the task
    /// was cancelled; a later refresh then records what the storage says.
    private func downloadQueuedBook(
        _ bookID: UUID,
        in library: LibraryViewModel,
        provider: CloudProvider?,
        origin: DownloadOrigin
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
            DiagnosticLog.event(.storage, "\(origin.logTags.failed): \(book.title): \(explanation)")
            ending = .failed(title: book.title, explanation: explanation)
        }
        // A book removed from the library meanwhile has no row to tell.
        guard library.bookByID(bookID) != nil else { return nil }
        switch ending {
        case .downloaded:
            states.record(.downloaded, for: bookID)
            noteKeptBookDownload(bookID, failed: false)
        case .failed(_, let explanation):
            states.record(.downloadFailed(explanation), for: bookID)
            noteKeptBookDownload(bookID, failed: true)
        }
        return ending
    }

    // MARK: Remove Download

    /// Removes the downloads of `books` (Remove Download), keeping the books
    /// in the cloud, records them as in the cloud, and says what happened:
    /// announced from `window` when every download was removed, shown in the
    /// returned refusal's alert when any book kept its download.
    ///
    /// Only downloaded books take part, and none whose download the list is
    /// removing already, so asking twice removes once. A book open in a
    /// reader, or one kept on this Mac, by the listener's choice or for the
    /// reading list, is refused at once, without asking the storage
    /// (`BookCloudError.bookIsOpen`, `.keptOnThisMac`,
    /// `.keptForReadingList`), and the
    /// storage refuses a book with changes not uploaded yet (`.notUploaded`);
    /// a refused book keeps its download. Nothing is deleted from the cloud,
    /// so nothing asks first. The removals read and change files, so they
    /// run off the main thread.
    ///
    /// A refusal is said once, by its alert, with nothing announced besides:
    /// VoiceOver reads an alert as it appears, so the same words announced
    /// too would be heard twice, or cut off as the alert takes its focus
    /// (REV14 feeds 6, as `FeedCommandRunner.refuse(message:)` does; #2094).
    /// The alert's message is the whole summary: what was removed, what
    /// stayed, and why.
    /// - Returns: The refusal for `window` to show when any book keeps its
    ///   download; nil when every download was removed, or none could be.
    @discardableResult
    func removeDownloads(of books: [Book], in library: LibraryViewModel, from window: PlatformWindow?) async -> LibraryCloudRefusal? {
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
            // Both reasons are named at once, so the advice never leads to a
            // second refusal.
            switch (kept.contains(book.id), kept.isKeptForReadingList(book.id)) {
            case (true, true): return .failure(.keptOnThisMacAndForReadingList)
            case (true, false): return .failure(.keptOnThisMac)
            case (false, true): return .failure(.keptForReadingList)
            case (false, false): break
            }
            return .success(BookPackage(book))
        }
        DiagnosticLog.event(
            .storage,
            "REMOVE_DOWNLOAD_STARTED: \(CountWording.list(targets.map(\.title)))"
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
        // A refusal is shown, not said: its alert carries the whole message.
        guard refused.isEmpty else {
            return LibraryCloudRefusal(
                title: LibraryCloudWording.removalRefusedTitle(refusedCount: refused.count),
                message: message
            )
        }
        VoiceOverAnnouncer.announce(message, from: window)
        return nil
    }
}

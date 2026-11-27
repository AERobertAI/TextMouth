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
        /// Keep on All Devices (FR43): every device that syncs keeps the
        /// books' files, offered only while sync is on.
        case keepOnAllDevices
        /// Stop Keeping on All Devices: ends that for the books.
        case stopKeepingOnAllDevices
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
            case .keepOnAllDevices:
                return forSelection ? SyncWording.keepTitle(count: count) : SyncWording.keepTitle
            case .stopKeepingOnAllDevices:
                return forSelection ? SyncWording.stopKeepingTitle(count: count) : SyncWording.stopKeepingTitle
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
    ///   the downloaded ones, in a cloud library, and in a synced library for
    ///   a book whole on this device (`BookCloudStates.canRemoveDownload(_:)`);
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
    ///   - keptOnAllDevices: The IDs of the books kept on all devices that
    ///     sync (FR43), whose Keep on All Devices and Stop Keeping on All
    ///     Devices are offered only while sync is on.
    @MainActor
    static func commands(
        for targets: [Book],
        isSelection: Bool,
        states: BookCloudStates,
        kept: Set<UUID>,
        keptOnAllDevices: Set<UUID> = []
    ) -> [LibraryCloudCommand] {
        let listed = targets.map { (book: $0, state: states.listedState(of: $0.id)) }
        // Keep on This Mac is for a library in a cloud folder; a synced
        // library has Keep on All Devices instead, and Remove Download too.
        let inCloudLibrary = states.isCloudLibrary ? targets : []
        let synced = states.syncIsOn ? targets : []
        let offered: [(kind: Kind, books: [Book])] = [
            (.download, listed.filter { $0.state?.canDownload == true }.map(\.book)),
            (.removeDownload, targets.filter { states.canRemoveDownload($0) }),
            (.keepOnThisMac, inCloudLibrary.filter { !kept.contains($0.id) }),
            (.stopKeepingOnThisMac, inCloudLibrary.filter { kept.contains($0.id) }),
            (.keepOnAllDevices, synced.filter { !keptOnAllDevices.contains($0.id) }),
            (.stopKeepingOnAllDevices, synced.filter { keptOnAllDevices.contains($0.id) }),
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
    /// again by a refresh, by ID. Books `All books` downloads wait the same way.
    private var keptBookRetryTimes: [UUID: Date] = [:]
    /// When each book the removal of unopened downloads had to leave for a reason that costs a look at its files
    /// may be tried again, by ID (FR45).
    private var unopenedRetryTimes: [UUID: Date] = [:]
    /// The books the removal of unopened downloads has left on the device for want of a proven copy, until they go
    /// or are protected: the count the status line shows stays steady while a book waits out its day.
    private var unopenedHeld: Set<UUID> = []
    /// The books whose refusal the log has already told, so a book that waits is told once, not at each sync.
    private var unopenedLogged: Set<UUID> = []
    /// Whether a sweep of unopened downloads is under way: sweeps run one at a time.
    private var isSweepingUnopened = false

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
    /// Which books this device keeps downloaded now (FR45): the setting's, unless a test supplies its own.
    private let booksChoice: @MainActor () -> BooksOnThisDevice
    /// Told how many books `All books` could not download for want of room, after each plan (FR45): the sync's
    /// status line says it.
    private let roomNotice: @MainActor (Int) -> Void
    /// When the files of the book at a package last arrived on this device (`SyncPlaceholder.arrivedAt`), read off
    /// the main thread; a test supplies its own.
    private let packageArrival: @Sendable (URL) -> Date?
    /// Whether the network path costs (cellular, a hotspot, Low Data Mode), asked before each download and each
    /// proof that would download; `SyncActivity.pathIsCostly` unless a test supplies its own.
    private let pathIsCostly: @Sendable () -> Bool
    /// This device's settings now, which a removal looks at again just before it deletes (FR45).
    private let currentSettings: @MainActor () -> SyncDeviceSettings
    /// The books a person freed, which "All books" leaves in the cloud until they are opened (FR46).
    private let freedOnPurpose: @MainActor () -> BooksFreedOnPurpose
    /// The books whose size and room a plan is reading now, which a second
    /// refresh must not plan again.
    private(set) var booksBeingPlanned: Set<UUID> = []
    /// The reading list's books the listener has been told of: that they
    /// download, or that there is no room (`readingListDownloadsStarted`), so
    /// a refresh that finds them evicted again, or still short of room,
    /// says nothing more.
    private var booksToldOfReadingListDownload: Set<UUID> = []
    /// The books logged as left out for want of room
    /// (`logBooksLeftOutForRoom`), until they next start, so each refresh
    /// that finds one still short adds no line.
    private var booksLoggedShortOfRoom: Set<UUID> = []

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
    ///   - booksChoice: Which books this device keeps (FR45).
    ///   - roomNotice: Told how many books could not download for want of room.
    ///   - packageArrival: When a package's files last arrived on this device.
    ///   - pathIsCostly: Whether the network path costs.
    ///   - currentSettings: This device's settings now.
    ///   - freedOnPurpose: The books a person freed.
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
        freeSpaceReserve: Int64 = ArchiveLimits.standard.freeSpaceReserve,
        booksChoice: @escaping @MainActor () -> BooksOnThisDevice = { SyncSpaceSettings.shared.settings.books },
        roomNotice: @escaping @MainActor (Int) -> Void = { SyncCenter.shared.noteSpace(booksShortOfRoom: $0) },
        packageArrival: @escaping @Sendable (URL) -> Date? = { SyncPlaceholder.arrivedAt($0) },
        pathIsCostly: @escaping @Sendable () -> Bool = { SyncActivity.pathIsCostly },
        currentSettings: @escaping @MainActor () -> SyncDeviceSettings = { SyncSpaceSettings.shared.settings },
        freedOnPurpose: @escaping @MainActor () -> BooksFreedOnPurpose = { BooksFreedOnPurpose.shared }
    ) {
        self.states = states
        self.kept = kept
        self.storage = storage
        self.refreshAfterRemoval = refreshAfterRemoval
        self.revealInFinder = revealInFinder
        self.now = now
        self.freeSpace = freeSpace
        self.freeSpaceReserve = freeSpaceReserve
        self.booksChoice = booksChoice
        self.roomNotice = roomNotice
        self.packageArrival = packageArrival
        self.pathIsCostly = pathIsCostly
        self.currentSettings = currentSettings
        self.freedOnPurpose = freedOnPurpose
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
        case .keepOnAllDevices:
            setKeptOnAllDevices(true, command.books, from: window)
        case .stopKeepingOnAllDevices:
            setKeptOnAllDevices(false, command.books, from: window)
        case .showInFinder:
            showInFinder(command.books)
        }
        return nil
    }

    // MARK: Keep on All Devices (FR43)

    /// Keeps `books` on all devices that sync, or stops: the choice is
    /// stamped in the sync (`SyncCenter.setKeep`), which every device reads,
    /// and VoiceOver hears which books. The downloads follow the next sync
    /// (`LibraryViewModel.syncDidApply(keptBookIDs:mayDownload:)`).
    func setKeptOnAllDevices(_ keeping: Bool, _ books: [Book], from window: PlatformWindow?, announcing: Bool = true) {
        guard !books.isEmpty else { return }
        // The books whose keep this changes: not kept yet to keep, kept to
        // stop. VoiceOver hears only those, so a stop that removed no keep
        // says nothing it did not do. Every way to the choice, a row's
        // command, the Library menu, and Book Information's checkbox, comes here.
        let before = KeptBooks.shared.syncedBookIDs
        let changed = books.filter { keeping ? !before.contains($0.id) : before.contains($0.id) }
        SyncCenter.shared.setKeep(keeping, for: books.map(\.id))
        // The set follows at once, so the Book Information checkbox and the
        // rows read the new value as VoiceOver asks, before the sync's own
        // registers say so.
        KeptBooks.shared.noteSyncedChange(keeping: keeping, Set(books.map(\.id)))
        guard announcing, !changed.isEmpty else { return }
        let titles = changed.map(\.title).joined(separator: ", ")
        DiagnosticLog.event(.storage, "KEEP_ON_ALL: \(keeping ? "keeping" : "stopped keeping") \(changed.count) book(s) on all devices") // l10n: no (debug log, English)
        VoiceOverAnnouncer.announce(
            keeping ? SyncWording.announceKeeping(title: titles) : SyncWording.announceStoppedKeeping(title: titles),
            from: window
        )
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
        DiagnosticLog.event(.storage, "KEEP_ON_MAC: keeping \(titles.joined(separator: ", ")) on this Mac") // l10n: no (debug log, English)
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
        DiagnosticLog.event(.storage, "KEEP_ON_MAC: stopped keeping \(titles.joined(separator: ", ")) on this Mac") // l10n: no (debug log, English)
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
                    inCloudLibrary: states.isCloudLibrary,
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
    func downloadEvictedKeptBooks(in library: LibraryViewModel, afterSync: Bool = false) -> Task<Void, Never>? {
        // In a library that is not in a cloud folder, only the call a sync
        // makes downloads (`LibraryViewModel.syncDidApply`), once it has found
        // the network allows it; the cloud refresher's own call, which knows
        // nothing of the network's cost, leaves a synced library alone.
        guard states.isCloudLibrary || afterSync else { return nil }
        guard states.showsCloudNotes, kept.keepsAnyBook else { return nil }
        let time = now()
        let evicted = library.library.books.filter { book in
            kept.isKept(book.id)
                && states.listedState(of: book.id) == .inCloud
                && (keptBookRetryTimes[book.id].map { $0 <= time } ?? true)
        }
        return downloadWhatFits(of: evicted, in: library, from: nil, origin: .keptBookRefresh)
    }

    // MARK: Books on This Device (FR45)

    /// Under `All books`, downloads each book this device lacks, after a sync: the books the sync recorded as
    /// only in the cloud, one at a time, quietly, as many as the free space allows (`downloadWhatFits`), the
    /// rows saying "Downloading 40%". Never removes one. A book short of room is left, and the sync's status
    /// line says how many (`roomNotice`); a book whose download failed waits `keptBookRetryDelay`.
    /// Does nothing while the choice is the other one, or sync is off.
    /// - Returns: The task running the downloads, which tests await; nil when none needed to start.
    @discardableResult
    func downloadMissingBooks(in library: LibraryViewModel) -> Task<Void, Never>? {
        guard states.syncIsOn, booksChoice() == .allBooks, !pathIsCostly() else { return nil }
        let time = now()
        // A book a person freed stays freed until it is opened again: the next sync does not undo their command.
        let freed = freedOnPurpose()
        let missing = library.library.books.filter { book in
            states.listedState(of: book.id) == .inCloud
                && (keptBookRetryTimes[book.id].map { $0 <= time } ?? true)
                && !freed.isHeld(book)
        }
        guard !missing.isEmpty else {
            roomNotice(0)
            return nil
        }
        return downloadWhatFits(of: missing, in: library, from: nil, origin: .allBooks)
    }

    /// What one sweep of the removal of unopened downloads did.
    struct UnopenedRemovalReport: Equatable {
        /// The books whose downloads were removed.
        var removed: [UUID] = []
        /// How many books are left on this device for now, because their copies in iCloud Drive are not proven yet.
        var waiting = 0
    }

    /// The most books one sweep takes off the device: the rest wait for the next sync, so a sweep after a long
    /// absence does not read back a whole library at once. Books that cannot be proven are not counted: they
    /// cost only a look, and never keep the books behind them from going.
    static let unopenedBooksPerSweep = 25

    /// Removes the downloads of books left unopened for the days of `settings` (FR45), after a sync, keeping each
    /// book in the library as a placeholder that says In Cloud. Only under `Books you open or keep`, with days
    /// set and the date the removal began known (`settings.activeDays`, `removalsBeganAt`). One sweep runs at a
    /// time: a second asked for while one is under way does nothing.
    ///
    /// A book is left alone when `isProtected` says so (kept, listed, in use, a feed's, or busy), when it was
    /// opened, played, or arrived within the days, and whenever the proof of its copy in the sync folder falls
    /// short (`StoreRemoval`): it then stays whole and the sweep counts it as waiting. The book is looked at
    /// again right before its files go, with the setting, since the proof can take minutes (`FreeingCheck`): one
    /// opened, kept, or edited meanwhile stays. The rows are recorded In Cloud, and VoiceOver hears one summary
    /// for the whole sweep, never one for each book.
    /// - Parameters:
    ///   - books: The library's books.
    ///   - library: The library, which the last look asks.
    ///   - settings: This device's settings.
    ///   - mayDownload: Whether files of a copy that are away in iCloud Drive may be downloaded to read them back:
    ///     not on a connection that costs.
    ///   - isProtected: Whether a book is never removed now.
    @discardableResult
    func removeUnopenedDownloads(
        of books: [Book],
        in library: LibraryViewModel,
        settings: SyncDeviceSettings,
        mayDownload: Bool,
        isProtected: @escaping @MainActor @Sendable (Book) -> Bool
    ) async -> UnopenedRemovalReport {
        var report = UnopenedRemovalReport()
        guard !isSweepingUnopened else { return report }
        guard states.syncIsOn, let days = settings.activeDays, let began = settings.removalsBeganAt else { return report }
        isSweepingUnopened = true
        defer { isSweepingUnopened = false }
        let time = now()
        let bookIDs = Set(books.map(\.id))
        unopenedHeld.formIntersection(bookIDs)
        // The books due by their own dates, longest unopened first; their files' arrival is looked at one by one below.
        let candidates = books
            .filter { book in
                book.feedLink == nil && (unopenedRetryTimes[book.id].map { $0 <= time } ?? true)
            }
            .map { ($0, SyncSpacePolicy.lastInUse(opened: $0.lastOpened, played: $0.lastPlaybackStopped, arrived: nil, removalsBeganAt: began)) }
            .filter { SyncSpacePolicy.isDue(lastInUse: $0.1, days: days, now: time) }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        let storage = storage()
        for book in candidates {
            guard report.removed.count < Self.unopenedBooksPerSweep else { break }
            // Looked at now, as the library is now: a book opened or kept meanwhile stays.
            guard !isProtected(book), !booksBeingRemoved.contains(book.id), states.canRemoveDownload(book) else {
                unopenedHeld.remove(book.id)
                continue
            }
            // Marked before the first wait, so a person's Remove Download of the book meanwhile leaves it to this sweep.
            booksBeingRemoved.insert(book.id)
            defer { booksBeingRemoved.remove(book.id) }
            let package = BookPackage(book)
            let arrival = packageArrival
            let arrived = await Task.detached(priority: .utility) { arrival(package.url) }.value
            let lastInUse = SyncSpacePolicy.lastInUse(opened: book.lastOpened, played: book.lastPlaybackStopped, arrived: arrived, removalsBeganAt: began)
            guard SyncSpacePolicy.isDue(lastInUse: lastInUse, days: days, now: time) else { continue }
            // The last look asks again whether the book is due, as it is then: opened or played meanwhile, or the days
            // made longer, it stays.
            let lastLook = finalCheck(for: book.id, in: library, protecting: isProtected) { [weak self] current in
                self?.isStillDue(current, arrived: arrived) ?? false
            }
            // A yes of the last look holds the book busy until its row says what came of the removal, recorded below.
            defer { endFreeing(book.id, in: library) }
            do {
                try await FreeingCheck.$current.withValue(lastLook) {
                    try await storage.removeDownloadAsync(of: package, mayDownload: mayDownload)
                }
                states.record(.inCloud, for: book.id)
                report.removed.append(book.id)
                unopenedHeld.remove(book.id)
            } catch BookCloudError.syncRemoval(.nothingToRemove) {
                // Away already, though no row said so: the row says it now, and nothing was removed.
                states.record(.inCloud, for: book.id)
                unopenedHeld.remove(book.id)
            } catch BookCloudError.syncRemoval(.busy) {
                // The last look said no (opened, kept, in use, or no longer due): the book stays as a protected book
                // does, and the status line never counts it as waiting for its copy in iCloud Drive.
                unopenedHeld.remove(book.id)
            } catch {
                unopenedHeld.insert(book.id)
                // Said once for each book, and never with a title or a path (a package's names hold the title).
                if unopenedLogged.insert(book.id).inserted {
                    let reason = (error as? BookCloudError)?.logReason ?? "an unexpected error" // l10n: no (debug log text)
                    DiagnosticLog.event(.storage, "UNOPENED_DOWNLOAD_KEPT: book \(book.id.uuidString.prefix(8)): \(reason)")
                }
                // Files that did not match, or would not go, are looked at again tomorrow, not at each sync.
                if case .syncRemoval(let refusal)? = error as? BookCloudError, Self.isCostly(refusal) {
                    unopenedRetryTimes[book.id] = time.addingTimeInterval(SyncSpacePolicy.secondsInDay)
                }
            }
        }
        report.waiting = unopenedHeld.count
        guard !report.removed.isEmpty else { return report }
        refreshAfterRemoval()
        DiagnosticLog.event(.storage, "UNOPENED_DOWNLOADS_REMOVED: \(report.removed.count) removed after \(days) days")
        VoiceOverAnnouncer.announce(SyncWording.announceRemovedUnopened(books: report.removed.count, days: days))
        return report
    }

    /// The library's last word before a removal writes its pointer (`FreeingCheck`), asked on the main actor inside
    /// the removal's storage work, with the package about to change: the book is still in the library, and that
    /// package is still its own (a book moved to another folder meanwhile is not freed from its old place); nothing
    /// protects it now; sync is on and the library may change; no reader has it open; and, for a sweep, the book is
    /// still due (`stillDue`).
    ///
    /// A yes holds the book busy at once, in the same step, until its row says what came of the removal
    /// (`beginFreeing`, `endFreeing`): nothing the look asked about can begin between its answer and the files' going.
    private func finalCheck(
        for bookID: UUID,
        in library: LibraryViewModel,
        protecting isProtected: @escaping @MainActor @Sendable (Book) -> Bool,
        stillDue: (@MainActor @Sendable (Book) -> Bool)? = nil
    ) -> @MainActor @Sendable (URL) -> Bool {
        { [weak self, weak library] package in
            guard let self, let library, let book = library.bookByID(bookID) else { return false }
            guard BookPackage(book).url.standardizedFileURL.path == package.standardizedFileURL.path else { return false }
            guard self.states.syncIsOn, library.maySyncNow, !library.isBookOpenNow(bookID) else { return false }
            guard !isProtected(book) else { return false }
            if let stillDue, !stillDue(book) { return false }
            self.beginFreeing(bookID, in: library)
            return true
        }
    }

    /// Whether `book`, as the library holds it now, is still due to have its download removed by the settings as they
    /// are now: they still remove unopened downloads, and the book has gone unopened and unplayed for their days, counted
    /// from the latest of its opening, its play, `arrived` (its files' arrival, read before the proof), and the day the
    /// removal began. A book opened and closed while its copy was checked, or days made longer meanwhile, is not.
    private func isStillDue(_ book: Book, arrived: Date?) -> Bool {
        let settings = currentSettings()
        guard let days = settings.activeDays, let began = settings.removalsBeganAt else { return false }
        let lastInUse = SyncSpacePolicy.lastInUse(opened: book.lastOpened, played: book.lastPlaybackStopped, arrived: arrived, removalsBeganAt: began)
        return SyncSpacePolicy.isDue(lastInUse: lastInUse, days: days, now: now())
    }

    /// Holds the book `bookID` busy while its files go (`BooksBeingFreed`): the editors, an export, a transcription,
    /// and a sync's removal wait, and a reader's load waits for the package move it is bracketed as, then loads the
    /// book from wherever it is, as one opened during any package move does.
    private func beginFreeing(_ bookID: UUID, in library: LibraryViewModel) {
        guard !library.booksBeingFreed.contains(bookID) else { return }
        library.booksBeingFreed.begin(bookID)
        library.bookUpdates.packagesWillMove([bookID])
    }

    /// Ends what `beginFreeing` began for the book `bookID`, once its row says what came of the removal; nothing when
    /// the last look never said yes.
    private func endFreeing(_ bookID: UUID, in library: LibraryViewModel) {
        guard library.booksBeingFreed.contains(bookID) else { return }
        library.bookUpdates.packagesDidMove([bookID])
        library.booksBeingFreed.end(bookID)
    }

    /// Whether looking at a book again is costly enough (its files were hashed, or read back) that a refusal
    /// waits a day: the files differ or would not go. A copy not uploaded yet, or an offline device, costs
    /// nothing to look at again and is tried at the next sync.
    private static func isCostly(_ refusal: SyncRemovalRefusal) -> Bool {
        switch refusal {
        case .changedHere, .doesNotMatch, .couldNotRemove: return true
        case .notBackedUp, .missingFromFolder, .notUploaded, .uploadFailed, .offline, .needsDownload, .needsRoom,
             .folderUnreachable, .busy, .nothingToRemove:
            return false
        }
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
    ///
    /// A book whose size is unknown takes a pass of its own: the plan
    /// starts the first such book and puts the books after it off, then the
    /// task plans those again once that download has ended, reading the free
    /// space afresh, so a long list of books the drive gives no size for
    /// cannot fill the volume at once.
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
            var pending = candidates
            var isFirstPass = true
            var toldOfLaterShortfall = false
            while !pending.isEmpty, !Task.isCancelled {
                // Books put off waited through a whole download: the listener
                // may have cleared the choice, stopped keeping a book, or
                // taken it off the list meanwhile. The first pass is checked
                // already, by the command that started it.
                if !isFirstPass {
                    pending = pending.filter { isStillWanted($0, in: library, origin: origin) }
                }
                let plan = await planDownloads(of: pending)
                // The states may have moved on while the plan was read.
                let starting = plan.fits.filter(canStartDownload)
                let waiting = plan.deferred.filter(canStartDownload)
                // The listener hears of the whole list once, at its first
                // pass: the books put off start later, and say nothing then.
                announceReadingListDownloads(
                    starting: isFirstPass ? starting + waiting : starting,
                    short: plan.short,
                    origin: origin,
                    from: window
                )
                // A later pass that finds the room gone corrects that notice,
                // once, counting only the books it leaves out.
                if !isFirstPass, !toldOfLaterShortfall {
                    toldOfLaterShortfall = announceShortfallOfLaterPass(plan.short, origin: origin, from: window)
                }
                logBooksLeftOutForRoom(plan.short, starting: starting, origin: origin)
                if origin == .allBooks { roomNotice(plan.short.count) }
                await download(starting, in: library, from: window, origin: origin)?.value
                pending = waiting
                isFirstPass = false
            }
            booksBeingPlanned.subtract(candidateIDs)
        }
    }

    /// Whether the download of `book`, begun for `origin`, is still wanted:
    /// Download Now's books always; a refresh's and a keep's while the book
    /// is kept on this Mac for either reason; the reading list's add while
    /// the book is on the list and this Mac keeps the list's books.
    private func isStillWanted(_ book: Book, in library: LibraryViewModel, origin: DownloadOrigin) -> Bool {
        switch origin {
        case .downloadNow:
            return true
        case .keepOnThisMac, .keptBookRefresh:
            return kept.isKept(book.id)
        case .readingListAdd:
            return kept.keepsReadingListBooks && library.readingList.contains(book.id)
        case .allBooks:
            return booksChoice() == .allBooks
        }
    }

    /// Tells the listener, at medium priority, that the books of `short`
    /// that are the reading list's found no room, in the words of the first
    /// notice for a list none of whose books starts. The first notice counted
    /// the books it put off as downloading, so this one corrects it.
    /// - Returns: Whether a notice was said; nothing is for no list book.
    private func announceShortfallOfLaterPass(_ short: [Book], origin: DownloadOrigin, from window: PlatformWindow?) -> Bool {
        let listBooks = short.filter { origin == .readingListAdd || kept.isKeptForReadingList($0.id) }
        guard !listBooks.isEmpty else { return false }
        VoiceOverAnnouncer.announce(
            LibraryCloudWording.readingListDownloadsStarted(
                titles: [],
                short: listBooks.count,
                quietly: origin.isQuiet
            ),
            from: window,
            priority: .medium
        )
        return true
    }

    /// Which of `books` fit in the space free on the library's volume, in
    /// order, each taking what it still needs to download, less the reserve
    /// (`freeSpaceReserve`) that stays free; the rest are short of room.
    ///
    /// A book whose size is unknown takes nothing from the room, so with
    /// room above the reserve it starts, but the room that is left cannot be
    /// weighed until it has downloaded: the books after the first such book
    /// are put off (`deferred`), to be planned again then. Nothing is short
    /// when the volume's free space cannot be told. Reads off the main
    /// thread, and downloads nothing.
    private func planDownloads(of books: [Book]) async -> (fits: [Book], short: [Book], deferred: [Book]) {
        let storage = storage()
        let packages = books.map { BookPackage($0) }
        let root = TextMouthPaths.root
        let freeSpace = freeSpace
        let reads = await Task.detached(priority: .userInitiated) {
            (free: freeSpace(root), needs: packages.map { storage.bytesToDownload(of: $0) })
        }.value
        // nil: the volume cannot tell its free space, so every book fits.
        var room = reads.free.map { $0 - freeSpaceReserve }
        var fits: [Book] = []
        var short: [Book] = []
        var deferred: [Book] = []
        var unknownSizeStarted = false
        for (book, need) in zip(books, reads.needs) {
            if unknownSizeStarted {
                deferred.append(book)
            } else if let left = room, (need ?? 0) > left {
                short.append(book)
            } else {
                fits.append(book)
                room = room.map { $0 - (need ?? 0) }
                unknownSizeStarted = need == nil
            }
        }
        return (fits, short, deferred)
    }

    /// Logs each of `short`, the books left out of a plan for want of room,
    /// under DOWNLOAD_SKIPPED_NO_ROOM, whoever's they are (the reading
    /// list's, or books the listener keeps on this Mac): only the log tells
    /// of the listener's own, since VoiceOver hears of the list's alone. A
    /// book is logged once until it next starts (`starting`), so a refresh
    /// that finds it still short each minute adds no line.
    private func logBooksLeftOutForRoom(_ short: [Book], starting: [Book], origin: DownloadOrigin) {
        booksLoggedShortOfRoom.subtract(starting.map(\.id))
        for book in short where booksLoggedShortOfRoom.insert(book.id).inserted {
            DiagnosticLog.event(.storage, "DOWNLOAD_SKIPPED_NO_ROOM: \(origin.logSource): \(book.title)")
        }
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
                quietly: origin.isQuiet
            ),
            from: window,
            priority: .medium
        )
    }

    /// Notes how a download of the book `bookID` ended, for a kept book, or for any book when `origin` is `All books`: a
    /// failure makes refreshes wait `keptBookRetryDelay` before they try it
    /// again, and a success lets the next eviction be downloaded at once.
    private func noteKeptBookDownload(_ bookID: UUID, failed: Bool, origin: DownloadOrigin) {
        guard kept.isKept(bookID) || origin == .allBooks else { return }
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
        /// The setting `All books` (FR45): after a sync this device downloads each
        /// book it lacks, one at a time, quietly, as the rows show.
        case allBooks

        /// Whether the download itself tells VoiceOver which books start
        /// downloading, as Download Now does.
        var announcesStart: Bool {
            self == .downloadNow
        }

        /// Whether VoiceOver hears how the downloads ended.
        var announcesEnd: Bool {
            self != .keptBookRefresh && self != .allBooks
        }

        /// Whether the books' words, as the reading list's notice says them, are the quiet ones.
        var isQuiet: Bool {
            self == .keptBookRefresh || self == .allBooks
        }

        /// What the line of a book left out for want of room says started
        /// the plan, so the log tells a refresh's books from the list's adds.
        var logSource: String {
            switch self {
            case .downloadNow: return "Download Now"
            case .keepOnThisMac: return "Keep on This Mac"
            case .keptBookRefresh: return "refresh of kept books"
            case .readingListAdd: return "added to the reading list"
            case .allBooks: return "all books"
            }
        }

        /// The tags of the lines logged as the downloads start, as one of
        /// them fails, and once they have all ended. Each tag is spelled out
        /// whole, so a search of the source finds it.
        var logTags: (started: String, failed: String, finished: String) {
            switch self {
            case .downloadNow:
                return ("DOWNLOAD_NOW_STARTED", "DOWNLOAD_NOW_FAILED", "DOWNLOAD_NOW_FINISHED")
            case .keepOnThisMac, .keptBookRefresh, .readingListAdd, .allBooks:
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
        DiagnosticLog.event(.storage, "\(origin.logTags.started): \(titles.joined(separator: ", "))") // l10n: no (debug log, English)

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
        // "All books" goes on only while it is still the choice and the path does not cost: Wi-Fi lost, Low Data
        // Mode turned on, or the choice changed while earlier books downloaded, stops the books still queued.
        if origin == .allBooks, pathIsCostly() || booksChoice() != .allBooks {
            states.record(.inCloud, for: bookID)
            return nil
        }
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
            DiagnosticLog.event(.storage, "\(origin.logTags.failed): \(book.title): \(failure.logReason)")
            ending = .failed(title: book.title, explanation: explanation)
        }
        // A book removed from the library meanwhile has no row to tell.
        guard library.bookByID(bookID) != nil else { return nil }
        switch ending {
        case .downloaded:
            states.record(.downloaded, for: bookID)
            noteKeptBookDownload(bookID, failed: false, origin: origin)
        case .failed(_, let explanation):
            states.record(.downloadFailed(explanation), for: bookID)
            noteKeptBookDownload(bookID, failed: true, origin: origin)
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
            !booksBeingRemoved.contains(book.id) && states.canRemoveDownload(book)
        }
        guard !targets.isEmpty else { return nil }
        let targetIDs = Set(targets.map(\.id))
        booksBeingRemoved.formUnion(targetIDs)
        defer { booksBeingRemoved.subtract(targetIDs) }
        // A synced library's copy is in iCloud Drive, whichever folder the library is in.
        let provider = states.libraryLocation.provider ?? (states.syncIsOn ? .iCloudDrive : nil)
        let storage = storage()
        let syncIsOn = states.syncIsOn
        // Each book's package, or why its download stays without asking the
        // storage: the book is open in a reader, in use, or kept.
        let requests = targets.map { book -> Result<BookPackage, BookCloudError> in
            if library.isBookOpenNow(book.id) { return .failure(.bookIsOpen) }
            // In a synced library a book being exported, transcribed, edited,
            // or fetched keeps its files too, and a book kept on all devices.
            if syncIsOn {
                if library.isBookBusyForSync(book.id) { return .failure(.bookInUse) }
                if kept.isKeptOnAllDevices(book.id) { return .failure(.keptOnAllDevices) }
            }
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
            "REMOVE_DOWNLOAD_STARTED: \(targets.map(\.title).joined(separator: ", "))" // l10n: no (debug log, English)
        )

        // A person's command may download what it needs to prove the copy, but never over a connection that costs:
        // then it says the book waits for Wi-Fi. Each book is looked at again, with its protections, right before its
        // files go (`FreeingCheck`).
        let mayDownload = !pathIsCostly()
        let lastLooks = targets.map { finalCheck(for: $0.id, in: library, protecting: { [weak self] book in self?.isHeldByTheLibrary(book, in: library) ?? true }) }
        // A proof that takes a while says it is working, once.
        let working = syncIsOn ? Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { VoiceOverAnnouncer.announce(SyncWording.checkingTheCopy, from: window) }
        } : nil
        defer { working?.cancel() }
        // One book at a time, since a synced library's removal reads the book's copy back first (FR46) and
        // each waits on the network. Each book's row says In Cloud as soon as its own files are gone, which ends the
        // hold its last look began (`endFreeing`), so a book freed first is never held busy for the books after it.
        var failures: [BookCloudError?] = []
        for (request, lastLook) in zip(requests, lastLooks) {
            switch request {
            case .failure(let refusal):
                failures.append(refusal)
            case .success(let package):
                let failure = await Self.removeDownload(of: package, with: storage, mayDownload: mayDownload, syncIsOn: syncIsOn, lastLook: lastLook)
                if failure == nil { states.record(.inCloud, for: package.bookID) }
                endFreeing(package.bookID, in: library)
                failures.append(failure)
            }
        }
        working?.cancel()

        var removed: [String] = []
        var refused: [(title: String, explanation: String)] = []
        for (book, failure) in zip(targets, failures) {
            if let failure {
                let explanation = failure.explanation(in: provider)
                refused.append((title: book.title, explanation: explanation))
                DiagnosticLog.event(.storage, "REMOVE_DOWNLOAD_REFUSED: \(book.title): \(failure.logReason)")
            } else {
                removed.append(book.title)
                // Under "All books" the next sync would download it again: it stays freed until it is opened.
                if syncIsOn { freedOnPurpose().note(book.id, at: now()) }
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
        // Under "All books" the result says the book is not downloaded again until it is opened.
        let keepsEveryBook = syncIsOn && booksChoice() == .allBooks
        VoiceOverAnnouncer.announce(keepsEveryBook ? SentenceWording.joined([message, SyncWording.removedDownloadsAgainOnOpening]) : message, from: window)
        return nil
    }

    /// Removes one book's download for Remove Download, off the main thread (a cloud library's storage removes
    /// synchronously, and a synced library's reads the copy back), with the last look set for the storage to ask.
    /// - Returns: Why the download stayed; nil when it went. An error that is not the storage's own is the removal's
    ///   failure, never a download's, which `.provider` would say; in a synced library it is said in the app's own
    ///   words, never the system's, which can name a file.
    private nonisolated static func removeDownload(
        of package: BookPackage,
        with storage: any BookCloudStorage,
        mayDownload: Bool,
        syncIsOn: Bool,
        lastLook: @escaping @MainActor @Sendable (URL) -> Bool
    ) async -> BookCloudError? {
        await Task.detached(priority: .userInitiated) { () -> BookCloudError? in
            do {
                try await FreeingCheck.$current.withValue(lastLook) {
                    try await storage.removeDownloadAsync(of: package, mayDownload: mayDownload)
                }
                return nil
            } catch {
                return (error as? BookCloudError) ?? (syncIsOn ? .syncRemoval(.couldNotRemove("")) : .removalFailed(error.localizedDescription))
            }
        }.value
    }

    /// Whether the library holds `book` now, so that its download is not removed: it is kept (by the listener, the
    /// reading list, or on all devices), on the reading list, open, in use, or downloading.
    private func isHeldByTheLibrary(_ book: Book, in library: LibraryViewModel) -> Bool {
        library.isBookBusyForSync(book.id)
            || kept.isKept(book.id)
            || library.library.readingList.contains(book.id)
            || booksDownloading.contains(book.id)
    }
}

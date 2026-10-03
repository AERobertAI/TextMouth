import AppKit
import Combine
import Foundation

// MARK: - FR02 Cloud Library: the List's Side
//
// The library list shows each book's cloud state from `BookCloudStates`
// (see BookCloudNote.swift). `LibraryCloudRefresher` keeps that record
// current while a Library window is visible, and `LibraryCloudCommand`
// decides which cloud commands a book or a selection offers. Every read of
// the file system goes through `BookCloudStorage`, off the main thread.

extension LibraryViewModel {
    /// The package of every book in the library, as the cloud services see
    /// it (FR02). Making them reads no file.
    var cloudPackages: [BookPackage] {
        library.books.map(BookPackage.init)
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
}

// MARK: - Refresher

/// Keeps `BookCloudStates` current for the Library windows (FR02).
///
/// It refreshes when a Library window appears, when the app becomes active
/// while one is visible, after every change to where the library's books
/// are, and as `LibraryCloudRefreshCadence` says while one is visible. Each
/// refresh is one call to `BookCloudStates.refresh(_:using:)`, which reads
/// off the main thread. Refreshes never overlap: a request made while one
/// runs starts one more right after it, so the last refresh always reads
/// after the last request.
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
    /// Whether a refresh was requested while one ran.
    private var refreshRequestedWhileRunning = false
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

    /// Refreshes every book's cloud state now, or once more after the
    /// refresh that is running. Does nothing before a Library window has
    /// shown a library.
    func requestRefresh() {
        guard isEnabled, library != nil else { return }
        guard refreshing == nil else {
            refreshRequestedWhileRunning = true
            return
        }
        refreshing = Task { [weak self] in
            await self?.refreshUntilCurrent()
        }
    }

    /// Waits until the refreshes running or requested now have finished.
    func waitForRefreshes() async {
        await refreshing?.value
    }

    /// Refreshes back to back until no request is left, then lets the next
    /// request start a new run.
    private func refreshUntilCurrent() async {
        repeat {
            refreshRequestedWhileRunning = false
            guard let library else { break }
            await states.refresh(library.cloudPackages, using: storage())
        } while refreshRequestedWhileRunning
        refreshing = nil
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
    /// cancelled.
    private func startTimer(waiting interval: Duration) -> Task<Void, Never> {
        Task { [weak self, sleep] in
            while true {
                do {
                    try await sleep(interval)
                } catch {
                    return // Cancelled: a new cadence, or no window to refresh.
                }
                guard !Task.isCancelled, let self else { return }
                self.requestRefresh()
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

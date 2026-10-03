import SwiftUI
import Combine
import ZIPFoundation

enum LibrarySortField: String, CaseIterable, Codable {
    case title = "Title"
    case author = "Author"
    case dateAdded = "Date Added"
    case lastOpened = "Last Opened"
    case fileSize = "File Size"
    case manual = "Manual Order"

    var accessibilityLabel: String { rawValue }
}

enum LibraryCategory: String, CaseIterable, Codable {
    case folders = "Folders"
    case allItems = "All Items"
    case noFolder = "No Folder"
    case recent = "Recent"

    /// Key used to store per-category sort settings in folderSortSettings.
    /// Folder category uses the actual folder path; other categories use
    /// a reserved key that cannot collide with real folder paths.
    var sortSettingsKey: String? {
        switch self {
        case .folders:  return nil  // uses folder path instead
        case .allItems: return "__allItems__"
        case .noFolder: return "__noFolder__"
        case .recent:   return "__recent__"
        }
    }

    /// The default sort setting for this category when no user preference exists.
    var defaultSortSetting: FolderSortSetting {
        switch self {
        case .recent: return .recentDefault
        default:      return .defaultSort
        }
    }
}

/// App-level library data and operations.
/// Per-window navigation state (folder path, category, search) lives in the views.
@MainActor
final class LibraryViewModel: ObservableObject {
    /// Every change is offered to `bookUpdates`, which keeps the readers
    /// with a book open up to date with its row (TODO P10).
    @Published var library = Library() {
        didSet { bookUpdates.libraryDidChange(library) }
    }
    /// Tells open readers when the library changes or moves their book.
    let bookUpdates = LibraryBookUpdates()
    @Published var errorMessage: String?
    @Published var showError = false
    /// Book IDs currently open in a reader window
    @Published var openBookIDs: Set<UUID> = []
    /// Incremented periodically to force library views to refresh time estimates
    @Published var refreshTick: UInt = 0

    /// The questions imports are waiting to ask, one at a time and in the
    /// order they arose (TODO I01): whether to replace or keep a duplicate,
    /// whether to delete an original file, and whether to put a ZIP
    /// archive's books in a folder of their own. Only the import and
    /// question code in LibraryViewModel+Import and LibraryViewModel+Duplicates
    /// changes it; each Library window's question sheet shows its current
    /// question (`ImportDecisionPresenter`).
    @Published var importDecisions = ImportDecisionQueue()

    /// Book removal confirmation (supports single or multi-book removal)
    @Published var showRemoveBookDialog = false
    @Published var pendingRemoveBooks: [Book] = []

    /// Last folder path a book was moved to, used as default in move sheet
    @Published var lastMovedFolderPath: String = ""

    /// Folder deletion dialogs
    @Published var showDeleteFolderDialog = false
    @Published var pendingDeleteFolder: BookFolder?
    @Published var showDeleteFolderDestinationSheet = false
    @Published var showDeleteEverythingConfirm = false

    /// Import progress tracking
    @Published var isImporting = false
    @Published var importProgressCurrent = 0
    @Published var importProgressTotal = 0
    @Published var importProgressMessage = ""
    let importOperationQueue = SerialImportQueue()
    /// Opens a book's reader window, as an import that was asked to open its
    /// book does once the book is in the library. The app posts
    /// `.openBookWindow`, which the window router hands to one window (TODO
    /// A05); tests replace it to see which book an import opens without
    /// opening a window.
    var readerOpener: @MainActor (UUID) -> Void = { bookID in
        NotificationCenter.default.post(name: .openBookWindow, object: bookID)
    }

    /// Text extraction progress tracking (for startup cache generation and re-extraction)
    @Published var isExtracting = false
    @Published var extractionProgressCurrent = 0
    @Published var extractionProgressTotal = 0
    @Published var extractionProgressMessage = ""

    /// Set while library.json exists but cannot be read. The library shown is
    /// then provisional and index writes are suspended. Only the recovery
    /// actions in LibraryViewModel+IndexRecovery change it.
    @Published var indexRecovery: LibraryIndexRecovery?
    /// Presents the index recovery options (a sheet in the library window).
    @Published var showIndexRecoveryOptions = false

    /// Why the data directory can't be used, while it can't (FR02): at
    /// launch, the library is neither loaded nor created; after a loss,
    /// nothing more is saved there. Every Library window shows the Library
    /// Not Available screen while it is set. Only the data-directory
    /// functions at the end of this file change it.
    @Published private(set) var dataDirectoryUnavailability: DataDirectoryUnavailability?
    /// A sentence about the last app-wide action refused while the library
    /// is unavailable, such as opening a book from Finder, for the Library
    /// Not Available screen; nil when there is none.
    @Published var dataDirectoryRefusalNotice: String?
    /// The data-directory move under way, while one copies the library
    /// (FR02): every Library window shows its progress in a sheet that
    /// keeps the library from changing meanwhile, and Storage settings show
    /// it too. Only the data-directory move in LibraryViewModel+Migration
    /// sets it.
    @Published var dataDirectoryMove: DataDirectoryMoveProgress?

    /// False for the inert model used by previews and tests, which never
    /// starts disk maintenance, observers, or background analysis by itself.
    let runsBackgroundWork: Bool
    /// What the data-directory check and the session lease work with: the
    /// app's preferences, volume notifications, and lease, or a test's.
    let dataDirectoryEnvironment: DataDirectoryEnvironment
    /// Whether the startup the launch check defers has run: at launch, or
    /// on the Try Again that first found the library.
    private(set) var hasStartedLibrary = false
    /// The data directory the last check found the library in, which an
    /// unmount or a failed write may take away; nil until one is found.
    private(set) var availableDataDirectory: DataDirectoryLocation?
    /// The reason last announced to VoiceOver, so each is announced once.
    private(set) var announcedUnavailability: DataDirectoryUnavailability?

    /// Combine subscriptions shared across extension files
    var cancellables = Set<AnyCancellable>()
    /// Owns the main-run-loop timer through a handle that can cancel from any thread.
    var refreshTimer: LibraryRefreshTimer?
    /// Shared config service used across extension files. Reached when
    /// first needed rather than when the model is made, so config.json is
    /// never read before the launch check has found the library (FR02).
    var configService: ConfigService { .shared }

    /// An inert model lets previews and lifecycle tests opt out of disk migration,
    /// observers, and background maintenance; the app uses the default startup.
    /// - Parameter dataDirectoryEnvironment: Where the data-directory check
    ///   reads this Mac's expectations and hears of unmounted volumes: the
    ///   app's, unless a test passes its own.
    init(initializeServices: Bool = true, dataDirectoryEnvironment: DataDirectoryEnvironment = .app) {
        runsBackgroundWork = initializeServices
        self.dataDirectoryEnvironment = dataDirectoryEnvironment
        guard initializeServices else { return }
        // Migrate from old sandbox container if needed (before loading library)
        migrateFromSandboxContainer()

        observeDataDirectoryLoss()
        // Nothing is created or loaded until the library is known to be
        // there (FR02). Otherwise the Library windows say why, and Try
        // Again runs the startup once the library is back.
        if checkDataDirectory() {
            startLibrary()
        }
    }

    /// The startup the launch check defers until the library is there (FR02):
    /// the directory structure, the library's identity, the sweep of what
    /// interrupted imports left, the index with its repair, the observers,
    /// and the background maintenance. It runs once: at launch, or on the
    /// Try Again that first finds the library.
    func startLibrary() {
        guard !hasStartedLibrary else { return }
        hasStartedLibrary = true

        // Ensure directory structure exists on first launch
        try? TextMouthPaths.ensureDirectoryStructure()
        recordLibraryIdentity()
        // Clear what ZIP imports interrupted by a crash left extracted.
        removeLeftoverArchiveExtractions()

        // Load the index and run the startup repair; an unreadable index
        // enters recovery with a provisional library and saves nothing.
        loadLibraryIndex()
        setupDataDirectoryChangeHandler()
        importOperationQueue.onActivityChanged = { [weak self] activeCount in
            guard let self else { return }
            self.isImporting = activeCount > 0
            if activeCount == 0 {
                self.importProgressCurrent = 0
                self.importProgressTotal = 0
                self.importProgressMessage = ""
            }
        }
        startRefreshTimer()
        updateContentCachesAndStatistics()
        // In a library another Mac can open, say this Mac has it open.
        dataDirectoryEnvironment.sessionLease?.begin()
    }

    deinit {
        // Background analysis can release the final reference. The handle moves
        // timer cleanup to its owning thread without capturing this dying model.
        refreshTimer?.invalidate()
    }

    // MARK: - Book Update Helpers

    /// Find a book by ID, apply a mutation, then save and persist.
    /// Centralizes the repeated find-index -> mutate -> save -> persist pattern.
    func updateBook(id: UUID, _ mutate: (inout Book) -> Void) {
        guard let index = library.books.firstIndex(where: { $0.id == id }) else { return }
        mutate(&library.books[index])
        save()
        LibraryPersistenceService.saveBookInfo(for: library.books[index])
    }

    // MARK: - Persistence

    /// Save the library index, debounced to avoid rapid repeated writes.
    /// Position updates happen very frequently; this coalesces them.
    func save() {
        LibraryPersistenceService.save(library)
    }

    /// Route externally edited config paths through the same validated migration
    /// workflow as the Storage settings UI.
    func setupDataDirectoryChangeHandler() {
        NotificationCenter.default.publisher(for: .dataDirectoryChangeRequested)
            .compactMap { $0.userInfo?["path"] as? String }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] path in
                guard let self else { return }
                let target = path.isEmpty
                    ? TextMouthPaths.defaultRoot
                    : URL(fileURLWithPath: path, isDirectory: true)
                self.moveDataDirectory(to: target)
            }
            .store(in: &cancellables)
    }

}

// MARK: - Data Directory Availability (FR02)

/// What the library model's data-directory check works with: the app's
/// own preferences, the workspace's volume notifications, and the session
/// lease, or a test's.
struct DataDirectoryEnvironment {
    /// The store naming the data directory and the library expected there.
    var preferences: UserDefaults
    /// Where volume unmounts are announced: the workspace's notification
    /// center in the app.
    var volumeNotifications: NotificationCenter
    /// The note in a library other Macs can open that this Mac has it open
    /// (`LibrarySessionLease`), held while the library is open; nil holds
    /// none.
    var sessionLease: LibrarySessionLease?

    /// An environment of a test's own, holding no session lease unless it
    /// passes one.
    init(preferences: UserDefaults, volumeNotifications: NotificationCenter, sessionLease: LibrarySessionLease? = nil) {
        self.preferences = preferences
        self.volumeNotifications = volumeNotifications
        self.sessionLease = sessionLease
    }

    /// The app's: this process's preferences, the shared workspace, and the
    /// shared session lease.
    @MainActor static var app: DataDirectoryEnvironment {
        DataDirectoryEnvironment(
            preferences: TextMouthRuntime.current.preferences,
            volumeNotifications: NSWorkspace.shared.notificationCenter,
            sessionLease: .shared
        )
    }
}

extension LibraryViewModel {

    // MARK: Checking

    /// Checks the data directory and makes what it finds the model's state:
    /// the gate that lets writers in or keeps them out, the reason the
    /// Library windows show, and, when the bookmark found the library under
    /// another path, the data directory itself. Returns whether the library
    /// is available.
    @discardableResult
    func checkDataDirectory() -> Bool {
        let preferences = dataDirectoryEnvironment.preferences
        let root = TextMouthPaths.root
        let outcome = DataDirectoryCheck.of(root: root, preferences: preferences)
            .run(itemStatus: CloudServices.itemStatus)
        switch outcome {
        case .available(_, let relocated):
            if let relocated {
                useRelocatedDataDirectory(relocated, foundFor: root)
            }
            let current = TextMouthPaths.root
            DataDirectoryGate.open(current)
            availableDataDirectory = DataDirectoryLocation(current)
            if dataDirectoryUnavailability != nil {
                DiagnosticLog.event(
                    .storage,
                    "DATA_DIRECTORY_AVAILABLE: the library is back in \(DataDirectoryPaths.shortName(of: current))"
                )
                dataDirectoryUnavailability = nil
                dataDirectoryRefusalNotice = nil
            }
            return true
        case .unavailable(let reason):
            DataDirectoryGate.close(root)
            if reason != dataDirectoryUnavailability {
                DiagnosticLog.event(.storage, "DATA_DIRECTORY_UNAVAILABLE: \(reason.logDescription)")
                dataDirectoryUnavailability = reason
            }
            return false
        }
    }

    /// Makes `folder`, where the bookmark found the library last named
    /// `root`, the data directory: the preferences name it, with a fresh
    /// bookmark, and the next storage generation starts there, between the
    /// persistence queues' writes, before anything is loaded or saved.
    private func useRelocatedDataDirectory(_ folder: URL, foundFor root: URL) {
        let line = TextMouthPaths.recordRelocation(from: root, to: folder, in: dataDirectoryEnvironment.preferences)
        LibraryPersistenceService.betweenWrites {
            StorageBoundary.shared.publish(root: folder)
        }
        DiagnosticLog.event(.storage, line)
    }

    /// Records which library this is, as it opens (FR02): a library without
    /// an identity, from before identities came in or just created, is given
    /// one; the identity becomes the one this Mac expects; and a custom data
    /// directory without a bookmark, chosen before bookmarks came in, gets
    /// one. A failure is logged and changes nothing: the next opening tries
    /// again.
    func recordLibraryIdentity() {
        let root = TextMouthPaths.root
        let preferences = dataDirectoryEnvironment.preferences
        do {
            let adopted = try LibraryIdentity.adopt(in: root)
            if adopted.isNew {
                DiagnosticLog.event(
                    .storage,
                    "LIBRARY_IDENTITY: gave the library in \(DataDirectoryPaths.shortName(of: root)) "
                        + "the identity \(adopted.identity.id.uuidString)"
                )
            }
            DataDirectoryPreferences.expectedIdentity.write(adopted.identity.id, to: preferences)
        } catch {
            DiagnosticLog.event(
                .storage,
                "LIBRARY_IDENTITY: could not record the identity of the library in "
                    + "\(DataDirectoryPaths.shortName(of: root)): \(error.localizedDescription)"
            )
        }
        if !TextMouthPaths.isDefaultLocation(root), DataDirectoryPreferences.bookmark.read(from: preferences) == nil {
            DataDirectoryPreferences.bookmark.write(DataDirectoryPreferences.makeBookmark(of: root), to: preferences)
        }
    }

    // MARK: Try Again

    /// Try Again on the Library Not Available screen (FR02): checks the data
    /// directory again and, when the library is there, starts it: the whole
    /// startup when it was unavailable at launch, or, after it was lost while
    /// TextMouth ran, a fresh read of library.json that carries this
    /// session's reading progress into it, then the repair and the saves
    /// that waited. Services that left their files unread are told to read
    /// them. VoiceOver hears how it went.
    /// - Returns: Whether the library is available now.
    @discardableResult
    func retryDataDirectory() -> Bool {
        guard dataDirectoryUnavailability != nil else { return true }
        guard checkDataDirectory() else {
            if let reason = dataDirectoryUnavailability {
                announcedUnavailability = reason
                VoiceOverAnnouncer.announce("The library is still not available. \(reason.explanation)")
            }
            return false
        }
        if hasStartedLibrary {
            reloadLibraryAfterDataDirectoryReturned()
            dataDirectoryEnvironment.sessionLease?.begin()
        } else {
            startLibrary()
        }
        announcedUnavailability = nil
        NotificationCenter.default.post(name: .dataDirectoryDidBecomeAvailable, object: nil)
        VoiceOverAnnouncer.announce("The library is available.")
        return true
    }

    // MARK: The Library Not Available Screen

    /// Tells VoiceOver why the library can't be used, once for each reason,
    /// however many Library windows show the screen (FR02). The screen asks
    /// for this once VoiceOver has moved to the reason.
    func announceDataDirectoryUnavailability(from window: NSWindow? = nil) {
        guard let reason = dataDirectoryUnavailability, reason != announcedUnavailability else { return }
        announcedUnavailability = reason
        VoiceOverAnnouncer.announce(DataDirectoryUnavailableText.announcement(for: reason), from: window)
    }

    /// Refuses an app-wide action that needs the library while it can't be
    /// used (FR02), such as a book opened from Finder: the Library Not
    /// Available screen shows `refusal`, and VoiceOver hears it.
    func refuseWhileDataDirectoryUnavailable(_ refusal: String, from window: NSWindow? = nil) {
        dataDirectoryRefusalNotice = refusal
        VoiceOverAnnouncer.announce(refusal, from: window)
    }

    // MARK: Losing the Data Directory

    /// Starts listening for what can take the data directory away while
    /// TextMouth runs: an unmounted volume, and a write that found the
    /// folder gone (`LibraryPersistenceService`).
    func observeDataDirectoryLoss() {
        dataDirectoryEnvironment.volumeNotifications.publisher(for: NSWorkspace.didUnmountNotification)
            .compactMap { $0.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] volume in self?.volumeDidUnmount(volume) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .dataDirectoryWriteFoundFolderMissing)
            .compactMap { $0.userInfo?[DataDirectoryEvents.rootKey] as? String }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] root in self?.dataDirectoryMayHaveVanished(at: root) }
            .store(in: &cancellables)
    }

    /// Checks the data directory again when the volume mounted at `volume`
    /// held it, by its name or by the folder a link leads to.
    func volumeDidUnmount(_ volume: URL) {
        guard let available = availableDataDirectory else { return }
        let volumePath = volume.standardizedFileURL.path
        let isOnVolume = [available.named.path, available.real.path].contains {
            $0 == volumePath || $0.hasPrefix(volumePath + "/")
        }
        guard isOnVolume else { return }
        DiagnosticLog.event(
            .storage,
            "DATA_DIRECTORY_UNMOUNTED: the volume \(volume.lastPathComponent) holding the library was unmounted"
        )
        dataDirectoryMayHaveVanished()
    }

    /// Checks the data directory again after something suggested it is gone
    /// (FR02). When it is, saving stops: index writes wait behind the gate,
    /// and record writes that fail stay listed for a retry. The Library
    /// windows then show the Library Not Available screen, and Try Again
    /// resumes. A report about another data directory, such as one this
    /// process no longer uses, changes nothing.
    /// - Parameter root: The data directory a write found missing, or nil
    ///   for the one in use.
    func dataDirectoryMayHaveVanished(at root: String? = nil) {
        guard hasStartedLibrary, dataDirectoryUnavailability == nil, let available = availableDataDirectory else {
            return
        }
        if let root, URL(fileURLWithPath: root).standardizedFileURL.path != available.named.path {
            return
        }
        guard !checkDataDirectory() else { return }
        // Its folder may be gone: the lease ages out unless Try Again
        // resumes it.
        dataDirectoryEnvironment.sessionLease?.pause()
        DiagnosticLog.event(.storage, "DATA_DIRECTORY_LOST: stopped saving until the library is back")
    }
}

/// Keeps a Timer on the main run loop while allowing its owner to die on a worker
/// queue. Global-actor isolation makes this handle Sendable; the Timer itself is
/// accessed only on the thread where it was scheduled.
@MainActor
final class LibraryRefreshTimer {
    let timer: Timer

    /// Wrap a timer that was created on the main actor.
    init(timer: Timer) {
        self.timer = timer
    }

    /// Cancel immediately on the main thread, or keep just this handle alive until
    /// the main queue can cancel. Repeated cancellation is safe for Foundation timers.
    nonisolated func invalidate() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { timer.invalidate() }
        } else {
            DispatchQueue.main.async { self.timer.invalidate() }
        }
    }
}

extension Notification.Name {
    static let openBookWindow = Notification.Name("openBookWindow")
}

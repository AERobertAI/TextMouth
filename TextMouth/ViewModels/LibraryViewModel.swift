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
    @Published var library = Library()
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

    /// False for the inert model used by previews and tests, which never
    /// starts disk maintenance, observers, or background analysis by itself.
    let runsBackgroundWork: Bool

    /// Combine subscriptions shared across extension files
    var cancellables = Set<AnyCancellable>()
    /// Owns the main-run-loop timer through a handle that can cancel from any thread.
    var refreshTimer: LibraryRefreshTimer?
    /// Shared config service used across extension files
    let configService = ConfigService.shared

    /// An inert model lets previews and lifecycle tests opt out of disk migration,
    /// observers, and background maintenance; the app uses the default startup.
    init(initializeServices: Bool = true) {
        runsBackgroundWork = initializeServices
        guard initializeServices else { return }
        // Migrate from old sandbox container if needed (before loading library)
        migrateFromSandboxContainer()

        // Ensure directory structure exists on first launch
        try? TextMouthPaths.ensureDirectoryStructure()
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

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

/// The views of the library a Library window shows, as its View picker
/// names them, in the picker's order. Folders shows one folder at a time;
/// the others list books from every folder: all of them, those never
/// opened, those opened lately, and those in the reading list. Unopened
/// replaced No Folder, which listed the root's books; Folders still lists
/// those at the root. Recently Opened was called Recent until FR13.
enum LibraryCategory: String, CaseIterable, Codable {
    case folders = "Folders"
    case allItems = "All Items"
    /// Every book never opened, from every folder, and the feeds with items
    /// not yet played.
    case unopened = "Unopened"
    /// The books opened last, newest first, and of each feed's episodes
    /// and articles the one opened last (FR11): named for what it lists,
    /// as the listener asked on October 9, 2026 (FR13).
    case recent = "Recently Opened"
    /// The reading list (FR09): books from any folder, in the order the
    /// user arranges, which no sort changes.
    case readingList = "Reading List"

    /// What the category Unopened replaced was called. A category saved
    /// under that name reads as Unopened.
    static let formerNoFolderName = "No Folder"
    /// What Recently Opened was called until FR13. A category saved under
    /// that name reads as Recently Opened, and is saved under its new name
    /// from then on; its sort is kept under the same key (`__recent__`).
    static let formerRecentName = "Recent"
    /// The key that category's sort was saved under. It is read as the
    /// Unopened sort until one is chosen at Unopened (`Library.sortSetting(at:)`)
    /// and never written, and no folder can take it as a name.
    static let formerNoFolderSortSettingsKey = "__noFolder__"

    /// Key used to store per-category sort settings in folderSortSettings.
    /// Folder category uses the actual folder path; other categories use
    /// a reserved key that cannot collide with real folder paths. The
    /// Reading List's is reserved too, though no sort is ever saved under
    /// it: the list keeps its own order (`LibraryLocation.keepsItsOwnOrder`).
    var sortSettingsKey: String? {
        switch self {
        case .folders:     return nil  // uses folder path instead
        case .allItems:    return "__allItems__"
        case .unopened:    return "__unopened__"
        case .recent:      return "__recent__"
        case .readingList: return "__readingList__"
        }
    }

    /// The default sort setting for this category when no user preference
    /// exists: newest first for Recent (by last opened) and for Unopened (by
    /// date added, since no unopened book has been opened), the list's own
    /// order for the Reading List, which is its only one, and title
    /// ascending elsewhere.
    var defaultSortSetting: FolderSortSetting {
        switch self {
        case .recent:      return .recentDefault
        case .unopened:    return .unopenedDefault
        case .readingList: return .readingListOrder
        default:           return .defaultSort
        }
    }

    /// Reads a category by the name it was saved under: its own name, or a
    /// former one, "No Folder" for Unopened, which replaced it, and "Recent"
    /// for Recently Opened (FR13); nil for any other name. The decoder and
    /// the Library views' stored identities (`LibraryViewID`) read names
    /// this one way, so nothing saved under an old name fails to load.
    init?(savedName name: String) {
        if let category = LibraryCategory(rawValue: name) {
            self = category
        } else if name == Self.formerNoFolderName {
            self = .unopened
        } else if name == Self.formerRecentName {
            self = .recent
        } else {
            return nil
        }
    }

    /// Reads a saved category by its name (`init(savedName:)`), so nothing
    /// saved under an old name fails to load. Saving still writes the name
    /// itself.
    init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        guard let category = LibraryCategory(savedName: name) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "No library category is named \(name)."
            ))
        }
        self = category
    }
}

/// App-level library data and operations.
/// Per-window navigation state (folder path, category, search) lives in the views.
@MainActor
final class LibraryViewModel: ObservableObject {
    /// Every change is offered first to `listCache`, so no Library window
    /// reads a list derived from the library before it (TODO PERF10), then
    /// to `bookUpdates`, which keeps the readers with a book open up to date
    /// with its row (TODO P10).
    @Published var library = Library() {
        didSet {
            listCache.libraryDidChange(from: oldValue, to: library)
            bookUpdates.libraryDidChange(library)
        }
    }
    /// The lists Library windows show, each derived once and kept until a
    /// change it depends on (TODO PERF10); read through
    /// `displayedBooks(at:matching:)` and `bookCount(inFolderTree:)`.
    let listCache = LibraryListCache()
    /// Tells open readers when the library changes or moves their book.
    let bookUpdates = LibraryBookUpdates()
    /// The reading list (FR09), as the library holds it: its books in
    /// reading order and its options. Changed only through the functions in
    /// LibraryViewModel+ReadingList, each of which saves the index.
    var readingList: ReadingList {
        library.readingList
    }
    /// How many rows this TextMouth cannot read and keeps as they are
    /// (V03): books a newer TextMouth added, those of library.json and
    /// those of every feed's index (`Library.unreadableRowCount`). Storage
    /// settings say so.
    var booksNeedingNewerTextMouth: Int {
        library.unreadableRowCount
    }
    /// The books the reading list's Skip Finished Books passes over (FR09):
    /// those Books Finished counts (`ReadingStats.finishedBookIDs`), which a
    /// book joins when it is played or read to its end and stops there or
    /// continues to the next book (`ReadingStatsService.markBookFinished`).
    /// That is a deliberate record, unlike a position near the end, which
    /// may be saved short of it (P07); a book counted once stays counted,
    /// even when read again. Tests give their own.
    var finishedBookIDs: @MainActor () -> Set<UUID> = { ReadingStatsService.shared.stats.finishedBookIDs }
    /// Where readers are between checkpoints (TODO PERF11), which the rows
    /// and the summary bar show: `updateLiveReadingPosition` reports there
    /// instead of changing the library, so a playing reader no longer
    /// publishes this model once a second.
    let livePositions = LiveReadingPositions()
    @Published var errorMessage: String?
    /// The library alert's title, or nil for "Error", which most of its
    /// messages are. An import that ends without bringing anything in, and
    /// without failing, has a title of its own (October 13, 2026).
    @Published var errorTitle: String?
    /// Whether the library alert shows. Once it closes, however it is
    /// closed, the title goes back to "Error", so the next alert, raised
    /// anywhere, is never given a title meant for another.
    @Published var showError = false {
        didSet {
            if !showError { errorTitle = nil }
        }
    }
    /// Book IDs currently open in a reader window. A book that leaves it
    /// drops its live position (TODO PERF11): its reader saved its position
    /// to the library as it closed, and the row shows that one again. The
    /// audio editing activity follows them, so the original policy never
    /// deletes an open book's original (FR04).
    @Published var openBookIDs: Set<UUID> = [] {
        didSet {
            livePositions.keepOnly(openBookIDs)
            audioEditActivity.setOpenInReaders(openBookIDs)
        }
    }
    /// How many readers are open for each book, from `registerOpenBook` to
    /// `unregisterOpenBook`: a book stays in `openBookIDs` until its last reader
    /// closes, since two windows may show one book.
    var openReaderCounts: [UUID: Int] = [:]
    /// Which books' audio is in use in a way an original must stay for:
    /// open in a reader (mirrored from `openBookIDs`), or being edited or
    /// rendered (FR04, `AudioOriginalSweep`).
    let audioEditActivity = AudioEditActivity()
    /// The books being edited with Edit Text, whose feed downloads the
    /// feeds' rules leave for their next pass (`feedBooksInUse`): the app's
    /// sessions, unless a test gives the model sessions of its own.
    var textEditSessions: BookTextEditSessions = .shared
    /// Which engine runs the filters of audio edits: the installed ffmpeg or
    /// TextMouth's own, as the setting and this Mac say (FR04); a test can
    /// choose one, so its results never depend on what this Mac has.
    var audioFilterEngine: () -> AudioFilterEngine = { AudioFilterEngine.current() }

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

    /// Whether any import is queued or running, which shows the import
    /// overlay in every Library window.
    @Published var isImporting = false
    /// What the import overlay shows: an object of its own, which only the
    /// overlay observes, so the many reports of a ZIP batch never redraw
    /// the Library windows' lists (FR10, as TODO PERF12 did for the text
    /// extraction's progress).
    let importProgress = ImportProgress()
    let importOperationQueue = SerialImportQueue()
    /// Opens a book's reader window, as an import that was asked to open its
    /// book does once the book is in the library. The app posts
    /// `.openBookWindow`, which the window router hands to one window (TODO
    /// A05); tests replace it to see which book an import opens without
    /// opening a window.
    var readerOpener: @MainActor (UUID) -> Void = { bookID in
        NotificationCenter.default.post(name: .openBookWindow, object: bookID)
    }
    /// Whether an import offers to transcribe the book it added (FR05):
    /// the setting and this Mac's system decide (`TranscriptionOffers`);
    /// tests replace it to offer without either.
    var offersTranscription: @MainActor (Book) -> Bool = { TranscriptionOffers.offersTranscription(of: $0) }
    /// Removes the package of a book Replace Existing replaced, once the new
    /// copy is committed (ST04), to the Trash when the flag is true and for
    /// good otherwise (`DuplicateReplacement.removeReplacedPackage`); tests
    /// replace it to make the removal fail.
    var removesReplacedPackage: @MainActor (Book, Bool) throws -> Void = { book, movesToTrash in
        try DuplicateReplacement.removeReplacedPackage(of: book, movesToTrash: movesToTrash)
    }
    /// The Edit Text editor whose session of a replaced book ends, saying
    /// so (ST04): the app's, made only when a session is to end; tests give
    /// their own, with the sessions they give `textEditSessions`.
    var bookTextEditor: @MainActor () -> BookTextEditor = { BookTextEditor.shared }
    /// The re-reads in another encoding under way, app-wide, which a quit
    /// waits for (`TextRereads`): the app's, unless a test gives its own.
    var textRereads: TextRereads = .shared
    /// The books whose text is being read again in another encoding, with
    /// other braille file characters, or with another braille code, or whose
    /// copy Replace Existing is replacing, from the moment the listener confirms
    /// until the library row has the new reading
    /// (`readTextAgain(bookID:choosing:access:)`, encodingchoice and
    /// braillecodes), kept in
    /// `textRereads`. What would rewrite such a book's text meanwhile waits
    /// for it, each asking `readingAgainRefusal(of:)`: a second re-read of
    /// it, from either Book Information, Edit Text, Redo Text Extraction
    /// (review of October 24, finding 3), and Replace Existing.
    var booksBeingReadAgain: Set<UUID> {
        get { textRereads.bookIDs }
        set { textRereads.bookIDs = newValue }
    }
    /// The offers to transcribe that the user accepted (FR05), for the
    /// Library window that asked to open the Transcribe Audio sheet.
    let acceptedTranscriptionOffers = PassthroughSubject<TranscriptionOfferAcceptance, Never>()

    /// The text extraction batch's progress (startup cache generation and
    /// re-extraction), an object of its own so that each finished book
    /// redraws only the views showing it, never this model's observers
    /// (TODO PERF12).
    let textExtraction = TextExtractionProgress()
    /// The conversion of the library's Ogg audio to AAC (B06): which book
    /// converts, which its reader refuses to play, and how far it has got,
    /// which the Library window's overlay shows.
    let oggConversion = OggConversionProgress()
    /// Whether a text extraction batch runs; a second is refused meanwhile.
    var isExtracting: Bool {
        textExtraction.isExtracting
    }
    /// Whether the metadata refresh runs
    /// (`refreshOutdatedMetadata(access:then:)`); a second is refused
    /// meanwhile.
    var isRefreshingMetadata = false
    /// Finished books' analysis summaries, on their way to `library`
    /// together: in one change and one save at most every half second, at
    /// the end of each pass, and at quit (TODO PERF12).
    private(set) lazy var analysisSummaries = ContentAnalysisSummaryBuffer { [weak self] summaries in
        self?.applyAnalysisSummaries(summaries)
    }

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
    /// The files the last check named as only in the cloud, which the fetch
    /// reads next (`LibraryFileFetch`); empty when the check named none.
    var pendingLibraryFiles: [URL] = []
    /// The fetch of those files while one runs (LibraryViewModel+LibraryFetch);
    /// nil otherwise, so a second never starts beside it.
    var libraryFetchTask: Task<Void, Never>?
    /// Names the running fetch: a fetch whose token is no longer this one's
    /// drops its results.
    var libraryFetchToken: UUID?
    /// The data directory's path the running fetch works for.
    var libraryFetchRoot: String?
    /// The standardized paths of the files whose fetch reads were started
    /// and have not returned, including those of a fetch that gave up on a
    /// stuck read: none is read again meanwhile, so no threads pile up.
    var libraryFilesBeingRead: Set<String> = []
    /// The slots that cap the fetch reads in flight, for the library's
    /// fetch and the launch files alike.
    let libraryFetchReadSlots = LibraryFetchReadSlots()
    /// Whether the user chose another library: this process is about to be
    /// replaced, so nothing opens in it, and the Library window says which
    /// book it was asked to open that will not be. Cleared if TextMouth can't
    /// open again.
    @Published var librarySwitchPending = false
    /// The waits before the retries of a fetch whose reads fail or bring
    /// nothing: a sync service that isn't up yet just after a restart often
    /// is within half a minute.
    var libraryFetchRetryDelays = LibraryViewModel.defaultLibraryFetchRetryDelays
    /// How long a fetch waits for its reads before it shows the failure.
    var libraryFetchStallLimit: Duration = BookCloudStorageService.defaultStallLimit
    /// Whether this Mac is online, which a stalled fetch's log line says.
    var libraryFetchReachability: NetworkReachability = .system
    /// The Library window that last announced the Library Not Available
    /// screen, which then announces that the library is available, since
    /// an announcement needs a window to come from.
    weak var unavailabilityWindow: PlatformWindow?
    /// What the services that read the library's small launch files are told
    /// when each has been fetched from the cloud (`fetchLaunchFilesInBackground`):
    /// the app's services, unless a test passes recorders.
    var launchFileTakeUp = LibraryLaunchFileTakeUp.app

    /// The feed engine whose feeds' items this library lists in their feeds'
    /// folders (FR11): the app's (`FeedCenter.shared`) while nil, or the one
    /// a test starts in this library, as `FeedTestWorld` does (`feeds`).
    var feedEngine: FeedCenter?
    /// Each feed's rows by item, and the library's books by ID, worked out
    /// once for each change of the library (FR11, branch A2): what the feed
    /// engine's counts and states find rows through
    /// (`feedItemRows(of:)`, `feedBook(withID:)`).
    let feedItemRowLookup = FeedItemRowLookup()

    /// Combine subscriptions shared across extension files
    var cancellables = Set<AnyCancellable>()
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
    /// interrupted imports left and of the reading texts this Mac kept that
    /// went unused for a day, the index with its repair, the sweep of the
    /// recordings' original takes whose time is up and of the audio
    /// editor's caches a crash left, the observers, and the background
    /// maintenance, after which the finished books are put at their ends
    /// once (`moveFinishedBooksToTheirEndsOnce`, TODO P07). It runs once: at
    /// launch, or on the Try Again that first finds the library.
    func startLibrary() {
        guard !hasStartedLibrary else { return }
        hasStartedLibrary = true

        // Ensure directory structure exists on first launch
        try? TextMouthPaths.ensureDirectoryStructure()
        recordLibraryIdentity()
        // Clear what ZIP imports interrupted by a crash left extracted.
        removeLeftoverArchiveExtractions()
        // Clear the reading texts this Mac kept that went unused for a day,
        // off the main thread; they are this Mac's own, never in the cloud.
        ReadingTextCache.shared.removeExpiredInBackground()

        // Load the index and run the startup repair; an unreadable index
        // enters recovery with a provisional library and saves nothing.
        loadLibraryIndex()
        setupDataDirectoryChangeHandler()
        // Delete the originals of recordings and edited audiobooks whose
        // time is up, off the main thread, downloading nothing (FR04).
        sweepAudioOriginalsInBackground()
        // Clear what the audio editor left in this Mac's caches when
        // TextMouth last ended with editors open, off the main thread.
        removeStaleAudioEditCachesInBackground()
        // The import overlay follows the import queue (FR10).
        observeImportActivity()
        // Speak Import Progress, from any window (FR10).
        observeImportProgressRequests()
        // Speak Download Progress, from any window (FR10's feed half).
        observeDownloadProgressRequests()
        // Once the rows are measured, the books Books Finished counts at
        // 100 percent are put at their ends, once (TODO P07).
        updateContentCachesAndStatistics { [weak self] in
            self?.moveFinishedBooksToTheirEndsOnce()
        }
        // The podcast and article feeds start in the background (FR03).
        startFeeds()
        // In a library another Mac can open, say this Mac has it open.
        dataDirectoryEnvironment.sessionLease?.begin()
        // In a cloud library, the other small files it opens with that are
        // only in the cloud come down now, without holding anything back.
        fetchLaunchFilesInBackground()
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
    /// Reads one file or folder of the library that is only in the cloud, so
    /// it comes to this Mac; nil fetches nothing, and the library then waits
    /// for Try Again as before.
    var libraryFetch: LibraryFileFetch?

    /// An environment of a test's own, holding no session lease and fetching
    /// nothing unless it passes them.
    init(
        preferences: UserDefaults,
        volumeNotifications: NotificationCenter,
        sessionLease: LibrarySessionLease? = nil,
        libraryFetch: LibraryFileFetch? = nil
    ) {
        self.preferences = preferences
        self.volumeNotifications = volumeNotifications
        self.sessionLease = sessionLease
        self.libraryFetch = libraryFetch
    }

    /// The app's: this process's preferences, the shared workspace, and the
    /// shared session lease.
    @MainActor static var app: DataDirectoryEnvironment {
        #if os(macOS)
        DataDirectoryEnvironment(
            preferences: TextMouthRuntime.current.preferences,
            volumeNotifications: NSWorkspace.shared.notificationCenter,
            sessionLease: .shared,
            libraryFetch: LibraryFileFetcher.app
        )
        #else
        // iOS has no workspace to announce unmounted volumes (phase 0): the
        // default center stands in, and nothing posts the unmount names to it.
        // A phone's library is in its own container, never shared with
        // another device and never in a cloud drive, so it holds no session
        // lease, whose repeating timer would run for nothing, and fetches
        // nothing from a cloud (the engineering review's F30).
        DataDirectoryEnvironment(
            preferences: TextMouthRuntime.current.preferences,
            volumeNotifications: .default,
            sessionLease: nil,
            libraryFetch: nil
        )
        #endif
    }
}

extension LibraryViewModel {

    // MARK: Checking

    /// Checks the data directory and makes what it finds the model's state:
    /// the gate that lets writers in or keeps them out, the reason the
    /// Library windows show, and, when the bookmark found the library under
    /// another path, the data directory itself. Files only in the cloud start
    /// the library's fetch of them (LibraryViewModel+LibraryFetch), which
    /// runs this check again after each pass and ends when the library is
    /// available, so the check cancels a fetch the files have outrun.
    /// Returns whether the library is available.
    @discardableResult
    func checkDataDirectory() -> Bool {
        let preferences = dataDirectoryEnvironment.preferences
        let root = TextMouthPaths.root
        // While a fetch runs it reads the files itself, so the check asks
        // the sync service for nothing.
        let itemStatus: any CloudItemStatusProviding = libraryFetchTask == nil
            ? CloudServices.itemStatus
            : WithoutDownloadRequests(base: CloudServices.itemStatus)
        let (outcome, pending) = DataDirectoryCheck.of(root: root, preferences: preferences)
            .runNamingPending(itemStatus: itemStatus)
        pendingLibraryFiles = pending
        switch outcome {
        case .available(_, let relocated):
            // Files that arrived end any fetch still waiting on them.
            cancelLibraryFetch()
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
            // Files only in the cloud are fetched, and the fetch says so
            // on the screen; any other reason is shown as it is.
            if !beginLibraryFetch(for: reason) {
                noteDataDirectoryUnavailable(reason)
            }
            return false
        }
    }

    /// Records that the data directory is unavailable for `reason`, once for
    /// each reason: the one place that sets `dataDirectoryUnavailability`.
    /// The check calls it, and tests use it to stand for a library whose
    /// drive dropped off.
    func noteDataDirectoryUnavailable(_ reason: DataDirectoryUnavailability) {
        guard reason != dataDirectoryUnavailability else { return }
        DiagnosticLog.event(.storage, "DATA_DIRECTORY_UNAVAILABLE: \(reason.logDescription)")
        dataDirectoryUnavailability = reason
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
        openLibraryAfterDataDirectoryReturned()
        return true
    }

    /// Opens the library once a check has found it (the check has already
    /// opened the gate and cleared the reason): the whole startup when it
    /// was unavailable at launch, or, after it was lost while TextMouth ran,
    /// a fresh read of library.json, then the lease again. Services that
    /// left their files unread are told to read them, and VoiceOver hears
    /// that the library is available. Try Again and the fetch of the
    /// library's files (LibraryViewModel+LibraryFetch) both end here.
    func openLibraryAfterDataDirectoryReturned() {
        if hasStartedLibrary {
            reloadLibraryAfterDataDirectoryReturned()
            dataDirectoryEnvironment.sessionLease?.begin()
            fetchLaunchFilesInBackground()
        } else {
            startLibrary()
        }
        announcedUnavailability = nil
        NotificationCenter.default.post(name: .dataDirectoryDidBecomeAvailable, object: nil)
        VoiceOverAnnouncer.announce("The library is available.", from: unavailabilityWindow)
    }

    // MARK: The Library Not Available Screen

    /// Tells VoiceOver why the library can't be used, once for each reason,
    /// however many Library windows show the screen (FR02). The screen asks
    /// for this once VoiceOver has moved to the reason.
    func announceDataDirectoryUnavailability(from window: PlatformWindow? = nil) {
        guard let reason = dataDirectoryUnavailability, reason != announcedUnavailability else { return }
        announcedUnavailability = reason
        unavailabilityWindow = window ?? unavailabilityWindow
        VoiceOverAnnouncer.announce(DataDirectoryUnavailableText.announcement(for: reason), from: window)
    }

    /// Refuses an app-wide action that needs the library while it can't be
    /// used (FR02), such as a book opened from Finder: the Library Not
    /// Available screen shows `refusal`, and VoiceOver hears it.
    func refuseWhileDataDirectoryUnavailable(_ refusal: String, from window: PlatformWindow? = nil) {
        dataDirectoryRefusalNotice = refusal
        VoiceOverAnnouncer.announce(refusal, from: window)
    }

    // MARK: Losing the Data Directory

    /// Starts listening for what can take the data directory away while
    /// TextMouth runs: an unmounted volume, and a write that found the
    /// folder gone (`LibraryPersistenceService`).
    func observeDataDirectoryLoss() {
        #if os(macOS)
        dataDirectoryEnvironment.volumeNotifications.publisher(for: NSWorkspace.didUnmountNotification)
            .compactMap { $0.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] volume in self?.volumeDidUnmount(volume) }
            .store(in: &cancellables)
        #endif
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
        if let root, URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL.path != available.named.path {
            return
        }
        guard !checkDataDirectory() else { return }
        // Its folder may be gone: the lease ages out unless Try Again
        // resumes it.
        dataDirectoryEnvironment.sessionLease?.pause()
        DiagnosticLog.event(.storage, "DATA_DIRECTORY_LOST: stopped saving until the library is back")
    }
}

extension Notification.Name {
    static let openBookWindow = Notification.Name("openBookWindow")
}

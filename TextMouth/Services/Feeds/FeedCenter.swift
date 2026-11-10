import Combine
import Foundation

// MARK: - What the Feed Engine Works With (FR03)

/// What the feed engine works with (FR03): the app's own, or a test's.
struct FeedEnvironment {
    /// Where the feeds' records are kept.
    var records: FeedStore.Location
    /// Where a record that can't be saved is reported: the app's center, or
    /// a test's own.
    var failureCenter: PersistenceFailureCenter
    /// Where this Mac's fetch details are kept, or nil to keep them in memory.
    var fetchStateFolder: URL?
    /// The network.
    var network: FeedNetwork
    /// Where Add Feed searches for podcasts: Apple's directory, or a test's
    /// stub server.
    var directory: FeedDirectory
    /// The store the feed settings are read from.
    var preferences: UserDefaults
    /// The time now.
    var now: @Sendable () -> Date
    /// Waits between scheduled refreshes; cancelling the waiting task ends
    /// the wait with `CancellationError`.
    var sleep: @Sendable (Duration) async throws -> Void
    /// Whether Low Power Mode is on, which puts scheduled refreshes off.
    var isLowPowerMode: @Sendable () -> Bool
    /// Whether the engine works by itself: refreshing at launch and on the
    /// interval. Never in a process hosting tests, unless a test asks for it.
    var worksOnItsOwn: Bool
    /// This Mac's folder for the resume data of downloads stopped partway.
    var resumeFolder: URL
    /// This Mac's folder for finished downloads waiting to be imported.
    var downloadsFolder: URL
    /// The free bytes on the volume holding a location.
    var freeSpace: @Sendable (URL) -> Int64?
    /// The boundary imports run through as storage work.
    var boundary: StorageBoundary
    /// The book storage, which says whether a package in a cloud library is
    /// wholly on this Mac.
    var bookStorage: @MainActor () -> any BookCloudStorage
    /// The statistics service whose finished books (`.bookDidFinish`) mark
    /// feed items played, or nil for none.
    var finishedBooksSource: AnyObject?
    /// Removes an item as the listener's own deletions do, to the Trash or
    /// for good as the removal setting says: a download's file, or its whole
    /// package (Delete Download, FR11). A test removes it for good, never
    /// to the Trash.
    var removeItem: @MainActor (URL) throws -> Void

    /// The app's: the data directory's Feeds folder, this Mac's Caches, the
    /// network, and the app's preferences. A process hosting tests never
    /// works on its own, and its network refuses every request.
    @MainActor static var app: FeedEnvironment {
        FeedEnvironment(
            records: .app,
            failureCenter: .shared,
            fetchStateFolder: MachineLocalPaths.feedCaches.appendingPathComponent("Fetch State", isDirectory: true),
            network: .app,
            directory: .apple,
            preferences: TextMouthRuntime.current.preferences,
            now: { Date() },
            sleep: { try await Task.sleep(for: $0) },
            isLowPowerMode: { ProcessInfo.processInfo.isLowPowerModeEnabled },
            worksOnItsOwn: !TextMouthRuntime.current.isHostedTest,
            resumeFolder: MachineLocalPaths.feedCaches.appendingPathComponent("Resume Data", isDirectory: true),
            downloadsFolder: MachineLocalPaths.feedDownloads,
            freeSpace: { ArchiveLimits.volumeFreeSpace(at: $0) },
            boundary: .shared,
            bookStorage: { CloudServices.bookStorage },
            finishedBooksSource: ReadingStatsService.shared,
            removeItem: { try FileImportService.removeItemRespectingTrashSetting(at: $0) }
        )
    }
}

// MARK: - The Library the Engine Works In

/// What the feed engine asks of the library it works in (FR03). The library
/// model is the app's (`LibraryViewModel+Feeds`); tests may give their own.
@MainActor
protocol FeedLibraryHost: AnyObject {
    /// The path of the library folder `folderID`, or nil when no folder has
    /// that ID any more.
    func feedFolderPath(forFolderID folderID: UUID) -> String?
    /// The book `bookID`, when the library lists it.
    func feedBook(withID bookID: UUID) -> Book?
    /// The feed `feedID`'s rows, by the identity of the item each came from:
    /// those whose files are here, and those kept after their files went
    /// (FR11).
    func feedItemRows(of feedID: UUID) -> FeedItemRows
    /// Lists a book a feed download published, and saves the library.
    func addFeedBook(_ book: Book)
    /// The transcript fetched with an episode was saved into its package
    /// (FMT25): the library row says "Transcribed", and an open reader shows
    /// `text`.
    func feedTranscriptAttached(bookID: UUID, text: TranscriptText)
    /// Removes the files of the feed items `books` through `remove`, once
    /// each record that keeps the listener's state and the feeds' indexes
    /// are on disk, keeping each package that holds something of the
    /// listener's when `keepingPackages` (FR11, branch A2).
    /// - Throws: `FeedItemPackageError.indexNotWritten`, with no file
    ///   touched.
    func removeFeedFiles(
        of books: [Book],
        keepingPackages: Bool,
        remove: (FeedFileRemoval) throws -> Void
    ) throws -> FeedFileRemovalOutcome
    /// The first part of `removeFeedFiles(of:keepingPackages:remove:)`, for
    /// a removal whose files go off the main thread (FR11): the records and
    /// the feeds' indexes on disk, the rows out of the books, nothing
    /// removed yet.
    /// `listenersFilesHeld` carries what reading the packages off the main
    /// thread found for the books it names (`FeedItemPackage.listenersFilesHeld(in:)`),
    /// so a removal of many does not read their transcripts here.
    /// - Returns: The removals to make.
    /// - Throws: `FeedItemPackageError.indexNotWritten`, with nothing
    ///   changed.
    func readyFeedFilesForRemoval(
        of books: [Book],
        keepingPackages: Bool,
        listenersFilesHeld: [UUID: Bool]
    ) throws -> [FeedFileRemoval]
    /// The last part of `removeFeedFiles(of:keepingPackages:remove:)`, once
    /// the files of `removals` have gone, but for those `failures` names
    /// with why, whose rows go back where they were.
    func settleFeedFileRemovals(_ removals: [FeedFileRemoval], failures: [UUID: any Error]) -> FeedFileRemovalOutcome
    /// The books in use now, which no rule of the engine's removes, leaving
    /// each for the rule's next pass (REV11 F1): those open in readers,
    /// which covers one playing; the book being transcribed, whose
    /// transcript is saved into its package only once its audio has been
    /// heard; those an export is reading; and those whose text is being
    /// edited with Edit Text, whose edit would otherwise be left behind by
    /// the download going (the listener's own deletions do not wait for
    /// these, since an editing session ends only when TextMouth quits).
    var feedBooksInUse: Set<UUID> { get }
    /// How the book `bookID` is in use now in a way the listener's own
    /// deletions refuse, saying why (`FeedDownloadInUseError`), or nil when
    /// it is not: every book with a use is in `feedBooksInUse`, which the
    /// rules wait for, but not the reverse (a book whose text is being
    /// edited has none, so those deletions go ahead).
    func feedBookUse(of bookID: UUID) -> FeedBookUse?
    /// Whether the book `bookID` is on the reading list, whose downloads the
    /// newest-N rule never removes (FR11).
    func feedBookIsOnReadingList(_ bookID: UUID) -> Bool
    /// Publishes the books open in readers whenever they change.
    var feedBooksOpenInReadersChanges: AnyPublisher<Set<UUID>, Never> { get }
    /// Whether the library lists every book it holds: not while its index
    /// is recovered, when its list is provisional and a book missing from it
    /// may still be on disk.
    var feedLibraryIsComplete: Bool { get }
    /// Opens the book `bookID` in its reader.
    func openFeedBook(_ bookID: UUID)
    /// Makes a new library folder for a feed titled `title`, inside the
    /// folder at `parentPath` ("" for the library's top level), named after
    /// the feed, with " 2", " 3", and so on added when that name is taken
    /// there, and returns its ID.
    /// - Throws: `FeedFolderError`, saying why no folder could be made.
    func makeFeedFolder(named title: String, inParentPath parentPath: String) throws(FeedFolderError) -> UUID
    /// Every row of the feed `feedID` the library holds, each once (FR14):
    /// its downloads among the books, then the rows kept on its shelf after
    /// their downloads went.
    func everyRow(ofFeed feedID: UUID) -> [Book]
    /// Forgets the index of the feed `feedID` for good, once every row of
    /// the feed has left the library, as Delete Feed… does before the feed's
    /// folder goes (FR14): no save writes the index again, which would make
    /// that folder anew, and no snapshot waiting to be written still holds
    /// it.
    func forgetFeedIndex(of feedID: UUID)
    /// Deletes the library folder `folderID`, the folder of a feed just
    /// deleted, when nothing else is in it: no book of the library's own, no
    /// folder, and no other feed's items (FR14).
    /// - Returns: What became of the folder.
    func removeFolderOfDeletedFeed(_ folderID: UUID) async -> FeedFolderFate
}

/// Why no folder could be made for a new subscription (FR03), in a sentence
/// the subscribe sheet shows and VoiceOver speaks.
struct FeedFolderError: Error, Equatable, Sendable {
    /// Why, as a sentence.
    let message: String
}

// MARK: - What the Engine Announces

/// What the feed engine announces (FR03), for the library to show and the
/// listener to hear: the interface decides what to say, and whether to
/// raise an alert or a notification (`FeedSettings.refreshAlert` and
/// `FeedSettings.notifications`).
enum FeedEvent: Equatable, Sendable {
    /// A feed was subscribed to.
    case subscribed(feedID: UUID)
    /// One feed's refresh ended.
    case refreshed(FeedRefreshReport)
    /// A refresh of every feed ended.
    case refreshedAll(FeedRefreshSummary)
    /// An item's download started.
    case downloadStarted(feedID: UUID, itemID: FeedItem.ID)
    /// An item's download finished: its book is in the library.
    case downloadFinished(feedID: UUID, itemID: FeedItem.ID, bookID: UUID)
    /// An item's download failed, for the reason given.
    case downloadFailed(feedID: UUID, itemID: FeedItem.ID, reason: String)
    /// An item's download, one the listener asked for or one under way, was
    /// cancelled before it finished, by Cancel Download, by the feed
    /// downloads section's Cancel, or by Delete Feed…. The item is not
    /// downloaded by now, so a listener of the event finds a consistent
    /// record (REV18a finding 6).
    case downloadCancelled(feedID: UUID, itemID: FeedItem.ID)
    /// A change of the "List and download" choice or its number took effect,
    /// once it had stayed unchanged for `FeedCenter.itemPolicyQuietTime`
    /// (FR11): the global setting's, which covers every feed, when `global`,
    /// and the feeds `feedIDs`' own, both when both changed within one wait
    /// (feed review item 20).
    case itemPolicyApplied(global: Bool, feedIDs: Set<UUID>)
}

// MARK: - Subscribing

/// Where a new subscription's downloads go (FR03).
enum FeedFolderChoice: Equatable, Sendable {
    /// The library folder with this ID, which must exist.
    case folder(UUID)
    /// A new folder of the feed's own, named after the feed once it has been
    /// read, made inside the library folder at this path ("" for the
    /// library's top level): the listener's choice of October 4, "a new
    /// feed's folder goes anywhere". Nothing is made unless the subscription
    /// succeeds.
    case newFolder(inParentPath: String)
}

/// How subscribing to an address ended (FR03).
enum FeedSubscribeOutcome: Equatable, Sendable {
    /// The feed is subscribed: its record.
    case subscribed(Feed)
    /// The address is a web page naming several feeds, the first being the
    /// site's main one: the listener chooses one and subscribes to it.
    case choose([FeedLink])
}

/// How long the feed downloads section's Cancel holds back a feed's
/// newest-N downloads (FR14, `FeedCenter.cancelEveryDownload()`): until a
/// check of the feed that began after Cancel has ended. TextMouth's next
/// launch ends every pause, which lives only in memory.
enum FeedRulePause: Equatable, Sendable {
    /// Until the feed's next check ends.
    case untilNextCheck
    /// Until the check after the one under way as Cancel was pressed ends:
    /// a check that began before Cancel ends none.
    case untilTheCheckAfterTheOneUnderWay
}

/// What unsubscribing from a feed did (FR11, branch D,
/// `FeedCenter.unsubscribe(_:)`), for the words the listener hears.
struct FeedUnsubscribeOutcome: Equatable, Sendable {
    /// How many of the feed's downloads stay, its items in its own folder.
    var downloadCount: Int
    /// How many packages the feed kept for downloads removed earlier were
    /// deleted, with their places, bookmarks, and transcripts: of those
    /// Unsubscribe's question named, never another (REV14 feeds 1).
    var deletedKeptCount: Int
}

/// Why subscribing to an address failed (FR03), in sentences a listener reads.
enum FeedSubscribeError: Error, Equatable, Sendable {
    /// The address is not an http or https address.
    case invalidAddress
    /// The folder chosen for the feed's downloads is gone.
    case folderMissing
    /// The feed is subscribed already, under the title given.
    case alreadySubscribed(title: String)
    /// The feed is in the library already, under the title given, and the
    /// listener unsubscribed from it (FR11, branch D): Resubscribe, not
    /// a second subscription, checks it again.
    case unsubscribedAlready(title: String)
    /// The address is a web page that names no feed.
    case pageNamesNoFeed
    /// The feed could not be fetched or read.
    case refreshFailed(FeedRefreshError, host: String)
    /// The feed was read, but no folder could be made for it, for the
    /// reason given.
    case folderNotMade(FeedFolderError)

    /// The sentence the subscribe sheet shows and VoiceOver speaks.
    var message: String {
        switch self {
        case .invalidAddress:
            return "That isn't a web address. Enter a feed's address, or the address of a page that names one."
        case .folderMissing:
            return "The folder chosen for this feed is no longer in the library. Choose another folder."
        case .alreadySubscribed(let title):
            return "You're already subscribed to \(title)."
        case .unsubscribedAlready(let title):
            return "\(title) is in your library, unsubscribed. Choose Resubscribe on its row, or in its Feed Info, to check it again."
        case .pageNamesNoFeed:
            return "That page doesn't name a feed."
        case let .refreshFailed(error, host):
            return error.message(about: host, host: host)
        case .folderNotMade(let error):
            return error.message
        }
    }
}

// MARK: - The Engine

/// The podcast and article reader's engine (FR03): every subscription and
/// its items (`FeedStore`), this Mac's fetch details (`FeedFetchStates`),
/// refreshing (`FeedRefresher`), and the operations the library offers.
///
/// It starts with the library (`start(library:)`, from
/// `LibraryViewModel.startLibrary()`): it reads the records off the main
/// thread, and then, unless it is in a process hosting tests, refreshes
/// every feed when the settings say to, and again on the interval while
/// TextMouth runs, rescheduling when the interval changes. Nothing it does
/// at launch holds the library back.
///
/// Library windows observe it: it republishes every change of its records
/// and fetch details, and publishes which feeds are refreshing; it
/// announces what happens through `events`.
@MainActor
final class FeedCenter: ObservableObject {
    /// The app's engine.
    static let shared = FeedCenter(environment: .app)

    /// What the engine works with.
    let environment: FeedEnvironment
    /// Every subscription's record.
    let store: FeedStore
    /// This Mac's fetch details.
    let fetchStates: FeedFetchStates
    /// Refreshes feeds, telling this engine which are refreshing and how
    /// each refresh ended.
    private(set) lazy var refresher = FeedRefresher(
        store: store,
        fetchStates: fetchStates,
        network: environment.network,
        settings: { [weak self] in self?.settings ?? .standard },
        now: environment.now,
        keptRecords: { [weak self] feedID in self?.keptRecordItemIDs(of: feedID) ?? [] },
        refreshingChanged: { [weak self] feedIDs in self?.refreshingFeedIDs = feedIDs },
        reportRefresh: { [weak self] report in self?.refreshEnded(report) }
    )
    /// Downloads items, one at a time.
    private(set) lazy var downloads = FeedDownloadManager(
        store: store,
        environment: FeedDownloadManager.Environment(
            network: environment.network,
            resumeFolder: environment.resumeFolder,
            holdingFolder: environment.downloadsFolder,
            freeSpace: environment.freeSpace,
            reserve: ArchiveLimits.standard.freeSpaceReserve,
            boundary: environment.boundary,
            now: environment.now,
            removeItem: environment.removeItem
        ),
        library: { [weak self] in self?.library },
        announce: { [weak self] event in self?.downloadEventHappened(event) }
    )
    /// What the engine announces, delivered on the main actor.
    let events = PassthroughSubject<FeedEvent, Never>()
    /// The feeds being refreshed now.
    @Published private(set) var refreshingFeedIDs: Set<UUID> = []

    /// The library the engine works in, once started.
    private(set) weak var library: FeedLibraryHost?
    /// Whether `start(library:)` has run.
    private(set) var hasStarted = false
    /// The scheduled refreshes, while they run.
    private var schedule: Task<Void, Never>?
    /// Hears the interval setting change, to reschedule.
    private var intervalObserver: PreferenceObserver?
    /// Hears the "List and download" choice and its number change (FR11).
    private var itemPolicyObserver: PreferenceObserver?
    /// The wait for the choice and its number to stay unchanged before the
    /// newest-N rule acts on a change, while it runs (FR11).
    private var itemPolicyWait: Task<Void, Never>?
    /// The feeds whose own choice or number changed since the rule last
    /// acted on a change (FR11).
    private var feedsWithChangedItemPolicy: Set<UUID> = []
    /// Whether the global choice or number changed since the rule last acted
    /// on a change, kept beside the feeds' own, so a feed's change made
    /// within the global change's wait is announced too (feed review item
    /// 20).
    private var globalItemPolicyChanged = false
    /// Passes the stores' changes on to this engine's observers.
    private var forwarding: [AnyCancellable] = []
    /// Hears finished books, and the readers that open and close.
    private var lifecycleObservers: [AnyCancellable] = []
    /// Whether the engine's own work runs: a sweep of played downloads, or a
    /// pass of the newest-N rule (FR11), one at a time (`requestSweep()`,
    /// `requestItemPolicyPass(for:retryingFailures:)`).
    var isSweeping = false
    /// Whether a sweep was asked for and has not run yet.
    var sweepRequested = false
    /// The pass of the newest-N rule asked for and not run yet, with every
    /// pass asked for meanwhile (FR11).
    var pendingItemPolicyPass: FeedItemPolicyPassRequest?
    /// Whether each audiobook of the library's own came from a feed, as its
    /// package record's feed link says, by book ID: read once a book for
    /// Books Finished (`finishedBookKind(of:)`, REV11).
    var feedOriginOfRecords: [UUID: Bool] = [:]
    /// The feeds whose newest-N downloads the feed downloads section's
    /// Cancel holds back, and until when (FR14, `cancelEveryDownload()`):
    /// the rule asks for none of their items meanwhile, while its other
    /// work, taking back and removing, goes on.
    var rulePauses: [UUID: FeedRulePause] = [:]

    /// An engine working with `environment`, started by `start(library:)`.
    init(environment: FeedEnvironment) {
        self.environment = environment
        store = FeedStore(location: environment.records, failureCenter: environment.failureCenter)
        fetchStates = FeedFetchStates(folder: environment.fetchStateFolder)
        forwarding = [
            store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            fetchStates.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
        ]
        if let source = environment.finishedBooksSource {
            // Posted on the main actor, by the statistics service.
            lifecycleObservers.append(
                NotificationCenter.default.publisher(for: .bookDidFinish, object: source)
                    .compactMap { $0.userInfo?[ReadingStatsService.finishedBookIDKey] as? UUID }
                    .sink { [weak self] bookID in self?.bookDidFinish(bookID) }
            )
            // Books Finished asks this engine what kind of book one is, as
            // it knows which audiobooks are its episodes.
            (source as? ReadingStatsService)?.finishedBookKind = { [weak self] bookID in
                self?.finishedBookKind(of: bookID)
            }
        }
    }

    /// The feed settings in force.
    var settings: FeedSettings {
        FeedSettings.read(from: environment.preferences)
    }

    // MARK: Starting

    /// Starts the engine in `library`, once: moves the settings before the
    /// "List and download" choice to it (FR11), reads the records and this
    /// Mac's fetch details off the main thread, moving each feed's retired
    /// override to a choice of its own, then, when the engine works on its
    /// own, asks again for the downloads TextMouth quit during, asks for a
    /// sweep of played downloads and a pass of the newest-N rule over every
    /// feed, refreshes every feed if the settings say to, and starts the
    /// scheduled refreshes. Returns at once.
    /// - Returns: The work started, which tests may await.
    @discardableResult
    func start(library: FeedLibraryHost) -> Task<Void, Never>? {
        guard !hasStarted else { return nil }
        hasStarted = true
        self.library = library
        // Before anything reads the choice, so all read the same one.
        FeedSettings.moveToItemPolicyIfNeeded(in: environment.preferences)
        return Task {
            await store.load()
            moveKeptEntriesOverrides()
            await fetchStates.load()
            await downloads.sweepLeftovers()
            guard environment.worksOnItsOwn else { return }
            // What a Delete Download cut short left hidden in a feed's
            // folder goes, as that deletion would have sent it.
            await sweepRemovalHolders()
            // The downloads under way when TextMouth last quit go on, the
            // one that ran from where it stopped.
            await downloads.resumeDownloadsSavedAtQuit()
            // A reader closing lets a played download it held be deleted; the
            // newest-N rule waits for its own passes (FR11).
            lifecycleObservers.append(
                library.feedBooksOpenInReadersChanges.sink { [weak self] _ in self?.requestSweep() }
            )
            requestSweep()
            // Each feed's newest downloaded at once, as at the first launch
            // of the version that brought the rule (FR11).
            requestItemPolicyPass(for: nil)
            intervalObserver = PreferenceObserver(
                keys: [FeedSettings.refreshIntervalHoursPreference.key],
                in: environment.preferences
            ) { [weak self] _ in
                self?.startSchedule()
            }
            // The global choice or number changed, wherever it was changed:
            // the rule acts on it once it has stayed unchanged (FR11).
            itemPolicyObserver = PreferenceObserver(
                keys: [FeedSettings.itemsPreference.key, FeedSettings.newestCountPreference.key],
                in: environment.preferences
            ) { [weak self] _ in
                self?.itemPolicyChanged(for: nil)
            }
            startSchedule()
            if settings.refreshAtLaunch {
                await refreshAll(origin: .launch)
            }
        }
    }

    /// Sweeps the hidden holders a Delete Download left in the feeds' own
    /// folders (`FeedItemPackage.removalHolders(in:)`), which nothing else
    /// ever removes, each as its row says (REV14 feeds 3,
    /// `FeedItemPackage.sweepHolder(_:puttingBackInto:remove:)`):
    ///
    /// - A holder named for a download the library still lists as
    ///   downloaded, in the same feed's folder, kept the files of a Delete
    ///   Download that was refused and could not put them back
    ///   (FEED_DOWNLOAD_HELD_ASIDE): they go back into its package, so the
    ///   row says "Downloaded" of a file that is there, whatever Removal
    ///   Behavior says.
    /// - Any other, as a crash between moving an article's file and text
    ///   into one and the Trash taking it leaves, was a deletion that went
    ///   ahead, the feed's index written without the file first: what it
    ///   holds goes as that deletion would have sent it, to the Trash or for
    ///   good as Removal Behavior says (`FeedEnvironment.removeItem`), under
    ///   the file's own name rather than the holder's hidden one, so the
    ///   Trash shows it.
    ///
    /// Nothing is swept while the library's index is recovered: its list of
    /// books is provisional, and a refused deletion's row could be missing
    /// from it. The folders are listed off the main thread; a holder that
    /// cannot be emptied stays, logged, for the next launch.
    func sweepRemovalHolders() async {
        guard let library, library.feedLibraryIsComplete else { return }
        let root = TextMouthPaths.root
        let holders = await OffMainWork.run(on: .global(qos: .utility)) {
            FeedItemPackage.removalHolders(in: root)
        }
        for holder in holders {
            do {
                let sweep = try FeedItemPackage.sweepHolder(
                    holder,
                    puttingBackInto: packageWaitingForItsFiles(in: holder, library: library, root: root),
                    remove: environment.removeItem
                )
                DiagnosticLog.event(.feeds, "FEED_HELD_ASIDE_SWEPT: \(holder.lastPathComponent): \(Self.sweepNote(sweep))")
            } catch {
                DiagnosticLog.event(
                    .feeds,
                    "FEED_HELD_ASIDE_LEFT: \(holder.lastPathComponent): \(error.localizedDescription); the next launch tries again"
                )
            }
        }
    }

    /// The package whose files wait in the holder `holder`, as a Delete
    /// Download that was refused, and could not put them back, left them:
    /// that of the download the holder is named after, which `library`
    /// still lists as downloaded, in the holder's own feed's folder; nil
    /// when no download is so listed, as when the deletion went ahead, or
    /// for a holder named before REV14.
    private func packageWaitingForItsFiles(in holder: URL, library: FeedLibraryHost, root: URL) -> URL? {
        guard let bookID = FeedItemPackage.bookID(ofRemovalHolderNamed: holder.lastPathComponent),
              let row = library.feedBook(withID: bookID), row.isFeedItem,
              let package = try? FeedItemPackage.packageForRemoval(of: row, in: root),
              package.deletingLastPathComponent().standardizedFileURL.path == holder.deletingLastPathComponent().standardizedFileURL.path
        else { return nil }
        return package
    }

    /// What the launch's sweep did with one holder, as its log line says it.
    private static func sweepNote(_ sweep: FeedItemPackage.HolderSweep) -> String {
        var notes: [String] = []
        if !sweep.putBack.isEmpty {
            notes.append("put back \(sweep.putBack.joined(separator: " and ")) into the package of the download whose deletion was refused")
        }
        if !sweep.removed.isEmpty {
            notes.append("removed \(sweep.removed.joined(separator: " and ")) as Removal Behavior says, left by a Delete Download cut short")
        }
        return notes.isEmpty ? "nothing was left in it" : notes.joined(separator: "; ")
    }

    /// Stops the scheduled refreshes, as when a test ends.
    func stop() {
        schedule?.cancel()
        schedule = nil
        intervalObserver = nil
        itemPolicyWait?.cancel()
        itemPolicyWait = nil
        itemPolicyObserver = nil
    }

    /// Whether refreshes run on the interval setting: not before the engine
    /// starts, nor while the setting is 0.
    var refreshesOnSchedule: Bool {
        schedule != nil
    }

    /// Starts the scheduled refreshes over, on the interval setting: one
    /// every interval while TextMouth runs, none when the setting is 0, and
    /// none while Low Power Mode is on, until the next interval.
    private func startSchedule() {
        schedule?.cancel()
        schedule = nil
        guard environment.worksOnItsOwn, let interval = settings.refreshInterval else { return }
        let sleep = environment.sleep
        schedule = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleep(.seconds(interval))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                if self.environment.isLowPowerMode() {
                    DiagnosticLog.trace(.feeds, "scheduled refresh put off while Low Power Mode is on")
                    continue
                }
                await self.refreshAll(origin: .scheduled)
            }
        }
    }

    // MARK: Reading

    /// Every subscription, by title.
    var feeds: [Feed] {
        store.feeds
    }

    /// The feed whose downloads go to the library folder `folderID`: what
    /// the library shows "Feed" after.
    func feed(inFolder folderID: UUID) -> Feed? {
        store.feed(inFolder: folderID)
    }

    /// What the feed `feedID` lists and downloads by itself now (FR11): its
    /// own "List and download" choice, or the global one, which a feed no
    /// longer subscribed follows too.
    func itemPolicy(of feedID: UUID) -> FeedItemPolicy {
        store.record(of: feedID)?.feed.itemPolicyOverride ?? FeedSettings.itemPolicy(in: environment.preferences)
    }

    /// The items of the feed `feedID` the library lists, newest first: every
    /// item not deleted, or, under "Only the newest 5 listed", the short
    /// list (FR11, `FeedRecord.listedItems(under:hasFile:)`), an item's file
    /// being here while the library lists its book.
    func listedItems(of feedID: UUID) -> [FeedItem] {
        guard let record = store.record(of: feedID) else { return [] }
        return record.listedItems(under: itemPolicy(of: feedID).listing) { downloadedRow(of: $0, in: feedID) != nil }
    }

    /// How this Mac last checked the feed `feedID`.
    func fetchState(of feedID: UUID) -> FeedFetchState {
        fetchStates.state(of: feedID)
    }

    // MARK: Searching

    /// Searches the podcast directory for `term`, as Add Feed's Search
    /// does, and returns the podcasts it found that name a feed, in the
    /// directory's order.
    /// - Throws: `FeedSearchError`.
    func searchDirectory(for term: String) async throws -> [FeedDirectoryResult] {
        try await environment.directory.search(term, through: environment.network)
    }

    // MARK: Subscribing

    /// Subscribes to the feed at `address`, as the listener typed it, its
    /// downloads going to the library folder `folderID`. An address that is
    /// a web page naming one feed subscribes to that feed; a page naming
    /// several returns them for the listener to choose.
    /// - Throws: `FeedSubscribeError`.
    func subscribe(to address: String, folderID: UUID) async throws -> FeedSubscribeOutcome {
        try await subscribe(to: address, into: .folder(folderID))
    }

    /// Subscribes to the feed at `address`, as the listener typed it, its
    /// downloads going where `choice` says: an existing folder, or a new
    /// folder named after the feed, made only once the feed has been read.
    /// An address that is a web page naming one feed subscribes to that
    /// feed; a page naming several returns them for the listener to choose,
    /// and nothing is made until one is chosen and subscribed to.
    /// - Throws: `FeedSubscribeError`.
    func subscribe(to address: String, into choice: FeedFolderChoice) async throws -> FeedSubscribeOutcome {
        guard let url = FeedAddress.normalized(address) else { throw FeedSubscribeError.invalidAddress }
        if case .folder(let folderID) = choice, library?.feedFolderPath(forFolderID: folderID) == nil {
            throw FeedSubscribeError.folderMissing
        }
        return try await subscribe(url, into: choice, followingPage: true)
    }

    /// Subscribes to the feed at `url`; when `followingPage`, an address
    /// that is a web page is searched for the feeds it names.
    private func subscribe(_ url: URL, into choice: FeedFolderChoice, followingPage: Bool) async throws -> FeedSubscribeOutcome {
        if let existing = subscribedFeed(at: url) {
            throw Self.alreadyInTheLibrary(existing)
        }
        let host = FeedHost.of(url)
        let fetched: FeedFetchResult
        do {
            fetched = try await environment.network.fetch(url, discretionary: false)
        } catch {
            throw FeedSubscribeError.refreshFailed(.fetch(FeedFetchError.from(error, host: host)), host: host)
        }
        guard case .body(let body) = fetched else {
            throw FeedSubscribeError.refreshFailed(.fetch(.serverError(status: 304, host: host)), host: host)
        }
        let address = body.permanentURL ?? url
        let now = environment.now()
        // A new subscription follows the global choice's listing (FR11).
        let keepEntries = settings.itemPolicy.listing.keptEntries
        // A new folder is made only once the feed has been read, so until
        // then the record names a stand-in, replaced below.
        let provisionalFolderID: UUID
        if case .folder(let folderID) = choice {
            provisionalFolderID = folderID
        } else {
            provisionalFolderID = UUID()
        }
        let read = await OffMainWork.run(on: .global(qos: .userInitiated)) { () -> Result<FeedRecord, FeedParseError> in
            do {
                let feed = try FeedParser.parse(body.data, baseURL: body.finalURL)
                var record = FeedRecord(feed: Feed(feedURL: address, folderID: provisionalFolderID, subscribedDate: now))
                var texts = FeedTextCache()
                FeedReconciler.merge(feed, into: &record, keepEntries: keepEntries, now: now, texts: &texts)
                return .success(record)
            } catch {
                return .failure(error as? FeedParseError ?? .notAFeed)
            }
        }
        switch read {
        case .success(var record):
            // Another subscription to the same feed may have finished meanwhile.
            if let existing = subscribedFeed(at: record.feed.feedURL) {
                throw Self.alreadyInTheLibrary(existing)
            }
            record.feed.folderID = try folderID(for: record.feed, choice: choice)
            store.add(record)
            fetchStates.update(record.feed.id) { state in
                // The body with the record's date, as a refresh notes them,
                // so the next refresh skips this body as unchanged only
                // while the record it loads holds this merge.
                state.noteBodyMerged(body, keptEntries: keepEntries, into: record)
                state.lastCheck = now
                state.lastSuccess = now
            }
            DiagnosticLog.event(
                .feeds,
                "FEED_SUBSCRIBED: \(record.feed.title) (\(FeedHost.of(record.feed.feedURL))): \(record.items.count) item(s) kept"
            )
            events.send(.subscribed(feedID: record.feed.id))
            // The feed's newest downloaded at once (FR11).
            requestItemPolicyPass(for: [record.feed.id])
            return .subscribed(record.feed)
        case .failure(.notAFeed) where followingPage:
            let links = await OffMainWork.run(on: .global(qos: .userInitiated)) {
                FeedDiscovery.feedLinks(inPage: body.text, pageURL: body.finalURL)
            }
            switch links.count {
            case 0:
                throw FeedSubscribeError.pageNamesNoFeed
            case 1:
                return try await subscribe(links[0].url, into: choice, followingPage: false)
            default:
                return .choose(links)
            }
        case .failure(let error):
            throw FeedSubscribeError.refreshFailed(.parse(error), host: host)
        }
    }

    /// The folder a new subscription to `feed`, just read, puts its
    /// downloads in: the existing folder `choice` names, which must still be
    /// in the library, or a new one named after the feed, made now.
    /// - Throws: `FeedSubscribeError.folderMissing` or `.folderNotMade`.
    private func folderID(for feed: Feed, choice: FeedFolderChoice) throws(FeedSubscribeError) -> UUID {
        guard let library else { throw FeedSubscribeError.folderMissing }
        switch choice {
        case .folder(let folderID):
            // The folder may have gone while the feed was fetched.
            guard library.feedFolderPath(forFolderID: folderID) != nil else { throw FeedSubscribeError.folderMissing }
            return folderID
        case .newFolder(let parentPath):
            do {
                return try library.makeFeedFolder(named: feed.title, inParentPath: parentPath)
            } catch {
                throw FeedSubscribeError.folderNotMade(error)
            }
        }
    }

    /// The subscription to the feed at `url`, whatever its scheme or a
    /// trailing slash, if there is one: subscribed, or unsubscribed from and
    /// kept (FR11, branch D).
    func subscribedFeed(at url: URL) -> Feed? {
        let key = FeedAddress.comparisonKey(url)
        return store.feeds.first { FeedAddress.comparisonKey($0.feedURL) == key }
    }

    /// Why subscribing to the feed `existing` is refused, as the library has
    /// it already: subscribed, or unsubscribed from (FR11, branch D), which
    /// Resubscribe checks again.
    private static func alreadyInTheLibrary(_ existing: Feed) -> FeedSubscribeError {
        existing.isSubscribed ? .alreadySubscribed(title: existing.title) : .unsubscribedAlready(title: existing.title)
    }

    /// Unsubscribes from the feed `feedID` (FR11, branch D), as the listener
    /// asked on October 9: "just keep it a feed with rules kept except you
    /// can't check it or manually check it for new items". Only checking
    /// stops (`Feed.isSubscribed`; `FeedRefresher`). The feed keeps its
    /// record, which notes when it was unsubscribed, its library folder,
    /// still a feed's, its own settings, its downloads, which stay its items
    /// in its own folder, and this Mac's fetch details; its rules go on
    /// removing what they remove. The newest-N rule's downloads not yet
    /// under way are taken back, since it downloads nothing for an
    /// unsubscribed feed, and the one under way, like the listener's, runs
    /// on. The packages the feed kept for downloads removed earlier go, with
    /// their places and bookmarks (`deleteKeptPackages(_:of:)`), as the
    /// listener accepted: "Clearing out old deleted episodes itself seems
    /// fine"; but only those of the items `keptItemIDs` names, the ones
    /// Unsubscribe's question named (none when it asked nothing), less any
    /// downloading again since, which their downloads restore. Those are
    /// decided first: taking back the rule's downloads leaves more kept
    /// packages with no download to restore them, and none of those was
    /// asked about (REV14 feeds 1). Resubscribe (`resubscribe(_:)`) checks
    /// the feed again.
    /// - Returns: What unsubscribing did, for the words the listener hears;
    ///   nil for a feed TextMouth has no record of, or one already
    ///   unsubscribed, which changes nothing.
    @discardableResult
    func unsubscribe(_ feedID: UUID, deletingKeptOf keptItemIDs: Set<FeedItem.ID> = []) -> FeedUnsubscribeOutcome? {
        guard let feed = store.record(of: feedID)?.feed, feed.isSubscribed else { return nil }
        // Decided before the rule's downloads are taken back below, which
        // would add the packages they were restoring.
        let deleting = keptRowsUnsubscribeDeletes(of: feedID, among: keptItemIDs)
        store.update(feedID) { $0.feed.unsubscribedDate = environment.now() }
        downloads.withdrawRuleDownloads(of: feedID) { _ in true }
        // The rule downloads nothing for it by itself now, so a pause Cancel
        // put on it has nothing left to hold back (FR14).
        rulePauses[feedID] = nil
        let outcome = FeedUnsubscribeOutcome(
            downloadCount: library?.feedItemRows(of: feedID).downloaded.count ?? 0,
            deletedKeptCount: deleteKeptPackages(deleting, of: feedID)
        )
        DiagnosticLog.event(
            .feeds,
            "FEED_UNSUBSCRIBED: \(feed.title): checking stops; "
                + "\(CountWording.phrase(outcome.downloadCount, singular: "download stays", plural: "downloads stay")); "
                + "deleted \(CountWording.phrase(outcome.deletedKeptCount, singular: "package", plural: "packages")) "
                + "kept for removed downloads"
        )
        return outcome
    }

    /// Subscribes again to the feed `feedID`, which the listener unsubscribed
    /// from (FR11, branch D): checking starts again, at launch, on the
    /// interval, and in Refresh All Feeds, and the feed is checked at once,
    /// as Check Feed checks it, on any network; the end of that check asks
    /// for the newest-N rule's pass over the feed, as every check's end
    /// does, which downloads its newest again.
    /// - Returns: How the check at once ended; nil for a feed TextMouth has
    ///   no record of, or one subscribed already, which changes nothing.
    @discardableResult
    func resubscribe(_ feedID: UUID) async -> FeedRefreshReport? {
        guard let feed = store.record(of: feedID)?.feed, !feed.isSubscribed else { return nil }
        store.update(feedID) { $0.feed.unsubscribedDate = nil }
        DiagnosticLog.event(.feeds, "FEED_RESUBSCRIBED: \(feed.title): checking starts again, at once")
        return await refresh(feedID)
    }

    // MARK: Refreshing

    /// Refreshes the feed `feedID` because the listener asked (Check Feed),
    /// and returns how it ended; nil when it is not subscribed.
    @discardableResult
    func refresh(_ feedID: UUID) async -> FeedRefreshReport? {
        await refresher.refresh(feedID, origin: .listener)
    }

    /// Refreshes every feed, and announces one summary. A record that was
    /// only in the cloud until now is read first, and moves its retired
    /// override to a choice of its own before it is refreshed (FR11).
    @discardableResult
    func refreshAll(origin: FeedRefreshOrigin = .listener) async -> FeedRefreshSummary {
        await store.loadRecordsInCloud()
        moveKeptEntriesOverrides()
        let summary = await refresher.refreshAll(origin: origin)
        events.send(.refreshedAll(summary))
        return summary
    }

    /// Announces the end of one feed's refresh, and asks for the newest-N
    /// rule's pass over the feed (FR11), which takes back what it no longer
    /// counts, downloads its newest, and removes its oldest downloads beyond
    /// them, trying its failed downloads again when the refresh reached the
    /// network. A refresh TextMouth made by itself that was not put off
    /// reached a network without data limits, which such a refresh needs, so
    /// the downloads one put off are tried again: once the pass is asked
    /// for, and only those the rule still counts, so a put-off download
    /// whose item was played, or left the newest, never starts before the
    /// pass takes it back (REV11 F3).
    private func refreshEnded(_ report: FeedRefreshReport) {
        events.send(.refreshed(report))
        endRulePause(afterCheckOf: report.feedID)
        requestSweep()
        requestItemPolicyPass(for: [report.feedID], retryingFailures: report.outcome != .skipped)
        if report.origin.isDiscretionary, report.outcome != .skipped {
            retryCountedPutOffDownloads()
        }
    }

    /// Notes that a check of the feed `feedID` ended, which ends the pause
    /// the feed downloads section's Cancel put on the feed's newest-N
    /// downloads (FR14), so the pass this check asks for downloads them
    /// again; a check that was under way as Cancel was pressed only leaves
    /// the pause to the next one.
    private func endRulePause(afterCheckOf feedID: UUID) {
        switch rulePauses[feedID] {
        case .untilTheCheckAfterTheOneUnderWay?:
            rulePauses[feedID] = .untilNextCheck
        case .untilNextCheck?:
            rulePauses[feedID] = nil
        case nil:
            break
        }
    }

    /// Stops every feed download as the feed downloads section's Cancel
    /// does, a pause rather than a refusal (FR14,
    /// `FeedDownloadManager.cancelEveryDownload()`): what was under way,
    /// waiting to start, or waiting for a network or for room stops, and
    /// every partial download goes. For each feed whose download stopped,
    /// the newest-N rule downloads nothing by itself until a check of the
    /// feed that began after Cancel has ended (the hourly check, Check Feed,
    /// Refresh All Feeds, or Resubscribe), never sooner, whatever else asks
    /// for a pass meanwhile, or until TextMouth next opens, whose first pass
    /// covers every feed. The listener's own Download is never held back.
    /// - Returns: What VoiceOver hears of it, which the window says once
    ///   its focus has moved (REV13 item 3): what stopped, and how it comes
    ///   back, promising only what the rule will download again
    ///   (`comingBack(of:)`, REV14 feeds 5).
    @discardableResult
    func cancelEveryDownload() -> String {
        let cancellation = downloads.cancelEveryDownload()
        for feedID in cancellation.feedIDs {
            // A check under way began before Cancel, so ends no pause.
            rulePauses[feedID] = refreshingFeedIDs.contains(feedID) ? .untilTheCheckAfterTheOneUnderWay : .untilNextCheck
        }
        return FeedDownloadProgressWording.cancelled(
            stopped: cancellation.stopped.map(\.title),
            finishing: cancellation.finishing,
            comingBack: comingBack(of: cancellation.stopped)
        )
    }

    /// What VoiceOver says the feed downloads section's Cancel button does,
    /// as Cancel would act now: what it stops, and how what it would stop
    /// comes back, as Cancel would then say it (REV14 feeds 5).
    func cancelButtonHint() -> String {
        FeedDownloadProgressWording.cancelButtonHint(comingBack(of: downloads.downloadsCancelWouldStop))
    }

    /// How the downloads `stopped` come back after Cancel (REV14 feeds 5):
    /// those the newest-N rule downloads again by itself, after their feeds'
    /// next checks, being items it would ever download
    /// (`ruleWouldDownload(_:)`) among the newest its feed counts
    /// (`countedItemIDs(in:under:)`, none for a feed that downloads by hand
    /// or is unsubscribed from); and the others, which only the listener's
    /// Download brings back. Each feed's count of its newest is worked out
    /// once.
    func comingBack(of stopped: [FeedDownloadManager.Cancellation.Stopped]) -> FeedCancelReturn {
        var counted: [UUID: Set<FeedItem.ID>] = [:]
        let byItself = stopped.filter { download in
            guard let record = store.record(of: download.feedID), let item = record.item(download.itemID),
                  Self.ruleWouldDownload(item) else { return false }
            let feedCounts = counted[download.feedID] ?? Self.countedItemIDs(in: record, under: itemPolicy(of: download.feedID))
            counted[download.feedID] = feedCounts
            return feedCounts.contains(download.itemID)
        }.count
        return FeedCancelReturn(byItself: byItself, byDownload: stopped.count - byItself)
    }

    /// Asks again for the downloads a network with data limits put off whose
    /// items the newest-N rule still counts (`countedItemIDs(in:under:)`),
    /// working out each feed's count once; the others stay put off for the
    /// rule's pass to take back (REV11 F3).
    private func retryCountedPutOffDownloads() {
        var counted: [UUID: Set<FeedItem.ID>] = [:]
        downloads.retryPutOffDownloads { request in
            let feedCounts = counted[request.feedID] ?? store.record(of: request.feedID).map {
                Self.countedItemIDs(in: $0, under: itemPolicy(of: request.feedID))
            } ?? []
            counted[request.feedID] = feedCounts
            return feedCounts.contains(request.itemID)
        }
    }

    /// Passes a download's event on to the engine's listeners, and, when a
    /// download the newest-N rule made finishes, asks for the rule's pass
    /// over its feed, which removes the files of its oldest downloads beyond
    /// the newest should it now hold more than the number (FR11).
    private func downloadEventHappened(_ event: FeedEvent) {
        events.send(event)
        if case .downloadFinished(let feedID, let itemID, _) = event,
           store.record(of: feedID)?.item(itemID)?.downloadOrigin == .window {
            requestItemPolicyPass(for: [feedID])
        }
    }

    // MARK: Downloading

    /// Downloads the item `itemID` of the feed `feedID` because the listener
    /// asked (Download, or trying a failed download again). An item moved
    /// into the library, whose book the library still lists, is never
    /// downloaded again (FR11, branch D). A reader waiting for the item to
    /// go on to it asks `startingNext`, to have it ahead of the downloads
    /// queued before it, without opening it.
    func download(_ itemID: FeedItem.ID, of feedID: UUID, startingNext: Bool = false) {
        guard libraryBook(of: itemID, in: feedID) == nil else { return }
        downloads.download(itemID, of: feedID, origin: .listener, startingNext: startingNext)
    }

    /// Opens the item `itemID` of the feed `feedID`: its book at once when
    /// it is downloaded, or moved into the library (FR11, branch D), or else
    /// once it has downloaded, ahead of the others waiting, as a book in the
    /// cloud downloads before it opens.
    func open(_ itemID: FeedItem.ID, of feedID: UUID) {
        if let book = libraryBook(of: itemID, in: feedID) {
            library?.openFeedBook(book.id)
            return
        }
        downloads.download(itemID, of: feedID, origin: .listener, opening: true)
    }

    /// The book the item `itemID` of the feed `feedID` became in the library
    /// by Move to Library… (FR11, branch D), while the library lists it.
    func libraryBook(of itemID: FeedItem.ID, in feedID: UUID) -> Book? {
        guard let bookID = store.record(of: feedID)?.item(itemID)?.state.libraryBookID else { return nil }
        return library?.feedBook(withID: bookID)
    }

    /// Stops the download of the item `itemID` of the feed `feedID`, or takes
    /// it out of the queue, as Cancel Download does: the item is the
    /// listener's from then on, so the newest-N rule never downloads it again
    /// by itself (FR11). A download whose book is already being added to the
    /// library comes too late to stop, and finishes
    /// (`FeedDownloadManager.cancel(_:of:)`): it stays whoever's it was, so
    /// one the rule asked for stays the rule's, to remove once it is no
    /// longer among the newest.
    /// - Returns: Whether the download stopped, or finishes all the same.
    @discardableResult
    func cancelDownload(_ itemID: FeedItem.ID, of feedID: UUID) -> FeedDownloadManager.CancelOutcome {
        let outcome = downloads.cancel(itemID, of: feedID)
        if outcome == .stopped {
            store.updateItem(itemID, of: feedID) { $0.downloadOrigin = .listener }
        }
        return outcome
    }

    /// The items of the feed `feedID` whose packages were kept with the
    /// listener's place after their files went (FR11, branch A2), which
    /// every refresh keeps in the feed's record.
    func keptRecordItemIDs(of feedID: UUID) -> Set<FeedItem.ID> {
        Set((library?.feedItemRows(of: feedID).kept ?? [:]).keys)
    }

    /// The state the library shows for `item` of the feed `feedID`: its own,
    /// except that an item whose book the library no longer lists, as after
    /// the book was deleted from the library, is not downloaded, whether it
    /// was its feed's download or moved into the library (FR11, branch D).
    func state(of item: FeedItem, in feedID: UUID) -> FeedItemState {
        if item.state.bookID != nil, downloadedRow(of: item, in: feedID) == nil {
            return .notDownloaded
        }
        if let bookID = item.state.libraryBookID, let library, library.feedBook(withID: bookID) == nil {
            return .notDownloaded
        }
        return item.state
    }

    /// The row of `item` of the feed `feedID` whose file is here, if the
    /// library lists one: found by the item's identity among the feed's rows
    /// (FR11), and otherwise by the book the item names, as a download made
    /// before FR11 is a book of the library's own until it moves into its
    /// feed's folder. Either lookup takes one step.
    func downloadedRow(of item: FeedItem, in feedID: UUID) -> Book? {
        guard let bookID = item.state.bookID, let library else { return nil }
        if let row = library.feedItemRows(of: feedID).downloaded[item.id], row.id == bookID {
            return row
        }
        return library.feedBook(withID: bookID)
    }

    // MARK: A Feed's Own Settings

    /// Lists the feed `feedID`'s items in the library folder `folderID` from
    /// now on, those already downloaded among them: a feed's downloads stay
    /// in the feed's own folder in the data directory, and the library
    /// folder only lists them, by the feed's ID (FR11), so all of them
    /// follow at once, and nothing moves on disk.
    func setFolder(_ folderID: UUID, of feedID: UUID) {
        store.update(feedID) { $0.feed.folderID = folderID }
    }

    /// Gives the feed `feedID` its own "List and download" choice and number
    /// (FR11), or nil to use the global setting. The list changes at once;
    /// when what it lists changes, the next check reads the feed whole, so a
    /// widened list brings back the entries a short one let go. The
    /// newest-N rule acts on the change once it has stayed unchanged for ten
    /// seconds (`itemPolicyChanged(for:)`).
    func setItemPolicy(_ policy: FeedItemPolicy?, of feedID: UUID) {
        guard let feed = store.record(of: feedID)?.feed, feed.itemPolicyOverride != policy else { return }
        store.update(feedID) { $0.feed.itemPolicyOverride = policy }
        itemPolicyChanged(for: [feedID])
    }

    /// How long the "List and download" choice and its number must stay
    /// unchanged before the newest-N rule acts on a change (FR11): ten
    /// seconds, so typing 15 in the number never passes through 1, removing
    /// what 1 would remove.
    static let itemPolicyQuietTime: Duration = .seconds(10)

    /// Whether a change of the choice or its number waits to be acted on
    /// (FR11).
    var isWaitingOnItemPolicyChange: Bool {
        itemPolicyWait != nil
    }

    /// Notes that the choice or its number changed for the feeds `feedIDs`,
    /// every feed when nil (FR11), and asks for the newest-N rule's pass
    /// over them once neither has changed for `itemPolicyQuietTime`, each
    /// change starting the wait over. The pass then downloads what a larger
    /// number newly counts, removes the rule's downloads beyond a smaller
    /// one, and, for a choice that downloads by hand, takes back the rule's
    /// downloads not yet under way and removes nothing. As the wait ends,
    /// the engine announces that the change took effect
    /// (`FeedEvent.itemPolicyApplied`), for VoiceOver to say so (branch C):
    /// the global change and each feed's own, both when both were made
    /// within one wait (feed review item 20). Only an engine working on its
    /// own waits; a test runs the pass itself.
    func itemPolicyChanged(for feedIDs: Set<UUID>?) {
        guard environment.worksOnItsOwn else { return }
        // The global change and the feeds' own are kept apart, so neither
        // hides the other from what VoiceOver hears.
        if let feedIDs {
            feedsWithChangedItemPolicy.formUnion(feedIDs)
        } else {
            globalItemPolicyChanged = true
        }
        itemPolicyWait?.cancel()
        let sleep = environment.sleep
        itemPolicyWait = Task { [weak self] in
            do {
                try await sleep(Self.itemPolicyQuietTime)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            let global = self.globalItemPolicyChanged
            let feeds = self.feedsWithChangedItemPolicy
            self.globalItemPolicyChanged = false
            self.feedsWithChangedItemPolicy = []
            self.itemPolicyWait = nil
            self.events.send(.itemPolicyApplied(global: global, feedIDs: feeds))
            // A global change covers every feed.
            self.requestItemPolicyPass(for: global ? nil : feeds)
        }
    }

    /// Moves each feed's retired number of entries kept
    /// (`Feed.keepEntriesOverride`) to a "List and download" choice of its
    /// own (FR11), once: a feed whose record still holds one gets the choice
    /// it asks for under the global choice
    /// (`FeedItemPolicy.migrated(keepEntriesOverride:under:)`), unless it
    /// has a choice of its own already, and loses the override, which marks
    /// the move as made; its record is written then. "Finish It!", which
    /// keeps every entry, uses the global setting from then on. Runs once
    /// the records have loaded, and again as records that were only in the
    /// cloud arrive.
    /// - Returns: The feeds whose overrides moved, by title.
    @discardableResult
    func moveKeptEntriesOverrides() -> [UUID] {
        let global = settings.itemPolicy
        var moved: [UUID] = []
        for feed in store.feeds {
            guard let entries = feed.keepEntriesOverride else { continue }
            let own = feed.itemPolicyOverride ?? FeedItemPolicy.migrated(keepEntriesOverride: entries, under: global)
            store.update(feed.id) { record in
                record.feed.itemPolicyOverride = own
                record.feed.keepEntriesOverride = nil
            }
            moved.append(feed.id)
            let kept = entries < 0 ? "every entry" : CountWording.phrase(entries, singular: "entry", plural: "entries")
            let choice = own.map { "\($0.choice.rawValue) counting \($0.newestCount)" } ?? "the global setting"
            DiagnosticLog.event(.feeds, "FEED_ITEM_POLICY_MOVED: \(feed.title): keeping \(kept) became \(choice)")
        }
        return moved
    }

    /// Gives the feed `feedID` its own days after playing that a download is
    /// deleted, or nil to follow the setting.
    func setDeleteDownloadsDaysAfterPlayed(_ days: Int?, of feedID: UUID) {
        store.update(feedID) {
            $0.feed.deleteDownloadsDaysAfterPlayedOverride = days.map(SettingsPolicy.feedDeleteDownloadsDaysAfterPlayed.validated)
        }
    }

    /// Gives the feed `feedID` its own listening options (FR19), or none
    /// when `options` is nil or standard: standard options are never stored,
    /// so a feed left as it was keeps a record exactly as it was. Writes the
    /// record only when its durable form changed, so setting what the feed
    /// already has writes nothing.
    func setListeningOptions(_ options: ListeningOptions?, of feedID: UUID) {
        let stored = options.flatMap { $0.isStandard ? nil : $0 }
        store.update(feedID) { $0.feed.listeningOptions = stored }
    }
}

extension FeedAddress {
    /// What two addresses of one feed share whatever their scheme, letter
    /// case of host, or trailing slash: its host, path, and query.
    static func comparisonKey(_ url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        var path = url.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        return host + path + (url.query.map { "?" + $0 } ?? "")
    }
}

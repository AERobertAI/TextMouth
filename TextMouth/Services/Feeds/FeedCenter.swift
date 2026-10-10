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
    /// - Returns: The removals to make.
    /// - Throws: `FeedItemPackageError.indexNotWritten`, with nothing
    ///   changed.
    func readyFeedFilesForRemoval(of books: [Book], keepingPackages: Bool) throws -> [FeedFileRemoval]
    /// The last part of `removeFeedFiles(of:keepingPackages:remove:)`, once
    /// the files of `removals` have gone, but for those `failures` names
    /// with why, whose rows go back where they were.
    func settleFeedFileRemovals(_ removals: [FeedFileRemoval], failures: [UUID: any Error]) -> FeedFileRemovalOutcome
    /// The books open in readers now, which nothing may delete.
    var feedBooksOpenInReaders: Set<UUID> { get }
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

/// Why subscribing to an address failed (FR03), in sentences a listener reads.
enum FeedSubscribeError: Error, Equatable, Sendable {
    /// The address is not an http or https address.
    case invalidAddress
    /// The folder chosen for the feed's downloads is gone.
    case folderMissing
    /// The feed is subscribed already, under the title given.
    case alreadySubscribed(title: String)
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
            now: environment.now
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
            startSchedule()
            if settings.refreshAtLaunch {
                await refreshAll(origin: .launch)
            }
        }
    }

    /// Stops the scheduled refreshes, as when a test ends.
    func stop() {
        schedule?.cancel()
        schedule = nil
        intervalObserver = nil
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
            throw FeedSubscribeError.alreadySubscribed(title: existing.title)
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
                throw FeedSubscribeError.alreadySubscribed(title: existing.title)
            }
            record.feed.folderID = try folderID(for: record.feed, choice: choice)
            store.add(record)
            fetchStates.update(record.feed.id) { state in
                state.etag = body.etag
                state.lastModified = body.lastModified
                state.bodyDigest = body.digest
                state.keptEntriesOfLastBody = keepEntries
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
    /// trailing slash, if there is one.
    func subscribedFeed(at url: URL) -> Feed? {
        let key = FeedAddress.comparisonKey(url)
        return store.feeds.first { FeedAddress.comparisonKey($0.feedURL) == key }
    }

    /// Ends the subscription `feedID`: its record and this Mac's fetch
    /// details go, and every book it downloaded stays in its folder.
    func unsubscribe(_ feedID: UUID) {
        guard let feed = store.record(of: feedID)?.feed else { return }
        downloads.cancelAll(of: feedID)
        store.remove(feedID)
        fetchStates.remove(feedID)
        DiagnosticLog.event(.feeds, "FEED_UNSUBSCRIBED: \(feed.title)")
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
    /// rule's pass over the feed (FR11), which downloads its newest and
    /// removes its oldest downloads beyond them, trying its failed downloads
    /// again when the refresh reached the network. A refresh TextMouth made
    /// by itself that was not put off reached a network without data limits,
    /// which such a refresh needs, so the downloads one put off are tried
    /// again first.
    private func refreshEnded(_ report: FeedRefreshReport) {
        events.send(.refreshed(report))
        requestSweep()
        if report.origin.isDiscretionary, report.outcome != .skipped {
            downloads.retryPutOffDownloads()
        }
        requestItemPolicyPass(for: [report.feedID], retryingFailures: report.outcome != .skipped)
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
    /// asked (Download, or trying a failed download again).
    func download(_ itemID: FeedItem.ID, of feedID: UUID) {
        downloads.download(itemID, of: feedID, origin: .listener)
    }

    /// Opens the item `itemID` of the feed `feedID`: its book at once when
    /// it is downloaded, or else once it has downloaded, ahead of the others
    /// waiting, as a book in the cloud downloads before it opens.
    func open(_ itemID: FeedItem.ID, of feedID: UUID) {
        downloads.download(itemID, of: feedID, origin: .listener, opening: true)
    }

    /// Stops the download of the item `itemID` of the feed `feedID`, or takes
    /// it out of the queue, as Cancel Download does: the item is the
    /// listener's from then on, so the newest-N rule never downloads it again
    /// by itself (FR11).
    func cancelDownload(_ itemID: FeedItem.ID, of feedID: UUID) {
        downloads.cancel(itemID, of: feedID)
        store.updateItem(itemID, of: feedID) { $0.downloadOrigin = .listener }
    }

    /// The items of the feed `feedID` whose packages were kept with the
    /// listener's place after their files went (FR11, branch A2), which
    /// every refresh keeps in the feed's record.
    func keptRecordItemIDs(of feedID: UUID) -> Set<FeedItem.ID> {
        Set((library?.feedItemRows(of: feedID).kept ?? [:]).keys)
    }

    /// The state the library shows for `item` of the feed `feedID`: its own,
    /// except that an item whose book the library no longer lists, as after
    /// the book was deleted from the library, is not downloaded.
    func state(of item: FeedItem, in feedID: UUID) -> FeedItemState {
        if item.state.bookID != nil, downloadedRow(of: item, in: feedID) == nil {
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

    /// Sends the feed `feedID`'s downloads to the library folder `folderID`
    /// from now on; the books it downloaded stay where they are.
    func setFolder(_ folderID: UUID, of feedID: UUID) {
        store.update(feedID) { $0.feed.folderID = folderID }
    }

    /// Gives the feed `feedID` its own "List and download" choice and number
    /// (FR11), or nil to use the global setting. The list changes at once;
    /// when what it lists changes, the next check reads the feed whole, so a
    /// widened list brings back the entries a short one let go.
    func setItemPolicy(_ policy: FeedItemPolicy?, of feedID: UUID) {
        store.update(feedID) { $0.feed.itemPolicyOverride = policy }
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

    /// Gives the feed `feedID` its own retired number of entries kept, or
    /// nil to follow the retired setting, as Feed Info's old control does
    /// until the interface of the "List and download" choice takes its
    /// place. The engine lists by the choice, so the number counts only once
    /// the move to the choice turns it into a choice of the feed's own, at
    /// the next refresh of every feed or the next launch
    /// (`moveKeptEntriesOverrides()`).
    func setKeepEntries(_ entries: Int?, of feedID: UUID) {
        store.update(feedID) { $0.feed.keepEntriesOverride = entries.map(SettingsPolicy.feedKeepEntries.validated) }
    }

    /// Gives the feed `feedID` its own days after playing that a download is
    /// deleted, or nil to follow the setting.
    func setDeleteDownloadsDaysAfterPlayed(_ days: Int?, of feedID: UUID) {
        store.update(feedID) {
            $0.feed.deleteDownloadsDaysAfterPlayedOverride = days.map(SettingsPolicy.feedDeleteDownloadsDaysAfterPlayed.validated)
        }
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

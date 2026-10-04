import Combine
import Foundation

// MARK: - What the Feed Engine Works With (FR03)

/// What the feed engine works with (FR03): the app's own, or a test's.
struct FeedEnvironment {
    /// Where the feeds' records are kept.
    var records: FeedStore.Location
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
    /// Deletes a book's package as the listener's own deletions do, to the
    /// Trash or for good as the removal setting says (Delete Download).
    var deleteBookPackage: @MainActor (Book) throws -> Void

    /// The app's: the data directory's Feeds folder, this Mac's Caches, the
    /// network, and the app's preferences. A process hosting tests never
    /// works on its own, and its network refuses every request.
    @MainActor static var app: FeedEnvironment {
        FeedEnvironment(
            records: .app,
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
            deleteBookPackage: { try FileImportService.deleteBookPackage($0) }
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
    /// Lists a book a feed download published, and saves the library.
    func addFeedBook(_ book: Book)
    /// Takes out of the library a book whose package was deleted, and saves
    /// the library.
    func removeFeedBook(_ book: Book)
    /// The books open in readers now, which nothing may delete.
    var feedBooksOpenInReaders: Set<UUID> { get }
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
        announce: { [weak self] event in self?.events.send(event) }
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
    /// Whether a sweep of played downloads runs (`requestSweep()`).
    var isSweeping = false
    /// Whether a sweep was asked for while one ran, so it runs again.
    var sweepRequestedAgain = false

    /// An engine working with `environment`, started by `start(library:)`.
    init(environment: FeedEnvironment) {
        self.environment = environment
        store = FeedStore(location: environment.records)
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
        }
    }

    /// The feed settings in force.
    var settings: FeedSettings {
        FeedSettings.read(from: environment.preferences)
    }

    // MARK: Starting

    /// Starts the engine in `library`, once: reads the records and this
    /// Mac's fetch details off the main thread, then, when the engine works
    /// on its own, asks again for the downloads TextMouth quit during,
    /// refreshes every feed if the settings say to, and starts the scheduled
    /// refreshes. Returns at once.
    /// - Returns: The work started, which tests may await.
    @discardableResult
    func start(library: FeedLibraryHost) -> Task<Void, Never>? {
        guard !hasStarted else { return nil }
        hasStarted = true
        self.library = library
        return Task {
            await store.load()
            await fetchStates.load()
            await downloads.sweepLeftovers()
            guard environment.worksOnItsOwn else { return }
            // The downloads under way when TextMouth last quit go on, the
            // one that ran from where it stopped.
            await downloads.resumeDownloadsSavedAtQuit()
            // A reader closing lets a played download it held be deleted.
            lifecycleObservers.append(
                library.feedBooksOpenInReadersChanges.sink { [weak self] _ in self?.requestSweep() }
            )
            requestSweep()
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

    /// The items of the feed `feedID` the library lists, newest first.
    func listedItems(of feedID: UUID) -> [FeedItem] {
        store.record(of: feedID)?.listedItems ?? []
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
        let keepEntries = settings.keepEntries
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

    /// Refreshes every feed, and announces one summary.
    @discardableResult
    func refreshAll(origin: FeedRefreshOrigin = .listener) async -> FeedRefreshSummary {
        let summary = await refresher.refreshAll(origin: origin)
        events.send(.refreshedAll(summary))
        return summary
    }

    /// Announces the end of one feed's refresh, and, with automatic downloads
    /// on, downloads the items it found new.
    private func refreshEnded(_ report: FeedRefreshReport) {
        events.send(.refreshed(report))
        requestSweep()
        guard settings.autoDownload else { return }
        for itemID in report.newItemIDs {
            downloads.download(itemID, of: report.feedID, origin: .automatic)
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
    /// it out of the queue.
    func cancelDownload(_ itemID: FeedItem.ID, of feedID: UUID) {
        downloads.cancel(itemID, of: feedID)
    }

    /// The state the library shows for `item`: its own, except that an item
    /// whose book the library no longer lists, as after the book was deleted
    /// from the library, is not downloaded.
    func state(of item: FeedItem) -> FeedItemState {
        if let bookID = item.state.bookID, library?.feedBook(withID: bookID) == nil {
            return .notDownloaded
        }
        return item.state
    }

    // MARK: A Feed's Own Settings

    /// Sends the feed `feedID`'s downloads to the library folder `folderID`
    /// from now on; the books it downloaded stay where they are.
    func setFolder(_ folderID: UUID, of feedID: UUID) {
        store.update(feedID) { $0.feed.folderID = folderID }
    }

    /// Gives the feed `feedID` its own number of entries kept, or nil to
    /// follow the setting; the next refresh applies it, reading the feed
    /// whole again even when it has not changed.
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

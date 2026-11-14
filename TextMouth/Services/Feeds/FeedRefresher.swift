import Foundation

// MARK: - Why a Refresh Failed (FR03)

/// Why a feed could not be refreshed or subscribed to (FR03): its fetch
/// failed, or what came back is no feed TextMouth reads.
enum FeedRefreshError: Error, Equatable, Sendable {
    /// The fetch failed.
    case fetch(FeedFetchError)
    /// The document could not be read as a feed.
    case parse(FeedParseError)

    /// The sentence the library shows and VoiceOver speaks about a feed
    /// named `name` at `host`.
    func message(about name: String, host: String) -> String {
        switch self {
        case .fetch(let error):
            return error.message(about: name)
        case .parse(.empty):
            return "The feed at \(host) is empty."
        case .parse(.tooLarge):
            return FeedFetchError.tooLarge(host: host).message(about: name)
        case .parse(.notAFeed):
            return "The address of \(name) doesn't hold a feed TextMouth can read."
        case let .parse(.damaged(problem, line, _)):
            return "The feed is damaged at line \(line): \(problem)."
        }
    }

    /// Whether the refresh was only put off: a refresh TextMouth made by
    /// itself, refused on an expensive or constrained network, or stopped.
    var isPostponement: Bool {
        self == .fetch(.constrainedNetwork) || self == .fetch(.cancelled)
    }
}

// MARK: - What a Refresh Reports

/// Who started a refresh.
enum FeedRefreshOrigin: Equatable, Sendable {
    /// TextMouth, as it opened (`FeedSettings.refreshAtLaunch`).
    case launch
    /// TextMouth, on the interval setting (`FeedSettings.refreshIntervalHours`).
    case scheduled
    /// The listener (Check Feed, or Refresh All Feeds).
    case listener

    /// Whether the refresh is work the listener did not ask for, which waits
    /// for a network without data limits and skips a feed that is gone.
    var isDiscretionary: Bool {
        self != .listener
    }
}

/// How one feed's refresh ended (FR03).
struct FeedRefreshReport: Equatable, Sendable {
    /// How it ended.
    enum Outcome: Equatable, Sendable {
        /// The feed was read: what it brought.
        case updated(newItemIDs: [FeedItem.ID])
        /// The feed has not changed: the server said so, or sent the same
        /// bytes as last time.
        case unchanged
        /// The refresh failed, for the reason given, which the library shows.
        case failed(String)
        /// The refresh was not made: TextMouth was offline, on a network
        /// with data limits, or the feed is gone, and it waits for its next
        /// turn.
        case skipped
    }

    /// The feed refreshed.
    var feedID: UUID
    /// The feed's title when the refresh ended.
    var feedTitle: String
    /// Who started it.
    var origin: FeedRefreshOrigin
    /// How it ended.
    var outcome: Outcome

    /// The items that arrived as new.
    var newItemIDs: [FeedItem.ID] {
        if case .updated(let ids) = outcome { return ids }
        return []
    }

    /// Why it failed, if it did.
    var failure: String? {
        if case .failed(let message) = outcome { return message }
        return nil
    }
}

/// How a refresh of every feed ended.
struct FeedRefreshSummary: Equatable, Sendable {
    /// Who started it.
    var origin: FeedRefreshOrigin
    /// Each feed's report, by title.
    var reports: [FeedRefreshReport]

    /// How many items arrived as new, in every feed.
    var newItemCount: Int {
        reports.reduce(0) { $0 + $1.newItemIDs.count }
    }

    /// The titles of the feeds whose refresh failed.
    var failedFeedTitles: [String] {
        reports.filter { $0.failure != nil }.map(\.feedTitle)
    }
}

// MARK: - Refreshing

/// Refreshes feeds (FR03): fetches each with a conditional request, skips
/// one whose body has not changed, reads and merges the rest
/// (`FeedReconciler`), and records how each check ended.
///
/// A fetch sends the ETag and Last-Modified date the last one received
/// (If-None-Match and If-Modified-Since), and 304 means nothing changed; of
/// the three real podcast feeds the research tried, one answered 304 and
/// the others sent every byte again, so a body whose SHA-256 digest matches
/// the last one is neither read again nor saved either. Both hold only
/// while the feed keeps as many entries as when its last body was read: a
/// changed listing (the "List and download" choice or its number, FR11)
/// reads the feed whole again, so it applies at the next check, a widened
/// list bringing back the entries a short one let go. A record that does
/// not know its feed's size (`Feed.entryTotal`),
/// written before TextMouth recorded it, reads its feed whole once too, so
/// the size is known from that check on; so does a record that does not
/// hold the merge of the last body read, its write having waited for the
/// data directory or failed before TextMouth quit
/// (`FeedFetchState.lastBodyIsMerged(into:)`), so the next launch's check
/// merges that body again rather than hiding its new items. A feed that
/// moved for good, by a permanent redirect or its own
/// `itunes:new-feed-url`, is fetched from its new address from then on. A
/// refresh that ends after its feed was unsubscribed changes nothing.
///
/// Everything slow happens off the main actor: the fetch, and the parse and
/// first merge, which read the items' texts. The main actor then merges the
/// result into the record as it is by then, so what the listener did
/// meanwhile (a download, a played episode) is kept, and records the
/// outcome. A feed's refreshes never overlap: a second request for a feed
/// being refreshed waits for that refresh and reports its outcome. A
/// failure is recorded for its feed alone and never stops the others.
///
/// A feed the listener unsubscribed from (`Feed.isSubscribed`, FR11, branch
/// D) is never checked: not at launch, on the interval, or in Refresh All
/// Feeds, which pass over it, nor by Check Feed, which the library does not
/// offer for it; and a refresh under way as it is unsubscribed changes
/// nothing, as one whose feed is gone changes nothing.
@MainActor
final class FeedRefresher {
    /// The records.
    private let store: FeedStore
    /// This Mac's fetch details.
    private let fetchStates: FeedFetchStates
    /// The network.
    private let network: FeedNetwork
    /// The feed settings now.
    private let settings: () -> FeedSettings
    /// The time now.
    private let now: @Sendable () -> Date
    /// The items of a feed whose packages were kept with the listener's
    /// place after their files went, which every merge keeps (FR11).
    private let keptRecords: (UUID) -> Set<FeedItem.ID>
    /// Told which feeds are refreshing, whenever that changes.
    private let refreshingChanged: (Set<UUID>) -> Void
    /// Told of each refresh that ended.
    private let reportRefresh: (FeedRefreshReport) -> Void
    /// The refresh under way of each feed.
    private var running: [UUID: Task<FeedRefreshReport?, Never>] = [:] {
        didSet { refreshingChanged(refreshingFeedIDs) }
    }

    /// A refresher of `store`'s feeds through `network`, recording each
    /// check in `fetchStates`, telling `refreshingChanged` which feeds are
    /// refreshing, and `reportRefresh` how each refresh ended. Each merge
    /// keeps the items `keptRecords` names for a feed, whose packages were
    /// kept with the listener's place after their files went (FR11).
    init(
        store: FeedStore,
        fetchStates: FeedFetchStates,
        network: FeedNetwork,
        settings: @escaping () -> FeedSettings,
        now: @escaping @Sendable () -> Date,
        keptRecords: @escaping (UUID) -> Set<FeedItem.ID> = { _ in [] },
        refreshingChanged: @escaping (Set<UUID>) -> Void,
        reportRefresh: @escaping (FeedRefreshReport) -> Void
    ) {
        self.store = store
        self.fetchStates = fetchStates
        self.network = network
        self.settings = settings
        self.now = now
        self.keptRecords = keptRecords
        self.refreshingChanged = refreshingChanged
        self.reportRefresh = reportRefresh
    }

    /// The feeds being refreshed now.
    var refreshingFeedIDs: Set<UUID> {
        Set(running.keys)
    }

    /// Refreshes the feed `feedID`, or waits for the refresh of it under way,
    /// and returns how it ended; nil when the feed is not subscribed: gone,
    /// or unsubscribed (FR11, branch D), which is never checked, so it
    /// never even shows as checking.
    @discardableResult
    func refresh(_ feedID: UUID, origin: FeedRefreshOrigin) async -> FeedRefreshReport? {
        if let underWay = running[feedID] {
            return await underWay.value
        }
        guard isChecked(feedID) else { return nil }
        let refresh = Task { await perform(feedID, origin: origin) }
        running[feedID] = refresh
        let report = await refresh.value
        running[feedID] = nil
        if let report {
            reportRefresh(report)
        }
        return report
    }

    /// Refreshes every feed the listener is subscribed to, at most
    /// `concurrency` at once, and returns each one's report, by title; a
    /// feed unsubscribed from (FR11, branch D) is passed over, with no
    /// report.
    func refreshAll(origin: FeedRefreshOrigin, concurrency: Int = 4) async -> FeedRefreshSummary {
        await store.loadRecordsInCloud()
        let feedIDs = store.feeds.filter(\.isSubscribed).map(\.id)
        var reports: [FeedRefreshReport] = []
        await withTaskGroup(of: FeedRefreshReport?.self) { group in
            var next = 0
            // Keeps at most `concurrency` refreshes under way.
            func startNext() {
                guard next < feedIDs.count else { return }
                let feedID = feedIDs[next]
                next += 1
                group.addTask { await self.refresh(feedID, origin: origin) }
            }
            for _ in 0..<max(1, concurrency) {
                startNext()
            }
            while let report = await group.next() {
                if let report {
                    reports.append(report)
                }
                startNext()
            }
        }
        reports.sortStably { $0.feedTitle.localizedStandardCompare($1.feedTitle) == .orderedAscending }
        return FeedRefreshSummary(origin: origin, reports: reports)
    }

    // MARK: One Refresh

    /// Whether the feed `feedID` is one TextMouth checks: its record is
    /// here, and says the listener is subscribed (FR11, branch D).
    private func isChecked(_ feedID: UUID) -> Bool {
        store.record(of: feedID)?.feed.isSubscribed == true
    }

    /// Refreshes the feed `feedID` once.
    private func perform(_ feedID: UUID, origin: FeedRefreshOrigin) async -> FeedRefreshReport? {
        guard let record = store.record(of: feedID), record.feed.isSubscribed else { return nil }
        let fetchState = fetchStates.state(of: feedID)
        let host = FeedHost.of(record.feed.feedURL)
        /// The report of this refresh, with the feed's title as it is now.
        func report(_ outcome: FeedRefreshReport.Outcome) -> FeedRefreshReport {
            FeedRefreshReport(
                feedID: feedID,
                feedTitle: store.record(of: feedID)?.feed.title ?? record.feed.title,
                origin: origin,
                outcome: outcome
            )
        }

        if origin.isDiscretionary, fetchState.isGone || !network.reachability.isOnline() {
            DiagnosticLog.trace(.feeds, "refresh of a feed at \(host) put off: \(fetchState.isGone ? "gone" : "offline")")
            return report(.skipped)
        }

        let started = now()
        // The entries the feed's listing keeps (FR11): every one, or the
        // newest of the short list.
        let keepEntries = record.feed.itemPolicy(under: settings()).listing.keptEntries
        let work = await Self.fetchAndRead(
            record,
            fetchState: fetchState,
            network: network,
            discretionary: origin.isDiscretionary,
            keepEntries: keepEntries,
            keptRecords: keptRecords(feedID),
            now: started
        )
        // A feed gone, or unsubscribed from (FR11, branch D), while it was
        // fetched is left alone, and its fetch details are not made again,
        // nor changed: the listener stopped its checking before this one
        // ended.
        guard isChecked(feedID) else { return nil }

        switch work {
        case let .unchanged(validators, movedTo):
            if let movedTo {
                store.update(feedID) { current in
                    guard current.feed.feedURL != movedTo else { return }
                    DiagnosticLog.event(
                        .feeds,
                        "FEED_MOVED: \(current.feed.title): from \(FeedHost.of(current.feed.feedURL)) to \(FeedHost.of(movedTo))"
                    )
                    current.feed.feedURL = movedTo
                }
            }
            fetchStates.update(feedID) { state in
                state.recordSuccess(at: started)
                if let validators {
                    state.etag = validators.etag
                    state.lastModified = validators.lastModified
                }
            }
            DiagnosticLog.trace(.feeds, "a feed at \(host) is unchanged")
            return report(.unchanged)

        case .read(let feed, let body, var texts):
            var merged = FeedReconciler.MergeResult()
            var keptEntries = keepEntries
            store.update(feedID) { current in
                let moved = Self.movedAddress(of: current.feed, body: body, feed: feed)
                if let moved {
                    DiagnosticLog.event(
                        .feeds,
                        "FEED_MOVED: \(current.feed.title): from \(FeedHost.of(current.feed.feedURL)) to \(FeedHost.of(moved))"
                    )
                    current.feed.feedURL = moved
                }
                // The listing in force now, which the choice may have
                // changed while the feed was fetched.
                keptEntries = current.feed.itemPolicy(under: settings()).listing.keptEntries
                merged = FeedReconciler.merge(
                    feed,
                    into: &current,
                    keepEntries: keptEntries,
                    now: started,
                    texts: &texts,
                    keepingRecordsOf: keptRecords(feedID)
                )
            }
            // The record as the store holds it after the merge, written or
            // not: its write may wait for the data directory, or fail, while
            // these details are written to this Mac's Caches at once, so they
            // note the record's date, which a later check compares with the
            // record it loads (`fetchAndRead`).
            let mergedRecord = store.record(of: feedID)
            fetchStates.update(feedID) { state in
                state.recordSuccess(at: started)
                state.noteBodyMerged(body, keptEntries: keptEntries, into: mergedRecord)
            }
            let title = store.record(of: feedID)?.feed.title ?? record.feed.title
            if let repair = feed.repair {
                DiagnosticLog.event(.feeds, "FEED_PARSE_REPAIRED: \(title) (\(host)): \(repair.description)")
            }
            if !merged.newItemIDs.isEmpty || merged.changed {
                DiagnosticLog.event(
                    .feeds,
                    "FEED_REFRESHED: \(title) (\(host)): \(merged.newItemIDs.count) new, "
                        + "\(merged.addedItemIDs.count) added, \(merged.removedItemIDs.count) removed"
                )
            }
            return report(.updated(newItemIDs: merged.newItemIDs))

        case .failed(let error):
            if origin.isDiscretionary, error.isPostponement || error == .fetch(.offline) {
                DiagnosticLog.trace(.feeds, "refresh of a feed at \(host) put off by the network")
                return report(.skipped)
            }
            let message = error.message(about: store.record(of: feedID)?.feed.title ?? record.feed.title, host: host)
            fetchStates.update(feedID) { state in
                state.lastCheck = started
                state.lastError = FeedRefreshFailure(message: message, date: started)
                state.isGone = error == .fetch(.gone)
            }
            DiagnosticLog.event(.feeds, "FEED_REFRESH_FAILED: \(record.feed.title) (\(host)): \(message)")
            return report(.failed(message))
        }
    }

    /// The address the feed `feed` should be fetched from from now on, or
    /// nil when it stays where it is: the address every redirect led to when
    /// all were permanent, else the address the document names as its new
    /// one (`itunes:new-feed-url`).
    private static func movedAddress(of current: Feed, body: FeedFetchedBody, feed: ParsedFeed) -> URL? {
        let moved = body.permanentURL ?? feed.newFeedURL.flatMap { FeedTransport.isWebAddress($0) ? $0 : nil }
        guard let moved, moved != current.feedURL else { return nil }
        return moved
    }

    // MARK: Fetching and Reading

    /// The validators a server sent with a body: its ETag and its
    /// Last-Modified date.
    struct Validators: Sendable {
        var etag: String?
        var lastModified: String?
    }

    /// What fetching and reading a feed found.
    enum Work: Sendable {
        /// The feed has not changed: a 304 (no new validators), or the same
        /// bytes as the last body read (the validators sent with them); with
        /// the address every redirect led to when all were permanent.
        case unchanged(Validators?, movedTo: URL?)
        /// The feed was read, its body kept for its validators and digest,
        /// with the texts the first merge read.
        case read(ParsedFeed, FeedFetchedBody, FeedTextCache)
        /// The fetch or the reading failed.
        case failed(FeedRefreshError)
    }

    /// Fetches `record`'s feed through `network` with the validators of
    /// `fetchState`, and, when it changed, `keepEntries` (the number of
    /// newest entries the feed's listing keeps, -1 for every one) differs
    /// from the number its last body was merged with, the record does not
    /// know the feed's size, or the record does not hold the merge of the
    /// last body read (`FeedFetchState.lastBodyIsMerged(into:)`), reads it
    /// and merges it into a copy of `record`, off the main actor, keeping
    /// the texts that merge read.
    nonisolated static func fetchAndRead(
        _ record: FeedRecord,
        fetchState: FeedFetchState,
        network: FeedNetwork,
        discretionary: Bool,
        keepEntries: Int,
        keptRecords: Set<FeedItem.ID> = [],
        now: Date
    ) async -> Work {
        // The last body counts only when it was merged keeping as many
        // entries as the record keeps now, the record knows the feed's
        // size, which a record written before TextMouth recorded it does
        // not, and the record holds that merge: one whose write waited or
        // failed, and never reached disk before TextMouth quit, was loaded
        // with an older date, and skipping the same bytes (or a 304) would
        // hide the merge's new items until the feed changed, which a
        // finished show never does. Validators mean something only beside
        // the digest of the body they came with, which is what decides that
        // nothing changed.
        let lastBodyCounts = fetchState.keptEntriesOfLastBody == keepEntries
            && record.feed.entryTotal != nil
            && fetchState.lastBodyIsMerged(into: record)
        let lastDigest = lastBodyCounts ? fetchState.bodyDigest : nil
        let fetched: FeedFetchResult
        do {
            fetched = try await network.fetch(
                record.feed.feedURL,
                etag: lastDigest != nil ? fetchState.etag : nil,
                lastModified: lastDigest != nil ? fetchState.lastModified : nil,
                discretionary: discretionary
            )
        } catch {
            return .failed(.fetch(FeedFetchError.from(error, host: FeedHost.of(record.feed.feedURL))))
        }
        let body: FeedFetchedBody
        switch fetched {
        case .notModified(let permanentURL):
            return .unchanged(nil, movedTo: permanentURL)
        case .body(let fetchedBody):
            body = fetchedBody
        }
        return await OffMainWork.run(on: .global(qos: .utility)) {
            if body.digest == lastDigest {
                return .unchanged(Validators(etag: body.etag, lastModified: body.lastModified), movedTo: body.permanentURL)
            }
            do {
                let feed = try FeedParser.parse(body.data, baseURL: body.finalURL)
                var copy = record
                var texts = FeedTextCache()
                FeedReconciler.merge(feed, into: &copy, keepEntries: keepEntries, now: now, texts: &texts, keepingRecordsOf: keptRecords)
                return .read(feed, body, texts)
            } catch let error as FeedParseError {
                return .failed(.parse(error))
            } catch {
                return .failed(.parse(.notAFeed))
            }
        }
    }
}

private extension FeedFetchState {
    /// Records a check that succeeded at `date`.
    mutating func recordSuccess(at date: Date) {
        lastCheck = date
        lastSuccess = date
        lastError = nil
        isGone = false
    }
}

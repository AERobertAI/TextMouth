import Foundation

// MARK: - The Newest-N Rule (FR11)

/// What one pass of the newest-N rule did (FR11, branch B), for the tests
/// and the debug log.
struct FeedItemPolicyPassReport: Equatable, Sendable {
    /// The downloads the pass asked for, each feed's newest first.
    var requestedItemIDs: [FeedItem.ID] = []
    /// The rule's downloads not yet under way that the pass took back: their
    /// items no longer counted among the newest, were played, or their
    /// feed's choice no longer downloads by itself.
    var withdrawnItemIDs: [FeedItem.ID] = []
    /// The downloads whose files the pass removed, by book ID, each feed's
    /// oldest first.
    var removedBookIDs: [UUID] = []
    /// Those of `removedBookIDs` whose packages stayed, holding the
    /// listener's place, bookmarks, settings, or transcript.
    var keptPackageBookIDs: [UUID] = []
    /// The downloads due to go but open in a reader, which covers one
    /// playing: looked at again at the next pass.
    var openBookIDs: [UUID] = []
    /// The downloads due to go but on the reading list, which the rule never
    /// removes.
    var onReadingListBookIDs: [UUID] = []
    /// The downloads due to go in a cloud library whose packages this Mac
    /// does not hold whole, left to a Mac that has them.
    var leftInCloudBookIDs: [UUID] = []
}

/// A pass of the newest-N rule asked for and not run yet (FR11): the feeds
/// it covers, and those whose failed downloads it tries again, as a pass
/// that follows a refresh does.
struct FeedItemPolicyPassRequest: Equatable, Sendable {
    /// The feeds the pass covers, every feed when nil.
    var feedIDs: Set<UUID>?
    /// The feeds whose failed downloads the pass tries again.
    var retryingFeedIDs: Set<UUID>

    /// This request and `other` run as one pass: the feeds of both, every
    /// feed when either covers every one, and the failed downloads of both
    /// tried again.
    func adding(_ other: FeedItemPolicyPassRequest) -> FeedItemPolicyPassRequest {
        FeedItemPolicyPassRequest(
            feedIDs: feedIDs.flatMap { mine in other.feedIDs.map { mine.union($0) } },
            retryingFeedIDs: retryingFeedIDs.union(other.retryingFeedIDs)
        )
    }
}

extension FeedCenter {
    /// Runs one pass of the newest-N rule (FR11) over the subscribed feeds
    /// `feedIDs`, every one when nil, trying again the failed downloads of
    /// the feeds `retrying`, and returns what it did.
    ///
    /// For a feed whose choice is "Every item listed, newest 5 downloaded":
    /// 1. It takes back the rule's downloads not yet under way whose items
    ///    no longer count: outside the newest, or played.
    /// 2. It asks for each of the newest items not played, unless it is
    ///    here, downloading, waiting for a network without data limits, the
    ///    listener's (`ruleMayDownload(_:)`), or failed and the feed not in
    ///    `retrying`, so a broken file never strains its server more than
    ///    once a refresh. Played items count among the newest, so playing
    ///    one never brings an older one in (the listener's answer 4). The
    ///    downloads are discretionary, waiting for a network without data
    ///    limits, and for room (`FeedItemState.waiting`).
    /// 3. When the rule holds more of the feed's downloads than the number,
    ///    it removes the files of its oldest ones outside the newest until
    ///    it holds the number, keeping each package that holds something of
    ///    the listener's, as Delete Download does (`removeDue`). It never
    ///    removes a download the listener asked for, one on the reading
    ///    list, one open in a reader (which covers one playing), or, in a
    ///    cloud library, one this Mac does not hold whole; those are passed
    ///    over and looked at again at the next pass (the listener's answer
    ///    5). A download that fails or waits removes nothing, so the
    ///    episodes ready to play never drop for a new one that could not
    ///    arrive.
    ///
    /// For a feed whose choice downloads by hand, it takes back the rule's
    /// downloads not yet under way and removes nothing. Nothing runs while
    /// the library's index is recovered, its list of books provisional.
    ///
    /// For a feed the listener unsubscribed from (FR11, branch D), whose
    /// rules stay in force while checking stops, the rule downloads nothing
    /// by itself: it takes back its downloads not yet under way, asks for
    /// none, and removes as step 3 says, so its downloads beyond the newest
    /// still go. The listener's Download still downloads a listed item.
    @discardableResult
    func applyItemPolicy(to feedIDs: Set<UUID>? = nil, retrying: Set<UUID> = []) async -> FeedItemPolicyPassReport {
        var report = FeedItemPolicyPassReport()
        guard let library, library.feedLibraryIsComplete else { return report }
        let global = FeedSettings.itemPolicy(in: environment.preferences)
        var due: [FeedDueRemoval] = []
        for feed in store.feeds where feedIDs?.contains(feed.id) ?? true {
            guard let record = store.record(of: feed.id) else { continue }
            guard case .newest(let count) = (feed.itemPolicyOverride ?? global).downloading else {
                report.withdrawnItemIDs += downloads.withdrawRuleDownloads(of: feed.id) { _ in true }
                continue
            }
            let newest = record.newestItems(count)
            if feed.isSubscribed {
                let counted = Set(newest.filter { $0.playedDate == nil }.map(\.id))
                report.withdrawnItemIDs += downloads.withdrawRuleDownloads(of: feed.id) { !counted.contains($0) }

                let asked = newest.filter { ruleDownloads($0, of: feed.id, retryingFailures: retrying.contains(feed.id)) }
                for item in asked {
                    downloads.download(item.id, of: feed.id, origin: .window)
                }
                report.requestedItemIDs += asked.map(\.id)
                if !asked.isEmpty {
                    DiagnosticLog.event(.feeds, "FEED_RULE_DOWNLOADS: \(feed.title): asked for \(asked.count) of the newest \(count)")
                }
            } else {
                // Unsubscribed: nothing downloads by itself, and what the
                // rule asked for before goes back.
                report.withdrawnItemIDs += downloads.withdrawRuleDownloads(of: feed.id) { _ in true }
            }

            due += dueRemovals(in: record, keeping: count, newest: Set(newest.map(\.id)), library: library, report: &report)
        }
        guard !due.isEmpty else { return report }

        let outcome = await removeDue(due, from: library, by: "the newest-N rule", at: environment.now(), putOffEvent: "FEED_RULE_PUT_OFF")
        report.leftInCloudBookIDs = outcome.leftInCloud
        report.removedBookIDs = outcome.removed.map(\.row.id)
        report.keptPackageBookIDs = outcome.removed.filter(\.keepsPackage).map(\.row.id)
        if !outcome.leftInCloud.isEmpty {
            DiagnosticLog.event(
                .feeds,
                "FEED_RULE_LEFT_IN_CLOUD: \(outcome.leftInCloud.count) download(s) outside the newest not wholly on this Mac left for a Mac that has them"
            )
        }
        return report
    }

    /// Whether the rule may ever download `item` by itself (FR11): it has
    /// downloaded it before, or nobody has; never once the listener has
    /// asked for it, deleted it, or stopped it (`FeedItem.downloadOrigin`),
    /// nor an item whose download, made before the rule, went, which was the
    /// listener's or played.
    static func ruleMayDownload(_ item: FeedItem) -> Bool {
        switch item.downloadOrigin {
        case .window:
            return true
        case .listener:
            return false
        case nil:
            return item.downloadDeletedDate == nil
        }
    }

    /// Whether this pass asks for `item`, one of the feed `feedID`'s newest:
    /// not played or deleted, one the rule may download, not downloaded by
    /// its record nor here, not downloading, not put off for a network, and
    /// failed only when `retryingFailures`. A wait for room is tried again.
    private func ruleDownloads(_ item: FeedItem, of feedID: UUID, retryingFailures: Bool) -> Bool {
        guard item.deletedDate == nil, item.playedDate == nil, Self.ruleMayDownload(item) else { return false }
        // An item its record names as downloaded is left for the sweep to
        // settle when its book is gone; and one whose row is here while its
        // record says otherwise, as an older TextMouth leaves it until the
        // launch marks it downloaded again, is never fetched a second time.
        guard item.state.bookID == nil, library?.feedItemRows(of: feedID).downloaded[item.id] == nil else { return false }
        guard !downloads.isDownloading(item.id, of: feedID), !downloads.isPutOff(item.id, of: feedID) else { return false }
        if item.state.failureReason != nil {
            return retryingFailures
        }
        return true
    }

    /// The rule's downloads of `record`'s feed to remove (FR11): when the
    /// rule holds more of them than `count`, its oldest outside the newest
    /// (`newest`), until it would hold `count`, less those it leaves alone,
    /// each noted in `report`: one open in a reader, or on the reading list.
    /// A download made before FR11, never the rule's, is not among them.
    private func dueRemovals(
        in record: FeedRecord,
        keeping count: Int,
        newest: Set<FeedItem.ID>,
        library: FeedLibraryHost,
        report: inout FeedItemPolicyPassReport
    ) -> [FeedDueRemoval] {
        let held = record.items.compactMap { item -> (item: FeedItem, book: Book)? in
            guard item.deletedDate == nil, item.downloadOrigin == .window,
                  let book = downloadedRow(of: item, in: record.feed.id) else { return nil }
            return (item, book)
        }
        var excess = held.count - count
        var due: [FeedDueRemoval] = []
        // Oldest first.
        for (item, book) in held.reversed() where excess > 0 && !newest.contains(item.id) {
            if library.feedBooksOpenInReaders.contains(book.id) {
                report.openBookIDs.append(book.id)
                continue
            }
            if library.feedBookIsOnReadingList(book.id) {
                report.onReadingListBookIDs.append(book.id)
                continue
            }
            guard book.isFeedItem else { continue }
            due.append(FeedDueRemoval(feedID: record.feed.id, itemID: item.id, book: book, reason: "outside the newest \(count)"))
            excess -= 1
        }
        return due
    }
}

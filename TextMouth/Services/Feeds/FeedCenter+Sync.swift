import Foundation

// FeedCenter+Sync.swift: the feed engine's half of syncing feeds between
// devices (FR56, phase 1). The pure merge (`SyncMerge.apply`) says what the
// winners do to this device's feeds; this carries it out through the store
// and the engine's own commands, so a synced change has the side effects the
// listener's would (the newest-N rule's pass after a choice changes, checking
// stopping at Unsubscribe).

extension FeedCenter {
    /// The subscriptions as the sync projects them, or nil until the records
    /// have loaded: before then the store holds none, which must never read
    /// as every feed removed (`SyncLibraryHost.syncFeeds`).
    var syncFeeds: [Feed]? {
        store.hasLoaded ? store.feeds : nil
    }

    /// Carries out what a merge does to the feeds: adds a record for each feed
    /// another device subscribed to, checking it at once when it is subscribed
    /// and the engine works on its own; writes each changed feed's synced
    /// fields through the engine's commands; and deletes each feed another
    /// device deleted, as Delete Feed… does, with this device's removal
    /// setting.
    /// A feed a person changed since the merge was made (`SyncFeedApplication.startFeeds`)
    /// keeps their change, as a book's row does (`SyncRowMerge`): none of the merge's fields
    /// goes over theirs, it is not deleted, and its keys are offered again, by when the
    /// person's change is recorded and outranks the merge's.
    /// - Returns: The feeds whose change did not land (the records not loaded,
    ///   a feed gone meanwhile or changed since the merge, one subscribed here
    ///   meanwhile, a deletion refused because a download is in use): their
    ///   keys are applied again at a later sync.
    func applySync(_ application: SyncFeedApplication) async -> Set<UUID> {
        let named = Set(application.feedsToAdd.map(\.id) + application.feedsToChange.map(\.id) + application.feedsToRemove)
        guard store.hasLoaded else { return named }
        var failed = Set<UUID>()
        for feed in application.feedsToAdd where !addSyncedFeed(feed) { failed.insert(feed.id) }
        for feed in application.feedsToChange where !changeSyncedFields(to: feed, from: application.startFeeds[feed.id]) {
            failed.insert(feed.id)
        }
        for feedID in application.feedsToRemove {
            // A feed a person changed since the merge was made waits: their change may bring it back.
            if let start = application.startFeeds[feedID], let current = store.record(of: feedID)?.feed,
               SyncFeedValues.values(of: [current]) != SyncFeedValues.values(of: [start]) {
                failed.insert(feedID)
                continue
            }
            do {
                // Nil: no record (gone already, which is the merge's aim) or a deletion under way.
                // Its library folder follows the folder's own keys, as the deleting device left it.
                if try await deleteFeed(feedID, leavingLibraryFolder: true) == nil, store.record(of: feedID) != nil { failed.insert(feedID) }
            } catch {
                failed.insert(feedID)
                DiagnosticLog.event(.feeds, "FEED_SYNC: a feed another device deleted stays for now (\(type(of: error)))") // l10n: no (debug log text, which stays English)
            }
        }
        return failed
    }

    /// Adds the record of `feed`, which another device subscribed to, unless
    /// this device has one of that ID already. Its newest date is moved to
    /// now, so the episodes out before it arrived are not new here. A
    /// subscribed feed is checked at once, as discretionary work (it waits
    /// for a network without data limits), so its folder lists its episodes.
    /// - Returns: False, adding nothing, when a feed of its address was
    ///   subscribed here since the merge was made: the next merge leaves the
    ///   copy out, as it leaves out any copy of a feed this device has.
    private func addSyncedFeed(_ feed: Feed) -> Bool {
        guard store.record(of: feed.id) == nil else { return true }
        let address = FeedAddress.comparisonKey(feed.feedURL)
        guard !store.feeds.contains(where: { FeedAddress.comparisonKey($0.feedURL) == address }) else { return false }
        var arriving = feed
        arriving.newestItemDate = max(feed.subscribedDate, environment.now())
        store.add(FeedRecord(feed: arriving))
        DiagnosticLog.event(.feeds, "FEED_SYNC: added \(feed.feedURL.host ?? "a feed") from another device") // l10n: no (debug log text, which stays English)
        guard arriving.isSubscribed, environment.worksOnItsOwn else { return true }
        let feedID = arriving.id
        Task { [weak self] in _ = await self?.refresher.refresh(feedID, origin: .scheduled) }
        return true
    }

    /// Writes the synced fields of `feed` to this device's record of it,
    /// through the commands the listener's changes take, and only where they
    /// differ and this device's value is still `start`'s (the record the
    /// merge was made from; nil writes every field that differs).
    /// - Returns: False for a feed this device no longer has, or one with a
    ///   field a person changed since `start`, which keeps their value.
    private func changeSyncedFields(to feed: Feed, from start: Feed?) -> Bool {
        guard let current = store.record(of: feed.id)?.feed else { return false }
        var keptAPersonsChange = false
        /// Whether the merge's value of `field` lands: it differs from this device's, and this
        /// device's is still the one the merge was made from.
        func lands<Value: Equatable>(_ field: KeyPath<Feed, Value>) -> Bool {
            guard current[keyPath: field] != feed[keyPath: field] else { return false }
            if let start, current[keyPath: field] != start[keyPath: field] {
                keptAPersonsChange = true
                return false
            }
            return true
        }
        if lands(\.feedURL) { store.update(feed.id) { $0.feed.feedURL = feed.feedURL } }
        if lands(\.folderID) { setFolder(feed.folderID, of: feed.id) }
        if lands(\.itemPolicyOverride) {
            // Not through `setItemPolicy`: its quiet time is for a number being typed, and its
            // announcement for the listener who made the change, on the other device. The rule's pass follows.
            store.update(feed.id) { $0.feed.itemPolicyOverride = feed.itemPolicyOverride }
            requestItemPolicyPass(for: [feed.id])
        }
        if lands(\.deleteDownloadsDaysAfterPlayedOverride) {
            setDeleteDownloadsDaysAfterPlayed(feed.deleteDownloadsDaysAfterPlayedOverride, of: feed.id)
        }
        if lands(\.listeningOptions) { setListeningOptions(feed.listeningOptions, of: feed.id) }
        if lands(\.unsubscribedDate) { applySyncedSubscription(of: feed, current: current) }
        return !keptAPersonsChange
    }

    /// Unsubscribes or subscribes again as another device did. Unsubscribing
    /// goes through `unsubscribe(_:)`, deleting none of the packages kept for
    /// removed downloads (nobody here was asked), and then takes the other
    /// device's date, so every device holds one value. Subscribing again
    /// clears the date at once, before the merge's baseline is taken, and
    /// checks the feed as discretionary work.
    private func applySyncedSubscription(of feed: Feed, current: Feed) {
        if let date = feed.unsubscribedDate {
            if current.isSubscribed { unsubscribe(feed.id) }
            store.update(feed.id) { $0.feed.unsubscribedDate = date }
        } else {
            store.update(feed.id) { $0.feed.unsubscribedDate = nil }
            DiagnosticLog.event(.feeds, "FEED_SYNC: \(current.title): subscribed again on another device") // l10n: no (debug log text, which stays English)
            guard environment.worksOnItsOwn else { return }
            let feedID = feed.id
            Task { [weak self] in _ = await self?.refresher.refresh(feedID, origin: .scheduled) }
        }
    }
}

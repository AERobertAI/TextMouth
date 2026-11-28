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
    /// - Returns: The feeds whose change did not land (the records not loaded,
    ///   a feed gone meanwhile, a deletion refused because a download is in
    ///   use): their keys are applied again at a later sync.
    func applySync(_ application: SyncFeedApplication) async -> Set<UUID> {
        let named = Set(application.feedsToAdd.map(\.id) + application.feedsToChange.map(\.id) + application.feedsToRemove)
        guard store.hasLoaded else { return named }
        var failed = Set<UUID>()
        for feed in application.feedsToAdd { addSyncedFeed(feed) }
        for feed in application.feedsToChange where !changeSyncedFields(to: feed) { failed.insert(feed.id) }
        for feedID in application.feedsToRemove {
            do {
                // Nil: no record (gone already, which is the merge's aim) or a deletion under way.
                if try await deleteFeed(feedID) == nil, store.record(of: feedID) != nil { failed.insert(feedID) }
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
    private func addSyncedFeed(_ feed: Feed) {
        guard store.record(of: feed.id) == nil else { return }
        var arriving = feed
        arriving.newestItemDate = max(feed.subscribedDate, environment.now())
        store.add(FeedRecord(feed: arriving))
        DiagnosticLog.event(.feeds, "FEED_SYNC: added \(feed.feedURL.host ?? "a feed") from another device") // l10n: no (debug log text, which stays English)
        guard arriving.isSubscribed, environment.worksOnItsOwn else { return }
        let feedID = arriving.id
        Task { [weak self] in _ = await self?.refresher.refresh(feedID, origin: .scheduled) }
    }

    /// Writes the synced fields of `feed` to this device's record of it,
    /// through the commands the listener's changes take, and only where they
    /// differ. Returns false for a feed this device no longer has.
    private func changeSyncedFields(to feed: Feed) -> Bool {
        guard let current = store.record(of: feed.id)?.feed else { return false }
        if current.feedURL != feed.feedURL { store.update(feed.id) { $0.feed.feedURL = feed.feedURL } }
        if current.folderID != feed.folderID { setFolder(feed.folderID, of: feed.id) }
        if current.itemPolicyOverride != feed.itemPolicyOverride {
            // Not through `setItemPolicy`: its quiet time is for a number being typed, and its
            // announcement for the listener who made the change, on the other device. The rule's pass follows.
            store.update(feed.id) { $0.feed.itemPolicyOverride = feed.itemPolicyOverride }
            requestItemPolicyPass(for: [feed.id])
        }
        if current.deleteDownloadsDaysAfterPlayedOverride != feed.deleteDownloadsDaysAfterPlayedOverride {
            setDeleteDownloadsDaysAfterPlayed(feed.deleteDownloadsDaysAfterPlayedOverride, of: feed.id)
        }
        if current.listeningOptions != feed.listeningOptions { setListeningOptions(feed.listeningOptions, of: feed.id) }
        if current.unsubscribedDate != feed.unsubscribedDate { applySyncedSubscription(of: feed, current: current) }
        return true
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

import Foundation

// MARK: - A Gone Feed's Downloads Return to the Library

/// What returning the downloads of one feed whose record is gone to the
/// library did (`LibraryViewModel.returnDownloads(ofFeed:toFolderID:removingWith:)`).
struct FeedDownloadReturn: Equatable {
    /// The downloads that are books of the library's own now, as the library
    /// lists them.
    var returned: [Book] = []
    /// The downloads that could not move, which stay in the feed's folder for
    /// the next launch to try again.
    var stayed: [Book] = []
    /// How many packages kept for removed downloads were deleted.
    var deletedKeptPackages = 0
    /// Whether the feed's folder is gone, its index with it.
    var removedFeedFolder = false
}

/// A feed whose record is truly gone gets its downloads back as books of the
/// library's own, at launch (REV10, item 3): the inverse of the first
/// launch's move of downloads into their feeds' folders
/// (`LibraryViewModel+FeedItemMove.swift`). Without its record nothing lists
/// a feed's items, so a download left in the feed's folder would be listed
/// nowhere.
///
/// Unsubscribe no longer comes here (FR11, branch D): it keeps the feed, its
/// record among the rest, so its downloads stay its items. A record is truly
/// gone when it was lost outside TextMouth, or when an Unsubscribe made by a
/// build before branch D deleted it and that build did not return the
/// downloads. The launch returns the downloads of every feed whose folder is
/// here while its record is gone, at the library's top level, since nothing
/// names that feed's library folder any more (in a cloud library, only once
/// this Mac has found the record gone at two launches, as another Mac's sync
/// can bring a feed's folder before its record: `FeedRecordAbsence`). Each
/// keeps its book ID, place, playback times, bookmarks, settings,
/// transcript, and place on the reading list. What the feed kept of
/// downloads removed earlier goes, since nothing can download them again
/// without the feed: the user accepted that for unsubscribing ("Clearing out
/// old deleted episodes itself seems fine").
extension LibraryViewModel {

    // MARK: At Launch

    /// Returns to the library, as books of its own at its top level, the
    /// downloads of every feed this launch takes for gone
    /// (`feedsTakenForGone(knownFeeds:absence:)`), one feed at a time, as
    /// `returnDownloads(ofFeed:toFolderID:removingWith:)` does. Called once
    /// the feeds' records have loaded.
    /// - Parameters:
    ///   - knownFeeds: The feeds whose records are known, subscribed or not:
    ///     unless a test gives its own, the feed engine's, read or found only
    ///     in the cloud.
    ///   - absence: How a record's absence is judged: where the data
    ///     directory is, this Mac, and this launch (`feedRecordAbsence`),
    ///     unless a test gives its own.
    ///   - remove: How a package kept for a removed download, and the feed's
    ///     folder, are removed: as the feed engine removes them (the Trash or
    ///     for good, as the removal setting says), unless a test gives its own.
    /// - Returns: How many downloads became books of the library's own.
    @discardableResult
    func returnDownloadsOfFeedsWithoutRecords(
        knownFeeds: Set<UUID>? = nil,
        absence: FeedRecordAbsence? = nil,
        removingWith remove: (@MainActor (URL) throws -> Void)? = nil
    ) async -> Int {
        var returned = 0
        for feedID in feedsTakenForGone(knownFeeds: knownFeeds, absence: absence ?? feedRecordAbsence) {
            returned += await returnDownloads(ofFeed: feedID, toFolderID: nil, removingWith: remove).returned.count
        }
        return returned
    }

    /// The feeds whose folders this library read at launch
    /// (`FeedShelf.indexedFeedIDs`) while none of `knownFeeds` (by default
    /// the feed engine's records, read or only in the cloud, once they have
    /// loaded, an unsubscribed feed's among them) is theirs and the records'
    /// folder, listed without downloading anything, shows no record of
    /// theirs and no placeholder of one
    /// (`FeedRecordAbsence.placeholderName(of:)`), in the order of their IDs.
    ///
    /// A record that can't be read, preserved and left out, still has its
    /// file, so its feed is not one. Nothing is decided while the records'
    /// folder cannot be listed without downloading it, while the feed
    /// engine's records have not loaded, or for a feed whose index is left
    /// alone (`FeedShelf.indexesLeftAlone`), whose rows here may be only some
    /// of its own.
    func feedsWithoutRecords(knownFeeds: Set<UUID>? = nil) -> [UUID] {
        recordPresence(knownFeeds: knownFeeds)?.gone ?? []
    }

    /// The feeds this launch takes for gone, whose downloads return to the
    /// library, in the order of their IDs: in a data directory that is not
    /// in a cloud location, every feed without its record
    /// (`feedsWithoutRecords(knownFeeds:)`); in a cloud one, only those this
    /// Mac also found without their records at an earlier launch, as the
    /// note it left beside each one's index then says (`FeedRecordAbsence`).
    /// A feed found without its record for the first time is noted and
    /// passed over, and a feed whose record is here has this Mac's notes
    /// taken away, so an absence counts only while it lasts.
    func feedsTakenForGone(knownFeeds: Set<UUID>? = nil, absence: FeedRecordAbsence) -> [UUID] {
        guard let presence = recordPresence(knownFeeds: knownFeeds) else { return [] }
        guard absence.isCloud else { return presence.gone }
        let root = TextMouthPaths.root
        for feedID in presence.here {
            absence.forgetNotes(ofFeed: feedID, in: FeedPaths.itemsFolder(of: feedID, in: root))
        }
        return presence.gone.filter { feedID in
            absence.wasGoneAtAnEarlierLaunch(feed: feedID, folder: FeedPaths.itemsFolder(of: feedID, in: root))
        }
    }

    /// How this launch judges a feed's record gone (`FeedRecordAbsence`):
    /// by whether the data directory is in a cloud location, as the feed
    /// engine's book storage says, this Mac's ID, and this launch.
    var feedRecordAbsence: FeedRecordAbsence {
        let isCloud = feeds.environment.bookStorage().libraryLocation().isCloud
        // Only a cloud library needs this Mac named, so the ID is read (and,
        // the first time, made) only for one.
        return FeedRecordAbsence(
            isCloud: isCloud,
            macID: isCloud ? LibrarySessionLease.shared.macID : "",
            launchID: FeedRecordAbsence.thisLaunch
        )
    }

    /// What this launch knows of the records of the feeds whose folders this
    /// library read (`FeedShelf.indexedFeedIDs`), each in the order of their
    /// IDs: those whose records are gone while their folders are here, and
    /// those whose records are here, known (`knownFeeds`, by default the feed
    /// engine's) or listed in the records' folder, a placeholder of one
    /// included. A feed whose index is left alone is in neither. Nil while
    /// nothing can be known: the feed engine's records have not loaded, or
    /// the records' folder cannot be listed without downloading it.
    private func recordPresence(knownFeeds: Set<UUID>?) -> (gone: [UUID], here: [UUID])? {
        let store = feeds.store
        let known = knownFeeds ?? (store.hasLoaded ? Set(store.records.keys).union(store.recordsInCloud) : nil)
        guard let known else { return nil }
        let decidable = library.feedShelf.indexedFeedIDs
            .subtracting(library.feedShelf.indexesLeftAlone)
            .sortedStably { $0.uuidString < $1.uuidString }
        var here = decidable.filter { known.contains($0) }
        let candidates = decidable.filter { !known.contains($0) }
        guard !candidates.isEmpty else { return ([], here) }
        let recordsFolder = store.location.currentFolder()
        let names: Set<String>
        do {
            names = Set(try DatalessFiles.withoutDownloading {
                try FileManager.default.contentsOfDirectory(atPath: recordsFolder.path)
            })
        } catch {
            return nil
        }
        let root = TextMouthPaths.root
        var gone: [UUID] = []
        for feedID in candidates {
            let recordName = FeedPaths.recordFile(of: feedID, in: recordsFolder).lastPathComponent
            if names.contains(recordName) || names.contains(FeedRecordAbsence.placeholderName(of: recordName)) {
                here.append(feedID)
            } else if FileManager.default.fileExists(atPath: FeedPaths.itemsFolder(of: feedID, in: root).path) {
                gone.append(feedID)
            }
        }
        return (gone, here.sortedStably { $0.uuidString < $1.uuidString })
    }

    // MARK: One Feed

    /// Turns the downloads of the feed `feedID`, whose record is gone, back
    /// into books of the library's own, in the library folder `folderID`
    /// names, or at the top level when it names none that is still there
    /// (as the launch asks, nothing naming it), and deletes what the feed
    /// kept of removed downloads.
    /// In order:
    ///
    /// 1. each download's package moves from the feed's folder into that
    ///    library folder, in one rename, and its record is written there,
    ///    without the feed link in its row (its record keeps the link, so
    ///    the book is still known to have come from a feed);
    /// 2. the rows become books of the library's own, and library.json is
    ///    written with them and waited for, while the feed's index on disk
    ///    is left as it is (`FeedShelf.leaveIndexAlone(of:)`), still listing
    ///    them;
    /// 3. only then does each package kept for a removed download go, and,
    ///    once no download stayed, the feed's folder with its index.
    ///
    /// A launch after a crash between any two steps finishes it. A package
    /// moved before library.json was written is adopted from the Library
    /// folder by the startup repair, under its own book ID, so its reading
    /// list place holds, and its row in the feed's index gives way to it
    /// (`joinFeedItems(journaled:access:skips:)`); then the launch returns
    /// the feed's other downloads, and deletes what is left of the feed's
    /// folder, since its record is gone
    /// (`returnDownloadsOfFeedsWithoutRecords(knownFeeds:absence:removingWith:)`;
    /// in a cloud library, at the second launch that finds it gone). A
    /// download that cannot move stays where it is, its package put back
    /// when its record could not be written, and the feed's folder stays
    /// with it, for the next launch to try again.
    ///
    /// It holds the storage work, as the move into the feeds' folders does,
    /// waits silently for work under way, and writes the saves already
    /// queued first; readers with a returning book open follow its package.
    /// It does nothing while the library index is recovered, the data
    /// directory is away or moving, or another operation holds the storage
    /// work; the next launch tries again. Nor does it do anything for a feed
    /// that left nothing (`leftSomething(feedID:)`), as one whose record went
    /// before it downloaded anything: no storage work, and no save.
    /// - Parameter remove: How a package kept for a removed download, and the
    ///   feed's folder, are removed: as the feed engine removes them, unless
    ///   a test gives its own.
    @discardableResult
    func returnDownloads(
        ofFeed feedID: UUID,
        toFolderID folderID: UUID?,
        removingWith remove: (@MainActor (URL) throws -> Void)? = nil
    ) async -> FeedDownloadReturn {
        guard canMoveDownloads, leftSomething(feedID: feedID) else { return FeedDownloadReturn() }
        guard let hold = try? StorageBoundary.shared.holdWork(for: .movingBooksBetweenFolders) else {
            DiagnosticLog.event(
                .storage,
                "FEED_DOWNLOADS_RETURN: \(feedID.uuidString.prefix(8)): put off, since another operation holds the storage "
                    + "work; the next launch returns them"
            )
            return FeedDownloadReturn()
        }
        defer { hold.release() }
        await hold.waitForWorkUnderWay { _ in }
        LibraryPersistenceService.flushPendingSave()

        // The library as it is now, after the wait; nothing below awaits, so
        // no other change can come between reading it and publishing it.
        guard canMoveDownloads else { return FeedDownloadReturn() }
        let remove = remove ?? feeds.environment.removeItem
        let root = TextMouthPaths.root
        let folderPath = folderID.flatMap { feedFolderPath(forFolderID: $0) } ?? ""
        let downloads = library.books.filter { $0.feedLink?.feedID == feedID }
        let returningIDs = Set(downloads.map(\.id))
        bookUpdates.packagesWillMove(returningIDs)
        defer { bookUpdates.packagesDidMove(returningIDs) }

        var outcome = FeedDownloadReturn()
        for row in downloads {
            do {
                outcome.returned.append(try Self.moveIntoTheLibrary(row, folderPath: folderPath, root: root))
            } catch {
                outcome.stayed.append(row)
                DiagnosticLog.event(
                    .storage,
                    "FEED_DOWNLOAD_RETURN_FAILED: \"\(row.title)\": \(error.localizedDescription); "
                        + "it stays in its feed's folder, and the next launch tries again"
                )
            }
        }

        var updated = library
        for row in outcome.returned {
            guard let index = updated.books.firstIndex(where: { $0.id == row.id }) else { continue }
            updated.books[index].fileLocation = row.fileLocation
        }
        let kept = updated.feedShelf.takeRows { $0.feedLink?.feedID == feedID }
        updated.feedShelf.leaveIndexAlone(of: feedID)
        library = updated
        guard LibraryPersistenceService.saveAndWait(library) else {
            // Reported and retried as every failed index write is; the
            // feed's folder keeps all it holds until library.json does.
            DiagnosticLog.event(
                .storage,
                "FEED_DOWNLOADS_RETURN: \(feedID.uuidString.prefix(8)): library.json could not be written, so the "
                    + "feed's folder keeps what it holds for the next launch"
            )
            return outcome
        }

        outcome.deletedKeptPackages = deleteKeptPackages(kept, of: feedID, root: root, remove: remove)
        if outcome.stayed.isEmpty, removeFeedFolder(of: feedID, root: root, remove: remove) {
            outcome.removedFeedFolder = true
            library.feedShelf.forgetIndex(of: feedID)
        }
        DiagnosticLog.event(
            .storage,
            "FEED_DOWNLOADS_RETURNED: \(feedID.uuidString.prefix(8)): "
                + "\(CountWording.phrase(outcome.returned.count, singular: "download", plural: "downloads")) of a feed "
                + "whose record is gone became books \(folderPath.isEmpty ? "at the library's top level" : "in its folder"); "
                + "deleted \(CountWording.phrase(outcome.deletedKeptPackages, singular: "package", plural: "packages")) "
                + "kept for removed downloads"
                + (outcome.stayed.isEmpty ? "" : "; \(outcome.stayed.count) stayed in the feed's folder")
        )
        return outcome
    }

    /// Whether the feed `feedID` left anything for the return of its
    /// downloads to do: a download among the library's books, a row kept on
    /// its feed's shelf after its download went, an index the library keeps
    /// for it, or its folder in the data directory. A feed that downloaded
    /// nothing left none of these.
    private func leftSomething(feedID: UUID) -> Bool {
        library.books.contains { $0.feedLink?.feedID == feedID }
            || library.feedShelf.rows.contains { $0.feedLink?.feedID == feedID }
            || library.feedShelf.indexedFeedIDs.contains(feedID)
            || FileManager.default.fileExists(atPath: FeedPaths.itemsFolder(of: feedID, in: TextMouthPaths.root).path)
    }

    /// Deletes, through `remove`, the package of each of `rows`, the feed
    /// `feedID`'s rows kept after their downloads went, in its folder in the
    /// data directory at `root`, and forgets any record write still queued
    /// for it. A row whose package name names no package directly in a
    /// feed's folder (`FeedItemPackage.isPackageName(_:)`) is passed over:
    /// its "package" could be the feed's whole folder. Returns how many went.
    private func deleteKeptPackages(
        _ rows: [Book],
        of feedID: UUID,
        root: URL,
        remove: @MainActor (URL) throws -> Void
    ) -> Int {
        var deleted = 0
        for row in rows where FeedItemPackage.isPackageName(row.tmbDirectoryName) {
            let package = FeedPaths.packageDirectory(named: row.tmbDirectoryName, of: feedID, in: root)
            LibraryPersistenceService.forgetDeletedBook(row)
            guard FileManager.default.fileExists(atPath: package.path) else { continue }
            do {
                try remove(package)
                deleted += 1
            } catch {
                DiagnosticLog.event(
                    .storage,
                    "FEED_DOWNLOADS_RETURN: could not delete the package kept for \"\(row.title)\": "
                        + "\(error.localizedDescription); the next launch tries again"
                )
            }
        }
        return deleted
    }

    /// Removes, through `remove`, the folder of the feed `feedID` in the data
    /// directory at `root`, its index and what interrupted downloads left
    /// hidden there with it, once nothing else is in it. A folder still
    /// holding a package, as one whose record is only in the cloud and so
    /// was never read as a row, stays for a launch that reads it. Returns
    /// whether the folder is gone.
    private func removeFeedFolder(of feedID: UUID, root: URL, remove: @MainActor (URL) throws -> Void) -> Bool {
        let folder = FeedPaths.itemsFolder(of: feedID, in: root)
        let names: [String]
        do {
            names = try DatalessFiles.withoutDownloading {
                try FileManager.default.contentsOfDirectory(atPath: folder.path)
            }
        } catch {
            return !FileManager.default.fileExists(atPath: folder.path)
        }
        let left = names.filter { !$0.hasPrefix(".") && $0 != FeedPaths.indexFileName }
        guard left.isEmpty else {
            DiagnosticLog.event(
                .storage,
                "FEED_DOWNLOADS_RETURN: \(feedID.uuidString.prefix(8)): the feed's folder stays, holding "
                    + "\(CountWording.phrase(left.count, singular: "item", plural: "items")) no row named; "
                    + "the next launch reads it again"
            )
            return false
        }
        do {
            try remove(folder)
            return true
        } catch {
            DiagnosticLog.event(
                .storage,
                "FEED_DOWNLOADS_RETURN: \(feedID.uuidString.prefix(8)): could not remove the feed's folder: "
                    + "\(error.localizedDescription); the next launch tries again"
            )
            return false
        }
    }
}

// MARK: - A Record Gone, or Not Here Yet

/// How a launch judges that a feed whose folder is here has no record, so
/// that the feed is gone and its downloads return to the library
/// (`LibraryViewModel.feedsTakenForGone(knownFeeds:absence:)`;
/// REV10, the A1 review's cloud item). An unsubscribed feed keeps its record
/// (FR11, branch D), so it is never one.
///
/// In a data directory that is not in a cloud location, a record's absence
/// decides at once. In a cloud location (FR02) it decides nothing alone: a
/// feed subscribed on another Mac can reach this one as its folder before
/// its record does, and an Unsubscribe there by a build before branch D,
/// which moved the downloads itself, could reach it as the record's removal
/// before those moves. So the
/// records' folder, listed without downloading anything, must show no
/// record and no placeholder of one at two launches of this Mac: the first
/// leaves a note beside the feed's index, an empty hidden file named after
/// this Mac and that launch (`.record-absent-<Mac ID>-<launch ID>`), and a
/// later launch that finds the record still gone and that note there takes
/// the feed for gone. A launch that finds the record here takes
/// this Mac's notes away. Another Mac's notes count for nothing here; every
/// note goes with the feed's folder once its downloads have returned.
struct FeedRecordAbsence: Equatable, Sendable {
    /// Whether the data directory is in a cloud location, where an absence
    /// counts only once it has lasted from an earlier launch.
    var isCloud: Bool
    /// This Mac, as its notes name it: the ID TextMouth keeps for it
    /// (`LibrarySessionLease.macID`).
    var macID: String
    /// This launch, as its note names it.
    var launchID: UUID

    /// This process's launch.
    static let thisLaunch = UUID()
    /// What begins every note's name: hidden, so the feed's folder never
    /// takes it for a package (`FeedIndexFiles`).
    static let notePrefix = ".record-absent-"

    /// The name a sync service may show in place of the record file
    /// `recordName` while the record is only in the cloud: an older iCloud
    /// Drive's placeholder, ".<name>.icloud". Newer sync services keep the
    /// record's own name, on a dataless file.
    static func placeholderName(of recordName: String) -> String {
        ".\(recordName).icloud"
    }

    /// What begins the names of this Mac's notes, whichever their launch.
    private var macNotePrefix: String {
        Self.notePrefix + macID + "-"
    }

    /// The name of this launch's note.
    private var noteName: String {
        macNotePrefix + launchID.uuidString
    }

    /// Whether this Mac found the record of the feed `feedID`, whose folder
    /// is `folder`, gone at an earlier launch too, as a note of that launch
    /// in the folder says. When it did not, this launch's note is left
    /// there, with one FEED_RECORD_ABSENT line, for a later launch to find;
    /// a folder that cannot be listed or written in decides nothing.
    func wasGoneAtAnEarlierLaunch(feed feedID: UUID, folder: URL) -> Bool {
        let notes = notesOfThisMac(in: folder)
        if notes.contains(where: { $0 != noteName }) {
            return true
        }
        if !notes.contains(noteName) {
            let wrote = FileManager.default.createFile(atPath: folder.appendingPathComponent(noteName).path, contents: Data())
            DiagnosticLog.event(
                .storage,
                "FEED_RECORD_ABSENT: \(feedID.uuidString.prefix(8)): its folder is here and its record is not; in a cloud "
                    + "library its downloads stay until a later launch finds the record gone too"
                    + (wrote ? "" : ", though the note saying so could not be written, so a later launch looks again")
            )
        }
        return false
    }

    /// Takes away this Mac's notes from `folder`, the folder of the feed
    /// `feedID`, whose record is here, so an absence found later counts
    /// from then on; with one FEED_RECORD_BACK line when there were some.
    func forgetNotes(ofFeed feedID: UUID, in folder: URL) {
        let notes = notesOfThisMac(in: folder)
        guard !notes.isEmpty else { return }
        for note in notes {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(note))
        }
        DiagnosticLog.event(
            .storage,
            "FEED_RECORD_BACK: \(feedID.uuidString.prefix(8)): its record is here again, so the note of its absence is gone"
        )
    }

    /// The names of this Mac's notes in `folder`, listed without
    /// downloading anything; none when it cannot be listed.
    private func notesOfThisMac(in folder: URL) -> [String] {
        let names = DatalessFiles.withoutDownloading {
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        }
        return names.filter { $0.hasPrefix(macNotePrefix) }
    }
}

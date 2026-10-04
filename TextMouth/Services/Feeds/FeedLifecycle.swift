import Foundation

// MARK: - Played, and Deleted After (FR03)

/// What one sweep of played downloads did (FR03).
struct FeedSweepReport: Equatable, Sendable {
    /// The downloads deleted, by book ID.
    var deletedBookIDs: [UUID] = []
    /// The downloads due but open in a reader, left until it closes.
    var openBookIDs: [UUID] = []
    /// The downloads due in a cloud library whose packages are not wholly on
    /// this Mac, left to a Mac that has them.
    var leftInCloudBookIDs: [UUID] = []
    /// The items whose books the library no longer lists, now not
    /// downloaded.
    var forgottenItemIDs: [FeedItem.ID] = []
}

/// How deleting one due download went, off the main thread.
enum FeedSweepOutcome: Equatable, Sendable {
    /// The package is gone.
    case deleted
    /// In a cloud library, the package is not wholly on this Mac.
    case leftInCloud
    /// The package was not where the book's row said, as when the book moved
    /// meanwhile: the next sweep tries again.
    case moved
    /// The package could not be deleted, for the reason given.
    case failed(String)
}

extension FeedCenter {
    // MARK: Played

    /// Records that the book `bookID` played or was read to its end, when it
    /// is a feed item's download: the item is played from now. The reader
    /// reaches here through the completion that counts Books Finished
    /// (`ReadingStatsService.markBookFinished(bookID:title:)`, which posts
    /// `.bookDidFinish`), so finished episodes and articles count as finished
    /// books, as the listener decided for now.
    func bookDidFinish(_ bookID: UUID) {
        guard let (feed, item) = store.item(downloadedAs: bookID) else { return }
        store.updateItem(item.id, of: feed.id) { $0.playedDate = environment.now() }
        DiagnosticLog.event(.feeds, "FEED_ITEM_PLAYED: \(item.title) (\(feed.title))")
        requestSweep()
    }

    /// What kind of book the book `bookID` is, as Books Finished counts it
    /// (`ReadingStatsService.finishedBookKind`): a podcast episode when this
    /// engine downloaded it as an episode, and otherwise an audiobook or a
    /// text book by its format, an article being a text book; nil when the
    /// library no longer lists it, or the engine has not started.
    func finishedBookKind(of bookID: UUID) -> FinishedBookKind? {
        guard let book = library?.feedBook(withID: bookID) else { return nil }
        return FinishedBookKind.of(format: book.format, isFeedDownload: store.item(downloadedAs: bookID) != nil)
    }

    /// Marks the item `itemID` of the feed `feedID` played (an article: read)
    /// now, as Mark as Played does; the delete-after-played rule counts from
    /// now.
    func markPlayed(_ itemID: FeedItem.ID, of feedID: UUID) {
        store.updateItem(itemID, of: feedID) { $0.playedDate = environment.now() }
        requestSweep()
    }

    /// Marks the item `itemID` of the feed `feedID` unplayed, as Mark as
    /// Unplayed does: its download is kept from then on.
    func markUnplayed(_ itemID: FeedItem.ID, of feedID: UUID) {
        store.updateItem(itemID, of: feedID) { $0.playedDate = nil }
    }

    /// Marks every item the library lists of the feed `feedID` that is not
    /// played yet played now, as Mark All Played does, in one change of its
    /// record, so the record is written once; the delete-after-played rule
    /// counts from now.
    /// - Returns: How many items were marked.
    @discardableResult
    func markAllPlayed(of feedID: UUID) -> Int {
        let now = environment.now()
        var marked = 0
        store.update(feedID) { record in
            for index in record.items.indices
            where record.items[index].deletedDate == nil && record.items[index].playedDate == nil {
                record.items[index].playedDate = now
                marked += 1
            }
        }
        if marked > 0 {
            requestSweep()
        }
        return marked
    }

    // MARK: Deleting

    /// Deletes the download of the item `itemID` of the feed `feedID`, as
    /// Delete Download does: its book leaves the library, its package going
    /// to the Trash or deleted as the removal setting says, and the item
    /// stays, not downloaded. Refused for a book open in a reader.
    /// - Throws: the error that kept the package from being deleted, or
    ///   `BookCloudError.bookIsOpen`.
    func deleteDownload(_ itemID: FeedItem.ID, of feedID: UUID) throws {
        guard let item = store.record(of: feedID)?.item(itemID), let bookID = item.state.bookID else { return }
        if let library, let book = library.feedBook(withID: bookID) {
            guard !library.feedBooksOpenInReaders.contains(bookID) else { throw BookCloudError.bookIsOpen }
            try environment.deleteBookPackage(book)
            library.removeFeedBook(book)
        }
        store.updateItem(itemID, of: feedID) { item in
            item.state = .notDownloaded
            item.downloadDeletedDate = environment.now()
        }
    }

    /// Deletes the item `itemID` of the feed `feedID`, as Delete Episode does:
    /// its download stops or is deleted, and the item leaves every list,
    /// while its record keeps it so no refresh brings it back.
    /// - Throws: what `deleteDownload(_:of:)` throws; the item then stays.
    func deleteItem(_ itemID: FeedItem.ID, of feedID: UUID) throws {
        downloads.cancel(itemID, of: feedID)
        try deleteDownload(itemID, of: feedID)
        store.updateItem(itemID, of: feedID) { $0.deletedDate = environment.now() }
    }

    // MARK: The Sweep

    /// Asks for a sweep of played downloads: one starts at once, or after the
    /// one under way, which a request made meanwhile makes run again.
    func requestSweep() {
        guard environment.worksOnItsOwn else { return }
        guard !isSweeping else {
            sweepRequestedAgain = true
            return
        }
        isSweeping = true
        Task {
            repeat {
                sweepRequestedAgain = false
                await sweepPlayedDownloads()
            } while sweepRequestedAgain
            isSweeping = false
        }
    }

    /// Deletes the downloads the delete-after-played rule says are due: an
    /// item played at least its feed's number of days ago (0 at once, -1
    /// never; `FeedSettings.deleteDownloadsDaysAfterPlayed` unless the feed
    /// overrides it). The book leaves the library through the removal every
    /// deleted package ends in (`LibraryViewModel.removeDeletedBook(_:)`),
    /// and its item stays, not downloaded, with the date its download went.
    ///
    /// The package is deleted for good, rather than moved to the Trash, so
    /// played episodes never fill the Trash, and off the main thread, with
    /// dataless files left in the cloud. A book open in a reader waits until
    /// its reader closes. In a cloud library, a package is deleted only when
    /// this Mac holds it whole, as its cloud state says, read without
    /// downloading anything (`BookCloudStorage.state(of:in:)`): one only in
    /// the cloud, or still syncing, is left to a Mac that has it, which also
    /// knows whether a reader there has it open. An item whose book the
    /// library no longer lists, as after the listener deleted the book,
    /// becomes not downloaded. Nothing is swept while the library's index is
    /// recovered: its list of books is provisional then, and a book missing
    /// from it may still be on disk.
    @discardableResult
    func sweepPlayedDownloads() async -> FeedSweepReport {
        var report = FeedSweepReport()
        guard let library, library.feedLibraryIsComplete else { return report }
        let now = environment.now()
        let settings = self.settings
        var due: [(feedID: UUID, itemID: FeedItem.ID, book: Book)] = []
        for record in store.records.values {
            let days = record.feed.deleteDownloadsDaysAfterPlayed(under: settings)
            for item in record.items {
                guard let bookID = item.state.bookID else { continue }
                guard let book = library.feedBook(withID: bookID) else {
                    store.updateItem(item.id, of: record.feed.id) { item in
                        item.state = .notDownloaded
                        item.downloadDeletedDate = now
                    }
                    report.forgottenItemIDs.append(item.id)
                    continue
                }
                guard days >= 0, let played = item.playedDate,
                      now >= played.addingTimeInterval(TimeInterval(days) * 86_400) else { continue }
                guard !library.feedBooksOpenInReaders.contains(bookID) else {
                    report.openBookIDs.append(bookID)
                    continue
                }
                due.append((record.feed.id, item.id, book))
            }
        }
        guard !due.isEmpty else { return report }

        let storage = environment.bookStorage()
        let packages = due.map { BookPackage($0.book) }
        let outcomes = await OffMainWork.run(on: .global(qos: .utility)) {
            Self.deletePackages(packages, storage: storage)
        }

        for entry in due {
            switch outcomes[entry.book.id] {
            case .deleted?:
                // The row is taken out only when it still names the package
                // deleted.
                if let current = library.feedBook(withID: entry.book.id), current.tmbDirectory == entry.book.tmbDirectory {
                    library.removeFeedBook(current)
                }
                store.updateItem(entry.itemID, of: entry.feedID) { item in
                    item.state = .notDownloaded
                    item.downloadDeletedDate = now
                }
                report.deletedBookIDs.append(entry.book.id)
                DiagnosticLog.event(.feeds, "FEED_DOWNLOAD_DELETED: \(entry.book.title): played, deleted by the delete-after rule")
            case .leftInCloud?:
                report.leftInCloudBookIDs.append(entry.book.id)
            case .failed(let reason)?:
                DiagnosticLog.event(.feeds, "FEED_DOWNLOAD_DELETE_FAILED: \(entry.book.title): \(reason)")
            case .moved?, nil:
                continue
            }
        }
        if !report.leftInCloudBookIDs.isEmpty {
            DiagnosticLog.event(
                .feeds,
                "FEED_SWEEP_LEFT_IN_CLOUD: \(report.leftInCloudBookIDs.count) played download(s) not wholly on this Mac left for a Mac that has them"
            )
        }
        return report
    }

    /// Deletes each of `packages` for good, off the main thread, with
    /// dataless files left in the cloud. In a cloud library, as `storage`
    /// says, a package not wholly on this Mac is left as it is.
    nonisolated static func deletePackages(_ packages: [BookPackage], storage: any BookCloudStorage) -> [UUID: FeedSweepOutcome] {
        let location = storage.libraryLocation()
        var outcomes: [UUID: FeedSweepOutcome] = [:]
        for package in packages {
            if location.isCloud {
                switch storage.state(of: package, in: location) {
                case .downloaded, .local:
                    break
                default:
                    outcomes[package.bookID] = .leftInCloud
                    continue
                }
            }
            do {
                try DatalessFiles.withoutDownloading {
                    try FileManager.default.removeItem(at: package.url)
                }
                outcomes[package.bookID] = .deleted
            } catch CocoaError.fileNoSuchFile {
                outcomes[package.bookID] = .moved
            } catch {
                outcomes[package.bookID] = .failed(error.localizedDescription)
            }
        }
        return outcomes
    }
}

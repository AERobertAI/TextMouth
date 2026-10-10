import CryptoKit
import Foundation

// MARK: - Why a Download Failed (FR03)

/// Why an item's download failed (FR03), in sentences a listener reads,
/// kept with the item (`FeedItemState.failed`) until it is tried again.
enum FeedDownloadError: Error, Equatable, Sendable {
    /// The transfer failed.
    case transfer(FeedFetchError)
    /// The feed's folder is no longer in the library.
    case folderMissing
    /// The library's disk lacks room for the file, of this many bytes, and
    /// the space TextMouth keeps free.
    case notEnoughSpace(bytes: Int64)
    /// The file is of a kind TextMouth does not play, named by its MIME type
    /// or extension.
    case unsupportedFile(String)
    /// The import failed, for the reason given (`ImportFailure.reason`).
    case importFailed(String)

    /// The sentence the library shows and VoiceOver speaks about the item
    /// titled `title`.
    func message(about title: String) -> String {
        switch self {
        case .transfer(let error):
            return error.downloadMessage(about: title)
        case .folderMissing:
            return "The folder for this feed is no longer in the library. Choose another folder for it."
        case .notEnoughSpace(let bytes):
            let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            return "There isn't room on this Mac for this episode (\(size))."
        case .unsupportedFile(let kind):
            return "TextMouth can't play this kind of file (\(kind))."
        case .importFailed(let reason):
            return reason
        }
    }
}

// MARK: - Why a Download Waits (FR11)

/// Why a download the newest-N rule asked for waits rather than fails
/// (FR11): it is put off by itself and tried again by itself, its item
/// saying "Waiting to Download" and why (`FeedItemState.waiting`).
enum FeedDownloadWait: Equatable, Sendable {
    /// A network with data limits refused it, or this Mac was offline (REV11
    /// F4): it is asked for again once a refresh TextMouth makes by itself
    /// reaches a network without data limits.
    case network
    /// The library's disk lacks room for the file, of this many bytes, and
    /// the space TextMouth keeps free: the rule tries it again at its next
    /// pass, and never removes anything to make room.
    case room(bytes: Int64)

    /// The wait a failure of one of the rule's downloads is: a network with
    /// data limits, this Mac being offline, as at a first launch away from
    /// any network (REV11 F4), or too little room; nil for any other
    /// failure, which fails as a listener's download does.
    init?(_ failure: FeedDownloadError) {
        switch failure {
        case .transfer(.constrainedNetwork), .transfer(.offline):
            self = .network
        case .notEnoughSpace(let bytes):
            self = .room(bytes: bytes)
        default:
            return nil
        }
    }

    /// Why, as the item's row says it after "Waiting to Download": "it
    /// downloads on a network without data limits", or "it needs room for
    /// 61 MB on this Mac".
    var reason: String {
        switch self {
        case .network:
            return "it downloads on a network without data limits"
        case .room(let bytes):
            return "it needs room for \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) on this Mac"
        }
    }
}

extension FeedFetchError {
    /// The sentence about a download of the item titled `title` that failed
    /// this way, naming the server by its host alone.
    func downloadMessage(about title: String) -> String {
        switch self {
        case .offline:
            return "This Mac is offline, so “\(title)” can't be downloaded. Connect to the internet and try again."
        case .hostNotFound(let host):
            return "The server \(host) couldn't be found."
        case .timedOut(let host):
            return "\(host) didn't answer for \(Int(FeedNetwork.requestTimeout)) seconds."
        case .notFound:
            return "The server says the file is gone."
        case .needsPassword:
            return "This file needs a password, which TextMouth can't send yet."
        case .gone:
            return "The publisher has removed this file."
        case .serverError(let status, let host):
            return "\(host) couldn't send the file (error \(status)). Try again later."
        case .tooLarge(let host):
            return "The page at \(host) is larger than TextMouth reads."
        case .connectionFailed(let host, let reason):
            return "\(host) couldn't be reached: \(reason)"
        case .notAWebAddress:
            return "The file's address isn't a web address TextMouth can open."
        case .constrainedNetwork:
            return "“\(title)” waits for a network without data limits to download by itself."
        case .cancelled:
            return "The download was stopped."
        }
    }
}

// MARK: - Downloading Items

/// Downloads feed items one at a time, in the order asked, and publishes
/// each as a book in its feed's folder (FR03).
///
/// An episode's file comes through a `URLSessionDownloadTask`, its progress
/// counted in bytes, as a cloud download's is, against the length the
/// server gives, or the feed's estimate until it does, and told to the
/// downloads' progress alone (`progress`, FR10), which the Library windows'
/// feed downloads section observes; the item's state says only that it
/// downloads, from the moment it is asked for. A download that stops
/// partway keeps the resume data the server allows in this Mac's Feeds
/// folder in Caches, and the next download of the item goes on from
/// there. The finished file waits in this Mac's Feed Downloads
/// folder, then is imported (`FeedEpisodeImporter`) on a queue of its own,
/// as storage work, adding its book to the library on the main actor before
/// that work ends, as every import does, so a data-directory move never
/// falls between the two. An article's download is its book, written from
/// its text, or from its web page when the feed gives only a summary.
///
/// A failure is kept with its item, with its reason, until it is tried
/// again; cancelling forgets the download and any part of it. An item asked
/// for while it waits or downloads is not asked for twice, and opening an
/// item downloads it first and opens its book once it is in the library.
///
/// Quitting stops every download keeping its place (`stopForQuit()`, which
/// `FeedQuitHold` holds the quit for): the one under way keeps what it
/// downloaded as resume data, and the downloads asked for are listed in
/// this Mac's resume folder, so the next launch asks for them again
/// (`resumeDownloadsSavedAtQuit()`) and the one under way goes on from
/// where it stopped.
@MainActor
final class FeedDownloadManager {
    /// Who asked for a download (FR11): the listener, through Download or
    /// opening an item, or the newest-N rule, whose downloads are
    /// discretionary, waiting for a network without data limits. A finished
    /// download records it in its item (`FeedItem.downloadOrigin`).
    typealias Origin = FeedDownloadOrigin

    /// One download asked for.
    struct Request: Equatable, Sendable {
        let feedID: UUID
        let itemID: FeedItem.ID
        var origin: Origin
        var opensWhenDone: Bool
    }

    /// Where the manager keeps its files, and what it asks of the disk.
    struct Environment {
        /// The network.
        var network: FeedNetwork
        /// This Mac's folder for resume data.
        var resumeFolder: URL
        /// This Mac's folder for finished downloads waiting to be imported.
        var holdingFolder: URL
        /// The free bytes on the volume holding a location.
        var freeSpace: @Sendable (URL) -> Int64?
        /// The bytes a download leaves free on the library's disk.
        var reserve: Int64
        /// The boundary the imports run through as storage work.
        var boundary: StorageBoundary
        /// The time now.
        var now: @Sendable () -> Date
    }

    /// The records.
    private let store: FeedStore
    /// Where files go, and the network.
    private let environment: Environment
    /// The library the books go into.
    private let library: () -> FeedLibraryHost?
    /// Told what happens.
    private let announce: (FeedEvent) -> Void
    /// The downloads waiting, in order.
    private(set) var queue: [Request] = []
    /// The download under way.
    private(set) var current: Request?
    /// The task running the download under way.
    private var currentTask: Task<Void, Never>?
    /// The transfer of the download under way, while its file arrives,
    /// which quitting stops keeping what it downloaded.
    private var currentTransfer: FeedTransferHandle?
    /// Whether TextMouth is quitting (`stopForQuit()`): no download starts,
    /// and none that stops forgets its place.
    private(set) var isStoppedForQuit = false
    /// The newest-N rule's downloads a network with data limits put off, in
    /// the order they were, waiting for a refresh TextMouth makes by itself
    /// to reach a network without them (`retryPutOffDownloads()`).
    private(set) var putOff: [Request] = []
    /// Called on the main actor as an import has finished, just before its
    /// book is listed, for a test to act at that moment, as Delete Episode
    /// can while an import runs; nil in the app.
    var beforeCommit: (@MainActor (Request) -> Void)?
    /// Runs imports in order, off the main thread.
    private let importQueue = DispatchQueue(label: "com.textmouth.feed-imports", qos: .userInitiated)
    /// How far the downloads have got, as the Library windows' feed
    /// downloads section shows it and VoiceOver hears it (FR10): told every
    /// change of the queue, each download's start, bytes, and end, and
    /// observed by that section alone.
    let progress: FeedDownloadProgress

    /// A manager downloading `store`'s items into `library`, telling
    /// `announce` what happens.
    init(
        store: FeedStore,
        environment: Environment,
        library: @escaping () -> FeedLibraryHost?,
        announce: @escaping (FeedEvent) -> Void
    ) {
        self.store = store
        self.environment = environment
        self.library = library
        self.announce = announce
        let now = environment.now
        progress = FeedDownloadProgress(now: { now() })
    }

    // MARK: Asking

    /// Downloads the item `itemID` of the feed `feedID`, after those already
    /// waiting; one the listener opens comes first, and opens once its book
    /// is in the library. An item downloaded already, whose book is in the
    /// library, opens at once when asked. Asking again for an item that
    /// waits or downloads only adds what the new request adds, and asking
    /// for one a network with data limits put off takes the place of that
    /// request. Nothing is asked for while TextMouth quits.
    func download(_ itemID: FeedItem.ID, of feedID: UUID, origin: Origin, opening: Bool = false) {
        guard !isStoppedForQuit, let item = store.record(of: feedID)?.item(itemID), item.deletedDate == nil else { return }
        // However it goes, the downloads' progress hears the queue (FR10).
        defer { publishQueue() }
        putOff.removeAll { $0.feedID == feedID && $0.itemID == itemID }
        if let bookID = item.state.bookID, library()?.feedBook(withID: bookID) != nil {
            if opening {
                library()?.openFeedBook(bookID)
            }
            return
        }
        if var running = current, running.feedID == feedID, running.itemID == itemID {
            running.opensWhenDone = running.opensWhenDone || opening
            if origin == .listener {
                running.origin = .listener
            }
            current = running
            return
        }
        var request = Request(feedID: feedID, itemID: itemID, origin: origin, opensWhenDone: opening)
        if let waiting = queue.firstIndex(where: { $0.feedID == feedID && $0.itemID == itemID }) {
            request.opensWhenDone = request.opensWhenDone || queue[waiting].opensWhenDone
            request.origin = origin == .listener ? .listener : queue[waiting].origin
            queue.remove(at: waiting)
        }
        if opening {
            queue.insert(request, at: 0)
        } else {
            queue.append(request)
        }
        store.updateItem(itemID, of: feedID) { $0.state = .downloading }
        startNext()
    }

    /// Stops the download of the item `itemID`, or takes it out of the
    /// queue, or out of the downloads put off, forgetting any part
    /// downloaded; the item is not downloaded, nor waiting (FR11).
    func cancel(_ itemID: FeedItem.ID, of feedID: UUID) {
        defer { publishQueue() }
        putOff.removeAll { $0.feedID == feedID && $0.itemID == itemID }
        if let waiting = queue.firstIndex(where: { $0.feedID == feedID && $0.itemID == itemID }) {
            queue.remove(at: waiting)
            store.updateItem(itemID, of: feedID) { $0.state = .notDownloaded }
        } else if current?.feedID == feedID, current?.itemID == itemID {
            currentTask?.cancel()
        } else {
            // Put off by itself, for a network or for room: no longer.
            store.updateItem(itemID, of: feedID) { item in
                if item.state.waitingReason != nil {
                    item.state = .notDownloaded
                }
            }
        }
        try? FileManager.default.removeItem(at: resumeDataFile(for: itemID, of: feedID))
    }

    /// Stops the download under way and takes every download waiting to
    /// start out of the queue, as the feed downloads section's Cancel does
    /// (FR10), whether the listener or the newest-N rule asked for each:
    /// each item is not downloaded, forgets any part downloaded, and is the
    /// listener's from then on, so the rule never downloads it again by
    /// itself (`FeedItem.downloadOrigin`), as Cancel Download makes one the
    /// listener's. A download whose book is already being added to the
    /// library finishes, since an import is never stopped partway; the
    /// rule's downloads waiting for a network or for room keep waiting.
    /// VoiceOver hears at once what stopped, and what still waits.
    func cancelEveryDownload() {
        guard !isStoppedForQuit else { return }
        // A book being added can't be stopped: it finishes as it began.
        let finishing = progress.state.download?.isAddingToLibrary == true ? current : nil
        let underWay = finishing == nil ? current : nil
        let waiting = queue
        let stopping = (underWay.map { [$0] } ?? []) + waiting
        let titles = stopping.compactMap { store.record(of: $0.feedID)?.item($0.itemID)?.title }
        queue.removeAll()
        if underWay != nil {
            // Its task ends as Cancel Download's does, its item not
            // downloaded (`run(_:)`).
            currentTask?.cancel()
        }
        // One change of each feed's record for all of its items stopped:
        // those waiting to start are not downloaded now, and every one is
        // the listener's.
        for (feedID, requests) in Dictionary(grouping: stopping, by: \.feedID) {
            let itemIDs = Set(requests.map(\.itemID))
            let waitingIDs = Set(waiting.filter { $0.feedID == feedID }.map(\.itemID))
            store.update(feedID) { record in
                for index in record.items.indices where itemIDs.contains(record.items[index].id) {
                    if waitingIDs.contains(record.items[index].id) {
                        record.items[index].state = .notDownloaded
                    }
                    record.items[index].downloadOrigin = .listener
                }
            }
        }
        for request in stopping {
            try? FileManager.default.removeItem(at: resumeDataFile(for: request.itemID, of: request.feedID))
        }
        let finishingTitle = finishing.flatMap { store.record(of: $0.feedID)?.item($0.itemID)?.title }
        DiagnosticLog.event(.feeds, "FEED_DOWNLOADS_CANCELLED: \(stopping.count) download(s) stopped\(finishingTitle == nil ? "" : ", one finishing")")
        progress.cancel(stopped: titles, finishing: finishingTitle)
        publishQueue()
    }

    /// Whether the item `itemID` waits in the queue or downloads.
    func isDownloading(_ itemID: FeedItem.ID, of feedID: UUID) -> Bool {
        (current?.feedID == feedID && current?.itemID == itemID)
            || queue.contains { $0.feedID == feedID && $0.itemID == itemID }
    }

    /// Whether the item `itemID`'s download was put off by a network with
    /// data limits, waiting for a refresh to reach one without them (FR11).
    func isPutOff(_ itemID: FeedItem.ID, of feedID: UUID) -> Bool {
        putOff.contains { $0.feedID == feedID && $0.itemID == itemID }
    }

    /// Takes every waiting, running, and put-off download of the feed
    /// `feedID` away, as a feed leaving the library would need. No command
    /// calls it since Unsubscribe keeps the feed and only withdraws the
    /// rule's downloads (FR11, branch D, `withdrawRuleDownloads`); it stays
    /// for a Delete Feed…, which is still the listener's to decide, with
    /// `FeedStore.remove(_:)` and `FeedFetchStates.remove(_:)`.
    func cancelAll(of feedID: UUID) {
        defer { publishQueue() }
        queue.removeAll { $0.feedID == feedID }
        putOff.removeAll { $0.feedID == feedID }
        if current?.feedID == feedID {
            currentTask?.cancel()
        }
    }

    /// Takes back the newest-N rule's downloads of the feed `feedID` not yet
    /// under way whose items `shouldWithdraw` names (FR11): those waiting in
    /// the queue, those a network with data limits put off, those waiting
    /// for room, and those that failed (REV11 F4), so no row says "Download
    /// Failed" of a download nobody asked for once its item no longer
    /// counts. Each item is not downloaded, and stays the rule's, to be
    /// asked for again should it count again; the download under way runs
    /// on, and the listener's downloads, failed or not, are never taken
    /// back.
    /// - Returns: The items taken back.
    @discardableResult
    func withdrawRuleDownloads(of feedID: UUID, where shouldWithdraw: (FeedItem.ID) -> Bool) -> [FeedItem.ID] {
        /// Whether `request` is one of the rule's for the feed that goes.
        func goes(_ request: Request) -> Bool {
            request.feedID == feedID && request.origin == .window && shouldWithdraw(request.itemID)
        }
        var withdrawn = (queue + putOff).filter(goes).map(\.itemID)
        queue.removeAll(where: goes)
        putOff.removeAll(where: goes)
        // A wait for room holds no request, and neither does the rule's
        // failed download: their items alone say so.
        let settled = store.record(of: feedID)?.items.filter { item in
            (item.state.waitingReason != nil || item.hasRulesFailedDownload)
                && !withdrawn.contains(item.id) && shouldWithdraw(item.id)
        }.map(\.id) ?? []
        withdrawn += settled
        guard !withdrawn.isEmpty else { return [] }
        store.update(feedID) { record in
            for index in record.items.indices where withdrawn.contains(record.items[index].id) {
                record.items[index].state = .notDownloaded
            }
        }
        publishQueue()
        DiagnosticLog.trace(.feeds, "the newest-N rule took back \(withdrawn.count) download(s) no longer wanted")
        return withdrawn
    }

    /// Asks again for the newest-N rule's downloads a network with data
    /// limits put off that `shouldRetry` names, every one unless it names
    /// fewer, in their order, as a refresh TextMouth made by itself, which
    /// such a network refuses too, has just reached the network: it has no
    /// data limits now. One refused again is put off again; one not named
    /// stays put off, for the rule's next pass to take back (REV11 F3).
    func retryPutOffDownloads(where shouldRetry: (Request) -> Bool = { _ in true }) {
        let waiting = putOff.filter(shouldRetry)
        putOff.removeAll { waiting.contains($0) }
        for request in waiting {
            download(request.itemID, of: request.feedID, origin: .window)
        }
        // An item gone meanwhile was asked for nothing: it waits no more.
        publishQueue()
    }

    // MARK: Running

    /// Starts the next download when none is under way, unless TextMouth
    /// quits; the downloads' progress hears it begin, and how it ended
    /// before the one after it begins (FR10).
    private func startNext() {
        guard !isStoppedForQuit, current == nil, !queue.isEmpty else { return }
        let request = queue.removeFirst()
        current = request
        beginProgress(of: request)
        currentTask = Task {
            let ending = await run(request)
            current = nil
            currentTask = nil
            progress.end(ending, queued: queuedSizes, waits: waitingApart())
            startNext()
        }
    }

    /// Runs the download `request`, to its book or its failure, and returns
    /// how it ended, for the downloads' progress (FR10).
    private func run(_ request: Request) async -> FeedDownloadEnding {
        guard let record = store.record(of: request.feedID), let item = record.item(request.itemID),
              item.deletedDate == nil else { return .stopped }
        let feed = record.feed
        DiagnosticLog.event(.feeds, "FEED_DOWNLOAD_STARTED: \(item.title) (\(feed.title))")
        announce(.downloadStarted(feedID: request.feedID, itemID: request.itemID))
        do {
            // A download goes to its feed's own folder (FR11); the feed's
            // library folder is where it is listed, so a feed whose folder is
            // gone downloads nothing, as before.
            guard library()?.feedFolderPath(forFolderID: feed.folderID) != nil else {
                throw FeedDownloadError.folderMissing
            }
            // An item whose earlier download's file went while its package
            // was kept, with the listener's place, is downloaded again as the
            // same book, in the same package (FR11, branch A2).
            let kept = library()?.feedItemRows(of: feed.id).kept[item.id]
            let book: Book
            if let enclosure = item.enclosure, enclosure.isPlayable {
                book = try await downloadEpisode(item, enclosure: enclosure, of: feed, request: request, restoring: kept)
            } else {
                book = try await downloadArticle(item, of: feed, request: request, restoring: kept)
            }
            DiagnosticLog.event(.feeds, "FEED_DOWNLOAD_FINISHED: \(item.title) (\(feed.title))")
            announce(.downloadFinished(feedID: request.feedID, itemID: request.itemID, bookID: book.id))
            if current?.opensWhenDone == true {
                library()?.openFeedBook(book.id)
            }
            return .downloaded
        } catch {
            if isStoppedForQuit {
                // Quitting stopped it: it keeps its place, which
                // `stopForQuit()` saves, and its item stays as it was.
                DiagnosticLog.trace(.feeds, "a download under way stopped for quitting, keeping its place")
                return .stopped
            }
            let failure = Self.downloadError(error)
            if failure == .transfer(.cancelled) {
                store.updateItem(request.itemID, of: request.feedID) { $0.state = .notDownloaded }
                DiagnosticLog.event(.feeds, "FEED_DOWNLOAD_CANCELLED: \(item.title) (\(feed.title))")
                return .stopped
            }
            // As it stands now: the listener may have asked for it meanwhile.
            let asked = latest(request)
            if asked.origin == .window, let wait = FeedDownloadWait(failure) {
                // The rule's download waits, rather than fails (FR11): for a
                // network without data limits, asked for again once a
                // refresh reaches one; for room, tried again at the rule's
                // next pass. Nothing is announced: nobody asked to hear it.
                if wait == .network, !isPutOff(request.itemID, of: request.feedID) {
                    putOff.append(asked)
                }
                store.updateItem(request.itemID, of: request.feedID) { $0.state = .waiting(wait.reason) }
                DiagnosticLog.event(.feeds, "FEED_DOWNLOAD_WAITING: \(item.title) (\(feed.title)): \(wait.reason)")
                return .waiting
            }
            let message = failure.message(about: item.title)
            store.updateItem(request.itemID, of: request.feedID) { item in
                item.state = .failed(message)
                // A download the listener asked for stays the listener's to
                // try again, never the newest-N rule's (FR11); the rule's
                // failure is the rule's, which a pass takes back once the
                // item no longer counts (REV11 F4).
                item.downloadOrigin = FeedDownloadOrigin.after(asked.origin, given: item.downloadOrigin)
            }
            DiagnosticLog.event(.feeds, "FEED_DOWNLOAD_FAILED: \(item.title) (\(feed.title)): \(message)")
            announce(.downloadFailed(feedID: request.feedID, itemID: request.itemID, reason: message))
            return .failed
        }
    }

    /// Downloads an episode's file and imports it as an audiobook: as the
    /// book `kept` was, when the item's package was kept after an earlier
    /// download's file went.
    private func downloadEpisode(
        _ item: FeedItem,
        enclosure: FeedEnclosure,
        of feed: Feed,
        request: Request,
        restoring kept: Book?
    ) async throws -> Book {
        // A file no type or extension names as one TextMouth plays is never
        // fetched; the server's own type may still decide once it answers.
        guard FeedEpisodeImporter.fileExtension(responseMIMEType: nil, enclosure: enclosure) != nil else {
            throw FeedDownloadError.unsupportedFile(enclosure.mimeType ?? enclosure.url.pathExtension)
        }
        if let length = enclosure.length, let free = environment.freeSpace(TextMouthPaths.libraryDir),
           free - length < environment.reserve {
            throw FeedDownloadError.notEnoughSpace(bytes: length)
        }
        let resumeFile = resumeDataFile(for: request.itemID, of: request.feedID)
        let resumeData = try? Data(contentsOf: resumeFile)
        let holding = environment.holdingFolder.appendingPathComponent("\(UUID().uuidString).download")
        let estimate = enclosure.length
        let transfer = FeedTransferHandle()
        currentTransfer = transfer
        defer { currentTransfer = nil }
        let downloaded: FeedDownloadedFile
        do {
            downloaded = try await environment.network.download(
                enclosure.url,
                resumingFrom: resumeData,
                to: holding,
                discretionary: request.origin == .window,
                handle: transfer
            ) { written, expected in
                // On the main queue, in the order the bytes arrived.
                DispatchQueue.main.async {
                    self.downloaded(written, of: expected, estimate: estimate, for: request)
                }
            }
        } catch let failure as FeedTransferFailure {
            if failure.error == .cancelled, isStoppedForQuit {
                // Quitting stopped it, and `stopForQuit()` keeps what it
                // downloaded in the resume file.
            } else if let data = failure.resumeData, failure.error != .cancelled {
                Self.saveResumeData(data, to: resumeFile)
            } else {
                try? FileManager.default.removeItem(at: resumeFile)
            }
            throw FeedDownloadError.transfer(failure.error)
        }
        try? FileManager.default.removeItem(at: resumeFile)
        defer { try? FileManager.default.removeItem(at: holding) }
        guard let fileExtension = FeedEpisodeImporter.fileExtension(responseMIMEType: downloaded.mimeType, enclosure: enclosure) else {
            throw FeedDownloadError.unsupportedFile(downloaded.mimeType ?? enclosure.mimeType ?? enclosure.url.pathExtension)
        }
        let fileName = FeedEpisodeImporter.fileName(title: item.title, fileExtension: fileExtension)
        let now = environment.now()
        return try await importAndCommit(request) {
            try FeedEpisodeImporter.importEpisode(holding, named: fileName, item: item, of: feed, dateAdded: now, restoring: kept)
        }
    }

    /// Writes an article's book and imports it as an HTML book: as the book
    /// `kept` was, when the item's package was kept after an earlier
    /// download's file went.
    private func downloadArticle(_ item: FeedItem, of feed: Feed, request: Request, restoring kept: Book?) async throws -> Book {
        let network = environment.network
        let discretionary = request.origin == .window
        let body = try await FeedEpisodeImporter.articleBody(for: item) { link in
            do {
                guard case .body(let page) = try await network.fetch(link, discretionary: discretionary) else { return nil }
                return page.text
            } catch let refusal as FeedFetchError where discretionary && Self.waitsForANetwork(refusal) {
                // The rule's article waits for a network without data
                // limits, as its episodes do, rather than be written for
                // good from its summary (feed review item 14).
                throw FeedDownloadError.transfer(refusal)
            } catch {
                // Any other failure leaves the item's own text to stand.
                return nil
            }
        }
        // Stopped meanwhile, by Cancel Download or the downloads section's
        // Cancel (FR10): it stops here, before its book is written. A page
        // whose fetch was stopped reads as none, and the article would
        // otherwise be written from its summary all the same.
        try Task.checkCancellation()
        let html = FeedEpisodeImporter.articleHTML(for: item, of: feed, body: body)
        let now = environment.now()
        return try await importAndCommit(request) {
            try FeedEpisodeImporter.importArticle(html: html, item: item, of: feed, dateAdded: now, restoring: kept)
        }
    }

    /// Runs `work` off the main thread on the queue imports run on, after
    /// every import asked for before it, and returns what it returns (FR11).
    /// The engine's own rules remove feed items' files here, so a download
    /// restoring an item into its kept package, which imports here too, never
    /// interleaves with the removal of a file from that package.
    func runBesideImports<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
        let queue = importQueue
        return await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }

    /// Runs `importBook` on the import queue as storage work and, before that
    /// work ends, adds its book to the library and marks the item downloaded
    /// on the main actor, as every import adds its book. The downloads'
    /// progress says the book is being added (FR10).
    private func importAndCommit(_ request: Request, _ importBook: @escaping @Sendable () throws -> ImportedBook) async throws -> Book {
        progress.beginAddingToLibrary()
        let boundary = environment.boundary
        let queue = importQueue
        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Book, Error>) in
                queue.async {
                    do {
                        let book = try boundary.perform(.importing) { _ -> Book in
                            let imported = try importBook()
                            let listed = DispatchQueue.main.sync {
                                self.commit(imported.book, for: request)
                            }
                            // Its item was deleted while it imported: the
                            // download ends as if stopped.
                            guard listed else { throw FeedDownloadError.transfer(.cancelled) }
                            return imported.book
                        }
                        continuation.resume(returning: book)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch let error as FeedDownloadError {
            throw error
        } catch {
            throw FeedDownloadError.importFailed(ImportFailure.reason(for: error))
        }
    }

    /// Adds `book` to the library and marks the item of `request` downloaded
    /// as it, by whoever asked for it (FR11): the listener when the listener
    /// asked at any point, otherwise the newest-N rule. Returns whether it
    /// did.
    ///
    /// An item gone from its record, or deleted, while its download imported
    /// (Delete Episode stops a transfer, but not an import once begun, which
    /// may be restoring the item's kept package meanwhile) gets no row: the
    /// package the import just published, in the kept package's place when
    /// it restored one, is deleted for good, so nothing of a deleted item
    /// comes back.
    private func commit(_ book: Book, for request: Request) -> Bool {
        beforeCommit?(request)
        guard let item = store.record(of: request.feedID)?.item(request.itemID), item.deletedDate == nil else {
            discardPackage(of: book)
            return false
        }
        library()?.addFeedBook(book)
        let origin = latest(request).origin
        store.updateItem(request.itemID, of: request.feedID) { item in
            item.state = .downloaded(bookID: book.id)
            item.downloadDeletedDate = nil
            item.downloadOrigin = origin
        }
        return true
    }

    /// Deletes for good the package an import published for an item deleted
    /// while it imported: only a package in its feed's own folder, as every
    /// download publishes one, and never anything else.
    private func discardPackage(of book: Book) {
        guard book.feedLink != nil, FeedItemPackage.isPackageName(book.tmbDirectoryName) else { return }
        do {
            try FileManager.default.removeItem(at: book.tmbDirectory)
        } catch CocoaError.fileNoSuchFile {
            // Deleted with its item already.
        } catch {
            DiagnosticLog.event(.feeds, "FEED_DOWNLOAD_LEFT: \(book.title): its item was deleted, and its package could not be: \(error.localizedDescription)")
            return
        }
        DiagnosticLog.event(.feeds, "FEED_DOWNLOAD_DISCARDED: \(book.title): its item was deleted while it imported")
    }

    /// `request` as it stands now: the download under way when it is the
    /// same item's, which asking again while it ran may have made the
    /// listener's, or one that opens when done; otherwise as it was asked.
    private func latest(_ request: Request) -> Request {
        guard let current, current.feedID == request.feedID, current.itemID == request.itemID else { return request }
        return current
    }

    /// Tells the downloads' progress how far the download `request` has
    /// got, at every report, which it keeps without publishing (FR10).
    /// Nothing of it goes into the item, whose state says only that it
    /// downloads: no report compares the feed's record (board #1410) or
    /// redraws a Library list (PERF12).
    private func downloaded(_ written: Int64, of expected: Int64, estimate: Int64?, for request: Request) {
        guard current == request || current?.itemID == request.itemID else { return }
        progress.receive(Self.progress(written: written, expected: expected, estimate: estimate))
    }

    /// A download's progress, as a cloud download's is counted: in bytes,
    /// against the bytes the server says are coming, or the feed's estimate
    /// until it says.
    static func progress(written: Int64, expected: Int64, estimate: Int64?) -> BookDownloadProgress {
        let total = expected > 0 ? expected : max(estimate ?? 0, 0)
        return BookDownloadProgress(completedFiles: 0, totalFiles: 1, completedBytes: max(0, written), totalBytes: total)
    }

    // MARK: The Downloads' Progress (FR10)

    /// Tells the downloads' progress that the download `request` began, by
    /// its item's and its feed's titles, an episode's file at none of the
    /// bytes its feed gives; an article's page comes uncounted. A request
    /// whose item went begins nothing, and ends at once.
    private func beginProgress(of request: Request) {
        guard let record = store.record(of: request.feedID), let item = record.item(request.itemID) else {
            publishQueue()
            return
        }
        let transfer = Self.isEpisode(item) ? Self.progress(written: 0, expected: 0, estimate: item.enclosure?.length) : nil
        progress.begin(title: item.title, feedTitle: record.feed.title, transfer: transfer, queued: queuedSizes, waits: waitingApart())
    }

    /// Tells the downloads' progress the downloads waiting to start and
    /// those waiting apart, as they stand now.
    private func publishQueue() {
        progress.update(queued: queuedSizes, waits: waitingApart())
    }

    /// What Speak Download Progress says now (FR10): every line the feed
    /// downloads section shows, or that no download is under way, with the
    /// downloads waiting apart counted anew first, as a wait for room lives
    /// only in its item's state, which can change, or go with its feed's
    /// record, without the queue changing.
    func spokenProgress() -> String {
        publishQueue()
        return progress.spokenStatus()
    }

    /// The downloads waiting to start, in order, each by the bytes its feed
    /// gives for its file: nil for an article, and for an episode whose feed
    /// gives none.
    private var queuedSizes: [Int64?] {
        queue.map { request in
            store.record(of: request.feedID)?.item(request.itemID).flatMap { item in
                Self.isEpisode(item) ? item.enclosure?.length : nil
            }
        }
    }

    /// Whether `item` downloads as an episode, its file through the network,
    /// rather than as an article, whose page is its book: as `run(_:)` tells
    /// them apart.
    private static func isEpisode(_ item: FeedItem) -> Bool {
        item.enclosure?.isPlayable == true
    }

    /// The newest-N rule's downloads waiting apart (FR11), by their reason:
    /// those a network with data limits put off, held as requests, and
    /// those waiting for room, which only their items' states say.
    private func waitingApart() -> FeedDownloadWaits {
        var room = 0
        for record in store.records.values {
            for item in record.items where item.state.waitingReason != nil && !isPutOff(item.id, of: record.feed.id) {
                room += 1
            }
        }
        return FeedDownloadWaits(network: putOff.count, room: room)
    }

    // MARK: Quitting

    /// A download asked for when TextMouth quit, as the list of them in
    /// this Mac's resume folder keeps it.
    struct SavedDownload: Codable, Equatable, Sendable {
        let feedID: UUID
        let itemID: FeedItem.ID
        let origin: Origin
    }

    /// Whether a download waits, runs, or was put off by a network with data
    /// limits, which quitting keeps the place of.
    var hasWork: Bool {
        current != nil || !queue.isEmpty || !putOff.isEmpty
    }

    /// Where the downloads asked for when TextMouth quit are listed, beside
    /// their resume data: this Mac's own, never synced.
    var savedAtQuitFile: URL {
        environment.resumeFolder.appendingPathComponent("Downloads at Quit.json")
    }

    /// Stops every download as TextMouth quits, keeping each one's place for
    /// the next launch (`resumeDownloadsSavedAtQuit()`): every download asked
    /// for, the one under way first and those a network with data limits put
    /// off last, is listed in this Mac's resume folder, and then the one
    /// under way stops, keeping what it downloaded as resume data when its
    /// server allows. Nothing starts afterwards. Returns once both are
    /// written. The list comes first, so a quit that stops waiting for the
    /// resume data still finds every download again; an article, or an
    /// import under way, is listed and starts over.
    func stopForQuit() async {
        guard !isStoppedForQuit else { return }
        isStoppedForQuit = true
        // The section shows nothing more, and VoiceOver hears no end (FR10).
        progress.clear()
        let pending = (current.map { [$0] } ?? []) + queue + putOff
        guard !pending.isEmpty else { return }
        let saved = pending.map { SavedDownload(feedID: $0.feedID, itemID: $0.itemID, origin: $0.origin) }
        let list = savedAtQuitFile
        await OffMainWork.run(on: .global(qos: .userInitiated)) { Self.saveList(saved, to: list) }
        guard let running = current, let transfer = currentTransfer, let data = await transfer.stopKeepingResumeData() else {
            DiagnosticLog.trace(.feeds, "quitting: \(saved.count) download(s) listed for the next launch, without resume data")
            return
        }
        let file = resumeDataFile(for: running.itemID, of: running.feedID)
        await OffMainWork.run(on: .global(qos: .userInitiated)) { Self.saveResumeData(data, to: file) }
        DiagnosticLog.trace(.feeds, "quitting: \(saved.count) download(s) listed for the next launch, one with resume data")
    }

    /// Asks again for the downloads `stopForQuit()` listed when TextMouth
    /// last quit, in their order and for the reasons first asked, and
    /// forgets the list: each item still listed and not downloaded downloads
    /// again, going on from its resume data when it has some. None opens
    /// its book when done. The engine runs this once as it starts.
    func resumeDownloadsSavedAtQuit() async {
        let list = savedAtQuitFile
        let saved = await OffMainWork.run(on: .global(qos: .utility)) { () -> [SavedDownload] in
            defer { try? FileManager.default.removeItem(at: list) }
            guard let data = try? Data(contentsOf: list) else { return [] }
            return (try? JSONDecoder().decode([SavedDownload].self, from: data)) ?? []
        }
        for download in saved {
            self.download(download.itemID, of: download.feedID, origin: download.origin)
        }
    }

    /// Writes the list of downloads `saved` to `file`; a failure only means
    /// the next launch asks for none of them.
    nonisolated private static func saveList(_ saved: [SavedDownload], to file: URL) {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    // MARK: Files

    /// Where the resume data of the item `itemID` of the feed `feedID` is
    /// kept: a name of its feed and a digest of its identity, which can hold
    /// any character.
    func resumeDataFile(for itemID: FeedItem.ID, of feedID: UUID) -> URL {
        let digest = SHA256.hash(data: Data(itemID.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return environment.resumeFolder.appendingPathComponent("\(feedID.uuidString)-\(digest).resume")
    }

    /// Keeps `data` as resume data at `file`; a failure only means the next
    /// download starts over.
    nonisolated private static func saveResumeData(_ data: Data, to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// Removes what interrupted downloads left: every finished download
    /// waiting in the holding folder, which nothing imports any more once
    /// TextMouth has quit, and resume data older than `resumeDataLifetime`.
    /// Runs off the main thread.
    func sweepLeftovers() async {
        let holding = environment.holdingFolder
        let resume = environment.resumeFolder
        let cutoff = environment.now().addingTimeInterval(-Self.resumeDataLifetime)
        let inUse = current != nil || !queue.isEmpty
        await OffMainWork.run(on: .global(qos: .utility)) {
            let fileManager = FileManager.default
            if !inUse {
                for name in (try? fileManager.contentsOfDirectory(atPath: holding.path)) ?? [] {
                    try? fileManager.removeItem(at: holding.appendingPathComponent(name))
                }
            }
            for name in (try? fileManager.contentsOfDirectory(atPath: resume.path)) ?? [] {
                let file = resume.appendingPathComponent(name)
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified < cutoff {
                    try? fileManager.removeItem(at: file)
                }
            }
        }
    }

    /// How long resume data is kept: a week, past which a server has most
    /// likely changed the file or forgotten the download.
    static let resumeDataLifetime: TimeInterval = 7 * 86_400

    /// Whether a fetch that failed as `refusal` waits for a network, when
    /// the newest-N rule asked for it: refused on a network with data
    /// limits, or this Mac offline (`FeedDownloadWait.network`).
    nonisolated static func waitsForANetwork(_ refusal: FeedFetchError) -> Bool {
        FeedDownloadWait(.transfer(refusal)) == .network
    }

    /// `error` as a download error.
    private static func downloadError(_ error: Error) -> FeedDownloadError {
        if let error = error as? FeedDownloadError {
            return error
        }
        if error is CancellationError {
            return .transfer(.cancelled)
        }
        return .importFailed(ImportFailure.reason(for: error))
    }
}

// MARK: - Holding a Quit

/// Holds a quit while the feed downloads keep their place (FR03). The
/// application delegate asks it only once the quit is sure to go ahead,
/// with nothing unsaved or Quit Anyway chosen, so a quit that leaves
/// TextMouth open never stops a download.
@MainActor
enum FeedQuitHold {
    /// The longest a quit waits for the downloads: producing resume data
    /// takes a moment, and past this TextMouth quits anyway, the list of
    /// downloads written already and the one under way starting over.
    static let longestWait: Duration = .seconds(3)

    /// Holds the quit while `downloads` stop keeping their place
    /// (`FeedDownloadManager.stopForQuit()`), when any waits or runs, and
    /// returns whether it holds it, for the delegate to answer
    /// `.terminateLater`. `reply` is then called once, with true, as soon as
    /// the downloads have kept their place or `longestWait` has passed.
    static func hold(
        _ downloads: FeedDownloadManager,
        longestWait: Duration = FeedQuitHold.longestWait,
        reply: @escaping @MainActor (Bool) -> Void
    ) -> Bool {
        guard downloads.hasWork, !downloads.isStoppedForQuit else { return false }
        let answer = HeldQuitAnswer(reply)
        Task {
            await downloads.stopForQuit()
            answer.give()
        }
        Task {
            try? await Task.sleep(for: longestWait)
            answer.give()
        }
        return true
    }
}

/// The answer to one held quit, given once, by whichever of its waits ends
/// first.
@MainActor
private final class HeldQuitAnswer {
    /// Answers the quit, until it has been answered.
    private var reply: ((Bool) -> Void)?

    /// An answer given through `reply`.
    init(_ reply: @escaping @MainActor (Bool) -> Void) {
        self.reply = reply
    }

    /// Lets the quit go ahead, unless it was let go already.
    func give() {
        guard let reply else { return }
        self.reply = nil
        reply(true)
    }
}

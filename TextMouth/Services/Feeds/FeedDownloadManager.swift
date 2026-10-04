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
/// published in its item's state as a cloud download's is, so the library
/// shows "Downloading 40%" (counted in bytes, against the length the server
/// gives, or the feed's estimate until it does), whole percents only. A
/// download that stops partway keeps the resume data the server allows in
/// this Mac's Feeds folder in Caches, and the next download of the item
/// goes on from there. The finished file waits in this Mac's Feed Downloads
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
@MainActor
final class FeedDownloadManager {
    /// Why a download was asked for.
    enum Origin: Equatable, Sendable {
        /// The listener asked: Download, or opening an item.
        case listener
        /// A refresh found the item new, with automatic downloads on: it waits
        /// for a network without data limits.
        case automatic
    }

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
    /// The whole percent last published for the download under way.
    private var publishedPercent = -1
    /// Runs imports in order, off the main thread.
    private let importQueue = DispatchQueue(label: "com.textmouth.feed-imports", qos: .userInitiated)

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
    }

    // MARK: Asking

    /// Downloads the item `itemID` of the feed `feedID`, after those already
    /// waiting; one the listener opens comes first, and opens once its book
    /// is in the library. An item downloaded already, whose book is in the
    /// library, opens at once when asked. Asking again for an item that
    /// waits or downloads only adds what the new request adds.
    func download(_ itemID: FeedItem.ID, of feedID: UUID, origin: Origin, opening: Bool = false) {
        guard let item = store.record(of: feedID)?.item(itemID), item.deletedDate == nil else { return }
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
        store.updateItem(itemID, of: feedID) { $0.state = .downloading(Self.progress(written: 0, expected: 0, estimate: $0.enclosure?.length)) }
        startNext()
    }

    /// Stops the download of the item `itemID`, or takes it out of the
    /// queue, forgetting any part downloaded; the item is not downloaded.
    func cancel(_ itemID: FeedItem.ID, of feedID: UUID) {
        if let waiting = queue.firstIndex(where: { $0.feedID == feedID && $0.itemID == itemID }) {
            queue.remove(at: waiting)
            store.updateItem(itemID, of: feedID) { $0.state = .notDownloaded }
        } else if current?.feedID == feedID, current?.itemID == itemID {
            currentTask?.cancel()
        }
        try? FileManager.default.removeItem(at: resumeDataFile(for: itemID, of: feedID))
    }

    /// Whether the item `itemID` waits or downloads.
    func isDownloading(_ itemID: FeedItem.ID, of feedID: UUID) -> Bool {
        (current?.feedID == feedID && current?.itemID == itemID)
            || queue.contains { $0.feedID == feedID && $0.itemID == itemID }
    }

    /// Takes every waiting and running download of the feed `feedID` away,
    /// as when it is no longer subscribed.
    func cancelAll(of feedID: UUID) {
        queue.removeAll { $0.feedID == feedID }
        if current?.feedID == feedID {
            currentTask?.cancel()
        }
    }

    // MARK: Running

    /// Starts the next download when none is under way.
    private func startNext() {
        guard current == nil, !queue.isEmpty else { return }
        let request = queue.removeFirst()
        current = request
        publishedPercent = -1
        currentTask = Task {
            await run(request)
            current = nil
            currentTask = nil
            startNext()
        }
    }

    /// Runs the download `request`, to its book or its failure.
    private func run(_ request: Request) async {
        guard let record = store.record(of: request.feedID), let item = record.item(request.itemID),
              item.deletedDate == nil else { return }
        let feed = record.feed
        DiagnosticLog.event(.feeds, "FEED_DOWNLOAD_STARTED: \(item.title) (\(feed.title))")
        announce(.downloadStarted(feedID: request.feedID, itemID: request.itemID))
        do {
            guard let folderPath = library()?.feedFolderPath(forFolderID: feed.folderID) else {
                throw FeedDownloadError.folderMissing
            }
            let book: Book
            if let enclosure = item.enclosure, enclosure.isPlayable {
                book = try await downloadEpisode(item, enclosure: enclosure, of: feed, toFolder: folderPath, request: request)
            } else {
                book = try await downloadArticle(item, of: feed, toFolder: folderPath, request: request)
            }
            DiagnosticLog.event(.feeds, "FEED_DOWNLOAD_FINISHED: \(item.title) (\(feed.title))")
            announce(.downloadFinished(feedID: request.feedID, itemID: request.itemID, bookID: book.id))
            if current?.opensWhenDone == true {
                library()?.openFeedBook(book.id)
            }
        } catch {
            let failure = Self.downloadError(error)
            if failure == .transfer(.cancelled) {
                store.updateItem(request.itemID, of: request.feedID) { $0.state = .notDownloaded }
                DiagnosticLog.event(.feeds, "FEED_DOWNLOAD_CANCELLED: \(item.title) (\(feed.title))")
                return
            }
            let message = failure.message(about: item.title)
            store.updateItem(request.itemID, of: request.feedID) { $0.state = .failed(message) }
            DiagnosticLog.event(.feeds, "FEED_DOWNLOAD_FAILED: \(item.title) (\(feed.title)): \(message)")
            announce(.downloadFailed(feedID: request.feedID, itemID: request.itemID, reason: message))
        }
    }

    /// Downloads an episode's file and imports it as an audiobook.
    private func downloadEpisode(
        _ item: FeedItem,
        enclosure: FeedEnclosure,
        of feed: Feed,
        toFolder folderPath: String,
        request: Request
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
        let downloaded: FeedDownloadedFile
        do {
            downloaded = try await environment.network.download(
                enclosure.url,
                resumingFrom: resumeData,
                to: holding,
                discretionary: request.origin == .automatic
            ) { written, expected in
                // On the main queue, in the order the bytes arrived.
                DispatchQueue.main.async {
                    self.downloaded(written, of: expected, estimate: estimate, for: request)
                }
            }
        } catch let failure as FeedTransferFailure {
            if let data = failure.resumeData, failure.error != .cancelled {
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
            try FeedEpisodeImporter.importEpisode(holding, named: fileName, item: item, of: feed, toFolder: folderPath, dateAdded: now)
        }
    }

    /// Writes an article's book and imports it as an HTML book.
    private func downloadArticle(_ item: FeedItem, of feed: Feed, toFolder folderPath: String, request: Request) async throws -> Book {
        let network = environment.network
        let discretionary = request.origin == .automatic
        let body = await FeedEpisodeImporter.articleBody(for: item) { link in
            guard case .body(let page)? = try? await network.fetch(link, discretionary: discretionary) else { return nil }
            return page.text
        }
        let html = FeedEpisodeImporter.articleHTML(for: item, of: feed, body: body)
        let now = environment.now()
        return try await importAndCommit(request) {
            try FeedEpisodeImporter.importArticle(html: html, item: item, of: feed, toFolder: folderPath, dateAdded: now)
        }
    }

    /// Runs `importBook` on the import queue as storage work and, before that
    /// work ends, adds its book to the library and marks the item downloaded
    /// on the main actor, as every import adds its book.
    private func importAndCommit(_ request: Request, _ importBook: @escaping @Sendable () throws -> ImportedBook) async throws -> Book {
        let boundary = environment.boundary
        let queue = importQueue
        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Book, Error>) in
                queue.async {
                    do {
                        let book = try boundary.perform(.importing) { _ -> Book in
                            let imported = try importBook()
                            DispatchQueue.main.sync {
                                self.commit(imported.book, for: request)
                            }
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
    /// as it.
    private func commit(_ book: Book, for request: Request) {
        library()?.addFeedBook(book)
        store.updateItem(request.itemID, of: request.feedID) { item in
            item.state = .downloaded(bookID: book.id)
            item.downloadDeletedDate = nil
        }
    }

    /// Publishes how far the download `request` has got, when its whole
    /// percent grew, while its item is still downloading.
    private func downloaded(_ written: Int64, of expected: Int64, estimate: Int64?, for request: Request) {
        guard current == request || current?.itemID == request.itemID else { return }
        let progress = Self.progress(written: written, expected: expected, estimate: estimate)
        guard progress.percent > publishedPercent else { return }
        publishedPercent = progress.percent
        store.updateItem(request.itemID, of: request.feedID) { item in
            guard item.state.isDownloading else { return }
            item.state = .downloading(progress)
        }
    }

    /// A download's progress, as a cloud download's is counted: in bytes,
    /// against the bytes the server says are coming, or the feed's estimate
    /// until it says.
    static func progress(written: Int64, expected: Int64, estimate: Int64?) -> BookDownloadProgress {
        let total = expected > 0 ? expected : max(estimate ?? 0, 0)
        return BookDownloadProgress(completedFiles: 0, totalFiles: 1, completedBytes: max(0, written), totalBytes: total)
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
    private static func saveResumeData(_ data: Data, to file: URL) {
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

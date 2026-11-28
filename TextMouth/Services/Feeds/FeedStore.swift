import Combine
import Foundation

// MARK: - Where Feed Files Live (FR03)

/// Where the feed engine keeps its files (FR03).
///
/// - The data directory's Feeds folder, beside library.json, holds one
///   record per subscription, `<feed ID>.json` (`FeedRecord`). It syncs with
///   a library in the cloud and moves with the data directory.
/// - This Mac's Caches folder holds a Feeds folder of what a refresh makes
///   again (`FeedFetchState`) and the resume data of downloads stopped
///   partway; Application Support holds finished downloads waiting to be
///   imported. None of these syncs.
enum FeedPaths {
    /// The name of the data directory's folder of feed records.
    static let recordsFolderName = "Feeds" // l10n: no (a folder name on disk)

    /// The folder of feed records in the data directory at `root`.
    static func recordsFolder(in root: URL) -> URL {
        root.appendingPathComponent(recordsFolderName, isDirectory: true)
    }

    /// The record file of the feed `feedID` in `folder`.
    static func recordFile(of feedID: UUID, in folder: URL) -> URL {
        folder.appendingPathComponent("\(feedID.uuidString).json", isDirectory: false)
    }

    /// The feed whose record a file named `name` holds: a name that is
    /// exactly a feed's ID, as TextMouth writes it, followed by ".json". A
    /// sync service's conflict copy ("<ID> 2.json") and a preserved
    /// unreadable copy name none, so neither is ever read in place of the
    /// record it copies.
    static func feedID(ofRecordNamed name: String) -> UUID? {
        guard name.hasSuffix(".json") else { return nil }
        let stem = String(name.dropLast(".json".count))
        guard let id = UUID(uuidString: stem), id.uuidString == stem else { return nil }
        return id
    }
}

extension MachineLocalPaths {
    /// This Mac's Feeds folder in Caches: each feed's fetch details
    /// (`FeedFetchStates`) and the resume data of downloads stopped partway
    /// (`FeedDownloadManager`). A refresh or a download makes all of it
    /// again, so it lives where macOS may empty it and Time Machine leaves
    /// it out.
    static var feedCaches: URL {
        caches.appendingPathComponent("Feeds", isDirectory: true)
    }

    /// Finished feed downloads waiting to be imported, kept on this Mac's
    /// own disk between the download and its import (`FeedDownloadManager`).
    /// Whatever an interrupted import leaves here is removed at the next
    /// launch.
    static var feedDownloads: URL {
        root.appendingPathComponent("Feed Downloads", isDirectory: true)
    }
}

// MARK: - Reading and Writing Records

/// How feed records are written to and read from disk. Dates are ISO 8601,
/// and the keys sorted and indented, so a record reads well by hand and two
/// records of one feed compare line by line.
enum FeedRecordCoding {
    /// Writes records.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Reads records.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - The Store

/// Every subscription's record, on the main actor (FR03).
///
/// The store is the live copy of the data directory's Feeds folder: it reads
/// every record once (`load()`), off the main thread, and writes a record
/// whenever its durable form changes (`update(_:_:)`), on a serial queue of
/// its own. A download asked for, under way, or waiting is published but
/// never written (`FeedRecord.durable`), and how far a download has got
/// never reaches the store (FR10, `FeedDownloadProgress`). Each write
/// replaces its file atomically, as
/// storage work (`StorageWork.savingFeeds`): a data-directory move waits for
/// a write under way and holds the next, which then goes to the new data
/// directory, so no record is written into the old one after the copy.
///
/// A record that can't be read or decoded is preserved beside itself and
/// left out; a record only in the cloud is asked of the sync service and
/// read again by `loadRecordsInCloud()`. A write that fails, or that waits
/// while the data directory is unavailable, is tried again with the feed's
/// next change and once the data directory is back. A write that fails is
/// reported to `PersistenceFailureCenter`, as every other save is, with a
/// retry, so the Library window's banner names the feed and quitting asks
/// first; the feed's next write that succeeds settles it, and removing the
/// feed's record (`remove(_:)`, as Delete Feed… does) withdraws it. A quit
/// waits for the writes and removals still on the queue (`quitWork()`).
@MainActor
final class FeedStore: ObservableObject {
    /// Where a store keeps its records.
    struct Location: Sendable {
        /// The Feeds folder of the data directory in use now, for reads.
        let currentFolder: @Sendable () -> URL
        /// The Feeds folder of a generation's data directory, for writes.
        let folder: @Sendable (StorageGeneration) -> URL
        /// The boundary every write runs through as storage work.
        let boundary: StorageBoundary
        /// Whether the data directory in use can't be written now (FR02).
        let isUnavailable: @Sendable () -> Bool

        /// The app's: the Feeds folder of the data directory in use.
        static var app: Location {
            Location(
                currentFolder: { FeedPaths.recordsFolder(in: TextMouthPaths.root) },
                folder: { FeedPaths.recordsFolder(in: $0.root) },
                boundary: .shared,
                isUnavailable: { TextMouthPaths.isDataDirectoryUnavailable }
            )
        }

        /// A folder of a test's own, outside any data directory.
        static func folder(_ folder: URL, boundary: StorageBoundary = .shared) -> Location {
            Location(
                currentFolder: { folder },
                folder: { _ in folder },
                boundary: boundary,
                isUnavailable: { false }
            )
        }
    }

    /// Every subscription's record, by feed ID.
    @Published private(set) var records: [UUID: FeedRecord] = [:]
    /// Whether the records have been read from disk.
    @Published private(set) var hasLoaded = false

    /// Where the records are kept.
    let location: Location
    /// The record files found only in the cloud, by feed ID, which
    /// `loadRecordsInCloud()` reads once they are on this Mac.
    private(set) var recordsInCloud: Set<UUID> = []
    /// The feeds whose latest change is not on disk yet: their write failed
    /// or waited while the data directory was unavailable.
    private(set) var unsavedFeedIDs: Set<UUID> = []
    /// The feeds whose retry waited for an operation holding the storage
    /// work (`retryWrite(of:failureID:)`) and whose write has not ended yet.
    /// Once the last has ended, VoiceOver hears how the retry went.
    private var retriesWaiting: Set<UUID> = []
    /// Writes and removes record files in the order asked.
    private let writeQueue = DispatchQueue(label: "com.textmouth.feed-records", qos: .utility)
    /// The feeds with a write or a removal of their record on the write
    /// queue that has not reported back yet, each with how many and the
    /// feed's title: what a quit waits for (`quitWork()`).
    private var changesUnderWay: [UUID: ChangeUnderWay] = [:]
    /// Where failed writes are reported.
    private let failureCenter: PersistenceFailureCenter
    /// Hears when the data directory is available again.
    private var availabilitySubscription: AnyCancellable?

    /// A store keeping its records at `location`, read by `load()`, and
    /// reporting failed writes to `failureCenter`.
    init(location: Location = .app, failureCenter: PersistenceFailureCenter = .shared) {
        self.location = location
        self.failureCenter = failureCenter
        availabilitySubscription = NotificationCenter.default
            .publisher(for: .dataDirectoryDidBecomeAvailable)
            .sink { [weak self] _ in self?.saveUnsavedRecords() }
    }

    // MARK: Reading

    /// Every subscription, by title.
    var feeds: [Feed] {
        records.values.map(\.feed).sortedStably {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    /// The record of the feed `feedID`, subscribed or not (FR11, branch D),
    /// if the library has the feed.
    func record(of feedID: UUID) -> FeedRecord? {
        records[feedID]
    }

    /// The feed whose downloads go to the folder `folderID`, if any.
    func feed(inFolder folderID: UUID) -> Feed? {
        feeds.first { $0.folderID == folderID }
    }

    /// The feed and item a book was downloaded from, found by the book's ID.
    func item(downloadedAs bookID: UUID) -> (feed: Feed, item: FeedItem)? {
        for record in records.values {
            if let item = record.item(downloadedAs: bookID) {
                return (record.feed, item)
            }
        }
        return nil
    }

    /// The feed and item linked to a book, found by the book's ID: the
    /// item downloaded as it, or moved into the library as it by Move to
    /// Library… (FR11, branch D, `FeedRecord.item(linkedTo:)`).
    func item(linkedTo bookID: UUID) -> (feed: Feed, item: FeedItem)? {
        for record in records.values {
            if let item = record.item(linkedTo: bookID) {
                return (record.feed, item)
            }
        }
        return nil
    }

    /// Reads every record in the Feeds folder off the main thread and makes
    /// them the store's. A record added meanwhile, by a subscription made
    /// before the folder was read, is kept. Records found only in the cloud
    /// are asked of the sync service.
    func load() async {
        let folder = location.currentFolder()
        let read = await OffMainWork.run(on: .global(qos: .utility)) {
            Self.readRecords(in: folder)
        }
        records = read.records.merging(records) { _, kept in kept }
        recordsInCloud = read.inCloud
        hasLoaded = true
        requestDownloads(of: read.inCloud, in: folder)
    }

    /// Reads again the records `load()` found only in the cloud, adding
    /// each that is on this Mac now. A feed subscribed or changed meanwhile
    /// keeps its record as the store holds it.
    func loadRecordsInCloud() async {
        // Only once `load()` has listed what is in the cloud.
        guard hasLoaded, !recordsInCloud.isEmpty else { return }
        let folder = location.currentFolder()
        let waiting = recordsInCloud
        let read = await OffMainWork.run(on: .global(qos: .utility)) {
            Self.readRecords(in: folder, only: waiting)
        }
        records = read.records.merging(records) { _, kept in kept }
        recordsInCloud = read.inCloud
        requestDownloads(of: read.inCloud, in: folder)
    }

    /// What reading the Feeds folder found: the records read, and the feeds
    /// whose records are only in the cloud.
    struct ReadResult: Sendable {
        var records: [UUID: FeedRecord] = [:]
        var inCloud: Set<UUID> = []
    }

    /// Reads the record files in `folder`, or only those of the feeds in
    /// `only`, with dataless files left in the cloud. A file that can't be
    /// read or decoded is preserved beside itself and left out, with one
    /// FEED_RECORD_UNREADABLE line.
    nonisolated static func readRecords(in folder: URL, only: Set<UUID>? = nil) -> ReadResult {
        var result = ReadResult()
        let names = DatalessFiles.withoutDownloading {
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        }
        let decoder = FeedRecordCoding.decoder()
        for name in names.sortedStably() {
            guard let feedID = FeedPaths.feedID(ofRecordNamed: name), only?.contains(feedID) ?? true else { continue }
            let file = FeedPaths.recordFile(of: feedID, in: folder)
            let unusable: (bytes: Data?, reason: String)
            switch SavedFile.read(file, using: SavedFile.readWithoutDownloading) {
            case .missing:
                continue
            case .inCloud:
                result.inCloud.insert(feedID)
                DiagnosticLog.event(.feeds, "FEED_RECORD_IN_CLOUD: \(name) is only in the cloud; reading it once it is here")
                continue
            case .contents(let data):
                do {
                    var record = try decoder.decode(FeedRecord.self, from: data)
                    // The file's name decides which feed it holds, so a
                    // record copied under another name is a feed of its own.
                    record.feed.id = feedID
                    result.records[feedID] = record
                    continue
                } catch {
                    unusable = (data, error.localizedDescription)
                }
            case .unreadable(let reason):
                unusable = (nil, reason)
            }
            SavedFile.preserveUnusable(
                file,
                bytes: unusable.bytes,
                because: unusable.reason,
                logging: "FEED_RECORD_UNREADABLE",
                in: .feeds,
                standIn: "the feed is left out until its record can be read" // l10n: no (debug log text, which stays English)
            )
        }
        return result
    }

    /// Asks the sync service for the record files of `feedIDs`, which a read
    /// found only in the cloud.
    private func requestDownloads(of feedIDs: Set<UUID>, in folder: URL) {
        for feedID in feedIDs {
            SavedFile.requestDownload(of: FeedPaths.recordFile(of: feedID, in: folder))
        }
    }

    // MARK: Changing

    /// Adds a new subscription's record and writes it.
    func add(_ record: FeedRecord) {
        records[record.feed.id] = record
        write(record.feed.id)
    }

    /// Removes the feed `feedID` and deletes its record file, and a failed
    /// write of its record no longer needs saving, as Delete Feed… does
    /// (FR14, `FeedCenter.deleteFeed(_:)`) once the feed's downloads and
    /// folder are gone. Any downloads still in the feed's folder would be
    /// returned to the library as books by a later launch, as for any feed
    /// whose record is gone
    /// (`LibraryViewModel.returnDownloadsOfFeedsWithoutRecords`), which is
    /// why Delete Feed… removes the record last. A retry of its record still
    /// waiting for the storage work is dropped, silently: nothing is left to
    /// save, and it no longer holds back what VoiceOver hears of the others.
    func remove(_ feedID: UUID) {
        guard let removed = records.removeValue(forKey: feedID) else { return }
        unsavedFeedIDs.remove(feedID)
        retriesWaiting.remove(feedID)
        failureCenter.withdraw(.feed(feedID))
        let location = location
        noteChangeQueued(of: feedID, title: removed.feed.title)
        // The store is kept until the removal ends, which reports back to it
        // on the main queue, as a write does.
        writeQueue.async {
            location.boundary.perform(.savingFeeds) { generation in
                let file = FeedPaths.recordFile(of: feedID, in: location.folder(generation))
                do {
                    try FileManager.default.removeItem(at: file)
                } catch CocoaError.fileNoSuchFile {
                    // Never written.
                } catch {
                    DiagnosticLog.event(
                        .feeds,
                        "FEED_RECORD_SAVE_FAILED: could not delete \(file.lastPathComponent): \(error.localizedDescription)"
                    )
                }
            }
            DispatchQueue.main.async {
                self.noteChangeEnded(of: feedID)
                // Nothing is left to save for the feed, including a change a
                // quit reported as still under way (`quitWork()`).
                self.failureCenter.withdraw(.feed(feedID))
            }
        }
    }

    /// Changes the record of the feed `feedID` with `change`, and writes it
    /// when its durable form changed. Does nothing for a feed whose record
    /// is gone, such as one deleted while a refresh of it ran (FR14).
    func update(_ feedID: UUID, _ change: (inout FeedRecord) -> Void) {
        guard var record = records[feedID] else { return }
        let before = record
        change(&record)
        guard record != before else { return }
        records[feedID] = record
        if record.durable != before.durable {
            write(feedID)
        }
    }

    /// Changes the item `itemID` of the feed `feedID` with `change`, as
    /// `update(_:_:)` changes a record. Does nothing for an item the record
    /// no longer keeps.
    func updateItem(_ itemID: FeedItem.ID, of feedID: UUID, _ change: (inout FeedItem) -> Void) {
        update(feedID) { record in
            guard let index = record.index(of: itemID) else { return }
            change(&record.items[index])
        }
    }

    // MARK: Writing

    /// A write of a record that failed: why, and the file it was for.
    private struct WriteFailure: Sendable {
        let error: any Error
        let path: String
    }

    /// Writes the record of the feed `feedID` as it is now, on the write
    /// queue, as storage work. The record is encoded there, so a large one
    /// never holds the main thread.
    private func write(_ feedID: UUID) {
        guard let record = records[feedID]?.durable else { return }
        guard !location.isUnavailable() else {
            unsavedFeedIDs.insert(feedID)
            return
        }
        let location = location
        noteChangeQueued(of: feedID, title: record.feed.title)
        // The store is kept until the write ends, which reports back to it
        // on the main queue.
        writeQueue.async {
            let failure = location.boundary.perform(.savingFeeds) { generation -> WriteFailure? in
                Self.writeRecord(record, in: location.folder(generation))
            }
            DispatchQueue.main.async {
                self.noteChangeEnded(of: feedID)
                self.noteWrite(of: feedID, title: record.feed.title, failure: failure)
            }
        }
    }

    /// Records how a write of the feed `feedID`, titled `title`, ended
    /// (`recordOutcome(of:title:failure:)`), and, when a retry of the feed
    /// waited for the storage work, that its wait is over
    /// (`noteEndOfWaitingRetry(of:)`).
    private func noteWrite(of feedID: UUID, title: String, failure: WriteFailure?) {
        recordOutcome(of: feedID, title: title, failure: failure)
        noteEndOfWaitingRetry(of: feedID)
    }

    /// Once a write of the feed `feedID` has ended after its retry waited for
    /// the storage work, and no other feed's retry still waits, tells
    /// VoiceOver how the retry went, as a retry that writes at once is told:
    /// "Feed subscriptions saved.", or "Retry did not succeed." and the
    /// banner's row. The first write to end after the wait answers for it:
    /// it holds the record as it was when it was asked for, and any later
    /// change is written right after it.
    private func noteEndOfWaitingRetry(of feedID: UUID) {
        guard retriesWaiting.remove(feedID) != nil, retriesWaiting.isEmpty else { return }
        failureCenter.announceOutcomeOfWaitingRetry(of: .feedRecords)
    }

    /// Records how a write of the feed `feedID`, titled `title`, ended.
    /// One that succeeded settles any failure reported for the feed. One
    /// that failed leaves the feed unsaved, for its next change or the data
    /// directory's return to write again, and is reported to the failure
    /// center with a retry, unless the feed's record was removed meanwhile,
    /// as Delete Feed… removes it.
    private func recordOutcome(of feedID: UUID, title: String, failure: WriteFailure?) {
        guard let failure else {
            unsavedFeedIDs.remove(feedID)
            failureCenter.recordSuccess(.feed(feedID))
            return
        }
        guard records[feedID] != nil else { return }
        unsavedFeedIDs.insert(feedID)
        // The failure center keeps the retry while an operation holds the
        // storage work, and runs it once that ends (`retryWrite`).
        failureCenter.recordFailure(
            .feedRecord(feedID: feedID, title: title),
            path: failure.path,
            error: failure.error,
            waitsForStorageWork: true
        ) { [weak self] failureID in
            self?.retryWrite(of: feedID, failureID: failureID)
        }
    }

    /// Writes the record of the feed `feedID` again for a retry of the
    /// failed write `failureID`, and waits for it, as a retry must, so the
    /// failure center can say at once how it went. The record is written as
    /// it is now, after every write asked for before, so an older state
    /// never lands over a newer one. Nothing is written when a later write
    /// has settled that failure meanwhile, the feed is gone, or the data
    /// directory can't be written now, which keeps the feed unsaved for its
    /// return.
    ///
    /// While an operation holds the storage work (a data-directory move,
    /// Rebuild Directory, a folder edit, Move to Library, a switch of
    /// libraries), the failure center keeps the retry and runs it once the
    /// operation ends (`PersistenceFailure.waitsForStorageWork`), so this
    /// runs during a hold only for a store whose boundary is not the
    /// center's, as a test's may be: it is the guard for that case. Then the
    /// retry waits for it as every write does: the failure
    /// now says it waits, and when the changes are saved
    /// (`RetryWaitsForStorageWork`), and the record is written as
    /// `write(_:)` writes it, once the hold ends, in the data directory in
    /// use then, which settles the failure; VoiceOver then hears how it went
    /// (`noteEndOfWaitingRetry(of:)`). Waiting here instead held the main
    /// thread for good behind a write already waiting for the hold, which
    /// only the main actor releases; and writing here, on the main thread,
    /// ran unrecorded across the hold (`StorageBoundary.perform`), into a
    /// data directory a move was copying, and called the change saved. With
    /// no hold, none can begin until the write below ends: every hold is
    /// taken on the main actor, which waits for it. A retry that writes at
    /// once stands in for one of the feed still waiting, and the failure
    /// center tells how it went.
    private func retryWrite(of feedID: UUID, failureID: PersistenceFailure.ID) {
        guard let record = records[feedID]?.durable, !location.isUnavailable() else { return }
        if let operation = location.boundary.heldFor {
            let file = FeedPaths.recordFile(of: feedID, in: location.currentFolder())
            // Recorded as an outcome only: the wait has just begun.
            recordOutcome(
                of: feedID,
                title: record.feed.title,
                failure: WriteFailure(error: RetryWaitsForStorageWork(operation: operation, action: .save), path: file.path)
            )
            retriesWaiting.insert(feedID)
            write(feedID)
            return
        }
        retriesWaiting.remove(feedID)
        let location = location
        let failureCenter = failureCenter
        let attempt: (wrote: Bool, failure: WriteFailure?) = writeQueue.sync {
            guard failureCenter.isOutstanding(failureID) else { return (false, nil) }
            let failure = location.boundary.perform(.savingFeeds) { generation -> WriteFailure? in
                Self.writeRecord(record, in: location.folder(generation))
            }
            return (true, failure)
        }
        if attempt.wrote {
            noteWrite(of: feedID, title: record.feed.title, failure: attempt.failure)
        }
    }

    /// Writes `record` into `folder`, which is made inside its data directory
    /// when missing, replacing the file atomically. Returns why it failed,
    /// having logged it, or nil once it is written.
    nonisolated private static func writeRecord(_ record: FeedRecord, in folder: URL) -> WriteFailure? {
        let file = FeedPaths.recordFile(of: record.feed.id, in: folder)
        do {
            let data = try FeedRecordCoding.encoder().encode(record)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            } catch CocoaError.fileWriteFileExists {
                // Already there.
            }
            try data.write(to: file, options: .atomic)
            return nil
        } catch {
            DiagnosticLog.event(
                .feeds,
                "FEED_RECORD_SAVE_FAILED: \(record.feed.title): could not write \(file.lastPathComponent): "
                    + error.localizedDescription
            )
            return WriteFailure(error: error, path: file.path)
        }
    }

    /// Writes every record whose latest change is not on disk yet, as when
    /// the data directory is available again.
    func saveUnsavedRecords() {
        for feedID in unsavedFeedIDs {
            write(feedID)
        }
    }

    /// Waits until every write and removal asked for so far has ended, and
    /// the store has heard how each write went.
    func flush() async {
        let queue = writeQueue
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // A write reports on the main queue before it ends, so the main
            // queue's next turn after the write queue drains follows every
            // report.
            queue.async {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    // MARK: Quitting

    /// A feed's changes on the write queue: how many, and the feed's latest
    /// title, for a report of the changes a quit could not wait for.
    private struct ChangeUnderWay {
        var count: Int
        var title: String
    }

    /// Notes that a write or removal of the feed `feedID`'s record, titled
    /// `title` now, is on the write queue.
    private func noteChangeQueued(of feedID: UUID, title: String) {
        let count = changesUnderWay[feedID]?.count ?? 0
        changesUnderWay[feedID] = ChangeUnderWay(count: count + 1, title: title)
    }

    /// Notes that a write or removal of the feed `feedID`'s record has
    /// reported back.
    private func noteChangeEnded(of feedID: UUID) {
        guard var change = changesUnderWay[feedID] else { return }
        change.count -= 1
        changesUnderWay[feedID] = change.count > 0 ? change : nil
    }

    /// Whether a write or removal of a record is on the write queue.
    var hasChangesUnderWay: Bool {
        !changesUnderWay.isEmpty
    }

    /// The longest a quit waits for the record changes on the write queue:
    /// a write takes moments, unless an operation holding the storage work
    /// holds it, such as a folder edit or Rebuild Directory, which a quit
    /// waits for this long to end. Past this TextMouth quits anyway, once it
    /// has said what is still unsaved (`reportChangesStillUnderWay()`).
    static let longestQuitWait: Duration = .seconds(10)

    /// The record changes on the write queue as work a quit waits for
    /// (`QuitHold`, review3 item 5): while any is there, until none is, for
    /// at most `longestWait`. A quit used to drop them without a word, since
    /// a change still queued had not failed: a feed change made just before
    /// quitting, or one waiting behind a folder edit's or Rebuild
    /// Directory's hold. When the quit stops waiting, each change still
    /// there is reported unsaved, so the quit asked again asks about it
    /// first; one that lands later settles its report, as any write does.
    func quitWork(longestWait: Duration = FeedStore.longestQuitWait) -> QuitHold.Work {
        QuitHold.Work(
            isRunning: { self.hasChangesUnderWay },
            end: {
                // Changes made during the wait are waited for too.
                while self.hasChangesUnderWay {
                    await self.flush()
                }
            },
            longestWait: longestWait,
            kind: "feed records",
            finishing: { FeedRecordQuitWording.finishing },
            gaveUp: { self.reportChangesStillUnderWay() }
        )
    }

    /// Reports each feed whose change is still on the write queue as
    /// unsaved, when a quit has stopped waiting for it: with the operation
    /// holding the storage work as the reason, in the words of a retry kept
    /// for it (`RetryWaitsForStorageWork`), or else that TextMouth is still
    /// saving it. No retry is offered: the change is queued already, and
    /// lands by itself unless TextMouth quits first; its write then settles
    /// the report, and a removal withdraws it.
    private func reportChangesStillUnderWay() {
        let folder = location.currentFolder()
        let reason: any Error = location.boundary.heldFor.map { RetryWaitsForStorageWork(operation: $0, action: .save) }
            ?? FeedRecordStillBeingSaved()
        for (feedID, change) in changesUnderWay {
            failureCenter.recordFailure(
                .feedRecord(feedID: feedID, title: change.title),
                path: FeedPaths.recordFile(of: feedID, in: folder).path,
                error: reason
            )
        }
    }
}

/// Why a feed's change is not saved when a quit has stopped waiting for its
/// write with no operation holding the storage work: the write is still on
/// the write queue, behind a slow disk (`FeedStore.quitWork()`).
struct FeedRecordStillBeingSaved: LocalizedError, Equatable {
    var errorDescription: String? {
        FeedRecordQuitWording.stillSaving
    }
}

/// The words of a quit that waits for feed records to be written
/// (`FeedStore.quitWork()`).
enum FeedRecordQuitWording {
    /// What the quit is finishing, after "TextMouth is finishing up before
    /// it quits:" (`QuitHoldWording`).
    static var finishing: String {
        // Translators: What the app is finishing before it quits, after "TextMouth is finishing up before it quits:". Lower case, without a full stop.
        InterfaceText.line("feedRecordQuit.finishing", "saving the changes to your feed subscriptions")
    }

    /// Why a feed's change is still unsaved when the quit stopped waiting:
    /// the reason that ends "Changes to the feed “Planet Money” could not be
    /// saved:" in the quit's prompt and the banner.
    static var stillSaving: String {
        // Translators: The reason that ends "Changes to the feed “Planet Money” could not be saved:" in the quit prompt and banner. Them are the feed's changes.
        InterfaceText.line("feedRecordQuit.stillSaving", "TextMouth is still saving them.")
    }
}

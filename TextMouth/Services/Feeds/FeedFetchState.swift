import Foundation

// MARK: - How This Mac Last Fetched a Feed (FR03)

/// How this Mac last fetched one feed (FR03): the validators and digest that
/// let the next refresh skip an unchanged feed, when it last checked, and
/// how the last check ended.
///
/// Kept in this Mac's own Caches folder (`MachineLocalPaths.feedCaches`),
/// never in the feed's record: a refresh changes these every time, and
/// writing them into the synced record would upload every feed after every
/// refresh. Everything here is made again by the next refresh: when macOS
/// empties Caches, that refresh fetches and reads each feed whole once.
struct FeedFetchState: Codable, Equatable, Sendable {
    /// The ETag the server sent with the feed body last read, sent back as
    /// If-None-Match.
    var etag: String?
    /// The Last-Modified date the server sent with the feed body last read,
    /// sent back as If-Modified-Since, exactly as the server wrote it.
    var lastModified: String?
    /// The SHA-256 digest of the feed body last read, in hexadecimal: a body
    /// with the same digest is neither read again nor saved, for the servers
    /// that answer every request in full.
    var bodyDigest: String?
    /// How many of the feed's newest entries the record kept when the body
    /// last read was merged (`Feed.keepEntries(under:)`). Under another
    /// number, the next refresh reads the feed whole again, sending no
    /// validators, so a changed setting applies at once even to a feed that
    /// has not changed.
    var keptEntriesOfLastBody: Int?
    /// When this Mac last checked the feed, however the check ended.
    var lastCheck: Date?
    /// When a check last succeeded.
    var lastSuccess: Date?
    /// How the last check failed, or nil when it succeeded.
    var lastError: FeedRefreshFailure?
    /// Whether the server said the feed is gone for good (410 Gone): a
    /// scheduled refresh skips it, and only a refresh the listener asks for
    /// tries it again.
    var isGone = false

    /// The state of a feed never checked on this Mac.
    init() {}

    /// Reads a state, every field optional, so a file from another version
    /// of TextMouth still gives what it can.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        etag = try? container.decodeIfPresent(String.self, forKey: .etag)
        lastModified = try? container.decodeIfPresent(String.self, forKey: .lastModified)
        bodyDigest = try? container.decodeIfPresent(String.self, forKey: .bodyDigest)
        keptEntriesOfLastBody = try? container.decodeIfPresent(Int.self, forKey: .keptEntriesOfLastBody)
        lastCheck = try? container.decodeIfPresent(Date.self, forKey: .lastCheck)
        lastSuccess = try? container.decodeIfPresent(Date.self, forKey: .lastSuccess)
        lastError = try? container.decodeIfPresent(FeedRefreshFailure.self, forKey: .lastError)
        isGone = (try? container.decodeIfPresent(Bool.self, forKey: .isGone)) ?? false
    }
}

/// How a check of a feed failed: the sentence the library shows and
/// VoiceOver speaks, and when.
struct FeedRefreshFailure: Codable, Equatable, Sendable {
    /// Why the check failed, as a sentence that names the feed's host and
    /// never its whole address.
    var message: String
    /// When it failed.
    var date: Date
}

// MARK: - The Store

/// Every feed's fetch details on this Mac, on the main actor (FR03): one
/// file per feed in this Mac's Feeds folder in Caches,
/// `<feed ID>.json`, written whenever a feed's details change.
///
/// The folder is this Mac's own, so a write never waits on the network or
/// on a data-directory move; writes still run on a serial queue of their
/// own, off the main thread. A file that can't be read is treated as
/// missing: its feed is fetched whole once.
@MainActor
final class FeedFetchStates: ObservableObject {
    /// Each feed's fetch details, by feed ID. A feed with none has never
    /// been checked on this Mac.
    @Published private(set) var states: [UUID: FeedFetchState] = [:]

    /// Where the files are kept, or nil to keep them in memory only.
    let folder: URL?
    /// Writes and removes files in the order asked.
    private let writeQueue = DispatchQueue(label: "com.textmouth.feed-fetch-states", qos: .utility)

    /// Details kept in `folder`, read by `load()`; nil keeps them in memory.
    init(folder: URL?) {
        self.folder = folder
    }

    /// The fetch details of the feed `feedID`: those of a feed never checked
    /// when there are none.
    func state(of feedID: UUID) -> FeedFetchState {
        states[feedID] ?? FeedFetchState()
    }

    /// Reads every file in the folder off the main thread. Details recorded
    /// meanwhile are kept.
    func load() async {
        guard let folder else { return }
        let read = await OffMainWork.run(on: .global(qos: .utility)) {
            Self.readStates(in: folder)
        }
        states = read.merging(states) { _, kept in kept }
    }

    /// Changes the details of the feed `feedID` with `change`, writing them
    /// when they changed.
    func update(_ feedID: UUID, _ change: (inout FeedFetchState) -> Void) {
        var state = self.state(of: feedID)
        let before = states[feedID]
        change(&state)
        guard state != before else { return }
        states[feedID] = state
        write(state, of: feedID)
    }

    /// Forgets the feed `feedID`, removing its file, as when it is no longer
    /// subscribed.
    func remove(_ feedID: UUID) {
        states[feedID] = nil
        guard let folder else { return }
        writeQueue.async {
            try? FileManager.default.removeItem(at: FeedPaths.recordFile(of: feedID, in: folder))
        }
    }

    /// Waits until every write asked for so far has ended.
    func flush() async {
        let queue = writeQueue
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    /// Writes `state` as the file of the feed `feedID`, on the write queue.
    /// A failure is logged; the details hold in memory until the next one.
    private func write(_ state: FeedFetchState, of feedID: UUID) {
        guard let folder else { return }
        writeQueue.async {
            let file = FeedPaths.recordFile(of: feedID, in: folder)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FeedRecordCoding.encoder().encode(state).write(to: file, options: .atomic)
            } catch {
                DiagnosticLog.event(
                    .feeds,
                    "FEED_FETCH_STATE_SAVE_FAILED: \(file.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
    }

    /// The details in each feed's file in `folder`; a file that can't be
    /// read or decoded counts as missing.
    nonisolated private static func readStates(in folder: URL) -> [UUID: FeedFetchState] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let decoder = FeedRecordCoding.decoder()
        var states: [UUID: FeedFetchState] = [:]
        for name in names {
            guard let feedID = FeedPaths.feedID(ofRecordNamed: name),
                  let data = try? Data(contentsOf: FeedPaths.recordFile(of: feedID, in: folder)),
                  let state = try? decoder.decode(FeedFetchState.self, from: data) else { continue }
            states[feedID] = state
        }
        return states
    }
}

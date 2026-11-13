import Combine
import Foundation
import XCTest
import os
@testable import TextMouth

// MARK: - FR02 Library Cloud Test Support
//
// Helpers shared by the library list's cloud tests (LibraryCloud*Tests):
// storage that counts and can hold refreshes, a sleep stepped by hand, and
// books made for them. Nothing here waits a fixed time.

/// Book storage that passes every call to a `FakeBookCloudStorage`, counts
/// the refreshes that read it and the calls made on the main thread, notes
/// the books whose states were read, and can hold one refresh's reading
/// until the test lets it go. A refresh reads `libraryLocation()` exactly
/// once.
final class CountingBookCloudStorage: BookCloudStorage, @unchecked Sendable {
    /// The scripted storage behind this one.
    let fake: FakeBookCloudStorage

    /// Guards the stored properties below: refreshes read from any thread.
    private let lock = NSLock()
    /// How many times `libraryLocation()` was read.
    private var locationReads = 0
    /// The books whose states were read, in the order read.
    private var stateReads: [UUID] = []
    /// How many calls of any kind were made on the main thread, where
    /// none belongs: each can wait on the network in a real cloud folder.
    private var callsOnMainThread = 0
    /// While set, the next read of the location waits on it.
    private var gate: DispatchSemaphore?
    /// Called on the reading thread as each refresh starts to read.
    private var readObserver: (@Sendable () -> Void)?
    /// While set, each removal waits on it.
    private var removalGate: DispatchSemaphore?
    /// Called on the removing thread as a held removal starts.
    private var removalObserver: (@Sendable () -> Void)?

    /// Storage in front of `fake`.
    init(_ fake: FakeBookCloudStorage = FakeBookCloudStorage()) {
        self.fake = fake
    }

    /// How many refreshes have read this storage.
    var refreshCount: Int {
        lock.withLock { locationReads }
    }

    /// How many calls were made on the main thread; it should stay 0.
    var mainThreadCalls: Int {
        lock.withLock { callsOnMainThread }
    }

    /// The books whose states every refresh so far read, in the order read.
    var statesRead: [UUID] {
        lock.withLock { stateReads }
    }

    /// Counts a call made on the main thread.
    private func noteThread() {
        if Thread.isMainThread {
            lock.withLock { callsOnMainThread += 1 }
        }
    }

    /// Calls `observer` on the reading thread whenever a refresh starts to
    /// read; nil stops calling.
    func onRead(_ observer: (@Sendable () -> Void)?) {
        lock.withLock { readObserver = observer }
    }

    /// Makes the next refresh wait, after it starts to read, until
    /// `releaseReads()`.
    func holdReads() {
        lock.withLock { gate = DispatchSemaphore(value: 0) }
    }

    /// Lets a held refresh go on, and stops holding later ones.
    func releaseReads() {
        let held = lock.withLock { () -> DispatchSemaphore? in
            defer { gate = nil }
            return gate
        }
        held?.signal()
    }

    /// Makes the next removal call `observer` on its thread as it starts,
    /// then wait until `releaseRemovals()`.
    func holdRemovals(onRemoval observer: @escaping @Sendable () -> Void) {
        lock.withLock {
            removalGate = DispatchSemaphore(value: 0)
            removalObserver = observer
        }
    }

    /// Lets a held removal go on, and stops holding later ones.
    func releaseRemovals() {
        let held = lock.withLock { () -> DispatchSemaphore? in
            defer {
                removalGate = nil
                removalObserver = nil
            }
            return removalGate
        }
        held?.signal()
    }

    /// Counts the read, tells the observer, waits while held, then answers
    /// as the fake does.
    func libraryLocation() -> StorageLocation {
        noteThread()
        let (held, observer) = lock.withLock { () -> (DispatchSemaphore?, (@Sendable () -> Void)?) in
            locationReads += 1
            return (gate, readObserver)
        }
        observer?()
        held?.wait()
        return fake.libraryLocation()
    }

    /// Notes the book, then answers with the fake's state.
    func state(of package: BookPackage) -> BookCloudState {
        noteThread()
        lock.withLock { stateReads.append(package.bookID) }
        return fake.state(of: package)
    }

    /// The fake's scripted size.
    func bytesToDownload(of package: BookPackage) -> Int64? {
        fake.bytesToDownload(of: package)
    }

    /// The fake's download.
    func download(_ package: BookPackage) -> AsyncThrowingStream<BookDownloadProgress, Error> {
        noteThread()
        return fake.download(package)
    }

    /// Tells the observer, waits while held, then removes as the fake does.
    func removeDownload(of package: BookPackage) throws {
        noteThread()
        let (held, observer) = lock.withLock { (removalGate, removalObserver) }
        observer?()
        held?.wait()
        try fake.removeDownload(of: package)
    }
}

/// The item provider the app installs, reading the file system as the app
/// does, with every lookup of where a folder lives counted (PERF16): each
/// read of `UbiquitousItemStatusProvider.locationKeys`, one for each
/// `location(of:)` of a folder that exists. With `reportingCloud`, every
/// folder looked up reads as managed by a sync service, so the provider
/// places a library in the test root in iCloud Drive, after the real
/// lookup, and a test can see what locating a library in the cloud costs.
///
/// The provider is the app's own type, not a stand-in, so it suits book
/// storage whatever else that storage asks of its provider.
final class LocationCountingReads: Sendable {
    /// The provider, reading through the counting reader.
    let provider: UbiquitousItemStatusProvider
    /// How many location lookups were read, from any thread.
    private let reads: OSAllocatedUnfairLock<Int>

    /// A provider whose folders are where they are, or all in iCloud Drive
    /// when `reportingCloud`.
    init(reportingCloud: Bool = false) {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        self.reads = reads
        provider = UbiquitousItemStatusProvider(readMetadata: { url, keys in
            var metadata = try UbiquitousItemStatusProvider.readFreshMetadata(of: url, keys: keys)
            if keys == UbiquitousItemStatusProvider.locationKeys {
                reads.withLock { $0 += 1 }
                if reportingCloud {
                    metadata.isUbiquitousItem = true
                }
            }
            return metadata
        })
    }

    /// How many location lookups were read so far.
    var count: Int {
        reads.withLock { $0 }
    }
}

/// A sleep a test steps by hand. Each call records the wait it was asked
/// for, tells the observer how many waits were asked for so far, and waits
/// until the test wakes it. Cancelling the sleeping task ends the sleep with
/// `CancellationError`, as `Task.sleep` does.
final class SteppedSleep: @unchecked Sendable {
    /// Guards the stored properties below: sleeps run on any thread.
    private let lock = NSLock()
    /// The sleeps not woken yet, by ID.
    private var sleepers: [UUID: CheckedContinuation<Void, Error>] = [:]
    /// The IDs of the sleeps not woken yet, oldest first.
    private var order: [UUID] = []
    /// Every wait asked for, in order.
    private var waits: [Duration] = []
    /// Called on the sleeping thread with the number of waits asked for so far.
    private var sleepObserver: (@Sendable (Int) -> Void)?

    /// Every wait asked for so far, in order, woken or not.
    var requestedWaits: [Duration] {
        lock.withLock { waits }
    }

    /// Calls `observer` with the number of waits asked for so far whenever a
    /// sleep starts.
    func onSleep(_ observer: (@Sendable (Int) -> Void)?) {
        lock.withLock { sleepObserver = observer }
    }

    /// Sleeps until `wakeOldest()` wakes this sleep or its task is cancelled.
    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let (count, observer) = lock.withLock { () -> (Int, (@Sendable (Int) -> Void)?) in
                    sleepers[id] = continuation
                    order.append(id)
                    waits.append(duration)
                    return (waits.count, sleepObserver)
                }
                // A task cancelled before it got here has already run its
                // cancellation handler, which found nothing to end.
                if Task.isCancelled {
                    take(id)?.resume(throwing: CancellationError())
                    return
                }
                observer?(count)
            }
        } onCancel: {
            take(id)?.resume(throwing: CancellationError())
        }
    }

    /// Wakes the oldest sleep still waiting, as if its time had passed.
    func wakeOldest() {
        let oldest = lock.withLock { order.first }
        if let oldest {
            take(oldest)?.resume()
        }
    }

    /// Removes and returns the sleep `id`, if it still waits, so it is ended
    /// exactly once.
    private func take(_ id: UUID) -> CheckedContinuation<Void, Error>? {
        lock.withLock {
            order.removeAll { $0 == id }
            return sleepers.removeValue(forKey: id)
        }
    }
}

/// A book for the cloud tests, packaged nowhere: its row and its
/// `BookPackage` are all the tests use, and nothing reads its files.
/// - Parameters:
///   - title: The book's title.
///   - author: The book's author.
///   - format: The book's format.
///   - folderPath: The library folder holding it.
func cloudTestBook(
    _ title: String = "Moby-Dick",
    author: String = "Herman Melville",
    format: BookFormat = .epub,
    folderPath: String = ""
) -> Book {
    Book(
        title: title,
        author: author,
        format: format,
        filePath: "/Cloud Library Tests/\(title).\(format == .audio ? "m4b" : "epub")",
        md5Hash: "",
        folderPath: folderPath,
        lastOpened: Date()
    )
}

extension XCTestCase {
    /// Lets every block already queued on the main queue run, such as a
    /// notification delivered with `receive(on: DispatchQueue.main)`: the
    /// main queue runs its blocks in order, so this one runs after them.
    @MainActor
    func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// The messages VoiceOver was asked to announce while `body` ran, as
    /// the announcer's recording delivery kept them; nothing is spoken. The
    /// previous poster is put back afterwards.
    @MainActor
    func announcements(during body: () async -> Void) async -> [String] {
        await announcementsWithPriority(during: body).map(\.message)
    }

    /// The announcements VoiceOver was asked to make while `body` ran, with
    /// the priority of each, as `announcements(during:)` records them.
    @MainActor
    func announcementsWithPriority(during body: () async -> Void) async -> [VoiceOverAnnouncement] {
        let previousPoster = VoiceOverAnnouncer.poster
        VoiceOverAnnouncer.poster = VoiceOverAnnouncer.makePoster(delivering: .record)
        defer { VoiceOverAnnouncer.poster = previousPoster }
        let alreadyRecorded = VoiceOverAnnouncer.recordedAnnouncements.count
        await body()
        return Array(VoiceOverAnnouncer.recordedAnnouncements.dropFirst(alreadyRecorded))
    }

    /// Waits until `commands` has read the sizes and the free space for
    /// every download it planned (`downloadEvictedKeptBooks(in:)` and the
    /// reading list's), so that whatever it announces about them has been
    /// announced and the downloads it chose have been started. Fails the
    /// test after `timeout` seconds rather than waiting forever.
    @MainActor
    func waitForPlanning(of commands: LibraryCloudCommands, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !commands.booksBeingPlanned.isEmpty {
            guard Date() < deadline else {
                XCTFail("The downloads were never planned")
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Waits until `states` records `state` for the book `bookID`, as soon
    /// as it does, failing the test after `timeout` seconds rather than
    /// waiting forever.
    ///
    /// A held download is safe to finish once its first step is recorded:
    /// the fake registers the hold while it makes the stream, before any
    /// step can be read from it.
    @MainActor
    func waitUntil(
        _ states: BookCloudStates,
        records state: BookCloudState,
        for bookID: UUID,
        timeout: TimeInterval = 10
    ) async {
        guard states.state(of: bookID) != state else { return }
        let recorded = expectation(description: "\(state) is recorded")
        recorded.assertForOverFulfill = false
        let subscription = states.$states.sink { newStates in
            if newStates[bookID] == state { recorded.fulfill() }
        }
        await fulfillment(of: [recorded], timeout: timeout)
        subscription.cancel()
    }
}

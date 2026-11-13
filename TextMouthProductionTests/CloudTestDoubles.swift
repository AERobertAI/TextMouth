import Foundation
@testable import TextMouth

// MARK: - FR02 Cloud Test Doubles
//
// Fakes of the cloud contract (CloudStorageContract.swift) for hosted tests.
// The `cloudcore` task owns this file. Copy it verbatim to
// TextMouthProductionTests/CloudTestDoubles.swift and change it only through
// `cloudcore`, so every branch holds the same file.

/// A sync service scripted by a test (FR02): each folder's location and each
/// item's status by path, whether that item carries sync flags of its own,
/// and a record of what was asked of it.
///
/// An item scripted without sync flags of its own is one the service does
/// not sync by itself, as iCloud Drive syncs each file inside a book's
/// package only as part of the package: a request to download it or remove
/// its local copy is refused as iCloud Drive refuses one, with "The file
/// “…” doesn’t exist." (NSCocoaErrorDomain 4). An item with no status at
/// all, such as a folder a test never scripts, takes every request.
final class FakeCloudItemStatusProvider: SyncFlagReporting, @unchecked Sendable {
    /// Guards every stored property: tests and background work call in from
    /// any thread.
    private let lock = NSLock()
    /// Locations by standardized folder path; `.local` when absent.
    private var locations: [String: StorageLocation] = [:]
    /// Statuses by standardized path; `.missing` when absent.
    private var statuses: [String: CloudItemStatus] = [:]
    /// The standardized paths whose status carries no sync flags of its own.
    private var withoutSyncFlags: Set<String> = []
    /// What `requestDownload(of:)` throws, when anything.
    private var downloadFailure: Error?
    /// The files asked to download, in order.
    private var requestedDownloads: [URL] = []
    /// The files whose local copies were asked to be removed, in order.
    private var requestedRemovals: [URL] = []

    /// A provider that knows nothing yet: every folder is local and every
    /// path is missing.
    init() {}

    /// Sets where the folder at `folder` lives.
    func setLocation(_ location: StorageLocation, of folder: URL) {
        lock.withLock { locations[folder.standardizedFileURL.path] = location }
    }

    /// Sets the status of the item at `file`, a file or a package folder,
    /// which carries sync flags of its own unless `carriesSyncFlags` is
    /// false: then the service syncs it only as part of a package, and
    /// refuses every request for it.
    func setStatus(_ status: CloudItemStatus, of file: URL, carriesSyncFlags: Bool = true) {
        let path = file.standardizedFileURL.path
        lock.withLock {
            statuses[path] = status
            if carriesSyncFlags {
                withoutSyncFlags.remove(path)
            } else {
                withoutSyncFlags.insert(path)
            }
        }
    }

    /// Makes `requestDownload(of:)` throw `error`; nil lets it succeed again.
    func failDownloads(with error: Error?) {
        lock.withLock { downloadFailure = error }
    }

    /// The files asked to download, in order.
    var downloadRequests: [URL] {
        lock.withLock { requestedDownloads }
    }

    /// The files whose local copies were asked to be removed, in order.
    var removalRequests: [URL] {
        lock.withLock { requestedRemovals }
    }

    /// The scripted location of `folder`.
    func location(of folder: URL) -> StorageLocation {
        lock.withLock { locations[folder.standardizedFileURL.path] ?? .local }
    }

    /// The scripted status of `file`.
    func status(of file: URL) -> CloudItemStatus {
        flaggedStatus(of: file).status
    }

    /// The scripted status of `item`, which carries sync flags of its own
    /// when it has a status scripted with them; an item with none scripted
    /// is missing and carries none.
    func flaggedStatus(of item: URL) -> FlaggedItemStatus {
        let path = item.standardizedFileURL.path
        return lock.withLock {
            guard let status = statuses[path] else {
                return FlaggedItemStatus(status: .missing, carriesSyncFlags: false)
            }
            return FlaggedItemStatus(status: status, carriesSyncFlags: !withoutSyncFlags.contains(path))
        }
    }

    /// Records the request, then refuses one for an item the service syncs
    /// only as part of a package, or throws the scripted failure, if any.
    func requestDownload(of file: URL) throws {
        try lock.withLock {
            requestedDownloads.append(file)
            try refuseUnlessSyncedOnItsOwn(file)
            if let downloadFailure { throw downloadFailure }
        }
    }

    /// Records the request, then refuses one for an item the service syncs
    /// only as part of a package.
    func removeLocalCopy(of file: URL) throws {
        try lock.withLock {
            requestedRemovals.append(file)
            try refuseUnlessSyncedOnItsOwn(file)
        }
    }

    /// Throws iCloud Drive's refusal of a request for an item inside a
    /// package it syncs as one item: an item scripted without sync flags of
    /// its own. Call it under `lock`.
    private func refuseUnlessSyncedOnItsOwn(_ item: URL) throws {
        let path = item.standardizedFileURL.path
        guard withoutSyncFlags.contains(path) else { return }
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path])
    }
}

/// Book storage scripted by a test (FR02): the library's location, each
/// book's state, the progress a download reports and how it ends, and a
/// record of what was asked of it.
final class FakeBookCloudStorage: BookCloudStorage, @unchecked Sendable {
    /// How one book's next download goes.
    private struct Script {
        /// The progress the download reports, in order.
        var steps: [BookDownloadProgress]
        /// The failure that ends it, or nil for success.
        var failure: BookCloudError?
        /// Whether it stays open after its steps until the test calls
        /// `finishHeldDownload(of:failingWith:)`.
        var holdsOpen: Bool
    }

    /// Guards every stored property: tests and background work call in from
    /// any thread.
    private let lock = NSLock()
    /// Where the library lives.
    private var location: StorageLocation
    /// Each book's state; `.downloaded` when absent.
    private var states: [UUID: BookCloudState] = [:]
    /// Each book's next download.
    private var scripts: [UUID: Script] = [:]
    /// Downloads held open, by book.
    private var heldDownloads: [UUID: AsyncThrowingStream<BookDownloadProgress, Error>.Continuation] = [:]
    /// What `removeDownload(of:)` throws for a book, when anything.
    private var removalFailures: [UUID: BookCloudError] = [:]
    /// The books whose downloads started, in order.
    private var startedDownloads: [UUID] = []
    /// The books whose downloads ended because their iteration was cancelled.
    private var cancelledDownloads: [UUID] = []
    /// The books whose downloads were removed, in order.
    private var removedDownloads: [UUID] = []
    /// How many bytes each book still needs, when a test says; nil (unknown)
    /// when absent.
    private var bytesNeeded: [UUID: Int64] = [:]

    /// Storage for a library at `location`: a cloud location unless the test
    /// says otherwise.
    init(location: StorageLocation = .cloud(.iCloudDrive)) {
        self.location = location
    }

    /// Moves the library to `location`.
    func setLibraryLocation(_ location: StorageLocation) {
        lock.withLock { self.location = location }
    }

    /// Says the book `bookID` needs `bytes` to download; nil makes its size
    /// unknown again.
    func setBytesToDownload(_ bytes: Int64?, of bookID: UUID) {
        lock.withLock { bytesNeeded[bookID] = bytes }
    }

    /// The bytes a test scripted for the book, or nil (unknown).
    func bytesToDownload(of package: BookPackage) -> Int64? {
        lock.withLock { bytesNeeded[package.bookID] }
    }

    /// Sets the state of the book `bookID`.
    func setState(_ state: BookCloudState, of bookID: UUID) {
        lock.withLock { states[bookID] = state }
    }

    /// Scripts the next download of the book `bookID`: it reports `steps`,
    /// then ends with `failure`, or succeeds when `failure` is nil, which
    /// makes the book `.downloaded`. With `holdsOpen`, it waits after its
    /// steps until `finishHeldDownload(of:failingWith:)`.
    func scriptDownload(
        of bookID: UUID,
        steps: [BookDownloadProgress],
        failingWith failure: BookCloudError? = nil,
        holdsOpen: Bool = false
    ) {
        lock.withLock { scripts[bookID] = Script(steps: steps, failure: failure, holdsOpen: holdsOpen) }
    }

    /// Ends the held download of the book `bookID` with `failure`, or with
    /// success when `failure` is nil.
    func finishHeldDownload(of bookID: UUID, failingWith failure: BookCloudError? = nil) {
        let continuation = lock.withLock { heldDownloads.removeValue(forKey: bookID) }
        if let failure {
            continuation?.finish(throwing: failure)
        } else {
            setState(.downloaded, of: bookID)
            continuation?.finish()
        }
    }

    /// Makes `removeDownload(of:)` throw `error` for the book `bookID`; nil
    /// lets it succeed again.
    func failRemoval(of bookID: UUID, with error: BookCloudError?) {
        lock.withLock { removalFailures[bookID] = error }
    }

    /// The books whose downloads started, in order.
    var downloadsStarted: [UUID] {
        lock.withLock { startedDownloads }
    }

    /// The books whose downloads ended because their iteration was cancelled.
    var downloadsCancelled: [UUID] {
        lock.withLock { cancelledDownloads }
    }

    /// The books whose downloads were removed, in order.
    var downloadsRemoved: [UUID] {
        lock.withLock { removedDownloads }
    }

    /// The scripted location.
    func libraryLocation() -> StorageLocation {
        lock.withLock { location }
    }

    /// The scripted state; `.downloaded` when none was set.
    func state(of package: BookPackage) -> BookCloudState {
        lock.withLock { states[package.bookID] ?? .downloaded }
    }

    /// Plays the book's script: its steps, then its ending, or a hold.
    ///
    /// The steps, the hold, and the record of the start happen together
    /// under the lock, so a test that sees the download started, on any
    /// thread, can at once finish a held download with every step already
    /// delivered. The ending happens outside the lock: finishing calls
    /// `onTermination`, which takes the lock itself.
    func download(_ package: BookPackage) -> AsyncThrowingStream<BookDownloadProgress, Error> {
        let bookID = package.bookID
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] termination in
                guard let self, case .cancelled = termination else { return }
                self.lock.withLock {
                    self.cancelledDownloads.append(bookID)
                    _ = self.heldDownloads.removeValue(forKey: bookID)
                }
            }
            let script = self.lock.withLock { () -> Script in
                let script = self.scripts.removeValue(forKey: bookID) ?? Script(steps: [], failure: nil, holdsOpen: false)
                for step in script.steps {
                    continuation.yield(step)
                }
                if script.holdsOpen {
                    self.heldDownloads[bookID] = continuation
                }
                self.startedDownloads.append(bookID)
                return script
            }
            guard !script.holdsOpen else { return }
            if let failure = script.failure {
                continuation.finish(throwing: failure)
            } else {
                self.setState(.downloaded, of: bookID)
                continuation.finish()
            }
        }
    }

    /// Throws the scripted failure, or records the removal and makes the book
    /// `.inCloud`.
    func removeDownload(of package: BookPackage) throws {
        try lock.withLock {
            if let failure = removalFailures[package.bookID] { throw failure }
            removedDownloads.append(package.bookID)
            states[package.bookID] = .inCloud
        }
    }
}

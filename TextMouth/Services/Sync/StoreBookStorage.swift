import Foundation
import os

// MARK: - Books Not on This Device (FR43, section 6)

/// A book another device added looks like a cloud book here: its package is a
/// placeholder (its record and a pointer naming files that are away), so it
/// shows In Cloud, Download Now and the reader's download view fetch it with
/// Cancel and Try Again, and maintenance leaves it alone. Every other book is
/// answered by the live storage, unchanged.
///
/// Downloading goes through `SyncCenter`, which fetches from the sync folder
/// and checks each blob. The state of a fetch in progress or failed is kept
/// here, since a placeholder's own files can't say it.
final class StoreBookStorage: BookCloudStorage {
    /// What this storage knows of a book it is fetching or has failed to fetch.
    private enum Phase: Sendable {
        case fetching(BookDownloadProgress)
        case failed(String)
    }

    /// The live storage, which answers for every book that is on this device.
    private let live: any BookCloudStorage
    /// Starts a fetch of a placeholder; the center's by default.
    private let fetcher: @Sendable (BookPackage) -> AsyncThrowingStream<BookDownloadProgress, Error>
    /// Removes a whole book's files once the store is proven to hold them (FR46); the center's by default.
    private let remover: @Sendable (BookPackage, _ mayDownload: Bool) async throws -> Void
    /// Whether sync is on: no pointer is read while it is not (R1, R2).
    private let isSyncOn: @Sendable () -> Bool
    /// The fetches in progress or failed, by book ID.
    private let phases = OSAllocatedUnfairLock(initialState: [UUID: Phase]())

    /// Wraps the live storage; fetches go through `SyncCenter`, or through `fetcher` in a test.
    init(
        wrapping live: any BookCloudStorage,
        isSyncOn: @escaping @Sendable () -> Bool = { SyncActivity.isOn },
        fetcher: @escaping @Sendable (BookPackage) -> AsyncThrowingStream<BookDownloadProgress, Error> = { SyncCenter.fetch($0) },
        remover: @escaping @Sendable (BookPackage, Bool) async throws -> Void = { try await SyncCenter.removeDownload($0, mayDownload: $1) }
    ) {
        self.live = live
        self.isSyncOn = isSyncOn
        self.fetcher = fetcher
        self.remover = remover
    }

    // MARK: The library's questions

    func libraryLocation() -> StorageLocation { live.libraryLocation() }

    func state(of package: BookPackage) -> BookCloudState {
        placeholderState(of: package) ?? live.state(of: package)
    }

    func state(of package: BookPackage, in location: StorageLocation) -> BookCloudState {
        placeholderState(of: package) ?? live.state(of: package, in: location)
    }

    /// The state of a book with files away, or nil for a book that is whole here.
    private func placeholderState(of package: BookPackage) -> BookCloudState? {
        guard isSyncOn() else { return nil }
        switch phases.withLock({ $0[package.bookID] }) {
        case .fetching(let progress): return .downloading(progress)
        case .failed(let message): return .downloadFailed(message)
        case nil: break
        }
        return StoreFetch.isMissingFiles(package.url) ? .inCloud : nil
    }

    func bytesToDownload(of package: BookPackage) -> Int64? {
        guard isSyncOn() else { return live.bytesToDownload(of: package) }
        return StoreFetch.isMissingFiles(package.url) ? StoreFetch.bytesToFetch(package.url) : live.bytesToDownload(of: package)
    }

    func removeDownload(of package: BookPackage) throws {
        try live.removeDownload(of: package)
    }

    /// Frees a synced book's files while it stays in iCloud Drive (FR46): only once the sync folder is proven to
    /// hold every one of them (`StoreRemoval`). A book being fetched now is refused, as one open is. With sync off the
    /// live storage answers, as it does for every library not synced.
    func removeDownloadAsync(of package: BookPackage, mayDownload: Bool) async throws {
        guard isSyncOn() else {
            // A library in a cloud folder is the live storage's. A library that is not, with sync off, has no copy in
            // any folder to prove: it is refused, never reported removed when nothing was.
            if live.libraryLocation().isCloud { try live.removeDownload(of: package); return }
            throw BookCloudError.syncRemoval(.notBackedUp)
        }
        if case .fetching? = phases.withLock({ $0[package.bookID] }) { throw BookCloudError.bookInUse }
        do {
            try await remover(package, mayDownload)
        } catch let refusal as SyncRemovalRefusal {
            throw BookCloudError.syncRemoval(refusal)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BookCloudError {
            throw error
        } catch {
            // Never the system's words, which can name a file of the book.
            throw BookCloudError.syncRemoval(.couldNotRemove(""))
        }
    }

    // MARK: Downloading

    func download(_ package: BookPackage) -> AsyncThrowingStream<BookDownloadProgress, Error> {
        guard isSyncOn(), StoreFetch.isMissingFiles(package.url) else { return live.download(package) }
        let fetches = fetcher(package)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await progress in fetches {
                        phases.withLock { $0[package.bookID] = .fetching(progress) }
                        continuation.yield(progress)
                    }
                    phases.withLock { $0[package.bookID] = nil }
                    continuation.finish()
                } catch is CancellationError {
                    phases.withLock { $0[package.bookID] = nil }
                    continuation.finish(throwing: CancellationError())
                } catch {
                    let mapped = Self.cloudError(for: error)
                    phases.withLock { $0[package.bookID] = .failed(String(describing: mapped)) }
                    continuation.finish(throwing: mapped)
                }
            }
            // Ending the iteration stops the fetch, as the contract says.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Why a fetch stalled, naming iCloud Drive; on a cellular or hotspot connection (or in Low Data Mode) with
    /// section 7's hint to connect to Wi-Fi.
    static func stalledSentence(onCostlyPath: Bool) -> String {
        onCostlyPath ? SyncWording.fetchStalled + " " + SyncWording.fetchCellularHint : SyncWording.fetchStalled
    }

    /// Whether this is the iPhone's app, for the words that name the device.
    private static var isPhone: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    /// The contract's error for a fetch's: offline and stalled keep their own, anything else is the provider's.
    static func cloudError(for error: Error) -> Error {
        switch error as? SyncProblem {
        case .offline: return BookCloudError.offline
        case .notDownloaded: return BookCloudError.provider(stalledSentence(onCostlyPath: SyncActivity.pathIsCostly))
        case .some(.damaged), .some(.notASyncFolder): return BookCloudError.provider(SyncWording.notASyncFolder)
        case .some(.folderMissing): return BookCloudError.provider(SyncWording.statusFolderMissing(device: SyncWording.thisDevice(isPhone: Self.isPhone)))
        default: return error
        }
    }
}

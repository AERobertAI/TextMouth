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
    /// Whether sync is on: no pointer is read while it is not (R1, R2).
    private let isSyncOn: @Sendable () -> Bool
    /// The fetches in progress or failed, by book ID.
    private let phases = OSAllocatedUnfairLock(initialState: [UUID: Phase]())

    /// Wraps the live storage; fetches go through `SyncCenter`, or through `fetcher` in a test.
    init(
        wrapping live: any BookCloudStorage,
        isSyncOn: @escaping @Sendable () -> Bool = { SyncActivity.isOn },
        fetcher: @escaping @Sendable (BookPackage) -> AsyncThrowingStream<BookDownloadProgress, Error> = { SyncCenter.fetch($0) }
    ) {
        self.live = live
        self.isSyncOn = isSyncOn
        self.fetcher = fetcher
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
        case .notDownloaded: return BookCloudError.stalled(seconds: 60)
        case .some(.damaged), .some(.notASyncFolder): return BookCloudError.provider(SyncWording.notASyncFolder)
        case .some(.folderMissing): return BookCloudError.provider(SyncWording.statusFolderMissing(device: SyncWording.thisDevice(isPhone: Self.isPhone)))
        default: return error
        }
    }
}

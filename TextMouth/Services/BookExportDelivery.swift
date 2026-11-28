import Foundation
import os

/// How an export makes each file and puts it in the folder chosen (FR31): the
/// one place the Mac's way and the iPhone's differ.
///
/// Every file an export writes is made whole in a scratch folder first, and
/// only then delivered to its name in the folder chosen, so that Stop or a
/// failure partway leaves nothing of it there, and nothing already there is
/// ever replaced or removed. What differs is where the scratch folder is, and
/// how a finished file crosses into the folder chosen:
///
/// - **`moving`**, the Mac's: the scratch folder is the system's own, kept on
///   the target's volume where the system makes one, so delivery is a rename
///   that refuses a taken name (`BookExportService.moveExclusively`).
/// - **`coordinatedCopy`**, the iPhone's: the scratch folder is in the app's
///   temporary folder, and delivery copies the whole file into place under a
///   file coordinator, created exclusively. The folder chosen is outside the
///   app's container, often a file provider's (iCloud Drive's, or a third
///   party's), where Apple's guide to chosen folders says to coordinate every
///   access, and a rename from the container into a provider's folder is not
///   relied on. The folders of the target (a book's, a track folder) are made
///   under the coordinator too, and Stop cancels a coordination that is
///   blocked on a provider. The scratch copy is removed by the export, as the
///   Mac's is.
///
/// A value, so a test passes its own, and the Mac's host tests the iPhone's
/// copy too.
struct BookExportDelivery: Sendable {
    /// Makes a new, empty scratch folder for the file that will become
    /// `target`, in which the export makes it.
    let makeScratchFolder: @Sendable (_ target: URL) throws -> URL
    /// Makes the folder of `target`, and any above it that are missing, and
    /// puts the whole file, or folder such as an RTFD package, at `scratch`
    /// at `target`, which must not exist: if anything is there, even
    /// something that appeared an instant ago, it throws
    /// `CocoaError.fileWriteFileExists` and leaves both as they are. It
    /// throws `CancellationError` once `cancellation` says Stop, even while
    /// it waits on a file provider. The export removes the scratch folder
    /// afterwards, whatever this did.
    let deliver: @Sendable (_ scratch: URL, _ target: URL, _ cancellation: BookExportCancellation) throws -> Void
    /// Removes the scratch folders an earlier run of the app left, which a
    /// launch ended while a file was being made cannot (the iPhone's
    /// temporary folder is the app's own, and iOS empties it when it likes);
    /// asked as an export starts, off the main thread. Nothing for the Mac,
    /// whose scratch folders are the system's to clear.
    let removeStaleScratchFolders: @Sendable () -> Void

    /// A delivery that makes scratch folders by `makeScratchFolder`, delivers
    /// by `deliver`, and sweeps by `removeStaleScratchFolders`, which a
    /// delivery that leaves nothing behind leaves out.
    init(
        makeScratchFolder: @escaping @Sendable (_ target: URL) throws -> URL,
        deliver: @escaping @Sendable (_ scratch: URL, _ target: URL, _ cancellation: BookExportCancellation) throws -> Void,
        removeStaleScratchFolders: @escaping @Sendable () -> Void = {}
    ) {
        self.makeScratchFolder = makeScratchFolder
        self.deliver = deliver
        self.removeStaleScratchFolders = removeStaleScratchFolders
    }

    /// The Mac's way: a scratch folder on the target's volume, and a move
    /// (`BookExportService.moveExclusively`) into a folder made first.
    static let moving = BookExportDelivery(
        makeScratchFolder: { try BookExportService.makeScratchFolder(near: $0) },
        deliver: { scratch, target, _ in
            try BookExportService.makeFolder(of: target)
            try BookExportService.moveExclusively(scratch, to: target)
        }
    )

    /// The iPhone's way: a scratch folder in the app's temporary folder, and
    /// a copy under a file coordinator (`copyCoordinated(_:to:cancellation:)`).
    static let coordinatedCopy = BookExportDelivery(
        makeScratchFolder: { _ in try BookExportService.makeTemporaryScratchFolder() },
        deliver: { try copyCoordinated($0, to: $1, cancellation: $2) },
        removeStaleScratchFolders: { removeStaleScratchFolders() }
    )

    /// The way the running app delivers: the move on the Mac, the coordinated
    /// copy on the iPhone.
    static var standard: BookExportDelivery {
        #if os(macOS)
        .moving
        #else
        .coordinatedCopy
        #endif
    }

    // MARK: - The Coordinated Copy

    /// Makes the folder of `target` and copies `scratch`, a file or a folder
    /// with all it holds, to `target`, each under a file coordinator that
    /// coordinates the writing of what it makes, so that the file provider
    /// which owns the folder chosen, and any other app reading it, know of
    /// the new items. The copy creates `target` exclusively
    /// (`BookExportService.copyExclusively`), so nothing is ever replaced, and
    /// the item it made is removed only if the copy then fails. While a
    /// coordination waits on a provider, Stop cancels it
    /// (`NSFileCoordinator.cancel()`, through the export's cancellation).
    /// - Parameter betweenCoordinations: Run once the folder is made and before the file is copied, which only a test
    ///   gives, to press Stop at the one moment no earlier check covers.
    /// - Throws: `CancellationError` when stopped; `CocoaError.fileWriteFileExists`
    ///   for a name that is taken; the coordinator's error when it cannot
    ///   coordinate; otherwise the creation's or the copy's.
    static func copyCoordinated(
        _ scratch: URL,
        to target: URL,
        cancellation: BookExportCancellation,
        betweenCoordinations: () -> Void = {}
    ) throws {
        try cancellation.checkCancelled()
        let coordinator = NSFileCoordinator(filePresenter: nil)
        // Stop calls `cancel()` from another thread, which Apple documents for a coordinator; the lock only carries the
        // coordinator, which is no `Sendable` type, to the closure that Stop runs.
        let stopper = OSAllocatedUnfairLock(uncheckedState: coordinator)
        try cancellation.childProcesses.whileRunning({ stopper.withLockUnchecked { $0.cancel() } }) {
            try coordinateWriting(coordinator, at: target.deletingLastPathComponent(), cancellation: cancellation) { folder in
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            // A Stop that came while the folder was coordinated lands no file: the second coordination, which could
            // wait on a provider and then copy, is not begun.
            betweenCoordinations()
            try cancellation.checkCancelled()
            try coordinateWriting(coordinator, at: target, cancellation: cancellation) { coordinatedTarget in
                try BookExportService.copyExclusively(scratch, to: coordinatedTarget)
            }
        }
    }

    /// Runs `body`, with the URL to write, under `coordinator`'s coordination
    /// of the writing of `url`. A coordination the export's Stop cancelled
    /// throws `CancellationError`.
    private static func coordinateWriting(
        _ coordinator: NSFileCoordinator,
        at url: URL,
        cancellation: BookExportCancellation,
        _ body: (URL) throws -> Void
    ) throws {
        var coordinationError: NSError?
        var bodyError: Error?
        // The accessor runs on this thread, before `coordinate` returns, and
        // is not run at all when the coordinator fails.
        coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError) { coordinated in
            do {
                try body(coordinated)
            } catch {
                bodyError = error
            }
        }
        if let bodyError { throw bodyError }
        if let coordinationError {
            // A coordination Stop cancelled says so with an error of its own; it is a Stop, not a failure.
            try cancellation.checkCancelled()
            throw coordinationError
        }
    }

    // MARK: - Stale Scratch Folders

    /// The start of the name of every scratch folder the iPhone's delivery makes.
    static let scratchFolderPrefix = "TextMouth Export " // l10n: no (a folder of the app's temporary files, never shown)

    /// Removes the scratch folders in `directory`, the app's temporary folder
    /// unless a test gives its own, that were last changed more than `age`
    /// before `now`: what an export the system ended left, which nothing else
    /// removes. A day, so a long export under way, which keeps its folder
    /// changing, is never in its way. Anything else in the folder is left.
    static func removeStaleScratchFolders(
        in directory: URL = FileManager.default.temporaryDirectory,
        olderThan age: TimeInterval = 24 * 60 * 60,
        now: Date = Date()
    ) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let names = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ) else { return }
        for folder in names where folder.lastPathComponent.hasPrefix(scratchFolderPrefix) {
            guard let values = try? folder.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true,
                  let changed = values.contentModificationDate,
                  now.timeIntervalSince(changed) > age else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

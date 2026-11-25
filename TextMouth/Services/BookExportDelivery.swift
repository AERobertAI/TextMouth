import Foundation

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
///   relied on. The scratch copy is removed by the export, as the Mac's is.
///
/// A value, so a test passes its own, and the Mac's host tests the iPhone's
/// copy too.
struct BookExportDelivery: Sendable {
    /// Makes a new, empty scratch folder for the file that will become
    /// `target`, in which the export makes it.
    let makeScratchFolder: @Sendable (_ target: URL) throws -> URL
    /// Puts the whole file, or folder such as an RTFD package, at `scratch`
    /// at `target`, which must not exist: if anything is there, even
    /// something that appeared an instant ago, it throws
    /// `CocoaError.fileWriteFileExists` and leaves both as they are. The
    /// export removes the scratch folder afterwards, whatever this did.
    let deliver: @Sendable (_ scratch: URL, _ target: URL) throws -> Void

    /// The Mac's way: a scratch folder on the target's volume, and a move
    /// (`BookExportService.moveExclusively`).
    static let moving = BookExportDelivery(
        makeScratchFolder: { try BookExportService.makeScratchFolder(near: $0) },
        deliver: { try BookExportService.moveExclusively($0, to: $1) }
    )

    /// The iPhone's way: a scratch folder in the app's temporary folder, and
    /// a copy under a file coordinator (`copyCoordinated(_:to:)`).
    static let coordinatedCopy = BookExportDelivery(
        makeScratchFolder: { _ in try BookExportService.makeTemporaryScratchFolder() },
        deliver: { try copyCoordinated($0, to: $1) }
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

    /// Copies `scratch`, a file or a folder with all it holds, to `target`
    /// under a file coordinator that coordinates the writing of `target`, so
    /// that the file provider which owns the folder chosen, and any other app
    /// reading it, know of the new item. The copy creates `target` exclusively
    /// (`BookExportService.copyExclusively`), so nothing is ever replaced, and
    /// the item it made is removed only if the copy then fails.
    /// - Throws: `CocoaError.fileWriteFileExists` for a name that is taken;
    ///   the coordinator's error when it cannot coordinate; otherwise the
    ///   copy's.
    static func copyCoordinated(_ scratch: URL, to target: URL) throws {
        var coordinationError: NSError?
        var copyError: Error?
        // The accessor runs on this thread, before `coordinate` returns, and
        // is not run at all when the coordinator fails.
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: target,
            options: [],
            error: &coordinationError
        ) { coordinatedTarget in
            do {
                try BookExportService.copyExclusively(scratch, to: coordinatedTarget)
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }
}

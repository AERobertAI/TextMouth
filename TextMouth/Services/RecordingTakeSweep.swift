import Foundation

/// Applies the original-take policy (`RecordingOriginalPolicy`) to the
/// recordings in the library: each original take whose time is up is
/// deleted from its book's package, and the book's origin record says it is
/// gone. The library runs it at launch and after each recording is saved,
/// off the main thread, as storage work (`StorageWork.recordingTakes`), so
/// it never runs across a data-directory move.
///
/// It never downloads anything. A recording's take is a file of its package,
/// so in a library kept in the cloud it syncs like the rest of the package;
/// a package whose origin record is only in the cloud is left for a later
/// sweep, on this Mac or another, where the record is downloaded. Deleting a
/// take reads none of it, so a take only in the cloud is deleted all the
/// same once its record says its time is up.
enum RecordingTakeSweep {
    /// What one sweep did.
    struct Result: Equatable, Sendable {
        /// Takes deleted.
        var removed = 0
        /// Packages left alone because their origin record is only in the
        /// cloud.
        var leftInCloud = 0
        /// Takes whose deletion, or whose record's update, failed; tried
        /// again by the next sweep.
        var failed = 0
    }

    /// Whether the take `take` is due to be deleted at `now`, under its book's
    /// own policy or else `global`.
    static func isDue(_ take: BookOrigin.OriginalTake, global: RecordingOriginalPolicy, now: Date) -> Bool {
        take.effectivePolicy(global: global).isDue(lastEdited: take.lastEditedAt, now: now)
    }

    /// Sweeps the packages at `packages`: each one with an origin record
    /// holding a take that is due at `now` under `global` loses the take,
    /// and its record says so. A package with no origin record, or with no
    /// take kept, is left as it is. Logs what it did, when it did anything.
    /// `load` reads a package's record without downloading it, throwing
    /// only for a record in the cloud; tests stand in one of their own,
    /// since only a sync service makes files that are only in the cloud.
    static func sweep(
        packages: [URL],
        global: RecordingOriginalPolicy,
        now: Date,
        load: (URL) throws -> BookOrigin? = BookOrigin.load(fromPackage:)
    ) -> Result {
        var result = Result()
        for package in packages {
            let origin: BookOrigin?
            do {
                origin = try load(package)
            } catch {
                // Only a record in the cloud throws: never downloaded here.
                result.leftInCloud += 1
                continue
            }
            guard var origin, let take = origin.originalTake, isDue(take, global: global, now: now) else { continue }
            do {
                try removeTake(take, from: package)
                origin.originalTake = nil
                try origin.save(toPackage: package)
                result.removed += 1
            } catch {
                result.failed += 1
                DiagnosticLog.event(
                    .storage,
                    "RECORDING_TAKE_REMOVAL_FAILED: \(package.lastPathComponent): \(CaptureSessionRecordingBackend.describe(error))"
                )
            }
        }
        if result.removed > 0 || result.leftInCloud > 0 {
            DiagnosticLog.event(
                .storage,
                "RECORDING_TAKES_SWEPT: removed \(result.removed) original take(s); "
                    + "\(result.leftInCloud) package(s) whose record is only in the cloud left for later"
            )
        }
        return result
    }

    /// Deletes `take`'s file from `package`, when it is there. A file name
    /// that would reach outside the package is refused, however the record
    /// was edited.
    private static func removeTake(_ take: BookOrigin.OriginalTake, from package: URL) throws {
        guard BookOrigin.isPlainFileName(take.fileName) else {
            throw CocoaError(.fileNoSuchFile)
        }
        do {
            try FileManager.default.removeItem(at: package.appendingPathComponent(take.fileName))
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already gone: the record is brought up to date below.
        }
    }
}

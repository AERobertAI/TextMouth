import Foundation

/// Applies the original policy (`AudioOriginalPolicy`) to the audiobooks in
/// the library (FR04): each original whose time is up is deleted from its
/// book's package, and the book's edit history says it is gone, so its edits
/// start from the book's audio as last rendered from then on. The library
/// runs it at launch, after each edit is rendered, and after a book's own
/// policy changes, off the main thread, as storage work
/// (`StorageWork.audioEditing`), so it never runs across a data-directory
/// move.
///
/// An original is deleted only when nothing can still need it:
///
/// - its book's policy says its time is up (`AudioOriginalPolicy.isDue`);
/// - the book's audio holds exactly the applied edits, so no undone edit and
///   no edit not yet rendered needs the original to be made
///   (`AudioEditList.canForgetOriginal`);
/// - the book is not open in a reader, and its audio is not being edited or
///   rendered (`AudioEditActivity`), checked under the history store's lock,
///   which a render takes only after its use has begun.
///
/// It never downloads anything. An original is a file of its package, so in
/// a library kept in the cloud it syncs like the rest of the package; a
/// package whose history is only in the cloud is left for a later sweep, on
/// this Mac or another, where the history is downloaded. Deleting an
/// original reads none of it, so one only in the cloud is deleted all the
/// same once its history says its time is up. A history this version cannot
/// read, damaged or from a later version, is left alone: no original is
/// deleted on a guess.
enum AudioOriginalSweep {
    /// What one sweep did.
    struct Result: Equatable, Sendable {
        /// Originals deleted.
        var removed = 0
        /// Packages left alone because their history is only in the cloud.
        var leftInCloud = 0
        /// Originals due but kept because their book is in use.
        var inUse = 0
        /// Originals whose deletion, or whose history's update, failed;
        /// tried again by the next sweep.
        var failed = 0

        /// Adds what another sweep did.
        mutating func add(_ other: Result) {
            removed += other.removed
            leftInCloud += other.leftInCloud
            inUse += other.inUse
            failed += other.failed
        }
    }

    /// One book's package, as a sweep looks at it.
    struct Package: Equatable, Sendable {
        /// The book's identity, by which `isInUse` knows it.
        let bookID: UUID
        /// The package.
        let url: URL
        /// The book's file, by its path inside the package: a recording's
        /// take is the original of this file.
        let bookFile: String
    }

    /// Sweeps the packages `packages` at `now`, under the global policy
    /// `global`, leaving alone every book `isInUse` says is in use. Logs what
    /// it did, when it did anything. The history is read through `reader`
    /// and a recording's origin record through `loadOrigin`, which leave
    /// files only in the cloud there; tests pass readers of their own, since
    /// only a sync service makes such files.
    static func sweep(
        packages: [Package],
        global: AudioOriginalPolicy,
        now: Date,
        isInUse: (UUID) -> Bool = { _ in false },
        reader: SavedFile.Reader = SavedFile.readWithoutDownloading,
        loadOrigin: (URL) throws -> BookOrigin? = BookOrigin.load(fromPackage:)
    ) -> Result {
        var result = Result()
        for package in packages {
            do {
                let swept = try AudioEditHistoryStore.update(
                    package: package.url,
                    bookFile: package.bookFile,
                    using: reader,
                    loadOrigin: loadOrigin
                ) { history in
                    sweep(&history, of: package, global: global, now: now, isInUse: isInUse)
                }
                result.add(swept)
            } catch AudioEditError.historyInCloud {
                result.leftInCloud += 1
            } catch AudioEditError.historyFromNewerVersion, AudioEditError.historyUnusable {
                // Left alone: the history says nothing this version can trust
                // about which originals the book still needs.
                continue
            } catch {
                result.failed += 1
                logFailure(error, in: package)
            }
        }
        if result.removed > 0 || result.leftInCloud > 0 {
            DiagnosticLog.event(
                .storage,
                "AUDIO_ORIGINALS_SWEPT: removed \(result.removed) original(s); "
                    + "\(result.inUse) kept while their book is in use; "
                    + "\(result.leftInCloud) package(s) whose history is only in the cloud left for later"
            )
        }
        return result
    }

    /// Deletes from `history`, the history of `package`, each original whose
    /// time is up and that nothing can still need, as the type describes, and
    /// says what it did.
    private static func sweep(
        _ history: inout AudioEditHistory,
        of package: Package,
        global: AudioOriginalPolicy,
        now: Date,
        isInUse: (UUID) -> Bool
    ) -> Result {
        let policy = history.effectivePolicy(global: global)
        var result = Result()
        for list in history.files {
            guard let original = list.original,
                  policy.isDue(lastEdited: original.lastEditedAt, now: now),
                  list.canForgetOriginal else { continue }
            guard !isInUse(package.bookID) else {
                result.inUse += 1
                continue
            }
            do {
                try removeOriginal(original, from: package.url)
                var swept = list
                swept.forgetOriginal(at: now)
                history.setList(swept)
                result.removed += 1
            } catch {
                result.failed += 1
                logFailure(error, in: package)
            }
        }
        return result
    }

    /// Deletes `original`'s file from the package at `package`, when it is
    /// there. A path that would reach outside the package is refused, however
    /// the history was edited.
    private static func removeOriginal(_ original: AudioOriginal, from package: URL) throws {
        guard let url = AudioEditPackage.url(of: original.file, in: package) else {
            throw AudioEditError.fileOutsidePackage
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already gone: the history is brought up to date all the same.
        }
    }

    /// Logs that an original in `package` could not be deleted, or its
    /// history not updated, because of `error`, named by its domain and code:
    /// its own words can name the package's folder by its full path.
    private static func logFailure(_ error: Error, in package: Package) {
        let failure = error as NSError
        DiagnosticLog.event(
            .storage,
            "AUDIO_ORIGINAL_REMOVAL_FAILED: \(package.url.lastPathComponent): error \(failure.code) in \(failure.domain)"
        )
    }
}

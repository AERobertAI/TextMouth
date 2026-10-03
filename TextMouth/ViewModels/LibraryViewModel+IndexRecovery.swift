import SwiftUI

/// The library index on disk exists but could not be read. While the model
/// publishes this, the library shown is provisional (rebuilt from the
/// packages and folders on disk) and nothing writes library.json.
struct LibraryIndexRecovery {
    /// The latest failure to read the index; Try Again replaces it.
    var failure: LibraryIndexReadFailure
    /// The result of the last recovery action that did not end recovery,
    /// shown in the recovery sheet until another action runs.
    var lastAttempt: LibraryIndexRecoveryOutcome?
}

/// What a recovery action did, with the sentence that describes it.
enum LibraryIndexRecoveryOutcome: Equatable {
    /// Try Again read the index, and the library is back to normal.
    case restored(bookCount: Int)
    /// Try Again found no index at all any more, so there was nothing left to
    /// protect and the provisional library was saved as the new index.
    case savedProvisionalLibrary(bookCount: Int, preservedCopy: URL?)
    /// Try Again still could not read the index.
    case stillUnreadable(reason: String)
    /// Rebuild Library Index saved the provisional library as the new index.
    case rebuilt(bookCount: Int, preservedCopy: URL?)
    /// Rebuild Library Index replaced nothing.
    case rebuildFailed(reason: String)
    /// No recovery was in progress.
    case notRecovering

    /// Plain sentences for VoiceOver and for the recovery sheet. Paths are
    /// spelled out so the preserved copy can be found by name.
    var message: String {
        switch self {
        case .restored(let bookCount):
            return "The library index was read successfully. Your library has "
                + "\(CountWording.books(bookCount)), and changes are being saved again."
        case .savedProvisionalLibrary(let bookCount, let preservedCopy):
            return "The unreadable library index is no longer there, so TextMouth saved "
                + "the library rebuilt from your books as the new index, with \(CountWording.books(bookCount))."
                + Self.keptCopySentence(preservedCopy)
        case .stillUnreadable(let reason):
            return "The library index still could not be read. \(reason)"
        case .rebuilt(let bookCount, let preservedCopy):
            return "The library index was rebuilt with \(CountWording.books(bookCount))."
                + Self.keptCopySentence(preservedCopy)
        case .rebuildFailed(let reason):
            return "The library index was not rebuilt. \(reason)"
        case .notRecovering:
            return "The library index is already readable."
        }
    }

    /// Names the preserved copy of the old index, when there is one.
    private static func keptCopySentence(_ preservedCopy: URL?) -> String {
        guard let preservedCopy else { return "" }
        return " The previous index is kept at \(preservedCopy.path)."
    }
}

/// Loading the library index, and recovering when it cannot be read.
extension LibraryViewModel {

    // MARK: - Loading

    /// Reads library.json and runs the startup repair; called once, at
    /// startup (Try Again uses `retryLibraryIndex()`). An unreadable index,
    /// which the service has already preserved and protected by suspending
    /// index writes, puts the model into recovery: the library shown is
    /// rebuilt from disk and the recovery options are presented.
    func loadLibraryIndex() {
        switch LibraryPersistenceService.load() {
        case .loaded(let loaded):
            library = loaded
        case .missing:
            library = Library()
        case .unreadable(let failure):
            library = Library()
            indexRecovery = LibraryIndexRecovery(failure: failure)
            showIndexRecoveryOptions = true
        }
        migrateOldBooksIfNeeded()
    }

    /// Builds the provisional library shown while the index cannot be read:
    /// every package with a readable bookInfo.json, found by the existing
    /// orphan adoption, and a row for every folder on disk. Nothing is saved.
    func buildProvisionalLibrary() {
        FileImportService.adoptOrphanedTMBPackages(library: &library)
        FileImportService.adoptLibraryFolders(library: &library)
    }

    // MARK: - Recovery Actions

    /// Try Again: reads the index again. When it loads now, reading progress
    /// and moved packages from this session are carried into it, index
    /// writes resume, and the ordinary startup work runs: the repair (which
    /// also adopts books imported meanwhile) and a save.
    @discardableResult
    func retryLibraryIndex() -> LibraryIndexRecoveryOutcome {
        guard let recovery = indexRecovery else { return .notRecovering }
        switch LibraryPersistenceService.load() {
        case .unreadable(let failure):
            let outcome = LibraryIndexRecoveryOutcome.stillUnreadable(reason: failure.reason)
            indexRecovery = LibraryIndexRecovery(failure: failure, lastAttempt: outcome)
            return outcome
        case .loaded(let loaded):
            let merged = Self.carryingRecoverySessionState(from: library, into: loaded)
            finishRecovery()
            library = merged
            resumeStartupWork()
            return .restored(bookCount: library.books.count)
        case .missing:
            // The damaged file was moved or deleted outside TextMouth, so
            // nothing is left to protect. Keep the provisional library and
            // save it, as a fresh start would.
            finishRecovery()
            resumeStartupWork()
            return .savedProvisionalLibrary(
                bookCount: library.books.count,
                preservedCopy: recovery.failure.quarantineURL
            )
        }
    }

    /// Rebuild Library Index: saves the provisional library as the new index.
    /// Folder rows, sort settings, and manual order that only the unreadable
    /// index held are lost; its preserved copy keeps them. Nothing is
    /// replaced when the current file cannot be preserved first.
    @discardableResult
    func rebuildLibraryIndex() -> LibraryIndexRecoveryOutcome {
        guard let recovery = indexRecovery else { return .notRecovering }
        do {
            let replacedCopy = try LibraryPersistenceService.replaceUnreadableIndex(with: library)
            finishRecovery()
            return .rebuilt(
                bookCount: library.books.count,
                preservedCopy: replacedCopy ?? recovery.failure.quarantineURL
            )
        } catch {
            let outcome = LibraryIndexRecoveryOutcome.rebuildFailed(reason: error.localizedDescription)
            indexRecovery?.lastAttempt = outcome
            return outcome
        }
    }

    /// Quit: exits without writing library.json. Index writes stay suspended
    /// while recovering, so the termination flush saves only package metadata.
    func quitWithoutWritingLibraryIndex() {
        NSApplication.shared.terminate(nil)
    }

    /// Throws while the index cannot be read. Data-directory maintenance
    /// (Rebuild Directory, Reset to Default, Change Location) reconciles or
    /// copies the library index, so it would act on, or write out, the
    /// provisional library; it waits until recovery ends.
    func ensureLibraryIndexIsReadable() throws {
        if indexRecovery != nil {
            throw LibraryIndexRecoveryError.indexUnreadable
        }
    }

    /// Ends recovery: index writes resume and the recovery options close.
    private func finishRecovery() {
        LibraryPersistenceService.resumeIndexWrites()
        indexRecovery = nil
        showIndexRecoveryOptions = false
    }

    /// Runs the startup work skipped while the index could not be read: the
    /// ordinary repair and a save, which also writes an index whose legacy
    /// migration was deferred. The app's model also refreshes text caches and
    /// statistics; the inert model used by tests starts no background work.
    private func resumeStartupWork() {
        migrateOldBooksIfNeeded()
        save()
        if runsBackgroundWork {
            updateContentCachesAndStatistics()
        }
    }

    // MARK: - Merging a Recovery Session

    /// Carries what happened while the index could not be read into the index
    /// that loaded on Try Again. The loaded index stays authoritative for
    /// folders, sort settings, order, and book metadata. For each book in
    /// both, it takes from the provisional library:
    /// - the package location, when the recorded file is gone but the
    ///   provisional path exists, because the package moved meanwhile; and
    /// - the reading position with its playback times, and the last-opened
    ///   date, when they are newer. They are timestamped, so newer is known
    ///   to be the latest progress, which was saved to bookInfo.json.
    nonisolated static func carryingRecoverySessionState(
        from provisional: Library,
        into loaded: Library,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Library {
        let sessionBooks = Dictionary(
            provisional.books.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var merged = loaded
        for index in merged.books.indices {
            guard let session = sessionBooks[merged.books[index].id] else { continue }
            var book = merged.books[index]
            if !fileExists(book.filePath), fileExists(session.filePath) {
                book.filePath = session.filePath
                book.folderPath = session.folderPath
                book.tmbDirectoryName = session.tmbDirectoryName
            }
            if let position = session.readingPosition,
               position.lastUpdated > (book.readingPosition?.lastUpdated ?? .distantPast) {
                book.readingPosition = position
                book.lastPlaybackStarted = session.lastPlaybackStarted
                book.lastPlaybackStopped = session.lastPlaybackStopped
            }
            if let opened = session.lastOpened, opened > (book.lastOpened ?? .distantPast) {
                book.lastOpened = opened
            }
            merged.books[index] = book
        }
        return merged
    }
}

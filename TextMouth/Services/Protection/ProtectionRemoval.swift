import Foundation
import PDFKit

/// Takes a password off a book's own file, once the book is unlocked and the
/// person asks (FR41): the file in the library is rewritten without its
/// password, in place, never into a second copy, and the book is then an
/// ordinary book. The person's original, outside the library, is never
/// touched.
enum ProtectionRemoval {

    /// Why the password could not be taken off.
    enum Failure: Error, Equatable {
        /// The book is not unlocked, so there is nothing plain to write.
        case notUnlocked
        /// The file could not be rewritten; it is as it was.
        case couldNotWrite
    }

    /// Rewrites the file at `url`, which is unlocked for now and read as
    /// `format`, without its password.
    ///
    /// The new file is written under a hidden name beside the old one, then
    /// put in place with one rename, so a crash leaves the protected file
    /// whole, with a leftover. A failed write or rename removes its own
    /// copy, which holds the book without its password, and the launch
    /// sweeps up one a crash left, once the library's index is read
    /// (`LibraryViewModel.sweepPasswordRemovalLeftovers()`,
    /// `removeLeftovers(inPackageAt:)`). The space needed is one copy, for
    /// as long as the write lasts.
    /// - Throws: `Failure`.
    static func removePassword(fromFileAt url: URL, format: BookFormat) throws {
        guard UnlockedSources.isUnlocked(url), let scheme = ProtectionDetector.scheme(ofFileAt: url, format: format) else {
            throw Failure.notUnlocked
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".unprotecting-\(UUID().uuidString)")
        do {
            switch scheme {
            case .zip, .officeOpenXML:
                guard let plain = UnlockedSources.plainArchiveData(for: url) else { throw Failure.notUnlocked }
                try plain.write(to: temporary)
            case .pdf:
                // The unlocked document is written with empty passwords: it
                // opens with no prompt, and keeps its outline, labels, and
                // information, which a copy of its pages would lose.
                guard let document = UnlockedSources.openPDF(at: url),
                      document.write(to: temporary, withOptions: [.userPasswordOption: "", .ownerPasswordOption: ""]) else {
                    throw Failure.couldNotWrite
                }
            }
            // On the disk before the rename puts it in place: the rename
            // replaces the library's only copy of the book, so a power loss
            // just after it must not leave a name over bytes never written.
            try flushToDisk(temporary)
            try SavedFile.renameReplacing(temporary, url)
        } catch let failure as Failure {
            discard(temporary)
            throw failure
        } catch {
            discard(temporary)
            throw Failure.couldNotWrite
        }
        // What was found about the old file no longer holds.
        ProtectionDetector.forget(url)
    }

    /// The prefix of the hidden copy's name.
    static let temporaryPrefix = ".unprotecting-"

    /// Asks the file system to put the file at `url` on the disk now, as
    /// the search texts are before their rename (`LibrarySearchTextStore`).
    /// - Throws: when the file cannot be opened or flushed.
    private static func flushToDisk(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    /// Deletes a copy of the book without its password, which a failed
    /// write or rename left. Its name is a path this code made itself.
    private static func discard(_ temporary: URL) {
        try? FileManager.default.removeItem(at: temporary)
    }

    /// Deletes the copies a crash left in the package at `package`, each by
    /// its exact path, and returns how many. Looks at nothing in the cloud.
    @discardableResult
    static func removeLeftovers(inPackageAt package: URL) -> Int {
        DatalessFiles.withoutDownloading {
            guard !DatalessFiles.isDataless(package),
                  let names = try? FileManager.default.contentsOfDirectory(atPath: package.path) else { return 0 }
            var removed = 0
            for name in names where name.hasPrefix(temporaryPrefix) {
                if (try? FileManager.default.removeItem(at: package.appendingPathComponent(name))) != nil { removed += 1 }
            }
            return removed
        }
    }
}

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
    /// whole, with a leftover that the library's usual sweep of hidden
    /// import leftovers can remove. The space needed is one copy, for as
    /// long as the write lasts.
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
            try SavedFile.renameReplacing(temporary, url)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.couldNotWrite
        }
        // What was found about the old file no longer holds.
        ProtectionDetector.forget(url)
    }
}

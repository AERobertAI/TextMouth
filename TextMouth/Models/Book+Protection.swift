import Foundation

// MARK: - A Book Protected by a Password (FR41)

extension Book {
    /// The password scheme protecting the book's own file, or nil. Found by
    /// looking at the file, not recorded: a record keeps no secret and no
    /// marker, so an older TextMouth reads every book as before.
    var protectionScheme: ProtectionScheme? {
        // An audiobook is never protected here: its tracks are not a file a
        // password locks, and a protected audiobook is not supported yet.
        guard !format.isAudio else { return nil }
        return ProtectionDetector.scheme(ofFileAt: bookFileURL, format: format)
    }

    /// Whether the book's file has a password. While it does, TextMouth
    /// keeps no plain copy of its text on disk: no text cache, no index of
    /// its headings, no search text, and no words around a saved place.
    var isPasswordProtected: Bool { protectionScheme != nil }

    /// Whether the book is protected and not unlocked for now. Every
    /// background pass skips such a book (the launch re-reads, cache
    /// rebuilds, metadata refreshes, Redo Text Extraction, and search
    /// indexing), without a prompt, an error line, or a retry.
    var isLocked: Bool {
        isPasswordProtected && !UnlockedSources.isUnlocked(bookFileURL)
    }
}

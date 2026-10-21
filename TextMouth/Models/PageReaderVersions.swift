import Foundation

/// Which formats write page markers into a book's content.md, and the
/// version of each one's page reader (PG09). A book records the version that
/// wrote its content.md (`Book.pageReaderVersion`); at launch, a book whose
/// format has a newer page reader than the one recorded, or none, is read
/// again from its file so that it gains its pages
/// (`LibraryViewModel.booksNeedingCacheUpdate`).
///
/// A format that gains pages later (PG12's braille) adds its line here,
/// which reads again only its own books, without another pass over the rest
/// of the library. A format whose page reader changes
/// raises its own version in the same way.
enum PageReaderVersions {
    /// The version of `format`'s page reader; nil for a format that writes
    /// no page markers. Every format listed was given pages in the same
    /// release, so each starts at "1.0.0".
    ///
    /// The formats textutil reads (`.rtf`, `.rtfd`, `.doc`, `.odt`, and
    /// `.wordml`, PG11) gained their pages in the same release. A format that
    /// gains pages later (PG12's braille) adds a case of its own with its own
    /// version, which reads again only its own books.
    static func current(for format: BookFormat) -> String? {
        switch format {
        case .epub, .html, .pdf, .docx, .daisy:
            return "1.0.0"
        case .rtf, .rtfd, .doc, .odt, .wordml:
            return "1.0.0"
        default:
            return nil
        }
    }

    /// Whether a book of `format` that recorded `stored` as its page reader
    /// (nil when it recorded none) is behind the format's current one. False
    /// for a format without pages: such a book is never read again for them.
    static func isOutdated(format: BookFormat, stored: String?) -> Bool {
        guard let current = current(for: format) else { return false }
        return SemanticVersion.isOutdated(stored: stored, current: current)
    }

    /// Whether `book`'s content.md predates its format's page reader.
    static func isOutdated(_ book: Book) -> Bool {
        isOutdated(format: book.format, stored: book.pageReaderVersion)
    }
}

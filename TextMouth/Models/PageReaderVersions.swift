import Foundation
import os

/// Which formats write page markers into a book's content.md, and the
/// version of each one's page reader (PG09). A book records the version that
/// wrote its content.md (`Book.pageReaderVersion`); at launch, while the
/// launch re-read is switched on (`launchRereadIsOn`, off for now), a book
/// whose format has a newer page reader than the one recorded, or none, is
/// read again from its file so that it gains its pages
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
    ///
    /// A stamp's failure note is not part of its version (`stamp(for:pageRunFailed:previous:)`):
    /// "1.0.0+failed" is page reader 1.0.0, which tried and is not tried
    /// again, while "1.0.0+failed-once" is behind, so that the book is read
    /// once more, unless a newer TextMouth on another Mac wrote it (FR02).
    static func isOutdated(format: BookFormat, stored: String?) -> Bool {
        guard let current = current(for: format) else { return false }
        guard let stored else { return true }
        let version = String(stored.prefix { $0 != noteSeparator })
        if stored.hasSuffix(failedOnceNote) {
            // Tried once more by this reader or a newer one, never an older.
            return !SemanticVersion.isOutdated(stored: current, current: version)
        }
        return SemanticVersion.isOutdated(stored: version, current: current)
    }

    // MARK: - A Page Run That Failed (PG16)

    /// What begins a stamp's note, after its version.
    private static let noteSeparator: Character = "+"

    /// The note of a page run that failed once: the book is read again for
    /// its pages at the next launch.
    private static let failedOnceNote = "+failed-once"

    /// The note of a page run that failed again, or of a book whose file
    /// could not be read for its pages at all: it is not read again for
    /// them until its format's page reader changes, or Redo Text Extraction
    /// reads it.
    private static let failedNote = "+failed"

    /// The page reader a generation records for a book of `format` whose
    /// stamp was `previous` (PG16): the format's current one when its pages
    /// were read, nil for a format without pages. When the run that reads
    /// them failed or was stopped (`pageRunFailed`, textutil's second run),
    /// the book was read without pages, and the stamp notes it rather than
    /// record its pages as done: "1.0.0+failed-once" the first time, which
    /// the next launch reads again, and "1.0.0+failed" when that try fails
    /// too, so a document that always fails is not read at every launch.
    static func stamp(for format: BookFormat, pageRunFailed: Bool, previous: String?) -> String? {
        guard let current = current(for: format) else { return nil }
        guard pageRunFailed else { return current }
        return previous == current + failedOnceNote ? current + failedNote : current + failedOnceNote
    }

    /// The stamp of a book of `format` whose file could not be read for its
    /// pages at all, being missing or no longer readable (PG16): the
    /// current version, noting a failure that is not tried again; nil for a
    /// format without pages.
    static func failedStamp(for format: BookFormat) -> String? {
        current(for: format).map { $0 + failedNote }
    }

    /// Whether `stamp` notes a failure (`stamp(for:pageRunFailed:previous:)`).
    static func notesFailure(_ stamp: String?) -> Bool {
        stamp?.contains(noteSeparator) ?? false
    }

    /// The line logged for `title`'s book when its run for pages failed and
    /// `stamp` notes it, saying whether the next launch reads it again.
    static func failedRunLogLine(title: String, stamp: String?) -> String {
        let next = stamp?.hasSuffix(failedOnceNote) == true
            ? "it is read again for them at the next launch"
            : "it keeps its text without them until Redo Text Extraction"
        return "PAGES_RUN_FAILED: \(title): its pages could not be read; \(next)"
    }

    /// Whether `book`'s content.md predates its format's page reader.
    static func isOutdated(_ book: Book) -> Bool {
        isOutdated(format: book.format, stored: book.pageReaderVersion)
    }

    // MARK: - The Launch Re-read's Switch

    /// Whether the startup batch reads the books already in the library
    /// again to give them their pages (PG09): **off** in this release.
    ///
    /// A review of PG09 (October 21, 2026) found the re-read not yet safe to
    /// run on a library the user has worked on:
    /// 1. It compares only the chapters' reading text, so an Edit Text change
    ///    made before B12 that only turned a paragraph into a heading,
    ///    changed a heading's level, or renamed a chapter looks unchanged,
    ///    and would be read over without a copy.
    /// 2. A book it keeps as changed by hand records no edit (`editedText`),
    ///    so the next cache-format bump replaces that text without a copy.
    /// 3. content.md is written before its record is committed, and a quit
    ///    does not wait for the batch, so an interrupted batch leaves
    ///    TextMouth's own text looking like the user's edit, which the book
    ///    then keeps from every later re-read.
    /// 7. The page reader is recorded even when textutil's second run failed
    ///    or timed out, so such a book never gains its pages and is never
    ///    tried again.
    ///
    /// Books imported or read again from their files gain their pages all
    /// the same: every generation writes them and records its format's page
    /// reader (`MarkdownCacheService.GeneratedCache`). Once those findings
    /// are fixed, setting this to true turns the re-read on. Its code stays
    /// as it is, and its tests run it switched on
    /// (`_setLaunchRereadForTesting(_:)`).
    static let launchRereadIsOn = false

    /// Whether the startup batch is to read `book` again for its pages
    /// (PG09): its content.md predates its format's page reader, and the
    /// launch re-read is switched on (`launchRereadIsOn`). Every choice the
    /// re-read makes asks this, so while it is off the batch neither chooses
    /// a book for its pages, nor refuses to recover a record for them, nor
    /// compares a book's text with its file's, nor records a page reader for
    /// text it keeps.
    static func isDueForPages(_ book: Book) -> Bool {
        isDueForPages(format: book.format, stored: book.pageReaderVersion)
    }

    /// `isDueForPages(_:)` for a book of `format` whose record holds
    /// `stored` as its page reader (nil when it holds none).
    static func isDueForPages(format: BookFormat, stored: String?) -> Bool {
        launchRereadRuns.withLock { $0 } && isOutdated(format: format, stored: stored)
    }

    /// Whether the re-read runs now: `launchRereadIsOn` in the app, and what
    /// a test set with `_setLaunchRereadForTesting(_:)`. Held under a lock,
    /// since the batch asks on its worker threads.
    private static let launchRereadRuns = OSAllocatedUnfairLock(initialState: launchRereadIsOn)

    /// Switches the launch re-read on or off for a test, and returns how it
    /// was, for the test to put back. The app never calls it.
    @discardableResult
    static func _setLaunchRereadForTesting(_ isOn: Bool) -> Bool {
        launchRereadRuns.withLock { runs in
            let previous = runs
            runs = isOn
            return previous
        }
    }
}

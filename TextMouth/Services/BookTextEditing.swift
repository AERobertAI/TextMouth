import Foundation
import os

// MARK: - What an Edit Is Checked Against (FR05)

/// What a book's files held when TextMouth last took its text as current:
/// when Edit Text began, or when it last took an edit. A later content.md
/// with other bytes, beside a source still holding these, is an edit the
/// user made.
struct BookTextBaseline: Equatable, Sendable {
    /// The book's own file, or nil when it could not be fingerprinted (it is
    /// only in the cloud, or gone), which then counts as unchanged, as a
    /// source that cannot be examined does for every text cache (TODO T07).
    var source: FileFingerprint?
    /// content.md.
    var cache: FileFingerprint
}

/// Why an edited content.md was not taken as the book's text.
enum BookTextEditRefusal: Equatable, Sendable {
    /// Its bytes are not UTF-8 text.
    case notText
    /// It no longer holds a chapter with anything in it.
    case noChapters
}

/// An edit taken as the book's text: committed to its record, with the
/// text readers show.
struct BookTextEdit: Sendable {
    /// The book as its record now records it, with the edit's analysis.
    let committed: Book
    /// The edited text, parsed and indexed as a reader shows it.
    let content: DocumentContent
}

/// What checking a book's content.md for an edit found.
enum BookTextEditCheck: Sendable {
    /// content.md holds what it held: nothing to do.
    case unchanged
    /// content.md, or the package holding it, is only in the cloud (FR02):
    /// it is left alone until it is on this Mac.
    case inCloud
    /// content.md is gone, or the book left the library: there is nothing
    /// to take.
    case missing
    /// content.md changed, and so did the book's own file since the edit
    /// began, so the edit is not taken: the next load rebuilds the text
    /// from that file, as it rebuilds any stale text cache (TODO T07).
    /// Carries the digest of the content.md found.
    case sourceChanged(digest: String)
    /// content.md changed but was refused, with why; the book keeps its
    /// earlier text and index. Carries the digest of the content.md found.
    case refused(BookTextEditRefusal, digest: String)
    /// The edit is the book's text now.
    case adopted(BookTextEdit)
    /// The edit could not be committed to the book's record, with why.
    case failed(String)
}

// MARK: - Sessions

/// The books whose text is being edited in another app, each with its
/// baseline, shared by everything that checks for an edit (FR05): the
/// watcher of each content.md, TextMouth becoming the active app, and a
/// reader about to read the book's files (`settlePendingEdit(of:)`).
///
/// Every check runs on one serial queue, as storage work
/// (`StorageBoundary.perform`), so two checks of a book never overlap, a
/// check waits while a data-directory move or a folder edit holds the
/// storage work, and each sees the baseline the one before it left.
final class BookTextEditSessions: Sendable {
    /// The sessions of the app's Edit Text commands.
    static let shared = BookTextEditSessions()

    /// One book being edited.
    struct Session: Sendable {
        /// What the book's files held when its text was last taken.
        var baseline: BookTextBaseline
        /// Hears what each check found, on the checking queue.
        let report: @Sendable (UUID, BookTextEditCheck) -> Void
    }

    /// The sessions, by book ID, guarded by the lock itself.
    private let sessions = OSAllocatedUnfairLock<[UUID: Session]>(initialState: [:])

    /// The queue every check runs on, one at a time.
    let queue = DispatchQueue(label: "com.textmouth.text-edits", qos: .userInitiated)

    /// How a check reads files without downloading (FR02).
    let access: MaintenanceFileAccess
    /// The reading texts this Mac keeps, from which a book whose edit is
    /// taken has its own removed (PERF22).
    let readingTexts: ReadingTextCache
    /// The boundary checks run inside, as storage work.
    let boundary: StorageBoundary

    /// Sessions checked with `access`, dropping reading texts from
    /// `readingTexts`, as storage work of `boundary`: the app's, unless a
    /// test passes its own.
    init(
        access: MaintenanceFileAccess = .live,
        readingTexts: ReadingTextCache = .shared,
        boundary: StorageBoundary = .shared
    ) {
        self.access = access
        self.readingTexts = readingTexts
        self.boundary = boundary
    }

    // MARK: Beginning and Ending

    /// Starts, or starts again, the session of the book `bookID`.
    func begin(_ bookID: UUID, _ session: Session) {
        sessions.withLock { $0[bookID] = session }
    }

    /// Ends the session of the book `bookID`, if there is one.
    func end(_ bookID: UUID) {
        _ = sessions.withLock { $0.removeValue(forKey: bookID) }
    }

    /// Whether the book `bookID` is being edited.
    func isEditing(_ bookID: UUID) -> Bool {
        sessions.withLock { $0[bookID] != nil }
    }

    /// The books being edited.
    var bookIDs: Set<UUID> {
        sessions.withLock { Set($0.keys) }
    }

    /// The baseline of the book `bookID`, while it is being edited.
    func baseline(of bookID: UUID) -> BookTextBaseline? {
        sessions.withLock { $0[bookID]?.baseline }
    }

    // MARK: Checking

    /// Checks `book`, as the library holds it now, for an edit soon, on
    /// the checking queue.
    func scheduleCheck(of book: Book) {
        queue.async { [self] in
            check(book)
        }
    }

    /// Checks `book` for an edit now, waiting for the check, so that a
    /// reader about to read the book's files reads the edit taken rather
    /// than finding content.md changed under a record that does not
    /// describe it, which would have it rebuilt from the source (TODO T07).
    /// Does nothing for a book not being edited. A check never waits for
    /// the main thread, so this may be called from it, as a test does.
    /// - Returns: The book as its record records it once an edit was taken
    ///   now, whose analysis the reader then reads by; nil otherwise.
    @discardableResult
    func settlePendingEdit(of book: Book) -> Book? {
        guard isEditing(book.id) else { return nil }
        let found = queue.sync {
            check(book)
        }
        guard case .adopted(let edit) = found else { return nil }
        return edit.committed
    }

    /// Checks `book` for an edit, as storage work, so it waits while a
    /// data-directory move or a folder edit holds the storage work; its
    /// paths are then taken under the data directory in use. A folder edit
    /// that moved the book meanwhile leaves its files elsewhere, which this
    /// check finds missing; the next one, with the book as the library
    /// holds it then, finds them. Reports what was found to the session,
    /// and keeps a new baseline when an edit was taken or the files were
    /// only rewritten. Runs on the queue.
    /// - Returns: What was found; nil for a book not being edited.
    @discardableResult
    private func check(_ book: Book) -> BookTextEditCheck? {
        let bookID = book.id
        guard let session = sessions.withLock({ $0[bookID] }) else { return nil }
        let found: BookTextEditCheck = boundary.perform(.contentAnalysis) { _ in
            // The baseline is read again: a check that waited for a hold
            // follows the one before it.
            let baseline = sessions.withLock { $0[bookID]?.baseline } ?? session.baseline
            let checked = Self.check(
                boundary.rebasedToCurrent(book),
                against: baseline,
                access: access,
                readingTexts: readingTexts
            )
            if let baseline = checked.baseline {
                sessions.withLock { $0[bookID]?.baseline = baseline }
            }
            return checked.found
        }
        session.report(bookID, found)
        return found
    }

    // MARK: The Check

    /// What `book`'s files hold now, as the baseline an edit is checked
    /// against: content.md's fingerprint and its source's, read with
    /// dataless files left in the cloud (FR02). A source only in the cloud,
    /// or gone, is left unfingerprinted.
    /// - Returns: The baseline, or why editing cannot begin: content.md, or
    ///   its package, is in the cloud, or content.md is missing or cannot
    ///   be read.
    static func baseline(of book: Book, access: MaintenanceFileAccess) -> Result<BookTextBaseline, BookTextEditStartFailure> {
        let cacheURL = MarkdownCacheService.cacheURL(for: book)
        let sourceURL = book.bookFileURL
        if access.isInCloud(book.tmbDirectory) || access.isInCloud(cacheURL) {
            return .failure(.inCloud)
        }
        guard access.presence(of: cacheURL) == .present else { return .failure(.missing) }
        let hasher = access.hasher
        guard let cache = FileFingerprint(of: cacheURL, hasher: hasher) else {
            return .failure(.unreadable)
        }
        let source = access.isInCloud(sourceURL) ? nil : FileFingerprint(of: sourceURL, hasher: hasher)
        return .success(BookTextBaseline(source: source, cache: cache))
    }

    /// Checks `book`'s content.md against `baseline` and takes an edit as
    /// the book's text when content.md changed while its source did not.
    ///
    /// - content.md, or its package, only in the cloud is left alone, and so
    ///   is a content.md whose size and date are unchanged, or that was
    ///   rewritten with the same bytes (which gives a new baseline).
    /// - A changed source refuses the edit (`sourceChanged`), as does a
    ///   content.md that is not UTF-8 or no longer holds a chapter with
    ///   anything in it (`refused`); the book keeps its earlier index.
    /// - Otherwise content.md is indexed afresh (headings, lengths, and
    ///   counts), its fingerprints become those of the edited bytes and
    ///   the source, so the text is not rebuilt from the source, and the
    ///   index is committed to the book's record at once, its cache format
    ///   current (`LibraryPersistenceService.saveContentAnalysis`). The
    ///   reading text this Mac kept for the book is removed.
    ///
    /// - Returns: What was found, and the baseline from now on when it
    ///   changed.
    static func check(
        _ book: Book,
        against baseline: BookTextBaseline,
        access: MaintenanceFileAccess,
        readingTexts: ReadingTextCache
    ) -> (found: BookTextEditCheck, baseline: BookTextBaseline?) {
        guard !book.format.isAudio, !book.tmbDirectoryName.isEmpty else { return (.missing, nil) }
        let cacheURL = MarkdownCacheService.cacheURL(for: book)
        let sourceURL = book.bookFileURL
        if access.isInCloud(book.tmbDirectory) || access.isInCloud(cacheURL) {
            return (.inCloud, nil)
        }
        // content.md is stamped before it is read, so a save while it is
        // read differs from this stamp next time.
        guard let cacheStamp = FileStamp(of: cacheURL) else { return (.missing, nil) }
        if baseline.cache.comparison(with: cacheStamp) == .same {
            return (.unchanged, nil)
        }
        let bytes: Data
        do {
            bytes = try access.read(cacheURL) { try Data(contentsOf: cacheURL) }
        } catch where DatalessFiles.isDownloadRefusal(error) {
            return (.inCloud, nil)
        } catch {
            return (.failed(error.localizedDescription), nil)
        }
        let digest = access.hasher.digestOfData(bytes)
        let cache = FileFingerprint(stamp: cacheStamp, digest: digest)
        guard digest != baseline.cache.digest else {
            // Rewritten with the same bytes: nothing was edited.
            return (.unchanged, BookTextBaseline(source: baseline.source, cache: cache))
        }
        let source: FileFingerprint?
        switch checkSource(baseline.source, at: sourceURL, access: access) {
        case .changed:
            logLine("TEXT_EDIT_SOURCE_CHANGED", about: book, "the book's own file changed too; its text will be read from that file again")
            return (.sourceChanged(digest: digest), nil)
        case .unchanged(let fingerprint):
            source = fingerprint
        }

        guard let text = try? MarkdownCacheService.cacheText(from: bytes, at: cacheURL) else {
            logLine("TEXT_EDIT_REFUSED", about: book, "content.md is not UTF-8 text")
            return (.refused(.notText, digest: digest), nil)
        }
        let parsed = MarkdownCacheService.parseMultiChapterMarkdown(text, bookTitle: book.title, bookAuthor: book.author)
        guard parsed.chapters.contains(where: { chapter in chapter.text.contains { !$0.isWhitespace } }) else {
            logLine("TEXT_EDIT_REFUSED", about: book, "content.md holds no chapter with anything in it")
            return (.refused(.noChapters, digest: digest), nil)
        }

        var index = parsed.contentIndex.replacingFormat(book.format)
        index.textCacheFingerprint = source.map { TextCacheFingerprint(source: $0, cache: cache) }
        let committed: Book?
        do {
            committed = try LibraryPersistenceService.saveContentAnalysis(
                for: book,
                index: index,
                cacheFormatVersion: MarkdownCacheService.currentCacheVersion
            )
        } catch {
            logLine("TEXT_EDIT_FAILED", about: book, error.localizedDescription)
            return (.failed(error.localizedDescription), nil)
        }
        guard let committed else {
            // The record could not take it now (it is only in the cloud, or
            // the book moved meanwhile); the next check tries again.
            return (.failed(BookTextEditWording.recordUnavailable), nil)
        }
        // The kept reading text was read from the content.md just replaced.
        readingTexts.remove(bookID: book.id)
        logLine(
            "TEXT_EDIT_ADOPTED",
            about: book,
            "\(index.chapters.count) chapter(s), \(index.totalWordCount) word(s), \(index.allHeadings.count) heading(s)"
        )
        let content = DocumentContent(title: parsed.title, author: parsed.author, chapters: parsed.chapters, contentIndex: index)
        return (.adopted(BookTextEdit(committed: committed, content: content)), BookTextBaseline(source: source, cache: cache))
    }

    /// What checking a book's source against its baseline found.
    private enum SourceCheck {
        /// The source holds other bytes than it did.
        case changed
        /// The source holds what it did, as this fingerprint now describes
        /// it; nil when it has none, being only in the cloud or gone.
        case unchanged(FileFingerprint?)
    }

    /// Whether the source at `url` still holds what `recorded` says it held:
    /// unchanged with its new stamp when it was only rewritten. A source
    /// only in the cloud, gone, or unreadable is no change, as for every
    /// text cache (TODO T07), and keeps `recorded`; one never fingerprinted
    /// is fingerprinted now, when it can be.
    private static func checkSource(_ recorded: FileFingerprint?, at url: URL, access: MaintenanceFileAccess) -> SourceCheck {
        let isInCloud = access.isInCloud(url)
        guard let recorded else {
            return .unchanged(isInCloud ? nil : FileFingerprint(of: url, hasher: access.hasher))
        }
        switch recorded.comparison(with: FileStamp(of: url), isDataless: isInCloud) {
        case .same, .dataless, .unexamined:
            return .unchanged(recorded)
        case .resized:
            return .changed
        case .redated(let stamp):
            guard let digest = try? access.hasher.digestOfFile(url) else { return .unchanged(recorded) }
            return digest == recorded.digest ? .unchanged(FileFingerprint(stamp: stamp, digest: digest)) : .changed
        }
    }

    /// Records `<tag>: <title>: <detail>` in the debug log, as an event of
    /// the storage category (`DiagnosticLog`).
    private static func logLine(_ tag: String, about book: Book, _ detail: String) {
        DiagnosticLog.event(.storage, "\(tag): \(book.title): \(detail)")
    }
}

/// Why Edit Text could not begin.
enum BookTextEditStartFailure: Error, Equatable, Sendable {
    /// content.md, or the package holding it, is only in the cloud (FR02).
    case inCloud
    /// The book has no content.md yet.
    case missing
    /// content.md cannot be read.
    case unreadable
}

import Foundation
import os

// MARK: - What an Edit Is Checked Against (FR05)

/// What a book's files held when TextMouth last took its text as current:
/// when Edit Text began, or when it last took an edit. A later content.md
/// with other bytes, beside a source still holding these, is an edit the
/// user made.
struct BookTextBaseline: Equatable, Sendable {
    /// The file the text is written from (`BookTextEditSessions.sourceURL(of:)`):
    /// a text book's own file, or a transcribed audiobook's transcript.json;
    /// nil when it could not be fingerprinted (it is only in the cloud, or
    /// gone), which then counts as unchanged, as a source that cannot be
    /// examined does for every text cache (TODO T07).
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
    /// The book's own file changed too since the edit began, so the book's
    /// text is read from that file again, as any stale text cache is
    /// rebuilt (TODO T07).
    case sourceChanged
    /// A transcribed audiobook's transcript changed too since the edit
    /// began, as when it is transcribed again, so its text is written from
    /// the new transcript again.
    case transcriptChanged
    /// A transcribed audiobook's edited text holds `found` chapters, where
    /// the audiobook has `expected`: its text keeps one chapter for each of
    /// the audio's.
    case chaptersChanged(found: Int, expected: Int)
    /// It could not be read, or the book's record could not take it, or a
    /// rebuild found it before any check had, with why: a sentence.
    case failed(String)

    /// Whether the book keeps the text it had while this edit stands, and
    /// nothing rebuilds its content.md over the edit (FR05): true but for a
    /// changed source or transcript, which the book's text is written from
    /// again once the edit is kept beside content.md.
    var keepsEarlierText: Bool {
        self != .sourceChanged && self != .transcriptChanged
    }
}

/// An edit taken as the book's text: committed to its record, with the
/// text readers show.
struct BookTextEdit: Sendable {
    /// What readers show of an edit.
    enum Text: Sendable {
        /// A text book's edited text, parsed and indexed.
        case document(DocumentContent)
        /// A transcribed audiobook's edited transcript text (FR05), laid
        /// over the audio it plays on.
        case transcript(TranscriptText)
    }

    /// The book as its record now records it, with the edit's analysis.
    let committed: Book
    /// The edited text, as a reader shows it.
    let text: Text
}

/// What checking a book's content.md for an edit found, or what a rebuild
/// of its text did to the text the user saved there.
enum BookTextEditCheck: Sendable {
    /// content.md holds what it held: nothing to do.
    case unchanged
    /// content.md, or the package holding it, is only in the cloud (FR02):
    /// it is left alone until it is on this Mac.
    case inCloud
    /// content.md is gone, or the book left the library: there is nothing
    /// to take.
    case missing
    /// content.md changed but was not taken, with why, the digest of what
    /// it held (nil when it could not be read), and the copy of it kept
    /// beside it (`BookTextEditSessions.keepCopy(of:bytes:)`), nil when
    /// none could be made. The book keeps its earlier text and index.
    case refused(BookTextEditRefusal, digest: String?, keptCopy: URL?)
    /// The edit is the book's text now.
    case adopted(BookTextEdit)
    /// A rebuild read the book's text from its own file again, over text
    /// the user had saved in content.md, which was kept first as this copy.
    case replaced(keptCopy: URL)
}

/// What a read of a book's files does about its text being edited, once
/// any edit saved has been checked (`BookTextEditSessions.settlePendingEdit`).
enum BookTextEditSettlement: Sendable {
    /// Read the book as usual: it is not being edited, nothing new was
    /// saved, or its own file changed, which its text is read from again
    /// once the edit is kept beside content.md.
    case readAsUsual
    /// Read the book as its record now records it, with the edit just
    /// taken, whose analysis the read then goes by.
    case readTaken(Book)
    /// Read nothing: content.md holds an edit that cannot be taken, which a
    /// read would rebuild over from the book's own file. The read stops
    /// with this error, which says why and where the edit was kept.
    case hold(BookTextEditPending)
}

/// Why the text of a book being edited is neither read nor rebuilt now:
/// its content.md holds an edit TextMouth cannot take, which only the user
/// can settle in their editor (FR05). A reader shows its description in
/// place of the book; a rebuild that meets it leaves the book's text alone.
struct BookTextEditPending: LocalizedError, Sendable {
    /// The book's title.
    let bookTitle: String
    /// Why the edit cannot be taken.
    let refusal: BookTextEditRefusal
    /// The copy of the edited text kept beside content.md, or nil when none
    /// could be made.
    let keptCopy: URL?

    var errorDescription: String? {
        BookTextEditWording.held(refusal, bookTitle: bookTitle, keptCopy: keptCopy)
    }
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
///
/// Nothing the user saves in content.md is lost while the book is being
/// edited. An edit a check cannot take is kept beside content.md first
/// (`keepCopy(of:bytes:)`), and while it stands, beside an unchanged source,
/// neither a reader (`settlePendingEdit(of:)`) nor any rebuild of the text
/// (`permitTextRebuild(of:writing:)`) replaces it; a rebuild that does
/// replace text the user saved, taken or not, keeps it the same way first.
final class BookTextEditSessions: Sendable {
    /// The sessions of the app's Edit Text commands.
    static let shared = BookTextEditSessions()

    /// One book being edited.
    struct Session: Sendable {
        /// What the book's files held when its text was last taken, or last
        /// rebuilt from the book's own file.
        var baseline: BookTextBaseline
        /// Hears what each check found, on the checking queue, and what a
        /// rebuild replaced, on the rebuild's thread.
        let report: @Sendable (UUID, BookTextEditCheck) -> Void
        /// The edit the last check could not take; nil once an edit is
        /// taken, content.md holds the text taken again, or the text is
        /// rebuilt.
        var refused: RefusedEdit? = nil
        /// The copy kept of text the user saved, which the rebuild under way
        /// is about to replace (`permitTextRebuild(of:writing:)`), reported
        /// once the rebuild is written (`textRebuilt(_:writing:fingerprint:)`).
        var replacedCopy: URL? = nil
    }

    /// An edit a check could not take: the digest of what content.md held,
    /// nil when it could not be read, and why.
    struct RefusedEdit: Equatable, Sendable {
        let digest: String?
        let refusal: BookTextEditRefusal
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

    /// Checks `book` for an edit now, waiting for the check, before a
    /// reader reads the book's files, and says what the read does
    /// (`BookTextEditSettlement`). It reads an edit just taken, rather than
    /// finding content.md changed under a record that does not describe it,
    /// which would have it rebuilt from the source (TODO T07). It stops
    /// while content.md holds an edit that cannot be taken, which the check
    /// kept beside content.md, rather than rebuild over it. Otherwise it
    /// reads as usual, as it does at once for a book not being edited. A
    /// check never waits for the main thread, so this may be called from
    /// it, as a test does.
    @discardableResult
    func settlePendingEdit(of book: Book) -> BookTextEditSettlement {
        guard isEditing(book.id) else { return .readAsUsual }
        let found = queue.sync {
            check(book)
        }
        switch found {
        case .adopted(let edit)?:
            return .readTaken(edit.committed)
        case .refused(let refusal, _, let keptCopy)? where refusal.keepsEarlierText:
            return .hold(BookTextEditPending(bookTitle: book.title, refusal: refusal, keptCopy: keptCopy))
        default:
            return .readAsUsual
        }
    }

    /// Checks `book` for an edit, as storage work, so it waits while a
    /// data-directory move or a folder edit holds the storage work; its
    /// paths are then taken under the data directory in use. A folder edit
    /// that moved the book meanwhile leaves its files elsewhere, which this
    /// check finds missing; the next one, with the book as the library
    /// holds it then, finds them. Reports what was found to the session,
    /// keeps a new baseline when an edit was taken or the files were only
    /// rewritten, and remembers an edit it could not take, for a rebuild
    /// that meets it to say why (`permitTextRebuild(of:writing:)`). Runs on
    /// the queue.
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
            sessions.withLock { all in
                guard all[bookID] != nil else { return }
                if let baseline = checked.baseline {
                    all[bookID]?.baseline = baseline
                }
                switch checked.found {
                case .refused(let refusal, let digest, _):
                    all[bookID]?.refused = RefusedEdit(digest: digest, refusal: refusal)
                case .adopted, .unchanged:
                    all[bookID]?.refused = nil
                case .inCloud, .missing, .replaced:
                    break
                }
            }
            return checked.found
        }
        session.report(bookID, found)
        return found
    }

    // MARK: Rebuilds

    /// Lets a rebuild replace `book`'s content.md with `newBytes`, its text
    /// read again from the book's own file (`MarkdownCacheService`), once
    /// what the user saved there is safe.
    ///
    /// A book not being edited, or whose content.md is gone or holds those
    /// very bytes, is rebuilt at once. Otherwise content.md holds text the
    /// user saved, taken or not, which is kept beside it first
    /// (`keepCopy(of:bytes:)`). The rebuild may then go on when that text was
    /// taken, or when the book's own file changed since, which the book's
    /// text is read from again; the session hears of the copy once the
    /// rebuild is written (`textRebuilt(_:writing:fingerprint:)`). It is
    /// refused while content.md holds an edit not taken beside an unchanged
    /// source, which only the user can settle in their editor, while
    /// content.md is only in the cloud, and when no copy could be kept.
    ///
    /// Runs on the rebuild's thread, inside its storage work, and never
    /// waits for the checking queue, whose check may itself be waiting for
    /// that storage work.
    /// - Throws: `BookTextEditPending`, saying why and where the edited
    ///   text was kept.
    func permitTextRebuild(of book: Book, writing newBytes: Data) throws {
        guard let session = sessions.withLock({ $0[book.id] }) else { return }
        let cacheURL = MarkdownCacheService.cacheURL(for: book)
        guard FileStamp(of: cacheURL) != nil else { return }
        guard !access.isInCloud(cacheURL) else {
            throw holding(book, .failed(BookTextEditWording.onlyInCloud), keptCopy: nil)
        }
        let bytes = try? access.read(cacheURL) { try Data(contentsOf: cacheURL) }
        guard bytes != newBytes else { return }

        let kept = Self.keepCopy(of: cacheURL, bytes: bytes)
        let digest = bytes.map { access.hasher.digestOfData($0) }
        let wasTaken = digest != nil && digest == session.baseline.cache.digest
        let mayReplace = wasTaken || Self.hasChanged(session.baseline.source, at: Self.sourceURL(of: book), access: access)
        if let kept, mayReplace {
            sessions.withLock { $0[book.id]?.replacedCopy = kept }
            Self.logLine("TEXT_EDIT_KEPT", about: book, "content.md kept as \(kept.lastPathComponent) before its text was read again from the book's own file")
            return
        }
        let refusal: BookTextEditRefusal
        if kept == nil {
            refusal = .failed(BookTextEditWording.noCopyKept)
        } else if let earlier = session.refused, earlier.digest == digest {
            refusal = earlier.refusal
        } else {
            refusal = .failed(BookTextEditWording.notReadYet)
        }
        throw holding(book, refusal, keptCopy: kept)
    }

    /// Takes the content.md a rebuild just wrote as `bytes`, read again from
    /// `book`'s own file, as the text of the book's session from now on, so
    /// the user's next save is checked against it and an edit refused before
    /// is forgotten. A copy kept of text the user had saved there
    /// (`permitTextRebuild(of:writing:)`) is reported, for VoiceOver to say
    /// where it is. `fingerprint` is what the rebuild recorded, when it could.
    func textRebuilt(_ book: Book, writing bytes: Data, fingerprint: TextCacheFingerprint?) {
        guard isEditing(book.id) else { return }
        let cacheURL = MarkdownCacheService.cacheURL(for: book)
        let hasher = access.hasher
        guard let cache = fingerprint?.cache
            ?? FileStamp(of: cacheURL).map({ FileFingerprint(stamp: $0, digest: hasher.digestOfData(bytes)) }) else { return }
        let sourceURL = Self.sourceURL(of: book)
        let source = fingerprint?.source
            ?? (access.isInCloud(sourceURL) ? nil : FileFingerprint(of: sourceURL, hasher: hasher))
        // The session as it was, with the copy to report, once it is reset.
        let before = sessions.withLock { all -> Session? in
            guard let session = all[book.id] else { return nil }
            all[book.id]?.baseline = BookTextBaseline(source: source, cache: cache)
            all[book.id]?.refused = nil
            all[book.id]?.replacedCopy = nil
            return session
        }
        if let before, let kept = before.replacedCopy {
            before.report(book.id, .replaced(keptCopy: kept))
        }
    }

    /// The error that keeps `book`'s text from being rebuilt or read, for
    /// `refusal`, with the copy kept of the edit, logged once as
    /// `TEXT_EDIT_HELD`.
    private func holding(_ book: Book, _ refusal: BookTextEditRefusal, keptCopy: URL?) -> BookTextEditPending {
        Self.logLine("TEXT_EDIT_HELD", about: book, "its text was not read again from the book's own file over an edit not taken\(Self.keptNote(keptCopy))")
        return BookTextEditPending(bookTitle: book.title, refusal: refusal, keptCopy: keptCopy)
    }

    /// Keeps a copy of the content.md at `url` beside it, holding `bytes`,
    /// or linked to the file when they could not be read, named like
    /// "content.md.edited-20261004T123012Z" (`TextMouthPaths.keptTextCopyMarker`).
    /// A copy kept earlier of the same bytes is used again, and nothing is
    /// downloaded (`SavedFile.preserveUnusable`).
    /// - Returns: The copy, or nil when none could be made.
    static func keepCopy(of url: URL, bytes: Data?) -> URL? {
        SavedFile.preserveUnusable(url, bytes: bytes, marker: TextMouthPaths.keptTextCopyMarker)
    }

    /// The end of a log line saying where an edit was kept: "; kept as
    /// content.md.edited-…", or that no copy could be made.
    private static func keptNote(_ keptCopy: URL?) -> String {
        keptCopy.map { "; kept as \($0.lastPathComponent)" } ?? "; no copy of it could be kept"
    }

    // MARK: The Check

    /// The file `book`'s text is written from, which an edit is taken
    /// beside only while it holds what it held: a text book's own file, or,
    /// for a transcribed audiobook, its transcript.json (FR05).
    static func sourceURL(of book: Book) -> URL {
        book.format.isAudio ? TextMouthPaths.transcriptPath(in: book.tmbDirectory) : book.bookFileURL
    }

    /// What `book`'s files hold now, as the baseline an edit is checked
    /// against: content.md's fingerprint and its source's
    /// (`sourceURL(of:)`), read with dataless files left in the cloud
    /// (FR02). A source only in the cloud, or gone, is left unfingerprinted.
    /// - Returns: The baseline, or why editing cannot begin: content.md, or
    ///   its package, is in the cloud, or content.md is missing or cannot
    ///   be read.
    static func baseline(of book: Book, access: MaintenanceFileAccess) -> Result<BookTextBaseline, BookTextEditStartFailure> {
        let cacheURL = MarkdownCacheService.cacheURL(for: book)
        let sourceURL = sourceURL(of: book)
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
    /// - An edit is refused beside a changed source, when content.md is not
    ///   UTF-8 or no longer holds a chapter with anything in it, and when it
    ///   cannot be read or committed; the book keeps its earlier index. A
    ///   refused edit is first kept beside content.md (`keepCopy(of:bytes:)`),
    ///   so nothing the user saved is lost when the text is rebuilt.
    /// - Otherwise content.md is indexed afresh (headings, lengths, and
    ///   counts), its fingerprints become those of the edited bytes and
    ///   the source, so the text is not rebuilt from the source, and the
    ///   index is committed to the book's record at once, its cache format
    ///   current (`LibraryPersistenceService.saveContentAnalysis`). The
    ///   reading text this Mac kept for the book is removed.
    /// - A transcribed audiobook's edit is taken into its transcript
    ///   instead (`TranscriptStore.takeEdit`): transcript.json takes the
    ///   edit, so the text written from it is the edit from then on, and the
    ///   book's audio index takes the text's layer. An edit that changes the
    ///   number of chapters, or of an audiobook whose audio changed since it
    ///   was transcribed, is refused as any other is.
    ///
    /// - Returns: What was found, and the baseline from now on when it
    ///   changed.
    static func check(
        _ book: Book,
        against baseline: BookTextBaseline,
        access: MaintenanceFileAccess,
        readingTexts: ReadingTextCache
    ) -> (found: BookTextEditCheck, baseline: BookTextBaseline?) {
        guard !book.tmbDirectoryName.isEmpty else { return (.missing, nil) }
        let cacheURL = MarkdownCacheService.cacheURL(for: book)
        let sourceURL = sourceURL(of: book)
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
            // Bytes that cannot be read are kept by a link to the file.
            let kept = keepCopy(of: cacheURL, bytes: nil)
            logLine("TEXT_EDIT_FAILED", about: book, "content.md could not be read: \(error.localizedDescription)\(keptNote(kept))")
            return (.refused(.failed(error.localizedDescription), digest: nil, keptCopy: kept), nil)
        }
        let digest = access.hasher.digestOfData(bytes)
        let cache = FileFingerprint(stamp: cacheStamp, digest: digest)
        guard digest != baseline.cache.digest else {
            // Rewritten with the same bytes: nothing was edited.
            return (.unchanged, BookTextBaseline(source: baseline.source, cache: cache))
        }
        /// Refuses the edit for `refusal`, keeping it beside content.md
        /// first, with one line tagged `tag` saying `why`.
        func refuse(_ refusal: BookTextEditRefusal, tag: String, _ why: String) -> (found: BookTextEditCheck, baseline: BookTextBaseline?) {
            let kept = keepCopy(of: cacheURL, bytes: bytes)
            logLine(tag, about: book, "\(why)\(keptNote(kept))")
            return (.refused(refusal, digest: digest, keptCopy: kept), nil)
        }
        let source: FileFingerprint?
        switch checkSource(baseline.source, at: sourceURL, access: access) {
        case .changed where book.format.isAudio:
            return refuse(
                .transcriptChanged,
                tag: "TEXT_EDIT_SOURCE_CHANGED",
                "the book's transcript changed too; its text will be written from that transcript again"
            )
        case .changed:
            return refuse(
                .sourceChanged,
                tag: "TEXT_EDIT_SOURCE_CHANGED",
                "the book's own file changed too; its text will be read from that file again"
            )
        case .unchanged(let fingerprint):
            source = fingerprint
        }

        guard let text = try? MarkdownCacheService.cacheText(from: bytes, at: cacheURL) else {
            return refuse(.notText, tag: "TEXT_EDIT_REFUSED", "content.md is not UTF-8 text")
        }
        let parsed = MarkdownCacheService.parseMultiChapterMarkdown(text, bookTitle: book.title, bookAuthor: book.author)
        guard parsed.chapters.contains(where: { chapter in chapter.text.contains { !$0.isWhitespace } }) else {
            return refuse(.noChapters, tag: "TEXT_EDIT_REFUSED", "content.md holds no chapter with anything in it")
        }
        if book.format.isAudio {
            return takeTranscriptEdit(of: book, parsed: parsed, markdown: text, cache: cache, readingTexts: readingTexts, access: access, refuse: refuse)
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
            return refuse(.failed(error.localizedDescription), tag: "TEXT_EDIT_FAILED", error.localizedDescription)
        }
        guard let committed else {
            // The record could not take it now (it is only in the cloud, or
            // the book moved meanwhile); the next check tries again.
            return refuse(
                .failed(BookTextEditWording.recordUnavailable),
                tag: "TEXT_EDIT_FAILED",
                "the book's record could not take the edit now"
            )
        }
        // The kept reading text was read from the content.md just replaced.
        readingTexts.remove(bookID: book.id)
        logLine(
            "TEXT_EDIT_ADOPTED",
            about: book,
            "\(index.chapters.count) chapter(s), \(index.totalWordCount) word(s), \(index.allHeadings.count) heading(s)"
        )
        let content = DocumentContent(title: parsed.title, author: parsed.author, chapters: parsed.chapters, contentIndex: index)
        return (.adopted(BookTextEdit(committed: committed, text: .document(content))), BookTextBaseline(source: source, cache: cache))
    }

    /// Takes the edit `parsed`, content.md as the user saved it, holding
    /// `markdown`, fingerprinted as `cache`, into the transcript of `book`,
    /// a transcribed audiobook (FR05, `TranscriptStore.takeEdit`), or
    /// refuses it through `refuse`, which keeps it beside content.md. The
    /// baseline from then on is the transcript.json the edit wrote, beside
    /// the user's content.md.
    private static func takeTranscriptEdit(
        of book: Book,
        parsed: DocumentContent,
        markdown: String,
        cache: FileFingerprint,
        readingTexts: ReadingTextCache,
        access: MaintenanceFileAccess,
        refuse: (BookTextEditRefusal, String, String) -> (found: BookTextEditCheck, baseline: BookTextBaseline?)
    ) -> (found: BookTextEditCheck, baseline: BookTextBaseline?) {
        let taken: TranscriptStore.TakenEdit?
        do {
            taken = try TranscriptStore.takeEdit(
                parsed.chapters,
                markdown: markdown,
                cache: cache,
                of: book,
                isDataless: access.isInCloud,
                hasher: access.hasher
            )
        } catch TranscriptEditError.chaptersChanged(let found, let expected) {
            return refuse(
                .chaptersChanged(found: found, expected: expected),
                "TEXT_EDIT_REFUSED",
                "the edited transcript holds \(found) chapter(s), where the audiobook has \(expected)"
            )
        } catch TranscriptEditError.audioChanged(let reason) {
            return refuse(
                .failed(BookTextEditWording.transcriptStale),
                "TEXT_EDIT_REFUSED",
                "the transcript no longer describes the audio: \(reason)"
            )
        } catch TranscriptEditError.transcriptUnavailable {
            return refuse(.failed(BookTextEditWording.transcriptUnavailable), "TEXT_EDIT_FAILED", "transcript.json could not be read")
        } catch TranscriptEditError.unindexable(let failure) {
            return refuse(.failed(BookTextEditWording.transcriptUnindexable), "TEXT_EDIT_FAILED", "the edit could not be indexed: \(failure)")
        } catch {
            return refuse(.failed(error.localizedDescription), "TEXT_EDIT_FAILED", error.localizedDescription)
        }
        guard let taken else {
            // The record could not take it now (it is only in the cloud, or
            // the book moved meanwhile); the next check tries again.
            return refuse(.failed(BookTextEditWording.recordUnavailable), "TEXT_EDIT_FAILED", "the book's record could not take the edit now")
        }
        // The kept reading text was read from the content.md just replaced.
        readingTexts.remove(bookID: book.id)
        let chapterCount = taken.text.chapters.count
        let wordCount = taken.text.index.totalWordCount
        logLine("TEXT_EDIT_ADOPTED", about: book, "the transcript took it: \(chapterCount) chapter(s), \(wordCount) word(s)")
        return (
            .adopted(BookTextEdit(committed: taken.committed, text: .transcript(taken.text))),
            BookTextBaseline(source: taken.source, cache: cache)
        )
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

    /// Whether the source at `url` holds other bytes than `recorded` says it
    /// held (`checkSource(_:at:access:)`).
    private static func hasChanged(_ recorded: FileFingerprint?, at url: URL, access: MaintenanceFileAccess) -> Bool {
        if case .changed = checkSource(recorded, at: url, access: access) {
            return true
        }
        return false
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

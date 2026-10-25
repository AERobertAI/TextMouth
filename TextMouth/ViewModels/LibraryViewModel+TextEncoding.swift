import Foundation

// MARK: - Reading a Book Again in Another Encoding (encodingchoice)

/// What the work of reading a book's text again, off the main actor, came
/// to (`LibraryViewModel.rereadText(of:as:access:isOpenInReader:)`).
enum TextEncodingReread: Sendable {
    /// The text was read again and committed: what the book's package now
    /// records, with the new text for an open reader; what the book is read
    /// in now; and the copy kept of text TextMouth did not write, if any.
    case readAgain(TextCacheUpdate, reading: TextEncodingReading?, keptCopy: URL?)
    /// Nothing changed, for the reason given, in full.
    case refused(String)
}

extension LibraryViewModel {

    // MARK: Refusals

    /// Why the text of `book` can't be read again in another encoding now,
    /// in full, or nil when it can, as far as the library can tell without
    /// looking at the book's files, which are looked at as it is read
    /// (`rereadText(of:as:access:isOpenInReader:)`): a file only in the
    /// cloud, or bytes not valid in the encoding chosen.
    ///
    /// - Another operation holds the library's storage work (a folder edit
    ///   moving books, Rebuild Directory, a data-directory move, a switch of
    ///   libraries): the re-read would write into packages moving under it.
    ///   Replace Existing waits for the same (`replacementRefusal(of:)`), in
    ///   the same words (`StorageBusyError`).
    /// - The library's text is being read again (the launch batch, Redo Text
    ///   Extraction), which may be rewriting this very book.
    /// - The book is being read again already, from Book Information in the
    ///   library or in a reader (`readingAgainRefusal(of:)`).
    /// - The book is being exported: the export would write the old text or
    ///   the new, whichever it read. Of the uses Replace Existing waits for
    ///   (`FeedBookUse`), it is the one a text book can have but for a
    ///   reader, which shows the new text instead.
    ///
    /// A book being edited with Edit Text is not refused: its session stops
    /// for the re-read, as it does for Replace Existing
    /// (`readTextAgain(bookID:as:access:)`, review of October 24, finding 6).
    func textEncodingChangeRefusal(of book: Book) -> String? {
        if let held = StorageBoundary.shared.heldFor {
            return StorageBusyError(reason: held).errorDescription
        }
        if isExtracting {
            return TextEncodingWording.extractionRefusal
        }
        if let refusal = readingAgainRefusal(of: book.id) {
            return refusal
        }
        if BookExportModel.booksBeingExported.contains(book.id) {
            return TextEncodingWording.exportingRefusal(bookTitle: book.title)
        }
        return nil
    }

    /// Why text can't be rewritten now because TextMouth is reading a book's
    /// text again in another encoding (`booksBeingReadAgain`), in full: the
    /// book `bookID`'s, or, when nil, any book's, as Redo Text Extraction
    /// asks, since it rewrites every book's text. Nil when no such re-read
    /// is under way. A second re-read of the book, Edit Text, Redo Text
    /// Extraction, and Replace Existing (`replacementRefusal(of:)`) all ask
    /// here, so each waits in the same words, and none leaves content.md
    /// from one run beside the record of another (review of October 24,
    /// finding 3); so does the launch's text batch, which leaves such a book
    /// alone (`extractMissingContentCaches(access:then:)`), and a reader's
    /// load, which waits for its re-read (`ReaderViewModel.beginReadingForLoad()`).
    func readingAgainRefusal(of bookID: UUID? = nil) -> String? {
        guard !booksBeingReadAgain.isEmpty else { return nil }
        let busy = library.books.first { book in
            booksBeingReadAgain.contains(book.id) && (bookID == nil || book.id == bookID)
        }
        return busy.map { TextEncodingWording.readingAgainRefusal(bookTitle: $0.title) }
    }

    // MARK: Reading Again

    /// Reads the text of the book `bookID` again from its file as `option`
    /// says, once the listener has confirmed it in Book Information's Text
    /// Encoding pop-up: in one encoding, which the book records as chosen,
    /// or automatically, as an import reads a file, which records the guess,
    /// if it made one, and that the listener chose Automatic.
    ///
    /// It is the one-book form of what Redo Text Extraction does
    /// (`MarkdownCacheService.generateReportedCacheAnalyzeAndStamp`, then
    /// `LibraryPersistenceService.saveContentAnalysis`), with its
    /// protections: the book's places move with the text (T06); a reader
    /// that has the book open shows the new text, its cursor following its
    /// words (ST01); and nothing is downloaded. Text TextMouth did not write
    /// (an Edit Text change, or a save no edit took) is kept beside the new
    /// text first, as Replace Existing keeps it, and VoiceOver hears where.
    /// The analysis and the encoding go into the book's record in one write,
    /// before the row takes them.
    ///
    /// A book being edited with Edit Text has its session paused first, an
    /// edit saved and not yet checked being taken
    /// (`BookTextEditor.pauseEditing(of:)`): the session watches the
    /// content.md the re-read replaces, and would take the new reading for
    /// an edit. A re-read that goes ahead ends it, as Replace Existing ends
    /// one, keeping its text beside the new reading, and VoiceOver hears
    /// that Edit Text has stopped (review of October 24, finding 6); one
    /// that changes nothing begins it again (`resumeEditing(of:)`), so the
    /// listener's later saves are still taken.
    ///
    /// Nothing changes, and why is returned, when the book is busy
    /// (`textEncodingChangeRefusal(of:)`), when a file it reads is only in
    /// the cloud, when its bytes are not valid in the encoding chosen, which
    /// is read strictly (`TextFileDecoder.EncodingPolicy.chosen(_:)`), when
    /// the text TextMouth did not write cannot be kept, and when the reading
    /// fails.
    /// - Returns: `.success` with what VoiceOver was told, or `.failure`
    ///   with why nothing changed, which Book Information shows and
    ///   announces.
    func readTextAgain(
        bookID: UUID,
        as option: TextEncodingOption,
        access: MaintenanceFileAccess = .live
    ) async -> OperationOutcome {
        guard let book = bookByID(bookID) else {
            return .failure(TextEncodingWording.bookGoneRefusal)
        }
        // Book Information offers no choice for such a book; refused all the same.
        guard book.offersTextEncodingChoice else {
            return .failure(TextEncodingWording.failedRefusal(bookTitle: book.title, reason: nil))
        }
        if let refusal = textEncodingChangeRefusal(of: book) {
            return .failure(refusal)
        }
        // The book is busy until its row has the new reading: whatever would
        // rewrite its text meanwhile waits (`readingAgainRefusal(of:)`).
        booksBeingReadAgain.insert(bookID)
        defer { booksBeingReadAgain.remove(bookID) }
        // Edit Text's session pauses, an editor made only for a session
        // there is, as Replace Existing makes one.
        let editor = textEditSessions.isEditing(bookID) ? bookTextEditor() : nil
        let wasEditing = await editor?.pauseEditing(of: book) ?? false
        // The row as the pause left it, with any edit it took.
        guard let current = bookByID(bookID) else {
            return .failure(TextEncodingWording.bookGoneRefusal)
        }
        // Asked from the work's thread at the commit: the activity mirrors
        // the books open in readers (`openBookIDs`) behind a lock, as the
        // batch asks it.
        let activity = audioEditActivity
        let isOpenInReader: @Sendable (UUID) -> Bool = { activity.isOpenInReader($0) }
        let reread = await OffMainWork.run {
            Self.rereadText(of: current, as: option, access: access, isOpenInReader: isOpenInReader)
        }
        switch reread {
        case .refused(let reason):
            if wasEditing, let editor {
                await editor.resumeEditing(of: current)
            }
            return .failure(reason)
        case let .readAgain(update, reading, keptCopy):
            applyTextCacheUpdate(update, atOnce: true)
            if let record = update.summary?.textEncodingRecord {
                DiagnosticLog.event(.storage, Self.textEncodingLogLine(title: book.title, record: record, keptCopy: keptCopy))
            }
            let announcement = TextEncodingWording.readAgainAnnouncement(
                bookTitle: book.title, reading: reading, keptCopy: keptCopy, stoppedEditing: wasEditing
            )
            VoiceOverAnnouncer.announce(announcement)
            return .success(announcement)
        }
    }

    /// The work of `readTextAgain(bookID:as:access:)` off the main actor,
    /// for `book` as the library held it: every file checked to be on this
    /// Mac; the bytes read strictly in the encoding chosen, before anything
    /// is written; the text TextMouth did not write kept; the file read
    /// again, with its places moved; and the analysis committed with the
    /// encoding and who decided it, in one write of the book's record.
    ///
    /// It is one piece of storage work, from the first read to the commit
    /// (`StorageBoundary.perform`, whose work started inside it, such as the
    /// rebuild's own, is part of it): a folder edit or a data-directory move
    /// that begins meanwhile waits for it to end, so the book's package
    /// never moves between content.md's write and the record's commit
    /// (review of October 24, finding 2).
    nonisolated static func rereadText(
        of book: Book,
        as option: TextEncodingOption,
        access: MaintenanceFileAccess,
        isOpenInReader: @escaping @Sendable (UUID) -> Bool
    ) -> TextEncodingReread {
        let notDownloaded = TextEncodingReread.refused(LibraryCloudWording.notDownloaded(titles: [book.title]))
        return StorageBoundary.shared.perform(.textExtraction) { _ in
            // Its paths in the data directory in use now, should a move have
            // published while the work waited to begin.
            let book = StorageBoundary.shared.rebasedToCurrent(book)
            guard access.fileInCloud(of: book, reading: .all) == nil else { return notDownloaded }
            do {
                return try access.read(book.bookFileURL) {
                    try rereadFiles(of: book, as: option, access: access, isOpenInReader: isOpenInReader)
                }
            } catch where DatalessFiles.isDownloadRefusal(error) {
                return notDownloaded
            } catch is UnwrittenTextNotKept {
                return .refused(TextEncodingWording.editNotKeptRefusal(bookTitle: book.title))
            } catch is CommitDropped {
                return .refused(TextEncodingWording.failedRefusal(bookTitle: book.title, reason: nil))
            } catch {
                return .refused(TextEncodingWording.failedRefusal(bookTitle: book.title, reason: error.localizedDescription))
            }
        }
    }

    /// The reads and writes of `rereadText(of:as:access:isOpenInReader:)`,
    /// with dataless files left in the cloud.
    ///
    /// content.md is put back as it was, its bytes and its dates, when
    /// anything fails once it is replaced, as a transcript's install puts
    /// back what it wrote (`PackageFileBeforeInstall`): the record then still
    /// describes it, so no later load takes the new reading for text changed
    /// by hand, and the refusal's "left the book as it was" is true. Putting
    /// back is simpler than committing the record first, since the record's
    /// fingerprint of content.md is only known once content.md is written.
    /// - Throws: why the book was not read again; `CommitDropped` when the
    ///   record took nothing (`LibraryPersistenceService.saveContentAnalysis`).
    private nonisolated static func rereadFiles(
        of book: Book,
        as option: TextEncodingOption,
        access: MaintenanceFileAccess,
        isOpenInReader: @Sendable (UUID) -> Bool
    ) throws -> TextEncodingReread {
        // 1. The encoding chosen, read strictly before anything is written.
        var chosen: TextEncodingRecord?
        if option != .automatic {
            guard let validated = try validatedChoice(of: option, for: book) else {
                return .refused(TextEncodingWording.notValidRefusal(
                    bookTitle: book.title, encoding: TextEncodingChoices.name(of: option)
                ))
            }
            chosen = validated
        }
        // 2. Text TextMouth did not write, kept beside the new text.
        let keptCopy = try keptUnwrittenText(of: book, access: access)
        // 3. The file read again, as chosen, or as an import reads it, with
        // content.md as it is now kept to be put back. The read decides the
        // encoding, so the decision the record holds, which it replaces, is
        // not read in its place.
        let cacheURL = MarkdownCacheService.cacheURL(for: book)
        let textBefore = PackageFileBeforeInstall(cacheURL)
        var updated = book
        updated.textEncodingRecord = chosen ?? .unrecorded
        guard let generated = try MarkdownCacheService.generateReportedCacheAnalyzeAndStamp(
            for: &updated, replacingEditedText: true, decidingEncoding: true
        ) else {
            return .refused(TextEncodingWording.failedRefusal(bookTitle: book.title, reason: nil))
        }
        let textWritten = generated.content.contentIndex.textCacheFingerprint?.cache.stamp ?? FileStamp(of: cacheURL)
        do {
            // Automatic records its guess, if it made one, and that the
            // listener chose Automatic, so no older choice in the record
            // comes back in place of nothing (`TextEncodingSource`).
            let record = chosen ?? TextEncodingRecord(identifier: updated.textEncoding, source: .automatic)
            updated.textEncodingRecord = record
            // A file that went to the cloud meanwhile may have been read in
            // part, so nothing is committed from it.
            try access.requireOnThisMac(book, reading: .all)
            guard let committed = try LibraryPersistenceService.saveContentAnalysis(
                for: updated,
                index: generated.content.contentIndex,
                cacheFormatVersion: MarkdownCacheService.currentCacheVersion,
                movedPlaces: generated.movedPlaces,
                pageReaderVersion: .some(generated.pageReaderVersion),
                textEncoding: record
            ) else { throw CommitDropped() }
            // Which readers have the book open is asked now, at the commit,
            // as the batch asks it (`updateTextCache`): a reader opened while
            // the book was read is given the new text too, so its checkpoints
            // never write the old text's places.
            let textForOpenReader = isOpenInReader(book.id)
                ? TextForOpenReader(content: generated.content, movedPlaces: generated.movedPlaces)
                : nil
            let update = TextCacheUpdate(
                summary: ContentAnalysisSummary(committed: committed, movedPlaces: generated.movedPlaces),
                textForOpenReader: textForOpenReader
            )
            // What it is read in now, for VoiceOver to say.
            guard case .known(let reading) = TextEncodingReading.current(of: committed, access: access) else {
                return .readAgain(update, reading: nil, keptCopy: keptCopy)
            }
            return .readAgain(update, reading: reading, keptCopy: keptCopy)
        } catch {
            // The places' copy of the old text stays with the places, for
            // the launch's place recovery, which moves nothing to the same
            // text and then lets it go, as after any dropped commit.
            PackageFileBeforeInstall.putBack(
                [(textBefore, textWritten)], of: book, after: "the re-read", logTag: textEncodingChangedLogTag
            )
            throw error
        }
    }

    /// The record a choice of `option` gives `book`: the first identifier of
    /// the option's name whose encoding reads every byte of the book's file
    /// (`TextEncodingChoices.identifiers(of:)`), as chosen; nil when none
    /// does. Reads the file, and writes nothing.
    /// - Throws: why the file could not be read; bytes not valid in an
    ///   encoding only send it on to the next.
    private nonisolated static func validatedChoice(of option: TextEncodingOption, for book: Book) throws -> TextEncodingRecord? {
        for identifier in TextEncodingChoices.identifiers(of: option) {
            do {
                _ = try TextFileDecoder.readDecodedText(at: book.bookFileURL, format: book.format, policy: .chosen(identifier))
                return TextEncodingRecord(identifier: identifier, source: .chosen)
            } catch TextEncodingError.invalidForChosenEncoding {
                continue
            }
        }
        return nil
    }

    /// Keeps the text `book`'s content.md holds beside it before the re-read
    /// replaces it, when TextMouth did not write it: an Edit Text change, or
    /// a save no edit took, as Replace Existing keeps it
    /// (`DuplicateReplacement.holdsUnwrittenText(_:of:hasher:)`). The copy is
    /// named as Edit Text names the copies it keeps
    /// (`BookTextEditSessions.keepCopy(of:bytes:)`), and the rebuild that
    /// follows finds it and keeps no second one. Nil when there is no such
    /// text, or no content.md.
    /// - Throws: `UnwrittenTextNotKept` when it could not be kept, so the
    ///   book is not read again over it.
    private nonisolated static func keptUnwrittenText(of book: Book, access: MaintenanceFileAccess) throws -> URL? {
        guard let bytes = try unwrittenText(of: book, access: access) else { return nil }
        let cacheURL = MarkdownCacheService.cacheURL(for: book)
        guard let copy = BookTextEditSessions.keepCopy(of: cacheURL, bytes: bytes) else { throw UnwrittenTextNotKept() }
        return copy
    }

    /// The bytes of `book`'s content.md when they hold text TextMouth did not
    /// write, which a re-read keeps beside the new reading: an Edit Text
    /// change, or a save no edit took
    /// (`DuplicateReplacement.holdsUnwrittenText(_:of:hasher:)`). Nil when
    /// there is no such text, or no content.md. Read through `access`, so a
    /// content.md only in the cloud is never downloaded for it; the
    /// confirmation asks it too, to say whether a copy will be kept
    /// (`TextEncodingChoiceModel.choose(_:)`).
    /// - Throws: why content.md could not be read.
    nonisolated static func unwrittenText(of book: Book, access: MaintenanceFileAccess) throws -> Data? {
        let cacheURL = MarkdownCacheService.cacheURL(for: book)
        guard FileStamp(of: cacheURL) != nil else { return nil }
        let bytes = try access.read(cacheURL) { try Data(contentsOf: cacheURL) }
        return DuplicateReplacement.holdsUnwrittenText(bytes, of: book, hasher: access.hasher) ? bytes : nil
    }

    /// The debug log's line for a book read again in another encoding: the
    /// title, the encoding it records and who decided it, and where text
    /// TextMouth did not write was kept, as
    /// `TEXT_ENCODING_CHANGED: Ledger: read again as koi8-r, chosen`.
    nonisolated static func textEncodingLogLine(title: String, record: TextEncodingRecord, keptCopy: URL?) -> String {
        var line = "\(textEncodingChangedLogTag): \(title): "
        switch (record.identifier, record.source) {
        case (let identifier?, .chosen):
            line += "read again as \(identifier), chosen"
        case (let identifier?, _):
            line += "read again automatically, as \(identifier), guessed"
        case (nil, _):
            line += "read again automatically, with no encoding to record"
        }
        if let keptCopy {
            line += "; its earlier text was kept as \(keptCopy.lastPathComponent)"
        }
        return line
    }

    /// The tag that begins the log line of a book read again in another
    /// encoding.
    nonisolated static let textEncodingChangedLogTag = "TEXT_ENCODING_CHANGED"
}

/// Why a book was not read again in another encoding: the text TextMouth did
/// not write could not be kept beside the new reading.
private struct UnwrittenTextNotKept: Error {}

/// Why a book was not read again in another encoding: its record took
/// nothing, as when its file was replaced or moved meanwhile, so content.md
/// is put back.
private struct CommitDropped: Error {}

// MARK: - Re-reads Under Way

/// The books whose text is being read again in another encoding, app-wide:
/// from the listener's confirmation until the library row has the new
/// reading (`LibraryViewModel.readTextAgain(bookID:as:access:)`, which marks
/// them through `LibraryViewModel.booksBeingReadAgain`). What would rewrite
/// such a book's text waits for its re-read
/// (`LibraryViewModel.readingAgainRefusal(of:)`), and so does a quit
/// (`quitWork()`): a re-read stopped between content.md's write and its
/// record's would leave the new reading beside the old record, which the
/// next launch takes for an edit saved while TextMouth was closed (review
/// of October 25, item 1).
@MainActor
final class TextRereads {
    /// The app's re-reads, which its library model marks and its quit waits for.
    static let shared = TextRereads()

    /// The longest a quit waits for the re-reads under way: one takes about
    /// a second for a long book, and past this TextMouth quits anyway.
    static let longestQuitWait: Duration = .seconds(10)

    /// The books being read again.
    var bookIDs: Set<UUID> = [] {
        didSet {
            begun &+= bookIDs.subtracting(oldValue).count
            resumeWaitersWhoMayGoOn()
        }
    }

    /// How many re-reads have begun, so a reader of a book's text can tell
    /// whether one began, and maybe ended, while it read (`BookTextEditor`).
    private(set) var begun = 0

    /// Those waiting for a re-read to end, each with the book it waits for,
    /// or nil for every book (`ended(_:)`).
    private var waiters: [(bookID: UUID?, continuation: CheckedContinuation<Void, Never>)] = []

    /// Whether the book `bookID` is being read again, or, when nil, any book.
    func isReadingAgain(_ bookID: UUID? = nil) -> Bool {
        bookID.map(bookIDs.contains) ?? !bookIDs.isEmpty
    }

    /// Returns once the book `bookID` is no longer being read again, or,
    /// when nil, once no book is: at once when that is so already.
    func ended(_ bookID: UUID? = nil) async {
        guard isReadingAgain(bookID) else { return }
        await withCheckedContinuation { waiters.append((bookID, $0)) }
    }

    /// The re-reads as work a quit waits for (`QuitHold`): while any runs,
    /// until every one has ended, for at most `longestWait`.
    func quitWork(longestWait: Duration = TextRereads.longestQuitWait) -> QuitHold.Work {
        QuitHold.Work(
            isRunning: { self.isReadingAgain() },
            end: { await self.ended() },
            longestWait: longestWait
        )
    }

    /// Lets each waiter whose book is no longer being read again go on.
    private func resumeWaitersWhoMayGoOn() {
        let ready = waiters.filter { !isReadingAgain($0.bookID) }
        guard !ready.isEmpty else { return }
        waiters.removeAll { !isReadingAgain($0.bookID) }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

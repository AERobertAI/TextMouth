import Foundation

// MARK: - Reading a Book Again in Another Encoding or Other Braille File Characters (encodingchoice, braillecodes)

/// What a re-read of a book's text decides, once the listener has confirmed
/// it in Book Information (`LibraryViewModel.readTextAgain(bookID:choosing:access:)`):
/// how the book's file is read from now on. A text book's choice is its
/// encoding (encodingchoice); a BRF or BRL braille book's is its braille
/// file characters, the code its file writes its cells in (braillecodes).
/// The re-read is one and the same for both, but for what this decides.
enum TextRereadChoice: Hashable, Sendable {
    /// A plain-text, Markdown, or HTML book's file read in the encoding the
    /// option names, or automatically, as an import reads it.
    case textEncoding(TextEncodingOption)
    /// A BRF or BRL braille book's file read with the braille file
    /// characters of this code.
    case brailleFileCode(BrailleFileCode)
    /// A braille book's file read with this braille table, the braille code
    /// its cells are translated to print by (`Book.brailleTable`, FMT21).
    case brailleTable(BrailleTable)
    /// A braille book's file read with these braille file characters and
    /// this braille table together, one re-read for both: what Replace
    /// Existing carries to a copy of the same file when the listener chose
    /// both for the old copy in Book Information.
    case brailleFileCodeAndTable(BrailleFileCode, BrailleTable)

    /// Whether Book Information offers `book` a choice of this kind: its
    /// Text Encoding pop-up (`Book.offersTextEncodingChoice`), its braille
    /// file characters (`Book.offersBrailleFileCodeChoice`), or its braille
    /// code (`Book.offersBrailleTableChoice`).
    func isOffered(to book: Book) -> Bool {
        switch self {
        case .textEncoding: return book.offersTextEncodingChoice
        case .brailleFileCode: return book.offersBrailleFileCodeChoice
        case .brailleTable: return book.offersBrailleTableChoice
        case .brailleFileCodeAndTable: return book.offersBrailleFileCodeChoice && book.offersBrailleTableChoice
        }
    }

    /// The tag that begins the debug log's lines of a re-read of this kind,
    /// its own line and a line naming a file it could not put back.
    var logTag: String {
        switch self {
        case .textEncoding: return LibraryViewModel.textEncodingChangedLogTag
        case .brailleFileCode, .brailleFileCodeAndTable: return LibraryViewModel.brailleFileCodeChangedLogTag
        case .brailleTable: return LibraryViewModel.brailleTableChangedLogTag
        }
    }
}

/// The work a book is marked as being read again for
/// (`TextRereads.begin(_:for:)`), so the sentence that says why something
/// waits names the work under way.
enum TextRereadWork: Equatable, Sendable {
    /// A text book read again in another encoding (Book Information's Text
    /// Encoding pop-up).
    case encoding
    /// A BRF or BRL braille book read again with other braille file
    /// characters (the Braille File Characters pop-up).
    case brailleFileCode
    /// A braille book read again with another braille code (the Braille
    /// Code pop-up).
    case brailleCode
    /// A new copy taking the place of the book (Replace Existing), made
    /// ready off the main actor, which may read it again in the old copy's
    /// reading.
    case replacement

    /// The work a re-read of `choice` is.
    init(_ choice: TextRereadChoice) {
        switch choice {
        case .textEncoding: self = .encoding
        case .brailleFileCode: self = .brailleFileCode
        case .brailleTable, .brailleFileCodeAndTable: self = .brailleCode
        }
    }

    /// Why what would rewrite the text of the book titled `bookTitle` waits
    /// while this work is under way, in full.
    func refusal(bookTitle: String) -> String {
        switch self {
        case .encoding: return TextEncodingWording.readingAgainRefusal(bookTitle: bookTitle)
        case .brailleFileCode: return BrailleFileCodeWording.readingAgainRefusal(bookTitle: bookTitle)
        case .brailleCode: return BrailleCodeWording.readingAgainRefusal(bookTitle: bookTitle)
        case .replacement: return DuplicateCopyWording.replacingRefusal(bookTitle: bookTitle)
        }
    }
}

/// What the work of reading a book's text again, off the main actor, came
/// to (`LibraryViewModel.rereadText(of:as:access:isOpenInReader:)`).
enum TextReread: Sendable {
    /// The text was read again and committed: what the book's package now
    /// records, with the new text for an open reader; what the book is read
    /// in now, in words for VoiceOver (the encoding's description, or the
    /// braille file characters' name), or nil when that could not be learnt;
    /// and the copy kept of text TextMouth did not write, if any.
    case readAgain(TextCacheUpdate, reading: String?, keptCopy: URL?)
    /// Nothing changed, for the reason given, in full.
    case refused(String)
}

extension LibraryViewModel {

    // MARK: Refusals

    /// Why the text of `book` can't be read again now, in full, or nil when
    /// it can, asked for either choice, another encoding or other braille
    /// file characters (`TextRereadChoice`), as far as the library can tell
    /// without looking at the book's files, which are looked at as it is
    /// read (`rereadText(of:as:access:isOpenInReader:)`): a file only in the
    /// cloud, bytes not valid in the encoding chosen, or a file not braille
    /// in the characters chosen.
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
    /// (`readTextAgain(bookID:choosing:access:)`, review of October 24,
    /// finding 6).
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
    /// text again in another encoding or with other braille file characters
    /// (`booksBeingReadAgain`), in full, in the words of the re-read under
    /// way: the book `bookID`'s, or, when nil, any book's, as Redo Text
    /// Extraction asks, since it rewrites every book's text. Nil when no such
    /// re-read is under way. A second re-read of the book, Edit Text, Redo Text
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
        // The work that marked the book names itself (a replacement, a
        // braille code's re-read, ...). A book marked without one (the set
        // assigned directly) is worded by its format: a braille book's by its
        // braille file characters, any other book's by its encoding.
        return busy.map { book in
            let work = textRereads.works[book.id] ?? (book.format == .braille ? .brailleFileCode : .encoding)
            return work.refusal(bookTitle: book.title)
        }
    }

    // MARK: Reading Again

    /// Reads the text of the book `bookID` again from its file as `choice`
    /// says, once the listener has confirmed it in Book Information: a text
    /// book's in one encoding, which the book records as chosen, or
    /// automatically, as an import reads a file, which records the guess, if
    /// it made one, and that the listener chose Automatic (encodingchoice); a
    /// BRF or BRL braille book's with other braille file characters, which
    /// the book records by their code's id (braillecodes). It is one re-read
    /// for both: only whether the book offers the choice, how the choice is
    /// checked against the file, and what the commit records, the debug log
    /// says, and VoiceOver hears differ by the choice.
    ///
    /// It is the one-book form of what Redo Text Extraction does
    /// (`MarkdownCacheService.generateReportedCacheAnalyzeAndStamp`, then
    /// `LibraryPersistenceService.saveContentAnalysis`), with its
    /// protections: the book's places move with the text (T06); a reader
    /// that has the book open shows the new text, its cursor following its
    /// words (ST01); and nothing is downloaded. Text TextMouth did not write
    /// (an Edit Text change, or a save no edit took) is kept beside the new
    /// text first, as Replace Existing keeps it, and VoiceOver hears where.
    /// The analysis and the choice (the encoding, or the braille file
    /// characters) go into the book's record in one write, before the row
    /// takes them.
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
    /// Nothing changes, and why is returned, when the book is not offered
    /// such a choice (`TextRereadChoice.isOffered(to:)`), when it is busy
    /// (`textEncodingChangeRefusal(of:)`), when a file it reads is only in
    /// the cloud, when its bytes are not valid in the encoding chosen, which
    /// is read strictly (`TextFileDecoder.EncodingPolicy.chosen(_:)`), or
    /// its pages are not braille in the characters chosen
    /// (`BrailleBookReader.requireReadable(_:as:)`), when the text TextMouth
    /// did not write cannot be kept, and when the reading fails.
    /// - Returns: `.success` with what VoiceOver was told, or `.failure`
    ///   with why nothing changed, which Book Information shows and
    ///   announces.
    func readTextAgain(
        bookID: UUID,
        choosing choice: TextRereadChoice,
        access: MaintenanceFileAccess = .live
    ) async -> OperationOutcome {
        guard let book = bookByID(bookID) else {
            return .failure(TextEncodingWording.bookGoneRefusal)
        }
        // Book Information offers no such choice for such a book; refused all the same.
        guard choice.isOffered(to: book) else {
            return .failure(TextEncodingWording.failedRefusal(bookTitle: book.title, reason: nil))
        }
        if let refusal = textEncodingChangeRefusal(of: book) {
            return .failure(refusal)
        }
        // The book is busy until its row has the new reading: whatever would
        // rewrite its text meanwhile waits (`readingAgainRefusal(of:)`).
        textRereads.begin(bookID, for: TextRereadWork(choice))
        defer { textRereads.end(bookID) }
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
            Self.rereadText(of: current, as: choice, access: access, isOpenInReader: isOpenInReader)
        }
        switch reread {
        case .refused(let reason):
            if wasEditing, let editor {
                await editor.resumeEditing(of: current)
            }
            return .failure(reason)
        case let .readAgain(update, reading, keptCopy):
            applyTextCacheUpdate(update, atOnce: true)
            // The debug log's lines say what the record now decides, in the
            // choice's own words.
            for line in Self.rereadLogLines(title: book.title, choice: choice, update: update, keptCopy: keptCopy) {
                DiagnosticLog.event(.storage, line)
            }
            let announcement = TextEncodingWording.readAgainAnnouncement(
                bookTitle: book.title, readingDescription: reading, keptCopy: keptCopy, stoppedEditing: wasEditing
            )
            VoiceOverAnnouncer.announce(announcement)
            return .success(announcement)
        }
    }

    /// The work of `readTextAgain(bookID:choosing:access:)` off the main
    /// actor, for `book` as the library held it: every file checked to be on
    /// this Mac; the choice checked against the file before anything is
    /// written (the bytes read strictly in the encoding chosen, or the pages
    /// read with the braille file characters chosen); the text TextMouth did
    /// not write kept; the file read again, with its places moved; and the
    /// analysis committed with what the choice decides (the encoding and who
    /// decided it, or the braille file characters), in one write of the
    /// book's record.
    ///
    /// It is one piece of storage work, from the first read to the commit
    /// (`StorageBoundary.perform`, whose work started inside it, such as the
    /// rebuild's own, is part of it): a folder edit or a data-directory move
    /// that begins meanwhile waits for it to end, so the book's package
    /// never moves between content.md's write and the record's commit
    /// (review of October 24, finding 2).
    nonisolated static func rereadText(
        of book: Book,
        as choice: TextRereadChoice,
        access: MaintenanceFileAccess,
        isOpenInReader: @escaping @Sendable (UUID) -> Bool
    ) -> TextReread {
        let notDownloaded = TextReread.refused(LibraryCloudWording.notDownloaded(titles: [book.title]))
        return StorageBoundary.shared.perform(.textExtraction) { _ in
            // Its paths in the data directory in use now, should a move have
            // published while the work waited to begin.
            let book = StorageBoundary.shared.rebasedToCurrent(book)
            guard access.fileInCloud(of: book, reading: .all) == nil else { return notDownloaded }
            do {
                return try access.read(book.bookFileURL) {
                    try rereadFiles(of: book, as: choice, access: access, isOpenInReader: isOpenInReader)
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
    /// contentIndex.json is put back the same way when the commit wrote it
    /// before bookInfo.json failed (`BookInfo.saveRecord(to:)` writes the
    /// index first), so the package keeps a text and an index that match
    /// (review of October 25, item 4).
    /// - Throws: why the book was not read again; `CommitDropped` when the
    ///   record took nothing (`LibraryPersistenceService.saveContentAnalysis`).
    private nonisolated static func rereadFiles(
        of book: Book,
        as choice: TextRereadChoice,
        access: MaintenanceFileAccess,
        isOpenInReader: @Sendable (UUID) -> Bool
    ) throws -> TextReread {
        // 1. The choice checked against the file before anything is written,
        // then set on the book to be read again, as its row will hold it.
        // The read decides (`decidingEncoding`), so it reads as this book
        // says, never as the decision the record holds, which it replaces.
        var updated = book
        var chosen: TextEncodingRecord?
        switch choice {
        case .textEncoding(let option):
            // The encoding chosen, read strictly; Automatic sets none, and
            // the read guesses as an import does.
            if option != .automatic {
                guard let validated = try validatedChoice(of: option, for: book) else {
                    return .refused(TextEncodingWording.notValidRefusal(
                        bookTitle: book.title, encoding: TextEncodingChoices.name(of: option)
                    ))
                }
                chosen = validated
            }
            updated.textEncodingRecord = chosen ?? .unrecorded
        case .brailleFileCode(let code):
            if let refusal = try settingBrailleFileCode(code, on: &updated, of: book) { return refusal }
        case .brailleTable(let table):
            settingBrailleTable(table, on: &updated)
        case .brailleFileCodeAndTable(let code, let table):
            // One re-read for both: the file checked in the code chosen, then
            // both set on the book to be read again.
            if let refusal = try settingBrailleFileCode(code, on: &updated, of: book) { return refusal }
            settingBrailleTable(table, on: &updated)
        }
        // 2. Text TextMouth did not write, kept beside the new text, the
        // copies already there noted first.
        let copiesBefore = Set(keptTextCopies(of: book))
        let keptCopy = try keptUnwrittenText(of: book, access: access)
        // 3. The file read again, as chosen, or as an import reads it, with
        // content.md and contentIndex.json as they are now kept to be put
        // back.
        let cacheURL = MarkdownCacheService.cacheURL(for: book)
        let textBefore = PackageFileBeforeInstall(cacheURL)
        let indexBefore = PackageFileBeforeInstall(TextMouthPaths.contentIndexPath(in: book.tmbDirectory))
        guard let generated = try MarkdownCacheService.generateReportedCacheAnalyzeAndStamp(
            for: &updated, replacingEditedText: true, decidingEncoding: true
        ) else {
            return .refused(TextEncodingWording.failedRefusal(bookTitle: book.title, reason: nil))
        }
        let textWritten = generated.content.contentIndex.textCacheFingerprint?.cache.stamp ?? FileStamp(of: cacheURL)
        do {
            // What the record takes as decided, with the analysis: the
            // encoding and who decided it, or the braille file characters.
            let decidedEncoding: TextEncodingRecord?
            let decidedCode: String?
            let decidedTable: LibraryPersistenceService.BrailleTableDecision?
            switch choice {
            case .textEncoding:
                // Automatic records its guess, if it made one, and that the
                // listener chose Automatic, so no older choice in the record
                // comes back in place of nothing (`TextEncodingSource`).
                let record = chosen ?? TextEncodingRecord(identifier: updated.textEncoding, source: .automatic)
                updated.textEncodingRecord = record
                decidedEncoding = record
                decidedCode = nil
                decidedTable = nil
            case .brailleFileCode(let code):
                decidedEncoding = nil
                decidedCode = code.id
                decidedTable = nil
            case .brailleTable(let table):
                // The table and the version it was read under, as the
                // reading above recorded them on the book.
                decidedEncoding = nil
                decidedCode = nil
                decidedTable = .init(table: table.id, version: updated.brailleTableVersion)
            case .brailleFileCodeAndTable(let code, let table):
                // Both, in the one write.
                decidedEncoding = nil
                decidedCode = code.id
                decidedTable = .init(table: table.id, version: updated.brailleTableVersion)
            }
            // A file that went to the cloud meanwhile may have been read in
            // part, so nothing is committed from it.
            try access.requireOnThisMac(book, reading: .all)
            guard let committed = try LibraryPersistenceService.saveContentAnalysis(
                for: updated,
                index: generated.content.contentIndex,
                cacheFormatVersion: MarkdownCacheService.currentCacheVersion,
                movedPlaces: generated.movedPlaces,
                pageReaderVersion: .some(generated.pageReaderVersion),
                textEncoding: decidedEncoding,
                brailleFileCode: decidedCode,
                brailleTable: decidedTable
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
            // The copy VoiceOver hears of is the one kept last, which holds
            // the newest text: a save made after the copy above, which the
            // rebuild kept as a second (review of October 25, item 5).
            let lastKept = keptTextCopies(of: book).last { !copiesBefore.contains($0) } ?? keptCopy
            // What it is read in now, in words, for VoiceOver to say: the
            // encoding as the book's record and file now say it, nil when
            // that can't be learnt; or the braille file characters' name.
            let reading: String?
            switch choice {
            case .textEncoding:
                if case .known(let encoding) = TextEncodingReading.current(of: committed, access: access) {
                    reading = encoding.description
                } else {
                    reading = nil
                }
            case .brailleFileCode(let code):
                reading = code.name
            case .brailleTable(let table):
                reading = BrailleTableCatalog.description(ofTableID: table.id)
            case .brailleFileCodeAndTable(let code, let table):
                reading = "\(code.name), \(BrailleTableCatalog.description(ofTableID: table.id))"
            }
            return .readAgain(update, reading: reading, keptCopy: lastKept)
        } catch {
            // The places' copy of the old text stays with the places, for
            // the launch's place recovery, which moves nothing to the same
            // text and then lets it go, as after any dropped commit. The
            // index's stamp now is the one the commit's write left, or the
            // one it had when the commit never wrote it, which puts nothing
            // back.
            PackageFileBeforeInstall.putBack(
                [(textBefore, textWritten), (indexBefore, FileStamp(of: indexBefore.url))],
                of: book, after: "the re-read", logTag: choice.logTag
            )
            throw error
        }
    }

    /// Sets the braille file characters `code` on `updated`, the book to be
    /// read again, after checking that the file's pages read with them: the
    /// refusal is the reader's own sentence, and any other error passes on,
    /// as the encoding's does. The code is set by its id, North American
    /// Braille ASCII's included, never nil, so the record's decision stands
    /// over a row that lags behind it (`BrailleFileCodeRecord.standing(row:recorded:)`).
    /// - Returns: the refusal when the file is not braille in `code`, else nil.
    private nonisolated static func settingBrailleFileCode(
        _ code: BrailleFileCode, on updated: inout Book, of book: Book
    ) throws -> TextReread? {
        do {
            try BrailleBookReader.requireReadable(book.bookFileURL, as: code)
        } catch let error as BrailleFileError {
            return .refused(BrailleFileCodeWording.notReadableRefusal(
                bookTitle: book.title, codeName: code.name, reason: error.localizedDescription
            ))
        }
        updated.brailleFileCode = code.id
        return nil
    }

    /// Sets the braille table `table` on `updated`, the book to be read
    /// again, as an import sets it: its stored value, and the liblouis
    /// version of this Mac's tables for one of them
    /// (`BrailleTableCatalog.versionToRecord(forTable:)`), so the reading
    /// checks that the Mac's tables are the ones it was made with. Nothing
    /// is checked beforehand: any braille translates to print in any table,
    /// and a table that cannot be used (one a macOS update removed) fails the
    /// reading, before anything is written.
    private nonisolated static func settingBrailleTable(_ table: BrailleTable, on updated: inout Book) {
        updated.brailleTable = table.id
        updated.brailleTableVersion = BrailleTableCatalog.versionToRecord(forTable: table.id)
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

    /// The copies kept beside `book`'s content.md of text TextMouth did not
    /// write, oldest first (`LibraryIndexQuarantine.existingCopies`).
    private nonisolated static func keptTextCopies(of book: Book) -> [URL] {
        LibraryIndexQuarantine.existingCopies(of: MarkdownCacheService.cacheURL(for: book), marker: TextMouthPaths.keptTextCopyMarker)
    }

    /// The bytes of `book`'s content.md when they hold text TextMouth did not
    /// write, which a re-read keeps beside the new reading: an Edit Text
    /// change, or a save no edit took
    /// (`DuplicateReplacement.holdsUnwrittenText(_:of:hasher:)`). Nil when
    /// there is no such text, or no content.md. Read through `access`, so a
    /// content.md only in the cloud is never downloaded for it; the
    /// confirmation asks it too, to say whether a copy will be kept
    /// (`rereadPreflight(of:access:)`).
    /// - Throws: why content.md could not be read.
    nonisolated static func unwrittenText(of book: Book, access: MaintenanceFileAccess) throws -> Data? {
        let cacheURL = MarkdownCacheService.cacheURL(for: book)
        guard FileStamp(of: cacheURL) != nil else { return nil }
        let bytes = try access.read(cacheURL) { try Data(contentsOf: cacheURL) }
        return DuplicateReplacement.holdsUnwrittenText(bytes, of: book, hasher: access.hasher) ? bytes : nil
    }

    /// The debug log's lines for the book titled `title` read again as
    /// `choice` says, which `update` committed and which kept `keptCopy` of
    /// text TextMouth did not write: a text book's
    /// (`textEncodingLogLine(title:record:keptCopy:)`, none when the commit
    /// recorded no encoding), or a braille book's, one for its braille file
    /// characters (`brailleFileCodeLogLine(title:code:keptCopy:)`) and one
    /// for its table (`brailleTableLogLine(title:table:keptCopy:)`), both
    /// when both were chosen, the kept copy named in the first. One place
    /// for the re-read of Book Information and the one Replace Existing
    /// makes of the new copy (`DuplicateReplacement`).
    nonisolated static func rereadLogLines(
        title: String, choice: TextRereadChoice, update: TextCacheUpdate, keptCopy: URL?
    ) -> [String] {
        switch choice {
        case .textEncoding:
            return update.summary.map { [textEncodingLogLine(title: title, record: $0.textEncodingRecord, keptCopy: keptCopy)] } ?? []
        case .brailleFileCode(let code):
            return [brailleFileCodeLogLine(title: title, code: code, keptCopy: keptCopy)]
        case .brailleTable(let table):
            return [brailleTableLogLine(title: title, table: table, keptCopy: keptCopy)]
        case .brailleFileCodeAndTable(let code, let table):
            return [
                brailleFileCodeLogLine(title: title, code: code, keptCopy: keptCopy),
                brailleTableLogLine(title: title, table: table, keptCopy: nil),
            ]
        }
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
        return line + keptCopyClause(keptCopy)
    }

    /// The tag that begins the log line of a book read again in another
    /// encoding.
    nonisolated static let textEncodingChangedLogTag = "TEXT_ENCODING_CHANGED"

    /// The debug log's line for a braille book read again with other braille
    /// file characters (braillecodes): the title, the id of the code it
    /// records, and where text TextMouth did not write was kept, as
    /// `BRAILLE_FILE_CODE_CHANGED: Ledger: read again with ascii-eurobraille`.
    nonisolated static func brailleFileCodeLogLine(title: String, code: BrailleFileCode, keptCopy: URL?) -> String {
        "\(brailleFileCodeChangedLogTag): \(title): read again with \(code.id)" + keptCopyClause(keptCopy)
    }

    /// The tag that begins the log line of a braille book read again with
    /// other braille file characters.
    nonisolated static let brailleFileCodeChangedLogTag = "BRAILLE_FILE_CODE_CHANGED"

    /// The debug log's line for a braille book read again with another
    /// braille table (its braille code): the title, the stored value of the
    /// table it records, and where text TextMouth did not write was kept, as
    /// `BRAILLE_TABLE_CHANGED: Ledger: read again with en-ueb-g1.ctb`.
    nonisolated static func brailleTableLogLine(title: String, table: BrailleTable, keptCopy: URL?) -> String {
        "\(brailleTableChangedLogTag): \(title): read again with \(table.id)" + keptCopyClause(keptCopy)
    }

    /// The tag that begins the log line of a braille book read again with
    /// another braille table.
    nonisolated static let brailleTableChangedLogTag = "BRAILLE_TABLE_CHANGED"

    /// What a re-read's log line ends with: where text TextMouth did not
    /// write was kept, by the copy's name, as "; its earlier text was kept as
    /// content.md.edited-20261024T120000Z", or nothing when none was.
    private nonisolated static func keptCopyClause(_ keptCopy: URL?) -> String {
        keptCopy.map { "; its earlier text was kept as \($0.lastPathComponent)" } ?? ""
    }
}

/// Why a book was not read again: the text TextMouth did not write could not
/// be kept beside the new reading.
private struct UnwrittenTextNotKept: Error {}

/// Why a book was not read again: its record took nothing, as when its file
/// was replaced or moved meanwhile, so content.md is put back.
private struct CommitDropped: Error {}

// MARK: - Re-reads Under Way

/// The books whose text is being read again, in another encoding, with
/// other braille file characters, or with another braille code, or whose
/// copy is being replaced by a new one, app-wide: from the listener's
/// confirmation until the library row has the new reading
/// (`LibraryViewModel.readTextAgain(bookID:choosing:access:)`, which marks
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
            // The work of a book that is no longer being read again is forgotten.
            if works.keys.contains(where: { !bookIDs.contains($0) }) {
                works = works.filter { bookIDs.contains($0.key) }
            }
            resumeWaitersWhoMayGoOn()
        }
    }

    /// What each book in `bookIDs` is being read again for, when the work
    /// that marked it said (`begin(_:for:)`): the busy sentence names it
    /// (`LibraryViewModel.readingAgainRefusal(of:)`). A book marked without
    /// (`bookIDs` set directly) has none, and is worded by its format.
    private(set) var works: [UUID: TextRereadWork] = [:]

    /// Marks the book `bookID` as being read again for `work`.
    func begin(_ bookID: UUID, for work: TextRereadWork) {
        works[bookID] = work
        bookIDs.insert(bookID)
    }

    /// Marks the book `bookID` as no longer being read again.
    func end(_ bookID: UUID) {
        bookIDs.remove(bookID)
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
            longestWait: longestWait,
            kind: "text re-reads",
            finishing: {
                let count = self.bookIDs.count
                return count == 1
                    ? "reading a book's text again in another encoding"
                    : "reading the text of \(count) books again in another encoding"
            }
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

import SwiftUI

/// The questions imports ask the user (TODO I01): whether to replace or keep
/// a duplicate, whether to delete an original file, and whether to put a ZIP
/// archive's books in a new folder.
///
/// Imports finish one after another off the main thread and go on while a
/// question waits, so every question is queued in `importDecisions`, holding
/// everything its answer acts on, and asked one at a time in order. An
/// answer reaches only the question it was given to
/// (`answerImportDecision(_:with:)`): that question's own books and files,
/// captured when its import finished, and its own request to open the book.
/// Cancelling a question settles that question alone; the import overlay's
/// Cancel withdraws every question of the batch it stops
/// (`withdrawCancelledImportDecisions()`).
extension LibraryViewModel {

    /// How a duplicate's new copy that cannot be discarded is reported.
    private static let discardFailureContext = "Could not discard duplicate import"

    // MARK: - Asking

    /// Asks `decision` once every question queued before it is settled. A
    /// question whose batch was cancelled is withdrawn at once instead,
    /// unasked (`withdraw(_:)`).
    func ask(_ decision: ImportDecision) {
        guard !decision.request.isCancelled else {
            withdraw(decision)
            return
        }
        importDecisions.enqueue(decision)
    }

    /// The words the question sheet shows, and VoiceOver speaks, for the
    /// question being asked; nil while none is. A duplicate names the copy
    /// it matches now, and an original file's question follows the Trash
    /// preference in force, which its deletion reads too.
    var currentImportDecisionWording: ImportDecisionWording? {
        guard let decision = importDecisions.current else { return nil }
        var matchingTitle: String?
        if case .duplicate(let duplicate) = decision.kind {
            matchingTitle = duplicateMatch(for: duplicate.book)?.title
        }
        return ImportDecisionWording(
            for: decision,
            position: importDecisions.position,
            total: importDecisions.total,
            matchingTitle: matchingTitle,
            movesToTrash: removalPreferences.movesToTrash
        )
    }

    // MARK: - Duplicate Detection

    /// The books Find Duplicate Books scans: the library's own, never a
    /// feed's items (FR11), which belong to their feed, where one file may
    /// come from two shows.
    var booksForDuplicateScan: [Book] {
        library.libraryBooks
    }

    /// The book in the library that `book` is a copy of: one with the same
    /// file content, or failing that one imported from the same source path.
    /// Nil when the library holds no copy.
    func duplicateMatch(for book: Book) -> Book? {
        /// Whether `existing` was imported from the same source path as `book`.
        func isFromSameSource(_ existing: Book) -> Bool {
            guard let sourcePath = book.sourceFilePath, !sourcePath.isEmpty else { return false }
            return existing.sourceFilePath == sourcePath
        }
        // Only the library's own books: a feed's item may carry the same file
        // as a book, as two shows can carry one file (FR11).
        let others = library.libraryBooks.lazy.filter { $0.id != book.id }
        return others.first { $0.md5Hash == book.md5Hash } ?? others.first(where: isFromSameSource)
    }

    /// Adds `book` to the library or, when the library already holds a copy
    /// of it, queues the question whether to replace that copy, keep both,
    /// or discard the new one.
    ///
    /// - Parameters:
    ///   - originalURL: The file the book was imported from, which the
    ///     "After Importing a Book" preference may delete once the book is
    ///     kept; nil when it must stay.
    ///   - warning: What the new book is missing, told with the question
    ///     when one is needed.
    ///   - request: What the book's import was asked to do.
    /// - Returns: Whether the book was added now; false when its question
    ///   was queued instead.
    @discardableResult
    func addBookCheckingDuplicate(
        _ book: Book,
        originalURL: URL? = nil,
        warning: String? = nil,
        request: ImportRequest = ImportRequest()
    ) -> Bool {
        if let existing = duplicateMatch(for: book) {
            let duplicate = ImportDecision.DuplicateBook(
                book: book,
                existing: existing,
                originalURL: originalURL,
                warning: warning
            )
            ask(ImportDecision(kind: .duplicate(duplicate), request: request))
            return false
        }
        library.addBook(book)
        return true
    }

    // MARK: - Once a Book Is in the Library

    /// The question "After Importing a Book" raises about `url`, the original
    /// file of the book `bookID` (nil for a ZIP archive's books) just added
    /// to the library, carrying `request`. Nil when there is no file, when
    /// the preference keeps it, or when it deletes it now, which this does.
    func originalFileQuestion(for url: URL?, of bookID: UUID?, request: ImportRequest) -> ImportDecision? {
        guard let url else { return nil }
        switch configService.config.importDeleteBehavior {
        case .keepOriginal:
            return nil
        case .deleteAfterImport:
            deleteOriginalFile(at: url)
            return nil
        case .askEachTime:
            return ImportDecision(kind: .originalFile(.init(url: url, bookID: bookID)), request: request)
        }
    }

    /// Finishes `book`, just added to the library from `originalURL`: applies
    /// the "After Importing a Book" preference to the original, then opens
    /// the book when `request` asked for that. A question about the original
    /// is asked first, and the book opens once it is answered.
    ///
    /// - Parameter followingAnswer: Whether answering the current question
    ///   added the book: that question is settled here, and the question
    ///   about the same file's original is asked next, before every other
    ///   question waiting. Otherwise an import added the book directly, and
    ///   its question waits behind the others.
    func finishAddedBook(_ book: Book, originalURL: URL?, request: ImportRequest, followingAnswer: Bool = false) {
        let question = originalFileQuestion(for: originalURL, of: book.id, request: request)
        if followingAnswer {
            importDecisions.settleCurrent(followedBy: question)
        } else if let question {
            ask(question)
        }
        offerTranscription(of: book, request: request)
        if question == nil {
            openAfterImport(book.id, request: request)
        }
    }

    /// Asks whether to transcribe `book`, just added to the library by an
    /// import made with `request`, when the import offers that (FR05): an
    /// audiobook, while "Offer to transcribe after importing an audiobook"
    /// is on. The offer waits behind every question already waiting, so it
    /// follows the import's own; it never holds up the book's opening.
    func offerTranscription(of book: Book, request: ImportRequest) {
        guard offersTranscription(book) else { return }
        ask(TranscriptionOffers.question(for: book, request: request))
    }

    /// Opens the reader of `bookID`, a book an import added, when `request`
    /// asked for that, its batch was not cancelled, and the book is still in
    /// the library.
    func openAfterImport(_ bookID: UUID?, request: ImportRequest) {
        guard let bookID,
              request.opensAfterImport,
              !request.isCancelled,
              library.books.contains(where: { $0.id == bookID }) else { return }
        readerOpener(bookID)
    }

    // MARK: - Answering

    /// Answers the question `id` with `answer`, when it is the question being
    /// asked and takes that answer. The answer acts on that question's own
    /// books and files, then the question is settled and the next is asked.
    ///
    /// - Returns: What happened. After a failure the question is still being
    ///   asked, and the outcome says why, for its sheet to show beside the
    ///   choices. An answer to a question no longer being asked, such as a
    ///   second press of a button whose question was just settled, does
    ///   nothing and succeeds, so it can never land on the next question.
    ///   An answer given while the library moves is refused, and the
    ///   question waits for one once the move ends.
    @discardableResult
    func answerImportDecision(_ id: ImportDecision.ID, with answer: ImportDecisionAnswer) -> OperationOutcome {
        guard let decision = importDecisions.current,
              decision.id == id,
              answer.fits(decision.kind) else {
            return .success(nil)
        }
        // No answer acts while the library moves. A window shows one sheet
        // at a time, so a Library window already asking this question when
        // the move began keeps asking it instead of showing the move, and
        // its answer would change the library as it is copied: Replace
        // Existing, for one, would delete the library's copy from the old
        // data directory after the copy took it, leaving a stray package in
        // the new one. The question stays, to be answered once the move ends.
        guard dataDirectoryMove == nil else {
            return .failure(DataDirectoryMoveWording.importAnswerRefusal)
        }
        switch decision.kind {
        case .duplicate(let duplicate):
            return settle(duplicate, of: decision, with: answer)
        case .originalFile(let original):
            return settle(original, of: decision, with: answer)
        case .zipFolder(let batch):
            return settle(batch, with: answer)
        case .transcriptionOffer(let offer):
            return settle(offer, of: decision, with: answer)
        }
    }

    /// Answers an offer to transcribe an audiobook just imported (FR05):
    /// Transcribe hands the book to the Library window that asked, which
    /// opens the Transcribe Audio sheet for it and starts once it can; Not
    /// Now leaves the book as it is. A book that left the library meanwhile
    /// is not transcribed.
    private func settle(
        _ offer: ImportDecision.TranscriptionOffer,
        of decision: ImportDecision,
        with answer: ImportDecisionAnswer
    ) -> OperationOutcome {
        importDecisions.settleCurrent()
        if answer == .transcribe, bookByID(offer.bookID) != nil {
            acceptedTranscriptionOffers.send(TranscriptionOfferAcceptance(
                bookID: offer.bookID,
                origin: decision.request.origin
            ))
        }
        return .success(nil)
    }

    /// Answers a duplicate's question. Replace removes the library's copy
    /// that matches now, which an earlier answer may have changed since the
    /// question arose, and adds the new copy, which takes the old copy's
    /// place on the reading list (FR09); Keep Both adds it beside the old
    /// one; either then follows the "After Importing a Book" preference for
    /// the new copy's original and opens the book when its import asked.
    /// Cancel discards the new copy, which leaves its original alone.
    private func settle(
        _ duplicate: ImportDecision.DuplicateBook,
        of decision: ImportDecision,
        with answer: ImportDecisionAnswer
    ) -> OperationOutcome {
        switch answer {
        case .replaceExisting:
            if let existing = duplicateMatch(for: duplicate.book) {
                do {
                    try FileImportService.deleteBookPackage(existing)
                } catch {
                    return .failure("Could not replace duplicate", error)
                }
                // The new copy has an ID of its own: it takes the old copy's
                // place on the list before the old copy leaves the library,
                // which would take that place off the list.
                library.readingList.replace(existing.id, with: duplicate.book.id)
                removeDeletedBook(existing)
            }
        case .keepBoth:
            break
        case .cancel:
            do {
                try FileImportService.deleteBookPackage(duplicate.book)
            } catch {
                return .failure(Self.discardFailureContext, error)
            }
            importDecisions.settleCurrent()
            return .success(nil)
        case .deleteOriginal, .createFolder, .transcribe:
            // A duplicate does not take these (`ImportDecisionAnswer.fits`).
            return .success(nil)
        }
        // `Library.addBook` refuses a second copy of the same content, which
        // Keep Both asks for, and which Replace still meets when the library
        // held two copies: the new copy joins directly.
        library.books.append(duplicate.book)
        save()
        // Imported at the Reading List, the copy joins the list's end, unless
        // Replace already gave it the old copy's place there.
        addImportedBooksToReadingList([duplicate.book], request: decision.request)
        finishAddedBook(duplicate.book, originalURL: duplicate.originalURL, request: decision.request, followingAnswer: true)
        return .success(nil)
    }

    /// Answers an original file's question: deletes the file, or keeps it.
    /// A deletion that fails is reported to the failure center with a retry
    /// (TODO S09) rather than held against the question. Either way the book
    /// is in the library, so it opens now when its import asked for that.
    private func settle(
        _ original: ImportDecision.OriginalFile,
        of decision: ImportDecision,
        with answer: ImportDecisionAnswer
    ) -> OperationOutcome {
        if answer == .deleteOriginal {
            deleteOriginalFile(at: original.url)
        }
        importDecisions.settleCurrent()
        openAfterImport(original.bookID, request: decision.request)
        return .success(nil)
    }

    /// Answers a ZIP archive's folder question: moves its books into a new
    /// folder, or leaves them where they are. A folder that cannot be made
    /// keeps the question open, with the reason, so another name can be
    /// tried.
    private func settle(_ batch: ImportDecision.ZipBatch, with answer: ImportDecisionAnswer) -> OperationOutcome {
        if case .createFolder(let name) = answer {
            let outcome = moveBooks(of: batch, intoNewFolderNamed: name)
            guard outcome.succeeded else { return outcome }
        }
        importDecisions.settleCurrent()
        return .success(nil)
    }

    /// Moves the books `batch` added, those still in the library, into a new
    /// folder named `name` inside the folder they were imported into. A name
    /// the library refuses changes nothing and says why; a move that fails is
    /// rolled back (`commitLibraryTransition`).
    private func moveBooks(of batch: ImportDecision.ZipBatch, intoNewFolderNamed name: String) -> OperationOutcome {
        var proposed = library
        let folder: BookFolder
        do {
            folder = try proposed.createFolderThrowing(name: name, parentPath: batch.folderPath)
        } catch {
            return Self.outcome(refusing: error, context: "Could not create folder")
        }
        // Books are told apart by ID: keeping both copies of a book is
        // allowed, so its content cannot tell which copy this archive added.
        let affectedIDs = Set(batch.books.map(\.id))
        for index in proposed.books.indices where affectedIDs.contains(proposed.books[index].id) {
            proposed.books[index].folderPath = folder.fullPath
        }
        do {
            try TextMouthPaths.ensureLibrarySubfolder(folder.fullPath)
            try commitLibraryTransition(proposed, affectedBookIDs: affectedIDs)
            return .success(nil)
        } catch {
            return .failure("Could not organize imported ZIP books", error)
        }
    }

    // MARK: - Withdrawing

    /// Withdraws every waiting question whose batch was cancelled, the one
    /// being asked included, as the import overlay's Cancel does for the
    /// batch it stops; the questions of later imports stay in their order.
    func withdrawCancelledImportDecisions() {
        for decision in importDecisions.withdrawAll(where: { $0.request.isCancelled }) {
            withdraw(decision)
        }
    }

    /// Withdraws `decision` unasked, as Cancel answers it but opening
    /// nothing: a duplicate's new copy is discarded, an original file is
    /// kept, and a ZIP archive's books stay where they are. A copy that
    /// cannot be discarded is reported through the library's alert.
    private func withdraw(_ decision: ImportDecision) {
        guard case .duplicate(let duplicate) = decision.kind else { return }
        do {
            try FileImportService.deleteBookPackage(duplicate.book)
        } catch {
            presentFilesystemError(Self.discardFailureContext, error: error)
        }
    }

    // MARK: - Deleting an Original

    /// Deletes `url`, the original file of a book just imported, to the
    /// Trash or permanently as "Move to Trash instead of deleting" chooses
    /// (TODO S09). A deletion that fails is reported to the failure center
    /// with the file's path, in the words of that mode, and with a retry, so
    /// a file left behind is never taken for one removed; one that succeeds
    /// settles an earlier failure for the file. Leaving a file behind loses
    /// nothing, so such a failure never holds up quitting.
    ///
    /// - Parameters:
    ///   - url: The original file.
    ///   - delete: Removes the file; tests replace it, so nothing they do
    ///     reaches the real Trash. Its retry removes the same way.
    func deleteOriginalFile(
        at url: URL,
        using delete: @escaping @MainActor @Sendable (URL) throws -> Void = { url in
            try FileImportService.deleteOriginalFile(at: url)
        }
    ) {
        let movesToTrash = removalPreferences.movesToTrash
        do {
            try delete(url)
            failureCenter.recordSuccess(.originalFile(url.path))
        } catch {
            failureCenter.recordFailure(
                .originalFile(path: url.path, movesToTrash: movesToTrash),
                path: url.path,
                error: error
            ) { [weak self] _ in
                self?.deleteOriginalFile(at: url, using: delete)
            }
        }
    }
}

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
        var match: Book?
        if case .duplicate(let duplicate) = decision.kind {
            match = duplicateMatch(for: duplicate.book)
        }
        return ImportDecisionWording(
            for: decision,
            position: importDecisions.position,
            total: importDecisions.total,
            matchingTitle: match?.title,
            matchingFormat: match?.format,
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
    /// - Parameters:
    ///   - followingAnswer: Whether answering the current question added the
    ///     book: that question is settled here, and the question about the
    ///     same file's original is asked next, before every other question
    ///     waiting. Otherwise an import added the book directly, and its
    ///     question waits behind the others.
    ///   - offeringTranscription: Whether an audiobook is offered for
    ///     transcription, as every import offers one, except a replaced book
    ///     that kept its transcript (ST04).
    func finishAddedBook(
        _ book: Book,
        originalURL: URL?,
        request: ImportRequest,
        followingAnswer: Bool = false,
        offeringTranscription: Bool = true
    ) {
        let question = originalFileQuestion(for: originalURL, of: book.id, request: request)
        if followingAnswer {
            importDecisions.settleCurrent(followedBy: question)
        } else if let question {
            ask(question)
        }
        if offeringTranscription {
            offerTranscription(of: book, request: request)
        }
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

    /// Answers a duplicate's question. Replace puts the new copy in the place
    /// of the library's copy that matches now, as that same book
    /// (`replaceExisting(with:of:)`, ST04); Keep Both adds it beside the old
    /// one (`keep(_:of:)`); either then follows the "After Importing a Book"
    /// preference for the new copy's original and opens the book when its
    /// import asked. Cancel discards the new copy, which leaves its original
    /// alone.
    private func settle(
        _ duplicate: ImportDecision.DuplicateBook,
        of decision: ImportDecision,
        with answer: ImportDecisionAnswer
    ) -> OperationOutcome {
        switch answer {
        case .replaceExisting:
            return replaceExisting(with: duplicate, of: decision)
        case .keepBoth:
            keep(duplicate, of: decision)
            return .success(nil)
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
    }

    /// Keeps a duplicate's new copy as a book of its own, beside the copy
    /// it matched, as Keep Both does, and as Replace does once no copy
    /// matches any more.
    private func keep(_ duplicate: ImportDecision.DuplicateBook, of decision: ImportDecision) {
        // `Library.addBook` refuses a second copy of the same content, which
        // Keep Both asks for: the new copy joins directly.
        library.books.append(duplicate.book)
        save()
        finishKeeping(duplicate.book, from: duplicate, of: decision)
    }

    /// Finishes keeping `book`, the book a duplicate's answer left in the
    /// library: imported at the Reading List, it joins the list's end,
    /// unless it already has a place there, as a replaced book keeps its
    /// own; then the question about its original is asked, and the book
    /// opened, as its import asked. An audiobook is offered for
    /// transcription while `offeringTranscription`.
    private func finishKeeping(
        _ book: Book,
        from duplicate: ImportDecision.DuplicateBook,
        of decision: ImportDecision,
        offeringTranscription: Bool = true
    ) {
        addImportedBooksToReadingList([book], request: decision.request)
        finishAddedBook(
            book,
            originalURL: duplicate.originalURL,
            request: decision.request,
            followingAnswer: true,
            offeringTranscription: offeringTranscription
        )
    }

    // MARK: - Replacing (ST04)

    /// How a replacement that could not go ahead is reported.
    private static let replaceFailureContext = "Could not replace duplicate"

    /// Answers Replace Existing (ST04): the new copy takes the place of the
    /// library's copy that matches now, which an earlier answer may have
    /// changed since the question arose, as that same book, with its ID,
    /// places, bookmarks, settings, folder, place on the reading list, and,
    /// for the same audio, its transcript (`DuplicateReplacement`). Once no
    /// copy matches, the new copy joins as Keep Both adds it.
    ///
    /// The library's copy is left as it is, and the question stays, saying
    /// why, while the copy is in use (`replacementRefusal(of:)`), while
    /// something carried over is only in the cloud, and when the new copy
    /// cannot be committed; the new copy's package is then as its import
    /// left it.
    ///
    /// The old copy's package goes only once the new copy is committed:
    /// its record, with the carried state under the kept ID, and then the
    /// library's index naming it, are on disk first. A stop at any moment
    /// leaves either the old book whole, or the new copy with everything
    /// carried over; an old package a stop leaves behind names a listed
    /// book, so the launch never adopts it as a second row of the same ID
    /// (`FileImportService.adoptOrphanedTMBPackages`). Once committed, the
    /// replacement stands: an old package that cannot be removed then is
    /// reported, and stays (`removeReplacedPackage(of:)`).
    private func replaceExisting(
        with duplicate: ImportDecision.DuplicateBook,
        of decision: ImportDecision
    ) -> OperationOutcome {
        guard let match = duplicateMatch(for: duplicate.book) else {
            keep(duplicate, of: decision)
            return .success(nil)
        }
        if let refusal = replacementRefusal(of: match) {
            return .failure(refusal.sentence)
        }
        // Analyses of the old copy waiting in the buffer reach its row now,
        // while the row is the old copy's. One still on its way (on the main
        // queue, or running) can arrive after the replacement: it names the
        // old package, which the new row's is not, so it never lands there
        // (`applyAnalysisSummaries`).
        analysisSummaries.flush()
        let existing = bookByID(match.id) ?? match
        let preparation: DuplicateReplacement.Preparation
        do {
            preparation = try DuplicateReplacement.prepare(replacing: existing, with: duplicate.book)
        } catch let refusal as DuplicateReplacement.Refusal {
            return .failure(refusal.sentence)
        } catch {
            return .failure(Self.replaceFailureContext, error)
        }
        do {
            try commitReplacement(of: existing, by: preparation)
        } catch {
            preparation.undo()
            // The new copy's record names the import's own ID again, should
            // the record have been written before the index failed.
            try? duplicate.book.saveBookInfoThrowing()
            return .failure(Self.replaceFailureContext, error)
        }
        removeReplacedPackage(of: existing)
        if let keptText = preparation.keptText {
            // Where the old copy's text went is said aloud, as every other
            // path that keeps such a copy says it: after the answer's own
            // words rather than over them.
            VoiceOverAnnouncer.announce(
                DuplicateReplacement.keptTextAnnouncement(title: existing.title, copy: keptText),
                priority: .medium
            )
        }
        finishKeeping(preparation.book, from: duplicate, of: decision, offeringTranscription: !preparation.keptTranscript)
        return .success(nil)
    }

    /// Why Replace Existing waits for `existing`, the library's copy of a
    /// duplicate, or nil when it need not: the copy is open in a reader,
    /// whose saves of places in the old text would reach the new copy under
    /// the same ID; being transcribed or exported, work that reads the old
    /// copy's files and would lose what it makes (`feedBookUse(of:)`, the
    /// uses a feed download's deletion refuses); or its audio is being
    /// edited, or saved from the audio editor. Nor does it go ahead while
    /// another operation holds the library's storage work, as a folder edit
    /// does while it moves packages off the main thread: the replacement
    /// would carry nothing from a package moved meanwhile, and its record
    /// would be written into the old package's new place (ST04 review,
    /// finding 5).
    func replacementRefusal(of existing: Book) -> DuplicateReplacement.Refusal? {
        if let held = StorageBoundary.shared.heldFor {
            return .storageBusy(held)
        }
        if let use = feedBookUse(of: existing.id) {
            return .inUse(use, title: existing.title)
        }
        if audioEditActivity.isBeingEdited(existing.id) {
            return .audioBeingEdited(title: existing.title)
        }
        return nil
    }

    /// Commits `preparation.book`, the new copy, in the place of `existing`,
    /// whose package is still where it was: in its row, so the library's
    /// order and the reading list, which name the book by its ID, keep it.
    ///
    /// Each step reaches the disk before the next: whatever waits to be
    /// written of the old copy goes into its own package, so nothing queued
    /// for the ID lands after the new record; then the new copy's record,
    /// with the carried state under the kept ID; then the library's index
    /// naming it (`LibraryPersistenceService.saveAndWait(_:)`). Only then
    /// does the library hold the new row. A failed write leaves the library
    /// as it was. The reading text this Mac kept for the old copy goes, and
    /// a session editing its text or manifest ends: what it watches went
    /// with the old copy.
    /// - Throws: why the new copy's record, or the library's index, could
    ///   not be written.
    private func commitReplacement(of existing: Book, by preparation: DuplicateReplacement.Preparation) throws {
        let book = preparation.book
        LibraryPersistenceService.writePendingBookInfoNow(bookID: existing.id)
        try book.saveBookInfoThrowing()
        var replaced = library
        if let index = replaced.books.firstIndex(where: { $0.id == existing.id }) {
            replaced.books[index] = book
        } else {
            replaced.books.append(book)
        }
        guard LibraryPersistenceService.saveAndWait(replaced) else {
            // A later save of the library as it is settles the failed write,
            // so its retry never writes the row the library does not hold.
            save()
            throw DuplicateReplacement.IndexNotSaved()
        }
        library = replaced
        // The new record holds the book's state now: nothing of the old
        // copy's counts as unsaved.
        LibraryPersistenceService.forgetDeletedBook(existing)
        ReadingTextCache.shared.remove(bookID: existing.id)
        endEditingSessions(of: existing)
        if book.format.isAudio || existing.format.isAudio {
            TranscribedBooks.shared.record(book.id, isTranscribed: preparation.keptTranscript)
        }
        DiagnosticLog.event(.storage, Self.replacementLogLine(for: book, preparation: preparation))
    }

    /// Removes the package of `existing`, which a committed new copy has
    /// replaced, as Removal Behavior says (`removesReplacedPackage`). The
    /// replacement stands whatever happens: a package that cannot be removed
    /// stays in its folder, and the library's alert says so; it names a
    /// listed book, so no launch adopts it as a second one.
    private func removeReplacedPackage(of existing: Book) {
        let movesToTrash = removalPreferences.movesToTrash
        do {
            try removesReplacedPackage(existing, movesToTrash)
        } catch {
            presentFailure(of: .failure(DuplicateReplacement.oldCopyLeftMessage(
                title: existing.title,
                movesToTrash: movesToTrash,
                reason: error.localizedDescription
            )))
        }
    }

    /// The debug log's line for a replacement: the book, what it kept, and
    /// the copy of the old text kept beside the new one, if any.
    static func replacementLogLine(for book: Book, preparation: DuplicateReplacement.Preparation) -> String {
        var line = "DUPLICATE_REPLACED: \(book.title): the new copy took its place under its ID, "
            + "with \(CountWording.bookmarks(book.bookmarks.count))"
        if book.format.isAudio {
            line += preparation.keptTranscript ? ", and its transcript" : ", without a transcript"
        }
        if let keptText = preparation.keptText {
            line += "; its earlier text was kept as \(keptText.lastPathComponent)"
        }
        return line
    }

    /// Ends the Edit Text and Edit Manifest sessions of `existing`, the
    /// replaced copy, if any: what they watch is its content.md or manifest,
    /// and a check finding the new copy's files would take them for an edit.
    /// Edit Text says it stopped, as it does for a book removed; Edit
    /// Manifest ends quietly, as it does then. Only a session that exists is
    /// ended, so no editor is made for none.
    private func endEditingSessions(of existing: Book) {
        if BookTextEditSessions.shared.isEditing(existing.id) {
            BookTextEditor.shared.endBecauseBookWasReplaced(existing.id, title: existing.title)
        }
        textEditSessions.end(existing.id)
        if BookManifestEditSessions.shared.isEditing(existing.id) {
            BookManifestEditor.shared.end(existing.id)
        }
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

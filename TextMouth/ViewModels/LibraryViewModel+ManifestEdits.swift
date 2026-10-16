import Foundation

// MARK: - Edited Manifests (FR17)

extension LibraryViewModel {
    /// Gives the library an edit of a book's manifest that Edit Manifest
    /// took, already committed to the book's record
    /// (`BookManifestEditSessions`): the book's row takes the edit's
    /// analysis (its duration, its counts, and its index version), which
    /// its list shows, and the moves of its places the record took, and is
    /// saved; then its title and author take the manifest's, when it gives
    /// them, through the one write of a manifest book's title and author;
    /// then the book's open readers show the new arrangement as they play
    /// on (`LibraryBookEvent.tracksRearranged`). The row's changes reach the
    /// readers first, through the usual updates, so their copies of the book
    /// agree with the headings they show.
    func commitManifestEdit(_ edit: BookManifestEdit) {
        applyAnalysisSummaries([ContentAnalysisSummary(committed: edit.committed, movedPlaces: edit.movedPlaces)])
        setTitleAndAuthor(ofManifestBook: edit.committed.id, title: edit.title, author: edit.author)
        bookUpdates.tracksRearranged(bookID: edit.committed.id, by: edit)
    }

    // MARK: Hand Edits Made Before FR17, Kept Once

    /// The preference that records the one-time pass keeping hand-edited
    /// titles and authors in manifests (`keepHandEditedTitlesInManifestsOnce`)
    /// as made on this Mac for the library this Mac expects
    /// (`DataDirectoryPreferences.expectedIdentity`), so each library has it
    /// once: its version, `manifestHandEditsKeptVersion`, once made.
    nonisolated static func manifestHandEditsKeptKey(in preferences: UserDefaults) -> String {
        let base = "library.manifestHandEditsKeptVersion"
        guard let identity = DataDirectoryPreferences.expectedIdentity.read(from: preferences) else { return base }
        return base + "." + identity.uuidString
    }

    /// The version of the one-time pass this TextMouth makes.
    nonisolated static let manifestHandEditsKeptVersion = 1

    /// What the one-time pass did, counts alone.
    struct ManifestHandEditsOutcome: Equatable, Sendable {
        /// The books whose manifests were given their hand-edited title or
        /// author.
        var kept = 0
        /// The books left for a later launch: files only in the cloud, or a
        /// manifest that could not be written.
        var waiting = 0

        /// The debug log's line for the pass.
        var logLine: String {
            "MANIFEST_HAND_EDITS_KEPT: wrote the hand-edited title or author of \(kept) book(s) of tracks "
                + "into their manifests; \(waiting) wait for a later launch"
        }
    }

    /// Writes, once for each library, the title and the author each book of
    /// tracks' row records as edited by hand into its manifest, where the
    /// manifest gives another (`BookManifestFile.keepHandEditedTitleAndAuthor`),
    /// before any look takes an edit made outside a session (FR18): since
    /// FR17 the two change together, so such a disagreement can only be a
    /// hand edit made before FR17, which must never be lost. After the pass,
    /// a manifest that disagrees with its book wins, as an edit made outside
    /// TextMouth. A row without a hand edit is left alone, so a title
    /// changed in the manifest is still taken.
    ///
    /// The pass runs on the manifest sessions' queue, so every look waits
    /// for it, and until it is recorded as done each look keeps its book's
    /// hand edits first. A book whose files are only in the cloud waits for
    /// a later launch, which makes the pass again; nothing is downloaded.
    /// One `MANIFEST_HAND_EDITS_KEPT` line in the debug log counts what was
    /// done.
    /// - Parameters:
    ///   - preferences: Where the pass is recorded as made.
    ///   - access: How the pass reaches the books' files (FR02).
    ///   - sessions: The manifest sessions whose queue the pass runs on.
    ///   - completion: Called on the main actor with what the pass did, or
    ///     with nil, at once, when it was made already.
    func keepHandEditedTitlesInManifestsOnce(
        preferences: UserDefaults = TextMouthRuntime.current.preferences,
        access: MaintenanceFileAccess = .live,
        sessions: BookManifestEditSessions = .shared,
        then completion: (@MainActor @Sendable (ManifestHandEditsOutcome?) -> Void)? = nil
    ) {
        let key = Self.manifestHandEditsKeptKey(in: preferences)
        guard preferences.integer(forKey: key) < Self.manifestHandEditsKeptVersion else {
            completion?(nil)
            return
        }
        sessions.setKeepsHandEditsFirst(true)
        let books = library.books.filter { book in
            BookManifestEditing.mayHaveTrackFolder(book)
                && (book.handEdits?.contains(.title) == true || book.handEdits?.contains(.author) == true)
        }
        // Recorded back on the main actor: made only once nothing waits.
        let finish: @MainActor @Sendable (ManifestHandEditsOutcome) -> Void = { done in
            DiagnosticLog.event(.storage, done.logLine)
            if done.waiting == 0 {
                preferences.set(Self.manifestHandEditsKeptVersion, forKey: key)
                sessions.setKeepsHandEditsFirst(false)
            }
            completion?(done)
        }
        let isDataless = access.isDataless
        sessions.queue.async {
            var outcome = ManifestHandEditsOutcome()
            for book in books {
                switch BookManifestFile.keepHandEditedTitleAndAuthor(of: book, sessions: sessions, isDataless: isDataless) {
                case .kept:
                    outcome.kept += 1
                case .waiting:
                    outcome.waiting += 1
                case .unchanged:
                    break
                }
            }
            let done = outcome
            DispatchQueue.main.async {
                finish(done)
            }
        }
    }

    // MARK: Edits Made While TextMouth Was Closed (FR18)

    /// Looks once, at launch, at the manifest of every audiobook that may
    /// play a folder of tracks, for an edit made outside Edit Manifest while
    /// TextMouth was closed or on another Mac, and hands what each look
    /// found to `editor`, which takes an edit as a save through Edit
    /// Manifest is taken and announces it (`BookManifestEditSessions.look`).
    /// The looks run one book at a time off the main thread, beside the
    /// launch's other maintenance of books
    /// (`updateContentCachesAndStatistics(access:then:)`), each reading only
    /// a book's record, its manifest, and its audio folder's listing; a book
    /// whose files are only in the cloud by `access` is left as it is (FR02).
    /// - Parameter completion: Called on the main actor once every look has
    ///   been acted on.
    func takeOutsideManifestEdits(
        access: MaintenanceFileAccess = .live,
        editor: BookManifestEditor = .shared,
        then completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        let books = library.books.filter(BookManifestEditing.mayHaveTrackFolder)
        guard !books.isEmpty else {
            completion?()
            return
        }
        let sessions = editor.sessions
        let isDataless = access.isDataless
        DispatchQueue.global(qos: .utility).async {
            let found = books.map { book in
                (bookID: book.id, found: sessions.look(at: book, isDataless: isDataless))
            }
            DispatchQueue.main.async { [weak self] in
                if let self {
                    for look in found {
                        editor.handle(look.found, for: look.bookID, in: self)
                    }
                }
                completion?()
            }
        }
    }

    // MARK: Title and Author, Kept in Step

    /// The one write of the title and author of an audiobook of tracks
    /// (FR17), so that its manifest and the book never say different things.
    /// The user, October 13, 2026: "I kind of think hand edited meta data in
    /// TextMouth in this case should just be synced / stored in the
    /// MANIFEST since it's both user editable and them diverging might get
    /// someone confused."
    ///
    /// The book's row, and so its record, takes `title` and `author` now,
    /// nil leaving either; then its manifest takes them, as storage work on
    /// the manifest sessions' queue, in the order they were given
    /// (`BookManifestFile.keepTitleAndAuthor`). Every path through which a
    /// manifest book's title or author changes calls this: an edited
    /// manifest taken (`commitManifestEdit`), whose manifest holds them
    /// already, and a metadata editor's save (`updateBookMetadata`), whose
    /// row holds them already. The launch's metadata refresh reads no tags
    /// from a folder of tracks, so it changes neither. A book that is no
    /// audiobook of tracks has only its row changed.
    ///
    /// A title or author the manifest cannot take now (it is only in the
    /// cloud, or is midway through an edit) is kept as owed to it, on this
    /// Mac, and written before the next look compares (`ManifestOwedFields`,
    /// `BookManifestEditSessions.settleOwedFields(of:adding:isDataless:)`),
    /// so the manifest's old value never replaces the user's edit.
    /// - Parameters:
    ///   - written: Called on the main actor with whether the manifest was
    ///     written by this call.
    ///   - isDataless: Tells a file only in the cloud; tests stand in for it.
    func setTitleAndAuthor(
        ofManifestBook bookID: UUID,
        title: String?,
        author: String?,
        sessions: BookManifestEditSessions = .shared,
        written: (@MainActor @Sendable (Bool) -> Void)? = nil,
        isDataless: @escaping @Sendable (URL) -> Bool = { DatalessFiles.isDataless($0) }
    ) {
        guard let row = bookByID(bookID), title != nil || author != nil else {
            written?(false)
            return
        }
        let newTitle = title ?? row.title
        let newAuthor = author ?? row.author
        if newTitle != row.title || newAuthor != row.author {
            updateBook(id: bookID) { book in
                book.title = newTitle
                book.author = newAuthor
            }
        }
        guard let book = bookByID(bookID), BookManifestEditing.canEditManifest(of: book, isTrackFolder: true) else {
            written?(false)
            return
        }
        // The fields this call gives: the manifest is owed them from now on,
        // until a write puts them in (`ManifestOwedFields`).
        var given: Set<Book.MetadataField> = []
        if title != nil { given.insert(.title) }
        if author != nil { given.insert(.author) }
        let owedByThisCall = given
        sessions.queue.async {
            let didWrite = sessions.settleOwedFields(of: book, adding: owedByThisCall, isDataless: isDataless)
            Task { @MainActor in
                written?(didWrite)
            }
        }
    }
}

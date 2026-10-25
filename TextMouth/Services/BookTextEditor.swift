import AppKit
import UniformTypeIdentifiers

/// Edit Text in Default Editor and Edit Text With… (FR05): a text book's
/// text opens in the user's own editor, as its content.md, and TextMouth
/// takes what the user saves as the book's text.
///
/// There is no editor in TextMouth. The command opens the package's
/// content.md with the default app for Markdown, or with an app the user
/// chooses, after explaining what will happen the first time it is used on
/// this Mac. From then on the book is edited in a session
/// (`BookTextEditSessions`): a watcher on content.md, and TextMouth
/// becoming the active app, check for an edit, and an edit is taken when
/// content.md changed while the book's own file did not. Taking it indexes
/// the edited text afresh, commits it to the book's record, gives the
/// library row its new counts, refreshes the book's open readers near
/// where they were, and announces "Text updated" (at once while TextMouth
/// is active, or when it becomes active).
///
/// A transcribed audiobook's text is edited the same way: its content.md is
/// its transcript's text, and an edit is taken while its transcript.json
/// has not changed, into the transcript itself (`TranscriptStore.takeEdit`),
/// so the text written from the transcript is the edit from then on; its
/// open readers show the edited text as the book plays on.
@MainActor
final class BookTextEditor {
    /// The app's editor.
    static let shared = BookTextEditor()

    /// Whether Edit Text has explained itself on this Mac: machine-local,
    /// never in config.json (`ConfigService.AppConfig.Portability`).
    nonisolated static let explainedPreference = StoredPreference.flag("editTextExplained", default: false)

    /// Explains what Edit Text does, for the book titled with the string,
    /// over the window, and says whether the user goes on.
    typealias Explainer = PackageFileEditing.Explainer
    /// Asks which app to edit the book titled with the string in; nil when
    /// the user cancels.
    typealias AppChooser = PackageFileEditing.AppChooser
    /// Opens a file in an app, or in the default app for it when nil.
    typealias Opener = PackageFileEditing.Opener

    /// The words of Edit Text's explanation and app chooser.
    static let wording = PackageFileEditing.Wording(
        explanationTitle: BookTextEditWording.explanationTitle(bookTitle:),
        explanation: BookTextEditWording.explanation,
        appPanelTitle: BookTextEditWording.appPanelTitle,
        appPanelMessage: BookTextEditWording.appPanelMessage(bookTitle:)
    )

    /// The sessions of the books being edited.
    let sessions: BookTextEditSessions
    /// What Edit Text shares with Edit Manifest (`PackageFileEditing`): the
    /// explanation, the app chooser, the opener, the watchers, TextMouth
    /// becoming active, and the announcements.
    let files: PackageFileEditing

    /// The library the books edited belong to, as the last Edit Text gave it.
    private weak var library: LibraryViewModel?
    /// The edit last refused for each book, so the same refused bytes are
    /// announced once, however often they are checked.
    private var announcedRefusals: [UUID: BookTextEditSessions.RefusedEdit] = [:]
    /// The copies of each book's edited text VoiceOver has been told of, so
    /// a copy a rebuild kept is not announced again.
    private var announcedCopies: [UUID: Set<URL>] = [:]
    /// The feed episodes whose transcript's note (`updatedInFeed`) has been
    /// announced in the session now running, so only the first edit says it.
    private var announcedFeedNotes: Set<UUID> = []
    /// The title of the book of each session, kept when the session begins,
    /// so a session that ends because its book left the library can still
    /// name the book (`endBecauseBookIsGone(_:)`).
    private var sessionTitles: [UUID: String] = [:]

    /// An editor whose sessions are `sessions`, remembering its explanation
    /// in `preferences` and hearing TextMouth become active on
    /// `notificationCenter`: the app's, unless a test passes its own. The
    /// other arguments stand for the user and the system: the first-use
    /// explanation, the app chooser of Edit Text With…, what opens
    /// content.md, and whether TextMouth is active (`PackageFileEditing`).
    init(
        sessions: BookTextEditSessions = .shared,
        preferences: UserDefaults = TextMouthRuntime.current.preferences,
        notificationCenter: NotificationCenter = .default,
        explain: @escaping Explainer = BookTextEditor.explainWithAlert,
        chooseApp: @escaping AppChooser = BookTextEditor.chooseAppWithPanel,
        open: @escaping Opener = PackageFileEditing.openWithWorkspace,
        isAppActive: @escaping @MainActor () -> Bool = { NSApp?.isActive ?? false }
    ) {
        self.sessions = sessions
        files = PackageFileEditing(
            explainedPreference: Self.explainedPreference,
            preferences: preferences,
            notificationCenter: notificationCenter,
            explain: explain,
            chooseApp: chooseApp,
            open: open,
            isAppActive: isAppActive
        )
        files.checkAll = { [weak self] in
            self?.checkEveryBook()
        }
    }

    // MARK: Editing

    /// Opens `book`'s text for editing, in the default app for Markdown or,
    /// with `choosingApp`, in an app the user chooses, after explaining
    /// what will happen the first time. A transcribed audiobook's text is
    /// its transcript's, which takes the edit (FR05). A book already being
    /// edited keeps its session, so an edit it has not taken yet is never
    /// lost. Says why nothing opened: an audiobook without a transcript, a
    /// text that is only in the cloud (FR02) or not written yet, a text
    /// being read again in another encoding, or an editor that could not
    /// open it. `window` is where the dialogs and announcements appear.
    func edit(_ book: Book, choosingApp: Bool, in library: LibraryViewModel, from window: NSWindow?) async {
        guard !refusesWhileReadAgain(book, in: library, from: window) else { return }
        guard await Self.hasText(book) else {
            files.announce(BookTextEditWording.noText(bookTitle: book.title), from: window)
            return
        }
        self.library = library
        let access = sessions.access
        let found = await OffMainWork.run { BookTextEditSessions.baseline(of: book, access: access) }
        let baseline: BookTextBaseline
        switch found {
        case .failure(let failure):
            files.announce(BookTextEditWording.cannotBegin(failure, bookTitle: book.title), from: window)
            return
        case .success(let current):
            baseline = current
        }
        guard let choice = await files.chooseEditor(bookTitle: book.title, choosingApp: choosingApp, from: window) else { return }
        // Asked again: a re-read may have begun while the dialogs were open.
        guard !refusesWhileReadAgain(book, in: library, from: window) else { return }
        let startedSession = begin(book.id, baseline: baseline)
        do {
            try await files.open(MarkdownCacheService.cacheURL(for: book), choice.app)
        } catch {
            if startedSession {
                end(book.id)
            }
            files.announce(BookTextEditWording.openFailed(bookTitle: book.title, reason: error.localizedDescription), from: window)
        }
    }

    /// Whether `book`'s text is being read again in another encoding, which
    /// Edit Text waits for, saying so (`LibraryViewModel.readingAgainRefusal(of:)`):
    /// the re-read replaces the text a session would watch (review of
    /// October 24, finding 3).
    private func refusesWhileReadAgain(_ book: Book, in library: LibraryViewModel, from window: NSWindow?) -> Bool {
        guard let refusal = library.readingAgainRefusal(of: book.id) else { return false }
        files.announce(refusal, from: window)
        return true
    }

    /// Pauses `book`'s session before a change rewrites its transcript
    /// (Clean Up, Undo Cleanup, a new transcription, Delete Transcript):
    /// a check of the book already running finishes, and an edit saved but
    /// not yet checked is taken, committed, and announced as any taken edit
    /// is (`BookTextEditSessions.settlePendingEdit(of:)`), all off the main
    /// thread, so no check races the change. Then the session ends, as the
    /// change rewrites the text it watched.
    /// - Returns: Whether the book was being edited; false at once if not.
    ///   A change that fails afterwards calls `resumeEditing(of:)` when this
    ///   returned true, so the user's later saves are still taken.
    func pauseEditing(of book: Book) async -> Bool {
        guard sessions.isEditing(book.id) else { return false }
        let sessions = self.sessions
        // What the settlement says to read is of no use here: the change that
        // follows rewrites the text itself.
        _ = await OffMainWork.run { sessions.settlePendingEdit(of: book) }
        end(book.id)
        return true
    }

    /// Begins `book`'s session again after a change that `pauseEditing(of:)`
    /// paused has failed, from a fresh baseline of the text the book has
    /// now, so the user's next save is taken. It says nothing and opens no
    /// editor: the user's editor is open already. When the baseline cannot
    /// be read, it announces why, as `edit(_:choosingApp:in:from:)` does.
    func resumeEditing(of book: Book) async {
        let access = sessions.access
        let found = await OffMainWork.run { BookTextEditSessions.baseline(of: book, access: access) }
        switch found {
        case .failure(let failure):
            files.announce(BookTextEditWording.cannotBegin(failure, bookTitle: book.title))
        case .success(let baseline):
            begin(book.id, baseline: baseline)
        }
    }

    /// Whether `book`'s text can be edited here, as the app knows which
    /// audiobooks are transcribed (`TranscribedBooks`): a text book's, or a
    /// transcribed audiobook's transcript text (FR05).
    static func canEditText(of book: Book) -> Bool {
        canEditText(of: book, isTranscribed: TranscribedBooks.shared.contains(book.id))
    }

    /// Whether `book`'s text can be edited here, given whether it is
    /// `isTranscribed`: a text book's text, and any transcribed audiobook's
    /// transcript text, an episode's in its feed included (the user's request
    /// of October 23, 2026). Its content.md is its transcript's text, and its
    /// transcript takes the edit (`TranscriptStore.takeEdit`). Never a feed
    /// article's text, which belongs to its feed (FR11, question 4). An
    /// episode's edit is kept in its transcript, which stays in the
    /// episode's package when its download is deleted (`FeedItemPackage`),
    /// and goes only with Delete Episode, Delete Feed, or Delete Transcript.
    /// Edit Text… and Edit Text With… are not offered otherwise, in the
    /// library's rows or the reader's Book menu.
    static func canEditText(of book: Book, isTranscribed: Bool) -> Bool {
        !book.tmbDirectoryName.isEmpty && (book.format.isAudio ? isTranscribed : !book.isFeedItem)
    }

    /// Whether `book` has text to edit now: a text book always, an
    /// audiobook once its package holds a transcript, looked for off the
    /// main thread without reading it.
    private static func hasText(_ book: Book) async -> Bool {
        guard book.format.isAudio else { return true }
        guard !book.tmbDirectoryName.isEmpty else { return false }
        let transcript = TextMouthPaths.transcriptPath(in: book.tmbDirectory)
        return await OffMainWork.run { FileManager.default.fileExists(atPath: transcript.path) }
    }

    // MARK: Sessions

    /// Starts the session of the book `bookID` from `baseline`, with a
    /// watcher on its content.md, unless it is being edited already.
    /// - Returns: Whether a session was started.
    @discardableResult
    func begin(_ bookID: UUID, baseline: BookTextBaseline) -> Bool {
        guard !sessions.isEditing(bookID) else { return false }
        let library = self.library
        sessions.begin(bookID, BookTextEditSessions.Session(
            baseline: baseline,
            report: { [weak self] bookID, found in
                Task { @MainActor in
                    self?.handle(found, for: bookID)
                }
            }
        ))
        files.watch(
            bookID,
            file: { [weak library] in library?.bookByID(bookID).map(MarkdownCacheService.cacheURL(for:)) },
            changed: { [weak self] in self?.check(bookID) }
        )
        // The session's copy of the text its edits replace, and the title
        // to name the book by if it leaves the library.
        if let book = library?.bookByID(bookID) {
            sessions.keepOldText(of: book)
            sessionTitles[bookID] = book.title
        }
        return true
    }

    /// Checks the book `bookID` for an edit, as the library holds the book
    /// now; a book that has left the library ends its session instead,
    /// saying so.
    func check(_ bookID: UUID) {
        guard let book = library?.bookByID(bookID) else {
            endBecauseBookIsGone(bookID)
            return
        }
        sessions.scheduleCheck(of: book)
    }

    /// Ends the session of the book `bookID` because the library no longer
    /// lists the book (it was removed, or a feed episode's download was
    /// deleted and its row moved to its feed's shelf), after announcing that
    /// Edit Text has stopped for it, so the user is not left saving into an
    /// editor nothing listens to. Said once: the session, and its title, go
    /// with the first call.
    private func endBecauseBookIsGone(_ bookID: UUID) {
        if let title = sessionTitles[bookID] {
            files.announce(BookTextEditWording.stoppedBookGone(bookTitle: title))
        }
        end(bookID)
    }

    /// Ends the session of the book `bookID` because Replace Existing put a
    /// new copy, `title` before it, in the book's place (ST04), saying that
    /// Edit Text has stopped for it: the book keeps its ID, so no check finds
    /// it gone, but the text being edited went with the old copy, and a save
    /// into it would never be taken. Says nothing, and ends nothing, when the
    /// book had no session.
    func endBecauseBookWasReplaced(_ bookID: UUID, title: String) {
        guard sessions.isEditing(bookID) || files.watchedBookIDs.contains(bookID) else { return }
        files.announce(BookTextEditWording.stoppedBookReplaced(bookTitle: sessionTitles[bookID] ?? title))
        end(bookID)
    }

    /// Ends the session of the book `bookID`: its watcher stops, and no
    /// edit of it is checked for any more.
    func end(_ bookID: UUID) {
        sessions.end(bookID)
        files.stopWatching(bookID)
        announcedRefusals[bookID] = nil
        announcedCopies[bookID] = nil
        announcedFeedNotes.remove(bookID)
        sessionTitles[bookID] = nil
    }

    /// Ends every session, as a test does when it ends.
    func endAll() {
        for bookID in files.watchedBookIDs {
            end(bookID)
        }
    }

    /// TextMouth became active: says what waited, and checks every book
    /// being edited for an edit saved meanwhile.
    func appBecameActive() {
        files.appBecameActive()
    }

    /// Checks every book being edited, as TextMouth becoming active does.
    private func checkEveryBook() {
        for bookID in sessions.bookIDs {
            check(bookID)
        }
    }

    // MARK: What a Check Found

    /// Acts on what a check of the book `bookID` found, or what a rebuild of
    /// its text did: an edit taken is given to the library, which refreshes
    /// the book's row and its open readers, and announced; an edit not taken
    /// is announced once for the same bytes and reason, with where it was
    /// kept; text a rebuild replaced is announced once for each copy kept of
    /// it; a book gone from the library ends its session.
    func handle(_ found: BookTextEditCheck, for bookID: UUID) {
        let title = library?.bookByID(bookID)?.title ?? ""
        switch found {
        case .unchanged, .inCloud:
            return
        case .missing:
            if library?.bookByID(bookID) == nil {
                endBecauseBookIsGone(bookID)
            }
        case .adopted(let edit):
            announcedRefusals[bookID] = nil
            // Read before the commit, which refreshes the row: a feed
            // episode's first edit in a session also says where its
            // transcript stays; later edits say only that the text updated.
            let isFeedItem = library?.bookByID(bookID)?.isFeedItem == true
            library?.commitTextEdit(edit)
            let firstInFeed = isFeedItem && announcedFeedNotes.insert(bookID).inserted
            files.announce(firstInFeed ? BookTextEditWording.updatedInFeed : BookTextEditWording.updated)
        case .refused(let refusal, let digest, let keptCopy):
            let refused = BookTextEditSessions.RefusedEdit(digest: digest, refusal: refusal)
            guard announcedRefusals[bookID] != refused else { return }
            announcedRefusals[bookID] = refused
            if let keptCopy {
                announcedCopies[bookID, default: []].insert(keptCopy)
            }
            files.announce(BookTextEditWording.notTaken(refusal, bookTitle: title, keptCopy: keptCopy))
        case .replaced(let keptCopy):
            guard announcedCopies[bookID, default: []].insert(keptCopy).inserted else { return }
            announcedRefusals[bookID] = nil
            files.announce(BookTextEditWording.replaced(bookTitle: title, keptCopy: keptCopy))
        }
    }

    // MARK: The System's Dialogs

    /// Edit Text's first-use explanation, as an alert over `window` (or the
    /// app): Continue, which Return presses, and Cancel, which Escape presses.
    static func explainWithAlert(bookTitle: String, window: NSWindow?) async -> Bool {
        await PackageFileEditing.explainWithAlert(wording, bookTitle: bookTitle, window: window)
    }

    /// The app chooser of Edit Text With…: an open panel of apps, starting
    /// in Applications, over `window` (or on its own).
    static func chooseAppWithPanel(bookTitle: String, window: NSWindow?) async -> URL? {
        await PackageFileEditing.chooseAppWithPanel(wording, bookTitle: bookTitle, window: window)
    }
}

// MARK: - Watching content.md

/// Watches one file of a book's package for saves, its content.md (FR05)
/// or its manifest.json (FR17), and says when a burst of them has settled.
///
/// An editor's save can replace the file, as TextEdit's does: the watcher
/// then follows the file to wherever the book now keeps it, which `file`
/// names, looking again for a moment while the new file lands. A save the
/// watcher misses is still found when TextMouth becomes active, so the
/// watcher only makes the edit arrive sooner.
@MainActor
final class ContentFileWatcher {
    /// How long saves must stay quiet before `changed` is called: an
    /// editor's save arrives as several events.
    static let quietPeriod: TimeInterval = 0.75

    /// The file to watch, as the book keeps it now; nil once it has none.
    private let file: @MainActor () -> URL?
    /// Called once a burst of saves has settled.
    private let changed: @MainActor () -> Void
    /// The source listening to the file, while one does.
    private var source: DispatchSourceFileSystemObject?
    /// The call of `changed` waiting for the saves to settle.
    private var settle: DispatchWorkItem?
    /// Whether the watcher has stopped for good.
    private var isCancelled = false

    /// A watcher of the file `file` names, calling `changed` once each burst
    /// of saves has settled.
    init(file: @escaping @MainActor () -> URL?, changed: @escaping @MainActor () -> Void) {
        self.file = file
        self.changed = changed
        arm(attempt: 0)
    }

    /// Stops watching for good.
    func cancel() {
        isCancelled = true
        source?.cancel()
        source = nil
        settle?.cancel()
        settle = nil
    }

    /// Listens to the file now there, or, when none is there yet, as while
    /// an editor replaces it, looks again a few times.
    private func arm(attempt: Int) {
        guard !isCancelled, source == nil else { return }
        guard let url = file(), !DatalessFiles.isDataless(url) else {
            retry(after: attempt)
            return
        }
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            retry(after: attempt)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke, .attrib, .link],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.received(source.data)
            }
        }
        // Dispatch runs this once the source has stopped using the
        // descriptor, the only safe moment to close it.
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        source.resume()
        self.source = source
    }

    /// Looks for the file again a little later, up to ten times; after
    /// that, TextMouth's next activation still finds an edit.
    private func retry(after attempt: Int) {
        guard attempt < 10 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                self?.arm(attempt: attempt + 1)
            }
        }
    }

    /// One event from the file: a replaced file is followed to the new one,
    /// and `changed` is put off until events stop.
    private func received(_ event: DispatchSource.FileSystemEvent) {
        if !event.isDisjoint(with: [.delete, .rename, .revoke]) {
            source?.cancel()
            source = nil
            arm(attempt: 0)
        }
        settle?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isCancelled else { return }
                self.settle = nil
                self.changed()
            }
        }
        settle = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quietPeriod, execute: item)
    }
}

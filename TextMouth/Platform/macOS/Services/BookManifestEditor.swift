import AppKit

/// Edit Manifest in Default Editor and Edit Manifest With… (FR17): a
/// multi-track audiobook's manifest.json opens in the user's own editor, and
/// TextMouth takes what the user saves as the book's arrangement.
///
/// It works as Edit Text does (`BookTextEditor`), sharing its explanation,
/// app chooser, opener, watcher, and announcements (`PackageFileEditing`).
/// The command opens the manifest with the default app for JSON, or an app
/// the user chooses, after explaining itself the first time on this Mac,
/// writing a manifest first for a book without one
/// (`BookManifestFile.prepare`). From then on the book is edited in a
/// session (`BookManifestEditSessions`): a watcher on its manifest, and
/// TextMouth becoming active, check for an edit. An edit is checked as an
/// import checks a manifest; one with a problem changes nothing and is
/// announced once in the import's words, and the next save is taken. A good
/// one is committed to the book's record with its rebuilt headings, given
/// to the library, which refreshes the book's row and its open readers, and
/// announced: "Manifest updated".
@MainActor
final class BookManifestEditor {
    /// The app's editor.
    static let shared = BookManifestEditor()

    /// Whether Edit Manifest has explained itself on this Mac: machine-local,
    /// never in config.json (`ConfigService.AppConfig.Portability`).
    nonisolated static let explainedPreference = StoredPreference.flag("editManifestExplained", default: false)

    /// The words of Edit Manifest's explanation and app chooser.
    static let wording = PackageFileEditing.Wording(
        explanationTitle: BookManifestEditWording.explanationTitle(bookTitle:),
        explanation: BookManifestEditWording.explanation,
        appPanelTitle: BookManifestEditWording.appPanelTitle,
        appPanelMessage: BookManifestEditWording.appPanelMessage(bookTitle:)
    )

    /// The sessions of the books whose manifests are being edited.
    let sessions: BookManifestEditSessions
    /// What Edit Manifest shares with Edit Text (`PackageFileEditing`).
    let files: PackageFileEditing

    /// The library the books edited belong to, as the last Edit Manifest
    /// gave it.
    private weak var library: LibraryViewModel?
    /// The digest of the manifest last refused for each book, so the same
    /// refused bytes are announced once, however often they are checked.
    private var announcedRefusals: [UUID: String] = [:]

    /// An editor whose sessions are `sessions`, remembering its explanation
    /// in `preferences` and hearing TextMouth become active on
    /// `notificationCenter`: the app's, unless a test passes its own. The
    /// other arguments stand for the user and the system, as for Edit Text.
    init(
        sessions: BookManifestEditSessions = .shared,
        preferences: UserDefaults = TextMouthRuntime.current.preferences,
        notificationCenter: NotificationCenter = .default,
        explain: @escaping PackageFileEditing.Explainer = BookManifestEditor.explainWithAlert,
        chooseApp: @escaping PackageFileEditing.AppChooser = BookManifestEditor.chooseAppWithPanel,
        open: @escaping PackageFileEditing.Opener = PackageFileEditing.openWithWorkspace,
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

    /// Opens `book`'s manifest for editing, in the default app for JSON or,
    /// with `choosingApp`, in an app the user chooses, after explaining what
    /// will happen the first time. A book without a manifest is given one
    /// first, from the book as it is (`BookManifestFile.prepare`), once the
    /// user has gone on. A book already being edited keeps its session, so
    /// an edit it has not taken yet is never lost. Says why nothing opened:
    /// a book that is no audiobook of tracks, one only in the cloud (FR02),
    /// a manifest that could not be written, or an editor that could not
    /// open it. `window` is where the dialogs and announcements appear.
    func edit(_ book: Book, choosingApp: Bool, in library: LibraryViewModel, from window: NSWindow?) async {
        // Told before the explanation, as Edit Text tells why it cannot begin.
        guard BookManifestEditing.canEditManifest(of: book, isTrackFolder: true) else {
            files.announce(BookManifestEditWording.noManifest(bookTitle: book.title), from: window)
            return
        }
        let folder = book.bookFileURL
        switch await OffMainWork.run({ BookManifestEditing.isTrackFolder(folder) }) {
        case nil:
            files.announce(BookManifestEditWording.inCloud(bookTitle: book.title), from: window)
            return
        case false?:
            files.announce(BookManifestEditWording.noManifest(bookTitle: book.title), from: window)
            return
        case true?:
            break
        }
        self.library = library
        guard let choice = await files.chooseEditor(bookTitle: book.title, choosingApp: choosingApp, from: window) else { return }
        let sessions = self.sessions
        let prepared = await OffMainWork.run { BookManifestFile.prepare(book, sessions: sessions) }
        let ready: BookManifestFile.Ready
        switch prepared {
        case .failure(.inCloud):
            files.announce(BookManifestEditWording.inCloud(bookTitle: book.title), from: window)
            return
        case .failure(.notTrackFolder):
            files.announce(BookManifestEditWording.noManifest(bookTitle: book.title), from: window)
            return
        case .failure(.failed(let reason)):
            files.announce(BookManifestEditWording.cannotBegin(bookTitle: book.title, reason: reason), from: window)
            return
        case .success(let found):
            ready = found
        }
        let startedSession = begin(book.id, baseline: ready.fingerprint)
        do {
            try await files.open(ready.location.url, choice.app)
        } catch {
            if startedSession {
                end(book.id)
            }
            files.announce(BookManifestEditWording.openFailed(bookTitle: book.title, reason: error.localizedDescription), from: window)
        }
    }

    // MARK: Sessions

    /// Starts the session of the book `bookID` from `baseline`, with a
    /// watcher on its manifest, unless it is being edited already.
    /// - Returns: Whether a session was started.
    @discardableResult
    func begin(_ bookID: UUID, baseline: FileFingerprint) -> Bool {
        guard !sessions.isEditing(bookID) else { return false }
        let library = self.library
        sessions.begin(bookID, BookManifestEditSessions.Session(
            baseline: baseline,
            report: { [weak self] bookID, found in
                Task { @MainActor in
                    self?.handle(found, for: bookID)
                }
            }
        ))
        files.watch(
            bookID,
            file: { [weak library] in
                library?.bookByID(bookID).flatMap { AudioManifestLocation.find(in: $0.bookFileURL)?.url }
            },
            changed: { [weak self] in self?.check(bookID) }
        )
        return true
    }

    /// Checks the book `bookID` for an edit, as the library holds the book
    /// now; a book that has left the library ends its session instead.
    func check(_ bookID: UUID) {
        guard let book = library?.bookByID(bookID) else {
            end(bookID)
            return
        }
        sessions.scheduleCheck(of: book)
    }

    /// Ends the session of the book `bookID`: its watcher stops, and no
    /// edit of it is checked for any more.
    func end(_ bookID: UUID) {
        sessions.end(bookID)
        files.stopWatching(bookID)
        announcedRefusals[bookID] = nil
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

    // MARK: Edits Made Outside a Session (FR18)

    /// Looks at `book`'s manifest for an edit made outside Edit Manifest,
    /// off the main thread (`BookManifestEditSessions.scheduleLook`), and
    /// acts on what was found in `library` as on a session's check: for a
    /// book open in a reader as TextMouth becomes active, `pauses` being the
    /// pauses the reader keeps between its tracks.
    func lookForOutsideEdit(of book: Book, showingPauses pauses: ChapterPauses?, in library: LibraryViewModel) {
        let bookID = book.id
        sessions.scheduleLook(at: book, showingPauses: pauses) { found in
            Task { @MainActor [weak self, weak library] in
                guard let self, let library else { return }
                self.handle(found, for: bookID, in: library)
            }
        }
    }

    /// Acts on what a look at the book `bookID` of `library` found, as on
    /// what a session's check found (`handle(_:for:)`): an edit taken is
    /// given to `library` and announced, and one refused is announced once
    /// for the same bytes (FR18).
    func handle(_ found: BookManifestEditCheck, for bookID: UUID, in library: LibraryViewModel) {
        self.library = library
        handle(found, for: bookID)
    }

    // MARK: What a Check Found

    /// Acts on what a check of the book `bookID` found: an edit taken is
    /// given to the library, which refreshes the book's row and its open
    /// readers, and announced; an edit not taken is announced once for the
    /// same bytes, with its problem; a book gone from the library ends its
    /// session.
    func handle(_ found: BookManifestEditCheck, for bookID: UUID) {
        switch found {
        case .unchanged, .inCloud:
            return
        case .missing:
            if library?.bookByID(bookID) == nil {
                end(bookID)
            }
        case .adopted(let edit):
            announcedRefusals[bookID] = nil
            library?.commitManifestEdit(edit)
            files.announce(BookManifestEditWording.updated)
        case .refused(let problem, let digest):
            guard announcedRefusals[bookID] != digest else { return }
            announcedRefusals[bookID] = digest
            let title = library?.bookByID(bookID)?.title ?? ""
            files.announce(BookManifestEditWording.notTaken(problem: problem, bookTitle: title))
        }
    }

    // MARK: The System's Dialogs

    /// Edit Manifest's first-use explanation, as an alert over `window` (or
    /// the app): Continue, which Return presses, and Cancel, which Escape
    /// presses.
    static func explainWithAlert(bookTitle: String, window: NSWindow?) async -> Bool {
        await PackageFileEditing.explainWithAlert(wording, bookTitle: bookTitle, window: window)
    }

    /// The app chooser of Edit Manifest With…: an open panel of apps,
    /// starting in Applications, over `window` (or on its own).
    static func chooseAppWithPanel(bookTitle: String, window: NSWindow?) async -> URL? {
        await PackageFileEditing.chooseAppWithPanel(wording, bookTitle: bookTitle, window: window)
    }
}

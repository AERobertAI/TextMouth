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
@MainActor
final class BookTextEditor {
    /// The app's editor.
    static let shared = BookTextEditor()

    /// Whether Edit Text has explained itself on this Mac: machine-local,
    /// never in config.json (`ConfigService.AppConfig.Portability`).
    nonisolated static let explainedPreference = StoredPreference.flag("editTextExplained", default: false)

    /// Explains what Edit Text does, for the book titled with the string,
    /// over the window, and says whether the user goes on.
    typealias Explainer = @MainActor (_ bookTitle: String, _ window: NSWindow?) async -> Bool
    /// Asks which app to edit the book titled with the string in; nil when
    /// the user cancels.
    typealias AppChooser = @MainActor (_ bookTitle: String, _ window: NSWindow?) async -> URL?
    /// Opens a file in an app, or in the default app for it when nil.
    typealias Opener = @MainActor (_ file: URL, _ app: URL?) async throws -> Void

    /// The sessions of the books being edited.
    let sessions: BookTextEditSessions
    /// Where the explanation is remembered.
    private let preferences: UserDefaults
    /// Where TextMouth's becoming active is heard.
    private let notificationCenter: NotificationCenter
    /// Explains Edit Text the first time; tests answer for the user.
    var explain: Explainer
    /// Chooses the app for Edit Text With…; tests choose without a panel.
    var chooseApp: AppChooser
    /// Opens content.md; tests open nothing.
    var open: Opener
    /// Whether TextMouth is the active app, so an announcement is heard now
    /// rather than when it becomes active; tests say it is.
    var isAppActive: @MainActor () -> Bool

    /// The library the books edited belong to, as the last Edit Text gave it.
    private weak var library: LibraryViewModel?
    /// The watcher of each edited book's content.md, by book ID.
    private var watchers: [UUID: ContentFileWatcher] = [:]
    /// The edit last refused for each book, so the same refused bytes are
    /// announced once, however often they are checked.
    private var announcedRefusals: [UUID: BookTextEditSessions.RefusedEdit] = [:]
    /// The copies of each book's edited text VoiceOver has been told of, so
    /// a copy a rebuild kept is not announced again.
    private var announcedCopies: [UUID: Set<URL>] = [:]
    /// What waits to be announced until TextMouth becomes active.
    private var pendingAnnouncements: [String] = []
    /// The observation of TextMouth becoming active, while any book is edited.
    private var activationObserver: NSObjectProtocol?

    /// An editor whose sessions are `sessions`, remembering its explanation
    /// in `preferences` and hearing TextMouth become active on
    /// `notificationCenter`: the app's, unless a test passes its own. The
    /// other arguments stand for the user and the system, as described on
    /// the properties they set.
    init(
        sessions: BookTextEditSessions = .shared,
        preferences: UserDefaults = TextMouthRuntime.current.preferences,
        notificationCenter: NotificationCenter = .default,
        explain: @escaping Explainer = BookTextEditor.explainWithAlert,
        chooseApp: @escaping AppChooser = BookTextEditor.chooseAppWithPanel,
        open: @escaping Opener = BookTextEditor.openWithWorkspace,
        isAppActive: @escaping @MainActor () -> Bool = { NSApp?.isActive ?? false }
    ) {
        self.sessions = sessions
        self.preferences = preferences
        self.notificationCenter = notificationCenter
        self.explain = explain
        self.chooseApp = chooseApp
        self.open = open
        self.isAppActive = isAppActive
    }

    // MARK: Editing

    /// Opens `book`'s text for editing, in the default app for Markdown or,
    /// with `choosingApp`, in an app the user chooses, after explaining
    /// what will happen the first time. A book already being edited keeps
    /// its session, so an edit it has not taken yet is never lost. Says why
    /// nothing opened: an audiobook, whose text is not edited here yet, a
    /// text that is only in the cloud (FR02) or not written yet, or an
    /// editor that could not open it. `window` is where the dialogs and
    /// announcements appear.
    func edit(_ book: Book, choosingApp: Bool, in library: LibraryViewModel, from window: NSWindow?) async {
        guard !book.format.isAudio else {
            announce(BookTextEditWording.noText(bookTitle: book.title), from: window)
            return
        }
        self.library = library
        let access = sessions.access
        let found = await OffMainWork.run { BookTextEditSessions.baseline(of: book, access: access) }
        let baseline: BookTextBaseline
        switch found {
        case .failure(let failure):
            announce(BookTextEditWording.cannotBegin(failure, bookTitle: book.title), from: window)
            return
        case .success(let current):
            baseline = current
        }
        if !Self.explainedPreference.read(from: preferences) {
            guard await explain(book.title, window) else { return }
            Self.explainedPreference.write(true, to: preferences)
        }
        var app: URL?
        if choosingApp {
            guard let chosen = await chooseApp(book.title, window) else { return }
            app = chosen
        }
        let startedSession = begin(book.id, baseline: baseline)
        do {
            try await open(MarkdownCacheService.cacheURL(for: book), app)
        } catch {
            if startedSession {
                end(book.id)
            }
            announce(BookTextEditWording.openFailed(bookTitle: book.title, reason: error.localizedDescription), from: window)
        }
    }

    /// Whether `book`'s text can be edited here: a text book's, for now.
    /// An audiobook's content.md, its transcript's text, is written from
    /// its transcript, which a later task makes editable.
    static func canEditText(of book: Book) -> Bool {
        !book.format.isAudio && !book.tmbDirectoryName.isEmpty
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
        watchers[bookID] = ContentFileWatcher(
            file: { [weak library] in library?.bookByID(bookID).map(MarkdownCacheService.cacheURL(for:)) },
            changed: { [weak self] in self?.check(bookID) }
        )
        observeActivation()
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
        watchers.removeValue(forKey: bookID)?.cancel()
        announcedRefusals[bookID] = nil
        announcedCopies[bookID] = nil
        if sessions.bookIDs.isEmpty, let observer = activationObserver {
            notificationCenter.removeObserver(observer)
            activationObserver = nil
        }
    }

    /// Ends every session, as a test does when it ends.
    func endAll() {
        for bookID in Array(watchers.keys) {
            end(bookID)
        }
    }

    /// Checks every edited book when TextMouth becomes active, after saying
    /// what waited for it.
    private func observeActivation() {
        guard activationObserver == nil else { return }
        activationObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.appBecameActive()
            }
        }
    }

    /// TextMouth became active: says what waited, and checks every book
    /// being edited for an edit saved meanwhile.
    func appBecameActive() {
        announcePending()
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
                end(bookID)
            }
        case .adopted(let edit):
            announcedRefusals[bookID] = nil
            library?.commitTextEdit(edit)
            announce(BookTextEditWording.updated)
        case .refused(let refusal, let digest, let keptCopy):
            let refused = BookTextEditSessions.RefusedEdit(digest: digest, refusal: refusal)
            guard announcedRefusals[bookID] != refused else { return }
            announcedRefusals[bookID] = refused
            if let keptCopy {
                announcedCopies[bookID, default: []].insert(keptCopy)
            }
            announce(BookTextEditWording.notTaken(refusal, bookTitle: title, keptCopy: keptCopy))
        case .replaced(let keptCopy):
            guard announcedCopies[bookID, default: []].insert(keptCopy).inserted else { return }
            announcedRefusals[bookID] = nil
            announce(BookTextEditWording.replaced(bookTitle: title, keptCopy: keptCopy))
        }
    }

    // MARK: Announcing

    /// Announces `message` now while TextMouth is active, from `window`
    /// when given; otherwise keeps it until TextMouth becomes active, so it
    /// never talks over the user's editing in another app.
    private func announce(_ message: String, from window: NSWindow? = nil) {
        guard isAppActive() else {
            if !pendingAnnouncements.contains(message) {
                pendingAnnouncements.append(message)
            }
            return
        }
        VoiceOverAnnouncer.announce(message, from: window)
    }

    /// Announces what waited for TextMouth to become active, as one message.
    private func announcePending() {
        guard !pendingAnnouncements.isEmpty else { return }
        let message = pendingAnnouncements.joined(separator: ". ")
        pendingAnnouncements = []
        VoiceOverAnnouncer.announce(message)
    }

    // MARK: The System's Dialogs and Workspace

    /// The first-use explanation as an alert over `window` (or the app):
    /// Continue, which Return presses, and Cancel, which Escape presses.
    static func explainWithAlert(bookTitle: String, window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.messageText = BookTextEditWording.explanationTitle(bookTitle: bookTitle)
        alert.informativeText = BookTextEditWording.explanation
        alert.addButton(withTitle: BookTextEditWording.continueTitle)
        let cancel = alert.addButton(withTitle: BookTextEditWording.cancelTitle)
        cancel.keyEquivalent = "\u{1b}"
        guard let window else {
            return alert.runModal() == .alertFirstButtonReturn
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
        }
    }

    /// The app chooser of Edit Text With…: an open panel of apps, starting
    /// in Applications, over `window` (or on its own).
    static func chooseAppWithPanel(bookTitle: String, window: NSWindow?) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = BookTextEditWording.appPanelTitle
        panel.message = BookTextEditWording.appPanelMessage(bookTitle: bookTitle)
        panel.prompt = BookTextEditWording.appPanelPrompt
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.url : nil
    }

    /// Opens `file` in `app`, or in the default app for Markdown, falling
    /// back to TextEdit when no app opens Markdown.
    static func openWithWorkspace(_ file: URL, app: URL?) async throws {
        let workspace = NSWorkspace.shared
        let chosen = app
            ?? workspace.urlForApplication(toOpen: file)
            ?? workspace.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
        guard let chosen else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: file])
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // The workspace reports on a queue of its own; the continuation
        // hands its answer back here.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            workspace.open([file], withApplicationAt: chosen, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

// MARK: - Watching content.md

/// Watches one book's content.md for saves and says when a burst of them
/// has settled (FR05).
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

import AppKit

/// What Edit Text (FR05, `BookTextEditor`) and Edit Manifest (FR17,
/// `BookManifestEditor`) share: a file of a book's package opened in the
/// user's own editor, and the edits saved there taken back.
///
/// The file opens in the default app for it, or in an app the user chooses,
/// after an explanation given the first time on this Mac. While a book is
/// edited, a watcher on its file (`ContentFileWatcher`), and TextMouth
/// becoming the active app, check it for an edit, which each editor takes
/// in its own way. What VoiceOver is told is said at once while TextMouth
/// is active, and otherwise kept until it becomes active, so it never talks
/// over the user's editing in another app.
@MainActor
final class PackageFileEditing {
    /// Explains what the edit does, for the book titled with the string,
    /// over the window, and says whether the user goes on.
    typealias Explainer = @MainActor (_ bookTitle: String, _ window: NSWindow?) async -> Bool
    /// Asks which app to edit the book titled with the string in; nil when
    /// the user cancels.
    typealias AppChooser = @MainActor (_ bookTitle: String, _ window: NSWindow?) async -> URL?
    /// Opens a file in an app, or in the default app for it when nil.
    typealias Opener = @MainActor (_ file: URL, _ app: URL?) async throws -> Void

    /// The words of one kind of edit's explanation and app chooser; the
    /// buttons are the same for every kind (`BookTextEditWording`).
    struct Wording {
        /// The explanation's title, for the book titled with the string.
        let explanationTitle: (String) -> String
        /// What the explanation says will happen.
        let explanation: String
        /// The app chooser's title.
        let appPanelTitle: String
        /// The app chooser's message, for the book titled with the string.
        let appPanelMessage: (String) -> String
    }

    /// Where the user said to open the file.
    enum EditorChoice: Equatable {
        /// The default app for the file.
        case defaultApp
        /// The app the user chose.
        case chosen(URL)

        /// The app to open the file in; nil for the default app.
        var app: URL? {
            if case .chosen(let app) = self { return app }
            return nil
        }
    }

    /// Whether this kind of edit has explained itself on this Mac.
    private let explainedPreference: StoredPreference<Bool>
    /// Where the explanation is remembered.
    private let preferences: UserDefaults
    /// Where TextMouth's becoming active is heard.
    private let notificationCenter: NotificationCenter
    /// Explains the edit the first time; tests answer for the user.
    let explain: Explainer
    /// Chooses the app for the "With…" command; tests choose without a panel.
    let chooseApp: AppChooser
    /// Opens the file; tests open nothing.
    let open: Opener
    /// Whether TextMouth is the active app, so an announcement is heard now
    /// rather than when it becomes active; tests say it is.
    let isAppActive: @MainActor () -> Bool
    /// Checks every book being edited, as TextMouth becomes active: set by
    /// the editor that owns this.
    var checkAll: @MainActor () -> Void = {}

    /// The watcher of each edited book's file, by book ID.
    private var watchers: [UUID: ContentFileWatcher] = [:]
    /// What waits to be announced until TextMouth becomes active.
    private var pendingAnnouncements: [String] = []
    /// The observation of TextMouth becoming active, while any book is edited.
    private var activationObserver: NSObjectProtocol?

    /// The shared part of an editor that remembers its explanation as
    /// `explainedPreference` in `preferences` and hears TextMouth become
    /// active on `notificationCenter`. The other arguments stand for the
    /// user and the system, as described on the properties they set.
    init(
        explainedPreference: StoredPreference<Bool>,
        preferences: UserDefaults,
        notificationCenter: NotificationCenter,
        explain: @escaping Explainer,
        chooseApp: @escaping AppChooser,
        open: @escaping Opener,
        isAppActive: @escaping @MainActor () -> Bool
    ) {
        self.explainedPreference = explainedPreference
        self.preferences = preferences
        self.notificationCenter = notificationCenter
        self.explain = explain
        self.chooseApp = chooseApp
        self.open = open
        self.isAppActive = isAppActive
    }

    // MARK: Choosing the Editor

    /// Explains the edit over `window` the first time on this Mac, then,
    /// when `choosingApp`, asks which app to edit the book titled
    /// `bookTitle` in. Nil when the user cancels either.
    func chooseEditor(bookTitle: String, choosingApp: Bool, from window: NSWindow?) async -> EditorChoice? {
        if !explainedPreference.read(from: preferences) {
            guard await explain(bookTitle, window) else { return nil }
            explainedPreference.write(true, to: preferences)
        }
        guard choosingApp else { return .defaultApp }
        guard let chosen = await chooseApp(bookTitle, window) else { return nil }
        return .chosen(chosen)
    }

    // MARK: Watching

    /// The books whose files are watched.
    var watchedBookIDs: Set<UUID> {
        Set(watchers.keys)
    }

    /// Watches the file `file` names for the book `bookID`, calling
    /// `changed` once each burst of saves has settled, and listens for
    /// TextMouth becoming active.
    func watch(_ bookID: UUID, file: @escaping @MainActor () -> URL?, changed: @escaping @MainActor () -> Void) {
        watchers[bookID]?.cancel()
        watchers[bookID] = ContentFileWatcher(file: file, changed: changed)
        observeActivation()
    }

    /// Stops watching the book `bookID`'s file, and stops listening for
    /// TextMouth becoming active once no book is watched.
    func stopWatching(_ bookID: UUID) {
        watchers.removeValue(forKey: bookID)?.cancel()
        if watchers.isEmpty, let observer = activationObserver {
            notificationCenter.removeObserver(observer)
            activationObserver = nil
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
        checkAll()
    }

    // MARK: Announcing

    /// Announces `message` now while TextMouth is active, from `window`
    /// when given; otherwise keeps it until TextMouth becomes active, so it
    /// never talks over the user's editing in another app.
    func announce(_ message: String, from window: NSWindow? = nil) {
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

    /// The first-use explanation worded by `wording`, as an alert over
    /// `window` (or the app): Continue, which Return presses, and Cancel,
    /// which Escape presses.
    static func explainWithAlert(_ wording: Wording, bookTitle: String, window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.messageText = wording.explanationTitle(bookTitle)
        alert.informativeText = wording.explanation
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

    /// The app chooser worded by `wording`: an open panel of apps, starting
    /// in Applications, over `window` (or on its own).
    static func chooseAppWithPanel(_ wording: Wording, bookTitle: String, window: NSWindow?) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = wording.appPanelTitle
        panel.message = wording.appPanelMessage(bookTitle)
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

    /// Opens `file` in `app`, or in the default app for its kind (Markdown
    /// for content.md, JSON for manifest.json), falling back to TextEdit
    /// when no app opens that kind.
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

import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Hides context-specific menu bar items (Playback, Navigate, etc.) when
    /// the focused window doesn't support them, so VoiceOver doesn't encounter
    /// empty, non-interactive menus.
    let menuVisibilityManager = MenuVisibilityManager()

    /// Opens the next book's reader for Continue to Next Book when no
    /// Library window is open to receive the notification and open it.
    private var continueToNextBookFallback: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let buildIdentity = BuildIdentity.current
        NSLog("%@", buildIdentity.diagnosticLine)
        try? TextMouthPaths.ensureDirectoryStructure()
        TextMouthPaths.appendLog(
            to: TextMouthPaths.debugLogFile,
            message: buildIdentity.diagnosticLine
        )

        // Disable automatic window tabbing (prevents "New Tab" menu proliferation)
        NSWindow.allowsAutomaticWindowTabbing = false

        Self.disableWindowRestoration()

        // Start hiding/showing context-specific menus based on active window type
        menuVisibilityManager.startObserving()

        // A Library window opens the next book's reader for Continue to
        // Next Book. With none open, nothing would, so the app does.
        continueToNextBookFallback = NotificationCenter.default
            .publisher(for: .continueToNextBook)
            .sink { notification in
                guard let bookID = notification.nextBookID else { return }
                Self.openContinuedBookIfNoLibraryWindow(
                    bookID,
                    router: .shared,
                    keyWindow: NSApp.keyWindow
                )
            }
    }

    /// Disables macOS automatic window state restoration
    /// (`NSQuitAlwaysKeepsWindows`), so previous sessions don't spawn extra
    /// library or reader windows on launch. Only one library window should
    /// appear on startup; additional ones require Cmd+N.
    ///
    /// - Parameter preferences: Where the setting is saved: this process's
    ///   preferences. In the app they are the standard store AppKit reads;
    ///   under hosted tests they are the sandbox's, so the test host never
    ///   rewrites the developer's own copy of the setting.
    static func disableWindowRestoration(in preferences: UserDefaults = TextMouthRuntime.current.preferences) {
        preferences.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Allows SwiftUI to create its initial Library window, but suppresses the
    /// extra untitled Library scene AppKit otherwise requests while opening a
    /// document-style URL into an already-windowed application.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        Self.shouldOpenUntitledLibrary(
            hasOpenLibraryWindow: LibraryWindowRouter.shared.hasRegisteredWindow
        )
    }

    /// Pure policy core keeps the AppKit delegate decision testable without
    /// driving an application-launch Apple event.
    static func shouldOpenUntitledLibrary(hasOpenLibraryWindow: Bool) -> Bool {
        !hasOpenLibraryWindow
    }

    /// The app-level fallback for Continue to Next Book: when no Library
    /// window is registered to open the next book's reader, open it
    /// through an open reader window instead.
    ///
    /// The router's choice keeps this and the Library windows mutually
    /// exclusive: while any Library window is registered, exactly one of
    /// them opens the reader and this does nothing. SwiftUI gives
    /// `openWindow` only to views, never to the app or its delegate, so
    /// the reader opens through the action a reader window lent the
    /// router. With no window open at all there is none, and the request
    /// left for the book simply expires.
    ///
    /// - Parameters:
    ///   - bookID: The next book, named by the notification.
    ///   - router: The registry of open Library and reader windows.
    ///   - keyWindow: The window currently receiving keystrokes.
    /// - Returns: Whether this fallback opened the reader window.
    @discardableResult
    static func openContinuedBookIfNoLibraryWindow(
        _ bookID: UUID,
        router: LibraryWindowRouter,
        keyWindow: NSWindow?
    ) -> Bool {
        guard case .appFallback = router.continueToNextBookOpener(keyWindow: keyWindow) else {
            return false
        }
        if router.openReaderWindow(for: bookID, keyWindow: keyWindow) {
            return true
        }
        TextMouthPaths.appendLog(
            to: TextMouthPaths.debugLogFile,
            message: "continue to next book: no window is open to open \(bookID) from"
        )
        return false
    }

    // MARK: - Termination

    /// Holds a quit while the failure center reports unsaved changes.
    private let terminationGuard = UnsavedChangesTerminationGuard()

    /// Whether TextMouth may quit now (TODO S09). The exact sequence:
    ///
    /// 1. Here, everything pending is flushed as the termination path
    ///    flushes it, but nothing is ended: the library index and every
    ///    queued book record (`LibraryPersistenceService.flushPendingSave`),
    ///    then the statistics, whose open listening session is credited so
    ///    far and left open (`ReadingStatsService.flushPendingSaves`).
    ///    Settings and substitution rules are written as they change. Each
    ///    write's failure reaches the failure center before its flush ends.
    /// 2. With nothing unsaved, TextMouth quits: `applicationWillTerminate`
    ///    then shuts down as it always has, in its order: menu observation
    ///    stops, the config watcher stops, pending saves are flushed again,
    ///    the listening session ends, the statistics are flushed, and their
    ///    timer stops.
    /// 3. With changes unsaved, this request is cancelled, once, and an
    ///    alert names what is unsaved, with Retry, Quit Anyway, and Cancel.
    ///    Retry runs every unsaved write again and asks to quit again,
    ///    which starts over at step 1. Quit Anyway asks to quit again, and
    ///    that second request quits at step 2, whatever is unsaved. Cancel
    ///    keeps TextMouth open.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminationGuard.reply()
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuVisibilityManager.stopObserving()
        ConfigService.shared.shutdown()
        LibraryPersistenceService.flushPendingSave()
        let statsService = ReadingStatsService.shared
        statsService.endSession()
        statsService.flushPendingSaves()
        statsService.shutdown()
    }

    /// Handle files opened via Finder "Open With" or drag-to-dock
    func application(_ application: NSApplication, open urls: [URL]) {
        NotificationCenter.default.post(
            name: .openFilesFromFinder,
            object: nil,
            userInfo: ["urls": urls]
        )
    }
}

extension Notification.Name {
    static let openFilesFromFinder = Notification.Name("openFilesFromFinder")
}

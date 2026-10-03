import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Hides context-specific menu bar items (Playback, Navigate, etc.) when
    /// the focused window doesn't support them, so VoiceOver doesn't encounter
    /// empty, non-interactive menus.
    let menuVisibilityManager = MenuVisibilityManager()

    /// Starts routing app-wide actions (TODO A05) before Finder can hand
    /// over a book at launch. SwiftUI opens the first Library window itself,
    /// so an action that arrives before that window registers waits for it
    /// instead of opening a second.
    func applicationWillFinishLaunching(_ notification: Notification) {
        let router = LibraryWindowRouter.shared
        router.expectLibraryWindow()
        router.listen(to: .default)
    }

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

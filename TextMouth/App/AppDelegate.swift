import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Hides context-specific menu bar items (Playback, Navigate, etc.) when
    /// the focused window doesn't support them, so VoiceOver doesn't encounter
    /// empty, non-interactive menus.
    let menuVisibilityManager = MenuVisibilityManager()

    /// The router that takes app-wide actions: the shared one, which the
    /// Library and reader windows register with, unless a test sets its own.
    var router = LibraryWindowRouter.shared

    /// Starts routing app-wide actions (TODO A05) before Finder can hand
    /// over a book at launch. SwiftUI opens the first Library window itself,
    /// so an action that arrives before that window registers waits for it
    /// instead of opening a second. Later, an action no open window can take
    /// opens a Library window through SwiftUI's main scene.
    func applicationWillFinishLaunching(_ notification: Notification) {
        router.openLibraryWindow = Self.openLibraryWindowThroughSwiftUI
        router.expectLibraryWindow()
        router.listen(to: .default)
    }

    /// Opens a new Library window the way AppKit asks SwiftUI for one when
    /// the app is reopened with no window: SwiftUI's own application
    /// delegate, which forwards to this one, answers
    /// `applicationOpenUntitledFile(_:)` by opening a window of the app's
    /// main scene, the Library. In the running app this opens exactly one
    /// Library window, which registers with the router at once, whether a
    /// Library window, only readers, or no window at all is open.
    ///
    /// This delegate must never implement `applicationOpenUntitledFile(_:)`
    /// itself: SwiftUI would hand the call here instead of opening a window.
    ///
    /// Other ways fall short (tried in the running app, TODO A05). No
    /// responder answers `newWindow:`, so sending it does nothing. A reader
    /// window's `openWindow` cannot name the Library scene, which has no
    /// identifier, and exists only while a reader is open. A reopen event
    /// opens a window only while no window at all is visible. File > New >
    /// New Window works, but only by finding the menu item by its title.
    ///
    /// - Returns: Whether SwiftUI opened a Library window.
    static func openLibraryWindowThroughSwiftUI() -> Bool {
        NSApp.delegate?.applicationOpenUntitledFile?(NSApp) ?? false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The data directory first, so its Logs folder can take the line.
        try? TextMouthPaths.ensureDirectoryStructure()
        Self.logBuildIdentity(.current)

        // Disable automatic window tabbing (prevents "New Tab" menu proliferation)
        NSWindow.allowsAutomaticWindowTabbing = false

        Self.disableWindowRestoration()

        // Start hiding/showing context-specific menus based on active window type
        menuVisibilityManager.startObserving()
    }

    /// Records which build is running, as launch does: in the unified log,
    /// which Console shows even for an app opened from Finder, and as the
    /// debug log's `BUILD_IDENTITY` line, an event of the app category
    /// (`DiagnosticLog`), so it is written whether or not tracing is on.
    static func logBuildIdentity(_ identity: BuildIdentity) {
        NSLog("%@", identity.diagnosticLine)
        DiagnosticLog.event(.app, identity.diagnosticLine)
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
            hasOpenLibraryWindow: router.hasRegisteredWindow
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

    /// Takes the items opened from Finder, with Open With, a drop on the
    /// Dock icon, or a launch to open them, as one app-wide action: the
    /// Library window the router chooses imports them and opens each book
    /// (TODO A05). With every Library window closed, SwiftUI shows one again
    /// before this is called; on a cold launch, before any Library window
    /// has registered, the items wait for the first one.
    func application(_ application: NSApplication, open urls: [URL]) {
        router.route(.openFiles(urls))
    }
}

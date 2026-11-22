import AppKit

// MARK: - Menu Visibility Manager
//
// OVERVIEW
// --------
// SwiftUI's CommandsBuilder does not support conditional top-level menus.
// You cannot write `if condition { CommandMenu("X") { ... } }` — it won't
// compile. So even when a CommandMenu's body is empty (because the
// @FocusedValue condition is false), the menu title still appears in the
// menu bar as a non-interactive dead-end. VoiceOver announces these empty
// menus, which is confusing and wastes the user's time.
//
// This class works around the limitation by using AppKit's NSMenuItem.isHidden
// to hide menu bar items that don't apply to the current window type. It
// observes NSWindow.didBecomeMainNotification / didResignMainNotification and
// applies visibility rules on each change.
//
// HOW IT WORKS
// ------------
// 1. Each CommandMenu in MenuCommands.swift keeps real contents in its body.
//    The menu title visibility below decides whether those contents are
//    reachable for the active window type. Keeping bodies populated avoids
//    the SwiftUI/AppKit timing bug where a title is visible but its body is
//    empty after the app deactivates and reactivates.
//
// 2. This manager handles the menu *titles* in the menu bar. It reads
//    NSApp.mainWindow, determines which ActiveWindowType it is, and sets
//    isHidden on the corresponding NSMenuItems in NSApp.mainMenu.
//
// 3. Window type detection uses the NSWindow.identifier assigned by SwiftUI:
//    - Reader windows: identifier contains "book-reader" (from the
//      WindowGroup id: "book-reader" in TextMouthApp.swift)
//    - Settings window: identifier starts with "com_apple_SwiftUI_Settings"
//      (assigned by SwiftUI's Settings scene — NOT an NSPanel, and its title
//      is the current tab name like "Shortcuts", not "Settings")
//    - The Record window: identifier "new-recording", set by
//      RecordingWindowController — no context menus, as Settings
//    - Audio editor windows: identifier "audio-editor", set by
//      AudioEditorWindowController — no context menus either
//    - Library windows: the fallback — any titled, non-utility window that
//      didn't match the above checks
//    - No window (nil): all context menus hidden
//
// ADDING A NEW WINDOW TYPE
// ------------------------
// To add a new window type (e.g. a statistics window) with its own menus:
//
// 1. Add a case to ActiveWindowType in MenuCommands.swift (e.g. .statistics)
//
// 2. In your new window's root view, set the focused value:
//      .focusedValue(\.activeWindowType, .statistics)
//
// 3. Create your CommandMenu in MenuCommands.swift, guarding its items with:
//      if windowType == .statistics { ... }
//
// 4. In this file, add the menu title(s) to a new static set:
//      static let statisticsMenuTitles: Set<String> = ["Statistics"]
//    and add it to allContextMenuTitles.
//
// 5. In detectWindowType, add a check BEFORE the library fallback. Use the
//    window's identifier (not its title — SwiftUI may set the title to
//    anything). For a WindowGroup with id: "stats-window", check:
//      if identifier.contains("stats-window") { return .statistics }
//
// 6. In applyVisibility, add a clause for the new titles:
//      } else if statisticsMenuTitles.contains(title) {
//          item.isHidden = (windowType != .statistics)
//      }
//
// 7. Add tests in MenuVisibilityTests.swift (both the mirrored type and
//    the test functions).
//
// PITFALLS TO WATCH FOR
// ---------------------
// - Window identifiers: SwiftUI generates long identifiers that include the
//   full view type chain (e.g. "SwiftUI.ModifiedContent<TextMouth.Settings
//   ViewModel>..."). Use contains() for your own WindowGroup ids (which
//   appear as substrings) but use hasPrefix() for system identifiers like
//   "com_apple_SwiftUI_Settings" to avoid false matches against type names
//   that happen to contain the same word.
//
// - The library window is the fallback case (no explicit identifier check).
//   New window types MUST be detected before the library fallback or they
//   will be misidentified as library windows.
//
// - Settings is a regular NSWindow, not an NSPanel. Don't rely on
//   `window is NSPanel` to detect it.
//
// - The title of the Settings window is the current tab name (e.g.
//   "Shortcuts", "General"), not "Settings" or "Preferences". Don't use
//   window.title to detect it.

/// Manages hiding and showing context-specific menu bar items based on the
/// active window type, so VoiceOver users don't encounter empty menus.
/// See the file-level comment above for architecture details and instructions
/// on adding new window types.
@MainActor
final class MenuVisibilityManager {

    // MARK: - Menu Title Sets
    //
    // Each set contains the title strings of CommandMenus that should only be
    // visible for that window type. A menu shows its title from `MenuWording`
    // (the same member its `CommandMenu` is given), which reads the interface
    // language: the Bookmarks menu reads "Marcadores" in Spanish. Each set
    // therefore holds every title's text in the interface language AND in
    // English, or the menu would stop hiding in any language whose word
    // differs. The sets are built from the wording members themselves, so a
    // menu and its title set can never disagree.

    /// The wording of the CommandMenus that appear only when a reader window
    /// is focused: the one list the reader's title set is built from.
    static let readerMenuWording: [() -> String] = [
        { MenuWording.playback }, { MenuWording.navigate }, { MenuWording.bookmarks }, { MenuWording.book }
    ]

    /// The wording of the CommandMenus that appear only when a library window
    /// is focused.
    static let libraryMenuWording: [() -> String] = [{ MenuWording.library }]

    /// The titles a menu bar item may show for `wording`: each title in the
    /// interface language in use now (exactly what the `CommandMenu` puts in
    /// the menu bar), in English (what a menu shows when its language has no
    /// text, and what the menus were named before), and in each of
    /// `languages`. A computed value rather than a stored one, so a language
    /// change is never cached away.
    ///
    /// - Parameters:
    ///   - wording: Wording members of `MenuWording`, one for each CommandMenu.
    ///   - languages: Further interface languages to read each title in
    ///     (codes such as "es"); tests pass Spanish to prove the Spanish title
    ///     is in the set.
    static func titles(for wording: [() -> String], languages: [String] = []) -> Set<String> {
        Set(wording.flatMap { title -> [String] in
            // The member read under each language in turn: a test's task-local
            // language makes the engine answer in it, with nothing global changed.
            let others = (["en"] + languages).map { language in
                InterfaceLanguage.$scopedLanguage.withValue(language) { title() }
            }
            return [title()] + others
        })
    }

    /// Menu titles that should only appear when a reader window is focused
    static var readerMenuTitles: Set<String> { titles(for: readerMenuWording) }

    /// Menu titles that should only appear when a library window is focused
    static var libraryMenuTitles: Set<String> { titles(for: libraryMenuWording) }

    /// All context-specific menu titles (union of all window-type sets).
    /// Standard menus (File, Edit, View, Window, Help) are never touched.
    static var allContextMenuTitles: Set<String> { readerMenuTitles.union(libraryMenuTitles) }

    // MARK: - Observation

    /// NotificationCenter observers, removed on deinit
    private var observers: [NSObjectProtocol] = []

    /// Starts observing window focus changes. Called once from AppDelegate
    /// in applicationDidFinishLaunching.
    func startObserving() {
        let refresh: @MainActor @Sendable () -> Void = { [weak self] in
            self?.updateMenuVisibility()
        }
        // Window became main (gained focus) — update immediately
        let becameMain = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { refresh() }
        }
        observers.append(becameMain)

        // Window resigned main — delayed update so the new main window has
        // time to activate. Covers the case where the last window closes
        // and no window is main (hides all context menus).
        let resignedMain = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignMainNotification,
            object: nil,
            queue: .main
        ) { _ in
            DispatchQueue.main.async { refresh() }
        }
        observers.append(resignedMain)

        // App activation/deactivation can leave NSApp.mainWindow and SwiftUI
        // focused values briefly out of phase. Refresh on both edges so
        // returning from another app does not leave context menus hidden or
        // visible with stale contents.
        let becameActive = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            DispatchQueue.main.async { refresh() }
        }
        observers.append(becameActive)

        let resignedActive = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { refresh() }
        }
        observers.append(resignedActive)

        // SwiftUI may construct or refresh a window's focused values after
        // AppKit has already delivered the window-main notification. Views can
        // post this once they know their host window exists.
        let explicitRefresh = NotificationCenter.default.addObserver(
            forName: .refreshContextMenus,
            object: nil,
            queue: .main
        ) { _ in
            DispatchQueue.main.async { refresh() }
        }
        observers.append(explicitRefresh)

        // A switch of the interface language gives every menu a new title, which the visibility rules compare against
        // (`titles(for:)` reads each in the language in use). Once SwiftUI has rebuilt the menu bar's items, the bar's
        // layout direction follows the language and the rules apply again, so every context menu is found by its new
        // title and none is left showing in a window that should hide it (FR39).
        let languageChanged = NotificationCenter.default.addObserver(
            forName: InterfaceLanguage.didChange,
            object: nil,
            queue: .main
        ) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Self.applyLayoutDirection(of: NSApp.mainMenu, for: InterfaceLanguage.current)
                    refresh()
                }
            }
        }
        observers.append(languageChanged)

        // Initial update after SwiftUI has built the menu bar
        DispatchQueue.main.async { [weak self] in
            self?.updateMenuVisibility()
        }
    }

    /// Sets `menu`'s layout direction to the language's: right to left for Arabic, Hebrew, Persian, and Urdu. The menu
    /// items macOS supplies itself change their words and their side only from the next launch (FR39).
    static func applyLayoutDirection(of menu: NSMenu?, for state: InterfaceLanguage.State) {
        menu?.userInterfaceLayoutDirection = state.isRightToLeft ? .rightToLeft : .leftToRight
    }

    /// Removes all notification observers.
    func stopObserving() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    // MARK: - Core Logic

    /// Reads the current main window, determines its type, and applies
    /// visibility rules to all menu bar items.
    func updateMenuVisibility() {
        let activeWindow = NSApp.mainWindow ?? NSApp.keyWindow
        let windowType = Self.detectWindowType(for: activeWindow)
        Self.applyVisibility(for: windowType, to: NSApp.mainMenu)
    }

    /// Determines the ActiveWindowType for the given window by inspecting
    /// its identifier. Returns nil for windows that aren't library or reader
    /// (e.g. Settings, About), which causes all context menus to be hidden.
    ///
    /// Detection order matters — the library case is a fallback that matches
    /// any titled, non-utility window. New window types must be checked
    /// BEFORE the library fallback.
    static func detectWindowType(for window: NSWindow?) -> ActiveWindowType? {
        guard let window = window else { return nil }

        let identifier = window.identifier?.rawValue ?? ""

        // --- Reader windows ---
        // Opened via WindowGroup("Book Reader", id: "book-reader", ...) in
        // TextMouthApp.swift. SwiftUI includes "book-reader" in the identifier.
        if identifier.contains(BookReaderWindowView.windowID) {
            return .reader
        }

        // --- Settings window ---
        // SwiftUI's Settings scene creates a regular NSWindow (not NSPanel!)
        // with identifier "com_apple_SwiftUI_Settings_window". The window
        // title is the current tab name (e.g. "Shortcuts", "General"), NOT
        // "Settings" or "Preferences".
        //
        // IMPORTANT: Use hasPrefix, not contains. Library window identifiers
        // include the full SwiftUI view type chain which contains
        // "SettingsViewModel" — a contains("Settings") check would match
        // library windows too.
        if identifier.hasPrefix("com_apple_SwiftUI_Settings") {
            return nil
        }

        // --- The Record window ---
        // An AppKit window TextMouth makes itself and names exactly
        // (RecordingWindowController.windowIdentifier, FR04). It is neither
        // a Library nor a reader window and has no menus of its own, so,
        // like Settings, it shows no context menu.
        if identifier == RecordingWindowController.windowIdentifier {
            return nil
        }

        // --- The Search Library window ---
        // An AppKit window TextMouth makes itself and names exactly
        // (LibrarySearchWindowController.windowIdentifier). It is neither a
        // Library nor a reader window, and must not fall to the Library
        // fallback below, which would show the Library's menus over a window
        // that cannot use them.
        if identifier == LibrarySearchWindowController.windowIdentifier {
            return nil
        }

        // --- The audio editor ---
        // AppKit windows TextMouth makes itself, one for each book being
        // edited, all named exactly (AudioEditorWindowController
        // .windowIdentifier, FR04). Neither Library nor reader windows, and
        // with no menus of their own, they show no context menu either.
        if identifier == AudioEditorWindowController.windowIdentifier {
            return nil
        }

        // --- Add new window types here ---
        // Check the identifier BEFORE the library fallback below. Example:
        //   if identifier.contains("my-window-id") { return .myType }

        // --- Library windows (fallback) ---
        // The library WindowGroup is the default (no explicit id), so its
        // identifier is a long SwiftUI-generated string. Any titled,
        // non-utility window that wasn't caught above is assumed to be a
        // library window.
        if window.styleMask.contains(.titled) && !window.styleMask.contains(.utilityWindow) {
            return .library
        }

        return nil
    }

    /// Sets isHidden on each context-specific menu item in the given menu
    /// based on the active window type. Standard menus (File, Edit, etc.)
    /// are never modified.
    ///
    /// When adding a new window type, add an `else if` clause here matching
    /// the new title set against the new ActiveWindowType case.
    static func applyVisibility(for windowType: ActiveWindowType?, to mainMenu: NSMenu?) {
        guard let mainMenu = mainMenu else { return }

        // Built once per call: each set holds each title in the interface language and in English.
        let readerTitles = readerMenuTitles
        let libraryTitles = libraryMenuTitles

        for item in mainMenu.items {
            let title = item.title

            if readerTitles.contains(title) {
                item.isHidden = (windowType != .reader)
            } else if libraryTitles.contains(title) {
                item.isHidden = (windowType != .library)
            }
            // When adding a new window type:
            // } else if newTypeMenuTitles.contains(title) {
            //     item.isHidden = (windowType != .newType)
            // }
        }
    }
}

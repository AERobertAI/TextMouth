import AppKit

/// Manages hiding and showing context-specific menu bar items based on the
/// active window type. SwiftUI's CommandsBuilder does not support conditional
/// logic at the top level, so empty CommandMenu titles still appear in the
/// menu bar as non-interactive dead-ends — particularly problematic for
/// VoiceOver users. This class uses AppKit's NSMenuItem.isHidden to fully
/// remove irrelevant menus from the bar when they have no applicable items.
final class MenuVisibilityManager {

    /// Menu titles that should only appear when a reader window is focused
    static let readerMenuTitles: Set<String> = ["Playback", "Navigate", "Bookmarks"]

    /// Menu titles that should only appear when a library window is focused
    static let libraryMenuTitles: Set<String> = ["Library"]

    /// All context-specific menu titles (union of reader + library sets)
    static let allContextMenuTitles: Set<String> = readerMenuTitles.union(libraryMenuTitles)

    /// NotificationCenter observers so we can clean up on deinit
    private var observers: [NSObjectProtocol] = []

    /// Sets up observers for window focus changes and performs an initial update.
    func startObserving() {
        // Update menus whenever a window becomes main (gains focus)
        let becameMain = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateMenuVisibility()
        }
        observers.append(becameMain)

        // Update when a window resigns main — covers the case where the last
        // window closes and no window is main (hide all context menus)
        let resignedMain = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Small delay so the new main window has time to become active
            DispatchQueue.main.async {
                self?.updateMenuVisibility()
            }
        }
        observers.append(resignedMain)

        // Initial update after SwiftUI has built the menu bar. A slight delay
        // ensures the main menu is populated before we attempt to modify it.
        DispatchQueue.main.async { [weak self] in
            self?.updateMenuVisibility()
        }
    }

    /// Stops observing window changes and removes all notification observers.
    func stopObserving() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    deinit {
        stopObserving()
    }

    // MARK: - Core Logic

    /// Determines the active window type from the current main window and
    /// hides or shows menus accordingly. Extracted as a static method so
    /// unit tests can verify the logic without needing live windows.
    func updateMenuVisibility() {
        let windowType = Self.detectWindowType(for: NSApp.mainWindow)
        Self.applyVisibility(for: windowType, to: NSApp.mainMenu)
    }

    /// Detects the window type by checking the main window's content view
    /// for a focusedValue marker. Library windows use LibraryWindowView and
    /// reader windows use BookReaderWindowView — both set .focusedValue on
    /// their root view. We identify the type by the window's title and
    /// content structure.
    static func detectWindowType(for window: NSWindow?) -> ActiveWindowType? {
        guard let window = window else { return nil }

        // Reader windows are opened with the "Book Reader" window group,
        // which gives them an identifier containing "book-reader".
        if let identifier = window.identifier?.rawValue,
           identifier.contains("book-reader") {
            return .reader
        }

        // The library WindowGroup is the default (no explicit id), so library
        // windows will NOT have "book-reader" in their identifier. We also
        // check that the window is not a settings/preferences panel.
        if window.styleMask.contains(.titled) && !window.styleMask.contains(.utilityWindow) {
            // Settings windows typically have "Preferences" or "Settings" title,
            // and use a different style. Library windows are the default.
            let title = window.title
            if title == "Settings" || title == "Preferences" {
                return nil
            }
            return .library
        }

        return nil
    }

    /// Applies the visibility rules to all items in the given main menu.
    /// Reader-only menus are hidden unless windowType is .reader, and
    /// library-only menus are hidden unless windowType is .library.
    static func applyVisibility(for windowType: ActiveWindowType?, to mainMenu: NSMenu?) {
        guard let mainMenu = mainMenu else { return }

        for item in mainMenu.items {
            let title = item.title

            if readerMenuTitles.contains(title) {
                item.isHidden = (windowType != .reader)
            } else if libraryMenuTitles.contains(title) {
                item.isHidden = (windowType != .library)
            }
        }
    }
}

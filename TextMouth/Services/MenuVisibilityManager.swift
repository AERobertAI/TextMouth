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

        // Also observe key window changes — panels like Settings become key
        // without becoming main, so didBecomeMain alone misses them.
        let becameKey = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateMenuVisibility()
        }
        observers.append(becameKey)

        let resignedKey = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateMenuVisibility()
            }
        }
        observers.append(resignedKey)

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

    /// Determines the active window type from the frontmost window and
    /// hides or shows menus accordingly. Checks the key window first
    /// because panels (like Settings) become key but not main — if the
    /// key window is a non-app window we should hide all context menus
    /// rather than showing stale menus from the main window behind it.
    func updateMenuVisibility() {
        let effectiveWindow = Self.effectiveWindow()
        let windowType = Self.detectWindowType(for: effectiveWindow)
        Self.applyVisibility(for: windowType, to: NSApp.mainMenu)
    }

    /// Returns the window that should drive menu visibility. The key window
    /// takes priority because panels (Settings, About) become key without
    /// becoming main. If the key window is not a library or reader window,
    /// returning it lets detectWindowType return nil, hiding all context
    /// menus. Falls back to mainWindow when no key window exists.
    static func effectiveWindow() -> NSWindow? {
        if let keyWindow = NSApp.keyWindow {
            return keyWindow
        }
        return NSApp.mainWindow
    }

    /// Detects the window type from the given window. Reader windows are
    /// identified by their "book-reader" window group identifier. Library
    /// windows are the default WindowGroup (no special id). Panels like
    /// Settings, About, and other non-document windows return nil.
    static func detectWindowType(for window: NSWindow?) -> ActiveWindowType? {
        guard let window = window else { return nil }

        // Panels (Settings, About, color pickers, etc.) are never library
        // or reader windows. NSPanel is a subclass of NSWindow.
        if window is NSPanel {
            return nil
        }

        // Reader windows are opened with the "Book Reader" window group,
        // which gives them an identifier containing "book-reader".
        if let identifier = window.identifier?.rawValue,
           identifier.contains("book-reader") {
            return .reader
        }

        // The library WindowGroup is the default (no explicit id), so library
        // windows will NOT have "book-reader" in their identifier. Filter out
        // any other non-document windows by title as an extra safety check.
        if window.styleMask.contains(.titled) && !window.styleMask.contains(.utilityWindow) {
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

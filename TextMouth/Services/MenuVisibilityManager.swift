import AppKit

/// Manages hiding and showing context-specific menu bar items based on the
/// active window type. SwiftUI's CommandsBuilder does not support conditional
/// logic at the top level, so empty CommandMenu titles still appear in the
/// menu bar as non-interactive dead-ends — particularly problematic for
/// VoiceOver users.
///
/// Uses two strategies:
/// - NSMenuItem.isHidden for menus where SwiftUI respects the flag
/// - Physical removal from NSApp.mainMenu for menus where SwiftUI resets
///   isHidden (notably "Library"). Removed items are stored and re-inserted
///   when they should be visible again.
///
/// Applied in applicationWillUpdate so it runs after SwiftUI's own menu
/// rebuild cycle, getting the last word on visibility.
final class MenuVisibilityManager {

    /// Menu titles that should only appear when a reader window is focused
    static let readerMenuTitles: Set<String> = ["Playback", "Navigate", "Bookmarks"]

    /// Menu titles that should only appear when a library window is focused
    static let libraryMenuTitles: Set<String> = ["Library"]

    /// All context-specific menu titles (union of reader + library sets)
    static let allContextMenuTitles: Set<String> = readerMenuTitles.union(libraryMenuTitles)

    /// Stores menu items that have been removed from the menu bar, keyed by
    /// title. Each entry holds the item and its original index so it can be
    /// re-inserted in the correct position.
    private var removedItems: [String: (item: NSMenuItem, index: Int)] = [:]

    // MARK: - Core Logic

    /// Called from AppDelegate.applicationWillUpdate on every event loop
    /// iteration. Detects the active window type and shows/hides menus.
    func updateMenuVisibility() {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let windowType = Self.detectWindowType(for: window)
        applyVisibility(for: windowType)
    }

    /// Detects the window type from the given window. Reader windows are
    /// identified by their "book-reader" window group identifier. Library
    /// windows are the default WindowGroup. Panels and other non-document
    /// windows return nil.
    static func detectWindowType(for window: NSWindow?) -> ActiveWindowType? {
        guard let window = window else { return nil }

        // Panels (Settings, About, color pickers, etc.) are never library
        // or reader windows.
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
        // windows will NOT have "book-reader" in their identifier.
        if window.styleMask.contains(.titled) && !window.styleMask.contains(.utilityWindow) {
            let title = window.title
            if title == "Settings" || title == "Preferences" {
                return nil
            }
            return .library
        }

        return nil
    }

    /// Shows or hides menus by physically removing them from or re-inserting
    /// them into NSApp.mainMenu. This defeats SwiftUI's tendency to reset
    /// isHidden on certain menus during its update cycle.
    private func applyVisibility(for windowType: ActiveWindowType?) {
        guard let mainMenu = NSApp.mainMenu else { return }

        // First, re-insert any previously removed items that should now be
        // visible, so we can inspect the full menu bar.
        reinsertVisibleItems(for: windowType, into: mainMenu)

        // Now remove items that should be hidden.
        removeHiddenItems(for: windowType, from: mainMenu)
    }

    /// Re-inserts previously removed menu items that should be visible for
    /// the current window type.
    private func reinsertVisibleItems(for windowType: ActiveWindowType?, into mainMenu: NSMenu) {
        // Reader menus should be visible when windowType is .reader
        if windowType == .reader {
            for title in Self.readerMenuTitles {
                reinsertItem(titled: title, into: mainMenu)
            }
        }

        // Library menus should be visible when windowType is .library
        if windowType == .library {
            for title in Self.libraryMenuTitles {
                reinsertItem(titled: title, into: mainMenu)
            }
        }
    }

    /// Removes menu items that should be hidden for the current window type.
    private func removeHiddenItems(for windowType: ActiveWindowType?, from mainMenu: NSMenu) {
        // Hide reader menus when NOT in reader
        if windowType != .reader {
            for title in Self.readerMenuTitles {
                removeItem(titled: title, from: mainMenu)
            }
        }

        // Hide library menus when NOT in library
        if windowType != .library {
            for title in Self.libraryMenuTitles {
                removeItem(titled: title, from: mainMenu)
            }
        }
    }

    /// Removes a menu item by title, storing it for later re-insertion.
    private func removeItem(titled title: String, from mainMenu: NSMenu) {
        // Already removed — nothing to do
        guard removedItems[title] == nil else { return }

        guard let item = mainMenu.items.first(where: { $0.title == title }) else { return }
        let index = mainMenu.index(of: item)
        removedItems[title] = (item: item, index: index)
        mainMenu.removeItem(item)
    }

    /// Re-inserts a previously removed menu item at its original position.
    private func reinsertItem(titled title: String, into mainMenu: NSMenu) {
        guard let stored = removedItems.removeValue(forKey: title) else { return }

        // Clamp the index to the current menu size in case other items
        // were also added or removed since we stored the index.
        let safeIndex = min(stored.index, mainMenu.items.count)
        mainMenu.insertItem(stored.item, at: safeIndex)
    }

    // MARK: - Static helpers for unit testing

    /// Pure-logic version of visibility rules for unit testing with real
    /// NSMenu objects. Uses isHidden since tests don't have SwiftUI
    /// fighting back.
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

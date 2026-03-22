import AppKit

/// Manages hiding and showing context-specific menu bar items based on the
/// active window type. SwiftUI's CommandsBuilder does not support conditional
/// logic at the top level, so empty CommandMenu titles still appear in the
/// menu bar as non-interactive dead-ends — particularly problematic for
/// VoiceOver users. This class uses AppKit's NSMenuItem.isHidden to fully
/// remove irrelevant menus from the bar when they have no applicable items.
///
/// The visibility is applied in applicationWillUpdate rather than via
/// notifications because SwiftUI re-evaluates CommandMenu bodies when
/// @FocusedValue changes, resetting isHidden. applicationWillUpdate fires
/// after SwiftUI's rebuild, so our isHidden always gets the last word.
final class MenuVisibilityManager {

    /// Menu titles that should only appear when a reader window is focused
    static let readerMenuTitles: Set<String> = ["Playback", "Navigate", "Bookmarks"]

    /// Menu titles that should only appear when a library window is focused
    static let libraryMenuTitles: Set<String> = ["Library"]

    /// All context-specific menu titles (union of reader + library sets)
    static let allContextMenuTitles: Set<String> = readerMenuTitles.union(libraryMenuTitles)

    // MARK: - Core Logic

    /// Called from AppDelegate.applicationWillUpdate on every event loop
    /// iteration. Detects the active window type and hides or shows menus.
    func updateMenuVisibility() {
        // Check key window first — panels (Settings, About) become key
        // without becoming main, and should hide all context menus.
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let windowType = Self.detectWindowType(for: window)
        Self.applyVisibility(for: windowType, to: NSApp.mainMenu)
    }

    /// Detects the window type from the given window. Reader windows are
    /// identified by their "book-reader" window group identifier. Library
    /// windows are the default WindowGroup (no special id). Panels and
    /// other non-document windows return nil.
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

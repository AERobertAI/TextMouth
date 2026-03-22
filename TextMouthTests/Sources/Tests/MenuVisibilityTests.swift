import Foundation
import AppKit

// MARK: - Mirrored MenuVisibilityManager (static logic only, for testing)

/// Mirrors the static methods from the app's MenuVisibilityManager so we can
/// test the visibility logic without needing the full app runtime.
enum MenuVisibilityManager {
    /// Menu titles that should only appear when a reader window is focused
    static let readerMenuTitles: Set<String> = ["Playback", "Navigate", "Bookmarks"]

    /// Menu titles that should only appear when a library window is focused
    static let libraryMenuTitles: Set<String> = ["Library"]

    /// All context-specific menu titles (union of reader + library sets)
    static let allContextMenuTitles: Set<String> = readerMenuTitles.union(libraryMenuTitles)

    /// Applies the visibility rules to all items in the given main menu.
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

    /// Detects window type from an NSWindow (nil for nil input).
    static func detectWindowType(for window: NSWindow?) -> ActiveWindowType? {
        guard let window = window else { return nil }

        // Panels (Settings, About, etc.) are never library or reader windows
        if window is NSPanel {
            return nil
        }

        if let identifier = window.identifier?.rawValue,
           identifier.contains("book-reader") {
            return .reader
        }

        if window.styleMask.contains(.titled) && !window.styleMask.contains(.utilityWindow) {
            let title = window.title
            if title == "Settings" || title == "Preferences" {
                return nil
            }
            return .library
        }

        return nil
    }
}

// MARK: - Tests

func runMenuVisibilityTests() {
print("\n--- Menu Visibility Tests ---")

// MARK: - Menu title sets

test("Reader menu titles contains expected menus") {
    let titles = MenuVisibilityManager.readerMenuTitles
    try assertTrue(titles.contains("Playback"), "Should include Playback")
    try assertTrue(titles.contains("Navigate"), "Should include Navigate")
    try assertTrue(titles.contains("Bookmarks"), "Should include Bookmarks")
    try assertEqual(titles.count, 3, "Should have exactly 3 reader menus")
}

test("Library menu titles contains expected menus") {
    let titles = MenuVisibilityManager.libraryMenuTitles
    try assertTrue(titles.contains("Library"), "Should include Library")
    try assertEqual(titles.count, 1, "Should have exactly 1 library menu")
}

test("All context menu titles is union of reader and library") {
    let all = MenuVisibilityManager.allContextMenuTitles
    try assertEqual(all.count, 4, "Should have 4 total context menus")
    for title in MenuVisibilityManager.readerMenuTitles {
        try assertTrue(all.contains(title), "\(title) should be in allContextMenuTitles")
    }
    for title in MenuVisibilityManager.libraryMenuTitles {
        try assertTrue(all.contains(title), "\(title) should be in allContextMenuTitles")
    }
}

test("Reader and library menu titles do not overlap") {
    let overlap = MenuVisibilityManager.readerMenuTitles.intersection(
        MenuVisibilityManager.libraryMenuTitles
    )
    try assertEqual(overlap.count, 0, "Reader and library menus should not share titles")
}

// MARK: - applyVisibility logic using real NSMenu

test("applyVisibility: reader window shows reader menus, hides library menus") {
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "Playback", action: nil, keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "Navigate", action: nil, keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "Bookmarks", action: nil, keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "Library", action: nil, keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "File", action: nil, keyEquivalent: ""))

    MenuVisibilityManager.applyVisibility(for: .reader, to: menu)

    try assertTrue(!menu.items[0].isHidden, "Playback should be visible for reader")
    try assertTrue(!menu.items[1].isHidden, "Navigate should be visible for reader")
    try assertTrue(!menu.items[2].isHidden, "Bookmarks should be visible for reader")
    try assertTrue(menu.items[3].isHidden, "Library should be hidden for reader")
    try assertTrue(!menu.items[4].isHidden, "File should remain visible")
}

test("applyVisibility: library window shows library menus, hides reader menus") {
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "Playback", action: nil, keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "Navigate", action: nil, keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "Bookmarks", action: nil, keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "Library", action: nil, keyEquivalent: ""))

    MenuVisibilityManager.applyVisibility(for: .library, to: menu)

    try assertTrue(menu.items[0].isHidden, "Playback should be hidden for library")
    try assertTrue(menu.items[1].isHidden, "Navigate should be hidden for library")
    try assertTrue(menu.items[2].isHidden, "Bookmarks should be hidden for library")
    try assertTrue(!menu.items[3].isHidden, "Library should be visible for library")
}

test("applyVisibility: nil window type hides all context menus") {
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "Playback", action: nil, keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "Navigate", action: nil, keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "Bookmarks", action: nil, keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "Library", action: nil, keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""))

    MenuVisibilityManager.applyVisibility(for: nil, to: menu)

    try assertTrue(menu.items[0].isHidden, "Playback should be hidden for nil")
    try assertTrue(menu.items[1].isHidden, "Navigate should be hidden for nil")
    try assertTrue(menu.items[2].isHidden, "Bookmarks should be hidden for nil")
    try assertTrue(menu.items[3].isHidden, "Library should be hidden for nil")
    try assertTrue(!menu.items[4].isHidden, "Edit should remain visible for nil")
}

test("applyVisibility: nil menu is safe no-op") {
    // Should not crash when called with nil menu
    MenuVisibilityManager.applyVisibility(for: .reader, to: nil)
    MenuVisibilityManager.applyVisibility(for: nil, to: nil)
}

test("applyVisibility: non-context menus are never hidden") {
    let standardTitles = ["TextMouth", "File", "Edit", "View", "Window", "Help"]
    let menu = NSMenu()
    for title in standardTitles {
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
    }

    // Try all possible window types — standard menus should never be hidden
    for windowType in [ActiveWindowType.reader, ActiveWindowType.library] {
        MenuVisibilityManager.applyVisibility(for: windowType, to: menu)
        for item in menu.items {
            try assertTrue(!item.isHidden, "\(item.title) should never be hidden")
        }
    }

    // Also nil
    MenuVisibilityManager.applyVisibility(for: nil, to: menu)
    for item in menu.items {
        try assertTrue(!item.isHidden, "\(item.title) should never be hidden for nil window")
    }
}

test("applyVisibility: switching window type toggles visibility correctly") {
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "Playback", action: nil, keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "Library", action: nil, keyEquivalent: ""))

    // Start with reader
    MenuVisibilityManager.applyVisibility(for: .reader, to: menu)
    try assertTrue(!menu.items[0].isHidden, "Playback visible for reader")
    try assertTrue(menu.items[1].isHidden, "Library hidden for reader")

    // Switch to library
    MenuVisibilityManager.applyVisibility(for: .library, to: menu)
    try assertTrue(menu.items[0].isHidden, "Playback hidden after switch to library")
    try assertTrue(!menu.items[1].isHidden, "Library visible after switch to library")

    // Switch to nil (no window)
    MenuVisibilityManager.applyVisibility(for: nil, to: menu)
    try assertTrue(menu.items[0].isHidden, "Playback hidden for nil")
    try assertTrue(menu.items[1].isHidden, "Library hidden for nil")

    // Switch back to reader
    MenuVisibilityManager.applyVisibility(for: .reader, to: menu)
    try assertTrue(!menu.items[0].isHidden, "Playback visible again after back to reader")
    try assertTrue(menu.items[1].isHidden, "Library hidden again after back to reader")
}

// MARK: - detectWindowType logic

test("detectWindowType: nil window returns nil") {
    let result = MenuVisibilityManager.detectWindowType(for: nil)
    try assertTrue(result == nil, "Nil window should return nil type")
}

test("detectWindowType: NSPanel returns nil (Settings, About, etc.)") {
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: true
    )
    panel.title = "Settings"
    let result = MenuVisibilityManager.detectWindowType(for: panel)
    try assertTrue(result == nil, "NSPanel should return nil window type")
}

test("detectWindowType: NSPanel with any title returns nil") {
    // Even a panel titled like a library window should return nil
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: true
    )
    panel.title = "TextMouth"
    let result = MenuVisibilityManager.detectWindowType(for: panel)
    try assertTrue(result == nil, "NSPanel should always return nil regardless of title")
}

} // end runMenuVisibilityTests

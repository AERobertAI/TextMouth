import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    /// Hides context-specific menu bar items (Playback, Navigate, etc.) when
    /// the focused window doesn't support them, so VoiceOver doesn't encounter
    /// empty, non-interactive menus.
    let menuVisibilityManager = MenuVisibilityManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Disable automatic window tabbing (prevents "New Tab" menu proliferation)
        NSWindow.allowsAutomaticWindowTabbing = false

        // Disable macOS automatic window state restoration so previous sessions don't
        // spawn extra library or reader windows on launch. Only one library window
        // should appear on startup; additional ones require Cmd+N.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    /// Called on every event loop iteration. Applies menu visibility after
    /// SwiftUI has finished rebuilding CommandMenu bodies, so menus that
    /// should be hidden are removed from the menu bar even when SwiftUI
    /// tries to reset them.
    func applicationWillUpdate(_ notification: Notification) {
        menuVisibilityManager.updateMenuVisibility()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
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

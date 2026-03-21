import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Disable automatic window tabbing (prevents "New Tab" menu proliferation)
        NSWindow.allowsAutomaticWindowTabbing = false

        // Disable macOS automatic window state restoration so previous sessions don't
        // spawn extra library or reader windows on launch. Only one library window
        // should appear on startup; additional ones require Cmd+N.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
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

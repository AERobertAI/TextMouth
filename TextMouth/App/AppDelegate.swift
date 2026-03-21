import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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

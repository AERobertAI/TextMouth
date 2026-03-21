import SwiftUI

@main
struct TextMouthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var libraryViewModel = LibraryViewModel()
    @StateObject private var settingsViewModel = SettingsViewModel()
    @StateObject private var shortcutManager = KeyboardShortcutManager()
    @StateObject private var soundEffectService = SoundEffectService()

    var body: some Scene {
        // Library windows — Cmd+N creates a new one
        WindowGroup {
            LibraryWindowView()
                .environmentObject(libraryViewModel)
                .environmentObject(settingsViewModel)
                .environmentObject(shortcutManager)
                .environmentObject(soundEffectService)
        }
        .commands {
            // Keep "Open Book..." alongside the standard "New Window" (Cmd+N)
            CommandGroup(after: .newItem) {
                Button("Open Book...") {
                    NotificationCenter.default.post(name: .openBookFile, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("New from Text...") {
                    NotificationCenter.default.post(name: .newFromText, object: nil)
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }

            PlaybackCommands()
            NavigationCommands()
            BookmarkCommands()
        }

        // Book reader windows — opened programmatically via openWindow(id:value:)
        WindowGroup("Book Reader", id: "book-reader", for: UUID.self) { $bookID in
            if let bookID = bookID {
                BookReaderWindowView(
                    bookID: bookID,
                    libraryViewModel: libraryViewModel,
                    settingsViewModel: settingsViewModel
                )
                .environmentObject(libraryViewModel)
                .environmentObject(settingsViewModel)
                .environmentObject(shortcutManager)
                .environmentObject(soundEffectService)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(libraryViewModel)
                .environmentObject(settingsViewModel)
                .environmentObject(shortcutManager)
                .environmentObject(soundEffectService)
        }
    }
}

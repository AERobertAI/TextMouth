import SwiftUI

@main
struct TextMouthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var libraryViewModel = LibraryViewModel()
    @StateObject private var settingsViewModel = SettingsViewModel()
    @StateObject private var shortcutManager = KeyboardShortcutManager()
    @StateObject private var soundEffectService = SoundEffectService()
    @StateObject private var libraryWindowRouter = LibraryWindowRouter.shared

    /// Installs the real cloud services (FR02) before anything else runs.
    /// The app's initializer is the earliest point: SwiftUI creates the
    /// library model above before `applicationWillFinishLaunching`, and the
    /// library's launch checks use the services.
    init() {
        CloudServices.installSystemServices()
    }

    var body: some Scene {
        // Library window — only one opens on launch; Cmd+N can still create additional ones.
        WindowGroup {
            LibraryWindowView()
                .environmentObject(libraryViewModel)
                .environmentObject(settingsViewModel)
                .environmentObject(shortcutManager)
                .environmentObject(soundEffectService)
                .environmentObject(libraryWindowRouter)
                .onAppear {
                    // Lists the installed voices once the first window shows,
                    // off the main thread, rather than before it (TODO PERF07).
                    VoiceCatalog.shared.loadIfNeeded()
                    // Recordings are saved into this library, whichever menu
                    // opens the Record window (FR04).
                    RecordingWindowController.shared.attach(libraryViewModel)
                }
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

                // Records from a microphone into a new audiobook (FR04).
                Button(RecordingWording.menuTitle) {
                    RecordingWindowController.shared.show(library: libraryViewModel)
                }
                .keyboardShortcut(RecordingShortcuts.newRecording)
            }

            PlaybackCommands()
            NavigationCommands()
            LibraryCommands()
            BookmarkCommands()
            BookCommands()
        }

        // Book reader windows — opened programmatically via openWindow(id:value:)
        // Restoration disabled so old reader windows don't reopen on launch.
        WindowGroup("Book Reader", id: BookReaderWindowView.windowID, for: UUID.self) { $bookID in
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
        // Without this, SwiftUI adds File > New > New Book Reader Window,
        // which opens a reader with no book: an empty window whose Playback
        // and Navigate menus can do nothing (TODO A05). A reader opens only
        // for a book, from the Library or through the router.
        .commandsRemoved()

        Settings {
            SettingsView()
                .environmentObject(libraryViewModel)
                .environmentObject(settingsViewModel)
                .environmentObject(shortcutManager)
                .environmentObject(soundEffectService)
        }
    }
}

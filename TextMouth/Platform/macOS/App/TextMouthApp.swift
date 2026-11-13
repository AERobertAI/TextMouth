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
                    // Search Library… searches this library, whichever window
                    // its menu command is chosen in.
                    LibrarySearchWindowController.shared.attach(libraryViewModel)
                }
        }
        .commands {
            // Open Book…, New from Text…, and New Recording… beside the
            // standard New Window (Command-N), each with its key in force.
            FileCommands(shortcuts: shortcutManager, library: libraryViewModel)
            // Edit > Find > Search Library…, with its key in force.
            EditCommands(shortcuts: shortcutManager)
            PlaybackCommands(shortcuts: shortcutManager)
            NavigationCommands()
            LibraryCommands(shortcuts: shortcutManager)
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
                    settingsViewModel: settingsViewModel,
                    // Listening goes on to another book in this window
                    // (0.2.5): the window's book changes, and `.id` below
                    // makes a new view, with a new reader, of it.
                    showBook: { nextBookID in $bookID.wrappedValue = nextBookID }
                )
                .environmentObject(libraryViewModel)
                .environmentObject(settingsViewModel)
                .environmentObject(shortcutManager)
                .environmentObject(soundEffectService)
                // Without an identity of its own for each book, SwiftUI
                // would keep the old view and its reader, and the window
                // would go on showing the old book.
                .id(bookID)
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

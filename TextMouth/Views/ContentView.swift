import SwiftUI
import Combine

/// Root view for a library window. Each library window has its own navigation state.
struct LibraryWindowView: View {
    @EnvironmentObject var libraryViewModel: LibraryViewModel
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var libraryWindowRouter: LibraryWindowRouter
    @Environment(\.openWindow) private var openWindow

    @State private var currentFolderPath = ""
    @State private var category: LibraryCategory = .folders
    @State private var showFileImporter = false
    @State private var zipFolderName = ""
    /// The NSWindow hosting this library view, captured via WindowAccessor
    @State private var hostWindow: NSWindow?

    /// Finder-style folder navigation history (back/forward with Cmd+[ / Cmd+])
    @StateObject private var folderNav = FolderNavigationHistory()
    /// The removal preferences, observed so the Remove Book dialog's words
    /// follow a change made in Settings, even while the dialog is open.
    @ObservedObject private var removal = RemovalPreferencesModel.shared

    var body: some View {
        // Read while the view is installed, as SwiftUI requires, and lent to
        // the router with this window's way of taking app-wide actions.
        let openReaderWindow = openWindow
        ZStack {
            LibraryView(
                currentFolderPath: $currentFolderPath,
                category: $category,
                showFileImporter: $showFileImporter,
                onOpenBook: { book in
                    openWindow(id: "book-reader", value: book.id)
                }
            )

            // Import progress overlay
            if libraryViewModel.isImporting {
                ProgressOverlay(
                    title: "Importing Books",
                    current: libraryViewModel.importProgressCurrent,
                    total: libraryViewModel.importProgressTotal,
                    message: libraryViewModel.importProgressMessage,
                    itemNoun: "books processed"
                )
            }

            // Text extraction progress overlay (shown on startup or re-extraction)
            if libraryViewModel.isExtracting {
                ProgressOverlay(
                    title: "Extracting Text",
                    current: libraryViewModel.extractionProgressCurrent,
                    total: libraryViewModel.extractionProgressTotal,
                    message: libraryViewModel.extractionProgressMessage,
                    itemNoun: "books extracted"
                )
            }
        }
        .background(WindowAccessor(onWindowFound: { window in
            if let previousWindow = hostWindow, previousWindow !== window {
                libraryWindowRouter.unregister(previousWindow)
            }
            hostWindow = window
            registerForGlobalActions(window, openingReadersWith: openReaderWindow)
            NotificationCenter.default.post(name: .refreshContextMenus, object: nil)
        }))
        // Tell SwiftUI that an existing Library scene can receive any incoming
        // file URL. Without this registration, external book opens fall
        // through to a newly-created instance of the first WindowGroup.
        .handlesExternalEvents(preferring: [], allowing: ["*"])
        .focusedValue(\.activeWindowType, .library)
        .onAppear {
            NotificationCenter.default.post(name: .refreshContextMenus, object: nil)
        }
        .onDisappear {
            if let hostWindow {
                libraryWindowRouter.unregister(hostWindow)
            }
        }
        .navigationTitle(windowTitle)
        .frame(minWidth: 600, minHeight: 400)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: FileImportService.supportedTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                libraryViewModel.importFiles(urls: urls, toFolder: currentFolderPath)
            case .failure(let error):
                libraryViewModel.errorMessage = error.localizedDescription
                libraryViewModel.showError = true
            }
        }
        .alert("Error", isPresented: $libraryViewModel.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(libraryViewModel.errorMessage ?? "An unknown error occurred.")
        }
        // Zip folder creation dialog
        .alert("Create Folder for Imported Books?", isPresented: $libraryViewModel.showZipFolderDialog) {
            TextField("Folder name", text: $zipFolderName)
            Button("Create Folder") {
                libraryViewModel.moveZipBooksToFolder(folderName: zipFolderName)
                zipFolderName = ""
            }
            Button("No Thanks", role: .cancel) {
                libraryViewModel.pendingZipBooks = []
            }
        } message: {
            Text("\(libraryViewModel.pendingZipBooks.count) books were imported from the ZIP. Would you like to create a new folder to hold them?")
        }
        // Delete original file confirmation dialog, in the words of the Trash
        // preference, which decides where the file goes
        .alert(
            libraryViewModel.pendingOriginalFileWording.confirmationTitle,
            isPresented: $libraryViewModel.showDeleteOriginalDialog
        ) {
            Button(libraryViewModel.pendingOriginalFileWording.buttonTitle, role: .destructive) {
                if let url = libraryViewModel.pendingOriginalURL {
                    libraryViewModel.deleteOriginalFile(at: url)
                }
                libraryViewModel.pendingOriginalURL = nil
            }
            Button("Keep", role: .cancel) {
                libraryViewModel.pendingOriginalURL = nil
            }
        } message: {
            Text(libraryViewModel.pendingOriginalFileWording.confirmationMessage)
        }
        // Remove book confirmation dialog (supports single or multiple books).
        // Its words say whether the files go to the Trash, are deleted
        // permanently, or stay, as the Trash preference chooses (TODO A08).
        .alert(
            removalChoice.title,
            isPresented: $libraryViewModel.showRemoveBookDialog
        ) {
            Button(removalChoice.deleteButtonTitle, role: .destructive) {
                let books = libraryViewModel.pendingRemoveBooks
                libraryViewModel.removeBooksAndDelete(books)
                libraryViewModel.pendingRemoveBooks = []
            }
            Button(removalChoice.keepButtonTitle) {
                let books = libraryViewModel.pendingRemoveBooks
                libraryViewModel.removeBooksFromLibraryOnly(books)
                libraryViewModel.pendingRemoveBooks = []
            }
            Button("Cancel", role: .cancel) {
                libraryViewModel.pendingRemoveBooks = []
            }
        } message: {
            if !libraryViewModel.pendingRemoveBooks.isEmpty {
                Text(removalChoice.message)
            }
        }
        // Duplicate import dialog
        .alert("Duplicate Book Found", isPresented: $libraryViewModel.showDuplicateDialog) {
            Button("Replace Existing") {
                libraryViewModel.replaceDuplicate()
            }
            Button("Keep Both") {
                libraryViewModel.keepDuplicate()
            }
            Button("Cancel", role: .cancel) {
                libraryViewModel.cancelDuplicate()
            }
        } message: {
            if let existing = libraryViewModel.pendingDuplicateExisting {
                let choice = "A book matching \"\(existing.title)\" is already in your library. Replace the existing copy (updates the .tmb and timestamp) or keep both as separate entries?"
                // A new copy missing chapters says so with the choice, so it
                // never replaces a complete copy unannounced.
                let incomplete = libraryViewModel.pendingDuplicateWarning
                    .map { "\n\nThe copy just imported is incomplete. \($0)" } ?? ""
                Text(verbatim: choice + incomplete)
            }
        }
        // Open Book..., Import DAISY Folder…, opening a book's reader, and
        // Continue to Next Book are app-wide actions: the router takes each
        // posted one and hands it to exactly one window (TODO A05), this one
        // through `takeGlobalAction(_:openingReadersWith:)` when it is chosen.
        .onReceive(NotificationCenter.default.publisher(for: .goBack)) { _ in
            if isKeyLibraryWindow, let path = folderNav.goBack() {
                currentFolderPath = path
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .goForward)) { _ in
            if isKeyLibraryWindow, let path = folderNav.goForward() {
                currentFolderPath = path
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateUpLevel)) { _ in
            if isKeyLibraryWindow, let parent = FolderNavigationHistory.parentPath(of: currentFolderPath) {
                currentFolderPath = parent
            }
        }
        // Record folder changes into the navigation history and announce them.
        // The sort shown follows the location without any loading: the window
        // title and the list restore it from the library whenever they draw.
        .onChange(of: currentFolderPath) { _, newPath in
            folderNav.recordVisit(to: newPath)
            announceFolderChange(newPath)
        }
    }

    /// The words for the Remove Book confirmation, in the mode the Trash
    /// preference chooses.
    private var removalChoice: RemovalChoiceWording {
        RemovalChoiceWording(
            books: libraryViewModel.pendingRemoveBooks,
            movesToTrash: removal.preferences.movesToTrash
        )
    }

    /// The window title: the location and the sort it shows, restored from
    /// the setting saved for the location by the same function the list
    /// sorts with, so the title agrees with the order and the Sort menu from
    /// the first frame (TODO A06).
    private var windowTitle: String {
        let location = LibraryLocation(category: category, folderPath: currentFolderPath)
        return location.windowTitle(sortedBy: libraryViewModel.sortState(at: location))
    }

    /// Announce the new folder name and book count to VoiceOver when navigating.
    private func announceFolderChange(_ path: String) {
        let message = FolderNavigationHistory.announcement(
            for: path,
            library: libraryViewModel.library
        )

        guard let window = hostWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else { return }
        NSAccessibility.post(
            element: window,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    /// True when this library window is the current key (focused) window.
    /// Used to prevent multiple library windows from all responding to the same
    /// global notification (e.g. opening a file dialog in every library window at once).
    private var isKeyLibraryWindow: Bool {
        guard let hostWindow = hostWindow else { return true }
        return hostWindow.isKeyWindow
    }

    // MARK: - App-Wide Actions (TODO A05)

    /// Registers this Library window with the router, lending it the way
    /// this window takes app-wide actions. The router decides which one
    /// window takes each action; this window never acts on an app-wide
    /// notification by itself, since SwiftUI keeps a closed Library window's
    /// view alive and still receiving notifications.
    ///
    /// - Parameters:
    ///   - window: This view's hosting window.
    ///   - openReaderWindow: This window's `openWindow` action, read while
    ///     the view was installed, which opens a book's reader window.
    private func registerForGlobalActions(_ window: NSWindow, openingReadersWith openReaderWindow: OpenWindowAction) {
        libraryWindowRouter.register(window) { action in
            takeGlobalAction(action, openingReadersWith: openReaderWindow)
        }
    }

    /// Takes an app-wide action the router chose this Library window for.
    /// A panel is presented on this window, brought to the front first: a
    /// reader, Settings, or another Library window may be key, and the panel
    /// must appear where the user and VoiceOver are.
    private func takeGlobalAction(_ action: GlobalAction, openingReadersWith openReaderWindow: OpenWindowAction) {
        switch action {
        case .openBookFile:
            bringToFront()
            showFileImporter = true
        case .importDAISYFolder:
            bringToFront()
            presentDAISYFolderPanel()
        case .openBookWindow(let bookID), .continueToNextBook(let bookID):
            // Opens the book's reader window, or brings it forward when it
            // is already open.
            openReaderWindow(id: BookReaderWindowView.windowID, value: bookID)
        }
    }

    /// Brings this Library window to the front as the key window, out of
    /// the Dock first when it was minimized.
    private func bringToFront() {
        guard let hostWindow else { return }
        if hostWindow.isMiniaturized {
            hostWindow.deminiaturize(nil)
        }
        hostWindow.makeKeyAndOrderFront(nil)
    }

    /// Presents the folder-only panel of Library > Import DAISY Folder… as a
    /// sheet on this Library window (on its own while the window is not yet
    /// known), and imports the folders chosen into the folder being viewed
    /// (TODO I02).
    private func presentDAISYFolderPanel() {
        let panel = LibraryViewModel.makeDAISYFolderPanel()
        let destination = currentFolderPath
        let viewModel = libraryViewModel
        let importChosenFolders: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            viewModel.importDAISYFolders(panel.urls, toFolder: destination)
        }
        if let hostWindow {
            panel.beginSheetModal(for: hostWindow, completionHandler: importChosenFolders)
        } else {
            panel.begin(completionHandler: importChosenFolders)
        }
    }
}

// MARK: - Progress Overlay

/// Reusable progress overlay for long-running operations (import, extraction, etc.)
struct ProgressOverlay: View {
    let title: String
    let current: Int
    let total: Int
    let message: String
    /// Noun for the items being processed (e.g. "books extracted", "books processed")
    let itemNoun: String

    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if total > 0 {
                ProgressView(value: Double(current), total: Double(total))
                    .progressViewStyle(.linear)
                    .frame(width: 300)

                Text("\(current) of \(total) \(itemNoun)")
                    .font(.body)
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
            }

            if !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(total > 0
            ? "\(title): \(current) of \(total) \(itemNoun)"
            : "\(title)"
        )
    }
}

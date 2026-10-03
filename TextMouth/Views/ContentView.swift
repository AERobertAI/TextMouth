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
    /// Presents the New from Text sheet, from the toolbar or through the
    /// router for File > New from Text....
    @State private var showTextInput = false
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
                showTextInput: $showTextInput,
                onOpenBook: { book in
                    openWindow(id: "book-reader", value: book.id)
                }
            )

            // Import progress overlay, whose Cancel button stops ZIP imports
            if libraryViewModel.isImporting {
                Self.importProgressOverlay(for: libraryViewModel)
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
            // SwiftUI shows a closed Library window again, rather than open
            // a new one, for a book opened from Finder; the window takes
            // app-wide actions again from then on. A window appearing for
            // the first time registers once its hosting window is found.
            if let hostWindow {
                registerForGlobalActions(hostWindow, openingReadersWith: openReaderWindow)
            }
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
        // Import questions: replace or keep a duplicate, delete an original
        // file, put a ZIP archive's books in a folder. They wait in one queue
        // and are asked one at a time (TODO I01).
        .importDecisionSheet(for: libraryViewModel, in: hostWindow, router: libraryWindowRouter)
        // Open Book..., New from Text..., Import DAISY Folder…, Go to Library,
        // items opened from Finder, opening a book's reader, and Continue to
        // Next Book are app-wide actions: the router hands each to exactly
        // one window (TODO A05), this one through
        // `takeGlobalAction(_:openingReadersWith:)` when it is chosen.
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
        case .newFromText:
            bringToFront()
            showTextInput = true
        case .importDAISYFolder:
            bringToFront()
            presentDAISYFolderPanel()
        case .goToLibrary:
            bringToFront()
        case .openFiles(let items):
            // A Library window is already on screen for the items: SwiftUI
            // shows one for them, or the router opened one. The import's
            // progress and questions appear there, and each book imported
            // opens afterwards.
            libraryViewModel.importAndOpenFiles(urls: items)
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
///
/// For VoiceOver the overlay is a container labelled with its status
/// (`spokenStatus`). It contains its parts rather than combining them, so a
/// Cancel button inside stays a control of its own that VoiceOver can reach
/// and press (TODO I05).
struct ProgressOverlay: View {
    let title: String
    let current: Int
    let total: Int
    let message: String
    /// Noun for the items being processed (e.g. "books extracted", "books processed")
    let itemNoun: String
    /// Cancels the operation the overlay shows, from its Cancel button or
    /// the Escape key; nil, the default, shows no Cancel button.
    var onCancel: (@MainActor () -> Void)? = nil

    /// What VoiceOver calls the Cancel button. Only the import overlay has
    /// one, so the name says what it cancels.
    static let cancelButtonLabel = "Cancel Import"
    /// What VoiceOver says the Cancel button does: it stops the ZIP archive
    /// imports under way and queued (`LibraryViewModel.cancelImports()`),
    /// though a book already being imported, such as a single audiobook
    /// archive, is finished first, and every book already imported stays.
    static let cancelButtonHint = "Stops importing ZIP archives after the current book. Books already imported stay in the library."

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

            if let onCancel {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(Self.cancelButtonLabel)
                    .accessibilityHint(Self.cancelButtonHint)
            }
        }
        .padding(32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 10)
        // A container, not one combined element: combining would fold the
        // Cancel button into the status, out of VoiceOver's reach.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spokenStatus)
    }

    /// What VoiceOver reads for the overlay: its title, then the items done
    /// of the total while the bar has one. While the bar is indeterminate,
    /// the message carries the progress instead (a ZIP archive's items
    /// extracted, say), so it follows the title; with no message, the title
    /// is read alone.
    var spokenStatus: String {
        if total > 0 {
            return "\(title): \(current) of \(total) \(itemNoun)"
        }
        return message.isEmpty ? title : "\(title): \(message)"
    }
}

extension LibraryWindowView {
    /// The overlay a Library window shows while imports run: their progress,
    /// and a Cancel button, which Escape presses too, that stops the ZIP
    /// imports under way and queued (`LibraryViewModel.cancelImports()`,
    /// TODO I05). The window's body shows exactly this overlay, made here so
    /// tests can press the very button the window shows.
    static func importProgressOverlay(for libraryViewModel: LibraryViewModel) -> ProgressOverlay {
        ProgressOverlay(
            title: "Importing Books",
            current: libraryViewModel.importProgressCurrent,
            total: libraryViewModel.importProgressTotal,
            message: libraryViewModel.importProgressMessage,
            itemNoun: "books processed",
            onCancel: libraryViewModel.cancelImports
        )
    }
}

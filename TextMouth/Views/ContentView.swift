import SwiftUI
import Combine

/// Root view for a library window. Each library window has its own navigation state.
struct LibraryWindowView: View {
    @EnvironmentObject var libraryViewModel: LibraryViewModel
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Environment(\.openWindow) private var openWindow

    @State private var currentFolderPath = ""
    @State private var category: LibraryCategory = .folders
    @State private var sortField: LibrarySortField = .title
    @State private var sortAscending: Bool = true
    @State private var showFileImporter = false
    @State private var zipFolderName = ""
    /// The NSWindow hosting this library view, captured via WindowAccessor
    @State private var hostWindow: NSWindow?

    /// Finder-style folder navigation history (back/forward with Cmd+[ / Cmd+])
    @StateObject private var folderNav = FolderNavigationHistory()
    /// Suppresses saving sort settings back to the library when loading from a folder change
    @State private var isLoadingFolderSort = false

    var body: some View {
        ZStack {
            LibraryView(
                currentFolderPath: $currentFolderPath,
                category: $category,
                sortField: $sortField,
                sortAscending: $sortAscending,
                showFileImporter: $showFileImporter,
                onOpenBook: { book in
                    openWindow(id: "book-reader", value: book.id)
                }
            )

            // Import progress overlay
            if libraryViewModel.isImporting {
                ImportProgressOverlay(
                    current: libraryViewModel.importProgressCurrent,
                    total: libraryViewModel.importProgressTotal,
                    message: libraryViewModel.importProgressMessage
                )
            }

            // Text extraction progress overlay (shown on startup or re-extraction)
            if libraryViewModel.isExtracting {
                ExtractionProgressOverlay(
                    current: libraryViewModel.extractionProgressCurrent,
                    total: libraryViewModel.extractionProgressTotal,
                    message: libraryViewModel.extractionProgressMessage
                )
            }
        }
        .background(WindowAccessor(onWindowFound: { window in
            hostWindow = window
        }))
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
        // Delete original file confirmation dialog
        .alert("Delete Original File?", isPresented: $libraryViewModel.showDeleteOriginalDialog) {
            Button("Delete", role: .destructive) {
                if let url = libraryViewModel.pendingOriginalURL {
                    FileImportService.deleteOriginalFile(at: url)
                }
                libraryViewModel.pendingOriginalURL = nil
            }
            Button("Keep", role: .cancel) {
                libraryViewModel.pendingOriginalURL = nil
            }
        } message: {
            if let url = libraryViewModel.pendingOriginalURL {
                Text("The book has been imported successfully. Delete the original file \"\(url.lastPathComponent)\"?")
            } else {
                Text("The book has been imported successfully. Delete the original file?")
            }
        }
        // Remove book confirmation dialog (supports single or multiple books)
        .alert(
            libraryViewModel.pendingRemoveBooks.count > 1
                ? "Remove \(libraryViewModel.pendingRemoveBooks.count) Books?"
                : "Remove Book?",
            isPresented: $libraryViewModel.showRemoveBookDialog
        ) {
            Button("Remove & Delete", role: .destructive) {
                let books = libraryViewModel.pendingRemoveBooks
                libraryViewModel.removeBooksAndDelete(books)
                libraryViewModel.pendingRemoveBooks = []
            }
            Button("Remove from Library Only") {
                let books = libraryViewModel.pendingRemoveBooks
                libraryViewModel.removeBooksFromLibraryOnly(books)
                libraryViewModel.pendingRemoveBooks = []
            }
            Button("Cancel", role: .cancel) {
                libraryViewModel.pendingRemoveBooks = []
            }
        } message: {
            let books = libraryViewModel.pendingRemoveBooks
            if books.count == 1, let book = books.first {
                Text("Remove \"\(book.title)\"? \"Remove & Delete\" also deletes the .tmb package from disk. \"Remove from Library Only\" keeps the file.")
            } else if books.count > 1 {
                Text("Remove \(books.count) books? \"Remove & Delete\" also deletes the .tmb packages from disk. \"Remove from Library Only\" keeps the files.")
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
                Text("A book matching \"\(existing.title)\" is already in your library. Replace the existing copy (updates the .tmb and timestamp) or keep both as separate entries?")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openBookFile)) { _ in
            // Only show the file importer in the key (focused) library window
            // to prevent multiple file dialogs from appearing at once
            if isKeyLibraryWindow {
                showFileImporter = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openBookWindow)) { notification in
            // Only open from the key library window to prevent duplicate openWindow calls
            if isKeyLibraryWindow, let bookID = notification.object as? UUID {
                openWindow(id: "book-reader", value: bookID)
            }
        }
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
        // Record folder changes into the navigation history, load sort settings, and announce
        .onChange(of: currentFolderPath) { _, newPath in
            folderNav.recordVisit(to: newPath)
            loadSortSettings(for: newPath)
            announceFolderChange(newPath)
        }
        // Save sort settings back to the library when the user changes them
        .onChange(of: sortField) { _, _ in
            saveSortSettings()
        }
        .onChange(of: sortAscending) { _, _ in
            saveSortSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .continueToNextBook)) { notification in
            if isKeyLibraryWindow, let bookID = notification.userInfo?["bookID"] as? UUID {
                openWindow(id: "book-reader", value: bookID)
            }
        }
    }

    private var windowTitle: String {
        let locationName: String
        switch category {
        case .folders:
            locationName = currentFolderPath.isEmpty ? "All Folders" : currentFolderPath.components(separatedBy: "/").last ?? "All Folders"
        case .allItems:
            locationName = "All Items"
        case .noFolder:
            locationName = "No Folder"
        case .recent:
            locationName = "Recent"
        }
        let direction = sortAscending ? "Ascending" : "Descending"
        return "Library: \(locationName) (\(sortField.rawValue) \(direction))"
    }

    /// Load per-folder sort settings when navigating to a new folder.
    private func loadSortSettings(for path: String) {
        let setting = libraryViewModel.library.sortSetting(for: path)
        isLoadingFolderSort = true
        sortField = setting.sortField
        sortAscending = setting.sortAscending
        isLoadingFolderSort = false
    }

    /// Save the current sort field/direction as this folder's sort setting.
    private func saveSortSettings() {
        guard !isLoadingFolderSort else { return }
        let setting = FolderSortSetting(sortField: sortField, sortAscending: sortAscending)
        libraryViewModel.setFolderSortSetting(setting, for: currentFolderPath)
    }

    /// Announce the new folder name and book count to VoiceOver when navigating.
    private func announceFolderChange(_ path: String) {
        let folderName = path.isEmpty ? "Library" : (path.components(separatedBy: "/").last ?? "Library")
        // At root, show total library count; in a folder, show recursive subtree count
        let bookCount = path.isEmpty
            ? libraryViewModel.library.books.count
            : libraryViewModel.library.totalBooksInFolderTree(path)
        let bookWord = bookCount == 1 ? "book" : "books"
        let message = "\(folderName), \(bookCount) \(bookWord)"

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
}

// MARK: - Extraction Progress Overlay

/// Shown when TextMouth is extracting text from books that don't yet have
/// a cached content.md (e.g. on first launch after update, or during re-extraction).
struct ExtractionProgressOverlay: View {
    let current: Int
    let total: Int
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Text("Extracting Text")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if total > 0 {
                ProgressView(value: Double(current), total: Double(total))
                    .progressViewStyle(.linear)
                    .frame(width: 300)

                Text("\(current) of \(total) books extracted")
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
            ? "Extracting text: \(current) of \(total) books processed"
            : "Extracting text from library books"
        )
    }
}

// MARK: - Import Progress Overlay

struct ImportProgressOverlay: View {
    let current: Int
    let total: Int
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Text("Importing Books")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if total > 0 {
                ProgressView(value: Double(current), total: Double(total))
                    .progressViewStyle(.linear)
                    .frame(width: 300)

                Text("\(current) of \(total) books processed")
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
            ? "Importing books: \(current) of \(total) processed"
            : "Importing books: extracting archive"
        )
    }
}

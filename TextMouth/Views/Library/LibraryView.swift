import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var libraryViewModel: LibraryViewModel
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Binding var currentFolderPath: String
    @Binding var category: LibraryCategory
    @Binding var sortField: LibrarySortField
    @Binding var sortAscending: Bool
    @Binding var showFileImporter: Bool
    let onOpenBook: (Book) -> Void

    @State private var showNewFolderSheet = false
    @State private var newFolderName = ""
    @State private var newFolderParentPath = ""
    @State private var booksToMove: [Book] = []
    @State private var showMoveSheet = false
    @State private var folderToMove: BookFolder?
    @State private var showMoveFolderSheet = false
    @State private var folderToRename: BookFolder?
    @State private var showRenameFolderSheet = false
    @State private var renameFolderText = ""
    @State private var searchText = ""
    @State private var selectedBookIDs: Set<UUID> = []
    /// Edit mode: activating a book toggles its selection instead of opening it
    @State private var isEditMode = false
    /// Books selected via edit mode (persists through VoiceOver navigation)
    @State private var editSelection: Set<UUID> = []
    @State private var bookInfoTarget: Book?
    /// EPUB metadata loaded on-demand when showing the rich editor from the library
    @State private var richInfoEPUBMetadata: EPUBMetadata?
    /// Audio metadata loaded on-demand when showing the rich editor from the library
    @State private var richInfoAudioMetadata: AudioMetadata?
    @State private var showTextInput = false
    /// The NSWindow hosting this library, for checking key window status on notifications
    @State private var hostWindow: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            // Category picker
            Picker("View", selection: $category) {
                ForEach(LibraryCategory.allCases, id: \.self) { cat in
                    Text(cat.rawValue).tag(cat)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .accessibilityLabel("Library category")

            // Breadcrumb navigation (only in folders mode)
            if category == .folders && !currentFolderPath.isEmpty {
                BreadcrumbBar(
                    path: currentFolderPath,
                    onNavigate: { currentFolderPath = $0 },
                    onNavigateRoot: { currentFolderPath = "" }
                )
            }

            // Quick-resume button
            if let lastBook = libraryViewModel.lastOpenedBook {
                Button {
                    onOpenBook(lastBook)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                            .foregroundColor(.accentColor)
                            .accessibilityHidden(true)
                        Text("Continue: \(lastBook.title)")
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        if let remaining = lastBook.estimatedTimeRemaining(wpm: settingsViewModel.wordsPerMinute) {
                            Text("\(TimeFormatting.format(remaining)) left")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel({
                    var label = "Continue listening to \(lastBook.title)"
                    if let remaining = lastBook.estimatedTimeRemaining(wpm: settingsViewModel.wordsPerMinute) {
                        label += ", \(TimeFormatting.spoken(remaining)) remaining"
                    }
                    return label
                }())
                .accessibilityHint("Opens the last book you were reading")
            }

            // Edit mode toolbar: shown when edit mode is active
            if isEditMode {
                EditModeBar(
                    selectedCount: effectiveSelection.count,
                    totalCount: filteredBooks.count,
                    onSelectAll: {
                        editSelection = Set(filteredBooks.map { $0.id })
                    },
                    onDeselectAll: {
                        editSelection = []
                        selectedBookIDs = []
                    },
                    onMove: {
                        let books = selectedBooks
                        if !books.isEmpty {
                            booksToMove = books
                            showMoveSheet = true
                        }
                    },
                    onRemove: {
                        let books = selectedBooks
                        if !books.isEmpty {
                            libraryViewModel.removeBooks(books)
                            clearAllSelections()
                        }
                    },
                    onDone: {
                        clearAllSelections()
                    }
                )
            }

            // Total time remaining bar (refreshTick forces periodic re-evaluation)
            let _ = libraryViewModel.refreshTick
            TimeRemainingBar(books: displayedBooks, wpm: settingsViewModel.wordsPerMinute)

            // Main list with native selection
            List(selection: $selectedBookIDs) {
                // Folders section (only in folders category)
                if category == .folders {
                    let subfolders = libraryViewModel.subfoldersOf(currentFolderPath)
                    if !subfolders.isEmpty {
                        Section {
                            ForEach(subfolders) { folder in
                                Button {
                                    currentFolderPath = folder.fullPath
                                } label: {
                                    FolderRow(
                                        folder: folder,
                                        bookCount: libraryViewModel.library.totalBooksInFolderTree(folder.fullPath)
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityAction(.default) {
                                    currentFolderPath = folder.fullPath
                                }
                                .contextMenu {
                                    Button("Rename Folder...") {
                                        folderToRename = folder
                                        renameFolderText = folder.name
                                        showRenameFolderSheet = true
                                    }
                                    Button("Move Folder...") {
                                        folderToMove = folder
                                        showMoveFolderSheet = true
                                    }
                                    Divider()
                                    Button("Delete Folder...", role: .destructive) {
                                        if libraryViewModel.folderHasContents(folder) {
                                            libraryViewModel.pendingDeleteFolder = folder
                                            libraryViewModel.showDeleteFolderDialog = true
                                        } else {
                                            // Empty folder — just delete it
                                            libraryViewModel.removeFolder(folder)
                                        }
                                    }
                                }
                            }
                        } header: {
                            Text("Folders")
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                }

                // Books section
                Section {
                    // Reference refreshTick so the list re-evaluates when the timer fires
                    let _ = libraryViewModel.refreshTick
                    ForEach(filteredBooks) { book in
                        BookRow(
                            book: book,
                            isOpenInWindow: libraryViewModel.openBookIDs.contains(book.id),
                            wpm: settingsViewModel.wordsPerMinute,
                            isEditMode: isEditMode,
                            isEditSelected: editSelection.contains(book.id)
                        )
                            .tag(book.id)
                            .accessibilityAction(.default) {
                                if isEditMode {
                                    toggleEditSelection(book.id)
                                } else {
                                    onOpenBook(book)
                                }
                            }
                            .contextMenu {
                                // Determine which books the action applies to:
                                // use edit selection in edit mode, native selection otherwise,
                                // falling back to just the clicked book.
                                let targetBooks: [Book] = {
                                    let ids = effectiveSelection
                                    if ids.contains(book.id), ids.count > 1 {
                                        return filteredBooks.filter { ids.contains($0.id) }
                                    }
                                    return [book]
                                }()
                                let isMulti = targetBooks.count > 1

                                if !isMulti {
                                    Button("Open") {
                                        onOpenBook(book)
                                    }
                                    Button("Book Info") {
                                        showBookInfo(for: book)
                                    }
                                }
                                if !isEditMode {
                                    Button("Select") {
                                        editSelection.insert(book.id)
                                        isEditMode = true
                                    }
                                }
                                Button(isMulti ? "Move \(targetBooks.count) Books to Folder..." : "Move to Folder...") {
                                    booksToMove = targetBooks
                                    showMoveSheet = true
                                }
                                // Manual order move commands (single book only, when sort is Manual)
                                if !isMulti && sortField == .manual {
                                    Divider()
                                    Button("Move Up") {
                                        libraryViewModel.moveBookInManualOrder(
                                            bookID: book.id, direction: -1, folderPath: currentFolderPath
                                        )
                                    }
                                    Button("Move Down") {
                                        libraryViewModel.moveBookInManualOrder(
                                            bookID: book.id, direction: 1, folderPath: currentFolderPath
                                        )
                                    }
                                }
                                Divider()
                                Button(isMulti ? "Remove \(targetBooks.count) Books from Library" : "Remove from Library", role: .destructive) {
                                    libraryViewModel.removeBooks(targetBooks)
                                    clearAllSelections()
                                }
                            }
                    }
                    .onMove { source, destination in
                        if sortField == .manual {
                            libraryViewModel.reorderBooksInFolder(
                                folderPath: currentFolderPath,
                                from: source,
                                to: destination
                            )
                        }
                    }
                } header: {
                    Text("Books (\(filteredBooks.count))")
                        .accessibilityAddTraits(.isHeader)
                }
            }
            .searchable(text: $searchText, prompt: "Search books")
            .accessibilityRotor("Books") {
                ForEach(filteredBooks) { book in
                    AccessibilityRotorEntry(book.title, id: book.id)
                }
            }
            .accessibilityRotor("Folders") {
                ForEach(libraryViewModel.subfoldersOf(currentFolderPath)) { folder in
                    AccessibilityRotorEntry(
                        "\(folder.name), \(libraryViewModel.library.totalBooksInFolderTree(folder.fullPath)) books",
                        id: folder.id
                    )
                }
            }
            .onDeleteCommand {
                // Delete key removes all selected books (either selection mechanism)
                let books = selectedBooks
                if !books.isEmpty {
                    libraryViewModel.removeBooks(books)
                    clearAllSelections()
                }
            }
            .onChange(of: currentFolderPath) { _ in
                // Clear selections when navigating to a different folder
                editSelection = []
                selectedBookIDs = []
            }
            .onChange(of: category) { _ in
                // Clear selections when switching library categories
                editSelection = []
                selectedBookIDs = []
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if category == .folders && !currentFolderPath.isEmpty {
                    Button {
                        navigateUp()
                    } label: {
                        Label("Up One Level", systemImage: "chevron.up")
                    }
                    .accessibilityLabel("Go up one folder level")
                }

                Button {
                    showFileImporter = true
                } label: {
                    Label("Import Book", systemImage: "plus")
                }
                .accessibilityLabel("Import a book file")
                .accessibilityHint("Opens a file picker to import EPUB, text, markdown, or HTML files")

                Button {
                    showTextInput = true
                } label: {
                    Label("New from Text", systemImage: "doc.text")
                }
                .accessibilityLabel("New book from text")
                .accessibilityHint("Create a new book by pasting or typing text")

                // Edit mode toggle
                Button {
                    if isEditMode {
                        clearAllSelections()
                    } else {
                        isEditMode = true
                    }
                } label: {
                    Label(isEditMode ? "Done" : "Edit", systemImage: isEditMode ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .accessibilityLabel(isEditMode ? "Exit edit mode" : "Enter edit mode")
                .accessibilityHint(isEditMode
                    ? "Exits edit mode. \(editSelection.count) books selected."
                    : "Enter edit mode to select multiple books for moving or deleting")

                if category == .folders {
                    Button {
                        newFolderParentPath = currentFolderPath
                        showNewFolderSheet = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    .accessibilityLabel("Create new folder")
                }

                // Sort controls
                Menu {
                    ForEach(LibrarySortField.allCases, id: \.self) { field in
                        Button {
                            if sortField == field {
                                sortAscending.toggle()
                            } else {
                                sortField = field
                                sortAscending = true
                            }
                        } label: {
                            HStack {
                                Text(field.rawValue)
                                if sortField == field {
                                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                }
                            }
                        }
                    }
                    Divider()
                    Button {
                        sortAscending.toggle()
                    } label: {
                        Text(sortAscending ? "Sort Descending" : "Sort Ascending")
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Sort books by \(sortField.rawValue), \(sortAscending ? "ascending" : "descending")")
            }
        }
        .sheet(isPresented: $showNewFolderSheet) {
            NewFolderSheet(
                folderName: $newFolderName,
                parentPath: $newFolderParentPath,
                folders: libraryViewModel.library.folders,
                onCreate: {
                    libraryViewModel.createFolder(name: newFolderName, parentPath: newFolderParentPath)
                    newFolderName = ""
                    newFolderParentPath = currentFolderPath
                    showNewFolderSheet = false
                },
                onCancel: {
                    newFolderName = ""
                    newFolderParentPath = currentFolderPath
                    showNewFolderSheet = false
                }
            )
        }
        .sheet(isPresented: $showMoveSheet) {
            if !booksToMove.isEmpty {
                MoveFolderSheet(
                    books: booksToMove,
                    library: libraryViewModel.library,
                    lastMovedFolderPath: libraryViewModel.lastMovedFolderPath,
                    onMove: { path in
                        libraryViewModel.moveBooks(booksToMove, toFolder: path)
                        clearAllSelections()
                        showMoveSheet = false
                    },
                    onCreateFolder: { name, parentPath in
                        libraryViewModel.createFolder(name: name, parentPath: parentPath)
                    },
                    onCancel: { showMoveSheet = false }
                )
            }
        }
        .background(WindowAccessor(onWindowFound: { window in
            hostWindow = window
        }))
        .sheet(item: $bookInfoTarget) { book in
            if book.format == .epub, let metadata = richInfoEPUBMetadata {
                // EPUB books get the rich metadata editor with publisher, date, etc.
                MetadataEditorView(
                    metadata: metadata,
                    isEPUB: true,
                    onSave: { updated, writeToFile in
                        var updatedBook = book
                        updatedBook.title = updated.title
                        updatedBook.author = updated.author
                        libraryViewModel.updateBookMetadata(updatedBook)
                        if writeToFile {
                            let url = URL(fileURLWithPath: book.filePath)
                            if let newHash = try? EPUBParser.writeMetadata(updated, to: url) {
                                var hashBook = updatedBook
                                hashBook.md5Hash = newHash
                                libraryViewModel.updateBookMetadata(hashBook)
                            }
                        }
                    }
                )
            } else if book.format.isAudio, let audioMeta = richInfoAudioMetadata {
                // Audio books get the rich metadata editor with album, genre, etc.
                MetadataEditorView(
                    audioMetadata: audioMeta,
                    onSave: { updated in
                        var updatedBook = book
                        updatedBook.title = updated.title
                        updatedBook.author = updated.artist
                        updatedBook.audioAlbum = updated.album
                        updatedBook.audioGenre = updated.genre
                        updatedBook.audioYear = updated.year
                        libraryViewModel.updateBookMetadata(updatedBook)
                    }
                )
            } else {
                // Plain text, markdown, HTML — simple title/author editor
                LibraryBookInfoSheet(book: book, libraryViewModel: libraryViewModel)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showBookInfo)) { notification in
            // Only open in the focused library window
            if let sourceWindow = notification.userInfo?["sourceWindow"] as? NSWindow {
                guard hostWindow == nil || sourceWindow === hostWindow else { return }
            } else {
                // Menu command (no sourceWindow) — check this window is key
                if let hw = hostWindow, !hw.isKeyWindow { return }
            }
            // Cmd+I: show info for the first selected book
            if let id = selectedBookIDs.first,
               let book = filteredBooks.first(where: { $0.id == id }) {
                showBookInfo(for: book)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSelectedBook)) { notification in
            // Only respond in the focused library window
            if let sourceWindow = notification.userInfo?["sourceWindow"] as? NSWindow {
                guard hostWindow == nil || sourceWindow === hostWindow else { return }
            } else {
                if let hw = hostWindow, !hw.isKeyWindow { return }
            }
            if let id = selectedBookIDs.first,
               let book = filteredBooks.first(where: { $0.id == id }) {
                onOpenBook(book)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newFromText)) { _ in
            // Only open in the focused library window
            if let hw = hostWindow, !hw.isKeyWindow { return }
            showTextInput = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .removeFromLibrary)) { notification in
            // Cmd+Delete: remove selected books from library
            if let sourceWindow = notification.userInfo?["sourceWindow"] as? NSWindow {
                guard hostWindow == nil || sourceWindow === hostWindow else { return }
            } else {
                if let hw = hostWindow, !hw.isKeyWindow { return }
            }
            let books = selectedBooks
            if !books.isEmpty {
                libraryViewModel.removeBooks(books)
                clearAllSelections()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newFolder)) { notification in
            // Cmd+Shift+N: create new folder
            if let sourceWindow = notification.userInfo?["sourceWindow"] as? NSWindow {
                guard hostWindow == nil || sourceWindow === hostWindow else { return }
            } else {
                if let hw = hostWindow, !hw.isKeyWindow { return }
            }
            newFolderParentPath = currentFolderPath
            showNewFolderSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .moveToFolder)) { notification in
            // Cmd+Shift+M: move selected books to folder
            if let sourceWindow = notification.userInfo?["sourceWindow"] as? NSWindow {
                guard hostWindow == nil || sourceWindow === hostWindow else { return }
            } else {
                if let hw = hostWindow, !hw.isKeyWindow { return }
            }
            let books = selectedBooks
            if !books.isEmpty {
                booksToMove = books
                showMoveSheet = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectAll)) { notification in
            // Cmd+A: select all visible books (in edit mode, use edit selection)
            if let sourceWindow = notification.userInfo?["sourceWindow"] as? NSWindow {
                guard hostWindow == nil || sourceWindow === hostWindow else { return }
            } else {
                if let hw = hostWindow, !hw.isKeyWindow { return }
            }
            let allIDs = Set(filteredBooks.map { $0.id })
            if isEditMode {
                editSelection = allIDs
            } else {
                // Auto-enter edit mode so the selection is visible and persistent
                editSelection = allIDs
                isEditMode = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleEditMode)) { notification in
            // Cmd+E: toggle edit mode
            if let sourceWindow = notification.userInfo?["sourceWindow"] as? NSWindow {
                guard hostWindow == nil || sourceWindow === hostWindow else { return }
            } else {
                if let hw = hostWindow, !hw.isKeyWindow { return }
            }
            if isEditMode {
                clearAllSelections()
            } else {
                isEditMode = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .moveBookUp)) { notification in
            if let sourceWindow = notification.userInfo?["sourceWindow"] as? NSWindow {
                guard hostWindow == nil || sourceWindow === hostWindow else { return }
            } else {
                if let hw = hostWindow, !hw.isKeyWindow { return }
            }
            moveSelectedBookInManualOrder(direction: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .moveBookDown)) { notification in
            if let sourceWindow = notification.userInfo?["sourceWindow"] as? NSWindow {
                guard hostWindow == nil || sourceWindow === hostWindow else { return }
            } else {
                if let hw = hostWindow, !hw.isKeyWindow { return }
            }
            moveSelectedBookInManualOrder(direction: 1)
        }
        .sheet(isPresented: $showTextInput) {
            TextInputView(
                onAdd: { title, author, text in
                    libraryViewModel.createBookFromText(title: title, author: author, text: text, toFolder: currentFolderPath)
                    showTextInput = false
                },
                onCancel: { showTextInput = false }
            )
        }
        // Rename folder sheet
        .sheet(isPresented: $showRenameFolderSheet) {
            if let folder = folderToRename {
                RenameFolderSheet(
                    currentName: folder.name,
                    newName: $renameFolderText,
                    onRename: {
                        libraryViewModel.renameFolder(folder, to: renameFolderText)
                        // Update currentFolderPath if we're inside the renamed folder
                        if currentFolderPath == folder.fullPath {
                            let sanitized = renameFolderText
                                .replacingOccurrences(of: "/", with: "-")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            currentFolderPath = folder.parentPath.isEmpty
                                ? sanitized
                                : "\(folder.parentPath)/\(sanitized)"
                        } else if currentFolderPath.hasPrefix(folder.fullPath + "/") {
                            let sanitized = renameFolderText
                                .replacingOccurrences(of: "/", with: "-")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            let newPrefix = folder.parentPath.isEmpty
                                ? sanitized
                                : "\(folder.parentPath)/\(sanitized)"
                            currentFolderPath = newPrefix + String(currentFolderPath.dropFirst(folder.fullPath.count))
                        }
                        showRenameFolderSheet = false
                    },
                    onCancel: {
                        showRenameFolderSheet = false
                    }
                )
            }
        }
        // Move folder to new parent sheet
        .sheet(isPresented: $showMoveFolderSheet) {
            if let folder = folderToMove {
                MoveFolderToParentSheet(
                    folder: folder,
                    library: libraryViewModel.library,
                    onMove: { newParent in
                        libraryViewModel.moveFolder(folder, toParent: newParent)
                        showMoveFolderSheet = false
                    },
                    onCancel: { showMoveFolderSheet = false }
                )
            }
        }
        // Delete folder dialog: move contents out vs delete everything
        .alert(
            "Delete Folder?",
            isPresented: $libraryViewModel.showDeleteFolderDialog
        ) {
            Button("Move Contents Out") {
                libraryViewModel.showDeleteFolderDestinationSheet = true
            }
            Button("Delete Everything", role: .destructive) {
                libraryViewModel.showDeleteEverythingConfirm = true
            }
            Button("Cancel", role: .cancel) {
                libraryViewModel.pendingDeleteFolder = nil
            }
        } message: {
            if let folder = libraryViewModel.pendingDeleteFolder {
                let count = libraryViewModel.library.totalBooksInFolderTree(folder.fullPath)
                Text("\"\(folder.name)\" contains \(count) \(count == 1 ? "book" : "books") and may have subfolders. What would you like to do?")
            }
        }
        // Second confirmation for Delete Everything
        .alert(
            "Are you sure?",
            isPresented: $libraryViewModel.showDeleteEverythingConfirm
        ) {
            Button("Delete Everything", role: .destructive) {
                if let folder = libraryViewModel.pendingDeleteFolder {
                    libraryViewModel.removeFolderAndEverything(folder)
                    libraryViewModel.pendingDeleteFolder = nil
                }
            }
            Button("Cancel", role: .cancel) {
                libraryViewModel.pendingDeleteFolder = nil
            }
        } message: {
            if let folder = libraryViewModel.pendingDeleteFolder {
                let count = libraryViewModel.library.totalBooksInFolderTree(folder.fullPath)
                Text("This will permanently remove the folder \"\(folder.name)\" and all \(count) \(count == 1 ? "book" : "books") inside it. This cannot be undone.")
            }
        }
        // Move contents destination picker
        .sheet(isPresented: $libraryViewModel.showDeleteFolderDestinationSheet) {
            if let folder = libraryViewModel.pendingDeleteFolder {
                DeleteFolderMoveContentsSheet(
                    folder: folder,
                    library: libraryViewModel.library,
                    onConfirm: { destination in
                        libraryViewModel.removeFolderMovingContents(folder, toPath: destination)
                        libraryViewModel.pendingDeleteFolder = nil
                        libraryViewModel.showDeleteFolderDestinationSheet = false
                    },
                    onCancel: {
                        libraryViewModel.pendingDeleteFolder = nil
                        libraryViewModel.showDeleteFolderDestinationSheet = false
                    }
                )
            }
        }
    }

    /// Toggle a book's membership in the edit selection set
    private func toggleEditSelection(_ id: UUID) {
        if editSelection.contains(id) {
            editSelection.remove(id)
        } else {
            editSelection.insert(id)
        }
    }

    /// Clear all selections (both native and edit mode) and exit edit mode
    private func clearAllSelections() {
        editSelection = []
        selectedBookIDs = []
        isEditMode = false
    }

    /// The union of native List selection and edit mode selection.
    /// Shortcut handlers use this so either selection mechanism works.
    private var effectiveSelection: Set<UUID> {
        selectedBookIDs.union(editSelection)
    }

    /// Books currently selected via either mechanism
    private var selectedBooks: [Book] {
        let ids = effectiveSelection
        return filteredBooks.filter { ids.contains($0.id) }
    }

    private var displayedBooks: [Book] {
        libraryViewModel.sortedBooks(
            libraryViewModel.booksForCategory(category, folderPath: currentFolderPath),
            by: sortField,
            ascending: sortAscending
        )
    }

    /// Move the currently selected book up or down in manual sort order.
    /// Only works when a single book is selected and sort is Manual Order.
    private func moveSelectedBookInManualOrder(direction: Int) {
        guard sortField == .manual else { return }
        let ids = effectiveSelection
        guard ids.count == 1, let bookID = ids.first else { return }
        libraryViewModel.moveBookInManualOrder(
            bookID: bookID, direction: direction, folderPath: currentFolderPath
        )
    }

    private var filteredBooks: [Book] {
        let books = displayedBooks
        if searchText.isEmpty { return books }
        let query = searchText.lowercased()
        return books.filter {
            $0.title.lowercased().contains(query) ||
            $0.author.lowercased().contains(query)
        }
    }

    private func navigateUp() {
        let parts = currentFolderPath.components(separatedBy: "/")
        if parts.count > 1 {
            currentFolderPath = parts.dropLast().joined(separator: "/")
        } else {
            currentFolderPath = ""
        }
    }

    /// Load format-specific metadata and present the appropriate info editor.
    /// EPUB and audio books get the rich MetadataEditorView; plain text formats
    /// get the simple LibraryBookInfoSheet.
    private func showBookInfo(for book: Book) {
        richInfoEPUBMetadata = nil
        richInfoAudioMetadata = nil

        if book.format == .epub {
            // Load EPUB metadata from the file
            let url = URL(fileURLWithPath: book.filePath)
            richInfoEPUBMetadata = try? EPUBParser.readMetadata(url: url)
        } else if book.format.isAudio {
            // Load audio metadata asynchronously, then show the sheet
            Task {
                let meta = await AudioPlaybackService.extractFullMetadata(
                    from: URL(fileURLWithPath: book.filePath)
                )
                // Overlay stored user edits
                var merged = meta
                merged.title = book.title
                merged.artist = book.author
                if let album = book.audioAlbum { merged.album = album }
                if let genre = book.audioGenre { merged.genre = genre }
                if let year = book.audioYear { merged.year = year }
                await MainActor.run {
                    richInfoAudioMetadata = merged
                    bookInfoTarget = book
                }
            }
            return // Don't set bookInfoTarget yet — the Task will do it
        }

        bookInfoTarget = book
    }
}

// MARK: - Edit Mode Bar

/// Toolbar shown at the top of the library when edit mode is active.
/// Provides batch actions and selection controls that work reliably with VoiceOver.
struct EditModeBar: View {
    let selectedCount: Int
    let totalCount: Int
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void
    let onMove: () -> Void
    let onRemove: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(selectedCount) of \(totalCount) selected")
                .font(.callout)
                .fontWeight(.medium)

            Spacer()

            Button(selectedCount == totalCount ? "Deselect All" : "Select All") {
                if selectedCount == totalCount {
                    onDeselectAll()
                } else {
                    onSelectAll()
                }
            }
            .accessibilityLabel(selectedCount == totalCount ? "Deselect all books" : "Select all \(totalCount) books")

            Button("Move") { onMove() }
                .disabled(selectedCount == 0)
                .accessibilityLabel("Move \(selectedCount) \(selectedCount == 1 ? "book" : "books") to folder")

            Button("Remove", role: .destructive) { onRemove() }
                .disabled(selectedCount == 0)
                .accessibilityLabel("Remove \(selectedCount) \(selectedCount == 1 ? "book" : "books") from library")

            Button("Done") { onDone() }
                .fontWeight(.semibold)
                .accessibilityLabel("Exit edit mode")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Edit mode, \(selectedCount) of \(totalCount) books selected")
    }
}

// MARK: - Time Remaining Bar

struct TimeRemainingBar: View {
    let books: [Book]
    let wpm: Double

    var body: some View {
        let (time, known, unknown) = computeTimeRemaining()
        if known > 0 || unknown > 0 {
            HStack(spacing: 12) {
                Label {
                    if known > 0 {
                        Text("\(TimeFormatting.format(time)) remaining")
                    }
                } icon: {
                    Image(systemName: "clock")
                        .foregroundColor(.green)
                }
                .font(.caption)

                if unknown > 0 {
                    Text("(\(unknown) \(unknown == 1 ? "book" : "books") not yet opened)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text("\(books.count) \(books.count == 1 ? "book" : "books")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel(time: time, known: known, unknown: unknown))
        }
    }

    private func computeTimeRemaining() -> (TimeInterval, Int, Int) {
        var total: TimeInterval = 0
        var known = 0
        var unknown = 0
        for book in books {
            if let remaining = book.estimatedTimeRemaining(wpm: wpm) {
                total += remaining
                known += 1
            } else {
                unknown += 1
            }
        }
        return (total, known, unknown)
    }

    private func accessibilityLabel(time: TimeInterval, known: Int, unknown: Int) -> String {
        var parts: [String] = []
        parts.append("\(books.count) \(books.count == 1 ? "book" : "books")")
        if known > 0 {
            parts.append("\(TimeFormatting.spoken(time)) total remaining at current speed")
        }
        if unknown > 0 {
            parts.append("\(unknown) \(unknown == 1 ? "book has" : "books have") not been opened yet")
        }
        return parts.joined(separator: ". ")
    }
}

// MARK: - Subviews

struct BreadcrumbBar: View {
    let path: String
    let onNavigate: (String) -> Void
    let onNavigateRoot: () -> Void

    var body: some View {
        HStack {
            Button("Library") { onNavigateRoot() }
                .buttonStyle(.plain)
                .accessibilityLabel("Navigate to library root")

            let parts = path.components(separatedBy: "/")
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)

                Button(part) {
                    let subPath = parts[0...index].joined(separator: "/")
                    onNavigate(subPath)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Navigate to \(part)")
            }

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }
}

struct FolderRow: View {
    let folder: BookFolder
    var bookCount: Int = 0

    var body: some View {
        HStack {
            Image(systemName: "folder.fill")
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)
            Text(folder.name)
                .font(.headline)
            Spacer()
            Text("\(bookCount) \(bookCount == 1 ? "book" : "books")")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(folder.name), \(bookCount) \(bookCount == 1 ? "book" : "books")")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Double-tap to open folder")
    }
}

struct BookRow: View {
    let book: Book
    var isOpenInWindow: Bool = false
    var wpm: Double = 200
    var isEditMode: Bool = false
    var isEditSelected: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            // Selection indicator in edit mode
            if isEditMode {
                Image(systemName: isEditSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isEditSelected ? .accentColor : .secondary)
                    .font(.title3)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(book.title)
                        .font(.headline)

                    if book.lastOpened == nil {
                        Text("New")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(3)
                    } else if isOpenInWindow {
                        Text("Now Reading")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(3)
                    }
                }
                HStack {
                    Text(book.author)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Spacer()

                    if let pos = book.readingPosition {
                        Text("Ch. \(pos.chapterIndex + 1)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let remaining = book.estimatedTimeRemaining(wpm: wpm) {
                        Text("\(TimeFormatting.format(remaining)) left")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text(book.format.displayName)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(isEditMode
            ? "Double-tap to \(isEditSelected ? "deselect" : "select")"
            : "Press Enter to open, Command I for info")
        .accessibilityAddTraits(isEditSelected ? [.isSelected] : [])
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        if isEditMode && isEditSelected {
            parts.append("Selected")
        }
        parts.append(book.title)
        parts.append("by \(book.author)")
        if book.lastOpened == nil {
            parts.append("New")
        } else if isOpenInWindow {
            parts.append("Now Reading")
        }
        if let pos = book.readingPosition {
            parts.append("Chapter \(pos.chapterIndex + 1)")
        }
        if let remaining = book.estimatedTimeRemaining(wpm: wpm) {
            parts.append("\(TimeFormatting.spoken(remaining)) remaining")
        }
        parts.append(book.format.displayName)
        return parts.joined(separator: ", ")
    }
}

/// Book info editor accessible from the library context menu
struct LibraryBookInfoSheet: View {
    let book: Book
    let libraryViewModel: LibraryViewModel
    @State private var title: String
    @State private var author: String
    @Environment(\.dismiss) private var dismiss

    init(book: Book, libraryViewModel: LibraryViewModel) {
        self.book = book
        self.libraryViewModel = libraryViewModel
        self._title = State(initialValue: book.title)
        self._author = State(initialValue: book.author)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Book Information")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Form {
                TextField("Title", text: $title)
                    .accessibilityLabel("Book title")
                TextField("Author", text: $author)
                    .accessibilityLabel("Book author")

                LabeledContent("Format") {
                    Text(book.format.displayName)
                }
                LabeledContent("Added") {
                    Text(book.dateAdded, style: .date)
                }
                if let lastOpened = book.lastOpened {
                    LabeledContent("Last Opened") {
                        Text(lastOpened, style: .date)
                    }
                }
                if let words = book.totalWordCount {
                    LabeledContent("Word Count") {
                        Text("\(words)")
                    }
                }
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button("Save") {
                    // Capture state before dismissing
                    let savedTitle = title
                    let savedAuthor = author
                    let savedBook = book
                    let vm = libraryViewModel

                    // Dismiss first so shared state updates don't steal focus
                    dismiss()

                    DispatchQueue.main.async {
                        var updated = savedBook
                        updated.title = savedTitle
                        updated.author = savedAuthor
                        vm.updateBookMetadata(updated)
                    }
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(title.isEmpty)
            }
        }
        .padding()
        .frame(width: 400, height: 350)
        .navigationTitle("Info: \(book.title)")
    }
}

struct NewFolderSheet: View {
    @Binding var folderName: String
    @Binding var parentPath: String
    let folders: [BookFolder]
    let onCreate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("New Folder")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            TextField("Folder name", text: $folderName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Folder name")

            Picker("Parent folder", selection: $parentPath) {
                Text("Library Root").tag("")
                ForEach(folders.sortedTreeOrder()) { folder in
                    if folder.depth < BookFolder.maxDepth {
                        Text(folder.fullPath).tag(folder.fullPath)
                    }
                }
            }
            .accessibilityLabel("Parent folder")

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Create", action: onCreate)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(folderName.isEmpty)
            }
        }
        .padding()
        .frame(width: 300)
        .navigationTitle("New Folder")
    }
}

struct MoveFolderSheet: View {
    let books: [Book]
    let library: Library
    let lastMovedFolderPath: String
    let onMove: (String) -> Void
    let onCreateFolder: (String, String) -> Void
    let onCancel: () -> Void

    /// The folder path currently selected in the picker
    @State private var selectedPath: String = ""
    /// Whether the inline new-folder fields are showing
    @State private var showNewFolder = false
    /// Name for the new folder being created
    @State private var newFolderName = ""
    /// Parent path for the new folder
    @State private var newFolderParent = ""

    /// Title shown in the sheet header
    private var headerTitle: String {
        if books.count == 1, let book = books.first {
            return "Move \"\(book.title)\""
        }
        return "Move \(books.count) Books"
    }

    /// All available destination paths, including "Library Root" (empty string)
    private var folderOptions: [(label: String, path: String)] {
        var options: [(String, String)] = [("Library Root", "")]
        for folder in library.folders.sortedTreeOrder() {
            options.append((folder.fullPath, folder.fullPath))
        }
        return options
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(headerTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            // Folder picker
            Picker("Destination", selection: $selectedPath) {
                ForEach(folderOptions, id: \.path) { option in
                    Text(option.label).tag(option.path)
                }
            }
            .accessibilityLabel("Destination folder")

            // Inline new folder creation
            if showNewFolder {
                GroupBox("New Folder") {
                    VStack(spacing: 8) {
                        TextField("Folder name", text: $newFolderName)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("New folder name")

                        Picker("Parent folder", selection: $newFolderParent) {
                            Text("Library Root").tag("")
                            ForEach(library.folders.sortedTreeOrder()) { folder in
                                if folder.depth < BookFolder.maxDepth {
                                    Text(folder.fullPath).tag(folder.fullPath)
                                }
                            }
                        }
                        .accessibilityLabel("Parent folder for new folder")

                        HStack {
                            Button("Cancel") {
                                newFolderName = ""
                                showNewFolder = false
                            }
                            Spacer()
                            Button("Create") {
                                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !name.isEmpty else { return }
                                onCreateFolder(name, newFolderParent)
                                // Select the newly created folder as destination
                                let sanitized = name.replacingOccurrences(of: "/", with: "-")
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                let newPath = newFolderParent.isEmpty ? sanitized : "\(newFolderParent)/\(sanitized)"
                                selectedPath = newPath
                                newFolderName = ""
                                showNewFolder = false
                            }
                            .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                if !showNewFolder {
                    Button("New Folder...") {
                        showNewFolder = true
                    }
                }

                Button("Move") {
                    onMove(selectedPath)
                }
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding()
        .frame(width: 400)
        .navigationTitle(headerTitle)
        .onAppear {
            // Default to last moved folder if it still exists, otherwise Library Root
            if !lastMovedFolderPath.isEmpty,
               folderOptions.contains(where: { $0.path == lastMovedFolderPath }) {
                selectedPath = lastMovedFolderPath
            }
        }
    }
}

/// Sheet for moving a folder to a new parent folder
/// Sheet for renaming a folder
struct RenameFolderSheet: View {
    let currentName: String
    @Binding var newName: String
    let onRename: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Folder")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            TextField("Folder name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("New folder name")

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Rename", action: onRename)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || newName.trimmingCharacters(in: .whitespacesAndNewlines) == currentName)
            }
        }
        .padding()
        .frame(width: 300)
        .navigationTitle("Rename Folder")
    }
}

struct MoveFolderToParentSheet: View {
    let folder: BookFolder
    let library: Library
    let onMove: (String) -> Void
    let onCancel: () -> Void

    @State private var selectedParent = ""

    /// Valid destinations: all folders except the folder itself, its descendants, and its current parent
    private var validDestinations: [(label: String, path: String)] {
        let selfPath = folder.fullPath
        var options: [(String, String)] = [("Library Root", "")]
        for f in library.folders.sortedTreeOrder() {
            // Exclude: the folder itself, its descendants, and check depth limit
            if f.fullPath == selfPath { continue }
            if f.fullPath.hasPrefix(selfPath + "/") { continue }
            // Check that moving here wouldn't exceed max depth
            let newDepth = (f.fullPath.isEmpty ? 0 : f.fullPath.components(separatedBy: "/").count) + 1
            if newDepth > BookFolder.maxDepth { continue }
            options.append((f.fullPath, f.fullPath))
        }
        return options
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Move \"\(folder.name)\"")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Picker("New parent folder", selection: $selectedParent) {
                ForEach(validDestinations, id: \.path) { option in
                    Text(option.label).tag(option.path)
                }
            }
            .accessibilityLabel("Destination parent folder")

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Move") { onMove(selectedParent) }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(selectedParent == folder.parentPath)
            }
        }
        .padding()
        .frame(width: 400)
        .navigationTitle("Move Folder: \(folder.name)")
        .onAppear {
            selectedParent = folder.parentPath
        }
    }
}

/// Sheet for choosing where to move folder contents when deleting a folder
struct DeleteFolderMoveContentsSheet: View {
    let folder: BookFolder
    let library: Library
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    @State private var selectedDestination = ""

    /// Valid destinations: all folders except the folder being deleted and its descendants
    private var validDestinations: [(label: String, path: String)] {
        let selfPath = folder.fullPath
        var options: [(String, String)] = [("Library Root", "")]
        for f in library.folders.sortedTreeOrder() {
            if f.fullPath == selfPath { continue }
            if f.fullPath.hasPrefix(selfPath + "/") { continue }
            options.append((f.fullPath, f.fullPath))
        }
        return options
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Move Contents of \"\(folder.name)\"")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Text("Choose where to move the books and subfolders before deleting \"\(folder.name)\".")
                .font(.callout)
                .foregroundColor(.secondary)

            Picker("Move contents to", selection: $selectedDestination) {
                ForEach(validDestinations, id: \.path) { option in
                    Text(option.label).tag(option.path)
                }
            }
            .accessibilityLabel("Destination for folder contents")

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Move Contents & Delete Folder") {
                    onConfirm(selectedDestination)
                }
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding()
        .frame(width: 450)
        .navigationTitle("Move Contents: \(folder.name)")
        .onAppear {
            // Default to the parent of the folder being deleted
            selectedDestination = folder.parentPath
        }
    }
}

// MARK: - Tree-Order Folder Sorting

extension Array where Element == BookFolder {
    /// Sort folders in tree order: each parent is immediately followed by its children,
    /// then the next sibling. Siblings are sorted alphabetically.
    /// This prevents unrelated folders like "Misc SciFi anthologies" from appearing
    /// between "Misc SciFi" and "Misc SciFi/Sub" in picker lists.
    func sortedTreeOrder() -> [BookFolder] {
        // Sort so that a folder's children appear immediately after it,
        // before any unrelated folder that shares a prefix (e.g. "Misc SciFi"
        // children before "Misc SciFi anthologies").
        //
        // Replace "/" with "\0" for comparison so path separators sort before
        // any printable character (space is 0x20, "/" is 0x2F — both after "\0").
        // This ensures "Misc SciFi\0Sub" < "Misc SciFi anthologies".
        sorted {
            let a = $0.fullPath.lowercased().replacingOccurrences(of: "/", with: "\0")
            let b = $1.fullPath.lowercased().replacingOccurrences(of: "/", with: "\0")
            return a < b
        }
    }
}

// Make Book conform to Identifiable for .sheet(item:) usage (already conforms via existing `id` property)

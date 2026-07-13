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
        let subfolders = category == .folders ? libraryViewModel.subfoldersOf(currentFolderPath) : []

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
            continueListeningButton

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
            TimeRemainingBar(
                books: displayedBooks,
                wpm: settingsViewModel.wordsPerMinute,
                focusIdentifier: preferredLibraryFocusTarget == .timeSummary ? voiceOverFocusID : nil,
                shouldTriggerFocus: preferredLibraryFocusTarget == .timeSummary
            )

            // Main list with native selection
            List(selection: $selectedBookIDs) {
                // Folders section (only in folders category)
                if category == .folders {
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
                    ForEach(Array(filteredBooks.enumerated()), id: \.element.id) { index, book in
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
                                    let canUp = libraryViewModel.canMoveBookInManualOrder(
                                        bookID: book.id, direction: -1, folderPath: currentFolderPath
                                    )
                                    let canDown = libraryViewModel.canMoveBookInManualOrder(
                                        bookID: book.id, direction: 1, folderPath: currentFolderPath
                                    )
                                    if canUp || canDown {
                                        Divider()
                                    }
                                    if canUp {
                                        Button("Move Up") {
                                            if let result = libraryViewModel.moveBookInManualOrder(
                                                bookID: book.id, direction: -1, folderPath: currentFolderPath
                                            ) {
                                                announceToVoiceOver("Moved \(result.movedTitle) above \(result.adjacentTitle)")
                                            }
                                        }
                                    }
                                    if canDown {
                                        Button("Move Down") {
                                            if let result = libraryViewModel.moveBookInManualOrder(
                                                bookID: book.id, direction: 1, folderPath: currentFolderPath
                                            ) {
                                                announceToVoiceOver("Moved \(result.movedTitle) below \(result.adjacentTitle)")
                                            }
                                        }
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

                importBookButton

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
                    // Only show "Apply to Subfolders" when in folders mode and subfolders exist
                    if category == .folders {
                        let hasSubfolders = !libraryViewModel.subfoldersOf(currentFolderPath).isEmpty
                        if hasSubfolders {
                            Divider()
                            Button {
                                let setting = FolderSortSetting(sortField: sortField, sortAscending: sortAscending)
                                libraryViewModel.applySortToSubfolders(setting, from: currentFolderPath)
                            } label: {
                                Text("Apply Sort to All Subfolders")
                            }
                        }
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
                        updatedBook.epubPublisher = updated.publisher
                        updatedBook.epubPublicationDate = updated.publicationDate
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

    // MARK: - Extracted Subviews

    /// Continue Listening button — extracted to reduce body complexity for the type checker
    @ViewBuilder
    private var continueListeningButton: some View {
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
            .accessibilityIdentifier(voiceOverFocusID)
            .background(StandardVoiceOverFocus(delay: 1.2))
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

    private enum LibraryFocusTarget {
        case timeSummary
        case importButton
    }

    private var preferredLibraryFocusTarget: LibraryFocusTarget? {
        guard libraryViewModel.lastOpenedBook == nil else { return nil }
        // The content summary above the table is a stable AX target in this view,
        // while section headers were not reliably discoverable by the focus helper.
        if !displayedBooks.isEmpty {
            return .timeSummary
        }
        return .importButton
    }

    private var importBookButton: some View {
        Button {
            showFileImporter = true
        } label: {
            Label("Import Book", systemImage: "plus")
        }
        .accessibilityLabel("Import a book file")
        .accessibilityHint("Opens a file picker to import EPUB, text, markdown, or HTML files")
        .modifier(LibraryFocusTargetModifier(
            isEnabled: preferredLibraryFocusTarget == .importButton
        ))
    }

    private struct LibraryFocusTargetModifier: ViewModifier {
        let isEnabled: Bool

        func body(content: Content) -> some View {
            if isEnabled {
                content
                    .accessibilityIdentifier(voiceOverFocusID)
                    .background(StandardVoiceOverFocus(delay: 1.2))
            } else {
                content
            }
        }
    }

    /// Move the currently selected book up or down in manual sort order.
    /// Only works when a single book is selected and sort is Manual Order.
    /// Announces the result to VoiceOver.
    private func moveSelectedBookInManualOrder(direction: Int) {
        guard sortField == .manual else { return }
        let ids = effectiveSelection
        guard ids.count == 1, let bookID = ids.first else { return }
        if let result = libraryViewModel.moveBookInManualOrder(
            bookID: bookID, direction: direction, folderPath: currentFolderPath
        ) {
            let position = result.direction < 0 ? "above" : "below"
            let message = "Moved \(result.movedTitle) \(position) \(result.adjacentTitle)"
            announceToVoiceOver(message)
        }
    }

    /// Post a VoiceOver announcement for the library window.
    private func announceToVoiceOver(_ message: String) {
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
            if let extracted = try? EPUBParser.readMetadata(url: url) {
                richInfoEPUBMetadata = book.mergingEditableEPUBMetadata(extracted)
            }
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

// Make Book conform to Identifiable for .sheet(item:) usage (already conforms via existing `id` property)

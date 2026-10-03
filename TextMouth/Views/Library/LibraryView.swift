import SwiftUI

/// Shared decision table for routing keyboard and menu commands to one of
/// several open windows. Source-tagged shortcuts follow their source window;
/// source-less menu commands follow the key window. During initial window
/// attachment a missing host is accepted so the first command is not lost.
enum WindowCommandRouting {
    static func shouldAccept(
        hasSourceWindow: Bool,
        sourceMatchesHost: Bool,
        hasHostWindow: Bool,
        hostWindowIsKey: Bool
    ) -> Bool {
        if hasSourceWindow {
            return !hasHostWindow || sourceMatchesHost
        }
        return !hasHostWindow || hostWindowIsKey
    }

    /// Route a command from either a normal window or one of its presented
    /// sheets. AppKit makes the sheet the key window while it is visible, so
    /// comparing the key/source window directly with its reader host prevents
    /// a panel's own shortcut from reaching the reader to close that panel.
    @MainActor
    static func shouldAccept(
        sourceWindow: NSWindow?,
        hostWindow: NSWindow?,
        keyWindow: NSWindow?
    ) -> Bool {
        guard let hostWindow else { return true }

        // A source-tagged keyboard shortcut follows its source. A menu command
        // has no source tag, so it follows the window currently receiving keys.
        guard let commandWindow = sourceWindow ?? keyWindow else {
            return hostWindow.isKeyWindow
        }

        return rootWindow(for: commandWindow) === rootWindow(for: hostWindow)
    }

    /// Walk through nested sheets to the document window that owns them.
    /// The visited set guards against a malformed AppKit relationship cycle.
    @MainActor
    static func rootWindow(for window: NSWindow) -> NSWindow {
        var currentWindow = window
        var visited: Set<ObjectIdentifier> = []

        while visited.insert(ObjectIdentifier(currentWindow)).inserted,
              let parent = currentWindow.sheetParent {
            currentWindow = parent
        }

        return currentWindow
    }
}

enum LibraryFocusTarget: Equatable {
    case continueListening
    case timeSummary
    case importButton

    /// Chooses a single initial accessibility target for the library.
    static func preferred(hasContinueListening: Bool, hasDisplayedBooks: Bool) -> Self {
        if hasContinueListening { return .continueListening }
        return hasDisplayedBooks ? .timeSummary : .importButton
    }
}

/// Pure selection rules shared by mouse, keyboard, context-menu, and
/// accessibility-driven library actions.
enum LibrarySelectionPolicy {
    static func toggled(_ selection: Set<UUID>, id: UUID) -> Set<UUID> {
        var result = selection
        if result.remove(id) == nil { result.insert(id) }
        return result
    }

    static func effective(native: Set<UUID>, edit: Set<UUID>) -> Set<UUID> {
        native.union(edit)
    }

    static func contextTargets(clickedID: UUID, effectiveSelection: Set<UUID>) -> Set<UUID> {
        if effectiveSelection.contains(clickedID), effectiveSelection.count > 1 {
            return effectiveSelection
        }
        return [clickedID]
    }

    static func clear(
        native: inout Set<UUID>,
        edit: inout Set<UUID>,
        isEditMode: inout Bool
    ) {
        native.removeAll()
        edit.removeAll()
        isEditMode = false
    }
}

/// Where a library window goes after one of its folder sheets renames or
/// moves a folder (TODO A07). Pure, so the rule is tested without a window.
enum FolderSheetNavigation {
    /// The folder path a window shows after an edit that tried to move the
    /// folder at `oldPath` to `newPath` (nil when the folder is no longer in
    /// the library). Only a success moves anything: a window showing that
    /// folder, or a folder inside it, follows it to its new path, and every
    /// other window stays where it is. After a failure, whether a refused
    /// name, a collision, or a write that failed, the window stays exactly
    /// where it was, just as the library did.
    static func folderPath(
        showing currentPath: String,
        after outcome: OperationOutcome,
        folderMovedFrom oldPath: String,
        to newPath: String?
    ) -> String {
        // The root never moves, and an empty prefix would match every path.
        guard outcome.succeeded, let newPath, !oldPath.isEmpty else { return currentPath }
        if currentPath == oldPath {
            return newPath
        }
        if currentPath.hasPrefix(oldPath + "/") {
            return newPath + String(currentPath.dropFirst(oldPath.count))
        }
        return currentPath
    }
}

struct LibraryView: View {
    @EnvironmentObject var libraryViewModel: LibraryViewModel
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Binding var currentFolderPath: String
    @Binding var category: LibraryCategory
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
    /// Whether removing asks first and where deleted files go, kept current
    /// so removal buttons and confirmations say what removal will do.
    @State private var removalPreferences = RemovalPreferences(ConfigService.shared.config)

    var body: some View {
        let subfolders = category == .folders ? libraryViewModel.subfoldersOf(currentFolderPath) : []

        VStack(spacing: 0) {
            // While the library index cannot be read, keep that visible after
            // the recovery sheet closes, with a way back to its options.
            if libraryViewModel.indexRecovery != nil {
                LibraryIndexRecoveryBanner {
                    libraryViewModel.showIndexRecoveryOptions = true
                }
            }

            // Writes and cleanups that failed stay in view, with Retry, until
            // they succeed or are dismissed (TODO S09).
            PersistenceFailureBanner(center: libraryViewModel.failureCenter)

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
                    removalPreferences: removalPreferences,
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
                                    let ids = LibrarySelectionPolicy.contextTargets(
                                        clickedID: book.id,
                                        effectiveSelection: effectiveSelection
                                    )
                                    return filteredBooks.filter { ids.contains($0.id) }
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
                                if !isMulti && sort.field == .manual {
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
                                // Says what removal will do: ask first, or
                                // move the files to the Trash, or delete them.
                                Button(
                                    LibraryRemoveCommandWording(
                                        preferences: removalPreferences,
                                        books: targetBooks
                                    ).menuTitle,
                                    role: .destructive
                                ) {
                                    libraryViewModel.removeBooks(targetBooks)
                                    clearAllSelections()
                                }
                            }
                    }
                    .onMove { source, destination in
                        if sort.field == .manual {
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

                // Sort controls. Every item reads the one sort the location
                // shows and changes it only through userChangedSort, so the
                // menu, the window title, and the order agree (TODO A06).
                Menu {
                    // A checkmark marks the field shown, for VoiceOver as
                    // well as on screen; choosing that field again reverses
                    // its direction, as the menu always has.
                    ForEach(LibrarySortField.allCases, id: \.self) { field in
                        Toggle(field.rawValue, isOn: Binding(
                            get: { sort.isChecked(field) },
                            set: { _ in userChangedSort(.choose(field)) }
                        ))
                    }
                    Divider()
                    // Disabled in manual order, which has no direction; the
                    // hint says why, to VoiceOver and as a tooltip.
                    Button(sort.directionCommandTitle) {
                        userChangedSort(.reverseDirection)
                    }
                    .disabled(!sort.isDirectionCommandEnabled)
                    .help(sort.directionCommandHint)
                    .accessibilityHint(sort.directionCommandHint)
                    // Only show "Apply to Subfolders" when in folders mode and subfolders exist
                    if category == .folders {
                        let hasSubfolders = !libraryViewModel.subfoldersOf(currentFolderPath).isEmpty
                        if hasSubfolders {
                            Divider()
                            Button {
                                libraryViewModel.applySortToSubfolders(sort.setting, from: currentFolderPath)
                                announceToVoiceOver(sort.subfolderAnnouncement)
                            } label: {
                                Text("Apply Sort to All Subfolders")
                            }
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .accessibilityLabel(sort.menuAccessibilityLabel)
            }
        }
        // Each sheet below closes only after its operation succeeds. After a
        // failure it stays open with the user's input and shows the reason,
        // and the window's folder and selection stay as they were (TODO A07).
        .sheet(isPresented: $showNewFolderSheet) {
            NewFolderSheet(
                folderName: $newFolderName,
                parentPath: $newFolderParentPath,
                folders: libraryViewModel.library.folders,
                onCreate: {
                    closingOnSuccess(libraryViewModel.createFolderReturningOutcome(
                        name: newFolderName,
                        parentPath: newFolderParentPath
                    )) {
                        newFolderName = ""
                        newFolderParentPath = currentFolderPath
                        showNewFolderSheet = false
                    }
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
                        closingOnSuccess(libraryViewModel.moveBooksReturningOutcome(booksToMove, toFolder: path)) {
                            clearAllSelections()
                            showMoveSheet = false
                        }
                    },
                    onCreateFolder: { name, parentPath in
                        libraryViewModel.createFolderReturningOutcome(name: name, parentPath: parentPath)
                    },
                    onCancel: { showMoveSheet = false }
                )
            }
        }
        .background(WindowAccessor(onWindowFound: { window in
            hostWindow = window
        }))
        .trackingRemovalPreferences($removalPreferences)
        // Library index recovery: presented at launch when library.json
        // cannot be read, and again from the recovery banner.
        .sheet(isPresented: $libraryViewModel.showIndexRecoveryOptions) {
            if let recovery = libraryViewModel.indexRecovery {
                LibraryIndexRecoverySheet(
                    recovery: recovery,
                    onTryAgain: { announceRecoveryOutcome(libraryViewModel.retryLibraryIndex()) },
                    onRebuild: { announceRecoveryOutcome(libraryViewModel.rebuildLibraryIndex()) },
                    onContinue: { libraryViewModel.showIndexRecoveryOptions = false },
                    onQuit: { libraryViewModel.quitWithoutWritingLibraryIndex() }
                )
            }
        }
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
                        editFolder(folder, closing: { showRenameFolderSheet = false }) {
                            libraryViewModel.renameFolderReturningOutcome(folder, to: renameFolderText)
                        }
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
                        editFolder(folder, closing: { showMoveFolderSheet = false }) {
                            libraryViewModel.moveFolderReturningOutcome(folder, toParent: newParent)
                        }
                    },
                    onCancel: { showMoveFolderSheet = false }
                )
            }
        }
        // Delete folder dialog: move contents out vs delete everything. The
        // words say whether everything goes to the Trash or is deleted
        // permanently, as the Trash preference chooses (TODO A08).
        .alert(
            "Delete Folder?",
            isPresented: $libraryViewModel.showDeleteFolderDialog
        ) {
            Button("Move Contents Out") {
                libraryViewModel.showDeleteFolderDestinationSheet = true
            }
            Button(deleteEverythingWording.buttonTitle, role: .destructive) {
                libraryViewModel.showDeleteEverythingConfirm = true
            }
            Button("Cancel", role: .cancel) {
                libraryViewModel.pendingDeleteFolder = nil
            }
        } message: {
            if libraryViewModel.pendingDeleteFolder != nil {
                Text(deleteEverythingWording.choiceMessage)
            }
        }
        // Second confirmation for Delete Everything
        .alert(
            deleteEverythingWording.confirmationTitle,
            isPresented: $libraryViewModel.showDeleteEverythingConfirm
        ) {
            Button(deleteEverythingWording.buttonTitle, role: .destructive) {
                if let folder = libraryViewModel.pendingDeleteFolder {
                    libraryViewModel.removeFolderAndEverything(folder)
                    libraryViewModel.pendingDeleteFolder = nil
                }
            }
            Button("Cancel", role: .cancel) {
                libraryViewModel.pendingDeleteFolder = nil
            }
        } message: {
            if libraryViewModel.pendingDeleteFolder != nil {
                Text(deleteEverythingWording.confirmationMessage)
            }
        }
        // Move contents destination picker
        .sheet(isPresented: $libraryViewModel.showDeleteFolderDestinationSheet) {
            if let folder = libraryViewModel.pendingDeleteFolder {
                DeleteFolderMoveContentsSheet(
                    folder: folder,
                    library: libraryViewModel.library,
                    onConfirm: { destination in
                        closingOnSuccess(libraryViewModel.removeFolderMovingContentsReturningOutcome(
                            folder,
                            toPath: destination
                        )) {
                            libraryViewModel.pendingDeleteFolder = nil
                            libraryViewModel.showDeleteFolderDestinationSheet = false
                        }
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

    /// The words for Delete Everything on the folder awaiting confirmation,
    /// in the mode the Trash preference chooses. With no folder pending, no
    /// dialog shows, and only the mode-dependent button title matters.
    private var deleteEverythingWording: FolderRemovalWording {
        let folder = libraryViewModel.pendingDeleteFolder
        return FolderRemovalWording(
            mode: removalPreferences.deletionMode,
            folderName: folder?.name ?? "",
            bookCount: folder.map { libraryViewModel.library.totalBooksInFolderTree($0.fullPath) } ?? 0
        )
    }

    /// Toggle a book's membership in the edit selection set
    private func toggleEditSelection(_ id: UUID) {
        editSelection = LibrarySelectionPolicy.toggled(editSelection, id: id)
    }

    // MARK: - Finishing Sheets

    /// Finishes the operation a sheet started: after a success runs `close`,
    /// which clears what the sheet was editing and closes it. Returns the
    /// outcome either way, so the sheet can show and announce a failure
    /// while it stays open with the user's input.
    private func closingOnSuccess(_ outcome: OperationOutcome, close: () -> Void) -> OperationOutcome {
        if outcome.succeeded {
            close()
        }
        return outcome
    }

    /// Runs `edit`, a rename or move of `folder` from one of the folder
    /// sheets, and finishes the sheet. After a success the sheet closes, and
    /// a window showing the folder, or a folder inside it, follows it to its
    /// new path; after a failure the folder shown stays as it was.
    private func editFolder(
        _ folder: BookFolder,
        closing close: () -> Void,
        _ edit: () -> OperationOutcome
    ) -> OperationOutcome {
        // Read the folder's path from the library on both sides of the edit:
        // the sheet's copy is from when it opened, and another window may
        // have moved the folder since.
        let pathBefore = libraryViewModel.library.folders.first { $0.id == folder.id }?.fullPath ?? folder.fullPath
        let outcome = edit()
        let pathAfter = libraryViewModel.library.folders.first { $0.id == folder.id }?.fullPath
        let destination = FolderSheetNavigation.folderPath(
            showing: currentFolderPath,
            after: outcome,
            folderMovedFrom: pathBefore,
            to: pathAfter
        )
        // Assign only a real change, compared by exact spelling: navigating
        // clears the selection, while a normalization-only rename must
        // still store the folder's new spelling.
        if !BookFolder.spellingsMatch(destination, currentFolderPath) {
            currentFolderPath = destination
        }
        return closingOnSuccess(outcome, close: close)
    }

    /// Clear all selections (both native and edit mode) and exit edit mode
    private func clearAllSelections() {
        LibrarySelectionPolicy.clear(
            native: &selectedBookIDs,
            edit: &editSelection,
            isEditMode: &isEditMode
        )
    }

    /// The union of native List selection and edit mode selection.
    /// Shortcut handlers use this so either selection mechanism works.
    private var effectiveSelection: Set<UUID> {
        LibrarySelectionPolicy.effective(native: selectedBookIDs, edit: editSelection)
    }

    /// Books currently selected via either mechanism
    private var selectedBooks: [Book] {
        let ids = effectiveSelection
        return filteredBooks.filter { ids.contains($0.id) }
    }

    /// Where this list is: its category and, in Folders, its folder.
    private var location: LibraryLocation {
        LibraryLocation(category: category, folderPath: currentFolderPath)
    }

    /// The sort the list shows, restored from the setting saved for its
    /// location whenever the view draws, so the first frame, a change of
    /// folder or category, a change made in another window, and a library
    /// replaced by index recovery all show the saved sort (TODO A06).
    /// Showing it never saves it.
    private var sort: LibrarySortState {
        libraryViewModel.sortState(at: location)
    }

    /// Makes and saves a change the user chose in the Sort menu, the one
    /// way a location's sort changes, then says the sort now shown, since
    /// the menu closes without saying it (TODO A06).
    private func userChangedSort(_ change: LibrarySortChange) {
        let shown = libraryViewModel.userChangedSort(change, at: location)
        announceToVoiceOver(shown.changeAnnouncement)
    }

    private var displayedBooks: [Book] {
        libraryViewModel.sortedBooks(
            libraryViewModel.booksForCategory(category, folderPath: currentFolderPath),
            by: sort
        )
    }

    private var preferredLibraryFocusTarget: LibraryFocusTarget? {
        let target = LibraryFocusTarget.preferred(
            hasContinueListening: libraryViewModel.lastOpenedBook != nil,
            hasDisplayedBooks: !displayedBooks.isEmpty
        )
        // Continue Listening owns its own focus identifier and trigger.
        return target == .continueListening ? nil : target
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
        guard sort.field == .manual else { return }
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

    /// Announce what a library index recovery action did. When the action
    /// closed the recovery sheet, wait for VoiceOver to settle on the library
    /// first, so the change of focus does not cut the announcement off.
    private func announceRecoveryOutcome(_ outcome: LibraryIndexRecoveryOutcome) {
        let message = outcome.message
        guard !libraryViewModel.showIndexRecoveryOptions else {
            announceToVoiceOver(message)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            announceToVoiceOver(message)
        }
    }

    /// Post a high-priority VoiceOver announcement from the library window,
    /// or from the key (or main) window before the library knows its window.
    private func announceToVoiceOver(_ message: String) {
        VoiceOverAnnouncer.announce(message, from: hostWindow)
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

        guard book.format.usesRichMetadataEditor else {
            bookInfoTarget = book
            return
        }

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

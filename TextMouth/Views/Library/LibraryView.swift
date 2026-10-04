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
    /// Presents the New from Text sheet. The Library window owns it, so
    /// File > New from Text... can present the sheet through the router
    /// whichever window is key (TODO A05).
    @Binding var showTextInput: Bool
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
    /// What the Book Info sheet shows for `bookInfoTarget`: read off the
    /// main thread, and never downloaded for a book only in the cloud (FR02).
    @State private var bookInfo: LibraryBookInfo = .simple
    /// The Book Info request still reading, so only the latest one presents
    /// its sheet.
    @State private var bookInfoRequest: UUID?
    /// The NSWindow hosting this library, for checking key window status on notifications
    @State private var hostWindow: NSWindow?
    /// Whether removing asks first and where deleted files go, kept current
    /// so removal buttons and confirmations say what removal will do.
    @State private var removalPreferences = RemovalPreferences(ConfigService.shared.config)
    /// Every book's cloud state (FR02), observed so the rows' notes follow
    /// each refresh and download. Rows read only what it recorded.
    @ObservedObject private var cloudStates = BookCloudStates.shared
    /// The books this Mac keeps downloaded (Keep on This Mac), observed so
    /// the rows' commands follow every change.
    @ObservedObject private var keptBooks = KeptBooks.shared
    /// This window's token for the cloud refresher, which keeps refreshing
    /// while any Library window is visible (FR02).
    @State private var cloudRefreshToken = UUID()
    /// A Remove Download refusal to show in this window (FR02).
    @State private var cloudRefusal: LibraryCloudRefusal?
    /// The Export dialog showing on this window, or nil (FR05).
    @State private var exportModel: BookExportModel?
    /// This window's transcription dialogs (FR05).
    @StateObject private var transcription = TranscriptionPresenter()
    /// Which audiobooks are transcribed or being transcribed (FR05),
    /// observed so the rows' notes follow.
    @ObservedObject private var transcribedBooks = TranscribedBooks.shared
    /// Whether this Library window has closed. SwiftUI keeps a closed window
    /// and its views for the rest of the session, and every change to the
    /// library would still rebuild this list nobody can see, so a closed
    /// window shows a placeholder instead (PERF27). SwiftUI can show a closed
    /// Library window again, for a book opened from Finder: the list comes
    /// back as soon as the window is on screen or key.
    @State private var isWindowClosed = false

    var body: some View {
        Group {
            if isWindowClosed {
                ClosedLibraryWindowPlaceholder()
            } else {
                libraryContent
            }
        }
        // Outside the list, so the window is followed while it is closed too.
        .background(WindowAccessor(
            onWindowFound: { window in
                hostWindow = window
            },
            onWindowBecameKey: reopenAfterClosing,
            onWindowWillClose: {
                isWindowClosed = true
            },
            onWindowBecameVisible: reopenAfterClosing
        ))
    }

    /// Shows the list again in a window SwiftUI brought back after it closed.
    private func reopenAfterClosing() {
        if isWindowClosed {
            isWindowClosed = false
        }
    }

    /// The window's library while the window is open: the list of the
    /// location's folders and books, with its bars, toolbar, and sheets.
    @ViewBuilder
    private var libraryContent: some View {
        let _ = ViewBodyCounter.record("LibraryView.list")
        // What the list shows, read once for the whole body and passed down
        // (PERF28): the bars, the rows, the header's count, the rotors, the
        // focus target, and the toolbar all use these rather than asking
        // the model again.
        let allBooks = displayedBooks
        let books = filteredBooks
        let folders = libraryViewModel.subfoldersOf(currentFolderPath)
        let subfolders = category == .folders ? folders : []
        let lastBook = libraryViewModel.lastOpenedBook
        let focusTarget = Self.preferredFocusTarget(
            hasContinueListening: lastBook != nil,
            hasDisplayedBooks: !allBooks.isEmpty
        )

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
            continueListeningButton(for: lastBook)

            // Edit mode toolbar: shown when edit mode is active
            if isEditMode {
                EditModeBar(
                    selectedCount: effectiveSelection.count,
                    totalCount: books.count,
                    removalPreferences: removalPreferences,
                    onSelectAll: {
                        editSelection = Set(books.map(\.id))
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

            // Total time remaining bar, with how many of the books shown are
            // in the cloud (FR02) and kept on this Mac (Keep on This Mac)
            TimeRemainingBar(
                books: allBooks,
                wpm: settingsViewModel.wordsPerMinute,
                booksInCloud: cloudStates.countInTheCloud(allBooks),
                booksKept: cloudStates.countKept(allBooks, in: keptBooks),
                focusIdentifier: focusTarget == .timeSummary ? voiceOverFocusID : nil,
                shouldTriggerFocus: focusTarget == .timeSummary,
                livePositions: libraryViewModel.livePositions
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
                                        bookCount: libraryViewModel.bookCount(inFolderTree: folder.fullPath)
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
                    bookRows(books, orderedBy: allBooks)
                } header: {
                    Text("Books (\(books.count))")
                        .accessibilityAddTraits(.isHeader)
                }
            }
            .searchable(text: $searchText, prompt: "Search books")
            .accessibilityRotor("Books") {
                ForEach(books) { book in
                    AccessibilityRotorEntry(book.title, id: book.id)
                }
            }
            .accessibilityRotor("Folders") {
                ForEach(folders) { folder in
                    AccessibilityRotorEntry(
                        "\(folder.name), \(libraryViewModel.bookCount(inFolderTree: folder.fullPath)) books",
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
            .onChange(of: currentFolderPath) { _, _ in
                // Clear selections when navigating to a different folder
                editSelection = []
                selectedBookIDs = []
            }
            .onChange(of: category) { _, _ in
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

                importBookButton(focusTarget: focusTarget)

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
                        let hasSubfolders = !folders.isEmpty
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
                        closingOnSuccess(await libraryViewModel.moveBooksReturningOutcome(booksToMove, toFolder: path)) {
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
        .trackingRemovalPreferences($removalPreferences)
        // Keeps the books' cloud states refreshed while the window is
        // visible, shows Remove Download's refusals (FR02), and takes the
        // Library menu's Keep on This Mac and Stop Keeping on This Mac.
        .modifier(LibraryCloudWindowSupport(
            token: cloudRefreshToken,
            library: libraryViewModel,
            refusal: $cloudRefusal,
            performKeepMenuCommand: performKeepMenuCommand
        ))
        // File > Export… for the selection, and the Export dialog (FR05).
        .modifier(LibraryExportSupport(
            exportModel: $exportModel,
            library: libraryViewModel,
            takesCommand: takesCommand,
            selectedBooks: { selectedBooks },
            hostWindow: hostWindow
        ))
        // The Transcribe Audio sheet the rows' commands open, and the rows'
        // transcription notes kept current (FR05).
        .modifier(LibraryTranscriptionSupport(presenter: transcription, library: libraryViewModel))
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
            bookInfoSheet(for: book)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showBookInfo)) { notification in
            // Only open in the focused library window
            guard takesCommand(notification) else { return }
            // Cmd+I: show info for the first selected book
            if let id = selectedBookIDs.first,
               let book = filteredBooks.first(where: { $0.id == id }) {
                showBookInfo(for: book)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSelectedBook)) { notification in
            // Only respond in the focused library window
            guard takesCommand(notification) else { return }
            if let id = selectedBookIDs.first,
               let book = filteredBooks.first(where: { $0.id == id }) {
                onOpenBook(book)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .removeFromLibrary)) { notification in
            // Cmd+Delete: remove selected books from library
            guard takesCommand(notification) else { return }
            let books = selectedBooks
            if !books.isEmpty {
                libraryViewModel.removeBooks(books)
                clearAllSelections()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newFolder)) { notification in
            // Cmd+Shift+N: create new folder
            guard takesCommand(notification) else { return }
            newFolderParentPath = currentFolderPath
            showNewFolderSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .moveToFolder)) { notification in
            // Cmd+Shift+M: move selected books to folder
            guard takesCommand(notification) else { return }
            let books = selectedBooks
            if !books.isEmpty {
                booksToMove = books
                showMoveSheet = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectAll)) { notification in
            // Cmd+A: select all visible books (in edit mode, use edit selection)
            guard takesCommand(notification) else { return }
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
            guard takesCommand(notification) else { return }
            if isEditMode {
                clearAllSelections()
            } else {
                isEditMode = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .moveBookUp)) { notification in
            guard takesCommand(notification) else { return }
            moveSelectedBookInManualOrder(direction: -1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .moveBookDown)) { notification in
            guard takesCommand(notification) else { return }
            moveSelectedBookInManualOrder(direction: 1)
        }
        .sheet(isPresented: $showTextInput) {
            TextInputView(
                onAdd: { title, author, text in
                    libraryViewModel.createBookFromText(
                        title: title,
                        author: author,
                        text: text,
                        toFolder: currentFolderPath,
                        from: ImportOrigin(window: hostWindow)
                    )
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
                        await editFolder(folder, closing: { showRenameFolderSheet = false }) {
                            await libraryViewModel.renameFolderReturningOutcome(folder, to: renameFolderText)
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
                        await editFolder(folder, closing: { showMoveFolderSheet = false }) {
                            await libraryViewModel.moveFolderReturningOutcome(folder, toParent: newParent)
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
                        closingOnSuccess(await libraryViewModel.removeFolderMovingContentsReturningOutcome(
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

    /// Continue Listening button for `lastBook`, the book last opened, when
    /// there is one — extracted to reduce body complexity for the type checker
    @ViewBuilder
    private func continueListeningButton(for lastBook: Book?) -> some View {
        if let lastBook {
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
            bookCount: folder.map { libraryViewModel.bookCount(inFolderTree: $0.fullPath) } ?? 0
        )
    }

    /// Toggle a book's membership in the edit selection set
    private func toggleEditSelection(_ id: UUID) {
        editSelection = LibrarySelectionPolicy.toggled(editSelection, id: id)
    }

    // MARK: - Book Rows

    /// The rows of `books`, the books the list shows. Each is an equatable
    /// row, which SwiftUI skips when nothing it shows has changed: a change
    /// to one book redraws one row, and a row's context menu is built only
    /// when its row draws (PERF28). Dragging rearranges a folder's manual
    /// order only where the rows are that whole order; elsewhere it is off.
    /// - Parameters:
    ///   - books: The books the list shows, as the search narrows them.
    ///   - allBooks: Every book at the location, in the order shown: while
    ///     the list shows a folder's manual order, that whole order, which
    ///     each row's Move Up and Move Down follow.
    private func bookRows(_ books: [Book], orderedBy allBooks: [Book]) -> some View {
        // The selection in list order, and its cloud commands, made once
        // for all the rows that belong to it.
        let selectedIDs = effectiveSelection
        let selection = books.filter { selectedIDs.contains($0.id) }
        let selectionCloudCommands = LibraryCloudCommand.commands(
            for: selection,
            isSelection: selection.count > 1,
            states: cloudStates,
            kept: keptBooks.bookIDs
        )
        // Every book's moves in the folder's manual order, read from the
        // order shown rather than by sorting the folder again for each row.
        let manualMoves = reorderableFolder == nil ? [:] : LibraryManualMoves.moves(in: allBooks)
        let actions = rowActions
        return ForEach(books) { book in
            bookRow(
                book,
                selectedIDs: selectedIDs,
                selection: selection,
                selectionCloudCommands: selectionCloudCommands,
                manualMoves: manualMoves,
                actions: actions
            )
        }
        .onMove(perform: dragReorderAction)
    }

    /// One book's row, with its context menu and its VoiceOver actions,
    /// which share the books they act on and the cloud commands (FR02).
    /// - Parameters:
    ///   - book: The row's book.
    ///   - selectedIDs: Every selected book, by either selection.
    ///   - selection: The selected books the list shows, in its order.
    ///   - selectionCloudCommands: The cloud commands of `selection`.
    ///   - manualMoves: Each book's moves in the manual order the list
    ///     shows, by ID; empty when it shows none.
    ///   - actions: What the row's commands do.
    private func bookRow(
        _ book: Book,
        selectedIDs: Set<UUID>,
        selection: [Book],
        selectionCloudCommands: [LibraryCloudCommand],
        manualMoves: [UUID: LibraryManualMoves],
        actions: LibraryBookRowActions
    ) -> some View {
        let targets = commandTargets(for: book, selectedIDs: selectedIDs, selection: selection)
        let isSelectionRow = targets.count > 1
        return LibraryBookListRow(
            book: book,
            isOpenInWindow: libraryViewModel.openBookIDs.contains(book.id),
            wpm: settingsViewModel.wordsPerMinute,
            isEditMode: isEditMode,
            isEditSelected: editSelection.contains(book.id),
            cloudState: cloudStates.listedState(of: book.id),
            isKeptOnThisMac: cloudStates.listsAsKept(book.id, in: keptBooks),
            targets: targets,
            cloudCommands: isSelectionRow
                ? selectionCloudCommands
                : LibraryCloudCommand.commands(
                    for: targets,
                    isSelection: false,
                    states: cloudStates,
                    kept: keptBooks.bookIDs
                ),
            // Move Up and Move Down move the row's own book alone (TODO A06).
            manualMoves: isSelectionRow ? nil : manualMoves[book.id],
            removalPreferences: removalPreferences,
            livePosition: libraryViewModel.livePositions.entry(for: book.id),
            transcriptionCommands: LibraryTranscriptionCommand.commands(for: targets),
            transcriptionNote: transcribedBooks.note(for: book.id),
            actions: actions
        )
        .equatable()
        .tag(book.id)
    }

    // MARK: - Row Commands

    /// The books a row's commands act on: the selection, in list order,
    /// when the row belongs to a selection of several books (in edit mode
    /// or the list's own), and otherwise the row's own book.
    /// - Parameters:
    ///   - book: The row's book.
    ///   - selectedIDs: Every selected book, by either selection.
    ///   - selection: The selected books the list shows, in its order.
    private func commandTargets(for book: Book, selectedIDs: Set<UUID>, selection: [Book]) -> [Book] {
        let ids = LibrarySelectionPolicy.contextTargets(clickedID: book.id, effectiveSelection: selectedIDs)
        return ids.count > 1 ? selection : [book]
    }

    /// What the rows' commands do, on this list's state as it is when they
    /// run: open, Book Info, Select, Move to Folder, Move Up and Move Down,
    /// the cloud commands, removal, Export, Edit Text, and the transcription
    /// commands (FR05).
    private var rowActions: LibraryBookRowActions {
        LibraryBookRowActions(
            open: onOpenBook,
            showInfo: { book in
                showBookInfo(for: book)
            },
            select: { book in
                editSelection.insert(book.id)
                isEditMode = true
            },
            toggleSelection: { book in
                toggleEditSelection(book.id)
            },
            moveToFolder: { books in
                booksToMove = books
                showMoveSheet = true
            },
            moveInManualOrder: { book, direction in
                if let folder = reorderableFolder {
                    moveBook(book.id, direction: direction, inManualOrderOf: folder)
                }
            },
            performCloudCommand: performCloudCommand,
            remove: { books in
                libraryViewModel.removeBooks(books)
                clearAllSelections()
            },
            export: { books in
                if exportModel == nil {
                    exportModel = BookExportModel(books: books, library: libraryViewModel)
                }
            },
            editText: { book, choosingApp in
                let window = hostWindow
                Task {
                    await BookTextEditor.shared.edit(book, choosingApp: choosingApp, in: libraryViewModel, from: window)
                }
            },
            performTranscriptionCommand: { command in
                transcription.perform(command, library: libraryViewModel, window: hostWindow)
            }
        )
    }

    /// Runs a row's cloud command, from its context menu or its VoiceOver
    /// actions, announcing from this window and showing here a refusal it
    /// reports (FR02).
    private func performCloudCommand(_ command: LibraryCloudCommand) {
        Task {
            let refusal = await LibraryCloudCommands.shared.perform(command, in: libraryViewModel, from: hostWindow)
            if let refusal {
                cloudRefusal = refusal
            }
        }
    }

    /// Runs Library > Keep on This Mac (`keeping`) or Stop Keeping on This
    /// Mac, which `notification` carried, for the books selected here, when
    /// this window takes the command; VoiceOver hears why when nothing
    /// changes.
    private func performKeepMenuCommand(_ keeping: Bool, _ notification: Notification) {
        guard takesCommand(notification) else { return }
        LibraryCloudCommands.shared.setKeptFromMenu(keeping, for: selectedBooks, in: libraryViewModel, from: hostWindow)
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
    /// sheets, and finishes the sheet once its books' packages have moved
    /// (PERF14). After a success the sheet closes, and a window showing the
    /// folder, or a folder inside it, follows it to its new path; after a
    /// failure the folder shown stays as it was.
    private func editFolder(
        _ folder: BookFolder,
        closing close: () -> Void,
        _ edit: () async -> OperationOutcome
    ) async -> OperationOutcome {
        // Read the folder's path from the library on both sides of the edit:
        // the sheet's copy is from when it opened, and another window may
        // have moved the folder since.
        let pathBefore = libraryViewModel.library.folders.first { $0.id == folder.id }?.fullPath ?? folder.fullPath
        let outcome = await edit()
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

    /// Whether this Library window takes the menu command or keyboard
    /// shortcut `notification` posts, as `WindowCommandRouting` decides: a
    /// shortcut names the window it was pressed in (`sourceWindow` in its
    /// user info), which alone takes it; a menu command names none, and the
    /// key window takes it; a window whose NSWindow isn't known yet takes
    /// either.
    private func takesCommand(_ notification: Notification) -> Bool {
        let sourceWindow = notification.userInfo?["sourceWindow"] as? NSWindow
        return WindowCommandRouting.shouldAccept(
            hasSourceWindow: sourceWindow != nil,
            sourceMatchesHost: sourceWindow === hostWindow,
            hasHostWindow: hostWindow != nil,
            hostWindowIsKey: hostWindow?.isKeyWindow ?? false
        )
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

    /// The folder whose books can be rearranged here now, or nil: only while
    /// the list shows one folder's manual order (see
    /// `LibraryLocation.reorderableFolder(sortedBy:)`).
    private var reorderableFolder: String? {
        location.reorderableFolder(sortedBy: sort)
    }

    /// What dragging a row does: rearranges the folder's manual order while
    /// the rows are that whole order, with no search narrowing them, and
    /// nothing anywhere else, where a row's position in the list is not its
    /// position in one folder's order (TODO A06). Nil turns dragging off.
    private var dragReorderAction: ((IndexSet, Int) -> Void)? {
        guard let folder = reorderableFolder, searchText.isEmpty else { return nil }
        return { source, destination in
            libraryViewModel.reorderBooksInFolder(folderPath: folder, from: source, to: destination)
        }
    }

    /// Makes and saves a change the user chose in the Sort menu, the one
    /// way a location's sort changes, then says the sort now shown, since
    /// the menu closes without saying it (TODO A06).
    private func userChangedSort(_ change: LibrarySortChange) {
        let shown = libraryViewModel.userChangedSort(change, at: location)
        announceToVoiceOver(shown.changeAnnouncement)
    }

    /// The books shown here before a search narrows them, in the sort the
    /// location shows: derived once by the model and kept until a change
    /// the list depends on (TODO PERF10).
    private var displayedBooks: [Book] {
        libraryViewModel.displayedBooks(at: location)
    }

    /// Which of the views this list owns takes the library's one initial
    /// VoiceOver focus: nil when Continue Listening, which owns its own
    /// focus identifier and trigger, takes it.
    private static func preferredFocusTarget(
        hasContinueListening: Bool,
        hasDisplayedBooks: Bool
    ) -> LibraryFocusTarget? {
        let target = LibraryFocusTarget.preferred(
            hasContinueListening: hasContinueListening,
            hasDisplayedBooks: hasDisplayedBooks
        )
        return target == .continueListening ? nil : target
    }

    /// The Import Book button: the initial VoiceOver target when
    /// `focusTarget` says so.
    private func importBookButton(focusTarget: LibraryFocusTarget?) -> some View {
        Button {
            showFileImporter = true
        } label: {
            Label("Import Book", systemImage: "plus")
        }
        .accessibilityLabel("Import a book file")
        .accessibilityHint("Opens a file picker to import EPUB, text, markdown, or HTML files")
        .modifier(LibraryFocusTargetModifier(
            isEnabled: focusTarget == .importButton
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
    /// Only works when a single book is selected and the list shows one
    /// folder's manual order (TODO A06). Announces the result to VoiceOver.
    private func moveSelectedBookInManualOrder(direction: Int) {
        guard let folder = reorderableFolder else { return }
        let ids = effectiveSelection
        guard ids.count == 1, let bookID = ids.first else { return }
        moveBook(bookID, direction: direction, inManualOrderOf: folder)
    }

    /// Moves a book one place up (-1) or down (+1) in `folder`'s manual
    /// order, which saves at once, and tells VoiceOver where it went. Move
    /// Up and Move Down in the context menu and on the keyboard share it.
    private func moveBook(_ bookID: UUID, direction: Int, inManualOrderOf folder: String) {
        if let result = libraryViewModel.moveBookInManualOrder(
            bookID: bookID, direction: direction, folderPath: folder
        ) {
            let position = result.direction < 0 ? "above" : "below"
            announceToVoiceOver("Moved \(result.movedTitle) \(position) \(result.adjacentTitle)")
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

    /// The books shown here as the search narrows them (title or author
    /// contains it, ignoring case), kept by the model like `displayedBooks`.
    private var filteredBooks: [Book] {
        libraryViewModel.displayedBooks(at: location, matching: searchText)
    }

    private func navigateUp() {
        let parts = currentFolderPath.components(separatedBy: "/")
        if parts.count > 1 {
            currentFolderPath = parts.dropLast().joined(separator: "/")
        } else {
            currentFolderPath = ""
        }
    }

    /// Shows Book Info for `book` once its metadata is read. EPUB and audio
    /// books get the rich MetadataEditorView; other formats, and an EPUB
    /// that cannot be read, get the simple LibraryBookInfoSheet. The reading
    /// happens off the main thread and never downloads a book whose file is
    /// only in the cloud, whose editor shows what the library keeps (FR02).
    /// A later request replaces one still reading.
    private func showBookInfo(for book: Book) {
        let request = UUID()
        bookInfoRequest = request
        Task {
            let info = await LibraryBookInfoReader.system.info(for: book)
            guard bookInfoRequest == request else { return }
            bookInfoRequest = nil
            bookInfo = info
            bookInfoTarget = book
        }
    }

    /// The Book Info sheet for `book`, as `showBookInfo(for:)` read it.
    @ViewBuilder
    private func bookInfoSheet(for book: Book) -> some View {
        switch bookInfo {
        case .epub(let metadata, let isCloudOnly):
            VStack(spacing: 0) {
                if isCloudOnly {
                    bookInfoCloudOnlyNote
                }
                // EPUB books get the rich metadata editor with publisher, date, etc.
                MetadataEditorView(
                    metadata: metadata,
                    isEPUB: true,
                    onSave: { updated, writeToFile in
                        // Writing an EPUB only in the cloud would download it
                        // first while the interface waited, so the editor
                        // stays open and says why instead.
                        if let refusal = LibraryBookInfo.writeRefusal(
                            isCloudOnly: isCloudOnly,
                            writesToFile: writeToFile
                        ) {
                            VoiceOverAnnouncer.announce(refusal)
                            return .failure(refusal)
                        }
                        // The library's copy of the EPUB is written first when
                        // asked, and nothing changes if that fails: the editor
                        // then stays open and shows why (TODO A09). VoiceOver
                        // hears the outcome from the editor, which has focus.
                        let save = libraryViewModel.saveEPUBMetadata(updated, for: book, writingToFile: writeToFile)
                        VoiceOverAnnouncer.announce(save.message)
                        return save.outcome
                    }
                )
            }
        case .audio(let metadata, let isCloudOnly):
            VStack(spacing: 0) {
                if isCloudOnly {
                    bookInfoCloudOnlyNote
                }
                // Audio books get the rich metadata editor with album, genre, etc.
                MetadataEditorView(
                    audioMetadata: metadata,
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
            }
        case .simple:
            // Plain text, markdown, HTML — simple title/author editor
            LibraryBookInfoSheet(book: book, libraryViewModel: libraryViewModel)
        }
    }

    /// Says, above the editor, that some details appear once the book is
    /// downloaded, for a book whose file is only in the cloud (FR02).
    private var bookInfoCloudOnlyNote: some View {
        Label(LibraryBookInfo.cloudOnlyNote, systemImage: "cloud")
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top])
    }
}

// MARK: - Closed Window (PERF27)

/// What a Library window shows once it has closed, in place of its list
/// (PERF27). Nobody sees it unless SwiftUI shows the window again, and then
/// only for the moment until the list returns; VoiceOver reads it as the
/// window's name.
private struct ClosedLibraryWindowPlaceholder: View {
    var body: some View {
        Text("Library")
            .font(.title2)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Cloud Library Window Support (FR02)

/// A Library window's part in the cloud library (FR02): while the window is
/// visible, the shared refresher keeps the books' cloud states current; the
/// window shows the refusals of the Remove Download commands run in it; and
/// it hears the Library menu's Keep on This Mac and Stop Keeping on This Mac.
private struct LibraryCloudWindowSupport: ViewModifier {
    /// The window's token for the refresher.
    let token: UUID
    /// The library the window shows.
    let library: LibraryViewModel
    /// The refusal to show, cleared when its alert is dismissed.
    @Binding var refusal: LibraryCloudRefusal?
    /// Runs Keep on This Mac (true) or Stop Keeping on This Mac (false) from
    /// the Library menu, with the notification that carried it, which says
    /// whether this window takes it.
    let performKeepMenuCommand: (_ keeping: Bool, _ notification: Notification) -> Void

    func body(content: Content) -> some View {
        content
            .onAppear {
                LibraryCloudRefresher.shared.libraryWindowAppeared(token, showing: library)
            }
            .onDisappear {
                LibraryCloudRefresher.shared.libraryWindowDisappeared(token)
            }
            .onReceive(NotificationCenter.default.publisher(for: .keepOnThisMac)) { notification in
                performKeepMenuCommand(true, notification)
            }
            .onReceive(NotificationCenter.default.publisher(for: .stopKeepingOnThisMac)) { notification in
                performKeepMenuCommand(false, notification)
            }
            // Why Remove Download kept a book's download, which VoiceOver
            // has also heard announced.
            .alert(refusal?.title ?? "", isPresented: isShowingRefusal, presenting: refusal) { _ in
                Button("OK", role: .cancel) {}
            } message: { refusal in
                Text(refusal.message)
            }
    }

    /// Whether the alert shows; dismissing it forgets the refusal.
    private var isShowingRefusal: Binding<Bool> {
        Binding(
            get: { refusal != nil },
            set: { isPresented in
                if !isPresented { refusal = nil }
            }
        )
    }
}

// Make Book conform to Identifiable for .sheet(item:) usage (already conforms via existing `id` property)

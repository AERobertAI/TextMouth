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
        sourceWindow: PlatformWindow?,
        hostWindow: PlatformWindow?,
        keyWindow: PlatformWindow?
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
    static func rootWindow(for window: PlatformWindow) -> PlatformWindow {
        #if os(macOS)
        var currentWindow = window
        var visited: Set<ObjectIdentifier> = []

        while visited.insert(ObjectIdentifier(currentWindow)).inserted,
              let parent = currentWindow.sheetParent {
            currentWindow = parent
        }

        return currentWindow
        #else
        // A UIWindow has no sheets of its own (a presented sheet is a view
        // controller inside it), so it is already the document window.
        return window
        #endif
    }
}

enum LibraryFocusTarget: Equatable {
    case continueListening
    case timeSummary
    /// Where VoiceOver's focus starts in a window with no books: the Add to
    /// Library button, which took over the Import button's place (FR20). The
    /// case keeps its name.
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

    /// The books among `books`, those a Library window lists, that its two
    /// selections, `native` (the list's own) and `edit` (edit mode's
    /// checks), select together, in the list's order: the books Move,
    /// Remove, and the reading list's commands act on, which the edit bar
    /// and the Edit button's hint both count (REV13; the hint counted edit
    /// mode's checks alone). A folder's or a feed's row selected in the
    /// list is no book, and a book no longer listed is not counted.
    static func selected(in books: [Book], native: Set<UUID>, edit: Set<UUID>) -> [Book] {
        let ids = effective(native: native, edit: edit)
        return books.filter { ids.contains($0.id) }
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

    /// The folder path a window showing `currentPath` shows once the
    /// library's folders are `library`'s, as after another window deleted or
    /// moved the folder it shows (Delete Feed…, Delete Folder…, a rename or
    /// a move there; the feed follow-ups after FR14): the same path while a
    /// folder is there; the new path of the folder it showed, `folderID`,
    /// when that folder is there under another; and otherwise the nearest
    /// folder above it still in the library, or the library's top level, so
    /// no window is left showing a path that names no folder.
    static func folderPath(showing currentPath: String, folderID: UUID?, in library: Library) -> String {
        guard !currentPath.isEmpty, library.existingFolder(equivalentTo: currentPath) == nil else { return currentPath }
        if let folderID, let moved = library.folders.first(where: { $0.id == folderID }) {
            return moved.fullPath
        }
        var parts = currentPath.components(separatedBy: "/").dropLast()
        while !parts.isEmpty {
            if let parent = library.existingFolder(equivalentTo: parts.joined(separator: "/")) {
                return parent.fullPath
            }
            parts = parts.dropLast()
        }
        return ""
    }
}

/// Keeps a Library window on a folder that is in the library
/// (`FolderSheetNavigation.folderPath(showing:folderID:in:)`): it notes the
/// folder the window shows each time it shows another, and when the
/// library's folders change, as another window deletes or moves that
/// folder, it follows the folder to its new path, or goes to the nearest
/// folder above it still there.
struct ShownFolderFollowing: ViewModifier {
    /// The folder path the window shows.
    @Binding var currentFolderPath: String
    /// The library as the window shows it now.
    let library: Library
    /// Whether the library lists every folder it holds: not while its index
    /// is recovered, when the list is provisional and a folder missing from
    /// it may still be there, so no window moves for it.
    let isComplete: Bool
    /// The folder the window last showed, by ID, so a move is followed.
    @State private var shownFolderID: UUID?

    func body(content: Content) -> some View {
        content
            .onChange(of: currentFolderPath, initial: true) { _, path in
                shownFolderID = library.existingFolder(equivalentTo: path)?.id
            }
            .onChange(of: library.folders) { _, _ in
                guard isComplete else { return }
                let path = FolderSheetNavigation.folderPath(showing: currentFolderPath, folderID: shownFolderID, in: library)
                // Compared by exact spelling, as the folder sheets' edits are.
                if !BookFolder.spellingsMatch(path, currentFolderPath) {
                    currentFolderPath = path
                }
            }
    }
}

struct LibraryView: View {
    @EnvironmentObject var libraryViewModel: LibraryViewModel
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Binding var currentFolderPath: String
    /// The view this window shows (October 30, 2026), by its identity: one
    /// of the Library's views (`LibraryViewDefinitionStore`).
    @Binding var shownViewID: LibraryViewID
    @Binding var showFileImporter: Bool
    /// Presents the New from Text sheet. The Library window owns it, so
    /// File > New from Text... can present the sheet through the router
    /// whichever window is key (TODO A05).
    @Binding var showTextInput: Bool
    let onOpenBook: (Book) -> Void
    /// What VoiceOver calls the View pop-up, whose items are the names of
    /// the views it offers. Until October 30, 2026 it was a segmented picker
    /// of the five categories, called "Library category"; the constant keeps
    /// the name the tests have always used.
    static let categoryPickerLabel = "Library view"
    /// Which library folders hold feeds, and the feed engine they follow
    /// (FR03): the app's, unless a test shows its own. Observed, as it
    /// publishes only when a feed's folder changes; the views showing a
    /// feed's items and counts observe the engine themselves.
    @ObservedObject var feedFolders: LibraryFeedFolders = .shared
    /// The Library's views, the app's unless a test gives its own, observed
    /// so the View pop-up and the view shown follow a change made in
    /// Settings or config.json (October 30, 2026).
    @ObservedObject var views: LibraryViewDefinitionStore = .shared

    /// What this window shows for the feeds: the Add Feed sheet and the
    /// notices after its commands (FR03). Kept, not observed: its sheets'
    /// host observes it, so a sheet opening never redraws the list.
    @State private var feedPresenter = LibraryFeedsPresenter()
    /// The Folder Settings sheet shown for a plain folder, from the toolbar's
    /// Folder Settings button or the Folder or Feed Settings command (FR19).
    @State private var folderSettings: FolderSettingsModel?
    /// What speaks the selected row's information for Speak Info and Speak
    /// Full Info, Shift-Command-I and Shift-Command-I twice (I and I twice
    /// until October 17, 2026), and for Book Info on a folder, which has no
    /// sheet (October 7, 2026; FR12). Kept, not observed: it draws nothing.
    @State private var infoSpeaker = LibraryInfoSpeaker()
    @State private var showNewFolderSheet = false
    @State private var newFolderName = ""
    @State private var newFolderParentPath = ""
    /// What the Move to Folder sheet moves while it shows: a request the
    /// sheet is handed, so it never opens empty (October 17, 2026).
    @State private var moveRequest: MoveToFolderRequest?
    /// What a move made from the Move sheet left to say, the feed items it
    /// left where they are, kept while the sheet closes (REV11 F6).
    @State private var afterMoveSheet = AnnouncementAfterSheet()
    /// The folder the Move Folder... sheet moves while it shows; nil closes it.
    @State private var folderToMove: BookFolder?
    /// The folder the Rename Folder... sheet renames while it shows; nil
    /// closes it.
    @State private var folderToRename: BookFolder?
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
    @State private var hostWindow: PlatformWindow?
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
    /// What this window owns of its Add to Library button (FR20): the
    /// sheet's model, and what its choices need of the window.
    @StateObject private var addToLibrary = AddToLibraryHost()
    /// Which audiobooks are transcribed or being transcribed (FR05),
    /// observed so the rows' notes follow.
    @ObservedObject private var transcribedBooks = TranscribedBooks.shared
    /// Which audiobooks play a folder of tracks, whose manifest can be
    /// edited (FR17).
    @ObservedObject private var trackFolderBooks = TrackFolderBooks.shared
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
        // How titles are sorted, shown, and found by typing (the Leading
        // articles setting), read once for the rows, the rotor, and the
        // Feeds section.
        let articles = libraryViewModel.leadingArticles
        // Which views shown when applicable list something, asked once for
        // the body, and shared by the View pop-up and Go to View (review of
        // October 31, 2026, finding 4).
        let applicable = libraryViewModel.applicableViews(in: views.list, center: feedFolders.center)
        // The views the View pop-up offers.
        let offered = libraryViewModel.offeredViews(
            in: views.list,
            current: shownViewID,
            center: feedFolders.center,
            applicable: applicable
        )
        // The names of the views Go to View counts, those offered to a
        // window showing none, which the Library menu's Go to View submenu
        // lists (design section 6).
        let goToViewNames = libraryViewModel.offeredViews(
            in: views.list,
            current: nil,
            center: feedFolders.center,
            applicable: applicable
        ).map(\.name)
        let folders = libraryViewModel.subfoldersOf(currentFolderPath)
        // The Folders section's rows and the Folders rotor's entries: none
        // outside Folders, and no row for a feed's folder where the Feeds
        // section lists its feed, whose row stands for it and takes its
        // rotor entry (FR03).
        let folderRows = shownFolderRows(of: folders)
        let subfolders = folderRows.shown
        let lastBook = libraryViewModel.lastOpenedBook
        // The feed whose folder this is, if it is one (FR03): its items are
        // listed, and its summary bar counts them, even before any download.
        let feedID = shownFeedID
        let focusTarget = Self.preferredFocusTarget(
            hasContinueListening: lastBook != nil,
            hasDisplayedBooks: !allBooks.isEmpty || feedID != nil
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

            // The View pop-up: the views offered, each by its name.
            viewPicker(offering: offered)

            // The Reading List's options, there alone (FR09).
            readingListOptions

            // Breadcrumb navigation (only in folders mode)
            if showsFolders && !currentFolderPath.isEmpty {
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
                // The listed books selected, which the Edit button's hint
                // counts too (REV13), and which Move and Remove act on.
                let selected = LibrarySelectionPolicy.selected(in: books, native: selectedBookIDs, edit: editSelection)
                EditModeBar(
                    selectedCount: selected.count,
                    totalCount: books.count,
                    removalPreferences: removalPreferences,
                    // Feed items alone: Remove is their Delete Download (REV11 F2).
                    selectedAreFeedItems: selected.allSatisfy(\.isFeedItem),
                    onSelectAll: {
                        editSelection = Set(books.map(\.id))
                    },
                    onDeselectAll: {
                        editSelection = []
                        selectedBookIDs = []
                    },
                    onMove: {
                        moveToFolder(selectedBooks)
                    },
                    onRemove: {
                        let books = selectedBooks
                        if !books.isEmpty {
                            libraryViewModel.removeBooks(books)
                            clearAllSelections()
                        }
                    },
                    // Add to and Remove from Reading List beside Move (FR09).
                    readingListCommands: editBarReadingListCommands,
                    onReadingListCommand: performReadingListCommand
                )
            }

            // Total time remaining bar, with how many of the books shown are
            // in the cloud (FR02) and kept on this Mac (Keep on This Mac); in
            // a feed's folder it counts the feed's items first and ends with
            // the feed's last check (FR03). It is the same view everywhere,
            // so moving between folders never makes it anew.
            // Elsewhere it names the feeds the Feeds section lists there beside
            // the books, "743 books, 2 feeds" (FR11), recounted as the engine
            // changes, which the bar's wrapper observes.
            FeedFolderSummaryBar(center: feedFolders.center, feedID: feedID) { summary in
                TimeRemainingBar(
                    books: allBooks,
                    wpm: settingsViewModel.wordsPerMinute,
                    booksInCloud: cloudStates.countInTheCloud(allBooks),
                    booksKept: cloudStates.countKept(allBooks, in: keptBooks),
                    focusIdentifier: focusTarget == .timeSummary ? voiceOverFocusID : nil,
                    shouldTriggerFocus: focusTarget == .timeSummary,
                    livePositions: libraryViewModel.livePositions,
                    feedSummary: summary,
                    feedCount: summary == nil ? LibraryFeedsSectionRows.feeds(at: location, center: feedFolders.center).count : 0
                )
            }

            // Main list with native selection
            List(selection: $selectedBookIDs) {
                // Folders section (only in Folders)
                if showsFolders && !subfolders.isEmpty {
                    foldersSection(subfolders)
                }

                // Feeds section, only where there are feeds (FR03); each
                // row also offers its feed's folder's commands, as the
                // folder's row, left out where the feed's row stands for
                // it, did.
                LibraryFeedsSection(
                    center: feedFolders.center,
                    location: location,
                    articles: articles,
                    open: openFeed,
                    perform: performFeedAction
                ) { row in
                    if let folder = folder(ofFeedRow: row) {
                        Divider()
                        folderMenu(folder)
                    }
                }

                // Books section; in a feed's folder, the feed's items with
                // the downloaded ones as their books (FR03). A view listing
                // no books, episodes, or articles, such as Feeds, has none,
                // and says so when it lists nothing at all (October 30, 2026).
                if listsItems {
                    booksSection(books, orderedBy: allBooks, feedID: feedID)
                } else if showsEmptySentence(allBooks: allBooks) {
                    Section {
                        emptyViewRow
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search books")
            .accessibilityRotor("Books") {
                // Each title as its row shows it ("Hobbit, The" while sorting
                // passes over articles), in the list's order.
                ForEach(books) { book in
                    AccessibilityRotorEntry(libraryViewModel.rowTitle(of: book, articles: articles) ?? book.title, id: book.id)
                }
            }
            .accessibilityRotor("Folders") {
                // Each folder here, as its row says it, or, for a feed's
                // folder the Feeds section's row stands for, moving to that
                // row (FR03).
                ForEach(folderRows.rotorEntries) { entry in
                    AccessibilityRotorEntry(entry.label, id: entry.id)
                }
            }
            #if os(macOS)
            .onDeleteCommand {
                // Delete key removes all selected books (either selection mechanism)
                let books = selectedBooks
                if !books.isEmpty {
                    libraryViewModel.removeBooks(books)
                    clearAllSelections()
                }
            }
            #endif
            .onChange(of: currentFolderPath) { _, _ in
                // Clear selections when navigating to a different folder
                editSelection = []
                selectedBookIDs = []
            }
            .onChange(of: shownViewID) { _, _ in
                // Clear selections when switching views
                editSelection = []
                selectedBookIDs = []
            }
            // Letter navigation that passes over leading articles, in the
            // Leading articles setting's second and third choices; in the
            // first, the list's own type select, as always.
            .modifier(LibraryTitleTyping(
                articles: articles,
                rows: {
                    typedRows(
                        folders: showsFolders ? subfolders : [],
                        books: listsItems ? books : [],
                        allBooks: allBooks,
                        feedID: feedID,
                        articles: articles
                    )
                },
                selection: $selectedBookIDs,
                window: hostWindow
            ))
        }
        .toolbar {
            ToolbarItemGroup {
                if showsFolders && !currentFolderPath.isEmpty {
                    Button {
                        navigateUp()
                    } label: {
                        Label("Up One Level", systemImage: "chevron.up")
                    }
                    .accessibilityLabel("Go up one folder level")
                }

                addToLibraryButton(focusTarget: focusTarget)

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
                .accessibilityHint(Self.editModeButtonHint(isEditMode: isEditMode, selectedCount: selectedBooks.count))

                if showsFolders {
                    Button {
                        newFolderParentPath = currentFolderPath
                        showNewFolderSheet = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    .accessibilityLabel("Create new folder")
                }

                // Feed Settings or Folder Settings for the folder shown (FR19).
                if let target = folderSettingsTarget {
                    folderSettingsButton(target)
                }

                // Sort controls (TODO A06), or the Reading List's one order
                // (FR09).
                sortMenu(hasSubfolders: !folders.isEmpty)
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
                    // The name as it was made and its parent, read before the
                    // close clears them, for the words said once it has closed.
                    let createdName = BookFolder.normalizedName(newFolderName)
                    let createdParent = newFolderParentPath
                    return closingOnSuccess(libraryViewModel.createFolderReturningOutcome(
                        name: newFolderName,
                        parentPath: newFolderParentPath
                    )) {
                        if let createdName {
                            VoiceOverAnnouncer.announceAfterSheetCloses(
                                NewFolderSheet.createdAnnouncement(name: createdName, parentPath: createdParent),
                                from: hostWindow
                            )
                        }
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
        // Which feed items a move left is said once the sheet has closed,
        // so its closing never cuts the words off (REV11 F6).
        .modifier(MoveToFolderSheetPresentation(
            request: $moveRequest,
            library: libraryViewModel,
            onMove: { request, path in
                let outcome = await libraryViewModel.moveBooksReturningOutcome(request.books, toFolder: path)
                return closingOnSuccess(outcome) {
                    afterMoveSheet.keep(outcome.message)
                    clearAllSelections()
                    moveRequest = nil
                }
            },
            onDismiss: sayWhatTheMoveLeft
        ))
        .trackingRemovalPreferences($removalPreferences)
        // A folder deleted or moved from another window, as by Delete
        // Feed… or Delete Folder…, leaves this window on the folder's new
        // path or the nearest folder above it, never on a path that names
        // no folder.
        .modifier(ShownFolderFollowing(
            currentFolderPath: $currentFolderPath,
            library: libraryViewModel.library,
            isComplete: libraryViewModel.indexRecovery == nil
        ))
        // The selection as the Library menu's Remove names it: Delete
        // Download for feed items alone (REV11 F2).
        .focusedSceneValue(
            \.libraryRemovalSelection,
            LibraryRemovalSelection(LibrarySelectionPolicy.selected(in: books, native: selectedBookIDs, edit: editSelection))
        )
        // Go to View's keys and submenu, and a view deleted while shown
        // (design sections 5 and 6), in a modifier of their own, which keeps
        // this chain within the type checker's time.
        .modifier(LibraryViewNavigationSupport(
            offeredNames: goToViewNames,
            list: views.list,
            takesCommand: takesCommand,
            goToView: { goToView(numbered: $0) },
            followDeletedView: followDeletedView
        ))
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
        // The Transcribe Audio sheet the rows' commands and the offers after
        // imports open, and the rows' transcription notes kept current (FR05).
        .modifier(LibraryTranscriptionSupport(presenter: transcription, library: libraryViewModel, hostWindow: hostWindow))
        // Library > Add Feed…, the Add Feed sheet, and the notices after
        // the feed commands (FR03).
        .modifier(LibraryFeedsWindowSupport(
            presenter: feedPresenter,
            feedFolders: feedFolders,
            library: libraryViewModel,
            hostWindow: hostWindow,
            shownFolderPath: showsFolders ? currentFolderPath : nil,
            takesCommand: takesCommand,
            // Move to Library…'s key acts on the selection (FR11, branch D).
            selectedBooks: { selectedBooks }
        ))
        // The Add to Library sheet, and the choice made in it, which runs
        // once the sheet has gone (FR20).
        .modifier(LibraryAddToLibrarySupport(
            host: addToLibrary,
            model: addToLibrary.model,
            library: libraryViewModel,
            hostWindow: hostWindow
        ))
        // Library > Folder or Feed Settings, and the Folder Settings sheet
        // (FR19).
        .modifier(LibraryFolderSettingsSupport(
            folderSettings: $folderSettings,
            takesCommand: takesCommand,
            openShownSettings: { openFolderSettings(folderSettingsTarget) }
        ))
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
            // Cmd+I: Book Info for the first selected book; Feed Info for a
            // feed's row, or a feed's folder's; a folder has no sheet, so
            // its row speaks its full information instead, as Speak Full
            // Info does (`LibraryInfoRow.infoCommand(feedInFolder:)`).
            switch selectedInfoRow?.infoCommand(feedInFolder: { feedFolders.feedID(inFolder: $0) }) {
            case .bookInfo(let book):
                showBookInfo(for: book)
            case .feedInfo(let feedID):
                showFeedInfo(feedID)
            case .speakFullInfo:
                speakSelectedInfo(.full)
            case nil:
                break
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .speakInfo)
                .merge(with: NotificationCenter.default.publisher(for: .speakFullInfo))
        ) { notification in
            // Shift-Command-I, and Library > Speak Info: the selected row's
            // brief summary; Shift-Command-I twice, and Library > Speak Full
            // Info, its full one (FR12). Spoken with the app's own voice.
            guard takesCommand(notification) else { return }
            speakSelectedInfo(notification.name == .speakFullInfo ? .full : .brief)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSelectedBook)) { notification in
            // Only respond in the focused library window
            guard takesCommand(notification) else { return }
            if let id = selectedBookIDs.first,
               let book = filteredBooks.first(where: { $0.id == id }) {
                openBook(book)
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
            moveToFolder(selectedBooks)
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
        // Move Book Up and Move Book Down, and Add to Reading List and
        // Remove from Reading List (FR09), for the selection.
        .modifier(LibraryOrderCommandsSupport(
            takesCommand: takesCommand,
            moveSelectedBook: { moveSelectedBookInManualOrder(direction: $0) },
            changeReadingList: { changeReadingList($0, with: selectedBooks) }
        ))
        .sheet(isPresented: $showTextInput) {
            TextInputView(
                onAdd: { title, author, text in
                    // Made at the Reading List, the book joins it, and goes
                    // to the folder this window showed last (FR09).
                    libraryViewModel.createBookFromText(
                        title: title,
                        author: author,
                        text: text,
                        toFolder: currentFolderPath,
                        from: ImportOrigin(window: hostWindow),
                        addingToReadingList: showsReadingList
                    )
                    showTextInput = false
                },
                onCancel: { showTextInput = false }
            )
        }
        // Rename folder sheet, handed its folder, so it never opens empty.
        .sheet(item: $folderToRename) { folder in
            RenameFolderSheet(
                currentName: folder.name,
                newName: $renameFolderText,
                onRename: {
                    await editFolder(folder, closing: { folderToRename = nil }) {
                        await libraryViewModel.renameFolderReturningOutcome(folder, to: renameFolderText)
                    }
                },
                onCancel: {
                    folderToRename = nil
                }
            )
        }
        // Move folder to new parent sheet, handed its folder, so it never
        // opens empty.
        .sheet(item: $folderToMove) { folder in
            MoveFolderToParentSheet(
                folder: folder,
                library: libraryViewModel.library,
                onMove: { newParent in
                    await editFolder(folder, closing: { folderToMove = nil }) {
                        await libraryViewModel.moveFolderReturningOutcome(folder, toParent: newParent)
                    }
                },
                onCancel: { folderToMove = nil }
            )
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

    // MARK: - The Sort Menu

    /// The Sort menu. Every item reads the one sort the location shows and
    /// changes it only through userChangedSort, so the menu, the window
    /// title, and the order agree (TODO A06). At the Reading List, which
    /// shows its own order (FR09), the menu names that order, checked, and
    /// offers no other.
    /// - Parameter hasSubfolders: Whether the folder shown has subfolders,
    ///   for Apply Sort to All Subfolders.
    private func sortMenu(hasSubfolders: Bool) -> some View {
        Menu {
            if location.keepsItsOwnOrder {
                readingListSortItem
            } else if location.listsOnlyFeeds {
                feedsSortItem
            } else {
                sortItems(hasSubfolders: hasSubfolders)
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityLabel(sortMenuLabel)
    }

    /// The Sort button's spoken label: the Reading List's one order, the
    /// feeds' order in a view listing only feeds, or the sort shown.
    private var sortMenuLabel: String {
        if location.keepsItsOwnOrder {
            return ReadingListWording.sortMenuLabel
        }
        return location.listsOnlyFeeds ? LibraryViewPickerWording.feedsSortMenuLabel : sort.menuAccessibilityLabel
    }

    /// The Sort menu's one item in a view listing only feeds, which are
    /// always listed by title (October 30, 2026): that order, checked, whose
    /// hint says so; choosing it says the order, as choosing a sort
    /// elsewhere says the sort now shown.
    private var feedsSortItem: some View {
        Toggle(LibraryViewPickerWording.feedsOrderName, isOn: Binding(
            get: { true },
            set: { _ in announceToVoiceOver(LibraryViewPickerWording.feedsOrderAnnouncement) }
        ))
        .help(LibraryViewPickerWording.feedsOrderHint)
        .accessibilityHint(LibraryViewPickerWording.feedsOrderHint)
    }

    /// The Sort menu's items where the user sorts the books: a field each,
    /// the direction command, and, in a folder with subfolders, Apply Sort
    /// to All Subfolders.
    @ViewBuilder
    private func sortItems(hasSubfolders: Bool) -> some View {
        // A checkmark marks the field shown, for VoiceOver as well as on
        // screen; choosing that field again leaves the sort as it is and
        // says it (TODO A11), and only the direction command reverses it.
        ForEach(LibrarySortField.allCases, id: \.self) { field in
            Toggle(field.rawValue, isOn: Binding(
                get: { sort.isChecked(field) },
                set: { _ in userChangedSort(.choose(field)) }
            ))
        }
        Divider()
        // Disabled in manual order, which has no direction; the hint says
        // why, to VoiceOver and as a tooltip.
        Button(sort.directionCommandTitle) {
            userChangedSort(.reverseDirection)
        }
        .disabled(!sort.isDirectionCommandEnabled)
        .help(sort.directionCommandHint)
        .accessibilityHint(sort.directionCommandHint)
        // Only show "Apply to Subfolders" when in folders mode and subfolders exist
        if showsFolders && hasSubfolders {
            Divider()
            Button {
                libraryViewModel.applySortToSubfolders(sort.setting, from: currentFolderPath)
                announceToVoiceOver(sort.subfolderAnnouncement)
            } label: {
                Text("Apply Sort to All Subfolders")
            }
        }
    }

    /// The Sort menu's one item at the Reading List (FR09): its order,
    /// checked, whose hint says how it changes; choosing it says the order,
    /// as choosing a sort elsewhere says the sort now shown.
    private var readingListSortItem: some View {
        Toggle(ReadingListWording.orderName, isOn: Binding(
            get: { true },
            set: { _ in announceToVoiceOver(ReadingListWording.orderAnnouncement) }
        ))
        .help(ReadingListWording.orderHint)
        .accessibilityHint(ReadingListWording.orderHint)
    }

    // MARK: - Extracted Subviews

    /// The options bar at the top of the Reading List (FR09), showing the
    /// list's own options and saving each choice at once; nothing in any
    /// other category.
    @ViewBuilder
    private var readingListOptions: some View {
        if showsReadingList {
            let list = libraryViewModel.readingList
            ReadingListOptionsBar(
                continuation: list.continuation,
                skipsFinished: list.skipsFinished,
                removesFinished: list.removesFinished,
                keepsBooks: keptBooks.keepsReadingListBooks,
                showsKeepChoice: cloudStates.showsCloudNotes,
                chooseContinuation: { libraryViewModel.setReadingListContinuation($0) },
                chooseSkipsFinished: { libraryViewModel.setReadingListSkipsFinished($0) },
                chooseRemovesFinished: { libraryViewModel.setReadingListRemovesFinished($0) },
                chooseKeepsBooks: { libraryViewModel.setKeepsReadingListBooks($0) }
            )
        }
    }

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
                    if let timeText = Self.continueTimeText(for: lastBook, wpm: settingsViewModel.wordsPerMinute) {
                        Text(timeText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.continueAccessibilityLabel(for: lastBook, wpm: settingsViewModel.wordsPerMinute))
            .accessibilityHint("Opens the last book you were reading")
            .accessibilityIdentifier(voiceOverFocusID)
            .background(StandardVoiceOverFocus(delay: 1.2))
        }
    }

    /// The time left the Continue button shows, "16:00 left", in the words
    /// a library row uses (`BookRow.remainingText(_:)`), or nil when the
    /// book has no time left to show: its estimate is unknown, or it rests
    /// at its end, where a row says "Finished" and the button once said
    /// "0:00 left" (TODO P07).
    nonisolated static func continueTimeText(for book: Book, wpm: Double) -> String? {
        BookRow.timeRemaining(for: book, wpm: wpm).map { BookRow.remainingText($0).visible }
    }

    /// What VoiceOver says for the Continue button, "Continue listening to
    /// Emma, 16 minutes remaining", with its time spoken as the book's row
    /// speaks it. A book with no time left to show, as a finished one,
    /// leaves the time out: "Continue listening to Emma".
    nonisolated static func continueAccessibilityLabel(for book: Book, wpm: Double) -> String {
        let label = "Continue listening to \(book.title)"
        guard let remaining = BookRow.timeRemaining(for: book, wpm: wpm) else { return label }
        return "\(label), \(BookRow.remainingText(remaining).spoken)"
    }

    /// The words for Delete Everything on the folder awaiting confirmation,
    /// in the mode the Trash preference chooses, naming the feeds whose own
    /// folder it is and those whose folders are inside it, and what happens
    /// to each (FR14, REV14 feeds 7), and counting the books a newer
    /// TextMouth added there, which are kept (stable020 review, finding 1).
    /// With no folder pending, no dialog shows, and only the mode-dependent
    /// button title matters.
    private var deleteEverythingWording: FolderRemovalWording {
        let folder = libraryViewModel.pendingDeleteFolder
        return FolderRemovalWording(
            mode: removalPreferences.deletionMode,
            folderName: folder?.name ?? "",
            bookCount: folder.map { libraryViewModel.bookCount(inFolderTree: $0.fullPath) } ?? 0,
            feedTitles: folder.map { libraryViewModel.feedTitles(inside: $0) } ?? [],
            ownFeedTitles: folder.map { libraryViewModel.feedTitles(of: $0) } ?? [],
            keptBookCount: folder.map { libraryViewModel.keptBookCount(inFolderTree: $0.fullPath) } ?? 0
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
        let context = bookRowContext(books, orderedBy: allBooks)
        return ForEach(books) { book in
            bookRow(book, context: context)
        }
        .onMove(perform: dragReorderAction)
    }

    /// What every book row of one drawing of the list shares, made once for
    /// all of them (PERF28): the selection and its cloud commands, each
    /// book's moves in the manual order shown, and what the rows' commands
    /// do.
    private struct BookRowContext {
        /// Every selected book, by either selection.
        let selectedIDs: Set<UUID>
        /// The selected books the list shows, in its order.
        let selection: [Book]
        /// The cloud commands of `selection`.
        let selectionCloudCommands: [LibraryCloudCommand]
        /// Each book's moves in the manual order the list shows, by ID;
        /// empty when it shows none.
        let manualMoves: [UUID: LibraryManualMoves]
        /// The books in the reading list (FR09), by ID.
        let readingListIDs: Set<UUID>
        /// The reading list commands of `selection` (FR09).
        let selectionReadingListCommands: [ReadingListCommand]
        /// What the rows' commands do.
        let actions: LibraryBookRowActions
        /// How the rows show titles (the Leading articles setting).
        let articles: LeadingArticles
    }

    /// The context the rows of `books` share, for a list whose location
    /// shows `allBooks`: Move Up and Move Down follow that whole order only
    /// where `offersManualMoves`, as nowhere a feed's items are listed by
    /// date (FR03), and only where the list shows an order the user
    /// arranges: a folder's manual order, or the reading list (FR09).
    private func bookRowContext(_ books: [Book], orderedBy allBooks: [Book], offersManualMoves: Bool = true) -> BookRowContext {
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
        // Every book's moves in the order the list shows, read from that
        // order rather than by sorting the folder again for each row.
        let manualMoves = reorderTarget == nil || !offersManualMoves ? [:] : LibraryManualMoves.moves(in: allBooks)
        let readingListIDs = Set(libraryViewModel.readingList.bookIDs)
        return BookRowContext(
            selectedIDs: selectedIDs,
            selection: selection,
            selectionCloudCommands: selectionCloudCommands,
            manualMoves: manualMoves,
            readingListIDs: readingListIDs,
            selectionReadingListCommands: ReadingListCommand.commands(
                for: selection,
                isSelection: selection.count > 1,
                inList: readingListIDs
            ),
            actions: rowActions,
            articles: libraryViewModel.leadingArticles
        )
    }

    /// One book's row, with its context menu and its VoiceOver actions,
    /// which share the books they act on and the cloud commands (FR02).
    /// - Parameters:
    ///   - book: The row's book.
    ///   - context: What the list's book rows share.
    ///   - feedActions: The commands of the feed item the book was
    ///     downloaded from, in its feed's folder (FR03).
    private func bookRow(_ book: Book, context: BookRowContext, feedActions: [FeedItemAction] = []) -> some View {
        let targets = commandTargets(for: book, selectedIDs: context.selectedIDs, selection: context.selection)
        let isSelectionRow = targets.count > 1
        return LibraryBookListRow(
            book: book,
            // "Hobbit, The" while sorting passes over articles.
            shownTitle: libraryViewModel.rowTitle(of: book, articles: context.articles),
            isOpenInWindow: libraryViewModel.openBookIDs.contains(book.id),
            wpm: settingsViewModel.wordsPerMinute,
            isEditMode: isEditMode,
            isEditSelected: editSelection.contains(book.id),
            cloudState: cloudStates.listedState(of: book.id),
            isKeptOnThisMac: cloudStates.listsAsKept(book.id, in: keptBooks),
            targets: targets,
            cloudCommands: isSelectionRow
                ? context.selectionCloudCommands
                : LibraryCloudCommand.commands(
                    for: targets,
                    isSelection: false,
                    states: cloudStates,
                    kept: keptBooks.bookIDs
                ),
            // Move Up and Move Down move the row's own book alone (TODO A06).
            manualMoves: isSelectionRow ? nil : context.manualMoves[book.id],
            removalPreferences: removalPreferences,
            livePosition: libraryViewModel.livePositions.entry(for: book.id),
            audioCommands: LibraryAudioCommand.commands(for: targets, isTranscribed: transcribedBooks.contains),
            transcriptionNote: transcribedBooks.note(for: book.id),
            isTrackFolder: trackFolderBooks.contains(book.id),
            // The item's commands act on the row's own book alone.
            feedActions: isSelectionRow ? [] : feedActions,
            // Said in every view but the Reading List, where every book is in it.
            isInReadingList: !showsReadingList && context.readingListIDs.contains(book.id),
            // Add to or Remove from Reading List, by membership (FR09).
            readingListCommands: isSelectionRow
                ? context.selectionReadingListCommands
                : ReadingListCommand.commands(for: targets, isSelection: false, inList: context.readingListIDs),
            actions: context.actions
        )
        .equatable()
        .tag(book.id)
    }

    // MARK: - Folders, Feeds, and Books Sections

    /// The Folders section: a row for each of `subfolders`, which opens the
    /// folder, with the folder commands in its context menu. A feed's folder
    /// has a row only where the Feeds section does not list its feed
    /// (`LibraryFeedFolders.folderRows(_:at:bookCount:)`); there it says
    /// "Feed" after its name, counts its feed's items as the feed's row
    /// does, and offers its feed's commands in its context menu and as its
    /// VoiceOver actions (FR03).
    private func foldersSection(_ subfolders: [BookFolder]) -> some View {
        Section {
            ForEach(subfolders) { folder in
                let feedID = feedFolders.feedID(inFolder: folder.id)
                let feedActions = feedActions(forFolder: folder)
                Button {
                    currentFolderPath = folder.fullPath
                } label: {
                    if let feedID {
                        // Its counts follow the feed engine, which the list
                        // itself does not observe.
                        FeedFolderRow(center: feedFolders.center, folder: folder, feedID: feedID)
                    } else {
                        FolderRow(
                            folder: folder,
                            bookCount: libraryViewModel.bookCount(inFolderTree: folder.fullPath),
                            feedsBelow: feedFolders.feedCount(below: folder)
                        )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAction(.default) {
                    currentFolderPath = folder.fullPath
                }
                .accessibilityActions {
                    ForEach(feedActions) { action in
                        Button(action.title) { performFeedAction(action) }
                    }
                }
                .contextMenu {
                    folderMenu(folder)
                    if !feedActions.isEmpty {
                        Divider()
                        ForEach(feedActions) { action in
                            Button(action.title, role: action.role) { performFeedAction(action) }
                        }
                    }
                }
            }
        } header: {
            Text("Folders")
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// A folder's commands: Rename, Move, and Delete, in its row's context
    /// menu, and, for a feed's folder, in its feed's row's, which stands for
    /// the folder where the Feeds section lists the feed (FR03). A feed's
    /// own folder holding nothing more than its items offers no Delete
    /// Folder…: its feed's commands beside these offer Delete Feed… there,
    /// so a feed has one delete (FR14); one holding more offers it, its
    /// question naming the feed (REV14 feeds 7).
    @ViewBuilder
    private func folderMenu(_ folder: BookFolder) -> some View {
        Button("Rename Folder...") {
            renameFolderText = folder.name
            folderToRename = folder
        }
        Button("Move Folder...") {
            folderToMove = folder
        }
        if libraryViewModel.offersDeleteFolder(folder) {
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

    /// The Books section of the books the list shows, or, in a feed's
    /// folder (`feedID`), the feed's items with the downloaded ones as their
    /// books, newest first, then the folder's other books (FR03). A feed's
    /// items are listed by date, so their rows offer no Move Up or Move
    /// Down and can't be dragged.
    @ViewBuilder
    private func booksSection(_ books: [Book], orderedBy allBooks: [Book], feedID: UUID?) -> some View {
        if let feedID {
            let context = bookRowContext(books, orderedBy: allBooks, offersManualMoves: false)
            FeedFolderSections(
                center: feedFolders.center,
                feedID: feedID,
                shownBooks: books,
                folderBooks: allBooks,
                search: searchText,
                wordsPerMinute: settingsViewModel.wordsPerMinute,
                articles: context.articles,
                bookRow: { book, actions in bookRow(book, context: context, feedActions: actions) },
                perform: performFeedItemAction
            )
        } else {
            Section {
                // An empty reading list says so, and how a book joins it
                // (FR09); a search that matches nothing leaves the list as
                // it is.
                if showsReadingList && allBooks.isEmpty {
                    Text(ReadingListWording.emptyList)
                        .foregroundColor(.secondary)
                } else if showsEmptySentence(allBooks: allBooks) {
                    emptyViewRow
                }
                bookRows(books, orderedBy: allBooks)
            } header: {
                // Episodes and articles listed beside books, as in Recently
                // Opened and the Reading List, are counted apart (FR11).
                Text(CountWording.booksHeader(of: books))
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    /// The list's rows, in its order, as letter navigation reaches them
    /// (`LibraryTitleTyping`): the Folders section's folders by their names
    /// as written; the Feeds section's feeds, in the order it shows them;
    /// and the books, as a feed's folder lists them where the list shows
    /// one (its items' books, then its other books). Rows the list's
    /// selection cannot hold, a feed's items not downloaded, are left out.
    /// - Parameters:
    ///   - folders: The folders the Folders section shows, or none.
    ///   - books: The books the list shows, as the search narrows them, or none.
    ///   - allBooks: Every book at the location, in the order shown.
    ///   - feedID: The feed whose folder the list shows, if it shows one.
    ///   - articles: How titles are sorted and shown.
    private func typedRows(
        folders: [BookFolder],
        books: [Book],
        allBooks: [Book],
        feedID: UUID?,
        articles: LeadingArticles
    ) -> [TypedRow<UUID>] {
        var rows = folders.map { TypedRow(id: $0.id, name: $0.name) }
        rows += LibraryFeedsSectionRows.rows(at: location, center: feedFolders.center, articles: articles)
            .map { TypedRow(id: $0.id, title: $0.title, language: nil) }
        var listedBooks = books
        if let feedID, !books.isEmpty {
            let listing = FeedFolderListing.make(
                feedID: feedID,
                center: feedFolders.center,
                shownBooks: books,
                folderBooks: allBooks,
                search: searchText,
                wordsPerMinute: settingsViewModel.wordsPerMinute,
                articles: articles
            )
            listedBooks = listing.entries.compactMap { entry in
                if case .book(let book, _) = entry { return book }
                return nil
            } + listing.otherBooks
        }
        rows += listedBooks.map { TypedRow(id: $0.id, title: $0.title, language: $0.epubLanguage) }
        return rows
    }

    /// The Folders section's rows and the Folders rotor's entries here, of
    /// `folders`, the folders directly inside this location
    /// (`LibraryFeedFolders.folderRows(_:at:bookCount:)`, FR03).
    private func shownFolderRows(of folders: [BookFolder]) -> LibraryFolderRows {
        feedFolders.folderRows(folders, at: location) { libraryViewModel.bookCount(inFolderTree: $0.fullPath) }
    }

    /// The library folder of the feed a Feeds row shows, or nil when it is
    /// gone (FR03).
    private func folder(ofFeedRow row: FeedRowContent) -> BookFolder? {
        guard let path = row.folderPath else { return nil }
        return libraryViewModel.library.folders.first { $0.fullPath == path }
    }

    /// The feed whose folder the list shows, when it shows one (FR03).
    private var shownFeedID: UUID? {
        guard showsFolders, !currentFolderPath.isEmpty,
              let folder = libraryViewModel.library.folders.first(where: { $0.fullPath == currentFolderPath }) else {
            return nil
        }
        return feedFolders.feedID(inFolder: folder.id)
    }

    /// Opens the folder of the feed a Feeds row shows, as a folder's row
    /// opens its folder, from the Folders view; a feed whose folder is gone
    /// says so and opens its Feed Info, where another folder can be chosen
    /// (FR03).
    private func openFeed(_ row: FeedRowContent) {
        guard let path = row.folderPath else {
            // Feed Info is where another folder can be chosen.
            announceToVoiceOver(FeedWording.folderMissing(title: row.title))
            performFeedAction(FeedAction(command: .feedInfo, feedID: row.id, title: FeedWording.feedInfoTitle))
            return
        }
        shownViewID = .category(.folders)
        currentFolderPath = path
    }

    /// The commands of the feed whose folder `folder` is, by its state
    /// (Unsubscribe or Resubscribe, FR11, branch D), or none for any other
    /// folder (FR03).
    private func feedActions(forFolder folder: BookFolder) -> [FeedAction] {
        guard let feedID = feedFolders.feedID(inFolder: folder.id) else { return [] }
        return FeedAction.actions(for: feedID, in: feedFolders.center)
    }

    /// What the feed commands chosen in this window work with (FR03).
    private var feedCommandContext: FeedCommandContext {
        FeedCommandContext(center: feedFolders.center, library: libraryViewModel, window: hostWindow)
    }

    /// Runs a feed's command from its row or its folder's row (FR03).
    private func performFeedAction(_ action: FeedAction) {
        feedPresenter.perform(action, in: feedCommandContext)
    }

    /// Runs a feed item's command from its row or its book's row: Open
    /// downloads an item first, as a book in the cloud downloads before it
    /// opens, its row saying how far the download has got (FR03).
    private func performFeedItemAction(_ action: FeedItemAction) {
        feedPresenter.perform(action, in: feedCommandContext)
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

    /// Opens `book` from this window's list: by its row's default action,
    /// its Open item, or Return on the selection. At the Reading List the
    /// book's reader is asked first to read it from the list (FR09), so its
    /// window is marked and the book continues through the list; Continue
    /// Listening, which opens the last book read, opens as it always has.
    private func openBook(_ book: Book) {
        ReadingListOpenRequests.shared.open(
            book,
            shownIn: location.category,
            libraryIsMoving: libraryViewModel.dataDirectoryMove != nil,
            with: onOpenBook
        )
    }

    /// What the rows' commands do, on this list's state as it is when they
    /// run: open, Book Info, Select, Move to Folder, Move Up and Move Down,
    /// the cloud commands, removal, Export, Edit Text, and the transcription
    /// commands (FR05).
    private var rowActions: LibraryBookRowActions {
        LibraryBookRowActions(
            open: openBook,
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
                moveToFolder(books)
            },
            moveInManualOrder: { book, direction in
                moveBooks([book.id], direction: direction)
            },
            moveSayingPlace: moveSayingPlace,
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
            editManifest: { book, choosingApp in
                let window = hostWindow
                Task {
                    await BookManifestEditor.shared.edit(book, choosingApp: choosingApp, in: libraryViewModel, from: window)
                }
            },
            performAudioCommand: { command in
                transcription.perform(command, library: libraryViewModel, window: hostWindow)
            },
            performFeedAction: performFeedItemAction,
            performReadingListCommand: performReadingListCommand
        )
    }

    /// Runs a reading list command (FR09), from a row's context menu or its
    /// VoiceOver actions, or from the edit-mode bar, announcing from this
    /// window what it did.
    private func performReadingListCommand(_ command: ReadingListCommand) {
        changeReadingList(command.kind, with: command.books)
    }

    /// The edit-mode bar's Add to Reading List and Remove from Reading List
    /// for the books selected here (FR09), by membership, or the one this
    /// view suggests, dimmed, while none is selected.
    private var editBarReadingListCommands: [ReadingListCommand] {
        ReadingListCommand.editBarCommands(
            for: selectedBooks,
            inList: Set(libraryViewModel.readingList.bookIDs),
            atReadingList: showsReadingList
        )
    }

    /// Adds `books` to the reading list or takes them off it (FR09), as a
    /// row's command, the edit-mode bar, or the Library menu asks, and says
    /// what it did, or why nothing changed, from this window. At the
    /// Reading List, the books taken off leave the view, so they leave the
    /// selection too: the edit-mode bar's count and commands then speak of
    /// the books still shown.
    private func changeReadingList(_ kind: ReadingListCommand.Kind, with books: [Book]) {
        switch kind {
        case .add:
            libraryViewModel.addToReadingList(books, announcingFrom: hostWindow)
        case .remove:
            libraryViewModel.removeFromReadingList(books, announcingFrom: hostWindow)
            if showsReadingList {
                let gone = Set(books.map(\.id)).subtracting(libraryViewModel.readingList.bookIDs)
                editSelection.subtract(gone)
                selectedBookIDs.subtract(gone)
            }
        }
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

    // MARK: - Moving Books

    /// Opens the Move to Folder sheet, by a request for `books`, from a
    /// row's command, the edit bar's Move, or Command-Shift-M, unless every
    /// one is a feed item, which Move to Folder never moves (FR11):
    /// VoiceOver then hears at once that they stay where they are, and no
    /// request is made. A mixed selection opens the sheet, and its move says
    /// which items it left.
    private func moveToFolder(_ books: [Book]) {
        guard !books.isEmpty else { return }
        guard books.contains(where: { !$0.isFeedItem }) else {
            if let left = LibraryTransitionWording.feedItemsLeft(titles: books.map(\.title)) {
                VoiceOverAnnouncer.announce(left, from: hostWindow)
            }
            return
        }
        moveRequest = MoveToFolderRequest(books: books)
    }

    /// Says which feed items the Move sheet's move left where they are,
    /// from this window, once the sheet has closed (REV11 F6).
    private func sayWhatTheMoveLeft() {
        let window = hostWindow
        afterMoveSheet.sheetDidClose { note in VoiceOverAnnouncer.announce(note, from: window) }
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

    /// The hint of the toolbar's Edit button, which enters edit mode and
    /// leaves it: what pressing it does, and, while in edit mode, how many
    /// books are selected, "1 book selected" or "3 books selected". A hint
    /// says the result, not what to do (TODO A10; it said "Enter edit mode
    /// to select multiple books for moving or deleting", and "1 books").
    nonisolated static func editModeButtonHint(isEditMode: Bool, selectedCount: Int) -> String {
        isEditMode
            ? "Exits edit mode. \(CountWording.books(selectedCount)) selected."
            : "Enters edit mode, for selecting several books to move or remove."
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

    /// The listed books currently selected, by either selection
    /// (`LibrarySelectionPolicy.selected(in:native:edit:)`).
    private var selectedBooks: [Book] {
        LibrarySelectionPolicy.selected(in: filteredBooks, native: selectedBookIDs, edit: editSelection)
    }

    /// Whether this Library window takes the menu command or keyboard
    /// shortcut `notification` posts, as `WindowCommandRouting` decides: a
    /// shortcut names the window it was pressed in (`sourceWindow` in its
    /// user info), which alone takes it; a menu command names none, and the
    /// key window takes it; a window whose NSWindow isn't known yet takes
    /// either.
    private func takesCommand(_ notification: Notification) -> Bool {
        let sourceWindow = notification.userInfo?["sourceWindow"] as? PlatformWindow
        return WindowCommandRouting.shouldAccept(
            hasSourceWindow: sourceWindow != nil,
            sourceMatchesHost: sourceWindow === hostWindow,
            hasHostWindow: hostWindow != nil,
            hostWindowIsKey: hostWindow?.isKeyWindow ?? false
        )
    }

    // MARK: - Speak Info and Book Info for the Selected Row

    /// The row Speak Info (Shift-Command-I) and Book Info (Command-I) act
    /// on: the first selected row in the list's order, which the List
    /// selects by ID for a folder's and a feed's row as for a book's, or
    /// the edit selection's first book (`LibraryInfoRow.selected`).
    private var selectedInfoRow: LibraryInfoRow? {
        LibraryInfoRow.selected(
            selectedBookIDs,
            editSelection: editSelection,
            folders: shownFolderRows(of: libraryViewModel.subfoldersOf(currentFolderPath)).shown,
            // In the order the Feeds section shows them.
            feeds: LibraryFeedsSectionRows.rows(at: location, center: feedFolders.center, articles: libraryViewModel.leadingArticles),
            books: filteredBooks
        )
    }

    /// Speaks the selected row's information with the app's own voice, as
    /// Where Am I speaks a position in a reader (`LibraryInfoSpeaker`): the
    /// `detail` summary of the row, in the chosen voice at the chosen speed,
    /// or, with nothing selected, that nothing is; or stops the summary
    /// speaking, as the speaker decides (FR12). The row's facts are
    /// gathered at the press, as the list shows them then, and the summary
    /// is tied to the row, so a press on another row speaks that one's.
    private func speakSelectedInfo(_ detail: SummaryDetail) {
        let row = selectedInfoRow
        infoSpeaker.press(
            detail,
            about: row?.id,
            voice: settingsViewModel.selectedVoice,
            wordsPerMinute: settingsViewModel.wordsPerMinute
        ) { spoken in
            row.map { row in
                LibraryInfoSubject(
                    row,
                    library: libraryViewModel,
                    feedFolders: feedFolders,
                    wordsPerMinute: settingsViewModel.wordsPerMinute,
                    cloudStates: cloudStates,
                    keptBooks: keptBooks,
                    measuresFileSize: spoken == .full
                )
            }
        }
    }

    /// Opens Feed Info for the feed `feedID`, as its row's command does
    /// (FR03).
    private func showFeedInfo(_ feedID: UUID) {
        performFeedAction(FeedAction(command: .feedInfo, feedID: feedID, title: FeedWording.feedInfoTitle))
    }

    /// What the settings button and command open: the settings of the
    /// folder this window shows, nil where it shows none (FR19).
    private var folderSettingsTarget: LibraryFolderSettingsTarget? {
        LibraryFolderSettingsTarget.of(
            category: location.category,
            folderPath: currentFolderPath,
            folders: libraryViewModel.library.folders,
            feedID: { feedFolders.feedID(inFolder: $0) },
            feedTitle: { feedFolders.center.store.records[$0]?.feed.title }
        )
    }

    /// The toolbar's Feed Settings or Folder Settings button for `target`.
    private func folderSettingsButton(_ target: LibraryFolderSettingsTarget) -> some View {
        Button {
            openFolderSettings(target)
        } label: {
            Label(target.buttonTitle, systemImage: target.systemImage)
        }
        .accessibilityLabel(target.accessibilityLabel)
        .accessibilityHint(target.accessibilityHint)
    }

    /// Opens the settings of `target`: Feed Info for a feed's folder, by the
    /// path Command-I takes, the Folder Settings sheet for a plain folder;
    /// with no target, says there is nothing to open (FR19).
    private func openFolderSettings(_ target: LibraryFolderSettingsTarget?) {
        LibraryFolderSettingsTarget.open(
            target,
            showFeedInfo: showFeedInfo,
            showFolderSettings: { folderID in
                folderSettings = FolderSettingsModel(
                    folderID: folderID,
                    library: libraryViewModel,
                    feedFolders: feedFolders,
                    wordsPerMinute: settingsViewModel.wordsPerMinute
                )
            },
            announce: announceToVoiceOver
        )
    }

    /// Where this list is: its view and, in Folders, its folder.
    private var location: LibraryLocation {
        LibraryLocation(view: shownView, folderPath: currentFolderPath)
    }

    /// The view this window shows: the one `shownViewID` names, or, once it
    /// is deleted, the first view offered, until `followDeletedView` moves
    /// there (October 30, 2026).
    private var shownView: LibraryViewDefinition {
        libraryViewModel.shownView(shownViewID, in: views.list, center: feedFolders.center).view
    }

    /// Whether this window shows Folders: one folder at a time, with its
    /// breadcrumbs, its subfolders, and its own commands.
    private var showsFolders: Bool {
        location.view.kind == .folders
    }

    /// Whether this window shows the Reading List (FR09), in its own order.
    private var showsReadingList: Bool {
        location.keepsItsOwnOrder
    }

    /// Whether the view shown lists books, episodes, or articles, so the
    /// list has a Books section (`hasBooksSection(_:)`).
    private var listsItems: Bool {
        Self.hasBooksSection(location.view)
    }

    /// Whether the list shows the sentence that nothing matches
    /// (`showsEmptySentence(for:listsBooks:listsFeeds:)`), `allBooks` being
    /// its books before a search narrows them.
    private func showsEmptySentence(allBooks: [Book]) -> Bool {
        Self.showsEmptySentence(
            for: location.view,
            listsBooks: !allBooks.isEmpty,
            listsFeeds: !LibraryFeedsSectionRows.feeds(at: location, center: feedFolders.center).isEmpty
        )
    }

    /// Whether a list of `view` has a Books section: every view but one
    /// listing feeds alone, such as Feeds, which would show only "Books (0)".
    nonisolated static func hasBooksSection(_ view: LibraryViewDefinition) -> Bool {
        view.filter?.listsItems ?? true
    }

    /// Whether a list of `view` shows the sentence that nothing matches,
    /// while it lists no book, episode, or article (`listsBooks`) and no
    /// feed (`listsFeeds`): in the Feeds view, the listener's views, and any
    /// view without a Books section, such as Unopened changed to list feeds
    /// alone, which would otherwise show nothing at all (review of October
    /// 31, 2026, finding 11). The five categories' views as TextMouth ships
    /// them look as they always have.
    nonisolated static func showsEmptySentence(for view: LibraryViewDefinition, listsBooks: Bool, listsFeeds: Bool) -> Bool {
        (view.id.category == nil || !hasBooksSection(view)) && !listsBooks && !listsFeeds
    }

    /// The row saying that the view lists nothing now.
    private var emptyViewRow: some View {
        Text(LibraryViewPickerWording.emptyView)
            .foregroundColor(.secondary)
    }

    /// Moves to the first view offered when the view this window showed was
    /// deleted, from Settings or by a change of config.json, and says so, so
    /// the listener is never left somewhere silently (design section 5).
    private func followDeletedView() {
        let shown = libraryViewModel.shownView(shownViewID, in: views.list, center: feedFolders.center)
        guard shown.fellBack else { return }
        shownViewID = shown.view.id
        announceToVoiceOver(LibraryViewPickerWording.deletedView(nowShowing: shown.view.name))
    }

    /// Goes to the `number`th view Go to View counts and says its name and
    /// what it lists, or says that there is no such view, as the model
    /// decides (`LibraryViewModel.goToView(numbered:in:folderPath:center:)`,
    /// design section 6).
    private func goToView(numbered number: Int) {
        let outcome = libraryViewModel.goToView(numbered: number, in: views.list, folderPath: currentFolderPath, center: feedFolders.center)
        if let view = outcome.view {
            shownViewID = view.id
        }
        announceToVoiceOver(outcome.announcement)
    }

    /// The View pop-up (October 30, 2026): the views `offered`, each by its
    /// name, choosing the view shown, spoken "Library view" with its value
    /// first, and no wider than `LibraryViewPickerWording.pickerWidthLimit`,
    /// so a long name never makes the window's content wider than the window.
    private func viewPicker(offering offered: [LibraryViewDefinition]) -> some View {
        HStack(spacing: 0) {
            Picker("View", selection: $shownViewID) {
                ForEach(offered) { view in
                    Text(view.name).tag(view.id)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: LibraryViewPickerWording.pickerWidthLimit, alignment: .leading)
            .accessibilityLabel(Self.categoryPickerLabel)
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    /// The sort the list shows, restored from the setting saved for its
    /// location whenever the view draws, so the first frame, a change of
    /// folder or category, a change made in another window, and a library
    /// replaced by index recovery all show the saved sort (TODO A06).
    /// Showing it never saves it.
    private var sort: LibrarySortState {
        libraryViewModel.sortState(at: location)
    }

    /// What can be rearranged here now, or nil: one folder's manual order,
    /// while the list shows it, or the reading list at the Reading List,
    /// which always shows its own order (see
    /// `LibraryLocation.reorderTarget(sortedBy:)`, FR09).
    private var reorderTarget: LibraryReorderTarget? {
        location.reorderTarget(sortedBy: sort)
    }

    /// What dragging a row does: rearranges the order the list shows, a
    /// folder's manual order or the reading list, while the rows are that
    /// whole order, with no search narrowing them, and nothing anywhere
    /// else, where a row's position in the list is not its position in an
    /// order the user arranges (TODO A06, FR09). Nil turns dragging off.
    private var dragReorderAction: ((IndexSet, Int) -> Void)? {
        guard let target = reorderTarget, searchText.isEmpty else { return nil }
        return { source, destination in
            libraryViewModel.reorderBooks(in: target, from: source, to: destination)
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

    /// The Open Book choice's hint, once the Import Book button's. It named
    /// four formats, which left out most of those TextMouth reads, its
    /// audiobooks among them (TODO A10). The Add to Library sheet reuses it.
    nonisolated static let importBookHint = "Opens a file picker to import books in any format TextMouth reads."

    /// The Add to Library button (FR20), which replaced the Import, New from
    /// Text, and Add Feed buttons: it shows the sheet that lists those ways
    /// to add. The initial VoiceOver target when
    /// `focusTarget` says so.
    private func addToLibraryButton(focusTarget: LibraryFocusTarget?) -> some View {
        Button {
            addToLibrary.present()
        } label: {
            Label(AddToLibraryWording.buttonTitle, systemImage: "plus")
        }
        .accessibilityLabel(AddToLibraryWording.buttonLabel)
        .accessibilityHint(AddToLibraryWording.buttonHint)
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

    /// Move the currently selected book up or down in the order the list
    /// shows. Only works when a single book is selected and the list shows
    /// an order the user arranges: one folder's manual order (TODO A06), or
    /// the reading list (FR09). Announces the result to VoiceOver, and when
    /// the move cannot be made, says why rather than staying silent
    /// (`LibraryViewModel.moveSelection`). Only the books selected count:
    /// a selected folder row is not a book to move.
    private func moveSelectedBookInManualOrder(direction: Int) {
        moveBooks(Set(selectedBooks.map(\.id)), direction: direction)
    }

    /// Moves the one book in `bookIDs` one place up (-1) or down (+1) in the
    /// order the list shows, which saves at once, and tells VoiceOver where
    /// it went or why it could not, the same way in a folder and in the
    /// reading list. Move Up and Move Down in the context menu, and Move
    /// Book Up and Move Book Down from the menu and the keyboard, share it.
    private func moveBooks(_ bookIDs: Set<UUID>, direction: Int) {
        announceToVoiceOver(
            libraryViewModel.moveSelection(bookIDs, direction: direction, at: location, sortedBy: sort)
        )
    }

    /// A row's Move Up (-1) or Move Down (+1) VoiceOver action (FR09):
    /// moves `book` one place in the order the list shows, a folder's
    /// manual order or the reading list, which saves at once, and tells
    /// VoiceOver the book's new place, "Dune, 3 of 12", so many moves in a
    /// row each say where the book stands. Should the list have changed
    /// since the row offered the action, so the book cannot move that way,
    /// it says so rather than nothing.
    private func moveSayingPlace(_ book: Book, direction: Int) {
        guard let target = reorderTarget,
              let result = libraryViewModel.moveBook(book.id, direction: direction, in: target) else {
            announceToVoiceOver(ManualBookOrder.cannotMoveAnnouncement(book.title, direction: direction))
            return
        }
        announceToVoiceOver(result.placeAnnouncement)
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

    /// The Book Info sheet for `book`, as `showBookInfo(for:)` read it:
    /// read-only, with no editor, for an episode or article in its feed
    /// (FR11, `Book.hasReadOnlyBookInfo`), and otherwise the editor its
    /// format has.
    @ViewBuilder
    private func bookInfoSheet(for book: Book) -> some View {
        if book.hasReadOnlyBookInfo {
            FeedItemBookInfoSheet(book: book, info: bookInfo, feedTitle: libraryViewModel.feedTitle(of: book))
        } else {
            bookInfoEditor(for: book)
        }
    }

    /// The Book Info editor for `book`, a book the listener can edit, as
    /// `showBookInfo(for:)` read it: an EPUB's or an audiobook's metadata
    /// editor, or the simple title and author sheet.
    @ViewBuilder
    private func bookInfoEditor(for book: Book) -> some View {
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
                    handEdits: book.handEdits,
                    onSave: { edited, opened, writeToFile in
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
                        // Only what the user changed since the editor opened
                        // is saved.
                        let save = libraryViewModel.saveEPUBMetadata(
                            edited, openedAs: opened, for: book, writingToFile: writeToFile
                        )
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
                    handEdits: book.handEdits,
                    book: book,
                    onSave: { edited, opened in
                        // Compared with what the editor opened with, which
                        // shows the file's tags where the row keeps none,
                        // so only what the user changed is saved and
                        // recorded as edited by hand.
                        libraryViewModel.updateBookMetadata(Book.MetadataEdit(opened: opened, saved: edited), of: book.id)
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

// MARK: - Arranging Commands (TODO A06, FR09)

/// A Library window's part in the Library menu's commands that arrange its
/// selected books, and in their keys: Move Book Up and Move Book Down, which
/// move the one selected book in the order the list shows, and Add to
/// Reading List and Remove from Reading List (FR09), which act on the whole
/// selection. Only the window that takes a command acts on it.
private struct LibraryOrderCommandsSupport: ViewModifier {
    /// Whether this window takes the command a notification carries.
    let takesCommand: (Notification) -> Bool
    /// Moves the selected book one place: -1 up, +1 down.
    let moveSelectedBook: (Int) -> Void
    /// Adds the selected books to the reading list, or takes them off it.
    let changeReadingList: (ReadingListCommand.Kind) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .moveBookUp)) { notification in
                guard takesCommand(notification) else { return }
                moveSelectedBook(-1)
            }
            .onReceive(NotificationCenter.default.publisher(for: .moveBookDown)) { notification in
                guard takesCommand(notification) else { return }
                moveSelectedBook(1)
            }
            // Library > Add to Reading List and Remove from Reading List,
            // and their keys once the user gives them some.
            .onReceive(NotificationCenter.default.publisher(for: .addToReadingList)) { notification in
                guard takesCommand(notification) else { return }
                changeReadingList(.add)
            }
            .onReceive(NotificationCenter.default.publisher(for: .removeFromReadingList)) { notification in
                guard takesCommand(notification) else { return }
                changeReadingList(.remove)
            }
    }
}

// MARK: - Moving Between Views (October 30, 2026)

/// A Library window's part in moving between the Library's views (design
/// sections 5 and 6, LIBRARY-VIEWS-RESEARCH-2026-10-30.md): it gives the
/// Library menu's Go to View submenu the names of the views it offers, goes
/// to a view by Go to View's keys and the submenu's items when it takes the
/// command, and follows a view deleted while it shows it. Only the window
/// that takes a command acts on it.
private struct LibraryViewNavigationSupport: ViewModifier {
    /// The names of the views Go to View counts, which the submenu lists.
    let offeredNames: [String]
    /// The Library's views, whose changes the window follows.
    let list: LibraryViewDefinitionList
    /// Whether this window takes the command a notification carries.
    let takesCommand: (Notification) -> Bool
    /// Goes to the view numbered, 1 for the first.
    let goToView: (Int) -> Void
    /// Moves to the first view offered when the view shown was deleted.
    let followDeletedView: () -> Void

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.libraryOfferedViewNames, offeredNames)
            // Go to View 1 to Go to View 9, Command-1 to Command-9 unless
            // changed, and the submenu: the view numbered, said with what it
            // lists.
            .onReceive(NotificationCenter.default.publisher(for: .goToLibraryView)) { notification in
                guard takesCommand(notification), let number = ShortcutAction.goToViewNumber(in: notification.userInfo) else { return }
                goToView(number)
            }
            // A view deleted while this window shows it gives way to the
            // first view offered, which is said.
            .onChange(of: list) { _, _ in
                followDeletedView()
            }
    }
}

// MARK: - Folder Settings Support (FR19)

/// A Library window's part in the settings of the folder it shows (FR19): it
/// presents the Folder Settings sheet whenever `folderSettings` holds a
/// model, and hears the Library menu's Folder or Feed Settings, and its key
/// once the user gives it one. Only the window that takes the command acts
/// on it. It is not private so a test can host it.
struct LibraryFolderSettingsSupport: ViewModifier {
    /// The model of the sheet shown; nil while none is.
    @Binding var folderSettings: FolderSettingsModel?
    /// Whether this window takes the command a notification carries.
    let takesCommand: (Notification) -> Bool
    /// Opens the settings of the folder the window shows, or says there is
    /// none.
    let openShownSettings: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .showFolderOrFeedSettings)) { notification in
                guard takesCommand(notification) else { return }
                openShownSettings()
            }
            .sheet(item: $folderSettings) { model in
                FolderSettingsSheet(model: model, onDone: { folderSettings = nil })
            }
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
            // Why Remove Download kept a book's download. This alert is the
            // only place the refusal is said: nothing announces it besides
            // (#2094).
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

// MARK: - A Category's View

extension LibraryView {
    /// A Library window's list showing one of the five categories' views, as
    /// the hosted tests show them: `category` stands for the view's identity,
    /// read as `.category(category)`, and set whenever the view chosen is a
    /// category's. An initializer in an extension, so the memberwise one,
    /// which the window uses, is kept.
    init(
        currentFolderPath: Binding<String>,
        category: Binding<LibraryCategory>,
        showFileImporter: Binding<Bool>,
        showTextInput: Binding<Bool>,
        onOpenBook: @escaping (Book) -> Void,
        feedFolders: LibraryFeedFolders = .shared
    ) {
        self.init(
            currentFolderPath: currentFolderPath,
            shownViewID: Binding(
                get: { .category(category.wrappedValue) },
                set: { id in
                    if let chosen = id.category {
                        category.wrappedValue = chosen
                    }
                }
            ),
            showFileImporter: showFileImporter,
            showTextInput: showTextInput,
            onOpenBook: onOpenBook,
            feedFolders: feedFolders
        )
    }
}
